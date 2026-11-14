// Body contracts the app reads (TRP1110A04, TRP1110A07, CLN1110A01).

import { registry } from "./actions.js";
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
// 가계부 몫을 나누는 사람 이름(ACT1114A07): 1~30자, 20명까지, 서로 다름.
const shareNames = (min) => (v) => Array.isArray(v) && v.length >= min && v.length <= 20 && v.every((n) => nonEmpty(n, 30))
  && new Set(v.map((n) => n.trim())).size === v.length;
const EXPENSE_CHANGES = ["amount", "currency", "title", "category", "kind", "tripId", "shareNames", "note", "date", "time"];
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
  // ACT1114A07: categoryId(분류)·important(중요)·parentGoalId(루틴 아래에 두기).
  addSchedule: ["title", "start", "end", "note", "categoryId", "important", "parentGoalId"],
  updateActivity: ["date", "recordId", "startTime", "title", "categoryId"],
  hideRecord: ["date", "recordId", "startTime"],
  mergeRecords: ["date", "recordIds", "title", "categoryId"],
  updateRecordTime: ["date", "recordId", "start", "end"],
  updateSchedule: ["planId", "date", "startTime", "title", "start", "end", "note", "categoryId", "important", "parentGoalId"],
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
  setTravelMode: ["date", "moveId", "mode", "line"],
  setBubble: ["date", "start", "end", "text", "kind"],
  // LED1110A01: 가계부 지출·수입. amount는 그 통화의 금액(양수), kind는 expense 기본 | income.
  // ACT1114A07: tripId(여행 가계부)·shareNames(몫을 나누는 사람, "@me"는 나)·note. 옛 앱은 모르는 칸을 그냥 넘긴다.
  addExpense: ["amount", "currency", "title", "category", "date", "time", "kind", "payer", "tripId", "shareNames", "note"],
  // AIQ1111A01: 앱이 넣은 가계부 기록 고치기·지우기. 고칠 칸이 하나 이상이거나 delete.
  updateExpense: ["entryId", "amount", "currency", "title", "category", "kind", "delete", "tripId", "shareNames", "note", "date", "time"],
  // PRL1112A01: 앱이 읽지 못한 결제 문자 형식을 읽는 규칙. pattern은 ICU 정규식, 앱이 sample로 다시 확인한다.
  addPaymentRule: ["name", "pattern", "sample", "kind"],
  // ACX1112A01: 가계부 설정(이 달 예산·내 계좌 이름), 규칙·확인 필요·받은 문자 정리, 화면 열기.
  setBudget: ["amountKRW", "month"],
  addOwnAccount: ["name"],
  removeOwnAccount: ["name"],
  deletePaymentRule: ["ruleId"],
  resolveReview: ["reviewId", "decision"],
  deleteInboxItem: ["inboxId"],
  openScreen: ["screen"],
  // ASK1112A01: 앱에서 사용자에게 객관식으로 묻는다. 답은 앱이 `/answers`에 올린다.
  askUser: ["question", "options", "multiSelect"],
  // ACA1112A01: 자주 가는 장소와 분류. 좌표는 받기만 하고 내보내지 않는다.
  addPlace: ["name", "latitude", "longitude", "radius", "autoRecord"],
  updatePlace: ["placeId", "name", "latitude", "longitude", "radius", "autoRecord"],
  deletePlace: ["placeId"],
  addCategory: ["name", "color", "icon"],
  updateCategory: ["categoryId", "name", "color", "icon", "hidden"],
  // ACB1112A01: 여행 만들기·고치기·지우기와 급여·통행료 차종 설정.
  addTrip: ["title", "start", "end", "wishDays", "countryCode", "regionName", "currency"],
  updateTrip: ["tripId", "title", "start", "end"],
  deleteTrip: ["tripId"],
  setSetting: ["setting", "value"],
  // ACD1112A01: 위험한 일은 앱에서 사용자가 승인해야 한다. AI는 요청만 보낸다.
  requestApproval: ["request", "value"],
  // HND1112A01: 앱의 「확인할 것」을 AI가 끝낸다 — 자주 머무는 곳 제안, 내 차 등록, 일정 제목 분류.
  resolvePlaceSuggestion: ["decision", "name", "kind"],
  setCarAudio: ["name", "isMyCar"],
  setCalendarTitleDetail: ["title", "detailId"],
  // TBG1112A01: 여행 예산(원). 0이면 예산 없이 쓰고 끝난 뒤 정산한다.
  setTripBudget: ["tripId", "budgetKRW"],
  setLanguage: ["language"],
  setTheme: ["theme"],
  setMapStyle: ["mapStyle"],
  setDisplayOption: ["option", "enabled"],
};
// 등록부(actions.js)의 동작을 더한다(AIX1114A01).
for (const name of registry.names()) {
  if (name in COMMAND_FIELDS) throw new Error("action defined twice: " + name);
  COMMAND_FIELDS[name] = registry.fields(name);
}
export const ACTIONS = Object.keys(COMMAND_FIELDS);
export const TRAVEL_MODES = ["walk", "subway", "bus", "car", "train", "flight"];
export const PAYMENT_RULE_KINDS = ["expense", "income", "ignore"];
// ACX1112A01
export const SCREENS = ["paymentAutomation", "shortcuts", "aiConnection", "ledger", "dataProtection", "settings",
  // ACC1112A01
  "salary", "carAudio", "alarm", "placeBook", "passport", "unconfirmedReview", "travel"];
