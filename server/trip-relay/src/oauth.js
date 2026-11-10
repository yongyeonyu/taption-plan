// MCP 인증용 OAuth 2.1(AIR1110A03). claude.ai·ChatGPT 커넥터가 쓴다.
// 흐름: 클라이언트 동적 등록 → 승인 화면(앱이 보여 준 8자 「연결 코드」 + 6자리 PIN) → 승인 코드 → 토큰(PKCE S256) → /mcp → refresh.
// 토큰은 64자라 주인·연결 키(43자)와 섞이지 않는다. access 8시간, refresh 90일(하루에 한 번 바뀜, 바뀐 뒤 1분이 지나
// 예전 것이 다시 오면 연결 폐기). REV1110A06: KV 쓰기를 줄이려고 access 수명을 늘리고 refresh를 매번 바꾸지 않는다.
// 연결(grant)은 DO 키 목록의 한 줄이다: GET /keys에 source "oauth"·client 이름으로 보이고 DELETE /keys?id=로 끊는다.
import {
  deriveToken, fromBase64, importDek, openJson, pepperedKey, randomHex, randomToken, sameText, sealJson, sha256Base64Url, sha256Hex,
  toBase64, wrapCryptoKey,
} from "./crypto.js";
import { escapeHtml, json, limited, readText, tooMany } from "./http.js";
import { isoSeconds, keyring, readWrap, sealInfo, verifyPin, writeWrap } from "./keys.js";
import { LIMITS, chargeWrites, countPerIpAndGlobal, userState } from "./state.js";
import { stripInvisible } from "./validate.js";

export const ACCESS_SECONDS = 8 * 3600;
const REFRESH_DAYS = 90;
const AUTH_CODE_SECONDS = 120;
const CONNECT_SECONDS = 600;
// 등록만 하고 쓰지 않은 클라이언트는 7일, 연결에 쓰이면 1년(30일마다 다시 셈)(N1, N13).
const CLIENT_UNUSED_TTL_SECONDS = 7 * 86400;
const CLIENT_TTL_SECONDS = 365 * 86400;
const CLIENT_RENEW_MS = 30 * 86400_000;
const CONNECT_ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"; // 헷갈리는 0·O·1·I 없음, 32자 × 8 = 40비트
const CSRF_COOKIE = "__Host-tp_csrf";
// 규격 그대로(phase3-contract). 승인 뒤 이동은 form-action에 걸리지 않게 302 대신 meta refresh 화면으로 한다.
export const AUTHORIZE_CSP = "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'";
const SCOPES = ["read", "write"];
const AUTH_METHODS = ["none", "client_secret_post", "client_secret_basic"];

const connectName = (hash) => "ocode:" + hash;
const authCodeName = (hash) => "oauthcode:" + hash;
const clientName = (id) => "oclient:" + id;

// MARK: 메타데이터 (RFC 9728, RFC 8414)

export const resourceMetadataUrl = (origin) => `${origin}/.well-known/oauth-protected-resource`;

export function protectedResource(origin) {
  return {
    resource: `${origin}/mcp`,
    authorization_servers: [origin],
    scopes_supported: SCOPES,
    bearer_methods_supported: ["header"],
    resource_name: "Taption Plan",
  };
}

export function authorizationServer(origin) {
  return {
    issuer: origin,
    authorization_endpoint: `${origin}/oauth/authorize`,
    token_endpoint: `${origin}/oauth/token`,
    registration_endpoint: `${origin}/oauth/register`,
    response_types_supported: ["code"],
    grant_types_supported: ["authorization_code", "refresh_token"],
    code_challenge_methods_supported: ["S256"],
    token_endpoint_auth_methods_supported: AUTH_METHODS,
    scopes_supported: SCOPES,
    authorization_response_iss_parameter_supported: true,
  };
}

const oauthError = (status, error, description) => json({ error, ...(description ? { error_description: description } : {}) }, status, { pragma: "no-cache" });

// MARK: 연결 코드 (앱, 주인 키)

function connectCode() {
  const bytes = crypto.getRandomValues(new Uint8Array(8));
  return [...bytes].map((b) => CONNECT_ALPHABET[b & 31]).join("");
}
const normalizeCode = (text) => String(text ?? "").toUpperCase().replace(/[\s-]/g, "");
const codeHash = (code) => sha256Hex("connect|" + code);

