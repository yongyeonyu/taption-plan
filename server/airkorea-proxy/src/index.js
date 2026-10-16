// Taption Plan air quality relay. Keeps the data.go.kr service key on the server
// and caches answers per station, so upstream traffic scales with stations, not users.
// It never reads or stores client identifiers: no logging of IPs, no cookies, no body.

const UPSTREAM = "https://apis.data.go.kr/B552584";
const STATION_NAME = /^[\p{L}\p{N} ()·.\-]{1,40}$/u;
const TTL_SECONDS = { stations: 24 * 60 * 60, measurement: 30 * 60 };

function json(body, status, cacheSeconds) {
  return new Response(body, {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": cacheSeconds ? `public, max-age=${cacheSeconds}` : "no-store",
    },
  });
}

function problem(status, code) {
  return json(JSON.stringify({ error: code }), status, 0);
}

// data.go.kr answers 200 with an error body when the key or quota is wrong, so only
// cache payloads whose header says success.
export function isSuccessfulPayload(text) {
  try {
    const header = JSON.parse(text)?.response?.header;
    return header?.resultCode === "00" && Array.isArray(JSON.parse(text)?.response?.body?.items);
  } catch {
    return false;
  }
}

export function upstreamURL(route, stationName, serviceKey) {
  const url = new URL(
    route === "stations"
      ? `${UPSTREAM}/MsrstnInfoInqireSvc/getMsrstnList`
      : `${UPSTREAM}/ArpltnInforInqireSvc/getMsrstnAcctoRltmMesureDnsty`
  );
  url.searchParams.set("serviceKey", serviceKey);
  url.searchParams.set("returnType", "json");
  url.searchParams.set("pageNo", "1");
  if (route === "stations") {
    url.searchParams.set("numOfRows", "1000");
  } else {
    url.searchParams.set("numOfRows", "1");
    url.searchParams.set("stationName", stationName);
    url.searchParams.set("dataTerm", "DAILY");
    url.searchParams.set("ver", "1.3");
  }
  return url;
}

export async function handle(request, env, cache = globalThis.caches?.default, fetchImpl = fetch) {
  if (request.method !== "GET") return problem(405, "method_not_allowed");
  const url = new URL(request.url);
  let route;
  let stationName = "";
  if (url.pathname === "/airkorea/stations" && [...url.searchParams].length === 0) {
    route = "stations";
  } else if (url.pathname === "/airkorea/measurement") {
    const names = url.searchParams.getAll("stationName");
    if (names.length !== 1 || [...url.searchParams].length !== 1 || !STATION_NAME.test(names[0])) {
      return problem(400, "invalid_station");
    }
    route = "measurement";
    stationName = names[0];
  } else {
    return problem(404, "not_found");
  }
  if (!env.AIRKOREA_SERVICE_KEY) return problem(503, "not_configured");

  // Normalised cache key: the same station always maps to one entry.
  const cacheKey = new Request(
    `${url.origin}/airkorea/${route}${route === "measurement" ? `?stationName=${encodeURIComponent(stationName)}` : ""}`
  );
  const hit = cache ? await cache.match(cacheKey) : undefined;
  if (hit) return hit;

  let upstream;
  try {
    upstream = await fetchImpl(upstreamURL(route, stationName, env.AIRKOREA_SERVICE_KEY).toString(), {
      headers: { accept: "application/json" },
    });
  } catch {
    return problem(502, "upstream_unreachable");
  }
  const text = await upstream.text();
  if (!upstream.ok || !isSuccessfulPayload(text)) return problem(502, "upstream_error");

  const response = json(text, 200, TTL_SECONDS[route]);
  if (cache) await cache.put(cacheKey, response.clone());
  return response;
}

export default {
  fetch(request, env, ctx) {
    const cache = globalThis.caches?.default;
    return handle(request, env, cache);
  },
};
