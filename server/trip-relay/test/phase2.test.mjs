// AIR1110A02 / SEC1110A01 / CLN1110A01: scoped keys, DEK v2 encryption, 24h command cap, new actions, summary, MCP, OpenAPI.
import assert from "node:assert/strict";
import test from "node:test";
import { handle, isCommand, seal, storageCryptoKey, storageKey } from "../src/index.js";

import { MemoryKV, makeEnv } from "./fakes.mjs";

const NOW = Date.parse("2026-11-10T03:00:00Z");
const DAY_MS = 86400_000;
const randomKey = () => Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64url");
const master = randomKey();
const reader = randomKey();
const writer = randomKey();
const iso = (ms) => new Date(ms).toISOString().replace(".000Z", "Z");
// SEC1110A02·A03: 연결 키를 만들려면 PIN이 필요하다(POST /pin {"pin"}).
export const PIN = "246810";
const registerWithPin = async (env, key) => {
  const registered = await handle(req("/register", "POST", {}, key), env);
  assert.equal((await handle(req("/pin", "POST", { pin: PIN }, key), env)).status, 200);
  return registered;
};

async function setup() {
  const { env, clock } = makeEnv();
  const registered = await registerWithPin(env, master);
  assert.equal(registered.status, 201);
  return { clock, env };
}
const dataNames = (env) => [...env.PLANS.map.keys()].filter((name) => !name.startsWith("reg:"));
const req = (path, method = "GET", body, key = master) => new Request(`https://relay.example.com${path}`, {
  method,
  headers: key ? { authorization: `Bearer ${key}`, "content-type": "application/json" } : {},
  body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body),
});
const hashOf = async (key) => (await storageKey(key)).slice("plan:".length);
const register = (env, keys, key = master) => handle(req("/keys", "POST", { keys, pin: PIN }, key), env);
const standardKeys = () => [
  { token: reader, scope: "read", expiresAt: iso(NOW + 365 * DAY_MS) },
  { token: writer, scope: "write", expiresAt: iso(NOW + 90 * DAY_MS) },
];
const day = (date, summary = {}, extra = {}) => ({ date, timeZone: "Asia/Seoul", summary: { categories: [], recordedMinutes: 0, plansScheduled: 0, plansCompleted: 0, ...summary }, records: [], memos: [], ...extra });
const upload = (days) => ({ format: "bokki-activity", version: 1, retentionDays: 30, days });
const command = (id, action, extra = {}) => ({ format: "bokki-command", version: 1, id, action, ...extra });
const memo = (id) => command(id, "addMemo", { text: "우유 사기" });
const plan = { format: "bokki-trip", version: 1, tripId: "t1", title: "방콕", items: [{ id: "i1", type: "sight", title: "왓 아룬" }] };

// MARK: keys and scopes

test("master registers read and write keys; GET /keys lists 8-hex ids without tokens", async () => {
  const { env } = await setup();
  const response = await register(env, standardKeys());
  assert.equal(response.status, 201);
  const listed = await (await handle(req("/keys"), env)).json();
  assert.deepEqual(listed.keys.map((k) => [k.id, k.scope, k.expiresAt, k.source]).sort((a, b) => a[1].localeCompare(b[1])), [
    [(await hashOf(reader)).slice(0, 8), "read", iso(NOW + 365 * DAY_MS), "rest"],
    [(await hashOf(writer)).slice(0, 8), "write", iso(NOW + 90 * DAY_MS), "rest"],
  ]);
  for (const value of env.PLANS.map.values()) for (const secret of [master, reader, writer]) assert.ok(!value.includes(secret));
  assert.equal(env.PLANS.options.get("dek:" + await hashOf(writer)).expirationTtl, 90 * 86400, "wrap lives until expiry");
  assert.ok(env.PLANS.map.has("tomb:" + await hashOf(writer)), "permanent marker: never registrable as a master");
});

