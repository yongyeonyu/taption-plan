// Taption Plan trip relay (TRP1110A04). An AI assistant POSTs a trip JSON with the user's key;
// the app GETs it on launch, shows a preview, then DELETEs it. Only a SHA-256 hash of the key is
// stored, plans expire after 3 days, and nothing else about the user is kept or logged.

const MAX_BODY_BYTES = 64 * 1024;
const TTL_SECONDS = 3 * 24 * 60 * 60;
const KEY_PATTERN = /^[A-Za-z0-9_-]{43}$/; // 32 random bytes, base64url without padding

function json(body, status) {
  return new Response(body === null ? null : JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });
}

export async function storageKey(token) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token));
  return "plan:" + [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function bearer(request) {
  const match = /^Bearer (.+)$/.exec(request.headers.get("authorization") ?? "");
  return match && KEY_PATTERN.test(match[1]) ? match[1] : null;
}

// Same contract the app reads: format "bokki-trip", version 1, a tripId and at least one item.
export function isTripPlan(value) {
  return value?.format === "bokki-trip" && value?.version === 1 && typeof value?.tripId === "string"
    && typeof value?.title === "string" && Array.isArray(value?.items) && value.items.length > 0
    && value.items.length <= 500;
}

export async function handle(request, env) {
  const url = new URL(request.url);
  if (url.pathname !== "/plan") return json({ error: "not_found" }, 404);
  const token = bearer(request);
  if (!token) return json({ error: "unauthorized" }, 401);
  const key = await storageKey(token);

  switch (request.method) {
    case "POST": {
      const length = Number(request.headers.get("content-length") ?? 0);
      if (length > MAX_BODY_BYTES) return json({ error: "too_large" }, 413);
      const text = await request.text();
      if (new TextEncoder().encode(text).length > MAX_BODY_BYTES) return json({ error: "too_large" }, 413);
      let plan;
      try { plan = JSON.parse(text); } catch { return json({ error: "invalid_json" }, 400); }
      if (!isTripPlan(plan)) return json({ error: "not_trip_plan" }, 422);
      await env.PLANS.put(key, JSON.stringify(plan), { expirationTtl: TTL_SECONDS });
      return json({ ok: true, tripId: plan.tripId, expiresInSeconds: TTL_SECONDS }, 201);
    }
    case "GET": {
      const stored = await env.PLANS.get(key);
      return stored ? new Response(stored, { status: 200, headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" } }) : json(null, 204);
    }
    case "DELETE":
      await env.PLANS.delete(key);
      return json(null, 204);
    default:
      return json({ error: "method_not_allowed" }, 405);
  }
}

export default {
  fetch(request, env) {
    return handle(request, env);
  },
};
