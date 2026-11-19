import assert from "node:assert/strict";
import test from "node:test";
import { checkSample, CLASSIFIER_LIMITS } from "../src/classifier.js";
import { handle } from "../src/index.js";
import { FakeD1 } from "./fake-d1.mjs";
import { makeEnv } from "./fakes.mjs";

const randomKey = () => Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64url");
const owner = randomKey();
const other = randomKey();
const ADMIN = "a".repeat(40);
const ORIGIN = "https://relay.example.com";

async function fresh(extra = {}) {
  const { env, clock } = makeEnv({ RELAY_DB: new FakeD1(), CLASSIFIER_ADMIN_TOKEN: ADMIN, ...extra });
  for (const key of [owner, other]) {
    const response = await handle(new Request(`${ORIGIN}/register`, { method: "POST", headers: { authorization: `Bearer ${key}` } }), { ...env, POST_LIMIT: undefined });
    assert.equal(response.status, 201);
  }
  return { env, clock };
}

const features = (extra = {}) => ({ averageSpeedKmh: 5, maximumSpeedKmh: 7.5, distanceMeters: 350, steps: 612, stepCadencePerMinute: 108, gpsAccuracyMeters: 10, dominantMotion: "walking", watchCovered: false, sampleCount: 6, ...extra });
let counter = 0;
const sample = (extra = {}) => ({
  schemaVersion: 1, id: `00000000-0000-4000-8000-${String(++counter).padStart(12, "0")}`, kind: "activity", minuteOfDay: 870, weekdayIndex: 3, durationSeconds: 1200,
  predicted: "rest", predictedDetail: null, predictedConfidence: "medium", predictedScore: 0.5, corrected: "work", correctedDetail: "work.meeting", correctedIsCustom: false,
  ruleVersion: "classifier-v1r4", features: features(), ...extra,
});
const payload = (samples, extra = {}) => ({ format: "bokki-misclassification", version: 1, ruleVersion: "classifier-v1r4", samples, ...extra });
const post = (body, key = owner, path = "/classifier-samples") => new Request(`${ORIGIN}${path}`, {
  method: "POST", headers: { authorization: `Bearer ${key}`, "content-type": "application/json" }, body: typeof body === "string" ? body : JSON.stringify(body),
});
const admin = (query = "", token = ADMIN) => new Request(`${ORIGIN}/classifier-samples/admin${query}`, { headers: token ? { authorization: `Bearer ${token}` } : {} });
const count = (env) => env.RELAY_DB.db.prepare("SELECT COUNT(*) AS n FROM misclass_samples").get().n;

test("a valid upload is stored and the response counts accepted, duplicates and rejected", async () => {
  const { env } = await fresh();
  const first = sample(), second = sample({ kind: "travel", predicted: "bus", corrected: "subway", correctedDetail: null, predictedConfidence: "low", predictedScore: null });
  const response = await handle(post(payload([first, second])), env);
  assert.equal(response.status, 201);
  assert.deepEqual(await response.json(), { ok: true, accepted: 2, duplicates: 0, rejected: 0 });
  assert.equal(count(env), 2);
  const again = await handle(post(payload([first, sample()])), env);
  assert.deepEqual(await again.json(), { ok: true, accepted: 1, duplicates: 1, rejected: 0 }, "같은 id는 무시");
  assert.equal(count(env), 3);
});

test("only the allow-listed shape is accepted; extra keys, long text and bad values are rejected per sample", async () => {
  const { env } = await fresh();
  const bad = [
    sample({ note: "집 근처 카페" }), // 모르는 열쇠
    sample({ predicted: "집 근처 카페" }), // 글자
    sample({ corrected: "x".repeat(40) }),
    sample({ minuteOfDay: 1440 }), sample({ weekdayIndex: 7 }), sample({ schemaVersion: 2 }),
    sample({ id: "not-a-uuid" }), sample({ features: features({ lat: 37.5 }) }), sample({ features: features({ dominantMotion: "flying" }) }),
    sample({ correctedIsCustom: true, corrected: "work" }), sample({ predictedScore: 1.5 }), sample({ predictedDetail: "한글 상세" }),
    sample({ ruleVersion: "규칙 1" }), { ...sample(), features: undefined },
  ];
  const good = sample();
  const response = await handle(post(payload([...bad, good])), env);
  assert.deepEqual(await response.json(), { ok: true, accepted: 1, duplicates: 0, rejected: bad.length });
  assert.equal(count(env), 1);
  const stored = JSON.parse(env.RELAY_DB.db.prepare("SELECT body FROM misclass_samples").get().body);
  assert.deepEqual(Object.keys(stored).sort(), Object.keys(good).sort());
  assert.equal(checkSample(sample({ correctedIsCustom: true, corrected: "custom", correctedDetail: null })) !== null, true, "사용자 지정은 custom 코드만");
});

test("payload checks: format, version, sample count and size", async () => {
  const { env } = await fresh();
  assert.equal((await handle(post(payload([sample()], { format: "other" })), env)).status, 422);
  assert.equal((await handle(post(payload([sample()], { version: 2 })), env)).status, 422);
  assert.equal((await handle(post(payload([])), env)).status, 422);
  assert.equal((await handle(post(payload(Array.from({ length: CLASSIFIER_LIMITS.maxSamples + 1 }, () => sample()))), env)).status, 422);
  assert.equal((await handle(post("{깨짐"), env)).status, 400);
  const two = await handle(post(payload(Array.from({ length: CLASSIFIER_LIMITS.maxSamples }, () => sample()))), env);
  assert.equal(two.status, 201, "200건까지 한 번에");
  assert.equal((await handle(post("x".repeat(CLASSIFIER_LIMITS.maxBytes + 10)), env)).status, 413);
  assert.equal(count(env), CLASSIFIER_LIMITS.maxSamples);
});

