// HTTP helpers shared by every route.

export const MAX_BODY_BYTES = 64 * 1024;
export const KEY_PATTERN = /^[A-Za-z0-9_-]{43}$/; // 32 random bytes, base64url without padding
// OAuth 토큰은 48바이트(64자)라 주인·연결 키로 등록될 수 없다(AIR1110A03).
export const OAUTH_TOKEN_PATTERN = /^[A-Za-z0-9_-]{64}$/;

export function json(body, status, headers = {}) {
  return new Response(body === null ? null : JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...headers },
  });
}

export function stored(text) {
  return new Response(text, { status: 200, headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" } });
}

export function bearer(request) {
  const match = /^Bearer (.+)$/.exec(request.headers.get("authorization") ?? "");
  return match && (KEY_PATTERN.test(match[1]) || OAUTH_TOKEN_PATTERN.test(match[1])) ? match[1] : null;
}

// 모든 429는 Retry-After 헤더와 본문 retryAfter(초)를 준다(SEC1110A03).
export const tooMany = (error = "rate_limited", retryAfter = 60, extra = {}) =>
  json({ error, retryAfter, ...extra }, 429, { "retry-after": String(retryAfter) });

// IPv6는 앞 /64로 묶는다(N12). 한 사람이 받는 /64 안의 주소를 바꿔 가며 한도를 피하지 못한다.
export function ipv6Prefix(ip) {
  if (ip.includes(".")) return ip.slice(ip.lastIndexOf(":") + 1); // ::ffff:1.2.3.4
  const [head, tail] = ip.toLowerCase().split("%")[0].split("::");
  const left = head ? head.split(":") : [];
  const right = tail ? tail.split(":") : [];
  const zeros = tail === undefined ? [] : Array(Math.max(0, 8 - left.length - right.length)).fill("0");
  const groups = [...left, ...zeros, ...right].slice(0, 4).map((g) => g.replace(/^0+(?=.)/, ""));
  return groups.join(":") + "::/64";
}

export function clientIp(request) {
  const ip = (request.headers.get("cf-connecting-ip") ?? "unknown").trim();
  return ip.includes(":") ? ipv6Prefix(ip) : ip;
}

// Cloudflare 속도 제한 바인딩. 없으면(시험·로컬) 통과.
export async function limited(binding, request) {
  if (!binding) return false;
  const { success } = await binding.limit({ key: clientIp(request) });
  return !success;
}

// 보낸 사람 IP마다 쓰기를 제한한다. 한 사람이 무료 KV 하루 쓰기 한도를 다 쓰지 못하게 한다.
export async function writeAllowed(request, env) {
  return !(await limited(env.POST_LIMIT, request));
}

// 본문을 스트림으로 읽어 64KB를 넘는 순간 멈춘다(SEC1110A02). chunked 본문도 다 받아 두지 않는다.
export async function readText(request, max = MAX_BODY_BYTES) {
  const length = Number(request.headers.get("content-length") ?? 0);
  if (length > max) return { error: json({ error: "too_large" }, 413) };
  if (!request.body) return { value: "" };
  const reader = request.body.getReader();
  const chunks = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > max) {
      await reader.cancel().catch(() => {});
      return { error: json({ error: "too_large" }, 413) };
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return { value: new TextDecoder().decode(bytes) };
}

// 64KB를 넘지 않는 JSON 본문을 읽는다. 실패하면 돌려줄 응답을 준다.
export async function readBody(request, { allowEmpty = false } = {}) {
  const text = await readText(request);
  if (text.error) return text;
  if (allowEmpty && !text.value.trim()) return { value: {} };
  try { return { value: JSON.parse(text.value) }; } catch { return { error: json({ error: "invalid_json" }, 400) }; }
}

const ESCAPES = { "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;" };
export const escapeHtml = (text) => String(text ?? "").replace(/[&<>"']/g, (c) => ESCAPES[c]);
