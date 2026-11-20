# taption-plan 서버 코드 검토 — server/trip-relay

- 검토일: 2026-11-20
- 범위: `server/trip-relay/src/*.js`(24개 파일, 약 8,000줄), `test/*.mjs`(참고용)
- 방법: 전수 읽기 + `rg` 패턴 검색(예외 삼킴, 로그, 경쟁, 중복 상수) + 테스트 대조. 코드 근거가 있는 것만 적음.
- 이 문서는 검토만 한다. 코드를 수정하지 않았다.

## 이미 알려진 항목 확인

- **AIR1114A01 (완료 보고 동시 도착 시 덮어쓰기) — 확인됨(대부분 완화, 잔여 있음).**
  직접 덮어쓰기는 막혀 있다: `src/state.js:227-235 taskFinish`가 DO 안에서 직렬로 돌며, 끝난 일은 `already_finished`(232행), 남이 맡은 일은 `not_claimer`(233행)로 거절한다. `taskClaim`(`state.js:211`)도 DO 직렬화 안에서만 맡는다.
  잔여: `taskFinish`의 맡은이 검사는 `processing` 상태일 때만 한다(233행). `waiting`·`asked` 상태의 일은 맡지 않고도 어떤 연결이든 끝낼 수 있어, 두 AI가 같은 일을 보고 결과를 내면 나중 것이 409로 버려진다(선착순, 병합 없음). 이 항목은 다시 제안하지 않고 확인만 적는다.
- **P13 (옛 KV 일 코드·옛 별칭·옛 키 제거) — 건드리지 않음.** `LEGACY_PLAINTEXT_UNTIL`(`src/crypto.js`)이 2026-11-15로 이미 지났고 평문 경로는 죽은 코드가 됐지만, P13 범위라 제안하지 않는다.
- **서버 배포 — 제안하지 않음.**

---

## P0 — 바로 고칠 것

### S1. 쓰기 AI가 사용자가 만든 규칙을 켜고 끌 수 있음 (권한 검사 누락)
- **파일:줄** — `src/rules.js:153-157`(`setRuleEnabled`), `src/state.js:315-345`(`ruleOps`)
- **문제** — MCP `set_rule_enabled` 도구는 `ruleOps`를 `onlyAI` 없이 부른다. `ruleOps`의 켜기·끄기 분기(`state.js:339-344`)에는 규칙 주인(`by`) 검사가 없다. 반면 같은 파일의 `rulePut`(`state.js:291`)은 AI가 사용자 규칙을 고치면 거부하고, `deleteRules`(`src/rules.js:148`)는 AI에게 `onlyAI: true`를 넘긴다. 즉 AI는 사용자 규칙을 고치거나 지우지는 못하지만 **끄는 것은 가능**해, 사용자가 켜 둔 결제·분류 규칙을 무력화할 수 있다. REST `/rules/ops`는 master 전용이라 안전하고, MCP `set_rule_enabled` 경로만 뚫려 있다.
- **고치는 방법** — `setRuleEnabled`에서 `ruleOps`를 부를 때 `onlyAI: ctx.auth?.kind !== "master"`를 넘기고, `ruleOps`의 켜기·끄기 분기에도 삭제와 같은 검사(`if (onlyAI && rule.by === "user") continue;`)를 넣는다.

### S2. 카카오·사진·구글 중계에서 fetch 예외를 안 잡음 (처리되지 않은 500)
- **파일:줄** — `src/index.js:66`(`kakaoKeyword`), `:84`(`kakaoImage`), `:162`(`photoSearch`), `:176`·`:189`(`googlePhoto`)
- **문제** — 다섯 곳 모두 `await fetcher(...)`를 try/catch 없이 부른다. 상류 네트워크 오류·DNS 실패로 fetch가 throw하면 Worker가 그대로 터져 500(Cloudflare 기본 오류)이 나간다. 같은 파일의 `relayBus`(`:231`)와 `src/directions.js:60`, `src/flights.js:214`, `src/expressway.js:62`는 모두 try/catch로 502를 돌려준다. 즉 이 네 함수만 예외 처리가 빠져 있다.
- **고치는 방법** — 다섯 곳의 fetch를 try/catch로 감싸고, 실패 시 `json({ error: "upstream_failed" }, 502)`(또는 기존 `upstream` 502 규약)를 돌려준다. `kakaoKeyword`의 `await upstream.text()`도 같은 try 안에 넣는다.