const codeState = (env, hash) => userState(env, "code:" + hash);
const codeKey = (env, code) => pepperedKey(env.PIN_PEPPER, "connect|" + code);

// POST /oauth/code: 10분 동안 한 번 쓰는 8자 코드. PIN이 먼저 있어야 한다.
// 기록은 KV가 아니라 코드마다의 DO에 두고, 서버 비밀(PIN_PEPPER)과 코드로 잠근다(N15). KV 쓰기도 없다.
export async function createConnectCode(request, ctx) {
  if (await limited(ctx.env.POST_LIMIT, request)) return tooMany();
  if (!ctx.env.PIN_PEPPER) return json({ error: "pin_check_unavailable" }, 503);
  const pin = await ctx.state.call("getPin", { now: ctx.now });
  if (!pin.sealed) return json({ error: "pin_not_set" }, 409);
  const code = connectCode();
  const hash = await codeHash(code);
  const expiresAt = ctx.now + CONNECT_SECONDS * 1000;
  const payload = { master: ctx.master, dek: toBase64(await ctx.ring.dekBytes()), expiresAt, epoch: pin.epoch };
  await codeState(ctx.env, hash).call("putCode", { sealed: await sealJson(await codeKey(ctx.env, code), connectName(hash), payload), expiresAt });
  return json({ code, expiresAt: isoSeconds(expiresAt), expiresIn: CONNECT_SECONDS, expiresInSeconds: CONNECT_SECONDS }, 201);
}

async function openConnectCode(env, code, hash, now) {
  if (!env.PIN_PEPPER) return null;
  const { sealed } = await codeState(env, hash).call("getCode", { now });
  const record = sealed ? await openJson(await codeKey(env, code), connectName(hash), sealed) : null;
  return record && record.expiresAt > now ? record : null;
}

// MARK: 동적 클라이언트 등록 (RFC 7591)

function redirectAllowed(uri) {
  if (typeof uri !== "string" || uri.length > 500) return false;
  let url;
  try { url = new URL(uri); } catch { return false; }
  if (url.hash || url.username || url.password) return false;
  if (url.protocol === "https:") return true;
  // Claude Code·Gemini CLI 같은 기기 안 클라이언트.
  return url.protocol === "http:" && ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
}

// 화면과 앱 목록에 보일 이름: 보이지 않는 글자·방향 바꿈 글자를 지우고 공백을 하나로 줄인다(N4).
const clientDisplayName = (value) => (typeof value === "string" ? stripInvisible(value).replace(/\s+/g, " ").trim().slice(0, 100) : "") || "AI app";
const hostOf = (uri) => new URL(uri).host;

export async function registerClient(request, env, now) {
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (await limited(env.POST_LIMIT, request)) return tooMany();
  const text = await readText(request, 8 * 1024);
  if (text.error) return text.error;
  let body;
  try { body = JSON.parse(text.value); } catch { return oauthError(400, "invalid_client_metadata", "Body must be JSON"); }
  const uris = body?.redirect_uris;
  if (!Array.isArray(uris) || uris.length < 1 || uris.length > 10 || !uris.every(redirectAllowed)) {
    return oauthError(400, "invalid_redirect_uri", "redirect_uris: 1-10 https (or http loopback) URLs without fragments");
  }
  const method = body.token_endpoint_auth_method ?? "client_secret_basic"; // RFC 7591 기본값
  if (!AUTH_METHODS.includes(method)) return oauthError(400, "invalid_client_metadata", "Unsupported token_endpoint_auth_method");
  const grants = body.grant_types ?? ["authorization_code", "refresh_token"];
  if (!Array.isArray(grants) || !grants.every((g) => g === "authorization_code" || g === "refresh_token")) {
    return oauthError(400, "invalid_client_metadata", "grant_types: authorization_code, refresh_token");
  }
  if (body.response_types !== undefined && !(Array.isArray(body.response_types) && body.response_types.every((t) => t === "code"))) {
    return oauthError(400, "invalid_client_metadata", "response_types: code");
  }
  // 인증 없이 KV에 쓰는 경로라 IP마다·서버 전체로 하루 수를 둔다(N1).
  const counted = await countPerIpAndGlobal(env, request, "oauthClients", LIMITS.oauthClientsPerIpDay, LIMITS.oauthClientsPerDay, now);
  if (!counted.ok) return tooMany("rate_limited", counted.retryAfter);
  const charge = await chargeWrites(env, null, 1, now);
  if (!charge.ok) return tooMany(charge.error, charge.retryAfter);
  const name = clientDisplayName(body.client_name);
  const id = randomToken(16);
  const secret = method === "none" ? null : randomToken(32);
  const record = { name, redirectUris: uris, method, secretHash: secret ? await sha256Hex(secret) : null, createdAt: now };
  await env.PLANS.put(clientName(id), JSON.stringify(record), { expirationTtl: CLIENT_UNUSED_TTL_SECONDS });
  return json({
    client_id: id, client_id_issued_at: Math.floor(now / 1000),
    ...(secret ? { client_secret: secret, client_secret_expires_at: 0 } : {}),
    client_name: name, redirect_uris: uris, token_endpoint_auth_method: method,
    grant_types: ["authorization_code", "refresh_token"], response_types: ["code"],
  }, 201);
}

