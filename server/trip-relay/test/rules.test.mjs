// AIX1114A01 P3: 규칙 저장소. 기한 없이 두고, 바뀔 때마다 버전이 오르고, 앱과 서버가 같은 버전을 본다.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { handle } from "../src/index.js";
import { RULE_TYPES, cleanRule, safePattern } from "../src/rules.js";
import { makeEnv } from "./fakes.mjs";

const fixtures = JSON.parse(readFileSync(new URL("./fixtures/rules.json", import.meta.url), "utf8"));
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
  const master = randomKey(), writer = randomKey(), reader = randomKey();
  assert.equal((await send(env, "/register", "POST", {}, master)).status, 201);
  assert.equal((await send(env, "/pin", "POST", { pin: PIN }, master)).status, 200);
  assert.equal((await send(env, "/keys", "POST", { keys: [{ token: writer, scope: "write", expiresAt: null }, { token: reader, scope: "read", expiresAt: null }], pin: PIN }, master)).status, 201);
  return { env, master, writer, reader };
}
const cafe = { type: "merchant_category", match: { contains: ["빵집"] }, result: { category: "cafe" } };

test("rule shapes: the shared fixtures (the app's evaluator reads the same file)", () => {
  assert.deepEqual([...new Set(fixtures.valid.map((r) => r.type))].sort(), Object.keys(RULE_TYPES).sort(), "every rule type has a valid example");
  for (const rule of fixtures.valid) assert.ok(cleanRule(rule), JSON.stringify(rule));
  for (const { why, rule } of fixtures.invalid) assert.equal(cleanRule(rule), null, why);
  assert.deepEqual(cleanRule({ ...cafe, extra: 1, match: { ...cafe.match, junk: true } }), { type: "merchant_category", appliesTo: 1, match: { contains: ["빵집"] }, result: { category: "cafe" } }, "unknown fields are dropped");
  assert.equal(safePattern("(?<amount>[\\d,]+)원"), true);
  assert.equal(safePattern("x".repeat(301)), false);
});

test("rules: AI saves, version rises, 304 when unchanged, bodies are not readable in storage", async () => {
  const { env, master, writer, reader } = await setup();
  const empty = await (await send(env, "/rules", "GET", undefined, reader)).json();
  assert.deepEqual([empty.format, empty.version, empty.rules], ["bokki-rules", 0, []]);
  assert.equal((await send(env, "/rules", "POST", { rules: [cafe] }, reader)).status, 403, "a read key cannot save");
  assert.equal((await send(env, "/rules", "POST", { rules: [{ type: "own_account", match: { name: "110123456789" } }] }, writer)).status, 422);
  const saved = await (await send(env, "/rules", "POST", { rules: [cafe, { ...fixtures.valid[0], taskId: "task-1" }] }, writer)).json();
  assert.equal(saved.version, 1);
  assert.equal(saved.ids.length, 2);
  const listed = await (await send(env, "/rules", "GET", undefined, master)).json();
  assert.deepEqual(listed.rules.map((r) => [r.type, r.enabled, r.source.by, r.source.taskId]), [["merchant_category", true, "ai", undefined], ["payment_text", true, "ai", "task-1"]]);
  assert.equal((await send(env, "/rules?since=1", "GET", undefined, master)).status, 304);
  assert.equal((await send(env, "/rules?since=0", "GET", undefined, master)).status, 200);
  const dump = JSON.stringify([...env.USER_STATE.instances.values()].map((i) => [...i.storage.map.entries()]));
  assert.equal(dump.includes("빵집"), false, "rule bodies are sealed");
});

test("rules: the user's edits win — disable survives a re-save, a deleted id is refused, AI cannot touch user rules", async () => {
  const { env, master, writer } = await setup();
  const { ids: [id] } = await (await send(env, "/rules", "POST", { rules: [cafe] }, writer)).json();
  const off = await (await send(env, "/rules/ops", "POST", { baseVersion: 1, ops: [{ op: "disable", id }] }, master)).json();
  assert.deepEqual([off.version, off.stale], [2, false]);
  await send(env, "/rules", "POST", { rules: [{ ...cafe, id }] }, writer);
  let listed = await (await send(env, "/rules", "GET", undefined, master)).json();
  assert.deepEqual(listed.rules.map((r) => r.enabled), [false], "still off after the AI saved it again");
  assert.equal((await send(env, "/rules/ops", "POST", { ops: [{ op: "enable", id }] }, writer)).status, 403, "ops are the app's");
  const gone = await (await send(env, "/rules/ops", "POST", { baseVersion: 1, ops: [{ op: "delete", id }] }, master)).json();
  assert.equal(gone.stale, true, "the app was behind and should fetch again");
  const again = await (await send(env, "/rules", "POST", { rules: [{ ...cafe, id }] }, writer)).json();
  assert.deepEqual([again.ids, again.refused], [[], [id]]);
  // 사용자가 만든 규칙.
  const mine = await (await send(env, "/rules/ops", "POST", { ops: [{ op: "put", rule: { id: "u-1", type: "skip_word", match: { word: "광고" } } }] }, master)).json();
  assert.ok(mine.ok);
  assert.equal((await (await send(env, "/rules?ids=u-1", "DELETE", undefined, writer)).json()).removed, 0, "an AI cannot delete a user rule");
  const overwrite = await (await send(env, "/rules", "POST", { rules: [{ id: "u-1", type: "skip_word", match: { word: "이벤트" } }] }, writer)).json();
  assert.deepEqual(overwrite.refused, ["u-1"]);
  listed = await (await send(env, "/rules", "GET", undefined, master)).json();
  assert.deepEqual(listed.rules.map((r) => [r.id, r.source.by, r.match.word]), [["u-1", "user", "광고"]]);
});

test("rules: the app acks the version it applied and what it skipped; MCP tools", async () => {
  const { env, master, writer, reader } = await setup();
  const put = await (await mcp(env, writer, "put_rules", { rules: [cafe] })).json();
  assert.match(put.result.content[0].text, /"version":1/);
  assert.equal((await send(env, "/rules/ack", "POST", { version: 1, engine: 1, skipped: ["r_x"] }, writer)).status, 403);
  assert.equal((await send(env, "/rules/ack", "POST", { version: 1, engine: 1, skipped: ["r_x"] }, master)).status, 200);
  const got = JSON.stringify(await (await mcp(env, reader, "get_rules")).json());
  assert.match(got, /merchant_category/);
  assert.match(got, /skipped/);
  const tools = (await (await send(env, "/mcp", "POST", { jsonrpc: "2.0", id: 1, method: "tools/list" }, reader)).json()).result.tools.map((t) => t.name);
  assert.ok(tools.includes("get_rules") && !tools.includes("put_rules"), "a read key sees only the read tool");
});
