// KEY1121A01: 앱(BOKKI Plan)·중계 서버(server/trip-relay)가 쓰는 외부 API 키를 이 맥에서만 모아 둔다.
//
// - 값은 저장소 밖 `~/.bokki-admin-console/keys.json`(폴더 700, 파일 600)에만 쓴다. 시험은 ADMIN_CONSOLE_KEYS로 임시 파일을 쓴다.
// - 화면·API 응답·기록에는 원문을 다시 내보내지 않는다(끝 4자리 마스킹만). 원문을 꺼내는 길은 터미널의 `--print-key` 하나뿐이다.
// - Cloudflare 시크릿 반영(`wrangler secret put`)·앱 빌드 설정 반영은 하지 않고 명령만 안내한다(배포는 대표 승인 사안).
// - 사용량은 공급자가 알려 주는 길이 없으면 「확인 불가」와 이유를 쓴다. 한도는 코드·설정에 적힌 값만 쓴다(추측값 없음).
import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

export const KEYS_FILE = process.env.ADMIN_CONSOLE_KEYS ?? join(homedir(), ".bokki-admin-console", "keys.json");

const DATA_GO_KR = "공공데이터포털(data.go.kr) › 마이페이지 › 데이터활용 › 활용신청 현황에서 키별 활용기간·트래픽을 봅니다";

/**
 * 키 목록. where: "server"(Worker 시크릿) | "app"(앱 빌드 설정 `TaptionPlan/AppSecrets.local.xcconfig`).
 * usage.kind: "unavailable"(확인 불가) | "limit"(우리가 정한 한도만 앎). limit 값은 저장소 코드·README에 적힌 것만.
 */
