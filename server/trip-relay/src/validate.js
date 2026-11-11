// Body contracts the app reads (TRP1110A04, TRP1110A07, CLN1110A01).

export const QUEUE_LIMIT = 50;
const RETENTION_DAYS = new Set([1, 7, 30]);
const DATE = /^\d{4}-\d{2}-\d{2}$/;
const TIME = /^([01]\d|2[0-3]):[0-5]\d$/;
const DATETIME = /^\d{4}-\d{2}-\d{2}T([01]\d|2[0-3]):[0-5]\d(:[0-5]\d)?(Z|[+-]\d{2}:\d{2})$/;

const nonEmpty = (value, max) => typeof value === "string" && value.trim().length > 0 && value.length <= max;
// 지울 때 `?ids=a,b`로 넘기므로 id에는 쉼표를 쓰지 않는다. 결과의 id는 예전에 받은 명령도 있어 느슨하게 본다.
const itemID = (value) => nonEmpty(value, 100) && !value.includes(",");
// 새 명령의 id(N10): 영문·숫자·`_`·`.`·`:`·`-` 1~100자. 공백이 없다.
export const COMMAND_ID = /^[\w.:-]{1,100}$/;
const commandID = (value) => typeof value === "string" && COMMAND_ID.test(value);
const given = (value) => value !== undefined && value !== null;
const optional = (value, check) => !given(value) || check(value);
const targetID = (v) => nonEmpty(v, 100);
const title = (max) => (v) => nonEmpty(v, max);
const note = (v) => typeof v === "string" && v.length <= 1000;
export const isDate = (v) => typeof v === "string" && DATE.test(v) && !Number.isNaN(Date.parse(v + "T00:00:00Z"));
export const isTime = (v) => typeof v === "string" && TIME.test(v);
const isInstant = (v) => typeof v === "string" && DATETIME.test(v) && !Number.isNaN(Date.parse(v));
// 일정 수정은 ISO 시각(오프셋 포함) 또는 그날의 HH:mm을 받는다(CLN1110A01).
const isClock = (v) => isInstant(v) || isTime(v);

// Same contract the app reads: format "bokki-trip", version 1, a tripId and at least one item.
export function isTripPlan(value) {
  return value?.format === "bokki-trip" && value?.version === 1 && typeof value?.tripId === "string"
    && typeof value?.title === "string" && Array.isArray(value?.items) && value.items.length > 0
    && value.items.length <= 500;
}

// 하루들 외에 선택 칸 goals·trips·placeBook을 받는다(AIR1110A03). 서버는 내용을 해석하지 않고 그대로 잠가 둔다.
export const ACTIVITY_EXTRAS = ["goals", "trips", "placeBook"];
const extraOK = (name, value) => value === null || (name === "placeBook" ? typeof value === "object" : Array.isArray(value) && value.length <= 500);

// 다듬어 줄 메모(MEM1110A02). 앱이 통째로 올리고, AI는 읽어 다듬은 글을 updateMemo로 보낸다.
export const POLISH_LIMIT = 20;
export function isPolishList(value) {
  return value?.format === "bokki-polish" && value?.version === 1 && Array.isArray(value?.memos)
    && value.memos.length >= 1 && value.memos.length <= POLISH_LIMIT
    && new Set(value.memos.map((m) => m?.id)).size === value.memos.length
    && value.memos.every((m) => m && targetID(m.id) && typeof m.text === "string"
      && codePoints(m.text.trim()) >= 1 && codePoints(m.text) <= 1000 && (m.date === undefined || isDate(m.date)));
}

export function isActivityUpload(value) {
  return value?.format === "bokki-activity" && value?.version === 1 && RETENTION_DAYS.has(value?.retentionDays)
    && Array.isArray(value?.days) && value.days.length >= 1 && value.days.length <= 7
    && value.days.every((day) => day && typeof day === "object" && isDate(day.date))
    && ACTIVITY_EXTRAS.every((name) => value[name] === undefined || extraOK(name, value[name]));
}

