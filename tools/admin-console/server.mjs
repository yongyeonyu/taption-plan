// ADM1120A01: 이 맥에서만 여는 운영 페이지. 공지(`announcements/latest.json`)와 시즌 팩(`.bpack` + `packs/season/index.json`)을 R2에 올린다.
//
//   node tools/admin-console/server.mjs            # 127.0.0.1 에서 열고, 접속 주소(일회용 토큰 포함)를 출력하고 브라우저를 연다
//   node tools/admin-console/server.mjs --dry-run  # 올리기 명령을 실행하지 않고 기록만 한다(연습·시험용)
//
// - 외부로 열지 않는다: 127.0.0.1 에만 묶고, Host 머리글이 127.0.0.1·localhost 가 아니면 거절한다(DNS 리바인딩 차단).
// - 로그인 대신 실행할 때마다 새로 만드는 토큰을 쓴다. 토큰은 이 맥 터미널에만 찍히고, API는 `X-Admin-Token` 머리글이 맞아야 답한다
//   (다른 사이트의 스크립트는 사용자 머리글을 붙이면 사전 요청이 필요한데 이 서버는 CORS에 답하지 않는다).
// - 올리는 길은 기존과 같다: `npx wrangler r2 object put … --remote --config <wrangler.local.toml>`. 비밀값은 다루지 않는다(wrangler 로그인 그대로).
// - 공지 검사·합치기는 `server/trip-relay/scripts/announce.mjs`, 팩 묶기는 `scripts/season-pack/build_bpack.py`를 그대로 부른다.
import { execFile } from "node:child_process";
import { randomBytes, timingSafeEqual } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { dirname, join, relative, resolve, sep } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
export const REPO = resolve(HERE, "../..");
const ANNOUNCE = await import(pathToFileURL(join(REPO, "server/trip-relay/scripts/announce.mjs")).href);
const SEED_ROOT = join(REPO, "Packages/SeasonPackKit/Sources/SeasonPackKit/Resources/seed");
// 시험은 이 두 경로를 임시 폴더로 바꾼다.
const BUILD_ROOT = process.env.ADMIN_CONSOLE_BUILD_ROOT ?? join(REPO, "build/admin-console");
const CONFIG_FILE = process.env.ADMIN_CONSOLE_CONFIG ?? join(HERE, "config.local.json");
const CATALOG_KEY = "packs/season/index.json";
const ANNOUNCE_KEY = "announcements/latest.json";
const MAX_BODY = 256 * 1024;

/** 작업용 사본(git worktree)이면 원래 저장소 폴더. git 제외 파일(xcconfig·wrangler.local.toml)은 거기에만 있다. */
export function mainCheckout(repo = REPO) {
  try {
    const text = readFileSync(join(repo, ".git"), "utf8"); // worktree에서는 파일: "gitdir: <main>/.git/worktrees/<name>"
    const gitdir = /^gitdir:\s*(.+)$/m.exec(text)?.[1]?.trim();
    const marker = gitdir ? gitdir.lastIndexOf(`${sep}.git${sep}worktrees${sep}`) : -1;
    return marker > 0 ? gitdir.slice(0, marker) : repo;
  } catch { return repo; }
}

const firstExisting = (paths) => paths.find((path) => existsSync(path)) ?? paths[0];

/** 기본 설정. 호스트는 앱 빌드 설정(`TRIP_RELAY_HOST`)에서 읽는다(공개 저장소에 적지 않음). */
export function defaultConfig(repo = REPO) {
  const roots = [...new Set([repo, mainCheckout(repo)])];
  let host = "";
  try {
    const file = firstExisting(roots.map((root) => join(root, "TaptionPlan/AppSecrets.local.xcconfig")));
    const line = readFileSync(file, "utf8").split("\n").find((l) => /^\s*TRIP_RELAY_HOST\s*=/.test(l));
    host = line ? line.split("=").slice(1).join("=").replace(/\/\/.*$/, "").replace(/^https?:\$\(\)\/\//, "").replace(/^https?:\/\//, "").trim() : "";
  } catch {}
  let bucket = "";
  try {
    const toml = readFileSync(join(repo, "server/trip-relay/wrangler.toml"), "utf8");
    bucket = /binding\s*=\s*"PUBLIC_BUCKET"\s*\n\s*bucket_name\s*=\s*"([^"]+)"/.exec(toml)?.[1] ?? "";
  } catch {}
  return { host, bucket, wranglerConfig: firstExisting(roots.map((root) => join(root, "server/trip-relay/wrangler.local.toml"))) };
}

