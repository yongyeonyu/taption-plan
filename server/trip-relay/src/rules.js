// 규칙 저장소(AIX1114A01 P3). AI가 판단한 것을 규칙(JSON)으로 서버에 계속 두고, 앱이 같은 버전을 받아 1차로 쓴다.
// 목록은 Durable Object에 규칙 하나씩 둔다(기한 없음, 쓰기가 차례로 일어남). 본문(match·result·note·source)은 봉인한다.
// 규칙 종류와 칸은 아래 RULE_TYPES 한 곳에 있고, 앱의 Swift 평가기와 `test/fixtures/rules.json`으로 맞춘다.
import { notify, pushForRules } from "./apns.js";
import { openJson, randomHex, sealJson } from "./crypto.js";
import { json } from "./http.js";

export const RULE_ENGINE = 1;
export const RULE_LIMITS = { rules: 500, perRequest: 20, bytes: 1500, gone: 200, contains: 10 };
export const RULE_CATEGORIES = ["food", "cafe", "transport", "shopping", "living", "health", "culture", "travel", "lodging", "education", "gift", "salary", "other"];
export const RULE_MODES = ["walk", "subway", "bus", "car", "train", "flight", "cycling"];

const codePoints = (text) => [...text].length;
const isObject = (v) => !!v && typeof v === "object" && !Array.isArray(v);
// 낱말: 2~40자, 숫자·공백만은 안 되고, 숫자 9자리가 이어지면(계좌·카드·전화) 안 된다.
const word = (min = 2, max = 40) => (v) => typeof v === "string" && codePoints(v.trim()) >= min && codePoints(v) <= max
  && !/^[\d\s]+$/.test(v) && !/\d{9,}/.test(v);
