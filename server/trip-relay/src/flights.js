// 국내 공항 무료 항공편 조회 중계(FLT1119A01). 공공데이터포털(data.go.kr) OpenAPI 두 곳을 한 모양으로 정규화한다.
// - 인천국제공항공사 정기운항편(StatusOfPaxFltSched) · 당일 운항현황: 비밀값 ICN_API_KEY
// - 한국공항공사 전국 공항 국내선·국제선 스케줄: 비밀값 KAC_API_KEY (인천은 이 목록에 없다)
// 키는 Worker 비밀값이고 앱에 넣지 않는다. 사용자의 항공편·예약번호·이름은 받지도 저장하지도 않는다: 받는 것은
// 공항 코드·날짜·방향·편명 같은 공개 값뿐이다. 상류 오류 원문(키가 섞일 수 있음)은 돌려주지 않는다(`expressway.js`와 같다).
//
// 확인한 것(2026-11-20, data.go.kr 상세 페이지): 정기운항편 서비스 주소 `apis.data.go.kr/B551177/StatusOfPaxFltSched`,
// 도착 조회 `getPaxFltSchedArrivalsDeOdp`, 요청 변수 serviceKey·pageNo·numOfRows·type·airport(상대 공항)·lang, 개발계정 일 500회,
// 오류 코드 22(일 한도)·23(초당 한도). **응답 칸 이름은 상세 페이지에 없어** 아래 `FIELD`의 후보 이름(대소문자 무시)으로 읽는다.
// 출발 조회·당일 운항현황·한국공항공사 주소는 같은 계열 이름을 따른 추정이므로, 키를 받은 뒤 `scripts/flights-probe.mjs`로
// 실제 칸 이름을 확인해 어긋나면 이 파일의 `SOURCES`·`FIELD`만 고친다.
import { json } from "./http.js";

const CACHE_ORIGIN = "https://flights-cache.invalid";
const SCHEDULE_TTL = 7 * 86_400;
const STATUS_TTL = 90;
const PAGE_ROWS = 1_000;
const MAX_PAGES = 5;
const MAX_FLIGHTS = 800;
const USER_AGENT = "Mozilla/5.0 (compatible; TaptionTripRelay/1.0)";
const STATUS_PAST_DAYS = 3;
const STATUS_FUTURE_DAYS = 6;
export const DEFAULT_DAILY_CALLS = 400;

const AIRPORT = /^[A-Z]{3}$/;
const FLIGHT = /^[A-Z0-9]{2}\d{1,4}[A-Z]?$/;
const AIRLINE = /^[A-Z0-9]{2}$/;
const DATE = /^(\d{4})-(\d{2})-(\d{2})$/;

// 상류 서비스 표. 주소·운항 조회 이름은 문서로 확인된 것만 확정이고 나머지는 추정이다(위 설명).
export const SOURCES = {
  icnSchedule: { key: "ICN_API_KEY", base: "https://apis.data.go.kr/B551177/StatusOfPaxFltSched/", dep: "getPaxFltSchedDeparturesDeOdp", arr: "getPaxFltSchedArrivalsDeOdp", otherEnd: "airport" },
  icnStatus: { key: "ICN_API_KEY", base: "https://apis.data.go.kr/B551177/StatusOfPassengerFlightsOdp/", dep: "getPassengerDeparturesOdp", arr: "getPassengerArrivalsOdp" },
  kacSchedule: { key: "KAC_API_KEY", base: "https://apis.data.go.kr/B551177/KacFlightSchedule/", dep: "getDepartureScheduleList", arr: "getArrivalScheduleList" },
};

