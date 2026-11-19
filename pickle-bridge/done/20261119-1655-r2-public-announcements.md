---
id: 20261119-1655-r2-public-announcements
created_at: 2026-11-19T16:55+09:00
status: done
request_id: R2PUB1119A01
finished_at: 2026-11-19T17:20+09:00
commit: a6e759bb
title: R2 공용 버킷 — 전체 공지·공용 정적 데이터 조회 엔드포인트
from: 비야
basis: 대표 직접 지시 (2026-11-19 채팅 「r2서버 올리자」 — 전체 공지와 도시별 POI 팩·온디바이스 ML 모델을 모두에게 뿌릴 공용 정적 저장소)
---

## 할 일

0. `git pull --rebase` 뒤 이 문서를 읽고, `AGENTS.md` 2절대로 요청 ID를 새로 만들어 `test.md` `## 남은 작업` 중 **배포·운영·출시** 영역에 한 줄, `### 요청 상세`에 원인·해결·검증 기준·상태를 먼저 적습니다. 이 문서에는 `request_id`가 없습니다.

1. 배경과 지금 상태(2026-11-19 `origin/main` `370d7cb`에서 확인함):
   - `server/trip-relay`는 개인 기록·AI 태스크 저장소를 KV에서 D1(`RELAY_DB`)으로 옮겼고(`D1R1119A01`·`D1R1119A02`), `wrangler.toml`에는 `[[d1_databases]]`, Durable Object 2종(`USER_STATE`·`SHARE_ROOM`), 속도 제한 3종, `[vars] KV_DAILY_WRITE_BUDGET`만 있습니다. **R2 바인딩과 공용 정적 데이터 엔드포인트는 없습니다.**
   - `src/index.js`의 `route()` 순서는 ①`PUBLIC` 표(고정 경로 4개) ②`!env.USER_STATE`면 503 ③IP별 `REQUEST_LIMIT` ④`switch`(`/register`·OAuth·`/mcp/<키>`·`/shared/admin/`·공유 방) ⑤`ROUTES[경로]`를 `authorized()`로 통과 ⑥모르는 경로 404입니다. 공용 경로를 `ROUTES`에 넣으면 키가 없어 401이 되고, ①보다 뒤에 두면 `USER_STATE`나 속도 제한에 먼저 걸리므로 **새 공용 길은 ① 바로 뒤, ②·③ 앞에서 가로채야 합니다.**
   - `src/http.js`의 `json()`은 기본으로 `cache-control: no-store`를 붙입니다. 공용 응답은 이 기본값을 그대로 쓰면 안 됩니다(2-5).
   - 시험은 `test/index.test.mjs`처럼 `handle(new Request(...), env)`를 직접 부르고, `env`는 `test/fakes.mjs`의 `makeEnv()`가 만듭니다(가짜 KV·진짜 DO). 새 가짜 R2 버킷도 여기에 둡니다.

