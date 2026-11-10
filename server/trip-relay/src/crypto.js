// 저장 암호화(SEC1110A01). v1: 연동 키에서 HKDF로 만든 AES-256-GCM 키로 값을 잠갔다.
// v2: 사용자마다 32바이트 DEK로 값을 잠그고, DEK는 키마다 HKDF(키, "wrap")로 감싸 `dek:<해시>`에 둔다.
// 어느 쪽이든 KV 이름을 추가 인증 데이터로 써서 값을 다른 이름으로 옮기면 풀리지 않는다.

const encoder = new TextEncoder();
export const toBase64 = (bytes) => btoa(String.fromCharCode(...bytes));
export const fromBase64 = (text) => Uint8Array.from(atob(text), (c) => c.charCodeAt(0));

export async function sha256Hex(text) {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function hkdfKey(token, info) {
  const material = await crypto.subtle.importKey("raw", encoder.encode(token), "HKDF", false, ["deriveKey"]);
  return crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: encoder.encode("taption-relay-v1"), info: encoder.encode(info) },
    material, { name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"],
  );
}

export const storageCryptoKey = (token) => hkdfKey(token, "storage");
export const wrapCryptoKey = (token) => hkdfKey(token, "wrap");
export const importDek = (raw) => crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt", "decrypt"]);
// 사용자 DEK. 주인 키에서 HKDF(info "dek")로 한 번 정해지는 32바이트라 서버에 따로 두지 않고,
// 첫 쓰기가 동시에 와도 서로 다른 DEK가 생기지 않는다. 범위 키는 이 값을 감싼 기록으로만 얻는다.
export async function masterDekBytes(token) {
  const material = await crypto.subtle.importKey("raw", encoder.encode(token), "HKDF", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits(
    { name: "HKDF", hash: "SHA-256", salt: encoder.encode("taption-relay-v1"), info: encoder.encode("dek") }, material, 256,
  );
  return new Uint8Array(bits);
}

export async function encryptBytes(cryptoKey, aad, bytes) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = await crypto.subtle.encrypt({ name: "AES-GCM", iv, additionalData: encoder.encode(aad) }, cryptoKey, bytes);
  return { iv: toBase64(iv), ct: toBase64(new Uint8Array(ct)) };
}

// 풀지 못하면 null.
export async function decryptBytes(cryptoKey, aad, envelope) {
  if (typeof envelope?.iv !== "string" || typeof envelope?.ct !== "string") return null;
  try {
    const plain = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: fromBase64(envelope.iv), additionalData: encoder.encode(aad) }, cryptoKey, fromBase64(envelope.ct),
    );
    return new Uint8Array(plain);
  } catch {
    return null;
  }
}

export async function seal(cryptoKey, name, plaintext, version = 1) {
  return JSON.stringify({ v: version, ...(await encryptBytes(cryptoKey, name, encoder.encode(plaintext))) });
}

async function openText(cryptoKey, name, envelope) {
  const bytes = cryptoKey ? await decryptBytes(cryptoKey, name, envelope) : null;
  return bytes ? new TextDecoder().decode(bytes) : null;
}

const isEnvelope = (value, version) => value?.v === version && typeof value.iv === "string" && typeof value.ct === "string";

// v1 봉투만 푼다(기존 시험·도구용). `legacy`는 암호화 전 평문 값이다.
export async function open(cryptoKey, name, stored) {
  let envelope;
  try { envelope = JSON.parse(stored); } catch { return { legacy: false, text: null }; }
  if (!isEnvelope(envelope, 1)) return { legacy: true, text: stored };
  return { legacy: false, text: await openText(cryptoKey, name, envelope) };
}

export function storedVersion(stored) {
  try {
    const envelope = JSON.parse(stored);
    return isEnvelope(envelope, 2) ? 2 : isEnvelope(envelope, 1) ? 1 : 0;
  } catch {
    return -1;
  }
}

// 라우트가 쓰는 KV와 같은 모양의 저장소. 읽을 때 풀고 쓸 때 v2로 잠근다(SEC1110A01).
// keys: { owner: 주인 키인지, legacy(): v1 키 또는 null, dek(): DEK 또는 null, ensureDek(): 없으면 만든다 }
// 예전 값(SEC1110A02): v1은 주인이 읽을 때, 암호화 전 평문은 접두어와 관계없이 누가 읽든 v2로 다시 잠근다(지우지 않음).
// 평문 예외는 LEGACY_PLAINTEXT_UNTIL(2026-11-14 끝)까지만 읽고, 그 뒤에는 없는 것으로 본다.
export const LEGACY_PLAINTEXT_UNTIL = Date.parse("2026-11-15T00:00:00Z");
const DAY_SECONDS = 86400;
const RESEAL_TTL = { plan: 3 * DAY_SECONDS, cmdres: 7 * DAY_SECONDS, cmd: 7 * DAY_SECONDS, act: 7 * DAY_SECONDS, ext: 7 * DAY_SECONDS };
const resealOptions = (name) => {
  const ttl = RESEAL_TTL[name.slice(0, name.indexOf(":"))];
  return ttl ? { expirationTtl: ttl } : undefined;
};