export const KEY_CATALOG = [
  { name: "ICN_API_KEY", kind: "external", where: "server", provider: "인천국제공항공사(공공데이터포털)", group: "항공편",
    feature: "항공편 조회 — 인천공항 정기 스케줄과 당일 운항현황(지연·탑승구)", missing: "인천 항공편 조회가 503(flight_key_missing)이 되고 앱은 「직접 입력 + 편명으로 검색」으로 넘어갑니다",
    usage: { kind: "limit", limit: "서버 전체 하루 400회(FLIGHT_DAILY_CALLS 기본값, KAC와 함께 셈) · 공급자 개발계정 일 500회", reason: "서버가 Durable Object(global:flights)에서 세지만 읽는 경로가 없어 오늘 쓴 수는 확인 불가", where: DATA_GO_KR },
    expiryHint: "공공데이터포털 활용기간(신청 화면에 표시)" },
  { name: "KAC_API_KEY", kind: "external", where: "server", provider: "한국공항공사(공공데이터포털)", group: "항공편",
    feature: "항공편 조회 — 김포·제주 등 전국 공항 국내선·국제선 스케줄(인천 제외)", missing: "인천 밖 공항의 항공편 조회가 503(flight_key_missing)이 되고 앱은 직접 입력으로 넘어갑니다",
    usage: { kind: "limit", limit: "서버 전체 하루 400회(FLIGHT_DAILY_CALLS 기본값, ICN과 함께 셈)", reason: "오늘 쓴 수는 서버가 내보내지 않아 확인 불가", where: DATA_GO_KR },
    expiryHint: "공공데이터포털 활용기간(신청 화면에 표시)" },
  { name: "EX_API_KEY", kind: "external", where: "server", provider: "한국도로공사(data.ex.co.kr)", group: "길·교통",
    feature: "고속도로 요금 — 영업소 위치·영업소간 통행료(차종별)", missing: "/ex/units·/ex/fare가 503(ex_key_missing)이 되고 앱은 같은 길의 지난 통행료만 씁니다",
    usage: { kind: "unavailable", reason: "공급자 사용량 API가 없고 서버도 따로 세지 않음(캐시: 영업소 7일·요금 1일)", where: "data.ex.co.kr › OpenAPI 활용 › 인증키 화면" },
    expiryHint: "data.ex.co.kr 인증키 화면(공공데이터포털 키와 다름)" },
  { name: "TAGO_SERVICE_KEY", kind: "external", where: "server", provider: "국토교통부 TAGO(공공데이터포털)", group: "길·교통",
    feature: "버스 정류장·노선 조회(/tago/stops·/tago/routes). TOUR_API_KEY가 없으면 관광공사 사진에도 대신 쓰입니다", missing: "버스 정류장·노선 조회가 503이 되어 꺼지고, TOUR_API_KEY도 없으면 관광공사 사진도 꺼집니다",
    usage: { kind: "unavailable", reason: "서버는 카카오와 같은 검색 한도(키마다 하루 500)로 막기만 하고 공급자별로 세지 않음", where: DATA_GO_KR },
    expiryHint: "공공데이터포털 활용기간(「일반 인증키 Decoding」 값)" },
  { name: "KAKAO_REST_API_KEY", kind: "external", where: "server", provider: "카카오 디벨로퍼스", group: "길·교통",
    feature: "장소 검색(카카오 로컬 키워드)·길찾기 중계·고속도로 영업소 좌표 보정", missing: "/kakao/keyword가 503이 되고 앱은 Apple 검색만 씁니다(길찾기 중계도 꺼짐)",
    usage: { kind: "limit", limit: "검색 키(설치)마다 하루 500회, IP당 1분 60회(서버 한도)", reason: "공급자 전체 호출 수는 서버에서 읽을 수 없어 확인 불가", where: "카카오 디벨로퍼스 › 내 애플리케이션 › 해당 앱 화면" },
    expiryHint: "REST 키는 재발급 전까지 쓰는 방식 — 갱신일을 직접 적어 두세요" },
  { name: "GOOGLE_PLACES_KEY", kind: "external", where: "server", provider: "Google Cloud(Places API New)", group: "사진",
    feature: "장소 사진 — 구글 장소의 첫 사진(장소 하나에 호출 두 번)", missing: "사진 출처 google이 503이 되고 앱은 다음 출처로 넘어갑니다",
    usage: { kind: "limit", limit: "하루 30건(대표가 구글 콘솔에서 건 상한, 코드 주석 GPH1114A11)", reason: "실제 쓴 수는 구글 콘솔에만 있어 확인 불가", where: "Google Cloud 콘솔 › API 및 서비스 › Places API › 할당량·측정항목" },
    expiryHint: "API 키 자체는 만료가 없고 결제 계정 상태를 확인" },
  { name: "MAPILLARY_TOKEN", kind: "external", where: "server", provider: "Mapillary", group: "사진",
    feature: "장소 사진 — 좌표 둘레 약 60m 거리 사진", missing: "사진 출처 mapillary가 503이 되어 꺼집니다",
    usage: { kind: "unavailable", reason: "공급자 사용량 API를 쓰지 않고 서버도 세지 않음", where: "Mapillary 개발자 화면(앱 토큰)" }, expiryHint: "공급자 화면에서 확인" },
  { name: "TOUR_API_KEY", kind: "external", where: "server", provider: "한국관광공사 TourAPI(공공데이터포털)", group: "사진",
    feature: "장소 사진 — 관광공사 관광지 대표 사진(이름 검색, 좌표 3km 안)", missing: "TAGO_SERVICE_KEY로 대신 부르고, 둘 다 없으면 사진 출처 tour가 꺼집니다",
    usage: { kind: "unavailable", reason: "서버가 따로 세지 않음", where: DATA_GO_KR }, expiryHint: "공공데이터포털 활용기간" },
  { name: "UNSPLASH_ACCESS_KEY", kind: "external", where: "server", provider: "Unsplash", group: "사진",
    feature: "장소 사진 — 이름으로 찾은 풍경 사진(3장)", missing: "사진 출처 unsplash가 503이 되어 꺼집니다",
    usage: { kind: "unavailable", reason: "서버가 세지 않음(공급자는 응답 머리글로 시간당 남은 수를 알려 주지만 서버가 저장하지 않음)", where: "unsplash.com/oauth/applications › 해당 앱" }, expiryHint: "공급자 화면에서 확인" },
  { name: "PEXELS_API_KEY", kind: "external", where: "server", provider: "Pexels", group: "사진",
    feature: "장소 사진 — 이름으로 찾은 풍경 사진(3장)", missing: "사진 출처 pexels가 503이 되어 꺼집니다",
    usage: { kind: "unavailable", reason: "서버가 세지 않음", where: "pexels.com/api › 내 API 키 화면" }, expiryHint: "공급자 화면에서 확인" },
  { name: "APNS_KEY_P8", kind: "internal", where: "server", provider: "Apple Developer(APNs 인증 키)", group: "푸시 알림", multiline: true,
    feature: "푸시 알림 — .p8 파일 내용 전체(-----BEGIN PRIVATE KEY----- 포함)", missing: "APNS_KEY_ID·APNS_TEAM_ID와 셋 중 하나라도 없으면 서버가 푸시를 하나도 보내지 않습니다",
    usage: { kind: "unavailable", reason: "서버가 보낸 수를 내보내지 않음", where: "Apple Developer › Certificates, Identifiers & Profiles › Keys" }, expiryHint: "Apple Developer › Keys에서 폐기 여부 확인" },
  { name: "APNS_KEY_ID", kind: "internal", where: "server", provider: "Apple Developer", group: "푸시 알림",
    feature: "푸시 알림 — APNs 인증 키 ID", missing: "푸시를 보내지 않습니다", usage: { kind: "unavailable", reason: "사용량 개념 없음(식별자)", where: "Apple Developer › Keys" }, expiryHint: "APNS_KEY_P8과 같음" },
  { name: "APNS_TEAM_ID", kind: "internal", where: "server", provider: "Apple Developer", group: "푸시 알림",
    feature: "푸시 알림 — 개발자 팀 ID", missing: "푸시를 보내지 않습니다", usage: { kind: "unavailable", reason: "사용량 개념 없음(식별자)", where: "Apple Developer › Membership" }, expiryHint: "Apple 개발자 멤버십 갱신일" },
  { name: "KAKAO_NATIVE_APP_KEY", kind: "app", where: "app", provider: "카카오 디벨로퍼스", group: "iOS 앱",
    feature: "카카오 지도(지도 종류 선택) — 앱에 들어가는 네이티브 앱 키", missing: "앱 설정에서 「카카오 지도」를 고를 수 없습니다",
    usage: { kind: "unavailable", reason: "기기에서 바로 부르므로 서버가 셀 수 없음", where: "카카오 디벨로퍼스 › 내 애플리케이션 › 해당 앱 화면" }, expiryHint: "재발급 전까지 쓰는 방식" },
  { name: "POSTHOG_API_KEY", kind: "app", where: "app", provider: "PostHog", group: "iOS 앱",
    feature: "진단 업로드 — 설정의 진단 보내기(PHG1120A01) 프로젝트 키", missing: "앱의 진단 업로드 버튼이 꺼집니다",
    usage: { kind: "unavailable", reason: "기기에서 바로 올리므로 서버가 셀 수 없음", where: "PostHog › Settings › Billing·Usage" }, expiryHint: "프로젝트 키는 만료가 없고 프로젝트 삭제·재발급 때 바뀜" },
  { name: "APNS_TOPIC", kind: "internal", where: "server", provider: "Apple Developer", group: "푸시 알림", optional: true,
    feature: "푸시 알림 — 번들 ID가 com.taption.plan이 아닐 때만 넣는 토픽", missing: "기본값 com.taption.plan을 씁니다(대부분 비워 둠)",
    usage: { kind: "unavailable", reason: "사용량 개념 없음(설정값)", where: "Apple Developer › Identifiers" }, expiryHint: "만료 없음(설정값)" },
  { name: "PIN_PEPPER", kind: "internal", where: "server", provider: "우리가 만든 무작위 값", group: "서버 내부", danger: "바꾸거나 잃으면 모든 사용자의 PIN이 맞지 않게 되어 앱에서 PIN을 다시 정해야 합니다. 서버에 이미 있으면 교체하지 마세요.",
    feature: "PIN 확인 — 서버가 PIN 검증값을 만들 때 섞는 비밀(32바이트 이상 무작위)", missing: "PIN 확인이 모두 503(pin_check_unavailable)이 되어 키 연결·OAuth 연결이 막힙니다",
    usage: { kind: "unavailable", reason: "사용량 개념 없음(내부 비밀)", where: "없음(우리 서버 안에서만 씀)" }, expiryHint: "만료 없음 — 바꾸지 않는 값" },
  { name: "CLASSIFIER_ADMIN_TOKEN", kind: "internal", where: "server", provider: "우리가 만든 무작위 값", group: "서버 내부",
    feature: "분류 표본 관리 길(/classifier-samples/admin) 읽기용 토큰(32자 이상)", missing: "관리 길이 503이 됩니다(앱 기능에는 영향 없음)",
    usage: { kind: "unavailable", reason: "사용량 개념 없음(관리 토큰)", where: "없음" }, expiryHint: "만료 없음 — 새어 나갔다고 의심되면 교체" },
  { name: "SHARED_RULES_ADMIN_TOKEN", kind: "internal", where: "server", provider: "우리가 만든 무작위 값", group: "서버 내부",
    feature: "공통 규칙 묶음 올리기 관리 길(/shared/admin/) 토큰(32자 이상, ~/.bokki-shared-rules/admin.json에도 둠)", missing: "공통 규칙 관리 길이 503이 됩니다",
    usage: { kind: "unavailable", reason: "사용량 개념 없음(관리 토큰)", where: "없음" }, expiryHint: "만료 없음 — 새어 나갔다고 의심되면 교체" },
  { name: "SHARED_RULES_PUBLIC_KEY", kind: "internal", where: "server", provider: "우리가 만든 Ed25519 키 쌍", group: "서버 내부", alsoApp: true,
    feature: "공통 규칙 묶음 서명 확인용 공개 키(base64, 비밀 아님). 앱 xcconfig에도 같은 값", missing: "서버 관리 길이 503이 되고 받기는 version 0만, 앱은 공통 규칙을 받지 않습니다",
    usage: { kind: "unavailable", reason: "사용량 개념 없음(공개 키)", where: "없음" }, expiryHint: "만료 없음 — 서명 키를 바꿀 때 함께 교체" },
  { name: "ALGOLIA_APP_ID", kind: "planned", where: "server", provider: "Algolia", group: "연동 예정",
    feature: "도시 팩 검색 색인(ARCH1120A01 2-1단계) — 앱 ID", missing: "아직 코드가 쓰지 않습니다(연동 전)",
    usage: { kind: "unavailable", reason: "연동 전", where: "Algolia 대시보드 › Settings › API Keys·Usage" }, expiryHint: "공급자 화면에서 확인" },
  { name: "ALGOLIA_WRITE_KEY", kind: "planned", where: "server", provider: "Algolia", group: "연동 예정",
    feature: "도시 팩 검색 색인(ARCH1120A01 2-1단계) — 색인 쓰기 키(서버에만)", missing: "아직 코드가 쓰지 않습니다(연동 전)",
    usage: { kind: "unavailable", reason: "연동 전", where: "Algolia 대시보드 › Settings › API Keys·Usage" }, expiryHint: "공급자 화면에서 확인" },
];

