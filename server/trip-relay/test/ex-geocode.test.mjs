import assert from "node:assert/strict";
import test from "node:test";
import { exUnits, pickPlace, unitWithoutLocation } from "../src/expressway.js";

// TGT1119A03: 포털에 위치가 없는 영업소를 카카오 장소 검색으로 채운다. 이름·좌표·키는 모두 가짜다.
const get = () => new Request("https://relay.example.com/ex/units");
const ok = (body) => new Response(JSON.stringify(body), { status: 200 });
const row = (code, name, lat, lng) => ({ unitCode: code, unitName: name, routeName: "가짜선", routeNo: "999", xValue: lng === null ? "" : String(lng), yValue: lat === null ? "" : String(lat) });
const place = (name, category, y, x) => ({ place_name: name, category_name: category, y: String(y), x: String(x) });
const TOLL = "교통,수송 > 도로시설 > 톨게이트";

function relay({ rows, kakao }) {
  const calls = { kakao: [], ex: 0 };
  const fetcher = async (url, init) => {
    const target = new URL(url);
    if (target.hostname === "dapi.kakao.com") {
      assert.equal(init.headers.authorization, "KakaoAK kakao-secret");
      const query = target.searchParams.get("query");
      calls.kakao.push(query);
      return ok({ documents: kakao[query] ?? [] });
    }
    calls.ex += 1;
    return ok({ code: "SUCCESS", count: rows.length, list: rows });
  };
  return { fetcher, calls };
}
const fakeStore = () => { const map = new Map(); return { map, async get(k) { return map.get(k) ?? null; }, async put(k, v) { map.set(k, v); } }; };
const env = (extra = {}) => ({ EX_API_KEY: "secret", KAKAO_REST_API_KEY: "kakao-secret", EX_PREFIX_UNITS: [], ...extra });

test("a unit without a location is found through Kakao place search and added", async () => {
  const { fetcher, calls } = relay({
    rows: [row("901", "가짜북", 10.1, 20.1), row("951", "가짜청", null, null)],
    kakao: { "가짜청톨게이트": [place("가짜청톨게이트", TOLL, 37.5, 126.6)] },
  });
  const body = await (await exUnits(get(), env(), fetcher, null)).json();
  assert.deepEqual(body.units.map((unit) => unit.code), ["901", "951"]);
  assert.deepEqual(body.units[1], { code: "951", name: "가짜청", route: "가짜선", routeNo: "999", lat: 37.5, lng: 126.6, geo: "kakao" });
  assert.equal(body.located, 1);
  assert.deepEqual(calls.kakao, ["가짜청톨게이트"], "이름만 보낸다: 사용자 값은 없다");
});

test("a wrong place is refused, IC is tried next, and a miss is remembered", async () => {
  const store = fakeStore();
  const { fetcher, calls } = relay({
    rows: [row("901", "가짜북", 10.1, 20.1), row("951", "가짜청", null, null)],
    kakao: { "가짜청톨게이트": [place("가짜청 치킨", "음식점 > 치킨", 37.5, 126.6)], "가짜청IC": [place("가짜청 무관", "음식점", 37.5, 126.6)] },
  });
  const first = await (await exUnits(get(), { ...env(), PLANS: store }, fetcher, null)).json();
  assert.deepEqual(first.units.map((unit) => unit.code), ["901"], "엉뚱한 장소(치킨집)는 영업소 좌표로 쓰지 않는다");
  assert.deepEqual(calls.kakao, ["가짜청톨게이트", "가짜청IC"]);
  assert.deepEqual(JSON.parse(store.map.get("geo:951")), { none: 1 }, "못 찾은 것도 저장해 다시 묻지 않는다");
  await exUnits(get(), { ...env(), PLANS: store }, fetcher, null);
  assert.equal(calls.kakao.length, 2, "두 번째는 저장된 「없음」을 쓴다");
});

test("a found place is stored and reused without asking Kakao again", async () => {
  const store = fakeStore();
  const { fetcher, calls } = relay({
    rows: [row("901", "가짜북", 10.1, 20.1), row("951", "가짜청IC", null, null)],
    kakao: { "가짜청IC": [place("가짜청IC", "교통,수송 > 도로시설 > IC", 37.5, 126.6)] },
  });
  await exUnits(get(), { ...env(), PLANS: store }, fetcher, null);
  assert.deepEqual(calls.kakao, ["가짜청IC"], "이름에 IC가 있으면 그 이름 그대로 한 번");
  assert.equal(JSON.parse(store.map.get("geo:951")).lat, 37.5);
  const again = await (await exUnits(get(), { ...env(), PLANS: store }, fetcher, null)).json();
  assert.equal(calls.kakao.length, 1);
  assert.equal(again.units.find((unit) => unit.code === "951").lng, 126.6);
});