async function loadClient(env, id) {
  if (typeof id !== "string" || !/^[A-Za-z0-9_-]{22}$/.test(id)) return null;
  try { return { id, ...JSON.parse((await env.PLANS.get(clientName(id))) ?? "null") }; } catch { return null; }
}

// 연결에 쓰인 클라이언트 기록을 1년으로 늘린다. 30일에 한 번만 쓴다(N13).
const renewDue = (client, now) => now - (client.renewedAt ?? 0) >= CLIENT_RENEW_MS;
async function renewClient(env, client, now) {
  if (!renewDue(client, now)) return;
  const { id, ...record } = client;
  await env.PLANS.put(clientName(id), JSON.stringify({ ...record, renewedAt: now }), { expirationTtl: CLIENT_TTL_SECONDS });
}

// MARK: 승인 화면

const PARAMS = ["response_type", "client_id", "redirect_uri", "code_challenge", "code_challenge_method", "state", "scope", "resource"];

function scopeOf(text) {
  const words = String(text ?? "").split(/\s+/).filter(Boolean);
  if (!words.every((w) => SCOPES.includes(w))) return null;
  return words.length === 0 || words.includes("write") ? "write" : "read";
}

// { client, params } 또는 { fatal } (돌려보낼 수 없음) 또는 { redirect, description } (오류를 돌려보낼 주소).
async function checkRequest(env, origin, get) {
  const p = Object.fromEntries(PARAMS.map((name) => [name, get(name) ?? ""]));
  const client = await loadClient(env, p.client_id);
  if (!client?.redirectUris) return { fatal: "알 수 없는 앱이에요. · Unknown client." };
  if (!p.redirect_uri && client.redirectUris.length === 1) p.redirect_uri = client.redirectUris[0];
  if (!client.redirectUris.includes(p.redirect_uri)) return { fatal: "돌아갈 주소가 등록되지 않았어요. · Unregistered redirect_uri." };
  const back = (error, description) => ({ description, redirect: redirectTo(p.redirect_uri, { error, error_description: description, state: p.state, iss: origin }) });
  if (p.response_type !== "code") return back("unsupported_response_type", "response_type must be code");
  if (p.code_challenge_method !== "S256" || !/^[A-Za-z0-9._~-]{43,128}$/.test(p.code_challenge)) return back("invalid_request", "PKCE S256 code_challenge required");
  const scope = scopeOf(p.scope);
  if (!scope) return back("invalid_scope", "scope: read or write");
  if (p.resource && ![`${origin}/mcp`, origin, `${origin}/`].includes(p.resource)) return back("invalid_target", "Unknown resource");
  return { client, params: { ...p, scope } };
}

function redirectTo(base, values) {
  const url = new URL(base);
  for (const [name, value] of Object.entries(values)) if (value) url.searchParams.set(name, value);
  return url.toString();
}

const STYLE = "body{font:16px/1.5 -apple-system,system-ui,sans-serif;max-width:420px;margin:40px auto;padding:0 16px;color:#222;background:#fff}"
  + "h1{font-size:20px}label{display:block;margin:14px 0 4px}input{width:100%;box-sizing:border-box;font-size:18px;padding:8px;border:1px solid #999;border-radius:6px}"
  + "button{font-size:16px;padding:10px 16px;margin:16px 8px 0 0;border-radius:6px;border:1px solid #555;background:#fff}"
  + "button.primary{background:#1d5bd8;color:#fff;border-color:#1d5bd8}.err{color:#b00020}.host{font-size:18px;word-break:break-all}.note{color:#555;font-size:14px}"
  + "@media(prefers-color-scheme:dark){body{background:#111;color:#eee}input,button{background:#222;color:#eee}}";

