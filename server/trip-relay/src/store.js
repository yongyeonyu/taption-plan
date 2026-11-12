// 저장소 읽기·쓰기. HTTP 경로와 MCP 도구가 같은 함수를 부른다(AIR1110A02).
// ctx = { kv, store: 암호화 KV, state: 주인 DO, ring, auth, master: 주인 해시, now: 밀리초, legacy: DO의 이전 표시 }
// SEC1110A02: 하루 기록 이름은 `act:<주인>:<HMAC(날짜)>`이고 날짜 목록은 DO가 잠근 채 가진다(KV list를 쓰지 않는다).
// 명령 큐와 24시간 한도는 DO가 가진다. 여행 계획·명령 결과·추가 칸(goals·trips·placeBook)은 KV에 잠가 둔다.
import { nameKey, openJson, sealJson, tagOf } from "./crypto.js";
import { json, stored, tooMany } from "./http.js";
import { chargeWrites } from "./state.js";
import { ACTIVITY_EXTRAS, QUEUE_LIMIT, cleanCommand, commandReason, isActivityUpload, isAnswerList, cleanAnswers, isAppState, cleanAppState, isCommand, isCommandResults, isDate, isPolishList, isTaskResult, isTaskUpload, isTripPlan, TASK_LIMIT } from "./validate.js";

const DAY = 24 * 60 * 60;
const DAY_MS = DAY * 1000;
export const PLAN_TTL_SECONDS = 3 * DAY;
export const QUEUE_TTL_SECONDS = 7 * DAY;
// 주인 이름마다 24시간 동안 받은 명령 30개까지(CLN1110A01). 세는 곳은 DO다.
export const DAILY_COMMAND_LIMIT = 30;
// 말풍선은 따로 24시간 48개(BUB1110A01). 30개 한도에 세지 않는다.
export const DAILY_BUBBLE_LIMIT = 48;

const planName = (ctx) => "plan:" + ctx.master;
const dayPrefix = (ctx) => `act:${ctx.master}:`;
const legacyQueueName = (ctx) => "cmd:" + ctx.master;
const resultName = (ctx) => "cmdres:" + ctx.master;
const extrasName = (ctx) => "ext:" + ctx.master;
const polishName = (ctx) => "polish:" + ctx.master;
export const POLISH_TTL_SECONDS = 7 * DAY;
const iso = (ms) => new Date(ms).toISOString();

function parse(text, fallback) {
  try { return JSON.parse(text) ?? fallback; } catch { return fallback; }
}

const names = (ctx) => (ctx.names ??= ctx.ring.dekBytes().then(nameKey));
export const dayName = async (ctx, date) => dayPrefix(ctx) + (await tagOf(await names(ctx), "day|" + date));
const commandTag = async (ctx, id) => tagOf(await names(ctx), "cmd|" + id);
const sealDate = async (ctx, name, date) => sealJson(await ctx.ring.dek(), "day|" + name, date);
// 하루 내용의 표시(updatedAt 제외). 같은 내용을 다시 올리면 KV에 쓰지 않는다(N1).
const contentTag = async (ctx, day) => tagOf(await names(ctx), "content|" + JSON.stringify({ ...day, updatedAt: undefined }));
const overBudget = (charge) => tooMany(charge.error, charge.retryAfter);
const sealCommand = async (ctx, tag, command) => sealJson(await ctx.ring.dek(), `cmd|${ctx.master}|${tag}`, command);

export async function listNames(kv, prefix) {
  const out = [];
  let cursor;
  do {
    const page = await kv.list({ prefix, cursor });
    out.push(...page.keys.map((key) => ({ name: key.name, expiration: key.expiration })));
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);
  return out;
}

// MARK: plan

export async function savePlan(ctx, value) {
  if (!isTripPlan(value)) return json({ error: "not_trip_plan" }, 422);
  const charge = await chargeWrites(ctx.env, ctx.state, 1, ctx.now);
  if (!charge.ok) return overBudget(charge);
  await ctx.store.put(planName(ctx), JSON.stringify(value), { expirationTtl: PLAN_TTL_SECONDS });
  return json({ ok: true, tripId: value.tripId, expiresInSeconds: PLAN_TTL_SECONDS }, 201);
}