### S3. `/public/*`이 모든 속도 제한을 우회함 (R2 이그레스 남용)
- **파일:줄** — `src/index.js:596-603`(`route()`), `src/public.js:1-3`
- **문제** — `route()`가 `publicAssets()`(599행)를 `limited()` 검사(603행)보다 먼저 부른다. `/public/assets/*`는 인증·속도 제한 없이 R2 객체를 그대로 내주는데, `mlpackage`·`zip` 같은 큰 파일도 된다(`src/public.js` CONTENT_TYPES). 한 IP가 큰 모델 파일을 반복 요청하면 R2 이그레스 비용·대역폭을 소진할 수 있다. `public.js` 주석에 "속도 제한도 없다"고 적혀 있어 의도된 설계로 보이나, 코드 차원의 방어가 전혀 없다.
- **고치는 방법** — (a) `/public/assets/*`에만 `limited(env.REQUEST_LIMIT, request)`를 `publicRoute` 안에서 적용하거나, (b) Cloudflare 대시보드의 속도 제한 규칙으로 `/public/assets/*`를 묶고 그 결정을 `wrangler.toml` 주석 또는 README에 적는다. 공지(`/public/announcements`, 작고 캐시됨)는 현행 유지가 합리적이다.

### S4. 일(task)이 100개를 넘으면 열린 일도 조용히 지워짐 (데이터 소실)
- **파일:줄** — `src/state.js:184-205`(`taskAdd`), 특히 `:198-203`
- **문제** — `taskAdd`는 목록이 `LIMITS.tasks`(100개)를 넘으면 끝난 것부터, 없으면 가장 오래된 것부터 `s.delete`로 지운다. 열린 일(`waiting`·`processing`·`asked`)이 100개를 넘으면 **열린 일이 상태 변경 없이 그냥 사라진다**. 실패·만료 표시도, `gone` 목록 기록도 없다. 앱이 올린 일이 서버에서 흔적 없이 없어진다.
- **고치는 방법** — 열린 일을 버릴 때는 삭제 대신 `status: "failed", code: "overflow"`(또는 `expired`)로 바꾸고 `sealed`를 비워, 앱이 `GET /tasks`로 소실을 확인할 수 있게 한다. 또는 열린 일이 100개에 찼으면 새 일 추가를 `too_many_tasks`(409/429)로 거절한다. 둘 중 하나를 택하고 주석에 적는다.

### S5. 명령 결과·활동 추가 칸 저장이 KV 읽기-수정-쓰기 경합에 노출됨
- **파일:줄** — `src/store.js:558-569`(`saveResults`), `src/store.js:332-341`(`saveExtras`)
- **문제** — 두 곳 모두 KV에서 읽고(`get`), 메모리에서 합치고(`filter`·`concat`·`slice`, 필드 병합), 다시 쓴다(`put`). DO를 거치지 않으므로 두 요청이 동시에 오면 한쪽의 병합 결과가 사라진다. `saveResults`는 앱이 명령 처리 결과를 올릴 때(두 기기가 같은 주인 키를 쓰거나 재시도가 겹치면 발생 가능), `saveExtras`는 하루 기록 업로드 시 goals·trips·placeBook을 합칠 때 해당한다. 명령 큐·일은 DO로 옮겼는데 이 두 병합 쓰기만 KV에 남아 있다.
- **고치는 방법** — (a) 두 값을 DO로 옮겨 `state.js`에 `resultAppend`·`extrasMerge` 같은 op을 두고 직렬화하거나, (b) 당장은 앱이 재시도 시 전체를 다시 올리도록 하고, 서버는 마지막 쓰기 승리(last-write-wins)를 문서화한다. (a)가 정석이다.

---

## P1 — 다음으로 고칠 것

