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

## 카카오 검색 중계(REV1110A03)

`GET /kakao/keyword?query=…&x=…&y=…&sort=…&radius=…&size=…` → 카카오 로컬 키워드 검색을 대신 부릅니다. 카카오 REST 키는 서버용이라 앱에 넣지 않고 Worker 비밀값으로만 둡니다(IP당 1분 60번). SEC1110A02부터 등록한 검색 키(설치마다) 또는 주인 키만 받고, 키마다 하루 500번입니다.

```sh
npx wrangler secret put KAKAO_REST_API_KEY --config wrangler.local.toml
```

비밀값이 없으면 `503`을 돌려주고, 앱은 Apple 검색만 씁니다.

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

배포 뒤 확인: 앱 새 빌드로 실행 → 「AI 연결」에서 PIN 설정 → 연결 키 만들기 → claude.ai 사용자 지정 커넥터에 `https://trip.bokkiyaw.com/mcp` 추가 → 앱의 연결 코드와 PIN으로 승인 → 「AI 연결」에 Claude가 연결됨으로 보이는지.
