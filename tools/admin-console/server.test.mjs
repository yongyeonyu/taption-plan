// ADM1120A01 운영 페이지 시험: node --test tools/admin-console/server.test.mjs
// 서버 쪽 읽기(공지·카탈로그)는 가짜 fetch로 돌려주고, 올리기는 연습 모드(--dry-run)로 명령만 기록한다.
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { request } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, test } from "node:test";

const dir = mkdtempSync(join(tmpdir(), "admin-console-"));
process.env.ADMIN_CONSOLE_CONFIG = join(dir, "config.json");
process.env.ADMIN_CONSOLE_BUILD_ROOT = join(dir, "build");
process.env.ADMIN_CONSOLE_KEYS = join(dir, "keys", "secrets.local.json");
process.env.ADMIN_CONSOLE_KEYS_LEGACY = join(dir, "legacy", "keys.json");
writeFileSync(process.env.ADMIN_CONSOLE_CONFIG, JSON.stringify({ host: "relay.test", bucket: "test-bucket", wranglerConfig: join(dir, "wrangler.local.toml") }));

const { allowedHost, catalogHash, checkSchedule, cleanItem, createConsole, localPacks, mainCheckout, planAnnouncements, planReset, putArgs, resetScopes, resolveResetDir, validateConfig, withSchedule, withoutPack } = await import("./server.mjs");

const KEYS = await import("./keys.mjs");

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

