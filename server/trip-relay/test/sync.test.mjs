// SYN1111A03: GET /command tells the app when an AI key was last seen and whether the AI ended the conversation.
import assert from "node:assert/strict";
import test from "node:test";
import { handle } from "../src/index.js";

import { makeEnv } from "./fakes.mjs";

const DAY_MS = 86400_000;
const randomKey = () => Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64url");
const master = randomKey();
const reader = randomKey();
const PIN = "246810";
const req = (path, method = "GET", body, key = master) => new Request(`https://relay.example.com${path}`, {
  method,
  headers: { authorization: `Bearer ${key}`, "content-type": "application/json" },
  body: body === undefined ? undefined : JSON.stringify(body),
});
const iso = (ms) => new Date(ms).toISOString().replace(".000Z", "Z");

test("command fetch reports AI activity and conversation end", async () => {
  const { env, clock } = makeEnv();
  assert.equal((await handle(req("/register", "POST", {}), env)).status, 201);
  assert.equal((await handle(req("/pin", "POST", { pin: PIN }), env)).status, 200);
  assert.equal((await handle(req("/keys", "POST", { keys: [{ token: reader, scope: "read", expiresAt: iso(clock.now + 30 * DAY_MS) }], pin: PIN }), env)).status, 201);

  let r = await handle(req("/command"), env);
  assert.equal(r.status, 204);
  assert.equal(r.headers.get("x-ai-seen-ago"), "-1", "no AI yet");
  assert.equal(r.headers.get("x-ai-ended"), "0");

  assert.equal((await handle(req("/activity", "GET", undefined, reader), env)).status < 500, true);
  clock.now += 30_000;
  r = await handle(req("/command"), env);
  assert.equal(r.headers.get("x-ai-seen-ago"), "30", "the app's own fetch does not count as AI");
  assert.equal(r.headers.get("x-ai-ended"), "0");

  assert.equal((await handle(req("/session/end", "POST", undefined, reader), env)).status, 200);
  r = await handle(req("/command"), env);
  assert.equal(r.headers.get("x-ai-ended"), "1");

  clock.now += 60_000;
  await handle(req("/activity", "GET", undefined, reader), env);
  r = await handle(req("/command"), env);
  assert.equal(r.headers.get("x-ai-seen-ago"), "0");
  assert.equal(r.headers.get("x-ai-ended"), "0", "a new AI request starts a new conversation");
});

test("MCP lists end_conversation for read keys", async () => {
  const { env, clock } = makeEnv();
  await handle(req("/register", "POST", {}), env);
  await handle(req("/pin", "POST", { pin: PIN }), env);
  await handle(req("/keys", "POST", { keys: [{ token: reader, scope: "read", expiresAt: iso(clock.now + 30 * DAY_MS) }], pin: PIN }), env);
  const list = await (await handle(req("/mcp", "POST", { jsonrpc: "2.0", id: 1, method: "tools/list" }, reader), env)).json();
  assert.ok(list.result.tools.some((tool) => tool.name === "end_conversation"));
  const call = await (await handle(req("/mcp", "POST", { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "end_conversation", arguments: {} } }, reader), env)).json();
  assert.equal(call.result.isError ?? false, false);
});

