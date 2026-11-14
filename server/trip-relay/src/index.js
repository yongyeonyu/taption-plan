// Taption Plan trip relay (TRP1110A04). An AI assistant POSTs a trip JSON with the user's key;
// the app GETs it on launch, shows a preview, and DELETEs it once the user applies it. Only a SHA-256 hash of the key is
// stored, plans expire after 3 days, and nothing else about the user is kept or logged.
// AIR1110A01/TRP1110A07 add an activity history the app uploads for the AI and a command queue the AI fills for the app.
// AIR1110A02/SEC1110A01 add scoped AI keys, per-user DEK encryption (v2), summaries, a remote MCP endpoint and OpenAPI.
// SEC1110A02 requires registration (/register), adds a PIN, a per-master Durable Object (keys, queue, budgets, PIN tries),
// per-route limits and encrypted metadata. AIR1110A03 adds OAuth 2.1 for MCP connectors and more AI actions.
import * as rules from "./rules.js";
import { createSetup, readSetup } from "./setup.js";
import { fxRoute } from "./fx.js";
import { open, seal, sha256Hex, storageCryptoKey, vault } from "./crypto.js";
import { bearer, json, limited, readBody, tooMany, writeAllowed } from "./http.js";
import { allows, buryLegacyWrap, importLegacyKeys, keyring, keysRoute, pinResetRoute, pinRoute, registerRoute, resealLegacyWrap, resolveKey, sealInfo } from "./keys.js";
import { mcpRoute } from "./mcp.js";
import { authorizeRoute, authorizationServer, createConnectCode, protectedResource, registerClient, resourceMetadataUrl, tokenRoute } from "./oauth.js";
import { openapi } from "./openapi.js";
import { LIMITS, ipState, userState } from "./state.js";
import * as store from "./store.js";

export { open, seal, storageCryptoKey, vault };
export { UserState } from "./state.js";
export { isActivityUpload, isCommand, isCommandResults, isTripPlan } from "./validate.js";

export async function storageKey(token) {
  return "plan:" + (await sha256Hex(token));
}

// Kakao Local keyword search proxy (REV1110A03). The REST key is a server key; shipping it inside the app
// let anyone pull it from the IPA. The app calls this route instead and the key stays a Worker secret.
// SEC1110A02: only registered keys (the install's search key or the master) may call it; 500 a day per key (DO).
// REV1110A06: the per-IP minute limit runs before auth (route), and each IP gets 2,000 searches a day across all its keys.
const KAKAO_URL = "https://dapi.kakao.com/v2/local/search/keyword.json";
const KAKAO_PARAMS = ["query", "x", "y", "radius", "sort", "size", "page"];
// TAU1110A01: 머문 곳 이름 후보. 좌표 주변 카테고리(음식점 FD6·카페 CE7 등) 검색.
const KAKAO_CATEGORY_URL = "https://dapi.kakao.com/v2/local/search/category.json";
const KAKAO_CATEGORY_PARAMS = ["category_group_code", "x", "y", "radius", "sort", "size", "page"];
const CATEGORY_CODE = /^[A-Z]{2}\d$/;

export async function kakaoKeyword(request, env, fetcher = fetch, category = false) {
  if (request.method !== "GET") return json({ error: "method_not_allowed" }, 405);
  if (!env.KAKAO_REST_API_KEY) return json({ error: "unavailable" }, 503);
  const incoming = new URL(request.url).searchParams;
  if (category) {
    const code = incoming.get("category_group_code") ?? "";
    const x = Number(incoming.get("x") ?? NaN), y = Number(incoming.get("y") ?? NaN), radius = Number(incoming.get("radius") ?? 50);
    if (!CATEGORY_CODE.test(code) || !(Math.abs(x) <= 180) || !(Math.abs(y) <= 90) || !(radius >= 1 && radius <= 500)) return json({ error: "bad_query" }, 400);
  } else {
    const query = incoming.get("query") ?? "";
    if (!query.trim() || query.length > 100) return json({ error: "bad_query" }, 400);
  }
  const target = new URL(category ? KAKAO_CATEGORY_URL : KAKAO_URL);
  for (const name of category ? KAKAO_CATEGORY_PARAMS : KAKAO_PARAMS) {
    const value = incoming.get(name);
    if (value !== null) target.searchParams.set(name, value.slice(0, 100));
  }
  const upstream = await fetcher(target, { headers: { authorization: `KakaoAK ${env.KAKAO_REST_API_KEY}` } });
  return new Response(await upstream.text(), {
    status: upstream.status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });
}