export function loadConfig() {
  const base = defaultConfig();
  try { return { ...base, ...JSON.parse(readFileSync(CONFIG_FILE, "utf8")) }; } catch { return base; }
}

const HOST_NAME = /^[A-Za-z0-9.-]{1,253}(:\d{1,5})?$/;
const BUCKET_NAME = /^[a-z0-9][a-z0-9-]{1,62}$/;

export function validateConfig(config) {
  const errors = [];
  if (!HOST_NAME.test(config.host ?? "")) errors.push("서버 주소는 호스트 이름만(https:// 없이)");
  if (!BUCKET_NAME.test(config.bucket ?? "")) errors.push("버킷 이름은 소문자·숫자·-");
  if (typeof config.wranglerConfig !== "string" || !config.wranglerConfig.endsWith(".toml")) errors.push("wrangler 설정은 .toml 파일 경로");
  return errors;
}

// ---- 서버에서 읽기(공개 GET만) ----

async function fetchJSON(url, fallback) {
  let response;
  try { response = await fetch(url, { headers: { "cache-control": "no-cache" } }); }
  catch (error) { throw new Error(`${url} 에 연결하지 못했습니다(${error.cause?.code ?? error.message}). 설정의 서버 주소와 인터넷 연결을 확인하세요.`); }
  if (response.status === 404 && fallback !== undefined) return fallback;
  if (!response.ok) throw new Error(`${url} 읽기 실패(${response.status})`);
  return response.json();
}

const emptyCatalog = () => ({ format: "bokki-season-packs", schema: 1, packs: [] });
const needHost = (config) => { if (validateConfig(config).length) throw Object.assign(new Error("설정 탭에서 서버 주소·버킷·wrangler 설정을 먼저 채우세요"), { status: 422 }); };
const currentAnnouncements = (config) => needHost(config) ?? fetchJSON(`https://${config.host}/public/announcements`);
const currentCatalog = (config) => needHost(config) ?? fetchJSON(`https://${config.host}/public/assets/${CATALOG_KEY}`, emptyCatalog());

// ---- 올리기(wrangler) ----

function run(command, args, options) {
  return new Promise((resolvePromise) => {
    execFile(command, args, { ...options, maxBuffer: 8 * 1024 * 1024, timeout: 10 * 60 * 1000 }, (error, stdout, stderr) => {
      resolvePromise({ ok: !error, code: error?.code ?? 0, output: `${stdout}${stderr}`.trim() });
    });
  });
}

export function putArgs(config, key, file, contentType, cacheControl) {
  return ["wrangler", "r2", "object", "put", `${config.bucket}/${key}`, "--file", file, "--content-type", contentType,
    "--cache-control", cacheControl, "--remote", "--config", config.wranglerConfig];
}

async function upload(ctx, key, file, contentType, cacheControl) {
  const args = putArgs(ctx.config, key, file, contentType, cacheControl);
  const line = `npx ${args.join(" ")}`;
  if (ctx.dryRun) { ctx.log(`[연습] ${line}`); return; }
  if (!existsSync(ctx.config.wranglerConfig)) throw new Error(`wrangler 설정 파일이 없습니다: ${ctx.config.wranglerConfig}`);
  ctx.log(`$ ${line}`);
  const result = await run("npx", args, { cwd: dirname(ctx.config.wranglerConfig) });
  ctx.log(result.output);
  if (!result.ok) throw new Error(`올리기 실패: ${key}`);
}

// ---- 공지 ----

function specOf(body) {
  const items = Array.isArray(body?.items) ? body.items : [];
  const remove = Array.isArray(body?.remove) ? body.remove.filter((id) => typeof id === "string") : [];
  return { items: items.map(cleanItem), remove };
}

