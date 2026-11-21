// 앱 안 AI 대화(AI1121A01): 앱(주인 키)이 보낸 대화를 Bedrock Converse로 넘기고, 답 + 사용자가 확인할 명령 후보를 돌려준다.
// 명령은 큐에 넣지 않는다. 앱이 화면에서 확인을 받은 뒤 스스로 반영한다.
// 개인정보(AGENTS.md 4절): 좌표·카드번호·주민번호는 보내기 전에 지우고, 맥락은 정한 칸(날짜·시간대·시군구·여행 제목·분류 이름)만 받는다.
// 0원 방어: 사용자·서버 전체 하루 호출 수와 하루 토큰 예약을 넘으면 429. 응답 길이(maxTokens)는 상한으로 자른다.
import { bedrockConfig, converse, readOutput } from "./bedrock.js";
import { json, tooMany } from "./http.js";
import { userState } from "./state.js";
import { COMMAND_FIELDS, EXPENSE_CATEGORIES, TRIP_STATUSES, isCommand, isTripPlan } from "./validate.js";

export const AI_LIMITS = {
  messages: 12,
  messageChars: 2000,
  totalChars: 8000,
  maxTokens: 1024,
  minTokens: 64,
  userCallsPerDay: 30,
  globalCallsPerDay: 300,
  userTokensPerDay: 60_000,
  commands: 20,
  tripBytes: 32 * 1024,
};
// 대화로 만들 수 있는 것은 새로 더하기뿐이다. 고치기·지우기는 앱의 다른 길(확인 시트)로만.
export const CONVERSE_ACTIONS = ["addSchedule", "addMemo", "addExpense", "addTripStop", "addGoal", "addTrip"];
const COORDINATE_FIELDS = ["latitude", "longitude", "lat", "lng"];

const positive = (value, fallback) => {
  const n = Number(value);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : fallback;
};
export function aiLimits(env) {
  return {
    ...AI_LIMITS,
    maxTokens: Math.min(4096, positive(env.AI_MAX_TOKENS, AI_LIMITS.maxTokens)),
    userCallsPerDay: positive(env.AI_USER_DAILY_CALLS, AI_LIMITS.userCallsPerDay),
    globalCallsPerDay: positive(env.AI_GLOBAL_DAILY_CALLS, AI_LIMITS.globalCallsPerDay),
    userTokensPerDay: positive(env.AI_USER_DAILY_TOKENS, AI_LIMITS.userTokensPerDay),
  };
}

// MARK: 민감정보 지우기

