// 시험용 KV·Durable Object 가짜(SEC1110A02). DO는 진짜 `UserState`를 메모리 저장소 위에서 돌린다.
import { ShareRoom, UserState } from "../src/index.js";

export class MemoryKV {
  constructor() { this.map = new Map(); this.options = new Map(); this.writes = 0; this.lists = 0; }
  async get(key) { return this.map.get(key) ?? null; }
  async put(key, value, options) { this.map.set(key, value); this.options.set(key, options); this.writes++; }
  async delete(key) { this.map.delete(key); this.writes++; }
  // Cloudflare KV list: pages of keys under a prefix (two per page here to exercise the cursor).
  async list({ prefix = "", cursor } = {}) {
    this.lists++;
    const names = [...this.map.keys()].filter((key) => key.startsWith(prefix)).sort();
    const start = cursor ? Number(cursor) : 0;
    const page = names.slice(start, start + 2);
    const done = start + 2 >= names.length;
    return { keys: page.map((name) => ({ name, expiration: this.options.get(name)?.expiration })), list_complete: done, cursor: done ? undefined : String(start + 2) };
  }
}

// 비동기 저장소. 매 호출마다 한 번 양보해 경쟁이 일어날 틈을 만든다(직렬화를 시험하려고).
const tick = () => new Promise((resolve) => setImmediate(resolve));

export class MemoryStorage {
  constructor() { this.map = new Map(); this.alarm = null; }
  async get(key) { await tick(); return structuredClone(this.map.get(key)); }
  async put(key, value) { await tick(); this.map.set(key, structuredClone(value)); }
  async delete(key) { await tick(); return this.map.delete(key); }
  async deleteAll() { this.map.clear(); }
  async list({ prefix = "" } = {}) {
    await tick();
    return new Map([...this.map.entries()].filter(([key]) => key.startsWith(prefix)).sort(([a], [b]) => a.localeCompare(b)).map(([k, v]) => [k, structuredClone(v)]));
  }
  async setAlarm(time) { this.alarm = time; }
}

export class FakeDurableObjects {
  constructor() { this.instances = new Map(); this.requests = 0; }
  idFromName(name) { return { name, toString: () => name }; }
  instance(name) {
    if (!this.instances.has(name)) this.instances.set(name, new UserState({ storage: new MemoryStorage() }));
    return this.instances.get(name);
  }
  get(id) {
    return { fetch: (url, init) => { this.requests++; return this.instance(id.name).fetch(new Request(url, init)); } };
  }
}

export function makeEnv(extra = {}) {
  const clock = { now: Date.parse("2026-11-10T03:00:00Z") };
  // PIN_PEPPER: 시험용 Worker 비밀(SEC1110A03).
  const env = { PLANS: new MemoryKV(), USER_STATE: new FakeDurableObjects(), NOW: () => clock.now, PIN_PEPPER: "test-pepper-0123456789abcdef0123456789", ...extra };
  return { env, clock };
}

// MARK: 여행 공유 방(TSH1114A26). 진짜 `ShareRoom`을 메모리 저장소와 가짜 소켓 위에서 돌린다.

// DO 저장소의 KV API 가운데 방이 쓰는 모양: 여러 키 get/put/delete(128개까지), list의 prefix·start·limit, 알람.
export class RoomStorage extends MemoryStorage {
  async get(key) {
    if (!Array.isArray(key)) return super.get(key);
    if (key.length > 128) throw new Error("get: more than 128 keys");
    await tick();
    return new Map(key.filter((k) => this.map.has(k)).map((k) => [k, structuredClone(this.map.get(k))]));
  }
  async put(key, value) {
    if (typeof key === "string") return super.put(key, value);
    if (Object.keys(key).length > 128) throw new Error("put: more than 128 keys");
    await tick();
    for (const [k, v] of Object.entries(key)) this.map.set(k, structuredClone(v));
  }
  async delete(key) {
    if (!Array.isArray(key)) return super.delete(key);
    if (key.length > 128) throw new Error("delete: more than 128 keys");
    await tick();
    for (const k of key) this.map.delete(k);
  }
  async list({ prefix = "", start, limit } = {}) {
    const all = [...(await super.list({ prefix })).entries()].filter(([k]) => start === undefined || k >= start);
    return new Map(limit === undefined ? all : all.slice(0, limit));
  }
  async getAlarm() { return this.alarm; }
  async deleteAlarm() { this.alarm = null; }
}

