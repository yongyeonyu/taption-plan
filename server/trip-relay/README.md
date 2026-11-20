# 여행 계획 중계 서버 (TRP1110A04)

AI 비서(도구 호출이 되는 비서, ChatGPT 맞춤 GPT Actions, 단축어 등)가 여행 JSON을 보내면, 사용자가 앱을 열 때 미리보기로 가져오는 Cloudflare Worker입니다. 복사·붙여넣기 없이 계획이 도착합니다.

## 동작
- 앱이 기기에서 연동 키(무작위 32바이트, base64url 43자)를 만들어 키체인에만 둡니다.
- AI가 `POST /plan`으로 JSON을 보냅니다. 헤더 `Authorization: Bearer <키>`, 본문은 앱의 여행 JSON 형식(`format: "bokki-trip"`, `version: 1`) 그대로입니다. 최대 64KB.
- 앱은 앱을 열 때 `GET /plan`으로 확인하고, 처음 보는 내용이면 미리보기를 띄웁니다. 사용자가 반영하면 `DELETE /plan`으로 지웁니다. 지운 뒤 잠깐 캐시가 같은 값을 돌려줘도 앱은 내용 해시로 걸러 다시 띄우지 않습니다.
- 서버는 키를 SHA-256으로만 저장하고(원래 키는 저장하지 않음), 값은 그 키로만 풀리게 암호화하며, 계획은 3일 뒤 자동으로 지웁니다. 키마다 마지막 계획 하나만 둡니다. IP·요청을 기록하지 않습니다.

| 요청 | 응답 |
|---|---|
| `POST /plan` | 201 저장, 400 JSON 아님, 401 키 없음·형식 틀림, 413 64KB 초과, 422 여행 형식 아님 |
| `GET /plan` | 200 계획 JSON, 204 없음 |
| `DELETE /plan` | 204 |

## 배포 (대표님이 하는 일)
1. 이 폴더에서:
   ```sh
   npx wrangler login
   npx wrangler kv namespace create PLANS
   ```
2. 나온 KV `id`를 `wrangler.toml`의 `REPLACE_WITH_KV_NAMESPACE_ID` 자리에 넣고 `npx wrangler deploy`.
3. 배포 주소의 호스트 이름만(예: `taption-trip-relay.<계정>.workers.dev` 또는 연결한 도메인) 앱 빌드 설정 `TRIP_RELAY_HOST`(`TaptionPlan/AppSecrets.local.xcconfig`)에 넣습니다. 비어 있으면 앱은 이 기능을 숨깁니다.
4. Cloudflare 대시보드에서 이 Worker에 속도 제한 규칙을 둡니다(예: IP당 분당 30회). 무료 KV는 하루 쓰기 1,000건이라, 남용되면 쓰기가 막힙니다.

## `/public/*` 속도 제한은 Cloudflare 규칙으로 (S3, CRV1120A01)

`/public/announcements`와 `/public/assets/*`는 인증·Worker 속도 제한 없이 R2를 그대로 읽어 준다(앱이 로그인 없이 받는 공용 파일). 시즌 팩 `.bpack`(최대 8MB)이나 큰 모델 파일을 한 IP가 반복해서 받으면 R2 이그레스를 쓸 수 있다. Worker 안에 한도를 두면 이어받기(`Range`)가 조각마다 한도에 걸려 끊기므로, **Worker 코드는 그대로 두고 Cloudflare 대시보드의 속도 제한 규칙으로 막는다**(대표 몫).

- 대상: 경로가 `/public/assets/` 로 시작하는 요청.
- 권장 시작값: IP당 1분에 60회(시즌 팩 하나는 조각 몇 개로 끝나고, 앱은 하루 몇 번만 받는다). 넘으면 429·10분 차단. 값은 Cloudflare 요금제 한도에 맞춰 조정한다.
- `/public/announcements`는 작고 엣지 캐시되므로 규칙에서 뺀다.
- 규칙을 만든 뒤 이어받기가 되는지 `curl -s -o /dev/null -D - -H "Range: bytes=0-99" https://<서버>/public/assets/<키>`가 `206`인지 확인한다.

## 확인할 것
- 무료 한도(Workers 요청, KV 읽기·쓰기)는 Cloudflare 요금 문서에서 배포 전에 다시 확인하세요.
- 여행 일정이 서버에 최대 3일 머무르므로 개인정보 처리방침(PRIVACY.md)과 App Store 개인정보 항목에 반영해야 합니다.

## 테스트
```sh
npm test
```

연동 규격(주소·인증·JSON 스키마·샘플)은 [docs/TRIP_RELAY_API.md](../../docs/TRIP_RELAY_API.md)를 보세요.

## AI 비서 하루 기록·명령(AIR1110A01·TRP1110A07)

| 요청 | 누가 | 응답 |
|---|---|---|
| `POST /activity` | 앱 | 201 저장(하루마다 `act:<해시>:<날짜>`, 보관 1·7·30일), 422 형식·보관 기간·날 수(1~7) 틀림 |
| `GET /activity[?date=YYYY-MM-DD]` | AI | 200 그날 또는 최근 7일 `{"days":[…]}`, 204 없음 |
| `DELETE /activity` | 앱 | 204 이 키의 모든 날(KV `list` 접두어로 찾음) |
| `POST /command` | AI | 201 큐에 넣음(`addMemo`·`addSchedule`·`updateActivity`, 최근 50개, 같은 id는 교체, 7일), 422 형식 틀림 |
| `GET /command` · `DELETE /command[?ids=a,b]` | 앱 | 200 `{"commands":[…]}`·204 |
| `POST /command/result` · `GET /command/result` | 앱 · AI | 201 · 200 `{"results":[…]}`·204 |