const COORDINATE_PATTERNS = [
  /-?\d{1,3}\.\d{3,}\s*[,/ ]\s*-?\d{1,3}\.\d{3,}/g,
  /\d{1,3}\s*°\s*\d{1,2}\s*['′](?:\s*\d{1,2}(?:\.\d+)?\s*["″])?\s*[NSEW북남동서]?/gi,
  /(?:[?&](?:q|ll|sll|center|query|daddr|saddr|destination|origin)=|@)-?\d{1,3}\.\d+\s*(?:,|%2C)\s*-?\d{1,3}\.\d+/gi,
];
const CARD_CANDIDATE = /(?<!\d)\d(?:[ -]?\d){12,18}(?!\d)/g;
const RRN = /(?<!\d)\d{6}\s*-\s*[1-8]\d{6}(?!\d)/g;

function luhn(digits) {
  let sum = 0;
  for (let i = 0; i < digits.length; i++) {
    let d = Number(digits[digits.length - 1 - i]);
    if (i % 2 === 1) { d *= 2; if (d > 9) d -= 9; }
    sum += d;
  }
  return sum % 10 === 0;
}

/** 좌표·카드번호·주민번호를 표시로 바꾼다. 무엇을 지웠는지 종류만 센다. */
export function redact(text) {
  const found = new Set();
  let out = String(text ?? "");
  out = out.replace(RRN, () => { found.add("idNumber"); return "[주민번호 생략]"; });
  out = out.replace(CARD_CANDIDATE, (match) => {
    const digits = match.replace(/\D/g, "");
    if (digits.length < 13 || digits.length > 19 || !luhn(digits)) return match;
    found.add("cardNumber");
    return "[카드번호 생략]";
  });
  for (const pattern of COORDINATE_PATTERNS) out = out.replace(pattern, () => { found.add("coordinates"); return "[위치 생략]"; });
  return { text: out, found: [...found] };
}

// MARK: 요청 읽기

const DATE = /^\d{4}-\d{2}-\d{2}$/;
const OFFSET = /^[+-](?:0\d|1[0-4]):[0-5]\d$/;
const shortText = (value, max) => (typeof value === "string" && value.trim() ? value.trim().slice(0, max) : undefined);

/** 맥락은 정한 칸만 옮긴다. 좌표 칸은 이름이 무엇이든 받지 않는다. */
export function readContext(raw, found) {
  const c = raw && typeof raw === "object" ? raw : {};
  const clean = (value, max) => {
    const text = shortText(value, max);
    if (text === undefined) return undefined;
    const r = redact(text);
    r.found.forEach((kind) => found.add(kind));
    return r.text;
  };
  const out = {};
  if (DATE.test(c.today ?? "")) out.today = c.today;
  if (OFFSET.test(c.timeZone ?? "")) out.timeZone = c.timeZone;
  if (c.language === "ko" || c.language === "en") out.language = c.language;
  const region = clean(c.region, 40);
  if (region) out.region = region;
  if (c.trip && typeof c.trip === "object") {
    const trip = { id: shortText(c.trip.id, 100), title: clean(c.trip.title, 60), startDate: DATE.test(c.trip.startDate ?? "") ? c.trip.startDate : undefined, endDate: DATE.test(c.trip.endDate ?? "") ? c.trip.endDate : undefined };
    if (trip.id || trip.title) out.trip = Object.fromEntries(Object.entries(trip).filter(([, v]) => v !== undefined));
  }
  if (Array.isArray(c.categories)) {
    const categories = c.categories.slice(0, 30).map((item) => ({ id: shortText(item?.id, 64), name: clean(item?.name, 20) })).filter((item) => item.id && item.name);
    if (categories.length) out.categories = categories;
  }
  return out;
}

/** 본문 → { messages, context, maxTokens, chars, redacted } 또는 { error }. */
export function readConverse(body, limits = AI_LIMITS) {
  const messages = body?.messages;
  if (!Array.isArray(messages) || messages.length < 1 || messages.length > limits.messages) return { error: "bad_messages" };
  const found = new Set();
  const out = [];
  let chars = 0;
  for (const message of messages) {
    if (message?.role !== "user" && message?.role !== "assistant") return { error: "bad_messages" };
    if (typeof message.text !== "string" || !message.text.trim()) return { error: "bad_messages" };
    if (message.text.length > limits.messageChars) return { error: "message_too_long" };
    const r = redact(message.text.trim());
    r.found.forEach((kind) => found.add(kind));
    chars += r.text.length;
    // Converse는 같은 역할이 이어지면 거절하므로 합친다.
    const last = out.at(-1);
    if (last?.role === message.role) last.content[0].text += "\n" + r.text;
    else out.push({ role: message.role, content: [{ text: r.text }] });
  }
  if (chars > limits.totalChars) return { error: "conversation_too_long" };
  if (out[0].role !== "user" || out.at(-1).role !== "user") return { error: "bad_messages" };
  const context = readContext(body.context, found);
  const asked = Number(body.maxTokens);
  const maxTokens = Number.isFinite(asked) ? Math.max(limits.minTokens, Math.min(limits.maxTokens, Math.floor(asked))) : limits.maxTokens;
  return { messages: out, context, maxTokens, chars, redacted: [...found].sort() };
}

// MARK: 프롬프트

const ACTION_GUIDE = [
  "addSchedule: title, start (ISO 8601 with offset), end?, note?, categoryId? (only an id from context.categories), important?, plannedSpend? (KRW)",
  "addMemo: text (<=1000), date? (YYYY-MM-DD), time? (HH:mm)",
  "addExpense: amount (>0, number), currency? (ISO 4217, default KRW), title (<=60), category? (" + EXPENSE_CATEGORIES.join("|") + "), kind? (expense|income), date?, time?, tripId? (context.trip.id), note?",
  "addTripStop: title, date (YYYY-MM-DD), tripId? (context.trip.id), status? (" + TRIP_STATUSES.join("|") + ")",
  "addGoal: title, start (YYYY-MM-DD), end?",
  "addTrip: title (<=60), start (YYYY-MM-DD), end?, countryCode? (ISO 3166-1 alpha-2), regionName?, currency?",
];

export function systemPrompt(context) {
  return [
    "You are the travel and day planner inside the BOKKI Plan iOS app. Reply in the user's language (Korean unless context.language is en), briefly and warmly.",
    "Always answer by calling the tool bokki_reply exactly once. Put your message to the user in reply.",
    "Put app actions the user clearly asked for in commands. The app shows them to the user, who confirms before anything changes, so never claim they are already saved.",
    "If a needed detail (date, amount, title) is missing, ask one short question in reply and return no command for it. Never guess amounts or dates.",
    "Never output coordinates, card numbers or ID numbers. Places are names only. Text like [위치 생략] was removed for privacy; do not ask for it.",
    "For a whole multi-day trip plan you may return trip as a bokki-trip draft: { title, startDate, endDate, items: [{ id, type (flight|lodging|activity|meal|transport|other), title, start, end?, place?: { name, address? } }] }.",
    "Allowed command actions and fields:",
    ...ACTION_GUIDE.map((line) => "- " + line),
    "Context: " + JSON.stringify(context),
  ].join("\n");
}

export const REPLY_TOOL = {
  toolSpec: {
    name: "bokki_reply",
    description: "The reply to the user and the app actions to propose for confirmation.",
    inputSchema: {
      json: {
        type: "object",
        required: ["reply"],
        properties: {
          reply: { type: "string", description: "Message to the user." },
          commands: { type: "array", items: { type: "object", required: ["action"], properties: { action: { type: "string", enum: CONVERSE_ACTIONS } } } },
          trip: { type: "object", description: "Optional bokki-trip draft for a multi-day plan." },
        },
      },
    },
  },
};

// MARK: 응답 다듬기

const randomId = () => "ai-" + [...crypto.getRandomValues(new Uint8Array(9))].map((b) => b.toString(16).padStart(2, "0")).join("");

/** 모델이 낸 명령 하나 → 검증된 bokki-command 또는 null. 좌표는 버리고, 좌표 없는 장소 이름은 메모 글로 옮긴다. */
export function shapeCommand(raw) {
  const action = raw?.action;
  if (!CONVERSE_ACTIONS.includes(action)) return null;
  const command = { format: "bokki-command", version: 1, id: randomId(), action };
  for (const field of COMMAND_FIELDS[action] ?? []) {
    if (raw[field] === undefined || raw[field] === null || COORDINATE_FIELDS.includes(field)) continue;
    command[field] = typeof raw[field] === "string" ? redact(raw[field]).text : raw[field];
  }
  if (typeof command.placeName === "string") {
    const place = "장소: " + command.placeName;
    command.note = typeof command.note === "string" && command.note.trim() ? `${command.note}\n${place}` : place;
    delete command.placeName;
  }
  if (typeof command.amount === "string") command.amount = Number(command.amount.replace(/[,\s]/g, ""));
  return isCommand(command) ? command : null;
}

/** bokki-trip 초안 → 검증된 계획 또는 null. 좌표·지도 주소는 지운다. */
export function shapeTrip(raw, limits = AI_LIMITS) {
  if (!raw || typeof raw !== "object" || !Array.isArray(raw.items)) return null;
  const trip = { ...raw, format: "bokki-trip", version: 1, tripId: typeof raw.tripId === "string" && raw.tripId ? raw.tripId.slice(0, 100) : randomId() };
  trip.items = raw.items.slice(0, 200).map((item, index) => {
    const out = { ...item, id: typeof item?.id === "string" && item.id ? item.id.slice(0, 60) : `i${index + 1}` };
    if (item?.place && typeof item.place === "object") {
      out.place = {};
      for (const field of ["name", "address"]) if (typeof item.place[field] === "string") out.place[field] = redact(item.place[field]).text.slice(0, 200);
      if (!out.place.name) delete out.place;
    }
    for (const field of COORDINATE_FIELDS) delete out[field];
    return out;
  });
  if (!isTripPlan(trip)) return null;
  return JSON.stringify(trip).length <= limits.tripBytes ? trip : null;
}

/** 도구 입력이 없으면 글에서 JSON을 찾아 본다. 그것도 없으면 글을 그대로 답으로 쓴다. */
export function readReply(output) {
  const { tool, text, usage, stopReason } = readOutput(output);
  let input = tool?.input ?? null;
  if (!input && text) {
    const start = text.indexOf("{"), end = text.lastIndexOf("}");
    if (start >= 0 && end > start) { try { input = JSON.parse(text.slice(start, end + 1)); } catch { input = null; } }
  }
  const reply = redact(typeof input?.reply === "string" ? input.reply : input ? "" : text).text.slice(0, 2000);
  return { reply, rawCommands: Array.isArray(input?.commands) ? input.commands : [], rawTrip: input?.trip, usage, stopReason };
}

// MARK: 경로

/** POST /ai/converse (주인 키). ctx는 index.js의 인증 문맥. */
export async function converseRoute(ctx, body) {
  const limits = aiLimits(ctx.env);
  const parsed = readConverse(body, limits);
  if (parsed.error) return json({ error: parsed.error }, 400);
  const config = bedrockConfig(ctx.env);
  if (!config) return json({ error: "ai_unavailable" }, 503);
  const now = ctx.now;
  const own = await ctx.state.call("countDaily", { name: "ai-converse", limit: limits.userCallsPerDay, now });
  if (!own.ok) return tooMany("daily_ai_limit", own.retryAfter);
  const all = await userState(ctx.env, "global:ai-converse").call("countDaily", { name: "ai-converse", limit: limits.globalCallsPerDay, now });
  if (!all.ok) return tooMany("daily_ai_server_limit", all.retryAfter);
  // 토큰은 부르기 전에 예약한다: 답 상한 + 입력 추정(글자 2개에 1토큰, 프롬프트 몫 600).
  const reserve = parsed.maxTokens + Math.ceil(parsed.chars / 2) + 600;
  const tokens = await ctx.state.call("countDaily", { name: "ai-tokens", limit: limits.userTokensPerDay, amount: reserve, now });
  if (!tokens.ok) return tooMany("daily_ai_token_limit", tokens.retryAfter);

  const result = await converse(config, {
    system: [{ text: systemPrompt(parsed.context) }],
    messages: parsed.messages,
    inferenceConfig: { maxTokens: parsed.maxTokens, temperature: 0.3 },
    toolConfig: { tools: [REPLY_TOOL], toolChoice: { auto: {} } },
  }, { fetcher: ctx.env.FETCH ?? fetch, now });
  if (!result.ok) {
    if (result.status === 429) return tooMany(result.error, 30);
    return json({ error: result.error, ...(result.upstreamStatus ? { status: result.upstreamStatus } : {}) }, result.status);
  }
  const reply = readReply(result.output);
  const commands = reply.rawCommands.slice(0, limits.commands).map(shapeCommand).filter(Boolean);
  const trip = reply.rawTrip ? shapeTrip(reply.rawTrip, limits) : null;
  const dropped = Math.min(reply.rawCommands.length, limits.commands) - commands.length + (reply.rawTrip && !trip ? 1 : 0);
  return json({
    reply: reply.reply,
    commands,
    ...(trip ? { trip } : {}),
    dropped,
    redacted: parsed.redacted,
    truncated: reply.stopReason === "max_tokens",
    usage: reply.usage,
  }, 200);
}
