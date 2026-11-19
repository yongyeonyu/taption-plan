// BRG1119A01: 공용 공지(R2 `announcements/latest.json`)를 합치고 검사해서 올린다. 올리는 사람은 대표(또는 대표가 시킨 클로드 코드)다.
//
//   node scripts/announce.mjs --host <중계 서버 주소> --title "점검 안내" --body "…" [--kind warning] [--id maintenance-1126] [--expires-at 2026-11-27T09:00+09:00]
//   node scripts/announce.mjs --host <주소> --spec spec.json       # {"items":[…],"remove":["옛-id"]} (비야 브리지 공지 게시 요청이 이 모양)
//   node scripts/announce.mjs --host <주소> --remove id1,id2       # 공지 내리기
//   node scripts/announce.mjs --host <주소> --clear                # 모든 공지 내리기(빈 목록)
//   … --upload [--config wrangler.local.toml]                      # 미리보기만 하지 말고 R2에 올린다(`--remote`는 스크립트가 붙인다)
//
// - 지금 올라간 공지(`GET /public/announcements`)에 합친다: 같은 `id`는 바꾸고, `--remove`는 내리고, `version`은 지금 값 + 1.
// - 검사는 `server/trip-relay/README.md` 「공지 JSON 스키마」와 같다(서버는 본문을 고치지 않고 앱이 거르므로 여기서 먼저 막는다).
// - `--upload` 없이는 아무것도 쓰지 않는다(미리보기와 만든 파일 경로만 보여 준다).
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

export const LIMITS = { items: 50, title: 100, body: 2000, link: 300 };
const KINDS = ["info", "update", "warning", "critical"];
const ID = /^[a-z0-9][a-z0-9._-]{0,63}$/;
const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2})$/;
const KEYS = ["id", "title", "body", "kind", "startsAt", "expiresAt", "minBuild", "maxBuild", "link", "titleByLang", "bodyByLang"];

const isObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const isText = (value, max) => typeof value === "string" && value.trim().length >= 1 && value.length <= max;

/** 공지 한 건 검사. 문제가 있으면 문장 배열, 없으면 빈 배열. */
export function problems(item) {
  if (!isObject(item)) return ["공지가 객체가 아님"];
  const out = [];
  for (const key of Object.keys(item)) if (!KEYS.includes(key)) out.push(`모르는 필드: ${key}`);
  if (typeof item.id !== "string" || !ID.test(item.id)) out.push("id는 [a-z0-9][a-z0-9._-]{0,63}");
  if (!isText(item.title, LIMITS.title)) out.push(`title은 1~${LIMITS.title}자`);
  if (!isText(item.body, LIMITS.body)) out.push(`body는 1~${LIMITS.body}자 평문`);
  if (/<[a-z!/][^>]*>/i.test(String(item.body ?? "")) || /<[a-z!/][^>]*>/i.test(String(item.title ?? ""))) out.push("HTML은 쓰지 않음");
  if (!KINDS.includes(item.kind)) out.push(`kind는 ${KINDS.join("·")}`);
  for (const key of ["startsAt", "expiresAt"]) {
    if (item[key] !== undefined && item[key] !== null && !(typeof item[key] === "string" && ISO.test(item[key]) && !Number.isNaN(Date.parse(item[key])))) out.push(`${key}는 오프셋이 있는 ISO 8601`);
  }
  for (const key of ["minBuild", "maxBuild"]) {
    if (item[key] !== undefined && item[key] !== null && !Number.isInteger(item[key])) out.push(`${key}는 정수`);
  }
  if (item.link !== undefined && item.link !== null && !(typeof item.link === "string" && item.link.length <= LIMITS.link && /^https:\/\/[^\s]+$/.test(item.link))) out.push(`link는 https:// 이고 ${LIMITS.link}자 이내`);
  for (const key of ["titleByLang", "bodyByLang"]) {
    const table = item[key];
    if (table !== undefined && !(isObject(table) && Object.entries(table).every(([lang, text]) => /^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})?$/.test(lang) && typeof text === "string" && text.length <= (key === "titleByLang" ? LIMITS.title : LIMITS.body)))) out.push(`${key}는 {"en": "…"} 모양`);
  }
  return out;
}

/** 지금 올라간 묶음에 요청을 합친다. 같은 id는 바꾸고(자리 유지), 새 것은 앞에 둔다. */
export function merge(current, spec) {
  const base = Array.isArray(current?.items) ? current.items : [];
  const remove = new Set(spec.remove ?? []);
  const incoming = spec.items ?? [];
  const byId = new Map(incoming.map((item) => [item?.id, item]));
  const kept = base.filter((item) => !remove.has(item.id)).map((item) => (byId.has(item.id) ? byId.get(item.id) : item));
  const fresh = incoming.filter((item) => !base.some((old) => old.id === item?.id));
  const items = [...fresh, ...kept];
  const version = (Number.isInteger(current?.version) && current.version >= 0 ? current.version : 0) + 1;
  return { version, items };
}

export function check(bundle) {
  const errors = [];
  if (!Number.isInteger(bundle.version) || bundle.version < 1) errors.push("version은 1 이상 정수");
  if (bundle.items.length > LIMITS.items) errors.push(`공지는 최대 ${LIMITS.items}개`);
  const seen = new Set();
  for (const item of bundle.items) {
    for (const message of problems(item)) errors.push(`${item?.id ?? "?"}: ${message}`);
    if (seen.has(item?.id)) errors.push(`${item?.id}: id가 겹침`);
    seen.add(item?.id);
  }
  return errors;
}

