// PRL1112A01: 앱이 읽지 못한 결제 문자(payment_rule)와 그 형식을 읽는 규칙(addPaymentRule).
import assert from "node:assert/strict";
import test from "node:test";
import { handle } from "../src/index.js";
import { toolList } from "../src/mcp.js";
import { openapi } from "../src/openapi.js";
import { ACTIONS, PAYMENT_RULE_KINDS, TASK_KINDS } from "../src/validate.js";
import { makeEnv } from "./fakes.mjs";

const ORIGIN = "https://relay.example.com";
const PIN = "135790";
const randomKey = () => Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64url");
const req = (path, method = "GET", body, key) => new Request(`${ORIGIN}${path}`, {
  method,
  headers: { ...(key ? { authorization: `Bearer ${key}` } : {}), "content-type": "application/json" },
  body: body === undefined ? undefined : JSON.stringify(body),
});
const send = (env, ...args) => handle(req(...args), env);
const mcp = (env, key, name, args = {}) => send(env, "/mcp", "POST", { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: args } }, key);
const A = "A1B2C3D4-E5F6-4789-9ABC-DEF012345678";
const SAMPLE = "[Web발신]\n신한카드(1*2*) 승인 홍*동 12,000원(일시불) 11/12 08:41 스타벅스";
const PATTERN = "신한카드\\([\\d*]+\\) 승인 \\S+ (?<amount>[\\d,]+)원\\(\\S+\\) (?<month>\\d+)/(?<day>\\d+) (?<hour>\\d+):(?<minute>\\d+) (?<merchant>.+)";
const rule = (extra = {}) => ({ name: "신한카드", pattern: PATTERN, sample: SAMPLE, ...extra });

async function setup() {
  const { env } = makeEnv();
  const master = randomKey(), reader = randomKey(), writer = randomKey();
  assert.equal((await send(env, "/register", "POST", {}, master)).status, 201);
  assert.equal((await send(env, "/pin", "POST", { pin: PIN }, master)).status, 200);
  const keys = [{ token: reader, scope: "read", expiresAt: null }, { token: writer, scope: "write", expiresAt: null }];
  assert.equal((await send(env, "/keys", "POST", { keys, pin: PIN }, master)).status, 201);
  const post = async (extra) => (await send(env, "/command", "POST",
    { format: "bokki-command", version: 1, id: crypto.randomUUID(), action: "addPaymentRule", ...extra }, writer)).status;
  const queued = async () => {
    const response = await send(env, "/command", "GET", undefined, master);
    return response.status === 204 ? [] : (await response.json()).commands;
  };
  return { env, master, reader, writer, post, queued };
}

test("payment_rule task: the app uploads it and the AI claims it", async () => {
  const { env, master, reader } = await setup();
  assert.ok(TASK_KINDS.includes("payment_rule"));
  const saved = await send(env, "/tasks", "POST", { format: "bokki-tasks", version: 1, tasks: [{ id: A, kind: "payment_rule", text: SAMPLE, date: "2026-11-12" }] }, master);
  assert.equal(saved.status, 201);
  assert.equal((await saved.json()).added, 1);
  const claimed = await (await send(env, "/tasks/claim", "POST", undefined, reader)).json();
  assert.deepEqual(claimed.tasks.map((t) => [t.id, t.kind, t.status]), [[A, "payment_rule", "processing"]]);
  const reply = JSON.stringify(await (await mcp(env, reader, "get_ai_tasks")).json());
  assert.doesNotMatch(reply, /untrusted_user_text\\":\\"payment_rule/, "the kind is not wrapped");
});

test("addPaymentRule: valid rules are queued with only the known fields", async () => {
  const { post, queued } = await setup();
  assert.deepEqual(PAYMENT_RULE_KINDS, ["expense", "income", "ignore"]);
  assert.ok(ACTIONS.includes("addPaymentRule"));
  assert.equal(await post(rule()), 201, "kind defaults to expense");
  assert.equal(await post(rule({ kind: "expense" })), 201);
  assert.equal(await post(rule({ kind: "income", extra: "dropped" })), 201);
  assert.equal(await post(rule({ name: "가".repeat(40), pattern: "(?<amount>" + "a".repeat(290), sample: "s".repeat(1000) })), 201, "at the limits");
  const commands = (await queued()).filter((c) => c.action === "addPaymentRule");
  assert.equal(commands.length, 4);
  assert.deepEqual([commands[0].name, commands[0].pattern, commands[0].sample, commands[0].kind], ["신한카드", PATTERN, SAMPLE, undefined]);
  assert.equal(commands[2].kind, "income");
  assert.equal(commands[2].extra, undefined);
});

