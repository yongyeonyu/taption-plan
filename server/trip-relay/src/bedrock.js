// AWS Bedrock Runtime `Converse` 직접 호출(AI1121A01). 무거운 SDK 없이 Web Crypto로 SigV4 서명만 한다.
// 비밀값은 Worker 비밀 `AWS_ACCESS_KEY_ID`·`AWS_SECRET_ACCESS_KEY`(+선택 `AWS_SESSION_TOKEN`), 지역 `AWS_REGION`, 모델 `AWS_BEDROCK_MODEL_ID`.
// 키·서명·상류 응답 본문은 기록하지도, 돌려주지도 않는다. 실패는 상태 코드와 짧은 이름만 남긴다.

export const DEFAULT_REGION = "us-east-1";
// 가성비 기본값. 대표가 `AWS_BEDROCK_MODEL_ID`로 바꾼다(예: Haiku 추론 프로필 ID).
export const DEFAULT_MODEL_ID = "us.amazon.nova-lite-v1:0";
const REGION = /^[a-z]{2}(-[a-z]+)+-\d$/;
const MODEL_ID = /^[A-Za-z0-9._:/-]{1,200}$/;

const encoder = new TextEncoder();
const hex = (buffer) => [...new Uint8Array(buffer)].map((b) => b.toString(16).padStart(2, "0")).join("");
export const sha256Hex = async (data) => hex(await crypto.subtle.digest("SHA-256", typeof data === "string" ? encoder.encode(data) : data));
async function hmac(key, data) {
  const imported = await crypto.subtle.importKey("raw", typeof key === "string" ? encoder.encode(key) : key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return crypto.subtle.sign("HMAC", imported, encoder.encode(data));
}

// RFC 3986: 영숫자와 - _ . ~ 만 그대로 둔다.
const rfc3986 = (value) => encodeURIComponent(value).replace(/[!'()*]/g, (c) => "%" + c.charCodeAt(0).toString(16).toUpperCase());

// S3가 아닌 서비스는 이미 인코딩된 경로의 조각을 한 번 더 인코딩한다(모델 ID의 `:`는 요청에 %3A, 서명에 %253A).
export function canonicalUri(pathname) {
  if (!pathname || pathname === "/") return "/";
  return pathname.split("/").map(rfc3986).join("/");
}

function canonicalQuery(searchParams) {
  return [...searchParams].map(([k, v]) => [rfc3986(k), rfc3986(v)])
    .sort(([a, x], [b, y]) => (a < b ? -1 : a > b ? 1 : x < y ? -1 : x > y ? 1 : 0))
    .map(([k, v]) => `${k}=${v}`).join("&");
}

/**
 * SigV4 서명 머리를 만든다. `headers`에는 서명할 머리(host 제외)를 넣고, 돌려받은 머리를 그대로 보낸다.
 * now는 시험용(밀리초). 비밀 키는 서명 계산에만 쓰고 결과에 넣지 않는다.
 */
export async function signRequest({ method, url, headers = {}, body = "", region, service, accessKeyId, secretAccessKey, sessionToken, now = Date.now() }) {
  const target = new URL(url);
  const amzDate = new Date(now).toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
  const day = amzDate.slice(0, 8);
  const all = { ...Object.fromEntries(Object.entries(headers).map(([k, v]) => [k.toLowerCase(), String(v)])), host: target.host, "x-amz-date": amzDate };
  if (sessionToken) all["x-amz-security-token"] = sessionToken;
  const names = Object.keys(all).sort();
  const canonicalHeaders = names.map((name) => `${name}:${all[name].trim().replace(/\s+/g, " ")}\n`).join("");
  const signedHeaders = names.join(";");
  const payloadHash = await sha256Hex(body);
  const canonical = [method.toUpperCase(), canonicalUri(target.pathname), canonicalQuery(target.searchParams), canonicalHeaders, signedHeaders, payloadHash].join("\n");
  const scope = `${day}/${region}/${service}/aws4_request`;
  const toSign = ["AWS4-HMAC-SHA256", amzDate, scope, await sha256Hex(canonical)].join("\n");
  let key = await hmac("AWS4" + secretAccessKey, day);
  for (const part of [region, service, "aws4_request"]) key = await hmac(key, part);
  const signature = hex(await hmac(key, toSign));
  const out = { ...all, authorization: `AWS4-HMAC-SHA256 Credential=${accessKeyId}/${scope}, SignedHeaders=${signedHeaders}, Signature=${signature}` };
  delete out.host; // fetch가 주소에서 넣는다.
  return out;
}

/** 비밀값이 다 있고 모양이 맞으면 설정, 아니면 null. 값 자체는 어디에도 내보내지 않는다. */
export function bedrockConfig(env) {
  const accessKeyId = env.AWS_ACCESS_KEY_ID?.trim(), secretAccessKey = env.AWS_SECRET_ACCESS_KEY?.trim();
  const region = env.AWS_REGION?.trim() || DEFAULT_REGION;
  const modelId = env.AWS_BEDROCK_MODEL_ID?.trim() || DEFAULT_MODEL_ID;
  if (!accessKeyId || !secretAccessKey || !REGION.test(region) || !MODEL_ID.test(modelId)) return null;
  return { accessKeyId, secretAccessKey, sessionToken: env.AWS_SESSION_TOKEN?.trim() || undefined, region, modelId };
}

export const converseUrl = (config) => `https://bedrock-runtime.${config.region}.amazonaws.com/model/${encodeURIComponent(config.modelId)}/converse`;

/**
 * Converse 한 번. request는 Converse 본문({ messages, system, inferenceConfig, toolConfig }).
 * 돌려주는 값: { ok: true, output } 또는 { ok: false, status, error }. 상류 본문은 버린다.
 */
export async function converse(config, request, { fetcher = fetch, now = Date.now(), timeoutMs = 25_000 } = {}) {
  const url = converseUrl(config);
  const body = JSON.stringify(request);
  const headers = await signRequest({
    method: "POST", url, body, region: config.region, service: "bedrock", now,
    accessKeyId: config.accessKeyId, secretAccessKey: config.secretAccessKey, sessionToken: config.sessionToken,
    headers: { "content-type": "application/json", accept: "application/json" },
  });
  let response;
  try {
    response = await fetcher(url, { method: "POST", headers, body, signal: AbortSignal.timeout?.(timeoutMs) });
  } catch {
    return { ok: false, status: 502, error: "upstream_failed" };
  }
  if (!response.ok) {
    try { await response.body?.cancel(); } catch { /* 본문은 읽지 않는다 */ }
    if (response.status === 429) return { ok: false, status: 429, error: "upstream_throttled" };
    if (response.status === 403 || response.status === 401) return { ok: false, status: 502, error: "upstream_denied" };
    return { ok: false, status: 502, error: "upstream", upstreamStatus: response.status };
  }
  try {
    return { ok: true, output: await response.json() };
  } catch {
    return { ok: false, status: 502, error: "upstream_bad_json" };
  }
}

/** Converse 응답에서 도구 입력(있으면)과 글, 사용량을 꺼낸다. */
export function readOutput(output) {
  const content = Array.isArray(output?.output?.message?.content) ? output.output.message.content : [];
  const tool = content.find((block) => block?.toolUse && typeof block.toolUse.input === "object" && block.toolUse.input !== null)?.toolUse ?? null;
  const text = content.map((block) => (typeof block?.text === "string" ? block.text : "")).join("").trim();
  const usage = output?.usage ?? {};
  const count = (v) => (Number.isFinite(v) && v >= 0 ? Math.round(v) : 0);
  return { tool, text, stopReason: typeof output?.stopReason === "string" ? output.stopReason : "", usage: { inputTokens: count(usage.inputTokens), outputTokens: count(usage.outputTokens) } };
}
