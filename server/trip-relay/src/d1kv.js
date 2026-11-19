// D1R1119A01: Cloudflare KV(`env.PLANS`) 호환 어댑터. 호출부(`get/put/delete/list`)는 그대로 두고 저장소만 D1로 바꾼다.
//
// 무중단 전환(Dual-Read, Lazy Migration)
// - 쓰기·삭제는 D1에만 한다. 옛 KV에는 쓰지 않는다(KV 쓰기 0건).
// - 읽기는 D1 먼저, 없으면 옛 KV에서 읽어 D1으로 복사(남은 TTL 유지)한 뒤 돌려준다.
// - 옛 KV 바인딩(`legacy`)이 없으면 D1만 쓴다.
//
// 삭제 표식(tombstone) 결정
// - 옛 KV에 같은 키가 남아 있으면 읽기가 그것을 되살린다. 옛 KV를 지울 수는 없으므로(쓰기 0건 조건),
//   그 경우에만 D1에 `TOMBSTONE` 값의 행을 둔다. get·list는 이 행을 「없음」으로 보고 옛 KV를 보지 않는다.
// - 표식의 만료는 옛 KV 항목의 만료와 같게 한다(옛 항목이 사라지면 표식도 필요 없다). 옛 항목에 만료가 없으면 표식도 영구.
// - 옛 KV에 없는 키는 표식 없이 그냥 지운다(이관이 끝나면 표식은 더 생기지 않는다).
// - 같은 이유로, 덮어쓴 값이 옛 KV보다 먼저 만료될 때도(옛 값 부활 방지) 만료 행을 표식으로 바꾼다.
//
// list 합치기(한계)
// - 옛 KV 키는 접두어 아래를 끝까지 읽어(옛 KV list 읽기) D1 목록과 합친다. 합친 정렬 순서에서
//   「마지막으로 준 이름」을 cursor로 쓰는 키셋 페이지네이션이다(옛 KV·D1 cursor를 섞지 않는다).
// - D1은 한 번에 limit+1행만 읽고, 그 범위(마지막 행 이름까지)에 든 옛 이름만 합친다. 범위 밖은 다음 페이지에 온다.
// - 옛 KV에 접두어 아래 키가 많으면 호출마다 읽기가 늘어난다. 이 서버의 list 사용처(접두어당 소수)에서는 문제없고,
//   이관이 끝나 옛 KV 바인딩을 떼면 이 비용은 사라진다.
// - `metadata`는 호출부가 쓰지 않아 지원하지 않는다.

export const TOMBSTONE = "\u0001d1kv-deleted\u0001"; // NUL은 SQLite 문자열을 자르므로 쓰지 않는다
const MAX_LIMIT = 1000;

const chunks = (items, size = 80) => Array.from({ length: Math.ceil(items.length / size) }, (_, i) => items.slice(i * size, (i + 1) * size)); // D1 바인딩 인자 한도(100) 아래
const marks = (n) => Array(n).fill("?").join(",");
const isExpired = (row, t) => row.expires_at !== null && row.expires_at !== undefined && row.expires_at <= t;