// 기록·계획을 고르는 방법: id 또는 (날짜와 시작 시각).
const recordTarget = (v) => isDate(v.date) && optional(v.recordId, targetID) && optional(v.startTime, isTime)
  && (given(v.recordId) || given(v.startTime));
const planTarget = (v) => (given(v.planId) && targetID(v.planId) && optional(v.date, isDate) && optional(v.startTime, isTime))
  || (!given(v.planId) && isDate(v.date) && isTime(v.startTime));
const distinctIDs = (ids, min, max) => Array.isArray(ids) && ids.length >= min && ids.length <= max
  && ids.every(targetID) && new Set(ids).size === ids.length;

// 앱에서만 바꿀 수 있는 위험한 것(전체 삭제·백업·키·PIN·권한·공유 수준·보관 기간·결제)은 동작이 없다(AIR1110A03).
// 설정은 안전한 것만: 언어·테마·지도 모양·표시 켜고 끄기. 값은 앱의 저장값 그대로다.
export const LANGUAGES = ["automatic", "korean", "english", "ja", "zh-Hans", "zh-Hant", "de", "fr", "it", "es", "pt-BR", "vi", "id", "th", "hi"];
export const THEMES = ["classic", "navy", "purple", "brown", "ink"];
export const MAP_STYLES = ["standard", "hybrid", "mapLibreNight", "mapLibreContrast", "mapLibreCasual", "mapLibreRPG", "mapLibreInk", "mapLibrePorcelain"];
export const DISPLAY_OPTIONS = ["mapPhotos", "mapRoutes", "mapFootprints"];
export const TRIP_STATUSES = ["booked", "planned", "tentative"];

const oneOf = (list) => (v) => list.includes(v);
const int = (min, max) => (v) => Number.isInteger(v) && v >= min && v <= max;
const notBefore = (start, end) => !(isDate(start) && isDate(end) && end < start);
const between = (min, max) => (v) => typeof v === "number" && Number.isFinite(v) && v >= min && v <= max;
// 좌표는 latitude/longitude 또는 lat/lng, 둘이 함께(앱 규격 AIR1110A03).
// 보낸 칸은 모두 본다(N10): latitude와 lat을 함께 보내면 둘 다 맞아야 한다.
const pair = (lat, lng) => (!given(lat) && !given(lng)) || (between(-90, 90)(lat) && between(-180, 180)(lng));
const coordinates = (v) => pair(v.latitude, v.longitude) && pair(v.lat, v.lng);
const goalTarget = (v) => optional(v.goalId, targetID) && optional(v.planId, targetID) && (given(v.goalId) || given(v.planId));

// MARK: 말풍선 (BUB1110A01, REV1110A06 N7)
// 기록을 바꾸지 않고 그 시각에 화랑이 말풍선으로만 보인다. 허용하는 것만 받는 문법 하나를 앱과 같이 쓴다
// (docs/ACTIVITY_RELAY_API.md 4.2). 글자 수는 유니코드 코드 포인트로 센다.
export const BUBBLE_LIMITS = { visible: 80, total: 300, links: 3, label: 20 };
// 보이지 않는 글자: 제어(Cc)·서식(Cf, 방향 바꿈·폭 없는 글자)·줄/문단 구분(Zl·Zp).
const INVISIBLE = /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/gu;
export const stripInvisible = (text) => text.replace(INVISIBLE, "");
const URL_CHARS = "[A-Za-z0-9\\-._~:/?#@!$&*+,;=%]";
// 링크 둘: [이름](https://…) 또는 맨 https://… (scheme은 대소문자 무관). 왼쪽부터 찾는다.
const LINK = new RegExp(`\\[([^\\[\\]<>\\\\]*)\\]\\((https://${URL_CHARS}+)\\)|(?<![A-Za-z0-9+.\\-])(https://${URL_CHARS}+)`, "gi");
const TRAILING = /[.,;:!?]+$/;
const HOST = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\.[a-z]{2,}$/;
// 링크 밖에 남은 `글자들:` + 공백 아닌 글자는 다른 scheme으로 본다(tel:1, http://, taptionplan:x, 못 읽은 https:).
const SCHEME = /(?<![A-Za-z0-9+.\-])[A-Za-z][A-Za-z0-9+.\-]*:(?=\S)/;
const FORBIDDEN = /[\[\]<>\\]/;
// 이름이 주소처럼 보이면 안 된다: `://`, `www.`, 글자·숫자 + 점 + 영문 2자 이상(apple.com).
const LABEL_LOOKS_LIKE_URL = /:\/\/|www[.．。｡]|[\p{L}\p{N}][.．。｡][A-Za-z]{2,}/iu;
const codePoints = (text) => [...text].length;

