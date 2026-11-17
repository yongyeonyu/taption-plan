// TSH1114A26: 여행 공유 방. 규약은 docs/TRIP_SHARE_PROTOCOL.md. 비밀번호·열쇠는 모두 여기서 만든 무작위 값이다.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { handle } from "../src/index.js";
import { CLOSE, SHARE } from "../src/share.js";
import { makeShareEnv } from "./fakes.mjs";
import { base64url, computeVector, deriveKeys, openItem, sealItem } from "./share-client.mjs";

const ORIGIN = "https://relay.example.com";
const MINUTE = 60_000, DAY = 86_400_000;
const random = (bytes) => crypto.getRandomValues(new Uint8Array(bytes));
const secret = () => base64url(random(32));
const itemId = () => base64url(random(16));
// 서버는 암호문을 풀지 않으므로 모양만 맞는 덩어리면 된다: 0x01 || 무작위.
const cipher = (bytes = 48) => base64url(Buffer.concat([Buffer.from([1]), random(bytes - 1)]));

async function call(env, method, path, { token, owner, body, headers = {} } = {}) {
  const response = await handle(new Request(ORIGIN + path, {
    method,
    headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...(owner ? { "x-share-owner": owner } : {}), "content-type": "application/json", ...headers },
    body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body),
  }), env);
  const text = await response.text();
  return { status: response.status, body: text ? JSON.parse(text) : null, headers: response.headers };
}

async function makeRoom(extra = {}) {
  const made = makeShareEnv(extra);
  const master = secret();
  assert.equal((await call(made.env, "POST", "/register", { token: master, body: {} })).status, 201);
  const room = { ...made, master, roomId: base64url(random(16)), proof: secret(), ownerKey: secret() };
  room.path = "/share/rooms/" + room.roomId;
  room.expiresAt = made.clock.now + 40 * DAY;
  const created = await call(made.env, "POST", "/share/rooms", { token: master, body: { roomId: room.roomId, proof: room.proof, ownerKey: room.ownerKey, expiresAt: room.expiresAt } });
  assert.equal(created.status, 201);
  room.created = created.body;
  room.owner = { no: 1, token: created.body.token };
  room.instance = made.rooms.instance("room:" + room.roomId);
  return room;
}

async function join(room, proof = room.proof) {
  const joined = await call(room.env, "POST", room.path + "/join", { body: { proof } });
  assert.equal(joined.status, 201);
  return { no: joined.body.member, token: joined.body.token };
}

const write = (room, member, writes, epoch = 1) => call(room.env, "POST", room.path + "/items", { token: member.token, body: { epoch, writes: [writes].flat() } });
const lock = (room, member, acquire = [], release = []) => call(room.env, "POST", room.path + "/locks", { token: member.token, body: { acquire, release } });
const changes = (room, member, since = 0, limit) => call(room.env, "GET", `${room.path}/changes?since=${since}${limit ? "&limit=" + limit : ""}`, { token: member.token });

/** 항목 하나를 만들고 { id, rev }를 준다. */
async function add(room, member, kind = "plan", extra = {}) {
  const id = extra.id ?? itemId();
  const made = await write(room, member, { id, kind, baseRev: 0, cipher: cipher(), ...extra });
  assert.equal(made.status, 200, JSON.stringify(made.body));
  return { id, rev: made.body.items[0].rev };
}

async function connect(room, member) {
  const opened = await call(room.env, "GET", room.path + "/ws", { token: member.token, headers: { upgrade: "websocket" } });
  assert.equal(opened.headers.get("x-test-upgrade"), "websocket", JSON.stringify(opened.body));
  return room.rooms.pairs.at(-1)[1];
}

/** 소켓으로 요청 하나를 보내고 그 응답(res)을 준다. */
async function ask(room, socket, message) {
  await room.instance.room.webSocketMessage(socket, JSON.stringify({ id: 7, ...message }));
  return socket.sent.findLast((m) => m.t === "res");
}

async function withLimit(name, value, run) {
  const before = SHARE[name];
  SHARE[name] = value;
  try { await run(); } finally { SHARE[name] = before; }
}

// MARK: 시험 벡터

test("share vectors: PBKDF2 → HKDF → proof and the cipher layout match the fixture and the protocol document", async () => {
  const fixture = JSON.parse(readFileSync(new URL("./fixtures/share-vectors.json", import.meta.url), "utf8"));
  const document = readFileSync(new URL("../../../docs/TRIP_SHARE_PROTOCOL.md", import.meta.url), "utf8");
  assert.equal(fixture.iterations, 600_000);
  assert.equal(fixture.vectors.length, 2);
  for (const { input, expected } of fixture.vectors) {
    assert.deepEqual(await computeVector(input), expected);
    for (const value of [input.roomId, input.linkSecretHex, expected.rootHex, expected.encKeyHex, expected.authKeyHex, expected.proof, expected.aad, expected.cipher]) {
      assert.ok(document.includes(value), `document is missing ${value}`);
    }
    const encKey = Buffer.from(expected.encKeyHex, "hex");
    assert.equal(await openItem(encKey, input, expected.cipher), input.plaintext);
    // AAD가 방·항목·종류·세대를 묶는다: 하나라도 다르면 풀리지 않는다.
    assert.equal(await openItem(encKey, { ...input, itemId: input.itemId + "x" }, expected.cipher), null);
    assert.equal(await openItem(encKey, { ...input, kind: "meta" }, expected.cipher), null);
    assert.equal(await openItem(encKey, { ...input, epoch: input.epoch + 1 }, expected.cipher), null);
    assert.equal(await openItem(encKey, { ...input, roomId: fixture.vectors[0].input.roomId === input.roomId ? fixture.vectors[1].input.roomId : fixture.vectors[0].input.roomId }, expected.cipher), null);
  }
});

test("share vectors: a room made from derived keys accepts the derived proof and stores the sealed item unchanged", async () => {
  const made = makeShareEnv();
  const master = secret(), roomId = base64url(random(16)), linkSecret = random(32);
  await call(made.env, "POST", "/register", { token: master, body: {} });
  const keys = await deriveKeys(roomId, linkSecret, "가을 여행 7");
  const path = "/share/rooms/" + roomId;
  const created = await call(made.env, "POST", "/share/rooms", { token: master, body: { roomId, proof: keys.proof, ownerKey: secret(), expiresAt: made.clock.now + DAY } });
  assert.equal(created.status, 201);
  const other = await deriveKeys(roomId, linkSecret, "가을 여행 8");
  assert.equal((await call(made.env, "POST", path + "/join", { body: { proof: other.proof } })).status, 403);
  const guest = await call(made.env, "POST", path + "/join", { body: { proof: (await deriveKeys(roomId, linkSecret, "가을 여행 7")).proof } });
  assert.equal(guest.status, 201);
  const id = itemId(), plaintext = JSON.stringify({ v: 1, title: "숙소 체크인" });
  const sealed = await sealItem(keys.encKey, { roomId, itemId: id, kind: "plan", epoch: 1 }, plaintext);
  assert.equal((await call(made.env, "POST", path + "/items", { token: created.body.token, body: { epoch: 1, writes: [{ id, kind: "plan", baseRev: 0, cipher: sealed }] } })).status, 200);
  const got = (await call(made.env, "GET", path + "/changes?since=0", { token: guest.body.token })).body.items[0];
  assert.equal(got.cipher, sealed);
  assert.equal(await openItem(keys.encKey, { roomId, itemId: got.id, kind: got.kind, epoch: got.epoch }, got.cipher), plaintext);
});

// MARK: 만들기

test("share create: only a registered app key makes a room, and the server keeps verifiers, never the secrets", async () => {
  const room = await makeRoom();
  assert.deepEqual({ ...room.created, token: "", limits: null }, { roomId: room.roomId, member: 1, token: "", epoch: 1, rev: 0, expiresAt: room.expiresAt, limits: null });
  assert.equal(room.created.limits.members, 10);
  assert.equal(room.instance.ctx.storage.alarm, room.expiresAt);
  const stored = JSON.stringify([...room.instance.ctx.storage.map.entries()]);
  for (const hidden of [room.proof, room.ownerKey, room.owner.token, room.master]) assert.ok(!stored.includes(hidden));

  const body = { roomId: base64url(random(16)), proof: secret(), ownerKey: secret(), expiresAt: room.expiresAt };
  assert.equal((await call(room.env, "POST", "/share/rooms", { body })).status, 401);
  assert.equal((await call(room.env, "POST", "/share/rooms", { token: secret(), body })).status, 401);
  assert.equal((await call(room.env, "POST", "/share/rooms", { token: room.master, body: { ...body, roomId: room.roomId } })).body.error, "room_exists");
  for (const bad of [{ roomId: "short" }, { proof: "x" }, { ownerKey: body.proof }, { ownerKey: undefined }]) {
    assert.equal((await call(room.env, "POST", "/share/rooms", { token: room.master, body: { ...body, ...bad } })).status, 422);
  }
  for (const expiresAt of [room.clock.now + MINUTE, room.clock.now + 401 * DAY, "soon"]) {
    assert.equal((await call(room.env, "POST", "/share/rooms", { token: room.master, body: { ...body, expiresAt } })).body.error, "bad_expiry");
  }
});

