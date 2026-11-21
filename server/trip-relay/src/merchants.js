// MER1121A01: 아이콘을 정하지 못한 가맹점 이름 모으기. 앱이 사용자의 동의(「가맹점 이름 보내기」) 뒤에만 올리는 이름과 건수를 D1에 쌓아,
// 요청이 많은 가맹점을 운영자가 골라 앱 아이콘 규칙에 등록하게 한다.
//   POST   /merchants/unknown  주인 키. {format:"bokki-merchants", version:1, items:[{name, count}]}. 한 번에 100개, 하루 300개(서로 다른 이름 기준).
//   DELETE /merchants/unknown  주인 키. 내가 보낸 이름을 모두 지운다.
//   GET    /merchants/admin    운영자 토큰(CLASSIFIER_ADMIN_TOKEN과 같은 값을 쓴다). `?limit=<n≤200>&min=<보낸 사람 수>`로 이름별 건수를 읽는다.
// 이름 안에 숫자 연속·`*`·@·주소 꼴이 있으면 받지 않는다(사람 이름·카드·전화 번호·계정이 섞이지 못하게). 보관은 1년.
import { sameText, sha256Hex } from "./crypto.js";
import { json, readText } from "./http.js";

export const MERCHANT_LIMITS = {
  maxBytes: 64 * 1024,
  maxItems: 100,
  perDay: 300,
  nameMin: 2,
  nameMax: 40,
  countMax: 100,
  retentionMs: 365 * 24 * 60 * 60 * 1000,
  adminMax: 200,
};
const DAY_MS = 24 * 60 * 60 * 1000;

const isObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const NUMBER_RUN = /\d{4,}/;
const FORBIDDEN = /[*@:/\\<>]|https?|www\./i;

/** 받아도 되는 이름이면 다듬은 이름(공백 정리), 아니면 null. */
export function cleanName(raw) {
  if (typeof raw !== "string") return null;
  const name = raw.normalize("NFC").replace(/\s+/g, " ").trim();
  const points = [...name].length;
  if (points < MERCHANT_LIMITS.nameMin || points > MERCHANT_LIMITS.nameMax) return null;
  if (NUMBER_RUN.test(name.replace(/[\s,.-]/g, "")) || FORBIDDEN.test(name)) return null;
  if (/[\u0000-\u001f\u007f]/.test(name)) return null;
  return name;
}

const ownerHash = (master) => sha256Hex(`merchants|${master}`);
const tooManyToday = () => json({ error: "merchant_daily_limit", retryAfter: 3600, perDay: MERCHANT_LIMITS.perDay }, 429, { "retry-after": "3600" });

export async function upload(request, ctx) {
  const db = ctx.env.RELAY_DB;
  if (!db) return json({ error: "unavailable" }, 503);
  const text = await readText(request, MERCHANT_LIMITS.maxBytes);
  if (text.error) return text.error;
  let body;
  try { body = JSON.parse(text.value); } catch { return json({ error: "invalid_json" }, 400); }
  if (!isObject(body) || body.format !== "bokki-merchants" || body.version !== 1 || !Array.isArray(body.items)) return json({ error: "invalid_payload" }, 422);
  if (body.items.length < 1 || body.items.length > MERCHANT_LIMITS.maxItems) return json({ error: "bad_item_count", max: MERCHANT_LIMITS.maxItems }, 422);

  const merged = new Map();
  let rejected = 0;
  for (const item of body.items) {
    const name = isObject(item) ? cleanName(item.name) : null;
    const count = isObject(item) ? item.count : null;
    if (!name || !Number.isInteger(count) || count < 1 || count > MERCHANT_LIMITS.countMax) { rejected++; continue; }
    merged.set(name, Math.min(MERCHANT_LIMITS.countMax, (merged.get(name) ?? 0) + count));
  }
  const owner = await ownerHash(ctx.master);
  const now = ctx.now;
  const used = await db.prepare("SELECT COUNT(*) AS n FROM unknown_merchants WHERE owner = ? AND last_at >= ?").bind(owner, now - DAY_MS).first();
  if ((used?.n ?? 0) + merged.size > MERCHANT_LIMITS.perDay) return tooManyToday();
  // 1년이 지난 것을 올릴 때마다 지운다(예약 작업이 따로 없다).
  await db.prepare("DELETE FROM unknown_merchants WHERE last_at < ?").bind(now - MERCHANT_LIMITS.retentionMs).run();
  const statements = [...merged].map(([name, count]) => db.prepare(
    "INSERT INTO unknown_merchants (name, owner, hits, first_at, last_at) VALUES (?, ?, ?, ?, ?) "
    + "ON CONFLICT(name, owner) DO UPDATE SET hits = hits + excluded.hits, last_at = excluded.last_at").bind(name, owner, count, now, now));
  if (typeof db.batch === "function") { if (statements.length) await db.batch(statements); } else for (const statement of statements) await statement.run();
  return json({ ok: true, accepted: merged.size, rejected }, 201);
}

export async function erase(ctx) {
  const db = ctx.env.RELAY_DB;
  if (!db) return json({ error: "unavailable" }, 503);
  const owner = await ownerHash(ctx.master);
  const count = await db.prepare("SELECT COUNT(*) AS n FROM unknown_merchants WHERE owner = ?").bind(owner).first();
  await db.prepare("DELETE FROM unknown_merchants WHERE owner = ?").bind(owner).run();
  return json({ ok: true, deleted: count?.n ?? 0 }, 200);
}

/** 운영자가 읽는다. 이름별 건수·보낸 사람 수·마지막 시각만 주고 owner는 주지 않는다. */
export async function adminRoute(request, env, url) {
  const token = env.CLASSIFIER_ADMIN_TOKEN;
  if (typeof token !== "string" || token.length < 32 || !env.RELAY_DB) return json({ error: "unavailable" }, 503);
  const given = /^Bearer (.+)$/.exec(request.headers.get("authorization") ?? "")?.[1];
  if (!sameText(given, token)) return json({ error: "unauthorized" }, 401);
  if (request.method !== "GET") return json({ error: "method_not_allowed" }, 405, { allow: "GET" });
  const limit = Number(url.searchParams.get("limit") ?? 50);
  const min = Number(url.searchParams.get("min") ?? 1);
  if (!Number.isInteger(limit) || limit < 1 || limit > MERCHANT_LIMITS.adminMax || !Number.isInteger(min) || min < 1 || min > 1_000_000) return json({ error: "bad_query" }, 422);
  const { results } = await env.RELAY_DB.prepare(
    "SELECT name, SUM(hits) AS hits, COUNT(*) AS users, MAX(last_at) AS last_at FROM unknown_merchants GROUP BY name HAVING users >= ? ORDER BY hits DESC, last_at DESC LIMIT ?").bind(min, limit).all();
  const totals = await env.RELAY_DB.prepare("SELECT COUNT(DISTINCT name) AS names, COUNT(DISTINCT owner) AS users, COALESCE(SUM(hits), 0) AS hits FROM unknown_merchants").bind().first();
  return json({
    format: "bokki-merchants-admin", version: 1,
    totals: { names: totals?.names ?? 0, users: totals?.users ?? 0, hits: totals?.hits ?? 0 },
    items: results.map((row) => ({ name: row.name, hits: row.hits, users: row.users, lastAt: new Date(row.last_at).toISOString() })),
  }, 200);
}
