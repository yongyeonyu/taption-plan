// PSH1114A06: 푸시(APNs). 시험용 키는 여기서 만들어 쓰고 버린다. 진짜 키·토큰은 쓰지 않는다.
import assert from "node:assert/strict";
import test from "node:test";
import { handle } from "../src/index.js";
import { providerToken, sendPush } from "../src/apns.js";
import { LIMITS } from "../src/state.js";
import { makeEnv } from "./fakes.mjs";

const ORIGIN = "https://relay.example.com";
const PIN = "135790";
const DEVICE = "ab".repeat(32);
const TASK = "A1B2C3D4-E5F6-4789-9ABC-DEF012345678";
const randomKey = () => Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64url");
const req = (path, method = "GET", body, key) => new Request(`${ORIGIN}${path}`, {
  method,
  headers: { ...(key ? { authorization: `Bearer ${key}` } : {}), "content-type": "application/json" },
  body: body === undefined ? undefined : JSON.stringify(body),
});
const send = (env, ...args) => handle(req(...args), env);
const command = (id, action, extra = {}) => ({ format: "bokki-command", version: 1, id, action, ...extra });
const theme = (id) => command(id, "setTheme", { theme: "ink" });
const question = (id) => command(id, "askUser", { question: "어느 쪽으로 할까요?", options: ["가", "나"] });
const rule = (id) => ({ id, type: "skip_word", match: { word: "광고" + id.slice(-1) }, result: {} });
const decode = (part) => JSON.parse(Buffer.from(part, "base64url").toString("utf8"));

async function throwawayKey() {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const der = Buffer.from(await crypto.subtle.exportKey("pkcs8", pair.privateKey)).toString("base64");
  return { pem: `-----BEGIN PRIVATE KEY-----\n${der.match(/.{1,64}/g).join("\n")}\n-----END PRIVATE KEY-----\n`, publicKey: pair.publicKey };
}

// 가짜 APNs. 받은 요청을 적어 둔다.
function fakeApns(reply = () => new Response(null, { status: 200 })) {
  const sent = [];
  const fetcher = async (url, init) => {
    const call = { url: String(url), headers: init.headers, payload: JSON.parse(init.body) };
    sent.push(call);
    return reply(call);
  };
  return { sent, fetcher };
}

async function setup({ secrets = true, reply, token = true } = {}) {
  const apns = fakeApns(reply);
  const key = await throwawayKey();
  const { env, clock } = makeEnv({ FETCH: apns.fetcher, ...(secrets ? { APNS_KEY_P8: key.pem, APNS_KEY_ID: "TESTKEY001", APNS_TEAM_ID: "TESTTEAM01" } : {}) });
  const master = randomKey(), ai = randomKey();
  assert.equal((await send(env, "/register", "POST", {}, master)).status, 201);
  assert.equal((await send(env, "/pin", "POST", { pin: PIN }, master)).status, 200);
  assert.equal((await send(env, "/keys", "POST", { keys: [{ token: ai, scope: "write", expiresAt: null }], pin: PIN }, master)).status, 201);
  if (token) assert.equal((await send(env, "/push/token", "POST", { token: DEVICE, env: "production", build: "400" }, master)).status, 200);
  return { env, clock, master, ai, sent: apns.sent, key };
}

async function storedPush(env) {
  for (const instance of env.USER_STATE.instances.values()) {
    const push = await instance.storage.get("push");
    if (push) return push;
  }
  return null;
}

test("push: provider token is an ES256 JWT with kid, iss and iat, and is reused for 45 minutes", async () => {
  const key = await throwawayKey();
  const env = { APNS_KEY_P8: key.pem, APNS_KEY_ID: "TESTKEY002", APNS_TEAM_ID: "TESTTEAM02" };
  const now = Date.parse("2026-11-14T00:00:00Z");
  const jwt = await providerToken(env, now);
  const parts = jwt.split(".");
  assert.equal(parts.length, 3);
  assert.deepEqual(decode(parts[0]), { alg: "ES256", kid: "TESTKEY002" });
  assert.deepEqual(decode(parts[1]), { iss: "TESTTEAM02", iat: now / 1000 });
  const signature = Buffer.from(parts[2], "base64url");
  assert.equal(signature.length, 64, "raw r||s");
  assert.ok(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key.publicKey, signature, new TextEncoder().encode(parts[0] + "." + parts[1])));
  assert.equal(await providerToken(env, now + 44 * 60_000), jwt, "cached");
  assert.notEqual(await providerToken(env, now + 46 * 60_000), jwt, "renewed");
});