쓰기(`POST`)는 모두 `POST_LIMIT`을 받습니다. 규격·샘플은 [docs/ACTIVITY_RELAY_API.md](../../docs/ACTIVITY_RELAY_API.md).

## 저장 암호화(SEC1110A01)

v2: 값은 사용자 DEK(주인 키에서 HKDF info `dek`로 정해지고 저장하지 않음)로 AES-256-GCM 암호화합니다(`{"v":2,"iv","ct"}`, KV 이름을 AAD로 사용). 범위 키마다 `dek:<해시>`에 DEK를 그 키의 HKDF(info `wrap`) 키로 감싸 두고, 범위·만료·주인 해시를 AAD로 묶습니다. v1(`{"v":1,…}`, 연동 키 HKDF info `storage`)은 주인 키로만 읽고 다음 쓰기에서 v2가 됩니다. 범위 키를 처음 등록하면 그 이름의 v1 값을 v2로 다시 잠급니다. 주인이 못 푸는 값은 지우고 204, 범위 키가 못 푸는 값은 지우지 않고 204입니다. 암호화 전 `/plan` 평문은 한 번 읽어 주며, 이 예외는 2026-11-14 뒤 지웁니다.

## 범위 키·한도·MCP·OpenAPI(AIR1110A02·CLN1110A01)

| 요청 | 범위 | 내용 |
|---|---|---|
| `POST`·`GET`·`DELETE /keys` | 주인 | 읽기·쓰기 키 등록(수명 365일 이내 또는 `expiresAt: null` 만료 없음)·목록(`id` = 해시 앞 8자)·폐기. 폐기·만료 키는 401 |
| `GET /activity/summary?range=week\|month[&end=]` | 읽기 | 저장된 날의 분류별 분·기록 분·걸음·계획 수 합계 |
| `POST /command` | 쓰기 | 새 동작 `hideRecord`·`mergeRecords`·`updateRecordTime`·`updateSchedule`·`deleteSchedule`·`updateMemo`·`deleteMemo`. 주인 이름마다 24시간 100개(429), 받은 시각은 큐 값에 함께 적어 명령당 KV 쓰기 1번 |
| `POST /mcp` | 읽기(도구마다) | 원격 MCP(JSON-RPC 2.0, `2025-06-18`, `initialize`·`tools/list`·`tools/call`, SSE 없음) |
| `GET /openapi.json` | 없음 | GPT Actions용 OpenAPI 3.1 |

(SEC1110A02부터 등록되지 않은 키는 401입니다. 아래 참고.) 코드는 `src/index.js`(경로·범위표), `keys.js`, `store.js`, `validate.js`, `crypto.js`, `mcp.js`, `openapi.js`로 나뉩니다. 시험은 `test/*.test.mjs`. 자세한 규격은 [docs/ACTIVITY_RELAY_API.md](../../docs/ACTIVITY_RELAY_API.md) 6~10장.

## 푸시(APNs, PSH1114A06)

AI(주인 키가 아닌 키)가 명령을 넣거나, 일을 끝내거나, 규칙을 바꾸면 앱을 깨웁니다. 푸시에는 종류(`k`: `cmd`·`q`·`task`·`rules`)만 싣고 사용자 글은 싣지 않습니다. 질문·승인과 `needsUser` 결과만 보이는 알림(`PUSH_AI_QUESTION`·`PUSH_AI_NEEDS_YOU`, 문구는 앱 `Localizable`)이고 나머지는 조용한 푸시입니다. 조용한 것은 종류마다 간격(명령·규칙 2분, 일 60초)과 하루 60번, 보이는 것은 하루 20번까지입니다. 앱의 5분 확인이 예비라 푸시가 안 가도 틀리는 것은 없습니다.

- `POST /push/token {token, env: sandbox|production, build?}`·`DELETE /push/token`: 주인 키만. 토큰은 DEK로 잠가 주인 DO에 둡니다. APNs가 410·`Unregistered`·`BadDeviceToken`을 주면 지우고, 「모두 끊기」·PIN 초기화 때도 지웁니다.
- 비밀값 세 개가 모두 있어야 보냅니다. 하나라도 없으면 조용히 건너뜁니다(배포 순서 자유).

```sh
npx wrangler secret put APNS_KEY_P8 --config wrangler.local.toml    # .p8 파일 내용 전체(-----BEGIN PRIVATE KEY----- 포함)
npx wrangler secret put APNS_KEY_ID --config wrangler.local.toml    # 키 ID
npx wrangler secret put APNS_TEAM_ID --config wrangler.local.toml   # 팀 ID
```

번들 ID가 `com.taption.plan`이 아니면 `APNS_TOPIC`을 따로 둡니다. 키 값은 저장소·로그·채팅에 남기지 않습니다.

## 카카오 검색 중계(REV1110A03)

`GET /kakao/keyword?query=…&x=…&y=…&sort=…&radius=…&size=…` → 카카오 로컬 키워드 검색을 대신 부릅니다. 카카오 REST 키는 서버용이라 앱에 넣지 않고 Worker 비밀값으로만 둡니다(IP당 1분 60번). SEC1110A02부터 등록한 검색 키(설치마다) 또는 주인 키만 받고, 키마다 하루 500번입니다.

