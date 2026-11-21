// 도시 팩 검색 색인(SRCH1121A01, ARCH1120A01 10절 1순위). Algolia는 검색용 파생 색인일 뿐이고 정본은 R2 팩이다.
// - 쓰기 키(ALGOLIA_WRITE_KEY)는 Worker 비밀값에만 둔다. 앱에는 주지 않는다. 이 파일은 키 원문을 로그·오류·응답에 쓰지 않는다.
// - 앱에는 ALGOLIA_SEARCH_KEY(검색 전용 키)에서 만든 Secured API Key만 준다: `filters=city:… AND version:…`과 validUntil이 걸려 있다.
//   검색 키가 없으면 쓰기 키로 대신하지 않고 503을 준다.
// - 색인에는 팩 항목의 검색용 필드만 보낸다(address·phone·note·좌표 외 개인 값 없음). 사용자 현재 좌표는 받지도 보내지도 않는다(geo-search 금지).
import { json } from "./http.js";

export const INDEX_NAME = "trip_packs_v1";
const BATCH_SIZE = 500;
const KEY_TTL_SECONDS = 3_600;
const MAX_KEY_TTL_SECONDS = 86_400;
export const DEFAULT_KEY_DAILY = 3_000;
const APP_ID = /^[A-Za-z0-9]{6,24}$/;
const CITY = /^[a-z0-9][a-z0-9-]{0,39}$/;
const MAX_ITEMS = 5_000;

export const keyDailyBudget = (env) => {
  const value = Number(env.ALGOLIA_KEY_DAILY);
  return Number.isInteger(value) && value > 0 ? value : DEFAULT_KEY_DAILY;
};

/** 앱 ID가 모양에 맞고 쓰기 키가 있어야 색인할 수 있다. */
export function writeConfig(env) {
  const appId = String(env.ALGOLIA_APP_ID ?? "").trim();
  const key = String(env.ALGOLIA_WRITE_KEY ?? "").trim();
  return APP_ID.test(appId) && key ? { appId, key } : null;
}

/** 앱에 내려줄 검색 전용 키(부모). */
export function searchConfig(env) {
  const appId = String(env.ALGOLIA_APP_ID ?? "").trim();
  const key = String(env.ALGOLIA_SEARCH_KEY ?? "").trim();
  return APP_ID.test(appId) && key ? { appId, key } : null;
}

export const validCity = (city) => typeof city === "string" && CITY.test(city);
export const validVersion = (version) => Number.isInteger(version) && version >= 1 && version <= 1_000_000;

const text = (value, max) => (typeof value === "string" && value.trim() ? value.trim().slice(0, max) : undefined);

/** 팩 항목 하나를 색인 레코드로. address·phone·note·checkedBy·sourceURL은 넣지 않는다. */
export function record(city, version, item) {
  if (!item || typeof item.id !== "string" || !item.id) return undefined;
  if (!Number.isFinite(item.lat) || !Number.isFinite(item.lng)) return undefined;
  const out = {
    objectID: `${city}:${version}:${item.id}`,
    city, version,
    name: text(item.name, 200) ?? "",
    nameKo: text(item.nameKo, 200) ?? "",
    category: text(item.category, 40) ?? "",
    area: text(item.area, 100) ?? "",
    tags: Array.isArray(item.tags) ? item.tags.filter((tag) => typeof tag === "string" && tag).slice(0, 12).map((tag) => tag.slice(0, 40)) : [],
    lat: item.lat, lng: item.lng,
    source: text(item.source, 40) ?? "",
    checkedAt: text(item.checkedAt, 10) ?? "",
  };
  for (const key of ["hours", "priceHint", "photo"]) {
    const value = text(item[key], key === "photo" ? 500 : 200);
    if (value) out[key] = value;
  }
  return out.name || out.nameKo ? out : undefined;
}

export function records(pack) {
  if (!pack || pack.format !== "bokki-trip-pack" || !validCity(pack.city) || !validVersion(pack.version) || !Array.isArray(pack.items)) return undefined;
  if (pack.items.length > MAX_ITEMS) return undefined;
  return pack.items.map((item) => record(pack.city, pack.version, item)).filter(Boolean);
}