export async function readPlan(ctx) {
  const text = await ctx.store.get(planName(ctx));
  return text ? stored(text) : json(null, 204);
}

// 없으면 지우지 않는다(KV 지우기 한도를 아낀다).
export async function deletePlan(ctx) {
  if ((await ctx.kv.get(planName(ctx))) != null) await ctx.kv.delete(planName(ctx));
  return json(null, 204);
}

// MARK: 다듬어 줄 메모 (MEM1110A02)

// 앱이 목록 전체를 바꿔 쓴다. AI는 읽기만 하고, 다듬은 글은 updateMemo 명령으로 보낸다.
export async function savePolish(ctx, value) {
  if (!isPolishList(value)) return json({ error: "not_polish_list" }, 422);
  const charge = await chargeWrites(ctx.env, ctx.state, 1, ctx.now);
  if (!charge.ok) return overBudget(charge);
  const memos = value.memos.map(({ id, text, date }) => (date ? { id, text, date } : { id, text }));
  await ctx.store.put(polishName(ctx), JSON.stringify({ format: "bokki-polish", version: 1, memos }), { expirationTtl: POLISH_TTL_SECONDS });
  return json({ ok: true, count: memos.length, expiresInSeconds: POLISH_TTL_SECONDS }, 201);
}

export async function readPolish(ctx) {
  const text = await ctx.store.get(polishName(ctx));
  return text ? stored(text) : json(null, 204);
}

export async function deletePolish(ctx) {
  if ((await ctx.kv.get(polishName(ctx))) != null) await ctx.kv.delete(polishName(ctx));
  return json(null, 204);
}

// MARK: 질문과 답 (ASK1112A01)

// AI가 askUser 명령으로 물은 것과 사용자의 답. 앱이 목록 전체를 바꿔 쓰고 AI는 읽기만 한다. 7일 뒤 사라진다.
const answersName = (ctx) => "answers:" + ctx.master;
export async function saveAnswers(ctx, value) {
  if (!isAnswerList(value)) return json({ error: "not_answer_list" }, 422);
  const charge = await chargeWrites(ctx.env, ctx.state, 1, ctx.now);
  if (!charge.ok) return overBudget(charge);
  const answers = cleanAnswers(value);
  await ctx.store.put(answersName(ctx), JSON.stringify({ format: "bokki-answers", version: 1, answers }), { expirationTtl: POLISH_TTL_SECONDS });
  return json({ ok: true, count: answers.length, expiresInSeconds: POLISH_TTL_SECONDS }, 201);
}

export async function readAnswers(ctx) {
  const text = await ctx.store.get(answersName(ctx));
  return text ? stored(text) : json(null, 204);
}

export async function deleteAnswers(ctx) {
  if ((await ctx.kv.get(answersName(ctx))) != null) await ctx.kv.delete(answersName(ctx));
  return json(null, 204);
}

// MARK: 앱 상태 (ACX1112A01)

// 앱이 통째로 바꿔 쓴다. AI는 읽기만 한다. 하루 기록과 같은 보관 기간 뒤 사라진다.
const appName = (ctx) => "app:" + ctx.master;
export async function saveAppState(ctx, value) {
  if (!isAppState(value)) return json({ error: "not_app_state" }, 422);
  const charge = await chargeWrites(ctx.env, ctx.state, 1, ctx.now);
  if (!charge.ok) return overBudget(charge);
  const ttl = value.retentionDays * DAY;
  await ctx.store.put(appName(ctx), JSON.stringify(cleanAppState(value)), { expirationTtl: ttl });
  return json({ ok: true, expiresInSeconds: ttl }, 201);
}

export async function readAppState(ctx) {
  const text = await ctx.store.get(appName(ctx));
  return text ? stored(text) : json(null, 204);
}

export async function deleteAppState(ctx) {
  if ((await ctx.kv.get(appName(ctx))) != null) await ctx.kv.delete(appName(ctx));
  return json(null, 204);
}

// MARK: AI 확인 목록 (AIQ1111A01)

