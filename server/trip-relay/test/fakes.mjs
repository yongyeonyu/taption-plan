// 시험용 KV·Durable Object 가짜(SEC1110A02). DO는 진짜 `UserState`를 메모리 저장소 위에서 돌린다.
import { UserState } from "../src/index.js";

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