test("scopes: read key reads only, write key also sends, app-only routes stay master-only", async () => {
  const { env } = await setup();
  await register(env, standardKeys());
  await handle(req("/activity", "POST", upload([day("2026-11-10")])), env);
  await handle(req("/plan", "POST", plan), env);
  for (const path of ["/activity", "/activity?date=2026-11-10", "/activity/summary?range=week", "/plan"]) {
    assert.equal((await handle(req(path, "GET", undefined, reader), env)).status, 200, `read ${path}`);
  }
  assert.equal((await handle(req("/command/result", "GET", undefined, reader), env)).status, 204);
  assert.equal((await handle(req("/command", "POST", memo("r1"), reader), env)).status, 403, "read key can't write");
  assert.equal((await handle(req("/plan", "POST", plan, reader), env)).status, 403);
  assert.equal((await handle(req("/command", "POST", memo("w1"), writer), env)).status, 201);
  assert.equal((await handle(req("/plan", "POST", plan, writer), env)).status, 201);
  for (const [path, method] of [["/activity", "POST"], ["/activity", "DELETE"], ["/command", "GET"], ["/command", "DELETE"], ["/command/result", "POST"], ["/plan", "DELETE"], ["/keys", "GET"], ["/keys", "POST"], ["/keys", "DELETE"]]) {
    for (const key of [reader, writer]) {
      assert.equal((await handle(req(path, method, method === "POST" ? {} : undefined, key), env)).status, 403, `${method} ${path}`);
    }
  }
  const queued = await (await handle(req("/command"), env)).json();
  assert.deepEqual(queued.commands.map((c) => c.id), ["w1"], "write key lands in the master namespace");
  const scoped = [await hashOf(reader), await hashOf(writer)];
  assert.ok(![...env.PLANS.map.keys()].some((k) => scoped.some((h) => k.includes(h)) && !k.startsWith("dek:") && !k.startsWith("tomb:")), "no data under scoped hashes");
});

test("expired and revoked scoped keys get 401", async () => {
  const { env, clock } = await setup();
  await register(env, [...standardKeys(), { token: "S".repeat(43), scope: "read", expiresAt: iso(NOW + DAY_MS) }]);
  assert.equal((await handle(req("/activity", "GET", undefined, "S".repeat(43)), env)).status, 204);
  clock.now = NOW + DAY_MS + 1000;
  assert.equal((await handle(req("/activity", "GET", undefined, "S".repeat(43)), env)).status, 401, "expired");
  assert.equal((await handle(req("/activity", "GET", undefined, reader), env)).status, 204, "others still work");
  assert.equal((await (await handle(req("/keys"), env)).json()).keys.length, 2, "expired keys are not listed");

  const id = (await hashOf(writer)).slice(0, 8);
  assert.equal((await handle(req(`/keys?id=${id}`, "DELETE"), env)).status, 204);
  assert.equal((await handle(req("/command", "POST", memo("x"), writer), env)).status, 401, "revoked");
  assert.equal((await handle(req("/activity", "GET", undefined, writer), env)).status, 401);
  assert.equal((await handle(req("/activity", "GET", undefined, reader), env)).status, 204);
  assert.equal((await handle(req("/keys?id=XYZ", "DELETE"), env)).status, 400);
  assert.equal((await handle(req("/keys", "DELETE"), env)).status, 204);
  assert.equal((await handle(req("/activity", "GET", undefined, reader), env)).status, 401, "revoke all");
  assert.deepEqual((await (await handle(req("/keys"), env)).json()).keys, []);
  assert.equal((await handle(req("/activity", "GET"), env)).status, 204, "master unaffected");
});

test("key registration rejects bad bodies, long lifetimes and other people's keys", async () => {
  const { env } = await setup();
  const write = (days) => ({ token: writer, scope: "write", expiresAt: iso(NOW + days * DAY_MS) });
  for (const keys of [
    [write(366)],
    [{ token: reader, scope: "read", expiresAt: iso(NOW + 366 * DAY_MS) }],
    [{ token: writer, scope: "write" }],
    [write(-1)],
    [{ ...write(30), scope: "admin" }],
    [{ ...write(30), token: "short" }],
    [{ ...write(30), token: master }],
    [write(30), write(30)],
    [{ ...write(30), expiresAt: "next week" }],
    [],
  ]) assert.equal((await register(env, keys)).status, 422, JSON.stringify(keys));
  assert.equal((await handle(req("/keys", "POST", "nope"), env)).status, 400);
  assert.deepEqual(dataNames(env), [], "nothing written for rejected bodies");

  // 다른 사람의 주인 키(등록됨)나 다른 사람의 범위 키 자리는 덮지 않는다.
  const other = randomKey();
  assert.equal((await registerWithPin(env, other)).status, 201);
  await handle(req("/plan", "POST", plan, other), env);
  assert.equal((await register(env, [{ token: other, scope: "read", expiresAt: iso(NOW + DAY_MS) }])).status, 409);
  assert.equal((await register(env, [{ token: reader, scope: "read", expiresAt: iso(NOW + DAY_MS) }], other)).status, 201);
  assert.equal((await register(env, [{ token: reader, scope: "read", expiresAt: iso(NOW + DAY_MS) }])).status, 409);
  assert.equal((await handle(req("/plan", "GET", undefined, other), env)).status, 200, "victim keeps their data");
});