test("share create: one app key makes at most five rooms a day", async () => {
  const room = await makeRoom();
  const make = () => call(room.env, "POST", "/share/rooms", { token: room.master, body: { roomId: base64url(random(16)), proof: secret(), ownerKey: secret(), expiresAt: room.expiresAt } });
  // makeRoom이 하나, room_exists 없이 넷 더.
  for (let i = 0; i < SHARE.roomsPerOwnerDay - 1; i++) assert.equal((await make()).status, 201);
  const over = await make();
  assert.equal(over.status, 429);
  assert.equal(over.body.error, "room_daily_limit");
  assert.ok(Number(over.headers.get("retry-after")) > 0);
  room.clock.now += DAY;
  assert.equal((await make()).status, 201);
});

test("share: without the SHARE_ROOM binding every share route answers 503 and other routes still work", async () => {
  const room = await makeRoom();
  delete room.env.SHARE_ROOM;
  assert.equal((await call(room.env, "GET", room.path, { token: room.owner.token })).status, 503);
  assert.equal((await call(room.env, "POST", "/share/rooms", { token: room.master, body: {} })).status, 503);
  assert.equal((await call(room.env, "GET", "/plan", { token: room.master })).status, 204);
});

// MARK: 입장

test("share join: right proof gets a member number and token; wrong proofs count down, then lock the room for 15 minutes", async () => {
  const room = await makeRoom();
  const guest = await join(room);
  assert.equal(guest.no, 2);
  assert.equal((await call(room.env, "GET", room.path, { token: guest.token })).body.you, 2);

  for (let left = SHARE.joinFailures - 1; left >= 1; left--) {
    const wrong = await call(room.env, "POST", room.path + "/join", { body: { proof: secret() } });
    assert.equal(wrong.status, 403);
    assert.deepEqual(wrong.body, { error: "wrong_password", remaining: left });
  }
  const locked = await call(room.env, "POST", room.path + "/join", { body: { proof: secret() } });
  assert.equal(locked.status, 429);
  assert.equal(locked.body.error, "join_locked");
  assert.equal(locked.headers.get("retry-after"), "900");
  // 잠긴 동안에는 맞는 증명도 받지 않는다. 이미 들어온 사람은 그대로 쓴다.
  assert.equal((await call(room.env, "POST", room.path + "/join", { body: { proof: room.proof } })).body.error, "join_locked");
  assert.equal((await call(room.env, "GET", room.path, { token: guest.token })).status, 200);
  room.clock.now += SHARE.joinLockMs + 1;
  assert.equal((await join(room)).no, 3);
  // 맞히면 틀린 수가 지워진다.
  assert.equal((await call(room.env, "POST", room.path + "/join", { body: { proof: secret() } })).body.remaining, SHARE.joinFailures - 1);
  assert.equal((await call(room.env, "POST", room.path + "/join", { body: { proof: "not-a-proof" } })).status, 422);
});

test("share join: old failures outside the 15 minute window do not add up", async () => {
  const room = await makeRoom();
  for (let i = 0; i < SHARE.joinFailures - 1; i++) await call(room.env, "POST", room.path + "/join", { body: { proof: secret() } });
  room.clock.now += SHARE.joinWindowMs + 1;
  assert.deepEqual((await call(room.env, "POST", room.path + "/join", { body: { proof: secret() } })).body, { error: "wrong_password", remaining: SHARE.joinFailures - 1 });
});

test("share join: the eleventh person is refused until someone leaves", async () => {
  const room = await makeRoom();
  const guests = [];
  for (let i = 0; i < SHARE.members - 1; i++) guests.push(await join(room));
  assert.equal(guests.at(-1).no, 10);
  const eleventh = await call(room.env, "POST", room.path + "/join", { body: { proof: room.proof } });
  assert.equal(eleventh.status, 409);
  assert.deepEqual(eleventh.body, { error: "room_full", limit: "members" });
  // 인원이 찼는지는 비밀번호를 맞힌 사람에게만 알린다.
  assert.equal((await call(room.env, "POST", room.path + "/join", { body: { proof: secret() } })).body.error, "wrong_password");
  assert.equal((await call(room.env, "POST", room.path + "/leave", { token: guests[3].token })).status, 204);
  assert.equal((await join(room)).no, 11); // 번호는 다시 쓰지 않는다.
  assert.equal((await call(room.env, "GET", room.path, { token: room.owner.token })).body.members.length, 10);
});

test("share join: one IP may try joining 60 times a day across rooms", async () => {
  const room = await makeRoom();
  const headers = { "cf-connecting-ip": "203.0.113.9" };
  await withLimit("joinsPerIpDay", 3, async () => {
    for (let i = 0; i < 3; i++) assert.equal((await call(room.env, "POST", room.path + "/join", { body: { proof: room.proof }, headers })).status, 201);
    const over = await call(room.env, "POST", room.path + "/join", { body: { proof: room.proof }, headers });
    assert.equal(over.status, 429);
    assert.equal(over.body.error, "join_ip_limit");
    assert.equal((await call(room.env, "POST", room.path + "/join", { body: { proof: room.proof }, headers: { "cf-connecting-ip": "203.0.113.10" } })).status, 201);
  });
});

test("share auth: room requests need a member token; unknown rooms, paths and methods are refused", async () => {
  const room = await makeRoom();
  assert.equal((await call(room.env, "GET", room.path)).status, 401);
  assert.equal((await call(room.env, "GET", room.path, { token: secret() })).status, 401);
  assert.equal((await call(room.env, "GET", room.path, { token: room.master })).status, 401);
  assert.equal((await call(room.env, "GET", "/share/rooms/" + base64url(random(16)), { token: room.owner.token })).status, 404);
  assert.equal((await call(room.env, "GET", room.path + "/nothing", { token: room.owner.token })).status, 404);
  assert.equal((await call(room.env, "GET", room.path + "/items", { token: room.owner.token })).status, 405);
  assert.equal((await call(room.env, "POST", room.path + "/items", { token: room.owner.token, body: "{" })).body.error, "invalid_json");
  const state = (await call(room.env, "GET", room.path, { token: room.owner.token })).body;
  assert.deepEqual(state.members, [{ no: 1, joinedAt: room.clock.now, online: false }]);
  assert.deepEqual({ rev: state.rev, epoch: state.epoch, closed: state.closed, counts: state.counts }, { rev: 0, epoch: 1, closed: false, counts: { items: 0, ids: 0, bytes: 0 } });
});

// MARK: 쓰기·충돌·잠금

test("share write: an edit needs the right baseRev; a stale one gets 409 with the latest item", async () => {
  const room = await makeRoom();
  const guest = await join(room);
  const first = await add(room, room.owner);
  assert.equal(first.rev, 1);
  assert.equal((await lock(room, room.owner, ["i:" + first.id])).status, 200);
  const second = await write(room, room.owner, { id: first.id, kind: "plan", baseRev: 1, cipher: cipher() });
  assert.equal(second.body.items[0].rev, 2);
  assert.equal((await lock(room, room.owner, [], ["i:" + first.id])).status, 200);

  assert.equal((await lock(room, guest, ["i:" + first.id])).status, 200);
  const stale = await write(room, guest, { id: first.id, kind: "plan", baseRev: 1, cipher: cipher() });
  assert.equal(stale.status, 409);
  assert.equal(stale.body.error, "conflict");
  assert.equal(stale.body.conflicts[0].current.rev, 2);
  assert.equal(stale.body.conflicts[0].current.by, 1);
  // 이미 있는 id로 만들기, 없는 항목 고치기, 지운 항목 고치기도 충돌이다.
  assert.equal((await write(room, guest, { id: first.id, kind: "plan", baseRev: 0, cipher: cipher() })).status, 409);
  assert.equal((await write(room, guest, { id: itemId(), kind: "expense-own", baseRev: 3, cipher: cipher() })).body.conflicts[0].current, null);
  assert.equal((await write(room, guest, { id: first.id, baseRev: 2, delete: true })).status, 200);
  const gone = await write(room, guest, { id: first.id, kind: "plan", baseRev: 0, cipher: cipher() });
  assert.equal(gone.body.conflicts[0].current.deleted, true);
  assert.equal(gone.body.conflicts[0].current.cipher, undefined);
});

