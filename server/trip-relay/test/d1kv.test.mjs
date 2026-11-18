// D1R1119A01: KV 호환 D1 어댑터(src/d1kv.js)와 서버 연결 시험.
import assert from "node:assert/strict";
import test from "node:test";
import { handle } from "../src/index.js";
import { TOMBSTONE, d1kv } from "../src/d1kv.js";
import { FakeD1 } from "./fake-d1.mjs";
import { MemoryKV, makeEnv } from "./fakes.mjs";

const T0 = Date.parse("2026-11-19T00:00:00Z");
function make({ withLegacy = true } = {}) {
  const clock = { now: T0 };
  const db = new FakeD1();
  const legacy = withLegacy ? new MemoryKV() : undefined;
  const kv = d1kv(db, legacy, { now: () => clock.now });
  return { clock, db, legacy, kv };
}
const names = async (kv, options) => (await kv.list(options)).keys.map((k) => k.name);
async function drain(kv, options) {
  const out = []; let cursor; let pages = 0;
  do {
    const p = await kv.list({ ...options, cursor });
    out.push(...p.keys.map((k) => k.name));
    cursor = p.list_complete ? undefined : p.cursor;
    pages++;
    assert.ok(pages < 50, "페이지가 끝나지 않음");
  } while (cursor);
  return { out, pages };
}

test("put·get: text와 json, expirationTtl·expiration은 ms로 저장된다", async () => {
  const { kv, db } = make({ withLegacy: false });
  await kv.put("a", JSON.stringify({ n: 1 }), { expirationTtl: 60 });
  await kv.put("b", "text", { expiration: Math.floor(T0 / 1000) + 120 });
  await kv.put("c", "forever");
  assert.deepEqual(await kv.get("a", { type: "json" }), { n: 1 });
  assert.deepEqual(await kv.get("a", "json"), { n: 1 });
  assert.equal(await kv.get("b"), "text");
  assert.equal(await kv.get("nope"), null);
  assert.deepEqual(db.rows().map((r) => [r.key, r.expires_at]), [["a", T0 + 60_000], ["b", T0 + 120_000], ["c", null]]);
  await kv.put("a", "again"); // 덮어쓰면 만료도 바뀐다
  assert.equal(db.rows()[0].expires_at, null);
});

test("TTL 만료: get은 null, list에서 빠지고, 행이 지워진다", async () => {
  const { kv, db, clock } = make({ withLegacy: false });
  await kv.put("x:1", "1", { expirationTtl: 10 });
  await kv.put("x:2", "2", { expirationTtl: 10 });
  await kv.put("x:3", "3");
  clock.now += 11_000;
  assert.equal(await kv.get("x:1"), null);
  assert.deepEqual(db.rows().map((r) => r.key), ["x:2", "x:3"], "get이 만료 행을 지운다");
  assert.deepEqual(await names(kv, { prefix: "x:" }), ["x:3"]);
  assert.deepEqual(db.rows().map((r) => r.key), ["x:3"], "list도 만료 행을 지운다");
});

test("Dual-Read 이관: 옛 KV에만 있는 키를 읽으면 D1으로 복사되고 다음엔 D1에서 읽힌다(남은 TTL 유지, 옛 KV 쓰기 0건)", async () => {
  const { kv, db, legacy, clock } = make();
  await legacy.put("plan:h", "sealed", { expiration: Math.floor(T0 / 1000) + 3600 });
  await legacy.put("tomb:h", "1");
  const writes = legacy.writes;
  assert.equal(await kv.get("plan:h"), "sealed");
  assert.equal(await kv.get("tomb:h"), "1");
  assert.deepEqual(db.rows().map((r) => [r.key, r.expires_at]), [["plan:h", T0 + 3_600_000], ["tomb:h", null]]);
  legacy.map.set("plan:h", "changed in old kv"); // 이제 D1이 정본: 옛 KV 변화는 보이지 않는다
  assert.equal(await kv.get("plan:h"), "sealed");
  clock.now += 3_601_000;
  assert.equal(await kv.get("plan:h"), null, "복사된 TTL대로 만료");
  assert.equal(legacy.writes, writes, "옛 KV 쓰기 0건");
});

test("옛 KV에서 이미 만료된 키는 복사하지 않는다", async () => {
  const { kv, db, legacy } = make();
  await legacy.put("old", "v", { expiration: Math.floor(T0 / 1000) - 5 });
  assert.equal(await kv.get("old"), null);
  assert.equal(db.rows().length, 0);
});

test("env.PLANS(옛 KV)가 없는 환경도 동작한다", async () => {
  const { kv } = make({ withLegacy: false });
  assert.equal(await kv.get("a"), null);
  await kv.put("a", "1");
  await kv.put("b", "2");
  assert.deepEqual(await names(kv), ["a", "b"]);
  await kv.delete("a");
  assert.equal(await kv.get("a"), null);
});