test("key lifetime is the user's choice: up to 365 days or no expiry (null) for both scopes", async () => {
  const { env, clock } = await setup();
  const forever = randomKey();
  const response = await register(env, [
    { token: reader, scope: "read", expiresAt: null },
    { token: forever, scope: "write", expiresAt: null },
    { token: writer, scope: "write", expiresAt: iso(NOW + 365 * DAY_MS) },
  ]);
  assert.equal(response.status, 201);
  assert.deepEqual((await response.json()).keys.map((k) => k.expiresAt), [null, null, iso(NOW + 365 * DAY_MS)]);
  assert.equal(env.PLANS.options.get("dek:" + await hashOf(forever)), undefined, "no expirationTtl for a no-expiry wrap");
  assert.deepEqual(Object.keys(JSON.parse(env.PLANS.map.get("dek:" + await hashOf(forever)))).sort(), ["ct", "iv", "v"], "no plaintext metadata");

  clock.now = NOW + 10 * 365 * DAY_MS;
  assert.equal((await handle(req("/command", "POST", memo("late"), forever), env)).status, 201, "still works ten years later");
  assert.equal((await handle(req("/activity", "GET", undefined, reader), env)).status, 204);
  assert.equal((await handle(req("/activity", "GET", undefined, writer), env)).status, 401, "the dated key expired");
  const listed = (await (await handle(req("/keys"), env)).json()).keys;
  assert.deepEqual(listed.map((k) => [k.scope, k.expiresAt]).sort(), [["read", null], ["write", null]]);

  const id = (await hashOf(forever)).slice(0, 8);
  assert.equal((await handle(req(`/keys?id=${id}`, "DELETE"), env)).status, 204);
  assert.equal((await handle(req("/activity", "GET", undefined, forever), env)).status, 401, "revoked");
  assert.ok(!env.PLANS.map.has("dek:" + await hashOf(forever)), "wrap deleted");
  assert.equal(env.PLANS.options.get("tomb:" + await hashOf(forever)), undefined, "tombstone is permanent");
  assert.equal((await handle(req("/register", "POST", {}, forever), env)).status, 409, "a revoked key never becomes a master");
  assert.equal((await handle(req("/activity", "GET", undefined, reader), env)).status, 204);
});

// MARK: encryption v2

test("DEK v2 round trip: one DEK wrapped per key, data sealed under the master name", async () => {
  const { env } = await setup();
  await register(env, standardKeys());
  await handle(req("/command", "POST", command("s1", "addSchedule", { title: "비밀 치과", start: "2026-11-12T15:00+09:00" }), writer), env);
  const m = await hashOf(master);
  assert.ok(!env.PLANS.map.has("dek:" + m), "the master DEK is derived from the master key, never stored");
  const wraps = await Promise.all([reader, writer].map(async (k) => JSON.parse(env.PLANS.map.get("dek:" + await hashOf(k)))));
  assert.deepEqual(wraps.map((w) => [w.v, w.scope, w.master]), [[3, undefined, undefined], [3, undefined, undefined]], "scope and master are inside the ciphertext");
  assert.notEqual(wraps[0].ct, wraps[1].ct, "each key wraps the DEK differently");
  const commands = (await (await handle(req("/command"), env)).json()).commands;
  assert.equal(commands[0].title, "비밀 치과", "master opens what the write key sealed");

  // 감싼 기록을 바꾸면 풀리지 않아 401.
  const name = "dek:" + await hashOf(reader);
  const wrap = JSON.parse(env.PLANS.map.get(name));
  const bytes = Buffer.from(wrap.ct, "base64");
  bytes[3] ^= 1;
  env.PLANS.map.set(name, JSON.stringify({ ...wrap, ct: bytes.toString("base64") }));
  assert.equal((await handle(req("/activity", "GET", undefined, reader), env)).status, 401);
});

