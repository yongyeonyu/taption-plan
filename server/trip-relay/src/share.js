// 여행 공유 방(TSH1114A26). 규약의 정본은 docs/TRIP_SHARE_PROTOCOL.md이고, 이 파일은 그 서버 쪽이다.
// 방 하나 = Durable Object `ShareRoom` 하나(이름 `room:<방 id>`). 기기가 암호화한 덩어리(cipher)만 받고 풀 수 없다.
// 서버가 아는 것: 방 id, 참여자 번호와 수, 항목 id·종류(kind)·묶음 이름(group)·크기·개정 번호·시각, 잠금, 공지 확인.
// 링크 비밀 값·비밀번호·닉네임은 오지 않는다. 입장 증명·주인 열쇠·참여 토큰은 SHA-256 검증값으로만 둔다. 아무것도 로그에 쓰지 않는다.
import { randomToken, sameText, sha256Hex } from "./crypto.js";
import { MAX_BODY_BYTES, json, limited, readText, tooMany } from "./http.js";
import { ipState, userState } from "./state.js";

const MINUTE_MS = 60_000;
const DAY_MS = 86_400_000;

export const SHARE = {
  members: 10, // 주인 포함, 지금 들어와 있는 수
  memberNumbers: 100, // 방이 사는 동안 나눠 주는 참여자 번호(다시 쓰지 않는다)
  itemBytes: 4096, // 암호문 하나(풀기 전 바이트)
  liveItems: 1000,
  itemIds: 3000, // 묘비 포함
  roomBytes: 1024 * 1024,
  batch: 50,
  bodyBytes: MAX_BODY_BYTES,
  rotateBodyBytes: 2 * 1024 * 1024,
  locksPerMember: 20,
  leaseMs: 2 * MINUTE_MS,
  socketsPerMember: 2,
  joinFailures: 5,
  joinWindowMs: 15 * MINUTE_MS,
  joinLockMs: 15 * MINUTE_MS,
  joinsPerIpDay: 60,
  roomsPerOwnerDay: 5,
  roomsPerDay: 300,
  minLifeMs: 60 * MINUTE_MS,
  maxLifeMs: 400 * DAY_MS,
  opsPerMinute: 240,
  changesPage: 200,
  changesChars: 256 * 1024,
  // 여행 중 동행 위치(LOC1116S01). 서버는 암호문만 다룬다.
  locBytes: 512, // 위치 암호문 하나(풀기 전 바이트)
  locGapMs: 5_000, // 한 사람이 위치를 보내는 최소 간격(도움 요청은 제외)
  locPerMinute: 20,
  locKeep: true, // 암호화된 마지막 위치를 짧게 둔다. false면 전달만 한다.
  locStoreGapMs: 90_000, // 저장은 이 간격보다 자주 하지 않는다(방송은 매번).
  locHelpStoreGapMs: 10_000, // 도움 요청을 이어 보낼 때의 저장 간격.
  locKeepMs: 10 * MINUTE_MS,
  locHelpKeepMs: 24 * 60 * MINUTE_MS,
  locWindowMaxMs: 40 * DAY_MS,
};

export const KINDS = ["plan", "expense-shared", "expense-own", "notice", "member", "meta", "meet"];
const LOCKED_KINDS = new Set(["plan", "expense-shared"]); // 여럿이 고칠 수 있는 종류만 잠금을 본다.
export const ROOM_PATH = /^\/share\/rooms\/([A-Za-z0-9_-]{22})(?:\/([a-z]+))?$/;
const ROOM_ID = /^[A-Za-z0-9_-]{22}$/;
const SECRET = /^[A-Za-z0-9_-]{43}$/; // 32바이트 base64url
const ITEM_ID = /^[A-Za-z0-9_-]{8,64}$/;
const GROUP = /^[A-Za-z0-9_-]{1,64}$/;
const LOCK_NAME = /^(?:i:[A-Za-z0-9_-]{8,64}|g:[A-Za-z0-9_-]{1,64})$/;
// 암호문: base64url(0x01 || nonce 12 || AES-GCM 암호문 || tag 16). 첫 바이트 0x01은 글자 "A" + "Q".."f".
const CIPHER = /^A[Q-Za-f][A-Za-z0-9_-]*$/;
const CIPHER_MIN_BYTES = 1 + 12 + 16;
export const CLOSE = { kicked: 4000, rekey: 4001, gone: 4002, replaced: 4003, tooBig: 1009 };

const pad = (n) => String(n).padStart(12, "0");
const isInt = (v, min = 0) => Number.isSafeInteger(v) && v >= min;
const cipherBytes = (text) => Math.floor((text.length * 3) / 4);
const digest = (label, roomId, secret) => sha256Hex(`share|${label}|${roomId}|${secret}`);
const reply = (status, body = null, headers) => ({ status, body, headers });
const fail = (status, error, extra = {}) => reply(status, { error, ...extra });
const busy = (error, ms) => {
  const retryAfter = Math.max(1, Math.ceil(ms / 1000));
  return reply(429, { error, retryAfter }, { "retry-after": String(retryAfter) });
};
const toResponse = (r) => (r instanceof Response ? r : json(r.body, r.status, r.headers ?? {}));
const publicLimits = () => ({
  members: SHARE.members, itemBytes: SHARE.itemBytes, liveItems: SHARE.liveItems, roomBytes: SHARE.roomBytes,
  batch: SHARE.batch, locksPerMember: SHARE.locksPerMember, leaseMs: SHARE.leaseMs,
});

function cipherError(cipher) {
  if (typeof cipher !== "string" || !CIPHER.test(cipher) || cipher.length % 4 === 1 || cipherBytes(cipher) < CIPHER_MIN_BYTES) return [422, "bad_cipher"];
  return cipherBytes(cipher) > SHARE.itemBytes ? [413, "item_too_large"] : null;
}