function htmlPage(title, body, { status = 200, headers = {} } = {}) {
  const html = `<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">`
    + `<meta name="referrer" content="same-origin"><title>${escapeHtml(title)}</title><style>${STYLE}</style></head><body>${body}</body></html>`;
  return new Response(html, {
    status,
    headers: {
      "content-type": "text/html; charset=utf-8", "cache-control": "no-store", "content-security-policy": AUTHORIZE_CSP,
      "x-frame-options": "DENY", "referrer-policy": "same-origin", "x-content-type-options": "nosniff", ...headers,
    },
  });
}

const errorPage = (message, status = 400, headers = {}) => htmlPage("Taption Plan", `<h1>Taption Plan</h1><p class="err">${escapeHtml(message)}</p>`, { status, headers });

// 승인 뒤 클라이언트로 돌아가는 화면. 302는 CSP form-action에 막히는 브라우저가 있어 meta refresh를 쓴다.
function withMeta(target) {
  return htmlPage("Taption Plan",
    `<meta http-equiv="refresh" content="0;url=${escapeHtml(target)}"><p>앱으로 돌아가는 중… · Returning to the app…</p>`
    + `<p><a href="${escapeHtml(target)}">계속 · Continue</a></p>`);
}

// 승인 전의 오류는 저절로 넘기지 않는다(N5). 등록된 주소라도 사용자가 눌러야 간다.
function requestErrorPage(checked) {
  const host = hostOf(checked.redirect);
  return htmlPage("Taption Plan", `<h1>Taption Plan</h1><p class="err">연결 요청이 올바르지 않아요. · This connection request is not valid.</p>`
    + `<p class="note">${escapeHtml(checked.description)}</p>`
    + `<p><a href="${escapeHtml(checked.redirect)}" rel="noreferrer">${escapeHtml(host)}(으)로 돌아가기 · Return to ${escapeHtml(host)}</a></p>`, { status: 400 });
}

function approvalPage(client, params, csrf, message) {
  const hidden = PARAMS.map((name) => `<input type="hidden" name="${name}" value="${escapeHtml(params[name])}">`).join("");
  const scope = params.scope === "write"
    ? "기록 읽기와 고치기(되돌릴 수 있음) · Read your records and send undoable edits"
    : "기록 읽기만 · Read your records only";
  const body = `<h1>AI 연결 승인 · Approve AI connection</h1>`
    + `<p><b>${escapeHtml(client.name)}</b> 앱이 Taption Plan에 연결하려고 해요. · wants to connect to Taption Plan.</p>`
    + `<p>승인하면 돌아가는 곳 · After approval you return to: <b class="host">${escapeHtml(hostOf(params.redirect_uri))}</b></p>`
    + `<p class="note">앱 이름은 그 앱이 적어 보낸 것이라 확인되지 않았어요. 위 주소가 내가 쓰는 AI 서비스의 주소인지 보고, 내가 직접 시작한 연결일 때만 승인하세요. · `
    + `The app name is self-reported and unverified. Approve only if the address above belongs to the AI service you use and you started this connection yourself.</p>`
    + `<p>요청 범위 · Requested access: <b>${escapeHtml(scope)}</b></p>`
    + (message ? `<p class="err">${escapeHtml(message)}</p>` : "")
    + `<form method="post" action="/oauth/authorize">${hidden}<input type="hidden" name="csrf" value="${escapeHtml(csrf)}">`
    + `<label for="code">연결 코드 · Connection code (앱 → 메인 메뉴 → 연결 → AI 연결)</label>`
    + `<input id="code" name="connect_code" autocomplete="off" autocapitalize="characters" maxlength="9" required>`
    + `<label for="pin">PIN (6자리 · 6 digits)</label>`
    + `<input id="pin" name="pin" type="password" inputmode="numeric" pattern="[0-9]{6}" maxlength="6" autocomplete="off" required>`
    + `<button class="primary" name="decision" value="approve">승인 · Approve</button>`
    + `<button name="decision" value="deny" formnovalidate>거절 · Deny</button></form>`
    + `<p class="note">코드는 10분 동안 한 번만 쓸 수 있어요. PIN을 5번 틀리면 15분 동안 잠겨요. · The code works once for 10 minutes; 5 wrong PINs lock approval for 15 minutes.</p>`;
  return htmlPage("AI 연결 승인 · Approve", body, {
    headers: { "set-cookie": `${CSRF_COOKIE}=${csrf}; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=${CONNECT_SECONDS}` },
  });
}