// 노선·번호처럼 숫자만이어도 되는 짧은 이름(「80」, 「1호선」). 긴 숫자는 여전히 안 된다.
const label = (max) => (v) => typeof v === "string" && codePoints(v.trim()) >= 1 && codePoints(v) <= max && !/\d{9,}/.test(v);
const words = (v) => Array.isArray(v) && v.length >= 1 && v.length <= RULE_LIMITS.contains && v.every(word()) && new Set(v).size === v.length;
const oneOf = (values) => (v) => values.includes(v);
const flag = (v) => typeof v === "boolean";
// 정규식: 300자, 묶음 12개까지. 되돌아보기·역참조·겹친 반복(지수 시간)은 받지 않는다.
export function safePattern(v) {
  if (typeof v !== "string" || v.length < 1 || v.length > 300) return false;
  if ((v.match(/\((?!\?[:=!])/g) ?? []).length > 12) return false;
  if (/\(\?<[=!]/.test(v) || /\\[1-9]/.test(v) || /\\k</.test(v)) return false;
  return !/\([^()]*[+*][^()]*\)\s*[+*{]/.test(v);
}

/** 종류마다 match·result에 받는 칸. `!`가 붙은 이름은 꼭 있어야 한다. `any`는 그 가운데 하나는 있어야 하는 칸들. */
export const RULE_TYPES = {
  payment_text: { match: { "pattern!": safePattern, "sample!": (v) => typeof v === "string" && v.length >= 1 && v.length <= 1000 },
    result: { "kind!": oneOf(["expense", "income", "ignore"]), name: word(1, 40) } },
  skip_word: { match: { "word!": word(1, 20) }, result: {} },
  text_ignore: { match: { "contains!": words, source: word(1, 40) }, result: { reason: word(1, 60) } },
  internal_transfer: { match: { "contains!": words }, result: {} },
  own_account: { match: { "name!": word(1, 30) }, result: {} },
  source_switch: { match: { "app!": word(1, 40) }, result: { "expense!": flag, "income!": flag } },
  merchant_category: { match: { contains: words, equals: word(1, 60), field: oneOf(["merchant", "text"]) }, any: ["contains", "equals"],
    result: { "category!": oneOf(RULE_CATEGORIES), title: word(1, 60) } },
  receipt_hint: { match: { "contains!": words }, result: { "isReceipt!": flag, category: oneOf(RULE_CATEGORIES) } },
  calendar_title: { match: { "title!": word(1, 80) }, result: { detailId: (v) => v === "none" || /^[\w.-]{1,60}$/.test(v) } },
  place_pair_mode: { match: { "from!": word(1, 60), "to!": word(1, 60) }, result: { "mode!": oneOf(RULE_MODES), line: label(20) } },
  ride_line: { match: { "board!": word(1, 60), "alight!": word(1, 60), "mode!": oneOf(["bus", "subway"]) }, result: { "line!": label(20) } },
};

function part(spec, value) {
  if (!isObject(value)) return null;
  const out = {};
  for (const [key, check] of Object.entries(spec)) {
    const name = key.replace("!", ""), given = value[name] !== undefined && value[name] !== null;
    if (!given) { if (key.endsWith("!")) return null; continue; }
    if (!check(value[name])) return null;
    out[name] = value[name];
  }
  return out;
}

/** 모양이 맞으면 알려진 칸만 남긴 규칙 본문 {type, match, result, note?, appliesTo}, 아니면 null. */
export function cleanRule(value) {
  const spec = RULE_TYPES[value?.type];
  if (!spec) return null;
  const match = part(spec.match, value.match), result = part(spec.result, value.result ?? {});
  if (!match || !result) return null;
  if (spec.any && !spec.any.some((name) => name in match)) return null;
  if (value.note !== undefined && value.note !== null && !(typeof value.note === "string" && codePoints(value.note) <= 120 && !/\d{9,}/.test(value.note))) return null;
  const appliesTo = value.appliesTo ?? RULE_ENGINE;
  if (!Number.isInteger(appliesTo) || appliesTo < 1 || appliesTo > 99) return null;
  const rule = { type: value.type, appliesTo, match, result, ...(value.note ? { note: value.note } : {}) };
  return JSON.stringify(rule).length <= RULE_LIMITS.bytes ? rule : null;
}
const ruleID = (v) => typeof v === "string" && /^[\w.:-]{1,64}$/.test(v);

const aad = (ctx, id) => `rule|${ctx.master}|${id}`;
const iso = (ms) => new Date(ms).toISOString();

async function openRules(ctx, listed) {
  const dek = await ctx.ring.dek();
  const rules = [];
  for (const row of listed.rules) {
    const body = await openJson(dek, aad(ctx, row.id), row.sealed);
    if (!body) continue;
    rules.push({ id: row.id, type: row.type, appliesTo: body.appliesTo ?? RULE_ENGINE, enabled: row.enabled, match: body.match, result: body.result,
      source: { by: row.by, ...(row.keyId ? { keyId: row.keyId } : {}), ...(body.taskId ? { taskId: body.taskId } : {}) },
      ...(body.note ? { note: body.note } : {}), createdAt: iso(row.createdAt), updatedAt: iso(row.updatedAt) });
  }
  return rules;
}

// GET /rules?since=<버전>: 같으면 304, 아니면 전체. 앱이 지금 쓰는 버전·건너뛴 규칙도 알려 준다.
export async function readRules(ctx, since) {
  const listed = await ctx.state.call("ruleList", {});
  const tag = `"${listed.version}"`;
  if (since !== null && since !== undefined && String(since) === String(listed.version)) return new Response(null, { status: 304, headers: { etag: tag, "cache-control": "no-store" } });
  return json({ format: "bokki-rules", version: listed.version, engine: RULE_ENGINE, updatedAt: iso(listed.updatedAt ?? ctx.now),
    rules: await openRules(ctx, listed), app: listed.app }, 200, { etag: tag });
}

async function sealRules(ctx, values, by) {
  const items = [];
  for (const value of values) {
    const rule = cleanRule(value);
    if (!rule || (value.id !== undefined && !ruleID(value.id))) return null;
    const id = value.id ?? "r_" + randomHex(8);
    const taskId = ruleID(value.taskId) ? value.taskId : undefined;
    const { type, ...body } = rule;
    items.push({ id, type, by, keyId: by === "ai" ? ctx.auth?.keyId ?? null : null, ...(typeof value.enabled === "boolean" ? { enabled: value.enabled } : {}),
      sealed: await sealJson(await ctx.ring.dek(), aad(ctx, id), { ...body, ...(taskId ? { taskId } : {}) }) });
  }
  return items;
}

// POST /rules {rules:[…]}: AI(쓰기 키)나 앱(주인)이 규칙을 더하거나 같은 id를 고친다.
export async function putRules(ctx, value) {
  if (!Array.isArray(value?.rules) || value.rules.length < 1 || value.rules.length > RULE_LIMITS.perRequest) return json({ error: "not_rule_list" }, 422);
  const master = ctx.auth?.kind === "master";
  const items = await sealRules(ctx, value.rules, master ? "user" : "ai");
  if (!items) return json({ error: "bad_rule" }, 422);
  const result = await ctx.state.call("rulePut", { items, now: ctx.now, master });
  if (result.error) return json({ error: result.error, ...(result.ids ? { ids: result.ids } : {}) }, result.error === "too_many_rules" ? 409 : 422);
  if (result.ids.length) notify(ctx, pushForRules());
  return json({ ok: true, version: result.version, ids: result.ids, refused: result.refused }, 201);
}

// POST /rules/ops {baseVersion, ops:[{op: enable|disable|delete, id} | {op: put, rule}]}: 앱에서 사용자가 고친 것.
export async function applyRuleOps(ctx, value) {
  if (!Array.isArray(value?.ops) || value.ops.length < 1 || value.ops.length > 50) return json({ error: "not_rule_ops" }, 422);
  const ops = [];
  for (const op of value.ops) {
    if (op?.op === "put") {
      const items = await sealRules(ctx, [op.rule], op.rule?.source?.by === "ai" ? "ai" : "user");
      if (!items) return json({ error: "bad_rule" }, 422);
      ops.push({ op: "put", item: items[0] });
    } else if (["enable", "disable", "delete"].includes(op?.op) && ruleID(op.id)) ops.push({ op: op.op, id: op.id });
    else return json({ error: "bad_rule_op" }, 422);
  }
  const result = await ctx.state.call("ruleOps", { ops, now: ctx.now });
  if (result.error) return json({ error: result.error }, 409);
  const stale = Number.isInteger(value.baseVersion) && value.baseVersion !== result.before;
  return json({ ok: true, version: result.version, stale }, 200);
}

// DELETE /rules?ids=a,b: AI는 자기(ai)가 만든 규칙만, 앱(주인)은 모두.
export async function deleteRules(ctx, ids) {
  const list = (ids ?? "").split(",").filter(Boolean);
  if (list.length < 1 || list.length > 50 || !list.every(ruleID)) return json({ error: "bad_rule_ids" }, 422);
  const result = await ctx.state.call("ruleOps", { ops: list.map((id) => ({ op: "delete", id })), now: ctx.now, onlyAI: ctx.auth?.kind !== "master" });
  if (result.changed) notify(ctx, pushForRules());
  return json({ ok: true, version: result.version, removed: result.changed }, 200);
}

export async function setRuleEnabled(ctx, value) {
  if (!ruleID(value?.id) || typeof value.enabled !== "boolean") return json({ error: "bad_rule_op" }, 422);
  const result = await ctx.state.call("ruleOps", { ops: [{ op: value.enabled ? "enable" : "disable", id: value.id }], now: ctx.now });
  if (result.changed) notify(ctx, pushForRules());
  return result.changed ? json({ ok: true, version: result.version }, 200) : json({ error: "no_rule" }, 404);
}

// POST /rules/ack {version, engine, skipped:[id]}: 앱이 어느 버전까지 받아 쓰는지, 못 쓰는 규칙은 무엇인지.
export async function ackRules(ctx, value) {
  if (!Number.isInteger(value?.version) || value.version < 0 || !Number.isInteger(value.engine) || value.engine < 1
    || (value.skipped !== undefined && !(Array.isArray(value.skipped) && value.skipped.length <= RULE_LIMITS.rules && value.skipped.every(ruleID)))) return json({ error: "bad_rule_ack" }, 422);
  await ctx.state.call("ruleAck", { version: value.version, engine: value.engine, skipped: value.skipped ?? [], now: ctx.now });
  return json({ ok: true }, 200);
}