/** 인덱스 설정: 다국어 동의어·오타 보정은 여기(서버)에만 둔다. 앱 코드에 사전을 박지 않는다. */
export const SETTINGS = {
  searchableAttributes: ["unordered(nameKo)", "unordered(name)", "tags", "area", "category"],
  attributesForFaceting: ["filterOnly(city)", "filterOnly(version)", "category", "tags"],
  attributesToRetrieve: ["objectID", "name", "nameKo", "category", "area", "tags", "hours", "priceHint", "lat", "lng", "source", "checkedAt", "photo", "city", "version"],
  queryLanguages: ["ko", "ja", "en"],
  indexLanguages: ["ko", "ja", "en"],
  typoTolerance: true,
  ignorePlurals: true,
  removeStopWords: false,
  hitsPerPage: 20,
  paginationLimitedTo: 100,
};

export const SYNONYMS = [
  { objectID: "ramen", type: "synonym", synonyms: ["ラーメン", "라멘", "라면집", "ramen"] },
  { objectID: "sushi", type: "synonym", synonyms: ["寿司", "스시", "초밥", "sushi"] },
  { objectID: "udon", type: "synonym", synonyms: ["うどん", "우동", "udon"] },
  { objectID: "izakaya", type: "synonym", synonyms: ["居酒屋", "이자카야", "izakaya"] },
  { objectID: "cafe", type: "synonym", synonyms: ["カフェ", "喫茶", "카페", "커피", "cafe", "coffee"] },
  { objectID: "onsen", type: "synonym", synonyms: ["温泉", "온천", "onsen", "hot spring"] },
  { objectID: "shrine", type: "synonym", synonyms: ["神社", "신사", "shrine"] },
  { objectID: "temple", type: "synonym", synonyms: ["寺", "절", "사찰", "temple"] },
  { objectID: "park", type: "synonym", synonyms: ["公園", "공원", "park"] },
  { objectID: "pharmacy", type: "synonym", synonyms: ["薬局", "약국", "pharmacy", "drugstore"] },
  { objectID: "hospital", type: "synonym", synonyms: ["病院", "병원", "hospital", "clinic"] },
  { objectID: "hotel", type: "synonym", synonyms: ["ホテル", "호텔", "숙소", "hotel", "inn"] },
  { objectID: "restaurant", type: "synonym", synonyms: ["レストラン", "食堂", "식당", "맛집", "restaurant"] },
  { objectID: "station", type: "synonym", synonyms: ["駅", "역", "station"] },
];

class AlgoliaError extends Error {
  constructor(status) { super(`algolia_${status}`); this.status = status; }
}

