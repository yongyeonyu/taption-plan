// FLT1119A01: `/flights/*`가 인증·IP 한도·서버 전체 하루 예산을 거쳐 상류까지 가는지(index.js 연결) 확인한다. 값은 모두 가짜다.
import assert from "node:assert/strict";
import test from "node:test";
import { handle } from "../src/index.js";
import { makeEnv } from "./fakes.mjs";

const ORIGIN = "https://relay.example.com";
const randomKey = () => Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64url");
const req = (path, method = "GET", body, key) => new Request(`${ORIGIN}${path}`, {
  method,
  headers: { ...(key ? { authorization: `Bearer ${key}` } : {}), "content-type": "application/json" },
  body: body === undefined ? undefined : JSON.stringify(body),
});
const send = (env, ...args) => handle(req(...args), env);
const item = { flightId: "AB123", airportCode: "BKK", st: "0905", sunday: "Y", monday: "Y", tuesday: "Y", wednesday: "Y", thursday: "Y", friday: "Y", saturday: "Y" };
const upstream = (calls) => async (url) => {
  calls.push(new URL(url));
  return new Response(JSON.stringify({ response: { header: { resultCode: "00" }, body: { items: { item: [item] }, totalCount: 1 } } }), { status: 200 });
};
const schedule = (date) => `/flights/schedule?airport=ICN&date=${date}&direction=dep`;

test("flights routes need a search key and reach upstream through the relay", async () => {
  const calls = [];
  const { env } = makeEnv({ ICN_API_KEY: "icn-secret", FETCH: upstream(calls), NOW: () => Date.UTC(2027, 2, 7, 3, 0) });
  const key = randomKey();
  assert.equal((await send(env, schedule("2027-03-07"))).status, 401, "키 없이는 받지 않는다");
  await send(env, "/register", "POST", { purpose: "search" }, key);
  const response = await send(env, schedule("2027-03-07"), "GET", undefined, key);
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.source, "season");
  assert.deepEqual(body.flights.map((flight) => flight.flight), ["AB123"]);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].searchParams.get("serviceKey"), "icn-secret");
  const status = await send(env, "/flights/status?airport=GMP&date=2027-03-07&direction=dep", "GET", undefined, key);
  assert.equal(status.status, 200);
  assert.equal((await status.json()).available, false);
});

test("flights routes return 503 flight_key_missing when the secret is not set", async () => {
  const { env } = makeEnv({ FETCH: upstream([]) });
  const key = randomKey();
  await send(env, "/register", "POST", { purpose: "search" }, key);
  const response = await send(env, schedule("2027-03-07"), "GET", undefined, key);
  assert.equal(response.status, 503);
  assert.equal((await response.json()).error, "flight_key_missing");
});

test("the server-wide daily upstream budget stops calls with 429 and a Retry-After", async () => {
  const calls = [];
  const { env } = makeEnv({ ICN_API_KEY: "icn-secret", FLIGHT_DAILY_CALLS: "2", FETCH: upstream(calls) });
  const key = randomKey();
  await send(env, "/register", "POST", { purpose: "search" }, key);
  assert.equal((await send(env, schedule("2027-03-07"), "GET", undefined, key)).status, 200);
  assert.equal((await send(env, schedule("2027-03-08"), "GET", undefined, key)).status, 200);
  const capped = await send(env, schedule("2027-03-09"), "GET", undefined, key);
  assert.equal(capped.status, 429);
  assert.equal((await capped.json()).error, "flight_daily_limit");
  assert.ok(Number(capped.headers.get("retry-after")) > 0);
  assert.equal(calls.length, 2, "예산이 끝난 뒤에는 상류를 부르지 않는다");
});