test("push: sendPush sets host, topic, type, priority and collapse id; missing secrets skip", async () => {
  const key = await throwawayKey();
  const env = { APNS_KEY_P8: key.pem, APNS_KEY_ID: "TESTKEY003", APNS_TEAM_ID: "TESTTEAM03" };
  const apns = fakeApns();
  const result = await sendPush(env, apns.fetcher, { token: DEVICE, sandbox: true, payload: { aps: { "content-available": 1 }, k: "cmd" }, pushType: "background", collapseId: "cmd" });
  assert.deepEqual(result, { ok: true, status: 200, gone: false });
  assert.equal(apns.sent[0].url, `https://api.sandbox.push.apple.com/3/device/${DEVICE}`);
  const headers = apns.sent[0].headers;
  assert.match(headers.authorization, /^bearer [\w-]+\.[\w-]+\.[\w-]+$/);
  assert.deepEqual([headers["apns-topic"], headers["apns-push-type"], headers["apns-priority"], headers["apns-collapse-id"]], ["com.taption.plan", "background", "5", "cmd"]);
  await sendPush({ ...env, APNS_TOPIC: "com.example.other" }, apns.fetcher, { token: DEVICE, payload: {}, pushType: "alert" });
  assert.equal(apns.sent[1].url, `https://api.push.apple.com/3/device/${DEVICE}`);
  assert.deepEqual([apns.sent[1].headers["apns-topic"], apns.sent[1].headers["apns-priority"], apns.sent[1].headers["apns-collapse-id"]], ["com.example.other", "10", undefined]);
  for (const missing of ["APNS_KEY_P8", "APNS_KEY_ID", "APNS_TEAM_ID"]) {
    assert.deepEqual(await sendPush({ ...env, [missing]: undefined }, apns.fetcher, { token: DEVICE, payload: {} }), { skipped: true });
  }
  assert.equal(apns.sent.length, 2);
  const gone = fakeApns(() => new Response(JSON.stringify({ reason: "BadDeviceToken" }), { status: 400 }));
  assert.equal((await sendPush(env, gone.fetcher, { token: DEVICE, payload: {} })).gone, true);
});

test("push: token route takes only the app's key and a well-formed token; it is stored sealed", async () => {
  const { env, master, ai } = await setup({ token: false });
  assert.equal((await send(env, "/push/token", "POST", { token: DEVICE, env: "production" }, ai)).status, 403);
  assert.equal((await send(env, "/push/token", "DELETE", undefined, ai)).status, 403);
  assert.equal((await send(env, "/push/token", "POST", { token: DEVICE, env: "production" })).status, 401);
  for (const bad of [{ token: "ab".repeat(31), env: "production" }, { token: "zz".repeat(32), env: "production" }, { token: "a".repeat(201), env: "sandbox" },
    { token: DEVICE, env: "prod" }, { token: DEVICE }, { token: DEVICE, env: "sandbox", build: "x1" }, {}]) {
    assert.equal((await send(env, "/push/token", "POST", bad, master)).status, 422, JSON.stringify(bad));
  }
  assert.equal(await storedPush(env), null);
  const saved = await send(env, "/push/token", "POST", { token: DEVICE.toUpperCase(), env: "sandbox", build: "401" }, master);
  assert.deepEqual([saved.status, await saved.json()], [200, { ok: true, push: true }]);
  const stored = await storedPush(env);
  assert.equal(stored.sandbox, true);
  assert.ok(!JSON.stringify(stored).toLowerCase().includes(DEVICE), "sealed");
  assert.equal((await send(env, "/push/token", "DELETE", undefined, master)).status, 204);
  assert.equal(await storedPush(env), null);
});

test("push: a queued command wakes the app silently, at most once per two minutes", async () => {
  const { env, clock, ai, sent } = await setup();
  assert.equal((await send(env, "/command", "POST", theme("c1"), ai)).status, 201);
  assert.equal(sent.length, 1);
  assert.equal(sent[0].url, `https://api.push.apple.com/3/device/${DEVICE}`);
  assert.deepEqual(sent[0].payload, { aps: { "content-available": 1 }, k: "cmd" });
  assert.deepEqual([sent[0].headers["apns-push-type"], sent[0].headers["apns-priority"], sent[0].headers["apns-collapse-id"]], ["background", "5", "cmd"]);
  clock.now += 119_000;
  assert.equal((await send(env, "/command", "POST", theme("c2"), ai)).status, 201);
  assert.equal(sent.length, 1, "too soon");
  clock.now += 2_000;
  assert.equal((await send(env, "/command", "POST", theme("c3"), ai)).status, 201);
  assert.equal(sent.length, 2);
  assert.equal((await send(env, "/command", "POST", { nope: true }, ai)).status, 422);
  assert.equal(sent.length, 2, "a refused command does not push");
});