/** 빈 칸은 빼고, 숫자 칸은 숫자로. 화면 폼이 보낸 값을 announce.mjs 모양으로 맞춘다. */
export function cleanItem(raw) {
  const item = {};
  for (const [key, value] of Object.entries(raw ?? {})) {
    if (value === "" || value === null || value === undefined) continue;
    if (key === "minBuild" || key === "maxBuild") item[key] = Number(value);
    else if (key === "titleByLang" || key === "bodyByLang") {
      const table = Object.fromEntries(Object.entries(value ?? {}).filter(([, text]) => typeof text === "string" && text.trim()));
      if (Object.keys(table).length) item[key] = table;
    } else item[key] = typeof value === "string" ? value.trim() : value;
  }
  return item;
}

export function planAnnouncements(current, spec) {
  const next = ANNOUNCE.merge(current, spec);
  return { next, errors: ANNOUNCE.check(next), preview: ANNOUNCE.preview(current, next) };
}

// ---- 시즌 팩 ----

const ko = (text) => (text && typeof text === "object" ? text.ko ?? text.en ?? "" : text ?? "");

/** 카드에 보여 줄 팩 내용: 자산 목록, 대표 아이콘, 안내 글, 음원, 가사 줄 수, 슬롯 이름. */
export function packDetails(manifest) {
  const files = (manifest.assets ?? []).map((a) => ({ id: a.id, path: a.path, kind: a.kind, bytes: a.bytes ?? 0 }));
  const byId = new Map(files.map((f) => [f.id, f]));
  const coverId = manifest.menuIcons?.[0]?.icon;
  const cover = (byId.get(coverId) ?? files.find((f) => f.kind === "image"))?.path ?? null;
  const intro = (manifest.menuIcons ?? []).flatMap((icon) => (icon.menu?.sections ?? []).flatMap((section) => (section.items ?? [])
    .filter((item) => item.kind === "text").map((item) => ({ title: ko(section.title), text: ko(item.text) }))));
  return {
    files, cover, intro,
    audio: (manifest.audio ?? []).map((a) => ({ id: a.id, asset: byId.get(a.asset)?.path ?? null, seconds: Math.round((a.durationMs ?? 0) / 1000), title: a.license?.title ?? a.id })),
    lyricLines: (manifest.lyrics ?? []).reduce((n, l) => n + (l.cues?.length ?? 0), 0),
    slots: Object.keys(manifest.slots ?? {}), actors: (manifest.actors ?? []).map((a) => a.id),
    menuIcons: (manifest.menuIcons ?? []).map((icon) => ko(icon.label)), credits: (manifest.credits ?? []).map(ko),
    priority: manifest.priority ?? null,
  };
}

const FILE_TYPES = { png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", webp: "image/webp", gif: "image/gif", m4a: "audio/mp4", mp3: "audio/mpeg", wav: "audio/wav" };

/** 묶을 수 있는 팩 폴더: seed/<id>/<version>/manifest.json */
export function localPacks(root = SEED_ROOT) {
  const out = [];
  if (!existsSync(root)) return out;
  for (const id of readdirSync(root).sort()) {
    const idDir = join(root, id);
    if (!statSync(idDir).isDirectory()) continue;
    for (const version of readdirSync(idDir).sort()) {
      const file = join(idDir, version, "manifest.json");
      if (!existsSync(file)) continue;
      try {
        const manifest = JSON.parse(readFileSync(file, "utf8"));
        const size = (manifest.assets ?? []).reduce((sum, asset) => sum + (asset.bytes ?? 0), 0);
        out.push({ dir: relative(REPO, join(idDir, version)), id: manifest.id, version: manifest.version,
          title: manifest.event?.title?.ko ?? manifest.event?.title?.en ?? manifest.id, windows: manifest.event?.windows ?? [],
          requiresAppBuild: manifest.requiresAppBuild ?? null, assets: (manifest.assets ?? []).length, bytes: size, ...packDetails(manifest) });
      } catch (error) {
        out.push({ dir: relative(REPO, join(idDir, version)), error: `매니페스트를 읽지 못함: ${error.message}` });
      }
    }
  }
  return out;
}

const SPAN_TIME = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})$/;
export const MAX_SPANS = 24;