test("삭제는 옛 KV 키를 되살리지 않는다(표식), 옛 KV 쓰기 0건", async () => {
  const { kv, db, legacy, clock } = make();
  await legacy.put("k:perm", "v");
  await legacy.put("k:ttl", "v", { expiration: Math.floor(T0 / 1000) + 100 });
  const writes = legacy.writes;
  await kv.delete("k:perm");
  await kv.delete("k:ttl");
  await kv.delete("k:never"); // 옛 KV에도 없음: 표식 없이 끝
  assert.equal(await kv.get("k:perm"), null);
  assert.equal(await kv.get("k:ttl"), null);
  assert.deepEqual(await names(kv, { prefix: "k:" }), []);
  assert.deepEqual(db.rows().map((r) => [r.key, r.value === TOMBSTONE, r.expires_at]), [["k:perm", true, null], ["k:ttl", true, T0 + 100_000]]);
  await kv.put("k:perm", "new"); // 다시 쓰면 표식을 덮는다
  assert.equal(await kv.get("k:perm"), "new");
  clock.now += 101_000; // 옛 항목이 만료되면 표식도 정리된다
  assert.equal(await kv.get("k:ttl"), null);
  assert.deepEqual(db.rows().map((r) => r.key), ["k:perm"]);
  assert.equal(legacy.writes, writes, "옛 KV 쓰기 0건");
});

test("D1 값을 짧은 TTL로 덮은 뒤 만료돼도 옛 KV 값이 부활하지 않는다", async () => {
  const { kv, legacy, clock } = make();
  await legacy.put("p", "old", { expiration: Math.floor(T0 / 1000) + 1000 });
  await kv.put("p", "new", { expirationTtl: 10 });
  clock.now += 11_000;
  assert.equal(await kv.get("p"), null);
  assert.equal(await kv.get("p"), null);
});

test("list: prefix·limit·cursor·list_complete, D1과 옛 KV를 합치고 중복·삭제된 키를 걸러낸다", async () => {
  const { kv, legacy } = make();
  for (const n of ["a:1", "a:3", "a:5", "a:7", "b:1"]) await legacy.put(n, "old");
  for (const n of ["a:2", "a:3", "a:6", "c:1"]) await kv.put(n, "new"); // a:3은 양쪽
  await kv.delete("a:5"); // 옛 KV에만 있던 키를 지움
  const first = await kv.list({ prefix: "a:", limit: 2 });
  assert.deepEqual([first.keys.map((k) => k.name), first.list_complete, typeof first.cursor], [["a:1", "a:2"], false, "string"]);
  assert.deepEqual((await drain(kv, { prefix: "a:", limit: 2 })).out, ["a:1", "a:2", "a:3", "a:6", "a:7"]);
  assert.deepEqual((await drain(kv, { prefix: "a:", limit: 1 })).out, ["a:1", "a:2", "a:3", "a:6", "a:7"]);
  const whole = await kv.list({ prefix: "a:" });
  assert.deepEqual([whole.keys.length, whole.list_complete, whole.cursor], [5, true, undefined]);
  assert.deepEqual(await names(kv), ["a:1", "a:2", "a:3", "a:6", "a:7", "b:1", "c:1"]);
  const exact = await kv.list({ prefix: "a:", limit: 5 });
  assert.equal(exact.list_complete, true, "limit과 개수가 같아도 더 없으면 완료");
});

test("list: 표식·만료 행이 많아도 페이지가 끊기지 않고 끝까지 읽힌다, expiration은 초", async () => {
  const { kv, legacy, clock } = make();
  for (let i = 0; i < 6; i++) await legacy.put(`t:${i}`, "old");
  for (let i = 0; i < 6; i++) await kv.delete(`t:${i}`); // 표식 6개
  await kv.put("t:z", "live", { expiration: Math.floor(T0 / 1000) + 50 });
  const { out } = await drain(kv, { prefix: "t:", limit: 2 });
  assert.deepEqual(out, ["t:z"]);
  assert.deepEqual((await kv.list({ prefix: "t:", limit: 50 })).keys, [{ name: "t:z", expiration: Math.floor(T0 / 1000) + 50 }]);
  clock.now += 60_000;
  assert.deepEqual(await names(kv, { prefix: "t:" }), []);
});

test("KV 쓰기 0건: 서버 요청을 돌려도 옛 KV는 쓰이지 않는다(RELAY_DB 연결)", async () => {
  const { env } = makeEnv({ RELAY_DB: new FakeD1() });
  const writes = env.PLANS.writes;
  const unauth = await handle(new Request("https://relay.test/plan", { method: "GET" }), env);
  assert.equal(unauth.status, 401);
  const key = Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64url");
  const register = await handle(new Request("https://relay.test/register", { method: "POST", headers: { authorization: "Bearer " + key, "content-type": "application/json" }, body: "{}" }), env);
  assert.ok(register.status < 300, String(register.status));
  assert.equal(env.PLANS.writes, writes, "옛 KV 쓰기 0건");
  assert.ok(env.RELAY_DB.writes > 0, "쓰기는 D1으로 갔다");
  assert.ok(env.RELAY_DB.rows().some((r) => r.key.startsWith("reg:")));
});
