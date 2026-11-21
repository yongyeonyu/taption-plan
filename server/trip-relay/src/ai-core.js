// AIG1122A01 Step 1: 복희 AI 2단 구조의 서버 바탕(설계서 3·5·10·11절). D1(`RELAY_DB`) 위에서 돈다.
//   - 16자리 ID: usr_·agt_·req_ + 혼동 문자(0 O 1 l I)를 뺀 57자 중 16자(약 93비트).
//   - 쿼터: Free 첫 7일 일 15회 → 이후 일 5회·월 30회, Pro(원타임 A안) 월 100회. 사용자 현지 자정 리셋. 성공한 서버 AI 응답만 센다(조건부 UPDATE 한 번).
//   - 작업 선점: `UPDATE … WHERE req_id=? AND status IN (…)` 한 번으로 먼저 온 AI 하나만 맡는다. 끝내기는 맡은 AI + version 일치만.
//   - 외부 우선 대기: 외부 에이전트가 있는 사용자의 작업은 `pending_external`로 시작하고 fallback_at이 지나면 내장 AI가 맡는다(기본 10분, 운영 레버).
//   - 운영 레버: `system_ai_config`(없으면 아래 기본값). 운영자 토큰(CLASSIFIER_ADMIN_TOKEN)으로만 읽고 바꾼다.
// 사용자 신원은 주인 키의 해시뿐이다. 좌표·글 원문은 이 모듈에 오지 않는다.
import { sameText, sha256Hex } from "./crypto.js";
import { json, readBody } from "./http.js";

// MARK: 16자리 ID

export const ID_ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"; // 0 O 1 l I 없음
export const ID_LENGTH = 16;
export const ID_PREFIXES = ["usr", "agt", "req"];
const ID_PATTERN = new RegExp(`^(${ID_PREFIXES.join("|")})_[${ID_ALPHABET}]{${ID_LENGTH}}$`);

/** `usr_…`·`agt_…`·`req_…`. 거부 표본추출로 치우침 없이 고른다. */
export function newId(prefix, random = (n) => crypto.getRandomValues(new Uint8Array(n))) {
  if (!ID_PREFIXES.includes(prefix)) throw new Error(`unknown id prefix: ${prefix}`);
  const limit = 256 - (256 % ID_ALPHABET.length); // 228: 이 밑의 바이트만 쓴다
  let out = "";
  while (out.length < ID_LENGTH) {
    for (const byte of random(32)) {
      if (byte >= limit) continue;
      out += ID_ALPHABET[byte % ID_ALPHABET.length];
      if (out.length === ID_LENGTH) break;
    }
  }
  return `${prefix}_${out}`;
}

export const isId = (value, prefix) => typeof value === "string" && ID_PATTERN.test(value) && (!prefix || value.startsWith(`${prefix}_`));

/** 내장 서버 AI의 고정 에이전트 ID. */
export const BUILT_IN_AGENT = "agt_BokkiHouseAgent2";

// MARK: 운영 레버

export const AI_CONFIG_DEFAULTS = Object.freeze({
  free_welcome_days: 7,
  free_welcome_daily: 15,
  free_daily: 5,
  free_monthly: 30,
  pro_monthly: 100,
  pro_daily: 0, // 0이면 하루 상한 없음
  fallback_minutes: 10, // 0이면 내장 AI 즉시 우선
  external_first: true,
  byo_agent_requires_pro: false, // 구매 확인(App Store) 전까지는 꺼 둔다: 지금 연결해 쓰는 사용자를 끊지 않는다
  pro_max_agents: 5,
  claim_lease_minutes: 30,
});

const CONFIG_RULES = {
  free_welcome_days: [0, 60], free_welcome_daily: [0, 1000], free_daily: [0, 1000], free_monthly: [0, 30_000],
  pro_monthly: [0, 100_000], pro_daily: [0, 10_000], pro_max_agents: [1, 50], claim_lease_minutes: [1, 240],
};
export const FALLBACK_CHOICES = [0, 3, 10, 30];