export function preview(current, next) {
  const was = new Map((current?.items ?? []).map((item) => [item.id, item]));
  const lines = [`version ${current?.version ?? 0} → ${next.version}, 공지 ${next.items.length}건`];
  for (const item of next.items) {
    const before = was.get(item.id);
    const mark = !before ? "추가" : JSON.stringify(before) === JSON.stringify(item) ? "그대로" : "바뀜";
    lines.push(`  [${mark}] ${item.id} (${item.kind}) 「${item.title}」 ${item.body.slice(0, 60)}${item.body.length > 60 ? "…" : ""}`);
  }
  for (const id of was.keys()) if (!next.items.some((item) => item.id === id)) lines.push(`  [내림] ${id}`);
  return lines.join("\n");
}

function parseArgs(argv) {
  const args = { remove: [] };
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i];
    const value = () => { const next = argv[++i]; if (next === undefined) throw new Error(`${flag} 값이 없습니다`); return next; };
    switch (flag) {
      case "--host": args.host = value(); break;
      case "--spec": args.spec = value(); break;
      case "--title": args.title = value(); break;
      case "--body": args.body = value(); break;
      case "--kind": args.kind = value(); break;
      case "--id": args.id = value(); break;
      case "--link": args.link = value(); break;
      case "--starts-at": args.startsAt = value(); break;
      case "--expires-at": args.expiresAt = value(); break;
      case "--min-build": args.minBuild = Number(value()); break;
      case "--max-build": args.maxBuild = Number(value()); break;
      case "--remove": args.remove.push(...value().split(",").filter(Boolean)); break;
      case "--clear": args.clear = true; break;
      case "--upload": args.upload = true; break;
      case "--config": args.config = value(); break;
      case "--out": args.out = value(); break;
      case "--current": args.current = value(); break; // 시험·오프라인용: 지금 묶음을 파일에서 읽는다
      default: throw new Error(`모르는 옵션: ${flag}`);
    }
  }
  return args;
}

/** 옵션을 {items, remove}로. 빠른 옵션(--title/--body)은 공지 한 건을 만든다. */
export function specFrom(args, now = new Date()) {
  const spec = args.spec ? JSON.parse(readFileSync(args.spec, "utf8")) : { items: [], remove: [] };
  if (!isObject(spec) || (spec.items !== undefined && !Array.isArray(spec.items)) || (spec.remove !== undefined && !Array.isArray(spec.remove))) throw new Error("spec은 {\"items\":[…],\"remove\":[…]} 모양");
  spec.items ??= []; spec.remove = [...(spec.remove ?? []), ...args.remove];
  if (args.title !== undefined || args.body !== undefined) {
    const stamp = now.toISOString().slice(0, 10).replaceAll("-", "").slice(2);
    const item = { id: args.id ?? `notice-${stamp}-${String(now.getTime()).slice(-4)}`, title: args.title, body: args.body, kind: args.kind ?? "info" };
    for (const [key, value] of [["link", args.link], ["startsAt", args.startsAt], ["expiresAt", args.expiresAt], ["minBuild", args.minBuild], ["maxBuild", args.maxBuild]]) if (value !== undefined) item[key] = value;
    spec.items.push(item);
  }
  return spec;
}

async function loadCurrent(args) {
  if (args.current) return JSON.parse(readFileSync(args.current, "utf8"));
  if (!args.host) throw new Error("--host <중계 서버 주소> 가 필요합니다(또는 --current 파일)");
  const response = await fetch(`https://${args.host}/public/announcements`, { headers: { "cache-control": "no-cache" } });
  if (!response.ok) throw new Error(`지금 공지를 읽지 못했습니다(${response.status})`);
  return response.json();
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const current = await loadCurrent(args);
  const spec = args.clear ? { items: [], remove: (current.items ?? []).map((item) => item.id) } : specFrom(args);
  if (!args.clear && spec.items.length === 0 && spec.remove.length === 0) throw new Error("올릴 공지(--title/--body 또는 --spec)나 내릴 id(--remove)가 없습니다");
  const next = merge(current, spec);
  const errors = check(next);
  console.log(preview(current, next));
  if (errors.length) { console.error("\n검사 실패:\n- " + errors.join("\n- ")); process.exit(2); }
  const out = args.out ?? join(mkdtempSync(join(tmpdir(), "announce-")), "announcements.json");
  writeFileSync(out, JSON.stringify(next, null, 2) + "\n");
  if (!args.upload) { console.log(`\n올리지 않았습니다(--upload 없음). 만든 파일: ${out}`); return; }
  execFileSync("npx", ["wrangler", "r2", "object", "put", "taption-trip-public/announcements/latest.json", "--file", out, "--content-type", "application/json",
    "--cache-control", "public, max-age=300", "--remote", "--config", args.config ?? "wrangler.local.toml"], { stdio: "inherit" });
  console.log("\n올렸습니다. 앱은 최대 5분(엣지 캐시)+30분(앱 쿨다운) 안에 받습니다.");
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main().catch((error) => { console.error(error.message); process.exit(1); });