// 앱(주인)이 올리고, AI가 가져가면 처리중, 결과를 내면 완료·실패. 끝난 항목은 원문을 지운다(대표 결정: 처리되면 지움, 길어도 7일).
const tasksName = (ctx) => "tasks:" + ctx.master;
export const TASKS_TTL_SECONDS = 7 * DAY;
const loadTasks = async (ctx) => parse(await ctx.store.get(tasksName(ctx)), null)?.tasks ?? [];
async function storeTasks(ctx, tasks) {
  if (tasks.length === 0) {
    if ((await ctx.kv.get(tasksName(ctx))) != null) await ctx.kv.delete(tasksName(ctx));
    return;
  }
  await ctx.store.put(tasksName(ctx), JSON.stringify({ format: "bokki-tasks", version: 1, tasks }), { expirationTtl: TASKS_TTL_SECONDS });
}
const tasksReply = (tasks) => (tasks.length ? json({ format: "bokki-tasks", version: 1, tasks }) : json(null, 204));
const isOpen = (task) => task.status === "waiting" || task.status === "processing";

export async function saveTasks(ctx, value) {
  if (!isTaskUpload(value)) return json({ error: "not_task_list" }, 422);
  const charge = await chargeWrites(ctx.env, ctx.state, 1, ctx.now);
  if (!charge.ok) return overBudget(charge);
  const tasks = await loadTasks(ctx);
  const known = new Set(tasks.map((task) => task.id));
  let added = 0;
  for (const { id, kind, text, date, context } of value.tasks) {
    if (known.has(id)) continue;
    tasks.push({ id, kind, text, ...(date ? { date } : {}), ...(context ? { context } : {}), status: "waiting", createdAt: iso(ctx.now), updatedAt: iso(ctx.now) });
    added += 1;
  }
  // 넘치면 끝난 것부터, 그다음 오래된 것부터 버린다.
  while (tasks.length > TASK_LIMIT) {
    const index = tasks.findIndex((task) => !isOpen(task));
    tasks.splice(index >= 0 ? index : 0, 1);
  }
  await storeTasks(ctx, tasks);
  return json({ ok: true, added, expiresInSeconds: TASKS_TTL_SECONDS }, 201);
}

export async function readTasks(ctx) {
  return tasksReply(await loadTasks(ctx));
}

// AI가 가져간다. 대기 중인 것을 처리중으로 바꾸고 아직 안 끝난 것을 돌려준다.
export async function claimTasks(ctx) {
  const tasks = await loadTasks(ctx);
  const waiting = tasks.filter((task) => task.status === "waiting");
  if (waiting.length > 0) {
    const charge = await chargeWrites(ctx.env, ctx.state, 1, ctx.now);
    if (!charge.ok) return overBudget(charge);
    for (const task of waiting) { task.status = "processing"; task.updatedAt = iso(ctx.now); }
    await storeTasks(ctx, tasks);
  }
  return tasksReply(tasks.filter(isOpen).map(({ id, kind, text, date, context, status }) => ({ id, kind, text, ...(date ? { date } : {}), ...(context ? { context } : {}), status })));
}

export async function finishTask(ctx, value) {
  if (!isTaskResult(value)) return json({ error: "not_task_result" }, 422);
  const tasks = await loadTasks(ctx);
  const task = tasks.find((item) => item.id === value.id);
  if (!task) return json({ error: "no_task" }, 404);
  const charge = await chargeWrites(ctx.env, ctx.state, 1, ctx.now);
  if (!charge.ok) return overBudget(charge);
  task.status = value.status;
  task.updatedAt = iso(ctx.now);
  delete task.text;
  delete task.context;
  if (value.result) task.result = value.result; else delete task.result;
  if (value.reason) task.reason = value.reason; else delete task.reason;
  await storeTasks(ctx, tasks);
  return json({ ok: true, id: task.id, status: task.status });
}

// 앱이 끝난 항목(완료·실패)을 지운다.
export async function deleteFinishedTasks(ctx) {
  const tasks = await loadTasks(ctx);
  const open = tasks.filter(isOpen);
  if (open.length !== tasks.length) await storeTasks(ctx, open);
  return json(null, 204);
}

// MARK: 예전 하루 기록 옮기기 (SEC1110A02)