test("share write: a batch is all or nothing", async () => {
  const room = await makeRoom();
  const kept = await add(room, room.owner, "expense-own");
  const batch = await write(room, room.owner, [
    { id: itemId(), kind: "plan", baseRev: 0, cipher: cipher() },
    { id: kept.id, kind: "expense-own", baseRev: 99, cipher: cipher() },
  ]);
  assert.equal(batch.status, 409);
  assert.equal(batch.body.conflicts[0].index, 1);
  const state = (await call(room.env, "GET", room.path, { token: room.owner.token })).body;
  assert.deepEqual({ rev: state.rev, items: state.counts.items }, { rev: 1, items: 1 });
  const dup = itemId();
  assert.equal((await write(room, room.owner, [{ id: dup, kind: "plan", baseRev: 0, cipher: cipher() }, { id: dup, kind: "plan", baseRev: 0, cipher: cipher() }])).body.error, "duplicate_id");
});

test("share lock: a lease is needed to edit, blocks others, renews, expires after two minutes and can be released", async () => {
  const room = await makeRoom();
  const guest = await join(room);
  const item = await add(room, room.owner);
  const edit = (member, baseRev) => write(room, member, { id: item.id, kind: "plan", baseRev, cipher: cipher() });

  const bare = await edit(guest, item.rev);
  assert.equal(bare.status, 423);
  assert.deepEqual(bare.body, { error: "lock_required", names: ["i:" + item.id] });

  const leased = await lock(room, guest, ["i:" + item.id]);
  assert.deepEqual(leased.body.locks, [{ name: "i:" + item.id, by: 2, until: room.clock.now + SHARE.leaseMs }]);
  const refused = await lock(room, room.owner, ["i:" + item.id]);
  assert.equal(refused.status, 423);
  assert.deepEqual(refused.body.locks, leased.body.locks);
  const blocked = await edit(room.owner, item.rev);
  assert.equal(blocked.status, 423);
  assert.equal(blocked.body.error, "locked");
  assert.equal(blocked.body.locks[0].by, 2);
  assert.equal((await write(room, room.owner, { id: item.id, baseRev: item.rev, delete: true })).body.error, "locked");

  // 연장: 같은 사람이 다시 잡으면 기한이 뒤로 간다.
  room.clock.now += 90_000;
  assert.equal((await lock(room, guest, ["i:" + item.id])).body.locks[0].until, room.clock.now + SHARE.leaseMs);
  room.clock.now += 90_000;
  assert.equal((await lock(room, room.owner, ["i:" + item.id])).status, 423);
  const edited = await edit(guest, item.rev);
  assert.equal(edited.status, 200);

  // 만료: 2분이 지나면 임대자도 다시 잡아야 하고, 남이 잡을 수 있다.
  room.clock.now += SHARE.leaseMs;
  assert.equal((await edit(guest, edited.body.items[0].rev)).body.error, "lock_required");
  assert.deepEqual((await call(room.env, "GET", room.path, { token: guest.token })).body.locks, []);
  assert.equal((await lock(room, room.owner, ["i:" + item.id])).status, 200);

  // 풀기: 남의 잠금은 풀리지 않고, 내 것은 풀린다.
  assert.deepEqual((await lock(room, guest, [], ["i:" + item.id])).body.released, []);
  assert.deepEqual((await lock(room, room.owner, [], ["i:" + item.id])).body.released, ["i:" + item.id]);
  assert.equal((await lock(room, guest, ["i:" + item.id])).status, 200);

  assert.equal((await lock(room, guest, ["bad name"])).status, 422);
  assert.equal((await lock(room, guest, [])).status, 422);
  await withLimit("locksPerMember", 2, async () => {
    assert.equal((await lock(room, guest, ["g:day-1", "g:day-2"])).body.error, "too_many_locks");
    assert.equal((await call(room.env, "GET", room.path, { token: guest.token })).body.locks.length, 1);
  });
});

test("share lock: a group lock covers its items for reordering, and item and group locks exclude each other", async () => {
  const room = await makeRoom();
  const guest = await join(room);
  const a = await add(room, room.owner, "plan", { group: "day-1" });
  const b = await add(room, room.owner, "plan", { group: "day-1" });
  const c = await add(room, room.owner, "plan", { group: "day-2" });

  // 손님이 a를 고치는 중이면 주인은 그 날 묶음을 잡지 못한다. 다른 날은 잡는다.
  assert.equal((await lock(room, guest, ["i:" + a.id])).status, 200);
  const blocked = await lock(room, room.owner, ["g:day-1"]);
  assert.equal(blocked.status, 423);
  assert.equal(blocked.body.locks[0].name, "i:" + a.id);
  assert.equal((await lock(room, room.owner, ["g:day-2"])).status, 200);
  assert.equal((await lock(room, guest, [], ["i:" + a.id])).status, 200);

  // 주인이 묶음을 잡으면 항목 잠금 없이 그 날의 항목들을 한 번에 쓴다(순서 바꾸기).
  assert.equal((await lock(room, room.owner, ["g:day-1"])).status, 200);
  const reorder = await write(room, room.owner, [
    { id: a.id, kind: "plan", baseRev: a.rev, cipher: cipher() },
    { id: b.id, kind: "plan", baseRev: b.rev, cipher: cipher() },
  ]);
  assert.equal(reorder.status, 200);
  // 그동안 손님은 그 날의 항목을 잡지도, 그 날에 새 항목을 만들지도, 다른 날 항목을 그 날로 옮기지도 못한다.
  assert.equal((await lock(room, guest, ["i:" + b.id])).body.locks[0].name, "g:day-1");
  assert.equal((await add(room, guest, "plan", { group: "day-3" })).rev > 0, true);
  assert.equal((await write(room, guest, { id: itemId(), kind: "plan", baseRev: 0, cipher: cipher(), group: "day-1" })).body.error, "locked");
  assert.equal((await lock(room, room.owner, [], ["g:day-2"])).status, 200);
  assert.equal((await lock(room, guest, ["i:" + c.id])).status, 200);
  assert.equal((await write(room, guest, { id: c.id, kind: "plan", baseRev: c.rev, cipher: cipher(), group: "day-1" })).body.error, "locked");
  // group을 빼고 쓰면 묶음은 그대로, null이면 묶음에서 뺀다.
  const kept = await write(room, guest, { id: c.id, kind: "plan", baseRev: c.rev, cipher: cipher() });
  assert.equal(kept.status, 200);
  assert.equal((await changes(room, guest, kept.body.rev - 1)).body.items[0].group, "day-2");
  const cleared = await write(room, guest, { id: c.id, kind: "plan", baseRev: kept.body.rev, cipher: cipher(), group: null });
  assert.equal((await changes(room, guest, cleared.body.rev - 1)).body.items[0].group, undefined);
});

// MARK: 권한

test("share kinds: meta is the owner's, a member card is its member's, own expenses and notices are their creator's", async () => {
  const room = await makeRoom();
  const guest = await join(room), third = await join(room);
  const forbidden = async (member, entry) => {
    const refused = await write(room, member, entry);
    assert.equal(refused.status, 403, JSON.stringify(refused.body));
    assert.equal(refused.body.error, "forbidden");
  };

  // meta: 주인만 만들고 고친다. 잠금 없이 쓴다.
  await forbidden(guest, { id: itemId(), kind: "meta", baseRev: 0, cipher: cipher() });
  const meta = await add(room, room.owner, "meta");
  await forbidden(guest, { id: meta.id, kind: "meta", baseRev: meta.rev, cipher: cipher() });
  await forbidden(guest, { id: meta.id, baseRev: meta.rev, delete: true });
  assert.equal((await write(room, room.owner, { id: meta.id, kind: "meta", baseRev: meta.rev, cipher: cipher() })).status, 200);

  // member: id가 member-<내 번호>인 카드 하나. 남의 카드는 주인도 못 쓰고, 카드는 직접 지우지 못한다.
  const card = await add(room, guest, "member", { id: "member-2" });
  await forbidden(guest, { id: "member-3", kind: "member", baseRev: 0, cipher: cipher() });
  await forbidden(room.owner, { id: "member-2", kind: "member", baseRev: card.rev, cipher: cipher() });
  await forbidden(guest, { id: "member-2", baseRev: card.rev, delete: true });
  assert.equal((await write(room, guest, { id: "member-2", kind: "member", baseRev: card.rev, cipher: cipher() })).status, 200);
  // member- 로 시작하는 id는 카드만 쓴다(남의 카드 자리를 다른 종류로 차지하지 못한다).
  assert.equal((await write(room, third, { id: "member-3", kind: "plan", baseRev: 0, cipher: cipher() })).status, 422);
  assert.equal((await write(room, third, { id: itemId(), kind: "member", baseRev: 0, cipher: cipher() })).status, 422);

  // expense-own: 누구나 만들고 만든 사람만 고치고 지운다.
  const own = await add(room, guest, "expense-own");
  await forbidden(room.owner, { id: own.id, kind: "expense-own", baseRev: own.rev, cipher: cipher() });
  await forbidden(third, { id: own.id, baseRev: own.rev, delete: true });
  assert.equal((await write(room, guest, { id: own.id, baseRev: own.rev, delete: true })).status, 200);

  // notice: 만든 사람만 고친다. 지우기는 만든 사람과 주인.
  const notice = await add(room, guest, "notice");
  await forbidden(third, { id: notice.id, kind: "notice", baseRev: notice.rev, cipher: cipher() });
  await forbidden(room.owner, { id: notice.id, kind: "notice", baseRev: notice.rev, cipher: cipher() });
  await forbidden(third, { id: notice.id, baseRev: notice.rev, delete: true });
  assert.equal((await write(room, room.owner, { id: notice.id, baseRev: notice.rev, delete: true })).status, 200);

  // 종류는 바꾸지 못한다. 모르는 종류는 받지 않는다.
  const shared = await add(room, guest, "expense-shared");
  await lock(room, third, ["i:" + shared.id]);
  assert.equal((await write(room, third, { id: shared.id, kind: "expense-own", baseRev: shared.rev, cipher: cipher() })).body.error, "kind_immutable");
  assert.equal((await write(room, third, { id: shared.id, kind: "expense-shared", baseRev: shared.rev, cipher: cipher() })).status, 200);
  assert.equal((await write(room, third, { id: itemId(), kind: "location", baseRev: 0, cipher: cipher() })).status, 422);
});