/** 받을 수 있는 설정 조각이면 정리한 객체, 아니면 오류 목록. */
export function checkConfigPatch(patch) {
  if (!patch || typeof patch !== "object" || Array.isArray(patch)) return { errors: ["객체여야 합니다"] };
  const out = {}, errors = [];
  for (const [key, value] of Object.entries(patch)) {
    if (CONFIG_RULES[key]) {
      const [low, high] = CONFIG_RULES[key];
      if (Number.isInteger(value) && value >= low && value <= high) out[key] = value; else errors.push(`${key}: ${low}~${high} 정수`);
    } else if (key === "fallback_minutes") {
      if (FALLBACK_CHOICES.includes(value)) out[key] = value; else errors.push(`fallback_minutes: ${FALLBACK_CHOICES.join("/")} 중 하나(0 = 내장 AI 즉시 우선)`);
    } else if (key === "external_first" || key === "byo_agent_requires_pro") {
      if (typeof value === "boolean") out[key] = value; else errors.push(`${key}: true/false`);
    } else errors.push(`${key}: 모르는 항목`);
  }
  return errors.length ? { errors } : { value: out };
}

export async function readConfig(db) {
  const { results } = await db.prepare("SELECT key, value FROM system_ai_config").bind().all();
  const config = { ...AI_CONFIG_DEFAULTS };
  for (const row of results) {
    if (!Object.hasOwn(AI_CONFIG_DEFAULTS, row.key)) continue;
    try {
      const value = JSON.parse(row.value);
      if (checkConfigPatch({ [row.key]: value }).value) config[row.key] = value;
    } catch { /* 깨진 값은 기본값 */ }
  }
  return config;
}

export async function writeConfig(db, patch, now) {
  const checked = checkConfigPatch(patch);
  if (checked.errors) return checked;
  for (const [key, value] of Object.entries(checked.value)) {
    await db.prepare("INSERT INTO system_ai_config (key, value, updated_at) VALUES (?, ?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at")
      .bind(key, JSON.stringify(value), now).run();
  }
  return { value: await readConfig(db) };
}

// MARK: 현지 날짜

export function validTimeZone(zone) {
  if (typeof zone !== "string" || zone.length > 64 || !/^[A-Za-z0-9_+\-/]+$/.test(zone)) return false;
  try { new Intl.DateTimeFormat("en-US", { timeZone: zone }); return true; } catch { return false; }
}

function localParts(ms, zone) {
  const parts = Object.fromEntries(new Intl.DateTimeFormat("en-US", {
    timeZone: zone, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23",
  }).formatToParts(new Date(ms)).map((part) => [part.type, part.value]));
  return { year: +parts.year, month: +parts.month, day: +parts.day, hour: +parts.hour, minute: +parts.minute, second: +parts.second };
}

/** 그 시각의 현지 날짜 키(YYYY-MM-DD)·달 키(YYYY-MM)·다음 현지 자정. */
export function localClock(ms, zone) {
  const p = localParts(ms, zone);
  const pad = (n) => String(n).padStart(2, "0");
  const offsetAt = (at) => { const q = localParts(at, zone); return Date.UTC(q.year, q.month - 1, q.day, q.hour, q.minute, q.second) - Math.floor(at / 1000) * 1000; };
  const midnight = Date.UTC(p.year, p.month - 1, p.day + 1);
  // 서머타임이 바뀌는 날이 있어 자정 근처의 오프셋으로 한 번 더 맞춘다.
  let next = midnight - offsetAt(ms);
  next = midnight - offsetAt(next);
  return { day: `${p.year}-${pad(p.month)}-${pad(p.day)}`, month: `${p.year}-${pad(p.month)}`, resetAt: next };
}

// MARK: 사용자·쿼터

const DAY_MS = 86_400_000;
const NO_CAP = 1_000_000_000;
const userHash = (master) => sha256Hex(`ai-user|${master}`);

/** 주인 키로 사용자 줄을 찾고 없으면 만든다(usr_ 발급). 시간대가 오면 갱신한다. */
export async function ensureUser(db, master, now, timeZone) {
  const owner = await userHash(master);
  let row = await db.prepare("SELECT * FROM user_ai_quotas WHERE owner_hash = ?").bind(owner).first();
  if (!row) {
    const zone = validTimeZone(timeZone) ? timeZone : "Asia/Seoul";
    await db.prepare("INSERT OR IGNORE INTO user_ai_quotas (user_id, owner_hash, created_at, time_zone) VALUES (?, ?, ?, ?)").bind(newId("usr"), owner, now, zone).run();
    row = await db.prepare("SELECT * FROM user_ai_quotas WHERE owner_hash = ?").bind(owner).first();
  } else if (validTimeZone(timeZone) && timeZone !== row.time_zone) {
    await db.prepare("UPDATE user_ai_quotas SET time_zone = ? WHERE user_id = ?").bind(timeZone, row.user_id).run();
    row = { ...row, time_zone: timeZone };
  }
  return row;
}

