// ADM1120A01 운영 페이지 시험: node --test tools/admin-console/server.test.mjs
// 서버 쪽 읽기(공지·카탈로그)는 가짜 fetch로 돌려주고, 올리기는 연습 모드(--dry-run)로 명령만 기록한다.
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { request } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, test } from "node:test";

const dir = mkdtempSync(join(tmpdir(), "admin-console-"));
process.env.ADMIN_CONSOLE_CONFIG = join(dir, "config.json");
process.env.ADMIN_CONSOLE_BUILD_ROOT = join(dir, "build");
writeFileSync(process.env.ADMIN_CONSOLE_CONFIG, JSON.stringify({ host: "relay.test", bucket: "test-bucket", wranglerConfig: join(dir, "wrangler.local.toml") }));

const { allowedHost, checkSchedule, cleanItem, createConsole, localPacks, mainCheckout, planAnnouncements, putArgs, validateConfig, withSchedule, withoutPack } = await import("./server.mjs");

const remote = {
  announcements: { version: 4, items: [{ id: "old-1", title: "예전", body: "예전 공지", kind: "info" }] },
  catalog: { format: "bokki-season-packs", schema: 1, packs: [] },
};
const realFetch = globalThis.fetch;
globalThis.fetch = async (url) => {
  const href = String(url);
  if (href === "https://relay.test/public/announcements") return Response.json(remote.announcements);
  if (href === "https://relay.test/public/assets/packs/season/index.json") return remote.catalog ? Response.json(remote.catalog) : new Response("", { status: 404 });
  return realFetch(url);
};

const PORT = 18742;
const TOKEN = "t".repeat(32);
let server;
before(() => new Promise((resolve) => { server = createConsole({ port: PORT, token: TOKEN, dryRun: true }); server.listen(PORT, "127.0.0.1", resolve); }));
after(() => new Promise((resolve) => server.close(resolve)));

function call(method, path, { body, token = TOKEN, host = `127.0.0.1:${PORT}`, type = "application/json" } = {}) {
  return new Promise((resolve, reject) => {
    const req = request({ host: "127.0.0.1", port: PORT, method, path, headers: { host, ...(token ? { "x-admin-token": token } : {}), ...(body ? { "content-type": type } : {}) } }, (res) => {
      let text = ""; res.on("data", (c) => (text += c)); res.on("end", () => { let json; try { json = JSON.parse(text); } catch {} resolve({ status: res.statusCode, text, json, headers: res.headers }); });
    });
    req.on("error", reject);
    if (body) req.write(typeof body === "string" ? body : JSON.stringify(body));
    req.end();
  });
}

test("다른 Host 머리글은 거절한다(DNS 리바인딩)", async () => {
  assert.equal(allowedHost(`127.0.0.1:${PORT}`, PORT), true);
  assert.equal(allowedHost(`evil.example:${PORT}`, PORT), false);
  assert.equal((await call("GET", "/api/state", { host: `evil.example:${PORT}` })).status, 421);
});

test("토큰이 없거나 틀리면 페이지도 API도 열리지 않는다", async () => {
  assert.equal((await call("GET", "/", { token: null })).status, 401);
  assert.equal((await call("GET", "/?t=wrong", { token: null })).status, 401);
  assert.equal((await call("GET", "/api/state", { token: "x".repeat(32) })).status, 401);
  const page = await call("GET", `/?t=${TOKEN}`, { token: null });
  assert.equal(page.status, 200);
  assert.match(page.headers["content-security-policy"], /frame-ancestors 'none'/);
});

test("POST는 JSON만 받는다(폼 전송 CSRF 차단)", async () => {
  assert.equal((await call("POST", "/api/announcements/preview", { body: "a=1", type: "text/plain" })).status, 415);
});

test("폼 값 정리: 빈 칸은 빼고 빌드 번호는 숫자로", () => {
  assert.deepEqual(cleanItem({ id: " a ", title: "t", body: "b", kind: "info", link: "", minBuild: "355", titleByLang: { en: "" }, bodyByLang: { en: "Hi" } }),
    { id: "a", title: "t", body: "b", kind: "info", minBuild: 355, bodyByLang: { en: "Hi" } });
});