async function call(config, fetcher, method, path, body) {
  const response = await fetcher(`https://${config.appId}.algolia.net${path}`, {
    method,
    headers: { "x-algolia-application-id": config.appId, "x-algolia-api-key": config.key, "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!response.ok) throw new AlgoliaError(response.status); // 응답 본문(키가 섞일 수 있음)은 읽지도 돌려주지도 않는다
  return response.json().catch(() => ({}));
}

const chunks = (list, size) => Array.from({ length: Math.ceil(list.length / size) }, (_, i) => list.slice(i * size, (i + 1) * size));

/** 새 버전을 색인한 뒤 같은 도시의 이전 버전만 지운다(`version < N`). 다른 도시는 건드리지 않는다. */
export async function indexPack(config, fetcher, pack) {
  const list = records(pack);
  if (!list) return { ok: false, error: "bad_pack" };
  const index = encodeURIComponent(INDEX_NAME);
  try {
    for (const part of chunks(list, BATCH_SIZE)) {
      await call(config, fetcher, "POST", `/1/indexes/${index}/batch`, { requests: part.map((body) => ({ action: "updateObject", body })) });
    }
    await call(config, fetcher, "POST", `/1/indexes/${index}/deleteByQuery`, {
      facetFilters: [`city:${pack.city}`], numericFilters: [`version<${pack.version}`],
    });
  } catch (error) {
    return { ok: false, error: "algolia_failed", status: error instanceof AlgoliaError ? error.status : 502 };
  }
  return { ok: true, indexed: list.length, city: pack.city, version: pack.version };
}

/** 팩이 없어진 도시의 레코드를 전부 지운다. */
export async function removeCity(config, fetcher, city) {
  if (!validCity(city)) return { ok: false, error: "bad_city" };
  try {
    await call(config, fetcher, "POST", `/1/indexes/${encodeURIComponent(INDEX_NAME)}/deleteByQuery`, { facetFilters: [`city:${city}`] });
  } catch (error) {
    return { ok: false, error: "algolia_failed", status: error instanceof AlgoliaError ? error.status : 502 };
  }
  return { ok: true, city };
}

export async function applySettings(config, fetcher) {
  const index = encodeURIComponent(INDEX_NAME);
  try {
    await call(config, fetcher, "PUT", `/1/indexes/${index}/settings`, SETTINGS);
    await call(config, fetcher, "POST", `/1/indexes/${index}/synonyms/batch?replaceExistingSynonyms=true`, SYNONYMS);
  } catch (error) {
    return { ok: false, error: "algolia_failed", status: error instanceof AlgoliaError ? error.status : 502 };
  }
  return { ok: true, synonyms: SYNONYMS.length };
}

const toHex = (buffer) => [...new Uint8Array(buffer)].map((byte) => byte.toString(16).padStart(2, "0")).join("");

/** Secured API Key: base64(HMAC-SHA256(부모 키, 조건) 16진수 + 조건). 조건에 도시·버전·만료·색인 제한을 건다. */
export async function securedKey(parentKey, { city, version, validUntil }) {
  const params = new URLSearchParams({
    filters: `city:"${city}" AND version:${version}`,
    validUntil: String(validUntil),
    restrictIndices: INDEX_NAME,
    hitsPerPage: "20",
  }).toString();
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(parentKey), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = toHex(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(params)));
  return btoa(mac + params);
}

/** GET /search/packs/key?city=&version= — 앱에 검색용 Secured Key를 준다. 호출 수는 서버 전체 하루 예산(charge)으로 센다. */
export async function keyRoute(request, env, now, charge) {
  const config = searchConfig(env);
  if (!config) return json({ error: "algolia_key_missing" }, 503);
  const url = new URL(request.url);
  const city = url.searchParams.get("city") ?? "";
  const version = Number(url.searchParams.get("version"));
  if (!validCity(city) || !validVersion(version)) return json({ error: "bad_request" }, 400);
  const counted = await charge();
  if (!counted.ok) {
    const retryAfter = counted.retryAfter ?? 3_600;
    return json({ error: "algolia_key_daily_limit", retryAfter }, 429, { "retry-after": String(retryAfter) });
  }
  const ttl = Math.min(KEY_TTL_SECONDS, MAX_KEY_TTL_SECONDS);
  const validUntil = Math.floor(now / 1000) + ttl;
  return json({ appId: config.appId, index: INDEX_NAME, key: await securedKey(config.key, { city, version, validUntil }), validUntil, ttl }, 200);
}

/** POST /search/packs/index {city, version} — R2의 팩(packs/trip/<city>/<version>/items.json)을 읽어 색인한다. 앱 주인 키만. */
export async function indexRoute(request, env, fetcher) {
  const config = writeConfig(env);
  if (!config) return json({ error: "algolia_not_configured" }, 503);
  if (!env.PUBLIC_BUCKET) return json({ error: "r2_missing" }, 503);
  const body = await request.json().catch(() => null);
  if (!body || !validCity(body.city) || !validVersion(body.version)) return json({ error: "bad_request" }, 400);
  const object = await env.PUBLIC_BUCKET.get(`packs/trip/${body.city}/${body.version}/items.json`);
  if (!object) return json({ error: "pack_not_found" }, 404);
  let pack;
  try { pack = JSON.parse(await object.text()); } catch { return json({ error: "bad_pack" }, 422); }
  if (pack?.city !== body.city || pack?.version !== body.version) return json({ error: "bad_pack" }, 422);
  const result = await indexPack(config, fetcher, pack);
  return result.ok ? json(result, 200) : json({ error: result.error, status: result.status }, result.error === "bad_pack" ? 422 : 502);
}

/** POST /search/packs/settings — 색인 설정과 동의어를 적용한다. 앱 주인 키만. */
export async function settingsRoute(env, fetcher) {
  const config = writeConfig(env);
  if (!config) return json({ error: "algolia_not_configured" }, 503);
  const result = await applySettings(config, fetcher);
  return result.ok ? json(result, 200) : json({ error: result.error, status: result.status }, 502);
}