// 응답 칸 후보 이름(소문자). 앞에서부터 처음 값이 있는 것을 쓴다.
export const FIELD = {
  flight: ["flightid", "flightno", "flightnumber", "fid", "domesticnum"],
  otherAirport: ["airportcode", "airport", "arrairport", "depairport", "startcity", "arrivalcity"],
  time: ["st", "scheduletime", "scheduledatetime", "domesticstarttime", "domesticarrivaltime"],
  expected: ["estimateddatetime", "estimatedtime", "chgtime", "changetime", "etd", "eta"],
  terminal: ["terminalid", "terminal", "terminalno"],
  gate: ["gatenumber", "gate", "gateno"],
  baggage: ["carousel", "baggage", "baggageclaim", "luggage"],
  remark: ["remark", "status", "rmk", "remarkkor"],
  codeshare: ["codeshare", "codeshareyn"],
  master: ["masterflightid", "masterflightno", "master"],
  season: ["season", "seasoncode", "seasonid"],
  validFrom: ["firstdate", "fromdate", "startdate", "domesticstdate", "operfromdate"],
  validTo: ["lastdate", "todate", "enddate", "domesticeddate", "opertodate"],
};
const WEEKDAYS = [
  ["sunday", "sun", "domesticsun"], ["monday", "mon", "domesticmon"], ["tuesday", "tue", "domestictue"], ["wednesday", "wed", "domesticwed"],
  ["thursday", "thu", "domesticthu"], ["friday", "fri", "domesticfri"], ["saturday", "sat", "domesticsat"],
];

const text = (value) => (typeof value === "string" ? value.trim() : typeof value === "number" ? String(value) : "");

function lowerKeys(row) {
  const out = {};
  if (row && typeof row === "object") for (const [name, value] of Object.entries(row)) out[name.toLowerCase()] = value;
  return out;
}

const pick = (row, names) => {
  for (const name of names) {
    const value = text(row[name]);
    if (value) return value;
  }
  return "";
};

// "1555"·"15:55"·"15:55:00" → "15:55". 모양이 아니면 "".
export function clock(value) {
  const raw = text(value).replace(/\D/g, "");
  if (raw.length === 3 || raw.length === 4 || raw.length === 6) {
    const padded = raw.length === 3 ? "0" + raw : raw.slice(0, 4);
    const hour = Number(padded.slice(0, 2)), minute = Number(padded.slice(2, 4));
    if (hour <= 23 && minute <= 59) return `${padded.slice(0, 2)}:${padded.slice(2, 4)}`;
  }
  return "";
}

// "20270301"·"2027-03-01" → "2027-03-01". 아니면 "".
export function isoDate(value) {
  const raw = text(value).replace(/\D/g, "").slice(0, 8);
  if (raw.length !== 8) return "";
  return `${raw.slice(0, 4)}-${raw.slice(4, 6)}-${raw.slice(6, 8)}`;
}

function truthy(value) {
  if (value === true) return true;
  const v = text(value).toUpperCase();
  return v === "Y" || v === "1" || v === "TRUE";
}

// 달력 날짜의 요일(0=일). 시간대 없이 UTC로 계산한다.
export function weekday(date) {
  const m = DATE.exec(date);
  return m ? new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]))).getUTCDay() : -1;
}

export function validDate(date) {
  const m = DATE.exec(date);
  if (!m) return false;
  const d = new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])));
  return d.getUTCFullYear() === Number(m[1]) && d.getUTCMonth() === Number(m[2]) - 1 && d.getUTCDate() === Number(m[3]);
}

const airlineOf = (flight) => flight.slice(0, 2);