// AIC1112A01: 응답의 sync가 어느 기기 것이고 언제 마지막으로 왔는지 알려 준다.
test("activity and summary carry sync: device, build, share level, app last seen and last upload", async () => {
  const { env, clock } = makeEnv();
  const app = (path, method, body, client) => {
    const request = req(path, method, body);
    if (client) request.headers.set("x-bokki-client", client);
    return request;
  };
  const rpc = (name, args = {}) => req("/mcp", "POST", { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: args } }, reader);
  assert.equal((await handle(req("/register", "POST", {}), env)).status, 201);
  assert.equal((await handle(req("/pin", "POST", { pin: PIN }), env)).status, 200);
  assert.equal((await handle(req("/keys", "POST", { keys: [{ token: reader, scope: "read", expiresAt: iso(clock.now + 30 * DAY_MS) }], pin: PIN }), env)).status, 201);

  // 올린 날이 없어도 MCP는 앱이 다녀간 때를 알려 준다.
  await handle(app("/command", "GET", undefined, "iPhone12,3;323;summary;debug"), env);
  const seenAt = new Date(clock.now).toISOString();
  let empty = (await (await handle(rpc("get_activity", { date: "2026-11-12" }), env)).json()).result.structuredContent;
  assert.deepEqual(empty, { stored: false, sync: { appLastSeenAt: seenAt, device: "iPhone12,3", appBuild: "323", shareLevel: "summary", debugBuild: true } });
  assert.equal((await handle(req("/activity?date=2026-11-12", "GET", undefined, reader), env)).status, 204, "REST stays 204");

  clock.now += 5 * 60_000;
  const day = { date: "2026-11-12", summary: { recordedMinutes: 10 } };
  assert.equal((await handle(app("/activity", "POST", { format: "bokki-activity", version: 1, retentionDays: 30, days: [day] }, "iPhone19,7;324;visits"), env)).status, 201);
  const uploadedAt = new Date(clock.now).toISOString();
  const sync = { appLastSeenAt: uploadedAt, lastUploadAt: uploadedAt, device: "iPhone19,7", appBuild: "324", shareLevel: "visits" };
  assert.deepEqual(await (await handle(req("/activity?date=2026-11-12", "GET", undefined, reader), env)).json(), { ...day, sync });
  assert.deepEqual((await (await handle(req("/activity", "GET", undefined, reader), env)).json()).sync, sync);
  assert.deepEqual((await (await handle(req("/activity/summary?range=week&end=2026-11-12", "GET", undefined, reader), env)).json()).sync, sync);

  // AI 키의 요청과 모양이 틀린 머리말은 앱이 다녀간 것으로 치지 않는다. 1분 안의 같은 정보는 다시 쓰지 않는다.
  clock.now += 30_000;
  await handle(app("/command", "GET", undefined, "<script>;1;visits"), env);
  const reading = req("/activity", "GET", undefined, reader);
  reading.headers.set("x-bokki-client", "Mac1,1;1;off");
  assert.deepEqual((await (await handle(reading, env)).json()).sync, sync);
  clock.now += 60_000;
  await handle(app("/command", "GET"), env);
  const later = (await (await handle(rpc("get_summary", { range: "week", end: "2026-11-12" }), env)).json()).result.structuredContent.sync;
  assert.deepEqual(later, { ...sync, appLastSeenAt: new Date(clock.now).toISOString() }, "values stay raw (not wrapped as untrusted)");

  // AIL1112A01: 잠금 중이면 올리기를 쉰다는 것을 알린다. 같은 표시를 두 번 보내거나 모르는 표시는 버린다.
  await handle(app("/command", "GET", undefined, "iPhone19,7;324;visits;debug;locked"), env);
  const paused = (await (await handle(rpc("get_summary", { range: "week", end: "2026-11-12" }), env)).json()).result.structuredContent.sync;
  assert.deepEqual([paused.uploadsPaused, paused.debugBuild], ["privacyLock", true]);
  await handle(app("/command", "GET", undefined, "iPhone19,7;324;visits;locked;locked"), env);
  await handle(app("/command", "GET", undefined, "iPhone19,7;324;visits;rooted"), env);
  assert.equal((await (await handle(req("/activity", "GET", undefined, reader), env)).json()).sync.uploadsPaused, "privacyLock", "bad headers change nothing");
  await handle(app("/command", "GET", undefined, "iPhone19,7;324;visits"), env);
  assert.equal((await (await handle(req("/activity", "GET", undefined, reader), env)).json()).sync.uploadsPaused, undefined, "unlocked again");
});
