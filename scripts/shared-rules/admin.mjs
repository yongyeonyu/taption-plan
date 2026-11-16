#!/usr/bin/env node
// 공통 규칙 검토·내보내기(SRL1116A01). 대표 Mac에서만 쓴다. 설계: docs/SHARED_RULES_PLAN.md
// 서명 개인 키는 ~/.bokki-shared-rules/signing.pem, 서버 주소·관리 토큰은 같은 폴더의 admin.json({host, token})에만 둔다. 저장소에 넣지 않는다.
//   node admin.mjs keygen                  서명 키 쌍을 만들고 서버에 넣을 공개 키를 보여 준다(이미 있으면 거부)
//   node admin.mjs candidates [--min N]    검토할 후보(기본: 서로 다른 기기 2대 이상)를 번호와 함께 보여 준다
//   node admin.mjs draft <번호,번호…>      고른 후보를 초안 파일(drafts/next.json)에 더한다(서버에 보내지 않음)
//   node admin.mjs status                  서버의 현재 묶음과 초안의 차이를 보여 준다
//   node admin.mjs publish                 초안(없으면 현재 묶음)을 다음 버전으로 서명해 서버에 올린다 — 이때부터 모든 앱이 받는다
//                                          (올린 초안은 drafts/published-v<판>.json으로 옮긴다. 초안의 기준 판이 서버 판과 다르면 거절)
//   node admin.mjs withdraw <규칙 id,…>    그 규칙을 뺀 새 버전을 서명해 올린다(잘못된 규칙 거두기)
import { generateKeyPairSync, createPrivateKey, createPublicKey, sign } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const dir = join(homedir(), ".bokki-shared-rules");
const keyFile = join(dir, "signing.pem"), configFile = join(dir, "admin.json"), draftFile = join(dir, "drafts", "next.json"), listFile = join(dir, "drafts", "last-candidates.json");
const [command, arg, ...rest] = process.argv.slice(2);
const flag = (name) => { const i = process.argv.indexOf(name); return i < 0 ? null : process.argv[i + 1]; };
const fail = (message) => { console.error(message); process.exit(1); };
const config = () => { if (!existsSync(configFile)) fail(`${configFile} 가 없습니다({"host":"…","token":"…"})`); return JSON.parse(readFileSync(configFile, "utf8")); };
async function call(path, method = "GET", body) {
  const { host, token } = config();
  const response = await fetch(`https://${host}${path}`, { method, headers: { authorization: `Bearer ${token}`, "content-type": "application/json" }, body: body ? JSON.stringify(body) : undefined });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) fail(`서버 ${response.status}: ${JSON.stringify(data)}`);
  return data;
}
const readDraft = () => existsSync(draftFile) ? JSON.parse(readFileSync(draftFile, "utf8")) : null;
const writeJson = (file, value) => { mkdirSync(join(file, ".."), { recursive: true }); writeFileSync(file, JSON.stringify(value, null, 2) + "\n"); };
const rawPublicKey = () => Buffer.from(createPublicKey(createPrivateKey(readFileSync(keyFile))).export({ format: "jwk" }).x, "base64url").toString("base64");
const line = (rule) => `${rule.type}  ${JSON.stringify(rule.match)} → ${JSON.stringify(rule.result)}`;

async function publish(current, rules, note) {
  const payload = JSON.stringify({ format: "bokki-shared-rules", version: current.version + 1, engine: 1, issuedAt: new Date().toISOString().slice(0, 10), rules });
  const signature = sign(null, Buffer.from(payload), createPrivateKey(readFileSync(keyFile))).toString("base64");
  console.log(`${note}: 버전 ${current.version} → ${current.version + 1}, 규칙 ${rules.length}개`);
  console.log(await call("/shared/admin/publish", "POST", { payload, signature }));
  return current.version + 1;
}
const currentBundle = async () => { const current = await call("/shared/admin/bundle"); return { version: current.version, rules: current.payload ? JSON.parse(current.payload).rules : [] }; };
// 초안은 만든 때의 서버 판(baseVersion) 위에 쌓는다. 그 사이 다른 판(거두기 등)이 나갔으면 그 초안으로 내보내지 않는다(REV1117A02).
function draftFor(current) {
  const draft = readDraft();
  if (draft && draft.baseVersion !== current.version) {
    fail(`초안(${draftFile})은 판 ${draft.baseVersion ?? "?"} 기준인데 서버는 판 ${current.version}입니다. 거둔 규칙이 되살아나지 않게 초안을 지우고 draft를 다시 하세요.`);
  }
  return draft;
}