export const REVIEW_DECISIONS = ["add", "discard"];
export const BUDGET_MAX_KRW = 1e12;
const UUID = /^[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$/;
const uuid = (v) => typeof v === "string" && UUID.test(v);
const MONTH = /^\d{4}-(0[1-9]|1[0-2])$/;
const isMonth = (v) => typeof v === "string" && MONTH.test(v);
// 내 계좌 이름: 다듬어 2~30자이고 번호처럼 보이는 숫자 덩어리가 없어야 한다(앱 규칙과 같다).
const accountName = (v) => nonEmpty(v, 30) && v.trim().length >= 2 && !/\d[\d -]{7,}\d/.test(v);
export const EXPENSE_CATEGORIES = ["food", "cafe", "transport", "shopping", "living", "health", "culture", "travel", "lodging", "education", "gift", "salary", "other"];

// ASK1112A01: 질문 1~200자, 보기 2~4개(1~60자, 서로 다름). 앱이 「직접 입력」을 늘 덧붙인다.
export const QUESTION_LIMITS = { question: 200, option: 60, minOptions: 2, maxOptions: 4, text: 200, answers: 20 };
const lengthIn = (v, max) => typeof v === "string" && codePoints(v.trim()) >= 1 && codePoints(v) <= max;
const questionText = (v) => lengthIn(v, QUESTION_LIMITS.question);
const answerOptions = (v) => Array.isArray(v) && v.length >= QUESTION_LIMITS.minOptions && v.length <= QUESTION_LIMITS.maxOptions
  && v.every((o) => lengthIn(o, QUESTION_LIMITS.option)) && new Set(v.map((o) => o.trim())).size === v.length;

// 앱이 올리는 질문과 답 목록. 통째로 바꿔 쓴다. status: waiting(아직 답 없음) | answered | skipped.
export const ANSWER_STATUSES = ["waiting", "answered", "skipped"];
const isoInstant = (v) => typeof v === "string" && v.length <= 40 && !Number.isNaN(Date.parse(v));
export function isAnswerList(value) {
  return value?.format === "bokki-answers" && value?.version === 1 && Array.isArray(value?.answers)
    && value.answers.length >= 1 && value.answers.length <= QUESTION_LIMITS.answers
    && new Set(value.answers.map((a) => a?.id)).size === value.answers.length
    && value.answers.every((a) => a && commandID(a.id) && questionText(a.question) && ANSWER_STATUSES.includes(a.status)
      && optional(a.choices, (c) => Array.isArray(c) && c.length <= QUESTION_LIMITS.maxOptions && c.every((o) => lengthIn(o, QUESTION_LIMITS.option)))
      && optional(a.text, (t) => lengthIn(t, QUESTION_LIMITS.text)) && optional(a.askedAt, isoInstant) && optional(a.answeredAt, isoInstant)
      && (a.status !== "answered" || (a.choices?.length ?? 0) > 0 || given(a.text)));
}
export const cleanAnswers = (value) => value.answers.map(({ id, question, status, choices, text, askedAt, answeredAt }) => ({
  id, question, status, ...(status === "answered" && choices?.length ? { choices } : {}), ...(status === "answered" && given(text) ? { text } : {}),
  ...(given(askedAt) ? { askedAt } : {}), ...(given(answeredAt) ? { answeredAt } : {}),
}));

// ACA1112A01: 장소 이름 1~40자·반경 30~500m, 분류 이름 1~20자·색 #RRGGBB·아이콘은 앱의 CategoryIcon 이름.
export const PLACE_LIMITS = { name: 40, category: 20, minRadius: 30, maxRadius: 500, places: 100, categories: 100 };
export const PLACE_KINDS = ["home", "school", "academy", "company", "hobby", "exercise", "restaurant", "custom"];
export const CATEGORY_ICONS = ["briefcase", "building", "book", "graduation", "target", "award", "stroller", "family", "shield", "health", "exercise",
  "sleep", "performance", "music", "travel", "location", "photo", "home", "meal", "cafe", "pet", "shopping", "nature", "calendar", "event", "memo",
  "movement", "activity", "relationship", "work", "community", "student", "exam", "military", "athlete", "pregnancy", "caregiver", "government", "food"];
const isBoolean = (v) => typeof v === "boolean";
const placeRadius = (v) => typeof v === "number" && Number.isFinite(v) && v >= PLACE_LIMITS.minRadius && v <= PLACE_LIMITS.maxRadius;
const hexColor = (v) => typeof v === "string" && /^#[0-9A-Fa-f]{6}$/.test(v);

// ACB1112A01: 여행 이름 1~60자, 날짜 없는 여행은 1~60일. 설정은 이 표의 이름만 받는다(값의 형과 범위).
export const TRIP_LIMITS = { title: 60, region: 40, wishDays: 60, trips: 100 };
const amountUpTo = (max) => (v) => typeof v === "number" && Number.isFinite(v) && v >= 0 && v <= max;
export const TOLL_VEHICLES = ["standard", "compact", "electric"];
export const SALARY_MODES = ["salary", "hourly"];
export const HOURLY_TAXES = ["threePointThree", "fourInsurance", "none"];
export const CATS = ["white", "calico", "mackerel"];
export const SETTINGS = {
  tollVehicle: oneOf(TOLL_VEHICLES),
  salaryMode: oneOf(SALARY_MODES),
  annualPay: amountUpTo(1e11),
  monthlyPay: amountUpTo(1e10),
  payIsNet: isBoolean,
  showsNetPay: isBoolean,
  hourlyPay: amountUpTo(1e7),
  hourlyPayIsNet: isBoolean,
  hourlyTax: oneOf(HOURLY_TAXES),
  weeklyHolidayPay: isBoolean,
  // ACC1112A01: 앱 자료 쪽 설정. 알림은 끄기만(켜기는 iOS 권한 창이 필요해 사용자가 한다).
  reduceMotion: isBoolean,
  weather: isBoolean,
  weatherSidebar: isBoolean,
  gpsIntervalSeconds: (v) => Number.isInteger(v) && v >= 30 && v <= 1800 && v % 30 === 0,
  cat: oneOf(CATS),
  notifications: (v) => v === false,
};
export const SETTING_NAMES = Object.keys(SETTINGS);
// ACD1112A01: 승인 요청 종류. 값이 있는 것은 그 값만, 없는 것은 값을 받지 않는다.
const noValue = (v) => !given(v);
export const APPROVALS = {
  shareLevel: oneOf(["off", "summary", "visits"]),
  retentionDays: (v) => RETENTION_DAYS.has(v),
  healthOff: noValue,
  eraseAllData: noValue,
  backup: noValue,
  restore: noValue,
  changePin: noValue,
};
export const APPROVAL_NAMES = Object.keys(APPROVALS);

// 알려진 칸만 남긴 명령. 동작을 모르면 null.
export function cleanCommand(value) {
  const fields = COMMAND_FIELDS[value?.action];
  if (!fields) return null;
  const out = { format: value.format, version: value.version, id: value.id, action: value.action };
  for (const name of fields) if (value[name] !== undefined) out[name] = value[name];
  // 어느 AI 일 때문에 보낸 명령인지(AIX1114A01 P2). 모양이 맞을 때만 남긴다.
  if (commandID(value.taskId)) out.taskId = value.taskId;
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
        && optional(v.payer, (p) => nonEmpty(p, 30)) && optional(v.date, isDate) && optional(v.time, isTime)
        && optional(v.tripId, targetID) && optional(v.shareNames, shareNames(1)) && optional(v.note, (n) => nonEmpty(n, 200));
    case "updateExpense":
      return targetID(v.entryId) && optional(v.amount, (a) => typeof a === "number" && Number.isFinite(a) && a > 0 && a <= 1e10)
        && optional(v.currency, (c) => /^[A-Z]{3}$/.test(c)) && optional(v.title, (t) => nonEmpty(t, 60))
        && optional(v.category, (c) => EXPENSE_CATEGORIES.includes(c)) && optional(v.kind, (k) => k === "expense" || k === "income")
        && optional(v.delete, (d) => d === true)
        // tripId "none"은 일상 가계부로 돌리고, shareNames []는 「다 같이」로 돌린다.
        && optional(v.tripId, targetID) && optional(v.shareNames, shareNames(0)) && optional(v.note, (n) => nonEmpty(n, 200))
        && optional(v.date, isDate) && optional(v.time, isTime)
        && (v.delete === true || EXPENSE_CHANGES.some((k) => given(v[k])));
    case "addSchedule":
      return nonEmpty(v.title, 200) && isInstant(v.start)
        && optional(v.end, (e) => isInstant(e) && Date.parse(e) > Date.parse(v.start)) && optional(v.note, note)
        && optional(v.categoryId, targetID) && optional(v.important, isBoolean) && optional(v.parentGoalId, uuid);
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
        && optional(v.note, note) && [v.title, v.start, v.end, v.note, v.categoryId, v.important, v.parentGoalId].some(given)
        // parentGoalId "none"은 루틴에서 떼어 낸다.
        && optional(v.categoryId, targetID) && optional(v.important, isBoolean) && optional(v.parentGoalId, (p) => p === "none" || uuid(p))
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
      return isDate(v.date) && targetID(v.moveId) && oneOf(TRAVEL_MODES)(v.mode) && optional(v.line, title(20));
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
    // ACX1112A01. amountKRW 0은 그 달 예산을 없앤다. month가 없으면 앱의 이번 달.
    case "setBudget":
      return typeof v.amountKRW === "number" && Number.isFinite(v.amountKRW) && v.amountKRW >= 0 && v.amountKRW <= BUDGET_MAX_KRW
        && optional(v.month, isMonth);
    case "addOwnAccount":
    case "removeOwnAccount":
      return accountName(v.name);
    case "deletePaymentRule":
      return uuid(v.ruleId);
    case "resolveReview":
      return uuid(v.reviewId) && oneOf(REVIEW_DECISIONS)(v.decision);
    case "deleteInboxItem":
      return uuid(v.inboxId);
    case "openScreen":
      return oneOf(SCREENS)(v.screen);
    case "addPlace":
      return lengthIn(v.name, PLACE_LIMITS.name) && pair(v.latitude, v.longitude) && optional(v.radius, placeRadius) && optional(v.autoRecord, isBoolean);
    case "updatePlace":
      return uuid(v.placeId) && optional(v.name, (n) => lengthIn(n, PLACE_LIMITS.name)) && pair(v.latitude, v.longitude)
        && optional(v.radius, placeRadius) && optional(v.autoRecord, isBoolean)
        && [v.name, v.latitude, v.radius, v.autoRecord].some(given);
    case "deletePlace":
      return uuid(v.placeId);
    case "addCategory":
      return lengthIn(v.name, PLACE_LIMITS.category) && hexColor(v.color) && optional(v.icon, oneOf(CATEGORY_ICONS));
    case "updateCategory":
      return targetID(v.categoryId) && optional(v.name, (n) => lengthIn(n, PLACE_LIMITS.category)) && optional(v.color, hexColor)
        && optional(v.icon, oneOf(CATEGORY_ICONS)) && optional(v.hidden, isBoolean) && [v.name, v.color, v.icon, v.hidden].some(given);
    case "addTrip":
      return lengthIn(v.title, TRIP_LIMITS.title) && optional(v.countryCode, (c) => typeof c === "string" && /^[A-Z]{2}$/.test(c))
        && optional(v.regionName, (r) => lengthIn(r, TRIP_LIMITS.region)) && optional(v.currency, (c) => typeof c === "string" && /^[A-Z]{3}$/.test(c))
        && (given(v.wishDays)
          ? Number.isInteger(v.wishDays) && v.wishDays >= 1 && v.wishDays <= TRIP_LIMITS.wishDays && !given(v.start) && !given(v.end)
          : isDate(v.start) && optional(v.end, isDate) && notBefore(v.start, v.end));
    case "updateTrip":
      return targetID(v.tripId) && optional(v.title, (t) => lengthIn(t, TRIP_LIMITS.title)) && optional(v.start, isDate) && optional(v.end, isDate)
        && notBefore(v.start, v.end) && [v.title, v.start, v.end].some(given);
    case "deleteTrip":
      return targetID(v.tripId);
    case "setSetting":
      return Object.hasOwn(SETTINGS, v.setting) && SETTINGS[v.setting](v.value);
    case "resolvePlaceSuggestion":
      return oneOf(["register", "dismiss"])(v.decision) && optional(v.name, (n) => lengthIn(n, PLACE_LIMITS.name)) && optional(v.kind, oneOf(PLACE_KINDS))
        && (v.decision === "register" || (!given(v.name) && !given(v.kind)));
    case "setTripBudget":
      return targetID(v.tripId) && typeof v.budgetKRW === "number" && Number.isFinite(v.budgetKRW) && v.budgetKRW >= 0 && v.budgetKRW <= BUDGET_MAX_KRW;
    case "setCarAudio":
      return lengthIn(v.name, 60) && isBoolean(v.isMyCar);
    case "setCalendarTitleDetail":
      return lengthIn(v.title, 200) && typeof v.detailId === "string" && /^(none|[a-z][A-Za-z]{0,29}\.[A-Za-z][A-Za-z0-9.]{0,39})$/.test(v.detailId);
    case "requestApproval":
      return Object.hasOwn(APPROVALS, v.request) && APPROVALS[v.request](v.value);
    case "askUser":
      return questionText(v.question) && answerOptions(v.options) && optional(v.multiSelect, (b) => typeof b === "boolean");
    case "setLanguage":
      return oneOf(LANGUAGES)(v.language);
    case "setTheme":
      return oneOf(THEMES)(v.theme);
    case "setMapStyle":
      return oneOf(MAP_STYLES)(v.mapStyle);
    case "setDisplayOption":
      return oneOf(DISPLAY_OPTIONS)(v.option) && typeof v.enabled === "boolean";
    default:
      return registry.validate(v) === true;
  }
}

