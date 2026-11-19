// CLS1119A01: 오분류 교정 표본 모으기. 앱이 사용자가 「보내기」를 눌렀을 때만 올리는 비식별 표본을 D1에 쌓는다.
// 앱이 만드는 JSON(`bokki-misclassification` v1)을 그대로 받되, 허용 목록 검사로 좌표·이름·글이 새어 들어오지 못하게 한다.
//   POST   /classifier-samples        주인 키. 200건·1MB까지, 하루 2,000건. 같은 `id`는 무시.
//   DELETE /classifier-samples        주인 키. 내가 올린 표본을 모두 지운다.
//   GET    /classifier-samples/admin  운영자 토큰(CLASSIFIER_ADMIN_TOKEN). `?since=<seq>&limit=<n≤500>`로 학습용 표본을 읽는다.
// 보관은 1년(대표 결정 2026-11-19): 올릴 때마다 지난 것을 지운다.
import { sameText, sha256Hex } from "./crypto.js";
import { json, readText } from "./http.js";

export const CLASSIFIER_LIMITS = {
  maxBytes: 1024 * 1024,
  maxSamples: 200,
  perDay: 2_000,
  retentionMs: 365 * 24 * 60 * 60 * 1000,
  adminPage: 500,
};
const DAY_MS = 24 * 60 * 60 * 1000;

const CODE = /^[a-z][A-Za-z0-9_-]{0,31}$/; // 분류 대분류 코드·이동 수단·"custom"·"unconfirmed"
const DETAIL = /^[a-z][A-Za-z0-9._-]{0,47}$/; // 분류표의 behavior 코드
const RULE_VERSION = /^[A-Za-z0-9._-]{1,32}$/;
const UUID = /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/;
const MOTIONS = ["stationary", "walking", "running", "cycling", "automotive", "unknown"];

const SAMPLE_KEYS = ["schemaVersion", "id", "kind", "minuteOfDay", "weekdayIndex", "durationSeconds", "predicted", "predictedDetail", "predictedConfidence",
  "predictedScore", "corrected", "correctedDetail", "correctedIsCustom", "ruleVersion", "features"];
const FEATURE_KEYS = ["averageSpeedKmh", "maximumSpeedKmh", "distanceMeters", "steps", "stepCadencePerMinute", "gpsAccuracyMeters", "dominantMotion", "watchCovered", "sampleCount"];

const isObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const sameKeys = (value, keys) => isObject(value) && Object.keys(value).length === keys.length && keys.every((key) => Object.hasOwn(value, key));
const int = (value, low, high) => Number.isInteger(value) && value >= low && value <= high;
const num = (value, low, high) => typeof value === "number" && Number.isFinite(value) && value >= low && value <= high;
const orNull = (check) => (value, ...range) => value === null || check(value, ...range);

/** 허용 목록 검사. 통과한 표본만 돌려주고(새 객체), 모르는 열쇠·긴 글·이상한 값이 하나라도 있으면 null. */
export function checkSample(raw) {
  if (!sameKeys(raw, SAMPLE_KEYS) || !sameKeys(raw.features, FEATURE_KEYS)) return null;
  const f = raw.features;
  const ok = raw.schemaVersion === 1 && typeof raw.id === "string" && UUID.test(raw.id) && ["activity", "travel"].includes(raw.kind)
    && int(raw.minuteOfDay, 0, 1439) && int(raw.weekdayIndex, 0, 6) && int(raw.durationSeconds, 0, 172_800)
    && typeof raw.predicted === "string" && CODE.test(raw.predicted) && orNull((v) => typeof v === "string" && DETAIL.test(v))(raw.predictedDetail)
    && orNull((v) => ["low", "medium", "high"].includes(v))(raw.predictedConfidence) && orNull(num)(raw.predictedScore, 0, 1)
    && typeof raw.corrected === "string" && CODE.test(raw.corrected) && orNull((v) => typeof v === "string" && DETAIL.test(v))(raw.correctedDetail)
    && typeof raw.correctedIsCustom === "boolean" && (!raw.correctedIsCustom || (raw.corrected === "custom" && raw.correctedDetail === null))
    && typeof raw.ruleVersion === "string" && RULE_VERSION.test(raw.ruleVersion)
    && orNull(num)(f.averageSpeedKmh, 0, 500) && orNull(num)(f.maximumSpeedKmh, 0, 500) && orNull(num)(f.distanceMeters, 0, 10_000_000)
    && orNull(int)(f.steps, 0, 200_000) && orNull(num)(f.stepCadencePerMinute, 0, 400) && orNull(num)(f.gpsAccuracyMeters, 0, 10_000)
    && orNull((v) => MOTIONS.includes(v))(f.dominantMotion) && typeof f.watchCovered === "boolean" && int(f.sampleCount, 0, 1_000_000);
  if (!ok) return null;
  return { ...Object.fromEntries(SAMPLE_KEYS.slice(0, -1).map((key) => [key, raw[key]])), features: Object.fromEntries(FEATURE_KEYS.map((key) => [key, f[key]])) };
}

