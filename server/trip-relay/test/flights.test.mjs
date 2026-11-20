import assert from "node:assert/strict";
import test from "node:test";
import { DEFAULT_DAILY_CALLS, clock, dailyBudget, flightsSchedule, flightsStatus, isoDate, normalizeSchedule, normalizeStatus, stateFromRemark, validDate, weekday } from "../src/flights.js";

// FLT1119A01: 국내 공항 무료 항공편 조회 중계. 상류 응답은 전부 가짜 값(익명 편명·공항)이다.
const NOW = Date.UTC(2027, 2, 7, 3, 0); // 2027-03-07 12:00 KST
const env = { ICN_API_KEY: "icn-secret", KAC_API_KEY: "kac-secret", NOW: () => NOW };
const get = (path) => new Request(`https://relay.example.com${path}`);
const envelope = (items, total = items.length) => ({ response: { header: { resultCode: "00" }, body: { items: { item: items }, totalCount: total } } });
const ok = (body) => new Response(JSON.stringify(body), { status: 200 });

function memoryCache() {
  const map = new Map();
  return {
    map,
    async match(key) { const body = map.get(key); return body === undefined ? undefined : new Response(body); },
    async put(key, response) { map.set(key, await response.text()); },
  };
}

// 2027-03-07은 일요일이다.
const row = (extra = {}) => ({
  flightId: "AB123", airportCode: "BKK", st: "0905", terminalId: "P02", gateNumber: null,
  codeshare: "N", masterflightid: "AB123", season: "2027S", firstdate: "20270301", lastdate: "20271023",
  sunday: "Y", monday: "Y", tuesday: "N", wednesday: "N", thursday: "N", friday: "N", saturday: "N", ...extra,
});

test("helpers: clock, date and weekday parsing", () => {
  assert.equal(clock("1555"), "15:55");
  assert.equal(clock("0905"), "09:05");
  assert.equal(clock("905"), "09:05");
  assert.equal(clock("15:55:00"), "15:55");
  assert.equal(clock("2460"), "");
  assert.equal(clock(""), "");
  assert.equal(isoDate("20270301"), "2027-03-01");
  assert.equal(isoDate("2027-03-01"), "2027-03-01");
  assert.equal(isoDate("202703"), "");
  assert.equal(weekday("2027-03-07"), 0);
  assert.equal(weekday("2027-03-08"), 1);
  assert.equal(validDate("2027-02-29"), false);
  assert.equal(validDate("2028-02-29"), true);
  assert.equal(validDate("2027-3-7"), false);
});

test("schedule row maps to the common shape and the weekday flags decide the day", () => {
  const sunday = { airport: "ICN", date: "2027-03-07", direction: "dep" };
  const item = normalizeSchedule(row(), sunday);
  assert.deepEqual(item, {
    flight: "AB123", airline: "AB", origin: "ICN", destination: "BKK", time: "09:05", departureTime: "09:05", arrivalTime: null, durationMinutes: null, dayOffset: 0,
    terminal: "P02", gate: null, codeshare: false, master: "AB123", season: "2027S", validFrom: "2027-03-01", validTo: "2027-10-23", status: null,
  });
  assert.equal(normalizeSchedule(row(), { ...sunday, date: "2027-03-09" }), null, "화요일은 운항하지 않는다");
  assert.equal(normalizeSchedule(row(), { ...sunday, direction: "arr" }).destination, "ICN", "도착편은 방향이 뒤집힌다");
  assert.equal(normalizeSchedule(row(), { ...sunday, direction: "arr" }).origin, "BKK");
});