2. 구현

   2-1. **`server/trip-relay/wrangler.toml`** — D1 블록 아래에 R2 바인딩을 더합니다.
   ```toml
   [[r2_buckets]]
   binding = "PUBLIC_BUCKET"
   bucket_name = "taption-trip-public"
   ```
   위에 한글 주석으로 남깁니다: 버킷은 `npx wrangler r2 bucket create taption-trip-public`로 대표가 만들고, 배포에 쓰는 git에 없는 `wrangler.local.toml`에도 같은 블록이 있어야 하며, 바인딩이 없어도 코드는 503이 아니라 안전한 빈 응답을 준다는 것. `preview_bucket_name`은 넣지 않습니다(로컬 미리보기는 R2 없이 도는 것이 이 기능의 설계 전제).

   2-2. **`src/public.js` 새 모듈** — `expressway.js`·`rules.js`처럼 갈래를 따로 두고, `export async function publicRoute(request, env)`가 `Response` 또는 `null`(이 경로가 아님)을 돌려주게 합니다. `index.js`의 `route()` ①바로 뒤에서 `const pub = await publicRoute(request, env); if (pub) return pub;`처럼 부릅니다. `handle`의 CORS·`withD1`은 그대로 둡니다(공용 길은 CORS를 열지 않음 — 앱은 네이티브이고, 브라우저에 열면 낭비 요청만 늘어납니다).

   2-3. **`GET /public/announcements`** — 전체 공지.
   - R2 키는 `announcements/latest.json` 고정.
   - `env.PUBLIC_BUCKET`이 없거나, 객체가 없거나, 본문이 JSON이 아니거나 `items`가 배열이 아니면 **항상 200 `{"version":0,"items":[]}`** + `cache-control: no-store`(첫 공지를 올렸을 때 바로 보이도록)를 돌려줍니다. 500·502로 앱을 깨뜨리지 않습니다.
   - 정상일 때는 200, `content-type: application/json; charset=utf-8`, `etag: <object.httpEtag>`, `cache-control: public, max-age=300`. 본문은 R2에 올린 JSON을 **고치지 않고 그대로** 돌려줍니다(서버가 `startsAt`·`expiresAt`·`minBuild`로 거르지 않습니다 — 그 판단은 앱 몫이고 후속 요청에서 정합니다).
   - 조건부 요청: `bucket.get(key, { onlyIf: request.headers })`로 R2에 맡기고, 본문이 없는 응답(`body`가 없음 = 전제 실패)이면 **304** + `etag`·`cache-control`을 같은 값으로 돌려줍니다. `If-None-Match`가 현재 ETag와 같으면 304여야 합니다.
   - 메서드는 `GET`만. 그 밖(HEAD 포함)은 **405** + `allow: GET`.

   2-4. **`GET /public/assets/<prefix>/<파일…>`** — 확장 공용 에셋(POI 팩·ML 모델·공지에 딸린 그림).
   - 허용 접두어는 첫 칸이 `announcements`, `packs`, `models` 셋뿐입니다. 그 밖은 **404**(존재 여부를 알려 주지 않음).
   - 키 검증은 **정규화하지 말고 거부**하는 쪽으로 합니다. `decodeURIComponent`로 풀어서 `..`를 없애는 방식은 이중 인코딩에 뚫리므로, 원래 `url.pathname`을 `/public/assets/` 뒤에서 `/`로 나눠 각 칸이 `^[A-Za-z0-9][A-Za-z0-9._-]*$`에 맞는지만 봅니다. `%`·공백·역슬래시·빈 칸(`//`)·`.`으로 시작하는 칸·8칸 초과·키 길이 200자 초과는 **400**. 이 규칙 때문에 업로드하는 파일 이름도 영문·숫자·`.`·`_`·`-`만 쓰게 됩니다(README에 적음).
   - 조회는 `bucket.get(key, { range: request.headers, onlyIf: request.headers })`.
     - 없음 → **404**.
     - `If-None-Match` 일치 → **304**(`etag` 포함).
     - `Range`가 있으면 **206** + `content-range: bytes <시작>-<끝>/<전체>`(R2가 준 `object.range`로 만듦) + `accept-ranges: bytes`. 잘못된 범위로 R2가 던지면 **416**.
     - 그 밖에는 200 + `content-length: object.size`.
   - `content-type`은 `object.httpMetadata.contentType`을 먼저 쓰고, 없으면 확장자 표(`.json`·`.jpg`/`.png`/`.webp`·`.mlmodelc`/`.mlpackage`는 `application/octet-stream`·`.zip`)로 정합니다. `etag: object.httpEtag`, `accept-ranges: bytes`.
   - `cache-control`은 `announcements/`로 시작하는 키만 `public, max-age=300`, 나머지는 `public, max-age=86400`.
   - 메서드는 `GET`만, 그 밖은 **405** + `allow: GET`. `/public/assets/` 뒤가 비었거나(`/public/assets/packs/`만 있는 경우 포함) 칸이 모자라면 404.

   2-5. **엣지 캐시(권장, 시험은 없어도 됨)** — 공지는 앱이 자주 부르므로 `caches.default`가 있으면(`typeof caches !== "undefined" && caches.default`) 200 응답만 `max-age`만큼 캐시하고 `match`로 먼저 답합니다. 시험(Node)에는 없으므로 `caches`가 없으면 그냥 R2로 갑니다. 캐시를 넣어도 **응답 헤더·상태는 캐시를 안 쓸 때와 같아야** 하고, `no-store` 응답은 캐시하지 않습니다.

   2-6. **읽기 전용 원칙** — Worker에는 R2 `put`/`delete`를 부르는 코드를 **한 줄도** 넣지 않습니다. 앱 주인 키(`master`)·AI 연결 키·OAuth 토큰은 공용 길에서 아예 읽지 않고(인증 전에 가로채므로 닿지 않음), 관리자용 업로드 엔드포인트나 관리자 토큰으로 쓰게 하는 우회도 만들지 않습니다. R2 자격 증명은 Worker 비밀값으로도 두지 않습니다(바인딩만). 공지·파일 업로드는 아래 CLI로만 합니다.

   2-7. **공지 JSON 스키마 초안** — `server/trip-relay/README.md`에 표로, `test/fixtures/public-announcements.json`에 실제 예로 넣고 시험이 그 파일을 그대로 올려 씁니다.
   | 필드 | 필수 | 형식·한도 | 뜻 |
   | --- | --- | --- | --- |
   | `version` | 필수 | 1 이상 정수 | 공지 묶음의 판. 올릴 때마다 1씩 올림. `0`은 서버가 주는 「아직 없음」 |
   | `items` | 필수 | 배열, 최대 50개 | 공지 목록 |
   | `items[].id` | 필수 | `[a-z0-9][a-z0-9._-]{0,63}` | 바뀌지 않는 식별자. 앱이 「읽음」 표시에 씀 |
   | `items[].title` | 필수 | 1~100자 평문 | 제목 |
   | `items[].body` | 필수 | 1~2000자 평문(HTML·마크다운 금지) | 본문 |
   | `items[].kind` | 필수 | `info`·`update`·`warning`·`critical` | 표시 분류. 심각도 순서가 곧 이 순서(별도 `level` 필드는 두지 않음) |
   | `items[].startsAt` | 선택 | ISO 8601(오프셋 포함) | 이때부터 보임. 없으면 즉시 |
   | `items[].expiresAt` | 선택 | ISO 8601 또는 `null` | 이때부터 안 보임. 없으면 계속 |
   | `items[].minBuild` | 선택 | 정수 | 이 빌드 미만 앱에는 안 보임 |
   | `items[].maxBuild` | 선택 | 정수 또는 `null` | 이 빌드 초과 앱에는 안 보임 |
   | `items[].link` | 선택 | `https://`, 300자 이내 | 「자세히」로 열 주소 |
   | `items[].titleByLang`·`bodyByLang` | 선택 | `{"en": "…", "ja": "…"}` | 다른 언어. 없으면 `title`·`body`를 씀(기본 언어는 한국어) |
   시험 픽스처의 공지는 가짜 내용(예: 「앱 점검 안내」)으로 씁니다. 실제 사용자·계정·좌표·도메인을 쓰지 않습니다.

   2-8. **README 「공용 공지·정적 데이터(R2)」 절** — `server/trip-relay/README.md`의 D1 절 뒤에 붙입니다.
   - 엔드포인트 표(경로·응답·상태 코드), 위 스키마 표, 읽기 전용 원칙.
   - 배포(대표 몫) 순서:
     ```sh
     npx wrangler r2 bucket create taption-trip-public
     # wrangler.local.toml의 [[d1_databases]] 아래에 같은 [[r2_buckets]] PUBLIC_BUCKET 블록을 넣는다
     npm test
     npx wrangler deploy --config wrangler.local.toml
     ```
   - 업로드(대표 몫). **Wrangler v4부터 `wrangler r2 object` 명령은 `--remote` 없이는 로컬 시뮬레이터에만 씁니다** — `--remote`를 빼면 올린 것처럼 보이지만 실제 버킷에는 없습니다. 명령에 반드시 넣습니다.
     ```sh
     npx wrangler r2 object put taption-trip-public/announcements/latest.json \
       --file ./announcements.json --content-type application/json \
       --cache-control "public, max-age=300" --remote --config wrangler.local.toml
     ```
     POI 팩·모델도 같은 방식(`packs/…`, `models/…`).
   - 배포 뒤 확인: `curl -s -o /dev/null -w '%{http_code}\n' https://<중계 서버 주소>/public/announcements`가 200, `-H 'If-None-Match: <받은 ETag>'`로 304, 없는 파일은 404. 저장소가 공개이므로 README에는 실제 도메인을 쓰지 말고 「앱이 쓰는 중계 서버 주소」로 적습니다.
   - 무료 한도(2026-11-19 Cloudflare 문서 기준): R2 무료는 저장 10GB·월, Class A(쓰기·목록) 월 100만, Class B(읽기) 월 1,000만, 나가기 전송료 무료. Worker 요청은 무료 계정 하루 10만 건에 함께 세어지므로 공지는 엣지 캐시(2-5)로 R2 읽기를 줄입니다. 유료 전환은 대표 결정 없이 하지 않는다고 한 줄 적습니다.
   - 「공용 버킷에 쓰는 길은 이 CLI뿐」, 「앱 키로는 읽기만」을 분명히 적습니다.
   - iOS 연동(앱이 언제·얼마나 자주 부르고, `kind`별 표시, 읽음 표시)은 **이번 범위가 아니며 별도 후속 요청**이라고 적습니다.