test("addPaymentRule: rejects bad lengths, types, kinds and a missing amount group", async () => {
  const { post, queued } = await setup();
  const bad = [
    [rule({ pattern: "(?<amount>\\d+)" + "a".repeat(290) }), "pattern over 300"],
    [rule({ pattern: "" }), "empty pattern"],
    [rule({ pattern: 5 }), "pattern not a string"],
    [rule({ pattern: "신한카드 승인 ([\\d,]+)원" }), "no amount group for the default kind"],
    [rule({ pattern: "신한카드 승인 ([\\d,]+)원", kind: "expense" }), "no amount group for expense"],
    [rule({ pattern: "입금 ([\\d,]+)원", kind: "income" }), "no amount group for income"],
    [rule({ kind: "refund" }), "unknown kind"],
    [rule({ kind: 1 }), "kind not a string"],
    [rule({ name: "" }), "empty name"],
    [rule({ name: "가".repeat(41) }), "name over 40"],
    [rule({ name: undefined }), "name required"],
    [rule({ sample: "" }), "empty sample"],
    [rule({ sample: "s".repeat(1001) }), "sample over 1000"],
    [rule({ sample: undefined }), "sample required"],
  ];
  for (const [value, why] of bad) assert.equal(await post(value), 422, why);
  assert.equal((await queued()).length, 0);
});

test("addPaymentRule: kind ignore needs no amount group", async () => {
  const { post } = await setup();
  assert.equal(await post({ name: "배송 알림", pattern: "\\[CJ대한통운\\] 고객님의 상품이", sample: "[CJ대한통운] 고객님의 상품이 배송되었습니다", kind: "ignore" }), 201);
  assert.equal(await post(rule({ kind: "ignore" })), 201, "an amount group is allowed too");
});

test("MCP add_payment_rule queues the addPaymentRule command; read keys cannot call it", async () => {
  const { env, reader, writer, queued } = await setup();
  const reply = JSON.stringify(await (await mcp(env, writer, "add_payment_rule", rule({ kind: "expense" }))).json());
  assert.doesNotMatch(reply, /isError":true/);
  const [command] = await queued();
  assert.deepEqual([command.action, command.name, command.pattern, command.sample, command.kind], ["addPaymentRule", "신한카드", PATTERN, SAMPLE, "expense"]);
  assert.match(command.id, /^mcp-/);
  const refused = JSON.stringify(await (await mcp(env, writer, "add_payment_rule", rule({ pattern: "승인 ([\\d,]+)원" }))).json());
  assert.match(refused, /isError":true/);
  assert.equal((await queued()).length, 1);
  assert.ok((await (await mcp(env, reader, "add_payment_rule", rule())).json()).error, "write tool");
});

test("add_payment_rule is documented for MCP and OpenAPI", () => {
  const tool = toolList().find((t) => t.name === "add_payment_rule");
  assert.deepEqual(tool.inputSchema.required, ["name", "pattern", "sample"]);
  assert.deepEqual(tool.inputSchema.properties.kind.enum, PAYMENT_RULE_KINDS);
  assert.equal(tool.annotations.destructiveHint, false);
  for (const word of ["(?<amount>", "merchant", "currency", "NSRegularExpression", "sample", "catch-all", "ignore"]) assert.ok(tool.description.includes(word), word);
  assert.match(toolList().find((t) => t.name === "get_ai_tasks").description, /payment_rule:/);
  const command = openapi(ORIGIN).components.schemas.Command;
  assert.ok(command.properties.action.enum.includes("addPaymentRule"));
  assert.match(command.description, /addPaymentRule/);
  for (const name of ["name", "pattern", "sample"]) assert.ok(command.properties[name], name);
  assert.ok(command.properties.kind.enum.includes("ignore"));
});