// 버스 노선 중계(BRT1113A01, 대표 지시 「버스노선 api 추가하자」). 국토교통부 TAGO(공공데이터포털) 버스정류소 정보.
// 키는 Worker 비밀값 TAGO_SERVICE_KEY(공공데이터포털 「일반 인증키 Decoding」 값)이고 앱에 넣지 않는다. 카카오와 같은 검색 한도를 쓴다.
// /tago/stops?lat&lng: 좌표 근처 정류소(도시 코드·정류소 ID·이름·좌표). /tago/routes?cityCode&nodeId: 그 정류소를 지나는 노선(번호·종류).
const TAGO_BASE = "https://apis.data.go.kr/1613000/BusSttnInfoInqireService/";
const CITY_CODE = /^\d{1,6}$/;
const NODE_ID = /^[A-Z]{3}\d{1,12}$/;

export async function tagoProxy(request, env, fetcher = fetch) {
  if (request.method !== "GET") return json({ error: "method_not_allowed" }, 405);
  if (!env.TAGO_SERVICE_KEY) return json({ error: "unavailable" }, 503);
  const url = new URL(request.url), incoming = url.searchParams;
  let target;
  if (url.pathname === "/tago/stops") {
    const lat = Number(incoming.get("lat") ?? NaN), lng = Number(incoming.get("lng") ?? NaN);
    if (!(Math.abs(lat) <= 90) || !(Math.abs(lng) <= 180)) return json({ error: "bad_query" }, 400);
    target = new URL(TAGO_BASE + "getCrdntPrxmtSttnList");
    target.searchParams.set("gpsLati", String(lat));
    target.searchParams.set("gpsLong", String(lng));
    target.searchParams.set("numOfRows", "10");
  } else {
    const cityCode = incoming.get("cityCode") ?? "", nodeId = incoming.get("nodeId") ?? "";
    if (!CITY_CODE.test(cityCode) || !NODE_ID.test(nodeId)) return json({ error: "bad_query" }, 400);
    target = new URL(TAGO_BASE + "getSttnThrghRouteList");
    target.searchParams.set("cityCode", cityCode);
    target.searchParams.set("nodeid", nodeId);
    target.searchParams.set("numOfRows", "100");
  }
  target.searchParams.set("pageNo", "1");
  target.searchParams.set("_type", "json");
  target.searchParams.set("serviceKey", env.TAGO_SERVICE_KEY);
  const upstream = await fetcher(target);
  return new Response(await upstream.text(), {
    status: upstream.status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });
}

// 서울 시내버스(BRT1113B01): TAGO에서 빠지는 서울은 서울특별시_정류소정보조회로 찾는다. 공공데이터포털 공통 키라 같은 비밀값을 쓴다.
// /seoul/stops?lat&lng: 좌표 근처 정류소(getStationByPos, 반경 100m). /seoul/routes?arsId: 정류소별 경유노선(getRouteByStation).
const SEOUL_BASE = "http://ws.bus.go.kr/api/rest/stationinfo/";
const ARS_ID = /^\d{5}$/;

export async function seoulBusProxy(request, env, fetcher = fetch) {
  if (request.method !== "GET") return json({ error: "method_not_allowed" }, 405);
  if (!env.TAGO_SERVICE_KEY) return json({ error: "unavailable" }, 503);
  const url = new URL(request.url), incoming = url.searchParams;
  let target;
  if (url.pathname === "/seoul/stops") {
    const lat = Number(incoming.get("lat") ?? NaN), lng = Number(incoming.get("lng") ?? NaN);
    if (!(Math.abs(lat) <= 90) || !(Math.abs(lng) <= 180)) return json({ error: "bad_query" }, 400);
    target = new URL(SEOUL_BASE + "getStationByPos");
    target.searchParams.set("tmX", String(lng));
    target.searchParams.set("tmY", String(lat));
    target.searchParams.set("radius", "100");
  } else {
    const arsId = incoming.get("arsId") ?? "";
    if (!ARS_ID.test(arsId)) return json({ error: "bad_query" }, 400);
    target = new URL(SEOUL_BASE + "getRouteByStation");
    target.searchParams.set("arsId", arsId);
  }
  target.searchParams.set("resultType", "json");
  target.searchParams.set("serviceKey", env.TAGO_SERVICE_KEY);
  const upstream = await fetcher(target);
  return new Response(await upstream.text(), {
    status: upstream.status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });
}