/** 지금 이 사용자에게 걸리는 상한. 웰컴 기간에는 월 상한을 세지 않는다. */
export function limitsFor(row, config, now) {
  const welcomeUntil = row.created_at + config.free_welcome_days * DAY_MS;
  if (row.plan === "pro") return { plan: "pro", welcome: false, welcomeUntil: null, daily: config.pro_daily || null, monthly: config.pro_monthly, countsMonth: true };
  const welcome = now < welcomeUntil;
  return welcome
    ? { plan: "free", welcome: true, welcomeUntil, daily: config.free_welcome_daily, monthly: null, countsMonth: false }
    : { plan: "free", welcome: false, welcomeUntil, daily: config.free_daily, monthly: config.free_monthly, countsMonth: true };
}

/** 사용량 보고(앱·운영 화면용). */
export function quotaView(row, config, now) {
  const limits = limitsFor(row, config, now);
  const clock = localClock(now, row.time_zone);
  const dailyUsed = row.day_key === clock.day ? row.daily_cloud_count : 0;
  const monthlyUsed = row.month_key === clock.month ? row.monthly_cloud_count : 0;
  const left = (used, cap) => (cap === null ? null : Math.max(0, cap - used));
  const remaining = [left(dailyUsed, limits.daily), limits.countsMonth ? left(monthlyUsed, limits.monthly) : null].filter((n) => n !== null);
  const exhausted = remaining.some((n) => n === 0);
  return {
    format: "bokki-ai-quota", version: 1, userId: row.user_id, plan: limits.plan, timeZone: row.time_zone,
    welcome: limits.welcome ? { until: new Date(limits.welcomeUntil).toISOString() } : null,
    daily: { used: dailyUsed, limit: limits.daily },
    monthly: { used: monthlyUsed, limit: limits.countsMonth ? limits.monthly : null },
    remaining: remaining.length ? Math.min(...remaining) : null,
    resetAt: new Date(clock.resetAt).toISOString(),
    ...(exhausted ? { fallback: "on_device" } : {}),
  };
}

/**
 * 성공한 서버 AI 응답 한 번을 센다. 상한 안이면 한 번의 조건부 UPDATE로 올리고 true, 넘으면 아무것도 바꾸지 않고 false.
 * 날짜가 바뀌었으면 같은 UPDATE 안에서 0부터 다시 센다(현지 자정 리셋).
 */
export async function chargeQuota(db, row, config, now) {
  const limits = limitsFor(row, config, now);
  const clock = localClock(now, row.time_zone);
  const month = limits.countsMonth ? 1 : 0;
  const result = await db.prepare(
    "UPDATE user_ai_quotas SET "
    + "daily_cloud_count = (CASE WHEN day_key = ?1 THEN daily_cloud_count ELSE 0 END) + 1, "
    + "monthly_cloud_count = (CASE WHEN month_key = ?2 THEN monthly_cloud_count ELSE 0 END) + ?3, "
    + "day_key = ?1, month_key = ?2, reset_at = ?4 "
    + "WHERE user_id = ?5 AND (CASE WHEN day_key = ?1 THEN daily_cloud_count ELSE 0 END) < ?6 "
    + "AND (CASE WHEN month_key = ?2 THEN monthly_cloud_count ELSE 0 END) + ?3 <= ?7",
  ).bind(clock.day, clock.month, month, clock.resetAt, row.user_id, limits.daily ?? NO_CAP, limits.countsMonth ? (limits.monthly ?? NO_CAP) : NO_CAP).run();
  return changes(result) === 1;
}

/** 쿼터를 넘었을 때의 통일 응답(5절 4): 앱은 오류 대신 온디바이스로 넘어간다. */
export const quotaExceeded = (view) => json({ error: "quota_exceeded", fallback: "on_device", plan: view.plan, resetAt: view.resetAt, daily: view.daily, monthly: view.monthly }, 429);

