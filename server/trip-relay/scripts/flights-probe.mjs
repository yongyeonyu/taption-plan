// FLT1119A01: 공공데이터 항공편 API의 실제 응답 칸 이름을 확인한다. 대표가 키를 받은 뒤 한 번 돌린다.
//
//   ICN_API_KEY=<키> node scripts/flights-probe.mjs icnSchedule dep
//   ICN_API_KEY=<키> node scripts/flights-probe.mjs icnStatus arr
//   KAC_API_KEY=<키> node scripts/flights-probe.mjs kacSchedule dep GMP
//
// - 키는 환경 변수로만 받고 출력·로그에 찍지 않는다. 주소도 키를 뺀 모양만 보여 준다.
// - 값은 보여 주지 않는다: 응답 줄(item)의 칸 이름, 줄 수, 결과 코드, 그리고 `src/flights.js`가 기대하는 칸 중
//   어느 것이 응답에 있는지/없는지만 적는다. 없는 칸이 있으면 `FIELD`의 후보 이름이나 `SOURCES`의 운항 조회 이름을 고친다.
import { FIELD, SOURCES } from "../src/flights.js";

const [name, direction = "dep", airport = ""] = process.argv.slice(2);
const source = SOURCES[name];
if (!source || !["dep", "arr"].includes(direction)) {
  console.error(`사용: node scripts/flights-probe.mjs <${Object.keys(SOURCES).join("|")}> <dep|arr> [공항 코드]`);
  process.exit(2);
}
const key = process.env[source.key];
if (!key) {
  console.error(`환경 변수 ${source.key}가 없습니다.`);
  process.exit(2);
}

const target = new URL(source.base + source[direction]);
const params = { pageNo: "1", numOfRows: "5", type: "json", lang: "E" };
if (name === "icnStatus") {
  const today = new Date(Date.now() + 9 * 3_600_000).toISOString().slice(0, 10).replace(/-/g, "");
  Object.assign(params, { searchday: today, from_time: "0000", to_time: "2359" });
}
if (airport) params.airport = airport.toUpperCase();
for (const [k, v] of Object.entries(params)) target.searchParams.set(k, v);
console.log(`요청: ${target.origin}${target.pathname}?${[...target.searchParams.keys()].join("&")}  (키는 serviceKey로 붙이되 출력하지 않음)`);
target.searchParams.set("serviceKey", key);

let response;
try {
  response = await fetch(target, { headers: { "user-agent": "Mozilla/5.0 (compatible; TaptionTripRelay/1.0)", accept: "application/json" } });
} catch {
  console.error("연결 실패");
  process.exit(1);
}
console.log(`HTTP ${response.status}`);
let body;
try { body = await response.json(); } catch {
  console.error("JSON이 아닌 응답(xml일 수 있음 또는 키 오류). 본문은 키가 섞일 수 있어 출력하지 않습니다.");
  process.exit(1);
}
const inner = body?.response;
console.log(`결과 코드: ${inner?.header?.resultCode ?? "(없음)"}  전체 수: ${inner?.body?.totalCount ?? "(없음)"}`);
const items = inner?.body?.items;
const list = Array.isArray(items) ? items : Array.isArray(items?.item) ? items.item : items?.item ? [items.item] : [];
console.log(`줄 수(요청 5): ${list.length}`);
const names = [...new Set(list.flatMap((row) => Object.keys(row ?? {})))];
console.log(`응답 칸 이름: ${names.join(", ") || "(없음)"}`);
const lower = new Set(names.map((n) => n.toLowerCase()));
for (const [field, candidates] of Object.entries(FIELD)) {
  const found = candidates.filter((c) => lower.has(c));
  console.log(`${field.padEnd(13)} ${found.length ? "있음 → " + found.join(", ") : "없음 (후보: " + candidates.join(", ") + ")"}`);
}
