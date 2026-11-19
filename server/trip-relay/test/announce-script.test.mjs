import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { check, merge, preview, problems, specFrom } from "../scripts/announce.mjs";

const item = (extra = {}) => ({ id: "test-notice", title: "공지 테스트", body: "안녕하세요", kind: "info", ...extra });

test("a valid item passes and each schema rule is caught", () => {
  assert.deepEqual(problems(item()), []);
  assert.deepEqual(problems(item({ startsAt: "2026-11-25T09:00+09:00", expiresAt: "2026-11-27T09:00:00Z", minBuild: 350, maxBuild: null, link: "https://example.com/a", titleByLang: { en: "Test" }, bodyByLang: { "zh-Hant": "你好" } })), []);
  const bad = [
    item({ id: "Bad Id" }), item({ id: "" }), item({ title: "" }), item({ title: "가".repeat(101) }), item({ body: "나".repeat(2001) }), item({ body: "<b>굵게</b>" }),
    item({ kind: "maintenance" }), item({ startsAt: "내일" }), item({ expiresAt: "2026-11-27" }), item({ minBuild: "350" }), item({ link: "http://example.com" }),
    item({ link: "https://" + "a".repeat(300) }), item({ titleByLang: { en: 5 } }), item({ note: "모르는 필드" }), null,
  ];
  for (const value of bad) assert.ok(problems(value).length > 0, JSON.stringify(value));
});

test("merge replaces by id, adds new ones first, removes ids and raises the version", () => {
  const current = { version: 3, items: [item({ id: "a", title: "A" }), item({ id: "b", title: "B" })] };
  const next = merge(current, { items: [item({ id: "b", title: "B2" }), item({ id: "c", title: "C" })], remove: ["a"] });
  assert.equal(next.version, 4);
  assert.deepEqual(next.items.map((entry) => [entry.id, entry.title]), [["c", "C"], ["b", "B2"]]);
  assert.deepEqual(merge(undefined, { items: [item()] }), { version: 1, items: [item()] }, "지금 공지가 없으면 version 1");
  assert.deepEqual(merge({ version: 0, items: [] }, { items: [], remove: ["x"] }).items, []);
});

test("check rejects duplicate ids, too many items and a bad version", () => {
  assert.deepEqual(check({ version: 2, items: [item()] }), []);
  assert.ok(check({ version: 2, items: [item(), item()] }).some((message) => message.includes("겹침")));
  assert.ok(check({ version: 2, items: Array.from({ length: 51 }, (_, index) => item({ id: `n${index}` })) }).some((message) => message.includes("최대")));
  assert.ok(check({ version: 0, items: [] }).length > 0);
});

test("preview marks added, changed, unchanged and removed items", () => {
  const current = { version: 1, items: [item({ id: "a" }), item({ id: "b", title: "옛" }), item({ id: "gone" })] };
  const next = { version: 2, items: [item({ id: "new" }), item({ id: "a" }), item({ id: "b", title: "새" })] };
  const text = preview(current, next);
  assert.match(text, /\[추가\] new/); assert.match(text, /\[그대로\] a/); assert.match(text, /\[바뀜\] b/); assert.match(text, /\[내림\] gone/);
  assert.match(text, /version 1 → 2/);
});

test("quick options build one item and a spec file is read and combined with --remove", () => {
  const quick = specFrom({ title: "점검", body: "내용", kind: "warning", id: "maintenance", expiresAt: "2026-12-01T00:00+09:00", remove: ["old"] }, new Date("2026-11-19T10:00:00Z"));
  assert.deepEqual(quick.items, [{ id: "maintenance", title: "점검", body: "내용", kind: "warning", expiresAt: "2026-12-01T00:00+09:00" }]);
  assert.deepEqual(quick.remove, ["old"]);
  const auto = specFrom({ title: "a", body: "b", remove: [] }, new Date("2026-11-19T10:00:00Z"));
  assert.match(auto.items[0].id, /^notice-261119-\d{4}$/);
  assert.deepEqual(problems(auto.items[0]), [], "만든 id도 규칙에 맞다");
  const dir = mkdtempSync(join(tmpdir(), "announce-test-"));
  const file = join(dir, "spec.json");
  writeFileSync(file, JSON.stringify({ items: [item({ id: "from-file" })], remove: ["x"] }));
  const spec = specFrom({ spec: file, remove: ["y"] });
  assert.deepEqual(spec.items.map((entry) => entry.id), ["from-file"]);
  assert.deepEqual(spec.remove, ["x", "y"]);
  assert.throws(() => { writeFileSync(file, "[]"); specFrom({ spec: file, remove: [] }); });
});