test("v1 values: the master's first read moves them to v2 under HMAC names keeping TTL; scoped keys then read them", async () => {
  const { env } = await setup();
  const m = await hashOf(master);
  const legacy = await storageCryptoKey(master);
  const put = async (name, value, expiration) => { env.PLANS.map.set(name, await seal(legacy, name, JSON.stringify(value), 1)); env.PLANS.options.set(name, { expiration }); };
  const expiration = Math.floor(NOW / 1000) + 5 * 86400;
  await put(`act:${m}:2026-11-09`, day("2026-11-09", { recordedMinutes: 60 }), expiration);
  await put("plan:" + m, plan, expiration);
  assert.equal((await (await handle(req("/activity?date=2026-11-09"), env)).json()).summary.recordedMinutes, 60, "master reads v1");
  assert.ok(!env.PLANS.map.has(`act:${m}:2026-11-09`), "moved off the date name");
  const [moved] = dataNames(env).filter((n) => n.startsWith(`act:${m}:`));
  assert.equal(JSON.parse(env.PLANS.map.get(moved)).v, 2);
  assert.equal(env.PLANS.options.get(moved).expirationTtl, 5 * 86400, "remaining TTL kept");
  assert.equal((await (await handle(req("/plan"), env)).json()).tripId, "t1");
  assert.equal(JSON.parse(env.PLANS.map.get("plan:" + m)).v, 2, "re-sealed on the master's read");

  assert.equal((await register(env, standardKeys())).status, 201);
  assert.equal((await (await handle(req("/activity?date=2026-11-09", "GET", undefined, reader), env)).json()).date, "2026-11-09");
  assert.equal((await (await handle(req("/plan", "GET", undefined, reader), env)).json()).tripId, "t1");
});

test("a master that only ever reads creates no DEK", async () => {
  const { env } = await setup();
  await handle(req("/plan"), env);
  await handle(req("/activity"), env);
  await handle(req("/keys"), env);
  assert.deepEqual(dataNames(env), []);
});

// MARK: 24h command cap

test("30 commands per master namespace per rolling 24 h, counted in the Durable Object", async () => {
  const { env, clock } = await setup();
  await register(env, standardKeys());
  const start = env.PLANS.writes;
  for (let i = 0; i < 20; i++) assert.equal((await handle(req("/command", "POST", memo(`w${i}`), writer), env)).status, 201);
  assert.equal(env.PLANS.writes - start, 0, "SEC1110A02: queue and counter live in the Durable Object, no KV writes");
  clock.now += 3600_000;
  await handle(req("/command", "DELETE"), env); // 앱이 큐를 비워도 한도는 남는다.
  for (let i = 0; i < 10; i++) assert.equal((await handle(req("/command", "POST", memo(`m${i}`)), env)).status, 201);
  const refused = await handle(req("/command", "POST", memo("late"), writer), env);
  assert.equal(refused.status, 429);
  const body = await refused.json();
  assert.equal(body.error, "daily_command_limit");
  assert.equal(Number(refused.headers.get("retry-after")), body.retryAfterSeconds);
  assert.equal(body.retryAfterSeconds, 23 * 3600, "the first 20 age out 24 h after they arrived");
  assert.equal((await handle(req("/command", "POST", memo("late")), env)).status, 429, "master shares the namespace cap");
  clock.now = NOW + DAY_MS + 1;
  assert.equal((await handle(req("/command", "POST", memo("next"), writer), env)).status, 201);
});

// MARK: new actions