// `act:<주인>:YYYY-MM-DD`(v1·v2·평문)를 HMAC 이름으로 옮기고 DO 목록에 넣는다. 남은 TTL은 지킨다. 지우지 않고 옮긴다.
// 범위 키는 v1을 풀 수 없으므로 한 번만 해 보고(daysScopedTried), 나머지는 주인(앱)이 다음 요청에서 마친다.
// N11: 한 번에 한 요청만 옮기고(DO 잠금), 새 이름이 이미 있는지는 KV가 아니라 DO 목록으로 보고, 요청 하나에 10일씩 옮긴다.
// 돌려주는 값: 다른 요청이 옮기는 중이면 false.
const MIGRATE_DAYS_PER_REQUEST = 10;

export async function ensureDays(ctx) {
  if (ctx.legacy.days || (!ctx.ring.owner && ctx.legacy.daysScopedTried)) return true;
  if (!(await ctx.state.call("claim", { name: "days", now: ctx.now })).ok) return false;
  const prefix = dayPrefix(ctx);
  const nowSeconds = Math.floor(ctx.now / 1000);
  const indexed = new Set((await ctx.state.call("listDays")).days.map((d) => d.name));
  const index = [];
  let blocked = false;
  let more = false;
  for (const { name, expiration } of await listNames(ctx.kv, prefix)) {
    const left = expiration ? expiration - nowSeconds : 7 * DAY;
    if (left < 60 || indexed.has(name)) continue;
    if (index.length >= MIGRATE_DAYS_PER_REQUEST) { more = true; break; }
    const suffix = name.slice(prefix.length);
    const text = await ctx.store.get(name, { reseal: false });
    if (text === null) { if (!ctx.ring.owner) blocked = true; continue; }
    const day = parse(text, null);
    if (isDate(suffix)) {
      const target = await dayName(ctx, suffix);
      // 새 이름이 목록에 있으면 그것이 더 새롭다.
      if (!indexed.has(target)) {
        await ctx.store.put(target, text, { expirationTtl: left });
        index.push({ name: target, date: await sealDate(ctx, target, suffix), exp: ctx.now + left * 1000 });
      }
      await ctx.kv.delete(name);
    } else if (isDate(day?.date)) {
      index.push({ name, date: await sealDate(ctx, name, day.date), exp: ctx.now + left * 1000 });
    }
  }
  if (index.length) await ctx.state.call("putDays", { days: index, now: ctx.now });
  const flags = more ? {} : blocked ? { daysScopedTried: true } : { days: true };
  if (!more) await ctx.state.call("markLegacy", flags);
  Object.assign(ctx.legacy, flags);
  await ctx.state.call("release", { name: "days" });
  return true;
}

// 저장된 날 [{name, date}] 날짜순. 만료된 이름표는 정리한다.
async function storedDays(ctx) {
  await ensureDays(ctx);
  const { days } = await ctx.state.call("listDays");
  const dek = await ctx.ring.dek();
  const live = [];
  const stale = [];
  for (const d of days) {
    const date = d.exp > ctx.now ? await openJson(dek, "day|" + d.name, d.date) : null;
    if (isDate(date)) live.push({ name: d.name, date });
    else stale.push(d.name);
  }
  if (stale.length) await ctx.state.call("removeDays", { names: stale });
  return live.sort((a, b) => a.date.localeCompare(b.date));
}

async function readDay(ctx, date) {
  const text = await ctx.store.get(await dayName(ctx, date));
  if (text || ctx.legacy.days) return text;
  // 아직 옮기지 못한 예전 이름(범위 키가 먼저 온 경우).
  return ctx.store.get(dayPrefix(ctx) + date, { reseal: false });
}

// MARK: activity

async function saveExtras(ctx, value, ttl) {
  const provided = ACTIVITY_EXTRAS.filter((name) => value[name] !== undefined);
  if (!provided.length) return;
  const extras = parse((await ctx.store.get(extrasName(ctx))) ?? "{}", {});
  for (const name of provided) {
    if (value[name] === null) delete extras[name];
    else extras[name] = value[name];
  }
  if (Object.keys(extras).length) await ctx.store.put(extrasName(ctx), JSON.stringify(extras), { expirationTtl: ttl });
  else if ((await ctx.kv.get(extrasName(ctx))) != null) await ctx.kv.delete(extrasName(ctx));
}