3. 시험 (`npm test`, 새 파일 `test/public.test.mjs`)
   - `test/fakes.mjs`에 `MemoryBucket` 가짜 R2를 더합니다: `get(key, { range, onlyIf })`·`head(key)`가 `{ body, size, httpEtag, httpMetadata, range, writeHttpMetadata(headers) }` 모양을 돌려주고, `onlyIf`의 `If-None-Match`가 맞으면 `body` 없이, `Range`가 있으면 그 구간만, 없으면 `null`을 돌려줍니다. `put`/`delete`는 시험이 실수로 쓰지 않았는지 세도록 두되, 시험에서만 씁니다.
   - 시험 항목(전부 `handle()`로 실제 경로를 부름):
     1. 공지 정상: 픽스처를 올려 두고 200, 본문이 픽스처와 같음, `etag`·`cache-control` 있음.
     2. 공지 미존재: 빈 버킷에서 200 `{"version":0,"items":[]}`, `cache-control: no-store`.
     3. 바인딩 없음: `env.PUBLIC_BUCKET`을 지운 환경에서도 200 빈 응답(503 아님). `env.USER_STATE`가 없어도 같은 결과(공용 길이 DO에 걸리지 않음).
     4. 깨진 JSON·`items` 없는 JSON: 500이 아니라 200 빈 응답 + `no-store`.
     5. ETag 304: 첫 응답의 `etag`를 `If-None-Match`로 보내면 304, 본문 없음.
     6. 허용 에셋: `packs/` 파일 200, `content-type`·`etag`·`accept-ranges` 있음.
     7. Range: `bytes=0-9` → 206, `content-range`가 맞음.
     8. 에셋 없음: 404.
     9. 경로 탈출·모양 위반: `/public/assets/packs/../secret`, `/public/assets/packs/%2e%2e/secret`, `/public/assets/packs//x.json`, `/public/assets/packs/` → 400.
     10. 허용 외 접두어: `/public/assets/private/x.json`, `/public/assets/packsx/x.json` → 404.
     11. 메서드 제한: `POST`·`PUT`·`DELETE`(공지·에셋 모두) → 405 + `allow: GET`. 공지에 `PUT`으로 쓰려는 요청이 R2에 아무것도 쓰지 않음(가짜 버킷 쓰기 횟수 0).
     12. 기존 경로 회귀: `/plan` 키 없이 401, 모르는 경로 404 그대로(이 시험은 기존 `index.test.mjs`에 이미 있으면 새로 만들지 않음).
   - `npm test` 전체를 돌리고 **실행·통과·실패·건너뜀 수치**를 xcresult 대신 콘솔 출력 그대로 회신에 적습니다. 새 의존성(`miniflare`·R2 모의 패키지 등)을 더하지 않습니다.
   - 앱 소스·앱 시험은 건드리지 않으므로 Xcode 빌드는 돌리지 않습니다(문서·서버 전용).

