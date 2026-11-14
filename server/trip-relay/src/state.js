// 주인 키마다 하나인 Durable Object `UserState`(SEC1110A02). SQLite 저장소를 쓰는 DO의 KV API(get/put/list/delete)만 쓴다.
// 이 DO가 정본으로 가진 것: 연결 키·OAuth 연결 목록과 영구 폐기 표시, 명령 큐와 24시간 한도, PIN 시도 수,
// 요청 예산(분·일), 카카오 검색 하루 수, 하루 기록 이름표, 한 번만 쓰는 코드. 큰 값(하루 기록·여행 계획)은 KV에 둔다.
// 사용자 글은 Worker가 DEK로 잠근 봉투(sealed)로만 들어온다. DO는 풀 수 없다.
// 요청은 인스턴스 안에서 차례로(serial) 처리한다. 입력 게이트에만 기대지 않는다.
// 이름: 주인 해시(64 hex) 또는 검색 키 해시, IP마다 하루 수는 `ip:<해시>`, 연결 코드는 `code:<해시>`,
// 서버 전체 하루 수는 `global:<이름>`.
import { sha256Hex } from "./crypto.js";
import { clientIp } from "./http.js";

const MINUTE_MS = 60_000;
const DAY_MS = 86_400_000;

export const LIMITS = {
  // 요청 예산(N6): 주인 키는 자기 몫, 연결들은 함께 쓰는 몫과 연결마다의 몫을 따로 센다.
  perMinute: 120,
  perDay: 2000,
  sharedPerMinute: 120,
  sharedPerDay: 2000,
  keyPerMinute: 60,
  keyPerDay: 1000,
  // KV 쓰기(N1): 주인마다 하루 수. 서버 전체 수는 env.KV_DAILY_WRITE_BUDGET(기본 900).
  kvWritesPerDay: 600,
  globalKvWritesPerDay: 900,
  oauthClientsPerIpDay: 10,
  oauthClientsPerDay: 200,
  kakaoPerDay: 500,
  kakaoPerIpDay: 2000,
  days: 62,
  tombstoneMs: 100 * DAY_MS,
  pinResetsPerDay: 3,
  refreshRotateMs: DAY_MS,
  refreshGraceMs: MINUTE_MS,
  lockMs: MINUTE_MS,
  // AI 일 목록(AIX1114A01 P2): 한 사람 100개, 가져간 지 30분 넘으면 대기로, 3번 넘기면 실패, 7일 지나면 만료·삭제.
  rules: 500,
  rulesGone: 200,
  tasks: 100,
  taskGone: 300,
  taskClaimMs: 30 * MINUTE_MS,
  taskAttempts: 3,
  taskLifeMs: 7 * DAY_MS,
  taskClaimBatch: 20,
  commandsPerDay: 100,
  queue: 100,
  bubblesPerDay: 48,
  bubbleQueue: 48,
  activeKeys: 20,
  // 푸시(PSH1114A06): 조용한 것은 종류마다 간격을 두고 하루 60번, 보이는 것은 하루 20번.
  pushGapMs: { cmd: 2 * MINUTE_MS, task: MINUTE_MS, rules: 2 * MINUTE_MS },
  pushSilentPerDay: 60,
  pushVisiblePerDay: 20,
  pinFailures: 5,
  pinWindowMs: 15 * MINUTE_MS,
  pinLockMs: 15 * MINUTE_MS,
  registrationsPerIpDay: 20,
  registrationsPerDay: 500,
  keysPerRequest: 3,
};

// adoptClosed: 「모두 끊기」·PIN 초기화 뒤에는 목록에 없던 예전(v2) 키를 더 받아들이지 않는다(N11).
const NO_LEGACY = { keys: false, queue: false, days: false, daysScopedTried: false, adoptClosed: false };
const seconds = (ms) => Math.max(1, Math.ceil(ms / 1000));
const pad = (n) => String(n).padStart(12, "0");

async function values(s, prefix) {
  return [...(await s.list({ prefix })).entries()];
}

async function activeEntries(s) {
  return (await values(s, "key:")).filter(([, e]) => !e.revoked);
}

// 폐기: 영구 표시만 남기고 봉투·refresh 해시를 지운다. 그 키가 보낸 명령도 지운다(finding 6).
async function revokeEntries(s, entries, now) {
  const keyIds = new Set(entries.map(([, e]) => e.keyId));
  for (const [name, e] of entries) await s.put(name, { keyId: e.keyId, kind: e.kind, revoked: true, revokedAt: now });
  for (const [name, c] of await values(s, "cmd:")) if (keyIds.has(c.keyId)) await s.delete(name);
  return entries.map(([name, e]) => ({
    hash: name.slice(4), keyId: e.keyId, kind: e.kind, refreshHash: e.refreshHash ?? null, prevRefreshHash: e.prevRefreshHash ?? null,
  }));
}

// 오래된 폐기 표시를 지운다(N13). 토큰의 영구 표시는 KV `tomb:`에 남아 있다.
async function pruneTombstones(s, now) {
  for (const [name, e] of await values(s, "key:")) if (e.revoked && (e.revokedAt ?? 0) < now - LIMITS.tombstoneMs) await s.delete(name);
}

async function legacyFlags(s) {
  return { ...NO_LEGACY, ...((await s.get("legacy")) ?? {}) };
}

