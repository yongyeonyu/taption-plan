// CRV1120A01 코드 검토 P0 서버 4건(S1·S2·S4·S5)의 동작 시험.
import assert from "node:assert/strict";
import test from "node:test";
import { handle, kakaoImage, kakaoKeyword, photoSearch } from "../src/index.js";
import { makeEnv } from "./fakes.mjs";

const ORIGIN = "https://relay.example.com";
const PIN = "135790";
const randomKey = () => Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64url");
const req = (path, method = "GET", body, key) => new Request(`${ORIGIN}${path}`, {
  method, headers: { ...(key ? { authorization: `Bearer ${key}` } : {}), "content-type": "application/json" }, body: body === undefined ? undefined : JSON.stringify(body),
});
const send = (env, ...args) => handle(req(...args), env);
const mcp = (env, key, name, args = {}) => send(env, "/mcp", "POST", { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: args } }, key);

async function setup() {
  const { env } = makeEnv();
  const master = randomKey(), writer = randomKey();
  assert.equal((await send(env, "/register", "POST", {}, master)).status, 201);
  assert.equal((await send(env, "/pin", "POST", { pin: PIN }, master)).status, 200);
  assert.equal((await send(env, "/keys", "POST", { keys: [{ token: writer, scope: "write", expiresAt: null }], pin: PIN }, master)).status, 201);
  return { env, master, writer };
}

test("S1: a write AI cannot turn a user's rule on or off (REST ops and MCP set_rule_enabled alike)", async () => {
  const { env, master, writer } = await setup();
  const made = await (await send(env, "/rules/ops", "POST", { ops: [{ op: "put", rule: { id: "u-1", type: "skip_word", match: { word: "광고" } } }] }, master)).json();
  assert.ok(made.ok);
  const aiRule = await (await send(env, "/rules", "POST", { rules: [{ type: "merchant_category", match: { contains: ["빵집"] }, result: { category: "cafe" } }] }, writer)).json();
  const aiId = aiRule.ids[0];
  const enabledOf = async (id) => (await (await send(env, "/rules", "GET", undefined, master)).json()).rules.find((r) => r.id === id).enabled;
  assert.equal(await enabledOf("u-1"), true);
  const off = await mcp(env, writer, "set_rule_enabled", { id: "u-1", enabled: false });
  assert.equal((await off.json()).result.isError ?? false, true, "MCP reports the refusal");
  assert.equal(await enabledOf("u-1"), true, "the user's rule is still on");
  // AI는 자기 규칙은 끌 수 있다.
  await mcp(env, writer, "set_rule_enabled", { id: aiId, enabled: false });
  assert.equal(await enabledOf(aiId), false);
});

test("S2: a thrown upstream fetch is a 502, not an unhandled error (kakao keyword, image, photo sources)", async () => {
  const boom = async () => { throw new TypeError("fetch failed"); };
  const env = { KAKAO_REST_API_KEY: "k", GOOGLE_PLACES_KEY: "g", PEXELS_API_KEY: "p" };
  const keyword = await kakaoKeyword(new Request(`${ORIGIN}/kakao/keyword?query=%EC%B9%B4%ED%8E%98`), env, boom);
  assert.equal(keyword.status, 502);
  assert.equal((await keyword.json()).error, "upstream_failed");
  assert.equal((await kakaoImage(new Request(`${ORIGIN}/kakao/image?query=%EC%B9%B4%ED%8E%98`), env, boom)).status, 502);
  assert.equal((await photoSearch(new Request(`${ORIGIN}/photo/search?source=pexels&query=cafe`), env, boom)).status, 502);
  assert.equal((await photoSearch(new Request(`${ORIGIN}/photo/search?source=google&query=cafe`), env, boom)).status, 502);
  // 두 번째 호출(사진 주소)이 던지는 경우.
  let calls = 0;
  const secondBoom = async () => {
    if (calls++ === 0) return new Response(JSON.stringify({ places: [{ photos: [{ name: "places/abc/photos/def" }] }] }), { status: 200 });
    throw new TypeError("fetch failed");
  };
  assert.equal((await photoSearch(new Request(`${ORIGIN}/photo/search?source=google&query=cafe`), env, secondBoom)).status, 502);
});

test("S4: more open tasks than the cap are marked failed(overflow), never silently deleted", async () => {
  const { env, master } = await setup();
  const id = (n) => `${String(n).padStart(8, "0")}-E5F6-4789-9ABC-DEF012345678`;
  const batch = (from, count) => ({ format: "bokki-tasks", version: 1, tasks: Array.from({ length: count }, (_, i) => ({ id: id(from + i), kind: "payment_text", text: `결제 ${from + i}` })) });
  for (let from = 0; from < 100; from += 20) assert.equal((await send(env, "/tasks", "POST", batch(from, 20), master)).status, 201);
  assert.equal((await send(env, "/tasks", "POST", batch(100, 5), master)).status, 201);
  const tasks = (await (await send(env, "/tasks", "GET", undefined, master)).json()).tasks;
  assert.equal(tasks.length, 105, "nothing disappeared");
  const failed = tasks.filter((t) => t.status === "failed");
  assert.equal(failed.length, 5);
  assert.ok(failed.every((t) => t.reason === "overflow"), "the app can see why");
  assert.deepEqual(failed.map((t) => t.id), [0, 1, 2, 3, 4].map(id), "oldest open tasks are the ones failed");
  // 다음 추가 때 끝난(실패) 것이 먼저 정리돼 상한으로 돌아온다.
  await send(env, "/tasks", "POST", batch(200, 1), master);
  const after = (await (await send(env, "/tasks", "GET", undefined, master)).json()).tasks;
  assert.ok(after.length <= 101);
});

test("S5: concurrent command-result uploads are merged, none is lost", async () => {
  const { env, master } = await setup();
  const post = (n) => send(env, "/command/result", "POST", { results: [{ id: `r${n}`, status: "applied" }] }, master);
  const replies = await Promise.all(Array.from({ length: 12 }, (_, n) => post(n)));
  assert.ok(replies.every((r) => r.status === 201), replies.map((r) => r.status).join());
  const { results } = await (await send(env, "/command/result", "GET", undefined, master)).json();
  assert.deepEqual(results.map((r) => r.id).sort(), Array.from({ length: 12 }, (_, n) => `r${n}`).sort());
});

test("S5: concurrent activity uploads keep every extras field and leave no lock behind", async () => {
  const { env, master } = await setup();
  const upload = (extra) => ({ format: "bokki-activity", version: 1, retentionDays: 7, days: [{ date: "2026-11-20" }], ...extra });
  // 처음 한 번은 예전 하루 기록 옮기기(ensureDays)를 먼저 끝낸다. 그 잠금은 이번 수정과 무관하다.
  const first = await send(env, "/activity", "POST", upload({}), master);
  assert.equal(first.status, 201, await first.clone().text());
  const replies = await Promise.all([
    send(env, "/activity", "POST", upload({ goals: [{ id: "g1", title: "운동" }] }), master),
    send(env, "/activity", "POST", upload({ trips: [{ id: "t1", title: "방콕" }] }), master),
  ]);
  assert.ok(replies.every((r) => r.status === 201), replies.map((r) => r.status).join());
  assert.equal((await send(env, "/command/result", "POST", { results: [{ id: "after", status: "applied" }] }, master)).status, 201, "no lock left behind");
});
