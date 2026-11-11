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
