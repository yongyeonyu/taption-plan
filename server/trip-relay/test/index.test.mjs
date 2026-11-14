import assert from "node:assert/strict";
import test from "node:test";
import { handle, isActivityUpload, isCommand, isTripPlan, kakaoImage, kakaoKeyword, photoSearch, seal, storageCryptoKey, storageKey } from "../src/index.js";

import { MemoryKV, makeEnv } from "./fakes.mjs";

const randomKey = () => Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64url");
const token = randomKey();
const other = randomKey();
// SEC1110A02: 등록한 키만 받는다. 시험마다 주인 키 둘을 등록한 환경을 만든다.
async function fresh(extra = {}) {
  const { env } = makeEnv(extra);
  for (const key of [token, other]) {
    const response = await handle(new Request("https://relay.example.com/register", { method: "POST", headers: { authorization: `Bearer ${key}` } }), { ...env, POST_LIMIT: undefined });
    assert.equal(response.status, 201);
  }
  return env;
}
// 등록 표시(reg:)를 뺀 저장 이름.
const dataNames = (env) => [...env.PLANS.map.keys()].filter((name) => !name.startsWith("reg:"));
const plan = { format: "bokki-trip", version: 1, tripId: "trip-1", title: "방콕", items: [{ id: "i1", type: "sight", title: "왓 아룬", start: "2026-12-02T09:00+07:00" }] };
const call = (method, body, key = token) => new Request("https://relay.example.com/plan", {
  method,
  headers: key ? { authorization: `Bearer ${key}`, "content-type": "application/json" } : {},
  body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body),
});

test("post then get then delete one plan per key, stored under a hash only", async () => {
  const env = await fresh();
  assert.equal((await handle(call("POST", plan), env)).status, 201);
  const stored = dataNames(env);
  assert.deepEqual(stored, [await storageKey(token)]);
  assert.ok(!stored[0].includes(token), "raw key is never stored");
  assert.equal(env.PLANS.options.get(stored[0]).expirationTtl, 3 * 24 * 60 * 60);
  const fetched = await handle(call("GET"), env);
  assert.equal(fetched.status, 200);
  assert.deepEqual(await fetched.json(), plan);
  assert.equal((await handle(call("DELETE"), env)).status, 204);
  assert.equal((await handle(call("GET"), env)).status, 204);
});

test("other keys cannot read a plan", async () => {
  const env = await fresh();
  await handle(call("POST", plan), env);
  assert.equal((await handle(call("GET", undefined, other), env)).status, 204);
});

test("rejects missing or malformed keys, non-trip bodies and large bodies", async () => {
  const env = await fresh();
  assert.equal((await handle(call("GET", undefined, null), env)).status, 401);
  assert.equal((await handle(call("GET", undefined, "short"), env)).status, 401);
  assert.equal((await handle(call("POST", "not json"), env)).status, 400);
  assert.equal((await handle(call("POST", { format: "other" }), env)).status, 422);
  assert.equal((await handle(call("POST", { ...plan, note: "x".repeat(70 * 1024) }), env)).status, 413);
  assert.equal((await handle(new Request("https://relay.example.com/other"), env)).status, 404);
  assert.deepEqual(dataNames(env), []);
});

test("trip plan contract matches the app", () => {
  assert.ok(isTripPlan(plan));
  assert.ok(!isTripPlan({ ...plan, version: 2 }));
  assert.ok(!isTripPlan({ ...plan, items: [] }));
});

test("post is refused with 429 once the per-IP limit is used up", async () => {
  let calls = 0;
  const env = await fresh({ POST_LIMIT: { limit: async () => ({ success: ++calls <= 1 }) } });
  assert.equal((await handle(call("POST", plan), env)).status, 201);
  assert.equal((await handle(call("POST", plan), env)).status, 429);
  assert.equal((await handle(call("GET"), env)).status, 200, "reads are not limited");
});