// https 주소 하나를 확인하고 정규화한 href를 준다. 틀리면 null.
// 호스트는 ASCII 도메인만(퓨니코드 xn--·IP·userinfo(@) 없음), 포트는 숫자, %는 16진수 두 자리와 함께.
export function bubbleUrl(text) {
  const rest = text.slice("https://".length);
  const authority = rest.split(/[/?#]/, 1)[0].toLowerCase();
  const [host, port, ...extra] = authority.split(":");
  if (extra.length || (port !== undefined && !/^\d{1,5}$/.test(port))) return null;
  if (!HOST.test(host) || host.length > 253 || host.split(".").some((label) => label.startsWith("xn--") || label.length > 63)) return null;
  if (/%(?![0-9A-Fa-f]{2})/.test(rest)) return null;
  let url;
  try { url = new URL("https://" + rest); } catch { return null; }
  return url.protocol === "https:" && url.hostname === host && !url.username && !url.password ? url.href : null;
}

const labelOK = (label) => label.trim().length > 0 && codePoints(label) <= BUBBLE_LIMITS.label && !LABEL_LOOKS_LIKE_URL.test(label);

// { text: 다듬고 주소를 정규화한 글 } 또는 { reason }.
export function bubbleText(value) {
  if (typeof value !== "string") return { reason: "text_required" };
  const text = stripInvisible(value).trim();
  if (!text) return { reason: "text_required" };
  if (text.includes("\\")) return { reason: "bad_character" };
  let links = 0;
  let out = "";
  let visible = "";
  let last = 0;
  const plain = (chunk) => { out += chunk; visible += chunk; };
  for (const match of text.matchAll(LINK)) {
    const [whole, label, linked, bare] = match;
    plain(text.slice(last, match.index));
    if (linked) {
      const href = bubbleUrl(linked);
      if (!href) return { reason: "bad_url" };
      if (!labelOK(label)) return { reason: "bad_link_label" };
      out += `[${label}](${href})`;
      visible += label;
      last = match.index + whole.length;
    } else {
      const trimmed = bare.replace(TRAILING, "");
      const href = bubbleUrl(trimmed);
      if (!href) return { reason: "bad_url" };
      out += href;
      last = match.index + trimmed.length;
    }
    links++;
  }
  plain(text.slice(last));
  // 남은 글(이름 포함)에 다른 scheme이나 링크 기호가 있으면 거절한다.
  if (SCHEME.test(visible)) return { reason: /(?<![A-Za-z0-9+.\-])https:/i.test(visible) ? "bad_url" : "url_scheme_not_allowed" };
  if (FORBIDDEN.test(visible)) return { reason: "bad_character" };
  if (links > BUBBLE_LIMITS.links) return { reason: "too_many_links" };
  const count = codePoints(visible.trim());
  if (count < 1) return { reason: "text_required" };
  if (count > BUBBLE_LIMITS.visible || codePoints(out) > BUBBLE_LIMITS.total) return { reason: "text_too_long" };
  return { text: out };
}

// 동작마다 받는 칸. 다른 칸은 큐에 넣기 전에 버린다(finding 14).
export const COMMAND_FIELDS = {
  addMemo: ["text", "date", "time"],
  addSchedule: ["title", "start", "end", "note"],
  updateActivity: ["date", "recordId", "startTime", "title", "categoryId"],
  hideRecord: ["date", "recordId", "startTime"],
  mergeRecords: ["date", "recordIds", "title", "categoryId"],
  updateRecordTime: ["date", "recordId", "start", "end"],
  updateSchedule: ["planId", "date", "startTime", "title", "start", "end", "note"],
  deleteSchedule: ["planId", "date", "startTime"],
  updateMemo: ["memoId", "text"],
  deleteMemo: ["memoId"],
  addGoal: ["title", "start", "end", "categoryId"],
  updateGoal: ["goalId", "planId", "title", "start", "end", "categoryId"],
  deleteGoal: ["goalId", "planId"],
  addTripStop: ["tripId", "title", "date", "latitude", "longitude", "lat", "lng", "status"],
  updateTripStop: ["stopId", "title", "date", "order", "status"],
  deleteTripStop: ["stopId"],
  setTripItemStatus: ["tripId", "itemId", "status"],
  updateSleep: ["recordId", "start", "end"],
  // ACT1111A01: 앱이 분류하지 못한 시간(하루 기록의 unconfirmed)을 분류로 채우기, 이동 구간(moves의 id)의 수단 고치기.
  classifyUnconfirmed: ["date", "start", "end", "title", "categoryId"],
  setTravelMode: ["date", "moveId", "mode"],
  setBubble: ["date", "start", "end", "text", "kind"],
  // LED1110A01: 가계부 지출·수입. amount는 그 통화의 금액(양수), kind는 expense 기본 | income.
  addExpense: ["amount", "currency", "title", "category", "date", "time", "kind", "payer"],
  // AIQ1111A01: 앱이 넣은 가계부 기록 고치기·지우기. 고칠 칸이 하나 이상이거나 delete.
  updateExpense: ["entryId", "amount", "currency", "title", "category", "kind", "delete"],
  // PRL1112A01: 앱이 읽지 못한 결제 문자 형식을 읽는 규칙. pattern은 ICU 정규식, 앱이 sample로 다시 확인한다.
  addPaymentRule: ["name", "pattern", "sample", "kind"],
  setLanguage: ["language"],
  setTheme: ["theme"],
  setMapStyle: ["mapStyle"],
  setDisplayOption: ["option", "enabled"],
};
export const ACTIONS = Object.keys(COMMAND_FIELDS);
export const TRAVEL_MODES = ["walk", "subway", "bus", "car", "train", "flight"];
export const PAYMENT_RULE_KINDS = ["expense", "income", "ignore"];
export const EXPENSE_CATEGORIES = ["food", "cafe", "transport", "shopping", "living", "health", "culture", "travel", "lodging", "education", "gift", "salary", "other"];

// 알려진 칸만 남긴 명령. 동작을 모르면 null.
export function cleanCommand(value) {
  const fields = COMMAND_FIELDS[value?.action];
  if (!fields) return null;
  const out = { format: value.format, version: value.version, id: value.id, action: value.action };
  for (const name of fields) if (value[name] !== undefined) out[name] = value[name];
  if (out.action === "setBubble") out.text = bubbleText(out.text).text;
  return out;
}

// 거절 이유(422 본문의 reason). 지금은 말풍선만 자세히 알려 준다.
export function commandReason(value) {
  if (!commandID(value?.id)) return "bad_id";
  if (value?.action !== "setBubble") return undefined;
  if (!isDate(value.date) || !isTime(value.start) || !isTime(value.end)) return "bad_time";
  if (value.end <= value.start) return "end_before_start";
  return bubbleText(value.text).reason;
}

// 동작마다 필요한 칸을 본다(TRP1110A07). 새 동작은 모두 사용자 교정으로 반영되고 원본은 지우지 않는다(CLN1110A01).
export function isCommand(value) {
  if (value?.format !== "bokki-command" || value?.version !== 1 || !commandID(value?.id)) return false;
  const v = value;
  switch (v.action) {
    case "addMemo":
      return nonEmpty(v.text, 1000) && optional(v.date, isDate) && optional(v.time, isTime);
    case "addExpense":
      return typeof v.amount === "number" && Number.isFinite(v.amount) && v.amount > 0 && v.amount <= 1e10
        && optional(v.currency, (c) => /^[A-Z]{3}$/.test(c)) && nonEmpty(v.title, 60)
        && optional(v.category, (c) => EXPENSE_CATEGORIES.includes(c)) && optional(v.kind, (k) => k === "expense" || k === "income")
        && optional(v.payer, (p) => nonEmpty(p, 30)) && optional(v.date, isDate) && optional(v.time, isTime);
    case "updateExpense":
      return targetID(v.entryId) && optional(v.amount, (a) => typeof a === "number" && Number.isFinite(a) && a > 0 && a <= 1e10)
        && optional(v.currency, (c) => /^[A-Z]{3}$/.test(c)) && optional(v.title, (t) => nonEmpty(t, 60))
        && optional(v.category, (c) => EXPENSE_CATEGORIES.includes(c)) && optional(v.kind, (k) => k === "expense" || k === "income")
        && optional(v.delete, (d) => d === true)
        && (v.delete === true || ["amount", "currency", "title", "category", "kind"].some((k) => given(v[k])));
    case "addSchedule":
      return nonEmpty(v.title, 200) && isInstant(v.start)
        && optional(v.end, (e) => isInstant(e) && Date.parse(e) > Date.parse(v.start)) && optional(v.note, note);
    case "updateActivity":
      return recordTarget(v) && optional(v.title, title(100)) && optional(v.categoryId, targetID)
        && (given(v.title) || given(v.categoryId));
    case "hideRecord":
      return recordTarget(v);
    case "mergeRecords":
      return isDate(v.date) && distinctIDs(v.recordIds, 2, 20) && optional(v.title, title(100)) && optional(v.categoryId, targetID);
    case "updateRecordTime":
      return isDate(v.date) && targetID(v.recordId) && optional(v.start, isTime) && optional(v.end, isTime)
        && (given(v.start) || given(v.end)) && !(given(v.start) && v.start === v.end);
    case "updateSchedule":
      return planTarget(v) && optional(v.title, title(200)) && optional(v.start, isClock) && optional(v.end, isClock)
        && optional(v.note, note) && [v.title, v.start, v.end, v.note].some(given)
        && !(isInstant(v.start) && isInstant(v.end) && Date.parse(v.end) <= Date.parse(v.start));
    case "deleteSchedule":
      return planTarget(v);
    case "updateMemo":
      return targetID(v.memoId) && nonEmpty(v.text, 1000);
    case "deleteMemo":
      return targetID(v.memoId);
    // 목표 = 상위 계획(AIR1110A03). 날짜는 YYYY-MM-DD, end는 선택.
    case "addGoal":
      return nonEmpty(v.title, 200) && isDate(v.start) && optional(v.end, isDate) && notBefore(v.start, v.end)
        && optional(v.categoryId, targetID);
    case "updateGoal":
      return goalTarget(v) && optional(v.title, title(200)) && optional(v.start, isDate) && optional(v.end, isDate)
        && optional(v.categoryId, targetID) && [v.title, v.start, v.end, v.categoryId].some(given) && notBefore(v.start, v.end);
    case "deleteGoal":
      return goalTarget(v);
    // 여행 일정(장소 도감의 여행 칸). date는 그날, order는 그날 안의 순서 0부터.
    case "addTripStop":
      return nonEmpty(v.title, 200) && isDate(v.date) && optional(v.tripId, targetID) && coordinates(v)
        && optional(v.status, oneOf(TRIP_STATUSES));
    case "updateTripStop":
      return targetID(v.stopId) && optional(v.title, title(200)) && optional(v.date, isDate) && optional(v.order, int(0, 999))
        && optional(v.status, oneOf(TRIP_STATUSES)) && [v.title, v.date, v.order, v.status].some(given);
    case "deleteTripStop":
      return targetID(v.stopId);
    case "setTripItemStatus":
      return targetID(v.tripId) && targetID(v.itemId) && oneOf(TRIP_STATUSES)(v.status);
    // 수면 기록의 시작·끝 교정(ISO 오프셋 포함 또는 HH:mm).
    case "updateSleep":
      return targetID(v.recordId) && optional(v.start, isClock) && optional(v.end, isClock) && (given(v.start) || given(v.end))
        && !(given(v.start) && v.start === v.end) && !(isInstant(v.start) && isInstant(v.end) && Date.parse(v.end) <= Date.parse(v.start));
    case "classifyUnconfirmed":
      return isDate(v.date) && isTime(v.start) && isTime(v.end) && v.end > v.start && targetID(v.categoryId)
        && optional(v.title, title(100));
    case "setTravelMode":
      return isDate(v.date) && targetID(v.moveId) && oneOf(TRAVEL_MODES)(v.mode);
    // 같은 날 start < end(HH:mm).
    case "setBubble": {
      // BUB1110A02: kind "routine"(기본, 시간대 필수) | "event"(그날 하루 내내 맨 앞, 날이 지나면 앱이 지움, 시간대는 없어도 됨).
      const kind = v.kind ?? "routine";
      if (kind !== "routine" && kind !== "event") return false;
      const window = given(v.start) || given(v.end)
        ? isTime(v.start) && isTime(v.end) && v.end > v.start
        : kind === "event";
      return isDate(v.date) && window && !!bubbleText(v.text).text;
    }
    // 서버는 모양·길이만 본다. ignore가 아니면 금액 그룹이 있어야 한다. 정규식이 sample에 맞는지는 앱이 확인한다.
    case "addPaymentRule":
      return nonEmpty(v.name, 40) && nonEmpty(v.pattern, 300) && nonEmpty(v.sample, 1000)
        && optional(v.kind, oneOf(PAYMENT_RULE_KINDS)) && (v.kind === "ignore" || v.pattern.includes("(?<amount>"));
    case "setLanguage":
      return oneOf(LANGUAGES)(v.language);
    case "setTheme":
      return oneOf(THEMES)(v.theme);
    case "setMapStyle":
      return oneOf(MAP_STYLES)(v.mapStyle);
    case "setDisplayOption":
      return oneOf(DISPLAY_OPTIONS)(v.option) && typeof v.enabled === "boolean";
    default:
      return false;
  }
}

export function isCommandResults(value) {
  return Array.isArray(value?.results) && value.results.length >= 1 && value.results.length <= QUEUE_LIMIT
    && value.results.every((r) => itemID(r?.id) && (r.status === "applied" || r.status === "rejected")
      && optional(r.reason, (v) => typeof v === "string" && v.length <= 300));
}

// AI 확인 목록(AIQ1111A01). 앱이 처리하지 못했거나 불분명한 것을 올리고, AI가 가져가 처리한 뒤 완료·실패를 남긴다.
export const TASK_KINDS = ["payment_text", "receipt_text", "payment_rule", "memo_polish", "route_check", "fare_check", "merge_review", "stay_place", "other"];
export const TASK_STATUSES = ["waiting", "processing", "done", "failed"];
export const TASK_LIMIT = 100;
const contextOK = (v) => !given(v) || (typeof v === "object" && !Array.isArray(v) && JSON.stringify(v).length <= 2000);
export function isTaskUpload(value) {
  return value?.format === "bokki-tasks" && value?.version === 1 && Array.isArray(value?.tasks)
    && value.tasks.length >= 1 && value.tasks.length <= 20
    && new Set(value.tasks.map((t) => t?.id)).size === value.tasks.length
    && value.tasks.every((t) => t && targetID(t.id) && TASK_KINDS.includes(t.kind) && typeof t.text === "string"
      && codePoints(t.text.trim()) >= 1 && codePoints(t.text) <= 2000 && optional(t.date, isDate) && contextOK(t.context));
}
export function isTaskResult(value) {
  return targetID(value?.id) && ["done", "failed"].includes(value?.status)
    && optional(value.result, (v) => typeof v === "string" && codePoints(v) <= 300)
    && optional(value.reason, (v) => typeof v === "string" && codePoints(v) <= 200);
}
