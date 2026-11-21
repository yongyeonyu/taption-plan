// AI1121A01: Bedrock SigV4 서명·Converse 응답 읽기·`/ai/converse`의 한도(429)·민감정보 차단. 키는 모두 가짜이고 상류는 부르지 않는다.
import assert from "node:assert/strict";
import test from "node:test";
import { handle } from "../src/index.js";
import { canonicalUri, converse, converseUrl, signRequest } from "../src/bedrock.js";
import { readReply, redact, shapeCommand, shapeTrip } from "../src/assist.js";
import { makeEnv } from "./fakes.mjs";

// AWS SigV4 문서의 공개 예시 자격 증명(실제 계정이 아님)과 시험 묶음 get-vanilla·post-vanilla의 기대 서명.
const DOC_KEY = { accessKeyId: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY" };
const DOC_TIME = Date.UTC(2015, 7, 30, 12, 36, 0);
const FAKE = { AWS_ACCESS_KEY_ID: "TESTKEYID0000000", AWS_SECRET_ACCESS_KEY: "test-secret-not-a-real-key", AWS_REGION: "ap-northeast-2", AWS_BEDROCK_MODEL_ID: "apac.anthropic.fake-haiku-v1:0" };

const ORIGIN = "https://relay.example.com";
const randomKey = () => Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64url");
const req = (path, method = "GET", body, key) => new Request(`${ORIGIN}${path}`, {
  method,
  headers: { ...(key ? { authorization: `Bearer ${key}` } : {}), "content-type": "application/json" },
  body: body === undefined ? undefined : JSON.stringify(body),
});
const send = (env, ...args) => handle(req(...args), env);

// 가짜 Bedrock: 받은 요청을 적어 두고 정한 답을 준다.
function fakeBedrock(answer = toolAnswer({ reply: "네, 넣어 둘게요." })) {
  const calls = [];
  const fetcher = async (url, init) => {
    calls.push({ url: String(url), headers: init.headers, body: JSON.parse(init.body) });
    return typeof answer === "function" ? answer() : new Response(JSON.stringify(answer), { status: 200 });
  };
  return { calls, fetcher };
}
const toolAnswer = (input, usage = { inputTokens: 120, outputTokens: 40 }) => ({
  output: { message: { role: "assistant", content: [{ toolUse: { toolUseId: "t1", name: "bokki_reply", input } }] } },
  stopReason: "tool_use", usage,
});

async function owner(extra = {}) {
  const bedrock = extra.bedrock ?? fakeBedrock();
  const { env, clock } = makeEnv({ ...FAKE, FETCH: bedrock.fetcher, ...extra.env });
  const key = randomKey();
  await send(env, "/register", "POST", {}, key);
  return { env, clock, key, bedrock };
}
const talk = (env, key, text, more = {}) => send(env, "/ai/converse", "POST", { messages: [{ role: "user", text }], ...more }, key);

// MARK: 서명

test("SigV4 matches the AWS get-vanilla and post-vanilla test vectors", async () => {
  const get = await signRequest({ method: "GET", url: "https://example.amazonaws.com/", region: "us-east-1", service: "service", ...DOC_KEY, now: DOC_TIME });
  assert.equal(get.authorization, "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31");
  assert.equal(get["x-amz-date"], "20150830T123600Z");
  const post = await signRequest({ method: "POST", url: "https://example.amazonaws.com/", region: "us-east-1", service: "service", ...DOC_KEY, now: DOC_TIME });
  assert.match(post.authorization, /Signature=5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b$/);
});

test("model ids with a colon are encoded once in the URL and twice in the canonical path", async () => {
  const url = converseUrl({ region: "us-east-1", modelId: "us.amazon.nova-lite-v1:0" });
  assert.equal(url, "https://bedrock-runtime.us-east-1.amazonaws.com/model/us.amazon.nova-lite-v1%3A0/converse");
  assert.equal(canonicalUri(new URL(url).pathname), "/model/us.amazon.nova-lite-v1%253A0/converse");
});

test("the signature changes with the body and the session token is signed", async () => {
  const base = { method: "POST", url: "https://bedrock-runtime.us-east-1.amazonaws.com/model/x/converse", region: "us-east-1", service: "bedrock", ...DOC_KEY, now: DOC_TIME };
  const a = await signRequest({ ...base, body: "{}" });
  const b = await signRequest({ ...base, body: "{\"a\":1}" });
  assert.notEqual(a.authorization, b.authorization);
  const withToken = await signRequest({ ...base, body: "{}", sessionToken: "fake-session" });
  assert.match(withToken.authorization, /SignedHeaders=host;x-amz-date;x-amz-security-token,/);
  assert.equal(JSON.stringify(a).includes(DOC_KEY.secretAccessKey), false, "비밀 키는 머리에 실리지 않는다");
});

test("converse hides the upstream body and maps failures", async () => {
  const config = { accessKeyId: FAKE.AWS_ACCESS_KEY_ID, secretAccessKey: FAKE.AWS_SECRET_ACCESS_KEY, region: "us-east-1", modelId: "m" };
  const denied = await converse(config, { messages: [] }, { fetcher: async () => new Response(`{"message":"key ${FAKE.AWS_ACCESS_KEY_ID} is not authorized"}`, { status: 403 }) });
  assert.deepEqual(denied, { ok: false, status: 502, error: "upstream_denied" });
  assert.deepEqual(await converse(config, { messages: [] }, { fetcher: async () => new Response("{}", { status: 429 }) }), { ok: false, status: 429, error: "upstream_throttled" });
  assert.deepEqual(await converse(config, { messages: [] }, { fetcher: async () => { throw new Error("dns"); } }), { ok: false, status: 502, error: "upstream_failed" });
});

// MARK: 민감정보

test("redact removes coordinates, Luhn-valid card numbers and resident numbers but keeps ordinary numbers", () => {
  const r = redact("11.11111, 22.22222 근처, 카드 4111 1111 1111 1111, 주민 900101-1234567, 전화 010-1234-5678, 12,000원");
  assert.equal(r.text.includes("11.11111"), false);
  assert.equal(r.text.includes("4111"), false);
  assert.equal(r.text.includes("1234567"), false);
  assert.ok(r.text.includes("010-1234-5678") && r.text.includes("12,000원"));
  assert.deepEqual(r.found.sort(), ["cardNumber", "coordinates", "idNumber"]);
  assert.deepEqual(redact("주문번호 1234 5678 9012 3456").found, [], "Luhn이 맞지 않는 긴 숫자는 그대로 둔다");
});

test("sensitive text and coordinate context never reach Bedrock", async () => {
  const { env, key, bedrock } = await owner();
  const response = await talk(env, key, "오늘 12.34567, 23.45678 에서 4111-1111-1111-1111 카드로 점심 12000원", {
    context: { today: "2026-11-21", timeZone: "+09:00", region: "가짜시 가짜구", latitude: 1.5, longitude: 2.5, location: { lat: 1.5, lng: 2.5 }, diary: "원본 일기 전문" },
  });
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.deepEqual(body.redacted, ["cardNumber", "coordinates"]);
  const sent = JSON.stringify(bedrock.calls[0].body);
  for (const secret of ["12.3456", "23.4567", "4111", "원본 일기", "\"latitude\"", "\"lat\""]) assert.equal(sent.includes(secret), false, secret);
  assert.ok(sent.includes("가짜시 가짜구"), "시군구는 보낸다");
});

// MARK: 경로

test("/ai/converse needs the master key and the AWS secrets", async () => {
  const { env, key } = await owner({ env: { AWS_SECRET_ACCESS_KEY: undefined } });
  assert.equal((await talk(env, undefined, "안녕")).status, 401);
  const search = randomKey();
  await send(env, "/register", "POST", { purpose: "search" }, search);
  assert.equal((await talk(env, search, "안녕")).status, 403);
  const off = await talk(env, key, "안녕");
  assert.equal(off.status, 503);
  assert.deepEqual(await off.json(), { error: "ai_unavailable" });
});

test("a reply comes back with validated commands; coordinates, edits and bad ones are dropped", async () => {
  const bedrock = fakeBedrock(toolAnswer({
    reply: "아래 세 가지를 넣을까요?",
    commands: [
      { action: "addSchedule", title: "가짜 미술관", start: "2026-11-22T10:00+09:00", end: "2026-11-22T12:00+09:00", placeName: "가짜 미술관", latitude: 1.1, longitude: 2.1 },
      { action: "addExpense", amount: "12,000", title: "점심", category: "food" },
      { action: "addMemo", text: "우산 챙기기", date: "2026-11-22" },
      { action: "deleteSchedule", planId: "x" },
      { action: "addExpense", amount: -3, title: "잘못" },
      { action: "addTripStop", title: "가짜 시장", date: "2026-11-22", lat: 10.1, lng: 20.2 },
    ],
  }));
  const { env, key } = await owner({ bedrock });
  const response = await talk(env, key, "내일 10시 미술관, 점심 12000원 썼고 우산 메모해 줘", { context: { today: "2026-11-21", timeZone: "+09:00" } });
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.reply, "아래 세 가지를 넣을까요?");
  assert.deepEqual(body.commands.map((c) => c.action), ["addSchedule", "addExpense", "addMemo", "addTripStop"]);
  assert.equal(body.dropped, 2);
  for (const c of body.commands) {
    assert.equal(c.format, "bokki-command");
    assert.match(c.id, /^ai-[0-9a-f]{18}$/);
    for (const field of ["latitude", "longitude", "lat", "lng", "placeName"]) assert.equal(field in c, false, field);
  }
  assert.equal(body.commands[0].note, "장소: 가짜 미술관");
  assert.equal(body.commands[1].amount, 12000);
  assert.deepEqual(body.usage, { inputTokens: 120, outputTokens: 40 });
  // 큐에는 넣지 않는다: 앱이 확인 뒤에 스스로 반영한다.
  assert.equal((await send(env, "/command", "GET", undefined, key)).status, 204);
  const call = bedrock.calls[0];
  assert.equal(call.url, "https://bedrock-runtime.ap-northeast-2.amazonaws.com/model/apac.anthropic.fake-haiku-v1%3A0/converse");
  assert.match(call.headers.authorization, /^AWS4-HMAC-SHA256 Credential=TESTKEYID0000000\/\d{8}\/ap-northeast-2\/bedrock\/aws4_request, /);
  assert.equal(JSON.stringify(call).includes(FAKE.AWS_SECRET_ACCESS_KEY), false, "비밀 키는 요청에 실리지 않는다");
});