// 정기운항편 한 줄을 정규화한다. 그 날 운항하지 않으면(요일·유효 기간) null.
export function normalizeSchedule(row, { airport, date, direction }) {
  const r = lowerKeys(row);
  const flight = pick(r, FIELD.flight).replace(/\s+/g, "").toUpperCase();
  const time = clock(pick(r, FIELD.time));
  const other = pick(r, FIELD.otherAirport).toUpperCase();
  if (!FLIGHT.test(flight) || !time || !AIRPORT.test(other)) return null;
  const from = isoDate(pick(r, FIELD.validFrom)), to = isoDate(pick(r, FIELD.validTo));
  if (from && date < from) return null;
  if (to && date > to) return null;
  const day = weekday(date);
  const flags = WEEKDAYS.map((names) => { const v = pick(r, names); return v === "" ? null : truthy(v); });
  // 요일 칸이 하나라도 있으면 그 날 칸이 참일 때만 운항한다. 하나도 없으면 매일로 본다.
  if (flags.some((flag) => flag !== null) && flags[day] !== true) return null;
  const master = pick(r, FIELD.master).replace(/\s+/g, "").toUpperCase();
  const codeshare = truthy(pick(r, FIELD.codeshare)) || (master !== "" && master !== flight);
  return {
    flight, airline: airlineOf(flight),
    origin: direction === "dep" ? airport : other, destination: direction === "dep" ? other : airport,
    time, dayOffset: 0,
    terminal: pick(r, FIELD.terminal) || null, gate: pick(r, FIELD.gate) || null,
    codeshare, master: FLIGHT.test(master) ? master : flight,
    season: pick(r, FIELD.season) || null, validFrom: from || null, validTo: to || null,
    status: null,
  };
}

// 비고 글에서 운항 상태를 읽는다. 모르면 정시로 본다.
export function stateFromRemark(remark, scheduled, expected) {
  const r = text(remark);
  if (/결항|cancel/i.test(r)) return "cancelled";
  if (/도착|arrived|landed/i.test(r)) return "arrived";
  if (/출발|탑승|departed|boarding/i.test(r) && !/지연/.test(r)) return "departed";
  if (/지연|delay/i.test(r)) return "delayed";
  if (scheduled && expected && expected > scheduled) return "delayed";
  return "ontime";
}

const minutes = (hhmm) => Number(hhmm.slice(0, 2)) * 60 + Number(hhmm.slice(3, 5));

// 당일 운항현황 한 줄. 예정 시각이 없으면 null.
export function normalizeStatus(row, { airport, direction }) {
  const r = lowerKeys(row);
  const flight = pick(r, FIELD.flight).replace(/\s+/g, "").toUpperCase();
  const scheduled = clock(pick(r, FIELD.time));
  const other = pick(r, FIELD.otherAirport).toUpperCase();
  if (!FLIGHT.test(flight) || !scheduled || !AIRPORT.test(other)) return null;
  const expected = clock(pick(r, FIELD.expected)) || null;
  const state = stateFromRemark(pick(r, FIELD.remark), scheduled, expected ?? "");
  let delay = 0;
  if (expected) {
    delay = minutes(expected) - minutes(scheduled);
    // 자정을 넘겨 늦어진 경우(예: 23:50 → 00:20)
    if (delay < -720) delay += 1440;
    if (delay < 0) delay = 0;
  }
  const baggage = pick(r, FIELD.baggage) || null;
  return {
    flight, airline: airlineOf(flight),
    origin: direction === "dep" ? airport : other, destination: direction === "dep" ? other : airport,
    time: scheduled, dayOffset: 0,
    terminal: pick(r, FIELD.terminal) || null, gate: pick(r, FIELD.gate) || null,
    codeshare: false, master: flight, season: null, validFrom: null, validTo: null,
    status: { state, scheduled, expected, delayMinutes: delay, terminal: pick(r, FIELD.terminal) || null, gate: pick(r, FIELD.gate) || null, baggage },
  };
}

// data.go.kr 응답 봉투에서 줄 목록과 전체 수. 성공 코드가 아니면 null.
export function unwrap(body) {
  const inner = body?.response;
  const code = text(inner?.header?.resultCode);
  if (code && code !== "00" && code !== "0000") return null;
  const items = inner?.body?.items;
  const list = Array.isArray(items) ? items : Array.isArray(items?.item) ? items.item : items?.item ? [items.item] : [];
  return { rows: list, total: Number(inner?.body?.totalCount ?? list.length) || list.length };
}

const upstreamFailed = () => json({ error: "upstream_failed" }, 502);
const missingKey = () => json({ error: "flight_key_missing", message: "flight API key is not set on the relay" }, 503);
const methodOnlyGet = (request) => (request.method === "GET" ? null : json({ error: "method_not_allowed" }, 405));

