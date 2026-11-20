// RTA1120A02: 앱 전면 실시간 반영 소켓. 방은 가짜 소켓·메모리 저장소 위에서 돌고, 값은 전부 익명이다.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { handle } from "../src/index.js";
import { REALTIME } from "../src/realtime.js";
import { sha256Hex } from "../src/crypto.js";
import { makeRealtimeEnv } from "./fakes.mjs";

const ORIGIN = "https://relay.example.com";
const PIN = "135790";
const randomKey = () => Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64url");
const call = (env, path, { method = "GET", body, key, upgrade = false } = {}) => handle(new Request(ORIGIN + path, {
  method,
  headers: { ...(key ? { authorization: `Bearer ${key}` } : {}), "content-type": "application/json", ...(upgrade ? { upgrade: "websocket" } : {}) },
  body: body === undefined ? undefined : JSON.stringify(body),
}), env);

async function setup(extra = {}) {
  const made = makeRealtimeEnv(extra);
  const master = randomKey(), ai = randomKey();
  assert.equal((await call(made.env, "/register", { method: "POST", body: {}, key: master })).status, 201);
  assert.equal((await call(made.env, "/pin", { method: "POST", body: { pin: PIN }, key: master })).status, 200);
  assert.equal((await call(made.env, "/keys", { method: "POST", body: { keys: [{ token: ai, scope: "write", expiresAt: null }], pin: PIN }, key: master })).status, 201);
  const room = made.rooms.instance("owner:" + (await sha256Hex(master)));
  return { ...made, master, ai, room };
}
const open = async (s, query = "") => {
  const before = s.rooms.pairs.length;
  const response = await call(s.env, "/rt/ws" + query, { key: s.master, upgrade: true });
  assert.equal(response.status, 200, "가짜 업그레이드는 200+표시 헤더");
  return s.rooms.pairs[before][1]; // 서버 쪽 소켓
};
const command = (id, action = "addMemo", extra = {}) => ({ format: "bokki-command", version: 1, id, action, text: "우유 사기", ...extra });
const sent = (ws) => ws.sent.map((m) => m.type);
// 하루 명령 한도에 걸리지 않게 방에 직접 발행한다(DO 안쪽 문).
const emit = (s, n) => Promise.all([...Array(n).keys()].map(async (i) => s.room.room.fetch(new Request("https://realtime/event", { method: "POST", body: JSON.stringify({ type: "cmd", id: `c${i}`, kind: "addMemo" }) }))));

test("route: not an upgrade → 426, no key → 401, an AI key is refused, no binding → 503", async () => {
  const s = await setup();
  assert.equal((await call(s.env, "/rt/ws", { key: s.master })).status, 426);
  assert.equal((await call(s.env, "/rt/ws", { upgrade: true })).status, 401);
  assert.equal((await call(s.env, "/rt/ws", { key: randomKey(), upgrade: true })).status, 401);
  assert.ok([401, 403].includes((await call(s.env, "/rt/ws", { key: s.ai, upgrade: true })).status), "AI 연결 키는 소켓을 열 수 없다");
  const bare = await setup();
  delete bare.env.REALTIME_ROOM;
  assert.equal((await call(bare.env, "/rt/ws", { key: bare.master, upgrade: true })).status, 503);
});

test("connect sends hello then ready; events arrive in id order, 50 per page with more", async () => {
  const s = await setup();
  await emit(s, 120);
  const ws = await open(s, "?since=0");
  const kinds = sent(ws);
  assert.equal(kinds[0], "hello");
  assert.equal(kinds.at(-1), "ready");
  const pages = ws.sent.filter((m) => m.type === "events");
  assert.deepEqual(pages.map((p) => [p.items.length, p.more]), [[50, true], [50, true], [20, false]]);
  const ids = pages.flatMap((p) => p.items.map((i) => i.e));
  assert.deepEqual(ids, [...ids].sort((a, b) => a - b));
  assert.equal(ids[0], 1);
  assert.equal(ids.at(-1), 120);
});

test("205 events keep only the latest 200: since=1 → resync, since beyond latest → resync", async () => {
  const s = await setup();
  await emit(s, 205);
  const old = await open(s, "?since=1");
  assert.deepEqual(sent(old), ["hello", "resync"]);
  const ahead = await open(s, "?since=999");
  assert.deepEqual(sent(ahead), ["hello", "resync"]);
  const fresh = await open(s, "?since=5");
  assert.ok(sent(fresh).includes("events"), "since=oldest-1이면 따라잡을 수 있다");
  assert.equal(s.room.ctx.storage.map.get("latest"), 205);
  assert.equal([...s.room.ctx.storage.map.keys()].filter((k) => k.startsWith("e:")).length, REALTIME.keep);
});