test("new command actions are validated", () => {
  const ok = [
    command("h1", "hideRecord", { date: "2026-11-10", recordId: "R1" }),
    command("h2", "hideRecord", { date: "2026-11-10", startTime: "09:30" }),
    command("g1", "mergeRecords", { date: "2026-11-10", recordIds: ["R1", "R2"], title: "업무", categoryId: "work" }),
    command("t1", "updateRecordTime", { date: "2026-11-10", recordId: "R1", start: "09:00" }),
    command("t2", "updateRecordTime", { date: "2026-11-10", recordId: "R1", start: "09:00", end: "10:00" }),
    command("p1", "updateSchedule", { planId: "P1", title: "치과" }),
    command("p2", "updateSchedule", { date: "2026-11-12", startTime: "15:00", start: "2026-11-12T16:00+09:00", end: "2026-11-12T17:00+09:00" }),
    command("p3", "updateSchedule", { planId: "P1", start: "16:00", note: "" }),
    command("d1", "deleteSchedule", { planId: "P1" }),
    command("d2", "deleteSchedule", { date: "2026-11-12", startTime: "15:00" }),
    command("e1", "updateMemo", { memoId: "MEMO1", text: "두유 사기" }),
    command("x1", "deleteMemo", { memoId: "MEMO1" }),
  ];
  for (const c of ok) assert.ok(isCommand(c), c.id);
  const bad = [
    command("h3", "hideRecord", { date: "2026-11-10" }),
    command("h4", "hideRecord", { recordId: "R1" }),
    command("h5", "hideRecord", { date: "2026-11-10", startTime: "9:30" }),
    command("g2", "mergeRecords", { date: "2026-11-10", recordIds: ["R1"] }),
    command("g3", "mergeRecords", { date: "2026-11-10", recordIds: Array.from({ length: 21 }, (_, i) => `R${i}`) }),
    command("g4", "mergeRecords", { date: "2026-11-10", recordIds: ["R1", "R1"] }),
    command("g5", "mergeRecords", { recordIds: ["R1", "R2"] }),
    command("g6", "mergeRecords", { date: "2026-11-10", recordIds: ["R1", ""] }),
    command("t3", "updateRecordTime", { date: "2026-11-10", recordId: "R1" }),
    command("t4", "updateRecordTime", { date: "2026-11-10", start: "09:00" }),
    command("t5", "updateRecordTime", { date: "2026-11-10", recordId: "R1", end: "24:00" }),
    command("t6", "updateRecordTime", { date: "2026-11-10", recordId: "R1", start: "09:00", end: "09:00" }),
    command("p4", "updateSchedule", { planId: "P1" }),
    command("p5", "updateSchedule", { date: "2026-11-12", title: "치과" }),
    command("p6", "updateSchedule", { planId: "P1", start: "2026-11-12T17:00+09:00", end: "2026-11-12T16:00+09:00" }),
    command("p7", "updateSchedule", { planId: "P1", start: "tomorrow" }),
    command("p8", "updateSchedule", { planId: "P1", note: "x".repeat(1001) }),
    command("d3", "deleteSchedule", {}),
    command("d4", "deleteSchedule", { date: "2026-11-12" }),
    command("e2", "updateMemo", { memoId: "MEMO1", text: "" }),
    command("e3", "updateMemo", { text: "두유" }),
    command("x2", "deleteMemo", {}),
  ];
  for (const c of bad) assert.ok(!isCommand(c), c.id);
});

// MARK: summary

test("activity summary adds up stored days in the week or month ending at end", async () => {
  const { env } = await setup();
  await register(env, standardKeys());
  const cat = (id, title, minutes) => ({ id, title, minutes });
  await handle(req("/activity", "POST", upload([
    day("2026-11-01", { categories: [cat("work", "업무", 999)], recordedMinutes: 999, steps: 9 }),
    day("2026-11-08", { categories: [cat("work", "업무", 300), cat("rest", "휴식", 60)], recordedMinutes: 360, steps: 4000, plansScheduled: 2, plansCompleted: 1 }),
    day("2026-11-09", { categories: [cat("work", "Work", 200)], recordedMinutes: 200, plansScheduled: 1, plansCompleted: 1 }),
    day("2026-11-10", { categories: [cat("rest", "휴식", 600)], recordedMinutes: 600, steps: 6000 }),
  ])), env);
  const week = await (await handle(req("/activity/summary?range=week&end=2026-11-10", "GET", undefined, reader), env)).json();
  assert.deepEqual(week, {
    range: "week", start: "2026-11-04", end: "2026-11-10", daysCovered: 3, dates: ["2026-11-08", "2026-11-09", "2026-11-10"],
    recordedMinutes: 1160, steps: 10000, plansScheduled: 3, plansCompleted: 2, stepDays: 2,
    categories: [{ id: "rest", title: "휴식", minutes: 660 }, { id: "work", title: "Work", minutes: 500 }],
    sync: week.sync,
  });
  const month = await (await handle(req("/activity/summary?range=month", "GET", undefined, reader), env)).json();
  assert.equal(month.end, "2026-11-10", "defaults to today or the newest stored day");
  assert.equal(month.start, "2026-10-12");
  assert.equal(month.daysCovered, 4);
  assert.equal((await handle(req("/activity/summary?range=week&end=2026-10-01", "GET", undefined, reader), env)).status, 204);
  assert.equal((await handle(req("/activity/summary?range=year", "GET", undefined, reader), env)).status, 400);
  assert.equal((await handle(req("/activity/summary?range=week&end=11-10", "GET", undefined, reader), env)).status, 400);
});