test("schedule row: validity window, codeshare, missing weekday columns and bad rows", () => {
  const base = { airport: "ICN", date: "2027-03-07", direction: "dep" };
  assert.equal(normalizeSchedule(row({ firstdate: "20270308" }), base), null, "시작 전");
  assert.equal(normalizeSchedule(row({ lastdate: "20270306" }), base), null, "종료 후");
  const shared = normalizeSchedule(row({ flightId: "CD456", masterflightid: "AB123", codeshare: "Y" }), base);
  assert.equal(shared.codeshare, true);
  assert.equal(shared.master, "AB123");
  const everyDay = { flightId: "EF789", airportCode: "NRT", st: "1555" };
  assert.equal(normalizeSchedule(everyDay, base).time, "15:55", "요일 칸이 없으면 매일");
  assert.equal(normalizeSchedule({ ...everyDay, flightId: "" }, base), null);
  assert.equal(normalizeSchedule({ ...everyDay, st: "" }, base), null);
  assert.equal(normalizeSchedule({ ...everyDay, airportCode: "XX" }, base), null);
  assert.equal(normalizeSchedule(null, base), null);
  // 필드 이름은 대소문자를 가리지 않는다
  assert.equal(normalizeSchedule({ FLIGHTID: "gh 12", AIRPORTCODE: "sin", ST: "0010" }, base).flight, "GH12");
});

test("status remark and delay mapping", () => {
  assert.equal(stateFromRemark("결항", "09:00", "09:00"), "cancelled");
  assert.equal(stateFromRemark("도착", "09:00", ""), "arrived");
  assert.equal(stateFromRemark("출발", "09:00", ""), "departed");
  assert.equal(stateFromRemark("지연", "09:00", "10:05"), "delayed");
  assert.equal(stateFromRemark("", "09:00", "10:05"), "delayed", "예상이 예정보다 늦으면 지연");
  assert.equal(stateFromRemark("", "09:00", "09:00"), "ontime");
  const item = normalizeStatus({ flightId: "AB125", airportCode: "BKK", scheduleDateTime: "1420", estimatedDateTime: "1525", remark: "지연", gateNumber: "252", terminalId: "T1" }, { airport: "ICN", direction: "dep" });
  assert.deepEqual(item.status, { state: "delayed", scheduled: "14:20", expected: "15:25", delayMinutes: 65, terminal: "T1", gate: "252", baggage: null });
  const overnight = normalizeStatus({ flightId: "AB126", airportCode: "BKK", st: "2350", estimatedDateTime: "0020" }, { airport: "ICN", direction: "dep" });
  assert.equal(overnight.status.delayMinutes, 30, "자정을 넘긴 지연");
  assert.equal(normalizeStatus({ flightId: "AB126", airportCode: "BKK" }, { airport: "ICN", direction: "dep" }), null);
});

test("schedule endpoint: filters the day's flights, sorts by time, marks source and updatedAt", async () => {
  const items = [row({ flightId: "EF789", airportCode: "NRT", st: "1555", masterflightid: "EF789" }), row(), row({ flightId: "GH111", airportCode: "SIN", st: "0010", tuesday: "N", sunday: "N" })];
  const fetcher = async () => ok(envelope(items));
  const response = await flightsSchedule(get("/flights/schedule?airport=ICN&date=2027-03-07&direction=dep"), env, fetcher, null);
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.source, "season");
  assert.equal(body.airport, "ICN");
  assert.deepEqual(body.flights.map((flight) => flight.flight), ["AB123", "EF789"], "시간순, 그날 안 뛰는 편 제외");
  assert.match(body.updatedAt, /^2027-03-07T03:00:00/);
  const filtered = await (await flightsSchedule(get("/flights/schedule?airport=ICN&date=2027-03-07&direction=dep&flight=ab123"), env, fetcher, null)).json();
  assert.deepEqual(filtered.flights.map((flight) => flight.flight), ["AB123"]);
  const byAirline = await (await flightsSchedule(get("/flights/schedule?airport=ICN&date=2027-03-07&direction=dep&airline=EF"), env, fetcher, null)).json();
  assert.deepEqual(byAirline.flights.map((flight) => flight.flight), ["EF789"]);
});

test("schedule endpoint: the second call is served from cache and never reaches upstream", async () => {
  const cache = memoryCache();
  let calls = 0, charged = 0;
  const fetcher = async () => { calls += 1; return ok(envelope([row()])); };
  const charge = async () => { charged += 1; return { ok: true }; };
  const path = "/flights/schedule?airport=ICN&date=2027-03-07&direction=dep";
  assert.equal((await flightsSchedule(get(path), env, fetcher, cache, charge)).status, 200);
  assert.equal((await flightsSchedule(get(path), env, fetcher, cache, charge)).status, 200);
  assert.equal(calls, 1);
  assert.equal(charged, 1, "캐시가 맞으면 예산을 세지 않는다");
  assert.equal([...cache.map.keys()].some((key) => key.includes("secret")), false, "캐시 열쇠에 키가 없다");
  // 같은 날이라도 다른 편명 필터는 같은 캐시를 쓴다(필터는 응답에서만 적용).
  await flightsSchedule(get(`${path}&flight=AB123`), env, fetcher, cache, charge);
  assert.equal(calls, 1);
});