### S6. 설정 링크(`/s/<코드>`) 읽기 횟수 경합 — 3회 제한을 넘길 수 있음
- **파일:줄** — `src/setup.js:44-72`(`readSetup`), 특히 `:61-69`
- **문제** — 읽기 횟수를 KV에서 읽고(`reads`), +1한 뒤 다시 봉인해 쓴다. 락·CAS가 없어 두 GET이 동시에 오면 둘 다 `reads: 0`을 읽고 둘 다 `reads: 1`을 써, 링크가 3회가 아니라 4회 이상 읽힌다. 키가 든 안내문이라 횟수 제한이 보안 경계인데, 동시 요청으로 우회된다. 순차 읽기 테스트(`test/polish.test.mjs:84-99`)만 있고 동시성 테스트는 없다.
- **고치는 방법** — 횟수를 DO(`code:<해시>` 인스턴스의 `takeCode` 패턴, `src/state.js`의 `takeCode` 참고)로 옮겨 직렬화하거나, 읽기 횟수를 3회가 아니라 "읽은 시각" 기반으로 바꾸고 여유를 둔다. 가장 작은 수정은 DO에 `setupRead` op을 두는 것이다.

### S7. 한 AI가 다른 AI의 규칙을 지울 수 있음 (만든 이 검사 없음)
- **파일:줄** — `src/rules.js:145-150`(`deleteRules`), `src/state.js:315-337`(`ruleOps`)
- **문제** — `deleteRules`는 AI에게 `onlyAI`를 넘기지만, `ruleOps`의 삭제 분기(`state.js:334`)는 `rule.by === "user"`만 건너뛸 뿐, 규칙에 저장된 `keyId`와 지우는 연결의 `keyId`를 비교하지 않는다. MCP `delete_rule` 설명은 "Delete rules you (an AI) saved"인데, 실제로는 연결 A가 연결 B가 만든 AI 규칙을 지울 수 있다. `rulePut`도 같은 id면 다른 AI의 규칙을 덮어쓴다(`state.js:291-312`, `keyId` 비교 없음).
- **고치는 방법** — `ruleOps`에 호출자의 `keyId`를 넘기고, `onlyAI`일 때 `rule.by === "ai" && rule.keyId && rule.keyId !== callerKeyId`면 건너뛰거나 `forbidden`을 돌려준다. `rulePut`의 덮어쓰기에도 같은 검사를 적용한다. (의도된 공유 동작이라면 MCP 설명을 "any AI rule"로 고친다.)

### S8. `addPaymentRule` 명령이 정규식 안전 검사를 안 함 (`put_rules`와 불일치)
- **파일:줄** — `src/validate.js:462-465`(`isCommand`의 `addPaymentRule`), 대조: `src/rules.js`의 `safePattern`·`RULE_TYPES.payment_text`
- **문제** — `put_rules`의 `payment_text` 규칙은 `safePattern`(되돌아보기·역참조·겹친 반복 거부, 300자·묶음 12개 상한)으로 검사하지만, `addPaymentRule` 명령은 길이 300자만 보고 `(?<amount>` 포함 여부만 확인한다. `(?<amount>(a+)+)` 같은 지수 시간 패턴이 그대로 큐에 들어가 앱(iOS NSRegularExpression)이 평가하게 된다. 결제 문자 본문은 짧아 실제 위험은 낮지만, 같은 정규식을 받는 두 경로의 검사 수준이 다르다.
- **고치는 방법** — `validate.js`의 `addPaymentRule` 검사에 `safePattern`을 재사용한다. (`rules.js`가 `validate.js`를 안 불러오므로 순환 참조 없이 `validate.js`에서 `rules.js`를 import하거나, `safePattern`을 `actions.js` 같은 공용 모듈로 옮긴다.)

### S9. 규칙 ops의 `baseVersion`이 어긋나도 그대로 적용됨 (낙관적 동시성 미적용)
- **파일:줄** — `src/rules.js:129-142`(`applyRuleOps`), 특히 `:140`
- **문제** — 앱이 보낸 `baseVersion`이 서버의 적용 전 버전(`result.before`)과 다르면 `stale: true`만 붙이고 ops는 전부 적용한다. 두 기기·앱과 AI가 동시에 규칙을 고치면 한쪽의 변경이 조용히 덮인다. `stale` 플래그만으로는 충돌을 막지 못한다.
- **고치는 방법** — `baseVersion`이 주어졌는데 어긋나면 ops를 적용하지 않고 `409 { error: "stale_version", version: result.before }`를 돌려준다. (앱이 `stale`을 받고 다시 읽어 재시도하는 흐름이라면 그 동작을 주석·문서에 명시하고 현행을 유지한다.)

