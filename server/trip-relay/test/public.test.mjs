import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { handle } from "../src/index.js";
import { MemoryBucket, makeEnv } from "./fakes.mjs";

const fixture = readFileSync(new URL("./fixtures/public-announcements.json", import.meta.url), "utf8");
const get = (path, headers = {}, method = "GET") => new Request(`https://relay.example.com${path}`, { method, headers });
const setup = async (extra = {}) => {
  const bucket = new MemoryBucket();
  const { env } = makeEnv({ PUBLIC_BUCKET: bucket, ...extra });
  await bucket.put("announcements/latest.json", fixture, { contentType: "application/json" });
  await bucket.put("packs/city-a/pois.json", "0123456789abcdefghij", { contentType: "application/json" });
  await bucket.put("models/place.mlpackage", "binary-model-data");
  bucket.writes = 0;
  return { env, bucket };
};
const emptyBody = { version: 0, items: [] };

test("announcements: returns the uploaded JSON untouched with etag and cache headers", async () => {
  const { env } = await setup();
  const response = await handle(get("/public/announcements"), env);
  assert.equal(response.status, 200);
  assert.equal(await response.text(), fixture);
  assert.ok(response.headers.get("etag"));
  assert.equal(response.headers.get("cache-control"), "public, max-age=300");
  assert.match(response.headers.get("content-type"), /^application\/json/);
  assert.equal(response.headers.get("access-control-allow-origin"), null);
});

test("announcements: empty bucket gives 200 with an empty list and no-store", async () => {
  const response = await handle(get("/public/announcements"), makeEnv({ PUBLIC_BUCKET: new MemoryBucket() }).env);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), emptyBody);
  assert.equal(response.headers.get("cache-control"), "no-store");
});

test("announcements: works without the R2 binding and without the Durable Object", async () => {
  const { env } = makeEnv();
  for (const bare of [env, { ...env, USER_STATE: undefined }]) {
    const response = await handle(get("/public/announcements"), bare);
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), emptyBody);
  }
});

test("announcements: broken JSON or missing items fall back to the empty list", async () => {
  const { env, bucket } = await setup();
  for (const text of ["{not json", '{"version":2}', '{"version":2,"items":"x"}', "null"]) {
    await bucket.put("announcements/latest.json", text);
    const response = await handle(get("/public/announcements"), env);
    assert.equal(response.status, 200, text);
    assert.deepEqual(await response.json(), emptyBody, text);
    assert.equal(response.headers.get("cache-control"), "no-store");
  }
});

test("announcements: If-None-Match with the current etag gives 304 without a body", async () => {
  const { env } = await setup();
  const first = await handle(get("/public/announcements"), env);
  const etag = first.headers.get("etag");
  const second = await handle(get("/public/announcements", { "if-none-match": etag }), env);
  assert.equal(second.status, 304);
  assert.equal(second.headers.get("etag"), etag);
  assert.equal(second.headers.get("cache-control"), "public, max-age=300");
  assert.equal(await second.text(), "");
});

test("assets: an allowed prefix is served with type, etag and accept-ranges", async () => {
  const { env } = await setup();
  const response = await handle(get("/public/assets/packs/city-a/pois.json"), env);
  assert.equal(response.status, 200);
  assert.equal(await response.text(), "0123456789abcdefghij");
  assert.match(response.headers.get("content-type"), /^application\/json/);
  assert.ok(response.headers.get("etag"));
  assert.equal(response.headers.get("accept-ranges"), "bytes");
  assert.equal(response.headers.get("cache-control"), "public, max-age=86400");
  const model = await handle(get("/public/assets/models/place.mlpackage"), env);
  assert.equal(model.headers.get("content-type"), "application/octet-stream");
  const cached = await handle(get("/public/assets/packs/city-a/pois.json", { "if-none-match": response.headers.get("etag") }), env);
  assert.equal(cached.status, 304);
});