test("share close: after the owner closes the settlement, shared expenses are read-only; reopening restores them", async () => {
  const room = await makeRoom();
  const guest = await join(room);
  const shared = await add(room, guest, "expense-shared");
  await lock(room, guest, ["i:" + shared.id]);

  assert.equal((await call(room.env, "POST", room.path + "/close", { token: guest.token, body: { closed: true } })).body.error, "owner_only");
  assert.equal((await call(room.env, "POST", room.path + "/close", { token: room.owner.token, body: { closed: true } })).body.error, "owner_only");
  assert.equal((await call(room.env, "POST", room.path + "/close", { token: guest.token, owner: room.ownerKey, body: { closed: true } })).body.error, "owner_only");
  assert.equal((await call(room.env, "POST", room.path + "/close", { token: room.owner.token, owner: secret(), body: { closed: true } })).status, 403);
  assert.equal((await call(room.env, "POST", room.path + "/close", { token: room.owner.token, owner: room.ownerKey, body: { closed: "yes" } })).status, 422);
  assert.deepEqual((await call(room.env, "POST", room.path + "/close", { token: room.owner.token, owner: room.ownerKey, body: { closed: true } })).body, { closed: true });

  for (const entry of [
    { id: itemId(), kind: "expense-shared", baseRev: 0, cipher: cipher() },
    { id: shared.id, kind: "expense-shared", baseRev: shared.rev, cipher: cipher() },
    { id: shared.id, baseRev: shared.rev, delete: true },
  ]) {
    for (const member of [guest, room.owner]) {
      const refused = await write(room, member, entry);
      assert.equal(refused.status, 423);
      assert.equal(refused.body.error, "settlement_closed");
    }
  }
  // 계획·개인 지출·공지는 마감과 상관없다.
  for (const kind of ["plan", "expense-own", "notice"]) await add(room, guest, kind);
  assert.equal((await call(room.env, "GET", room.path, { token: guest.token })).body.closed, true);
  assert.equal((await changes(room, guest)).body.closed, true);

  await call(room.env, "POST", room.path + "/close", { token: room.owner.token, owner: room.ownerKey, body: { closed: false } });
  assert.equal((await write(room, guest, { id: shared.id, kind: "expense-shared", baseRev: shared.rev, cipher: cipher() })).status, 200);
});

// MARK: 공지 확인

test("share notice: members confirm a notice, the sender sees who did, and editing the notice asks again", async () => {
  const room = await makeRoom();
  const guest = await join(room), third = await join(room);
  const notice = await add(room, guest, "notice");
  const ack = (member, id = notice.id) => call(room.env, "POST", room.path + "/acks", { token: member.token, body: { id } });

  const first = await ack(room.owner);
  assert.equal(first.status, 200);
  assert.deepEqual(first.body.acks, { 1: room.clock.now });
  room.clock.now += 5000;
  const again = await ack(room.owner); // 다시 눌러도 그대로
  assert.deepEqual(again.body, first.body);
  const second = await ack(third);
  assert.deepEqual(Object.keys(second.body.acks), ["1", "3"]);

  // 보낸 사람이 따라잡기로 본다: 내용 개정(rev)은 그대로, 순번(seq)만 올라 있다.
  const seen = (await changes(room, guest, notice.rev)).body;
  assert.equal(seen.items.length, 1);
  assert.deepEqual({ rev: seen.items[0].rev, seq: seen.items[0].seq, acks: seen.items[0].acks }, { rev: notice.rev, seq: second.body.seq, acks: second.body.acks });
  assert.ok(seen.items[0].seq > notice.rev);

  // 확인이 쌓여도 보낸 사람은 예전 rev로 고칠 수 있고, 고치면 확인이 비워진다.
  const edited = await write(room, guest, { id: notice.id, kind: "notice", baseRev: notice.rev, cipher: cipher() });
  assert.equal(edited.status, 200);
  assert.deepEqual((await changes(room, guest, edited.body.rev - 1)).body.items[0].acks, {});

  const plan = await add(room, guest, "plan");
  assert.equal((await ack(third, plan.id)).body.error, "no_notice");
  assert.equal((await ack(third, itemId())).status, 404);
  await write(room, guest, { id: notice.id, baseRev: edited.body.rev, delete: true });
  assert.equal((await ack(third)).status, 404);
});

// MARK: 따라잡기

test("share changes: catching up from a revision returns newer items in order, in pages, with tombstones", async () => {
  const room = await makeRoom();
  const guest = await join(room);
  const made = [];
  for (let i = 0; i < 5; i++) made.push(await add(room, room.owner, "expense-own"));
  await write(room, room.owner, { id: made[1].id, baseRev: made[1].rev, delete: true }); // rev 6

  const all = (await changes(room, guest)).body;
  assert.deepEqual({ rev: all.rev, epoch: all.epoch, more: all.more, next: all.next }, { rev: 6, epoch: 1, more: false, next: 6 });
  assert.deepEqual(all.items.map((i) => i.id), [made[0], made[2], made[3], made[4]].map((i) => i.id)); // 처음 받을 때 묘비는 뺀다.
  assert.deepEqual(Object.keys(all.items[0]).sort(), ["by", "cipher", "createdBy", "epoch", "id", "kind", "rev", "seq", "updatedAt"]);

  const page1 = (await changes(room, guest, 0, 2)).body;
  assert.deepEqual({ ids: page1.items.map((i) => i.id), more: page1.more, next: page1.next }, { ids: [made[0].id, made[2].id], more: true, next: 3 }); // 지워진 made[1]의 예전 순번 2는 비어 있다.
  const page2 = (await changes(room, guest, page1.next, 2)).body;
  assert.deepEqual({ ids: page2.items.map((i) => i.id), more: page2.more, next: page2.next }, { ids: [made[3].id, made[4].id], more: true, next: 5 });
  const page3 = (await changes(room, guest, page2.next, 2)).body;
  assert.deepEqual({ ids: page3.items.map((i) => i.id), more: page3.more, next: page3.next }, { ids: [made[1].id], more: false, next: 6 });
  assert.deepEqual(page3.items[0], { id: made[1].id, kind: "expense-own", rev: 6, seq: 6, deleted: true, updatedAt: room.clock.now, by: 1, createdBy: 1 });

  assert.deepEqual((await changes(room, guest, 6)).body.items, []);
  assert.equal((await call(room.env, "GET", room.path + "/changes?since=-1", { token: guest.token })).status, 422);
  assert.equal((await call(room.env, "GET", room.path + "/changes?since=abc", { token: guest.token })).status, 422);
  // 한 번에 주는 양은 글자 수로도 끊는다.
  await withLimit("changesChars", 100, async () => {
    const small = (await changes(room, guest)).body;
    assert.deepEqual({ count: small.items.length, more: small.more, next: small.next }, { count: 1, more: true, next: 1 });
  });
});

// MARK: 나가기·내보내기