```sh
npx wrangler secret put KAKAO_REST_API_KEY --config wrangler.local.toml
```

비밀값이 없으면 `503`을 돌려주고, 앱은 Apple 검색만 씁니다.

## 고속도로 영업소·통행료 중계(TGT1118A01)

한국도로공사 고속도로 공공데이터 포털(data.ex.co.kr) OpenAPI를 대신 부릅니다. 사용자 좌표는 받지 않습니다. 앱이 영업소 목록을 통째로 받아 기기에서 지난 영업소를 알아내고, 요금은 영업소 코드와 차종만 보냅니다. 검색 키로 부르고 카카오와 같은 하루 한도를 씁니다.

- `GET /ex/units` → 영업소 위치(`openapi/locationinfo/locationinfoUnit`)의 모든 쪽을 모아 `{ units: [{ code, name, route, routeNo, lat, lng }], count }`. 코드는 앞뒤 공백을 지우고 같은 코드는 하나만 둡니다. `xValue`가 경도, `yValue`가 위도입니다. 7일 캐시(한 쪽이라도 실패하면 502, 캐시 안 함).
- `GET /ex/fare?from=<출발 영업소 코드>&to=<도착 영업소 코드>&car=<1~8, 기본 1>` → 영업소간 통행요금(`openapi/toll/bhoinstIntoTollList`, 요청 `dprtrTolofCd`·`arrvTolofCd`)의 `{ from, to, car, fares: [{ from, fromName, to, toName, operator, normal, distanceKm }] }`. `normal`은 `nrmlKnd<car>Amt`(정상요금), 거리는 2·4·6차로 합계 거리의 합입니다. 본선(개방식) 영업소는 출발과 도착을 같은 코드로 묻습니다. 1일 캐시.
- 명세: data.ex.co.kr `openapi/basicinfo/openApiInfoM?apiId=0123`(영업소 위치)·`apiId=0620`(영업소간 통행요금). 공공데이터포털 `15111644`가 이 링크로 이어집니다.

키는 data.ex.co.kr에 가입해 「OpenAPI 활용」에서 인증키를 받아 넣습니다(공공데이터포털 키와 다릅니다).

```sh
npx wrangler secret put EX_API_KEY --config wrangler.local.toml
```

비밀값이 없으면 두 경로 모두 `503 {"error":"ex_key_missing"}`을 돌려주고, 앱은 지금의 같은 길 통행료만 씁니다.

## 국내 공항 무료 항공편 조회(FLT1119A01)

공공데이터포털(data.go.kr)의 인천국제공항공사·한국공항공사 OpenAPI를 대신 부릅니다. 값은 한 모양으로 맞춥니다. 사용자의 항공편·예약번호·이름·전화번호는 받지도 저장하지도 않고, 받는 것은 공항 코드·날짜·방향·편명 같은 공개 값뿐입니다. 검색 키로 부르고 카카오와 같은 IP별 하루 한도를 씁니다.

```
GET /flights/schedule?airport=ICN&date=YYYY-MM-DD&direction=dep|arr[&flight=AB123][&airline=AB]
GET /flights/status?airport=ICN&date=YYYY-MM-DD&direction=dep|arr[&flight=AB123]
```

- 응답 `{ airport, date, direction, source: "season"|"status", updatedAt, flights: [{ flight, airline, origin, destination, time, dayOffset, terminal, gate, codeshare, master, season, validFrom, validTo, status }] }`. `schedule`은 정기 스케줄(요일·유효 기간을 그 날짜에 맞춰 거릅니다), `status`는 당일 운항현황이고 `status` 칸에 `{ state: ontime|delayed|departed|arrived|cancelled, scheduled, expected, delayMinutes, terminal, gate, baggage }`가 들어갑니다. 앱은 운항현황이 없으면 「정기 스케줄 기준」이라고 표시합니다.
- 당일 운항현황은 인천만 연결합니다. 다른 공항은 `{ available: false, flights: [] }`입니다. 운항현황 날짜는 D-3~D+6만 받고 밖이면 `422 date_out_of_range`입니다.
- 오류: 인자 틀림 `400 bad_query`, 비밀값 없음 `503 {"error":"flight_key_missing"}`(그 소스만), 상류 실패 `502 {"error":"upstream_failed"}`(상류 원문·키는 돌려주지 않음), 하루 예산 소진 `429 flight_daily_limit` + `Retry-After`.
- 캐시(`caches.default`): 정기 스케줄 7일, 당일 운항현황 90초. 편명·항공사 필터는 응답에서만 적용해 같은 캐시를 씁니다. 응답의 `updatedAt`을 앱이 보여 줍니다.
- 호출 예산: 상류를 부를 때마다 서버 전체 하루 예산을 1씩 세고(Durable Object `global:flights`) 캐시가 맞으면 세지 않습니다. 기본 400회, 환경 변수 `FLIGHT_DAILY_CALLS`로 조정합니다(개발계정 일 500회 안의 안전선).

**국내선 시각 필드(FLT1120A01).** 행에 선택 필드 셋이 더해졌습니다: `departureTime`(출발 공항 현지 `HH:mm`)·`arrivalTime`(도착 공항 현지 `HH:mm`)·`durationMinutes`(두 공항이 모두 한국이고 두 시각이 모두 있을 때만, 자정을 넘기면 +1440). `dep` 행의 `time`은 출발, `arr` 행의 `time`은 도착이며 출발·도착 칸 이름은 `FIELD.depTime`·`FIELD.arrTime`이다(키를 받은 뒤 probe로 확인). 상류에 없으면 `null`이고 앱은 짝 행 또는 거리 어림으로 되돌아갑니다. 정기 스케줄 캐시는 30분(`SCHEDULE_TTL`)입니다. 당일 운항현황(`/flights/status`)은 지금처럼 인천만이고 국내 공항은 `available:false`입니다(나중에 넓히면 `available:true`·`source:"status"`만 주면 앱이 「실시간」으로 표시). **배포는 아직 하지 않았습니다**(대표 몫).

