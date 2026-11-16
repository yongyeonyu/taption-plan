// SRL1116A01: 공통 규칙. 운영자가 서명해 내보낸 묶음을 앱이 받고, 동의한 기기가 거른 후보를 올린다.
import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import { readFileSync } from "node:fs";
import test from "node:test";
import { handle } from "../src/index.js";
import { SHARED_LIMITS, cleanCandidate, fingerprint, patternLiterals, personalText, sharedRuleProblem } from "../src/shared.js";
import { makeEnv } from "./fakes.mjs";

const fixtures = JSON.parse(readFileSync(new URL("./fixtures/shared-rules.json", import.meta.url), "utf8"));
const ORIGIN = "https://relay.example.com";
const ADMIN = "admin-token-0123456789abcdef0123456789";
const randomKey = () => Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64url");
const req = (path, method = "GET", body, key) => new Request(`${ORIGIN}${path}`, {
  method, headers: { ...(key ? { authorization: `Bearer ${key}` } : {}), "content-type": "application/json" }, body: body === undefined ? undefined : JSON.stringify(body),
});
const send = (env, ...args) => handle(req(...args), env);

function signer() {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const raw = Buffer.from(publicKey.export({ format: "jwk" }).x, "base64url").toString("base64");
  return { publicKey: raw, sign: (payload) => sign(null, Buffer.from(payload), privateKey).toString("base64") };
}
const bundle = (version, rules) => JSON.stringify({ format: "bokki-shared-rules", version, engine: 1, issuedAt: "2026-11-16", rules });
const cafe = { id: "s_cafe", type: "merchant_category", match: { contains: ["스타벅스"] }, result: { category: "cafe" } };
const card = { id: "s_card", type: "payment_text", match: { pattern: "(?<merchant>.+) (?<amount>[\\d,]+)원 승인", sample: "가게 12,000원 승인" }, result: { kind: "expense", name: "카드" } };

async function setup(extra = {}) {
  const keys = signer();
  const { env, clock } = makeEnv({ SHARED_RULES_ADMIN_TOKEN: ADMIN, SHARED_RULES_PUBLIC_KEY: keys.publicKey, ...extra });
  const master = randomKey(), search = randomKey();
  assert.equal((await send(env, "/register", "POST", {}, master)).status, 201);
  assert.equal((await send(env, "/register", "POST", { purpose: "search" }, search)).status, 201);
  const publish = (payload, signature = keys.sign(payload)) => send(env, "/shared/admin/publish", "POST", { payload, signature }, ADMIN);
  return { env, clock, keys, master, search, publish };
}
async function user(env) {
  const key = randomKey();
  assert.equal((await send(env, "/register", "POST", {}, key)).status, 201);
  return key;
}

test("shared filter: the fixtures the app's filter reads too", async () => {
  for (const text of fixtures.personal) assert.equal(personalText(text), true, text);
  for (const text of fixtures.notPersonal) assert.equal(personalText(text), false, text);
  for (const { pattern, personal } of fixtures.literals) assert.equal(personalText(patternLiterals(pattern)), personal, pattern);
  for (const item of fixtures.accept) assert.deepEqual(cleanCandidate(item.in), item.out, JSON.stringify(item.in));
  for (const { why, rule } of fixtures.refuse) assert.equal(cleanCandidate(rule), null, why);
  assert.equal(await fingerprint({ a: 1, b: [1, 2] }), await fingerprint({ b: [1, 2], a: 1 }), "key order does not change the fingerprint");
  assert.equal(sharedRuleProblem(cafe), null);
  assert.equal(sharedRuleProblem({ ...cafe, type: "own_account", match: { name: "비상금" }, result: {} }), "type_not_shared");
  assert.equal(sharedRuleProblem({ ...card, result: { kind: "expense", name: "홍길동님 카드" } }), "personal");
  assert.equal(sharedRuleProblem({ id: "s_switch", type: "source_switch", match: { app: "토스" }, result: { expense: true, income: false } }), null);
});

test("shared rules: nothing before a publish, a signed bundle reaches any registered app, 304 when unchanged", async () => {
  const { env, master, search, publish } = await setup();
  assert.equal((await send(env, "/shared/rules")).status, 401, "an unregistered caller gets nothing");
  assert.deepEqual(await (await send(env, "/shared/rules", "GET", undefined, search)).json(), { format: "bokki-shared-rules", version: 0, payload: null, signature: null });
  const payload = bundle(1, [cafe, card]);
  assert.deepEqual(await (await publish(payload)).json(), { ok: true, version: 1, rules: 2 });
  for (const key of [search, master]) {
    const got = await (await send(env, "/shared/rules?since=0", "GET", undefined, key)).json();
    assert.deepEqual([got.version, got.payload], [1, payload]);
  }
  assert.equal((await send(env, "/shared/rules?since=1", "GET", undefined, search)).status, 304);
});

