// AIX1114A01 P1: 동작 등록부. 새 동작은 actions.js 한 곳에서 검증·도구·목록이 만들어진다.
import assert from "node:assert/strict";
import test from "node:test";
import { f, makeRegistry, registry } from "../src/actions.js";
import { ACTIONS, COMMAND_FIELDS } from "../src/validate.js";

const sample = () => makeRegistry().add("setFxRate", {
  tool: "set_fx_rate", title: "Set an exchange rate", description: "KRW per one unit of a currency.", destructive: false, since: 340,
  fields: { currency: f.oneOf(["USD", "JPY"], "ISO 4217").required_(), krwPerUnit: f.amount(1e7, "KRW per unit").required_(), note: f.text(40, "Optional note") },
  check: (v) => v.currency !== "JPY" || v.krwPerUnit < 100,
});

test("registry: validates required and optional fields and the extra check", () => {
  const reg = sample();
  const ok = { action: "setFxRate", currency: "USD", krwPerUnit: 1400 };
  assert.equal(reg.validate(ok), true);
  assert.equal(reg.validate({ ...ok, note: "오늘 환율" }), true);
  assert.equal(reg.validate({ ...ok, note: "" }), false, "an empty optional text is refused");
  assert.equal(reg.validate({ ...ok, note: null }), true, "null counts as not given");
  assert.equal(reg.validate({ action: "setFxRate", currency: "USD" }), false, "missing required");
  assert.equal(reg.validate({ ...ok, currency: "EUR" }), false);
  assert.equal(reg.validate({ ...ok, krwPerUnit: -1 }), false);
  assert.equal(reg.validate({ action: "setFxRate", currency: "JPY", krwPerUnit: 900 }), false, "the action's own check");
  assert.equal(reg.validate({ action: "somethingElse" }), undefined, "unknown actions fall through to the old validator");
});

test("registry: field kinds", () => {
  assert.equal(f.date().check("2026-11-14"), true);
  assert.equal(f.date().check("2026-13-01"), false);
  assert.equal(f.time().check("23:59"), true);
  assert.equal(f.time().check("24:00"), false);
  assert.equal(f.id().check("abc-1.2:3_x"), true);
  assert.equal(f.id().check("a b"), false);
  assert.equal(f.integer(1, 5).check(3), true);
  assert.equal(f.integer(1, 5).check(3.5), false);
  assert.equal(f.flag().check(false), true);
  assert.equal(f.list(f.text(5), 2).check(["a", "b"]), true);
  assert.equal(f.list(f.text(5), 2).check(["a", "b", "c"]), false);
  assert.equal(f.list(f.text(5), 2).check(["toolong"]), false);
  assert.equal(f.text(3).check("​​"), false, "invisible characters alone are empty");
});

test("registry: tools, manifest and the minimum app build", () => {
  const reg = sample();
  const [tool] = reg.tools();
  assert.deepEqual([tool.name, tool.action, tool.destructive, tool.required], ["set_fx_rate", "setFxRate", false, ["currency", "krwPerUnit"]]);
  assert.deepEqual(Object.keys(tool.properties), ["currency", "krwPerUnit", "note"]);
  assert.deepEqual(reg.manifest().actions[0], { action: "setFxRate", tool: "set_fx_rate", destructive: false, since: 340, fields: ["currency", "krwPerUnit", "note"], required: ["currency", "krwPerUnit"] });
  assert.equal(reg.needsBuild("setFxRate", "338"), 340);
  assert.equal(reg.needsBuild("setFxRate", "340"), null);
  assert.equal(reg.needsBuild("setFxRate", undefined), null, "an unknown build is not blocked");
  assert.equal(reg.needsBuild("nope", "1"), null);
});

test("registry: refuses duplicates, bad names and reserved fields", () => {
  const reg = sample();
  assert.throws(() => reg.add("setFxRate", { tool: "set_fx_rate", fields: {} }), /duplicate/);
  assert.throws(() => makeRegistry().add("Bad", { tool: "bad_tool", fields: {} }), /bad action name/);
  assert.throws(() => makeRegistry().add("fine", { tool: "BadTool", fields: {} }), /bad action name/);
  assert.throws(() => makeRegistry().add("fine", { tool: "fine_tool", fields: { id: f.id() } }), /reserved/);
});

test("registry: every registered action is a command action with its fields", () => {
  for (const name of registry.names()) {
    assert.ok(ACTIONS.includes(name), name);
    assert.deepEqual(COMMAND_FIELDS[name], registry.fields(name));
  }
});