const changes = (result) => result?.meta?.changes ?? result?.changes ?? 0;

// MARK: 에이전트(Pro 다중 연결)

export const AGENT_LABEL_MAX = 40;

export async function activeAgents(db, userId) {
  const { results } = await db.prepare("SELECT agt_id, label, created_at, last_seen_at FROM agent_tokens WHERE user_id = ? AND revoked_at IS NULL ORDER BY created_at").bind(userId).all();
  return results;
}

/** 외부 에이전트를 등록한다. Free는 운영 레버(byo_agent_requires_pro)가 켜져 있으면 막고, Pro는 pro_max_agents까지. */
export async function registerAgent(db, row, config, label, now, keyRef = null) {
  const clean = typeof label === "string" ? label.normalize("NFC").replace(/\s+/g, " ").trim() : "";
  if (!clean || [...clean].length > AGENT_LABEL_MAX || /[\u0000-\u001f\u007f]/.test(clean)) return { error: "bad_label" };
  if (row.plan !== "pro" && config.byo_agent_requires_pro) return { error: "pro_required" };
  const current = await activeAgents(db, row.user_id);
  const cap = row.plan === "pro" ? config.pro_max_agents : 1;
  if (current.length >= cap) return { error: "too_many_agents", max: cap };
  const agtId = newId("agt");
  await db.prepare("INSERT INTO agent_tokens (agt_id, user_id, kind, label, key_ref, created_at) VALUES (?, ?, 'external', ?, ?, ?)").bind(agtId, row.user_id, clean, keyRef, now).run();
  return { value: { agtId, label: clean } };
}

export async function revokeAgent(db, userId, agtId, now) {
  if (!isId(agtId, "agt")) return false;
  return changes(await db.prepare("UPDATE agent_tokens SET revoked_at = ? WHERE agt_id = ? AND user_id = ? AND revoked_at IS NULL").bind(now, agtId, userId).run()) === 1;
}

// MARK: 작업 선점·끝내기(중복 방지 3대 안전장치)

/**
 * 작업을 만든다. 같은 req_id는 다시 생기지 않는다(UNIQUE). 외부 에이전트가 있고 외부 우선이면 pending_external로 기다린다.
 * 돌려주는 값: { created, reqId, status }
 */
export async function createTask(db, { userId, taskType, reqId = newId("req"), hasExternal, config, now }) {
  if (!isId(reqId, "req") || !/^[a-z][a-z0-9_]{1,31}$/.test(taskType ?? "")) return { error: "bad_task" };
  const waitExternal = hasExternal && config.external_first && config.fallback_minutes > 0;
  const status = waitExternal ? "pending_external" : "pending";
  const fallbackAt = waitExternal ? now + config.fallback_minutes * 60_000 : null;
  const result = await db.prepare("INSERT OR IGNORE INTO ai_tasks (req_id, user_id, task_type, status, fallback_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)")
    .bind(reqId, userId, taskType, status, fallbackAt, now, now).run();
  if (changes(result) === 1) return { created: true, reqId, status };
  const existing = await db.prepare("SELECT status FROM ai_tasks WHERE req_id = ?").bind(reqId).first();
  return { created: false, reqId, status: existing?.status ?? null };
}

/**
 * 한 작업을 맡는다. 조건부 UPDATE 한 번이라 둘이 동시에 와도 하나만 이긴다.
 * - 외부 에이전트: pending·pending_external, 또는 선점이 만료된 claimed
 * - 내장 AI: pending, 기다림이 끝난 pending_external, 또는 선점이 만료된 claimed
 * 이기면 { claimed: true, version }을 돌려준다(끝낼 때 이 version을 내야 한다).
 */
