// REV1117A02: 공통 규칙 관리 스크립트(scripts/shared-rules/admin.mjs)의 초안 흐름.
// 내보낸 뒤 남은 초안이나 서버 판보다 오래된 초안이 거둔 규칙을 다시 내보내지 않는지 본다.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const script = fileURLToPath(new URL("../../../scripts/shared-rules/admin.mjs", import.meta.url));
const fake = fileURLToPath(new URL("./shared-admin-fetch.mjs", import.meta.url));
const rule = (id, word, category) => ({ id, type: "merchant_category", match: { contains: [word] }, result: { category } });
const candidate = (fp, word, category) => ({ fp, count: 3, type: "merchant_category", match: { contains: [word] }, result: { category } });
const bundle = (version, rules) => JSON.stringify({ format: "bokki-shared-rules", version, engine: 1, issuedAt: "2026-11-17", rules });

function workspace(version, rules) {
  const home = mkdtempSync(join(tmpdir(), "shared-admin-"));
  mkdirSync(join(home, ".bokki-shared-rules"), { recursive: true });
  writeFileSync(join(home, ".bokki-shared-rules", "admin.json"), JSON.stringify({ host: "relay.test", token: "t" }));
  const stateFile = join(home, "server.json");
  writeFileSync(stateFile, JSON.stringify({ version, payload: bundle(version, rules), candidates: [] }));
  const run = (...args) => spawnSync(process.execPath, ["--import", fake, script, ...args], {
    env: { ...process.env, HOME: home, SHARED_ADMIN_FAKE: stateFile }, encoding: "utf8",
  });
  const server = () => JSON.parse(readFileSync(stateFile, "utf8"));
  const offer = (candidates) => writeFileSync(stateFile, JSON.stringify({ ...server(), candidates }));
  assert.equal(run("keygen").status, 0);
  return { run, server, offer, ids: () => JSON.parse(server().payload).rules.map((r) => r.id).sort() };
}

test("shared admin: a published draft does not bring back a rule withdrawn later", () => {
  const w = workspace(1, [rule("s_a", "가나다", "food"), rule("s_b", "라마바", "cafe")]);
  w.offer([candidate("c".repeat(32), "사아자", "shopping")]);
  assert.equal(w.run("candidates").status, 0);
  assert.equal(w.run("draft", "1").status, 0);
  assert.equal(w.run("publish").status, 0);
  assert.deepEqual(w.ids(), ["s_a", "s_b", "sr_cccccccccccc"]);
  assert.equal(w.run("withdraw", "s_a").status, 0);
  assert.deepEqual(w.ids(), ["s_b", "sr_cccccccccccc"]);

  w.offer([candidate("d".repeat(32), "차카타", "living")]);
  assert.equal(w.run("candidates").status, 0);
  assert.equal(w.run("draft", "1").status, 0);
  assert.equal(w.run("publish").status, 0);
  assert.equal(w.server().version, 4);
  assert.deepEqual(w.ids(), ["s_b", "sr_cccccccccccc", "sr_dddddddddddd"]);
});

test("shared admin: a draft made before a withdraw is refused instead of published", () => {
  const w = workspace(1, [rule("s_a", "가나다", "food")]);
  w.offer([candidate("e".repeat(32), "파하가", "health")]);
  assert.equal(w.run("candidates").status, 0);
  assert.equal(w.run("draft", "1").status, 0);
  assert.equal(w.run("withdraw", "s_a").status, 0);
  assert.equal(w.server().version, 2);

  const refused = w.run("publish");
  assert.notEqual(refused.status, 0);
  assert.match(refused.stderr, /초안/);
  assert.equal(w.server().version, 2);
  assert.deepEqual(w.ids(), []);
});
