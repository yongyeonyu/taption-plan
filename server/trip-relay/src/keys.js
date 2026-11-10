// 키(SEC1110A01, AIR1110A02, SEC1110A02). 앱만 가진 주인 키(master)가 등록(`/register`)하고, AI용 연결 키를 만든다.
// 모든 값은 주인 해시 이름 아래에 있고, 연결 키·OAuth 토큰은 자기 `dek:<해시>` 감싼 기록으로 주인 이름과 DEK를 얻는다.
// v3 감싼 기록(SEC1110A02): `{"v":3,"iv","ct"}` 하나뿐이다. 범위·만료·주인·종류는 모두 토큰에서 만든 키로 잠근 안에 있다.
// 어느 키가 살아 있는지는 Durable Object(`state.js`)가 정본이다. `tomb:<해시>`는 연결 키였던 토큰의 영구 표시다.
import {
  decryptBytes, fromBase64, importDek, masterDekBytes, openJson, pinMac, sameBytes, sealJson, sha256Hex, storageCryptoKey,
  toBase64, wrapCryptoKey,
} from "./crypto.js";
import { KEY_PATTERN, bearer, json, limited, readBody, tooMany } from "./http.js";
import { LIMITS, chargeWrites, countPerIpAndGlobal, userState } from "./state.js";

const DAY_MS = 24 * 60 * 60 * 1000;
// 키 수명은 사용자가 고른다: 30일·90일·1년·만료 없음(null), 두 범위 모두(AIR1110A02).
const MAX_DAYS = { read: 365, write: 365 };
// 기기와 서버 시계 차이를 하루 미만까지 봐준다(366일째는 거절).
const CLOCK_LEEWAY_MS = DAY_MS;
const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d{1,9})?)?(Z|[+-]\d{2}:\d{2})$/;
// 앱이 만든 무작위 키만 받는다(finding 13). 32바이트 base64url 43자의 서로 다른 글자 수는 보통 30개 안팎이다.
export const MIN_DISTINCT_CHARS = 20;

const RANK = { read: 1, write: 2, master: 3 };
// search(지도 검색 전용 설치 키)는 카카오 중계만 쓴다.
export const allows = (scope, need) => (need === "search" ? scope === "search" || scope === "master" : (RANK[scope] ?? 0) >= RANK[need]);

const wrapName = (hash) => "dek:" + hash;
const tombName = (hash) => "tomb:" + hash;
const legacyWrapAad = (hash, scope, expiresAt, master) => `dek:${hash}|${scope}|${expiresAt ?? ""}|${master}`;
const infoAad = (master, hash) => `key|${master}|${hash}`;
const pinAad = (master) => `pin|${master}`;
// 초 단위 ISO(밀리초 없음). 앱의 ISO8601DateFormatter가 그대로 읽는다.
export const isoSeconds = (ms) => new Date(Math.floor(ms / 1000) * 1000).toISOString().replace(".000Z", "Z");
export const active = (expiresAt, now) => expiresAt === null || expiresAt === undefined || Date.parse(expiresAt) > now;
const ttlUntil = (expiresAt, now) => (expiresAt ? { expirationTtl: Math.max(60, Math.ceil((Date.parse(expiresAt) - now) / 1000)) } : undefined);

function parse(text) {
  try { return JSON.parse(text); } catch { return undefined; }
}

// MARK: 감싼 기록

// payload: { kind: key|access|refresh, scope, expiresAt, master, dek(base64), entry, keyId, source, clientId? }
export async function writeWrap(kv, token, hash, payload, now) {
  await kv.put(wrapName(hash), await sealJson(await wrapCryptoKey(token), wrapName(hash), payload), ttlUntil(payload.expiresAt, now));
}

export async function readWrap(kv, token, hash) {
  const record = parse((await kv.get(wrapName(hash))) ?? "null");
  if (record?.v !== 3) return null;
  return openJson(await wrapCryptoKey(token), wrapName(hash), record);
}

