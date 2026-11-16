// LOC1116S01: 기기(Swift)가 잠근 위치 암호문을 Node WebCrypto로 풀어 규약 21.1의 AAD·형식이 어긋나지 않음을 본다.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { openItem } from "./share-client.mjs";

test("share loc vector: a ciphertext sealed by the Swift package opens with the protocol's AAD", async () => {
  const v = JSON.parse(readFileSync(new URL("./fixtures/share-loc-vector.json", import.meta.url)));
  const plain = await openItem(Buffer.from(v.encKeyHex, "hex"), { roomId: v.roomId, itemId: `loc-${v.member}`, kind: "loc", epoch: v.epoch }, v.cipher);
  assert.deepEqual(JSON.parse(plain), v.payload);
  assert.equal(plain.length % 64, 0, "64바이트 배수 패딩");
  assert.equal(Buffer.from(v.cipher, "base64url").length <= 512, true);
  // 다른 참여자 자리로 옮기면 풀리지 않는다.
  assert.equal(await openItem(Buffer.from(v.encKeyHex, "hex"), { roomId: v.roomId, itemId: "loc-3", kind: "loc", epoch: v.epoch }, v.cipher), null);
});
