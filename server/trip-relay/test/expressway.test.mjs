import assert from "node:assert/strict";
import test from "node:test";
import { exFare, exUnits, normalizeUnit } from "../src/expressway.js";

// TGT1118A01: 고속도로 영업소·통행료 중계. 키는 서버에서만 붙이고, 사용자 좌표는 받지 않는다. 값은 모두 가짜다.
const env = { EX_API_KEY: "secret" };
const get = (path) => new Request(`https://relay.example.com${path}`);
const ok = (body) => new Response(JSON.stringify(body), { status: 200 });
const unitRow = (code, name, lat, lng) => ({ unitCode: `${code} `, unitName: name, routeName: "가짜선", routeNo: "999", xValue: String(lng), yValue: String(lat), pageNo: null });

function memoryCache() {
  const map = new Map();
  return {
    map,
    async match(key) { const body = map.get(key); return body === undefined ? undefined : new Response(body); },
    async put(key, response) { map.set(key, await response.text()); },
  };
}

test("units gathers every page, trims codes, drops bad rows and duplicates", async () => {
  const seen = [];
  const pages = {
    1: [unitRow("901", "가짜북", 10.1, 20.1), unitRow("902", "가짜남", 10.2, 20.2)],
    2: [unitRow("901", "가짜북", 10.1, 20.1), unitRow("903", "", 10.3, 20.3), unitRow("904", "가짜동", 0, 0), unitRow("905", "가짜서", 10.5, 20.5),
        { ...unitRow("906", "가짜빈", 0, 0), xValue: "", yValue: "" }, { ...unitRow("907", "가짜없음", 0, 0), xValue: null, yValue: null }],
  };
  const agents = [];
  const fetcher = async (url, init) => {
    const target = new URL(url);
    seen.push(target);
    agents.push(init?.headers?.["user-agent"] ?? "");
    return ok({ code: "SUCCESS", count: 150, list: pages[target.searchParams.get("pageNo")] ?? [] });
  };
  const response = await exUnits(get("/ex/units?lat=1&lng=2"), env, fetcher, null);
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.deepEqual(body.units.map((unit) => unit.code), ["901", "902", "905"]);
  assert.deepEqual(body.units[0], { code: "901", name: "가짜북", route: "가짜선", routeNo: "999", lat: 10.1, lng: 20.1 });
  assert.equal(seen.length, 2, "count 150 / 99줄 = 2쪽");
  assert.equal(seen[0].searchParams.get("numOfRows"), "99", "포털 한도");
  assert.ok(agents.every((agent) => agent.startsWith("Mozilla/")), "도구 기본 User-Agent는 포털이 막는다");
  for (const target of seen) {
    assert.equal(target.pathname, "/openapi/locationinfo/locationinfoUnit");
    assert.equal(target.searchParams.get("key"), "secret");
    assert.equal(target.searchParams.get("type"), "json");
    assert.equal(target.searchParams.has("lat") || target.searchParams.has("lng"), false, "앱 쿼리를 상류로 넘기지 않는다");
  }
  assert.match(response.headers.get("cache-control"), /max-age=604800/);
});

test("units are cached and a missing page is a failure, not a half list", async () => {
  const cache = memoryCache();
  let calls = 0;
  const fetcher = async () => { calls += 1; return ok({ code: "SUCCESS", count: 1, list: [unitRow("901", "가짜북", 10.1, 20.1)] }); };
  assert.equal((await exUnits(get("/ex/units"), env, fetcher, cache)).status, 200);
  assert.equal((await exUnits(get("/ex/units"), env, fetcher, cache)).status, 200);
  assert.equal(calls, 1, "두 번째는 캐시에서");
  assert.equal([...cache.map.keys()].some((key) => key.includes("secret")), false, "캐시 열쇠에 키가 없다");

  const broken = async (url) => new URL(url).searchParams.get("pageNo") === "1"
    ? ok({ code: "SUCCESS", count: 250, list: [unitRow("901", "가짜북", 10.1, 20.1)] })
    : new Response("down", { status: 500 });
  const empty = memoryCache();
  assert.equal((await exUnits(get("/ex/units"), env, broken, empty)).status, 502);
  assert.equal(empty.map.size, 0);
});