export function vault(kv, keys, now = Date.now()) {
  const store = {
    // reseal: false면 예전 값을 읽기만 한다(이름을 옮기는 이전 작업용).
    async get(name, { reseal = true } = {}) {
      const raw = await kv.get(name);
      if (raw === null || raw === undefined) return null;
      const version = storedVersion(raw);
      if (version === 2) {
        const text = await openText(await keys.dek(), name, JSON.parse(raw));
        if (text === null && keys.owner) await kv.delete(name); // 변조된 값
        return text;
      }
      if (version === 1) {
        // 범위 키는 v1 값을 풀 수 없다. 주인 값이므로 지우지 않고 없는 것으로 본다.
        if (!keys.owner) return null;
        const text = await openText(await keys.legacy(), name, JSON.parse(raw));
        if (text === null) { await kv.delete(name); return null; }
        if (reseal) await store.put(name, text, resealOptions(name));
        return text;
      }
      if (version === 0 && now < LEGACY_PLAINTEXT_UNTIL) {
        if (reseal) await store.put(name, raw, resealOptions(name));
        return raw;
      }
      return null;
    },
    async put(name, value, options) { await kv.put(name, await seal(await keys.ensureDek(), name, value, 2), options); },
    delete: (name) => kv.delete(name),
    list: (options) => kv.list(options),
    raw: (name) => kv.get(name),
  };
  return store;
}

// MARK: phase 3 helpers (SEC1110A02 · AIR1110A03)

export const toBase64Url = (bytes) => toBase64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
export const randomToken = (bytes = 32) => toBase64Url(crypto.getRandomValues(new Uint8Array(bytes)));
export const randomHex = (bytes = 32) => [...crypto.getRandomValues(new Uint8Array(bytes))].map((b) => b.toString(16).padStart(2, "0")).join("");

// 길이가 같을 때 모든 바이트를 본다(SEC1110A02).
export function sameBytes(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}
export const sameText = (a, b) => typeof a === "string" && typeof b === "string" && sameBytes(encoder.encode(a), encoder.encode(b));

// JSON 값을 AES-GCM으로 잠근 봉투 글자. 풀지 못하면 null.
export async function sealJson(cryptoKey, aad, value, version = 3) {
  return JSON.stringify({ v: version, ...(await encryptBytes(cryptoKey, aad, encoder.encode(JSON.stringify(value)))) });
}
export async function openJson(cryptoKey, aad, envelope) {
  const bytes = await decryptBytes(cryptoKey, aad, typeof envelope === "string" ? safeParse(envelope) : envelope);
  if (!bytes) return null;
  return safeParse(new TextDecoder().decode(bytes));
}
function safeParse(text) {
  try { return JSON.parse(text); } catch { return null; }
}

// DEK에서 이름 가리개 키를 만든다. 날짜·명령 id를 HMAC으로 바꿔 KV·DO 이름에 날짜가 보이지 않게 한다(SEC1110A02).
export async function nameKey(dekBytes) {
  const material = await crypto.subtle.importKey("raw", dekBytes, "HKDF", false, ["deriveKey"]);
  return crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: encoder.encode("taption-relay-v3"), info: encoder.encode("names") },
    material, { name: "HMAC", hash: "SHA-256", length: 256 }, false, ["sign"],
  );
}
export async function tagOf(hmacKey, text) {
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", hmacKey, encoder.encode(text)));
  return [...mac.slice(0, 16)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// PIN 검증값(SEC1110A03): HMAC-SHA256(key = Worker 비밀 PIN_PEPPER, msg = salt 16바이트 || PIN UTF-8).
// PBKDF2는 Workers 운영 환경의 반복 수 상한·무료 CPU 10ms에 걸려 쓰지 않는다(대표 결정).
export async function pinMac(pepper, salt, pin) {
  const key = await crypto.subtle.importKey("raw", encoder.encode(pepper), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const pinBytes = encoder.encode(pin);
  const message = new Uint8Array(salt.length + pinBytes.length);
  message.set(salt);
  message.set(pinBytes, salt.length);
  return new Uint8Array(await crypto.subtle.sign("HMAC", key, message));
}

export async function sha256Base64Url(text) {
  return toBase64Url(new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(text))));
}

// 비밀 글자에서 새 토큰을 정한다(HKDF). 같은 입력이면 같은 토큰이라, 다시 온 요청에 같은 값을 돌려줄 수 있다(N8).
export async function deriveToken(secret, salt, info, bytes = 48) {
  const material = await crypto.subtle.importKey("raw", encoder.encode(secret), "HKDF", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt: encoder.encode(salt), info: encoder.encode(info) }, material, bytes * 8);
  return toBase64Url(new Uint8Array(bits));
}

// 서버 비밀과 짧은 코드로 AES 키를 만든다(N15). 코드만으로는 풀 수 없다.
export async function pepperedKey(pepper, text) {
  const key = await crypto.subtle.importKey("raw", encoder.encode(pepper), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return importDek(new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(text))));
}