### S10. 분류 표본 하루 한도 검사가 검사-후-삽입 경합에 노출됨
- **파일:줄** — `src/classifier.js:77-86`(`upload`)
- **문제** — `SELECT COUNT(*)`으로 오늘 올린 수를 보고(77행) 한도를 넘지 않으면 `INSERT`한다(82-84행). 트랜잭션·락이 없어 두 업로드가 동시에 오면 둘 다 한도를 통과해 하루 2,000건을 넘길 수 있다. 같은 이유로 `accepted` 수도 동시 업로드가 섞이면 어긋난다(전후 COUNT 차이로 계산, 81·85-86행).
- **고치는 방법** — D1 `batch` 안에서 `INSERT ... SELECT ... WHERE (SELECT COUNT(*) ...) < 2000` 형태로 한 번에 처리하거나, 업로드 수를 주인 DO의 `countDaily`로 세어 직렬화한다. `accepted`는 `INSERT`의 변경 행 수(`changes`)로 계산한다.

### S11. 검색 예산이 잘못된 요청(400·503)에도 차감됨
- **파일:줄** — `src/state.js`의 `admit`(카카오 수 세기), `src/index.js`의 `authorized`(admit이 핸들러보다 먼저 돎), `src/index.js:340-360` 부근의 `kakaoRoute`·`tagoRoute`·`expresswayRoute`·`flightsRoute`(IP 수 세기)
- **문제** — 키당 하루 500건(`LIMITS.kakaoPerDay`)과 IP당 하루 2,000건(`LIMITS.kakaoPerIpDay`)이 핸들러의 입력 검증보다 먼저 차감된다. 쿼리가 틀려 400이 나거나, 서버 키가 없어 503이 나는 요청도 예산을 먹는다. 잘못된 요청을 반복하면 정상 검색 예산을 고갈시킬 수 있다.
- **고치는 방법** — IP 수 세기는 핸들러가 쿼리 검증을 통과한 뒤로 옮기거나(경량 검증만 라우터에서 먼저 수행), 키당 카카오 수는 `admit`이 아니라 각 중계 핸들러가 상류를 부르기 직전에 DO `countDaily`로 센다. 둘 다 바꾸기 크면, 최소한 서버 키가 없을 때(503 확정)는 세지 않게 한다.

### S12. 방 만들기 예산이 실패(409)에도 차감됨
- **파일:줄** — `src/share.js:765-769`(`createRoom`)
- **문제** — 주인당 하루 5개·서버 전체 하루 300개의 방 만들기 수를 DO `create` 호출보다 먼저 센다. 이미 있는 방 id로 만들어 409 `room_exists`가 나도 예산이 차감된다. 같은 id를 반복 시도하면 하루 몫을 소진할 수 있다.
- **고치는 방법** — DO `create`의 결과를 보고 201일 때만 수를 세도록 순서를 바꾸거나(두 번 호출이 필요해지면 DO `create` 안에서 수를 세게 합친다), 409일 때 차감분을 되돌리는 `refundDaily` op을 둔다.

### S13. 영업소 좌표 캐시 쓰기가 쓰기 예산을 우회함
- **파일:줄** — `src/expressway.js:123`·`:127`(`locate`의 `store.put`)
- **문제** — `geo:<코드>` 캐시 쓰기(찾음 1년·못 찾음 30일)가 `chargeWrites` 없이 `env.PLANS`에 직접 쓴다. 목록을 한 번 만들 때 최대 24건(`GEO_CALLS_PER_BUILD`)까지 쓰는데, 서버 전체 하루 쓰기 예산(8만 건) accounting에서 빠진다. 규모는 작지만 예산의 전제가 깨진다.
- **고치는 방법** — `exUnits`가 캐시를 만들 때 쓸 geo 행 수를 미리 세어 `chargeWrites`를 부르거나, `locate`의 쓰기를 예산 대상에서 빼는 결정을 주석으로 명시한다.

### S14. 하루 기록 이전(ensureDays) 중 예외가 나면 DO 잠금이 60초간 남음
- **파일:줄** — `src/store.js:270-303`(`ensureDays`), `claim` 272행·`release` 303행
- **문제** — `claim("days")` 뒤 KV 읽기·쓰기 중 예외가 나면 `release`에 닿지 않는다(try/finally 없음). 잠금은 1분 뒤 만료(`LIMITS.lockMs`)되어 자가 복구되지만, 그 사이 다른 요청은 `saveActivity`에서 503 `migrating`을 받는다.
- **고치는 방법** — `claim` 이후 본문을 try/finally로 감싸고 finally에서 `release`를 부른다.

