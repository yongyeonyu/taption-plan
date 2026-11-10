// LED1110A01: 가계부 원화 환산용 공개 환율. 하루 한 번 Frankfurter(유럽중앙은행 기준, 키 없음)에서 받아
// 전역 KV에 그날 하나만 둔다. 공개 자료라 암호화하지 않는다. 받지 못하면 전날 값을 stale로 준다.
import { json } from "./http.js";
import { chargeWrites } from "./state.js";

export const FX_URL = "https://api.frankfurter.app/latest";
const name = (day) => "fx:" + day;
const dayOf = (ms) => new Date(ms).toISOString().slice(0, 10);

export async function fxRoute(request, ctx) {
  if (request.method !== "GET") return json({ error: "method_not_allowed" }, 405);
  const today = dayOf(ctx.now);
  const cached = await ctx.kv.get(name(today));
  if (cached) return new Response(cached, { status: 200, headers: { "content-type": "application/json; charset=utf-8", "cache-control": "private, max-age=3600" } });
  const fetcher = ctx.env.FETCH ?? fetch;
  try {
    const reply = await fetcher(FX_URL);
    const body = reply.ok ? await reply.json() : null;
    if (body && typeof body.rates === "object" && body.base) {
      const value = JSON.stringify({ day: today, date: body.date, base: body.base, rates: { ...body.rates, [body.base]: 1 }, source: "ECB via frankfurter.app" });
      const charge = await chargeWrites(ctx.env, null, 1, ctx.now);
      if (charge.ok) await ctx.kv.put(name(today), value, { expirationTtl: 3 * 86_400 });
      return new Response(value, { status: 200, headers: { "content-type": "application/json; charset=utf-8", "cache-control": "private, max-age=3600" } });
    }
  } catch {
    // 아래에서 전날 값을 본다.
  }
  const yesterday = await ctx.kv.get(name(dayOf(ctx.now - 86_400_000)));
  if (yesterday) return json({ ...JSON.parse(yesterday), stale: true }, 200);
  return json({ error: "unavailable" }, 503);
}