4. `test.md` — 위 요청 ID 줄과 상세를 채우고, 상태는 「코드·시험 끝, 대표 몫: 버킷 만들기·로컬 설정에 바인딩 추가·배포·첫 공지 업로드」로 적습니다. `## 실기기 확인 목록`은 이번 범위에 넣지 않습니다(앱 연동 없음).

5. `pickle-bridge/README.md` 4절 회신 형식대로 `## 클로드 코드 회신`을 적고, frontmatter를 `status: done`·`finished_at`·`commit`으로 채운 뒤 `git mv`로 `pickle-bridge/done/`에 옮겨 커밋·푸시합니다(작업 커밋과 문서 이동 커밋 분리, 경로를 지정해 커밋).

## 확인 기준

- `GET /public/announcements`가 바인딩·파일이 없는 상태에서도 200 `{"version":0,"items":[]}`이고 앱/클라이언트가 깨지지 않는다.
- 공지를 올리면 같은 경로로 200, `If-None-Match`로 304가 되고, `Range` 요청이 206으로 답한다.
- 허용 접두어 밖·경로 탈출·메서드 위반이 각각 404·400·405로 막히고, 어떤 경우에도 R2에 쓰기·삭제가 일어나지 않는다.
- 공지 스키마 초안이 README와 `test/fixtures/public-announcements.json`에 같은 필드로 적혀 있다.
- `npm test` 실제 수치가 회신에 있고, 기존 시험이 줄지 않았다.
- 대표 몫 명령(버킷 만들기·로컬 설정 바인딩·배포·`--remote` 업로드)이 README와 회신에 그대로 적혀 있고, **대표가 실행하기 전 상태**임이 분명하다.
- 시작할 때 같은 기능(R2 바인딩·`/public/` 경로)이 이미 `main`에 있으면 중복 구현하지 말고 그 커밋·상태만 회신하고 문서를 `done/`으로 옮긴다.