### S15. 등록 표시 쓰기 실패 시 재등록이 등록 예산을 계속 먹음
- **파일:줄** — `src/keys.js:264-267`(`registerRoute`)
- **문제** — 전역 쓰기 예산이 바닥나면 `reg:<해시>` 표시 쓰기를 조용히 건너뛴다(`if (charge.ok)`). 표시가 없으면 앱이 켤 때마다 다시 등록할 때마다 IP·전역 등록 수(하루 20·500건)를 센다. 예산 부족이 계속되면 재등록만으로 전역 등록 한도를 소진할 수 있다.
- **고치는 방법** — 표시 쓰기에 실패하면 등록 자체를 429 `write_budget_exhausted`로 돌려주거나(앱이 나중에 다시 시도), DO `register`의 `created: false` 응답을 보고 표시 쓰기를 재시도한다.

### S16. 같은 연결 키를 동시에 두 번 등록하면 범위·만료가 어긋날 수 있음
- **파일:줄** — `src/keys.js:315-350`(`addKeys`), `src/state.js`의 `addEntries`
- **문제** — 검사(`namespaceInUse`·기존 wrap 확인, 334행 부근) → DO `addEntries` → `writeWrap` 사이에 원자성이 없다. 같은 토큰을 서로 다른 범위·만료로 동시에 등록하면, 두 번째 `addEntries`가 이미 있는 줄을 새 정보로 덮어쓰고 두 `writeWrap` 중 나중 것이 이겨, DO 정보와 wrap 내용이 어긋날 수 있다. 한 요청 안의 중복은 막혀 있지만(`parseKeyRequest`의 Set), 요청 간 동시는 막혀 있지 않다.
- **고치는 방법** — `addEntries`에서 이미 있는 해시에 대해 새 정보와 기존 정보가 다르면 `key_conflict`를 돌려주거나, `addKeys` 시작 시 DO `claim`으로 등록 잠금을 잡는다.

### S17. 서울 버스 중계가 평문 HTTP로 서비스 키를 보냄 (문서화된 절충안, 기록용)
- **파일:줄** — `src/index.js:270`(`SEOUL_BASE = "http://ws.bus.go.kr/..."`)
- **문제** — 서울 정류소 API에 https가 없어 중계 서버→서울 구간이 평문이고, `serviceKey`가 쿼리에 실린다. 같은 `TAGO_SERVICE_KEY`가 TAGO·관광공사 사진(`tour`)에도 쓰여 키 노출 범위가 넓다. AGENTS.md 4절 좌표 예외 3에 이미 적힌 대표 결정("서울도 TAGO로 먼저")이라 새로 제안하지 않고 기록만 한다.
- **고치는 방법** — (대표 결정 사항) 서울 전용 키를 따로 발급해 `TAGO_SERVICE_KEY`와 분리하거나, TAGO로 충분해지면 `/seoul/*` 경로를 닫는다.

### S18. 환율 stale 폴백의 `JSON.parse`가 예외를 안 잡음
- **파일:줄** — `src/fx.js:35`
- **문제** — 전날 캐시 값을 `JSON.parse(older)`로 풀 때 try/catch가 없다. 값은 서버가 쓴 것이라 보통은 안전하지만, 저장 값이 깨지면(수동 마이그레이션·D1 이관 중 손상) 500이 나간다. 같은 파일의 fetch 경로는 try/catch가 있다.
- **고치는 방법** — `JSON.parse`를 try/catch로 감싸고, 실패하면 다음 날(`back: 2`)로 넘어가거나 `unavailable` 503을 돌려준다.

### S19. 명령 지우기 `?ids=` 개수 상한이 없음
- **파일:줄** — `src/store.js:547-555`(`deleteCommands`)
- **문제** — `ids`를 쉼표로 나눈 뒤 개수 상한 없이 전부 HMAC 태그로 바꾼다. `/rules` 지우기는 50개(`src/rules.js:147`), 공유 후보 지우기는 100개(`src/shared.js`)로 막혀 있는데 여기만 없다. URL 길이 상한(수십 KB) 안에서 수천 개까지 들어올 수 있다.
- **고치는 방법** — `deleteRules`와 같은 50개(또는 100개) 상한을 두고, 넘으면 422를 돌려준다.

