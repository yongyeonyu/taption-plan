// 공통 규칙(SRL1116A01). 운영자가 검토해 서명한 규칙 묶음을 모든 앱이 받아 쓰고,
// 동의한 사용자의 기기에서 AI가 만든 규칙 가운데 누구에게나 통할 것을 「후보」로 모은다. 설계는 `docs/SHARED_RULES_PLAN.md`.
// 묶음과 후보는 Durable Object 인스턴스 하나(`shared:rules`)에 둔다. 후보에는 누가 올렸는지 적지 않는다.
// 묶음은 운영자 Mac의 Ed25519 키로 서명하고 서버는 공개 키로 확인만 한다(서버가 뚫려도 규칙을 바꿔 내보낼 수 없다).
import { fromBase64, sameText, sha256Hex } from "./crypto.js";
import { json, readBody, tooMany } from "./http.js";
import { RULE_ENGINE, cleanRule, safePattern } from "./rules.js";
import { userState } from "./state.js";

/** 공통으로 내보낼 수 있는 종류. 사람마다 다른 것(내 계좌·일정 제목·장소 쌍·넣지 않을 낱말)은 없다. */
export const SHARED_TYPES = ["payment_text", "text_ignore", "receipt_hint", "merchant_category", "source_switch"];
/** 기기에서 올릴 수 있는 종류. 앱별 스위치는 사용자가 고른 값이라 올리지 않고 운영자가 직접 쓴다. */
export const CANDIDATE_TYPES = ["payment_text", "text_ignore", "receipt_hint", "merchant_category"];
export const SHARED_LIMITS = { payloadBytes: 100_000, rules: 400, perRequest: 20, perDay: 40, candidates: 2_000, candidateDays: 90, sent: 1_000, minDevices: 2 };
const DAY_MS = 86_400_000;
const FORMAT = "bokki-shared-rules";
const sharedState = (env) => userState(env, "shared:rules");
const isObject = (v) => !!v && typeof v === "object" && !Array.isArray(v);

// MARK: 개인 정보 거르기 (앱의 `SharedRuleFilter`와 같은 규칙. `test/fixtures/shared-rules.json`으로 맞춘다)

/** 정규식에서 글자 그대로 맞추는 부분만 남긴다. 가린 글자(`\*`)는 ＊로 남겨 알아볼 수 있게 한다. */
export function patternLiterals(pattern) {
  return pattern
    .replace(/\\\*/g, "＊")
    .replace(/\(\?<[A-Za-z]\w*>/g, " ")
    .replace(/\\[dDsSwWbBnrt]/g, " ")
    .replace(/\[(?:\\.|[^\]\\])*\]/g, " ")
    .replace(/\{\d+(?:,\d*)?\}/g, " ")
    .replace(/\\(.)/g, "$1")
    .replace(/[()|?*+^$.]/g, " ");
}

const HONORIFIC_OK = ["고객", "회원", "본인", "가입자", "이용자"];
/** 개인을 알아볼 만한 글인가: 숫자 4자리 이상(카드 끝자리·계좌·금액), 가린 글자, 메일 주소, 「이름+님」. */
export function personalText(text) {
  if (/\d{4,}/.test(text) || /[＊*]/.test(text) || /@/.test(text)) return true;
  for (const [, name] of text.matchAll(/([가-힣]{2,4})\s*님/g)) if (!HONORIFIC_OK.some((word) => name.endsWith(word))) return true;
  return false;
}

/** 기기가 올린 후보에서 알려진 칸만 남긴다. 견본 글·이름·메모·가게 표시 이름은 받지 않는다. 개인 정보로 보이면 null. */
export function cleanCandidate(value) {
  if (!isObject(value) || !CANDIDATE_TYPES.includes(value.type)) return null;
  if (value.type === "payment_text") {
    const pattern = value.match?.pattern, kind = value.result?.kind;
    if (!safePattern(pattern) || !["expense", "income", "ignore"].includes(kind) || personalText(patternLiterals(pattern))) return null;
    return { type: value.type, match: { pattern }, result: { kind } };
  }
  const rule = cleanRule({ type: value.type, match: value.match, result: value.result });
  if (!rule) return null;
  const match = { ...rule.match }, result = { ...rule.result };
  delete result.title;
  delete result.reason;
  if (match.contains) match.contains = [...match.contains].sort();
  if ([...(match.contains ?? []), match.equals, match.source].some((text) => typeof text === "string" && personalText(text))) return null;
  return { type: value.type, match, result };
}

