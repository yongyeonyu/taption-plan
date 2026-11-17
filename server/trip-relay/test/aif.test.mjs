// AIF1118A01: REV1117A02에서 미룬 서버 결함.
import assert from "node:assert/strict";
import test from "node:test";
import { fromBase64, toBase64 } from "../src/crypto.js";

test("AIF1118A01: toBase64 handles large values without overflowing the call stack", () => {
  const bytes = new Uint8Array(1_000_000);
  for (let i = 0; i < bytes.length; i += 1) bytes[i] = (i * 31) & 0xff;
  const text = toBase64(bytes);
  assert.equal(text, Buffer.from(bytes).toString("base64"));
  assert.deepEqual(fromBase64(text), bytes);
  assert.equal(toBase64(new Uint8Array()), "");
});