test("kakao proxy forwards allowed params with the secret key and hides it from the app", async () => {
  let seen;
  const fetcher = async (url, init) => { seen = { url: new URL(url), auth: init.headers.authorization }; return new Response("{\"documents\":[]}", { status: 200 }); };
  const request = new Request("https://relay.example.com/kakao/keyword?query=%EC%B9%B4%ED%8E%98&x=127&y=37&sort=distance&evil=1");
  const response = await kakaoKeyword(request, { KAKAO_REST_API_KEY: "secret" }, fetcher);
  assert.equal(response.status, 200);
  assert.equal(seen.auth, "KakaoAK secret");
  assert.equal(seen.url.searchParams.get("query"), "카페");
  assert.equal(seen.url.searchParams.get("evil"), null);
  assert.equal((await kakaoKeyword(new Request("https://relay.example.com/kakao/keyword?query="), { KAKAO_REST_API_KEY: "secret" }, fetcher)).status, 400);
  assert.equal((await kakaoKeyword(request, {}, fetcher)).status, 503);
});


// AIR1110A01 / TRP1110A07: activity history and command queue.
const at = (path, method, body, key = token) => new Request(`https://relay.example.com${path}`, {
  method,
  headers: key ? { authorization: `Bearer ${key}`, "content-type": "application/json" } : {},
  body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body),
});
const hashOf = async (key = token) => (await storageKey(key)).slice("plan:".length);
const day = (date, extra = {}) => ({ date, timeZone: "Asia/Seoul", updatedAt: `${date}T12:00:00+09:00`, summary: { categories: [], recordedMinutes: 0, plansScheduled: 0, plansCompleted: 0 }, records: [], memos: [], ...extra });
const upload = (days, retentionDays = 7) => ({ format: "bokki-activity", version: 1, retentionDays, days });
const command = (id, action, extra) => ({ format: "bokki-command", version: 1, id, action, ...extra });
const memoCommand = (id, extra = {}) => command(id, "addMemo", { text: "우유 사기", date: "2026-11-10", time: "18:30", ...extra });

test("new routes need a valid key", async () => {
  const env = await fresh();
  const routes = [["/activity", "POST"], ["/activity", "GET"], ["/activity", "DELETE"], ["/command", "POST"], ["/command", "GET"], ["/command", "DELETE"], ["/command/result", "POST"], ["/command/result", "GET"]];
  for (const [path, method] of routes) {
    for (const key of [null, "bad", randomKey()]) {
      assert.equal((await handle(at(path, method, method === "POST" ? memoCommand("m") : undefined, key), env)).status, 401, `${method} ${path}`);
    }
  }
  assert.deepEqual(dataNames(env), []);
});

test("activity stores each day under its own key with the chosen retention", async () => {
  for (const [retention, ttl] of [[1, 86400], [7, 7 * 86400], [30, 30 * 86400]]) {
    const env = await fresh();
    const response = await handle(at("/activity", "POST", upload([day("2026-11-09"), day("2026-11-10")], retention)), env);
    assert.equal(response.status, 201);
    const hash = await hashOf();
    // SEC1110A02: 날짜 대신 HMAC 이름.
    const names = dataNames(env);
    assert.equal(names.length, 2);
    assert.ok(names.every((n) => /^act:[0-9a-f]{64}:[0-9a-f]{32}$/.test(n) && n.startsWith(`act:${hash}:`)), names.join());
    assert.ok(names.every((n) => env.PLANS.options.get(n).expirationTtl === ttl));
  }
});

test("activity rejects other formats, retention values and day counts", async () => {
  const env = await fresh();
  assert.ok(isActivityUpload(upload([day("2026-11-10")])));
  for (const bad of [
    upload([day("2026-11-10")], 3),
    { ...upload([day("2026-11-10")]), format: "bokki-today" },
    upload([]),
    upload(Array.from({ length: 8 }, (_, i) => day(`2026-11-0${i + 1}`))),
    upload([day("11/10")]),
  ]) assert.equal((await handle(at("/activity", "POST", bad), env)).status, 422);
  assert.equal((await handle(at("/activity", "POST", "nope"), env)).status, 400);
  assert.equal((await handle(at("/activity", "POST", upload([day("2026-11-10", { pad: "x".repeat(70 * 1024) })])), env)).status, 413);
  assert.deepEqual(dataNames(env), []);
});