## 하지 말 것

- **배포·버킷 생성·업로드·`wrangler.local.toml` 수정 금지.** `npx wrangler deploy`, `r2 bucket create`, `r2 object put`은 대표 몫입니다(파일 삭제·서버 배포는 지시서에 적혀 있어도 실행하지 않고 회신만, `AGENTS.md` 12절). `wrangler deploy --dry-run`도 억지로 맞추지 말고, 해 봤으면 결과만 적습니다.
- R2 쓰기·삭제 경로(관리자 업로드 엔드포인트, 관리자 토큰, 서명 URL 발급)를 만들지 말 것. 이번 기능은 읽기 전용입니다.
- `decodeURIComponent`로 경로를 풀어 정규화하는 방식으로 탈출을 막으려 하지 말 것 — 규칙에 안 맞으면 400으로 거부합니다.
- 공용 길에 CORS 헤더 추가, `Authorization` 해석, IP 속도 제한·DO 예산 호출 넣기.
- `AGENTS.md` 4절 「대표 결정」 바꾸기, `[observability]` 켜기, 기존 `ROUTES`·`authorized()`의 인증 규칙 바꾸기.
- 앱(iOS) 소스·앱 시험·`TaptionPlan` 쪽 변경. 앱 연동은 별도 후속 요청입니다.
- 지시서·회신·README·시험 픽스처에 개인정보·계정·실제 도메인·실제 좌표 쓰기(저장소는 공개입니다, `AGENTS.md` 8절).
- 다른 세션의 미커밋 변경(예: `TaptionPlan/Assets.xcassets/PlaceBook/.../PlaceBook_kr_sungnyemun.svg`)을 이번 커밋에 넣기.

## 참고

