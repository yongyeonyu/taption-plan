// MER1121A01: 아이콘을 정하지 못한 가맹점 이름 모으기. 이름·건수만 받고, 사람 이름·카드·전화 꼴은 거절하며, 운영자는 이름별 합계만 읽는다. 값은 가짜다.
import assert from "node:assert/strict";
import test from "node:test";
import { MERCHANT_LIMITS, cleanName } from "../src/merchants.js";
import { handle } from "../src/index.js";
import { FakeD1 } from "./fake-d1.mjs";
import { makeEnv } from "./fakes.mjs";

const randomKey = () => Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64url");
const owner = randomKey();
const other = randomKey();
const ADMIN = "a".repeat(40);
const ORIGIN = "https://relay.example.com";

async function fresh() {
  const { env, clock } = makeEnv({ RELAY_DB: new FakeD1(), CLASSIFIER_ADMIN_TOKEN: ADMIN });
  for (const key of [owner, other]) {
    const response = await handle(new Request(`${ORIGIN}/register`, { method: "POST", headers: { authorization: `Bearer ${key}` } }), { ...env, POST_LIMIT: undefined });
    assert.equal(response.status, 201);
  }
  return { env, clock };
}
const body = (items) => ({ format: "bokki-merchants", version: 1, items });
const post = (payload, key = owner) => new Request(`${ORIGIN}/merchants/unknown`, {
  method: "POST", headers: { authorization: `Bearer ${key}`, "content-type": "application/json" }, body: typeof payload === "string" ? payload : JSON.stringify(payload),
});
const admin = (query = "", token = ADMIN) => new Request(`${ORIGIN}/merchants/admin${query}`, { headers: token ? { authorization: `Bearer ${token}` } : {} });
const rows = (env) => env.RELAY_DB.db.prepare("SELECT * FROM unknown_merchants").all();

test("cleanName keeps ordinary merchant names and rejects numbers, masked names, accounts and links", () => {
  assert.equal(cleanName("  부천아이폰수리   수리마블 "), "부천아이폰수리 수리마블");
  assert.equal(cleanName("Blue Bottle Seongsu"), "Blue Bottle Seongsu");
  for (const bad of ["홍*동", "a@b.com", "https://x.example", "카드 1234567890", "010-1234-5678", "x", "a".repeat(41), "가게\u0000이름", 7, null, "서울/강남"]) {
    assert.equal(cleanName(bad), null, String(bad));
  }
});

test("an upload stores only names and counts, merges repeats, and rejects bad names per item", async () => {
  const { env } = await fresh();
  const response = await handle(post(body([{ name: "수리마블", count: 2 }, { name: "수리마블", count: 1 }, { name: "홍*동", count: 1 }, { name: "카페 하루", count: 0 }, { name: "다이소 부천점", count: 3 }])), env);
  assert.equal(response.status, 201);
  assert.deepEqual(await response.json(), { ok: true, accepted: 2, rejected: 2 });
  const stored = rows(env);
  assert.deepEqual(stored.map((row) => [row.name, row.hits]).sort(), [["다이소 부천점", 3], ["수리마블", 3]]);
  assert.deepEqual(Object.keys(stored[0]).sort(), ["first_at", "hits", "last_at", "name", "owner"], "이름·건수·해시·시각 밖의 열이 없다");
  assert.equal(JSON.stringify(stored).includes(owner), false, "주인 키 원문은 저장하지 않는다");
});

test("repeated uploads add up, and the admin sees totals per name with the number of users", async () => {
  const { env } = await fresh();
  await handle(post(body([{ name: "수리마블", count: 2 }, { name: "다이소 부천점", count: 1 }])), env);
  await handle(post(body([{ name: "수리마블", count: 1 }])), env);
  await handle(post(body([{ name: "수리마블", count: 4 }]), other), env);
  const response = await handle(admin(), env);
  assert.equal(response.status, 200);
  const result = await response.json();
  assert.deepEqual(result.totals, { names: 2, users: 2, hits: 8 });
  assert.deepEqual(result.items.map((item) => [item.name, item.hits, item.users]), [["수리마블", 7, 2], ["다이소 부천점", 1, 1]]);
  assert.equal(JSON.stringify(result).includes("owner"), false);
  const many = await (await handle(admin("?min=2"), env)).json();
  assert.deepEqual(many.items.map((item) => item.name), ["수리마블"], "보낸 사람 수가 많은 것만");
});

test("the admin route needs the admin token and a valid query", async () => {
  const { env } = await fresh();
  assert.equal((await handle(admin("", null), env)).status, 401);
  assert.equal((await handle(admin("", "b".repeat(40)), env)).status, 401);
  assert.equal((await handle(admin("?limit=0"), env)).status, 422);
  assert.equal((await handle(admin("?limit=201"), env)).status, 422);
  const none = makeEnv({ RELAY_DB: new FakeD1() }).env;
  assert.equal((await handle(admin(), none)).status, 503, "토큰이 없으면 열리지 않는다");
});

test("only a registered owner key can upload; shape, size and daily limits are enforced", async () => {
  const { env } = await fresh();
  assert.equal((await handle(new Request(`${ORIGIN}/merchants/unknown`, { method: "POST", body: "{}" }), env)).status, 401);
  assert.equal((await handle(post("{nope"), env)).status, 400);
  assert.equal((await handle(post({ format: "other", version: 1, items: [] }), env)).status, 422);
  assert.equal((await handle(post(body([])), env)).status, 422);
  const tooMany = body(Array.from({ length: MERCHANT_LIMITS.maxItems + 1 }, (_, i) => ({ name: `가게 ${String.fromCharCode(0xac00 + i)}`, count: 1 })));
  assert.equal((await handle(post(tooMany), env)).status, 422);
  const names = (from, count) => body(Array.from({ length: count }, (_, i) => ({ name: `가게 ${String.fromCharCode(0xac00 + from + i)}${String.fromCharCode(0xb000 + from + i)}`, count: 1 })));
  assert.equal((await handle(post(names(0, 100)), env)).status, 201);
  assert.equal((await handle(post(names(100, 100)), env)).status, 201);
  assert.equal((await handle(post(names(200, 100)), env)).status, 201);
  const capped = await handle(post(names(300, 1)), env);
  assert.equal(capped.status, 429);
  assert.equal((await capped.json()).error, "merchant_daily_limit");
});

test("DELETE removes only the caller's names", async () => {
  const { env } = await fresh();
  await handle(post(body([{ name: "수리마블", count: 1 }])), env);
  await handle(post(body([{ name: "수리마블", count: 1 }, { name: "다이소 부천점", count: 2 }]), other), env);
  const response = await handle(new Request(`${ORIGIN}/merchants/unknown`, { method: "DELETE", headers: { authorization: `Bearer ${owner}` } }), env);
  assert.deepEqual(await response.json(), { ok: true, deleted: 1 });
  assert.equal(rows(env).length, 2);
});

test("names older than a year are dropped on the next upload", async () => {
  const { env, clock } = await fresh();
  await handle(post(body([{ name: "옛 가게", count: 1 }])), env);
  clock.now += MERCHANT_LIMITS.retentionMs + 1000;
  await handle(post(body([{ name: "새 가게", count: 1 }])), env);
  assert.deepEqual(rows(env).map((row) => row.name), ["새 가게"]);
});