export class FakeSocket {
  constructor() { this.sent = []; this.closed = null; this.attachment = null; this.tags = []; }
  send(text) { if (this.closed) throw new Error("closed"); this.sent.push(JSON.parse(text)); }
  close(code, reason) { this.closed ??= { code, reason }; }
  serializeAttachment(value) { this.attachment = structuredClone(value); }
  deserializeAttachment() { return structuredClone(this.attachment); }
  /** 받은 것을 꺼내고 비운다. type을 주면 그 종류만 돌려준다. */
  take(type) { const out = this.sent.filter((m) => !type || m.t === type); this.sent = []; return out; }
}

export class FakeRooms {
  constructor(env) { this.env = env; this.instances = new Map(); this.requests = 0; this.pairs = []; }
  idFromName(name) { return { name, toString: () => name }; }
  instance(name) {
    if (!this.instances.has(name)) {
      const sockets = [];
      const ctx = {
        storage: new RoomStorage(), sockets,
        acceptWebSocket(ws, tags = []) { ws.tags = tags; sockets.push(ws); },
        getWebSockets(tag) { return sockets.filter((ws) => !ws.closed && (!tag || ws.tags.includes(tag))); },
        setWebSocketAutoResponse() {},
      };
      this.instances.set(name, { room: new ShareRoom(ctx, this.env), ctx });
    }
    return this.instances.get(name);
  }
  get(id) {
    return { fetch: (input, init) => { this.requests++; return this.instance(id.name).room.fetch(input instanceof Request ? input : new Request(input, init)); } };
  }
}

/** 방 DO와 가짜 소켓 짝을 더한 env. Node의 Response는 101을 만들지 못해 200과 표시 헤더로 대신한다. */
export function makeShareEnv(extra = {}) {
  const made = makeEnv(extra);
  const rooms = new FakeRooms(made.env);
  made.env.SHARE_ROOM = rooms;
  made.env.SOCKETS = {
    pair: () => { const pair = [new FakeSocket(), new FakeSocket()]; rooms.pairs.push(pair); return pair; },
    response: () => new Response(null, { status: 200, headers: { "x-test-upgrade": "websocket" } }),
  };
  return { ...made, rooms };
}

// R2PUB1119A01: 공용 R2 버킷 가짜. `get(key, { range, onlyIf })`는 R2처럼 없으면 null, 조건이 맞으면 body 없는 객체, 범위가 틀리면 던진다.
export class MemoryBucket {
  constructor() { this.objects = new Map(); this.reads = 0; this.writes = 0; }
  async put(key, value, { contentType } = {}) {
    this.writes++;
    const bytes = typeof value === "string" ? new TextEncoder().encode(value) : new Uint8Array(value);
    this.objects.set(key, { bytes, contentType, httpEtag: `"${Buffer.from(bytes).toString("base64url").slice(0, 12)}-${bytes.length}"` });
  }
  async delete(key) { this.writes++; this.objects.delete(key); }
  async get(key, { range, onlyIf } = {}) {
    this.reads++;
    const entry = this.objects.get(key);
    if (!entry) return null;
    const base = { key, size: entry.bytes.length, httpEtag: entry.httpEtag };
    const tags = (onlyIf?.get?.("if-none-match") ?? "").split(",").map((tag) => tag.trim());
    if (tags.includes(entry.httpEtag)) return base; // 전제 실패: 본문 없음
    let slice = entry.bytes, applied;
    const header = range?.get?.("range");
    if (header) {
      const match = /^bytes=(\d*)-(\d*)$/.exec(header);
      if (!match || (match[1] === "" && match[2] === "")) throw new Error("invalid range");
      const size = entry.bytes.length;
      const offset = match[1] === "" ? Math.max(0, size - Number(match[2])) : Number(match[1]);
      const end = match[1] === "" || match[2] === "" ? size - 1 : Math.min(Number(match[2]), size - 1);
      if (offset >= size || end < offset) throw new Error("unsatisfiable range");
      slice = entry.bytes.slice(offset, end + 1);
      applied = { offset, length: slice.length };
    }
    return {
      ...base, range: applied, body: new Response(slice).body, text: async () => new TextDecoder().decode(slice),
      writeHttpMetadata(headers) { if (entry.contentType) headers.set("content-type", entry.contentType); },
    };
  }
}