test("schedule endpoint: other airports use the Korea Airports Corporation source and key", async () => {
  const seen = [];
  const fetcher = async (url) => { seen.push(new URL(url)); return ok(envelope([row({ flightId: "ZZ100", airportCode: "CJU", st: "0800" })])); };
  const response = await flightsSchedule(get("/flights/schedule?airport=GMP&date=2027-03-07&direction=dep"), env, fetcher, null);
  assert.equal(response.status, 200);
  assert.equal(seen[0].searchParams.get("serviceKey"), "kac-secret");
  assert.equal(seen[0].searchParams.get("airport"), "GMP", "인천이 아닌 공항은 그 코드로 묻는다");
  assert.equal(seen[0].searchParams.get("type"), "json");
  const icn = [];
  await flightsSchedule(get("/flights/schedule?airport=ICN&date=2027-03-07&direction=dep"), env, async (url) => { icn.push(new URL(url)); return ok(envelope([])); }, null);
  assert.equal(icn[0].searchParams.get("serviceKey"), "icn-secret");
  assert.equal(icn[0].searchParams.has("airport"), false);
});

test("schedule endpoint: bad query 400, missing key 503, upstream failure 502 without leaking", async () => {
  const fetcher = async () => ok(envelope([row()]));
  for (const path of ["/flights/schedule", "/flights/schedule?airport=ICN&date=2027-03-07", "/flights/schedule?airport=IC&date=2027-03-07&direction=dep",
    "/flights/schedule?airport=ICN&date=2027-02-30&direction=dep", "/flights/schedule?airport=ICN&date=2027-03-07&direction=up",
    "/flights/schedule?airport=ICN&date=2027-03-07&direction=dep&flight=%3Cscript%3E", "/flights/schedule?airport=ICN&date=2027-03-07&direction=dep&airline=ABC"]) {
    assert.equal((await flightsSchedule(get(path), env, fetcher, null)).status, 400, path);
  }
  const noKey = await flightsSchedule(get("/flights/schedule?airport=ICN&date=2027-03-07&direction=dep"), {}, fetcher, null);
  assert.equal(noKey.status, 503);
  assert.deepEqual(await noKey.json(), { error: "flight_key_missing", message: "flight API key is not set on the relay" });
  const onlyIcn = { ICN_API_KEY: "x" };
  assert.equal((await flightsSchedule(get("/flights/schedule?airport=GMP&date=2027-03-07&direction=dep"), onlyIcn, fetcher, null)).status, 503, "한국공항공사 키만 없으면 그 소스만 503");
  assert.equal((await flightsSchedule(get("/flights/schedule?airport=ICN&date=2027-03-07&direction=dep"), onlyIcn, fetcher, null)).status, 200);

  const failures = [
    async () => new Response("nope secret icn-secret", { status: 500 }),
    async () => { throw new Error("connect failed icn-secret"); },
    async () => new Response("not json icn-secret", { status: 200 }),
    async () => ok({ response: { header: { resultCode: "22", resultMsg: "LIMITED icn-secret" } } }),
  ];
  for (const failing of failures) {
    const response = await flightsSchedule(get("/flights/schedule?airport=ICN&date=2027-03-07&direction=dep"), env, failing, null);
    assert.equal(response.status, 502);
    const text = await response.text();
    assert.deepEqual(JSON.parse(text), { error: "upstream_failed" });
    assert.equal(text.includes("secret"), false, "상류 원문·키를 돌려주지 않는다");
  }
  assert.equal((await flightsSchedule(new Request("https://relay.example.com/flights/schedule?airport=ICN&date=2027-03-07&direction=dep", { method: "POST" }), env, fetcher, null)).status, 405);
});