async function tagoRoute(request, ctx) {
  if (request.method === "GET" && ctx.env.TAGO_SERVICE_KEY) {
    const perIp = await (await ipState(ctx.env, request)).call("countDaily", { name: "kakao", limit: LIMITS.kakaoPerIpDay, now: ctx.now, expire: true });
    if (!perIp.ok) return tooMany("kakao_daily_limit", perIp.retryAfter);
  }
  return new URL(request.url).pathname.startsWith("/seoul/")
    ? seoulBusProxy(request, ctx.env, ctx.env.FETCH)
    : tagoProxy(request, ctx.env, ctx.env.FETCH);
}

// 경로마다 메서드별로 필요한 범위(AIR1110A02). master > write > read. search는 카카오 중계만.
// read: AI가 읽기만. write: 읽기 + 계획·명령 보내기. 앱 전용(올리기·지우기·큐 가져오기·키·PIN·연결 코드)은 master만.
// 본문이 있는 쓰기는 IP마다 POST_LIMIT을 더 받는다(withBody). legacy: 이 요청 전에 마칠 예전 자료 옮기기.
const withBody = (op) => async (request, ctx) => {
  if (!(await writeAllowed(request, ctx.env))) return tooMany();
  const body = await readBody(request);
  return body.error ?? op(ctx, body.value);
};
const query = (request, name) => new URL(request.url).searchParams.get(name);

// 검색 키는 누구나 등록할 수 있으므로 IP마다 하루 수도 센다(finding 4).
async function kakaoRoute(request, ctx) {
  if (request.method === "GET" && ctx.env.KAKAO_REST_API_KEY) {
    const perIp = await (await ipState(ctx.env, request)).call("countDaily", { name: "kakao", limit: LIMITS.kakaoPerIpDay, now: ctx.now, expire: true });
    if (!perIp.ok) return tooMany("kakao_daily_limit", perIp.retryAfter);
  }
  return kakaoKeyword(request, ctx.env, ctx.env.FETCH, new URL(request.url).pathname === "/kakao/category"); // FETCH: 시험용 바꿔치기
}

const ROUTES = {
  "/plan": {
    GET: ["read", (request, ctx) => store.readPlan(ctx)],
    POST: ["write", withBody(store.savePlan)],
    DELETE: ["master", (request, ctx) => store.deletePlan(ctx)],
  },
  "/activity": {
    GET: ["read", (request, ctx) => store.readActivity(ctx, query(request, "date"))],
    POST: ["master", withBody(store.saveActivity)],
    DELETE: ["master", (request, ctx) => store.deleteActivity(ctx)],
  },
  "/activity/summary": {
    GET: ["read", (request, ctx) => store.readSummary(ctx, query(request, "range"), query(request, "end"))],
  },
  "/command": {
    POST: ["write", withBody((ctx, value) => store.queueCommand(ctx, value, "rest"))],
    GET: ["master", (request, ctx) => store.readCommands(ctx)],
    DELETE: ["master", (request, ctx) => store.deleteCommands(ctx, query(request, "ids"))],
  },
  "/session/end": {
    POST: ["read", (request, ctx) => store.endConversation(ctx)],
  },
  "/polish": {
    GET: ["read", (request, ctx) => store.readPolish(ctx)],
    POST: ["master", withBody(store.savePolish)],
    DELETE: ["master", (request, ctx) => store.deletePolish(ctx)],
  },
  // ASK1112A01: AI가 물은 질문과 사용자의 답. 앱이 올리고 AI가 읽는다.
  "/answers": {
    GET: ["read", (request, ctx) => store.readAnswers(ctx)],
    POST: ["master", withBody(store.saveAnswers)],
    DELETE: ["master", (request, ctx) => store.deleteAnswers(ctx)],
  },
  // ACX1112A01: 앱 상태(설정·가계부·확인 필요·받은 문자·규칙). 앱이 올리고 AI가 읽는다.
  "/app": {
    GET: ["read", (request, ctx) => store.readAppState(ctx)],
    POST: ["master", withBody(store.saveAppState)],
    DELETE: ["master", (request, ctx) => store.deleteAppState(ctx)],
  },
  "/tasks": {
    GET: ["read", (request, ctx) => store.readTasks(ctx, request)],
    POST: ["master", withBody(store.saveTasks)],
    DELETE: ["master", (request, ctx) => store.deleteFinishedTasks(ctx)],
  },
  // 규칙 저장소(AIX1114A01 P3). AI는 읽고 더하고 자기 것을 지운다. 사용자가 고친 것은 앱이 주인 키로 올린다.
  "/rules": {
    GET: ["read", (request, ctx) => rules.readRules(ctx, query(request, "since"))],
    POST: ["write", withBody(rules.putRules)],
    DELETE: ["write", (request, ctx) => rules.deleteRules(ctx, query(request, "ids"))],
  },
  "/rules/ops": {
    POST: ["master", withBody(rules.applyRuleOps)],
  },
  "/rules/ack": {
    POST: ["master", withBody(rules.ackRules)],
  },
  "/tasks/claim": {
    POST: ["read", (request, ctx) => store.claimTasks(ctx)],
  },
  "/tasks/result": {
    POST: ["read", withBody(store.finishTask)],
  },
  "/command/result": {
    POST: ["master", withBody(store.saveResults)],
    GET: ["read", (request, ctx) => store.readResults(ctx)],
  },
  "/keys": {
    POST: ["master", keysRoute, "keys"],
    GET: ["master", keysRoute, "keys"],
    DELETE: ["master", keysRoute, "keys"],
  },
  "/pin": {
    POST: ["master", pinRoute],
    GET: ["master", pinRoute],
  },
  "/setup": {
    POST: ["master", createSetup],
  },
  "/pin/reset": {
    POST: ["master", pinResetRoute],
  },
  "/oauth/code": {
    POST: ["master", createConnectCode],
  },
  "/mcp": {
    POST: ["read", mcpRoute], // 도구마다 범위를 다시 본다.
  },
  "/kakao/keyword": {
    GET: ["search", kakaoRoute],
  },
  "/kakao/category": {
    GET: ["search", kakaoRoute],
  },
  "/tago/stops": {
    GET: ["search", tagoRoute],
  },
  "/tago/routes": {
    GET: ["search", tagoRoute],
  },
  "/seoul/stops": {
    GET: ["search", tagoRoute],
  },
  "/seoul/routes": {
    GET: ["search", tagoRoute],
  },
  "/fx": {
    GET: ["search", fxRoute],
  },
};

