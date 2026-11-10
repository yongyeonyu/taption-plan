// 1회용 연결 코드(SET1110A01). 앱이 연결 안내(키 포함)를 맡기면 짧은 주소 `/s/<코드>`를 돌려준다.
// AI가 그 주소를 열면 안내를 글로 내준다. 클립보드·메시지에는 키 대신 주소만 남는다.
// 서버는 코드에서 만든 키로 잠가 두고 코드는 해시로만 이름 짓는다. 10분 뒤 또는 세 번 열면 사라진다
// (채팅 앱의 링크 미리보기가 먼저 열어도 AI가 읽을 수 있게 세 번까지).
import { decryptBytes, encryptBytes, setupCryptoKey, sha256Hex } from "./crypto.js";
import { json, readBody, tooMany } from "./http.js";
import { chargeWrites } from "./state.js";

export const SETUP_TTL_SECONDS = 600;
export const SETUP_READS = 3;
export const SETUP_TEXT_LIMIT = 8000;
export const SETUP_PER_DAY = 30;
const ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // 헷갈리는 0·O·1·I 뺌. 32자 × 10자리 = 50비트.
export const SETUP_CODE = /^[A-HJ-NP-Z2-9]{10}$/;
const encoder = new TextEncoder();

const nameOf = async (code) => "setup:" + (await sha256Hex("setup|" + code));

function newCode() {
  const bytes = crypto.getRandomValues(new Uint8Array(10));
  return [...bytes].map((b) => ALPHABET[b & 31]).join("");
}

// POST /setup (주인) {"text"}: 맡기고 주소를 받는다.
export async function createSetup(request, ctx) {
  const body = await readBody(request);
  if (body.error) return body.error;
  const text = body.value?.text;
  if (typeof text !== "string" || !text.trim() || [...text].length > SETUP_TEXT_LIMIT) return json({ error: "not_setup" }, 422);
  const daily = await ctx.state.call("countDaily", { name: "setup", limit: SETUP_PER_DAY, now: ctx.now });
  if (!daily.ok) return tooMany("daily_setup_limit", daily.retryAfter);
  const charge = await chargeWrites(ctx.env, ctx.state, 1, ctx.now);
  if (!charge.ok) return tooMany(charge.error, charge.retryAfter);
  const code = newCode();
  const name = await nameOf(code);
  const expiresAt = Math.floor(ctx.now / 1000) + SETUP_TTL_SECONDS;
  const sealed = await encryptBytes(await setupCryptoKey(code), name, encoder.encode(JSON.stringify({ text, reads: 0, expiresAt })));
  await ctx.kv.put(name, JSON.stringify(sealed), { expiration: expiresAt });
  const url = new URL(request.url);
  return json({ ok: true, code, url: `${url.origin}/s/${code}`, expiresInSeconds: SETUP_TTL_SECONDS }, 201);
}

// GET /s/<코드> (공개): 안내 글. 없거나 끝났으면 404.
export async function readSetup(env, rawCode, now) {
  const code = rawCode.toUpperCase();
  const gone = () => new Response("This BOKKI Plan setup link has expired or was already used. Ask the user to make a new one in the app.\n", {
    status: 404, headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" },
  });
  if (!SETUP_CODE.test(code)) return gone();
  const name = await nameOf(code);
  const stored = await env.PLANS.get(name);
  if (!stored) return gone();
  let envelope;
  try { envelope = JSON.parse(stored); } catch { return gone(); }
  const key = await setupCryptoKey(code);
  const bytes = await decryptBytes(key, name, envelope);
  if (!bytes) return gone();
  const value = JSON.parse(new TextDecoder().decode(bytes));
  // KV 만료는 늦게 반영될 수 있어 저장한 만료 시각을 다시 본다.
  if (!(value.expiresAt > Math.floor(now / 1000))) return gone();
  const reads = (value.reads ?? 0) + 1;
  const charge = await chargeWrites(env, null, 1, now);
  if (!charge.ok) return tooMany(charge.error, charge.retryAfter);
  if (reads >= SETUP_READS) {
    await env.PLANS.delete(name);
  } else {
    const resealed = await encryptBytes(key, name, encoder.encode(JSON.stringify({ ...value, reads })));
    // 남은 시간은 그대로: 처음 만든 때부터 10분.
    await env.PLANS.put(name, JSON.stringify(resealed), { expiration: value.expiresAt });
  }
  return new Response(value.text, {
    status: 200,
    headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store", "x-robots-tag": "noindex, nofollow", "referrer-policy": "no-referrer" },
  });
}