test("schedule endpoint: daily call budget exhausted returns 429 with Retry-After and never calls upstream", async () => {
  let calls = 0;
  const fetcher = async () => { calls += 1; return ok(envelope([row()])); };
  const exhausted = async () => ({ ok: false, retryAfter: 4321 });
  const response = await flightsSchedule(get("/flights/schedule?airport=ICN&date=2027-03-07&direction=dep"), env, fetcher, null, exhausted);
  assert.equal(response.status, 429);
  assert.equal(response.headers.get("retry-after"), "4321");
  assert.deepEqual(await response.json(), { error: "flight_daily_limit", retryAfter: 4321 });
  assert.equal(calls, 0);
  assert.equal(dailyBudget({}), DEFAULT_DAILY_CALLS);
  assert.equal(dailyBudget({ FLIGHT_DAILY_CALLS: "250" }), 250);
  assert.equal(dailyBudget({ FLIGHT_DAILY_CALLS: "abc" }), DEFAULT_DAILY_CALLS);
  assert.equal(dailyBudget({ FLIGHT_DAILY_CALLS: "-5" }), DEFAULT_DAILY_CALLS);
});

test("schedule endpoint: pages are fetched until the list ends and each upstream call is charged once", async () => {
  const rowsFor = (page) => Array.from({ length: page === 1 ? 1000 : 5 }, (_, index) => row({ flightId: `AB${page}${String(index).padStart(3, "0")}`.slice(0, 6), airportCode: "BKK", st: "0905" }));
  let calls = 0, charged = 0;
  const fetcher = async (url) => { calls += 1; return ok(envelope(rowsFor(Number(new URL(url).searchParams.get("pageNo"))), 1005)); };
  const charge = async () => { charged += 1; return { ok: true }; };
  const response = await flightsSchedule(get("/flights/schedule?airport=ICN&date=2027-03-07&direction=dep"), env, fetcher, null, charge);
  assert.equal(response.status, 200);
  assert.equal(calls, 2);
  assert.equal(charged, 2);
});

test("status endpoint: delay, gate and baggage come through and the cache keeps it short", async () => {
  const cache = memoryCache();
  let calls = 0;
  const seen = [];
  const fetcher = async (url) => {
    calls += 1; seen.push(new URL(url));
    return ok(envelope([{ flightId: "AB125", airportCode: "BKK", scheduleDateTime: "1420", estimatedDateTime: "1525", remark: "지연", gateNumber: "252", terminalId: "T1", carousel: null }]));
  };
  const path = "/flights/status?airport=ICN&date=2027-03-07&direction=dep";
  const body = await (await flightsStatus(get(path), env, fetcher, cache)).json();
  assert.equal(body.source, "status");
  assert.equal(body.available, true);
  assert.deepEqual(body.flights[0].status, { state: "delayed", scheduled: "14:20", expected: "15:25", delayMinutes: 65, terminal: "T1", gate: "252", baggage: null });
  assert.equal(seen[0].searchParams.get("searchday"), "20270307");
  assert.equal(seen[0].searchParams.get("serviceKey"), "icn-secret");
  await flightsStatus(get(path), env, fetcher, cache);
  assert.equal(calls, 1);
  assert.match([...cache.map.keys()][0], /status\?airport=ICN/);
});

test("status endpoint: only ICN has live status, dates outside D-3..D+6 are refused, bad query 400, key 503", async () => {
  const fetcher = async () => { throw new Error("must not be called"); };
  const other = await (await flightsStatus(get("/flights/status?airport=GMP&date=2027-03-07&direction=dep"), env, fetcher, null)).json();
  assert.equal(other.available, false);
  assert.deepEqual(other.flights, []);
  assert.equal(other.source, "status");
  assert.equal((await flightsStatus(get("/flights/status?airport=ICN&date=2027-03-14&direction=dep"), env, fetcher, null)).status, 422, "D+7은 범위 밖");
  assert.equal((await flightsStatus(get("/flights/status?airport=ICN&date=2027-03-03&direction=dep"), env, fetcher, null)).status, 422, "D-4는 범위 밖");
  const edgeFuture = await flightsStatus(get("/flights/status?airport=ICN&date=2027-03-13&direction=dep"), env, async () => ok(envelope([])), null);
  assert.equal(edgeFuture.status, 200, "D+6은 범위 안");
  const edgePast = await flightsStatus(get("/flights/status?airport=ICN&date=2027-03-04&direction=arr"), env, async () => ok(envelope([])), null);
  assert.equal(edgePast.status, 200, "D-3은 범위 안");
  assert.equal((await flightsStatus(get("/flights/status?airport=ICN&direction=dep"), env, fetcher, null)).status, 400);
  assert.equal((await flightsStatus(get("/flights/status?airport=ICN&date=2027-03-07&direction=dep"), { NOW: env.NOW }, fetcher, null)).status, 503);
  assert.equal((await flightsStatus(get("/flights/status?airport=ICN&date=2027-03-07&direction=dep"), env, async () => new Response("x", { status: 500 }), null)).status, 502);
});