export const KIND_LABEL = { external: "서버 외부 API 키", internal: "서버 내부 시크릿", app: "iOS 앱 키", planned: "연동 예정·직접 추가" };

const BY_NAME = new Map(KEY_CATALOG.map((entry) => [entry.name, entry]));
export const CUSTOM_NAME = /^[A-Z][A-Z0-9_]{2,63}$/;

/** 직접 추가한 항목(store.custom)을 목록 모양으로. */
function customEntry(name, def) {
  return { name, kind: "planned", custom: true, where: def.where === "app" ? "app" : "server", provider: def.provider || "직접 추가", group: "연동 예정",
    feature: def.feature || "설명 없음(직접 추가한 칸)", missing: "아직 코드가 쓰지 않습니다(연동 전)", multiline: false,
    usage: { kind: "unavailable", reason: "연동 전", where: def.provider ? `${def.provider} 대시보드` : "공급자 대시보드" }, expiryHint: "공급자 화면에서 확인" };
}

export function allEntries(store = { custom: {} }) {
  const custom = Object.entries(store.custom ?? {}).filter(([name]) => !BY_NAME.has(name)).map(([name, def]) => customEntry(name, def));
  return [...KEY_CATALOG, ...custom];
}
export const knownKey = (name, store) => BY_NAME.get(name) ?? (store?.custom?.[name] ? customEntry(name, store.custom[name]) : null);