function cookie(request, name) {
  for (const part of (request.headers.get("cookie") ?? "").split(";")) {
    const [key, ...rest] = part.trim().split("=");
    if (key === name) return rest.join("=");
  }
  return null;
}

const PIN_MESSAGES = {
  pin_required: "PIN 6자리를 넣어 주세요. · Enter your 6-digit PIN.",
  pin_not_set: "먼저 앱에서 PIN을 만들어 주세요. · Set a PIN in the app first.",
  pin_locked: "PIN을 여러 번 틀려 15분 동안 잠겼어요. · Too many wrong PINs; locked for 15 minutes.",
  pin_check_unavailable: "지금은 PIN을 확인할 수 없어요. · PIN check is unavailable right now.",
};

export async function authorizeRoute(request, env, now) {
  const url = new URL(request.url);
  if (request.method === "GET") {
    const checked = await checkRequest(env, url.origin, (name) => url.searchParams.get(name));
    if (checked.fatal) return errorPage(checked.fatal);
    if (checked.redirect) return requestErrorPage(checked);
    return approvalPage(checked.client, checked.params, randomToken(24));
  }
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (await limited(env.POST_LIMIT, request)) return errorPage("잠시 뒤 다시 해 주세요. · Too many attempts, try again in a minute.", 429, { "retry-after": "60" });
  const origin = request.headers.get("origin");
  // CLD1111A01: no-referrer였을 때 브라우저가 우리 화면의 POST에도 `Origin: null`을 보내 승인이 막혔다.
  // 이제 same-origin이고, 앱 안 브라우저가 여전히 null을 보내면 아래 CSRF 쿠키 확인에 맡긴다.
  if (origin && origin !== "null" && origin !== url.origin) return errorPage("보안 확인에 실패했어요. · Security check failed.", 403);
  const text = await readText(request, 8 * 1024);
  if (text.error) return text.error;
  const form = new URLSearchParams(text.value);
  const csrf = cookie(request, CSRF_COOKIE);
  if (!csrf || !sameText(csrf, form.get("csrf") ?? "")) return errorPage("보안 확인에 실패했어요. 처음부터 다시 해 주세요. · Security check failed; start again.", 403);
  const checked = await checkRequest(env, url.origin, (name) => form.get(name));
  if (checked.fatal) return errorPage(checked.fatal);
  if (checked.redirect) return requestErrorPage(checked);
  const { client, params } = checked;
  if (form.get("decision") !== "approve") {
    return withMeta(redirectTo(params.redirect_uri, { error: "access_denied", state: params.state, iss: url.origin }));
  }
  const retry = (message) => approvalPage(client, params, csrf, message);
  const code = normalizeCode(form.get("connect_code"));
  const wrongCode = "연결 코드가 맞지 않거나 시간이 지났어요. 앱에서 새 코드를 받아 주세요. · Wrong or expired connection code.";
  if (code.length !== 8 || [...code].some((c) => !CONNECT_ALPHABET.includes(c))) return retry(wrongCode);
  const hash = await codeHash(code);
  const record = await openConnectCode(env, code, hash, now);
  if (!record) return retry(wrongCode);
  const state = userState(env, record.master);
  const pin = await verifyPin(env, state, await importDek(fromBase64(record.dek)), record.master, form.get("pin"), now);
  if (!pin.ok) {
    if (pin.error === "wrong_pin") return retry(`PIN이 맞지 않아요. ${pin.remaining}번 더 틀리면 잠겨요. · Wrong PIN; ${pin.remaining} tries left.`);
    return retry(PIN_MESSAGES[pin.error]);
  }
  // PIN을 초기화하기 전에 만든 코드는 쓰지 못한다.
  if (pin.epoch !== record.epoch) return retry(wrongCode);
  const charge = await chargeWrites(env, state, 1, now);
  if (!charge.ok) return errorPage("오늘은 더 연결할 수 없어요. 내일 다시 해 주세요. · Daily limit reached; try again tomorrow.", 429, { "retry-after": String(charge.retryAfter) });
  if (!(await codeState(env, hash).call("takeCode", { now })).ok) return retry(wrongCode);
  const authCode = randomToken(32);
  const authHash = await sha256Hex(authCode);
  const payload = {
    master: record.master, dek: record.dek, clientId: client.id, clientName: client.name, redirectUri: params.redirect_uri,
    host: hostOf(params.redirect_uri), epoch: record.epoch,
    challenge: params.code_challenge, scope: params.scope, expiresAt: now + AUTH_CODE_SECONDS * 1000,
  };
  await env.PLANS.put(authCodeName(authHash), await sealJson(await wrapCryptoKey(authCode), authCodeName(authHash), payload), { expirationTtl: AUTH_CODE_SECONDS });
  return withMeta(redirectTo(params.redirect_uri, { code: authCode, state: params.state, iss: url.origin }));
}

