// AIG1122A01 Step 1: 16자리 ID, 쿼터(현지 자정 리셋·웰컴 7일·Pro 월 100회), 에이전트 등록 게이트, 작업 선점·끝내기·외부 우선 폴백. 값은 전부 가짜다.
import assert from "node:assert/strict";
import test from "node:test";
import {
  AI_CONFIG_DEFAULTS, BUILT_IN_AGENT, ID_ALPHABET, chargeQuota, checkConfigPatch, claimDue, claimTask, createTask, ensureUser, finishTask,
  isId, localClock, newId, quotaView, readConfig, registerAgent, reopenTask, writeConfig,
} from "../src/ai-core.js";
import { handle } from "../src/index.js";
import { FakeD1 } from "./fake-d1.mjs";
import { makeEnv } from "./fakes.mjs";

const DAY = 86_400_000;
const T0 = Date.UTC(2026, 10, 21, 3, 0); // 2026-11-21 12:00 KST
const randomKey = () => Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64url");
const ADMIN = "b".repeat(40);
const ORIGIN = "https://relay.example.com";
const config = { ...AI_CONFIG_DEFAULTS };

test("16자리 ID: 접두사·길이·혼동 문자 없음·충돌 없음", () => {
  assert.equal(ID_ALPHABET.length, 57);
  for (const bad of ["0", "O", "1", "l", "I"]) assert.equal(ID_ALPHABET.includes(bad), false, bad);
  const seen = new Set();
  for (let i = 0; i < 5000; i++) {
    const id = newId(["usr", "agt", "req"][i % 3]);
    assert.match(id, /^(usr|agt|req)_[2-9A-HJ-NP-Za-km-z]{16}$/);
    seen.add(id);
  }
  assert.equal(seen.size, 5000);
  assert.equal(isId(BUILT_IN_AGENT, "agt"), true, "내장 AI 고정 ID도 같은 규칙");
  assert.equal(isId("usr_abc", "usr"), false);
  assert.equal(isId(newId("req"), "usr"), false);
  assert.throws(() => newId("xyz"));
  // 치우침 없음: 228 이상 바이트는 버린다.
  assert.equal(newId("usr", (n) => new Uint8Array(n).fill(255).map((v, i) => (i % 2 ? 255 : 0))), "usr_" + "2".repeat(16));
});

test("현지 날짜·다음 현지 자정", () => {
  const seoul = localClock(T0, "Asia/Seoul");
  assert.deepEqual([seoul.day, seoul.month], ["2026-11-21", "2026-11"]);
  assert.equal(new Date(seoul.resetAt).toISOString(), "2026-11-21T15:00:00.000Z", "KST 자정 = 15:00Z");
  const lateUtc = Date.UTC(2026, 10, 21, 16, 0); // KST 11-22 01:00
  assert.equal(localClock(lateUtc, "Asia/Seoul").day, "2026-11-22");
  assert.equal(localClock(lateUtc, "America/Los_Angeles").day, "2026-11-21");
  // 서머타임이 끝나는 날(2026-11-01 LA)에도 자정을 맞힌다.
  const dst = localClock(Date.UTC(2026, 10, 1, 12, 0), "America/Los_Angeles");
  assert.equal(new Date(dst.resetAt).toISOString(), "2026-11-02T08:00:00.000Z");
});

async function user(db, now = T0, tz = "Asia/Seoul") { return ensureUser(db, randomKey(), now, tz); }

test("Free 웰컴 7일: 하루 15회, 월 상한 없음, 현지 자정에 리셋", async () => {
  const db = new FakeD1();
  const row = await user(db);
  assert.match(row.user_id, /^usr_/);
  for (let i = 0; i < 15; i++) assert.equal(await chargeQuota(db, row, config, T0 + i), true, `#${i + 1}`);
  assert.equal(await chargeQuota(db, row, config, T0 + 100), false, "16번째는 막힌다");
  const fresh = await db.prepare("SELECT * FROM user_ai_quotas WHERE user_id = ?").bind(row.user_id).first();
  const view = quotaView(fresh, config, T0 + 100);
  assert.deepEqual([view.plan, view.daily.used, view.daily.limit, view.monthly.limit, view.remaining, view.fallback], ["free", 15, 15, null, 0, "on_device"]);
  assert.ok(view.welcome);
  // KST 자정이 지나면 다시 15회.
  const nextDay = Date.UTC(2026, 10, 21, 15, 0, 1);
  assert.equal(await chargeQuota(db, fresh, config, nextDay), true);
  const after = await db.prepare("SELECT daily_cloud_count, day_key, monthly_cloud_count FROM user_ai_quotas WHERE user_id = ?").bind(row.user_id).first();
  assert.deepEqual([after.daily_cloud_count, after.day_key, after.monthly_cloud_count], [1, "2026-11-22", 0], "웰컴 기간 사용은 월 상한에 세지 않는다");
});