export const sealInfo = async (ring, master, hash, info) => sealJson(await ring.dek(), infoAad(master, hash), info);
export const openInfo = async (ring, master, hash, sealed) => openJson(await ring.dek(), infoAad(master, hash), sealed);

// 연동 키 → auth. 401이면 null.
// 감싼 기록이 없는 43자 키는 주인 후보다. 등록 여부는 DO가 `admit`에서 확인한다(registration: true).
export async function resolveKey(kv, token, now) {
  const hash = await sha256Hex(token);
  const raw = await kv.get(wrapName(hash));
  if (raw === null || raw === undefined) {
    if (!KEY_PATTERN.test(token)) return null;
    // 주인 키로 보낸 명령의 keyId는 "master"(앱이 늘 살아 있는 것으로 본다).
    return { kind: "master", scope: "master", master: hash, hash, token, dekBytes: null, entry: null, keyId: "master", source: "rest" };
  }
  const record = parse(raw);
  if (record?.v === 3) {
    const info = await openJson(await wrapCryptoKey(token), wrapName(hash), record);
    if (!info || info.kind === "refresh" || !RANK[info.scope] || info.scope === "master" || !active(info.expiresAt, now)) return null;
    return {
      kind: info.kind, scope: info.scope, master: info.master, hash, token, dekBytes: fromBase64(info.dek),
      entry: info.entry, keyId: info.keyId, source: info.source, expiresAt: info.expiresAt,
    };
  }
  if (record?.v === 2) return resolveLegacyWrap(kv, token, hash, record, now);
  return null;
}

// 예전 v2 감싼 기록(범위·만료·주인이 평문). 폐기 표시는 영구 표시로 바꾸고, 살아 있는 키는 DO 입장 뒤 v3로 다시 잠근다.
async function resolveLegacyWrap(kv, token, hash, record, now) {
  if (record.revoked) {
    await kv.put(tombName(hash), "1");
    await kv.delete(wrapName(hash));
    return null;
  }
  if (!MAX_DAYS[record.scope] || typeof record.master !== "string") return null;
  const dekBytes = await decryptBytes(await wrapCryptoKey(token), legacyWrapAad(hash, record.scope, record.expiresAt, record.master), record);
  if (!dekBytes || dekBytes.length !== 32 || !active(record.expiresAt ?? null, now)) return null;
  return {
    kind: "key", scope: record.scope, master: record.master, hash, token, dekBytes, entry: hash, keyId: hash.slice(0, 8),
    source: "rest", expiresAt: record.expiresAt ?? null, legacyWrap: true,
  };
}

// DO가 받아들인 예전 키를 v3로 다시 잠근다(평문 범위·만료·주인을 없앤다).
export async function resealLegacyWrap(ctx) {
  const { auth, kv, now } = ctx;
  const payload = { kind: "key", scope: auth.scope, expiresAt: auth.expiresAt, master: auth.master, dek: toBase64(auth.dekBytes), entry: auth.hash, keyId: auth.keyId, source: "rest" };
  await writeWrap(kv, auth.token, auth.hash, payload, now);
  if (!(await kv.get(tombName(auth.hash)))) await kv.put(tombName(auth.hash), "1");
}

// 요청 하나의 열쇠 꾸러미. 필요할 때만 키를 만든다.
export function keyring(auth) {
  let dek = null;
  let legacy = null;
  const ring = {
    owner: auth.scope === "master",
    legacy: () => (ring.owner ? (legacy ??= storageCryptoKey(auth.token)) : null),
    async dekBytes() { return (auth.dekBytes ??= await masterDekBytes(auth.token)); },
    dek: () => (dek ??= ring.dekBytes().then(importDek)),
    ensureDek: () => ring.dek(),
  };
  return ring;
}

export function isoExpiry(value, scope, now) {
  if (value === null) return { ms: null };
  if (typeof value !== "string" || !ISO.test(value)) return null;
  const ms = Date.parse(value);
  if (Number.isNaN(ms) || ms <= now || ms >= now + MAX_DAYS[scope] * DAY_MS + CLOCK_LEEWAY_MS) return null;
  return { ms };
}

