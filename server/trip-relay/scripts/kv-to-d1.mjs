// D1R1119A02: 옛 KV(PLANS)에 남은 키를 한꺼번에 D1(kv_entries)로 복사한다. KV 바인딩을 떼기 전에 한 번 돌린다.
//
//   node scripts/kv-to-d1.mjs --config wrangler.local.toml --out /tmp/kv-to-d1.sql          # SQL만 만든다(읽기만)
//   node scripts/kv-to-d1.mjs --config wrangler.local.toml --out /tmp/kv-to-d1.sql --apply  # D1에도 적용한다
//
// - KV는 읽기만 한다(쓰기·삭제 없음). D1에는 `INSERT OR IGNORE`라서 이미 옮겨졌거나 D1에서 새로 쓴 값·삭제 표식을 덮지 않는다.
// - 이미 만료된 키는 건너뛰고, 남은 만료는 expires_at(ms)으로 그대로 옮긴다.
// - 값은 앱 코드가 이미 AES-GCM으로 잠근 문자열이다. 이 스크립트는 값을 출력하지 않는다(건수만).
import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";

const args = process.argv.slice(2);
const opt = (name, fallback) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : fallback; };
const config = opt("--config", "wrangler.local.toml");
const out = opt("--out", "kv-to-d1.sql");
const apply = args.includes("--apply");

const wrangler = (...rest) => execFileSync("npx", ["--no-install", "wrangler", ...rest, "--config", config], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
const sqlString = (text) => "'" + text.replaceAll("'", "''") + "'";

const keys = JSON.parse(wrangler("kv", "key", "list", "--binding", "PLANS", "--remote"));
const now = Date.now();
const rows = [];
let expired = 0;
for (const entry of keys) {
  if (entry.expiration && entry.expiration * 1000 <= now) { expired++; continue; }
  const value = wrangler("kv", "key", "get", entry.name, "--binding", "PLANS", "--remote", "--text");
  rows.push(`INSERT OR IGNORE INTO kv_entries(key,value,expires_at) VALUES(${sqlString(entry.name)},${sqlString(value)},${entry.expiration ? entry.expiration * 1000 : "NULL"});`);
}
writeFileSync(out, rows.join("\n") + "\n");
console.log(`KV 키 ${keys.length}개 중 복사 대상 ${rows.length}개, 이미 만료 ${expired}개. SQL: ${out}`);

if (apply && rows.length) {
  wrangler("d1", "execute", "taption-trip-relay", "--remote", "--yes", "--file", out);
  console.log("D1에 적용했습니다(INSERT OR IGNORE).");
}
