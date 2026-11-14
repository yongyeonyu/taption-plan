// 푸시(APNs, PSH1114A06). 외부 AI가 무언가 했을 때 앱이 5분 확인을 기다리지 않고 바로 가져가게 깨운다.
// 푸시에는 종류(k)만 싣고 사용자 글은 싣지 않는다. 폴링이 예비이므로 푸시가 안 가도 틀리는 것은 없다.
// 비밀값 APNS_KEY_P8(PKCS#8 PEM)·APNS_KEY_ID·APNS_TEAM_ID 가운데 하나라도 없으면 아무것도 보내지 않는다.
import { fromBase64, openJson, sealJson, toBase64Url } from "./crypto.js";
import { json } from "./http.js";

const TOKEN_LIFE_MS = 45 * 60_000; // 제공자 토큰은 20분~1시간 사이에만 새로 만든다(TooManyProviderTokenUpdates).
const DEFAULT_TOPIC = "com.taption.plan";
const encoder = new TextEncoder();
const part = (value) => toBase64Url(encoder.encode(JSON.stringify(value)));
let cached = null; // isolate마다 하나.

export const configured = (env) => !!(env.APNS_KEY_P8 && env.APNS_KEY_ID && env.APNS_TEAM_ID);

/** ES256 제공자 JWT. WebCrypto의 ECDSA 서명은 JWS가 쓰는 r||s 그대로다. */
export async function providerToken(env, now = Date.now()) {
  const tag = `${env.APNS_KEY_ID}|${env.APNS_TEAM_ID}|${env.APNS_KEY_P8.length}`;
  if (cached && cached.tag === tag && now - cached.at < TOKEN_LIFE_MS && now >= cached.at) return cached.jwt;
  const der = fromBase64(env.APNS_KEY_P8.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, ""));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const head = part({ alg: "ES256", kid: env.APNS_KEY_ID }) + "." + part({ iss: env.APNS_TEAM_ID, iat: Math.floor(now / 1000) });
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, encoder.encode(head));
  cached = { tag, at: now, jwt: head + "." + toBase64Url(new Uint8Array(signature)) };
  return cached.jwt;
}

/** 한 건 보낸다. { skipped } | { ok, status, gone }. gone이면 저장한 기기 토큰을 지워야 한다. */
export async function sendPush(env, fetcher, { token, sandbox = false, payload, pushType = "background", collapseId, priority, now }) {
  if (!configured(env)) return { skipped: true };
  const host = sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com";
  const response = await (fetcher ?? fetch)(`https://${host}/3/device/${token}`, {
    method: "POST",
    headers: {
      authorization: "bearer " + (await providerToken(env, now)),
      "apns-topic": env.APNS_TOPIC || DEFAULT_TOPIC,
      "apns-push-type": pushType,
      "apns-priority": String(priority ?? (pushType === "background" ? 5 : 10)),
      ...(collapseId ? { "apns-collapse-id": collapseId } : {}),
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
  });
  let reason = "";
  if (!response.ok) { try { reason = (await response.json())?.reason ?? ""; } catch { /* 본문 없음 */ } }
  return { ok: response.ok, status: response.status, gone: response.status === 410 || reason === "Unregistered" || reason === "BadDeviceToken" };
}

// MARK: 기기 토큰 (앱만 올리고 지운다). DEK로 잠가 주인 DO에 둔다.

const aad = (ctx) => `push|${ctx.master}`;
const DEVICE_TOKEN = /^[0-9a-f]{64,200}$/i;

export async function saveToken(ctx, value) {
  if (!DEVICE_TOKEN.test(value?.token ?? "") || !["sandbox", "production"].includes(value.env)
    || (value.build !== undefined && !(typeof value.build === "string" && /^\d{1,8}$/.test(value.build)))) return json({ error: "bad_push_token" }, 422);
  const sealed = await sealJson(await ctx.ring.dek(), aad(ctx), { token: value.token.toLowerCase() });
  await ctx.state.call("pushSet", { sealed, sandbox: value.env === "sandbox", build: value.build ?? null, now: ctx.now });
  return json({ ok: true, push: configured(ctx.env) }, 200);
}

export async function deleteToken(ctx) {
  await ctx.state.call("pushClear", {});
  return json(null, 204);
}

// MARK: 보낼 때

const QUESTION_ACTIONS = new Set(["askUser", "requestApproval"]);
const silent = (kind) => ({ payload: { aps: { "content-available": 1 }, k: kind }, pushType: "background", collapseId: kind });
const visible = (kind, key, collapseId) => ({
  payload: { aps: { alert: { "loc-key": key }, sound: "default", "content-available": 1 }, k: kind }, pushType: "alert", collapseId,
});

export const pushForCommand = (command) => QUESTION_ACTIONS.has(command.action)
  ? visible("q", "PUSH_AI_QUESTION", ("q-" + command.id).slice(0, 64)) : silent("cmd");
export const pushForTask = (outcome) => outcome?.needsUser === true ? visible("task", "PUSH_AI_NEEDS_YOU", "task-alert") : silent("task");
export const pushForRules = () => silent("rules");

async function deliver(ctx, push) {
  // 간격·하루 수를 DO가 보고 통과한 것만 토큰을 돌려준다.
  const gate = await ctx.state.call("pushGate", { kind: push.payload.k, visible: push.pushType === "alert", now: ctx.now });
  if (!gate.ok) return;
  const stored = await openJson(await ctx.ring.dek(), aad(ctx), gate.sealed);
  if (!stored?.token) return;
  const result = await sendPush(ctx.env, ctx.env.FETCH, { ...push, token: stored.token, sandbox: gate.sandbox, now: ctx.now });
  if (result.gone) await ctx.state.call("pushClear", { sealed: gate.sealed });
}

/** AI(주인 키가 아닌 키)의 요청 뒤에만 부른다. 응답을 늦추지 않게 ctx.defer(waitUntil)에 맡기고, 실패는 삼킨다. */
export function notify(ctx, push) {
  if (ctx.auth?.kind === "master" || !configured(ctx.env) || !ctx.state) return;
  const work = deliver(ctx, push).catch(() => {});
  if (ctx.defer) ctx.defer(work);
}