test("activity reads one day by date or the newest 7 days, and reads do not delete", async () => {
  const env = await fresh();
  assert.equal((await handle(at("/activity", "GET"), env)).status, 204);
  const dates = Array.from({ length: 9 }, (_, i) => `2026-11-${String(i + 1).padStart(2, "0")}`);
  await handle(at("/activity", "POST", upload(dates.slice(0, 7).map((d) => day(d)))), env);
  await handle(at("/activity", "POST", upload(dates.slice(7).map((d) => day(d)))), env);
  const one = await handle(at("/activity?date=2026-11-03", "GET"), env);
  assert.equal(one.status, 200);
  assert.equal((await one.json()).date, "2026-11-03");
  assert.equal((await handle(at("/activity?date=2026-10-01", "GET"), env)).status, 204);
  assert.equal((await handle(at("/activity?date=bad", "GET"), env)).status, 400);
  const list = await (await handle(at("/activity", "GET"), env)).json();
  assert.deepEqual(list.days.map((d) => d.date), dates.slice(2).reverse());
  assert.equal((await handle(at("/activity", "GET", undefined, other), env)).status, 204, "other keys see nothing");
  assert.equal(dataNames(env).length, 9);
});

test("activity delete removes every day of this key only, across list pages", async () => {
  const env = await fresh();
  await handle(at("/activity", "POST", upload(["2026-11-08", "2026-11-09", "2026-11-10"].map((d) => day(d)))), env);
  await handle(at("/activity", "POST", upload([day("2026-11-10")]), other), env);
  assert.equal((await handle(at("/activity", "DELETE"), env)).status, 204);
  assert.equal((await handle(at("/activity", "GET"), env)).status, 204);
  assert.equal((await handle(at("/activity", "GET", undefined, other), env)).status, 200);
});

test("commands are validated per action", () => {
  assert.ok(isCommand(memoCommand("m1")));
  assert.ok(isCommand(command("m2", "addMemo", { text: "날짜 없이" })));
  assert.ok(!isCommand(memoCommand("m3", { text: "" })));
  assert.ok(!isCommand(memoCommand("m4", { text: "x".repeat(1001) })));
  assert.ok(!isCommand(memoCommand("m5", { time: "25:00" })));
  assert.ok(!isCommand(memoCommand("a,b")));
  assert.ok(isCommand(command("s1", "addSchedule", { title: "치과", start: "2026-11-12T15:00+09:00", end: "2026-11-12T16:00+09:00", note: "검진" })));
  assert.ok(!isCommand(command("s2", "addSchedule", { title: "치과", start: "2026-11-12 15:00" })));
  assert.ok(!isCommand(command("s3", "addSchedule", { title: "치과", start: "2026-11-12T15:00+09:00", end: "2026-11-12T14:00+09:00" })));
  assert.ok(isCommand(command("u1", "updateActivity", { date: "2026-11-10", startTime: "14:00", title: "점심" })));
  assert.ok(isCommand(command("u2", "updateActivity", { date: "2026-11-10", recordId: "R1", categoryId: "eating" })));
  assert.ok(!isCommand(command("u3", "updateActivity", { date: "2026-11-10", startTime: "14:00" })), "needs title or category");
  assert.ok(!isCommand(command("u4", "updateActivity", { date: "2026-11-10", title: "점심" })), "needs a target");
  assert.ok(!isCommand(command("u5", "updateActivity", { startTime: "14:00", title: "점심" })), "needs a date");
  assert.ok(!isCommand(command("x1", "deleteEverything", {})));
  assert.ok(!isCommand({ ...memoCommand("v1"), version: 2 }));
});

test("command queue holds 100, refuses more with queue_full, replaces the same id and refreshes a 7-day TTL", async () => {
  // 한 시간에 하나씩 보내 24시간 30개 한도에 걸리지 않게 한다(CLN1110A01).
  let clock = Date.parse("2026-11-10T00:00:00Z");
  const env = await fresh({ NOW: () => clock });
  assert.equal((await handle(at("/command", "GET"), env)).status, 204);
  assert.equal((await handle(at("/command", "POST", { format: "other" }), env)).status, 422);
  for (let i = 0; i < 100; i++, clock += 3600_000) assert.equal((await handle(at("/command", "POST", memoCommand(`m${i}`)), env)).status, 201);
  // 꽉 차면 오래된 것을 지우지 않고 새 것을 거절한다(AIP1114A05). 같은 id를 바꾸는 것과 말풍선은 받는다.
  const full = await handle(at("/command", "POST", memoCommand("m100")), env);
  assert.equal(full.status, 429);
  assert.deepEqual(await full.json(), { error: "queue_full", limit: 100 });
  assert.equal((await handle(at("/command", "POST", memoCommand("m99", { text: "두유 사기" })), env)).status, 201);
  const { commands } = await (await handle(at("/command", "GET"), env)).json();
  assert.equal(commands.length, 100);
  assert.equal(commands[0].id, "m0", "the oldest command is kept");
  assert.equal(commands.at(-1).text, "두유 사기");
  // 앱이 가져가 지우면 다시 받는다.
  assert.equal((await handle(at("/command?ids=m0", "DELETE"), env)).status, 204);
  assert.equal((await handle(at("/command", "POST", memoCommand("m100")), env)).status, 201);
  assert.ok(!Number.isNaN(Date.parse(commands[0].receivedAt)));
  assert.deepEqual([commands[0].keyId, commands[0].source], ["master", "rest"], "SEC1110A02 attribution");
  assert.ok(!dataNames(env).some((n) => n.startsWith("cmd:")), "the queue lives in the Durable Object");
});

