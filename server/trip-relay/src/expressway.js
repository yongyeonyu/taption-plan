// 고속도로 통행료 중계(TGT1118A01). 한국도로공사 고속도로 공공데이터 포털(data.ex.co.kr) OpenAPI.
// 키는 Worker 비밀값 EX_API_KEY이고 앱에 넣지 않는다. 사용자 좌표는 받지 않는다: 앱은 영업소 목록을 통째로 받아
// 기기에서 견주고, 요금은 영업소 코드와 차종만 보낸다.
// - GET /ex/units: 영업소 위치(locationinfoUnit) 모든 쪽을 모아 {code, name, route, routeNo, lat, lng}로 정리. 7일 캐시.
//   포털에 위치(xValue·yValue)가 없는 영업소는 카카오 장소 검색(KAKAO_REST_API_KEY)으로 이름을 찾아 좌표를 채운다(TGT1119A03).
//   영업소 이름만 카카오에 보내고 사용자 좌표는 보내지 않는다. 찾은 값·못 찾은 것은 저장소(`geo:<코드>`)에 오래 두어 다시 묻지 않는다.
// - GET /ex/fare?from&to&car: 영업소간 통행요금(bhoinstIntoTollList)의 정상요금. 출발과 도착이 같으면 본선(개방식) 영업소. 1일 캐시.
//   시간대 할인 칸(odn1·odn2)은 넘기지 않는다: 앱이 정상요금에 자기 할인 규칙(LedgerTollDiscount)을 한 번만 적용한다.
//   이름 변수(dprtrTolofNm 등)는 부분 일치라 쓰지 않고 코드로만 묻는다.
import { json } from "./http.js";
import { PREFIX_UNITS } from "./ex-unit-prefix.js";

const EX_BASE = "https://data.ex.co.kr/openapi/";
const UNIT_CODE = /^[0-9A-Za-z]{1,6}$/;
// 포털이 한 쪽에 99줄까지만 준다.
const PAGE_ROWS = 99;
const MAX_PAGES = 20;
const UNITS_TTL = 7 * 86_400;
const FARE_TTL = 86_400;
// 이 이름은 우리 캐시 열쇠일 뿐 실제로 부르지 않는다. 키·사용자 값이 들어가지 않는다.
const CACHE_ORIGIN = "https://ex-cache.invalid";
// 포털 방화벽이 도구 기본 User-Agent를 400으로 막아, 일반 앱 값을 보낸다.
const USER_AGENT = "Mozilla/5.0 (compatible; TaptionTripRelay/1.0)";

// 위치 없는 영업소를 카카오 장소 검색으로 채운다(TGT1119A03). 한 번 목록을 만들 때 부르는 검색 수를 제한한다.
const KAKAO_PLACE_URL = "https://dapi.kakao.com/v2/local/search/keyword.json";
const GEO_CALLS_PER_BUILD = 24;
// 고정표를 만드는 스크립트만 한 번에 더 많이 묻는다(`EX_GEO_CALLS`). 서버에는 두지 않는다.
const geoCalls = (env) => Math.max(1, Number(env.EX_GEO_CALLS) || GEO_CALLS_PER_BUILD);
const GEO_TTL = 365 * 86_400;
const GEO_MISS_TTL = 30 * 86_400;
const PARTIAL_UNITS_TTL = 3_600;
const UNIT_WORD = /(톨게이트|요금소|영업소|IC|JC|나들목|분기점)$/i;
const UNIT_PLACE = /(톨게이트|요금소|영업소|IC|JC|나들목|분기점|고속도로|교통)/i;

const missingKey = () => json({ error: "ex_key_missing", message: "EX_API_KEY is not set on the relay" }, 503);
const upstreamFailed = () => json({ error: "upstream_failed" }, 502);
const text = (value) => (typeof value === "string" ? value.trim() : typeof value === "number" ? String(value) : "");

function reply(body, ttl) {
  return json(body, 200, { "cache-control": `private, max-age=${ttl}` });
}

async function cached(cache, key) {
  if (!cache) return null;
  try { return (await cache.match(key)) ?? null; } catch { return null; }
}

async function keep(cache, key, body, ttl) {
  if (!cache) return;
  const copy = new Response(JSON.stringify(body), { headers: { "content-type": "application/json; charset=utf-8", "cache-control": `max-age=${ttl}` } });
  try { await cache.put(key, copy); } catch { /* 캐시가 없어도 응답은 준다 */ }
}

// 상류 한 쪽. 실패·예외의 원문(서버 키가 섞일 수 있음)은 돌려주거나 던지지 않는다.
async function page(fetcher, path, params, key) {
  const target = new URL(EX_BASE + path);
  for (const [name, value] of Object.entries(params)) target.searchParams.set(name, value);
  target.searchParams.set("type", "json");
  target.searchParams.set("key", key);
  let upstream, body;
  try { upstream = await fetcher(target, { headers: { "user-agent": USER_AGENT, accept: "application/json" } }); } catch { return null; }
  if (!upstream.ok) return null;
  try { body = await upstream.json(); } catch { return null; }
  return body?.code === "SUCCESS" && Array.isArray(body.list) ? body : null;
}