### S20. 여행 계획의 제목·id 길이 상한과 항목 검증이 없음
- **파일:줄** — `src/validate.js:28-33`(`isTripPlan`)
- **문제** — `title`·`tripId`는 문자열이기만 하면 되고 길이 상한이 없으며, `items`는 개수(500개)만 보고 각 항목의 필드를 검증하지 않는다. 본문 64KB 상한이 있어 크기는 막히지만, 60KB짜리 제목이나 비정상 항목이 그대로 저장·전달된다. 앱이 미리보기에서 처리해야 한다.
- **고치는 방법** — `title` 200자·`tripId` 100자 상한을 두고, 항목마다 최소한 `title` 문자열·`type` 허용 목록 정도의 검사를 넣는다. (앱이 이미 검증한다면 서버 검사는 방어 차원으로만 둔다.)

---

## P2 — 일관성·문서

### S21. OpenAPI 문서와 실제 동작이 다름
- **파일:줄** — `src/openapi.js` 전체, 대조: `src/index.js`의 ROUTES, `src/mcp.js:14`
- **문제**
  1. `GET /tasks`가 문서에 없다. `/tasks/claim` 설명문에 "a read key can only list them with GET /tasks"라고 적혀 있는데 정작 `/tasks` 경로 정의가 없다.
  2. `/rules`(GET·POST·DELETE), `/rules/ops`, `/rules/ack`가 문서에 없다. AI가 부르는 경로인데 빠져 있다.
  3. `/tasks/claim`은 비었을 때 204를 돌려주는데(`src/store.js`의 `tasksReply`) 문서에는 200만 있다. `/tasks/result`는 409(`not_claimer`·`already_finished`)를 돌려주는데 문서에는 404·422만 있다. `/command`는 422 `app_too_old`를 돌려주는데 문서에 없다.
  4. `setSetting` 설명이 오래됐다. 문서에는 `memoDisplay`·`strideCentimeters`·`watchAcceleration`·`watchDataSync`·`location`·`photos`가 없고, 실제 `SETTINGS`(`src/validate.js`)에는 있다.
  5. 버전 표기 불일치: OpenAPI `info.version`은 `3.0.0`(`openapi.js:159`), MCP `SERVER_INFO.version`은 `3.1.0`(`mcp.js:14`).
- **고치는 방법** — `paths`에 `/tasks`(GET)와 `/rules`·`/rules/ops`·`/rules/ack`를 추가하고, 각 경로의 204·409·`app_too_old` 응답을 적는다. `setSetting` 설명을 `SETTINGS`에서 자동 생성하거나 목록을 맞춘다. 버전은 한 곳(예: `src/version.js`)에서 export해 두 파일이 같이 쓰게 한다.

### S22. 같은 상수가 여러 파일에 따로 정의됨
- **파일:줄**
  - `DAY_MS = 86_400_000`: `src/state.js:12`, `src/store.js:13`, `src/share.js:10`, `src/shared.js:15`, `src/keys.js:12`, `src/classifier.js:17`, `src/flights.js:291` (7곳). `MINUTE_MS = 60_000`: `src/state.js:11`, `src/share.js:9`.
  - `USER_AGENT = "Mozilla/5.0 (compatible; TaptionTripRelay/1.0)"`: `src/flights.js:20`, `src/expressway.js:23`. 같은 두 파일에 `text()`·`cached()`·`keep()`·`methodOnlyGet()`·`missingKey()`·`upstreamFailed()`도 거의 같은 코드로 중복된다(`flights.js:58,190-199`, `expressway.js:36-52,131`).
  - 명령·말풍선 하루 한도: `src/store.js:17,19`의 `DAILY_COMMAND_LIMIT = 100`·`DAILY_BUBBLE_LIMIT = 48`과 `src/state.js:45,47`의 `LIMITS.commandsPerDay = 100`·`LIMITS.bubblesPerDay = 48`이 같은 값이다. 한쪽만 바꾸면 오류 응답의 `limit`이 거짓이 된다.
  - `TASK_CLAIM_MS = 30 * 60_000`(`src/store.js:153`)은 어디에서도 쓰이지 않는 죽은 export이고, 실제 값은 `LIMITS.taskClaimMs`(`src/state.js:41`)가 들고 있다.
  - 일 개수 상한: `TASK_LIMIT = 100`(`src/validate.js:541`)과 `LIMITS.tasks = 100`(`src/state.js:39`). 이름이 비슷한데 다른 값도 있다: `QUEUE_LIMIT = 50`(`src/validate.js`, 명령 결과 개수)과 `LIMITS.queue = 100`(`src/state.js`, 명령 큐 크기).
  - 코드 알파벳: `CONNECT_ALPHABET`(`src/oauth.js`)과 `ALPHABET`(`src/setup.js`)이 같은 32자 집합이다(순서만 다름).