test("share leave and kick: the member's token stops working, their card and locks go, and kicking suggests a new password", async () => {
  const room = await makeRoom();
  const guest = await join(room), third = await join(room);
  await add(room, guest, "member", { id: "member-2" });
  const plan = await add(room, room.owner);
  await lock(room, guest, ["i:" + plan.id]);
  const socket = await connect(room, guest);
  const watcher = await connect(room, room.owner);
  watcher.take();

  assert.equal((await call(room.env, "POST", room.path + "/leave", { token: room.owner.token })).body.error, "owner_cannot_leave");
  assert.equal((await call(room.env, "POST", room.path + "/kick", { token: third.token, body: { member: 2 } })).body.error, "owner_only");
  const kicked = await call(room.env, "POST", room.path + "/kick", { token: room.owner.token, owner: room.ownerKey, body: { member: 2 } });
  assert.deepEqual(kicked.body, { ok: true, member: 2, rekeyRecommended: true });
  assert.deepEqual(socket.closed, { code: CLOSE.kicked, reason: "kicked" });
  const events = watcher.take();
  assert.deepEqual(events.find((m) => m.t === "locks").clear, ["i:" + plan.id]);
  assert.equal(events.find((m) => m.t === "items").items[0].deleted, true);
  assert.deepEqual(events.find((m) => m.t === "member"), { t: "member", event: "kick", no: 2, now: room.clock.now });

  const after = await call(room.env, "GET", room.path, { token: guest.token });
  assert.equal(after.status, 403);
  assert.deepEqual(after.body, { error: "removed", reason: "kicked" });
  const state = (await call(room.env, "GET", room.path, { token: room.owner.token })).body;
  assert.deepEqual(state.members.map((m) => m.no), [1, 3]);
  assert.deepEqual(state.locks, []);
  assert.equal((await changes(room, third, plan.rev)).body.items.find((i) => i.id === "member-2").deleted, true);
  for (const member of [1, 2, 9]) {
    assert.equal((await call(room.env, "POST", room.path + "/kick", { token: room.owner.token, owner: room.ownerKey, body: { member } })).body.error, "no_member");
  }

  assert.equal((await call(room.env, "POST", room.path + "/leave", { token: third.token })).status, 204);
  assert.deepEqual((await call(room.env, "GET", room.path, { token: third.token })).body, { error: "removed", reason: "left" });
  assert.deepEqual(watcher.take("member").at(-1), { t: "member", event: "leave", no: 3, now: room.clock.now });
});

// MARK: 키 교체

test("share rotate: the owner re-seals every live item under a new proof; others must re-enter the new password", async () => {
  const room = await makeRoom();
  const guest = await join(room);
  const kept = [await add(room, guest, "plan"), await add(room, guest, "notice"), await add(room, room.owner, "meta")];
  const dead = await add(room, guest, "expense-own");
  await write(room, guest, { id: dead.id, baseRev: dead.rev, delete: true }); // rev 5
  await call(room.env, "POST", room.path + "/acks", { token: room.owner.token, body: { id: kept[1].id } }); // rev 6
  await lock(room, guest, ["i:" + kept[0].id]);
  const guestSocket = await connect(room, guest), ownerSocket = await connect(room, room.owner);
  ownerSocket.take();

  const proof = secret();
  const fresh = kept.map((i) => ({ id: i.id, cipher: cipher(64) }));
  const rotate = (body, auth = { token: room.owner.token, owner: room.ownerKey }) => call(room.env, "POST", room.path + "/rotate", { ...auth, body });
  assert.equal((await rotate({ rev: 6, proof, items: fresh }, { token: guest.token })).body.error, "owner_only");
  assert.deepEqual((await rotate({ rev: 5, proof, items: fresh })).body, { error: "conflict", rev: 6 });
  assert.deepEqual((await rotate({ rev: 6, proof, items: fresh.slice(1) })).body, { error: "incomplete", missing: 1, extra: 0 });
  assert.deepEqual((await rotate({ rev: 6, proof, items: [...fresh, { id: dead.id, cipher: cipher() }] })).body, { error: "incomplete", missing: 0, extra: 1 });
  assert.equal((await rotate({ rev: 6, proof: room.proof, items: fresh })).body.error, "same_proof");
  assert.equal((await rotate({ rev: 6, proof, items: [fresh[0], fresh[0], fresh[2]] })).status, 422);
  assert.equal((await rotate({ rev: 6, proof, items: [{ ...fresh[0], cipher: "AAAA" }, fresh[1], fresh[2]] })).body.error, "bad_cipher");

  const done = await rotate({ rev: 6, proof, items: fresh });
  assert.deepEqual(done.body, { epoch: 2, rev: 9 });
  assert.deepEqual(guestSocket.closed, { code: CLOSE.rekey, reason: "rekey" });
  assert.equal(ownerSocket.closed, null);
  assert.deepEqual(ownerSocket.take("room")[0], { t: "room", closed: false, expiresAt: room.expiresAt, epoch: 2, rekeyed: true, now: room.clock.now });

  // 주인은 바로 계속 쓴다. 새 암호문·세대, 확인 기록과 만든 사람은 그대로, 잠금은 모두 풀렸다.
  const snapshot = (await changes(room, room.owner)).body;
  const after = (index) => snapshot.items.find((i) => i.id === kept[index].id);
  assert.equal(snapshot.items.length, 3);
  for (const [index, entry] of fresh.entries()) assert.deepEqual([after(index).cipher, after(index).epoch], [entry.cipher, 2]);
  assert.deepEqual([0, 1, 2].map((index) => after(index).createdBy), [2, 2, 1]);
  assert.deepEqual(Object.keys(after(1).acks), ["1"]);
  assert.deepEqual(snapshot.items.map((i) => i.seq), [7, 8, 9]);
  assert.deepEqual((await call(room.env, "GET", room.path, { token: room.owner.token })).body.locks, []);
  assert.equal((await write(room, room.owner, { id: itemId(), kind: "plan", baseRev: 0, cipher: cipher() }, 1)).body.error, "epoch_mismatch");
  assert.equal((await write(room, room.owner, { id: itemId(), kind: "plan", baseRev: 0, cipher: cipher() }, 2)).status, 200);

  // 손님은 새 비밀번호의 증명을 낼 때까지 아무것도 못 한다. 예전 증명으로는 들어오지도 못한다.
  for (const [method, sub] of [["GET", ""], ["GET", "/changes?since=0"], ["GET", "/ws"]]) {
    assert.deepEqual((await call(room.env, method, room.path + sub, { token: guest.token, headers: { upgrade: "websocket" } })).body, { error: "rekey_required", epoch: 2 });
  }
  assert.equal((await call(room.env, "POST", room.path + "/join", { body: { proof: room.proof } })).body.error, "wrong_password");
  assert.equal((await call(room.env, "POST", room.path + "/rekey", { token: guest.token, body: { proof: room.proof } })).body.error, "wrong_password");
  assert.equal((await call(room.env, "POST", room.path + "/rekey", { body: { proof } })).status, 401);
  assert.deepEqual((await call(room.env, "GET", room.path, { token: room.owner.token })).body.members[1], { no: 2, joinedAt: room.clock.now, online: false, stale: true });
  assert.deepEqual((await call(room.env, "POST", room.path + "/rekey", { token: guest.token, body: { proof } })).body, { epoch: 2, rev: 10 });
  assert.equal((await changes(room, guest)).status, 200);
  assert.equal((await join(room, proof)).no, 3);
});

// MARK: 지우기·만료

test("share delete: only the owner key erases the room, and nothing is left", async () => {
  const room = await makeRoom();
  const guest = await join(room);
  await add(room, guest);
  const socket = await connect(room, guest);
  assert.equal((await call(room.env, "DELETE", room.path, { token: guest.token })).status, 403);
  assert.equal((await call(room.env, "DELETE", room.path, { token: room.owner.token })).status, 403);
  assert.equal((await call(room.env, "DELETE", room.path, { token: room.owner.token, owner: room.ownerKey })).status, 204);
  assert.equal(room.instance.ctx.storage.map.size, 0);
  assert.equal(room.instance.ctx.storage.alarm, null);
  assert.deepEqual(socket.closed, { code: CLOSE.gone, reason: "deleted" });
  assert.equal((await call(room.env, "GET", room.path, { token: guest.token })).status, 404);
  assert.equal((await call(room.env, "POST", room.path + "/join", { body: { proof: room.proof } })).status, 404);
});

test("share expiry: the alarm erases the room at expiresAt; the owner may extend it up to 400 days from creation", async () => {
  const room = await makeRoom();
  const guest = await join(room);
  await add(room, guest);
  const storage = room.instance.ctx.storage;
  const extend = (expiresAt, auth = { token: room.owner.token, owner: room.ownerKey }) => call(room.env, "POST", room.path + "/expiry", { ...auth, body: { expiresAt } });

  assert.equal((await extend(room.expiresAt + DAY, { token: guest.token })).body.error, "owner_only");
  assert.equal((await extend(room.clock.now + 401 * DAY)).body.error, "bad_expiry");
  assert.equal((await extend(room.clock.now + MINUTE)).body.error, "bad_expiry");
  const later = room.expiresAt + 30 * DAY;
  assert.deepEqual((await extend(later)).body, { expiresAt: later });
  assert.equal(storage.alarm, later);

  // 늘리기 전에 맞춰 둔 알람이 와도 지우지 않고 새 기한으로 다시 맞춘다.
  room.clock.now = room.expiresAt + 1;
  storage.alarm = null;
  await room.instance.room.alarm();
  assert.equal(storage.alarm, later);
  assert.equal((await changes(room, guest)).body.items.length, 1);

  room.clock.now = later;
  await room.instance.room.alarm();
  assert.equal(storage.map.size, 0);
  assert.equal((await call(room.env, "GET", room.path, { token: guest.token })).status, 404);
});