// 등록 본문을 확인한다. 틀리면 null.
export function parseKeyRequest(value, masterToken, now) {
  const keys = value?.keys;
  if (!Array.isArray(keys) || keys.length < 1 || keys.length > LIMITS.keysPerRequest) return null;
  const tokens = new Set();
  const parsed = [];
  for (const key of keys) {
    if (!KEY_PATTERN.test(key?.token ?? "") || key.token === masterToken || tokens.has(key.token)) return null;
    if (!MAX_DAYS[key.scope]) return null;
    const expiry = isoExpiry(key.expiresAt, key.scope, now);
    if (expiry === null) return null;
    tokens.add(key.token);
    parsed.push({ token: key.token, scope: key.scope, expiresAt: expiry.ms === null ? null : isoSeconds(expiry.ms) });
  }
  return parsed;
}

// 이미 값이 있는 이름(등록 전 예전 주인 키)은 연결 키로 등록하지 않는다.
async function namespaceInUse(kv, hash) {
  for (const prefix of ["plan:", "cmd:", "cmdres:", "keys:", "ext:"]) if ((await kv.get(prefix + hash)) != null) return true;
  return (await kv.list({ prefix: `act:${hash}:` })).keys.length > 0;
}

// MARK: PIN (SEC1110A02)

const PIN_PATTERN = /^\d{6}$/;
const pepperOf = (env) => (typeof env?.PIN_PEPPER === "string" && env.PIN_PEPPER.length > 0 ? env.PIN_PEPPER : null);

// 새 검증값: 서버가 만든 salt 16바이트와 HMAC. DEK로 잠가 DO에 둔다.
async function makeVerifier(pepper, pin) {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  return { salt: toBase64(salt), mac: toBase64(await pinMac(pepper, salt, pin)) };
}
const sealVerifier = async (dek, master, verifier) => sealJson(dek, pinAad(master), verifier);

// PIN 확인. { ok } 또는 { error: pin_required|pin_not_set|pin_locked|wrong_pin|pin_check_unavailable, remaining?, lockedUntil? }
// 비밀(PIN_PEPPER)이 없으면 시도로 세지 않고 pin_check_unavailable.
export async function verifyPin(env, state, dek, master, pin, now) {
  if (typeof pin !== "string" || !PIN_PATTERN.test(pin)) return { error: "pin_required" };
  const pepper = pepperOf(env);
  if (!pepper) return { error: "pin_check_unavailable" };
  const stored = await state.call("getPin", { now });
  if (!stored.sealed) return { error: "pin_not_set" };
  if (stored.lockedUntil) return { error: "pin_locked", lockedUntil: stored.lockedUntil };
  const verifier = await openJson(dek, pinAad(master), stored.sealed);
  if (typeof verifier?.salt !== "string" || typeof verifier?.mac !== "string") return { error: "pin_not_set" };
  const ok = sameBytes(await pinMac(pepper, fromBase64(verifier.salt), pin), fromBase64(verifier.mac));
  const result = await state.call("recordPin", { ok, now });
  if (result.ok) return { ok: true, epoch: stored.epoch };
  if (result.locked) return { error: "pin_locked", lockedUntil: result.lockedUntil };
  return { error: "wrong_pin", remaining: result.remaining };
}

// PIN 결과를 응답으로. 응답에는 PIN을 넣지 않는다.
export function pinRefusal(result, now) {
  switch (result.error) {
    case "pin_required": return json({ error: "pin_required", message: "Enter the 6-digit PIN." }, 422);
    case "pin_not_set": return json({ error: "pin_not_set", message: "Set a PIN in the app first." }, 409);
    case "pin_check_unavailable": return json({ error: "pin_check_unavailable", message: "PIN check is unavailable right now." }, 503);
    case "pin_locked": {
      const retryAfter = Math.max(1, Math.ceil((result.lockedUntil - now) / 1000));
      return json({ error: "pin_locked", message: "Too many wrong PINs. Locked for 15 minutes.", retryAfter, lockedUntil: isoSeconds(result.lockedUntil) },
        423, { "retry-after": String(retryAfter) });
    }
    default: return json({ error: "wrong_pin", message: "Wrong PIN.", remaining: result.remaining }, 403);
  }
}

