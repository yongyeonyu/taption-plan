import assert from "node:assert/strict";
import test from "node:test";
import { handle, isSuccessfulPayload, upstreamURL } from "../src/index.js";

const ok = JSON.stringify({ response: { header: { resultCode: "00" }, body: { items: [{ pm10Value: "42" }] } } });
const env = { AIRKOREA_SERVICE_KEY: "secret-key" };

class MemoryCache {
  constructor() { this.map = new Map(); }
  async match(request) { return this.map.get(request.url)?.clone(); }
  async put(request, response) { this.map.set(request.url, response); }
}

function stubFetch(body = ok, status = 200) {
  const calls = [];
  const fn = async (url) => { calls.push(url); return new Response(body, { status }); };
  fn.calls = calls;
  return fn;
}

const get = (path) => new Request(`https://air.example.com${path}`);

test("measurement is fetched once per station and cached", async () => {
  const cache = new MemoryCache();
  const fetchImpl = stubFetch();
  const first = await handle(get("/airkorea/measurement?stationName=%EC%A2%85%EB%A1%9C%EA%B5%AC"), env, cache, fetchImpl);
  const second = await handle(get("/airkorea/measurement?stationName=%EC%A2%85%EB%A1%9C%EA%B5%AC"), env, cache, fetchImpl);
  assert.equal(first.status, 200);
  assert.equal(await second.text(), ok);
  assert.equal(fetchImpl.calls.length, 1);
  assert.match(first.headers.get("cache-control"), /max-age=1800/);
});

test("the service key is sent upstream but never returned", async () => {
  const fetchImpl = stubFetch();
  const response = await handle(get("/airkorea/stations"), env, new MemoryCache(), fetchImpl);
  assert.match(fetchImpl.calls[0], /serviceKey=secret-key/);
  assert.equal((await response.text()).includes("secret-key"), false);
});

test("invalid routes, methods and station names are rejected before any upstream call", async () => {
  const fetchImpl = stubFetch();
  const cases = [
    ["/other", 404], ["/airkorea/measurement", 400], ["/airkorea/measurement?stationName=", 400],
    ["/airkorea/measurement?stationName=a&stationName=b", 400], ["/airkorea/measurement?stationName=a&x=1", 400],
    ["/airkorea/measurement?stationName=%3Cscript%3E", 400], ["/airkorea/stations?pageNo=2", 404],
  ];
  for (const [path, status] of cases) {
    assert.equal((await handle(get(path), env, new MemoryCache(), fetchImpl)).status, status, path);
  }
  assert.equal((await handle(new Request("https://air.example.com/airkorea/stations", { method: "POST" }), env, new MemoryCache(), fetchImpl)).status, 405);
  assert.equal(fetchImpl.calls.length, 0);
});

test("upstream error bodies are not cached and become 502", async () => {
  const cache = new MemoryCache();
  const bad = JSON.stringify({ response: { header: { resultCode: "22", resultMsg: "LIMITED" } } });
  const response = await handle(get("/airkorea/measurement?stationName=A"), env, cache, stubFetch(bad));
  assert.equal(response.status, 502);
  assert.equal(cache.map.size, 0);
  assert.equal((await handle(get("/airkorea/measurement?stationName=A"), env, cache, stubFetch("x", 500))).status, 502);
});

test("a missing key reports not configured without calling upstream", async () => {
  const fetchImpl = stubFetch();
  assert.equal((await handle(get("/airkorea/stations"), {}, new MemoryCache(), fetchImpl)).status, 503);
  assert.equal(fetchImpl.calls.length, 0);
});

test("helpers", () => {
  assert.equal(isSuccessfulPayload("not json"), false);
  assert.equal(isSuccessfulPayload(ok), true);
  assert.match(upstreamURL("stations", "", "k").toString(), /numOfRows=1000/);
});