test("push: questions and approvals send a visible generic alert with no user text", async () => {
  const { env, ai, sent } = await setup();
  assert.equal((await send(env, "/command", "POST", theme("c1"), ai)).status, 201);
  assert.equal((await send(env, "/command", "POST", question("ask-1"), ai)).status, 201);
  const mcp = await send(env, "/mcp", "POST", { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "ask_user", arguments: { id: "ask-2", question: "저녁은 어디서?", options: ["집", "밖"] } } }, ai);
  assert.equal(mcp.status, 200);
  assert.equal(sent.length, 3, "questions are not held back by the silent gap");
  for (const [call, id] of [[sent[1], "ask-1"], [sent[2], "ask-2"]]) {
    assert.deepEqual(call.payload, { aps: { alert: { "loc-key": "PUSH_AI_QUESTION" }, sound: "default", "content-available": 1 }, k: "q" });
    assert.deepEqual([call.headers["apns-push-type"], call.headers["apns-priority"], call.headers["apns-collapse-id"]], ["alert", "10", "q-" + id]);
  }
  assert.ok(!JSON.stringify(sent).includes("저녁") && !JSON.stringify(sent).includes("어느"));
});

test("push: a finished task wakes the app once a minute; needsUser shows an alert", async () => {
  const { env, clock, master, ai, sent } = await setup();
  const ids = [0, 1, 2, 3].map((n) => TASK.slice(0, -1) + n);
  assert.equal((await send(env, "/tasks", "POST", { format: "bokki-tasks", version: 1, tasks: ids.map((id) => ({ id, kind: "payment_text", text: "문자 " + id })) }, master)).status, 201);
  assert.equal((await send(env, "/tasks/claim", "POST", undefined, ai)).status, 200);
  assert.equal(sent.length, 0, "uploading and claiming do not push");
  assert.equal((await send(env, "/tasks/result", "POST", { id: ids[0], status: "done", result: "넣음" }, ai)).status, 200);
  assert.deepEqual([sent.length, sent[0].payload, sent[0].headers["apns-collapse-id"]], [1, { aps: { "content-available": 1 }, k: "task" }, "task"]);
  clock.now += 30_000;
  assert.equal((await send(env, "/tasks/result", "POST", { id: ids[1], status: "done", result: "넣음" }, ai)).status, 200);
  assert.equal(sent.length, 1, "coalesced");
  assert.equal((await send(env, "/tasks/result", "POST", { id: ids[2], status: "done", result: "확인 필요", outcome: { needsUser: true } }, ai)).status, 200);
  assert.equal(sent.length, 2);
  assert.deepEqual(sent[1].payload, { aps: { alert: { "loc-key": "PUSH_AI_NEEDS_YOU" }, sound: "default", "content-available": 1 }, k: "task" });
  assert.equal(sent[1].headers["apns-push-type"], "alert");
  clock.now += 31_000;
  assert.equal((await send(env, "/tasks/result", "POST", { id: ids[3], status: "failed", reason: "모름" }, ai)).status, 200);
  assert.equal(sent.length, 3);
  assert.equal((await send(env, "/tasks/result", "POST", { id: "nope", status: "done" }, ai)).status, 404);
  assert.equal(sent.length, 3);
});

test("push: rules changed by an AI wake the app, at most once per two minutes", async () => {
  const { env, clock, ai, sent } = await setup();
  assert.equal((await send(env, "/rules", "POST", { rules: [rule("r_1")] }, ai)).status, 201);
  assert.deepEqual([sent.length, sent[0].payload, sent[0].headers["apns-collapse-id"], sent[0].headers["apns-push-type"]], [1, { aps: { "content-available": 1 }, k: "rules" }, "rules", "background"]);
  assert.equal((await send(env, "/rules", "POST", { rules: [rule("r_2")] }, ai)).status, 201);
  assert.equal(sent.length, 1);
  clock.now += 121_000;
  assert.equal((await send(env, "/rules?ids=r_1", "DELETE", undefined, ai)).status, 200);
  assert.equal(sent.length, 2);
  clock.now += 121_000;
  assert.equal((await send(env, "/rules?ids=r_gone", "DELETE", undefined, ai)).status, 200);
  assert.equal(sent.length, 2, "nothing changed");
});