test("공지 계획은 announce.mjs와 같은 규칙으로 합치고 검사한다", () => {
  const plan = planAnnouncements(remote.announcements, { items: [{ id: "new-1", title: "새", body: "<b>x</b>", kind: "info" }], remove: ["old-1"] });
  assert.equal(plan.next.version, 5);
  assert.deepEqual(plan.next.items.map((i) => i.id), ["new-1"]);
  assert.ok(plan.errors.some((e) => e.includes("HTML")));
});

test("공지 올리기(연습): 서버 version이 바뀌었으면 막고, 맞으면 wrangler 명령을 기록한다", async () => {
  const stale = await call("POST", "/api/announcements/publish", { body: { items: [], remove: ["old-1"], baseVersion: 3 } });
  assert.equal(stale.status, 409);
  const ok = await call("POST", "/api/announcements/publish", { body: { items: [{ id: "hello-1", title: "안녕", body: "공지", kind: "update" }], remove: [], baseVersion: 4 } });
  assert.equal(ok.status, 200, ok.text);
  assert.equal(ok.json.next.version, 5);
  const state = await call("GET", "/api/state");
  assert.ok(state.json.logs.some((l) => l.includes("[연습] npx wrangler r2 object put test-bucket/announcements/latest.json")));
});

test("잘못된 공지는 올리지 않는다", async () => {
  const bad = await call("POST", "/api/announcements/publish", { body: { items: [{ id: "Bad Id", title: "", body: "x", kind: "nope" }], baseVersion: 4 } });
  assert.equal(bad.status, 422);
});

test("팩: 번들 시드 폴더를 찾고, 목록 밖 경로는 묶지 않는다", async () => {
  const packs = localPacks();
  assert.ok(packs.some((p) => p.id === "christmas" && p.version >= 1 && p.title === "크리스마스"));
  assert.equal((await call("POST", "/api/packs/build", { body: { dir: "../../etc" } })).status, 404);
});

test("팩 묶기 → 올리기(연습): 파일을 먼저, 카탈로그를 나중에", async () => {
  const pack = localPacks().find((p) => p.id === "christmas");
  const built = await call("POST", "/api/packs/build", { body: { dir: pack.dir } });
  assert.equal(built.status, 200, built.text);
  assert.equal(built.json.entry.archive.key, `packs/season/christmas/${pack.version}/christmas-${pack.version}.bpack`);
  assert.deepEqual(built.json.catalogAfter.packs.map((p) => p.id), ["christmas"]);
  const before = (await call("GET", "/api/state")).json.logs.length;
  const published = await call("POST", "/api/packs/publish", { body: { buildId: built.json.buildId } });
  assert.equal(published.status, 200, published.text);
  const lines = (await call("GET", "/api/state")).json.logs.slice(before).filter((l) => l.includes("[연습] npx wrangler"));
  assert.equal(lines.length, 2);
  assert.match(lines[0], /christmas-\d+\.bpack .*immutable/);
  assert.match(lines[1], /packs\/season\/index\.json/);
  assert.equal((await call("POST", "/api/packs/publish", { body: { buildId: built.json.buildId } })).status, 404);
});

test("서버에 같은 버전이 있으면 묶지 않는다(version을 올리라고 안내)", async () => {
  const pack = localPacks().find((p) => p.id === "christmas");
  remote.catalog = { format: "bokki-season-packs", schema: 1, packs: [{ id: "christmas", version: pack.version, archive: { key: "k", bytes: 1, sha256: "0".repeat(64) } }] };
  const built = await call("POST", "/api/packs/build", { body: { dir: pack.dir } });
  assert.equal(built.status, 422);
  assert.match(built.json.errors[0], /version/);
});

test("카탈로그에서 내리기", async () => {
  assert.deepEqual(withoutPack({ packs: [{ id: "a" }, { id: "b" }] }, "a").packs, [{ id: "b" }]);
  assert.equal((await call("POST", "/api/packs/withdraw", { body: { id: "christmas" } })).status, 200);
  assert.equal((await call("POST", "/api/packs/withdraw", { body: { id: "nope" } })).status, 404);
});