/** 운영 기간 검사. null = 매니페스트 기간 그대로, [] = 꺼 둠. 칸은 [from, to), 겹치면 안 된다. */
export function checkSchedule(schedule) {
  if (schedule === null) return [];
  if (!Array.isArray(schedule)) return ["기간은 목록이어야 합니다"];
  if (schedule.length > MAX_SPANS) return [`기간은 ${MAX_SPANS}칸까지`];
  const errors = [];
  const spans = schedule.map((span, i) => {
    const ok = span && SPAN_TIME.test(span.from ?? "") && SPAN_TIME.test(span.to ?? "");
    const from = ok ? Date.parse(span.from) : NaN, to = ok ? Date.parse(span.to) : NaN;
    if (!ok || Number.isNaN(from) || Number.isNaN(to)) errors.push(`${i + 1}번째 기간: 시각 형식(예: 2026-11-21T00:00:00+09:00)`);
    else if (to <= from) errors.push(`${i + 1}번째 기간: 끝이 시작보다 늦어야 합니다`);
    return { from, to, i };
  }).filter((span) => span.to > span.from).sort((a, b) => a.from - b.from);
  for (let k = 1; k < spans.length; k++) if (spans[k].from < spans[k - 1].to) errors.push(`${spans[k - 1].i + 1}번째와 ${spans[k].i + 1}번째 기간이 겹칩니다`);
  return errors;
}

/** 카탈로그 항목의 기간을 바꾼다(null이면 칸을 지워 매니페스트 기간으로 돌아간다). 시작 순으로 정렬한다. */
export function withSchedule(catalog, id, schedule) {
  return { ...catalog, packs: (catalog.packs ?? []).map((entry) => {
    if (entry.id !== id) return entry;
    const next = { ...entry };
    if (schedule === null) delete next.schedule;
    else next.schedule = [...schedule].map(({ from, to }) => ({ from, to })).sort((a, b) => Date.parse(a.from) - Date.parse(b.from));
    return next;
  }) };
}

export function withoutPack(catalog, id) {
  return { ...catalog, packs: (catalog.packs ?? []).filter((entry) => entry.id !== id) };
}

// ---- HTTP ----