function writeError(w) {
  if (!w || typeof w !== "object" || typeof w.id !== "string" || !ITEM_ID.test(w.id) || !isInt(w.baseRev)) return [422, "bad_request"];
  if (w.delete !== undefined) return w.delete === true && w.baseRev > 0 ? null : [422, "bad_request"];
  if (!KINDS.includes(w.kind) || (w.kind === "member") !== w.id.startsWith("member-")) return [422, "bad_request"];
  if (w.group !== undefined && w.group !== null && (typeof w.group !== "string" || !GROUP.test(w.group))) return [422, "bad_request"];
  return cipherError(w.cipher);
}

// kind마다 누가 쓰는가. old: 지금 있는 항목(없으면 만들기). 반환: null이면 됨.
function denied(kind, me, old, w, room, now) {
  const mine = !old || old.cb === me.no;
  switch (kind) {
    case "plan": return null;
    case "expense-shared": return room.closed ? [423, "settlement_closed"] : null;
    case "expense-own": return mine ? null : [403, "forbidden"];
    case "notice": return mine || (w.delete && me.no === 1) ? null : [403, "forbidden"];
    case "member": return w.id === "member-" + me.no && !w.delete ? null : [403, "forbidden"];
    case "meta": return me.no === 1 ? null : [403, "forbidden"];
    // 모이는 곳(LOC1116S01): 방에 하나(id 고정), 누구나 정한다. 지우지 않고 「해제」 내용으로 덮어쓴다(지운 id는 다시 못 쓰므로).
    // 좌표가 든 항목이라 위치 기간 창 안에서만 올린다.
    case "meet": {
      if (w.id !== "meet-point" || w.delete) return [422, "bad_request"];
      const window = room.locWindow;
      return window && now >= window.from && now < window.until ? null : [403, "loc_closed"];
    }
    default: return [422, "bad_request"];
  }
}

const wire = (i) => (i.del
  ? { id: i.id, kind: i.kind, rev: i.rev, seq: i.seq, deleted: true, updatedAt: i.at, by: i.by, createdBy: i.cb }
  : {
    id: i.id, kind: i.kind, rev: i.rev, seq: i.seq, epoch: i.epoch, cipher: i.cipher, updatedAt: i.at, by: i.by, createdBy: i.cb,
    ...(i.group ? { group: i.group } : {}), ...(i.kind === "notice" ? { acks: i.acks ?? {} } : {}),
  });

// 지난 임대를 걷어 내고 남은 잠금을 준다.
function liveLocks(room, now) {
  for (const [name, lock] of Object.entries(room.locks)) if (lock.until <= now) delete room.locks[name];
  return Object.entries(room.locks).map(([name, lock]) => ({ name, by: lock.by, until: lock.until }));
}
const lockInfo = (room, name) => ({ name, by: room.locks[name].by, until: room.locks[name].until });
const activeMembers = (room) => room.members.filter((m) => !m.gone);

// 쓰기를 모아 await 없이 한꺼번에 낸다. DO 저장소는 사이에 await가 없는 쓰기를 하나로 묶어 원자적으로 적는다. 한 번에 128개까지.
class Batch {
  constructor(storage) { this.storage = storage; this.puts = new Map(); this.dels = new Set(); }
  put(key, value) { this.dels.delete(key); this.puts.set(key, value); }
  delete(key) { this.puts.delete(key); this.dels.add(key); }
  commit() {
    const work = [], dels = [...this.dels], puts = [...this.puts];
    for (let i = 0; i < dels.length; i += 128) work.push(this.storage.delete(dels.slice(i, i + 128)));
    for (let i = 0; i < puts.length; i += 128) work.push(this.storage.put(Object.fromEntries(puts.slice(i, i + 128))));
    return Promise.all(work);
  }
}

