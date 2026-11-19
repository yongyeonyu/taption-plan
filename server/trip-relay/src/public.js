// R2PUB1119A01: 모두에게 같은 공용 정적 데이터(전체 공지·POI 팩·온디바이스 모델)를 R2 버킷에서 읽기 전용으로 준다.
// 인증도 CORS도 속도 제한도 없다(앱은 네이티브). Worker는 R2에 쓰지 않는다 — 올리는 길은 대표의 `wrangler r2 object put --remote`뿐이다.
import { json } from "./http.js";

const ANNOUNCEMENTS_PATH = "/public/announcements";
const ASSETS_PREFIX = "/public/assets/";
const ANNOUNCEMENTS_KEY = "announcements/latest.json";
const ALLOWED_PREFIXES = new Set(["announcements", "packs", "models"]);
const CELL = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const MAX_CELLS = 8;
const MAX_KEY_LENGTH = 200;
const SHORT_CACHE = "public, max-age=300";
const LONG_CACHE = "public, max-age=86400";
const CONTENT_TYPES = {
  json: "application/json; charset=utf-8", jpg: "image/jpeg", jpeg: "image/jpeg", png: "image/png", webp: "image/webp",
  mlmodelc: "application/octet-stream", mlpackage: "application/octet-stream", zip: "application/zip",
};

const empty = () => json({ version: 0, items: [] }, 200);
const notAllowed = () => json({ error: "method_not_allowed" }, 405, { allow: "GET" });
const notModified = (etag, cacheControl) => new Response(null, { status: 304, headers: { etag, "cache-control": cacheControl } });

// 이 경로가 아니면 null. 맞으면 Response. 공용 길은 인증보다 앞에서 가로챈다.
export async function publicRoute(request, env, exec) {
  const path = new URL(request.url).pathname;
  if (path === ANNOUNCEMENTS_PATH) return request.method === "GET" ? announcements(request, env, exec) : notAllowed();
  if (path.startsWith(ASSETS_PREFIX) || path === "/public/assets") return request.method === "GET" ? asset(request, env, path) : notAllowed();
  return null;
}

// 공지: 버킷·파일이 없거나 JSON이 깨졌어도 앱이 깨지지 않게 항상 200과 빈 목록을 준다. 본문은 고치지 않고 그대로 돌려준다.
async function announcements(request, env, exec) {
  const bucket = env.PUBLIC_BUCKET;
  if (!bucket) return empty();
  const cache = edgeCache();
  const cached = cache ? await cache.match(cacheKey(request)) : undefined;
  if (cached) return matches(request, cached.headers.get("etag")) ? notModified(cached.headers.get("etag"), SHORT_CACHE) : cached;
  let object;
  try { object = await bucket.get(ANNOUNCEMENTS_KEY, { onlyIf: request.headers }); } catch { return empty(); }
  if (!object) return empty();
  if (!object.body) return notModified(object.httpEtag, SHORT_CACHE);
  let text;
  try {
    text = await object.text();
    if (!Array.isArray(JSON.parse(text)?.items)) return empty();
  } catch { return empty(); }
  const response = new Response(text, { status: 200, headers: { "content-type": CONTENT_TYPES.json, etag: object.httpEtag, "cache-control": SHORT_CACHE } });
  if (cache && !request.headers.has("if-none-match")) {
    const put = cache.put(cacheKey(request), response.clone());
    if (exec?.waitUntil) exec.waitUntil(put); else await put;
  }
  return response;
}

// 에셋: 키 모양이 틀리면 400(정규화하지 않고 거부), 허용 접두어 밖은 404.
async function asset(request, env, path) {
  const rest = path.slice(ASSETS_PREFIX.length);
  if (rest === "") return json({ error: "not_found" }, 404);
  const parts = rest.split("/");
  if (!ALLOWED_PREFIXES.has(parts[0])) return json({ error: "not_found" }, 404);
  const bare = parts.at(-1) === "";
  if (bare) parts.pop();
  if (parts.length > MAX_CELLS || rest.length > MAX_KEY_LENGTH || !parts.every((cell) => CELL.test(cell))) return json({ error: "invalid_key" }, 400);
  if (bare || parts.length < 2) return json({ error: "not_found" }, 404);
  const bucket = env.PUBLIC_BUCKET;
  if (!bucket) return json({ error: "not_found" }, 404);
  const key = parts.join("/");
  const cacheControl = parts[0] === "announcements" ? SHORT_CACHE : LONG_CACHE;
  let object;
  try { object = await bucket.get(key, { range: request.headers, onlyIf: request.headers }); } catch { return json({ error: "range_not_satisfiable" }, 416); }
  if (!object) return json({ error: "not_found" }, 404);
  if (!object.body) return notModified(object.httpEtag, cacheControl);
  const headers = new Headers();
  object.writeHttpMetadata?.(headers);
  if (!headers.has("content-type")) headers.set("content-type", CONTENT_TYPES[key.slice(key.lastIndexOf(".") + 1).toLowerCase()] ?? "application/octet-stream");
  headers.set("etag", object.httpEtag);
  headers.set("accept-ranges", "bytes");
  headers.set("cache-control", cacheControl);
  const range = request.headers.has("range") ? object.range : undefined;
  if (range) {
    const offset = range.offset ?? Math.max(0, object.size - (range.suffix ?? 0));
    const length = range.length ?? object.size - offset;
    headers.set("content-range", `bytes ${offset}-${offset + length - 1}/${object.size}`);
    headers.set("content-length", String(length));
    return new Response(object.body, { status: 206, headers });
  }
  headers.set("content-length", String(object.size));
  return new Response(object.body, { status: 200, headers });
}

const matches = (request, etag) => etag && (request.headers.get("if-none-match") ?? "").split(",").some((tag) => tag.trim().replace(/^W\//, "") === etag);
const edgeCache = () => (typeof caches !== "undefined" && caches.default ? caches.default : null);
const cacheKey = (request) => new Request(new URL(request.url).origin + ANNOUNCEMENTS_PATH);
