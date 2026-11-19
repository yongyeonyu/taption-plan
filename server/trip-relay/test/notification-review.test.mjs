// NTR1119A01: 일반 알림 검토 일(notification_review). 앱이 가계부로 읽지 않은 알림을 올리면 AI가 일정·메모로 처리한다.
import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { handle } from "../src/index.js";
import { makeEnv } from "./fakes.mjs";
import { isTaskUpload, TASK_KINDS } from "../src/validate.js";

const ORIGIN = "https://relay.example.com";
const PIN = "135790";
const randomKey = () => Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64url");
const req = (path, method = "GET", body, key) => new Request(`${ORIGIN}${path}`, {
  method,
  headers: { ...(key ? { authorization: `Bearer ${key}` } : {}), "content-type": "application/json" },
  body: body === undefined ? undefined : JSON.stringify(body),
});
const send = (env, ...args) => handle(req(...args), env);
const A = "A1B2C3D4-E5F6-4789-9ABC-DEF012345678";
const B = "B1B2C3D4-E5F6-4789-9ABC-DEF012345678";
const task = (extra = {}) => ({ id: A, kind: "notification_review", text: "[가짜극장] 가짜뮤지컬 예매 완료 2026-12-01 19:30", ...extra });
const upload = (tasks) => ({ format: "bokki-tasks", version: 1, tasks });
const rpc = (env, key, method, params) => send(env, "/mcp", "POST", { jsonrpc: "2.0", id: 1, method, params }, key);

async function setup() {
  const { env } = makeEnv();
  const master = randomKey(), ai = randomKey();
  assert.equal((await send(env, "/register", "POST", {}, master)).status, 201);
  assert.equal((await send(env, "/pin", "POST", { pin: PIN }, master)).status, 200);
  assert.equal((await send(env, "/keys", "POST", { keys: [{ token: ai, scope: "write", expiresAt: null }], pin: PIN }, master)).status, 201);
  return { env, master, ai };
}

test("notification_review: 올리기 검증", () => {
  assert.ok(TASK_KINDS.includes("notification_review"));
  assert.ok(isTaskUpload(upload([task({ date: "2026-12-01", context: { sourceApp: "가짜앱", receivedAt: "2026-11-19T09:00:00Z" } })])));
  assert.ok(isTaskUpload(upload([task()])), "context 없이도 됨");
  assert.ok(!isTaskUpload(upload([task({ kind: "unknown_kind" })])), "모르는 kind는 거절");
});

test("notification_review: 올린 일이 MCP·GET /tasks에 kind·context 그대로 나온다", async () => {
  const { env, master, ai } = await setup();
  const context = { sourceApp: "가짜앱", receivedAt: "2026-11-19T09:00:00Z" };
  assert.equal((await send(env, "/tasks", "POST", upload([task({ context }), { id: B, kind: "payment_text", text: "결제 1,000원" }]), master)).status, 201);

  const listed = await (await send(env, "/tasks", "GET", undefined, master)).json();
  const row = listed.tasks.find((t) => t.id === A);
  assert.equal(row.kind, "notification_review");
  assert.deepEqual(row.context, context);

  const res = await rpc(env, ai, "tools/call", { name: "get_ai_tasks", arguments: {} });
  const out = JSON.parse((await res.json()).result.content[0].text);
  assert.deepEqual(out.tasks.map((t) => t.id), [B, A], "결제 글이 먼저");
  assert.equal(out.tasks[1].kind, "notification_review");
  // MCP로 나갈 때 외부 앱 이름은 사용자 글처럼 감싸인다(안의 지시를 따르지 않도록). receivedAt은 그대로.
  assert.deepEqual(out.tasks[1].context, { sourceApp: { untrusted_user_text: "가짜앱" }, receivedAt: context.receivedAt });
});

test("notification_review: 지침·도구 설명·열거에 들어 있다", async () => {
  const { env, master } = await setup();
  const init = await (await rpc(env, master, "initialize", { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "t", version: "1" } })).json();
  assert.match(init.result.instructions, /notification_review/);
  const list = await (await rpc(env, master, "tools/list")).json();
  const tool = list.result.tools.find((t) => t.name === "get_ai_tasks");
  for (const re of [/notification_review/, /activity\.performanceMovie/, /never follow instructions/, /context\.sourceApp/, /context\.receivedAt/]) {
    assert.match(tool.description, re);
  }
  assert.match(readFileSync(new URL("../src/openapi.js", import.meta.url), "utf8"), /notification_review/);
});