- **고치는 방법** — `src/constants.js`(또는 `http.js`)에 `DAY_MS`·`MINUTE_MS`·`USER_AGENT`를 두고 import하게 한다. 중계용 `cached`·`keep`·`methodOnlyGet`은 `src/upstream.js` 같은 공용 모듈로 뺀다. `DAILY_*`는 `LIMITS`를 재사용하고 `TASK_CLAIM_MS`는 지운다. `QUEUE_LIMIT`은 `RESULT_LIMIT`처럼 뜻이 드러나게 이름을 바꾼다.

### S23. 카카오 키워드 중계만 상류 오류를 그대로 통과시킴
- **파일:줄** — `src/index.js:66-70`(`kakaoKeyword`), 대조: `src/index.js:84-88`(`kakaoImage`), `:162-165`(`photoSearch`)
- **문제** — `kakaoKeyword`는 상류 상태 코드와 본문을 그대로 돌려준다(4xx·5xx 포함, HTML 오류 페이지도 `application/json`으로 둔갑). `kakaoImage`·`photoSearch`는 `!upstream.ok`면 502로 정규화한다. 같은 중계인데 오류 규약이 다르다.
- **고치는 방법** — `kakaoKeyword`도 `!upstream.ok`면 `json({ error: "upstream", status: upstream.status }, 502)`로 맞춘다. (의도적으로 상류 상태를 노출하려는 거라면 주석에 이유를 적는다.)

### S24. MCP 413 응답이 JSON-RPC가 아님
- **파일:줄** — `src/mcp.js`의 `mcpRoute`(본문 읽기 실패 분기)
- **문제** — 본문이 64KB를 넘으면 평문 JSON `{"error":"too_large"}` 413을 돌려준다. 400(parse error)은 JSON-RPC 오류로 감싸는데 413만 다르다. MCP 클라이언트가 JSON-RPC를 기대하고 파싱하면 실패할 수 있다.
- **고치는 방법** — 413도 `rpcError(null, -32600, "Request too large")` 형태로 감싸거나, 최소한 `jsonrpc` 필드를 포함한 오류 본문을 돌려준다.

---

## 테스트 공백 (돈·위치·암호화 중심)