test("search budget leaves a partial list with a short cache and a pending count", async () => {
  const rows = [row("901", "가짜북", 10.1, 20.1), ...["951", "952", "953"].map((code, i) => row(code, `가짜${i}IC`, null, null))];
  const kakao = Object.fromEntries([0, 1, 2].map((i) => [`가짜${i}IC`, [place(`가짜${i}IC`, "교통 > IC", 37 + i / 10, 126.6)]]));
  const { fetcher, calls } = relay({ rows, kakao });
  const response = await exUnits(get(), env({ EX_GEO_CALLS: "2" }), fetcher, null);
  const body = await response.json();
  assert.equal(calls.kakao.length, 2);
  assert.equal(body.located, 2);
  assert.equal(body.pending, 1);
  assert.match(response.headers.get("cache-control"), /max-age=3600/, "남은 것이 있으면 짧게만 캐시");
  const done = await exUnits(get(), env({ EX_GEO_CALLS: "10" }), fetcher, null);
  assert.equal((await done.json()).pending, undefined);
  assert.match(done.headers.get("cache-control"), /max-age=604800/);
});

test("without a Kakao key nothing is searched and units without a location stay out", async () => {
  const { fetcher, calls } = relay({ rows: [row("901", "가짜북", 10.1, 20.1), row("951", "가짜청", null, null)], kakao: {} });
  const body = await (await exUnits(get(), { EX_API_KEY: "secret", EX_PREFIX_UNITS: [] }, fetcher, null)).json();
  assert.deepEqual(body.units.map((unit) => unit.code), ["901"]);
  assert.equal(calls.kakao.length, 0);
});

test("the report of units Kakao could not find is only given when asked for", async () => {
  const { fetcher } = relay({ rows: [row("901", "가짜북", 10.1, 20.1), row("951", "가짜청", null, null)], kakao: {} });
  assert.equal((await (await exUnits(get(), env(), fetcher, null)).json()).unlocated, undefined);
  const report = await (await exUnits(get(), env({ EX_GEO_REPORT: "1" }), fetcher, null)).json();
  assert.deepEqual(report.unlocated, [{ code: "951", name: "가짜청" }]);
});

test("pickPlace and unitWithoutLocation keep to safe shapes", () => {
  assert.equal(unitWithoutLocation(row("901", "가짜북", 10.1, 20.1)), null, "위치가 있으면 대상이 아니다");
  assert.deepEqual(unitWithoutLocation(row("951", "가짜청", null, null)), { code: "951", name: "가짜청", route: "가짜선", routeNo: "999" });
  assert.equal(unitWithoutLocation(row("bad code!", "가짜청", null, null)), null);
  assert.equal(unitWithoutLocation(row("951", "", null, null)), null);
  assert.equal(pickPlace([place("다른곳 톨게이트", TOLL, 37.5, 126.6)], "가짜청"), null, "이름이 들어 있어야 한다");
  assert.equal(pickPlace([place("가짜청톨게이트", TOLL, 10, 20)], "가짜청"), null, "한국 밖 좌표는 버린다");
  assert.equal(pickPlace([place("가짜청 식당", "음식점", 37.5, 126.6)], "가짜청"), null, "영업소·IC 장소가 아니면 버린다");
  assert.deepEqual(pickPlace([place("가짜청 식당", "음식점", 37.5, 126.6), place("가짜청톨게이트", TOLL, 37.5, 126.6)], "가짜청톨게이트"), { lat: 37.5, lng: 126.6, place: "가짜청톨게이트" }, "첫 결과가 아니라 맞는 결과");
});

test("the shipped fixed table is merged after the portal list and a portal code wins over it", async () => {
  const { PREFIX_UNITS } = await import("../src/ex-unit-prefix.js");
  assert.ok(PREFIX_UNITS.length > 0, "고정표가 채워져 있다");
  assert.ok(PREFIX_UNITS.every((unit) => /^\d{3}$/.test(unit.code) && unit.lat >= 33 && unit.lat <= 39 && unit.lng >= 124 && unit.lng <= 132), "모두 한국 좌표");
  const fixed = PREFIX_UNITS[0];
  const { fetcher } = relay({ rows: [row("901", "가짜북", 10.1, 20.1), row(fixed.code, "포털이앞섬", 11.5, 21.5)], kakao: {} });
  const body = await (await exUnits(get(), { EX_API_KEY: "secret" }, fetcher, null)).json();
  const codes = body.units.map((unit) => unit.code);
  assert.equal(new Set(codes).size, codes.length, "코드는 한 번씩만");
  assert.equal(body.units.find((unit) => unit.code === fixed.code).lat, 11.5, "포털에 위치가 있으면 포털 값");
  assert.ok(body.units.length > 2, "고정표 항목이 더해졌다");
});