test("assets: Range gives 206 with a matching content-range, a bad range gives 416", async () => {
  const { env } = await setup();
  const part = await handle(get("/public/assets/packs/city-a/pois.json", { range: "bytes=0-9" }), env);
  assert.equal(part.status, 206);
  assert.equal(await part.text(), "0123456789");
  assert.equal(part.headers.get("content-range"), "bytes 0-9/20");
  const tail = await handle(get("/public/assets/packs/city-a/pois.json", { range: "bytes=-5" }), env);
  assert.equal(tail.headers.get("content-range"), "bytes 15-19/20");
  assert.equal((await handle(get("/public/assets/packs/city-a/pois.json", { range: "bytes=500-600" }), env)).status, 416);
});

test("assets: missing files and a missing file name are 404", async () => {
  const { env } = await setup();
  for (const path of ["/public/assets/packs/nope.json", "/public/assets/packs/", "/public/assets/packs", "/public/assets/", "/public/assets"]) {
    assert.equal((await handle(get(path), env)).status, 404, path);
  }
  assert.equal((await handle(get("/public/assets/packs/x.json"), makeEnv().env)).status, 404, "no binding");
});

test("assets: malformed keys are rejected with 400 and never reach R2", async () => {
  const { env, bucket } = await setup();
  const bad = [
    "/public/assets/packs//x.json", "/public/assets/packs/%2e%2e%2fsecret", "/public/assets/packs/..%2fsecret", "/public/assets/packs/a%20b.json",
    "/public/assets/packs/a%5Cb.json", "/public/assets/packs/.hidden", "/public/assets/packs/a b.json", "/public/assets/packs/a/b/c/d/e/f/g/h.json",
    `/public/assets/packs/${"a".repeat(200)}.json`,
  ];
  for (const path of bad) assert.equal((await handle(get(path), env)).status, 400, path);
  assert.equal(bucket.reads, 0);
});

test("assets: dot segments are normalised by the URL parser and end in 404 before R2", async () => {
  const { env, bucket } = await setup();
  for (const path of ["/public/assets/packs/../secret", "/public/assets/packs/%2e%2e/secret", "/public/assets/packs/./../../x"]) {
    const response = await handle(get(path), env);
    assert.equal(response.status, 404, path);
  }
  assert.equal(bucket.reads, 0);
});

test("assets: prefixes outside the allow-list are 404", async () => {
  const { env, bucket } = await setup();
  for (const path of ["/public/assets/private/x.json", "/public/assets/packsx/x.json", "/public/assets/x.json"]) {
    assert.equal((await handle(get(path), env)).status, 404, path);
  }
  assert.equal(bucket.reads, 0);
});

test("only GET is allowed and nothing is ever written to R2", async () => {
  const { env, bucket } = await setup();
  for (const method of ["POST", "PUT", "DELETE", "PATCH", "HEAD"]) {
    for (const path of ["/public/announcements", "/public/assets/packs/city-a/pois.json"]) {
      const response = await handle(get(path, {}, method), env);
      assert.equal(response.status, 405, `${method} ${path}`);
      assert.equal(response.headers.get("allow"), "GET");
    }
  }
  await handle(get("/public/announcements"), env);
  await handle(get("/public/assets/packs/city-a/pois.json", { range: "bytes=0-3" }), env);
  assert.equal(bucket.writes, 0);
});

test("public routes leave the authenticated routes unchanged", async () => {
  const { env } = await setup();
  assert.equal((await handle(get("/plan"), env)).status, 401);
  assert.equal((await handle(get("/public/other"), env)).status, 404);
});

test("the fixture follows the documented announcement schema", () => {
  const body = JSON.parse(fixture);
  assert.ok(Number.isInteger(body.version) && body.version >= 1);
  assert.ok(Array.isArray(body.items) && body.items.length <= 50);
  for (const item of body.items) {
    assert.match(item.id, /^[a-z0-9][a-z0-9._-]{0,63}$/);
    assert.ok(item.title.length >= 1 && item.title.length <= 100);
    assert.ok(item.body.length >= 1 && item.body.length <= 2000);
    assert.ok(["info", "update", "warning", "critical"].includes(item.kind));
    if (item.link) assert.ok(item.link.startsWith("https://") && item.link.length <= 300);
  }
});
