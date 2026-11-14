// 여행 공유 규약(docs/TRIP_SHARE_PROTOCOL.md)의 기기 쪽 참고 구현(TSH1114A26). 서버는 이 계산을 하지 않는다.
// 앱(CryptoKit·CommonCrypto)이 같은 입력에서 같은 값을 내는지 `fixtures/share-vectors.json`으로 견준다.
const encoder = new TextEncoder();
export const PREFIX = "taption-share-v1";
export const PBKDF2_ITERATIONS = 600_000;
export const hex = (bytes) => Buffer.from(bytes).toString("hex");
export const base64url = (bytes) => Buffer.from(bytes).toString("base64url");
const bits = async (promise) => new Uint8Array(await promise);

/** 링크 비밀 값(32바이트)과 비밀번호에서 뿌리 키 → 암호화 키·입장 증명 키 → 입장 증명. */
export async function deriveKeys(roomId, linkSecret, password) {
  const salt = Buffer.concat([encoder.encode(`${PREFIX}|${roomId}|`), linkSecret]);
  const passwordKey = await crypto.subtle.importKey("raw", encoder.encode(password.normalize("NFC")), "PBKDF2", false, ["deriveBits"]);
  const root = await bits(crypto.subtle.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt, iterations: PBKDF2_ITERATIONS }, passwordKey, 256));
  const material = await crypto.subtle.importKey("raw", root, "HKDF", false, ["deriveBits"]);
  const expand = (info) => bits(crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt: encoder.encode(PREFIX), info: encoder.encode(info) }, material, 256));
  const encKey = await expand("enc");
  const authKey = await expand("auth");
  const macKey = await crypto.subtle.importKey("raw", authKey, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const proof = await bits(crypto.subtle.sign("HMAC", macKey, encoder.encode("join|" + roomId)));
  return { root, encKey, authKey, proof: base64url(proof) };
}

export const aadOf = (roomId, itemId, kind, epoch) => `${PREFIX}|${roomId}|${itemId}|${kind}|${epoch}`;

/** cipher = base64url(0x01 || nonce 12 || AES-256-GCM 암호문 || tag 16). */
export async function sealItem(encKey, { roomId, itemId, kind, epoch }, plaintext, nonce = crypto.getRandomValues(new Uint8Array(12))) {
  const key = await crypto.subtle.importKey("raw", encKey, "AES-GCM", false, ["encrypt"]);
  const sealed = await bits(crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce, additionalData: encoder.encode(aadOf(roomId, itemId, kind, epoch)) }, key, encoder.encode(plaintext)));
  return base64url(Buffer.concat([Buffer.from([1]), nonce, sealed]));
}

/** 풀지 못하면(키·방·항목·종류·세대가 다르면) null. */
export async function openItem(encKey, { roomId, itemId, kind, epoch }, cipher) {
  const raw = Buffer.from(cipher, "base64url");
  if (raw[0] !== 1) return null;
  const key = await crypto.subtle.importKey("raw", encKey, "AES-GCM", false, ["decrypt"]);
  try {
    return new TextDecoder().decode(await crypto.subtle.decrypt({ name: "AES-GCM", iv: raw.subarray(1, 13), additionalData: encoder.encode(aadOf(roomId, itemId, kind, epoch)) }, key, raw.subarray(13)));
  } catch {
    return null;
  }
}

/** 시험 벡터 하나를 입력에서 다시 계산한다. */
export async function computeVector(input) {
  const linkSecret = Buffer.from(input.linkSecretHex, "hex");
  const keys = await deriveKeys(input.roomId, linkSecret, input.password);
  const cipher = await sealItem(keys.encKey, input, input.plaintext, Buffer.from(input.nonceHex, "hex"));
  return {
    passwordUtf8Hex: hex(encoder.encode(input.password.normalize("NFC"))),
    saltHex: hex(Buffer.concat([encoder.encode(`${PREFIX}|${input.roomId}|`), linkSecret])),
    rootHex: hex(keys.root), encKeyHex: hex(keys.encKey), authKeyHex: hex(keys.authKey), proof: keys.proof,
    aad: aadOf(input.roomId, input.itemId, input.kind, input.epoch), cipher,
  };
}