async function cached(cache, key) {
  if (!cache) return null;
  try { return (await cache.match(key)) ?? null; } catch { return null; }
}

async function keep(cache, key, body, ttl) {
  if (!cache) return;
  const copy = new Response(JSON.stringify(body), { headers: { "content-type": "application/json; charset=utf-8", "cache-control": `max-age=${ttl}` } });
  try { await cache.put(key, copy); } catch { /* 캐시가 없어도 응답은 준다 */ }
}

// 상류 한 쪽. 실패·예외의 원문은 돌려주거나 던지지 않는다. 호출 예산은 부르기 전에 한 번 센다.
async function fetchPage(fetcher, source, operation, params, key, charge) {
  const spent = await charge();
  if (!spent.ok) return { limited: spent };
  const target = new URL(source.base + operation);
  for (const [name, value] of Object.entries(params)) target.searchParams.set(name, value);
  target.searchParams.set("type", "json");
  target.searchParams.set("serviceKey", key);
  let upstream, body;
  try { upstream = await fetcher(target, { headers: { "user-agent": USER_AGENT, accept: "application/json" } }); } catch { return null; }
  if (!upstream.ok) return null;
  try { body = await upstream.json(); } catch { return null; }
  return unwrap(body);
}

function query(request) {
  const q = new URL(request.url).searchParams;
  const airport = (q.get("airport") ?? "").trim().toUpperCase();
  const date = (q.get("date") ?? "").trim();
  const direction = (q.get("direction") ?? "").trim();
  const flight = (q.get("flight") ?? "").replace(/\s+/g, "").toUpperCase();
  const airline = (q.get("airline") ?? "").trim().toUpperCase();
  if (!AIRPORT.test(airport) || !validDate(date) || (direction !== "dep" && direction !== "arr")) return null;
  if (flight && !FLIGHT.test(flight)) return null;
  if (airline && !AIRLINE.test(airline)) return null;
  return { airport, date, direction, flight, airline };
}

const tooMany = (limited) => json({ error: "flight_daily_limit", retryAfter: limited.retryAfter ?? 3600 }, 429, { "retry-after": String(limited.retryAfter ?? 3600) });

function dailyBudget(env) {
  const configured = Number(env.FLIGHT_DAILY_CALLS);
  return Number.isInteger(configured) && configured > 0 ? configured : DEFAULT_DAILY_CALLS;
}
export { dailyBudget };

function respond(shape, flights, { flight, airline }, extra = {}) {
  const filtered = flights
    .filter((item) => (!flight || item.flight === flight || item.master === flight) && (!airline || item.airline === airline))
    .sort((a, b) => (a.time < b.time ? -1 : a.time > b.time ? 1 : a.flight < b.flight ? -1 : 1))
    .slice(0, MAX_FLIGHTS);
  return json({ ...shape, ...extra, flights: filtered }, 200, { "cache-control": "private, max-age=60" });
}