export function isCommandResults(value) {
  return Array.isArray(value?.results) && value.results.length >= 1 && value.results.length <= QUEUE_LIMIT
    && value.results.every((r) => itemID(r?.id) && (r.status === "applied" || r.status === "rejected")
      && optional(r.reason, (v) => typeof v === "string" && v.length <= 300));
}

// AI 확인 목록(AIQ1111A01). 앱이 처리하지 못했거나 불분명한 것을 올리고, AI가 가져가 처리한 뒤 완료·실패를 남긴다.
export const TASK_KINDS = ["payment_text", "receipt_text", "payment_rule", "memo_polish", "route_check", "fare_check", "merge_review", "stay_place", "other"];
export const TASK_STATUSES = ["waiting", "processing", "asked", "done", "failed", "expired"];
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
    && optional(value.reason, (v) => typeof v === "string" && codePoints(v) <= 200)
    && optional(value.outcome, isTaskOutcome);
}
// 일의 결과를 앱이 쓸 수 있는 모양으로(AIX1114A01 P2): 그 일로 보낸 명령·바뀐 가계부 기록·만든 규칙,
// 사용자에게 물은 질문(그 명령의 id), 사용자가 봐야 하는지.
const idList = (v) => Array.isArray(v) && v.length <= 20 && v.every((x) => commandID(x));
export function isTaskOutcome(value) {
  return !!value && typeof value === "object" && !Array.isArray(value)
    && optional(value.commandIds, idList) && optional(value.entryIds, idList) && optional(value.ruleIds, idList)
    && optional(value.askedQuestionId, (v) => commandID(v)) && optional(value.needsUser, (v) => typeof v === "boolean");
}
export function cleanTaskOutcome(value) {
  const out = {};
  for (const name of ["commandIds", "entryIds", "ruleIds"]) if (given(value?.[name]) && value[name].length) out[name] = value[name];
  if (given(value?.askedQuestionId)) out.askedQuestionId = value.askedQuestionId;
  if (value?.needsUser === true) out.needsUser = true;
  return Object.keys(out).length ? out : undefined;
}