test("no user data is read: personal-looking query values are ignored, not forwarded upstream", async () => {
  const seen = [];
  const fetcher = async (url) => { seen.push(new URL(url)); return ok(envelope([row()])); };
  await flightsSchedule(get("/flights/schedule?airport=ICN&date=2027-03-07&direction=dep&pnr=ABC123&name=HONG%2FGILDONG&phone=0000-0000"), env, fetcher, null);
  const names = [...seen[0].searchParams.keys()];
  for (const forbidden of ["pnr", "name", "phone"]) assert.equal(names.includes(forbidden), false, forbidden);
});

// FLT1120A01: 국내선 방향별 출발·도착 시각.
const domestic = (extra = {}) => row({ flightId: "AB101", airportCode: "CJU", st: undefined, domesticstarttime: "2350", domesticarrivaltime: "0020", ...extra });

test("domestic row: dep rows read the departure column, arr rows read the arrival column", () => {
  const dep = normalizeSchedule(domestic(), { airport: "GMP", date: "2027-03-07", direction: "dep" });
  assert.equal(dep.time, "23:50");
  assert.equal(dep.departureTime, "23:50");
  assert.equal(dep.arrivalTime, "00:20");
  assert.equal(dep.durationMinutes, 30, "23:50 → 00:20은 자정을 넘겨 30분");
  assert.equal(dep.origin, "GMP");
  assert.equal(dep.destination, "CJU");
  const arr = normalizeSchedule(domestic({ airportCode: "GMP" }), { airport: "CJU", date: "2027-03-07", direction: "arr" });
  assert.equal(arr.time, "00:20", "도착 조회의 time은 도착 칸");
  assert.equal(arr.arrivalTime, "00:20");
  assert.equal(arr.departureTime, "23:50");
  assert.equal(arr.origin, "GMP");
  assert.equal(arr.destination, "CJU");
});

test("domestic row: duration is only computed for two Korean airports and when both times exist", () => {
  const intl = normalizeSchedule(domestic({ airportCode: "NRT" }), { airport: "GMP", date: "2027-03-07", direction: "dep" });
  assert.equal(intl.durationMinutes, null, "시차가 있는 국제선은 계산하지 않는다");
  const oneSided = normalizeSchedule(row({ flightId: "AB102", airportCode: "CJU", st: "0905" }), { airport: "GMP", date: "2027-03-07", direction: "dep" });
  assert.equal(oneSided.arrivalTime, null);
  assert.equal(oneSided.durationMinutes, null);
});

test("schedule cache lasts 30 minutes and a hit does not call upstream again", async () => {
  const cache = memoryCache();
  let calls = 0;
  const fetcher = async () => { calls += 1; return ok(envelope([domestic()])); };
  const request = () => get("/flights/schedule?airport=GMP&date=2027-03-07&direction=dep");
  const first = await flightsSchedule(request(), env, fetcher, cache);
  assert.equal(first.status, 200);
  assert.equal(calls, 1);
  const second = await flightsSchedule(request(), env, fetcher, cache);
  assert.equal(calls, 1, "캐시 적중 때는 상류를 다시 부르지 않는다");
  const body = await second.json();
  assert.equal(body.flights[0].departureTime, "23:50");
  let ttl;
  const spy = { async match() { return undefined; }, async put(_key, response) { ttl = response.headers.get("cache-control"); } };
  await flightsSchedule(request(), env, fetcher, spy);
  assert.equal(ttl, "max-age=1800");
});