// 인증 없이 받는 경로. OAuth 메타데이터·등록·토큰은 브라우저 클라이언트도 부를 수 있게 CORS를 연다.
const PUBLIC = {
  "/openapi.json": (request, env, url) => json(openapi(url.origin), 200),
  "/.well-known/oauth-protected-resource": (request, env, url) => json(protectedResource(url.origin), 200),
  "/.well-known/oauth-protected-resource/mcp": (request, env, url) => json(protectedResource(url.origin), 200),
  "/.well-known/oauth-authorization-server": (request, env, url) => json(authorizationServer(url.origin), 200),
};
const CORS = { "access-control-allow-origin": "*", "access-control-allow-headers": "authorization, content-type, mcp-protocol-version", "access-control-allow-methods": "GET, POST, OPTIONS" };
const CORS_PATHS = new Set([...Object.keys(PUBLIC), "/oauth/register", "/oauth/token", "/mcp"]);

function withCors(response) {
  const out = new Response(response.body, response);
  for (const [name, value] of Object.entries(CORS)) out.headers.set(name, value);
  return out;
}

// /mcp의 401은 보호 자원 메타데이터를 가리켜 OAuth를 시작하게 한다(RFC 9728). 토큰이 있었는데 틀렸을 때만 invalid_token.
const unauthorized = (url, error, hadToken) => json({ error }, 401, url.pathname === "/mcp"
  ? { "www-authenticate": `Bearer resource_metadata="${resourceMetadataUrl(url.origin)}"${hadToken && error !== "unregistered" ? ", error=\"invalid_token\"" : ""}` }
  : {});

// 예전 v2 감싼 기록으로 들어온 키는 DO가 목록에 넣도록(adopt) 잠근 정보를 같이 보낸다.
async function adoptInfo(auth) {
  if (!auth.legacyWrap) return undefined;
  const ring = keyring({ scope: auth.scope, dekBytes: auth.dekBytes });
  return { keyId: auth.keyId, info: await sealInfo(ring, auth.master, auth.hash, { scope: auth.scope, expiresAt: auth.expiresAt, source: "rest" }) };
}

// 앱이 보내는 `x-bokki-client: <기기 종류 식별자>;<빌드>;<공유 수준>[;debug][;locked]`(AIC1112A01·AIL1112A01). 모양이 다르면 버린다.
// locked: 사생활 잠금 중이라 앱이 하루 기록 올리기를 쉬고 있다.
const CLIENT_FLAGS = ["debug", "locked"];
export function clientInfo(header) {
  const [device, appBuild, shareLevel, ...flags] = (header ?? "").split(";");
  if (!/^[A-Za-z][A-Za-z0-9,]{0,23}$/.test(device) || !/^\d{1,8}$/.test(appBuild ?? "") || !["off", "summary", "visits"].includes(shareLevel)
    || flags.some((flag) => !CLIENT_FLAGS.includes(flag)) || new Set(flags).size !== flags.length) return undefined;
  return { device, appBuild, shareLevel, ...(flags.includes("debug") ? { debugBuild: true } : {}), ...(flags.includes("locked") ? { uploadsPaused: "privacyLock" } : {}) };
}