test("an owner key is required and the sample table holds no owner key", async () => {
  const { env } = await fresh();
  assert.equal((await handle(new Request(`${ORIGIN}/classifier-samples`, { method: "POST", body: "{}" }), env)).status, 401);
  assert.equal((await handle(post(payload([sample()]), randomKey()), env)).status, 401, "등록 안 된 키");
  await handle(post(payload([sample()])), env);
  const rows = JSON.stringify(env.RELAY_DB.db.prepare("SELECT * FROM misclass_samples").all());
  assert.ok(!rows.includes(owner), "주인 키 원문이 표에 없다");
  assert.equal((await handle(new Request(`${ORIGIN}/classifier-samples`, { method: "GET", headers: { authorization: `Bearer ${owner}` } }), env)).status, 405, "주인 키로 읽기는 없다");
});

test("a daily limit of 2,000 samples per owner returns 429, and another owner is unaffected", async () => {
  const { env, clock } = await fresh();
  env.RELAY_DB.db.exec("BEGIN");
  const insert = env.RELAY_DB.db.prepare("INSERT INTO misclass_samples (id, owner, received_at, rule_version, body) VALUES (?, ?, ?, 'r', '{}')");
  const first = await handle(post(payload([sample()])), env);
  assert.equal(first.status, 201);
  const hash = env.RELAY_DB.db.prepare("SELECT owner FROM misclass_samples").get().owner;
  for (let i = 0; i < CLASSIFIER_LIMITS.perDay - 1; i++) insert.run(`filler-${i}`, hash, clock.now);
  env.RELAY_DB.db.exec("COMMIT");
  const over = await handle(post(payload([sample()])), env);
  assert.equal(over.status, 429);
  assert.equal(over.headers.get("retry-after"), "3600");
  assert.equal((await over.json()).error, "classifier_daily_limit");
  assert.equal((await handle(post(payload([sample()]), other), env)).status, 201, "다른 주인은 영향 없음");
  clock.now += 25 * 60 * 60 * 1000;
  assert.equal((await handle(post(payload([sample()])), env)).status, 201, "24시간 뒤에는 다시 올릴 수 있다");
});

test("samples older than one year are deleted when anyone uploads", async () => {
  const { env, clock } = await fresh();
  await handle(post(payload([sample()])), env);
  assert.equal(count(env), 1);
  clock.now += CLASSIFIER_LIMITS.retentionMs - 1_000;
  await handle(post(payload([sample()]), other), env);
  assert.equal(count(env), 2, "1년이 안 지난 것은 남는다");
  clock.now += 2_000;
  await handle(post(payload([sample()]), other), env);
  assert.equal(count(env), 2, "1년이 지난 첫 표본은 지워지고 새 표본이 들어온다");
  assert.ok(env.RELAY_DB.db.prepare("SELECT MIN(received_at) AS t FROM misclass_samples").get().t > clock.now - CLASSIFIER_LIMITS.retentionMs);
});

test("DELETE removes only the caller's samples", async () => {
  const { env } = await fresh();
  await handle(post(payload([sample(), sample()])), env);
  await handle(post(payload([sample()]), other), env);
  const response = await handle(new Request(`${ORIGIN}/classifier-samples`, { method: "DELETE", headers: { authorization: `Bearer ${owner}` } }), env);
  assert.deepEqual(await response.json(), { ok: true, deleted: 2 });
  assert.equal(count(env), 1);
});

test("the admin read needs the operator token and never shows owner or received time", async () => {
  const { env } = await fresh();
  await handle(post(payload([sample(), sample(), sample()])), env);
  assert.equal((await handle(admin("", null), env)).status, 401);
  assert.equal((await handle(admin("", "b".repeat(40)), env)).status, 401);
  assert.equal((await handle(admin("", owner), env)).status, 401, "주인 키로는 못 읽는다");
  assert.equal((await handle(admin(), { ...env, CLASSIFIER_ADMIN_TOKEN: undefined })).status, 503);
  const page = await (await handle(admin("?limit=2"), env)).json();
  assert.equal(page.samples.length, 2);
  assert.equal(page.format, "bokki-misclassification");
  for (const row of page.samples) assert.deepEqual(Object.keys(row).sort(), ["seq", ...Object.keys(sample())].sort());
  const rest = await (await handle(admin(`?since=${page.next}`), env)).json();
  assert.equal(rest.samples.length, 1);
  assert.ok(rest.samples[0].seq > page.next);
  assert.equal((await handle(admin("?limit=501"), env)).status, 422);
  assert.equal((await handle(admin("?since=-1"), env)).status, 422);
});

test("without the D1 binding the endpoints answer 503 and existing routes are unchanged", async () => {
  const { env } = makeEnv();
  await handle(new Request(`${ORIGIN}/register`, { method: "POST", headers: { authorization: `Bearer ${owner}` } }), { ...env, POST_LIMIT: undefined });
  assert.equal((await handle(post(payload([sample()])), env)).status, 503);
  assert.equal((await handle(new Request(`${ORIGIN}/plan`), env)).status, 401);
});