// MARK: 토큰 (authorization_code + PKCE S256, refresh_token)

async function readForm(request) {
  const text = await readText(request, 8 * 1024);
  if (text.error) return null;
  if ((request.headers.get("content-type") ?? "").includes("application/json")) {
    try { return new URLSearchParams(Object.entries(JSON.parse(text.value)).map(([k, v]) => [k, String(v)])); } catch { return null; }
  }
  return new URLSearchParams(text.value);
}

// client_secret_basic 또는 본문의 client_id(+client_secret).
async function authenticateClient(request, env, form) {
  let id = form.get("client_id");
  let secret = form.get("client_secret");
  const basic = /^Basic (.+)$/.exec(request.headers.get("authorization") ?? "");
  if (basic) {
    try {
      const [user, pass] = atob(basic[1]).split(":");
      id = decodeURIComponent(user);
      secret = decodeURIComponent(pass ?? "");
    } catch { return null; }
  }
  const client = await loadClient(env, id);
  if (!client?.redirectUris) return null;
  if (client.method === "none") return client;
  return secret && client.secretHash && sameText(await sha256Hex(secret), client.secretHash) ? client : null;
}

const wrapBase = (grant) => ({
  scope: grant.scope, master: grant.master, dek: grant.dek, entry: grant.entry, keyId: grant.keyId, source: "oauth",
  clientId: grant.clientId, client: grant.clientName, host: grant.host,
});
const writeAccess = (env, token, hash, grant, now) =>
  writeWrap(env.PLANS, token, hash, { ...wrapBase(grant), kind: "access", expiresAt: isoSeconds(now + ACCESS_SECONDS * 1000) }, now);
const writeRefresh = (env, token, hash, grant, now) =>
  writeWrap(env.PLANS, token, hash, { ...wrapBase(grant), kind: "refresh", expiresAt: grant.refreshExpiresAt }, now);

const tokenReply = (access, refresh, scope) => json(
  { access_token: access, token_type: "Bearer", expires_in: ACCESS_SECONDS, refresh_token: refresh, scope }, 200, { pragma: "no-cache" },
);
const unavailable = () => oauthError(503, "temporarily_unavailable");
const overBudget = (charge) => json({ error: "temporarily_unavailable", error_description: charge.error, retryAfter: charge.retryAfter }, 429,
  { "retry-after": String(charge.retryAfter), pragma: "no-cache" });

const grantInfo = async (dekBytes, master, entry, grant) => sealInfo(keyring({ scope: "oauth", dekBytes }), master, entry,
  { scope: grant.scope, expiresAt: grant.refreshExpiresAt, source: "oauth", client: grant.clientName, host: grant.host });