// 요청 하나를 예산에 센다. entry가 있으면 연결(함께 쓰는 몫 + 그 연결 몫), 없으면 주인 몫.
function chargeBudget(budget, entry, now) {
  const minute = Math.floor(now / MINUTE_MS);
  const day = Math.floor(now / DAY_MS);
  const next = budget?.day === day && budget.keys ? budget : { day, keys: {} };
  const lanes = entry
    ? [[next.keys[entry], LIMITS.keyPerMinute, LIMITS.keyPerDay], [next.shared, LIMITS.sharedPerMinute, LIMITS.sharedPerDay]]
    : [[next.master, LIMITS.perMinute, LIMITS.perDay]];
  const counts = lanes.map(([c]) => ({ d: c?.d ?? 0, m: c?.minute === minute ? c.m : 0, minute }));
  for (const [i, [, perMinute, perDay]] of lanes.entries()) {
    if (counts[i].m >= perMinute) return { error: "rate_limited", retryAfter: seconds((minute + 1) * MINUTE_MS - now) };
    if (counts[i].d >= perDay) return { error: "daily_request_limit", retryAfter: seconds((day + 1) * DAY_MS - now) };
  }
  for (const c of counts) { c.d++; c.m++; }
  if (entry) { next.keys[entry] = counts[0]; next.shared = counts[1]; } else next.master = counts[0];
  return { budget: next };
}

const TASK_OPEN = new Set(["waiting", "processing", "asked"]);
const TASK_PRIORITY = ["payment_text", "receipt_text", "payment_rule"];
const taskRank = (kind) => { const i = TASK_PRIORITY.indexOf(kind); return i < 0 ? TASK_PRIORITY.length : i; };

// 시간이 지난 일을 정리하고 남은 것을 돌려준다. 가져간 지 오래된 것은 대기로, 여러 번 넘긴 것은 실패로,
// 오래 열려 있던 것은 만료로(원문을 지운다), 끝난 지 오래된 것은 지운다.
async function sweepTasks(s, now) {
  const rows = [];
  for (const [name, t] of await values(s, "task:")) {
    if (TASK_OPEN.has(t.status)) {
      if (now - t.createdAt >= LIMITS.taskLifeMs) {
        Object.assign(t, { status: "expired", sealed: null, updatedAt: now, claimedBy: null });
        await s.put(name, t);
      } else if (t.status === "processing" && now - t.updatedAt >= LIMITS.taskClaimMs) {
        const attempts = (t.attempts ?? 1);
        if (attempts >= LIMITS.taskAttempts) Object.assign(t, { status: "failed", code: "timeout", sealed: null, updatedAt: now, claimedBy: null });
        else Object.assign(t, { status: "waiting", claimedBy: null });
        await s.put(name, t);
      }
    } else if (now - t.updatedAt >= LIMITS.taskLifeMs) {
      await s.delete(name);
      continue;
    }
    rows.push(t);
  }
  return rows.sort((a, b) => a.createdAt - b.createdAt || a.id.localeCompare(b.id));
}

