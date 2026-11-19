// TGT1119A03: 한국도로공사 포털에 위치가 없는 영업소를 한꺼번에 찾아 `src/ex-unit-prefix.js`(고정 좌표표)에 반영한다.
// 사람이 영업소를 하나씩 입력하지 않는다. 키 두 개(둘 다 서버 비밀값과 같은 것)만 환경 변수로 준다. 키는 출력·저장하지 않는다.
//
//   EX_API_KEY=포털키 KAKAO_REST_API_KEY=카카오키 node scripts/ex-units-fill.mjs
//
// - 포털 목록을 모아 위치(xValue·yValue)가 없는 영업소를 찾고, 카카오 장소 검색으로 이름을 찾아 좌표를 구한다
//   (「이름톨게이트」→「이름IC」, 결과에 이름이 들고 영업소·IC·고속도로 장소여야 하며 한국 안 좌표).
// - 이미 고정표에 있는 영업소는 다시 찾지 않고 그대로 둔다. 못 찾은 영업소는 이름만 출력한다(그 영업소는 지금처럼 빠짐).
// - 결과 파일을 확인한 뒤 커밋하고 서버를 배포한다. 출력은 건수와 이름뿐이다.
import { writeFileSync } from "node:fs";
import { exUnits } from "../src/expressway.js";
import { PREFIX_UNITS } from "../src/ex-unit-prefix.js";

const { EX_API_KEY, KAKAO_REST_API_KEY } = process.env;
if (!EX_API_KEY || !KAKAO_REST_API_KEY) {
  console.error("사용법: EX_API_KEY=포털키 KAKAO_REST_API_KEY=카카오키 node scripts/ex-units-fill.mjs");
  process.exit(2);
}
const response = await exUnits(new Request("https://relay.invalid/ex/units"), { EX_API_KEY, KAKAO_REST_API_KEY, EX_GEO_CALLS: "2000", EX_GEO_REPORT: "1" }, fetch, null);
if (response.status !== 200) { console.error(`포털 목록을 받지 못했습니다(${response.status}).`); process.exit(1); }
const body = await response.json();
const filled = body.units.filter((unit) => unit.geo === "kakao");
const keep = new Map(PREFIX_UNITS.map((unit) => [unit.code, unit]));
for (const unit of filled) keep.set(unit.code, unit);
const table = [...keep.values()].sort((a, b) => a.code.localeCompare(b.code));
const lines = table.map((unit) => `  ${JSON.stringify(unit)},`).join("\n");
const header = `// 한국도로공사 포털(locationinfoUnit)에 위치가 없는 영업소의 고정 좌표표(TGT1119A03, 대표 지시 「없는 것은 찾아서 pre fix로 반영」).
// \`scripts/ex-units-fill.mjs\`가 포털 목록에서 위치 없는 영업소를 찾아 카카오 장소 검색으로 좌표를 구해 이 파일을 다시 쓴다.
// 포털이 나중에 위치를 주면 포털 값이 앞선다. 영업소 코드·이름·노선·좌표(영업소 시설 좌표가 아니라 카카오가 찾은 장소 좌표)만 둔다.
`;
writeFileSync(new URL("../src/ex-unit-prefix.js", import.meta.url), `${header}export const PREFIX_UNITS = [\n${lines}\n];\n`);
console.log(`포털 영업소 ${body.count - table.length}개 + 고정표 ${table.length}개(이번에 새로 찾은 것 ${filled.length}개).`);
if (body.unlocated?.length) console.log(`카카오에서도 못 찾음 ${body.unlocated.length}개: ${body.unlocated.map((u) => `${u.name}(${u.code})`).join(", ")}`);
if (body.pending) console.log(`검색 한도·오류로 못 묻고 남은 것 ${body.pending}개: 같은 명령을 다시 실행하세요.`);