**상류에서 확인한 것과 못 한 것(2026-11-20).** 공공데이터포털 상세 페이지로 확인한 것: 정기운항편 서비스 `apis.data.go.kr/B551177/StatusOfPaxFltSched`, 도착 조회 `getPaxFltSchedArrivalsDeOdp`, 요청 변수 `serviceKey`·`pageNo`·`numOfRows`·`type`·`airport`(인천 오는 편의 출발 공항)·`lang`, 개발계정 일 500회, 오류 코드 22(일 한도)·23(초당 한도). **응답 칸 이름은 그 페이지에 비어 있어 확인하지 못했습니다.** 그래서 `src/flights.js`의 `FIELD`에 후보 이름(대소문자 무시)을 두고 읽습니다. 출발 조회 이름, 당일 운항현황(`StatusOfPassengerFlightsOdp`), 한국공항공사 주소는 같은 계열을 따른 추정입니다. 키를 받은 뒤 아래 점검을 한 번 돌려, 없는 칸이 나오면 `FIELD`·`SOURCES`만 고칩니다.

```sh
ICN_API_KEY=<키> node scripts/flights-probe.mjs icnSchedule dep
ICN_API_KEY=<키> node scripts/flights-probe.mjs icnStatus dep
KAC_API_KEY=<키> node scripts/flights-probe.mjs kacSchedule dep GMP
```

점검 스크립트는 키를 출력하지 않고 값도 보여 주지 않습니다(칸 이름·줄 수·결과 코드·기대하는 칸이 있는지만).

### 배포 (대표님이 하는 일 — 아직 안 했습니다)

공공데이터포털에서 두 API 활용 신청으로 키를 받아 넣고 배포합니다. 키가 없는 소스는 503이 되고 앱은 「직접 입력 + 편명으로 검색」으로 넘어갑니다.

```sh
cd server/trip-relay
npx wrangler secret put ICN_API_KEY --config wrangler.local.toml
npx wrangler secret put KAC_API_KEY --config wrangler.local.toml
npx wrangler deploy --config wrangler.local.toml
```

## 등록·PIN·Durable Object·OAuth (SEC1110A02·AIR1110A03)

- `POST /register`: 앱이 만든 키만 등록(서로 다른 글자 20개 미만은 422). 등록하지 않은 키는 모든 경로에서 401.
- `POST /pin/reset`(REV1110A06): PIN을 잊었을 때 주인 키로만. PIN·잠금을 지우고 모든 연결 키·OAuth 연결·대기 코드를 끊는다. 주인마다 하루 3번.
- `POST /pin`·`GET /pin`(`{"set","locked","retryAfter"?,"lockedUntil"}`): `{"pin"}`(바꿀 때 `currentPin`도). 서버가 HMAC-SHA256(비밀 `PIN_PEPPER`, salt‖PIN)으로 검증값을 만들어 DEK로 잠가 둔다(SEC1110A03). `POST /keys`에 `"pin"` 필요, 15분에 5번 틀리면 15분 잠금(423). 비밀이 없으면 503.
- `setBubble`(BUB1110A01): 보이기만 하는 화랑이 말풍선. 80자(링크 빼고), https 링크 3개, 24시간 48개(명령 100개와 따로). 글은 허용 문법 하나로만 받는다(규격 4.2).
- 모든 429에 `Retry-After`와 본문 `retryAfter`.
- Durable Object `UserState`(`src/state.js`, SQLite 저장소): 주인마다 키 목록·영구 폐기 표시·명령 큐·24시간 한도·PIN 시도·요청 예산(주인 키 1분 120·하루 2,000, 연결들은 따로 함께 1분 120·하루 2,000이고 연결마다 1분 60·하루 1,000)·KV 쓰기 하루 600·카카오 하루 500·하루 기록 이름표(62줄까지). 같은 클래스를 `ip:<해시>`(IP마다 하루 등록·검색 수), `code:<해시>`(연결 코드), `global:<이름>`(서버 전체 하루 수)에도 쓴다. 요청은 인스턴스 안에서 차례로 처리합니다.
- 메타데이터 암호화: 감싼 기록 v3(범위·만료·주인이 암호문 안), 하루 기록 이름은 HMAC(날짜가 보이지 않음).
- MCP: 바꾸는 도구 `destructiveHint: true`, 사용자 글은 `{"untrusted_user_text": …}`로 감쌈. 새 동작(목표·여행·수면·안전한 설정).
- OAuth 2.1(`src/oauth.js`): `/.well-known/oauth-protected-resource`, `/.well-known/oauth-authorization-server`, `POST /oauth/register`, `/oauth/authorize`(연결 코드 + PIN + CSRF + CSP), `POST /oauth/token`(PKCE S256, access 8시간, refresh는 하루에 한 번 바뀜), 앱용 `POST /oauth/code`(기록은 KV가 아니라 DO).
- KV 쓰기 아끼기(REV1110A06): 같은 내용의 하루는 다시 쓰지 않고, `/oauth/register`는 IP당 하루 10·전체 200, 새 등록은 IP당 하루 20·전체 500, 서버 전체 쓰기는 `KV_DAILY_WRITE_BUDGET`(기본 900)에서 멈춰 429를 준다.
- 시험: `npm test`(가짜 KV와 진짜 `UserState`를 메모리 저장소 위에서 돌리는 가짜 DO, `test/fakes.mjs`).