const OPS = {
  // MARK: 푸시 기기 토큰과 보낸 수 (PSH1114A06). 토큰은 Worker가 봉인해 넘긴다.

  async pushSet(s, { sealed, sandbox, build, now }) {
    await s.put("push", { sealed, sandbox: !!sandbox, build: build ?? null, at: now });
    return { ok: true };
  },

  async pushGet(s) {
    const push = await s.get("push");
    return push ? { sealed: push.sealed, sandbox: push.sandbox, build: push.build, at: push.at } : {};
  },

  // sealed가 있으면 그 토큰일 때만 지운다(그 사이 앱이 새 토큰을 올렸으면 둔다).
  async pushClear(s, { sealed } = {}) {
    const push = await s.get("push");
    if (!push || (sealed && push.sealed !== sealed)) return { cleared: false };
    await s.delete("push");
    return { cleared: true };
  },

  // 보내도 되는지 보고, 되면 보낸 것으로 적은 뒤 토큰을 돌려준다.
  async pushGate(s, { kind, visible, now }) {
    const push = await s.get("push");
    if (!push) return { ok: false, error: "no_token" };
    const day = Math.floor(now / DAY_MS);
    const sent = (await s.get("pushSent")) ?? {};
    const note = sent.day === day ? sent : { day, silent: 0, visible: 0, last: sent.last ?? {} };
    if (visible) {
      if (note.visible >= LIMITS.pushVisiblePerDay) return { ok: false, error: "daily_push_limit" };
      note.visible++;
    } else {
      const last = note.last[kind] ?? 0;
      if (now >= last && now - last < (LIMITS.pushGapMs[kind] ?? MINUTE_MS)) return { ok: false, error: "too_soon" };
      if (note.silent >= LIMITS.pushSilentPerDay) return { ok: false, error: "daily_push_limit" };
      note.silent++;
      note.last = { ...note.last, [kind]: now };
    }
    await s.put("pushSent", note);
    return { ok: true, sealed: push.sealed, sandbox: push.sandbox };
  },

  // MARK: AI 일 목록 (AIX1114A01 P2). 본문(글·맥락·결과)은 Worker가 봉인해 `sealed`로 넘긴다.

  async taskAdd(s, { items, now }) {
    const rows = await sweepTasks(s, now);
    const meta = (await s.get("tasksMeta")) ?? { gone: [] };
    const known = new Set([...rows.map((t) => t.id), ...meta.gone]);
    let added = 0;
    for (const item of items) {
      if (known.has(item.id)) continue;
      const row = { id: item.id, kind: item.kind, ...(item.date ? { date: item.date } : {}), status: "waiting", attempts: 0, createdAt: now, updatedAt: now, sealed: item.sealed };
      await s.put("task:" + item.id, row);
      rows.push(row);
      known.add(item.id);
      added++;
    }
    // 넘치면 끝난 것부터, 그다음 오래된 것부터 버린다.
    while (rows.length > LIMITS.tasks) {
      const index = rows.findIndex((t) => !TASK_OPEN.has(t.status));
      const [gone] = rows.splice(index >= 0 ? index : 0, 1);
      await s.delete("task:" + gone.id);
    }
    return { added };
  },

  async taskList(s, { now }) {
    return { tasks: await sweepTasks(s, now) };
  },

  // 대기 중인 것과 이 연결이 맡은 것을 준다. 급한 종류부터, 그다음 오래된 것부터. claim이면 맡았다고 적는다.
  async taskClaim(s, { keyId, now, limit, claim = true }) {
    const rows = await sweepTasks(s, now);
    const mine = rows.filter((t) => t.status === "waiting" || (t.status === "processing" && (!t.claimedBy || t.claimedBy === keyId)))
      .sort((a, b) => taskRank(a.kind) - taskRank(b.kind) || a.createdAt - b.createdAt)
      .slice(0, Math.max(1, Math.min(limit ?? LIMITS.taskClaimBatch, LIMITS.taskClaimBatch)));
    if (claim) {
      for (const t of mine) {
        if (t.status === "processing" && t.claimedBy === keyId) continue;
        Object.assign(t, { status: "processing", claimedBy: keyId, attempts: (t.attempts ?? 0) + 1, updatedAt: now });
        await s.put("task:" + t.id, t);
      }
    }
    return { tasks: mine };
  },

  // 맡은 연결만 끝낼 수 있다(다른 연결이 맡고 있으면 not_claimer). askedId가 있으면 사용자 답을 기다리는 상태가 된다.
  async taskFinish(s, { id, keyId, status, sealed, askedId, now }) {
    await sweepTasks(s, now);
    const t = await s.get("task:" + id);
    if (!t) return { ok: false, error: "no_task" };
    if (t.status === "processing" && t.claimedBy && t.claimedBy !== keyId) return { ok: false, error: "not_claimer" };
    Object.assign(t, { status: askedId ? "asked" : status, sealed, updatedAt: now, ...(askedId ? { askedId } : {}) });
    delete t.code;
    await s.put("task:" + id, t);
    return { ok: true, id, status: t.status };
  },

  // 사용자가 답한 질문을 기다리던 일은 다시 대기로 돌아간다.
  async taskAnswered(s, { ids, now }) {
    const answered = new Set(ids);
    let woken = 0;
    for (const [name, t] of await values(s, "task:")) {
      if (t.status !== "asked" || !answered.has(t.askedId)) continue;
      Object.assign(t, { status: "waiting", claimedBy: null, updatedAt: now });
      await s.put(name, t);
      woken++;
    }
    return { woken };
  },

  // 앱이 끝난 것을 지운다. 지운 id는 기억해 같은 id가 다시 와도 되살리지 않는다(AIU1114A01).
  async taskRemoveFinished(s) {
    const meta = (await s.get("tasksMeta")) ?? { gone: [] };
    let removed = 0;
    for (const [name, t] of await values(s, "task:")) {
      if (TASK_OPEN.has(t.status)) continue;
      await s.delete(name);
      meta.gone.push(t.id);
      removed++;
    }
    if (removed > 0) await s.put("tasksMeta", { ...meta, gone: meta.gone.slice(-LIMITS.taskGone) });
    return { removed };
  },

  // 예전 KV 문서(`tasks:<주인>`)를 한 번 옮긴다.
  async taskImport(s, { items, gone, now }) {
    const meta = (await s.get("tasksMeta")) ?? { gone: [] };
    if (meta.imported) return { imported: 0 };
    let imported = 0;
    for (const item of items) {
      if (await s.get("task:" + item.id)) continue;
      await s.put("task:" + item.id, item);
      imported++;
    }
    await s.put("tasksMeta", { gone: [...meta.gone, ...gone].slice(-LIMITS.taskGone), imported: now });
    return { imported };
  },

  // MARK: 규칙 저장소 (AIX1114A01 P3). 기한 없이 둔다. 바뀔 때마다 버전이 1 오른다.

  async ruleList(s) {
    const meta = (await s.get("rulesMeta")) ?? { version: 0 };
    const rules = (await values(s, "rule:")).map(([, r]) => r).sort((a, b) => (a.n ?? 0) - (b.n ?? 0) || a.createdAt - b.createdAt || a.id.localeCompare(b.id));
    return { version: meta.version, updatedAt: meta.updatedAt ?? null, rules, app: meta.app ?? null };
  },

  // 더하거나 같은 id를 고친다. 사용자가 지운 id는 받지 않는다(refused). AI는 사용자가 만든 규칙을 고치지 못한다.
  async rulePut(s, { items, now, master }) {
    const meta = (await s.get("rulesMeta")) ?? { version: 0 };
    const gone = new Set((await s.get("rulesGone")) ?? []);
    const count = (await values(s, "rule:")).length;
    const fresh = [];
    for (const item of items) if (!(await s.get("rule:" + item.id)) && !gone.has(item.id)) fresh.push(item.id);
    if (count + fresh.length > LIMITS.rules) return { error: "too_many_rules" };
    const ids = [], refused = [];
    for (const item of items) {
      const old = await s.get("rule:" + item.id);
      if (gone.has(item.id) || (old && old.by === "user" && !master)) { refused.push(item.id); continue; }
      // 사용자가 꺼 둔 규칙은 AI가 다시 올려도 꺼진 채로 둔다(켜려면 enabled를 적어야 한다).
      const enabled = item.enabled ?? old?.enabled ?? true;
      // n: 넣은 순서. 같은 시각에 넣은 규칙도 순서가 흔들리지 않게 한다.
      const n = old?.n ?? (meta.seq = (meta.seq ?? 0) + 1);
      await s.put("rule:" + item.id, { id: item.id, n, type: item.type, by: old?.by ?? item.by, keyId: item.keyId ?? old?.keyId ?? null, enabled, createdAt: old?.createdAt ?? now, updatedAt: now, sealed: item.sealed });
      ids.push(item.id);
    }
    const version = ids.length ? meta.version + 1 : meta.version;
    if (ids.length) await s.put("rulesMeta", { ...meta, version, updatedAt: now });
    return { version, ids, refused };
  },

  // 켜기·끄기·지우기·넣기. onlyAI면 AI가 만든 규칙만 지운다. 지운 id는 기억한다.
  async ruleOps(s, { ops, now, onlyAI = false }) {
    const meta = (await s.get("rulesMeta")) ?? { version: 0 };
    const gone = (await s.get("rulesGone")) ?? [];
    let changed = 0;
    for (const op of ops) {
      if (op.op === "put") {
        const old = await s.get("rule:" + op.item.id);
        if (!old && (await values(s, "rule:")).length >= LIMITS.rules) return { error: "too_many_rules" };
        const item = op.item;
        const n = old?.n ?? (meta.seq = (meta.seq ?? 0) + 1);
        await s.put("rule:" + item.id, { id: item.id, n, type: item.type, by: old?.by ?? item.by, keyId: old?.keyId ?? item.keyId ?? null, enabled: item.enabled ?? old?.enabled ?? true, createdAt: old?.createdAt ?? now, updatedAt: now, sealed: item.sealed });
        const index = gone.indexOf(item.id);
        if (index >= 0) gone.splice(index, 1);
        changed++;
        continue;
      }
      const rule = await s.get("rule:" + op.id);
      if (!rule) continue;
      if (op.op === "delete") {
        if (onlyAI && rule.by === "user") continue;
        await s.delete("rule:" + op.id);
        gone.push(op.id);
        changed++;
      } else {
        const enabled = op.op === "enable";
        if (rule.enabled === enabled) continue;
        await s.put("rule:" + op.id, { ...rule, enabled, updatedAt: now });
        changed++;
      }
    }
    const version = changed ? meta.version + 1 : meta.version;
    if (changed) {
      await s.put("rulesMeta", { ...meta, version, updatedAt: now });
      await s.put("rulesGone", gone.slice(-LIMITS.rulesGone));
    }
    return { before: meta.version, version, changed };
  },

  async ruleAck(s, { version, engine, skipped, now }) {
    const meta = (await s.get("rulesMeta")) ?? { version: 0 };
    await s.put("rulesMeta", { ...meta, app: { version, engine, skipped, seenAt: now } });
    return { ok: true };
  },

  // MARK: 등록·입장

  async register(s, { purpose, now }) {
    const current = await s.get("registration");
    if (current) return current.purpose === purpose ? { ok: true, created: false } : { ok: false, error: "purpose_conflict" };
    await s.put("registration", { purpose, at: now });
    return { ok: true, created: true };
  },

  // 모든 인증 요청이 지나간다: 등록·키 유효성·분당/일당 예산·카카오 하루 수를 한 번에 본다.
  async admit(s, { now, registration, entry, adopt, kakao, client }) {
    const reg = await s.get("registration");
    if (registration && !reg) return { ok: false, error: "unregistered" };
    if (entry) {
      const known = await s.get("key:" + entry);
      if (known?.revoked) return { ok: false, error: "revoked" };
      if (!known) {
        // 예전(v2) 감싼 기록은 주인이 만든 것이다. 목록에 없던 키(finding 5의 경쟁 잔여)도 보이게 넣는다.
        if (!adopt) return { ok: false, error: "unknown_key" };
        if ((await legacyFlags(s)).adoptClosed) {
          await s.put("key:" + entry, { keyId: adopt.keyId, kind: "key", revoked: true, revokedAt: now });
          return { ok: false, error: "revoked", tomb: true };
        }
        await s.put("key:" + entry, { keyId: adopt.keyId, kind: "key", info: adopt.info, revoked: false, createdAt: now });
      }
    }
    const day = Math.floor(now / DAY_MS);
    const charged = chargeBudget(await s.get("budget"), entry, now);
    if (charged.error) return { ok: false, ...charged };
    if (kakao) {
      const k = (await s.get("kakao")) ?? {};
      const count = k.day === day ? k.count : 0;
      if (count >= LIMITS.kakaoPerDay) return { ok: false, error: "kakao_daily_limit", retryAfter: seconds((day + 1) * DAY_MS - now) };
      await s.put("kakao", { day, count: count + 1 });
    }
    await s.put("budget", charged.budget);
    // AI 연결 키(주 키가 아닌 것)가 마지막으로 온 때. 앱이 AI와 대화 중인지 보고 확인 간격을 정한다(SYN1111A03).
    // 10초 안에 다시 오면 쓰지 않는다(저장 쓰기 절약).
    if (!registration && entry && !((await s.get("aiSeen")) > now - 10_000)) await s.put("aiSeen", now);
    // 앱(주 키)이 마지막으로 온 때와 그 기기(AIC1112A01). 1분 안에 다시 오면 기기 정보가 바뀌었을 때만 쓴다.
    if (registration && reg?.purpose !== "search") {
      const seen = await s.get("appSeen");
      const next = client ?? seen?.client ?? null;
      if (!(seen?.at > now - MINUTE_MS) || JSON.stringify(seen.client ?? null) !== JSON.stringify(next)) await s.put("appSeen", { at: now, client: next });
    }
    return { ok: true, purpose: reg?.purpose ?? null, legacy: await legacyFlags(s) };
  },

  // AI가 대화를 마쳤다고 알림(SYN1111A03). 앱은 빠른 확인을 바로 멈춘다.
  async endSession(s, { now }) {
    await s.put("aiEnded", now);
    return { ok: true };
  },

  async markLegacy(s, flags) {
    await s.put("legacy", { ...(await legacyFlags(s)), ...flags });
    return { ok: true };
  },

  // 옮기기 작업을 한 요청만 하게 한다(N11). 1분 지나면 풀린다.
  async claim(s, { name, now }) {
    const held = (await s.get("lock:" + name)) ?? 0;
    if (held > now - LIMITS.lockMs) return { ok: false };
    await s.put("lock:" + name, now);
    return { ok: true };
  },

  async release(s, { name }) {
    await s.delete("lock:" + name);
    return { ok: true };
  },

  // 하루 수 세기: 주인의 KV 쓰기, `ip:`·`global:` 인스턴스의 등록·검색 수. expire면 다음 날 인스턴스를 비운다.
  async countDaily(s, { name, limit, amount = 1, now, expire = false }) {
    const day = Math.floor(now / DAY_MS);
    const row = (await s.get("count:" + name)) ?? {};
    const count = row.day === day ? row.count : 0;
    if (count + amount > limit) return { ok: false, retryAfter: seconds((day + 1) * DAY_MS - now) };
    await s.put("count:" + name, { day, count: count + amount });
    if (expire && s.setAlarm) await s.setAlarm((day + 1) * DAY_MS + MINUTE_MS);
    return { ok: true };
  },

  // MARK: PIN (DEK로 잠근 검증값과 시도 수)

  async getPin(s, { now }) {
    const pin = await s.get("pin");
    const attempts = (await s.get("pinAttempts")) ?? {};
    return { sealed: pin?.sealed ?? null, lockedUntil: attempts.lockedUntil > now ? attempts.lockedUntil : null, epoch: (await s.get("epoch")) ?? 0 };
  },

  // PIN 초기화(주인만): 검증값·잠금을 지우고 모든 연결을 끊는다. epoch를 올려 대기 중인 연결 코드·승인 코드도 못 쓰게 한다.
  async resetPin(s, { now }) {
    const day = Math.floor(now / DAY_MS);
    const resets = (await s.get("pinResets")) ?? {};
    const count = resets.day === day ? resets.count : 0;
    if (count >= LIMITS.pinResetsPerDay) return { ok: false, retryAfter: seconds((day + 1) * DAY_MS - now) };
    await s.put("pinResets", { day, count: count + 1 });
    await s.delete("pin");
    await s.delete("pinAttempts");
    await s.put("epoch", ((await s.get("epoch")) ?? 0) + 1);
    await s.put("legacy", { ...(await legacyFlags(s)), adoptClosed: true });
    await s.delete("push");
    return { ok: true, revoked: await revokeEntries(s, await activeEntries(s), now) };
  },

  async setPin(s, { sealed }) {
    await s.put("pin", { sealed });
    return { ok: true };
  },

  // 비교 결과를 한 번에 기록한다. 15분 안에 5번 틀리면 15분 잠근다. 잠긴 동안은 맞아도 거절한다.
  async recordPin(s, { ok, now }) {
    const attempts = (await s.get("pinAttempts")) ?? { failures: [], lockedUntil: 0 };
    if (attempts.lockedUntil > now) return { ok: false, locked: true, lockedUntil: attempts.lockedUntil };
    if (ok) {
      await s.put("pinAttempts", { failures: [], lockedUntil: 0 });
      return { ok: true };
    }
    const failures = (attempts.failures ?? []).filter((t) => t > now - LIMITS.pinWindowMs).concat(now);
    if (failures.length >= LIMITS.pinFailures) {
      const lockedUntil = now + LIMITS.pinLockMs;
      await s.put("pinAttempts", { failures: [], lockedUntil });
      return { ok: false, locked: true, lockedUntil };
    }
    await s.put("pinAttempts", { failures, lockedUntil: 0 });
    return { ok: false, remaining: LIMITS.pinFailures - failures.length };
  },

  // MARK: 키 목록 (finding 5, 10)

  async listEntries(s) {
    return { entries: (await activeEntries(s)).map(([name, e]) => ({ hash: name.slice(4), keyId: e.keyId, kind: e.kind, info: e.info })) };
  },

  // tombed: 그 토큰에 영구 표시가 있다. 이 목록에 없으면 다른 사람의 키다.
  async addEntries(s, { entries, prune = [], now }) {
    await pruneTombstones(s, now);
    for (const hash of prune) {
      const e = await s.get("key:" + hash);
      if (e && !e.revoked) await s.put("key:" + hash, { keyId: e.keyId, kind: e.kind, revoked: true, revokedAt: now, expired: true });
    }
    const active = new Map(await activeEntries(s));
    let added = 0;
    for (const e of entries) {
      const known = await s.get("key:" + e.hash);
      if (known?.revoked) return { ok: false, error: "revoked_key" };
      if (!known && e.tombed) return { ok: false, error: "key_conflict" };
      if (!active.has("key:" + e.hash)) added++;
    }
    if (active.size + added > LIMITS.activeKeys) return { ok: false, error: "too_many_keys" };
    const created = [];
    for (const e of entries) {
      const known = await s.get("key:" + e.hash);
      if (!known) created.push(e.hash);
      await s.put("key:" + e.hash, { keyId: e.keyId, kind: e.kind, info: e.info, revoked: false, createdAt: known?.createdAt ?? now });
    }
    return { ok: true, created };
  },

  // 감싼 기록을 쓰지 못했을 때 방금 만든 줄을 없던 일로 한다(N1).
  async dropEntries(s, { hashes }) {
    for (const hash of hashes) await s.delete("key:" + hash);
    return { ok: true };
  },

  // 예전 KV 목록(`keys:<주인>`)을 가져온다. 이미 있는 것(폐기 포함)은 건드리지 않는다.
  async importEntries(s, { entries, now }) {
    for (const e of entries) {
      if (!(await s.get("key:" + e.hash))) await s.put("key:" + e.hash, { keyId: e.keyId, kind: "key", info: e.info, revoked: false, createdAt: now });
    }
    return { ok: true };
  },

  async revoke(s, { keyId, now }) {
    await pruneTombstones(s, now);
    const entries = (await activeEntries(s)).filter(([, e]) => keyId === null || e.keyId === keyId);
    if (keyId === null) {
      await s.put("legacy", { ...(await legacyFlags(s)), adoptClosed: true });
      await s.delete("push"); // 모두 끊으면 깨울 일이 없다. 다시 연결하면 앱이 토큰을 새로 올린다.
    }
    return { revoked: await revokeEntries(s, entries, now) };
  },

  // MARK: OAuth (AIR1110A03)

  // 승인 코드를 바꿔 연결(grant)을 만든다. 같은 코드를 다시 쓰면 그 코드로 만든 연결을 폐기한다(RFC 6749 4.1.2).
  // epoch: 코드를 만든 뒤 PIN을 초기화했으면 거절한다.
  async createGrant(s, { hash, keyId, info, refreshHash, codeTag, epoch, now }) {
    const used = await s.get("used:" + codeTag);
    if (used) {
      const grant = used.grant && (await s.get("key:" + used.grant));
      if (grant && !grant.revoked) await revokeEntries(s, [["key:" + used.grant, grant]], now);
      return { ok: false, error: "code_used", revoked: grant?.refreshHash ?? null };
    }
    if (epoch !== ((await s.get("epoch")) ?? 0)) return { ok: false, error: "stale_code" };
    await pruneTombstones(s, now);
    if ((await activeEntries(s)).length >= LIMITS.activeKeys) return { ok: false, error: "too_many_keys" };
    await s.put("used:" + codeTag, { at: now, grant: hash });
    await s.put("key:" + hash, { keyId, kind: "oauth", info, refreshHash, revoked: false, createdAt: now, rotatedAt: now });
    return { ok: true };
  },

  // 토큰 기록을 쓰지 못했을 때 연결과 코드 사용 표시를 되돌린다(N1). 클라이언트는 2분 안에 다시 바꿀 수 있다.
  async abortGrant(s, { hash, codeTag }) {
    await s.delete("key:" + hash);
    await s.delete("used:" + codeTag);
    return { ok: true };
  },

  // refresh 토큰은 하루에 한 번 바꾼다(N1: 바꿀 때만 KV에 쓴다). 바꾼 직후 1분은 예전 토큰도 받아 같은 새 토큰을 돌려준다(N8).
  // 그 뒤에 예전 토큰이 오면(도난 의심) 연결 전체를 폐기한다. nonce: 다음 토큰을 정하는 값(같은 요청이 겹쳐도 하나).
  async useRefresh(s, { hash, presented, nonce, now }) {
    const grant = await s.get("key:" + hash);
    if (!grant || grant.revoked) return { ok: false, error: "revoked" };
    if (grant.refreshHash === presented) {
      if (now - (grant.rotatedAt ?? grant.createdAt) < LIMITS.refreshRotateMs) return { ok: true, rotate: false };
      if (!grant.nextNonce) await s.put("key:" + hash, { ...grant, nextNonce: nonce });
      return { ok: true, rotate: true, nonce: grant.nextNonce ?? nonce };
    }
    if (grant.prevRefreshHash === presented && now - grant.rotatedAt < LIMITS.refreshGraceMs) return { ok: true, rotate: true, nonce: grant.prevNonce };
    await revokeEntries(s, [["key:" + hash, grant]], now);
    return { ok: false, error: "reuse", revoked: [grant.refreshHash, grant.prevRefreshHash].filter(Boolean) };
  },

  async commitRefresh(s, { hash, presented, next, info, now }) {
    const grant = await s.get("key:" + hash);
    if (!grant || grant.revoked) return { ok: false };
    if (grant.refreshHash === next) return { ok: true };
    if (grant.refreshHash !== presented) return { ok: false };
    const { nextNonce, ...rest } = grant;
    await s.put("key:" + hash, { ...rest, refreshHash: next, prevRefreshHash: presented, prevNonce: nextNonce, rotatedAt: now, info });
    return { ok: true };
  },

  // MARK: 연결 코드 (`code:<해시>` 인스턴스, N15). 기록은 서버 비밀과 코드로 잠근 봉투다.

  async putCode(s, { sealed, expiresAt }) {
    await s.put("code", { sealed, expiresAt });
    if (s.setAlarm) await s.setAlarm(expiresAt + MINUTE_MS);
    return { ok: true };
  },

  async getCode(s, { now }) {
    const code = await s.get("code");
    return { sealed: code && code.expiresAt > now ? code.sealed : null };
  },

  // 한 번만 성공한다.
  async takeCode(s, { now }) {
    const code = await s.get("code");
    if (!code || code.expiresAt <= now) return { ok: false };
    await s.delete("code");
    return { ok: true };
  },

  // MARK: 명령 큐 (finding 6, 8)

  // bubble: 말풍선(BUB1110A01)은 따로 세고(48개) 따로 자른다. 말풍선이 다른 명령을 밀어내지 않는다.
  async enqueue(s, { tag, keyId, source, sealed, now, bubble = false }) {
    const meta = (await s.get("queueMeta")) ?? { sent: [], seq: 0 };
    const field = bubble ? "bubbleSent" : "sent";
    const limit = bubble ? LIMITS.bubblesPerDay : LIMITS.commandsPerDay;
    const keep = bubble ? LIMITS.bubbleQueue : LIMITS.queue;
    const recent = (meta[field] ?? []).filter((t) => t > now - DAY_MS).sort((a, b) => a - b);
    if (recent.length >= limit) {
      return { ok: false, error: bubble ? "daily_bubble_limit" : "daily_command_limit", retryAfter: seconds(recent[recent.length - limit] + DAY_MS - now) };
    }
    let items = await values(s, "cmd:");
    // 같은 id는 같은 연결이 보낸 것만 새 값으로 바꾼다(N10). 다른 연결의 id는 덮지 못한다.
    if (items.some(([, c]) => c.tag === tag && c.keyId !== keyId)) return { ok: false, error: "id_conflict" };
    // 일반 명령은 꽉 차면 오래된 것을 버리지 않고 새 것을 거절한다(AIP1114A05). 같은 id를 바꾸는 것은 받는다.
    if (!bubble && items.filter(([, c]) => c.tag !== tag && !c.bubble).length >= keep) return { ok: false, error: "queue_full" };
    for (const [name, c] of items) if (c.tag === tag) await s.delete(name);
    items = items.filter(([, c]) => c.tag !== tag && !!c.bubble === bubble);
    const seq = meta.seq + 1;
    await s.put("cmd:" + pad(seq), { tag, keyId, source, sealed, receivedAt: now, ...(bubble ? { bubble: true } : {}) });
    items.push(["cmd:" + pad(seq), { receivedAt: now }]);
    items.sort(([a, x], [b, y]) => x.receivedAt - y.receivedAt || a.localeCompare(b));
    for (const [name] of items.slice(0, Math.max(0, items.length - keep))) await s.delete(name);
    await s.put("queueMeta", { ...meta, [field]: recent.concat(now), seq });
    return { ok: true, queued: Math.min(items.length, keep), remaining: limit - recent.length - 1 };
  },

  async listQueue(s, { now }) {
    const items = [];
    for (const [name, c] of await values(s, "cmd:")) {
      if (c.receivedAt <= now - 7 * DAY_MS) await s.delete(name);
      else items.push({ name, ...c });
    }
    items.sort((a, b) => a.receivedAt - b.receivedAt || a.name.localeCompare(b.name));
    return { aiSeen: (await s.get("aiSeen")) ?? null, aiEnded: (await s.get("aiEnded")) ?? null, commands: items.map(({ tag, keyId, source, sealed, receivedAt }) => ({ tag, keyId, source, sealed, receivedAt })) };
  },

  // tags가 null이면 전부. 24시간 받은 수는 남긴다(앱이 비울 때마다 한도가 풀리지 않게).
  async removeQueue(s, { tags }) {
    const remove = tags ? new Set(tags) : null;
    let removed = 0;
    for (const [name, c] of await values(s, "cmd:")) {
      if (!remove || remove.has(c.tag)) { await s.delete(name); removed++; }
    }
    return { removed };
  },

  // 예전 KV 큐(`cmd:<주인>`)를 합친다. 받은 시각 순, 최근 100개.
  async importQueue(s, { items, sent }) {
    const meta = (await s.get("queueMeta")) ?? { sent: [], seq: 0 };
    const existing = await values(s, "cmd:");
    const tags = new Set(existing.map(([, c]) => c.tag));
    let seq = meta.seq;
    for (const item of items) {
      if (tags.has(item.tag)) continue;
      seq++;
      await s.put("cmd:" + pad(seq), { tag: item.tag, keyId: null, source: "legacy", sealed: item.sealed, receivedAt: item.receivedAt });
    }
    const all = (await values(s, "cmd:")).filter(([, c]) => !c.bubble).sort(([a, x], [b, y]) => x.receivedAt - y.receivedAt || a.localeCompare(b));
    for (const [name] of all.slice(0, Math.max(0, all.length - LIMITS.queue))) await s.delete(name);
    await s.put("queueMeta", { ...meta, sent: [...new Set([...(meta.sent ?? []), ...sent])], seq });
    return { ok: true };
  },

  // MARK: 하루 기록 이름표 (finding 11). date는 DEK로 잠근 날짜, exp는 KV 만료 시각(ms).

  async listDays(s) {
    return { days: (await values(s, "day:")).map(([, d]) => d) };
  },

  // 만료된 줄을 지우고, 62줄을 넘으면 먼저 끝나는 날부터 뺀다(N13). 뺀 이름은 Worker가 KV에서 지운다.
  async putDays(s, { days, now }) {
    await s.put("appUploaded", now);
    for (const d of days) await s.put("day:" + d.name, d);
    const rows = (await values(s, "day:")).sort(([, a], [, b]) => a.exp - b.exp);
    const live = rows.filter(([, d]) => d.exp > now);
    const over = live.slice(0, Math.max(0, live.length - LIMITS.days));
    for (const [name, d] of rows) if (d.exp <= now) await s.delete(name);
    for (const [name] of over) await s.delete(name);
    return { ok: true, dropped: over.map(([, d]) => d.name) };
  },

  // 앱이 다녀간 때·올린 때·기기 정보(AIC1112A01). 없으면 null.
  async syncInfo(s) {
    const seen = await s.get("appSeen");
    return { seenAt: seen?.at ?? null, uploadedAt: (await s.get("appUploaded")) ?? null, client: seen?.client ?? null };
  },

  // names가 null이면 전부.
  async removeDays(s, { names }) {
    for (const [name, d] of await values(s, "day:")) if (!names || names.includes(d.name)) await s.delete(name);
    return { ok: true };
  },
};