test("command delete removes listed ids or all", async () => {
  const env = await fresh();
  for (const id of ["a", "b", "c"]) await handle(at("/command", "POST", memoCommand(id)), env);
  assert.equal((await handle(at("/command?ids=a,c", "DELETE"), env)).status, 204);
  assert.deepEqual((await (await handle(at("/command", "GET"), env)).json()).commands.map((c) => c.id), ["b"]);
  assert.equal((await handle(at("/command", "DELETE"), env)).status, 204);
  assert.equal((await handle(at("/command", "GET"), env)).status, 204);
});

test("command results are stored for the AI, deduped by id", async () => {
  const env = await fresh();
  assert.equal((await handle(at("/command/result", "GET"), env)).status, 204);
  assert.equal((await handle(at("/command/result", "POST", { results: [{ id: "a", status: "maybe" }] }), env)).status, 422);
  assert.equal((await handle(at("/command/result", "POST", { results: [] }), env)).status, 422);
  await handle(at("/command/result", "POST", { results: [{ id: "a", status: "rejected", reason: "no_record" }, { id: "b", status: "applied" }] }), env);
  await handle(at("/command/result", "POST", { results: [{ id: "a", status: "applied" }] }), env);
  const { results } = await (await handle(at("/command/result", "GET"), env)).json();
  assert.deepEqual(results.map((r) => [r.id, r.status, r.reason]), [["b", "applied", undefined], ["a", "applied", undefined]]);
  assert.equal(env.PLANS.options.get("cmdres:" + await hashOf()).expirationTtl, 7 * 86400);
});

test("every new write route shares the per-IP limit", async () => {
  let calls = 0;
  const env = await fresh({ POST_LIMIT: { limit: async () => ({ success: ++calls <= 3 }) } });
  assert.equal((await handle(at("/activity", "POST", upload([day("2026-11-10")])), env)).status, 201);
  assert.equal((await handle(at("/command", "POST", memoCommand("m1")), env)).status, 201);
  assert.equal((await handle(at("/command/result", "POST", { results: [{ id: "m1", status: "applied" }] }), env)).status, 201);
  assert.equal((await handle(at("/activity", "POST", upload([day("2026-11-10")])), env)).status, 429);
  assert.equal((await handle(at("/command", "POST", memoCommand("m2")), env)).status, 429);
  assert.equal((await handle(at("/command/result", "POST", { results: [{ id: "m2", status: "applied" }] }), env)).status, 429);
  assert.equal((await handle(at("/activity", "GET"), env)).status, 200, "reads are not limited");
  assert.equal((await handle(at("/command", "GET"), env)).status, 200);
});