/** 직접 추가 칸 검사. 이름은 대문자·숫자·_, 목록에 있는 이름은 안 됨. */
export function checkCustom(body) {
  const name = String(body?.name ?? "").trim();
  const errors = [];
  if (!CUSTOM_NAME.test(name)) errors.push("이름은 대문자로 시작하는 대문자·숫자·_ 3~64자(예: AWS_ACCESS_KEY_ID)");
  else if (BY_NAME.has(name)) errors.push("이미 목록에 있는 이름입니다");
  const provider = typeof body?.provider === "string" ? body.provider.trim() : "";
  const feature = typeof body?.feature === "string" ? body.feature.trim() : "";
  if (provider.length > 60) errors.push("공급자는 60자까지");
  if (feature.length > 200) errors.push("설명은 200자까지");
  return { errors, name, def: { provider, feature, where: body?.where === "app" ? "app" : "server" } };
}

export const MAX_VALUE = 8192;
const DATE = /^\d{4}-\d{2}-\d{2}$/;

/** 끝 4자리만. 12자 미만은 끝도 보이지 않는다(짧은 값은 4자리만으로도 많이 드러남). */
export function maskValue(value) {
  if (typeof value !== "string" || !value) return null;
  const tail = value.replace(/\s+$/, "");
  return tail.length >= 12 ? `••••${tail.slice(-4)}` : "••••";
}