test("Free 웰컴 뒤: 하루 5회·월 30회", async () => {
  const db = new FakeD1();
  const row = await user(db, T0 - 8 * DAY);
  const view0 = quotaView(row, config, T0);
  assert.deepEqual([view0.welcome, view0.daily.limit, view0.monthly.limit], [null, 5, 30]);
  for (let i = 0; i < 5; i++) assert.equal(await chargeQuota(db, row, config, T0), true);
  assert.equal(await chargeQuota(db, row, config, T0), false, "하루 5회");
  // 월 30회: 날을 바꿔 가며 채운다.
  let used = 5;
  for (let d = 1; used < 30; d++) for (let i = 0; i < 5 && used < 30; i++, used++) assert.equal(await chargeQuota(db, row, config, T0 + d * DAY), true);
  assert.equal(await chargeQuota(db, row, config, T0 + 7 * DAY), false, "월 30회가 차면 다른 날에도 막힌다");
  // 다음 달(현지)이 되면 풀린다.
  assert.equal(await chargeQuota(db, row, config, Date.UTC(2026, 11, 1, 1)), true);
});

test("Pro 원타임 A안: 월 100회, 하루 상한 없음, 운영 레버로 바꾼 값을 따른다", async () => {
  const db = new FakeD1();
  const row = { ...(await user(db, T0 - 30 * DAY)), plan: "pro" };
  await db.prepare("UPDATE user_ai_quotas SET plan = 'pro' WHERE user_id = ?").bind(row.user_id).run();
  for (let i = 0; i < 100; i++) assert.equal(await chargeQuota(db, row, config, T0), true);
  assert.equal(await chargeQuota(db, row, config, T0), false);
  const promo = (await writeConfig(db, { pro_monthly: 120 }, T0)).value;
  assert.equal(promo.pro_monthly, 120);
  assert.equal(await chargeQuota(db, row, await readConfig(db), T0), true, "운영 레버로 올리면 바로 반영");
});

test("동시에 와도 상한을 넘지 않는다(조건부 UPDATE 한 번)", async () => {
  const db = new FakeD1();
  const row = await user(db, T0 - 8 * DAY);
  const results = await Promise.all(Array.from({ length: 12 }, () => chargeQuota(db, row, config, T0)));
  assert.equal(results.filter(Boolean).length, 5);
});

test("운영 레버 검사: 폴백은 0/3/10/30분만, 모르는 항목·범위 밖은 거절, 깨진 값은 기본값", async () => {
  assert.deepEqual(checkConfigPatch({ fallback_minutes: 3, external_first: false }).value, { fallback_minutes: 3, external_first: false });
  assert.ok(checkConfigPatch({ fallback_minutes: 7 }).errors);
  assert.ok(checkConfigPatch({ free_daily: -1 }).errors);
  assert.ok(checkConfigPatch({ secret: 1 }).errors);
  assert.ok(checkConfigPatch([1]).errors);
  const db = new FakeD1();
  db.db.prepare("INSERT INTO system_ai_config (key, value, updated_at) VALUES ('free_daily', '\"x\"', 0), ('unknown', '1', 0)").run();
  assert.deepEqual(await readConfig(db), AI_CONFIG_DEFAULTS);
});

test("에이전트 등록: Free는 1개(레버가 켜지면 Pro 전용), Pro는 다중·상한, 해제", async () => {
  const db = new FakeD1();
  const free = await user(db);
  const one = await registerAgent(db, free, config, " 피클 ", T0);
  assert.match(one.value.agtId, /^agt_/);
  assert.equal(one.value.label, "피클");
  assert.equal((await registerAgent(db, free, config, "클로드", T0)).error, "too_many_agents");
  assert.equal((await registerAgent(db, await user(db), { ...config, byo_agent_requires_pro: true }, "피클", T0)).error, "pro_required");
  const pro = { ...(await user(db)), plan: "pro" };
  for (let i = 0; i < config.pro_max_agents; i++) assert.ok((await registerAgent(db, pro, config, `봇${i}`, T0)).value);
  assert.equal((await registerAgent(db, pro, config, "하나 더", T0)).error, "too_many_agents");
  assert.equal((await registerAgent(db, pro, config, "", T0)).error, "bad_label");
});