const canonical = (value) => Array.isArray(value) ? `[${value.map(canonical).join(",")}]`
  : isObject(value) ? `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonical(value[key])}`).join(",")}}` : JSON.stringify(value);
export const fingerprint = async (candidate) => (await sha256Hex(canonical(candidate))).slice(0, 32);

/** 내보낼 규칙 하나의 문제. 없으면 null. 견본 글(운영자가 지어낸 글)은 긴 숫자만 막는다. */
export function sharedRuleProblem(value) {
  if (!isObject(value) || typeof value.id !== "string" || !/^[\w.:-]{1,64}$/.test(value.id)) return "bad_id";
  if (!SHARED_TYPES.includes(value.type)) return "type_not_shared";
  const rule = cleanRule(value);
  if (!rule) return "bad_rule";
  const texts = [...(rule.match.contains ?? []), rule.match.equals, rule.match.source, rule.match.app, rule.result.name, rule.result.title, rule.note];
  if (rule.match.pattern) texts.push(patternLiterals(rule.match.pattern));
  if (texts.some((text) => typeof text === "string" && personalText(text))) return "personal";
  if (typeof rule.match.sample === "string" && /\d{9,}/.test(rule.match.sample)) return "personal";
  return null;
}

async function verified(env, payload, signature) {
  try {
    const key = await crypto.subtle.importKey("raw", fromBase64(env.SHARED_RULES_PUBLIC_KEY), { name: "Ed25519" }, false, ["verify"]);
    return await crypto.subtle.verify("Ed25519", key, fromBase64(signature), new TextEncoder().encode(payload));
  } catch { return false; }
}

/** 묶음(payload 글과 서명)을 읽어 { bundle } 또는 { error }. */
export async function checkBundle(env, payload, signature, currentVersion) {
  if (typeof payload !== "string" || typeof signature !== "string" || new TextEncoder().encode(payload).length > SHARED_LIMITS.payloadBytes) return { error: "bad_bundle" };
  let bundle;
  try { bundle = JSON.parse(payload); } catch { return { error: "bad_bundle" }; }
  if (!isObject(bundle) || bundle.format !== FORMAT || !Number.isInteger(bundle.version) || bundle.engine !== RULE_ENGINE
    || !Array.isArray(bundle.rules) || bundle.rules.length > SHARED_LIMITS.rules) return { error: "bad_bundle" };
  if (bundle.version <= currentVersion) return { error: "stale_version", version: currentVersion };
  const seen = new Set();
  for (const rule of bundle.rules) {
    const problem = seen.has(rule?.id) ? "duplicate_id" : sharedRuleProblem(rule);
    if (problem) return { error: problem, id: typeof rule?.id === "string" ? rule.id.slice(0, 64) : null };
    seen.add(rule.id);
  }
  if (!(await verified(env, payload, signature))) return { error: "bad_signature" };
  return { bundle };
}

// MARK: 앱이 부르는 것

// GET /shared/rules?since=<버전>: 같으면 304. 아직 내보낸 것이 없으면 version 0에 payload가 없다.
export async function readShared(ctx, since) {
  const current = await sharedState(ctx.env).call("sharedGet");
  const tag = `"${current.version}"`;
  if (since !== null && since !== undefined && String(since) === String(current.version)) return new Response(null, { status: 304, headers: { etag: tag, "cache-control": "no-store" } });
  return json({ format: FORMAT, version: current.version, payload: current.payload ?? null, signature: current.signature ?? null }, 200, { etag: tag });
}

// POST /shared/candidates {rules:[{type, match, result}]}: 동의한 사용자의 앱(주인 키)이 거른 규칙을 올린다.
// 같은 기기가 같은 규칙을 두 번 세지 않게 지문만 사용자 인스턴스에 적고, 후보에는 누가 올렸는지 적지 않는다.
export async function submitCandidates(ctx, value) {
  if (!Array.isArray(value?.rules) || value.rules.length < 1 || value.rules.length > SHARED_LIMITS.perRequest) return json({ error: "not_candidate_list" }, 422);
  const items = [];
  for (const raw of value.rules) {
    const candidate = cleanCandidate(raw);
    if (candidate) items.push({ fp: await fingerprint(candidate), ...candidate });
  }
  const refused = value.rules.length - items.length;
  if (!items.length) return json({ ok: true, accepted: 0, refused }, 200);
  const marked = await ctx.state.call("sharedMark", { fps: items.map((item) => item.fp), now: ctx.now, perDay: SHARED_LIMITS.perDay, keep: SHARED_LIMITS.sent });
  if (marked.error) return tooMany("shared_daily_limit", marked.retryAfter);
  const fresh = items.filter((item) => marked.fresh.includes(item.fp));
  if (fresh.length) await sharedState(ctx.env).call("sharedCandidatePut", { items: fresh, now: ctx.now, cap: SHARED_LIMITS.candidates, maxAgeMs: SHARED_LIMITS.candidateDays * DAY_MS });
  return json({ ok: true, accepted: fresh.length, refused }, 200);
}

// MARK: 운영자가 부르는 것 (`scripts/shared-rules/admin.mjs`). 서버 비밀값 SHARED_RULES_ADMIN_TOKEN이 있어야 열린다.

export async function adminRoute(request, env, url, now) {
  const token = env.SHARED_RULES_ADMIN_TOKEN;
  if (typeof token !== "string" || token.length < 32 || !env.SHARED_RULES_PUBLIC_KEY) return json({ error: "unavailable" }, 503);
  const given = /^Bearer (.+)$/.exec(request.headers.get("authorization") ?? "")?.[1];
  if (!sameText(given, token)) return json({ error: "unauthorized" }, 401);
  const state = sharedState(env), action = `${request.method} ${url.pathname}`;
  switch (action) {
    case "GET /shared/admin/bundle": {
      const current = await state.call("sharedGet");
      return json({ version: current.version, payload: current.payload ?? null, updatedAt: current.updatedAt ?? null }, 200);
    }
    case "GET /shared/admin/candidates": {
      const min = Number(url.searchParams.get("min") ?? SHARED_LIMITS.minDevices);
      if (!Number.isInteger(min) || min < 1) return json({ error: "bad_min" }, 422);
      const listed = await state.call("sharedCandidateList", { min, now, maxAgeMs: SHARED_LIMITS.candidateDays * DAY_MS });
      return json({ min, total: listed.total, candidates: listed.items }, 200);
    }
    case "DELETE /shared/admin/candidates": {
      const fps = (url.searchParams.get("fps") ?? "").split(",").filter(Boolean);
      if (fps.length < 1 || fps.length > 100 || !fps.every((fp) => /^[0-9a-f]{32}$/.test(fp))) return json({ error: "bad_fps" }, 422);
      return json({ ok: true, ...(await state.call("sharedCandidateDrop", { fps })) }, 200);
    }
    case "POST /shared/admin/publish": {
      const body = await readBody(request);
      if (body.error) return body.error;
      const current = await state.call("sharedGet");
      const checked = await checkBundle(env, body.value?.payload, body.value?.signature, current.version);
      if (checked.error) return json(checked, checked.error === "stale_version" ? 409 : 422);
      const saved = await state.call("sharedPut", { version: checked.bundle.version, payload: body.value.payload, signature: body.value.signature, now });
      return saved.error ? json(saved, 409) : json({ ok: true, version: saved.version, rules: checked.bundle.rules.length }, 201);
    }
    default: return json({ error: "not_found" }, 404);
  }
}