const ownerHash = (master) => sha256Hex(`classifier|${master}`);

export async function upload(request, ctx) {
  const db = ctx.env.RELAY_DB;
  if (!db) return json({ error: "unavailable" }, 503);
  const text = await readText(request, CLASSIFIER_LIMITS.maxBytes);
  if (text.error) return text.error;
  let body;
  try { body = JSON.parse(text.value); } catch { return json({ error: "invalid_json" }, 400); }
  if (!isObject(body) || body.format !== "bokki-misclassification" || body.version !== 1 || typeof body.ruleVersion !== "string" || !RULE_VERSION.test(body.ruleVersion)
    || !Array.isArray(body.samples)) return json({ error: "invalid_payload" }, 422);
  if (body.samples.length < 1 || body.samples.length > CLASSIFIER_LIMITS.maxSamples) return json({ error: "bad_sample_count", max: CLASSIFIER_LIMITS.maxSamples }, 422);

  const valid = [];
  let rejected = 0;
  const seen = new Set();
  for (const raw of body.samples) {
    const sample = checkSample(raw);
    if (!sample || seen.has(sample.id.toLowerCase())) { rejected++; continue; }
    seen.add(sample.id.toLowerCase());
    valid.push(sample);
  }
  const owner = await ownerHash(ctx.master);
  const now = ctx.now;
  const used = await db.prepare("SELECT COUNT(*) AS n FROM misclass_samples WHERE owner = ? AND received_at >= ?").bind(owner, now - DAY_MS).first();
  if ((used?.n ?? 0) + valid.length > CLASSIFIER_LIMITS.perDay) return tooManyToday();
  // 1년이 지난 표본을 올릴 때마다 지운다(예약 작업이 따로 없다).
  await db.prepare("DELETE FROM misclass_samples WHERE received_at < ?").bind(now - CLASSIFIER_LIMITS.retentionMs).run();
  const before = await db.prepare("SELECT COUNT(*) AS n FROM misclass_samples WHERE owner = ?").bind(owner).first();
  const statements = valid.map((sample) => db.prepare("INSERT OR IGNORE INTO misclass_samples (id, owner, received_at, rule_version, body) VALUES (?, ?, ?, ?, ?)")
    .bind(sample.id.toLowerCase(), owner, now, sample.ruleVersion, JSON.stringify({ ...sample, id: sample.id.toLowerCase() })));
  if (typeof db.batch === "function") { if (statements.length) await db.batch(statements); } else for (const statement of statements) await statement.run();
  const after = await db.prepare("SELECT COUNT(*) AS n FROM misclass_samples WHERE owner = ?").bind(owner).first();
  const accepted = Math.max(0, (after?.n ?? 0) - (before?.n ?? 0));
  return json({ ok: true, accepted, duplicates: valid.length - accepted, rejected }, 201);
}

const tooManyToday = () => json({ error: "classifier_daily_limit", retryAfter: 3600, perDay: CLASSIFIER_LIMITS.perDay }, 429, { "retry-after": "3600" });

export async function erase(ctx) {
  const db = ctx.env.RELAY_DB;
  if (!db) return json({ error: "unavailable" }, 503);
  const owner = await ownerHash(ctx.master);
  const count = await db.prepare("SELECT COUNT(*) AS n FROM misclass_samples WHERE owner = ?").bind(owner).first();
  await db.prepare("DELETE FROM misclass_samples WHERE owner = ?").bind(owner).run();
  return json({ ok: true, deleted: count?.n ?? 0 }, 200);
}

/** 운영자가 학습용으로 읽는다. owner·받은 시각은 내주지 않고, 순서 번호(seq)만 붙인다. */
export async function adminRoute(request, env, url) {
  const token = env.CLASSIFIER_ADMIN_TOKEN;
  if (typeof token !== "string" || token.length < 32 || !env.RELAY_DB) return json({ error: "unavailable" }, 503);
  const given = /^Bearer (.+)$/.exec(request.headers.get("authorization") ?? "")?.[1];
  if (!sameText(given, token)) return json({ error: "unauthorized" }, 401);
  if (request.method !== "GET") return json({ error: "method_not_allowed" }, 405, { allow: "GET" });
  const since = Number(url.searchParams.get("since") ?? 0);
  const limit = Number(url.searchParams.get("limit") ?? 200);
  if (!Number.isInteger(since) || since < 0 || !Number.isInteger(limit) || limit < 1 || limit > CLASSIFIER_LIMITS.adminPage) return json({ error: "bad_query" }, 422);
  const { results } = await env.RELAY_DB.prepare("SELECT seq, body FROM misclass_samples WHERE seq > ? ORDER BY seq LIMIT ?").bind(since, limit).all();
  const samples = results.map((row) => ({ seq: row.seq, ...JSON.parse(row.body) }));
  return json({ format: "bokki-misclassification", version: 1, samples, next: samples.at(-1)?.seq ?? since }, 200);
}
