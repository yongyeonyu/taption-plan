// REV1117A02: `scripts/shared-rules/admin.mjs`를 서버 없이 돌리는 가짜 관리 경로. `node --import`로 먼저 읽힌다.
// 상태(현재 묶음·후보)는 SHARED_ADMIN_FAKE 파일에 두어 명령 한 번마다 새 프로세스여도 이어진다.
import { readFileSync, writeFileSync } from "node:fs";

const file = process.env.SHARED_ADMIN_FAKE;
const reply = (status, body) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

globalThis.fetch = async (url, init = {}) => {
  const state = JSON.parse(readFileSync(file, "utf8"));
  const { pathname } = new URL(url);
  const action = `${init.method ?? "GET"} ${pathname}`;
  if (action === "GET /shared/admin/bundle") return reply(200, { version: state.version, payload: state.payload });
  if (action === "GET /shared/admin/candidates") return reply(200, { min: 2, total: state.candidates.length, candidates: state.candidates });
  if (action === "POST /shared/admin/publish") {
    const { payload } = JSON.parse(init.body);
    const { version } = JSON.parse(payload);
    if (version <= state.version) return reply(409, { error: "stale_version", version: state.version });
    writeFileSync(file, JSON.stringify({ ...state, version, payload }));
    return reply(201, { ok: true, version });
  }
  return reply(404, { error: "not_found" });
};