/** 값 검사. 오류 문구에 값을 넣지 않는다. */
export function checkValue(name, raw, store) {
  const entry = knownKey(name, store);
  if (!entry) return { error: "목록에 없는 키 이름입니다" };
  if (typeof raw !== "string") return { error: "값은 글자여야 합니다" };
  const value = entry.multiline ? raw.replace(/\r\n/g, "\n").trim() : raw.trim();
  if (!value) return { error: "값이 비어 있습니다(지우려면 「삭제」)" };
  if (value.length > MAX_VALUE) return { error: `값이 너무 깁니다(${MAX_VALUE}자까지)` };
  if (!entry.multiline && /\s/.test(value)) return { error: "키 값에 공백·줄바꿈이 있습니다. 앞뒤 따옴표나 줄바꿈이 섞였는지 확인하세요" };
  // eslint-disable-next-line no-control-regex
  if (/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(value)) return { error: "보이지 않는 제어 문자가 섞여 있습니다" };
  if (entry.multiline && !/^-----BEGIN [A-Z ]*PRIVATE KEY-----\n[\s\S]+\n-----END [A-Z ]*PRIVATE KEY-----$/.test(value)) return { error: ".p8 파일 내용 전체(BEGIN/END 줄 포함)를 붙여 넣으세요" };
  return { value };
}

/** 만료일 상태. expired | soon7 | soon30 | ok | none. 날짜는 이 맥 시간대의 그날 끝까지 유효로 본다. */
export function expiryState(expiresAt, now = new Date()) {
  if (!expiresAt || !DATE.test(expiresAt)) return { state: "none", days: null };
  const [y, m, d] = expiresAt.split("-").map(Number);
  const end = new Date(y, m - 1, d + 1); // 그날 자정 넘기 전까지
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const days = Math.round((new Date(y, m - 1, d) - today) / 86400000);
  if (now >= end) return { state: "expired", days };
  if (days <= 7) return { state: "soon7", days };
  if (days <= 30) return { state: "soon30", days };
  return { state: "ok", days };
}

export function checkMeta(body) {
  const errors = [];
  const expiresAt = body?.expiresAt === "" || body?.expiresAt === null || body?.expiresAt === undefined ? null : body.expiresAt;
  if (expiresAt !== null) {
    const ok = typeof expiresAt === "string" && DATE.test(expiresAt) && !Number.isNaN(Date.parse(`${expiresAt}T00:00:00Z`))
      && new Date(`${expiresAt}T00:00:00Z`).toISOString().slice(0, 10) === expiresAt;
    if (!ok) errors.push("만료일은 YYYY-MM-DD 날짜");
  }
  const note = typeof body?.note === "string" ? body.note.trim() : "";
  if (note.length > 200) errors.push("메모는 200자까지");
  return { errors, meta: { expiresAt, note } };
}

// ---- 파일 ----

export function readStore(file = KEYS_FILE) {
  try {
    const doc = JSON.parse(readFileSync(file, "utf8"));
    const obj = (v) => (v && typeof v === "object" && !Array.isArray(v) ? v : {});
    return { format: "bokki-admin-keys", schema: 1, keys: obj(doc?.keys), custom: obj(doc?.custom) };
  } catch { return { format: "bokki-admin-keys", schema: 1, keys: {}, custom: {} }; }
}

