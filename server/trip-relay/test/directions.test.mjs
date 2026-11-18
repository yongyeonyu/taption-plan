import assert from "node:assert/strict";
import test from "node:test";
import { kakaoDirections, parseDirections } from "../src/directions.js";

// KDR1118A01: 도로공사로 통행료를 모를 때만 쓰는 카카오 길찾기 중계. 좌표는 본문으로만 받고 저장하지 않는다. 값은 모두 가짜다.
const env = { KAKAO_REST_API_KEY: "secret" };
const post = (body, path = "/kakao/directions") => new Request(`https://relay.example.com${path}`, {
  method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body),
});
const route = {
  result_code: 0,
  summary: { fare: { taxi: 30000, toll: 6600 }, distance: 40123, duration: 2400 },
  sections: [
    { roads: [{ name: "가짜대로", vertexes: [20.1, 10.1, 20.2, 10.2] }, { name: "가짜고속도로", vertexes: [20.3, 10.3] }] },
    { roads: [{ name: "가짜고속도로", vertexes: [] }, { name: "", vertexes: [] }, { name: "가짜로", vertexes: [] }] },
  ],
};
const origin = { lat: 10.1, lng: 20.1 }, destination = { lat: 10.4, lng: 20.4 };

test("directions sends lng,lat with the server key and returns only toll, distance, time and road names", async () => {
  let seen, auth;
  const fetcher = async (url, init) => { seen = new URL(url); auth = init?.headers?.authorization; return new Response(JSON.stringify({ routes: [route] })); };
  const response = await kakaoDirections(post({ origin, destination, waypoints: [{ lat: 10.2, lng: 20.2 }, { lat: 10.3, lng: 20.3 }] }), env, fetcher);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { found: true, toll: 6600, distance: 40123, duration: 2400, roads: ["가짜대로", "가짜고속도로", "가짜로"] });
  assert.equal(seen.origin + seen.pathname, "https://apis-navi.kakaomobility.com/v1/directions");
  assert.equal(seen.searchParams.get("origin"), "20.100000,10.100000", "카카오는 경도,위도");
  assert.equal(seen.searchParams.get("destination"), "20.400000,10.400000");
  assert.equal(seen.searchParams.get("waypoints"), "20.200000,10.200000|20.300000,10.300000");
  assert.equal(seen.searchParams.get("car_type"), "1");
  assert.equal(auth, "KakaoAK secret");
  assert.equal(response.headers.get("cache-control"), "no-store", "좌표가 든 요청의 답을 캐시하지 않는다");
});

test("directions refuses GET, bad points, too many waypoints, and a missing key", async () => {
  const fetcher = async () => { throw new Error("부르면 안 된다"); };
  assert.equal((await kakaoDirections(new Request("https://relay.example.com/kakao/directions?origin=1,2"), env, fetcher)).status, 405, "좌표를 주소에 싣지 않는다");
  assert.equal((await kakaoDirections(post({ origin, destination: { lat: 200, lng: 20 } }), env, fetcher)).status, 400);
  assert.equal((await kakaoDirections(post({ origin }), env, fetcher)).status, 400);
  const six = Array.from({ length: 6 }, (_, i) => ({ lat: 10 + i / 10, lng: 20 + i / 10 }));
  assert.equal((await kakaoDirections(post({ origin, destination, waypoints: six }), env, fetcher)).status, 400, "경유지는 최대 5개");
  assert.equal((await kakaoDirections(post({ origin, destination }), {}, fetcher)).status, 503);
});

test("directions hides upstream failures and reports a route it could not find", async () => {
  const failing = async () => new Response("secret upstream detail 10.1,20.1", { status: 500 });
  const failed = await kakaoDirections(post({ origin, destination }), env, failing);
  assert.equal(failed.status, 502);
  assert.equal((await failed.text()).includes("10.1"), false, "상류 원문(좌표가 섞일 수 있음)을 돌려주지 않는다");
  const throwing = async () => { throw new Error("10.1,20.1"); };
  assert.equal((await kakaoDirections(post({ origin, destination }), env, throwing)).status, 502);
  const none = async () => new Response(JSON.stringify({ routes: [{ result_code: 104, result_msg: "too close" }] }));
  assert.deepEqual(await (await kakaoDirections(post({ origin, destination }), env, none)).json(), { found: false });
  assert.equal(parseDirections({}), null);
  assert.equal(parseDirections({ routes: [{ ...route, summary: { fare: {} } }] }).toll, 0, "통행료가 없으면 0원");
});