test("share expiry: a request after expiresAt finds nothing even if the alarm has not run", async () => {
  const room = await makeRoom();
  await add(room, room.owner);
  room.clock.now = room.expiresAt;
  assert.equal((await call(room.env, "GET", room.path, { token: room.owner.token })).status, 404);
  assert.equal(room.instance.ctx.storage.map.size, 0);
});

// MARK: 한도

test("share limits: item size, cipher shape, batch size, item count, room bytes, body size and per-member rate", async () => {
  const room = await makeRoom();
  const entry = (extra = {}) => ({ id: itemId(), kind: "expense-own", baseRev: 0, cipher: cipher(), ...extra });
  assert.equal((await write(room, room.owner, entry({ cipher: cipher(SHARE.itemBytes) }))).status, 200);
  const large = await write(room, room.owner, entry({ cipher: cipher(SHARE.itemBytes + 1) }));
  assert.equal(large.status, 413);
  assert.deepEqual(large.body, { error: "item_too_large", index: 0 });
  for (const bad of ["", "AQ", cipher(28), base64url(Buffer.concat([Buffer.from([2]), random(40)])), cipher() + "=", cipher() + "+", 12]) {
    assert.equal((await write(room, room.owner, entry({ cipher: bad }))).body.error, "bad_cipher", String(bad));
  }
  assert.equal((await write(room, room.owner, entry({ id: "short" }))).status, 422);
  assert.equal((await write(room, room.owner, entry({ baseRev: -1 }))).status, 422);
  assert.equal((await write(room, room.owner, entry({ group: "has space" }))).status, 422);
  assert.equal((await write(room, room.owner, [])).status, 422);
  assert.equal((await write(room, room.owner, Array.from({ length: SHARE.batch + 1 }, () => entry()))).status, 422);
  assert.equal((await write(room, room.owner, Array.from({ length: SHARE.batch }, () => entry()))).status, 200);
  assert.equal((await call(room.env, "POST", room.path + "/items", { token: room.owner.token, body: { epoch: 1, writes: Array.from({ length: 13 }, () => entry({ cipher: cipher(SHARE.itemBytes) })) } })).status, 413);

  const count = (await call(room.env, "GET", room.path, { token: room.owner.token })).body.counts;
  assert.deepEqual(count, { items: 51, ids: 51, bytes: SHARE.itemBytes + 50 * 48 });
  await withLimit("liveItems", 52, async () => {
    assert.equal((await write(room, room.owner, entry())).status, 200);
    assert.deepEqual((await write(room, room.owner, entry())).body, { error: "room_full", limit: "items" });
  });
  await withLimit("itemIds", 52, async () => {
    assert.deepEqual((await write(room, room.owner, entry())).body, { error: "room_full", limit: "ids" });
  });
  await withLimit("roomBytes", count.bytes + 48 + 10, async () => {
    assert.deepEqual((await write(room, room.owner, entry())).body, { error: "room_full", limit: "bytes" });
  });
  await withLimit("opsPerMinute", 3, async () => {
    room.clock.now += MINUTE;
    for (let i = 0; i < 3; i++) assert.equal((await call(room.env, "GET", room.path, { token: room.owner.token })).status, 200);
    const over = await call(room.env, "GET", room.path, { token: room.owner.token });
    assert.equal(over.status, 429);
    assert.equal(over.body.error, "rate_limited");
    room.clock.now += MINUTE;
    assert.equal((await call(room.env, "GET", room.path, { token: room.owner.token })).status, 200);
  });
});

test("share rotate: a full room of 300 items is re-sealed in storage batches of at most 128 keys", async () => {
  const room = await makeRoom();
  const ids = [];
  for (let page = 0; page < 6; page++) {
    const writes = Array.from({ length: 50 }, () => ({ id: itemId(), kind: "expense-own", baseRev: 0, cipher: cipher() }));
    ids.push(...writes.map((w) => w.id));
    assert.equal((await write(room, room.owner, writes)).status, 200);
  }
  const done = await call(room.env, "POST", room.path + "/rotate", { token: room.owner.token, owner: room.ownerKey, body: { rev: 300, proof: secret(), items: ids.map((id) => ({ id, cipher: cipher() })) } });
  assert.deepEqual(done.body, { epoch: 2, rev: 600 });
  const storage = room.instance.ctx.storage;
  assert.equal([...storage.map.keys()].filter((k) => k.startsWith("r:")).length, 300);
  let since = 0, seen = 0;
  for (;;) {
    const page = (await changes(room, room.owner, since)).body;
    seen += page.items.length;
    assert.ok(page.items.every((i) => i.epoch === 2));
    if (!page.more) break;
    since = page.next;
  }
  assert.equal(seen, 300);
});

// MARK: WebSocket (핸들러를 직접 부른다)

test("share socket: connecting needs an upgrade and a current member; hello carries the room state", async () => {
  const room = await makeRoom();
  const guest = await join(room);
  assert.equal((await call(room.env, "GET", room.path + "/ws", { token: guest.token })).status, 426);
  assert.equal((await call(room.env, "GET", room.path + "/ws", { headers: { upgrade: "websocket" } })).status, 401);
  const ownerSocket = await connect(room, room.owner);
  const hello = ownerSocket.take()[0];
  assert.deepEqual({ t: hello.t, you: hello.you, rev: hello.rev, epoch: hello.epoch, closed: hello.closed, locks: hello.locks }, { t: "hello", you: 1, rev: 0, epoch: 1, closed: false, locks: [] });
  assert.deepEqual(hello.members.map((m) => [m.no, m.online]), [[1, true], [2, false]]);
  assert.deepEqual(ownerSocket.tags, ["m:1"]);

  const guestSocket = await connect(room, guest);
  assert.deepEqual(ownerSocket.take(), [{ t: "member", event: "online", no: 2, now: room.clock.now }]);
  assert.deepEqual(guestSocket.take()[0].members.map((m) => m.online), [true, true]);
  // 입장은 방 안의 모두에게 알린다.
  await join(room);
  assert.deepEqual(guestSocket.take(), [{ t: "member", event: "join", no: 3, now: room.clock.now }]);
});

test("share socket: writes, locks and acks sent on a socket answer the sender and reach everyone else", async () => {
  const room = await makeRoom();
  const guest = await join(room);
  const ownerSocket = await connect(room, room.owner), guestSocket = await connect(room, guest);
  ownerSocket.take(); guestSocket.take();

  const id = itemId(), sealed = cipher();
  const made = await ask(room, guestSocket, { op: "write", epoch: 1, writes: [{ id, kind: "plan", baseRev: 0, cipher: sealed, group: "day-1" }] });
  assert.deepEqual(made, { t: "res", id: 7, status: 200, rev: 1, items: [{ id, rev: 1, seq: 1, updatedAt: room.clock.now }] });
  assert.deepEqual(guestSocket.take().length, 1); // 보낸 사람에게는 응답만
  assert.deepEqual(ownerSocket.take(), [{ t: "items", rev: 1, items: [{ id, kind: "plan", rev: 1, seq: 1, epoch: 1, cipher: sealed, updatedAt: room.clock.now, by: 2, createdBy: 2, group: "day-1" }] }]);

  const leased = await ask(room, guestSocket, { op: "lock", acquire: ["i:" + id] });
  assert.equal(leased.status, 200);
  assert.deepEqual(ownerSocket.take(), [{ t: "locks", set: [{ name: "i:" + id, by: 2, until: room.clock.now + SHARE.leaseMs }], clear: [], by: 2, now: room.clock.now }]);
  const refused = await ask(room, ownerSocket, { op: "lock", acquire: ["i:" + id] });
  assert.deepEqual({ status: refused.status, error: refused.error, by: refused.locks[0].by }, { status: 423, error: "locked", by: 2 });
  assert.deepEqual(guestSocket.take(), [leased]); // 거절은 방송하지 않는다.

  // HTTP로 한 일도 연결된 모두(보낸 사람의 소켓 포함)에게 간다.
  const notice = await add(room, room.owner, "notice");
  assert.equal(guestSocket.take("items")[0].items[0].id, notice.id);
  assert.equal(ownerSocket.take("items").length, 1);
  const acked = await ask(room, guestSocket, { op: "ack", notice: notice.id });
  assert.deepEqual(acked, { t: "res", id: 7, status: 200, acks: { 2: room.clock.now }, seq: 3, rev: 3 });
  assert.equal((await ask(room, guestSocket, { op: "ack" })).status, 422);
  assert.deepEqual(ownerSocket.take("ack"), [{ t: "ack", id: notice.id, by: 2, at: room.clock.now, seq: 3, rev: 3 }]);

  const caught = await ask(room, ownerSocket, { op: "changes", since: 1 });
  assert.deepEqual({ status: caught.status, ids: caught.items.map((i) => i.id), next: caught.next }, { status: 200, ids: [notice.id], next: 3 });
  assert.equal((await ask(room, ownerSocket, { op: "state" })).you, 1);
  assert.deepEqual(await ask(room, ownerSocket, { op: "dance" }), { t: "res", id: 7, status: 400, error: "unknown_op" });
  await room.instance.room.webSocketMessage(ownerSocket, "{");
  assert.deepEqual(ownerSocket.take().at(-1), { t: "res", id: null, status: 400, error: "invalid_json" });
  // 주인 전용 일은 소켓으로 받지 않는다.
  assert.equal((await ask(room, ownerSocket, { op: "rotate" })).error, "unknown_op");
});