export async function claimTask(db, { reqId, agtId, source, now, leaseMs }) {
  if (!isId(reqId, "req") || !isId(agtId, "agt") || !["built_in_ai", "external_agent"].includes(source)) return { claimed: false, error: "bad_claim" };
  const open = source === "external_agent"
    ? "(status IN ('pending', 'pending_external') OR (status = 'claimed' AND claim_until < ?3))"
    : "(status = 'pending' OR (status = 'pending_external' AND fallback_at <= ?3) OR (status = 'claimed' AND claim_until < ?3))";
  const result = await db.prepare(
    `UPDATE ai_tasks SET status = 'claimed', owner_agt_id = ?2, source = ?4, claim_until = ?3 + ?5, version = version + 1, updated_at = ?3 WHERE req_id = ?1 AND ${open}`,
  ).bind(reqId, agtId, now, source, leaseMs).run();
  if (changes(result) !== 1) {
    const row = await db.prepare("SELECT status, owner_agt_id FROM ai_tasks WHERE req_id = ?").bind(reqId).first();
    return { claimed: false, error: !row ? "no_task" : row.status === "pending_external" ? "waiting_external" : ["done", "failed"].includes(row.status) ? "already_finished" : "taken" };
  }
  const row = await db.prepare("SELECT version FROM ai_tasks WHERE req_id = ?").bind(reqId).first();
  return { claimed: true, version: row.version };
}

/** 이 AI가 맡을 수 있는 작업을 limit개까지 맡는다(각각 원자적으로). */
export async function claimDue(db, { userId, agtId, source, now, leaseMs, limit = 5 }) {
  const open = source === "external_agent"
    ? "(status IN ('pending', 'pending_external') OR (status = 'claimed' AND claim_until < ?2))"
    : "(status = 'pending' OR (status = 'pending_external' AND fallback_at <= ?2) OR (status = 'claimed' AND claim_until < ?2))";
  const { results } = await db.prepare(`SELECT req_id FROM ai_tasks WHERE user_id = ?1 AND ${open} ORDER BY created_at LIMIT ?3`).bind(userId, now, limit).all();
  const won = [];
  for (const { req_id: reqId } of results) {
    const outcome = await claimTask(db, { reqId, agtId, source, now, leaseMs });
    if (outcome.claimed) won.push({ reqId, version: outcome.version });
  }
  return won;
}

/** 맡은 AI가 version을 맞춰 끝낸다. 다른 AI·옛 version·이미 끝난 작업은 바꾸지 못한다(완료 잠금 + 낙관적 락). */
export async function finishTask(db, { reqId, agtId, version, status, now }) {
  if (!["done", "failed"].includes(status) || !Number.isInteger(version)) return { ok: false, error: "bad_finish" };
  const result = await db.prepare(
    "UPDATE ai_tasks SET status = ?1, version = version + 1, updated_by_agt_id = ?2, claim_until = NULL, updated_at = ?3 WHERE req_id = ?4 AND owner_agt_id = ?2 AND status = 'claimed' AND version = ?5",
  ).bind(status, agtId, now, reqId, version).run();
  if (changes(result) === 1) return { ok: true, version: version + 1 };
  const row = await db.prepare("SELECT status, owner_agt_id, version FROM ai_tasks WHERE req_id = ?").bind(reqId).first();
  if (!row) return { ok: false, error: "no_task" };
  if (["done", "failed"].includes(row.status)) return { ok: false, error: "already_finished" };
  if (row.owner_agt_id !== agtId) return { ok: false, error: "not_claimer" };
  return { ok: false, error: "version_conflict", version: row.version };
}

/** 사용자가 명시적으로 다시 해 달라고 할 때만, 끝난 작업을 다시 연다. */
export async function reopenTask(db, { reqId, userId, now }) {
  const result = await db.prepare("UPDATE ai_tasks SET status = 'pending', owner_agt_id = NULL, source = NULL, fallback_at = NULL, claim_until = NULL, version = version + 1, updated_at = ?1 WHERE req_id = ?2 AND user_id = ?3 AND status IN ('done', 'failed')")
    .bind(now, reqId, userId).run();
  return changes(result) === 1;
}

// MARK: 라우트

const unavailable = () => json({ error: "unavailable" }, 503);

/** GET /ai/quota?tz=Asia/Seoul (주인 키): 내 플랜·남은 횟수·리셋 시각. 처음 부르면 usr_ ID가 생긴다. */
export async function quotaRoute(request, ctx) {
  const db = ctx.env.RELAY_DB;
  if (!db) return unavailable();
  const tz = new URL(request.url).searchParams.get("tz");
  if (tz !== null && !validTimeZone(tz)) return json({ error: "bad_time_zone" }, 422);
  const row = await ensureUser(db, ctx.master, ctx.now, tz);
  return json(quotaView(row, await readConfig(db), ctx.now), 200);
}