test("an AI command pushes one cmd, a plan pushes patch/plan; the owner's own writes publish nothing", async () => {
  const s = await setup();
  const ws = await open(s);
  ws.take();
  assert.equal((await call(s.env, "/command", { method: "POST", body: command("c1"), key: s.ai })).status, 201);
  const cmds = ws.take().filter((m) => m.type === "cmd");
  assert.equal(cmds.length, 1);
  assert.equal(cmds[0].id, "c1");
  assert.equal(cmds[0].kind, "addMemo");
  assert.ok(Number.isInteger(cmds[0].at));
  const plan = { format: "bokki-trip", version: 1, tripId: "trip-7", title: "여행", days: [] };
  await call(s.env, "/plan", { method: "POST", body: plan, key: s.ai });
  const patches = ws.take().filter((m) => m.type === "patch");
  assert.ok(patches.length === 0 || patches[0].entity === "plan");
  // 주인 키가 쓴 것은 발행하지 않는다.
  await call(s.env, "/app", { method: "POST", body: { format: "bokki-app", version: 1, retentionDays: 7 }, key: s.master });
  assert.equal(ws.take().length, 0);
});

test("events carry no body, amounts, coordinates or names", async () => {
  const s = await setup();
  const ws = await open(s);
  ws.take();
  await call(s.env, "/command", { method: "POST", body: command("c1", "addMemo", { text: "비밀 메모 내용" }), key: s.ai });
  const text = JSON.stringify(ws.take());
  assert.equal(text.includes("비밀 메모"), false);
  for (const key of Object.keys(JSON.parse(text)[0])) assert.ok(["type", "id", "kind", "at", "e"].includes(key), key);
});

test("ping is answered by the runtime auto response, and the room never uses timers or alarms", async () => {
  const source = readFileSync(new URL("../src/realtime.js", import.meta.url), "utf8");
  assert.match(source, /WebSocketRequestResponsePair\("ping", "pong"\)/);
  const code = source.split("\n").filter((line) => !line.trim().startsWith("//")).join("\n");
  for (const banned of ["setInterval", "setTimeout", "setAlarm", ".accept()"]) assert.equal(code.includes(banned), false, banned);
});

test("reconnecting with since gets only what was missed; a since op catches up on the open socket", async () => {
  const s = await setup();
  const first = await open(s);
  for (const n of [1, 2, 3]) await call(s.env, "/command", { method: "POST", body: command(`c${n}`), key: s.ai });
  const seen = first.sent.filter((m) => m.type === "cmd").map((m) => m.e);
  assert.deepEqual(seen, [1, 2, 3]);
  first.closed = { code: 1006 };
  await call(s.env, "/command", { method: "POST", body: command("c4"), key: s.ai });
  const again = await open(s, "?since=3");
  assert.deepEqual(again.sent.find((m) => m.type === "events").items.map((i) => i.e), [4]);
  again.take();
  await s.room.room.webSocketMessage(again, JSON.stringify({ op: "since", since: 0 }));
  assert.deepEqual(again.sent.find((m) => m.type === "events").items.map((i) => i.e), [1, 2, 3, 4]);
  // 알 수 없는 글자·너무 긴 글자·JSON이 아닌 것은 조용히 무시한다.
  again.take();
  for (const junk of ["null", "pong", "x".repeat(1000), "{bad", JSON.stringify({ op: "nope" }), 5]) await s.room.room.webSocketMessage(again, junk);
  assert.equal(again.sent.length, 0);
});

test("a publish failure never blocks the command (201)", async () => {
  const s = await setup();
  s.env.REALTIME_ROOM.get = () => ({ fetch: () => { throw new Error("boom"); } });
  assert.equal((await call(s.env, "/command", { method: "POST", body: command("c1"), key: s.ai })).status, 201);
  s.env.REALTIME_ROOM.get = () => ({ fetch: async () => { throw new Error("late"); } });
  assert.equal((await call(s.env, "/command", { method: "POST", body: command("c2"), key: s.ai })).status, 201);
});

test("a sixth connection closes the oldest with 4408", async () => {
  const s = await setup();
  const sockets = [];
  for (let n = 0; n < REALTIME.sockets; n += 1) { s.clock.now += 1_000; sockets.push(await open(s)); }
  s.clock.now += 1_000;
  const sixth = await open(s);
  assert.equal(sockets[0].closed?.code, 4408);
  assert.ok(sockets[0].sent.some((m) => m.type === "bye"));
  assert.equal(sixth.closed, null);
  assert.equal(sockets.slice(1).every((ws) => ws.closed === null), true);
});

test("without the binding the command still works and nothing is published", async () => {
  const s = await setup();
  delete s.env.REALTIME_ROOM;
  assert.equal((await call(s.env, "/command", { method: "POST", body: command("c1"), key: s.ai })).status, 201);
});