test("maxTokens is clamped and conversations are bounded", async () => {
  const { env, key, bedrock } = await owner();
  await talk(env, key, "안녕", { maxTokens: 99999 });
  assert.equal(bedrock.calls[0].body.inferenceConfig.maxTokens, 1024);
  assert.equal((await talk(env, key, "가".repeat(2001))).status, 400);
  const many = Array.from({ length: 13 }, (_, i) => ({ role: i % 2 ? "assistant" : "user", text: "a" }));
  assert.equal((await send(env, "/ai/converse", "POST", { messages: many }, key)).status, 400);
  assert.equal((await send(env, "/ai/converse", "POST", { messages: [{ role: "assistant", text: "a" }] }, key)).status, 400);
});

test("the per-user daily call limit returns 429 before Bedrock is called", async () => {
  const { env, key, bedrock } = await owner({ env: { AI_USER_DAILY_CALLS: "2" } });
  assert.equal((await talk(env, key, "하나")).status, 200);
  assert.equal((await talk(env, key, "둘")).status, 200);
  const third = await talk(env, key, "셋");
  assert.equal(third.status, 429);
  assert.equal((await third.json()).error, "daily_ai_limit");
  assert.ok(Number(third.headers.get("retry-after")) > 0);
  assert.equal(bedrock.calls.length, 2);
});

