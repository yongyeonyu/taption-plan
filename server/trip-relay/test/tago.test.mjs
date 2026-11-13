import assert from "node:assert/strict";
import test from "node:test";
import { tagoProxy } from "../src/index.js";

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