/** 임시 파일(600)에 쓰고 바꿔 끼운다. 폴더는 700. */
export function writeStore(store, file = KEYS_FILE) {
  mkdirSync(dirname(file), { recursive: true, mode: 0o700 });
  const tmp = `${file}.${process.pid}.tmp`;
  writeFileSync(tmp, JSON.stringify(store, null, 2) + "\n", { mode: 0o600 });
  chmodSync(tmp, 0o600);
  renameSync(tmp, file);
  chmodSync(file, 0o600);
}

/** 파일 권한(예: 0o600). 파일이 없으면 null. */
export function storeMode(file = KEYS_FILE) {
  try { return existsSync(file) ? statSync(file).mode & 0o777 : null; } catch { return null; }
}

// ---- 화면용 ----

const wranglerPut = (name) => `cd server/trip-relay && npx wrangler secret put ${name} --config wrangler.local.toml`;
const pipePut = (name) => `node tools/admin-console/server.mjs --print-key ${name} | (cd server/trip-relay && npx wrangler secret put ${name} --config wrangler.local.toml)`;

/** 앱 빌드 설정(xcconfig)에 그 이름이 채워져 있는지. 값은 읽어도 내보내지 않고, 저장한 값과 같은지만 알려 준다. */
export function appBuildValue(xcconfigText, name) {
  if (typeof xcconfigText !== "string") return null;
  const line = xcconfigText.split("\n").find((l) => new RegExp(`^\\s*${name}\\s*=`).test(l));
  if (!line) return null;
  const value = line.split("=").slice(1).join("=").replace(/\/\/.*$/, "").trim();
  return value || null;
}

/** 원문 없이 화면에 보낼 한 줄. serverNames: wrangler secret list로 읽은 이름 집합(없으면 null). */
export function publicView(store, { now = new Date(), xcconfigText = null, serverNames = null } = {}) {
  return allEntries(store).map((entry) => {
    const saved = store.keys[entry.name] ?? {};
    const value = typeof saved.value === "string" && saved.value ? saved.value : null;
    const view = {
      name: entry.name, kind: entry.kind, kindLabel: KIND_LABEL[entry.kind], custom: entry.custom === true, danger: entry.danger ?? null, optional: entry.optional === true,
      where: entry.where, group: entry.group, provider: entry.provider, feature: entry.feature, missing: entry.missing,
      multiline: entry.multiline === true, usage: entry.usage, expiryHint: entry.expiryHint,
      hasValue: !!value, masked: maskValue(value), savedAt: saved.savedAt ?? null,
      expiresAt: saved.expiresAt ?? null, note: saved.note ?? "", expiry: expiryState(saved.expiresAt, now),
    };
    if (entry.where === "server") {
      view.apply = { how: entry.kind === "planned" ? "연동 코드가 들어온 뒤 Cloudflare 시크릿으로(대표 승인 뒤 터미널에서)" : "Cloudflare 시크릿(대표 승인 뒤 터미널에서)",
        commands: [pipePut(entry.name), wranglerPut(entry.name), ...(entry.alsoApp ? [`${entry.name} = <같은 값>   # TaptionPlan/AppSecrets.local.xcconfig, 다시 빌드`] : [])] };
      view.onServer = serverNames ? serverNames.has(entry.name) : null;
    } else {
      const built = appBuildValue(xcconfigText, entry.name);
      view.apply = { how: "앱 빌드 설정 TaptionPlan/AppSecrets.local.xcconfig(git 제외)에 직접 적고 다시 빌드(TestFlight는 대표 승인)", commands: [`${entry.name} = <키 값>`] };
      view.inAppBuild = built === null ? "empty" : value ? (built === value ? "same" : "different") : "filled";
    }
    return view;
  });
}

/** `wrangler secret list --format json` 출력에서 이름만. */
export function parseSecretList(output) {
  const start = output.indexOf("[");
  if (start < 0) return null;
  try {
    const list = JSON.parse(output.slice(start, output.lastIndexOf("]") + 1));
    return Array.isArray(list) ? new Set(list.map((item) => item?.name).filter((name) => typeof name === "string")) : null;
  } catch { return null; }
}