test("shared rules: publishing needs the admin token, the signing key, a newer version and clean rules", async () => {
  const { env, keys, master, publish } = await setup();
  const payload = bundle(1, [cafe]);
  assert.equal((await send(env, "/shared/admin/publish", "POST", { payload, signature: keys.sign(payload) }, master)).status, 401, "a user's key is not the admin token");
  assert.equal((await send(env, "/shared/admin/publish", "POST", { payload, signature: keys.sign(payload) })).status, 401);
  assert.deepEqual(await (await publish(payload, signer().sign(payload))).json(), { error: "bad_signature" });
  assert.deepEqual(await (await publish(payload, keys.sign(payload + " "))).json(), { error: "bad_signature" });
  assert.equal((await publish(payload)).status, 201);
  assert.equal((await publish(payload)).status, 409, "the same version again");
  assert.equal((await publish(bundle(0, []))).status, 409);
  const personal = await (await publish(bundle(2, [{ ...card, match: { ...card.match, pattern: "체크\\(1234\\) (?<amount>[\\d,]+)원" } }]))).json();
  assert.deepEqual(personal, { error: "personal", id: "s_card" });
  assert.equal((await (await publish(bundle(2, [{ id: "s_x", type: "skip_word", match: { word: "광고" }, result: {} }]))).json()).error, "type_not_shared");
  assert.equal((await (await publish(bundle(2, [cafe, cafe]))).json()).error, "duplicate_id");
  assert.equal((await publish("{}")).status, 422);
  // 거두기: 그 규칙을 뺀 새 버전을 낸다.
  assert.equal((await publish(bundle(2, []))).status, 201);
  assert.deepEqual(JSON.parse((await (await send(env, "/shared/admin/bundle", "GET", undefined, ADMIN)).json()).payload).rules, []);
});

test("shared rules: the admin routes stay closed until the token and the public key are set", async () => {
  const closed = makeEnv().env;
  assert.equal((await send(closed, "/shared/admin/candidates", "GET", undefined, ADMIN)).status, 503);
  const short = makeEnv({ SHARED_RULES_ADMIN_TOKEN: "short", SHARED_RULES_PUBLIC_KEY: signer().publicKey }).env;
  assert.equal((await send(short, "/shared/admin/candidates", "GET", undefined, "short")).status, 503);
  const { env } = await setup();
  assert.equal((await send(env, "/shared/admin/nothing", "GET", undefined, ADMIN)).status, 404);
});

test("candidates: filtered again on the server, counted once per device, shown only from two devices, no trace of who", async () => {
  const { env, master, search } = await setup();
  const rules = [fixtures.accept[0].in, fixtures.accept[2].in, fixtures.refuse[3].rule];
  assert.equal((await send(env, "/shared/candidates", "POST", { rules }, search)).status, 403, "a search key cannot upload");
  assert.deepEqual(await (await send(env, "/shared/candidates", "POST", { rules }, master)).json(), { ok: true, accepted: 2, refused: 1 });
  assert.deepEqual(await (await send(env, "/shared/candidates", "POST", { rules }, master)).json(), { ok: true, accepted: 0, refused: 1 }, "the same device again adds nothing");
  let listed = await (await send(env, "/shared/admin/candidates", "GET", undefined, ADMIN)).json();
  assert.deepEqual([listed.min, listed.total, listed.candidates], [2, 2, []], "one device is not enough");
  const second = await user(env);
  assert.equal((await (await send(env, "/shared/candidates", "POST", { rules: [fixtures.accept[2].in] }, second)).json()).accepted, 1);
  listed = await (await send(env, "/shared/admin/candidates", "GET", undefined, ADMIN)).json();
  assert.deepEqual(listed.candidates.map((c) => [c.type, c.match, c.result, c.count]), [["merchant_category", { contains: ["스타벅스"] }, { category: "cafe" }, 2]]);
  assert.equal((await (await send(env, "/shared/admin/candidates?min=1", "GET", undefined, ADMIN)).json()).candidates.length, 2);
  const stored = JSON.stringify([...env.USER_STATE.instances.get("shared:rules").storage.map.entries()]);
  for (const secret of [master, second, "동네가게", "내 카드", "커피"]) assert.equal(stored.includes(secret), false, `the candidate store has no ${secret}`);
  assert.equal(listed.candidates[0].firstAt % 86_400_000, 0, "only the day is kept");
  const { fp } = listed.candidates[0];
  assert.deepEqual(await (await send(env, `/shared/admin/candidates?fps=${fp}`, "DELETE", undefined, ADMIN)).json(), { ok: true, removed: 1 });
  assert.equal((await send(env, "/shared/candidates", "POST", { rules: [] }, master)).status, 422);
});

test("candidates: a daily cap per device and old candidates expire", async () => {
  const { env, clock, master } = await setup();
  const word = (n) => ({ type: "merchant_category", match: { contains: [`가게${String.fromCharCode(0xac00 + n)}`] }, result: { category: "food" } });
  for (let start = 0; start < SHARED_LIMITS.perDay; start += 20) {
    assert.equal((await send(env, "/shared/candidates", "POST", { rules: Array.from({ length: 20 }, (_, i) => word(start + i)) }, master)).status, 200);
    clock.now += 61_000; // IP마다 1분에 POST 20번
  }
  assert.equal((await send(env, "/shared/candidates", "POST", { rules: [word(999)] }, master)).status, 429);
  clock.now += (SHARED_LIMITS.candidateDays + 1) * 86_400_000;
  assert.equal((await (await send(env, "/shared/admin/candidates?min=1", "GET", undefined, ADMIN)).json()).total, 0);
});