export class ShareRoom {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.storage = ctx.storage;
    this.env = env ?? {};
    this.chain = Promise.resolve();
    this.locRates = new Map(); // 참여자 번호 → 위치 보내기 횟수·마지막 시각(메모리)
    this.rates = new Map(); // 참여자 번호 → 이번 분의 요청 수(메모리, 잠들면 0부터)
    // 글자 "ping"에는 DO를 깨우지 않고 "pong"을 돌려준다.
    if (typeof WebSocketRequestResponsePair !== "undefined") ctx.setWebSocketAutoResponse?.(new WebSocketRequestResponsePair("ping", "pong"));
  }

  now() { return this.env.NOW?.() ?? Date.now(); }

  serial(run) {
    const next = this.chain.then(run);
    this.chain = next.catch(() => {});
    return next;
  }

  async fetch(request) {
    const url = new URL(request.url);
    return toResponse(await this.serial(() => this.http(request, url, this.now())));
  }

  async readJson(request, max = SHARE.bodyBytes) {
    const text = await readText(request, max);
    if (text.error) return { error: fail(413, "too_large") };
    try { return { value: JSON.parse(text.value) }; } catch { return { error: fail(400, "invalid_json") }; }
  }

  // MARK: HTTP

  async http(request, url, now) {
    if (url.pathname === "/create") return this.create((await request.json()), now); // Worker만 부른다.
    const [, , sub = ""] = ROOM_PATH.exec(url.pathname) ?? [];
    const room = await this.liveRoom(now);
    if (!room) return fail(404, "not_found");
    const method = request.method;
    const op = `${method} ${sub}`;
    if (op === "POST join") return this.withBody(request, (body) => this.join(room, body, now));

    const found = await this.authenticate(room, request);
    if (found.error) return found.error;
    const me = found.member;
    const over = this.rate(me.no, now);
    if (over) return over;
    if (op === "POST rekey") return this.withBody(request, (body) => this.rekey(room, me, body, now));
    if (op === "POST leave") return me.no === 1 ? fail(409, "owner_cannot_leave") : this.remove(room, me, "left", now);
    if (me.epoch !== room.epoch) return fail(409, "rekey_required", { epoch: room.epoch });

    switch (op) {
      case "GET ": return reply(200, this.describe(room, me, now));
      case "GET changes": return this.changes(room, { since: Number(url.searchParams.get("since") ?? 0), limit: Number(url.searchParams.get("limit") ?? SHARE.changesPage) });
      case "GET ws": return this.connect(room, me, request, now);
      case "POST items": return this.withBody(request, (body) => this.write(room, me, body, now));
      case "POST locks": return this.withBody(request, (body) => this.lock(room, me, body, now));
      case "POST acks": return this.withBody(request, (body) => this.ack(room, me, body, now));
      case "PUT loc": return this.withBody(request, (body) => this.loc(room, me, body, now));
      case "DELETE loc": return this.locOff(room, me, now);
      case "GET loc": return reply(200, { locs: await this.readLocs(now), locWindow: room.locWindow ?? null, now });
      default:
    }
    const ownerOps = { "POST locwindow": "locWindow", "DELETE ": "erase", "POST kick": "kick", "POST close": "close", "POST expiry": "extend", "POST rotate": "rotate" };
    const name = ownerOps[op];
    if (!name) return fail(ROOM_SUBS.has(sub) ? 405 : 404, ROOM_SUBS.has(sub) ? "method_not_allowed" : "not_found");
    const ownerKey = request.headers.get("x-share-owner") ?? "";
    if (me.no !== 1 || !SECRET.test(ownerKey) || !sameText(await digest("owner", room.id, ownerKey), room.owner)) return fail(403, "owner_only");
    if (name === "erase") { await this.purge("deleted"); return reply(204); }
    return this.withBody(request, (body) => this[name](room, me, body, now), name === "rotate" ? SHARE.rotateBodyBytes : SHARE.bodyBytes);
  }

  async withBody(request, run, max) {
    const body = await this.readJson(request, max);
    return body.error ?? run(body.value ?? {});
  }

  // 기한이 지난 방은 알람을 기다리지 않고 지운다.
  async liveRoom(now) {
    const room = await this.storage.get("room");
    if (!room) return null;
    if (now >= room.expiresAt) { await this.purge("expired"); return null; }
    await this.sweepMeet(room, now);
    return room;
  }

  // 위치 기간이 끝나면 좌표가 든 「모이는 곳」을 묘비로 바꾼다(여행 기간 밖에는 좌표가 남지 않게). 기간마다 한 번만 한다.
  async sweepMeet(room, now) {
    const window = room.locWindow;
    if (!window || now < window.until || room.meetSwept === window.until) return;
    room.meetSwept = window.until;
    const item = await this.storage.get("i:meet-point");
    if (item && !item.del) {
      const batch = new Batch(this.storage);
      const rev = ++room.rev;
      batch.delete("r:" + pad(item.seq));
      const tomb = { id: item.id, kind: item.kind, rev, seq: rev, at: now, by: item.by, cb: item.cb, del: true };
      batch.put("i:" + item.id, tomb);
      batch.put("r:" + pad(rev), item.id);
      room.live = Math.max(0, room.live - 1);
      room.bytes = Math.max(0, room.bytes - cipherBytes(item.cipher));
      batch.put("room", room);
      await batch.commit();
      this.broadcast({ t: "items", rev: room.rev, items: [wire(tomb)] });
      return;
    }
    await this.storage.put("room", room);
  }

  // 다음 알람: 방 기한, 위치 기간이 아직 안 끝났으면 그 끝(모이는 곳을 거두려고).
  nextAlarm(room, now) {
    const end = room.locWindow?.until;
    return end && end > now && room.meetSwept !== end ? Math.min(room.expiresAt, end) : room.expiresAt;
  }

  async authenticate(room, request) {
    const match = /^Bearer ([A-Za-z0-9_-]{43})$/.exec(request.headers.get("authorization") ?? "");
    if (!match) return { error: fail(401, "unauthorized") };
    const hash = await digest("member", room.id, match[1]);
    const member = room.members.find((m) => sameText(m.hash, hash));
    if (!member) return { error: fail(401, "unauthorized") };
    if (member.gone) return { error: fail(403, "removed", { reason: member.gone }) };
    return { member };
  }

  rate(no, now) {
    const minute = Math.floor(now / MINUTE_MS);
    const row = this.rates.get(no);
    const count = row?.minute === minute ? row.count : 0;
    if (count >= SHARE.opsPerMinute) return busy("rate_limited", (minute + 1) * MINUTE_MS - now);
    this.rates.set(no, { minute, count: count + 1 });
    return null;
  }

  // MARK: 만들기·입장

  async create(args, now) {
    const old = await this.storage.get("room");
    if (old && now < old.expiresAt) return fail(409, "room_exists");
    if (old) await this.purge("expired");
    const token = randomToken();
    const room = {
      id: args.roomId, createdAt: now, expiresAt: args.expiresAt, epoch: 1, rev: 0, closed: false,
      join: await digest("join", args.roomId, args.proof), owner: await digest("owner", args.roomId, args.ownerKey),
      members: [{ no: 1, hash: await digest("member", args.roomId, token), epoch: 1, joinedAt: now }], nextNo: 2,
      locks: {}, fails: {}, live: 0, ids: 0, bytes: 0,
    };
    await this.storage.put("room", room);
    await this.storage.setAlarm(room.expiresAt);
    return reply(201, { roomId: room.id, member: 1, token, epoch: 1, rev: 0, expiresAt: room.expiresAt, limits: publicLimits() });
  }

  // 입장 증명을 견준다. 틀리면 방 단위로 세고, 다섯 번이면 15분 잠근다. 반환: null(맞음) 또는 응답.
  async checkProof(room, proof, now) {
    if (!SECRET.test(proof ?? "")) return fail(422, "bad_request");
    const fails = room.fails;
    if (fails.lockedUntil > now) return busy("join_locked", fails.lockedUntil - now);
    if (sameText(await digest("join", room.id, proof), room.join)) { room.fails = {}; return null; }
    const count = fails.first > now - SHARE.joinWindowMs ? fails.count + 1 : 1;
    room.fails = { first: count === 1 ? now : fails.first, count };
    if (count >= SHARE.joinFailures) room.fails = { lockedUntil: now + SHARE.joinLockMs };
    await this.storage.put("room", room);
    return room.fails.lockedUntil ? busy("join_locked", SHARE.joinLockMs) : fail(403, "wrong_password", { remaining: SHARE.joinFailures - count });
  }

  async join(room, body, now) {
    const wrong = await this.checkProof(room, body.proof, now);
    if (wrong) return wrong;
    if (activeMembers(room).length >= SHARE.members) return fail(409, "room_full", { limit: "members" });
    if (room.nextNo > SHARE.memberNumbers) return fail(409, "room_full", { limit: "numbers" });
    const token = randomToken();
    const member = { no: room.nextNo++, hash: await digest("member", room.id, token), epoch: room.epoch, joinedAt: now };
    room.members.push(member);
    await this.storage.put("room", room);
    this.broadcast({ t: "member", event: "join", no: member.no, now });
    return reply(201, { roomId: room.id, member: member.no, token, epoch: room.epoch, rev: room.rev, closed: room.closed, expiresAt: room.expiresAt, limits: publicLimits() });
  }

  async rekey(room, me, body, now) {
    const wrong = await this.checkProof(room, body.proof, now);
    if (wrong) return wrong;
    me.epoch = room.epoch;
    await this.storage.put("room", room);
    return reply(200, { epoch: room.epoch, rev: room.rev });
  }

  // MARK: 읽기

  online() {
    return new Set(this.ctx.getWebSockets().map((ws) => ws.deserializeAttachment()?.no));
  }

  describe(room, me, now) {
    const online = this.online();
    return {
      roomId: room.id, you: me.no, owner: 1, epoch: room.epoch, rev: room.rev, closed: room.closed, createdAt: room.createdAt, expiresAt: room.expiresAt,
      members: activeMembers(room).map((m) => ({ no: m.no, joinedAt: m.joinedAt, online: online.has(m.no), ...(m.epoch !== room.epoch ? { stale: true } : {}) })),
      locWindow: room.locWindow ?? null,
      locks: liveLocks(room, now), counts: { items: room.live, ids: room.ids, bytes: room.bytes }, limits: publicLimits(), now,
    };
  }

  // seq가 since보다 큰 항목을 seq 순으로. since가 0이면(처음 받기) 묘비는 뺀다.
  async changes(room, { since, limit }) {
    if (!isInt(since) || !isInt(limit, 1)) return fail(422, "bad_request");
    const page = Math.min(limit, SHARE.changesPage);
    const index = [...(await this.storage.list({ prefix: "r:", start: "r:" + pad(since + 1), limit: page + 1 })).entries()];
    const items = [];
    let chars = 0, next = since, taken = 0;
    for (const [name, id] of index.slice(0, page)) {
      const item = await this.storage.get("i:" + id);
      if (item && chars + (item.cipher?.length ?? 0) > SHARE.changesChars && items.length) break;
      taken++;
      next = Number(name.slice(2));
      if (!item || (since === 0 && item.del)) continue;
      chars += item.cipher?.length ?? 0;
      items.push(wire(item));
    }
    const more = taken < index.length;
    return reply(200, { rev: room.rev, epoch: room.epoch, closed: room.closed, items, more, next: more ? next : room.rev });
  }

  // MARK: 잠금

  // 남이 잡은 잠금 가운데 이 이름을 막는 것. 항목 잠금은 그 항목의 묶음 잠금에, 묶음 잠금은 그 묶음에 든 항목 잠금에 막힌다.
  async blockers(room, me, name) {
    const out = [];
    const other = (n) => room.locks[n] && room.locks[n].by !== me.no;
    if (other(name)) out.push(lockInfo(room, name));
    if (name.startsWith("i:")) {
      const group = (await this.storage.get(name))?.group;
      if (group && other("g:" + group)) out.push(lockInfo(room, "g:" + group));
    } else {
      for (const held of Object.keys(room.locks)) {
        if (held.startsWith("i:") && other(held) && (await this.storage.get(held))?.group === name.slice(2)) out.push(lockInfo(room, held));
      }
    }
    return out;
  }

  async lock(room, me, body, now, origin) {
    const acquire = body.acquire ?? [], release = body.release ?? [];
    const names = (list) => Array.isArray(list) && list.length <= SHARE.locksPerMember && list.every((n) => typeof n === "string" && LOCK_NAME.test(n));
    if (!names(acquire) || !names(release) || acquire.length + release.length === 0) return fail(422, "bad_request");
    liveLocks(room, now);
    const blocked = [];
    for (const name of acquire) blocked.push(...(await this.blockers(room, me, name)));
    if (blocked.length) return fail(423, "locked", { locks: blocked, now });
    const cleared = release.filter((name) => room.locks[name]?.by === me.no && !acquire.includes(name));
    for (const name of cleared) delete room.locks[name];
    const until = now + SHARE.leaseMs;
    for (const name of acquire) room.locks[name] = { by: me.no, until };
    if (Object.values(room.locks).filter((l) => l.by === me.no).length > SHARE.locksPerMember) return fail(422, "too_many_locks");
    await this.storage.put("room", room);
    const set = acquire.map((name) => ({ name, by: me.no, until }));
    if (set.length || cleared.length) this.broadcast({ t: "locks", set, clear: cleared, by: me.no, now }, origin);
    return reply(200, { locks: set, released: cleared, now });
  }

  // 한 참여자의 잠금을 모두 푼다(연결 끊김·나감). 저장은 부르는 쪽이 한다.
  dropLocks(room, no, now, origin) {
    const clear = Object.keys(room.locks).filter((name) => room.locks[name].by === no);
    for (const name of clear) delete room.locks[name];
    if (clear.length) this.broadcast({ t: "locks", set: [], clear, by: no, now }, origin);
    return clear.length;
  }

  // MARK: 쓰기

  async write(room, me, body, now, origin) {
    const writes = body.writes;
    if (!Array.isArray(writes) || writes.length < 1 || writes.length > SHARE.batch) return fail(422, "bad_request");
    const seen = new Set();
    for (const [index, w] of writes.entries()) {
      const bad = writeError(w) ?? (seen.has(w.id) ? [422, "duplicate_id"] : null);
      if (bad) return fail(bad[0], bad[1], { index });
      seen.add(w.id);
    }
    if (body.epoch !== room.epoch) return fail(409, "epoch_mismatch", { epoch: room.epoch });
    const current = await this.storage.get(writes.map((w) => "i:" + w.id));
    liveLocks(room, now);
    const mine = (name) => room.locks[name]?.by === me.no;
    const theirs = (name) => room.locks[name] && !mine(name);
    const conflicts = [], blocked = [], needed = [];
    let { live, ids, bytes } = room;
    for (const [index, w] of writes.entries()) {
      const old = current.get("i:" + w.id) ?? null;
      const creating = w.baseRev === 0;
      if (creating ? old && !(old.del && w.id === "meet-point") : !old || old.del || old.rev !== w.baseRev) { conflicts.push({ index, id: w.id, current: old ? wire(old) : null }); continue; }
      if (!creating && !w.delete && w.kind !== old.kind) return fail(422, "kind_immutable", { index });
      const kind = creating ? w.kind : old.kind;
      const no = denied(kind, me, old, w, room, now);
      if (no) return fail(no[0], no[1], { index, kind });
      w.nextGroup = w.delete ? undefined : w.group === undefined ? old?.group : w.group ?? undefined;
      if (LOCKED_KINDS.has(kind)) {
        const groups = [...new Set([old?.group, w.nextGroup].filter(Boolean))].map((g) => "g:" + g);
        const held = [...(creating ? [] : ["i:" + w.id]), ...groups].filter(theirs);
        if (held.length) blocked.push(...held.map((name) => lockInfo(room, name)));
        else if (!creating && !mine("i:" + w.id) && !(old.group && mine("g:" + old.group))) needed.push("i:" + w.id);
      }
      if (creating) { live++; if (!old) ids++; } // 지운 모이는 곳을 다시 정할 때는 id 수를 다시 세지 않는다
      if (w.delete) live--;
      bytes += (w.delete ? 0 : cipherBytes(w.cipher)) - (old && !old.del ? cipherBytes(old.cipher) : 0);
    }
    if (blocked.length) return fail(423, "locked", { locks: blocked, now });
    if (needed.length) return fail(423, "lock_required", { names: needed });
    if (conflicts.length) return fail(409, "conflict", { conflicts, rev: room.rev });
    const full = live > SHARE.liveItems ? "items" : ids > SHARE.itemIds ? "ids" : bytes > SHARE.roomBytes ? "bytes" : null;
    if (full) return fail(413, "room_full", { limit: full });

    const batch = new Batch(this.storage), done = [];
    for (const w of writes) {
      const old = current.get("i:" + w.id) ?? null;
      const rev = ++room.rev;
      const base = { id: w.id, kind: old?.kind ?? w.kind, rev, seq: rev, at: now, by: me.no, cb: old?.cb ?? me.no };
      const item = w.delete ? { ...base, del: true } : {
        ...base, epoch: room.epoch, cipher: w.cipher, ...(w.nextGroup ? { group: w.nextGroup } : {}), ...(base.kind === "notice" ? { acks: {} } : {}),
      };
      if (old) batch.delete("r:" + pad(old.seq));
      batch.put("i:" + w.id, item);
      batch.put("r:" + pad(rev), w.id);
      done.push(item);
    }
    Object.assign(room, { live, ids, bytes });
    batch.put("room", room);
    await batch.commit();
    this.broadcast({ t: "items", rev: room.rev, items: done.map(wire) }, origin);
    return reply(200, { rev: room.rev, items: done.map((i) => ({ id: i.id, rev: i.rev, seq: i.seq, updatedAt: i.at })) });
  }

  // 공지 확인. 누가 어떤 공지를 확인했는지는 내용이 아니라서 서버가 안다. 내용 개정(rev)은 그대로 두고 seq만 올린다.
  async ack(room, me, body, now, origin) {
    if (!ITEM_ID.test(body.id ?? "")) return fail(422, "bad_request");
    const item = await this.storage.get("i:" + body.id);
    if (!item || item.del || item.kind !== "notice") return fail(404, "no_notice");
    if (item.acks?.[me.no] === undefined) {
      const batch = new Batch(this.storage);
      batch.delete("r:" + pad(item.seq));
      item.acks = { ...item.acks, [me.no]: now };
      item.seq = ++room.rev;
      batch.put("i:" + item.id, item);
      batch.put("r:" + pad(item.seq), item.id);
      batch.put("room", room);
      await batch.commit();
      this.broadcast({ t: "ack", id: item.id, by: me.no, at: now, seq: item.seq, rev: room.rev }, origin);
    }
    return reply(200, { id: item.id, acks: item.acks, seq: item.seq, rev: room.rev });
  }

  // MARK: 나가기·내보내기

  async remove(room, member, reason, now) {
    member.gone = reason;
    member.goneAt = now;
    this.dropLocks(room, member.no, now);
    const batch = new Batch(this.storage);
    const card = await this.storage.get("i:member-" + member.no);
    if (card && !card.del) {
      batch.delete("r:" + pad(card.seq));
      const rev = ++room.rev;
      const tomb = { id: card.id, kind: card.kind, rev, seq: rev, at: now, by: member.no, cb: card.cb, del: true };
      batch.put("i:" + card.id, tomb);
      batch.put("r:" + pad(rev), card.id);
      room.live--;
      room.bytes -= cipherBytes(card.cipher);
      this.broadcast({ t: "items", rev, items: [wire(tomb)] });
    }
    batch.put("room", room);
    batch.delete("l:" + member.no);
    await batch.commit();
    this.broadcast({ t: "loc", by: member.no, off: true });
    for (const ws of this.ctx.getWebSockets("m:" + member.no)) this.bye(ws, reason, reason === "kicked" ? CLOSE.kicked : 1000);
    this.broadcast({ t: "member", event: reason === "kicked" ? "kick" : "leave", no: member.no, now });
    return reason === "kicked" ? reply(200, { ok: true, member: member.no, rekeyRecommended: true }) : reply(204);
  }

  async kick(room, me, body, now) {
    const target = activeMembers(room).find((m) => m.no === body.member);
    if (!target || target.no === 1) return fail(404, "no_member");
    return this.remove(room, target, "kicked", now);
  }

  // MARK: 주인만

  async close(room, me, body, now) {
    if (typeof body.closed !== "boolean") return fail(422, "bad_request");
    room.closed = body.closed;
    await this.storage.put("room", room);
    this.roomEvent(room, now);
    return reply(200, { closed: room.closed });
  }

  async extend(room, me, body, now) {
    if (!isInt(body.expiresAt) || body.expiresAt < now + SHARE.minLifeMs || body.expiresAt > room.createdAt + SHARE.maxLifeMs) return fail(422, "bad_expiry", { max: room.createdAt + SHARE.maxLifeMs });
    room.expiresAt = body.expiresAt;
    await this.storage.put("room", room);
    await this.storage.setAlarm(this.nextAlarm(room, now));
    this.roomEvent(room, now);
    return reply(200, { expiresAt: room.expiresAt });
  }

  roomEvent(room, now) {
    this.broadcast({ t: "room", closed: room.closed, expiresAt: room.expiresAt, epoch: room.epoch, locWindow: room.locWindow ?? null, now });
  }

  // MARK: 동행 위치 (LOC1116S01)

  // 저장된 위치 중 기한이 남은 것. 지난 것은 지운다.
  async readLocs(now) {
    const rows = [...(await this.storage.list({ prefix: "l:" })).entries()];
    const live = [], dead = [];
    for (const [key, row] of rows) (row.until > now ? live : dead).push(row.until > now ? row : key);
    if (dead.length) await this.storage.delete(dead);
    return live.map((r) => ({ by: r.no, cipher: r.cipher, epoch: r.epoch, at: r.at, ...(r.help ? { help: true } : {}) })).sort((a, b) => a.by - b.by);
  }

  // 위치 하나를 동행에게 전달한다. 내용은 읽지 않는다. 주인이 기간 창을 올리기 전과 창 밖에서는 받지 않는다.
  async loc(room, me, body, now, origin) {
    const error = cipherError(body.cipher);
    if (error) return fail(error[0], error[1]);
    if (cipherBytes(body.cipher) > SHARE.locBytes) return fail(413, "item_too_large");
    if (!isInt(body.epoch, 1)) return fail(422, "bad_request");
    if (body.epoch !== room.epoch) return fail(409, "epoch_mismatch", { epoch: room.epoch });
    const window = room.locWindow;
    if (!window || now < window.from || now >= window.until) return fail(403, "loc_closed", { locWindow: window ?? null });
    const help = body.help === true;
    const state = this.locRates.get(me.no) ?? { minute: -1, count: 0, last: 0 };
    const minute = Math.floor(now / MINUTE_MS);
    if (state.minute !== minute) { state.minute = minute; state.count = 0; }
    if (state.count >= SHARE.locPerMinute) return busy("loc_rate", (minute + 1) * MINUTE_MS - now);
    if (!help && now - state.last < SHARE.locGapMs) return busy("loc_rate", state.last + SHARE.locGapMs - now);
    state.count++;
    state.last = now;
    this.locRates.set(me.no, state);
    this.broadcast({ t: "loc", by: me.no, cipher: body.cipher, epoch: room.epoch, at: now, ...(help ? { help: true } : {}) }, origin);
    if (SHARE.locKeep) {
      const old = await this.storage.get("l:" + me.no);
      // 도움 요청이 이어질 때는 10초마다만 저장한다(보통 위치로 돌아갈 때와 처음 요청은 바로 저장).
      const gap = help && old?.help ? SHARE.locHelpStoreGapMs : SHARE.locStoreGapMs;
      if (!old || old.until <= now || help !== !!old.help || now - old.storedAt >= gap) {
        // 보관은 위치 기간 창이 끝나는 때를 넘기지 않는다(「여행 기간에만」).
        const until = Math.min(now + (help ? SHARE.locHelpKeepMs : SHARE.locKeepMs), window.until);
        await this.storage.put("l:" + me.no, { no: me.no, cipher: body.cipher, epoch: room.epoch, at: now, storedAt: now, help, until });
      }
    }
    return reply(200, { now });
  }

  // 내 저장된 위치를 지우고 동행에게 「껐음」을 알린다.
  async locOff(room, me, now) {
    // 끄기와 켜기를 번갈아 횟수 제한을 피하지 못하도록 `locRates`는 지우지 않는다.
    await this.storage.delete("l:" + me.no);
    this.broadcast({ t: "loc", by: me.no, off: true });
    return reply(204);
  }

  // 주인만: 위치를 보낼 수 있는 기간(밀리초). 이 기간 밖에는 서버가 위치를 받지 않는다.
  async locWindow(room, me, body, now) {
    const { from, until } = body;
    if (!isInt(from) || !isInt(until) || until <= from || until - from > SHARE.locWindowMaxMs || until <= now) return fail(422, "bad_request", { max: SHARE.locWindowMaxMs });
    room.locWindow = { from, until };
    await this.storage.put("room", room);
    await this.storage.setAlarm(this.nextAlarm(room, now));
    if (now < from || now >= until) {
      for (const key of (await this.storage.list({ prefix: "l:" })).keys()) await this.storage.delete(key);
      this.broadcast({ t: "loc", off: true, all: true });
    }
    this.roomEvent(room, now);
    return reply(200, { from, until });
  }

  // 비밀번호 바꾸기 = 키 교체. 주인 기기가 살아 있는 모든 항목을 새 키로 다시 잠가 한 번에 올린다.
  async rotate(room, me, body, now) {
    const list = body.items;
    if (!isInt(body.rev) || !SECRET.test(body.proof ?? "") || !Array.isArray(list) || list.length > SHARE.liveItems) return fail(422, "bad_request");
    if (body.rev !== room.rev) return fail(409, "conflict", { rev: room.rev });
    const join = await digest("join", room.id, body.proof);
    if (sameText(join, room.join)) return fail(422, "same_proof");
    const fresh = new Map();
    let bytes = 0;
    for (const [index, entry] of list.entries()) {
      const bad = !ITEM_ID.test(entry?.id ?? "") || fresh.has(entry.id) ? [422, "bad_request"] : cipherError(entry.cipher);
      if (bad) return fail(bad[0], bad[1], { index });
      fresh.set(entry.id, entry.cipher);
      bytes += cipherBytes(entry.cipher);
    }
    const live = [...(await this.storage.list({ prefix: "i:" })).values()].filter((i) => !i.del).sort((a, b) => a.seq - b.seq);
    const missing = live.filter((i) => !fresh.has(i.id)).length;
    if (missing || live.length !== fresh.size) return fail(422, "incomplete", { missing, extra: fresh.size - (live.length - missing) });
    if (bytes > SHARE.roomBytes) return fail(413, "room_full", { limit: "bytes" });

    const batch = new Batch(this.storage);
    room.epoch++;
    for (const item of live) {
      batch.delete("r:" + pad(item.seq));
      const rev = ++room.rev;
      batch.put("i:" + item.id, { ...item, cipher: fresh.get(item.id), epoch: room.epoch, rev, seq: rev });
      batch.put("r:" + pad(rev), item.id);
    }
    Object.assign(room, { join, bytes, locks: {}, fails: {} });
    me.epoch = room.epoch;
    batch.put("room", room);
    for (const key of (await this.storage.list({ prefix: "l:" })).keys()) batch.delete(key); // 옛 키로 잠근 위치는 버린다.
    await batch.commit();
    for (const ws of this.ctx.getWebSockets()) {
      if (ws.deserializeAttachment()?.no === 1) this.send(ws, { t: "room", closed: room.closed, expiresAt: room.expiresAt, epoch: room.epoch, rekeyed: true, now });
      else this.bye(ws, "rekey", CLOSE.rekey);
    }
    return reply(200, { epoch: room.epoch, rev: room.rev });
  }

  // 방을 통째로 지운다(주인의 지우기·기한). 남는 것이 없다.
  async purge(reason) {
    for (const ws of this.ctx.getWebSockets()) this.bye(ws, reason, CLOSE.gone);
    await this.storage.deleteAlarm?.();
    await this.storage.deleteAll();
  }

  async alarm() {
    await this.serial(async () => {
      const room = await this.storage.get("room");
      const now = this.now();
      if (!room || now >= room.expiresAt) return this.purge("expired");
      await this.sweepMeet(room, now);
      return this.storage.setAlarm(this.nextAlarm(room, now)); // 주인이 기한을 늘린 뒤에 온 예전 알람이거나 위치 기간 끝
    });
  }

  // MARK: WebSocket (Hibernation API)

  send(ws, message) {
    try { ws.send(JSON.stringify(message)); } catch { /* 닫히는 중 */ }
  }

  bye(ws, reason, code) {
    this.send(ws, { t: "bye", reason });
    try { ws.close(code, reason); } catch { /* 이미 닫힘 */ }
  }

  broadcast(message, except) {
    for (const ws of this.ctx.getWebSockets()) if (ws !== except) this.send(ws, message);
  }

  async connect(room, me, request, now) {
    if ((request.headers.get("upgrade") ?? "").toLowerCase() !== "websocket") return fail(426, "upgrade_required");
    const mine = this.ctx.getWebSockets("m:" + me.no).sort((a, b) => (a.deserializeAttachment()?.at ?? 0) - (b.deserializeAttachment()?.at ?? 0));
    for (const old of mine.slice(0, Math.max(0, mine.length - SHARE.socketsPerMember + 1))) this.bye(old, "replaced", CLOSE.replaced);
    const wasOnline = this.online().has(me.no);
    const [client, server] = this.env.SOCKETS?.pair() ?? Object.values(new WebSocketPair());
    this.ctx.acceptWebSocket(server, ["m:" + me.no]);
    server.serializeAttachment({ no: me.no, at: now });
    this.send(server, { t: "hello", ...this.describe(room, me, now), locs: await this.readLocs(now) });
    if (!wasOnline) this.broadcast({ t: "member", event: "online", no: me.no, now }, server);
    return this.env.SOCKETS?.response(client) ?? new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws, message) {
    if (typeof message !== "string" || message.length > SHARE.bodyBytes) return ws.close(CLOSE.tooBig, "too_large");
    let body;
    try { body = JSON.parse(message); } catch { return this.send(ws, { t: "res", id: null, status: 400, error: "invalid_json" }); }
    const id = typeof body?.id === "string" || typeof body?.id === "number" ? body.id : null;
    const result = await this.serial(() => this.socketOp(ws, body ?? {}, this.now()));
    if (result) this.send(ws, { ...(result.body ?? {}), t: "res", id, status: result.status }); // 본문의 id(공지 확인)보다 요청 번호가 앞선다.
  }

  async socketOp(ws, body, now) {
    const room = await this.liveRoom(now);
    const me = room?.members.find((m) => m.no === ws.deserializeAttachment()?.no);
    if (!room || !me || me.gone) { this.bye(ws, room ? "kicked" : "deleted", room ? CLOSE.kicked : CLOSE.gone); return null; }
    if (me.epoch !== room.epoch) { this.bye(ws, "rekey", CLOSE.rekey); return null; }
    const over = this.rate(me.no, now);
    if (over) return over;
    switch (body.op) {
      case "lock": return this.lock(room, me, body, now, ws);
      case "write": return this.write(room, me, body, now, ws);
      case "loc": return this.loc(room, me, body, now, ws);
      case "ack": return this.ack(room, me, { id: body.notice }, now, ws); // 소켓에서는 id가 요청 번호라 공지는 notice 칸으로 받는다.
      case "changes": return this.changes(room, { since: body.since ?? 0, limit: body.limit ?? SHARE.changesPage });
      case "state": return reply(200, this.describe(room, me, now));
      default: return fail(400, "unknown_op");
    }
  }

  // 그 참여자의 마지막 연결이 끊기면 잡고 있던 잠금을 모두 푼다.
  async webSocketClose(ws, code) {
    await this.serial(async () => {
      const no = ws.deserializeAttachment()?.no;
      try { ws.close(code === 1005 || code === 1006 ? 1000 : code, "bye"); } catch { /* 이미 닫힘 */ }
      const room = await this.storage.get("room");
      if (!room || no === undefined || this.ctx.getWebSockets("m:" + no).some((other) => other !== ws)) return;
      const now = this.now();
      if (this.dropLocks(room, no, now, ws)) await this.storage.put("room", room);
      this.broadcast({ t: "member", event: "offline", no, now }, ws);
    });
  }

  webSocketError(ws) {
    return this.webSocketClose(ws, 1011);
  }
}