규격 전체는 [docs/ACTIVITY_RELAY_API.md](../../docs/ACTIVITY_RELAY_API.md) 12~16장.

### 배포 (대표님이 하는 일)

배포 전에 알아 둘 것:

1. **되돌릴 수 없음**: `[[migrations]] new_sqlite_classes = ["UserState"]`는 처음 배포할 때 한 번 적용됩니다. 이전 Worker 버전으로 롤백해도 DO 클래스·저장소는 남고, 이전 코드는 DO를 모르므로 그 사이 DO에 들어간 명령·키 목록·PIN은 보이지 않습니다. 또 v3 감싼 기록·HMAC 이름·DO 큐로 옮긴 자료는 이전 코드가 읽지 못합니다. 롤백이 필요하면 앱 쪽에서 키를 다시 만들고 기록을 다시 올려야 합니다. 클래스 이름을 바꾸거나 지울 때는 `renamed_classes`·`deleted_classes` migration이 따로 필요합니다(지우면 그 저장소도 지워짐).
2. **빌드 305 이하 앱**: 등록이 필요해 `/plan` 중계가 앱을 업데이트할 때까지 멈춥니다(대표 결정). 앱 새 빌드를 먼저 TestFlight에 올리고, 서버는 그 빌드가 퍼진 뒤(또는 동시에) 배포하는 순서를 권합니다.
3. **PIN 비밀(필수)**: 배포 전에 `npx wrangler secret put PIN_PEPPER --config wrangler.local.toml`을 실행하고 무작위 32바이트 이상 값(예: `openssl rand -base64 48`의 출력)을 붙여 넣습니다. 없으면 PIN 확인이 모두 `503 pin_check_unavailable`입니다. 값을 바꾸거나 잃으면 모든 사용자의 PIN이 맞지 않게 됩니다. 저장소·로그·채팅에 남기지 마세요.
4. **무료 한도**: KV 하루 쓰기 1,000·지우기 1,000·목록 1,000, DO 요청 하루 10만·행 쓰기 10만. 요청마다 DO 예산 한 줄을 씁니다. OAuth 연결은 refresh마다(8시간에 한 번 쓸 때) KV 쓰기 1번, 하루에 한 번 refresh 토큰이 바뀔 때 2번입니다. 서버 전체 KV 쓰기는 `wrangler.toml`의 `KV_DAILY_WRITE_BUDGET`(기본 900)에서 멈추므로, 쓰는 사람이 늘면 유료 요금제로 바꾸고 이 값을 올려야 합니다.

배포 순서(`server/trip-relay`에서):

```sh
npx wrangler secret put PIN_PEPPER --config wrangler.local.toml   # 처음 한 번, 무작위 32바이트 이상
npm test                                              # 75개 통과 확인
npx wrangler deploy --dry-run --config wrangler.local.toml --outdir /tmp/relay-dry   # 바인딩 확인: USER_STATE, PLANS, POST_LIMIT(20/60s), KAKAO_LIMIT, REQUEST_LIMIT
npx wrangler deploy --config wrangler.local.toml      # migration v1-user-state가 함께 적용됨
npx wrangler deployments list --config wrangler.local.toml
curl -s https://trip.bokkiyaw.com/.well-known/oauth-authorization-server   # 200
curl -s -o /dev/null -w '%{http_code}\n' https://trip.bokkiyaw.com/plan -H "Authorization: Bearer $(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')"   # 401
```

`wrangler.toml`(공개용, KV id 자리표시)과 `wrangler.local.toml`(실제 KV id·도메인) 모두에 `USER_STATE` 바인딩과 migration, `REQUEST_LIMIT`이 들어 있습니다. 비밀값: `KAKAO_REST_API_KEY`(그대로), `PIN_PEPPER`(새로).

## 저장소를 KV에서 D1로 (D1R1119A01)

값 저장소가 Cloudflare KV(`PLANS`)에서 D1(`RELAY_DB`, 데이터베이스 `taption-trip-relay`)로 바뀝니다. 코드는 `env.PLANS.get/put/delete/list`를 그대로 부르고, `RELAY_DB`가 있으면 `src/d1kv.js`가 그 호출을 D1(표 `kv_entries`)로 처리합니다. 암호화(AES-GCM)는 그대로입니다. 위 「무료 한도」의 KV 하루 쓰기 1,000 설명은 D1 전환 뒤에는 D1 하루 10만 행 쓰기로 읽습니다.

- **쓰기·삭제는 D1에만**: 옛 KV에는 쓰지 않습니다.
- **읽기는 D1 먼저, 없으면 옛 KV**: 옛 KV 값을 읽으면 남은 TTL 그대로 D1로 복사합니다(Lazy Migration). 옛 KV 바인딩이 없어도 동작합니다.
- **삭제 표식**: 옛 KV에 같은 키가 남아 있을 때만 D1에 「삭제됨」 행을 두어 되살아나지 않게 합니다(만료는 옛 항목과 같게).
- **list**: D1 결과와 옛 KV의 아직 옮기지 않은 키를 합쳐 이름순으로 돌려주고, cursor는 「마지막으로 준 이름」입니다. 옛 KV는 접두어 아래를 끝까지 읽으므로 옛 KV에 키가 많으면 읽기가 늘어납니다(이관 뒤 바인딩을 떼면 사라짐).
- **쓰기 예산**: D1 무료 하루 10만 행 쓰기에 맞춰 서버 전체 `KV_DAILY_WRITE_BUDGET` 80000, 주인별 하루 5000으로 올렸습니다(변수 이름의 KV는 옛 이름 그대로).