export function normalizeUnit(row) {
  const code = text(row?.unitCode), name = text(row?.unitName);
  const lat = Number(text(row?.yValue)), lng = Number(text(row?.xValue));
  if (!UNIT_CODE.test(code) || !name || !(Math.abs(lat) <= 90) || !(Math.abs(lng) <= 180) || (lat === 0 && lng === 0)) return null;
  return { code, name: name.slice(0, 40), route: text(row?.routeName).slice(0, 40), routeNo: text(row?.routeNo).slice(0, 8), lat, lng };
}

// 포털이 위치를 주지 않은 영업소(코드·이름은 맞고 좌표가 비었거나 0). 카카오로 채울 후보다.
export function unitWithoutLocation(row) {
  const code = text(row?.unitCode), name = text(row?.unitName);
  if (!UNIT_CODE.test(code) || !name || normalizeUnit(row)) return null;
  return { code, name: name.slice(0, 40), route: text(row?.routeName).slice(0, 40), routeNo: text(row?.routeNo).slice(0, 8) };
}

// 카카오 장소 검색 결과 중 영업소로 볼 만한 것: 이름이 들어 있고 영업소·IC·고속도로·교통 장소이며 한국 안 좌표.
export function pickPlace(documents, name) {
  const plain = name.replace(UNIT_WORD, "").trim() || name;
  for (const doc of Array.isArray(documents) ? documents : []) {
    const placeName = text(doc?.place_name), lat = Number(doc?.y), lng = Number(doc?.x);
    if (!placeName.includes(plain) || !UNIT_PLACE.test(`${placeName} ${text(doc?.category_name)}`)) continue;
    if (lat >= 33 && lat <= 39 && lng >= 124 && lng <= 132) return { lat, lng, place: placeName.slice(0, 60) };
  }
  return null;
}

async function searchPlace(fetcher, key, query) {
  const target = new URL(KAKAO_PLACE_URL);
  target.searchParams.set("query", query);
  target.searchParams.set("size", "5");
  try {
    const upstream = await fetcher(target, { headers: { authorization: `KakaoAK ${key}` } });
    return upstream.ok ? (await upstream.json()).documents ?? [] : null;
  } catch { return null; }
}

// 이름 하나의 좌표. 저장소에 있으면 거기서, 없으면 카카오에 묻는다(검색 한도 안에서). 못 물었으면 undefined(다음에 다시).
async function locate(unit, env, fetcher, budget) {
  const limit = geoCalls(env);
  const store = env.PLANS, cacheName = `geo:${unit.code}`;
  if (store) {
    try {
      const stored = JSON.parse((await store.get(cacheName)) ?? "null");
      if (stored) return stored.none ? null : stored;
    } catch { /* 저장소가 없어도 묻는다 */ }
  }
  const queries = UNIT_WORD.test(unit.name) ? [unit.name] : [`${unit.name}톨게이트`, `${unit.name}IC`];
  let asked = false;
  for (const query of queries) {
    if (budget.calls >= limit) return undefined;
    budget.calls += 1;
    const documents = await searchPlace(fetcher, env.KAKAO_REST_API_KEY, query);
    if (documents === null) return undefined;
    asked = true;
    const found = pickPlace(documents, unit.name);
    if (found) {
      if (store) { try { await store.put(cacheName, JSON.stringify(found), { expirationTtl: GEO_TTL }); } catch { /* 다음에 다시 */ } }
      return found;
    }
  }
  if (store) { try { await store.put(cacheName, JSON.stringify({ none: 1 }), { expirationTtl: GEO_MISS_TTL }); } catch { /* 다음에 다시 */ } }
  return null;
}

const methodOnlyGet = (request) => (request.method === "GET" ? null : json({ error: "method_not_allowed" }, 405));