const ROOM_SUBS = new Set(["", "join", "rekey", "leave", "changes", "items", "locks", "acks", "kick", "close", "expiry", "rotate", "ws", "loc", "locwindow"]);

// MARK: Worker 쪽

const roomStub = (env, roomId) => env.SHARE_ROOM.get(env.SHARE_ROOM.idFromName("room:" + roomId));

// POST /share/rooms: 앱 등록 키(주인 범위)로 인증된 기기만 방을 만든다. 방과 등록 키의 연결은 어디에도 적지 않는다.
export async function createRoom(ctx, value) {
  if (!ctx.env.SHARE_ROOM) return json({ error: "unavailable" }, 503);
  const { roomId, proof, ownerKey, expiresAt } = value ?? {};
  if (!ROOM_ID.test(roomId ?? "") || !SECRET.test(proof ?? "") || !SECRET.test(ownerKey ?? "") || proof === ownerKey) return json({ error: "bad_request" }, 422);
  if (!isInt(expiresAt) || expiresAt < ctx.now + SHARE.minLifeMs || expiresAt > ctx.now + SHARE.maxLifeMs) return json({ error: "bad_expiry", max: ctx.now + SHARE.maxLifeMs }, 422);
  const own = await ctx.state.call("countDaily", { name: "shareRooms", limit: SHARE.roomsPerOwnerDay, now: ctx.now });
  if (!own.ok) return tooMany("room_daily_limit", own.retryAfter);
  const all = await userState(ctx.env, "global:shareRooms").call("countDaily", { name: "shareRooms", limit: SHARE.roomsPerDay, now: ctx.now });
  if (!all.ok) return tooMany("room_daily_limit", all.retryAfter);
  return roomStub(ctx.env, roomId).fetch("https://share-room/create", { method: "POST", body: JSON.stringify({ roomId, proof, ownerKey, expiresAt }) });
}

// /share/rooms/<방 id>[/…]: 방 DO로 그대로 넘긴다. 비밀번호를 대 보는 요청(join·rekey)은 IP마다 분·하루 수를 먼저 센다.
export async function roomRoute(request, env, match, now) {
  if (!env.SHARE_ROOM) return json({ error: "unavailable" }, 503);
  const [, roomId, sub = ""] = match;
  if (!ROOM_SUBS.has(sub)) return json({ error: "not_found" }, 404);
  if (request.method === "POST" && (sub === "join" || sub === "rekey")) {
    if (await limited(env.POST_LIMIT, request)) return tooMany();
    const perIp = await (await ipState(env, request)).call("countDaily", { name: "shareJoin", limit: SHARE.joinsPerIpDay, now, expire: true });
    if (!perIp.ok) return tooMany("join_ip_limit", perIp.retryAfter);
  }
  return roomStub(env, roomId).fetch(request);
}