- **T1. `set_rule_enabled`·`delete_rule`의 권한 동작 테스트 없음.** `test/phase2.test.mjs:332-334`에 도구 목록 완성도 검사만 있고, "AI가 사용자 규칙을 끄지 못한다"는 동작 테스트가 없다. S1을 고치면 이 테스트부터 넣는다.
- **T2. 일 100개 초과 시 열린 일 소실(S4) 테스트 없음.** `test/tasks.test.mjs`에 상한 초과·축출(eviction) 테스트가 없다.
- **T3. 설정 링크 동시 읽기(S6) 테스트 없음.** `test/polish.test.mjs:84-99`는 순차 3회 읽기만 확인한다. `Promise.all`로 동시 GET을 보내는 테스트가 필요하다.
- **T4. `saveResults`·`saveExtras` 동시 병합(S5) 테스트 없음.** 두 요청을 동시에 보내 결과가 합쳐지는지 확인하는 테스트가 없다.
- **T5. 암호화 보조 함수 단위 테스트 없음.** `pinMac`·`pepperedKey`·`deriveToken`·`sameBytes`·`sameText`를 직접 부르는 테스트가 없다(PIN·OAuth 통합 테스트로 간접 검증만 된다). 특히 `deriveToken`의 결정성(같은 입력→같은 토큰, N8의 전제)과 `pinMac`의 솔트·페퍼 분리가 단위 테스트로 고정돼 있지 않다.
- **T6. `not_claimer` 분기 테스트 없음.** `already_finished`는 `test/aif.test.mjs:46`에서 확인하지만, 남이 맡은 일을 끝내려 할 때 409가 나는 경로는 테스트가 없다.
- **T7. 환율 캐시 손상 폴백 테스트 없음.** `test/polish.test.mjs:155-169`는 stale 폴백을 확인하지만, 캐시 값이 깨졌을 때(S18)를 다루지 않는다.
- **T8. `addPaymentRule` 정규식 안전 검사 테스트 없음.** S8을 고치면 `(?<amount>(a+)+)` 같은 패턴이 거절되는 테스트를 `test/payment-rule.test.mjs`에 넣는다.
- **T9. `/public/assets` 속도 제한 테스트 없음.** S3을 고치면 함께 넣는다.
- 참고로 잘 돼 있는 부분: OAuth 전체 흐름(등록·승인·PKCE·회전·병렬 새로고침·재사용 시 폐기)은 `test/phase3.test.mjs:266-377`과 `test/rev06.test.mjs`에서, PIN 잠금은 `test/phase3.test.mjs:120`에서, 변조된 암호문 삭제는 `test/index.test.mjs:266`에서, 환율 stale 폴백은 `test/polish.test.mjs:155-169`에서 확인한다. `setup`·`fx`·`public`도 직접 import는 없지만 `handle()` 경유 통합 테스트가 있다.

---

## 확인했지만 문제없던 것 (기록용)

- **카카오 길찾기 `summary=false`(`src/directions.js`)** — 공식 문서(developers.kakaomobility.com 자동차 길찾기)에 `summary: false`는 "요약 정보와 상세 정보 반환(기본값)"으로 확인됨. 통행료·거리·시간·도로 이름이 모두 오는 것이 맞다. 의심했으나 정상.
- **IP DO 알람의 카운터 삭제(`src/state.js` `countDaily`·`alarm`)** — `expire: true`인 카운터 쓰기마다 알람이 다음 날 00:01로 다시 설정돼, 새벽 0시~1분 사이 쓰기가 지워지는 일은 사실상 없다. 자정 이후 조용한 IP의 전날 카운터만 정리된다.
- **OAuth refresh 회전·재시도(`src/oauth.js`·`src/state.js` `useRefresh`·`commitRefresh`)** — nonce 고정 + `refreshHash === next`면 성공 처리로 동시 새로고침·재시도가 같은 토큰으로 수렴한다. 커밋 실패 뒤에도 옛 토큰으로 다시 시도하면 스스로 복구된다.
- **PIN 초기화·폐기 뒤 남은 access wrap** — wrap이 KV에 남아도 DO의 `admit`이 `key:<entry>` 폐기 표시를 보고 401로 막는다. 이중 방어 확인됨.
- **CORS(`src/index.js:517-518`)** — `*`는 `/mcp`·`/oauth/register`·`/oauth/token`·공개 메타데이터에만 열려 있고, 쿠키 인증이 없어 `*`가 세션 탈취로 이어지지 않는다. 키는 Authorization 헤더로만 오간다.
- **키·토큰 로그 노출** — `src/`에 `console.*`이 없고, `wrangler.toml`에서 Workers Logs를 끄기로 돼 있다. 오류 응답에 키·좌표가 섞이지 않게 상류 원문을 버리는 곳(`directions`·`flights`·`expressway`·`relayBus`)도 확인됨.
- **공유 방 속도 제한(`src/share.js`)** — `rate()`·`locRates`가 메모리 기반이라 DO가 잠들면 0부터 시작하지만, 코드 주석에 명시돼 있고 잠들려면 비활성 기간이 필요해 지속 남용에는 악용하기 어렵다. 낮은 우선순위라 별도 항목으로 올리지 않았다.
- **D1 어댑터(`src/d1kv.js`)** — 이중 읽기·지연 이관·삭제 표식·`INSERT OR IGNORE` 경합 처리·list 키셋 페이지네이션이 일관되게 짜여 있다. `list`의 옛 KV 전수 읽기는 PLANS 바인딩이 뗀 뒤(D1R1119A02) 실행되지 않는다.