// 올린 뒤 보관 기간의 3/4 넘게 남아 있고 내용이 같으면 다시 쓰지 않는다.
const unchanged = (row, hash, ttl, now) => !!row && row.hash === hash && row.exp - now <= ttl * 1000 && row.exp - now > ttl * 750;

export async function saveActivity(ctx, value) {
  if (!isActivityUpload(value)) return json({ error: "not_activity" }, 422);
  if (!(await ensureDays(ctx))) return json({ error: "migrating", retryAfter: 60 }, 503, { "retry-after": "60" });
  const ttl = value.retentionDays * DAY;
  const known = new Map((await ctx.state.call("listDays")).days.map((d) => [d.name, d]));
  const changed = [];
  for (const day of value.days) {
    const name = await dayName(ctx, day.date);
    const hash = await contentTag(ctx, day);
    if (!unchanged(known.get(name), hash, ttl, ctx.now)) changed.push({ day, name, hash });
  }
  const extras = ACTIVITY_EXTRAS.some((name) => value[name] !== undefined);
  const charge = await chargeWrites(ctx.env, ctx.state, changed.length + (extras ? 1 : 0), ctx.now);
  if (!charge.ok) return overBudget(charge);
  const index = [];
  for (const { day, name, hash } of changed) {
    await ctx.store.put(name, JSON.stringify(day), { expirationTtl: ttl });
    index.push({ name, date: await sealDate(ctx, name, day.date), exp: ctx.now + ttl * 1000, hash });
  }
  if (index.length) {
    const { dropped } = await ctx.state.call("putDays", { days: index, now: ctx.now });
    for (const name of dropped ?? []) await ctx.kv.delete(name);
  }
  await saveExtras(ctx, value, ttl);
  return json({ ok: true, dates: value.days.map((day) => day.date), expiresInSeconds: ttl, written: changed.length }, 201);
}

// 이 연결이 어느 기기 것이고 얼마나 새것인지(AIC1112A01). 앱이 한 번도 오지 않았으면 null.
export async function readSync(ctx) {
  const { seenAt, uploadedAt, client } = await ctx.state.call("syncInfo");
  if (seenAt === null && uploadedAt === null) return null;
  return { ...(seenAt === null ? {} : { appLastSeenAt: iso(seenAt) }), ...(uploadedAt === null ? {} : { lastUploadAt: iso(uploadedAt) }), ...(client ?? {}) };
}
const withSync = async (ctx, value) => {
  const sync = await readSync(ctx);
  return sync ? { ...value, sync } : value;
};

export async function readActivity(ctx, date) {
  if (date !== null && date !== undefined) {
    if (!isDate(date)) return json({ error: "bad_date" }, 400);
    await ensureDays(ctx);
    const day = parse((await readDay(ctx, date)) ?? "null", null);
    return day && typeof day === "object" ? json(await withSync(ctx, day), 200) : json(null, 204);
  }
  const newest = (await storedDays(ctx)).reverse().slice(0, 7);
  const days = [];
  for (const { name } of newest) {
    const day = parse((await ctx.store.get(name)) ?? "null", null);
    if (day) days.push(day);
  }
  const extras = parse((await ctx.store.get(extrasName(ctx))) ?? "{}", {});
  return days.length ? json(await withSync(ctx, { days, ...extras }), 200) : json(null, 204);
}

// 이 주인의 모든 날과 추가 칸을 지운다. 아무것도 없으면 KV를 건드리지 않는다.
export async function deleteActivity(ctx) {
  const { days } = await ctx.state.call("listDays");
  const all = new Set(days.map((d) => d.name));
  if (!ctx.legacy.days) for (const { name } of await listNames(ctx.kv, dayPrefix(ctx))) all.add(name);
  const extras = (await ctx.kv.get(extrasName(ctx))) != null;
  if (!all.size && !extras && ctx.legacy.days) return json(null, 204);
  for (const name of all) await ctx.kv.delete(name);
  if (extras) await ctx.kv.delete(extrasName(ctx));
  if (days.length) await ctx.state.call("removeDays", { names: null });
  if (!ctx.legacy.days) await ctx.state.call("markLegacy", { days: true });
  return json(null, 204);
}

// MARK: summary (AIR1110A02)

const RANGE_DAYS = { week: 7, month: 30 };
const utcDate = (ms) => new Date(ms).toISOString().slice(0, 10);
const number = (v) => (typeof v === "number" && Number.isFinite(v) ? v : 0);