// `charge()`는 상류를 한 번 부를 때마다 서버 전체 하루 예산에서 1을 센다({ ok, retryAfter? }). 캐시가 맞으면 부르지 않는다.
export async function flightsSchedule(request, env, fetcher = fetch, cache = globalThis.caches?.default, charge = async () => ({ ok: true })) {
  const refused = methodOnlyGet(request);
  if (refused) return refused;
  const q = query(request);
  if (!q) return json({ error: "bad_query" }, 400);
  const source = q.airport === "ICN" ? SOURCES.icnSchedule : SOURCES.kacSchedule;
  const key = env[source.key];
  if (!key) return missingKey();
  const cacheKey = `${CACHE_ORIGIN}/schedule?airport=${q.airport}&date=${q.date}&direction=${q.direction}`;
  const shape = { airport: q.airport, date: q.date, direction: q.direction, source: "season" };
  const hit = await cached(cache, cacheKey);
  if (hit) {
    const stored = await hit.json();
    return respond(shape, stored.flights, q, { updatedAt: stored.updatedAt });
  }
  const operation = source[q.direction];
  const rows = [];
  for (let number = 1; number <= MAX_PAGES; number += 1) {
    const params = { pageNo: String(number), numOfRows: String(PAGE_ROWS), lang: "E" };
    // 인천이 아닌 공항은 그 공항 코드로 묻는다. 인천은 전체 목록에서 공항 칸으로 나눈다.
    if (q.airport !== "ICN") params.airport = q.airport;
    const got = await fetchPage(fetcher, source, operation, params, key, charge);
    if (got?.limited) return tooMany(got.limited);
    if (!got) return upstreamFailed();
    rows.push(...got.rows);
    if (got.rows.length < PAGE_ROWS || rows.length >= got.total) break;
  }
  const seen = new Set(), flights = [];
  for (const row of rows) {
    const item = normalizeSchedule(row, q);
    if (!item) continue;
    const id = `${item.flight}|${item.time}|${item.origin}|${item.destination}`;
    if (seen.has(id)) continue;
    seen.add(id);
    flights.push(item);
  }
  const updatedAt = new Date(env.NOW?.() ?? Date.now()).toISOString();
  await keep(cache, cacheKey, { flights, updatedAt }, SCHEDULE_TTL);
  return respond(shape, flights, q, { updatedAt });
}

const DAY_MS = 86_400_000;

export async function flightsStatus(request, env, fetcher = fetch, cache = globalThis.caches?.default, charge = async () => ({ ok: true })) {
  const refused = methodOnlyGet(request);
  if (refused) return refused;
  const q = query(request);
  if (!q) return json({ error: "bad_query" }, 400);
  const now = env.NOW?.() ?? Date.now();
  const target = Date.UTC(Number(q.date.slice(0, 4)), Number(q.date.slice(5, 7)) - 1, Number(q.date.slice(8, 10)));
  const today = Math.floor((now + 9 * 3_600_000) / DAY_MS) * DAY_MS; // 한국 날짜 기준
  if (target < today - STATUS_PAST_DAYS * DAY_MS || target > today + STATUS_FUTURE_DAYS * DAY_MS) return json({ error: "date_out_of_range" }, 422);
  const shape = { airport: q.airport, date: q.date, direction: q.direction, source: "status" };
  // 당일 운항현황은 인천만 연결한다. 다른 공항은 정기 스케줄만 있다(앱은 「정기 스케줄 기준」으로 표시한다).
  if (q.airport !== "ICN") return respond(shape, [], q, { available: false, updatedAt: new Date(now).toISOString() });
  const source = SOURCES.icnStatus;
  const key = env[source.key];
  if (!key) return missingKey();
  const cacheKey = `${CACHE_ORIGIN}/status?airport=${q.airport}&date=${q.date}&direction=${q.direction}`;
  const hit = await cached(cache, cacheKey);
  if (hit) {
    const stored = await hit.json();
    return respond(shape, stored.flights, q, { available: true, updatedAt: stored.updatedAt });
  }
  const rows = [];
  for (let number = 1; number <= MAX_PAGES; number += 1) {
    const params = { pageNo: String(number), numOfRows: String(PAGE_ROWS), searchday: q.date.replace(/-/g, ""), from_time: "0000", to_time: "2359", lang: "E" };
    const got = await fetchPage(fetcher, source, source[q.direction], params, key, charge);
    if (got?.limited) return tooMany(got.limited);
    if (!got) return upstreamFailed();
    rows.push(...got.rows);
    if (got.rows.length < PAGE_ROWS || rows.length >= got.total) break;
  }
  const flights = rows.map((row) => normalizeStatus(row, q)).filter(Boolean);
  const updatedAt = new Date(now).toISOString();
  await keep(cache, cacheKey, { flights, updatedAt }, STATUS_TTL);
  return respond(shape, flights, q, { available: true, updatedAt });
}