switch (command) {
  case "keygen": {
    if (existsSync(keyFile)) fail("이미 서명 키가 있습니다. 바꾸려면 앱 빌드에 들어간 공개 키도 바꿔야 하므로 직접 지우고 다시 하세요.");
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    writeFileSync(keyFile, generateKeyPairSync("ed25519").privateKey.export({ type: "pkcs8", format: "pem" }), { mode: 0o600 });
    chmodSync(keyFile, 0o600);
    console.log("공개 키(서버 비밀값 SHARED_RULES_PUBLIC_KEY와 앱 설정 SHARED_RULES_PUBLIC_KEY에 같은 값):\n" + rawPublicKey());
    break;
  }
  case "candidates": {
    const min = Number(flag("--min") ?? 2);
    const listed = await call(`/shared/admin/candidates?min=${min}`);
    writeJson(listFile, listed.candidates);
    console.log(`후보 ${listed.candidates.length}개 (전체 ${listed.total}개, 기기 ${min}대 이상)`);
    listed.candidates.forEach((c, i) => console.log(`${i + 1}. [${c.count}대] ${line(c)}`));
    break;
  }
  case "draft": {
    if (!arg || !existsSync(listFile)) fail("먼저 candidates를 실행하고 번호를 고르세요.");
    const list = JSON.parse(readFileSync(listFile, "utf8"));
    const current = await currentBundle();
    const draft = draftFor(current) ?? { baseVersion: current.version, rules: current.rules };
    for (const n of arg.split(",").map(Number)) {
      const c = list[n - 1];
      if (!c) fail(`번호 ${n}이 없습니다`);
      const id = "sr_" + c.fp.slice(0, 12);
      if (draft.rules.some((r) => r.id === id)) continue;
      const rule = { id, type: c.type, match: { ...c.match }, result: { ...c.result } };
      // 후보에는 견본 글이 없다. 결제 문자 정규식은 운영자가 지어낸 견본 글을 직접 넣어야 한다(실제 문자를 붙이지 말 것).
      if (c.type === "payment_text") { rule.match.sample = "여기에 지어낸 견본 문자를 쓰세요"; rule.result.name = "카드"; }
      draft.rules.push(rule);
    }
    writeJson(draftFile, draft);
    console.log(`초안에 ${draft.rules.length}개. ${draftFile} 를 열어 견본 글을 채우고 확인한 뒤 publish 하세요.`);
    break;
  }
  case "status": {
    const current = await currentBundle(), server = current.rules, draft = readDraft();
    console.log(`서버: 판 ${current.version}, ${server.length}개`); server.forEach((r) => console.log(`  ${r.id}  ${line(r)}`));
    if (draft) {
      console.log(`초안: 판 ${draft.baseVersion ?? "?"} 기준, ${draft.rules.length}개${draft.baseVersion === current.version ? "" : " — 서버 판과 달라 내보낼 수 없음(지우고 다시 draft)"}`);
      draft.rules.filter((r) => !server.some((s) => s.id === r.id)).forEach((r) => console.log(`  + ${r.id}  ${line(r)}`));
      server.filter((s) => !draft.rules.some((r) => r.id === s.id)).forEach((r) => console.log(`  - ${r.id}  ${line(r)}`));
    }
    break;
  }
  case "publish": {
    const current = await currentBundle(), draft = draftFor(current);
    if (draft?.rules.some((r) => r.match?.sample === "여기에 지어낸 견본 문자를 쓰세요")) fail("초안에 견본 글을 채우지 않은 규칙이 있습니다.");
    const version = await publish(current, draft ? draft.rules : current.rules, "내보내기");
    // 내보낸 초안은 보관해 두고, 다음 draft는 서버의 새 판에서 시작한다.
    if (draft) renameSync(draftFile, join(dir, "drafts", `published-v${version}.json`));
    break;
  }
  case "withdraw": {
    if (!arg) fail("거둘 규칙 id를 쉼표로 적으세요.");
    const gone = new Set([arg, ...rest].join(",").split(",").filter(Boolean));
    const current = await currentBundle();
    await publish(current, current.rules.filter((r) => !gone.has(r.id)), "거두기");
    break;
  }
  default: fail("사용법은 파일 맨 위 주석을 보세요.");
}