export async function exUnits(request, env, fetcher = fetch, cache = globalThis.caches?.default) {
  const refused = methodOnlyGet(request);
  if (refused) return refused;
  if (!env.EX_API_KEY) return missingKey();
  const cacheKey = `${CACHE_ORIGIN}/units`;
  const hit = await cached(cache, cacheKey);
  if (hit) return reply(await hit.json(), UNITS_TTL);
  const first = await page(fetcher, "locationinfo/locationinfoUnit", { numOfRows: String(PAGE_ROWS), pageNo: "1" }, env.EX_API_KEY);
  if (!first) return upstreamFailed();
  const pages = Math.min(MAX_PAGES, Math.max(1, Math.ceil(Number(first.count ?? 0) / PAGE_ROWS) || 1));
  const rows = [...first.list];
  for (let number = 2; number <= pages; number += 1) {
    const next = await page(fetcher, "locationinfo/locationinfoUnit", { numOfRows: String(PAGE_ROWS), pageNo: String(number) }, env.EX_API_KEY);
    // 한 쪽이라도 빠지면 반쪽 목록을 오래 캐시하지 않게 실패로 둔다.
    if (!next) return upstreamFailed();
    rows.push(...next.list);
  }
  const units = [], seen = new Set(), missing = [];
  for (const row of rows) {
    const unit = normalizeUnit(row);
    if (!unit) {
      const bare = unitWithoutLocation(row);
      if (bare && !missing.some((item) => item.code === bare.code)) missing.push(bare);
      continue;
    }
    if (seen.has(unit.code)) continue;
    seen.add(unit.code);
    units.push(unit);
  }
  if (units.length === 0) return upstreamFailed();
  // 고정표(PREFIX_UNITS)가 있으면 그 좌표를 먼저 쓴다(포털 값이 있는 코드는 포털이 앞선다).
  // 시험은 `env.EX_PREFIX_UNITS`(배열)로 실제 고정표 대신 자기 표를 넣는다. 운영 환경 변수는 문자열이라 배열이 아니다.
  for (const fixed of Array.isArray(env.EX_PREFIX_UNITS) ? env.EX_PREFIX_UNITS : PREFIX_UNITS) {
    if (seen.has(fixed.code)) continue;
    seen.add(fixed.code);
    units.push({ ...fixed });
  }
  // 위치 없는 영업소는 카카오 장소 검색으로 채운다. 이번에 다 못 물으면 짧게만 캐시해 다음 요청이 이어서 채운다.
  let pending = 0, located = 0;
  const unlocated = [];
  if (env.KAKAO_REST_API_KEY && missing.length) {
    const budget = { calls: 0 };
    for (const bare of missing) {
      if (seen.has(bare.code)) continue;
      const found = await locate(bare, env, fetcher, budget);
      if (found === undefined) { pending += 1; continue; }
      if (!found) { unlocated.push({ code: bare.code, name: bare.name }); continue; }
      seen.add(bare.code);
      units.push({ ...bare, lat: found.lat, lng: found.lng, geo: "kakao" });
      located += 1;
    }
  }
  const body = { units, count: units.length, ...(located ? { located } : {}), ...(pending ? { pending } : {}), ...(env.EX_GEO_REPORT ? { unlocated } : {}) };
  const ttl = pending ? PARTIAL_UNITS_TTL : UNITS_TTL;
  await keep(cache, cacheKey, body, ttl);
  return reply(body, ttl);
}

export function normalizeFare(row, car) {
  const raw = text(row?.[`nrmlKnd${car}Amt`]), amount = Number(raw);
  if (!raw || !Number.isFinite(amount) || amount < 0) return null;
  const km = ["crgw2SumDstne", "crgw4SumDstne", "crgw6SumDstne"].reduce((sum, name) => sum + (Number(text(row?.[name])) || 0), 0);
  return {
    from: text(row?.dprtrTolofCd), fromName: text(row?.dprtrTolofNm).slice(0, 40),
    to: text(row?.arrvTolofCd), toName: text(row?.arrvTolofNm).slice(0, 40),
    operator: text(row?.hoinstNm).slice(0, 40), normal: amount, distanceKm: Math.round(km * 1000) / 1000,
  };
}

export async function exFare(request, env, fetcher = fetch, cache = globalThis.caches?.default) {
  const refused = methodOnlyGet(request);
  if (refused) return refused;
  const query = new URL(request.url).searchParams;
  const from = (query.get("from") ?? "").trim(), to = (query.get("to") ?? "").trim(), car = query.get("car") ?? "1";
  if (!UNIT_CODE.test(from) || !UNIT_CODE.test(to) || !/^[1-8]$/.test(car)) return json({ error: "bad_query" }, 400);
  if (!env.EX_API_KEY) return missingKey();
  const cacheKey = `${CACHE_ORIGIN}/fare?from=${from}&to=${to}&car=${car}`;
  const hit = await cached(cache, cacheKey);
  if (hit) return reply(await hit.json(), FARE_TTL);
  const found = await page(fetcher, "toll/bhoinstIntoTollList", { dprtrTolofCd: from, arrvTolofCd: to, numOfRows: "20", pageNo: "1" }, env.EX_API_KEY);
  if (!found) return upstreamFailed();
  // 다른 영업소가 섞여 오면 버린다(이름 검색처럼 넓게 돌려주는 경우를 막는다).
  // 0건은 「요금을 모름」이다(개방식 일부 구간·민자 노선). 앱은 확실하지 않음으로 본다.
  const fares = found.list.map((row) => normalizeFare(row, car)).filter((fare) => fare && fare.from === from && fare.to === to);
  const body = { from, to, car: Number(car), fares };
  await keep(cache, cacheKey, body, FARE_TTL);
  return reply(body, FARE_TTL);
}