// 서버에 있는 날들을 모아 분류별 분·기록 분·걸음·계획 수를 더한다.
export function summarize(days, range, start, end) {
  const categories = new Map();
  const total = { recordedMinutes: 0, steps: 0, plansScheduled: 0, plansCompleted: 0 };
  let stepDays = 0;
  for (const day of [...days].sort((a, b) => a.date.localeCompare(b.date))) {
    const s = day.summary ?? {};
    total.recordedMinutes += number(s.recordedMinutes);
    total.plansScheduled += number(s.plansScheduled);
    total.plansCompleted += number(s.plansCompleted);
    if (typeof s.steps === "number") { total.steps += number(s.steps); stepDays++; }
    for (const c of Array.isArray(s.categories) ? s.categories : []) {
      if (typeof c?.id !== "string") continue;
      const entry = categories.get(c.id) ?? { id: c.id, title: c.title ?? c.id, minutes: 0 };
      entry.minutes += number(c.minutes);
      if (typeof c.title === "string") entry.title = c.title; // 최신 날의 이름
      categories.set(c.id, entry);
    }
  }
  return {
    range, start, end,
    daysCovered: days.length,
    dates: days.map((d) => d.date).sort(),
    ...total,
    stepDays,
    categories: [...categories.values()].sort((a, b) => b.minutes - a.minutes || a.id.localeCompare(b.id)),
  };
}

export async function readSummary(ctx, range, end) {
  const length = RANGE_DAYS[range];
  if (!length) return json({ error: "bad_range" }, 400);
  if (end !== null && end !== undefined && !isDate(end)) return json({ error: "bad_date" }, 400);
  const all = await storedDays(ctx);
  // 끝 날짜가 없으면 오늘(UTC)과 가장 최근에 올린 날 중 늦은 날. 동쪽 시간대의 '오늘'을 놓치지 않는다.
  const last = end ?? [utcDate(ctx.now), all.at(-1)?.date ?? ""].sort().at(-1);
  const start = utcDate(Date.parse(last + "T00:00:00Z") - (length - 1) * DAY_MS);
  const days = [];
  for (const { name, date } of all.filter((d) => d.date >= start && d.date <= last)) {
    const day = parse((await ctx.store.get(name)) ?? "null", null);
    if (isDate(day?.date)) days.push(day);
    else if (day) days.push({ ...day, date });
  }
  return days.length ? json(await withSync(ctx, summarize(days, range, start, last)), 200) : json(null, 204);
}

// MARK: commands (finding 6, 8, 14)

// 예전 KV 큐(`cmd:<주인>`, 배열 또는 {commands, sent})를 DO로 한 번 옮긴다. keyId는 null, source는 "legacy"가 된다.
export async function ensureQueue(ctx) {
  if (ctx.legacy.queue) return;
  const name = legacyQueueName(ctx);
  if ((await ctx.kv.get(name)) != null) {
    const text = await ctx.store.get(name, { reseal: false });
    if (text === null && !ctx.ring.owner) return; // v1: 주인이 옮긴다.
    const value = parse(text ?? "null", null);
    const commands = Array.isArray(value) ? value : Array.isArray(value?.commands) ? value.commands : [];
    const sent = Array.isArray(value?.sent) ? value.sent.filter((t) => typeof t === "number") : [];
    const items = [];
    for (const command of commands) {
      if (typeof command?.id !== "string") continue;
      const tag = await commandTag(ctx, command.id);
      const { keyId, source, ...rest } = command;
      items.push({ tag, sealed: await sealCommand(ctx, tag, rest), receivedAt: Date.parse(command.receivedAt) || ctx.now });
    }
    await ctx.state.call("importQueue", { items, sent });
    await ctx.kv.delete(name);
  }
  await ctx.state.call("markLegacy", { queue: true });
  ctx.legacy.queue = true;
}