test("fare asks by unit codes only and returns the normal fare for the car class", async () => {
  let seen;
  const fetcher = async (url) => {
    seen = new URL(url);
    return ok({ code: "SUCCESS", count: 2, list: [
      { dprtrTolofCd: "901", dprtrTolofNm: "가짜북", arrvTolofCd: "902", arrvTolofNm: "가짜남", hoinstNm: "가짜공사", nrmlKnd1Amt: "1200", nrmlKnd6Amt: "600", crgw2SumDstne: "0.000", crgw4SumDstne: "12.500", crgw6SumDstne: "1.250" },
      { dprtrTolofCd: "901", arrvTolofCd: "999", nrmlKnd1Amt: "5000" },
    ] });
  };
  const response = await exFare(get("/ex/fare?from=901&to=902&car=1"), env, fetcher, null);
  assert.equal(response.status, 200);
  assert.equal(seen.pathname, "/openapi/toll/bhoinstIntoTollList");
  assert.equal(seen.searchParams.get("dprtrTolofCd"), "901");
  assert.equal(seen.searchParams.get("arrvTolofCd"), "902");
  assert.equal(seen.searchParams.get("key"), "secret");
  const body = await response.json();
  assert.deepEqual(body, { from: "901", to: "902", car: 1, fares: [{ from: "901", fromName: "가짜북", to: "902", toName: "가짜남", operator: "가짜공사", normal: 1200, distanceKm: 13.75 }] },
    "다른 도착 영업소 줄은 버린다");
  const none = await (await exFare(get("/ex/fare?from=901&to=901"), env, async () => ok({ code: "SUCCESS", count: 0, list: [] }), null)).json();
  assert.deepEqual(none.fares, [], "0건은 요금을 모름");
  const compact = await (await exFare(get("/ex/fare?from=901&to=902&car=6"), env, fetcher, null)).json();
  assert.equal(compact.fares[0].normal, 600);
});

test("fare rejects bad input, and both routes say clearly when the key is missing", async () => {
  const fetcher = async () => ok({ code: "SUCCESS", list: [] });
  for (const path of ["/ex/fare?from=901&to=9;02", "/ex/fare?from=&to=902", "/ex/fare?from=901&to=902&car=9", "/ex/fare?from=1234567&to=902"]) {
    assert.equal((await exFare(get(path), env, fetcher, null)).status, 400, path);
  }
  for (const response of [await exUnits(get("/ex/units"), {}, fetcher, null), await exFare(get("/ex/fare?from=901&to=902"), {}, fetcher, null)]) {
    assert.equal(response.status, 503);
    assert.equal((await response.json()).error, "ex_key_missing");
  }
  const post = new Request("https://relay.example.com/ex/units", { method: "POST", body: "{}" });
  assert.equal((await exUnits(post, env, fetcher, null)).status, 405);
});

test("upstream failures and errors never echo the server key", async () => {
  const echo = async (url) => new Response(`error for ${url}`, { status: 500 });
  const thrower = async (url) => { throw new Error(`network failure ${url}`); };
  const refused = async () => ok({ code: "ERROR", message: "key secret invalid", list: [] });
  for (const fetcher of [echo, thrower, refused]) {
    for (const response of [await exUnits(get("/ex/units"), env, fetcher, null), await exFare(get("/ex/fare?from=901&to=902"), env, fetcher, null)]) {
      assert.equal(response.status, 502);
      assert.equal((await response.text()).includes("secret"), false);
    }
  }
});

test("normalizeUnit keeps longitude in xValue and latitude in yValue", () => {
  assert.deepEqual(normalizeUnit(unitRow("A1", "가짜", 11.5, 22.5)), { code: "A1", name: "가짜", route: "가짜선", routeNo: "999", lat: 11.5, lng: 22.5 });
  assert.equal(normalizeUnit(unitRow("901", "가짜", 95, 20)), null);
});