/** /ai/agents (주인 키): GET 목록, POST {label} 등록, DELETE ?id=agt_… 해제. */
export async function agentsRoute(request, ctx) {
  const db = ctx.env.RELAY_DB;
  if (!db) return unavailable();
  const row = await ensureUser(db, ctx.master, ctx.now, null);
  if (request.method === "GET") {
    const agents = await activeAgents(db, row.user_id);
    return json({ format: "bokki-ai-agents", version: 1, plan: row.plan, agents: agents.map((a) => ({ agtId: a.agt_id, label: a.label, createdAt: new Date(a.created_at).toISOString() })) }, 200);
  }
  if (request.method === "POST") {
    const body = await readBody(request);
    if (body.error) return body.error;
    const outcome = await registerAgent(db, row, await readConfig(db), body.value?.label, ctx.now);
    if (outcome.error === "pro_required") return json({ error: "pro_required", plan: row.plan }, 403);
    if (outcome.error === "too_many_agents") return json({ error: "too_many_agents", max: outcome.max }, 409);
    if (outcome.error) return json({ error: outcome.error }, 422);
    return json({ ok: true, ...outcome.value }, 201);
  }
  if (request.method === "DELETE") {
    const id = new URL(request.url).searchParams.get("id");
    return (await revokeAgent(db, row.user_id, id, ctx.now)) ? json(null, 204) : json({ error: "no_agent" }, 404);
  }
  return json({ error: "method_not_allowed" }, 405);
}

/** 운영자 토큰 길: /ai/admin/config (GET·PUT), /ai/admin/plan (POST {userId, plan}), /ai/admin/usage (GET). */
export async function adminRoute(request, env, url, now) {
  const token = env.CLASSIFIER_ADMIN_TOKEN;
  const db = env.RELAY_DB;
  if (typeof token !== "string" || token.length < 32 || !db) return unavailable();
  const given = /^Bearer (.+)$/.exec(request.headers.get("authorization") ?? "")?.[1];
  if (!sameText(given, token)) return json({ error: "unauthorized" }, 401);
  const path = url.pathname;
  if (path === "/ai/admin/config") {
    if (request.method === "GET") return json({ format: "bokki-ai-config", version: 1, config: await readConfig(db), defaults: AI_CONFIG_DEFAULTS }, 200);
    if (request.method === "PUT") {
      const body = await readBody(request);
      if (body.error) return body.error;
      const written = await writeConfig(db, body.value, now);
      return written.errors ? json({ error: "bad_config", errors: written.errors }, 422) : json({ ok: true, config: written.value }, 200);
    }
    return json({ error: "method_not_allowed" }, 405, { allow: "GET, PUT" });
  }
  if (path === "/ai/admin/plan") {
    if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405, { allow: "POST" });
    const body = await readBody(request);
    if (body.error) return body.error;
    const { userId, plan } = body.value ?? {};
    if (!isId(userId, "usr") || !["free", "pro"].includes(plan)) return json({ error: "bad_plan" }, 422);
    const result = await db.prepare("UPDATE user_ai_quotas SET plan = ?, plan_source = 'manual' WHERE user_id = ?").bind(plan, userId).run();
    return changes(result) === 1 ? json({ ok: true, userId, plan }, 200) : json({ error: "no_user" }, 404);
  }
  if (path === "/ai/admin/usage") {
    if (request.method !== "GET") return json({ error: "method_not_allowed" }, 405, { allow: "GET" });
    const users = await db.prepare("SELECT plan, COUNT(*) AS n FROM user_ai_quotas GROUP BY plan").bind().all();
    const tasks = await db.prepare("SELECT status, COALESCE(source, '') AS source, COUNT(*) AS n FROM ai_tasks GROUP BY status, source").bind().all();
    const agents = await db.prepare("SELECT COUNT(*) AS n FROM agent_tokens WHERE revoked_at IS NULL").bind().first();
    return json({
      format: "bokki-ai-usage", version: 1,
      users: Object.fromEntries(users.results.map((r) => [r.plan, r.n])),
      tasks: tasks.results.map((r) => ({ status: r.status, source: r.source || null, count: r.n })),
      agents: agents?.n ?? 0,
    }, 200);
  }
  return json({ error: "not_found" }, 404);
}