test("share socket: when a member's last connection drops, their locks are released and others are told", async () => {
  const room = await makeRoom();
  const guest = await join(room);
  const plan = await add(room, room.owner);
  const ownerSocket = await connect(room, room.owner);
  const first = await connect(room, guest), second = await connect(room, guest);
  await ask(room, first, { op: "lock", acquire: ["i:" + plan.id, "g:day-1"] });
  ownerSocket.take();

  // 같은 사람의 다른 연결이 남아 있으면 그대로 둔다.
  await room.instance.room.webSocketClose(first, 1006, "", false);
  first.closed ??= { code: 1006 };
  assert.deepEqual(ownerSocket.take(), []);
  assert.equal((await call(room.env, "GET", room.path, { token: room.owner.token })).body.locks.length, 2);

  await room.instance.room.webSocketClose(second, 1001, "", true);
  second.closed ??= { code: 1001 };
  const events = ownerSocket.take();
  assert.deepEqual(events[0].t === "locks" && events[0].clear.sort(), ["g:day-1", "i:" + plan.id].sort());
  assert.deepEqual(events[1], { t: "member", event: "offline", no: 2, now: room.clock.now });
  const state = (await call(room.env, "GET", room.path, { token: room.owner.token })).body;
  assert.deepEqual(state.locks, []);
  assert.deepEqual(state.members.map((m) => m.online), [true, false]);
  assert.equal((await lock(room, room.owner, ["i:" + plan.id])).status, 200);
});

test("share socket: a third connection replaces the member's oldest, and oversized or post-removal messages close the socket", async () => {
  const room = await makeRoom();
  const guest = await join(room);
  const first = await connect(room, guest);
  room.clock.now += 1000;
  const second = await connect(room, guest);
  room.clock.now += 1000;
  const third = await connect(room, guest);
  assert.deepEqual(first.closed, { code: CLOSE.replaced, reason: "replaced" });
  assert.equal(second.closed, null);

  await room.instance.room.webSocketMessage(second, "x".repeat(SHARE.bodyBytes + 1));
  assert.deepEqual(second.closed, { code: CLOSE.tooBig, reason: "too_large" });
  await room.instance.room.webSocketMessage(third, new ArrayBuffer(4));
  assert.equal(third.closed.code, CLOSE.tooBig);

  // 소켓이 남은 채 방이 사라졌다면(지우기와 메시지가 엇갈림) 닫는다.
  const late = await connect(room, guest);
  room.instance.ctx.storage.map.clear();
  await room.instance.room.webSocketMessage(late, JSON.stringify({ id: 1, op: "state" }));
  assert.deepEqual(late.closed, { code: CLOSE.gone, reason: "deleted" });
});

test("share privacy: the room code writes no logs and room paths carry no secret", async () => {
  const source = readFileSync(new URL("../src/share.js", import.meta.url), "utf8");
  assert.ok(!/console\./.test(source));
  const room = await makeRoom();
  // 주소에 넣은 증명·토큰은 쓰이지 않는다(헤더와 본문만 본다).
  assert.equal((await call(room.env, "POST", `${room.path}/join?proof=${room.proof}`, { body: {} })).status, 422);
  assert.equal((await call(room.env, "GET", `${room.path}?token=${room.owner.token}`)).status, 401);
});

test("share rotate: an entry may carry the day group re-derived under the new key; without it the group stays (TSR1117A01)", async () => {
  const room = await makeRoom();
  const moved = await add(room, room.owner, "plan", { group: "oldDayName" });
  const kept = await add(room, room.owner, "plan", { group: "otherRule" });
  const rotate = (items) => call(room.env, "POST", room.path + "/rotate", { token: room.owner.token, owner: room.ownerKey, body: { rev: 2, proof: secret(), items } });
  assert.equal((await rotate([{ id: moved.id, cipher: cipher(), group: "bad name!" }, { id: kept.id, cipher: cipher() }])).body.error, "bad_request");
  assert.equal((await rotate([{ id: moved.id, cipher: cipher(), group: 12 }, { id: kept.id, cipher: cipher() }])).status, 422);
  assert.equal((await rotate([{ id: moved.id, cipher: cipher(), group: "newDayName" }, { id: kept.id, cipher: cipher() }])).status, 200);
  const items = (await changes(room, room.owner)).body.items;
  assert.deepEqual(items.map((i) => [i.id, i.group]).sort(), [[moved.id, "newDayName"], [kept.id, "otherRule"]].sort());
  // 새 이름의 묶음 잠금이 그 항목을 덮는다.
  assert.equal((await lock(room, room.owner, ["g:newDayName"])).status, 200);
  const guestless = await write(room, room.owner, { id: moved.id, kind: "plan", baseRev: items.find((i) => i.id === moved.id).rev, cipher: cipher() }, 2);
  assert.equal(guestless.status, 200, JSON.stringify(guestless.body));
});

// MARK: 동행 위치 (LOC1116S01)

const openWindow = (room, from = room.clock.now - DAY, until = room.clock.now + 2 * DAY) =>
  call(room.env, "POST", room.path + "/locwindow", { token: room.owner.token, owner: room.ownerKey, body: { from, until } });
const sendLoc = (room, member, extra = {}) => call(room.env, "PUT", room.path + "/loc", { token: member.token, body: { epoch: 1, cipher: cipher(80), ...extra } });

test("share loc: nothing is accepted before the owner opens a window, and only the owner can open it", async () => {
  const room = await makeRoom();
  const guest = await join(room);
  assert.deepEqual((await sendLoc(room, guest)).body, { error: "loc_closed", locWindow: null });
  assert.equal((await call(room.env, "POST", room.path + "/locwindow", { token: guest.token, body: { from: 1, until: 2 } })).status, 403);
  assert.equal((await openWindow(room, room.clock.now, room.clock.now + SHARE.locWindowMaxMs + 1)).status, 422);
  assert.equal((await openWindow(room, room.clock.now + DAY, room.clock.now)).status, 422);
  assert.equal((await openWindow(room)).status, 200);
  assert.equal((await sendLoc(room, guest)).status, 200);
  // 창이 끝난 뒤에는 다시 거절한다.
  room.clock.now += 3 * DAY;
  assert.equal((await sendLoc(room, guest)).status, 403);
});

test("share loc: a position reaches the others but not the sender's socket, is kept once per member and replaced", async () => {
  const room = await makeRoom();
  const guest = await join(room);
  await openWindow(room);
  const ownerSocket = await connect(room, room.owner), guestSocket = await connect(room, guest);
  ownerSocket.take(); guestSocket.take();
  const sealed = cipher(80);
  const sent = await ask(room, guestSocket, { op: "loc", epoch: 1, cipher: sealed });
  assert.deepEqual(sent, { t: "res", id: 7, status: 200, now: room.clock.now });
  assert.deepEqual(ownerSocket.take("loc"), [{ t: "loc", by: 2, cipher: sealed, epoch: 1, at: room.clock.now }]);
  assert.equal(guestSocket.take("loc").length, 0);
  // 너무 잦으면 거절(도움 요청은 예외), 저장은 첫 건과 90초 뒤에만.
  assert.equal((await ask(room, guestSocket, { op: "loc", epoch: 1, cipher: cipher(80) })).error, "loc_rate");
  room.clock.now += 10_000;
  const second = cipher(80);
  assert.equal((await ask(room, guestSocket, { op: "loc", epoch: 1, cipher: second })).status, 200);
  assert.equal((await call(room.env, "GET", room.path + "/loc", { token: room.owner.token })).body.locs[0].cipher, sealed);
  room.clock.now += 90_000;
  const third = cipher(80);
  assert.equal((await ask(room, guestSocket, { op: "loc", epoch: 1, cipher: third })).status, 200);
  const kept = (await call(room.env, "GET", room.path + "/loc", { token: room.owner.token })).body;
  assert.deepEqual(kept.locs.map((l) => [l.by, l.cipher]), [[2, third]]);
  // 새로 붙은 소켓의 hello에 마지막 위치가 실려 온다.
  const later = await connect(room, room.owner);
  assert.deepEqual(later.sent.find((m) => m.t === "hello").locs.map((l) => l.by), [2]);
  // 10분이 지나면 없다.
  room.clock.now += 11 * MINUTE;
  assert.deepEqual((await call(room.env, "GET", room.path + "/loc", { token: room.owner.token })).body.locs, []);
});

