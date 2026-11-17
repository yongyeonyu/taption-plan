import assert from "node:assert/strict";
import test from "node:test";
import { seoulBusProxy, tagoProxy } from "../src/index.js";

// BRT1113A01: 버스 노선 중계. 키는 서버에서만 붙이고, 허용한 값만 넘긴다.
test("tago proxy looks up nearby stops with the server key", async () => {
  let seen;
  const fetcher = async (url) => { seen = new URL(url); return new Response("{\"response\":{}}", { status: 200 }); };
  const response = await tagoProxy(new Request("https://relay.example.com/tago/stops?lat=37.53&lng=126.67&serviceKey=evil"), { TAGO_SERVICE_KEY: "secret" }, fetcher);
  assert.equal(response.status, 200);
  assert.equal(seen.pathname.endsWith("/getCrdntPrxmtSttnList"), true);
  assert.equal(seen.searchParams.get("gpsLati"), "37.53");
  assert.equal(seen.searchParams.get("gpsLong"), "126.67");
  assert.equal(seen.searchParams.get("serviceKey"), "secret");
  assert.equal(seen.searchParams.get("_type"), "json");
});

test("tago proxy lists routes through a stop and rejects bad input", async () => {
  let seen;
  const fetcher = async (url) => { seen = new URL(url); return new Response("{}", { status: 200 }); };
  const env = { TAGO_SERVICE_KEY: "secret" };
  assert.equal((await tagoProxy(new Request("https://relay.example.com/tago/routes?cityCode=23&nodeId=ICB164000123"), env, fetcher)).status, 200);
  assert.equal(seen.pathname.endsWith("/getSttnThrghRouteList"), true);
  assert.equal(seen.searchParams.get("nodeid"), "ICB164000123");
  assert.equal((await tagoProxy(new Request("https://relay.example.com/tago/routes?cityCode=23&nodeId=x;drop"), env, fetcher)).status, 400);
  assert.equal((await tagoProxy(new Request("https://relay.example.com/tago/stops?lat=200&lng=1"), env, fetcher)).status, 400);
  assert.equal((await tagoProxy(new Request("https://relay.example.com/tago/stops?lat=37&lng=127"), {}, fetcher)).status, 503, "키가 없으면 쓸 수 없음");
});

test("seoul bus proxy finds stops by position and routes by stop number", async () => {
  let seen;
  const fetcher = async (url) => { seen = new URL(url); return new Response("{}", { status: 200 }); };
  const env = { TAGO_SERVICE_KEY: "secret" };
  assert.equal((await seoulBusProxy(new Request("https://relay.example.com/seoul/stops?lat=37.56&lng=126.97"), env, fetcher)).status, 200);
  assert.equal(seen.pathname.endsWith("/getStationByPos"), true);
  assert.equal(seen.searchParams.get("tmX"), "126.97");
  assert.equal(seen.searchParams.get("resultType"), "json");
  assert.equal(seen.searchParams.get("serviceKey"), "secret");
  assert.equal((await seoulBusProxy(new Request("https://relay.example.com/seoul/routes?arsId=01234"), env, fetcher)).status, 200);
  assert.equal(seen.searchParams.get("arsId"), "01234");
  assert.equal((await seoulBusProxy(new Request("https://relay.example.com/seoul/routes?arsId=12"), env, fetcher)).status, 400);
  assert.equal((await seoulBusProxy(new Request("https://relay.example.com/seoul/stops?lat=37&lng=127"), {}, fetcher)).status, 503);
});

// REV1117A03(대표 결정 2026-11-17): 정류장 조회 좌표는 저장·기록하지 않는다. 주소(요청 로그)에 남지 않게 본문으로도 받고,
// 상류 실패·예외의 원문(좌표·서버 키가 섞일 수 있음)을 돌려주거나 던지지 않는다. 예전 앱의 GET은 그대로 받는다.
const post = (path, body) => new Request(`https://relay.example.com${path}`, {
  method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body),
});

test("stop lookups accept coordinates in a POST body so the URL carries none", async () => {
  let seen;
  const fetcher = async (url) => { seen = new URL(url); return new Response("{}", { status: 200 }); };
  const env = { TAGO_SERVICE_KEY: "secret" };
  assert.equal((await tagoProxy(post("/tago/stops", { lat: 37.5, lng: 127 }), env, fetcher)).status, 200);
  assert.equal(seen.searchParams.get("gpsLati"), "37.5");
  assert.equal(seen.searchParams.get("gpsLong"), "127");
  assert.equal((await seoulBusProxy(post("/seoul/stops", { lat: 37.5, lng: 127 }), env, fetcher)).status, 200);
  assert.equal(seen.searchParams.get("tmY"), "37.5");
  assert.equal((await tagoProxy(post("/tago/stops", { lat: "x", lng: 1 }), env, fetcher)).status, 400);
  assert.equal((await tagoProxy(post("/tago/routes", { cityCode: "23", nodeId: "ICB164000123" }), env, fetcher)).status, 405,
    "본문은 좌표를 받는 정류장 조회에만");
});

test("upstream failures never echo coordinates or the server key back", async () => {
  const env = { TAGO_SERVICE_KEY: "secret" };
  const echo = async (url) => new Response(`error for ${url}`, { status: 500 });
  const thrower = async (url) => { throw new Error(`network failure ${url}`); };
  for (const fetcher of [echo, thrower]) {
    for (const [proxy, path] of [[tagoProxy, "/tago/stops"], [seoulBusProxy, "/seoul/stops"]]) {
      const response = await proxy(post(path, { lat: 37.5, lng: 127 }), env, fetcher);
      assert.equal(response.status, 502);
      const text = await response.text();
      assert.equal(/37\.5|127|secret/.test(text), false, text);
    }
  }
});