const JSON_HEADERS = { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" };
const SECURITY_HEADERS = {
  "x-content-type-options": "nosniff", "x-frame-options": "DENY", "referrer-policy": "no-referrer",
  "content-security-policy": "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
};

function send(res, status, body, headers = JSON_HEADERS) {
  res.writeHead(status, { ...SECURITY_HEADERS, ...headers });
  res.end(typeof body === "string" || Buffer.isBuffer(body) ? body : JSON.stringify(body));
}

function readBody(req) {
  return new Promise((resolvePromise, reject) => {
    let size = 0; const chunks = [];
    req.on("data", (chunk) => { size += chunk.length; if (size > MAX_BODY) { reject(new Error("본문이 너무 큽니다")); req.destroy(); } else chunks.push(chunk); });
    req.on("end", () => { try { resolvePromise(chunks.length ? JSON.parse(Buffer.concat(chunks).toString("utf8")) : {}); } catch { reject(new Error("JSON이 아닙니다")); } });
    req.on("error", reject);
  });
}

const sameToken = (given, token) => {
  const a = Buffer.from(String(given ?? "")); const b = Buffer.from(token);
  return a.length === b.length && timingSafeEqual(a, b);
};

export function allowedHost(header, port) {
  return header === `127.0.0.1:${port}` || header === `localhost:${port}`;
}

const STATIC = { "/app.js": ["app.js", "text/javascript; charset=utf-8"], "/app.css": ["app.css", "text/css; charset=utf-8"] };

export function createConsole({ port, token, dryRun = false, now = () => new Date() }) {
  const logs = [];
  let busy = null;
  const log = (line) => { if (!line) return; for (const part of String(line).split("\n")) logs.push(`${now().toLocaleTimeString("ko-KR", { hour12: false })} ${part}`); while (logs.length > 400) logs.shift(); };
  const builds = new Map();

  async function exclusive(label, work) {
    if (busy) throw Object.assign(new Error(`다른 작업(${busy}) 중입니다`), { status: 409 });
    busy = label;
    try { return await work(); } finally { busy = null; }
  }

  const routes = {
    "GET /api/state": async () => ({ config: loadConfig(), configErrors: validateConfig(loadConfig()), dryRun, busy, logs: logs.slice(-200) }),
    "POST /api/config": async (body) => {
      const next = { host: String(body.host ?? "").trim(), bucket: String(body.bucket ?? "").trim(), wranglerConfig: String(body.wranglerConfig ?? "").trim() };
      const errors = validateConfig(next);
      if (errors.length) return { status: 422, body: { errors } };
      writeFileSync(CONFIG_FILE, JSON.stringify(next, null, 2) + "\n");
      log("설정을 저장했습니다");
      return { config: next };
    },
    "GET /api/announcements": async () => currentAnnouncements(loadConfig()),
    "POST /api/announcements/preview": async (body) => planAnnouncements(await currentAnnouncements(loadConfig()), specOf(body)),
    "POST /api/announcements/publish": (body) => exclusive("공지 올리기", async () => {
      const config = loadConfig();
      const current = await currentAnnouncements(config);
      if (Number.isInteger(body.baseVersion) && body.baseVersion !== (current.version ?? 0)) {
        return { status: 409, body: { errors: [`그 사이 서버 공지가 바뀌었습니다(version ${body.baseVersion} → ${current.version}). 새로 읽고 다시 해 주세요.`] } };
      }
      const plan = planAnnouncements(current, specOf(body));
      if (plan.errors.length) return { status: 422, body: plan };
      const dir = join(BUILD_ROOT, `announce-${now().toISOString().replace(/[:.]/g, "-")}`);
      mkdirSync(dir, { recursive: true });
      const file = join(dir, "latest.json");
      writeFileSync(file, JSON.stringify(plan.next, null, 2) + "\n");
      log(`공지 version ${current.version ?? 0} → ${plan.next.version}`);
      await upload({ config, dryRun, log }, ANNOUNCE_KEY, file, "application/json", "public, max-age=300");
      log("공지를 올렸습니다. 앱은 최대 5분(엣지 캐시)+30분(앱 확인 간격) 안에 받습니다.");
      return { ...plan, file: relative(REPO, file), dryRun };
    }),
    "GET /api/packs": async () => {
      let catalog = null, catalogError = null;
      try { catalog = await currentCatalog(loadConfig()); } catch (error) { catalogError = error.message; }
      return { local: localPacks(), catalog, catalogError };
    },
    "POST /api/packs/build": (body) => exclusive("팩 묶기", async () => {
      const pack = localPacks().find((entry) => entry.dir === body.dir && !entry.error);
      if (!pack) return { status: 404, body: { errors: ["목록에 없는 팩 폴더입니다"] } };
      const config = loadConfig();
      const catalog = await currentCatalog(config);
      const live = (catalog.packs ?? []).find((entry) => entry.id === pack.id);
      if (live && live.version >= pack.version && !body.allowSameVersion) {
        return { status: 422, body: { errors: [`서버에 이미 ${pack.id} ${live.version}이(가) 있습니다. 고쳐 올리려면 manifest.json의 version을 ${live.version + 1} 이상으로 올리세요.`] } };
      }
      // 기간: 보내지 않으면 서버의 지금 기간을 이어 쓰고, null이면 매니페스트 기간, 목록이면 그 기간.
      const schedule = body.schedule === undefined ? (live?.schedule ?? null) : body.schedule;
      const scheduleErrors = checkSchedule(schedule);
      if (scheduleErrors.length) return { status: 422, body: { errors: scheduleErrors } };
      const buildId = `${pack.id}-${pack.version}-${now().toISOString().replace(/[:.]/g, "-")}`;
      const dir = join(BUILD_ROOT, buildId);
      mkdirSync(dir, { recursive: true });
      const index = join(dir, "index.json");
      writeFileSync(index, JSON.stringify(catalog, null, 2) + "\n");
      const result = await run("python3", [join(REPO, "scripts/season-pack/build_bpack.py"), join(REPO, pack.dir), "--out", dir, "--index", index], { cwd: REPO });
      log(`$ build_bpack.py ${pack.dir}`);
      log(result.output.split("\n[대표가 직접 실행]")[0]);
      if (!result.ok) return { status: 422, body: { errors: ["묶기 실패 — 기록을 보세요"], output: result.output } };
      const next = withSchedule(JSON.parse(readFileSync(index, "utf8")), pack.id, schedule);
      writeFileSync(index, JSON.stringify(next, null, 2) + "\n");
      const entry = next.packs.find((e) => e.id === pack.id);
      builds.set(buildId, { pack, entry, index, file: join(dir, `${pack.id}-${pack.version}.bpack`) });
      return { buildId, entry, catalogBefore: catalog, catalogAfter: next };
    }),
    "POST /api/packs/publish": (body) => exclusive("팩 올리기", async () => {
      const build = builds.get(body.buildId);
      if (!build) return { status: 404, body: { errors: ["묶은 결과가 없습니다. 다시 묶어 주세요."] } };
      const config = loadConfig();
      // 파일을 먼저, 카탈로그를 나중에: 앱이 아직 없는 파일을 가리키지 않게.
      await upload({ config, dryRun, log }, build.entry.archive.key, build.file, "application/octet-stream", "public, max-age=31536000, immutable");
      await upload({ config, dryRun, log }, CATALOG_KEY, build.index, "application/json", "public, max-age=300");
      builds.delete(body.buildId);
      const check = dryRun ? { skipped: true } : await rangeCheck(config, build.entry.archive.key);
      log(dryRun ? "[연습] 확인 생략" : `이어받기 확인: ${check.ok ? "206 통과" : `실패(${check.status})`}`);
      return { entry: build.entry, check, dryRun };
    }),
    "POST /api/packs/schedule": (body) => exclusive("기간 배포", async () => {
      const schedule = body.schedule === undefined ? null : body.schedule;
      const errors = checkSchedule(schedule);
      if (errors.length) return { status: 422, body: { errors } };
      const config = loadConfig();
      const catalog = await currentCatalog(config);
      if (!(catalog.packs ?? []).some((entry) => entry.id === body.id)) return { status: 404, body: { errors: ["서버 카탈로그에 없는 팩입니다. 먼저 팩을 올리세요."] } };
      const next = withSchedule(catalog, body.id, schedule);
      const dir = join(BUILD_ROOT, `schedule-${body.id}-${now().toISOString().replace(/[:.]/g, "-")}`);
      mkdirSync(dir, { recursive: true });
      const index = join(dir, "index.json");
      writeFileSync(index, JSON.stringify(next, null, 2) + "\n");
      await upload({ config, dryRun, log }, CATALOG_KEY, index, "application/json", "public, max-age=300");
      const spans = next.packs.find((entry) => entry.id === body.id).schedule;
      log(`${body.id} 기간: ${spans === undefined ? "매니페스트 기간 그대로" : spans.length ? spans.map((s) => `${s.from} ~ ${s.to}`).join(", ") : "꺼 둠"}`);
      log("앱은 다음 확인 때(최대 5분 엣지 캐시 + 30분 앱 확인 간격) 새 기간을 따릅니다.");
      return { catalog: next, dryRun };
    }),
    "POST /api/packs/withdraw": (body) => exclusive("팩 내리기", async () => {
      const config = loadConfig();
      const catalog = await currentCatalog(config);
      if (!(catalog.packs ?? []).some((entry) => entry.id === body.id)) return { status: 404, body: { errors: ["서버 카탈로그에 없는 팩입니다"] } };
      const next = withoutPack(catalog, body.id);
      const dir = join(BUILD_ROOT, `withdraw-${body.id}-${now().toISOString().replace(/[:.]/g, "-")}`);
      mkdirSync(dir, { recursive: true });
      const index = join(dir, "index.json");
      writeFileSync(index, JSON.stringify(next, null, 2) + "\n");
      await upload({ config, dryRun, log }, CATALOG_KEY, index, "application/json", "public, max-age=300");
      log(`카탈로그에서 ${body.id}을(를) 뺐습니다. 이미 받은 기기는 그 팩을 계속 갖고, 번들 시드가 있으면 그것을 씁니다.`);
      return { catalog: next, dryRun };
    }),
  };

  async function rangeCheck(config, key) {
    try {
      const response = await fetch(`https://${config.host}/public/assets/${key}`, { headers: { range: "bytes=0-99" } });
      await response.arrayBuffer();
      return { ok: response.status === 206 && /^bytes 0-99\//.test(response.headers.get("content-range") ?? ""), status: response.status };
    } catch (error) { return { ok: false, status: error.message }; }
  }

  return createServer(async (req, res) => {
    if (!allowedHost(req.headers.host, port)) return send(res, 421, { error: "이 맥의 127.0.0.1 주소로만 엽니다" });
    const url = new URL(req.url, `http://127.0.0.1:${port}`);
    if (req.method === "GET" && url.pathname === "/") {
      if (!sameToken(url.searchParams.get("t"), token)) return send(res, 401, "터미널에 찍힌 주소(토큰 포함)로 여세요.", { "content-type": "text/plain; charset=utf-8" });
      const html = readFileSync(join(HERE, "index.html"), "utf8").replace("__TOKEN__", token);
      return send(res, 200, html, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" });
    }
    if (req.method === "GET" && STATIC[url.pathname]) {
      const [file, type] = STATIC[url.pathname];
      return send(res, 200, readFileSync(join(HERE, file)), { "content-type": type, "cache-control": "no-store" });
    }
    if (req.method === "GET" && url.pathname === "/api/pack-file") {
      // <img>·<audio>는 머리글을 못 붙이므로 이 길만 ?t= 토큰도 받는다. 목록에 있는 팩 폴더의 매니페스트 자산만 내준다.
      if (!sameToken(req.headers["x-admin-token"] ?? url.searchParams.get("t"), token)) return send(res, 401, { error: "토큰이 맞지 않습니다" });
      const pack = localPacks().find((entry) => entry.dir === url.searchParams.get("dir") && !entry.error);
      const file = pack?.files.find((entry) => entry.path === url.searchParams.get("path"));
      if (!file) return send(res, 404, { error: "not_found" });
      const type = FILE_TYPES[file.path.split(".").pop().toLowerCase()] ?? "application/octet-stream";
      return send(res, 200, readFileSync(join(REPO, pack.dir, file.path)), { "content-type": type, "cache-control": "no-store" });
    }
    const route = routes[`${req.method} ${url.pathname}`];
    if (!route) return send(res, 404, { error: "not_found" });
    if (!sameToken(req.headers["x-admin-token"], token)) return send(res, 401, { error: "토큰이 맞지 않습니다" });
    if (req.method === "POST" && !(req.headers["content-type"] ?? "").startsWith("application/json")) return send(res, 415, { error: "JSON만 받습니다" });
    try {
      const body = req.method === "POST" ? await readBody(req) : {};
      if (req.method === "POST" && !url.pathname.startsWith("/api/config")) {
        const errors = validateConfig(loadConfig());
        if (errors.length) return send(res, 422, { errors: ["먼저 설정을 채우세요", ...errors] });
      }
      const result = await route(body);
      if (result && typeof result.status === "number" && result.body) return send(res, result.status, result.body);
      return send(res, 200, result);
    } catch (error) {
      log(`오류: ${error.message}`);
      return send(res, error.status ?? 500, { errors: [error.message] });
    }
  });
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const dryRun = process.argv.includes("--dry-run");
  const portFlag = process.argv.indexOf("--port");
  const port = portFlag > 0 ? Number(process.argv[portFlag + 1]) : 8742;
  const token = randomBytes(24).toString("base64url");
  const server = createConsole({ port, token, dryRun });
  server.listen(port, "127.0.0.1", () => {
    const address = `http://127.0.0.1:${port}/?t=${token}`;
    console.log(`BOKKI 운영 페이지${dryRun ? " (연습 모드: 올리지 않음)" : ""}\n  ${address}\n  이 맥에서만 열립니다. 끄려면 Ctrl+C.`);
    if (!process.argv.includes("--no-open")) execFile("open", [address], () => {});
  });
}