### D1 배포 (대표님이 하는 일)

`wrangler.toml`(공개)에는 `database_id = "REPLACE_WITH_D1_DATABASE_ID"` 자리표시만 있고, 실제 id는 git에 없는 `wrangler.local.toml`의 같은 `[[d1_databases]]` 블록에 넣습니다(KV id를 넣던 방식 그대로).

```sh
npx wrangler d1 create taption-trip-relay                # 출력되는 database_id를 wrangler.local.toml의 [[d1_databases]]에 넣는다
npx wrangler d1 migrations apply taption-trip-relay --remote --config wrangler.local.toml
npm test
npx wrangler deploy --config wrangler.local.toml
```

**옛 KV 바인딩 제거(D1R1119A02, 2026-11-19)**: 기다리지 않고 `scripts/kv-to-d1.mjs`로 옛 KV에 남은 키 133개를 D1로 일괄 복사(`INSERT OR IGNORE`라 D1의 새 값·삭제 표식은 안 덮음, 값은 출력하지 않음)한 뒤, 모든 키가 D1에 있음을 확인하고 두 toml에서 `[[kv_namespaces]] PLANS` 블록을 지웠다. `wrangler.local.toml`을 새로 만들 때는 KV 블록 없이 `[[d1_databases]]`만 둔다. 이 스크립트는 옛 KV가 다시 필요한 때(되돌리기)에만 쓴다.

```sh
node scripts/kv-to-d1.mjs --config wrangler.local.toml --out /tmp/kv-to-d1.sql          # SQL만 만든다(읽기만)
node scripts/kv-to-d1.mjs --config wrangler.local.toml --out /tmp/kv-to-d1.sql --apply  # D1에도 적용
```

## 공용 공지·정적 데이터 (R2PUB1119A01)

모두에게 같은 공지·POI 팩·온디바이스 모델을 R2 버킷(`PUBLIC_BUCKET`, `taption-trip-public`)에서 **읽기 전용**으로 줍니다. 인증·CORS·속도 제한은 없고(앱은 네이티브), `route()`에서 공용 표 바로 뒤, `USER_STATE` 확인 앞에서 가로챕니다(`src/public.js`). Worker에는 R2 `put`/`delete` 호출이 없고, 주인 키·AI 키·OAuth 토큰은 이 길에서 읽지 않으며, R2 자격 증명은 비밀값으로도 두지 않습니다(바인딩만).

| 경로 | 응답 |
| --- | --- |
| `GET /public/announcements` | 버킷 `announcements/latest.json`을 **고치지 않고** 그대로. 200 + `etag` + `cache-control: public, max-age=300`. 바인딩·파일이 없거나 JSON이 깨졌거나 `items`가 배열이 아니면 항상 200 `{"version":0,"items":[]}` + `no-store`. `If-None-Match`가 맞으면 304 |
| `GET /public/assets/<접두어>/<파일…>` | 접두어는 `announcements`·`packs`·`models`만. 없으면 404, 200은 `etag`·`accept-ranges: bytes`·`content-type`, `Range`는 206 + `content-range`, 잘못된 범위는 416, `If-None-Match`는 304. `announcements/`는 `max-age=300`, 나머지는 `max-age=86400` |
| 그 밖의 메서드 | 405 + `allow: GET`(HEAD 포함) |

키 모양: 각 칸은 `^[A-Za-z0-9][A-Za-z0-9._-]*$`, 8칸·200자 이하. `%`·공백·역슬래시·빈 칸(`//`)·`.`으로 시작하는 칸은 정규화하지 않고 **400**으로 거부합니다. 그래서 올리는 파일 이름도 영문·숫자·`.`·`_`·`-`만 씁니다. `..`·`%2e%2e` 칸은 URL 해석기가 먼저 걷어내므로 허용 접두어 밖이 되어 404입니다. 파일 이름 없이 `/public/assets/packs/`만 오면 404입니다. 엣지 캐시(`caches.default`)가 있으면 공지 200 응답만 `max-age`만큼 캐시하고, 없으면(시험·로컬) 그냥 R2로 갑니다.

### 공지 JSON 스키마 초안

`version`은 올릴 때마다 1씩 올리는 정수(`0`은 서버가 주는 「아직 없음」). 서버는 아래 시각·빌드 조건으로 거르지 않습니다 — 거르는 일은 앱 몫입니다. 예: `test/fixtures/public-announcements.json`.

