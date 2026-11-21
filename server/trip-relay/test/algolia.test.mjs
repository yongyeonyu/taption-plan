// SRCH1121A01: 도시 팩 Algolia 색인·Secured Key 발급. 값은 모두 가짜다(진짜 앱 ID·키 없음).
import assert from "node:assert/strict";
import test from "node:test";
import { INDEX_NAME, SETTINGS, SYNONYMS, indexPack, record, records, securedKey } from "../src/algolia.js";
import { handle } from "../src/index.js";
import { MemoryBucket, makeEnv } from "./fakes.mjs";

const ORIGIN = "https://relay.example.com";
const randomKey = () => Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64url");
const req = (path, method = "GET", body, key) => new Request(`${ORIGIN}${path}`, {
  method,
  headers: { ...(key ? { authorization: `Bearer ${key}` } : {}), "content-type": "application/json" },
  body: body === undefined ? undefined : JSON.stringify(body),
});
const send = (env, ...args) => handle(req(...args), env);

const pack = (version = 2) => ({
  format: "bokki-trip-pack", schema: 1, city: "fixture-city", version,
  items: [
    { id: "r-001", category: "restaurant", name: "Example Diner A", nameKo: "예시 식당 A", area: "예시구", address: "비밀 주소 1", phone: "000-0000", lat: 10, lng: 20,
      tags: ["예시", "라멘"], hours: "09:00-18:00", priceHint: "₩", note: "내부 메모", source: "seed", sourceURL: "https://example.com", checkedAt: "2026-11-01", checkedBy: "대표" },
    { id: "s-001", category: "sight", name: "Example Park", nameKo: "예시 공원", area: "예시구", lat: 10.01, lng: 20.01, note: "x", source: "seed", checkedAt: "2026-11-02", checkedBy: "비야" },
    { id: "bad", category: "sight", name: "No Coordinates", nameKo: "좌표 없음", area: "예시구", note: "x", source: "seed", checkedAt: "2026-11-02", checkedBy: "비야" },
  ],
});

test("records keep only the search fields and drop address, phone, notes and items without coordinates", () => {
  const list = records(pack());
  assert.equal(list.length, 2);
  const first = list[0];
  assert.equal(first.objectID, "fixture-city:2:r-001");
  assert.deepEqual(Object.keys(first).sort(), ["area", "category", "checkedAt", "city", "hours", "lat", "lng", "name", "nameKo", "objectID", "priceHint", "source", "tags", "version"].sort());
  assert.equal(JSON.stringify(list).includes("비밀 주소"), false);
  assert.equal(JSON.stringify(list).includes("000-0000"), false);
  assert.equal(JSON.stringify(list).includes("내부 메모"), false);
  assert.equal(record("c", 1, { id: "x", name: "N", lat: "1", lng: 2 }), undefined);
});

test("records reject a pack with the wrong shape or an unsafe city", () => {
  assert.equal(records({ ...pack(), format: "other" }), undefined);
  assert.equal(records({ ...pack(), city: "Bad City!" }), undefined);
  assert.equal(records({ ...pack(), version: 0 }), undefined);
});

test("indexPack upserts in batches, then deletes only older versions of the same city", async () => {
  const calls = [];
  const fetcher = async (url, init) => { calls.push({ url, init, body: init.body ? JSON.parse(init.body) : undefined }); return new Response("{}", { status: 200 }); };
  const result = await indexPack({ appId: "TESTAPP123", key: "write-secret" }, fetcher, pack(3));
  assert.deepEqual(result, { ok: true, indexed: 2, city: "fixture-city", version: 3 });
  assert.equal(calls.length, 2);
  assert.match(calls[0].url, new RegExp(`^https://TESTAPP123\\.algolia\\.net/1/indexes/${INDEX_NAME}/batch$`));
  assert.equal(calls[0].init.headers["x-algolia-api-key"], "write-secret");
  assert.equal(calls[0].body.requests.length, 2);
  assert.equal(calls[0].body.requests[0].action, "updateObject");
  assert.match(calls[1].url, /deleteByQuery$/);
  assert.deepEqual(calls[1].body, { facetFilters: ["city:fixture-city"], numericFilters: ["version<3"] });
});

test("an Algolia failure never echoes the upstream body or the key", async () => {
  const fetcher = async () => new Response("secret-write-key leaked here", { status: 403 });
  const result = await indexPack({ appId: "TESTAPP123", key: "secret-write-key" }, fetcher, pack());
  assert.deepEqual(result, { ok: false, error: "algolia_failed", status: 403 });
  assert.equal(JSON.stringify(result).includes("secret-write-key"), false);
});

test("securedKey locks the city, version, expiry and index, and signs with the parent key", async () => {
  const key = await securedKey("parent-search-key", { city: "fixture-city", version: 2, validUntil: 1_800_000_000 });
  const decoded = Buffer.from(key, "base64").toString();
  const params = decoded.slice(64);
  assert.match(decoded.slice(0, 64), /^[0-9a-f]{64}$/);
  const parsed = new URLSearchParams(params);
  assert.equal(parsed.get("filters"), 'city:"fixture-city" AND version:2');
  assert.equal(parsed.get("validUntil"), "1800000000");
  assert.equal(parsed.get("restrictIndices"), INDEX_NAME);
  const expected = Buffer.from(await crypto.subtle.sign("HMAC", await crypto.subtle.importKey("raw", new TextEncoder().encode("parent-search-key"), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]), new TextEncoder().encode(params))).toString("hex");
  assert.equal(decoded.slice(0, 64), expected);
  assert.equal(decoded.includes("parent-search-key"), false);
});