test("외부 우선 대기 → 10분 무응답이면 내장 AI 폴백, 선점은 하나만", async () => {
  const db = new FakeD1();
  const owner = await user(db);
  const external = newId("agt"), second = newId("agt");
  const task = await createTask(db, { userId: owner.user_id, taskType: "route_check", hasExternal: true, config, now: T0 });
  assert.equal(task.status, "pending_external");
  assert.deepEqual(await createTask(db, { userId: owner.user_id, taskType: "route_check", reqId: task.reqId, hasExternal: true, config, now: T0 }),
    { created: false, reqId: task.reqId, status: "pending_external" }, "같은 req_id는 다시 생기지 않는다");
  const lease = 30 * 60_000;
  assert.equal((await claimTask(db, { reqId: task.reqId, agtId: BUILT_IN_AGENT, source: "built_in_ai", now: T0 + 9 * 60_000, leaseMs: lease })).error, "waiting_external");
  // 10분이 지나면 내장 AI가 맡고, 늦게 온 외부 에이전트는 못 맡는다.
  const won = await claimTask(db, { reqId: task.reqId, agtId: BUILT_IN_AGENT, source: "built_in_ai", now: T0 + 10 * 60_000, leaseMs: lease });
  assert.equal(won.claimed, true);
  assert.equal((await claimTask(db, { reqId: task.reqId, agtId: external, source: "external_agent", now: T0 + 11 * 60_000, leaseMs: lease })).error, "taken");
  // 끝내기: 맡은 AI + version 일치만.
  assert.equal((await finishTask(db, { reqId: task.reqId, agtId: external, version: won.version, status: "done", now: T0 })).error, "not_claimer");
  assert.equal((await finishTask(db, { reqId: task.reqId, agtId: BUILT_IN_AGENT, version: won.version - 1, status: "done", now: T0 })).error, "version_conflict");
  const done = await finishTask(db, { reqId: task.reqId, agtId: BUILT_IN_AGENT, version: won.version, status: "done", now: T0 });
  assert.equal(done.ok, true);
  assert.equal((await finishTask(db, { reqId: task.reqId, agtId: BUILT_IN_AGENT, version: done.version, status: "done", now: T0 })).error, "already_finished", "완료 잠금");
  assert.equal((await claimTask(db, { reqId: task.reqId, agtId: second, source: "external_agent", now: T0 + DAY, leaseMs: lease })).error, "already_finished");
  // 사용자가 명시적으로 다시 요청하면 다시 열린다.
  assert.equal(await reopenTask(db, { reqId: task.reqId, userId: owner.user_id, now: T0 + DAY }), true);
  assert.equal((await claimTask(db, { reqId: task.reqId, agtId: second, source: "external_agent", now: T0 + DAY, leaseMs: lease })).claimed, true);
});

test("외부 에이전트가 먼저 오면 바로 맡고, 동시에 와도 하나만 이긴다. 선점이 만료되면 다시 맡을 수 있다", async () => {
  const db = new FakeD1();
  const owner = await user(db);
  const a = newId("agt"), b = newId("agt");
  const task = await createTask(db, { userId: owner.user_id, taskType: "payment_text", hasExternal: true, config, now: T0 });
  const outcomes = await Promise.all([a, b, BUILT_IN_AGENT].map((agtId, i) => claimTask(db, { reqId: task.reqId, agtId, source: i < 2 ? "external_agent" : "built_in_ai", now: T0 + 60_000, leaseMs: 60_000 })));
  assert.equal(outcomes.filter((o) => o.claimed).length, 1);
  assert.equal(outcomes[0].claimed, true);
  const late = await claimTask(db, { reqId: task.reqId, agtId: BUILT_IN_AGENT, source: "built_in_ai", now: T0 + 3 * 60_000, leaseMs: 60_000 });
  assert.equal(late.claimed, true, "선점이 만료되면 다른 AI가 맡는다");
  assert.equal((await finishTask(db, { reqId: task.reqId, agtId: a, version: outcomes[0].version, status: "done", now: T0 })).error, "not_claimer", "만료된 옛 주인은 끝내지 못한다");
});

test("외부 에이전트가 없거나 「내장 AI 즉시 우선」(0분)이면 바로 pending, claimDue는 맡을 수 있는 것만", async () => {
  const db = new FakeD1();
  const owner = await user(db);
  const plain = await createTask(db, { userId: owner.user_id, taskType: "memo_polish", hasExternal: false, config, now: T0 });
  const now0 = await createTask(db, { userId: owner.user_id, taskType: "memo_polish", hasExternal: true, config: { ...config, fallback_minutes: 0 }, now: T0 });
  const waiting = await createTask(db, { userId: owner.user_id, taskType: "memo_polish", hasExternal: true, config, now: T0 });
  assert.deepEqual([plain.status, now0.status, waiting.status], ["pending", "pending", "pending_external"]);
  const won = await claimDue(db, { userId: owner.user_id, agtId: BUILT_IN_AGENT, source: "built_in_ai", now: T0 + 1000, leaseMs: 60_000 });
  assert.deepEqual(won.map((w) => w.reqId).sort(), [plain.reqId, now0.reqId].sort());
  assert.equal((await createTask(db, { userId: owner.user_id, taskType: "Bad Type", hasExternal: false, config, now: T0 })).error, "bad_task");
});

