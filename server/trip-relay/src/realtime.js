// RTA1120A02: 앱 전면 실시간 반영. 주인마다 방 하나(Durable Object, SQLite, Hibernation)에 앱이 소켓으로 붙고,
// AI가 쓴 것이 성공하면 서버가 가벼운 알림(`cmd`·`patch`)만 민다. 본문은 앱이 기존 HTTP(`GET /command`·`GET /plan`…)로 가져간다.
// - 이벤트에 본문·금액·좌표·이름을 싣지 않는다. 기기 ID를 만들거나 저장하지 않는다(방 이름이 이미 주인 키의 해시다).
// - 표준 WebSocket API·타이머·알람을 쓰지 않는다: 하트비트는 `ping`→`pong` 자동 응답(DO를 깨우지 않음)이고, 놓친 이벤트는 앱이 `since`로 따라잡는다.
// - 발행은 편의다. 실패는 삼키고 응답을 늦추지 않으며(`ctx.defer`), 놓친 것은 앱의 폴링이 따라잡는다.
import { json } from "./http.js";

export const REALTIME = { keep: 200, page: 50, sockets: 5, messageBytes: 256 };
export const CLOSE = { replaced: 4408 };
const ENTITIES = new Set(["plan", "day", "memo", "app", "tasks", "rules"]);
const TYPES = new Set(["cmd", "patch"]);
const SAFE_ID = /^[A-Za-z0-9._:-]{1,64}$/;
const KIND = /^[A-Za-z0-9_]{1,40}$/;
const pad = (n) => String(n).padStart(10, "0");

export class RealtimeRoom {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.storage = ctx.storage;
    this.env = env ?? {};
    this.chain = Promise.resolve();
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
    if (request.method === "POST" && url.pathname === "/event") return this.serial(() => this.publish(request));
    if (request.method === "GET" && url.pathname !== "/event" && (request.headers.get("upgrade") ?? "").toLowerCase() === "websocket") return this.connect(request, url);
    return json({ error: "not_found" }, 404);
  }

  send(ws, message) {
    try { ws.send(JSON.stringify(message)); } catch { /* 이미 닫힌 연결 */ }
  }

  async bounds() {
    const latest = (await this.storage.get("latest")) ?? 0;
    const first = await this.storage.list({ prefix: "e:", limit: 1 });
    const oldest = first.size ? [...first.values()][0].e : latest + 1;
    return { latest, oldest };
  }

  async publish(request) {
    let event;
    try { event = await request.json(); } catch { return json({ error: "bad_event" }, 400); }
    if (!TYPES.has(event?.type) || (event.entity !== undefined && !ENTITIES.has(event.entity))) return json({ error: "bad_event" }, 400);
    if ((event.id !== undefined && !SAFE_ID.test(String(event.id))) || (event.kind !== undefined && !KIND.test(String(event.kind)))) return json({ error: "bad_event" }, 400);
    const latest = ((await this.storage.get("latest")) ?? 0) + 1;
    const record = { e: latest, type: event.type, at: this.now() };
    if (event.id !== undefined) record.id = String(event.id);
    if (event.kind !== undefined) record.kind = String(event.kind);
    if (event.entity !== undefined) record.entity = event.entity;
    await this.storage.put({ latest, ["e:" + pad(latest)]: record });
    // 오래된 것부터 지운다(지우기도 행 쓰기로 센다).
    if (latest > REALTIME.keep) await this.storage.delete("e:" + pad(latest - REALTIME.keep));
    for (const ws of this.ctx.getWebSockets()) this.send(ws, record);
    return json({ ok: true, e: latest }, 201);
  }

  async connect(request, url) {
    const now = this.now();
    // 한 주인의 방에는 기기 다섯 대까지. 넘으면 가장 오래된 연결부터 닫는다.
    const open = this.ctx.getWebSockets().sort((a, b) => (a.deserializeAttachment()?.at ?? 0) - (b.deserializeAttachment()?.at ?? 0));
    for (const old of open.slice(0, Math.max(0, open.length - REALTIME.sockets + 1))) {
      this.send(old, { type: "bye", reason: "replaced" });
      try { old.close(CLOSE.replaced, "replaced"); } catch { /* 이미 닫힘 */ }
    }
    const [client, server] = this.env.SOCKETS?.pair() ?? Object.values(new WebSocketPair());
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment({ at: now });
    const { latest, oldest } = await this.bounds();
    this.send(server, { type: "hello", latest, oldest, now });
    const raw = url.searchParams.get("since");
    if (raw !== null) await this.catchUp(server, Number(raw), { latest, oldest });
    else this.send(server, { type: "ready", latest });
    return this.env.SOCKETS?.response(client) ?? new Response(null, { status: 101, webSocket: client });
  }

  /** `since` 다음 이벤트를 50건씩 id 순으로 보낸다. 저장소가 비었거나 커서가 너무 낡았으면 `resync`만. */
  async catchUp(ws, since, bounds) {
    const { latest, oldest } = bounds;
    if (!Number.isInteger(since) || since < 0 || since > latest || (latest > 0 && since < oldest - 1)) { this.send(ws, { type: "resync" }); return; }
    let cursor = since;
    for (;;) {
      const page = await this.storage.list({ prefix: "e:", start: "e:" + pad(cursor + 1), limit: REALTIME.page + 1 });
      const items = [...page.values()].slice(0, REALTIME.page);
      const more = page.size > REALTIME.page;
      if (items.length) this.send(ws, { type: "events", items, more });
      if (!more) break;
      cursor = items.at(-1).e;
    }
    this.send(ws, { type: "ready", latest });
  }

  async webSocketMessage(ws, message) {
    // 글자 한 가지 op(`since`)만 받는다. 그 밖은 오류 응답 없이 조용히 무시한다(응답 고리 방지).
    if (typeof message !== "string" || message.length > REALTIME.messageBytes) return;
    let body;
    try { body = JSON.parse(message); } catch { return; }
    if (body?.op !== "since" || !Number.isInteger(body.since)) return;
    const bounds = await this.serial(() => this.bounds());
    await this.catchUp(ws, body.since, bounds);
  }

  async webSocketClose(ws, code) {
    try { ws.close(code === 1005 || code === 1006 ? 1000 : code, "bye"); } catch { /* 이미 닫힘 */ }
  }

  webSocketError(ws) {
    return this.webSocketClose(ws, 1011);
  }
}

// MARK: Worker 쪽

const roomStub = (env, master) => env.REALTIME_ROOM.get(env.REALTIME_ROOM.idFromName("owner:" + master));

/** GET /rt/ws — 앱(주인 키)만. 인증은 index.js의 기존 문을 그대로 지난다. */
export async function realtimeRoute(request, ctx) {
  if ((request.headers.get("upgrade") ?? "").toLowerCase() !== "websocket") return json({ error: "upgrade_required" }, 426);
  if (!ctx.env.REALTIME_ROOM) return json({ error: "unavailable" }, 503);
  return roomStub(ctx.env, ctx.master).fetch(request);
}

/** AI가 쓴 것이 성공한 직후에 부른다. 주인 키(앱)가 쓴 것은 발행하지 않는다. 바인딩이 없거나 실패해도 조용하다. */
export function publish(ctx, event) {
  if (ctx.auth?.kind === "master" || !ctx.env?.REALTIME_ROOM || !ctx.master) return;
  let work;
  try {
    work = Promise.resolve(roomStub(ctx.env, ctx.master).fetch("https://realtime/event", { method: "POST", body: JSON.stringify(event) })).catch(() => {});
  } catch { return; }
  if (ctx.defer) ctx.defer(work);
}
