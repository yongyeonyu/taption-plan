// MSC1119B02: 서버에 쌓인 오분류 교정 표본을 Mac에서 내려받아 집계하고, 분류 규칙을 고칠 후보를 요약한다.
//
//   CLASSIFIER_ADMIN_TOKEN=… node scripts/classifier-report.mjs --host <중계 서버 주소> [--rule-version classifier-v1r4] [--min-count 5] [--json] [--save samples.json]
//   node scripts/classifier-report.mjs --token-file <파일> --host <주소>      # 토큰을 파일에서(셸 기록에 안 남김)
//   node scripts/classifier-report.mjs --input samples.json                   # 내려받아 둔 표본으로 다시 집계(서버를 부르지 않음)
//
// - 읽는 길은 `GET /classifier-samples/admin`(운영자 토큰 `CLASSIFIER_ADMIN_TOKEN`, 서버 README 「오분류 교정 표본」). 토큰은 환경변수 또는 `--token-file`로만 받고
//   인자·로그·보고서에 쓰지 않는다. 서버 주소도 인자로 받을 뿐 코드에 두지 않는다.
// - 표본에는 좌표·날짜·이름이 없다(서버가 허용 목록으로 거른다). 보고서에는 건수·중앙값·비율만 담는다.
// - `--save`는 받은 원본을 파일로 남긴다(표본 자체이므로 저장소 밖에 둘 것). 아무것도 서버에 쓰지 않는다.
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const PAGE = 500;
const MAX_PAGES = 400; // 200,000건. 무한 반복 방지.

export function parseArgs(argv, env = {}) {
  const options = { host: env.TRIP_RELAY_HOST ?? null, token: env.CLASSIFIER_ADMIN_TOKEN ?? null, minCount: 5, ruleVersion: null, json: false, input: null, save: null, tokenFile: null };
  const takes = new Set(["--host", "--token-file", "--rule-version", "--min-count", "--input", "--save"]);
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i];
    if (flag === "--json") { options.json = true; continue; }
    if (!takes.has(flag)) throw new Error(`모르는 인자: ${flag}`);
    const value = argv[++i];
    if (value === undefined || value.startsWith("--")) throw new Error(`${flag} 값이 없습니다`);
    if (flag === "--host") options.host = value;
    else if (flag === "--token-file") options.tokenFile = value;
    else if (flag === "--rule-version") options.ruleVersion = value;
    else if (flag === "--min-count") {
      options.minCount = Number(value);
      if (!Number.isInteger(options.minCount) || options.minCount < 1) throw new Error("--min-count는 1 이상의 정수");
    } else if (flag === "--input") options.input = value;
    else options.save = value;
  }
  return options;
}

/** 서버 페이지를 처음부터 끝까지 읽는다. `fetchImpl`은 시험용 바꿔치기. */
export async function fetchAll({ host, token, fetchImpl = fetch }) {
  const samples = [];
  let since = 0;
  for (let page = 0; page < MAX_PAGES; page++) {
    const response = await fetchImpl(`https://${host}/classifier-samples/admin?since=${since}&limit=${PAGE}`, { headers: { authorization: `Bearer ${token}` } });
    if (response.status === 401) throw new Error("운영자 토큰이 맞지 않습니다(401)");
    if (response.status === 503) throw new Error("서버에 CLASSIFIER_ADMIN_TOKEN 또는 D1이 없습니다(503) — 서버 README 「배포」를 확인하세요");
    if (!response.ok) throw new Error(`서버 응답 ${response.status}`);
    const body = await response.json();
    if (!Array.isArray(body.samples)) throw new Error("응답 형식이 다릅니다");
    samples.push(...body.samples);
    if (body.samples.length < PAGE || !Number.isInteger(body.next) || body.next <= since) return samples;
    since = body.next;
  }
  return samples;
}

const median = (values) => {
  const sorted = values.filter((v) => typeof v === "number").sort((a, b) => a - b);
  if (!sorted.length) return null;
  const mid = sorted.length >> 1;
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
};
const share = (part, whole) => (whole ? part / whole : 0);
const pct = (ratio) => `${Math.round(ratio * 100)}%`;
const BANDS = [["새벽(0~6시)", 0, 360], ["오전(6~12시)", 360, 720], ["오후(12~18시)", 720, 1080], ["저녁·밤(18~24시)", 1080, 1440]];
const bandOf = (minute) => BANDS.find(([, low, high]) => minute >= low && minute < high)[0];
const topOf = (values) => {
  const counts = new Map();
  for (const v of values) if (v != null) counts.set(v, (counts.get(v) ?? 0) + 1);
  const [value, n] = [...counts.entries()].sort((a, b) => b[1] - a[1] || String(a[0]).localeCompare(String(b[0])))[0] ?? [null, 0];
  return { value, share: share(n, values.length) };
};
const clock = (minute) => (minute == null ? "-" : `${String(Math.floor(minute / 60)).padStart(2, "0")}:${String(Math.round(minute % 60)).padStart(2, "0")}`);

