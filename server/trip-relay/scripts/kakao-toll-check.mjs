// KDR1118A01: 카카오 길찾기 응답의 통행료(`routes[0].summary.fare.toll`)를 직접 확인한다. 중계 서버 코드(`parseDirections`)를 그대로 쓴다.
// 키는 환경 변수 `KAKAO_REST_API_KEY`로만 받고 출력하지 않는다. 좌표는 이 터미널 밖으로 나가지 않는다(카카오에만 보낸다).
//
//   KAKAO_REST_API_KEY=... node scripts/kakao-toll-check.mjs --origin 위도,경도 --dest 위도,경도 [--via 위도,경도 ...] [--car-type 1]
//
// 확인할 것: (1) 이미 아는 요금(예: 대표가 낸 금액)과 `toll`이 같은지 (2) 출퇴근 할인 시간대에 불러도 `toll`이 정상요금인지
// (3) 민자 도로(공항고속도로 등)가 `toll`에 들어 있는지 (4) 지난 도로 이름이 실제 길과 맞는지.
import { parseDirections } from "../src/directions.js";

const args = process.argv.slice(2);
const values = (name) => args.flatMap((a, i) => (a === name ? [args[i + 1]] : []));
const pair = (text) => { const [lat, lng] = String(text).split(",").map(Number); return Number.isFinite(lat) && Number.isFinite(lng) ? { lat, lng } : null; };
const xy = ({ lat, lng }) => `${lng.toFixed(6)},${lat.toFixed(6)}`;

const key = process.env.KAKAO_REST_API_KEY;
const origin = pair(values("--origin")[0]), destination = pair(values("--dest")[0]);
const via = values("--via").map(pair);
if (!key || !origin || !destination || via.some((v) => !v)) {
  console.error("사용법: KAKAO_REST_API_KEY=... node scripts/kakao-toll-check.mjs --origin 위도,경도 --dest 위도,경도 [--via 위도,경도 ...] [--car-type 1]");
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