// SEC1110A01: storage encryption.
// 무작위 암호문(base64)에 우연히 나오지 않을 만큼 긴 명령 id. 두 글자 "m1"은 6번에 1번쯤 우연히 걸렸다(FLK1112A01).
const SECRET_ID = "memo-id.secret:0001";
test("stored values are encrypted envelopes without plaintext", async () => {
  const env = await fresh();
  await handle(call("POST", plan), env);
  await handle(at("/command", "POST", memoCommand(SECRET_ID, { text: "비밀 메모 우유" })), env);
  await handle(at("/activity", "POST", upload([day("2026-11-10", { memos: [{ id: "x", text: "비밀 일기" }] })])), env);
  await handle(at("/command/result", "POST", { results: [{ id: SECRET_ID, status: "applied", reason: "secret_reason" }] }), env);
  assert.equal(dataNames(env).length, 3, "plan, one day, results; the queue is in the DO");
  for (const name of dataNames(env)) {
    const value = env.PLANS.map.get(name);
    const envelope = JSON.parse(value);
    assert.equal(envelope.v, 2, name);
    assert.equal(Buffer.from(envelope.iv, "base64").length, 12);
    for (const secret of ["왓 아룬", "비밀 메모", "비밀 일기", "secret_reason", "bokki"]) assert.ok(!value.includes(secret), `${name} leaks ${secret}`);
  }
  for (const instance of env.USER_STATE.instances.values()) {
    const dump = JSON.stringify([...instance.storage.map.entries()]);
    for (const secret of ["비밀 메모", SECRET_ID, "2026-11-10", "bokki"]) assert.ok(!dump.includes(secret), `DO leaks ${secret}`);
  }
  assert.equal((await (await handle(call("GET"), env)).json()).title, "방콕", "the right token still reads it");
});

test("tampered ciphertext reads as absent and is deleted", async () => {
  const env = await fresh();
  await handle(call("POST", plan), env);
  const name = await storageKey(token);
  const envelope = JSON.parse(env.PLANS.map.get(name));
  const bytes = Buffer.from(envelope.ct, "base64");
  bytes[0] ^= 1;
  env.PLANS.map.set(name, JSON.stringify({ ...envelope, ct: bytes.toString("base64") }));
  assert.equal((await handle(call("GET"), env)).status, 204);
  assert.ok(!env.PLANS.map.has(name));
});

test("a value copied to another key name does not decrypt (AAD)", async () => {
  const env = await fresh();
  await handle(at("/activity", "POST", upload([day("2026-11-09"), day("2026-11-10")])), env);
  const [first, second] = dataNames(env).filter((n) => n.startsWith("act:"));
  env.PLANS.map.set(first, env.PLANS.map.get(second));
  const dates = [];
  for (const date of ["2026-11-09", "2026-11-10"]) dates.push((await handle(at(`/activity?date=${date}`, "GET"), env)).status);
  assert.deepEqual(dates.sort(), [200, 204], "the moved copy no longer opens");
});

test("another token cannot open a value even under its own key name", async () => {
  const env = await fresh();
  const name = await storageKey(other);
  env.PLANS.map.set(name, await seal(await storageCryptoKey(token), name, JSON.stringify(plan)));
  assert.equal((await handle(call("GET", undefined, other), env)).status, 204);
});

test("legacy plaintext plans stay readable once and are encrypted on the next write", async () => {
  const env = await fresh();
  const name = await storageKey(token);
  env.PLANS.map.set(name, JSON.stringify(plan));
  const read = await handle(call("GET"), env);
  assert.equal(read.status, 200);
  assert.deepEqual(await read.json(), plan);
  await handle(call("POST", plan), env);
  assert.equal(JSON.parse(env.PLANS.map.get(name)).v, 2);
  const hash = await hashOf();
  // SEC1110A02: 다른 접두어의 평문도 지우지 않고 다시 잠가 옮긴다(2026-11-14까지).
  env.PLANS.map.set("cmd:" + hash, JSON.stringify([memoCommand("plain")]));
  const queued = await (await handle(at("/command", "GET"), env)).json();
  assert.deepEqual(queued.commands.map((c) => [c.id, c.keyId, c.source]), [["plain", null, "legacy"]]);
  assert.ok(!env.PLANS.map.has("cmd:" + hash), "moved into the Durable Object");
});