// GET /pin: {"set", "locked", "retryAfter"?(초), "lockedUntil"}. 주인만.
async function pinStatus(ctx) {
  const stored = await ctx.state.call("getPin", { now: ctx.now });
  const locked = !!stored.lockedUntil;
  return json({
    set: !!stored.sealed, locked,
    ...(locked ? { retryAfter: Math.max(1, Math.ceil((stored.lockedUntil - ctx.now) / 1000)) } : {}),
    lockedUntil: locked ? isoSeconds(stored.lockedUntil) : null,
  }, 200);
}

// POST /pin {"pin"}: 처음 정하기. 이미 있으면 {"pin": 새 PIN, "currentPin": 지금 PIN}(틀리면 잠금 수에 셈). 주인만.
export async function pinRoute(request, ctx) {
  if (request.method === "GET") return pinStatus(ctx);
  if (await limited(ctx.env.POST_LIMIT, request)) return tooMany();
  const body = await readBody(request);
  if (body.error) return body.error;
  const { pin, currentPin } = body.value ?? {};
  if (typeof pin !== "string" || !PIN_PATTERN.test(pin)) return pinRefusal({ error: "pin_required" }, ctx.now);
  const pepper = pepperOf(ctx.env);
  if (!pepper) return pinRefusal({ error: "pin_check_unavailable" }, ctx.now);
  const dek = await ctx.ring.dek();
  const stored = await ctx.state.call("getPin", { now: ctx.now });
  if (stored.sealed) {
    if (currentPin === undefined || currentPin === null) return json({ error: "current_pin_required", message: "Enter the current PIN to change it." }, 422);
    const check = await verifyPin(ctx.env, ctx.state, dek, ctx.master, currentPin, ctx.now);
    if (!check.ok) return pinRefusal(check.error === "pin_required" ? { error: "wrong_pin", remaining: undefined } : check, ctx.now);
  }
  await ctx.state.call("setPin", { sealed: await sealVerifier(dek, ctx.master, await makeVerifier(pepper, pin)) });
  return json({ ok: true }, 200);
}

// POST /pin/reset {}: PIN을 잊었을 때(REV1110A06). 주인 키만. PIN·잠금을 지우고 모든 연결 키·OAuth 연결을 끊는다.
// 대기 중인 연결 코드·승인 코드도 못 쓴다. 그 뒤 앱이 POST /pin {"pin"}으로 새 PIN을 정한다. 주인마다 하루 3번.
export async function pinResetRoute(request, ctx) {
  if (await limited(ctx.env.POST_LIMIT, request)) return tooMany();
  const body = await readBody(request, { allowEmpty: true });
  if (body.error) return body.error;
  const result = await ctx.state.call("resetPin", { now: ctx.now });
  if (!result.ok) return tooMany("rate_limited", result.retryAfter);
  await deleteWraps(ctx.kv, result.revoked);
  return json({ reset: true, revokedKeys: result.revoked.length }, 200);
}

// MARK: 등록 (finding 3, 13)

const distinctChars = (text) => new Set(text).size;