/** 표본 배열 → 집계. 순수 함수. */
export function analyze(samples, { minCount = 5, ruleVersion = null } = {}) {
  const used = ruleVersion ? samples.filter((s) => s.ruleVersion === ruleVersion) : samples;
  const byRule = {};
  for (const s of samples) byRule[s.ruleVersion] = (byRule[s.ruleVersion] ?? 0) + 1;
  const predictedTotals = new Map();
  const groups = new Map();
  for (const s of used) {
    predictedTotals.set(`${s.kind}|${s.predicted}`, (predictedTotals.get(`${s.kind}|${s.predicted}`) ?? 0) + 1);
    const key = `${s.kind}|${s.predicted}|${s.corrected}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(s);
  }
  const pairs = [...groups.entries()].map(([key, rows]) => {
    const [kind, predicted, corrected] = key.split("|");
    const f = rows.map((r) => r.features);
    const weekend = rows.filter((r) => r.weekdayIndex === 0 || r.weekdayIndex === 6).length;
    const band = topOf(rows.map((r) => bandOf(r.minuteOfDay)));
    const motion = topOf(f.map((x) => x.dominantMotion));
    const confidence = topOf(rows.map((r) => r.predictedConfidence));
    const pair = {
      kind, predicted, corrected, count: rows.length,
      shareOfPredicted: share(rows.length, predictedTotals.get(`${kind}|${predicted}`)),
      customShare: share(rows.filter((r) => r.correctedIsCustom).length, rows.length),
      highConfidenceShare: share(rows.filter((r) => r.predictedConfidence === "high").length, rows.length),
      topDetail: topOf(rows.map((r) => r.correctedDetail)),
      topBand: band, topMotion: motion, topConfidence: confidence, weekendShare: share(weekend, rows.length),
      medianMinuteOfDay: median(rows.map((r) => r.minuteOfDay)), medianDurationMinutes: (median(rows.map((r) => r.durationSeconds)) ?? 0) / 60,
      medianSpeedKmh: median(f.map((x) => x.averageSpeedKmh)), medianMaxSpeedKmh: median(f.map((x) => x.maximumSpeedKmh)), medianDistanceMeters: median(f.map((x) => x.distanceMeters)),
      medianCadence: median(f.map((x) => x.stepCadencePerMinute)), medianAccuracy: median(f.map((x) => x.gpsAccuracyMeters)),
      noSensorShare: share(f.filter((x) => x.sampleCount === 0).length, rows.length), watchShare: share(f.filter((x) => x.watchCovered).length, rows.length),
    };
    return { ...pair, hints: hints(pair) };
  }).sort((a, b) => b.count - a.count || `${a.predicted}${a.corrected}`.localeCompare(`${b.predicted}${b.corrected}`));
  const candidates = pairs.filter((p) => p.count >= minCount);
  return {
    total: samples.length, used: used.length, ruleVersion, byRule, minCount,
    byKind: { activity: used.filter((s) => s.kind === "activity").length, travel: used.filter((s) => s.kind === "travel").length },
    byConfidence: Object.fromEntries(["low", "medium", "high", null].map((c) => [String(c), used.filter((s) => s.predictedConfidence === c).length])),
    pairs, candidates, skippedPairs: pairs.length - candidates.length,
  };
}

/** 한 쌍의 모양에서 규칙 후보 문장을 만든다. 문장은 사람이 읽고 판단할 초안이다. */
function hints(p) {
  const out = [];
  if (p.predicted === "unconfirmed") out.push(`분류 못 한 구간을 사용자가 「${p.corrected}」로 채움 — 이 모양(${pct(p.topMotion.share)} ${p.topMotion.value ?? "움직임 정보 없음"}, ${clock(p.medianMinuteOfDay)} 무렵)이면 자동 분류로 올릴 후보`);
  if (p.customShare >= 0.5) out.push(`사용자가 직접 만든 분류가 ${pct(p.customShare)} — 분류표에 없는 이름이 반복됨, 새 상세 분류 후보`);
  if (p.highConfidenceShare >= 0.5) out.push(`확신도 high 였는데 틀린 비율 ${pct(p.highConfidenceShare)} — 점수·확신도 구간 재보정 후보`);
  if (p.kind === "travel") {
    if (p.medianSpeedKmh != null) out.push(`이동수단 판별: 평균 속도 중앙값 ${p.medianSpeedKmh}km/h, 최고 ${p.medianMaxSpeedKmh ?? "-"}km/h, 거리 ${p.medianDistanceMeters ?? "-"}m — 「${p.predicted}」/「${p.corrected}」 경계 속도 점검`);
    if (p.noSensorShare >= 0.3) out.push(`센서 원본 없는 표본 ${pct(p.noSensorShare)} — 규칙보다 수집 공백 문제일 수 있음`);
  } else {
    if (p.topBand.share >= 0.6) out.push(`${p.topBand.value}에 ${pct(p.topBand.share)} 몰림 — 시간대 가중 후보`);
    if (p.weekendShare >= 0.7 || p.weekendShare <= 0.1) out.push(p.weekendShare >= 0.7 ? `주말에 ${pct(p.weekendShare)} 몰림 — 요일 가중 후보` : "평일에만 나타남 — 요일 가중 후보");
    if (p.topMotion.share >= 0.7 && p.topMotion.value) out.push(`움직임 「${p.topMotion.value}」 ${pct(p.topMotion.share)} — 움직임과 분류 연결 점검`);
    if (p.medianDurationMinutes >= 90) out.push(`긴 구간(중앙값 ${Math.round(p.medianDurationMinutes)}분) — 구간 쪼개기 점검`);
  }
  if (p.topDetail.value && p.topDetail.share >= 0.5) out.push(`상세는 「${p.topDetail.value}」가 ${pct(p.topDetail.share)}`);
  return out;
}

export function render(report) {
  const lines = ["# 오분류 교정 표본 보고", ""];
  lines.push(`- 표본 ${report.total}건${report.ruleVersion ? ` 중 규칙 ${report.ruleVersion} ${report.used}건` : ""} · 활동 ${report.byKind.activity} · 이동 ${report.byKind.travel}`);
  lines.push(`- 규칙 판별 건수: ${Object.entries(report.byRule).map(([v, n]) => `${v} ${n}`).join(", ") || "-"}`);
  lines.push(`- 자동 분류 확신도: ${Object.entries(report.byConfidence).map(([k, v]) => `${k === "null" ? "없음" : k} ${v}`).join(" · ")}`);
  lines.push(`- 후보 기준: 같은 「자동 → 사용자」 쌍이 ${report.minCount}건 이상 (${report.candidates.length}쌍, 건수 부족 ${report.skippedPairs}쌍 제외)`, "");
  if (!report.candidates.length) lines.push("규칙 후보가 될 만큼 반복된 교정이 아직 없습니다.");
  report.candidates.forEach((p, index) => {
    lines.push(`## ${index + 1}. ${p.kind === "travel" ? "이동" : "활동"} ${p.predicted} → ${p.corrected} (${p.count}건, 「${p.predicted}」 교정의 ${pct(p.shareOfPredicted)})`);
    for (const hint of p.hints) lines.push(`- ${hint}`);
    if (!p.hints.length) lines.push("- 뚜렷한 쏠림 없음 — 건수가 더 쌓이면 다시 보기");
    lines.push("");
  });
  lines.push("표본은 비식별이며, 위 문장은 규칙을 고칠 초안입니다. 고친 규칙은 `ClassificationRules.version`을 올려 다음 표본과 구분하세요.");
  return lines.join("\n");
}

async function main() {
  const options = parseArgs(process.argv.slice(2), process.env);
  let samples;
  if (options.input) {
    const raw = JSON.parse(readFileSync(options.input, "utf8"));
    samples = Array.isArray(raw) ? raw : raw.samples;
    if (!Array.isArray(samples)) throw new Error("--input 파일에 표본 배열이 없습니다");
  } else {
    const token = options.tokenFile ? readFileSync(options.tokenFile, "utf8").trim() : options.token;
    if (!options.host) throw new Error("--host(또는 TRIP_RELAY_HOST)가 필요합니다");
    if (!token) throw new Error("CLASSIFIER_ADMIN_TOKEN 환경변수 또는 --token-file이 필요합니다");
    samples = await fetchAll({ host: options.host, token });
    if (options.save) writeFileSync(options.save, JSON.stringify({ format: "bokki-misclassification", version: 1, samples }), { mode: 0o600 });
  }
  const report = analyze(samples, options);
  console.log(options.json ? JSON.stringify(report, null, 2) : render(report));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => { console.error(`오류: ${error.message}`); process.exit(1); });
}