test("팩 내용 보기: 대표 아이콘·자산 목록을 주고, 목록 밖 파일·토큰 없는 요청은 막는다", async () => {
  const pack = localPacks().find((entry) => !entry.error);
  assert.ok(pack.cover && pack.files.length > 0 && Array.isArray(pack.audio));
  const q = (path, token = TOKEN) => `/api/pack-file?dir=${encodeURIComponent(pack.dir)}&path=${encodeURIComponent(path)}&t=${token}`;
  const ok = await call("GET", q(pack.cover), { token: null });
  assert.equal(ok.status, 200);
  assert.match(ok.headers["content-type"], /^image\//);
  assert.equal((await call("GET", q(pack.cover, "x".repeat(32)), { token: null })).status, 401);
  assert.equal((await call("GET", q("../../../../manifest.json"), { token: null })).status, 404);
});

// ---- ADM1120A03 초기화 ----

const ALL = { notices: true, packs: true, schedules: true };
const entryA = { id: "christmas", version: 2, archive: { key: "k", bytes: 1, sha256: "0".repeat(64) }, schedule: [{ from: "2026-12-19T00:00:00+09:00", to: "2026-12-30T00:00:00+09:00" }] };

test("초기화 미리보기: 셋 다 켜면 공지는 빈 목록+version+1, 카탈로그는 packs 비움", async () => {
  remote.announcements = { version: 4, items: [{ id: "old-1", title: "예전", body: "예전 공지", kind: "info" }] };
  remote.catalog = { format: "bokki-season-packs", schema: 1, packs: [entryA] };
  const preview = await call("POST", "/api/reset/preview", { body: { scopes: ALL } });
  assert.equal(preview.status, 200, preview.text);
  assert.deepEqual(preview.json.after.announcements.items, []);
  assert.equal(preview.json.after.announcements.version, 5);
  assert.deepEqual(preview.json.after.catalog.packs, []);
  assert.equal(preview.json.baseVersion, 4);
  assert.equal(preview.json.baseCatalogHash, catalogHash(remote.catalog));
  assert.deepEqual(preview.json.errors, []);
});

test("초기화: 기간만 지우면 팩은 남고 schedule 칸만 사라진다", () => {
  const plan = planReset({ version: 1, items: [] }, { packs: [entryA] }, { notices: false, packs: false, schedules: true });
  assert.equal(plan.after.catalog.packs.length, 1);
  assert.equal("schedule" in plan.after.catalog.packs[0], false);
  assert.equal(plan.after.announcements.version, 1, "공지는 그대로");
});

test("초기화: 범위가 모두 꺼졌거나 확인 글이 틀리면 422", async () => {
  assert.equal(resetScopes({}), null);
  assert.equal((await call("POST", "/api/reset/preview", { body: { scopes: {} } })).status, 422);
  const base = { scopes: ALL, baseVersion: 4, baseCatalogHash: catalogHash(remote.catalog) };
  assert.equal((await call("POST", "/api/reset/apply", { body: { ...base, confirm: "reset" } })).status, 422);
  assert.equal((await call("POST", "/api/reset/apply", { body: { ...base, scopes: {}, confirm: "초기화" } })).status, 422);
});

test("초기화: 그 사이 서버가 바뀌었으면 409이고 아무것도 올리지 않는다", async () => {
  const before = (await call("GET", "/api/state")).json.logs.length;
  const stale = await call("POST", "/api/reset/apply", { body: { scopes: ALL, baseVersion: 3, baseCatalogHash: catalogHash(remote.catalog), confirm: "초기화" } });
  assert.equal(stale.status, 409);
  const staleCatalog = await call("POST", "/api/reset/apply", { body: { scopes: ALL, baseVersion: 4, baseCatalogHash: "0000", confirm: "초기화" } });
  assert.equal(staleCatalog.status, 409);
  const logs = (await call("GET", "/api/state")).json.logs.slice(before);
  assert.equal(logs.some((l) => l.includes("wrangler")), false);
});

test("초기화 실행(연습) → 백업 파일이 있고 되돌리기가 그 내용을 그대로 올린다", async () => {
  const hash = catalogHash(remote.catalog);
  const before = (await call("GET", "/api/state")).json.logs.length;
  const done = await call("POST", "/api/reset/apply", { body: { scopes: ALL, baseVersion: 4, baseCatalogHash: hash, confirm: "초기화" } });
  assert.equal(done.status, 200, done.text);
  assert.equal(done.json.dryRun, true);
  const root = process.env.ADMIN_CONSOLE_BUILD_ROOT;
  const backup = join(root, done.json.dir);
  assert.match(done.json.dir, /^reset-\d{4}-\d{2}-\d{2}T[\d-]+$/);
  assert.deepEqual(JSON.parse(readFileSync(join(backup, "before-announcements.json"), "utf8")), remote.announcements);
  assert.deepEqual(JSON.parse(readFileSync(join(backup, "before-index.json"), "utf8")), remote.catalog);
  const uploads = (await call("GET", "/api/state")).json.logs.slice(before).filter((l) => l.includes("[연습] npx wrangler"));
  assert.equal(uploads.length, 2);
  assert.match(uploads[0], /announcements\/latest\.json --file .*after-announcements\.json/);
  assert.match(uploads[1], /packs\/season\/index\.json --file .*after-index\.json/);
  // 되돌리기: 기본은 마지막 초기화, 백업 파일을 그대로 올린다.
  const mark = (await call("GET", "/api/state")).json.logs.length;
  const restored = await call("POST", "/api/reset/restore", { body: {} });
  assert.equal(restored.status, 200, restored.text);
  assert.deepEqual(restored.json.restored, ["announcements", "catalog"]);
  const restoreLines = (await call("GET", "/api/state")).json.logs.slice(mark).filter((l) => l.includes("[연습] npx wrangler"));
  assert.equal(restoreLines.length, 2);
  assert.match(restoreLines[0], /before-announcements\.json/);
  assert.match(restoreLines[1], /before-index\.json/);
  const state = await call("GET", "/api/reset/state");
  assert.equal(state.json.lastReset.dir, done.json.dir);
});

test("초기화 되돌리기: dir이 모양 밖·.. ·절대경로면 400이고 BUILD_ROOT 밖을 읽지 않는다", async () => {
  const root = process.env.ADMIN_CONSOLE_BUILD_ROOT;
  // 밖 폴더에 before-* 가 아닌 파일을 둬서, 열렸다면 올리려 했을 상황을 만든다.
  mkdirSync(join(dir, "outside"), { recursive: true });
  writeFileSync(join(dir, "outside", "before-announcements.json"), "{}");
  writeFileSync(join(dir, "outside", "before-index.json"), "{}");
  for (const bad of ["../outside", "/etc", "reset-2026-11-20T00-00-00/../../outside", "reset-x", "", "reset-2026-11-20T00-00-00/sub"]) {
    const response = await call("POST", "/api/reset/restore", { body: { dir: bad } });
    assert.equal(response.status, 400, `${bad} → ${response.status}`);
  }
  assert.equal(resolveResetDir("../outside", root), null);
  assert.equal(resolveResetDir("reset-2026-11-20T00-00-00", root), join(root, "reset-2026-11-20T00-00-00"));
  assert.equal((await call("POST", "/api/reset/restore", { body: { dir: "reset-2099-01-01T00-00-00" } })).status, 404);
});

test("초기화 라우트도 토큰·Host 검사를 따른다", async () => {
  assert.equal((await call("GET", "/api/reset/state", { token: "x".repeat(32) })).status, 401);
  assert.equal((await call("POST", "/api/reset/apply", { token: null, body: { scopes: ALL } })).status, 401);
  assert.equal((await call("GET", "/api/reset/state", { host: `evil.example:${PORT}` })).status, 421);
});

// ---- API 키(KEY1121A01). 값은 모두 가짜. ----
const FAKE = "fake-test-key-0000000000AbCd";
const FAKE_P8 = "-----BEGIN PRIVATE KEY-----\nZmFrZS1wOC1mb3ItdGVzdHMtb25seQ==\n-----END PRIVATE KEY-----";

test("키 목록: 서버·앱이 쓰는 이름과 외부·AI·내부·앱으로 나뉘고 기능 설명·없을 때·사용량·만료 안내가 있다", async () => {
  const res = await call("GET", "/api/keys");
  assert.equal(res.status, 200);
  const names = res.json.keys.map((k) => k.name);
  for (const name of ["ICN_API_KEY", "KAC_API_KEY", "EX_API_KEY", "TAGO_SERVICE_KEY", "KAKAO_REST_API_KEY", "GOOGLE_PLACES_KEY", "POSTHOG_API_KEY", "KAKAO_NATIVE_APP_KEY"]) assert.ok(names.includes(name), name);
  const kindOf = Object.fromEntries(res.json.keys.map((k) => [k.name, k.kind]));
  for (const name of ["KAKAO_REST_API_KEY", "EX_API_KEY", "TAGO_SERVICE_KEY", "ICN_API_KEY", "KAC_API_KEY", "TOUR_API_KEY", "GOOGLE_PLACES_KEY", "UNSPLASH_ACCESS_KEY", "PEXELS_API_KEY", "MAPILLARY_TOKEN"]) assert.equal(kindOf[name], "external", name);
  for (const name of ["APNS_KEY_ID", "APNS_KEY_P8", "APNS_TEAM_ID", "APNS_TOPIC", "PIN_PEPPER", "CLASSIFIER_ADMIN_TOKEN", "SHARED_RULES_ADMIN_TOKEN", "SHARED_RULES_PUBLIC_KEY"]) assert.equal(kindOf[name], "internal", name);
  assert.equal(kindOf.KAKAO_NATIVE_APP_KEY, "app");
  assert.equal(kindOf.POSTHOG_API_KEY, "app");
  for (const name of ["ALGOLIA_APP_ID", "ALGOLIA_WRITE_KEY", "ALGOLIA_SEARCH_KEY", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_REGION", "AWS_BEDROCK_MODEL_ID"]) assert.equal(kindOf[name], "ai", name);
  assert.equal(res.json.keys.filter((k) => k.kind === "external").length, 10);
  assert.ok(res.json.keys.find((k) => k.name === "PIN_PEPPER").danger);
  assert.match(res.json.keys.find((k) => k.name === "ALGOLIA_SEARCH_KEY").missing, /Secured Key/);
  assert.match(res.json.keys.find((k) => k.name === "ALGOLIA_APP_ID").missing, /로컬 검색으로 폴백/);
  assert.deepEqual(Object.keys(res.json.kinds), ["external", "ai", "internal", "app", "custom"]);
  // 사용량은 세 가지로만: 한도(코드에 적힌 값) / 확인 불가(콘솔 안내) / 관리 불필요
  const labels = new Set(res.json.keys.map((k) => k.usage.label));
  assert.deepEqual([...labels].sort(), ["관리 불필요", "한도", "확인 불가(콘솔 안내)"].sort());
  assert.equal(res.json.keys.find((k) => k.name === "AWS_REGION").usage.label, "관리 불필요");
  assert.equal(res.json.keys.find((k) => k.name === "EX_API_KEY").usage.label, "확인 불가(콘솔 안내)");
  for (const key of res.json.keys) {
    assert.ok(key.feature && key.missing && key.expiryHint && key.usage.reason && key.usage.where, key.name);
    assert.ok(["limit", "unavailable", "none"].includes(key.usage.kind), key.name);
    assert.equal(key.hasValue, false);
  }
});

test("서버 소스에 나오는 비밀값 이름은 모두 목록이나 내부 목록에 있다", () => {
  const src = ["index.js", "algolia.js", "bedrock.js", "flights.js", "expressway.js", "apns.js", "directions.js", "shared.js", "classifier.js", "keys.js", "crypto.js", "oauth.js"]
    .map((file) => { try { return readFileSync(new URL(`../../server/trip-relay/src/${file}`, import.meta.url), "utf8"); } catch { return ""; } }).join("\n");
  const used = new Set([...src.matchAll(/\benv\.([A-Z][A-Z0-9]*_(?:API_KEY|SERVICE_KEY|ACCESS_KEY|ACCESS_KEY_ID|SECRET_ACCESS_KEY|SESSION_TOKEN|TOKEN|KEY|KEY_P8|KEY_ID|TEAM_ID|TOPIC|PEPPER|PUBLIC_KEY|APP_ID|WRITE_KEY|SEARCH_KEY))\b/g)].map((m) => m[1]));
  // flights.js는 env[source.key]로 읽으므로 SOURCES의 key: "…" 문자열도 센다.
  for (const m of src.matchAll(/\bkey:\s*"([A-Z][A-Z0-9_]+_KEY)"/g)) used.add(m[1]);
  assert.ok(used.has("ICN_API_KEY") && used.has("KAC_API_KEY") && used.has("APNS_TOPIC"));
  const covered = new Set(KEYS.KEY_CATALOG.map((k) => k.name));
  assert.ok(used.size >= 10);
  for (const name of used) assert.ok(covered.has(name), `${name}이(가) 키 화면에 없습니다`);
});

test("키 저장: 파일은 600, 응답·기록에는 원문 없이 끝 4자리만", async () => {
  const res = await call("POST", "/api/keys/set", { body: { name: "ICN_API_KEY", value: `  ${FAKE}  ` } });
  assert.equal(res.status, 200);
  assert.ok(!res.text.includes(FAKE));
  const icn = res.json.keys.find((k) => k.name === "ICN_API_KEY");
  assert.equal(icn.hasValue, true);
  assert.equal(icn.masked, "••••AbCd");
  assert.equal(statSync(process.env.ADMIN_CONSOLE_KEYS).mode & 0o777, 0o600);
  assert.equal(statSync(join(dir, "keys")).mode & 0o777, 0o700);
  assert.equal(res.json.fileMode, "0600");
  assert.equal(JSON.parse(readFileSync(process.env.ADMIN_CONSOLE_KEYS, "utf8")).keys.ICN_API_KEY.value, FAKE); // 앞뒤 공백은 지움
  const list = await call("GET", "/api/keys");
  assert.ok(!list.text.includes(FAKE));
  const state = await call("GET", "/api/state");
  assert.ok(!state.text.includes(FAKE) && !state.text.includes("AbCd"));
  assert.ok(state.json.logs.some((line) => line.includes("ICN_API_KEY: 키를 저장했습니다")));
});

test("키 저장 검사: 목록 밖 이름 404, 공백 섞임·빈 값·너무 긴 값 422, 오류에도 값이 없다", async () => {
  assert.equal((await call("POST", "/api/keys/set", { body: { name: "NOT_A_KEY", value: FAKE } })).status, 404);
  const spaced = await call("POST", "/api/keys/set", { body: { name: "EX_API_KEY", value: "fake key\nwith-break" } });
  assert.equal(spaced.status, 422);
  assert.ok(!spaced.text.includes("with-break"));
  assert.equal((await call("POST", "/api/keys/set", { body: { name: "EX_API_KEY", value: "   " } })).status, 422);
  assert.equal((await call("POST", "/api/keys/set", { body: { name: "EX_API_KEY", value: "x".repeat(KEYS.MAX_VALUE + 1) } })).status, 422);
  assert.equal((await call("POST", "/api/keys/set", { body: { name: "APNS_KEY_P8", value: "not-a-pem" } })).status, 422);
  const p8 = await call("POST", "/api/keys/set", { body: { name: "APNS_KEY_P8", value: FAKE_P8.replace(/\n/g, "\r\n") } });
  assert.equal(p8.status, 200);
  assert.ok(!p8.text.includes("ZmFrZS1wOC"));
});

test("마스킹: 12자 미만은 끝 자리도 숨긴다", () => {
  assert.equal(KEYS.maskValue("ABCDEFGHIJ"), "••••");
  assert.equal(KEYS.maskValue("fake-abcdefgh-1234"), "••••1234");
  assert.equal(KEYS.maskValue(""), null);
});

test("키 삭제: 값만 지우고 만료일·메모는 남긴다, 없는 값은 404", async () => {
  await call("POST", "/api/keys/set", { body: { name: "KAC_API_KEY", value: FAKE } });
  assert.equal((await call("POST", "/api/keys/meta", { body: { name: "KAC_API_KEY", expiresAt: "2028-11-20", note: "2년마다 연장" } })).status, 200);
  const res = await call("POST", "/api/keys/delete", { body: { name: "KAC_API_KEY" } });
  assert.equal(res.status, 200);
  const kac = res.json.keys.find((k) => k.name === "KAC_API_KEY");
  assert.equal(kac.hasValue, false);
  assert.equal(kac.expiresAt, "2028-11-20");
  assert.equal(kac.note, "2년마다 연장");
  assert.equal((await call("POST", "/api/keys/delete", { body: { name: "KAC_API_KEY" } })).status, 404);
  assert.equal((await call("POST", "/api/keys/delete", { body: { name: "NOT_A_KEY" } })).status, 404);
});

test("만료일: 형식 검사, 지우기, 만료됨·7일·30일 구분", async () => {
  assert.equal((await call("POST", "/api/keys/meta", { body: { name: "EX_API_KEY", expiresAt: "2026-02-30" } })).status, 422);
  assert.equal((await call("POST", "/api/keys/meta", { body: { name: "EX_API_KEY", expiresAt: "내일" } })).status, 422);
  const cleared = await call("POST", "/api/keys/meta", { body: { name: "EX_API_KEY", expiresAt: null, note: "" } });
  assert.equal(cleared.json.keys.find((k) => k.name === "EX_API_KEY").expiry.state, "none");
  const now = new Date(2026, 10, 21, 15, 0);
  assert.deepEqual(KEYS.expiryState("2026-11-20", now), { state: "expired", days: -1 });
  assert.deepEqual(KEYS.expiryState("2026-11-21", now), { state: "soon7", days: 0 }); // 그날 끝까지 유효
  assert.equal(KEYS.expiryState("2026-11-28", now).state, "soon7");
  assert.equal(KEYS.expiryState("2026-11-29", now).state, "soon30");
  assert.equal(KEYS.expiryState("2026-12-21", now).state, "soon30");
  assert.equal(KEYS.expiryState("2026-12-22", now).state, "ok");
  assert.equal(KEYS.expiryState(null, now).state, "none");
});

test("반영 안내: 서버 키는 wrangler secret put 명령만, 앱 키는 xcconfig 줄(값 자리 비움)", async () => {
  const { json } = await call("GET", "/api/keys");
  const icn = json.keys.find((k) => k.name === "ICN_API_KEY");
  // 설정 탭의 wrangler 설정 파일 경로를 따옴표로 붙인다(경로에 공백이 있어도 됨).
  assert.equal(icn.apply.commands[0], `npx wrangler secret put ICN_API_KEY --config "${join(dir, "wrangler.local.toml")}"`);
  assert.ok(icn.apply.commands.every((c) => !c.includes(FAKE) && !c.includes("deploy")));
  const posthog = json.keys.find((k) => k.name === "POSTHOG_API_KEY");
  assert.deepEqual(posthog.apply.commands, ["POSTHOG_API_KEY = <키 값>"]);
  assert.equal(KEYS.appBuildValue("A = 1\nPOSTHOG_API_KEY = phc_fake // 메모\n", "POSTHOG_API_KEY"), "phc_fake");
  assert.equal(KEYS.appBuildValue("POSTHOG_API_KEY =\n", "POSTHOG_API_KEY"), null);
});

test("서버 시크릿 이름 읽기(연습): 명령만 기록하고 값을 넣거나 배포하지 않는다", async () => {
  const res = await call("POST", "/api/keys/server-list", { body: {} });
  assert.equal(res.status, 200);
  const state = await call("GET", "/api/state");
  const line = state.json.logs.find((l) => l.includes("wrangler secret list"));
  assert.ok(line && line.includes("[연습]"));
  assert.ok(!state.json.logs.some((l) => /secret put|wrangler deploy/.test(l)));
  assert.deepEqual([...KEYS.parseSecretList('⛅️ wrangler\n[{"name":"ICN_API_KEY","type":"secret_text"},{"name":"EX_API_KEY","type":"secret_text"}]')], ["ICN_API_KEY", "EX_API_KEY"]);
  assert.equal(KEYS.parseSecretList("오류"), null);
});

test("키 라우트도 토큰·Host·JSON 검사를 따른다", async () => {
  assert.equal((await call("GET", "/api/keys", { token: null })).status, 401);
  assert.equal((await call("POST", "/api/keys/set", { body: { name: "EX_API_KEY", value: FAKE }, token: "x".repeat(32) })).status, 401);
  assert.equal((await call("GET", "/api/keys", { host: `evil.example:${PORT}` })).status, 421);
  assert.equal((await call("POST", "/api/keys/set", { body: "name=EX_API_KEY", type: "text/plain" })).status, 415);
});

test("연동 예정 칸 직접 추가: 이름 검사, 값 저장·마스킹, 칸 지우면 값도 지운다", async () => {
  assert.equal((await call("POST", "/api/keys/custom", { body: { name: "aws_key" } })).status, 422);
  assert.equal((await call("POST", "/api/keys/custom", { body: { name: "EX_API_KEY" } })).status, 422);
  assert.equal((await call("POST", "/api/keys/set", { body: { name: "AWS_FAKE_ACCESS_KEY_ID", value: FAKE } })).status, 404);
  const added = await call("POST", "/api/keys/custom", { body: { name: "AWS_FAKE_ACCESS_KEY_ID", provider: "AWS", feature: "시험용 가짜 칸", where: "server" } });
  assert.equal(added.status, 200);
  const slot = added.json.keys.find((k) => k.name === "AWS_FAKE_ACCESS_KEY_ID");
  assert.equal(slot.kind, "custom");
  assert.equal(slot.custom, true);
  assert.equal(slot.usage.reason, "연동 전");
  const saved = await call("POST", "/api/keys/set", { body: { name: "AWS_FAKE_ACCESS_KEY_ID", value: FAKE } });
  assert.equal(saved.json.keys.find((k) => k.name === "AWS_FAKE_ACCESS_KEY_ID").masked, "••••AbCd");
  assert.ok(!saved.text.includes(FAKE));
  const removed = await call("POST", "/api/keys/custom-remove", { body: { name: "AWS_FAKE_ACCESS_KEY_ID" } });
  assert.ok(!removed.json.keys.some((k) => k.name === "AWS_FAKE_ACCESS_KEY_ID"));
  assert.equal(JSON.parse(readFileSync(process.env.ADMIN_CONSOLE_KEYS, "utf8")).keys.AWS_FAKE_ACCESS_KEY_ID, undefined);
  assert.equal((await call("POST", "/api/keys/custom-remove", { body: { name: "EX_API_KEY" } })).status, 404);
});

test("키 파일·로그 어디에도 다른 키의 원문이 새지 않고, 저장 파일은 저장소 밖 경로를 기본으로 쓴다", async () => {
  const state = await call("GET", "/api/state");
  assert.ok(!state.text.includes(FAKE) && !state.text.includes("ZmFrZS1wOC"));
  const { KEYS_FILE } = KEYS;
  assert.equal(KEYS_FILE, process.env.ADMIN_CONSOLE_KEYS); // 시험은 임시 파일
  const source = readFileSync(new URL("./keys.mjs", import.meta.url), "utf8");
  assert.match(source, /join\(mainRepo\(\), "tools\/admin-console\/secrets\.local\.json"\)/);
  const ignore = readFileSync(new URL("../../.gitignore", import.meta.url), "utf8");
  assert.match(ignore, /^tools\/admin-console\/secrets\.local\.json$/m);
});

test("secret put 명령: 경로를 큰따옴표로 감싸고 \\ \" $ ` 를 막는다, 값은 들어가지 않는다", () => {
  assert.equal(KEYS.secretCommands("EX_API_KEY", "/a b/wrangler.local.toml").put, 'npx wrangler secret put EX_API_KEY --config "/a b/wrangler.local.toml"');
  assert.equal(KEYS.shQuote('/x/$HOME/"q"/`id`'), '"/x/\\$HOME/\\"q\\"/\\`id\\`"');
  assert.match(KEYS.secretCommands("EX_API_KEY", "/w.toml").pipe, /--print-key EX_API_KEY \| npx wrangler secret put EX_API_KEY --config "\/w\.toml"$/);
});

test("옛 저장소 밖 키 파일에서 한 번 옮겨 온다: 있는 이름은 덮지 않고, 옛 파일은 남기며, 응답에 원문이 없다", async () => {
  const legacy = process.env.ADMIN_CONSOLE_KEYS_LEGACY;
  assert.equal((await call("POST", "/api/keys/migrate", { body: {} })).status, 404);
  mkdirSync(join(dir, "legacy"), { recursive: true });
  writeFileSync(legacy, JSON.stringify({ keys: { MAPILLARY_TOKEN: { value: "fake-legacy-0000LGCY", expiresAt: "2027-01-31" }, ICN_API_KEY: { value: "fake-legacy-should-not-win" } }, custom: { OLD_FAKE_SLOT: { provider: "가짜" } } }));
  await call("POST", "/api/keys/set", { body: { name: "ICN_API_KEY", value: FAKE } });
  const before = await call("GET", "/api/keys");
  assert.ok(before.json.legacyFile);
  const res = await call("POST", "/api/keys/migrate", { body: {} });
  assert.equal(res.status, 200);
  assert.equal(res.json.migrated, 2);
  assert.ok(!res.text.includes("fake-legacy"));
  const stored = JSON.parse(readFileSync(process.env.ADMIN_CONSOLE_KEYS, "utf8"));
  assert.equal(stored.keys.ICN_API_KEY.value, FAKE);
  assert.equal(stored.keys.MAPILLARY_TOKEN.expiresAt, "2027-01-31");
  assert.ok(stored.custom.OLD_FAKE_SLOT);
  assert.equal(statSync(process.env.ADMIN_CONSOLE_KEYS).mode & 0o777, 0o600);
  assert.ok(readFileSync(legacy, "utf8").includes("LGCY")); // 옛 파일은 대표가 확인 뒤 지운다
  const state = await call("GET", "/api/state");
  assert.ok(!state.text.includes("fake-legacy"));
});