// POST /register: 본문의 키가 아니라 Authorization의 새 키를 등록한다. 앱은 2xx·409를 등록됨으로, 422를 약한 키로 본다.
export async function registerRoute(request, env, now) {
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (await limited(env.POST_LIMIT, request)) return tooMany();
  const token = bearer(request);
  if (!token || !KEY_PATTERN.test(token)) return json({ error: "unauthorized" }, 401);
  if (distinctChars(token) < MIN_DISTINCT_CHARS) return json({ error: "low_entropy" }, 422);
  const body = await readBody(request, { allowEmpty: true });
  if (body.error) return body.error;
  const purpose = body.value?.purpose ?? "master";
  if (purpose !== "master" && purpose !== "search") return json({ error: "bad_purpose" }, 400);
  // 예전 앱이 보내는 pinVerifier는 무시한다(SEC1110A03: PIN은 POST /pin으로만).
  const hash = await sha256Hex(token);
  // 연결 키였던 토큰(살아 있든 폐기됐든)은 주인이 될 수 없다(finding 10).
  if ((await env.PLANS.get(wrapName(hash))) != null || (await env.PLANS.get(tombName(hash))) != null) return json({ error: "key_conflict" }, 409);
  // 이미 등록된 키가 다시 오면 IP 하루 수에 세지 않는다(N3). 앱은 켤 때마다 등록을 다시 불러도 된다.
  const marker = await openJson(await wrapCryptoKey(token), "reg:" + hash, (await env.PLANS.get("reg:" + hash)) ?? "null");
  if (marker?.purpose) {
    return marker.purpose === purpose ? json({ ok: true, purpose, created: false }, 200) : json({ error: "purpose_conflict" }, 409);
  }
  const counted = await countPerIpAndGlobal(env, request, "registrations", LIMITS.registrationsPerIpDay, LIMITS.registrationsPerDay, now);
  if (!counted.ok) return tooMany("rate_limited", counted.retryAfter);
  const result = await userState(env, hash).call("register", { purpose, now });
  if (!result.ok) return json({ error: result.error }, 409);
  // DO에는 있는데 표시가 없으면(예전에 쓰다 실패) 다시 쓴다.
  const charge = await chargeWrites(env, null, 1, now);
  if (charge.ok) await env.PLANS.put("reg:" + hash, await sealJson(await wrapCryptoKey(token), "reg:" + hash, { purpose }));
  return json({ ok: true, purpose, created: result.created }, result.created ? 201 : 200);
}

// MARK: 연결 키 목록

const publicEntry = (entry, info) => ({
  id: entry.keyId, scope: info.scope, expiresAt: info.expiresAt ?? null, source: info.source ?? "rest",
  ...(info.client ? { client: info.client } : {}),
  ...(info.host ? { host: info.host } : {}),
});

// 살아 있는 목록과 만료된 해시.
export async function listKeys(ctx) {
  const { entries } = await ctx.state.call("listEntries");
  const live = [];
  const expired = [];
  for (const entry of entries) {
    const info = await openInfo(ctx.ring, ctx.master, entry.hash, entry.info);
    if (!info) continue;
    if (active(info.expiresAt, ctx.now)) live.push({ entry, info });
    else expired.push(entry.hash);
  }
  return { live, expired };
}

// 예전 KV 목록(`keys:<주인>`, phase 2)을 DO로 옮기고 지운다(SEC1110A02).
export async function importLegacyKeys(ctx) {
  const name = "keys:" + ctx.master;
  if ((await ctx.kv.get(name)) != null) {
    const list = parse((await ctx.store.get(name, { reseal: false })) ?? "[]");
    const entries = [];
    for (const e of Array.isArray(list) ? list : []) {
      if (typeof e?.hash !== "string" || !MAX_DAYS[e.scope]) continue;
      entries.push({ hash: e.hash, keyId: e.hash.slice(0, 8), info: await sealInfo(ctx.ring, ctx.master, e.hash, { scope: e.scope, expiresAt: e.expiresAt ?? null, source: "rest" }) });
    }
    if (entries.length) await ctx.state.call("importEntries", { entries, now: ctx.now });
    for (const e of entries) if (!(await ctx.kv.get(tombName(e.hash)))) await ctx.kv.put(tombName(e.hash), "1");
    await ctx.kv.delete(name);
  }
  await ctx.state.call("markLegacy", { keys: true });
}

const KEY_ERRORS = { too_many_keys: 422, revoked_key: 409, key_conflict: 409 };