// 앱 상태(ACX1112A01). 앱이 통째로 올리고 AI는 읽기만 한다: 설정, 가계부(이 달 합계·예산·최근 기록), 확인 필요,
// 받은 결제 문자(번호는 앱이 가린다), 결제 문자 규칙. 서버는 모양·개수만 보고 알려진 칸만 잠가 둔다.
export const APP_STATE_FIELDS = ["updatedAt", "timeZone", "settings", "ledger", "review", "inbox", "rules", "places", "categories", "trips", "placeSuggestion", "carAudio"];
export const APP_STATE_LIMITS = { entries: 200, review: 50, inbox: 30, rules: 20 };
const plainObject = (v) => !!v && typeof v === "object" && !Array.isArray(v);
const objectList = (v, max) => Array.isArray(v) && v.length <= max && v.every(plainObject);
export function isAppState(value) {
  return value?.format === "bokki-app" && value?.version === 1 && RETENTION_DAYS.has(value?.retentionDays)
    && plainObject(value.settings)
    && optional(value.updatedAt, isInstant) && optional(value.timeZone, (z) => nonEmpty(z, 40))
    && optional(value.ledger, (l) => plainObject(l) && optional(l.entries, (e) => objectList(e, APP_STATE_LIMITS.entries)))
    && optional(value.review, (l) => objectList(l, APP_STATE_LIMITS.review))
    && optional(value.inbox, (l) => objectList(l, APP_STATE_LIMITS.inbox))
    && optional(value.rules, (l) => objectList(l, APP_STATE_LIMITS.rules))
    && optional(value.places, (l) => objectList(l, PLACE_LIMITS.places)) && optional(value.categories, (l) => objectList(l, PLACE_LIMITS.categories))
    && optional(value.trips, (l) => objectList(l, TRIP_LIMITS.trips))
    && optional(value.placeSuggestion, plainObject) && optional(value.carAudio, plainObject);
}
export function cleanAppState(value) {
  const out = { format: "bokki-app", version: 1 };
  for (const name of APP_STATE_FIELDS) if (given(value[name])) out[name] = value[name];
  return out;
}