// source: rest(REST 연결 키·주인) | mcp(MCP에 연결 키) | oauth(MCP에 OAuth 토큰).
export async function queueCommand(ctx, value, source = "rest") {
  const command = isCommand(value) ? cleanCommand(value) : null;
  if (!command) {
    const reason = commandReason(value);
    return json({ error: "not_command", ...(reason ? { reason } : {}) }, 422);
  }
  await ensureQueue(ctx);
  const tag = await commandTag(ctx, command.id);
  const entry = { ...command, keyId: ctx.auth.keyId, source, receivedAt: iso(ctx.now) };
  const bubble = command.action === "setBubble";
  const result = await ctx.state.call("enqueue", { tag, keyId: ctx.auth.keyId, source, sealed: await sealCommand(ctx, tag, entry), now: ctx.now, bubble });
  if (result.error === "id_conflict") return json({ error: "id_conflict" }, 409);
  if (!result.ok) {
    const retry = result.retryAfter;
    const limit = bubble ? DAILY_BUBBLE_LIMIT : DAILY_COMMAND_LIMIT;
    return json({ error: result.error, limit, retryAfter: retry, retryAfterSeconds: retry }, 429, { "retry-after": String(retry) });
  }
  return json({ ok: true, id: command.id, queued: result.queued, remainingToday: result.remaining, expiresInSeconds: QUEUE_TTL_SECONDS }, 201);
}

export async function readCommands(ctx) {
  await ensureQueue(ctx);
  const { commands, aiSeen, aiEnded } = await ctx.state.call("listQueue", { now: ctx.now });
  // 앱이 확인 간격을 정하게 AI가 마지막으로 온 지 몇 초인지(온 적 없으면 -1), 그 뒤 대화를 마쳤는지 알린다(SYN1111A03).
  const headers = {
    "x-ai-seen-ago": String(aiSeen ? Math.max(0, Math.floor((ctx.now - aiSeen) / 1000)) : -1),
    "x-ai-ended": aiEnded && (!aiSeen || aiEnded >= aiSeen) ? "1" : "0",
  };
  const dek = await ctx.ring.dek();
  const out = [];
  for (const item of commands) {
    const command = await openJson(dek, `cmd|${ctx.master}|${item.tag}`, item.sealed);
    if (command) out.push({ ...command, keyId: item.keyId, source: item.source, receivedAt: command.receivedAt ?? iso(item.receivedAt) });
  }
  return out.length ? json({ commands: out }, 200, headers) : json(null, 204, headers);
}

// AI가 대화를 마쳤다(SYN1111A03). 읽기 키도 부를 수 있다.
export async function endConversation(ctx) {
  await ctx.state.call("endSession", { now: ctx.now });
  return json({ ok: true }, 200);
}

// 지워도 24시간 받은 수는 남긴다. 그래야 앱이 큐를 비울 때마다 한도가 풀리지 않는다.
export async function deleteCommands(ctx, ids) {
  await ensureQueue(ctx);
  // 예전에 받은 id는 앞뒤 공백이 있을 수 있어 그대로와 다듬은 것을 모두 지운다(N10).
  const list = ids ? [...new Set(ids.split(",").flatMap((id) => [id, id.trim()]).filter(Boolean))] : null;
  const tags = list ? await Promise.all(list.map((id) => commandTag(ctx, id))) : null;
  await ctx.state.call("removeQueue", { tags });
  return json(null, 204);
}

// MARK: command results

export async function saveResults(ctx, value) {
  if (!isCommandResults(value)) return json({ error: "not_results" }, 422);
  const charge = await chargeWrites(ctx.env, ctx.state, 1, ctx.now);
  if (!charge.ok) return overBudget(charge);
  const at = iso(ctx.now);
  const entries = value.results.map(({ id, status, reason }) => ({ id, status, ...(reason ? { reason } : {}), at }));
  const ids = new Set(entries.map((e) => e.id));
  const old = parse((await ctx.store.get(resultName(ctx))) ?? "[]", []);
  const items = (Array.isArray(old) ? old : []).filter((e) => !ids.has(e.id)).concat(entries).slice(-QUEUE_LIMIT);
  await ctx.store.put(resultName(ctx), JSON.stringify(items), { expirationTtl: QUEUE_TTL_SECONDS });
  return json({ ok: true }, 201);
}

export async function readResults(ctx) {
  const results = parse((await ctx.store.get(resultName(ctx))) ?? "[]", []);
  return Array.isArray(results) && results.length ? json({ results }, 200) : json(null, 204);
}