export class UserState {
  constructor(ctx) {
    this.storage = ctx.storage;
    this.chain = Promise.resolve();
  }

  serial(run) {
    const next = this.chain.then(run);
    this.chain = next.catch(() => {});
    return next;
  }

  async fetch(request) {
    const op = OPS[new URL(request.url).pathname.slice(1)];
    if (!op) return new Response("unknown op", { status: 404 });
    const args = await request.json();
    const result = await this.serial(() => op(this.storage, args));
    return new Response(JSON.stringify(result ?? {}), { headers: { "content-type": "application/json" } });
  }

  // `ip:`·`code:` 인스턴스만 알람을 건다.
  async alarm() {
    await this.storage.deleteAll();
  }
}

// Worker 쪽 호출. `await userState(env, name).call("admit", {...})`.
export function userState(env, name) {
  const namespace = env.USER_STATE;
  const stub = namespace.get(namespace.idFromName(name));
  return {
    async call(op, args = {}) {
      const response = await stub.fetch(`https://user-state/${op}`, { method: "POST", body: JSON.stringify(args) });
      if (!response.ok) throw new Error(`user-state ${op}: ${response.status}`);
      return response.json();
    },
  };
}

export const ipState = async (env, request) => userState(env, "ip:" + (await sha256Hex("ip|" + clientIp(request))));

// IP마다, 그리고 서버 전체로 하루 수를 센다. 넘으면 { ok: false, retryAfter }.
export async function countPerIpAndGlobal(env, request, name, perIp, global, now) {
  const own = await (await ipState(env, request)).call("countDaily", { name, limit: perIp, now, expire: true });
  if (!own.ok) return own;
  return userState(env, "global:" + name).call("countDaily", { name, limit: global, now });
}

// KV 쓰기 예산(N1). 주인의 하루 몫과 서버 전체 하루 몫에서 뺀다. 넘으면 쓰기 전에 429로 끝낸다.
export async function chargeWrites(env, state, writes, now) {
  if (writes <= 0) return { ok: true };
  if (state) {
    const own = await state.call("countDaily", { name: "writes", limit: LIMITS.kvWritesPerDay, amount: writes, now });
    if (!own.ok) return { ...own, error: "daily_write_limit" };
  }
  const limit = Number(env.KV_DAILY_WRITE_BUDGET) || LIMITS.globalKvWritesPerDay;
  const all = await userState(env, "global:writes").call("countDaily", { name: "writes", limit, amount: writes, now });
  return all.ok ? all : { ...all, error: "write_budget_exhausted" };
}
