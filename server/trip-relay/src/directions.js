// 카카오모빌리티 자동차 길찾기 중계(KDR1118A01). 도로공사 영업소 자료로 통행료를 알아내지 못한 자동차 이동만
// 앱이 묻는다(대표 결정 2026-11-18, AGENTS.md 좌표 예외 TGT1118A01).
// - POST /kakao/directions 본문 { origin:{lat,lng}, destination:{lat,lng}, waypoints:[{lat,lng}] (최대 5) }
// - 키는 기존 KAKAO_REST_API_KEY. 좌표는 본문으로만 받고 저장·기록하지 않는다(주소가 요청 로그에 남지 않게).
// - 돌려주는 것은 통행료·거리·시간·지난 도로 이름뿐이다. 길 좌표(vertexes)와 상류 원문은 넘기지 않는다.
import { json, readBody } from "./http.js";

const DIRECTIONS_URL = "https://apis-navi.kakaomobility.com/v1/directions";
const MAX_WAYPOINTS = 5;
const MAX_ROADS = 30;

const point = (value) => {
  const lat = Number(value?.lat), lng = Number(value?.lng);
  return Math.abs(lat) <= 90 && Math.abs(lng) <= 180 && !(lat === 0 && lng === 0) ? { lat, lng } : null;
};
// 카카오는 「경도,위도」 순서다. 소수 6자리(약 10cm)면 충분하다.
const xy = ({ lat, lng }) => `${lng.toFixed(6)},${lat.toFixed(6)}`;

export function parseDirections(body) {
  const route = Array.isArray(body?.routes) ? body.routes[0] : null;
  if (!route) return null;
  // 0이 아니면 길을 찾지 못한 것(출발·도착이 너무 가까움 등). 통행료를 모르는 것과 같다.
  if (route.result_code !== 0) return { found: false };
  const summary = route.summary ?? {};
  const toll = Number(summary.fare?.toll ?? 0);
  const roads = [];
  for (const section of Array.isArray(route.sections) ? route.sections : []) {
    for (const road of Array.isArray(section?.roads) ? section.roads : []) {
      const name = typeof road?.name === "string" ? road.name.trim().slice(0, 40) : "";
      if (name && !roads.includes(name) && roads.length < MAX_ROADS) roads.push(name);
    }
  }
  return {
    found: true,
    toll: Number.isFinite(toll) && toll >= 0 ? Math.round(toll) : 0,
    distance: Math.max(0, Math.round(Number(summary.distance) || 0)),
    duration: Math.max(0, Math.round(Number(summary.duration) || 0)),
    roads,
  };
}

export async function kakaoDirections(request, env, fetcher = fetch) {
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (!env.KAKAO_REST_API_KEY) return json({ error: "unavailable" }, 503);
  const body = await readBody(request);
  if (body.error) return body.error;
  const origin = point(body.value?.origin), destination = point(body.value?.destination);
  const rawWaypoints = Array.isArray(body.value?.waypoints) ? body.value.waypoints : [];
  const waypoints = rawWaypoints.map(point);
  if (!origin || !destination || rawWaypoints.length > MAX_WAYPOINTS || waypoints.some((value) => !value)) {
    return json({ error: "bad_query" }, 400);
  }
  const target = new URL(DIRECTIONS_URL);
  target.searchParams.set("origin", xy(origin));
  target.searchParams.set("destination", xy(destination));
  if (waypoints.length) target.searchParams.set("waypoints", waypoints.map(xy).join("|"));
  target.searchParams.set("car_type", "1");
  target.searchParams.set("summary", "false");
  let upstream, parsed;
  try { upstream = await fetcher(target, { headers: { authorization: `KakaoAK ${env.KAKAO_REST_API_KEY}` } }); } catch { return json({ error: "upstream_failed" }, 502); }
  if (!upstream.ok) return json({ error: "upstream_failed" }, 502);
  try { parsed = parseDirections(await upstream.json()); } catch { return json({ error: "upstream_failed" }, 502); }
  if (!parsed) return json({ error: "upstream_failed" }, 502);
  return json(parsed, 200, { "cache-control": "no-store" });
}