test("kakao image proxy returns only https photo links and their source (PHX1114A01)", async () => {
  let asked;
  const fetcher = async (url, init) => {
    asked = { url: String(url), auth: init.headers.authorization };
    return new Response(JSON.stringify({ documents: [
      { image_url: "https://img.example.com/a.jpg", thumbnail_url: "https://thumb.example.com/a", width: 800, height: 600, display_sitename: "어느 블로그", doc_url: "https://blog.example.com/1", collection: "blog" },
      { image_url: "http://insecure.example.com/b.jpg", thumbnail_url: "http://insecure.example.com/b", width: 1, height: 1, display_sitename: "x", doc_url: "http://x" },
    ] }), { status: 200 });
  };
  const response = await kakaoImage(new Request("https://relay.example.com/kakao/image?query=%EC%B9%B4%ED%8E%98"), { KAKAO_REST_API_KEY: "secret" }, fetcher);
  assert.equal(response.status, 200);
  assert.match(asked.url, /^https:\/\/dapi\.kakao\.com\/v2\/search\/image\?query=.*&size=5$/);
  assert.equal(asked.auth, "KakaoAK secret");
  assert.deepEqual((await response.json()).documents, [{ image: "https://img.example.com/a.jpg", thumbnail: "https://thumb.example.com/a", width: 800, height: 600, site: "어느 블로그", page: "https://blog.example.com/1" }]);
  assert.equal((await kakaoImage(new Request("https://relay.example.com/kakao/image?query="), { KAKAO_REST_API_KEY: "secret" }, fetcher)).status, 400);
  assert.equal((await kakaoImage(new Request("https://relay.example.com/kakao/image?query=a"), {}, fetcher)).status, 503);
});

test("photo search relays each source with its own key and returns only https links with a credit (PHS1114A01)", async () => {
  const seen = [];
  const answer = (body) => async (url, init = {}) => { seen.push({ url: String(url), headers: init.headers ?? {} }); return new Response(JSON.stringify(body), { status: 200 }); };
  const ask = (query, env, body) => photoSearch(new Request("https://relay.example.com/photo/search?" + query), env, answer(body));

  const street = await ask("source=mapillary&lat=37.5&lng=127", { MAPILLARY_TOKEN: "m" }, { data: [{ id: "123", thumb_1024_url: "https://img.example.com/s.jpg", creator: { username: "walker" } }, { id: "9", thumb_1024_url: "http://x/y.jpg" }] });
  assert.deepEqual((await street.json()).documents, [{ image: "https://img.example.com/s.jpg", site: "Mapillary · walker", page: "https://www.mapillary.com/app/?pKey=123" }]);
  assert.match(seen[0].url, /bbox=126\.999400%2C37\.499400%2C127\.000600%2C37\.500600/);
  assert.equal(seen[0].headers.authorization, "OAuth m");
  assert.equal((await ask("source=mapillary&query=x", { MAPILLARY_TOKEN: "m" }, {})).status, 400, "street photos need a coordinate");

  const tour = await ask("source=tour&query=%EA%B6%81&lat=37.5&lng=127", { TAGO_SERVICE_KEY: "t" }, { response: { body: { items: { item: [
    { title: "가까운 곳", firstimage: "http://tong.example.com/a.jpg", mapx: "127.001", mapy: "37.501" },
    { title: "먼 곳", firstimage: "http://tong.example.com/b.jpg", mapx: "129.0", mapy: "35.1" },
  ] } } } });
  assert.deepEqual((await tour.json()).documents, [{ image: "https://tong.example.com/a.jpg", site: "한국관광공사" }]);
  assert.match(seen.at(-1).url, /serviceKey=t&/);

  const city = await ask("source=unsplash&query=Bangkok", { UNSPLASH_ACCESS_KEY: "u" }, { results: [{ urls: { small: "https://images.example.com/c.jpg" }, user: { name: "A Person" }, links: { html: "https://unsplash.example.com/p/1" } }] });
  assert.deepEqual((await city.json()).documents, [{ image: "https://images.example.com/c.jpg", site: "A Person · Unsplash", page: "https://unsplash.example.com/p/1" }]);
  assert.equal(seen.at(-1).headers.authorization, "Client-ID u");

  const stock = await ask("source=pexels&query=Bangkok", { PEXELS_API_KEY: "p" }, { photos: [{ src: { medium: "https://images.example.com/d.jpg" }, photographer: "B Person", url: "https://pexels.example.com/photo/2" }] });
  assert.deepEqual((await stock.json()).documents, [{ image: "https://images.example.com/d.jpg", site: "B Person · Pexels", page: "https://pexels.example.com/photo/2" }]);

  for (const source of ["mapillary", "tour", "unsplash", "pexels"]) assert.equal((await ask(`source=${source}&query=a&lat=1&lng=1`, {}, {})).status, 503, source + " is off without its key");
  assert.equal((await ask("source=google&query=a", {}, {})).status, 400);
});