- `pickle-bridge/README.md`, `AGENTS.md` 5·8·12절.
- 서버: `server/trip-relay/src/index.js`(`route()`·`PUBLIC`·`ROUTES`), `src/http.js`(`json()`의 `no-store`), `src/expressway.js`(모듈 갈래 예), `test/fakes.mjs`(`makeEnv`), `test/index.test.mjs`(호출 방식), `README.md`(D1 절 뒤에 새 절).
- 관련 기록: `test.md`의 `D1R1119A01`·`D1R1119A02`(저장소 D1 전환·옛 KV 제거), `D1R1119A02`의 「서버 재배포 한 번 남음」.
- Cloudflare 문서(2026-11-19 확인): R2 Workers API 레퍼런스(`onlyIf`·`range`·`httpEtag`·`writeHttpMetadata`), R2 가격(무료 저장 10GB·Class A 100만·Class B 1,000만·전송료 무료), Workers 한도(무료 하루 10만 요청), Wrangler v4 마이그레이션(`r2 object` 기본이 로컬, 원격은 `--remote`).
- 이 요청은 「R2 바인딩 + 읽기 전용 공용 길 + 스키마 초안 + 시험」까지입니다. 앱이 공지를 언제 받아 어떻게 보여 줄지, POI 팩·모델 형식은 다음 요청에서 정합니다.

## 클로드 코드 회신

- 처리: 완료(코드·시험까지. 배포·버킷 생성·업로드는 대표 몫이라 하지 않음)
- 요청 ID: R2PUB1119A01 (`test.md` 「배포·운영·출시」 줄·요청 상세·검증 기록)
- 시작·끝: 2026-11-19 16:58 ~ 17:20 (KST)
- 커밋: `a6e759bb` 작업, 문서 이동은 `[비야 브리지] 20261119-1655-r2-public-announcements` 한 건
- 바꾼 파일: `server/trip-relay/src/public.js`(새), `src/index.js`(`route()`에서 공용 표 바로 뒤·`USER_STATE` 앞에 `publicRoute` 한 줄), `wrangler.toml`(`[[r2_buckets]] PUBLIC_BUCKET`), `test/public.test.mjs`·`test/fixtures/public-announcements.json`(새), `test/fakes.mjs`(`MemoryBucket`), `README.md`(「공용 공지·정적 데이터」 절), `test.md`. 앱(iOS) 소스는 건드리지 않음
- 검증: `npm test` 271건 실행·통과 271·실패 0·건너뜀 0(기존 257 + 새 14, 새 의존성 없음). 앱 빌드·시험은 서버 전용이라 안 함. 실제 R2·엣지 캐시(`caches.default`)는 Node 시험에 없어 확인 안 함
- 알아 둘 것 3가지:
  1. 지시서 모순: 시험 9번은 `/public/assets/packs/`를 400으로, 2-4절은 404로 적어 2-4절대로 404로 했습니다(`//`·`%`·`.`시작 등은 400).
  2. `/public/assets/packs/../secret`, `%2e%2e/secret`는 URL 해석기가 요청이 코드에 닿기 전에 `..`를 걷어내 `/public/assets/secret`이 되므로 400이 아니라 404(허용 접두어 밖)입니다. R2는 읽지 않습니다. 400 시험은 `..%2fsecret`처럼 슬래시를 인코딩한 형태로 했습니다.
  3. 공지를 읽기 시작한 R2 객체가 깨졌을 때는 빈 목록(`no-store`)이라, 새 `etag`가 안 생겨 304 순환에 빠지지 않습니다.
- 남은 것·확인 필요(전부 대표 몫, 아직 안 함): ① `npx wrangler r2 bucket create taption-trip-public` ② `wrangler.local.toml`에 `[[r2_buckets]] PUBLIC_BUCKET` 블록 추가 ③ `npx wrangler deploy --config wrangler.local.toml` ④ 첫 공지 `r2 object put … --remote` 업로드. 순서·명령은 README 「R2 배포·업로드」. 바인딩이 없어도 `/public/announcements`는 200 빈 목록이라 배포 순서가 틀려도 앱이 깨지지 않습니다. iOS 연동은 후속 요청