async function exchangeCode(env, client, form, now) {
  const code = form.get("code") ?? "";
  if (!/^[A-Za-z0-9_-]{43}$/.test(code)) return oauthError(400, "invalid_grant");
  const hash = await sha256Hex(code);
  const record = await openJson(await wrapCryptoKey(code), authCodeName(hash), (await env.PLANS.get(authCodeName(hash))) ?? "null");
  // redirect_uri는 보냈으면 같아야 하고, 없어도 된다(OAuth 2.1: 코드는 PKCE로 묶인다)(N8).
  const redirect = form.get("redirect_uri");
  const redirectOk = redirect === null || redirect === record?.redirectUri;
  if (!record || record.expiresAt <= now || record.clientId !== client.id || !redirectOk) return oauthError(400, "invalid_grant");
  const verifier = form.get("code_verifier") ?? "";
  if (!/^[A-Za-z0-9._~-]{43,128}$/.test(verifier) || !sameText(await sha256Base64Url(verifier), record.challenge)) {
    return oauthError(400, "invalid_grant", "PKCE verification failed");
  }
  const state = userState(env, record.master);
  const charge = await chargeWrites(env, state, renewDue(client, now) ? 3 : 2, now);
  if (!charge.ok) return overBudget(charge);
  const entry = randomHex(32);
  const grant = { ...record, entry, keyId: entry.slice(0, 8), refreshExpiresAt: isoSeconds(now + REFRESH_DAYS * 86400_000) };
  const access = randomToken(48);
  const refresh = randomToken(48);
  const refreshHash = await sha256Hex(refresh);
  const codeTag = "code|" + hash;
  const created = await state.call("createGrant", {
    hash: entry, keyId: grant.keyId, info: await grantInfo(fromBase64(record.dek), record.master, entry, grant),
    refreshHash, codeTag, epoch: record.epoch, now,
  });
  if (!created.ok) {
    // 이미 쓴 코드면 그 코드로 만든 연결도 끊었다.
    if (created.revoked) await env.PLANS.delete("dek:" + created.revoked);
    return oauthError(400, "invalid_grant", created.error === "too_many_keys" ? "Too many connections; remove one in the app" : undefined);
  }
  // 코드 기록은 2분 TTL까지 남겨 둔다. 다시 쓰면 DO가 알아채고 이 연결을 끊는다.
  try {
    await writeAccess(env, access, await sha256Hex(access), grant, now);
    await writeRefresh(env, refresh, refreshHash, grant, now);
    await renewClient(env, client, now);
  } catch {
    // KV가 쓰기를 거절했다: 코드를 태우지 않고 되돌려 클라이언트가 다시 바꿀 수 있게 한다(N1).
    await state.call("abortGrant", { hash: entry, codeTag });
    return unavailable();
  }
  return tokenReply(access, refresh, record.scope);
}

async function refreshGrant(env, client, form, now) {
  const presented = form.get("refresh_token") ?? "";
  if (!/^[A-Za-z0-9_-]{64}$/.test(presented)) return oauthError(400, "invalid_grant");
  const hash = await sha256Hex(presented);
  const wrap = await readWrap(env.PLANS, presented, hash);
  if (!wrap || wrap.kind !== "refresh" || wrap.clientId !== client.id || Date.parse(wrap.expiresAt) <= now) return oauthError(400, "invalid_grant");
  const state = userState(env, wrap.master);
  const use = await state.call("useRefresh", { hash: wrap.entry, presented: hash, nonce: randomHex(16), now });
  if (!use.ok) {
    for (const old of use.revoked ?? []) await env.PLANS.delete("dek:" + old);
    return oauthError(400, "invalid_grant");
  }
  const charge = await chargeWrites(env, state, use.rotate ? 2 : 1, now);
  if (!charge.ok) return overBudget(charge);
  const grant = { ...wrap, clientName: wrap.client, refreshExpiresAt: wrap.expiresAt };
  const access = randomToken(48);
  let refresh = presented;
  try {
    if (use.rotate) {
      // 다음 refresh 토큰은 지금 토큰과 DO의 nonce로 정해진다. 겹치거나 다시 온 요청도 같은 토큰을 받는다(N8).
      refresh = await deriveToken(presented, use.nonce, "refresh|" + wrap.entry);
      const next = await sha256Hex(refresh);
      grant.refreshExpiresAt = isoSeconds(now + REFRESH_DAYS * 86400_000);
      if ((await env.PLANS.get("dek:" + next)) == null) await writeRefresh(env, refresh, next, grant, now);
      const info = await grantInfo(fromBase64(wrap.dek), wrap.master, wrap.entry, grant);
      if (!(await state.call("commitRefresh", { hash: wrap.entry, presented: hash, next, info, now })).ok) return oauthError(400, "invalid_grant");
      await renewClient(env, client, now);
    }
    await writeAccess(env, access, await sha256Hex(access), grant, now);
  } catch {
    return unavailable();
  }
  return tokenReply(access, refresh, wrap.scope);
}

export async function tokenRoute(request, env, now) {
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const form = await readForm(request);
  if (!form) return oauthError(400, "invalid_request");
  const client = await authenticateClient(request, env, form);
  if (!client) return oauthError(401, "invalid_client");
  switch (form.get("grant_type")) {
    case "authorization_code": return exchangeCode(env, client, form, now);
    case "refresh_token": return refreshGrant(env, client, form, now);
    default: return oauthError(400, "unsupported_grant_type");
  }
}