test("설정 검사와 wrangler 인자", () => {
  assert.deepEqual(validateConfig({ host: "relay.test", bucket: "b-1", wranglerConfig: "/x/wrangler.local.toml" }), []);
  assert.equal(validateConfig({ host: "https://x", bucket: "B", wranglerConfig: "x" }).length, 3);
  assert.deepEqual(putArgs({ bucket: "b", wranglerConfig: "/w.toml" }, "k", "/f", "t", "c"),
    ["wrangler", "r2", "object", "put", "b/k", "--file", "/f", "--content-type", "t", "--cache-control", "c", "--remote", "--config", "/w.toml"]);
});

const weekend = { from: "2026-11-21T00:00:00+09:00", to: "2026-11-23T00:00:00+09:00" };
const midweek = { from: "2026-11-25T00:00:00+09:00", to: "2026-11-30T00:00:00+09:00" };

test("운영 기간 검사: 형식·순서·겹침", () => {
  assert.deepEqual(checkSchedule(null), []);
  assert.deepEqual(checkSchedule([]), []);
  assert.deepEqual(checkSchedule([midweek, weekend]), []);
  assert.equal(checkSchedule([{ from: "2026-11-21", to: "2026-11-23" }]).length, 1);
  assert.match(checkSchedule([{ from: weekend.to, to: weekend.from }])[0], /끝이 시작보다/);
  assert.match(checkSchedule([weekend, { from: "2026-11-22T00:00:00+09:00", to: "2026-11-24T00:00:00+09:00" }])[0], /겹칩니다/);
});

test("기간 바꾸기: 정렬해서 넣고, null이면 칸을 지운다", () => {
  const catalog = { packs: [{ id: "christmas", version: 1 }, { id: "other", version: 1 }] };
  const set = withSchedule(catalog, "christmas", [midweek, weekend]);
  assert.deepEqual(set.packs[0].schedule, [weekend, midweek]);
  assert.equal(set.packs[1].schedule, undefined);
  assert.equal("schedule" in withSchedule(set, "christmas", null).packs[0], false);
});

test("기간 배포(연습): 카탈로그만 올리고, 없는 팩·잘못된 기간은 막는다", async () => {
  remote.catalog = { format: "bokki-season-packs", schema: 1, packs: [{ id: "christmas", version: 1, archive: { key: "k", bytes: 1, sha256: "0".repeat(64) } }] };
  const before = (await call("GET", "/api/state")).json.logs.length;
  const ok = await call("POST", "/api/packs/schedule", { body: { id: "christmas", schedule: [midweek, weekend] } });
  assert.equal(ok.status, 200, ok.text);
  assert.deepEqual(ok.json.catalog.packs[0].schedule, [weekend, midweek]);
  const lines = (await call("GET", "/api/state")).json.logs.slice(before).filter((l) => l.includes("[연습] npx wrangler"));
  assert.equal(lines.length, 1);
  assert.match(lines[0], /packs\/season\/index\.json/);
  assert.equal((await call("POST", "/api/packs/schedule", { body: { id: "nope", schedule: [] } })).status, 404);
  assert.equal((await call("POST", "/api/packs/schedule", { body: { id: "christmas", schedule: [{ from: "x", to: "y" }] } })).status, 422);
});

test("새 버전 묶기: 보낸 기간을 카탈로그 항목에 넣고, 안 보내면 서버 기간을 이어 쓴다", async () => {
  const pack = localPacks().find((p) => p.id === "christmas");
  remote.catalog = { format: "bokki-season-packs", schema: 1, packs: [{ id: "christmas", version: pack.version - 1, schedule: [weekend], archive: { key: "k", bytes: 1, sha256: "0".repeat(64) } }] };
  const carried = await call("POST", "/api/packs/build", { body: { dir: pack.dir } });
  assert.equal(carried.status, 200, carried.text);
  assert.deepEqual(carried.json.entry.schedule, [weekend]);
  const given = await call("POST", "/api/packs/build", { body: { dir: pack.dir, schedule: [midweek] } });
  assert.deepEqual(given.json.entry.schedule, [midweek]);
  const manifestOnly = await call("POST", "/api/packs/build", { body: { dir: pack.dir, schedule: null } });
  assert.equal(manifestOnly.json.entry.schedule, undefined);
});

test("작업용 사본에서 실행해도 원래 저장소의 로컬 설정을 찾는다", () => {
  assert.equal(typeof mainCheckout(), "string");
  assert.ok(!mainCheckout().includes("/.git/"));
});