async function authorized(request, env, url, route, pathKey = null) {
  const token = pathKey ?? bearer(request);
  const now = env.NOW?.() ?? Date.now(); // 시험에서 시계를 바꿀 수 있게 한다.
  const auth = token ? await resolveKey(env.PLANS, token, now) : null;
  if (!auth) return unauthorized(url, "unauthorized", !!request.headers.get("authorization") || !!pathKey);
  // 주소에 넣는 키는 AI 연결 키만 된다. 주 키(앱·검색)는 주소에 두지 않는다(CLD1110A01).
  if (pathKey && auth.kind !== "key") return json({ error: "forbidden" }, 403);
  const entry = route[request.method];
  if (!entry) return json({ error: "method_not_allowed" }, 405);
  const [need, run, part] = entry;
  const state = userState(env, auth.master);
  const admission = await state.call("admit", {
    now, registration: auth.kind === "master", entry: auth.entry, adopt: await adoptInfo(auth), kakao: url.pathname.startsWith("/kakao/") || url.pathname.startsWith("/tago/") || url.pathname.startsWith("/seoul/"),
    client: auth.kind === "master" ? clientInfo(request.headers.get("x-bokki-client")) : undefined,
  });
  if (!admission.ok) {
    if (admission.tomb) await buryLegacyWrap(env.PLANS, auth.hash);
    if (admission.retryAfter) return tooMany(admission.error, admission.retryAfter);
    return unauthorized(url, admission.error === "unregistered" ? "unregistered" : "unauthorized", true);
  }
  if (admission.purpose === "search") auth.scope = "search";
  if (!allows(auth.scope, need)) return json({ error: "forbidden", scope: auth.scope }, 403);
  const ring = keyring(auth);
  const ctx = { env, kv: env.PLANS, store: vault(env.PLANS, ring, now), state, auth, ring, master: auth.master, now, legacy: admission.legacy };
  if (auth.legacyWrap) await resealLegacyWrap(ctx);
  if (part === "keys" && !ctx.legacy.keys) await importLegacyKeys(ctx);
  return run(request, ctx);
}

export async function handle(request, env) {
  const url = new URL(request.url);
  const cors = CORS_PATHS.has(url.pathname);
  if (request.method === "OPTIONS" && cors) return new Response(null, { status: 204, headers: CORS });
  const response = await route(request, env, url);
  return cors ? withCors(response) : response;
}

const MCP_KEY_PATH = /^\/mcp\/([A-Za-z0-9_-]{43})$/;
const SETUP_PATH = /^\/s\/([A-Za-z0-9]{1,20})$/;

async function route(request, env, url) {
  const now = env.NOW?.() ?? Date.now();
  const publicRoute = PUBLIC[url.pathname];
  if (publicRoute) return request.method === "GET" ? publicRoute(request, env, url) : json({ error: "method_not_allowed" }, 405);
  if (!env.USER_STATE) return json({ error: "unavailable" }, 503);
  // 인증 전에 IP마다 요청 수를 제한한다(finding 3). 카카오는 자기 제한(KAKAO_LIMIT)을 쓴다(N2: 이것도 인증 전).
  if (await limited(url.pathname.startsWith("/kakao/") || url.pathname.startsWith("/tago/") || url.pathname.startsWith("/seoul/") ? env.KAKAO_LIMIT : env.REQUEST_LIMIT, request)) return tooMany();
  switch (url.pathname) {
    case "/register": return registerRoute(request, env, now);
    case "/oauth/register": return registerClient(request, env, now);
    case "/oauth/authorize": return authorizeRoute(request, env, now);
    case "/oauth/token": return tokenRoute(request, env, now);
    default: {
      // Claude 맞춤 커넥터 「로그인 없음」용: `/mcp/<연결 키>`(CLD1110A01). 모바일에서 주소 하나만 붙여 넣는다.
      const setup = SETUP_PATH.exec(url.pathname);
      if (setup) return request.method === "GET" ? readSetup(env, setup[1], now) : json({ error: "method_not_allowed" }, 405);
      const keyed = MCP_KEY_PATH.exec(url.pathname);
      if (keyed) return authorized(request, env, url, ROUTES["/mcp"], keyed[1]);
      const entry = ROUTES[url.pathname];
      return entry ? authorized(request, env, url, entry) : json({ error: "not_found" }, 404);
    }
  }
}

export default {
  fetch(request, env) {
    return handle(request, env);
  },
};