// MARK: MCP

const rpc = (method, params, id = 1) => ({ jsonrpc: "2.0", id, method, ...(params ? { params } : {}) });
const mcp = async (env, message, key) => {
  const response = await handle(req("/mcp", "POST", message, key), env);
  return { status: response.status, body: response.status === 202 ? null : await response.json() };
};

test("MCP initialize, tools/list per scope, notifications and JSON-RPC errors", async () => {
  const { env } = await setup();
  await register(env, standardKeys());
  const init = await mcp(env, rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "1" } }), writer);
  assert.equal(init.status, 200);
  assert.equal(init.body.result.protocolVersion, "2025-06-18");
  assert.ok(init.body.result.capabilities.tools);
  assert.equal((await mcp(env, { jsonrpc: "2.0", method: "notifications/initialized" }, writer)).status, 202);
  const all = (await mcp(env, rpc("tools/list"), writer)).body.result.tools.map((t) => t.name);
  assert.deepEqual(all.sort(), ["add_category", "add_expense", "add_goal", "add_memo", "add_own_account", "add_payment_rule", "add_place", "add_schedule", "add_trip", "add_trip_stop", "ask_user", "classify_unconfirmed", "complete_ai_task", "delete_goal", "delete_inbox_item", "delete_memo", "delete_payment_rule", "delete_place", "delete_schedule", "delete_trip", "delete_trip_stop",
    "end_conversation", "get_activity", "get_ai_tasks", "get_answers", "get_app_state", "get_command_results", "get_polish_requests", "get_summary", "hide_record", "list_actions", "merge_records", "open_screen", "remove_own_account", "request_approval", "resolve_place_suggestion", "resolve_review", "run_action", "send_trip_plan", "set_bubble", "set_budget", "set_calendar_title_detail", "set_car_audio", "set_display_option", "set_language",
    "set_map_style", "set_setting", "set_theme", "set_travel_mode", "set_trip_budget", "set_trip_item_status", "update_activity", "update_category", "update_expense", "update_goal", "update_memo", "update_place", "update_record_time", "update_schedule",
    "update_sleep", "update_trip", "update_trip_stop"]);
  const read = (await mcp(env, rpc("tools/list"), reader)).body.result.tools;
  assert.deepEqual(read.map((t) => t.name).sort(), ["complete_ai_task", "end_conversation", "get_activity", "get_ai_tasks", "get_answers", "get_app_state", "get_command_results", "get_polish_requests", "get_summary", "list_actions"]);
  // AIC1112A01: 상태를 바꾸는 둘은 읽기 전용으로 표시하지 않는다.
  assert.ok(read.every((t) => t.inputSchema.type === "object" && t.annotations.readOnlyHint === !["complete_ai_task", "end_conversation"].includes(t.name)));
  assert.equal((await mcp(env, rpc("resources/list"), reader)).body.error.code, -32601);
  assert.equal((await mcp(env, rpc("tools/call", { name: "nope", arguments: {} }), reader)).body.error.code, -32602);
  assert.equal((await mcp(env, "{not json", reader)).body.error.code, -32700);
  assert.equal((await mcp(env, [rpc("ping")], reader)).body.error.code, -32600);
  assert.equal((await mcp(env, { id: 1, method: "ping" }, reader)).body.error.code, -32600);
  assert.deepEqual((await mcp(env, rpc("ping", undefined, "a"), reader)).body, { jsonrpc: "2.0", id: "a", result: {} });
  const unauthorized = await handle(req("/mcp", "POST", rpc("initialize"), null), env);
  assert.equal(unauthorized.status, 401);
  assert.equal(unauthorized.headers.get("www-authenticate"), 'Bearer resource_metadata="https://relay.example.com/.well-known/oauth-protected-resource"', "no token: no error code, so OAuth starts");
  assert.equal((await handle(req("/mcp", "GET", undefined, reader), env)).status, 405);
});