test("the daily token budget and the server-wide limit also return 429", async () => {
  const tokens = await owner({ env: { AI_USER_DAILY_TOKENS: "2000" } });
  assert.equal((await talk(tokens.env, tokens.key, "하나")).status, 200); // 1024 + 1 + 600 예약
  const over = await talk(tokens.env, tokens.key, "둘");
  assert.equal(over.status, 429);
  assert.equal((await over.json()).error, "daily_ai_token_limit");

  const shared = await owner({ env: { AI_GLOBAL_DAILY_CALLS: "1" } });
  const other = randomKey();
  await send(shared.env, "/register", "POST", {}, other);
  assert.equal((await talk(shared.env, shared.key, "하나")).status, 200);
  const blocked = await talk(shared.env, other, "둘");
  assert.equal(blocked.status, 429);
  assert.equal((await blocked.json()).error, "daily_ai_server_limit");
});

test("upstream failures do not leak the upstream body", async () => {
  const bedrock = fakeBedrock(() => new Response(`{"message":"The security token included in the request is invalid ${FAKE.AWS_ACCESS_KEY_ID}"}`, { status: 403 }));
  const { env, key } = await owner({ bedrock });
  const response = await talk(env, key, "안녕");
  assert.equal(response.status, 502);
  const text = await response.text();
  assert.equal(text.includes(FAKE.AWS_ACCESS_KEY_ID) || text.includes("security token"), false);
});

// MARK: 응답 읽기

test("a JSON answer in plain text is read when the model skipped the tool", () => {
  const out = readReply({ output: { message: { content: [{ text: "결과: {\"reply\":\"좋아요\",\"commands\":[{\"action\":\"addMemo\",\"text\":\"메모\"}]}" }] } }, usage: {} });
  assert.equal(out.reply, "좋아요");
  assert.equal(out.rawCommands.length, 1);
  assert.equal(readReply({ output: { message: { content: [{ text: "그냥 답" }] } } }).reply, "그냥 답");
  assert.equal(shapeCommand({ action: "addMemo", text: "카드 4111111111111111" }).text, "카드 [카드번호 생략]");
});

test("a trip draft is validated and loses coordinates and map links", () => {
  const trip = shapeTrip({
    title: "가짜 여행", startDate: "2026-12-01", endDate: "2026-12-02",
    items: [{ type: "activity", title: "가짜 공원", start: "2026-12-01T10:00+09:00", place: { name: "가짜 공원", lat: 1.23, lng: 4.56, mapsUrl: "https://maps.example.com/?q=1.23,4.56" } }],
  });
  assert.equal(trip.format, "bokki-trip");
  assert.deepEqual(trip.items[0].place, { name: "가짜 공원" });
  assert.equal(trip.items[0].id, "i1");
  assert.equal(shapeTrip({ title: "빈 여행", items: [] }), null);
});