test("push: daily caps hold (silent 60, visible 20)", async () => {
  const { env, clock, ai, sent } = await setup();
  for (let i = 0; i < LIMITS.pushVisiblePerDay + 2; i++) assert.equal((await send(env, "/command", "POST", question("ask-" + i), ai)).status, 201);
  assert.equal(sent.length, LIMITS.pushVisiblePerDay);
  sent.length = 0;
  for (let i = 0; i < LIMITS.pushSilentPerDay + 3; i++) {
    clock.now += 121_000;
    assert.equal((await send(env, "/command", "POST", theme("c-" + i), ai)).status, 201);
  }
  assert.equal(sent.length, LIMITS.pushSilentPerDay);
  clock.now += 86_400_000;
  assert.equal((await send(env, "/command", "POST", theme("next-day"), ai)).status, 201);
  assert.equal(sent.length, LIMITS.pushSilentPerDay + 1);
});

test("push: the app's own requests never push", async () => {
  const { env, master, sent } = await setup();
  assert.equal((await send(env, "/rules", "POST", { rules: [rule("r_1")] }, master)).status, 201);
  assert.equal((await send(env, "/rules/ops", "POST", { ops: [{ op: "disable", id: "r_1" }] }, master)).status, 200);
  assert.equal((await send(env, "/rules?ids=r_1", "DELETE", undefined, master)).status, 200);
  assert.equal((await send(env, "/command", "GET", undefined, master)).status, 204);
  assert.equal(sent.length, 0);
});

test("push: without secrets or without a token nothing is sent and everything else works", async () => {
  const bare = await setup({ secrets: false });
  assert.deepEqual(await (await send(bare.env, "/push/token", "POST", { token: DEVICE, env: "production" }, bare.master)).json(), { ok: true, push: false });
  assert.equal((await send(bare.env, "/command", "POST", theme("c1"), bare.ai)).status, 201);
  assert.equal((await send(bare.env, "/command", "POST", question("q1"), bare.ai)).status, 201);
  assert.equal((await send(bare.env, "/rules", "POST", { rules: [rule("r_1")] }, bare.ai)).status, 201);
  assert.equal((await (await send(bare.env, "/command", "GET", undefined, bare.master)).json()).commands.length, 2);
  assert.equal(bare.sent.length, 0);
  const tokenless = await setup({ token: false });
  assert.equal((await send(tokenless.env, "/command", "POST", theme("c1"), tokenless.ai)).status, 201);
  assert.equal(tokenless.sent.length, 0);
});

test("push: a 410 reply clears the token; a failing APNs never breaks the AI's request", async () => {
  const gone = await setup({ reply: () => new Response(JSON.stringify({ reason: "Unregistered" }), { status: 410 }) });
  assert.equal((await send(gone.env, "/command", "POST", theme("c1"), gone.ai)).status, 201);
  assert.equal(gone.sent.length, 1);
  assert.equal(await storedPush(gone.env), null);
  assert.equal((await send(gone.env, "/command", "POST", question("q1"), gone.ai)).status, 201);
  assert.equal(gone.sent.length, 1, "no token, no push");
  const down = await setup({ reply: () => { throw new Error("network"); } });
  assert.equal((await send(down.env, "/command", "POST", theme("c1"), down.ai)).status, 201);
  assert.notEqual(await storedPush(down.env), null);
  const busy = await setup({ reply: () => new Response(JSON.stringify({ reason: "TooManyRequests" }), { status: 429 }) });
  assert.equal((await send(busy.env, "/command", "POST", theme("c1"), busy.ai)).status, 201);
  assert.notEqual(await storedPush(busy.env), null, "other errors keep the token");
});

test("push: disconnecting every AI and a PIN reset drop the token", async () => {
  const one = await setup();
  assert.equal((await send(one.env, "/keys", "DELETE", undefined, one.master)).status, 204);
  assert.equal(await storedPush(one.env), null);
  const two = await setup();
  assert.equal((await send(two.env, "/pin/reset", "POST", {}, two.master)).status, 200);
  assert.equal(await storedPush(two.env), null);
});

test("push: with an execution context the push is handed to waitUntil", async () => {
  const { env, ai, sent } = await setup();
  const waiting = [];
  const response = await handle(req("/command", "POST", theme("c1"), ai), env, { waitUntil: (work) => waiting.push(work) });
  assert.equal(response.status, 201);
  assert.equal(waiting.length, 1);
  await Promise.all(waiting);
  assert.equal(sent.length, 1);
});