test("settings carry the synonyms and filters, and never geo or personal fields", () => {
  assert.ok(SYNONYMS.some((entry) => entry.synonyms.includes("ラーメン") && entry.synonyms.includes("라멘") && entry.synonyms.includes("ramen")));
  assert.ok(SETTINGS.attributesForFaceting.includes("filterOnly(city)"));
  assert.equal(JSON.stringify(SETTINGS).includes("geo"), false);
  assert.equal(SETTINGS.attributesToRetrieve.includes("address"), false);
  assert.equal(SETTINGS.attributesToRetrieve.includes("phone"), false);
});

test("the key route needs a search key, 503s without the search key, and never falls back to the write key", async () => {
  const { env } = makeEnv({ ALGOLIA_APP_ID: "TESTAPP123", ALGOLIA_WRITE_KEY: "write-secret", NOW: () => Date.UTC(2027, 0, 1, 0, 0) });
  const key = randomKey();
  assert.equal((await send(env, "/search/packs/key?city=fixture-city&version=2")).status, 401);
  await send(env, "/register", "POST", { purpose: "search" }, key);
  const response = await send(env, "/search/packs/key?city=fixture-city&version=2", "GET", undefined, key);
  assert.equal(response.status, 503);
  assert.equal((await response.json()).error, "algolia_key_missing");
});

test("the key route gives a short-lived Secured Key, validates input, and stops at the daily budget", async () => {
  const now = Date.UTC(2027, 0, 1, 0, 0);
  const { env } = makeEnv({ ALGOLIA_APP_ID: "TESTAPP123", ALGOLIA_SEARCH_KEY: "parent-search-key", ALGOLIA_WRITE_KEY: "write-secret", ALGOLIA_KEY_DAILY: "2", NOW: () => now });
  const key = randomKey();
  await send(env, "/register", "POST", { purpose: "search" }, key);
  const ok = await send(env, "/search/packs/key?city=fixture-city&version=2", "GET", undefined, key);
  assert.equal(ok.status, 200);
  const body = await ok.json();
  assert.equal(body.appId, "TESTAPP123");
  assert.equal(body.index, INDEX_NAME);
  assert.equal(body.validUntil, Math.floor(now / 1000) + 3600);
  const raw = JSON.stringify(body);
  assert.equal(raw.includes("parent-search-key"), false);
  assert.equal(raw.includes("write-secret"), false);
  assert.equal((await send(env, "/search/packs/key?city=Bad%20City&version=2", "GET", undefined, key)).status, 400);
  assert.equal((await send(env, "/search/packs/key?city=fixture-city&version=abc", "GET", undefined, key)).status, 400);
  assert.equal((await send(env, "/search/packs/key?city=fixture-city&version=2", "GET", undefined, key)).status, 200);
  const capped = await send(env, "/search/packs/key?city=fixture-city&version=2", "GET", undefined, key);
  assert.equal(capped.status, 429);
  assert.equal((await capped.json()).error, "algolia_key_daily_limit");
});

test("index and settings routes are owner-only and read the pack from R2", async () => {
  const calls = [];
  const fetcher = async (url, init) => { calls.push({ url, body: init.body ? JSON.parse(init.body) : undefined }); return new Response("{}", { status: 200 }); };
  const bucket = new MemoryBucket();
  await bucket.put("packs/trip/fixture-city/2/items.json", JSON.stringify(pack(2)));
  const { env } = makeEnv({ ALGOLIA_APP_ID: "TESTAPP123", ALGOLIA_WRITE_KEY: "write-secret", PUBLIC_BUCKET: bucket, FETCH: fetcher });
  const search = randomKey();
  const owner = randomKey();
  await send(env, "/register", "POST", { purpose: "search" }, search);
  await send(env, "/register", "POST", {}, owner);
  assert.notEqual((await send(env, "/search/packs/index", "POST", { city: "fixture-city", version: 2 }, search)).status, 200, "검색 키로는 색인할 수 없다");
  const response = await send(env, "/search/packs/index", "POST", { city: "fixture-city", version: 2 }, owner);
  assert.equal(response.status, 200);
  assert.equal((await response.json()).indexed, 2);
  assert.equal(calls.length, 2);
  assert.equal((await send(env, "/search/packs/index", "POST", { city: "fixture-city", version: 9 }, owner)).status, 404);
  const settings = await send(env, "/search/packs/settings", "POST", undefined, owner);
  assert.equal(settings.status, 200);
  assert.ok(calls.some((call) => /settings$/.test(call.url)));
  const bare = makeEnv({ FETCH: fetcher }).env;
  const other = randomKey();
  await send(bare, "/register", "POST", {}, other);
  assert.equal((await send(bare, "/search/packs/settings", "POST", undefined, other)).status, 503);
});