async function fresh() {
  const { env, clock } = makeEnv({ RELAY_DB: new FakeD1(), CLASSIFIER_ADMIN_TOKEN: ADMIN });
  const key = randomKey();
  const response = await handle(new Request(`${ORIGIN}/register`, { method: "POST", headers: { authorization: `Bearer ${key}` } }), { ...env, POST_LIMIT: undefined });
  assert.equal(response.status, 201);
  return { env, clock, key };
}
const call = (env, method, path, { key, token, body } = {}) => handle(new Request(`${ORIGIN}${path}`, {
  method, headers: { ...(key ? { authorization: `Bearer ${key}` } : {}), ...(token ? { authorization: `Bearer ${token}` } : {}), ...(body ? { "content-type": "application/json" } : {}) },
  ...(body ? { body: JSON.stringify(body) } : {}),
}), env);

test("라우트: /ai/quota는 주인 키로 usr_를 만들고 시간대를 받으며, /ai/agents는 등록·목록·해제", async () => {
  const { env, key } = await fresh();
  assert.equal((await call(env, "GET", "/ai/quota")).status, 401);
  assert.equal((await call(env, "GET", "/ai/quota?tz=Mars/Base", { key })).status, 422);
  const quota = await (await call(env, "GET", "/ai/quota?tz=Asia/Seoul", { key })).json();
  assert.match(quota.userId, /^usr_/);
  assert.deepEqual([quota.plan, quota.daily.limit, quota.timeZone], ["free", 15, "Asia/Seoul"]);
  const again = await (await call(env, "GET", "/ai/quota", { key })).json();
  assert.equal(again.userId, quota.userId, "같은 주인 키는 같은 usr_");
  const created = await call(env, "POST", "/ai/agents", { key, body: { label: "피클" } });
  assert.equal(created.status, 201);
  const { agtId } = await created.json();
  const list = await (await call(env, "GET", "/ai/agents", { key })).json();
  assert.deepEqual(list.agents.map((a) => a.agtId), [agtId]);
  assert.equal((await call(env, "DELETE", `/ai/agents?id=${agtId}`, { key })).status, 204);
  assert.equal((await call(env, "DELETE", `/ai/agents?id=${agtId}`, { key })).status, 404);
  const rows = env.RELAY_DB.db.prepare("SELECT * FROM user_ai_quotas").all();
  assert.equal(JSON.stringify(rows).includes(key), false, "주인 키 원문은 저장하지 않는다");
});

test("운영자 길: 토큰 없으면 401, 설정 읽기·바꾸기, 플랜 바꾸기, 사용 현황", async () => {
  const { env, key } = await fresh();
  assert.equal((await call(env, "GET", "/ai/admin/config")).status, 401);
  assert.equal((await call(env, "GET", "/ai/admin/config", { token: "c".repeat(40) })).status, 401);
  const read = await (await call(env, "GET", "/ai/admin/config", { token: ADMIN })).json();
  assert.equal(read.config.fallback_minutes, 10);
  assert.equal((await call(env, "PUT", "/ai/admin/config", { token: ADMIN, body: { fallback_minutes: 7 } })).status, 422);
  const put = await (await call(env, "PUT", "/ai/admin/config", { token: ADMIN, body: { fallback_minutes: 3, free_welcome_daily: 20 } })).json();
  assert.deepEqual([put.config.fallback_minutes, put.config.free_welcome_daily], [3, 20]);
  const { userId } = await (await call(env, "GET", "/ai/quota", { key })).json();
  assert.equal((await (await call(env, "GET", "/ai/quota", { key })).json()).daily.limit, 20, "운영 레버가 바로 앱 응답에 반영");
  assert.equal((await call(env, "POST", "/ai/admin/plan", { token: ADMIN, body: { userId, plan: "gold" } })).status, 422);
  assert.equal((await call(env, "POST", "/ai/admin/plan", { token: ADMIN, body: { userId: newId("usr"), plan: "pro" } })).status, 404);
  assert.equal((await call(env, "POST", "/ai/admin/plan", { token: ADMIN, body: { userId, plan: "pro" } })).status, 200);
  const pro = await (await call(env, "GET", "/ai/quota", { key })).json();
  assert.deepEqual([pro.plan, pro.monthly.limit, pro.daily.limit], ["pro", 100, null]);
  const usage = await (await call(env, "GET", "/ai/admin/usage", { token: ADMIN })).json();
  assert.deepEqual(usage.users, { pro: 1 });
});