| 필드 | 필수 | 형식·한도 | 뜻 |
| --- | --- | --- | --- |
| `version` | 필수 | 1 이상 정수 | 공지 묶음의 판 |
| `items` | 필수 | 배열, 최대 50개 | 공지 목록 |
| `items[].id` | 필수 | `[a-z0-9][a-z0-9._-]{0,63}` | 바뀌지 않는 식별자(앱의 「읽음」 표시) |
| `items[].title` | 필수 | 1~100자 평문 | 제목 |
| `items[].body` | 필수 | 1~2000자 평문(HTML·마크다운 금지) | 본문 |
| `items[].kind` | 필수 | `info`·`update`·`warning`·`critical` | 표시 분류, 이 순서가 곧 심각도 |
| `items[].startsAt` | 선택 | ISO 8601(오프셋 포함) | 이때부터 보임. 없으면 즉시 |
| `items[].expiresAt` | 선택 | ISO 8601 또는 `null` | 이때부터 안 보임. 없으면 계속 |
| `items[].minBuild` | 선택 | 정수 | 이 빌드 미만 앱에는 안 보임 |
| `items[].maxBuild` | 선택 | 정수 또는 `null` | 이 빌드 초과 앱에는 안 보임 |
| `items[].link` | 선택 | `https://`, 300자 이내 | 「자세히」로 열 주소 |
| `items[].titleByLang`·`bodyByLang` | 선택 | `{"en": "…", "ja": "…"}` | 다른 언어. 없으면 `title`·`body`(기본 한국어) |

공지를 올리거나 바꾸거나 내릴 때는 아래 명령을 손으로 치는 대신 `scripts/announce.mjs`(BRG1119A01)를 씁니다: 지금 올라간 공지에 합치고(`version`은 +1) 스키마를 검사해 미리보기를 보여 주며, `--upload`를 붙여야만 R2에 올립니다(`--remote` 자동). 예: `node scripts/announce.mjs --host <앱이 쓰는 중계 서버 주소> --title "점검 안내" --body "…" --kind warning --upload`. 비야의 공지 게시 요청 절차는 `pickle-bridge/README.md` 10절.

### R2 배포·업로드 (대표님이 하는 일 — 아직 안 했습니다)

```sh
npx wrangler r2 bucket create taption-trip-public
# wrangler.local.toml의 [[d1_databases]] 아래에 wrangler.toml과 같은 [[r2_buckets]] PUBLIC_BUCKET 블록을 넣는다
npm test
npx wrangler deploy --config wrangler.local.toml
```

업로드는 이 CLI뿐입니다(공용 버킷에 쓰는 길은 이것 하나, 앱 키로는 읽기만). **Wrangler v4부터 `wrangler r2 object`는 `--remote` 없이는 로컬 시뮬레이터에만 쓰므로**, 올린 것처럼 보여도 실제 버킷에는 없습니다. 반드시 `--remote`를 붙입니다.

```sh
npx wrangler r2 object put taption-trip-public/announcements/latest.json \
  --file ./announcements.json --content-type application/json \
  --cache-control "public, max-age=300" --remote --config wrangler.local.toml
```

POI 팩·모델도 같은 방식(`packs/…`, `models/…`). 배포 뒤 확인: `curl -s -o /dev/null -w '%{http_code}\n' <앱이 쓰는 중계 서버 주소>/public/announcements`가 200, `-H 'If-None-Match: <받은 ETag>'`로 304, 없는 파일은 404.

무료 한도(2026-11-19 Cloudflare 문서 기준): R2 저장 10GB·월, Class A(쓰기·목록) 월 100만, Class B(읽기) 월 1,000만, 나가기 전송료 무료. Worker 요청은 무료 계정 하루 10만 건에 함께 세어지므로 공지는 엣지 캐시로 R2 읽기를 줄입니다. 유료 전환은 대표 결정 없이 하지 않습니다. iOS 연동(언제·얼마나 자주 부르는지, `kind`별 표시, 읽음 표시)은 이번 범위가 아니며 별도 후속 요청입니다.

## 오분류 교정 표본 모으기 (CLS1119A01)

앱의 「분류 개선 데이터 수집」(MSC1119A01)을 켠 사용자가 **「보내기」를 눌렀을 때만** 올리는 비식별 표본을 D1 표 `misclass_samples`에 쌓습니다(마이그레이션 `migrations/0002_misclass_samples.sql`). 앱의 「서버로 보내기」(MSC1119B01)가 이 경로를 부르고, 모인 표본은 `scripts/classifier-report.mjs`로 맥에서 집계합니다(아래). 코드는 `src/classifier.js`.

| 경로 | 누가 | 응답 |
| --- | --- | --- |
| `POST /classifier-samples` | 주인 키 | 본문 `{"format":"bokki-misclassification","version":1,"ruleVersion":"…","samples":[1~200개]}`, **1MB까지**. `201` `{"ok":true,"accepted":n,"duplicates":n,"rejected":n}`. 같은 `id`는 무시, 허용 목록에 안 맞는 표본은 그 표본만 `rejected`. `422` 형식·건수 틀림, `413` 1MB 초과, `429 classifier_daily_limit` 하루 2,000건 초과(24시간 창, `retry-after: 3600`) |
| `DELETE /classifier-samples` | 주인 키 | `200` `{"ok":true,"deleted":n}` 내가 올린 표본을 모두 지운다 |
| `GET /classifier-samples/admin?since=<seq>&limit=<1~500>` | 운영자 토큰 | `200` `{"format","version","samples":[{"seq":n,…표본}],"next":seq}`. `CLASSIFIER_ADMIN_TOKEN`(32자 이상 비밀값)이 없으면 `503`, 틀리면 `401`. 주인·받은 시각은 내주지 않는다 |