async function addKeys(request, ctx) {
  const { kv, auth, ring, now, master } = ctx;
  if (await limited(ctx.env.POST_LIMIT, request)) return tooMany();
  const body = await readBody(request);
  if (body.error) return body.error;
  const keys = parseKeyRequest(body.value, auth.token, now);
  if (!keys) return json({ error: "not_keys" }, 422);
  const pin = await verifyPin(ctx.env, ctx.state, await ring.dek(), master, body.value.pin, now);
  if (!pin.ok) return pinRefusal(pin, now);
  const charge = await chargeWrites(ctx.env, ctx.state, keys.length * 2, now);
  if (!charge.ok) return tooMany(charge.error, charge.retryAfter);
  const entries = [];
  for (const key of keys) {
    const hash = await sha256Hex(key.token);
    if ((await kv.get("reg:" + hash)) != null) return json({ error: "key_conflict" }, 409);
    const raw = await kv.get(wrapName(hash));
    if (raw != null) {
      const record = parse(raw);
      const owner = record?.v === 3 ? (await readWrap(kv, key.token, hash))?.master : record?.master;
      if (owner !== master) return json({ error: "key_conflict" }, 409);
    }
    const tombed = (await kv.get(tombName(hash))) != null;
    // 다른 사람의 값이 있는 이름은 덮지 않는다.
    if (raw == null && !tombed && (await namespaceInUse(kv, hash))) return json({ error: "key_conflict" }, 409);
    const info = { scope: key.scope, expiresAt: key.expiresAt, source: "rest" };
    entries.push({ key, hash, keyId: hash.slice(0, 8), kind: "key", tombed, info, sealed: await sealInfo(ring, master, hash, info) });
  }
  const { expired } = await listKeys(ctx);
  const added = await ctx.state.call("addEntries", {
    entries: entries.map((e) => ({ hash: e.hash, keyId: e.keyId, kind: e.kind, info: e.sealed, tombed: e.tombed })), prune: expired, now,
  });
  if (!added.ok) return json({ error: added.error }, KEY_ERRORS[added.error] ?? 409);
  const dek = toBase64(await ring.dekBytes());
  try {
    for (const e of entries) {
      await writeWrap(kv, e.key.token, e.hash, { kind: "key", scope: e.key.scope, expiresAt: e.key.expiresAt, master, dek, entry: e.hash, keyId: e.keyId, source: "rest" }, now);
      if (!e.tombed) await kv.put(tombName(e.hash), "1");
    }
  } catch {
    // KV가 쓰기를 거절하면(하루 한도 등) 방금 만든 줄을 지워 감싼 기록 없는 연결이 남지 않게 한다.
    await ctx.state.call("dropEntries", { hashes: added.created });
    return json({ error: "storage_unavailable" }, 503, { "retry-after": "60" });
  }
  return json({ ok: true, keys: entries.map((e) => publicEntry(e, e.info)) }, 201);
}

// 폐기: DO가 먼저 표시하고 그 키의 명령을 지운 뒤, KV의 감싼 기록을 지운다(finding 5, 6, 10).
async function deleteWraps(kv, revoked) {
  for (const r of revoked) {
    if (r.kind === "key") await kv.delete(wrapName(r.hash));
    for (const hash of [r.refreshHash, r.prevRefreshHash]) if (hash) await kv.delete(wrapName(hash));
  }
}

export async function revokeKeys(ctx, keyId) {
  const { revoked } = await ctx.state.call("revoke", { keyId, now: ctx.now });
  await deleteWraps(ctx.kv, revoked);
  return revoked;
}

// DO가 받아들이지 않은 예전(v2) 키: 영구 표시로 바꾸고 감싼 기록을 지운다(N11).
export async function buryLegacyWrap(kv, hash) {
  await kv.put(tombName(hash), "1");
  await kv.delete(wrapName(hash));
}

export async function keysRoute(request, ctx) {
  switch (request.method) {
    case "POST":
      return addKeys(request, ctx);
    case "GET": {
      const { live } = await listKeys(ctx);
      return json({ keys: live.map(({ entry, info }) => publicEntry(entry, info)) }, 200);
    }
    case "DELETE": {
      const id = new URL(request.url).searchParams.get("id");
      if (id !== null && !/^[0-9a-f]{8}$/.test(id)) return json({ error: "bad_id" }, 400);
      await revokeKeys(ctx, id);
      return json(null, 204);
    }
    default:
      return json({ error: "method_not_allowed" }, 405);
  }
}
