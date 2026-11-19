// KDR1118A01: 카카오 길찾기 응답의 통행료(`routes[0].summary.fare.toll`)를 직접 확인한다. 중계 서버 코드(`parseDirections`)를 그대로 쓴다.
// 키는 환경 변수 `KAKAO_REST_API_KEY`로만 받고 출력하지 않는다. 좌표는 이 터미널 밖으로 나가지 않는다(카카오에만 보낸다).
//
//   KAKAO_REST_API_KEY=... node scripts/kakao-toll-check.mjs --origin "인천국제공항" --dest "청라IC" [--via "장소 이름" ...] [--car-type 1]
//     (장소는 이름이나 「위도,경도」. 이름은 카카오 장소 검색의 첫 결과를 쓴다)
//   KAKAO_REST_API_KEY=... node scripts/kakao-toll-check.mjs --raw 원본.json --day 0 --drive 1     # 원본의 실제 이동으로(좌표를 입력·출력하지 않는다)
//   node scripts/kakao-toll-check.mjs --raw 원본.json --list                                       # 이동 목록만(키 없이)
//
// 확인할 것: (1) 이미 아는 요금(예: 대표가 낸 금액)과 `toll`이 같은지 (2) 출퇴근 할인 시간대에 불러도 `toll`이 정상요금인지
// (3) 민자 도로(공항고속도로 등)가 `toll`에 들어 있는지 (4) 지난 도로 이름이 실제 길과 맞는지.
import { readFileSync } from "node:fs";
import { parseDirections } from "../src/directions.js";

const args = process.argv.slice(2);
const values = (name) => args.flatMap((a, i) => (a === name ? [args[i + 1]] : []));
const pair = (text) => { const [lat, lng] = String(text).split(",").map(Number); return Number.isFinite(lat) && Number.isFinite(lng) ? { lat, lng } : null; };
const xy = ({ lat, lng }) => `${lng.toFixed(6)},${lat.toFixed(6)}`;

const REFERENCE = 978307200; // 앱 원본의 시각은 2001-01-01 기준 초
const clock = (seconds) => new Date((seconds + REFERENCE) * 1000 + 9 * 3_600_000).toISOString().slice(5, 16).replace("T", " ");

// 원본 JSON의 자동차 이동(1km 넘는 것)에서 출발·도착·경유지 5개를 앱과 같은 방식으로 뽑는다.
function fromRaw(path, dayIndex, driveIndex, list) {
  const days = JSON.parse(readFileSync(path, "utf8"));
  const day = days[dayIndex];
  const drives = (day?.travel ?? []).filter((t) => t.mode === "car" && t.distanceMeters > 1000);
  if (list) drives.forEach((t, i) => console.log(`day ${dayIndex} drive ${i}: ${clock(t.span.start)} → ${clock(t.span.end)} KST, ${(t.distanceMeters / 1000).toFixed(1)}km`));
  const trip = drives[driveIndex];
  if (!trip) return null;
  const fixes = day.readings
    .filter((r) => r.point && r.timestamp >= trip.span.start && r.timestamp <= trip.span.end && r.locationFixQuality !== "approximate"
      && r.point.horizontalAccuracy >= 0 && r.point.horizontalAccuracy <= 100)
    .sort((a, b) => a.timestamp - b.timestamp)
    .map((r) => ({ lat: r.point.latitude, lng: r.point.longitude }));
  if (fixes.length < 2) return null;
  const pick = (n) => Array.from({ length: n }, (_, i) => fixes[Math.round(((i + 1) / (n + 1)) * (fixes.length - 1))]);
  if (!list || driveIndex !== 0 || process.argv.includes("--drive")) console.log(`이동: ${clock(trip.span.start)} → ${clock(trip.span.end)} KST, ${(trip.distanceMeters / 1000).toFixed(1)}km, 위치 ${fixes.length}개, 경유지 5개`);
  return { origin: fixes[0], destination: fixes[fixes.length - 1], via: pick(5) };
}

const rawPath = values("--raw")[0];
const key = process.env.KAKAO_REST_API_KEY;

// 「위도,경도」면 그대로, 아니면 카카오 장소 검색(키워드)의 첫 결과로 좌표를 구한다.
async function place(text) {
  const direct = pair(text);
  if (direct || !text) return direct;
  const search = new URL("https://dapi.kakao.com/v2/local/search/keyword.json");
  search.searchParams.set("query", text);
  search.searchParams.set("size", "1");
  const reply = await fetch(search, { headers: { authorization: `KakaoAK ${key}` } });
  const hit = reply.ok ? (await reply.json()).documents?.[0] : null;
  if (!hit) { console.error(`장소를 찾지 못했습니다: ${text}`); return null; }
  console.log(`장소 「${text}」 → ${hit.place_name} (${hit.address_name})`);
  return { lat: Number(hit.y), lng: Number(hit.x) };
}

let origin, destination, via;
if (rawPath) {
  const picked = fromRaw(rawPath, Number(values("--day")[0] ?? 0), Number(values("--drive")[0] ?? 0), args.includes("--list"));
  if (args.includes("--list") && !values("--drive").length) process.exit(0);
  if (!picked) { console.error("그 이동을 찾지 못했습니다. --list로 번호를 확인하세요."); process.exit(2); }
  ({ origin, destination, via } = picked);
} else if (key) {
  origin = await place(values("--origin")[0]);
  destination = await place(values("--dest")[0]);
  via = [];
  for (const text of values("--via")) via.push(await place(text));
}
if (!key || !origin || !destination || via.some((v) => !v)) {
  console.error("사용법: KAKAO_REST_API_KEY=실제키 node scripts/kakao-toll-check.mjs --raw 원본.json --day 0 --drive 1");
  console.error("   또는: KAKAO_REST_API_KEY=실제키 node scripts/kakao-toll-check.mjs --origin \"인천국제공항\" --dest \"청라IC\" [--via \"장소 이름\" ...]");
  process.exit(2);
}
const url = new URL("https://apis-navi.kakaomobility.com/v1/directions");
url.searchParams.set("origin", xy(origin));
url.searchParams.set("destination", xy(destination));
if (via.length) url.searchParams.set("waypoints", via.map(xy).join("|"));
url.searchParams.set("car_type", values("--car-type")[0] ?? "1");
url.searchParams.set("summary", "false");
const response = await fetch(url, { headers: { authorization: `KakaoAK ${key}` } });
if (!response.ok) { console.error(`카카오 응답 ${response.status}`); process.exit(1); }
const body = await response.json();
const route = body.routes?.[0];
console.log("원문 fare:", JSON.stringify(route?.summary?.fare ?? null));
console.log("앱이 읽는 값:", JSON.stringify(parseDirections(body)));