export function d1kv(db, legacy, { now = () => Date.now() } = {}) {
  const run = (sql, ...args) => db.prepare(sql).bind(...args).run();
  const first = (sql, ...args) => db.prepare(sql).bind(...args).first();
  const all = async (sql, ...args) => (await db.prepare(sql).bind(...args).all()).results ?? [];
  const upsert = (key, value, expiresAt) => run(
    "INSERT INTO kv_entries(key,value,expires_at) VALUES(?,?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value, expires_at=excluded.expires_at",
    key, value, expiresAt);

  // 옛 KV의 한 키의 만료(초). list는 접두어 일치 중 이름순 첫 항목을 주므로, 이름이 같으면 그 키다.
  async function legacyEntry(key) {
    if (!legacy) return null;
    const { keys } = await legacy.list({ prefix: key, limit: 1 });
    const hit = keys?.[0];
    return hit && hit.name === key ? { expiration: hit.expiration ?? null } : null;
  }

  // 옛 KV에 같은 키가 살아 있으면 표식으로, 없으면 행을 지운다.
  async function shadowOrDelete(key) {
    const old = await legacyEntry(key);
    if (old && (old.expiration === null || old.expiration * 1000 > now())) await upsert(key, TOMBSTONE, old.expiration ? old.expiration * 1000 : null);
    else await run("DELETE FROM kv_entries WHERE key=?", key);
  }

  const parse = (text, options) => ((typeof options === "string" ? options : options?.type) === "json" ? JSON.parse(text) : text);

  return {
    async get(key, options) {
      const row = await first("SELECT value, expires_at FROM kv_entries WHERE key=?", key);
      if (row) {
        if (isExpired(row, now())) {
          if (row.value === TOMBSTONE) await run("DELETE FROM kv_entries WHERE key=? AND expires_at<=?", key, now());
          else await shadowOrDelete(key);
          return null;
        }
        return row.value === TOMBSTONE ? null : parse(row.value, options);
      }
      if (!legacy) return null;
      const text = await legacy.get(key);
      if (text === null || text === undefined) return null;
      const old = await legacyEntry(key);
      const expiresAt = old?.expiration ? old.expiration * 1000 : null;
      if (expiresAt !== null && expiresAt <= now()) return null;
      // 그 사이 새로 쓴 값을 덮어쓰지 않는다.
      await run("INSERT OR IGNORE INTO kv_entries(key,value,expires_at) VALUES(?,?,?)", key, text, expiresAt);
      return parse(text, options);
    },

    async put(key, value, options = {}) {
      let expiresAt = null;
      if (options.expirationTtl !== undefined) expiresAt = now() + Number(options.expirationTtl) * 1000;
      else if (options.expiration !== undefined) expiresAt = Number(options.expiration) * 1000;
      await upsert(key, String(value), expiresAt);
    },

    async delete(key) { await shadowOrDelete(key); },

    // 반환: { keys: [{ name, expiration(초, 만료 없으면 생략) }], list_complete, cursor? }
    async list({ prefix = "", limit = MAX_LIMIT, cursor } = {}) {
      const page = Math.max(1, Math.min(Number(limit) || MAX_LIMIT, MAX_LIMIT));
      const t = now();
      const after = cursor ? String(cursor) : null; // 직전 페이지의 마지막 이름보다 큰 이름만.
      const rows = await all(
        `SELECT key, value, expires_at FROM kv_entries WHERE key>=? AND key<? ${after === null ? "" : "AND key>?"} ORDER BY key LIMIT ?`,
        prefix, prefix + "￿", ...(after === null ? [] : [after]), page + 1);
      const exhausted = rows.length <= page; // D1에 더 없다.
      const bound = exhausted ? null : rows[rows.length - 1].key; // 아니면 이 이름까지만 D1을 다 본 것.

      const merged = new Map(); // 이름 → expiration(초)
      const expiredRows = [];
      for (const r of rows) {
        if (isExpired(r, t)) expiredRows.push(r.key);
        else if (r.value !== TOMBSTONE) merged.set(r.key, r.expires_at === null ? undefined : Math.floor(r.expires_at / 1000));
      }
      const known = new Set(rows.map((r) => r.key)); // 표식·만료 행도 옛 KV를 가린다.
      const legacyAll = new Set(); // 옛 KV에 살아 있는 이름(만료 행 정리에 쓴다)
      if (legacy) {
        let c;
        do {
          const p = await legacy.list({ prefix, cursor: c });
          for (const k of p.keys ?? []) {
            if (!(k.expiration && k.expiration * 1000 <= t)) legacyAll.add(k.name);
            if ((after !== null && k.name <= after) || (bound !== null && k.name > bound) || known.has(k.name)) continue;
            if (k.expiration && k.expiration * 1000 <= t) continue;
            merged.set(k.name, k.expiration);
          }
          c = p.list_complete ? undefined : p.cursor;
        } while (c);
      }
      // 만료 행 정리. 옛 KV가 같은 이름을 살려 두고 있으면 지우지 않는다(get이 표식으로 바꾼다).
      const stale = expiredRows.filter((k) => !legacyAll.has(k));
      for (const part of chunks(stale)) await run(`DELETE FROM kv_entries WHERE key IN (${marks(part.length)}) AND expires_at<=?`, ...part, t);

      const names = [...merged.keys()].sort();
      const served = names.slice(0, page);
      const more = names.length > page || !exhausted;
      const next = names.length > page ? served[served.length - 1] : bound;
      return {
        keys: served.map((name) => (merged.get(name) === undefined ? { name } : { name, expiration: merged.get(name) })),
        list_complete: !more,
        ...(more ? { cursor: next } : {}),
      };
    },
  };
}

// 환경에 D1 바인딩(RELAY_DB)이 있으면 `PLANS`를 어댑터로 바꾼 사본을 돌려준다. 없으면 그대로(옛 KV로 동작).
export function withD1(env) {
  if (!env?.RELAY_DB) return env;
  return { ...env, PLANS: d1kv(env.RELAY_DB, env.PLANS, { now: () => env.NOW?.() ?? Date.now() }) };
}