- **허용 목록 검사**: 표본은 앱 형식의 열쇠(15개, 특징 9개)와 일치해야 하고, 문자열은 짧은 영문 코드 모양(`^[a-z][A-Za-z0-9_-]{0,31}$` 등)만 받습니다. 한글·공백·긴 글·모르는 열쇠·범위 밖 숫자는 거부합니다. 그래서 좌표·이름·제목이 실수로 들어와도 저장되지 않습니다.
- **저장**: `owner`는 주인 키 유래 해시(하루 한도·「내 표본 지우기」용)로 표본 안에 없고, 받은 시각(`received_at`)은 보관 기간과 하루 한도에만 씁니다.
- **보관 1년**(대표 결정 2026-11-19): 올릴 때마다 1년이 지난 표본을 지웁니다(예약 작업 없음).
- **한도**(대표 결정 2026-11-19): 한 번 200건·1MB, 하루 2,000건(주인별).

### 맥에서 표본 집계 (MSC1119B02)

```sh
CLASSIFIER_ADMIN_TOKEN=… node scripts/classifier-report.mjs --host <중계 서버 주소> [--rule-version classifier-v1r4] [--min-count 5] [--json] [--save 표본.json]
node scripts/classifier-report.mjs --token-file <토큰 파일> --host <주소>   # 토큰을 셸 기록에 남기지 않으려면
node scripts/classifier-report.mjs --input 표본.json                       # 받아 둔 표본으로 다시 집계(서버를 부르지 않음)
```

`GET /classifier-samples/admin`을 500건씩 끝까지 읽어(읽기만 합니다) 「자동 분류 → 사용자 분류」 쌍별로 건수·시간대·요일·움직임·속도·확신도를 집계하고, 같은 쌍이 `--min-count`건(기본 5) 이상 반복된 것을 규칙 고칠 후보로 문장으로 요약합니다(예: 확신도 high인데 틀림 → 점수 구간 재보정, 직접 만든 분류 반복 → 새 상세 분류, 이동수단 경계 속도 점검). 토큰은 환경변수나 `--token-file`로만 받고 출력·로그에 쓰지 않으며, 서버 주소도 인자로만 받습니다. `--save`는 표본 원본을 파일로 남기므로 저장소 밖에 둡니다. 시험은 `test/classifier-report.test.mjs`.

### 배포 (대표님이 하는 일 — 아직 안 했습니다)

```sh
npx wrangler d1 migrations apply taption-trip-relay --remote --config wrangler.local.toml   # 0002 적용
npx wrangler secret put CLASSIFIER_ADMIN_TOKEN --config wrangler.local.toml                  # 32자 이상 임의 문자열(학습용 읽기)
npm test
npx wrangler deploy --config wrangler.local.toml
```

마이그레이션 없이 배포하면 표가 없어 `POST`가 `500`입니다. 순서를 지켜 주세요. 앱 빌드 354는 이 경로를 아직 부르지 않으므로 서버만 배포해도 사용자에게 달라지는 것은 없습니다. 「서버로 보내기」가 든 앱 빌드가 나가려면 이 배포가 먼저여야 합니다(없으면 앱이 500을 받아 「서버가 받지 못했어요」를 보입니다).

## 여행 공유 방(TSH1114A26)

`/share/rooms`(방 만들기, 앱 등록 키)와 `/share/rooms/<방 id>/…`(입장·따라잡기·쓰기·잠금·공지 확인·WebSocket, 방의 참여 토큰). 방마다 Durable Object `ShareRoom` 하나이고 기기가 암호화한 덩어리만 둡니다. 규약 전체는 [docs/TRIP_SHARE_PROTOCOL.md](../../docs/TRIP_SHARE_PROTOCOL.md).

배포하려면 `wrangler.local.toml`에도 `wrangler.toml` 끝의 `SHARE_ROOM` 바인딩과 migration `v2-share-room`을 더합니다. 없으면 `/share/…`만 503이고 나머지는 그대로입니다. 새 비밀값은 없습니다.

배포 뒤 확인: 앱 새 빌드로 실행 → 「AI 연결」에서 PIN 설정 → 연결 키 만들기 → claude.ai 사용자 지정 커넥터에 `https://trip.bokkiyaw.com/mcp` 추가 → 앱의 연결 코드와 PIN으로 승인 → 「AI 연결」에 Claude가 연결됨으로 보이는지.

## 공통 규칙 (SRL1116A01)

운영자가 서명한 규칙 묶음을 모든 앱이 받아 쓰고, 동의한 사용자의 기기가 거른 후보를 모아 대표가 검토한다. 설계와 배포 순서는 `docs/SHARED_RULES_PLAN.md`.

- 앱: `GET /shared/rules?since=<판>`(등록된 검색·주 키, 같으면 304), `POST /shared/candidates`(주 키, 동의한 사용자만).
- 운영자: `GET /shared/admin/bundle`, `GET /shared/admin/candidates?min=2`, `DELETE /shared/admin/candidates?fps=a,b`, `POST /shared/admin/publish {payload, signature}`. `Authorization: Bearer <SHARED_RULES_ADMIN_TOKEN>`. 보통은 `scripts/shared-rules/admin.mjs`로 쓴다.
- 비밀값(둘 다 없으면 관리 길은 503): `npx wrangler secret put SHARED_RULES_PUBLIC_KEY`(Ed25519 공개 키 base64), `npx wrangler secret put SHARED_RULES_ADMIN_TOKEN`(32자 이상). 서명 개인 키는 서버에 두지 않는다.
- 저장: Durable Object 인스턴스 `shared:rules`(묶음 하나·후보 지문별 한 줄, 누가 올렸는지는 적지 않음)와 사용자 인스턴스의 `sharedSent`(올린 지문) 및 하루 수.