test("MCP tools/call: read tool reads storage, write tool queues a command, read key gets an error for writes", async () => {
  const { env } = await setup();
  await register(env, standardKeys());
  await handle(req("/activity", "POST", upload([day("2026-11-10", { recordedMinutes: 42 })])), env);

  const got = await mcp(env, rpc("tools/call", { name: "get_activity", arguments: { date: "2026-11-10" } }), reader);
  assert.equal(got.body.result.isError, undefined);
  assert.equal(got.body.result.structuredContent.summary.recordedMinutes, 42);
  assert.equal(JSON.parse(got.body.result.content[0].text).date, "2026-11-10");
  const summary = await mcp(env, rpc("tools/call", { name: "get_summary", arguments: { range: "week", end: "2026-11-10" } }), reader);
  assert.equal(summary.body.result.structuredContent.recordedMinutes, 42);
  const nothing = await mcp(env, rpc("tools/call", { name: "get_command_results", arguments: {} }), reader);
  assert.match(nothing.body.result.content[0].text, /^No edit results yet/);

  const denied = await mcp(env, rpc("tools/call", { name: "add_memo", arguments: { text: "우유" } }), reader);
  assert.equal(denied.body.error.code, -32003);
  assert.equal((await handle(req("/command"), env)).status, 204, "nothing queued");

  const added = await mcp(env, rpc("tools/call", { name: "add_memo", arguments: { text: "우유 사기", date: "2026-11-10", time: "18:30" } }), writer);
  assert.equal(added.body.result.structuredContent.ok, true);
  const hidden = await mcp(env, rpc("tools/call", { name: "hide_record", arguments: { id: "hide-1", date: "2026-11-10", recordId: "R1" } }), writer);
  assert.deepEqual(hidden.body.result.structuredContent.id, { untrusted_user_text: "hide-1" }, "ids that are not UUID/hex/one word are wrapped (REV1110A06 N9)");
  const invalid = await mcp(env, rpc("tools/call", { name: "merge_records", arguments: { date: "2026-11-10", recordIds: ["R1"] } }), writer);
  assert.equal(invalid.body.result.isError, true);
  assert.match(invalid.body.result.content[0].text, /422/);
  const { commands } = await (await handle(req("/command"), env)).json();
  assert.deepEqual(commands.map((c) => [c.action, c.format, c.version]), [["addMemo", "bokki-command", 1], ["hideRecord", "bokki-command", 1]]);
  assert.match(commands[0].id, /^mcp-[0-9a-f-]{36}$/);

  const sent = await mcp(env, rpc("tools/call", { name: "send_trip_plan", arguments: { plan } }), writer);
  assert.equal(sent.body.result.structuredContent.tripId, "t1");
  assert.equal((await (await handle(req("/plan"), env)).json()).title, "방콕");
});

test("MCP write tools share the per-IP limit and the 24h cap", async () => {
  const { env } = await setup();
  let calls = 0;
  env.POST_LIMIT = { limit: async () => ({ success: ++calls <= 1 }) };
  await handle(req("/activity", "GET"), env); // reads are not limited
  assert.equal((await register(env, standardKeys())).status, 201);
  const limited = await mcp(env, rpc("tools/call", { name: "add_memo", arguments: { text: "우유" } }), writer);
  assert.equal(limited.body.result.isError, true);
  assert.match(limited.body.result.content[0].text, /429/);
  assert.equal((await mcp(env, rpc("tools/call", { name: "get_activity", arguments: {} }), writer)).body.result.isError, undefined);
});

// MARK: OpenAPI

test("openapi.json is public, valid JSON and lists the AI routes with bearer auth", async () => {
  const { env } = await setup();
  const response = await handle(new Request("https://trip.bokkiyaw.com/openapi.json"), env);
  assert.equal(response.status, 200);
  const doc = JSON.parse(await response.text());
  assert.equal(doc.openapi, "3.1.0");
  assert.equal(doc.servers[0].url, "https://trip.bokkiyaw.com");
  assert.deepEqual(Object.keys(doc.paths).sort(), ["/activity", "/activity/summary", "/answers", "/app", "/command", "/command/result", "/plan", "/polish", "/session/end", "/tasks/claim", "/tasks/result"]);
  assert.equal(doc.components.securitySchemes.bearer.scheme, "bearer");
  const ids = Object.values(doc.paths).flatMap((p) => Object.values(p).map((op) => op.operationId));
  assert.equal(new Set(ids).size, ids.length, "unique operationIds");
  assert.ok(doc.components.schemas.Command.properties.action.enum.includes("mergeRecords"));
  assert.ok(doc.components.schemas.Command.properties.action.enum.includes("setTripItemStatus"));
  assert.deepEqual(dataNames(env), []);
  assert.equal((await handle(new Request("https://trip.bokkiyaw.com/openapi.json", { method: "POST" }), env)).status, 405);
});