test("share loc: help is stored for a day, bypasses the gap and is cleared by sending a normal position", async () => {
  const room = await makeRoom();
  const guest = await join(room);
  await openWindow(room);
  assert.equal((await sendLoc(room, guest)).status, 200);
  const help = cipher(90);
  assert.equal((await sendLoc(room, guest, { cipher: help, help: true })).status, 200); // 간격 안이어도
  room.clock.now += 20 * MINUTE;
  let locs = (await call(room.env, "GET", room.path + "/loc", { token: room.owner.token })).body.locs;
  assert.deepEqual(locs.map((l) => [l.cipher, l.help]), [[help, true]]);
  room.clock.now += 10_000;
  const calm = cipher(90);
  assert.equal((await sendLoc(room, guest, { cipher: calm })).status, 200); // 도움이 켜져 있었으므로 바로 저장
  locs = (await call(room.env, "GET", room.path + "/loc", { token: room.owner.token })).body.locs;
  assert.deepEqual(locs.map((l) => [l.cipher, l.help]), [[calm, undefined]]);
});

test("share loc: stopping, leaving, kicking and changing the password clear stored positions", async () => {
  const room = await makeRoom();
  const guest = await join(room), other = await join(room);
  await openWindow(room);
  await sendLoc(room, guest); await sendLoc(room, other);
  const ownerSocket = await connect(room, room.owner);
  ownerSocket.take();
  assert.equal((await call(room.env, "DELETE", room.path + "/loc", { token: guest.token })).status, 204);
  assert.deepEqual(ownerSocket.take("loc"), [{ t: "loc", by: 2, off: true }]);
  assert.deepEqual((await call(room.env, "GET", room.path + "/loc", { token: room.owner.token })).body.locs.map((l) => l.by), [3]);
  assert.equal((await call(room.env, "POST", room.path + "/kick", { token: room.owner.token, owner: room.ownerKey, body: { member: 3 } })).status, 200);
  assert.deepEqual((await call(room.env, "GET", room.path + "/loc", { token: room.owner.token })).body.locs, []);
});

test("share loc: turning location off does not reset the rate limit, and help storage keeps a gap (REV1117A01)", async () => {
  const room = await makeRoom();
  const guest = await join(room);
  await openWindow(room);
  assert.equal((await sendLoc(room, guest)).status, 200);
  assert.equal((await call(room.env, "DELETE", room.path + "/loc", { token: guest.token })).status, 204);
  // 끄고 바로 다시 켜도 15초 간격이 남아 있다.
  assert.equal((await sendLoc(room, guest)).body.error, "loc_rate");
  room.clock.now += SHARE.locGapMs;
  const first = cipher(90);
  assert.equal((await sendLoc(room, guest, { cipher: first, help: true })).status, 200);
  room.clock.now += 2_000;
  assert.equal((await sendLoc(room, guest, { cipher: cipher(90), help: true })).status, 200); // 방송은 되지만
  const kept = (await call(room.env, "GET", room.path + "/loc", { token: room.owner.token })).body.locs;
  assert.deepEqual(kept.map((l) => l.cipher), [first], "도움 요청도 10초 안에는 다시 저장하지 않는다");
});

test("share loc: stored positions never outlive the location window, even a help request (REV1117A01)", async () => {
  const room = await makeRoom();
  const guest = await join(room);
  await openWindow(room, room.clock.now - DAY, room.clock.now + 5 * MINUTE);
  assert.equal((await sendLoc(room, guest, { help: true })).status, 200);
  room.clock.now += 4 * MINUTE;
  assert.equal((await call(room.env, "GET", room.path + "/loc", { token: room.owner.token })).body.locs.length, 1);
  room.clock.now += 2 * MINUTE; // 창이 끝났다. 도움 요청은 24시간 보관이어도 남기지 않는다.
  assert.deepEqual((await call(room.env, "GET", room.path + "/loc", { token: room.owner.token })).body.locs, []);
});

test("share write: a non-string item id or group is a 422, not a crash (REV1117A01)", async () => {
  const room = await makeRoom();
  const guest = await join(room);
  assert.equal((await write(room, guest, { id: 12345678, kind: "plan", baseRev: 0, cipher: cipher() })).status, 422);
  assert.equal((await write(room, guest, { id: itemId(), kind: "plan", baseRev: 0, cipher: cipher(), group: 123 })).status, 422);
});

test("share loc: wrong epoch, bad or oversized ciphertext and a plain write of kind loc are refused", async () => {
  const room = await makeRoom();
  const guest = await join(room);
  await openWindow(room);
  assert.deepEqual((await sendLoc(room, guest, { epoch: 2 })).body, { error: "epoch_mismatch", epoch: 1 });
  assert.equal((await sendLoc(room, guest, { cipher: "nope" })).body.error, "bad_cipher");
  assert.equal((await sendLoc(room, guest, { cipher: cipher(SHARE.locBytes + 40) })).status, 413);
  assert.equal((await write(room, guest, { id: itemId(), kind: "loc", baseRev: 0, cipher: cipher() })).status, 422);
  assert.equal((await call(room.env, "PUT", room.path + "/loc", { body: { epoch: 1, cipher: cipher() } })).status, 401);
});

test("share meet: one gathering point per room, anyone sets it, only inside the location window, never deleted", async () => {
  const room = await makeRoom();
  const guest = await join(room);
  const make = (member, baseRev) => write(room, member, { id: "meet-point", kind: "meet", baseRev, cipher: cipher(120) });
  assert.equal((await make(guest, 0)).body.error, "loc_closed"); // 창이 없으면 못 올린다.
  await openWindow(room);
  const first = await make(guest, 0);
  assert.equal(first.status, 200, JSON.stringify(first.body));
  const second = await make(room.owner, first.body.items[0].rev); // 다른 사람이 고친다.
  assert.equal(second.status, 200);
  assert.equal((await write(room, guest, { id: "meet-point", baseRev: second.body.items[0].rev, delete: true })).status, 422);
  assert.equal((await write(room, guest, { id: itemId(), kind: "meet", baseRev: 0, cipher: cipher(120) })).status, 422); // id는 고정
  room.clock.now += 3 * DAY; // 창이 끝나면 서버가 거둔다(묘비): 옛 판으로 고치려 하면 충돌이고, 새로 정하려 해도 창 밖이다.
  assert.equal((await make(guest, second.body.items[0].rev)).status, 409);
  assert.equal((await make(guest, 0)).status, 403);
});

test("share meet: the server clears the gathering point when the location window ends, by alarm or on the next request (REV1117A01)", async () => {
  const room = await makeRoom();
  const guest = await join(room);
  const storage = room.instance.ctx.storage;
  const make = (member, baseRev) => write(room, member, { id: "meet-point", kind: "meet", baseRev, cipher: cipher(120) });
  const end = room.clock.now + 2 * DAY;
  assert.equal((await openWindow(room, room.clock.now - DAY, end)).status, 200);
  assert.equal(storage.alarm, end, "알람은 위치 기간 끝에 맞춘다");
  const first = await make(guest, 0);
  assert.equal(first.status, 200);
  const ownerSocket = await connect(room, room.owner);
  ownerSocket.take();

  // 아무도 접속하지 않아도 알람이 거둔다.
  room.clock.now = end;
  await room.instance.room.alarm();
  assert.equal(storage.alarm, room.expiresAt, "거둔 뒤에는 방 기한으로 돌아간다");
  const shown = (await changes(room, guest, first.body.rev)).body.items.find((i) => i.id === "meet-point"); // since=0은 묘비를 건너뛴다
  assert.equal(shown.deleted, true);
  assert.equal(shown.cipher, undefined, "좌표가 든 암호문도 남지 않는다");
  assert.deepEqual(ownerSocket.take("items").flatMap((m) => m.items).map((i) => [i.id, i.deleted]), [["meet-point", true]]);

  // 새 기간을 열면 모이는 곳을 다시 정할 수 있고, 그 기간이 끝나면 또 거둔다.
  assert.equal((await openWindow(room, end, end + DAY)).status, 200);
  const again = await make(guest, 0);
  assert.equal(again.status, 200, JSON.stringify(again.body));
  room.clock.now = end + DAY + 1; // 알람 없이 다음 요청이 거둔다.
  assert.equal((await changes(room, guest, again.body.rev)).body.items.find((i) => i.id === "meet-point").deleted, true);
});
