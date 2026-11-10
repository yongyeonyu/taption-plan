import assert from "node:assert/strict";
import test from "node:test";
import { handle, isTripPlan, storageKey } from "../src/index.js";

class MemoryKV {
  constructor() { this.map = new Map(); this.options = new Map(); }
  async get(key) { return this.map.get(key) ?? null; }
  async put(key, value, options) { this.map.set(key, value); this.options.set(key, options); }
  async delete(key) { this.map.delete(key); }
}

const token = "A".repeat(43);
const plan = { format: "bokki-trip", version: 1, tripId: "trip-1", title: "방콕", items: [{ id: "i1", type: "sight", title: "왓 아룬", start: "2026-12-02T09:00+07:00" }] };
const call = (method, body, key = token) => new Request("https://relay.example.com/plan", {
  method,
  headers: key ? { authorization: `Bearer ${key}`, "content-type": "application/json" } : {},
  body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body),
});

test("post then get then delete one plan per key, stored under a hash only", async () => {
  const env = { PLANS: new MemoryKV() };
  assert.equal((await handle(call("POST", plan), env)).status, 201);
  const stored = [...env.PLANS.map.keys()];
  assert.deepEqual(stored, [await storageKey(token)]);
  assert.ok(!stored[0].includes(token), "raw key is never stored");
  assert.equal(env.PLANS.options.get(stored[0]).expirationTtl, 3 * 24 * 60 * 60);
  const fetched = await handle(call("GET"), env);
  assert.equal(fetched.status, 200);
  assert.deepEqual(await fetched.json(), plan);
  assert.equal((await handle(call("DELETE"), env)).status, 204);
  assert.equal((await handle(call("GET"), env)).status, 204);
});

test("other keys cannot read a plan", async () => {
  const env = { PLANS: new MemoryKV() };
  await handle(call("POST", plan), env);
  assert.equal((await handle(call("GET", undefined, "B".repeat(43)), env)).status, 204);
});

test("rejects missing or malformed keys, non-trip bodies and large bodies", async () => {
  const env = { PLANS: new MemoryKV() };
  assert.equal((await handle(call("GET", undefined, null), env)).status, 401);
  assert.equal((await handle(call("GET", undefined, "short"), env)).status, 401);
  assert.equal((await handle(call("POST", "not json"), env)).status, 400);
  assert.equal((await handle(call("POST", { format: "other" }), env)).status, 422);
  assert.equal((await handle(call("POST", { ...plan, note: "x".repeat(70 * 1024) }), env)).status, 413);
  assert.equal((await handle(new Request("https://relay.example.com/other"), env)).status, 404);
  assert.equal(env.PLANS.map.size, 0);
});

test("trip plan contract matches the app", () => {
  assert.ok(isTripPlan(plan));
  assert.ok(!isTripPlan({ ...plan, version: 2 }));
  assert.ok(!isTripPlan({ ...plan, items: [] }));
});
