# taption-plan 코드 검토 — 구체적 개선안

- 검토일: 2026-11-20
- 기준 커밋: `e6a4445` (main, HSW1120A01)
- 규모: Swift 1,006개 파일, JS 25개 파일, 약 236,050줄(앱·패키지 기준)
- 범위: 앱 Swift 전체, `Packages/*`, `server/trip-relay`, CI, `tools/admin-console`
- 방법: 파일 전수 정독 + `rg` 패턴 대조 + 테스트 대조. 코드 근거가 있는 항목만 적었다.
- **이 문서는 검토만 한다. 저장소 파일을 하나도 수정하지 않았다.**
- 방향: 큰 기능 아이디어보다 손봐야 할 곳·보완할 문제 중심. 각 항목은 Claude Code가 바로 수정할 수 있게 "파일:줄 — 문제 — 고치는 방법" 형식으로 적었다.

## 제약·제외 (지킨 것)

- Claude Code가 Muse 공식 제공자 추가 작업 중인 파일과는 겹치는 변경을 제안하지 않았다: `TaptionPlan/UI/AssistantAIProvider.swift`, `AssistantConnectView.swift`, `AssistantConnectGuide.swift`, `AITaskPanel.swift`, `TaptionPlanTests/AssistantPhase3Tests.swift`, `docs/AI_ASSISTANT_GUIDE.md`, `docs/ACTIVITY_RELAY_API.md`. 아래 항목 중 이 파일들을 건드리는 것은 없다.
- `TaptionPlan/UI/TravelModeView.swift` actor 격리 CI 실패는 대표 지시로 건드리지 않았다.
- AGENTS.md §4 "대표 결정" 항목은 변경 제안 대상에서 제외했다.

## 요약

- 총 **110여 건**: P0 16건, P1 60여 건, P2 40여 건(죽은 코드 53건 포함 시 더 많음).
- 가장 급한 축은 세 가지다. **(1) 서버 권한·데이터 손실 결함 5건(S1–S5)**, **(2) 앱 데이터·백업·키 소실 위험 6건(D1–D6)**, **(3) CI가 테스트를 안 돌리는 3곳** — 패키지 6개, trip-relay(약 280건), 앱 테스트(약 3,064건)가 CI에서 전혀 실행되지 않는다.

## 상위 10 (먼저 Claude Code에 넘길 것)

| 순위 | 항목 | 파일 | 한 줄 요약 |
|---|---|---|---|
| 1 | S1 | `server/trip-relay/src/rules.js:153-157`, `src/state.js:339-344` | 쓰기 AI가 사용자가 만든 규칙을 끌 수 있음 (권한 검사 누락) |
| 2 | S3 | `server/trip-relay/src/index.js:599-603` | `/public/*`이 모든 속도 제한을 우회 — 큰 파일 반복 요청으로 R2 이그레스 소진 가능 |
| 3 | S4 | `server/trip-relay/src/state.js:198-203` | 일(task) 100개 초과 시 열린 일도 조용히 삭제됨 |
| 4 | D1 | `Packages/TaptionAssistant/.../AssistantSecrets.swift:44-49` | Keychain 키 교체가 삭제-후-추가라 실패하면 기존 키가 사라짐 |
| 5 | D3 | `Packages/TaptionPlanStore/.../TaptionStoreBackupRestore.swift:250-263` | 복원 복구 중 meta 읽기 실패 시 메모 합치기용 준비 파일이 지워짐 |
| 6 | CI-1~3 | `.github/workflows/ci.yml` | 패키지 6개·trip-relay·앱 단위 테스트가 CI에서 안 돎 |
| 7 | S5 | `server/trip-relay/src/store.js:332-341, 558-569` | 명령 결과·활동 추가 칸 저장이 KV 읽기-수정-쓰기 경합에 노출 |
| 8 | D6 | `Packages/TaptionTripShare/.../ShareRoomSession.swift:300-309` | 세션 해제 후에도 ping Task가 영원히 돌아감 (deinit 없음) |
| 9 | T-03 | `Packages/SeasonPackKit/.../SeasonPackWindows.swift:11-30` | 날짜 파싱에 월/일 검증이 없어 "2026-13-40"이 다음 해 날짜가 됨 (실제 버그) |
| 10 | S2 | `server/trip-relay/src/index.js:66, 84, 162, 176, 189` | 중계 fetch 5곳에 try/catch가 없어 상류 장애 시 처리되지 않은 500 |

---

## 1. P0 — 바로 고칠 것

### 1.1 서버 (trip-relay)

#### S1. 쓰기 AI가 사용자가 만든 규칙을 켜고 끌 수 있음 (권한 검사 누락)
- **파일:줄** — `server/trip-relay/src/rules.js:153-157`(`setRuleEnabled`), `src/state.js:315-345`(`ruleOps`)
- **문제** — MCP `set_rule_enabled` 도구는 `ruleOps`를 `onlyAI` 없이 부른다. `ruleOps`의 켜기·끄기 분기(`state.js:339-344`)에는 규칙 주인(`by`) 검사가 없다. 반면 같은 파일의 `rulePut`(`state.js:291`)은 AI가 사용자 규칙을 고치면 거부하고, `deleteRules`(`src/rules.js:148`)는 AI에게 `onlyAI: true`를 넘긴다. 즉 AI는 사용자 규칙을 고치거나 지우지는 못하지만 **끄는 것은 가능**해, 사용자가 켜 둔 결제·분류 규칙을 무력화할 수 있다. REST `/rules/ops`는 master 전용이라 안전하고, MCP `set_rule_enabled` 경로만 뚫려 있다. (직접 대조 확인함)
- **고치는 방법** — `setRuleEnabled`에서 `ruleOps`를 부를 때 `onlyAI: ctx.auth?.kind !== "master"`를 넘기고, `ruleOps`의 켜기·끄기 분기에도 삭제와 같은 검사(`if (onlyAI && rule.by === "user") continue;`)를 넣는다. 테스트: "AI가 사용자 규칙을 끄지 못한다"는 동작 테스트를 `test/phase2.test.mjs`에 추가한다.

#### S2. 카카오·사진·구글 중계에서 fetch 예외를 안 잡음 (처리되지 않은 500)
- **파일:줄** — `server/trip-relay/src/index.js:66`(`kakaoKeyword`), `:84`(`kakaoImage`), `:162`(`photoSearch`), `:176`·`:189`(`googlePhoto`)
- **문제** — 다섯 곳 모두 `await fetcher(...)`를 try/catch 없이 부른다. 상류 네트워크 오류·DNS 실패로 fetch가 throw하면 Worker가 그대로 터져 500(Cloudflare 기본 오류)이 나간다. 같은 파일의 `relayBus`(`:231`)와 `src/directions.js:60`, `src/flights.js:214`, `src/expressway.js:62`는 모두 try/catch로 502를 돌려준다. 즉 이 네 함수만 예외 처리가 빠져 있다.
- **고치는 방법** — 다섯 곳의 fetch를 try/catch로 감싸고, 실패 시 `json({ error: "upstream_failed" }, 502)`(또는 기존 `upstream` 502 규약)를 돌려준다. `kakaoKeyword`의 `await upstream.text()`도 같은 try 안에 넣는다.

#### S3. `/public/*`이 모든 속도 제한을 우회함 (R2 이그레스 남용)
- **파일:줄** — `server/trip-relay/src/index.js:596-603`(`route()`), `src/public.js:1-3`
- **문제** — `route()`가 `publicAssets()`(599행)를 `limited()` 검사(603행)보다 먼저 부른다. `/public/assets/*`는 인증·속도 제한 없이 R2 객체를 그대로 내주는데, `mlpackage`·`zip` 같은 큰 파일도 된다(`src/public.js` CONTENT_TYPES). 한 IP가 큰 모델 파일을 반복 요청하면 R2 이그레스 비용·대역폭을 소진할 수 있다. `public.js` 주석에 "속도 제한도 없다"고 적혀 있어 의도된 설계로 보이나, 코드 차원의 방어가 전혀 없다. (직접 대조 확인함)
- **고치는 방법** — (a) `/public/assets/*`에만 `limited(env.REQUEST_LIMIT, request)`를 `publicRoute` 안에서 적용하거나, (b) Cloudflare 대시보드의 속도 제한 규칙으로 `/public/assets/*`를 묶고 그 결정을 `wrangler.toml` 주석 또는 README에 적는다. 공지(`/public/announcements`, 작고 캐시됨)는 현행 유지가 합리적이다.

#### S4. 일(task)이 100개를 넘으면 열린 일도 조용히 지워짐 (데이터 소실)
- **파일:줄** — `server/trip-relay/src/state.js:184-205`(`taskAdd`), 특히 `:198-203`
- **문제** — `taskAdd`는 목록이 `LIMITS.tasks`(100개)를 넘으면 끝난 것부터, 없으면 가장 오래된 것부터 `s.delete`로 지운다. 열린 일(`waiting`·`processing`·`asked`)이 100개를 넘으면 **열린 일이 상태 변경 없이 그냥 사라진다**. 실패·만료 표시도, `gone` 목록 기록도 없다. 앱이 올린 일이 서버에서 흔적 없이 없어진다.
- **고치는 방법** — 열린 일을 버릴 때는 삭제 대신 `status: "failed", code: "overflow"`(또는 `expired`)로 바꾸고 `sealed`를 비워, 앱이 `GET /tasks`로 소실을 확인할 수 있게 한다. 또는 열린 일이 100개에 찼으면 새 일 추가를 `too_many_tasks`(409/429)로 거절한다. 둘 중 하나를 택하고 주석에 적는다. 테스트: `test/tasks.test.mjs`에 상한 초과·축출(eviction) 테스트 추가.

#### S5. 명령 결과·활동 추가 칸 저장이 KV 읽기-수정-쓰기 경합에 노출됨
- **파일:줄** — `server/trip-relay/src/store.js:558-569`(`saveResults`), `src/store.js:332-341`(`saveExtras`)
- **문제** — 두 곳 모두 KV에서 읽고(`get`), 메모리에서 합치고(`filter`·`concat`·`slice`, 필드 병합), 다시 쓴다(`put`). DO를 거치지 않으므로 두 요청이 동시에 오면 한쪽의 병합 결과가 사라진다. `saveResults`는 앱이 명령 처리 결과를 올릴 때(두 기기가 같은 주인 키를 쓰거나 재시도가 겹치면 발생 가능), `saveExtras`는 하루 기록 업로드 시 goals·trips·placeBook을 합칠 때 해당한다. 명령 큐·일은 DO로 옮겼는데 이 두 병합 쓰기만 KV에 남아 있다.
- **고치는 방법** — (a) 두 값을 DO로 옮겨 `state.js`에 `resultAppend`·`extrasMerge` 같은 op을 두고 직렬화하거나, (b) 당장은 앱이 재시도 시 전체를 다시 올리도록 하고, 서버는 마지막 쓰기 승리(last-write-wins)를 문서화한다. (a)가 정석이다. 테스트: 두 요청을 동시에 보내 결과가 합쳐지는지 확인하는 테스트 추가.

### 1.2 앱 데이터·백업·키

#### D1. Keychain 키 교체가 비원자적이라 실패하면 기존 키가 사라진다
- **파일:줄** — `Packages/TaptionAssistant/Sources/TaptionAssistantKit/AssistantSecrets.swift:44-49`
- **문제** — `write(_:to:)`가 먼저 `SecItemDelete`로 기존 항목을 지운 뒤 `SecItemAdd`로 새로 넣는다. `SecItemAdd`가 실패하면(기기 잠금·Keychain 접근 불가·디스크 문제) 이미 지운 옛 키는 돌아오지 않는다. 주 키(`relay-key`)가 사라지면 AI 연결·중계가 끊기고, 복구하려면 사용자가 연결 키를 다시 만들어야 한다. `SecItemDelete`의 반환값도 확인하지 않는다. (직접 대조 확인함)
- **고치는 방법** — 삭제 후 추가 대신 `SecItemUpdate`를 먼저 시도하고, 항목이 없을 때만(`errSecItemNotFound`) `SecItemAdd`로 넣는다. 또는 `SecItemAdd`가 성공한 뒤에야 옛 항목을 지우는 순서를 쓰되, 중복 항목(`errSecDuplicateItem`) 처리를 넣는다.

#### D2. `rawDigest`가 트랜잭션 없이 스캔해 찢어진 읽기의 다이제스트를 그대로 돌려준다
- **파일:줄** — `Packages/TaptionPlanCore/Sources/TaptionPlanCore/DayStoreV3+RawEvents.swift:733-803`
- **문제** — `rawDigest(for:)`가 `raw_events`를 한 행씩 스캔하면서 SHA256을 계산하는데, 이 스캔이 트랜잭션 밖에 있다. 다른 연결(다른 스토어 인스턴스·확장 프로그램)이 스캔 도중에 쓰면 앞부분은 쓰기 전, 뒷부분은 쓰기 후 상태가 섞인 다이제스트가 된다. 끝에서 `currentDataVersion() == dataVersion`을 확인하는 것은 영속화(`persistRawDigest`)만 막을 뿐, 찢어진 다이제스트 자체는 그대로 반환한다. 호출자는 이 값을 실제 DB 상태와 비교해 materialization 여부를 판단하므로 잘못된 다이제스트가 캐시·머티리얼라이즈 판정을 틀리게 할 수 있다.
- **고치는 방법** — 스캔 전체를 `withReadTransaction` 안에서 수행하거나, 스캔 뒤 `dataVersion`이 바뀌었으면 `staleRawEventCursor`를 던지고 호출자가 다시 시도하게 한다. (`rawEventPage`는 같은 검사를 이미 하고 있다.)

#### D3. 복원 복구(`recover`)에서 meta 읽기 실패 시 메모 합치기용 준비 파일을 지워 버린다
- **파일:줄** — `Packages/TaptionPlanStore/Sources/TaptionPlanStore/TaptionStoreBackupRestore.swift:250-263`
- **문제** — `recover`가 `try? await store.meta(pendingMemoKey)`로 "메모 남음" 표시를 읽는다. `meta`가 던지면(DB 오류 등) `pending`이 `nil`이 되고 `keep`도 `nil`이 돼, 뒤의 정리 루프가 준비 디렉토리를 전부 지운다. 그 안에 커밋은 됐지만 메모 합치기를 못 끝낸 준비 파일이 있으면 메모 복원이 영영 사라진다. 다음 `recover`에서는 표시가 남아 있어도 파일이 없으므로 `setMeta(pendingMemoKey, "")`으로 표시만 지우고 끝난다(253-258행: 파일이 없으면 `applyMemos`를 건너뛰고 표시를 지운다).
- **고치는 방법** — `meta` 읽기가 실패하면 정리 루프를 타지 않고 그대로 둔다(다음 작업에서 다시 시도). 즉 `try?` 대신 `do/catch`로 실패 시 `return`한다. 또는 표시를 못 읽었을 때는 어떤 준비 디렉토리도 지우지 않는다.

#### D4. 백업 엔진 직렬화에서 취소된 대기자가 영원히 매달리고, 취소됐는데도 작업이 실행된다
- **파일:줄** — `TaptionPlan/Core/TaptionBackupEngine.swift:191-199`
- **문제** — `exclusive`가 `withCheckedContinuation`으로 대기자를 등록한다. 이 continuation은 취소에 반응하지 않으므로, 대기 중 취소된 작업은 앞 작업이 끝날 때까지 그대로 매달렸다가, 재개된 뒤 취소 여부를 확인하지 않고 `prepareEnvironment()`와 본 작업을 그대로 실행한다. 백업·복원·오프로드가 사용자 취소 뒤에도 돌아가는 셈이다.
- **고치는 방법** — `withTaskCancellationHandler`로 취소 시 대기열에서 continuation을 빼고 재개하거나, 재개 직후 `try Task.checkCancellation()`을 넣어 취소됐으면 작업을 시작하지 않게 한다.

#### D5. `PRAGMA journal_mode=WAL` 결과를 확인하지 않아 WAL이 안 켜져도 조용히 넘어간다
- **파일:줄** — `Packages/TaptionPlanCore/Sources/TaptionPlanCore/DayStoreV3+Schema.swift:162-177` (`enableWriteAheadLog`, 167행)
- **문제** — `sqliteExecute`는 `sqlite3_exec`로 PRAGMA를 실행하고 반환 행을 버린다. 다른 연결이 DB를 열어 둔 상태에서는 `journal_mode=WAL`이 에러 없이 현재 모드(`delete`)를 돌려주기만 하므로, WAL이 안 켜진 채로 초기화가 성공한다. 이후 코드는 WAL을 전제로 한다(`checkpoint()`의 `sqlite3_wal_checkpoint_v2`, `-wal`/`-shm` 파일 보호). 재시도 루프는 `SQLITE_BUSY` 에러에만 반응해 이 경우를 잡지 못한다.
- **고치는 방법** — `sqlite3_exec` 대신 prepare/step으로 PRAGMA의 반환 값을 읽어 `wal`인지 확인하고, 아니면 `SQLITE_BUSY`처럼 재시도하거나 에러를 던진다.

#### D6. 공유 세션을 해제해도 ping Task가 영원히 돌아간다
- **파일:줄** — `Packages/TaptionTripShare/Sources/TaptionTripShare/ShareRoomSession.swift:300-309`
- **문제** — `startPing()`이 `Task { [environment, client] in while !Task.isCancelled { ... await client.ping() } }`를 만든다. 이 Task는 `self`를 약하게 잡지 않고 `client`를 강하게 잡으며, 세션에는 `deinit`이 없다(패키지 전체에 `deinit`이 없음). `stop()` 없이 세션이 해제되면 ping Task를 취소할 주체가 사라져 30초마다 `ping()`을 영원히 보내고 `ShareRoomClient` 액터도 살려 둔다. (`runTask`·`renewTask`는 `[weak self]`라 세션 해제 시 끝나지만 ping만 남는다.) (직접 대조 확인함)
- **고치는 방법** — `deinit`에서 `pingTask`·`runTask`·`renewTask`를 취소하거나, ping Task도 `[weak self]`로 세션 소멸 시 종료되게 한다. 함께 `events`·`locationEvents`의 continuation도 `finish()`로 닫는다(안 그러면 스트림을 들고 있던 구독자가 영원히 대기한다 — D34와 함께 해결).

### 1.3 CI가 테스트를 안 돌리는 곳

#### CI-1. CI packages job이 11개 패키지 중 4개만 테스트
- **파일:줄** — `.github/workflows/ci.yml` packages job — `for package in TaptionPlanCore TaptionRouteEngine TaptionActivityEngine TaptionPlanEngine`
- **문제** — `TaptionAssistant`(테스트 8개 파일), `TaptionClassifierEngine`(3개), `TaptionPlanStore`(13개), `TaptionTripShare`(7개), `TaptionWatchSync`(7개), `SeasonPackKit`(8개)의 테스트가 CI에서 전혀 돌지 않는다. 회귀가 CI를 통과해 main에 들어갈 수 있다.
- **고치는 방법** — 루프에 6개 패키지를 추가한다. `TaptionLedgerCore`는 테스트 파일이 0개라 일단 목록에서 빼고, 테스트를 더한 뒤(아래 2.4) 추가한다.

#### CI-2. CI relay job이 trip-relay를 테스트하지 않음
- **파일:줄** — `.github/workflows/ci.yml` relay job — `npm test`를 `server/airkorea-proxy`에서만 실행
- **문제** — 주 중계 서버 `server/trip-relay`(`package.json`의 `test`: `node --test test/*.test.mjs`, 약 280건)가 CI에서 돌지 않는다. 서버 회귀가 배포 전에 안 잡힌다.
- **고치는 방법** — relay job에 `npm test`(working-directory `server/trip-relay`) 단계를 추가한다. `tools/admin-console/server.test.mjs`도 같은 job에서 `node --test`로 돌리는 것을 함께 검토한다.

#### CI-3. CI에서 앱 단위 테스트(`TaptionPlanTests`, 약 3,064건)가 돌지 않음
- **파일:줄** — `.github/workflows/ci.yml` app job — `xcodebuild build`만 하고 `test`가 없음
- **문제** — 앱 전체 단위 테스트가 로컬에서만 돌고 CI에서는 빌드 성공 여부만 확인한다.
- **고치는 방법** — 별도 job으로 `xcodebuild test -only-testing:TaptionPlanTests`(시뮬레이터)를 추가한다. 시간·비용이 크면 대표와 상의해 nightly로 돌리는 것도 방법이다. 단, `TravelModeView.swift` actor 격리 오류로 app job이 이미 실패 중인데, 이는 대표 지시로 건드리지 않는 항목이므로 테스트 job 추가와는 별개로 다룬다.

### 1.4 실제 버그·미연결 보안 기능

#### T-03. 시즌 팩 날짜 파싱 미테스트 + 월/일 범위 검증 없음
- **파일:줄** — `Packages/SeasonPackKit/Sources/SeasonPackKit/Scheduler/SeasonPackWindows.swift:11-30`
- **문제** — `SeasonPackDateParsing.localDateTime(_:calendar:)`·`hourMinute(_:)` 테스트 0건. 더구나 월·일 범위 검사가 없어 `calendar.date(from:)`이 "2026-13-40" 같은 값을 굴려서 다음 해 날짜로 만들어 버린다(시각만 0...23·0...59 검사). 매니페스트 오타가 조용히 잘못된 기간이 된다. (직접 대조 확인함 — 월/일 검사 없음)
- **고치는 방법** — 월 1...12·일 1...31(해당 월 일수) 검증 추가 후, 정상/날짜만/시각 포함/무효 월·일·시각 테스트 추가. 같은 패턴의 날짜 정규화 문제는 D29(`LedgerCapture.swift:190, 583`, "2월 31일")도 함께 본다.

#### T-08. 생체 보호 백업 검증 진입점이 호출처 없음 (죽은 코드 + 보안 기능 미연결)
- **파일:줄** — `TaptionPlan/UX/AppModel+Backup.swift:243` (`validateBiometricProtectedData()`), `TaptionPlan/UX/AppModel.swift:892` (`refreshBiometricDataProtectionStatus()`)
- **문제** — `validateBiometricProtectedData()`가 저장소 전체에서 정의 1회만 나온다. 생체 보호 스냅샷의 `validate()`를 부르는 유일한 진입점인데 아무 데서도 안 불러서, 보호된 백업이 깨졌는지 확인하는 길이 없다. 상태 새로고침 함수도 호출처가 없다. (직접 대조 확인함)
- **고치는 방법** — 백업 목록·복원 전 검증 흐름에 연결하거나, 의도적으로 안 쓰는 거면 함수와 `BiometricDataProtectionStatus` 표시를 함께 삭제한다.

---

## 2. P1 — 다음으로 고칠 것

### 2.1 서버 (trip-relay)

#### S6. 설정 링크(`/s/<코드>`) 읽기 횟수 경합 — 3회 제한을 넘길 수 있음
- **파일:줄** — `server/trip-relay/src/setup.js:44-72`(`readSetup`), 특히 `:61-69`
- **문제** — 읽기 횟수를 KV에서 읽고(`reads`), +1한 뒤 다시 봉인해 쓴다. 락·CAS가 없어 두 GET이 동시에 오면 둘 다 `reads: 0`을 읽고 둘 다 `reads: 1`을 써, 링크가 3회가 아니라 4회 이상 읽힌다. 키가 든 안내문이라 횟수 제한이 보안 경계인데, 동시 요청으로 우회된다. 순차 읽기 테스트(`test/polish.test.mjs:84-99`)만 있고 동시성 테스트는 없다.
- **고치는 방법** — 횟수를 DO(`code:<해시>` 인스턴스의 `takeCode` 패턴, `src/state.js`의 `takeCode` 참고)로 옮겨 직렬화하거나, 읽기 횟수를 3회가 아니라 "읽은 시각" 기반으로 바꾸고 여유를 둔다. 가장 작은 수정은 DO에 `setupRead` op을 두는 것이다. 테스트: `Promise.all`로 동시 GET을 보내는 테스트 추가.

#### S7. 한 AI가 다른 AI의 규칙을 지울 수 있음 (만든 이 검사 없음)
- **파일:줄** — `server/trip-relay/src/rules.js:145-150`(`deleteRules`), `src/state.js:315-337`(`ruleOps`)
- **문제** — `deleteRules`는 AI에게 `onlyAI`를 넘기지만, `ruleOps`의 삭제 분기(`state.js:334`)는 `rule.by === "user"`만 건너뛸 뿐, 규칙에 저장된 `keyId`와 지우는 연결의 `keyId`를 비교하지 않는다. MCP `delete_rule` 설명은 "Delete rules you (an AI) saved"인데, 실제로는 연결 A가 연결 B가 만든 AI 규칙을 지울 수 있다. `rulePut`도 같은 id면 다른 AI의 규칙을 덮어쓴다(`state.js:291-312`, `keyId` 비교 없음).
- **고치는 방법** — `ruleOps`에 호출자의 `keyId`를 넘기고, `onlyAI`일 때 `rule.by === "ai" && rule.keyId && rule.keyId !== callerKeyId`면 건너뛰거나 `forbidden`을 돌려준다. `rulePut`의 덮어쓰기에도 같은 검사를 적용한다. (의도된 공유 동작이라면 MCP 설명을 "any AI rule"로 고친다.)

#### S8. `addPaymentRule` 명령이 정규식 안전 검사를 안 함 (`put_rules`와 불일치)
- **파일:줄** — `server/trip-relay/src/validate.js:462-465`(`isCommand`의 `addPaymentRule`), 대조: `src/rules.js`의 `safePattern`·`RULE_TYPES.payment_text`
- **문제** — `put_rules`의 `payment_text` 규칙은 `safePattern`(되돌아보기·역참조·겹친 반복 거부, 300자·묶음 12개 상한)으로 검사하지만, `addPaymentRule` 명령은 길이 300자만 보고 `(?<amount>` 포함 여부만 확인한다. `(?<amount>(a+)+)` 같은 지수 시간 패턴이 그대로 큐에 들어가 앱(iOS NSRegularExpression)이 평가하게 된다. 결제 문자 본문은 짧아 실제 위험은 낮지만, 같은 정규식을 받는 두 경로의 검사 수준이 다르다.
- **고치는 방법** — `validate.js`의 `addPaymentRule` 검사에 `safePattern`을 재사용한다. (`rules.js`가 `validate.js`를 안 불러오므로 순환 참조 없이 `validate.js`에서 `rules.js`를 import하거나, `safePattern`을 공용 모듈로 옮긴다.) 테스트: `(?<amount>(a+)+)` 같은 패턴이 거절되는 테스트를 `test/payment-rule.test.mjs`에 추가.

#### S9. 규칙 ops의 `baseVersion`이 어긋나도 그대로 적용됨 (낙관적 동시성 미적용)
- **파일:줄** — `server/trip-relay/src/rules.js:129-142`(`applyRuleOps`), 특히 `:140`
- **문제** — 앱이 보낸 `baseVersion`이 서버의 적용 전 버전(`result.before`)과 다르면 `stale: true`만 붙이고 ops는 전부 적용한다. 두 기기·앱과 AI가 동시에 규칙을 고치면 한쪽의 변경이 조용히 덮인다. `stale` 플래그만으로는 충돌을 막지 못한다.
- **고치는 방법** — `baseVersion`이 주어졌는데 어긋나면 ops를 적용하지 않고 `409 { error: "stale_version", version: result.before }`를 돌려준다. (앱이 `stale`을 받고 다시 읽어 재시도하는 흐름이라면 그 동작을 주석·문서에 명시하고 현행을 유지한다.)

#### S10. 분류 표본 하루 한도 검사가 검사-후-삽입 경합에 노출됨
- **파일:줄** — `server/trip-relay/src/classifier.js:77-86`(`upload`)
- **문제** — `SELECT COUNT(*)`으로 오늘 올린 수를 보고(77행) 한도를 넘지 않으면 `INSERT`한다(82-84행). 트랜잭션·락이 없어 두 업로드가 동시에 오면 둘 다 한도를 통과해 하루 2,000건을 넘길 수 있다. 같은 이유로 `accepted` 수도 동시 업로드가 섞이면 어긋난다(전후 COUNT 차이로 계산, 81·85-86행).
- **고치는 방법** — D1 `batch` 안에서 `INSERT ... SELECT ... WHERE (SELECT COUNT(*) ...) < 2000` 형태로 한 번에 처리하거나, 업로드 수를 주인 DO의 `countDaily`로 세어 직렬화한다. `accepted`는 `INSERT`의 변경 행 수(`changes`)로 계산한다.

#### S11. 검색 예산이 잘못된 요청(400·503)에도 차감됨
- **파일:줄** — `server/trip-relay/src/state.js`의 `admit`(카카오 수 세기), `src/index.js`의 `authorized`(admit이 핸들러보다 먼저 돎), `src/index.js:340-360` 부근의 `kakaoRoute`·`tagoRoute`·`expresswayRoute`·`flightsRoute`(IP 수 세기)
- **문제** — 키당 하루 500건(`LIMITS.kakaoPerDay`)과 IP당 하루 2,000건(`LIMITS.kakaoPerIpDay`)이 핸들러의 입력 검증보다 먼저 차감된다. 쿼리가 틀려 400이 나거나, 서버 키가 없어 503이 나는 요청도 예산을 먹는다. 잘못된 요청을 반복하면 정상 검색 예산을 고갈시킬 수 있다.
- **고치는 방법** — IP 수 세기는 핸들러가 쿼리 검증을 통과한 뒤로 옮기거나(경량 검증만 라우터에서 먼저 수행), 키당 카카오 수는 `admit`이 아니라 각 중계 핸들러가 상류를 부르기 직전에 DO `countDaily`로 센다. 둘 다 바꾸기 크면, 최소한 서버 키가 없을 때(503 확정)는 세지 않게 한다.

#### S12. 방 만들기 예산이 실패(409)에도 차감됨
- **파일:줄** — `server/trip-relay/src/share.js:765-769`(`createRoom`)
- **문제** — 주인당 하루 5개·서버 전체 하루 300개의 방 만들기 수를 DO `create` 호출보다 먼저 센다. 이미 있는 방 id로 만들어 409 `room_exists`가 나도 예산이 차감된다. 같은 id를 반복 시도하면 하루 몫을 소진할 수 있다.
- **고치는 방법** — DO `create`의 결과를 보고 201일 때만 수를 세도록 순서를 바꾸거나(두 번 호출이 필요해지면 DO `create` 안에서 수를 세게 합친다), 409일 때 차감분을 되돌리는 `refundDaily` op을 둔다.

#### S13. 영업소 좌표 캐시 쓰기가 쓰기 예산을 우회함
- **파일:줄** — `server/trip-relay/src/expressway.js:123`·`:127`(`locate`의 `store.put`)
- **문제** — `geo:<코드>` 캐시 쓰기(찾음 1년·못 찾음 30일)가 `chargeWrites` 없이 `env.PLANS`에 직접 쓴다. 목록을 한 번 만들 때 최대 24건(`GEO_CALLS_PER_BUILD`)까지 쓰는데, 서버 전체 하루 쓰기 예산(8만 건) accounting에서 빠진다. 규모는 작지만 예산의 전제가 깨진다.
- **고치는 방법** — `exUnits`가 캐시를 만들 때 쓸 geo 행 수를 미리 세어 `chargeWrites`를 부르거나, `locate`의 쓰기를 예산 대상에서 빼는 결정을 주석으로 명시한다.

#### S14. 하루 기록 이전(ensureDays) 중 예외가 나면 DO 잠금이 60초간 남음
- **파일:줄** — `server/trip-relay/src/store.js:270-303`(`ensureDays`), `claim` 272행·`release` 303행
- **문제** — `claim("days")` 뒤 KV 읽기·쓰기 중 예외가 나면 `release`에 닿지 않는다(try/finally 없음). 잠금은 1분 뒤 만료(`LIMITS.lockMs`)되어 자가 복구되지만, 그 사이 다른 요청은 `saveActivity`에서 503 `migrating`을 받는다.
- **고치는 방법** — `claim` 이후 본문을 try/finally로 감싸고 finally에서 `release`를 부른다.

#### S15. 등록 표시 쓰기 실패 시 재등록이 등록 예산을 계속 먹음
- **파일:줄** — `server/trip-relay/src/keys.js:264-267`(`registerRoute`)
- **문제** — 전역 쓰기 예산이 바닥나면 `reg:<해시>` 표시 쓰기를 조용히 건너뛴다(`if (charge.ok)`). 표시가 없으면 앱이 켤 때마다 다시 등록할 때마다 IP·전역 등록 수(하루 20·500건)를 센다. 예산 부족이 계속되면 재등록만으로 전역 등록 한도를 소진할 수 있다.
- **고치는 방법** — 표시 쓰기에 실패하면 등록 자체를 429 `write_budget_exhausted`로 돌려주거나(앱이 나중에 다시 시도), DO `register`의 `created: false` 응답을 보고 표시 쓰기를 재시도한다.

#### S16. 같은 연결 키를 동시에 두 번 등록하면 범위·만료가 어긋날 수 있음
- **파일:줄** — `server/trip-relay/src/keys.js:315-350`(`addKeys`), `src/state.js`의 `addEntries`
- **문제** — 검사(`namespaceInUse`·기존 wrap 확인, 334행 부근) → DO `addEntries` → `writeWrap` 사이에 원자성이 없다. 같은 토큰을 서로 다른 범위·만료로 동시에 등록하면, 두 번째 `addEntries`가 이미 있는 줄을 새 정보로 덮어쓰고 두 `writeWrap` 중 나중 것이 이겨, DO 정보와 wrap 내용이 어긋날 수 있다. 한 요청 안의 중복은 막혀 있지만(`parseKeyRequest`의 Set), 요청 간 동시는 막혀 있지 않다.
- **고치는 방법** — `addEntries`에서 이미 있는 해시에 대해 새 정보와 기존 정보가 다르면 `key_conflict`를 돌려주거나, `addKeys` 시작 시 DO `claim`으로 등록 잠금을 잡는다.

#### S17. 서울 버스 중계가 평문 HTTP로 서비스 키를 보냄 (문서화된 절충안, 기록용)
- **파일:줄** — `server/trip-relay/src/index.js:270`(`SEOUL_BASE = "http://ws.bus.go.kr/..."`)
- **문제** — 서울 정류소 API에 https가 없어 중계 서버→서울 구간이 평문이고, `serviceKey`가 쿼리에 실린다. 같은 `TAGO_SERVICE_KEY`가 TAGO·관광공사 사진(`tour`)에도 쓰여 키 노출 범위가 넓다. AGENTS.md 4절 좌표 예외 3에 이미 적힌 대표 결정("서울도 TAGO로 먼저")이라 새로 제안하지 않고 기록만 한다.
- **고치는 방법** — (대표 결정 사항) 서울 전용 키를 따로 발급해 `TAGO_SERVICE_KEY`와 분리하거나, TAGO로 충분해지면 `/seoul/*` 경로를 닫는다.

#### S18. 환율 stale 폴백의 `JSON.parse`가 예외를 안 잡음
- **파일:줄** — `server/trip-relay/src/fx.js:35`
- **문제** — 전날 캐시 값을 `JSON.parse(older)`로 풀 때 try/catch가 없다. 값은 서버가 쓴 것이라 보통은 안전하지만, 저장 값이 깨지면(수동 마이그레이션·D1 이관 중 손상) 500이 나간다. 같은 파일의 fetch 경로는 try/catch가 있다.
- **고치는 방법** — `JSON.parse`를 try/catch로 감싸고, 실패하면 다음 날(`back: 2`)로 넘어가거나 `unavailable` 503을 돌려준다. 테스트: 캐시 값이 깨졌을 때 폴백 테스트를 `test/polish.test.mjs`에 추가.

#### S19. 명령 지우기 `?ids=` 개수 상한이 없음
- **파일:줄** — `server/trip-relay/src/store.js:547-555`(`deleteCommands`)
- **문제** — `ids`를 쉼표로 나눈 뒤 개수 상한 없이 전부 HMAC 태그로 바꾼다. `/rules` 지우기는 50개(`src/rules.js:147`), 공유 후보 지우기는 100개(`src/shared.js`)로 막혀 있는데 여기만 없다. URL 길이 상한(수십 KB) 안에서 수천 개까지 들어올 수 있다.
- **고치는 방법** — `deleteRules`와 같은 50개(또는 100개) 상한을 두고, 넘으면 422를 돌려준다.

#### S20. 여행 계획의 제목·id 길이 상한과 항목 검증이 없음
- **파일:줄** — `server/trip-relay/src/validate.js:28-33`(`isTripPlan`)
- **문제** — `title`·`tripId`는 문자열이기만 하면 되고 길이 상한이 없으며, `items`는 개수(500개)만 보고 각 항목의 필드를 검증하지 않는다. 본문 64KB 상한이 있어 크기는 막히지만, 60KB짜리 제목이나 비정상 항목이 그대로 저장·전달된다. 앱이 미리보기에서 처리해야 한다.
- **고치는 방법** — `title` 200자·`tripId` 100자 상한을 두고, 항목마다 최소한 `title` 문자열·`type` 허용 목록 정도의 검사를 넣는다. (앱이 이미 검증한다면 서버 검사는 방어 차원으로만 둔다.)

### 2.2 앱 데이터·백업·파싱

#### D7. `bind(Data)`가 2GB 넘는 payload에서 `Int32` 변환 트랩으로 크래시한다
- **파일:줄** — `Packages/TaptionPlanCore/Sources/TaptionPlanCore/DayStoreV3+SQLite.swift:199-215` (207행 `Int32(value.count)`)
- **문제** — `bind(_ value: Data, ...)`가 길이 검사 없이 `Int32(value.count)`를 쓴다. `value.count > Int32.max`면 Swift 정수 변환이 런타임 트랩으로 크래시한다. 같은 파일의 `bindText`(:169-185행)는 `value.count <= Int(Int32.max)`를 검사해 `integerOverflow`를 던지는데 `bind(Data)`만 검사가 없다.
- **고치는 방법** — `bindText`와 같은 상한 검사를 `bind(Data)`에도 넣는다. (현실적으로 2GB payload는 드물지만, 검사 한 줄로 크래시를 에러로 바꿀 수 있다.)

#### D8. 백업 프레임 복호화에서 빈 압축 payload가 `baseAddress!` 크래시를 낸다
- **파일:줄** — `Packages/TaptionPlanStore/Sources/TaptionPlanStore/TaptionBackupFormat.swift:292-309` (301행)
- **문제** — `TaptionBackupCodec.decompress`가 코덱이 lzfse/zlib이고 `expectedSize > 0`인데 `data`가 비어 있으면 `source.bindMemory(...).baseAddress!`에서 트랩한다. `readSealedFrame`은 `payloadSize == 0`인 프레임을 막지 않는다(크기 검사만 통과하면 됨). 정상 작성기는 이런 프레임을 만들지 않으므로, 인증(GCM)을 통과한 비정상 파일에서만 터진다.
- **고치는 방법** — `decompress` 시작 부분에 `guard !data.isEmpty else { throw .malformed(...) }`를 넣거나, `readSealedFrame`에서 코덱이 압축일 때 `payloadSize > 0`을 요구한다.

#### D9. `backupAllMonths`가 설정 파일 백업 전에 취소를 확인하지 않는다
- **파일:줄** — `TaptionPlan/Core/TaptionBackupEngine.swift:289-297` (296행)
- **문제** — 월 순회 루프 안에서는 매번 `try Task.checkCancellation()`을 하지만, 루프 뒤의 설정 파일 백업(`attempt(.settings, ...)`) 앞에는 검사가 없다. 마지막 월 백업 도중 취소되면 설정 백업이 취소됐는데도 실행된다.
- **고치는 방법** — 296행 앞에 `try Task.checkCancellation()`을 넣는다.

#### D10. 복원 중 대용량 파일 복호화에는 취소 검사가 없어 취소가 늦게 먹힌다
- **파일:줄** — `TaptionPlan/Core/TaptionBackupEngine.swift:551-572` (571행)
- **문제** — `apply`에서 `Task.checkCancellation()`은 `decode`가 끝난 뒤에야 한 번 호출된다. `decode`의 줄 처리 핸들러 안에는 취소 검사가 없어, 수만 행짜리 파일을 풀 때는 취소 요청이 전체 복호화가 끝날 때까지 반영되지 않는다.
- **고치는 방법** — `decode`의 핸들러(또는 `flush` 배치 경계)마다 주기적으로 `try Task.checkCancellation()`을 확인한다.

#### D11. `listBackups`가 직렬화 밖에서 `keyCache`를 비워 진행 중 백업의 키 유도를 다시 하게 한다
- **파일:줄** — `TaptionPlan/Core/TaptionBackupEngine.swift:258` (`keyCache = [:]`), 197행과 대조
- **문제** — `listBackups`는 `exclusive`로 감싸지 않은 액터 메서드라, 백업 작업이 `await` 지점에서 양보한 사이에 끼어들어 `keyCache`를 비울 수 있다. 키가 지워지면 진행 중 백업이 다음 파일을 열 때 PBKDF2 60만 회를 다시 돌린다(기능 오류는 아니고 성능·배터리 비용).
- **고치는 방법** — `listBackups`도 `exclusive`로 감싸거나, 캐시를 비우는 대신 목록용 키와 작업용 키를 분리한다.

#### D12. 백업 JSON Lines 파서가 `NaN`·`Infinity`를 숫자로 받아들인다
- **파일:줄** — `Packages/TaptionPlanStore/Sources/TaptionPlanStore/TaptionBackupFormat.swift:1006` (`Double(token) != nil`)
- **문제** — `Double("NaN")`·`Double("Infinity")`는 `nil`이 아니므로, `NaN` 토큰이 `.number` 필드로 통과한다. 작성기(`Builder.double`)는 유한하지 않은 수를 거부하지만 파서는 허용해, 손상됐거나 조작된(인증된) 파일의 `NaN` 시각이 `Date(timeIntervalSince1970: .nan)`으로 기록 행에 들어갈 수 있다.
- **고치는 방법** — 숫자 토큰 검사에 `value.isFinite`를 추가한다.

#### D13. 백업 검증에서 `fields[5]`를 개수 확인 없이 인덱싱한다
- **파일:줄** — `TaptionPlan/Core/TaptionBackupEngine.swift:794` (`fields[5].double`)
- **문제** — `verifyFile`의 핸들러가 `TaptionBackupRowIdentity.entry(of:)`로 "c" 줄을 골라낸 뒤 `fields[5]`를 바로 읽는다. `entry(of:)`는 필드가 3개만 있어도 기록으로 인정하므로, 필드가 3~5개인 "c" 줄이면 인덱스 범위를 벗어나 크래시한다. 현재는 방금 쓴 임시 파일만 검증하므로 정상 경로에서는 나올 수 없지만, 방어 코드가 없다.
- **고치는 방법** — `fields.count == 10`을 먼저 확인하거나 `fields[safe: 5]` 식의 안전한 접근을 쓴다.

#### D14. "취소"가 들어간 결제가 무조건 환불(수입)로 기록된다 — 취소수수료 같은 실제 지출도 수입이 된다
- **파일:줄** — `TaptionPlan/Core/LedgerCapture.swift:101` (`isCancel: flat.contains("취소")`), `entry` 471-483행
- **문제** — `parse`가 본문에 "취소"만 있으면 `isCancel = true`로 하고, `entry`는 취소 문자를 수입으로 둔다. "취소수수료 10,000원 결제", "취소 수수료가 청구됩니다" 같은 실제 지출이 수입으로 잘못 들어간다. (PROPOSALS 8절 9번은 "취소는 수입으로 들어가고 원래 결제와 이어지지 않는다"는 별개 문제이고, 이 항목은 취소가 아닌 지출이 수입으로 바뀌는 새로운 오분류다.)
- **고치는 방법** — "취소수수료"·"취소 수수료"·"위약금" 같은 수수료 표현이 있으면 취소로 보지 않거나, "취소"가 "승인취소"·"결제취소"·"취소완료" 같은 취소 확정 표현일 때만 `isCancel`로 본다.

#### D15. 정오 12:00 거래를 "시각을 못 읽은 거래"로 오인해 중복 판정이 달라진다
- **파일:줄** — `TaptionPlan/Core/LedgerCapture.swift:627-634`
- **문제** — `LedgerCaptureBatch.exists`가 `hour: 12, minute: 0`인 항목을 시각 없음으로 보고 같은 날 기준으로 중복을 판단한다. 실제로 정오 12시 정각에 결제한 거래도 같은 취급을 받아, 같은 날 같은 금액의 다른 결제를 중복으로 빼 버릴 수 있다. (스크린샷 리더가 시각을 못 읽으면 낮 12시를 기본값으로 쓰기 때문에 생긴 구분법이다.)
- **고치는 방법** — 시각을 못 읽었는지 여부를 `Date` 값이 아니라 별도 플래그(예: `occurredAtKnown: Bool`)로 들고 다니게 한다.

#### D16. `appendRawEvents`에 배치·payload 크기 상한이 없어 긴 쓰기 트랜잭션이 다른 쓰기를 막는다
- **파일:줄** — `Packages/TaptionPlanCore/Sources/TaptionPlanCore/DayStoreV3.swift:99-146`, `DayStoreV3+Schema.swift:7` (`busy_timeout=5000`)
- **문제** — `appendRawEvents`는 이벤트 수나 payload 크기를 제한하지 않는다. 아웃박스(`insertOutboxItems`)에는 건수 4,096개·합계 64MB 상한이 있지만 raw 이벤트에는 없다. 수천 건을 한 `BEGIN IMMEDIATE` 트랜잭션으로 쓰면 5초 busy timeout을 넘는 동안 다른 연결의 쓰기가 `SQLITE_BUSY`("database is locked")로 실패한다.
- **고치는 방법** — 배치 크기에 상한을 두고(예: 1,000건 또는 4MB) 넘으면 나누어 쓰거나 에러를 던진다. 또는 호출자(복원 경로)가 페이징하도록 문서화한다.

#### D17. 공유 세션의 `probe`·`hello`·잠금 연장이 에러를 조용히 삼킨다
- **파일:줄** — `Packages/TaptionTripShare/Sources/TaptionTripShare/ShareRoomSession.swift:229-240` (`catch {}` 237행), 252행 (`try? await catchUp()`), 590-604행 (`catch {}` 601행)
- **문제** — 소켓이 끊긴 뒤 HTTP로 서버를 확인하는 `probe`가 모든 에러를 `catch {}`로 버리고 상태도 바꾸지 않는다. 주석에는 "나갔는지·방이 없는지·비밀번호가 바뀌었는지·인터넷이 없는지"를 본다고 적혀 있지만, 오류가 나면 UI는 아무것도 알 수 없다. `renewLocks()`는 `.locked`가 아닌 오류(네트워크 등)를 삼키고 `return true`를 돌려주어, 호출부(`:585`)가 false일 때만 갱신 태스크를 멈추므로 실패가 반복돼도 로그 한 줄 없이 계속 시도한다. 재연결이 왜 안 되는지, 따라잡기가 왜 멈췄는지 진단할 단서가 남지 않는다.
- **고치는 방법** — 최소한 진단 로그(`TaptionPlanDiagnosticsLogger`)에 에러 종류를 남긴다. `probe`는 `ShareError` 종류별로 나눠 방 없음·비밀번호 변경이면 끝 상태로 바꾸고 알림(`emit`)을 보내고, 네트워크 오류면 로그만 남긴다. `renewLocks`는 연속 실패 횟수를 세어 일정 횟수 넘으면 상태를 `offline`으로 바꾸는 것을 검토한다.

#### D18. 중계 전송이 `CancellationError`를 삼켜 취소와 네트워크 실패를 구분하지 못한다
- **파일:줄** — `Packages/TaptionAssistant/Sources/TaptionAssistantKit/TripRelay.swift:132` (`try? await session.data(for: request)`)
- **문제** — `sendResponse`가 `try?`로 모든 에러를 `nil`로 만든다. 작업 취소도 네트워크 실패와 같은 `nil`이 돼, 호출자(명령 폴링·작업 업로드)가 취소됐는데도 실패로 처리하고 다음 폴링을 예약하거나 재시도할 수 있다.
- **고치는 방법** — `CancellationError`는 다시 던지고(`catch is CancellationError { throw ... }`), 나머지만 `nil`로 만든다. 또는 `send`의 반환 타입에 취소 여부를 구분한다.

#### D19. 복원 준비 파일 비교에서 길이 0 blob이 `Data(bytes: nil)` 트랩을 낼 수 있다
- **파일:줄** — `Packages/TaptionPlanStore/Sources/TaptionPlanStore/TaptionStoreBackupRestore.swift:101-104`
- **문제** — `stagedValue`의 BLOB 분기가 `sqlite3_column_blob` 결과를 옵셔널 해제 없이 `Data(bytes:count:)`에 넘긴다. 길이 0인 blob은 `sqlite3_column_blob`이 NULL을 돌려주므로 트랩한다. 준비 DB가 손상됐을 때만 나오는 경로지만, 복원 비교 도중 크래시하면 복원이 중단된다.
- **고치는 방법** — `sqlite3_column_blob`이 `nil`이면 빈 `Data()`를 돌려주도록 `guard let`을 넣는다.

#### D20. 공유 키 유도(`ShareKeys.derive`)의 반복 횟수 하한이 없다
- **파일:줄** — `Packages/TaptionTripShare/Sources/TaptionTripShare/ShareKeys.swift:79` (`iterations > 0`만 검사)
- **문제** — `pbkdf2`가 `iterations > 0`만 요구한다. 현재 모든 호출처가 기본값 60만 회를 쓰지만, 나중에 어떤 호출처가 작은 값을 넘기면 조용히 약한 키가 만들어진다. 백업 쪽 `deriveKey`는 `minIterations`(10만)~`maxIterations`(500만) 범위를 강제하는 것과 대조된다.
- **고치는 방법** — `derive`·`pbkdf2`에 최소 반복 횟수(예: 100,000)를 강제한다.

### 2.3 테스트 공백 — P0 (돈·백업·분류·보안 핵심)

#### T-01. 이동 수단 점수 로직 전체 미테스트
- **파일:줄** — `Packages/TaptionClassifierEngine/Sources/TaptionClassifierEngine/ModeScorer.swift:26`
- **문제** — `ModeScorer.score(_:)`와 `WindowScore.best()`가 테스트에 한 번도 안 나온다. 속도 프로파일·Core Motion 가중치·비행기 최소속도(`airplaneMinimumSpeed = 55.0`)·배 속도 범위(`shipSpeedRange = 4.0...17.0`)가 분류 결과를 직접 정하는데 고정된 테스트가 없다. (직접 대조 확인함 — 테스트 참조 0건)
- **고치는 방법** — `TaptionClassifierEngineTests`에 속도별 `best()` 단언(걷기 1.3m/s·자동차 12m/s·비행기 200m/s 부근), 55m/s 경계, 배 범위 경계(4·17), `bestSpeed == nil` + `isIdle` 분기, Core Motion 분기별 점수 테스트 추가.

#### T-02. 분류 파이프라인 구간·지점 연산 미테스트
- **파일:줄** — `Packages/TaptionClassifierEngine/Sources/TaptionClassifierEngine/ClassifierModels.swift:4,50,59,68,156,160,166,179`
- **문제** — `ClassifierPipeline.modelVersion(_:)`·`isIdle(accelerationStandardDeviationG:rotationRate:)`, `ClassifierPoint.bearing(to:)`·`centroid(_:)`, `ClassifierInterval.overlap(with:)`·`intersection(with:)`·`union(_:gap:)`·`subtracting(_:from:)`가 테스트에 안 나온다. `distance(to:)`만 `ClassifierEngineTests.swift:178`에서 1회 간접 사용.
- **고치는 방법** — 겹침 없음/부분 겹침/포함, `union` 빈틈(gap) 경계, `subtracting` 자르기, `bearing` 0/360 경계, `centroid` 빈 배열(nil), `isIdle` 임계값 테스트 추가.

#### T-04. 백업 경로 대체 엔진 전체 미테스트
- **파일:줄** — `TaptionPlan/Core/PlanBackupRouteFallbackEngine.swift:11`
- **문제** — `PlanBackupRouteFallbackEngine` 전체가 테스트에 안 나온다. 백업 경로가 막혔을 때 대체 경로를 고르는 엔진인데, 간격 상한(`maximumRouteGap = 15 * 60`, :13) 경계 동작이 고정돼 있지 않다.
- **고치는 방법** — 간격 15분 경계(바로 아래/위), 대체 경로 선택·포기 케이스 테스트 추가.

#### T-05. 되돌리기 기록 타입 미테스트
- **파일:줄** — `TaptionPlan/UX/AppModel+EditHistory.swift`
- **문제** — `AppModelHistoryChange`·`AppModelHistoryEntry`·`AppModelHistoryItem`이 테스트에 안 나온다. 사용자 편집 되돌리기의 기록 형식이라, 형식이 깨지면 되돌리기가 조용히 안 된다.
- **고치는 방법** — 기록 생성→직렬화→복원 왕복, 되돌리기 적용·무시 케이스 테스트 추가.

#### T-06. Watch 하루 저장소 미테스트 (Watch 테스트 타깃 자체가 없음)
- **파일:줄** — `TaptionPlan/Core/WatchDayDatabase.swift:6`
- **문제** — `actor WatchDayDatabase`가 테스트에 안 나온다. `TaptionPlanWatch/`에는 테스트 타깃이 아예 없고, 앱 테스트의 Watch 관련 파일(`FeatureEngineTests+Watch.swift` 등)은 이 actor를 안 건드린다.
- **고치는 방법** — 앱 테스트 타깃에서 `WatchDayDatabase`를 직접 두는 단위 테스트를 넣거나, Watch 테스트 타깃 신설 여부를 대표에게 묻는다.

#### T-07. Watch 행동 CoreML 브리지 미테스트
- **파일:줄** — `Packages/TaptionWatchSync/Sources/TaptionWatchBehaviorML/WatchBehaviorModel.swift:9`
- **문제** — `WatchBehaviorModel.load(bundle:resource:)`·`predict(features:)`가 테스트에 안 나온다. `WatchWorkoutManager.swift:104`에서 `load()` 결과를 쓰는데, 모델이 없을 때 nil 경로조차 고정돼 있지 않다.
- **고치는 방법** — 모델 없는 번들에서 `load()`가 nil을 돌려주는 테스트부터 추가. `predict`는 작은 테스트용 `.mlmodelc` 픽스처가 필요하면 별도 작업으로 나눈다.

#### T-09. StoreKit 순수 로직 미테스트 (테스트 인프라 import만 있음)
- **파일:줄** — `TaptionPlan/Core/StoreKitSupport.swift:6,34,51`
- **문제** — `TaptionCommercePolicy.isSupportedProProductType(_:)`·`grantsProAccess(_:)`, `TaptionProAccessState`, `TaptionProTrialPolicy.merged(_:)`·`state(_:)`가 테스트에 안 나온다. `TaptionPlanTests/FeatureEngineTests+Planning.swift:4-5`는 `StoreKit`·`StoreKitTest`를 import만 하고 쓰지 않는다. IAP 판매는 보류 중(`AGENTS.md` 4절)이지만 체험·접근 판정은 순수 로직이라 지금 테스트할 수 있다.
- **고치는 방법** — 체험 합치기(중복·만료), 접근 상태 판정, Pro 제품 타입 판정 테스트 추가. 미사용 import는 정리.

#### T-10. 정산 원 단위 변환 경계 미테스트
- **파일:줄** — `Packages/TaptionLedgerCore/Sources/TaptionLedgerCore/LedgerTrips.swift:192`
- **문제** — `LedgerSplit.won(_:)`의 경계 분기(비유한→0, |금액| ≥ 1e15→0)가 테스트에 안 나온다. `even`·`transfers`·`greedy`·`zeroSumGroups`는 `LedgerTests.swift:1578` `LedgerSplitTests`에서 충분히 테스트됨.
- **고치는 방법** — `won(.nan)`·`won(.infinity)`·`won(1e15)`·`won(-1e15)` 단언 추가.

#### T-11. 환율 파싱·집계 경계 미테스트
- **파일:줄** — `Packages/TaptionLedgerCore/Sources/TaptionLedgerCore/LedgerCore.swift:92,163`
- **문제** — `LedgerFX.parse(_:)`와 `LedgerEntry.countedKRW`가 테스트에 직접 안 나온다. `krwPerUnit`·`signedKRW`(취소 건 0, `LedgerReviewTests.swift:50`)는 테스트됨.
- **고치는 방법** — `parse`에 잘못된 JSON·빈 데이터·통화 빠짐 케이스, `countedKRW`에 취소/미취소·`amountKRW == nil` 케이스 추가.

#### T-12. 센서 하루 파생 타입 미테스트 (리팩토링으로 새로 만든 타입)
- **파일:줄** — `TaptionPlan/UX/SensorTimelineDerivation.swift`, `TaptionPlan/UX/AppModel+SensorRefreshEvidence.swift`, `TaptionPlan/UX/AppModel+SensorRefreshRebuild.swift`
- **문제** — `SensorStayDerivation`·`SensorTravelDerivation`·`SensorRefreshEvidence`·`SensorRouteEvidence`·`SensorDayDerivation`이 테스트에 안 나온다. RFT1116A03에서 `performSensorTimelineRefresh`를 나누며 만든 타입들인데, `SensorTimelineRefreshTests`는 결과·되돌리기·취소만 고정하고 이 파생 타입들을 직접 안 건드린다.
- **고치는 방법** — 체류·이동 파생(경계 시각·빈 구간), 근거 읽기(지문 같은 날·다시 만드는 날) 테스트 추가.

#### T-13. 휴식 쪼개기 미테스트 + 제목 하드코딩
- **파일:줄** — `TaptionPlan/Core/WorkBreakPattern.swift:5,81`
- **문제** — `WorkBreakPattern.splitting(records:readings:asOf:)`가 테스트에 안 나온다. 회사 체류 중 휴식을 가르는 분류 로직인데, 갈라진 조각 제목이 `value.title = "휴식"`으로 하드코딩돼 있다.
- **고치는 방법** — 휴식 구간 분리·최소 길이·경계 테스트 추가. 제목은 분류 카탈로그의 "휴식" 상수를 쓰거나 번역 경로로 옮긴다(L-04와 함께).

#### T-14. 통행료·대중교통 요금 러너 미테스트
- **파일:줄** — `TaptionPlan/Core/LedgerTollGate.swift`, `TaptionPlan/Core/LedgerTransitFare.swift`
- **문제** — `LedgerTollFareStore`·`LedgerTollGateRunner`·`LedgerTollKakaoRunner`·`LedgerTransitFareRunner`가 테스트에 안 나온다. `LedgerTollGateTests.swift`는 게이트 정책만 테스트하고 실제 요금 조회 러너는 안 건드린다. 돈이 걸린 외부 조회라 실패·재시도 경로가 고정돼 있지 않다.
- **고치는 방법** — 가짜 요금표·가짜 응답으로 성공·빈 결과·오류·재시도 테스트 추가.

#### T-15. 단축어 진입점 미테스트
- **파일:줄** — `TaptionPlan/Core/FlightIntents.swift:22,56`
- **문제** — `FlightIntentRunner.run(_:now:)`·`SharedTextIntentRunner.run(_:now:container:)`이 테스트에 안 나온다. 단축어 자동화가 부르는 진입점인데, 앱 미준비 시 보관함(`FlightInbox.stash`·`FlightShareStore.enqueue`) 분기가 고정돼 있지 않다. (Intent 타입 자체는 시스템이 발견하므로 살아 있다.)
- **고치는 방법** — 준비됨/미준비·항공 알림/일반 글·읽기 실패 케이스 테스트 추가.

### 2.4 테스트 공백 — 패키지 자체 테스트 없음

#### TaptionLedgerCore에 테스트 파일이 없음
- **파일:줄** — `Packages/TaptionLedgerCore/` (소스 `LedgerCore.swift`, `LedgerTrips.swift` 2개, Tests 디렉토리 없음)
- **문제** — 가계부 값 타입·여행 장부 타입에 단위 테스트가 없다. `LedgerMessageParser` 테스트는 앱 테스트(`TaptionPlanTests/LedgerMessageAccuracyTests.swift` 등)에 있고, 정산·환율 계산 일부도 앱 테스트에서 커버되지만, 패키지 자체의 Codable 왕복·정산 계산 등은 직접 테스트가 없다. (T-10·T-11과 함께 해결)
- **고치는 방법** — `Packages/TaptionLedgerCore/Tests/TaptionLedgerCoreTests/`를 만들고 Codable 왕복·금액 합계·정산 계산·`won` 경계·`LedgerFX.parse` 테스트를 더한다. 그 뒤 CI packages job 목록(CI-1)에도 추가한다.

### 2.5 조용히 실패하는 곳 (그 외)

#### Watch 요약 저장 실패가 로그 없이 사라짐
- **파일:줄** — `TaptionPlan/UX/AppModel+WatchSummary.swift:658-668` (`persistWatchSummaryForDelivery`의 `catch { }`), 같은 파일의 `applyWatchSensorSummary`에 `return false` 경로가 약 15곳(165·172·184·188·199·203·217·287·291·344·382·388·414·429·432행 등)
- **문제** — Watch 요약 저장·적용이 실패하면 false만 돌려주고 어디에도 원인이 남지 않는다. Watch 동기화 문제를 나중에 추적할 길이 없다.
- **고치는 방법** — `persistWatchSummaryForDelivery`의 catch에서 `integrationLogger`로 오류를 남긴다. `applyWatchSensorSummary`의 주요 실패 지점에도 짧은 로그(어느 분기에서 멈췄는지)를 더한다. 좌표·건강 원본 값은 로그에 넣지 않는다.

#### 임시 파일 정리 실패를 삼킴 (낮음)
- **파일:줄** — `TaptionPlan/Core/PlanRepository.swift:711` (`catch {}` after `removeItem`)
- **문제** — 임시 파일 삭제가 실패하면 조용히 넘어가 임시 파일이 쌓일 수 있다.
- **고치는 방법** — 실패 횟수를 세어 디버그 로그로 남기거나, 반환값에 실패 개수를 포함한다. 동작 변경은 필요 없다.

### 2.6 번역 카탈로그를 안 타는 하드코딩 문구

앱은 `language.text(한국어, 영어)`(`UIPhrase`, `scripts/l10n` 추출 대상)와 `language.runtimeText`로 번역한다. 아래는 둘 다 안 타는 곳이다.

#### L-01. 오류 알림 제목·버튼 하드코딩
- **파일:줄** — `TaptionPlan/UI/AppShellView.swift:180,183`
- **문제** — `.alert("확인해 주세요", ...)` 제목과 `Button("확인")`이 한국어 그대로 박혀 있다.
- **고치는 방법** — `language.text("확인해 주세요", "Please check")`, `language.text("확인", "OK")`로 바꾼다.

#### L-02. 시트 제목 하드코딩
- **파일:줄** — `TaptionPlan/UI/MapHomeCounterDetailSheet.swift:309`
- **문제** — `Text("카운터 상세")`가 그대로 박혀 있다.
- **고치는 방법** — `language.text("카운터 상세", "Counter details")`로 바꾼다.

#### L-03. 접근성 라벨 하드코딩 5곳
- **파일:줄** — `TaptionPlan/UI/MapHomeMapAnnotations.swift:112,225,249`, `TaptionPlan/Core/CatAnimationShared.swift:311`, `TaptionPlan/UI/MapHomePhotoLayer.swift:334`
- **문제** — `.accessibilityLabel("집 레벨 ...")`, `.accessibilityLabel("집 성장과 오늘 하루 요약 보기")`, `.accessibilityLabel("집 레벨 ... · 성장 카드와 오늘 하루 요약 열기")`, `.accessibilityLabel("고양이 애니메이션")`, `.accessibilityLabel(Text("사진 \(count)장"))`이 번역 경로를 안 탄다. VoiceOver가 영어로 설정돼도 한국어로 읽힌다.
- **고치는 방법** — `language.text`/`language.runtimeText`로 바꾼다.

#### L-04. 분류 근거(evidence) 문자열 한국어 전용 + UI 노출
- **파일:줄** — `Packages/TaptionClassifierEngine/Sources/TaptionClassifierEngine/ModeScorer.swift:41`("가속도·회전 정지" 등), `TaptionPlan/Core/WorkBreakPattern.swift:12,81`("화면을 켠 채 폰을 손에 듦", 제목 "휴식"), `TaptionPlan/Core/AppleWatchSensorActivityEngine.swift:36,39,212,325,328,331`("심박수", "걸음·거리", "집 위치 내 지속 움직임" 등), `TaptionPlan/UI/MapHomeNLESubActivity.swift:201,211,241`("자동 기록", "이동 구간 판정", "일정 '\(...)'")
- **문제** — 근거 문자열이 한국어로만 만들어지는데, `MapHomeNLESubActivity.swift:199-201` `recordEvidence`가 `actual.evidence.first`를 후보 화면의 근거로 그대로 보여 준다. 영어 사용자는 근거가 한국어로 보인다.
- **고치는 방법** — 근거를 코드(키)로 저장하고 표시할 때 번역하거나, 최소한 UI에 노출되는 근거만 `language.text`로 바꾼다. 근거 문자열을 파싱하는 곳(`MapHomeApplePlaybackMath.swift:437` "노선 " 접두사 등)이 있어 형식을 바꾸면 함께 고쳐야 한다.

### 2.7 접근성 — 라벨 없는 이미지 버튼

#### A-01. `accessibilityLabel` 없는 이미지 전용 버튼 4곳
- **파일:줄** — `TaptionPlan/UI/LedgerSheet.swift:218,222` (월 이동 버튼 `chevron.left`·`chevron.right`), `TaptionPlan/UI/MapHomePlaceBookTools.swift:840,842` (여행 정류장 순서 이동 버튼 `chevron.up`·`chevron.down`)
- **문제** — 라벨이 없어 VoiceOver가 "버튼"으로만 읽는다. 바로 옆 `:844` 삭제 버튼은 `.accessibilityLabel(language.text("삭제", "Delete"))`이 있다.
- **고치는 방법** — `language.text("이전 달", "Previous month")`·`language.text("다음 달", "Next month")`, `language.text("위로 이동", "Move up")`·`language.text("아래로 이동", "Move down")` 라벨 추가.

---

## 3. P2 — 일관성·품질·정리

### 3.1 서버 — 문서·일관성

#### S21. OpenAPI 문서와 실제 동작이 다름
- **파일:줄** — `server/trip-relay/src/openapi.js` 전체, 대조: `src/index.js`의 ROUTES, `src/mcp.js:14`
- **문제**
  1. `GET /tasks`가 문서에 없다. `/tasks/claim` 설명문에 "a read key can only list them with GET /tasks"라고 적혀 있는데 정작 `/tasks` 경로 정의가 없다.
  2. `/rules`(GET·POST·DELETE), `/rules/ops`, `/rules/ack`가 문서에 없다. AI가 부르는 경로인데 빠져 있다.
  3. `/tasks/claim`은 비었을 때 204를 돌려주는데(`src/store.js`의 `tasksReply`) 문서에는 200만 있다. `/tasks/result`는 409(`not_claimer`·`already_finished`)를 돌려주는데 문서에는 404·422만 있다. `/command`는 422 `app_too_old`를 돌려주는데 문서에 없다.
  4. `setSetting` 설명이 오래됐다. 문서에는 `memoDisplay`·`strideCentimeters`·`watchAcceleration`·`watchDataSync`·`location`·`photos`가 없고, 실제 `SETTINGS`(`src/validate.js`)에는 있다.
  5. 버전 표기 불일치: OpenAPI `info.version`은 `3.0.0`(`openapi.js:159`), MCP `SERVER_INFO.version`은 `3.1.0`(`mcp.js:14`).
- **고치는 방법** — `paths`에 `/tasks`(GET)와 `/rules`·`/rules/ops`·`/rules/ack`를 추가하고, 각 경로의 204·409·`app_too_old` 응답을 적는다. `setSetting` 설명을 `SETTINGS`에서 자동 생성하거나 목록을 맞춘다. 버전은 한 곳(예: `src/version.js`)에서 export해 두 파일이 같이 쓰게 한다.

#### S22. 같은 상수가 여러 파일에 따로 정의됨
- **파일:줄** — `DAY_MS = 86_400_000`: `src/state.js:12`, `src/store.js:13`, `src/share.js:10`, `src/shared.js:15`, `src/keys.js:12`, `src/classifier.js:17`, `src/flights.js:291` (7곳). `MINUTE_MS = 60_000`: `src/state.js:11`, `src/share.js:9`. `USER_AGENT`: `src/flights.js:20`, `src/expressway.js:23` (같은 두 파일에 `text()`·`cached()`·`keep()`·`methodOnlyGet()`·`missingKey()`·`upstreamFailed()`도 거의 같은 코드로 중복). 명령·말풍선 하루 한도: `src/store.js:17,19`의 `DAILY_COMMAND_LIMIT = 100`·`DAILY_BUBBLE_LIMIT = 48`과 `src/state.js:45,47`의 `LIMITS.commandsPerDay = 100`·`LIMITS.bubblesPerDay = 48`이 같은 값. `TASK_CLAIM_MS = 30 * 60_000`(`src/store.js:153`)은 어디에서도 쓰이지 않는 죽은 export(실제 값은 `LIMITS.taskClaimMs`). 일 개수 상한: `TASK_LIMIT = 100`(`src/validate.js:541`)과 `LIMITS.tasks = 100`(`src/state.js:39`). 이름이 비슷한데 다른 값도 있다: `QUEUE_LIMIT = 50`(`src/validate.js`, 명령 결과 개수)과 `LIMITS.queue = 100`(`src/state.js`, 명령 큐 크기). 코드 알파벳: `CONNECT_ALPHABET`(`src/oauth.js`)과 `ALPHABET`(`src/setup.js`)이 같은 32자 집합(순서만 다름).
- **문제** — 한쪽만 바꾸면 오류 응답의 `limit`이 거짓이 되거나 동작이 어긋난다.
- **고치는 방법** — `src/constants.js`(또는 `http.js`)에 `DAY_MS`·`MINUTE_MS`·`USER_AGENT`를 두고 import하게 한다. 중계용 `cached`·`keep`·`methodOnlyGet`은 `src/upstream.js` 같은 공용 모듈로 뺀다. `DAILY_*`는 `LIMITS`를 재사용하고 `TASK_CLAIM_MS`는 지운다. `QUEUE_LIMIT`은 `RESULT_LIMIT`처럼 뜻이 드러나게 이름을 바꾼다.

#### S23. 카카오 키워드 중계만 상류 오류를 그대로 통과시킴
- **파일:줄** — `server/trip-relay/src/index.js:66-70`(`kakaoKeyword`), 대조: `src/index.js:84-88`(`kakaoImage`), `:162-165`(`photoSearch`)
- **문제** — `kakaoKeyword`는 상류 상태 코드와 본문을 그대로 돌려준다(4xx·5xx 포함, HTML 오류 페이지도 `application/json`으로 둔갑). `kakaoImage`·`photoSearch`는 `!upstream.ok`면 502로 정규화한다. 같은 중계인데 오류 규약이 다르다.
- **고치는 방법** — `kakaoKeyword`도 `!upstream.ok`면 `json({ error: "upstream", status: upstream.status }, 502)`로 맞춘다. (의도적으로 상류 상태를 노출하려는 거라면 주석에 이유를 적는다.)

#### S24. MCP 413 응답이 JSON-RPC가 아님
- **파일:줄** — `server/trip-relay/src/mcp.js`의 `mcpRoute`(본문 읽기 실패 분기)
- **문제** — 본문이 64KB를 넘으면 평문 JSON `{"error":"too_large"}` 413을 돌려준다. 400(parse error)은 JSON-RPC 오류로 감싸는데 413만 다르다. MCP 클라이언트가 JSON-RPC를 기대하고 파싱하면 실패할 수 있다.
- **고치는 방법** — 413도 `rpcError(null, -32600, "Request too large")` 형태로 감싸거나, 최소한 `jsonrpc` 필드를 포함한 오류 본문을 돌려준다.

#### 서버 테스트 공백 (S1–S24와 함께)
- **T1.** `set_rule_enabled`·`delete_rule`의 권한 동작 테스트 없음. `test/phase2.test.mjs:332-334`에 도구 목록 완성도 검사만 있고, "AI가 사용자 규칙을 끄지 못한다"는 동작 테스트가 없다. S1을 고치면 이 테스트부터 넣는다.
- **T2.** 일 100개 초과 시 열린 일 소실(S4) 테스트 없음. `test/tasks.test.mjs`에 상한 초과·축출 테스트가 없다.
- **T3.** 설정 링크 동시 읽기(S6) 테스트 없음. `test/polish.test.mjs:84-99`는 순차 3회 읽기만 확인한다.
- **T4.** `saveResults`·`saveExtras` 동시 병합(S5) 테스트 없음.
- **T5.** 암호화 보조 함수 단위 테스트 없음. `pinMac`·`pepperedKey`·`deriveToken`·`sameBytes`·`sameText`를 직접 부르는 테스트가 없다(PIN·OAuth 통합 테스트로 간접 검증만 된다). 특히 `deriveToken`의 결정성(같은 입력→같은 토큰)과 `pinMac`의 솔트·페퍼 분리가 단위 테스트로 고정돼 있지 않다.
- **T6.** `not_claimer` 분기 테스트 없음. `already_finished`는 `test/aif.test.mjs:46`에서 확인하지만, 남이 맡은 일을 끝내려 할 때 409가 나는 경로는 테스트가 없다.
- **T7.** 환율 캐시 손상 폴백 테스트 없음(S18과 함께).
- **T8.** `addPaymentRule` 정규식 안전 검사 테스트 없음(S8과 함께).
- **T9.** `/public/assets` 속도 제한 테스트 없음(S3과 함께).

### 3.2 앱 데이터·백업 — 낮음

#### D21. 백업 작성기가 기존 파일을 절단하지 않아 이전 내용 찌꺼기가 남을 수 있다
- **파일:줄** — `Packages/TaptionPlanStore/Sources/TaptionPlanStore/TaptionBackupFormat.swift:474-479`
- **문제** — `TaptionBackupFileWriter.init`이 `createFile` 후 `FileHandle(forWritingTo:)`로 열 뿐 절단하지 않는다. 대상 파일이 이미 있고 새 내용보다 길면 꼬리에 예전 바이트가 남아, 복호화 마지막의 "남은 바이트 없음" 검사가 실패한다. 엔진은 항상 UUID 임시 파일을 쓰므로 현재 경로는 안전하다.
- **고치는 방법** — 열 때 `try handle.truncate(atOffset: 0)`을 하거나, 기존 파일이 있으면 지우고 만든다.

#### D22. 한 줄이 프레임 상한을 넘으면 그 달 백업 전체가 실패한다
- **파일:줄** — `Packages/TaptionPlanStore/Sources/TaptionPlanStore/TaptionBackupFormat.swift:522-525`
- **문제** — `append`가 줄 하나를 `chunkBytes`보다 크게 두지 못하고, `flush`에서 `maxPlainFrameBytes`(엔진 설정 4MB 청크 기준 16MB)를 넘으면 `malformed("frame too large")`를 던져 그 달 백업 전체가 실패한다. 16MB짜리 메모 한 건이 달 전체 백업을 막는다.
- **고치는 방법** — 실패 전에 해당 행을 건너뛰고 결과에 알리거나, 프레임 상한을 넘기는 줄은 별도 에러로 구분해 사용자에게 보여준다.

#### D23. `TaptionDataFileLock.unlock`이 스레드에 안전하지 않아 fd를 두 번 닫을 수 있다
- **파일:줄** — `Packages/TaptionPlanStore/Sources/TaptionPlanStore/TaptionDataFileLock.swift:61-66`
- **문제** — `unlock()`의 `descriptor >= 0` 검사와 `-1` 대입 사이에 동기화가 없다(`@unchecked Sendable`). 두 스레드가 동시에 부르면 둘 다 `close`를 호출하고, 그 사이 fd 번호가 재사용되면 다른 파일의 fd를 닫을 수 있다. `deinit`에서도 `unlock()`을 부르므로 명시적 해제와 소멸이 겹칠 수 있다.
- **고치는 방법** — `NSLock`이나 `OSAllocatedUnfairLock`으로 `unlock`을 감싼다.

#### D24. `checkpoint()`가 PASSIVE 체크포인트가 실제로 끝났는지 확인하지 않는다
- **파일:줄** — `Packages/TaptionPlanCore/Sources/TaptionPlanCore/DayStoreV3.swift:499-517`
- **문제** — `sqlite3_wal_checkpoint_v2`에 `SQLITE_CHECKPOINT_PASSIVE`를 쓰고 로그/체크포인트 프레임 수(out 파라미터)를 `nil`로 버린다. PASSIVE는 다른 연결이 읽는 중이면 `SQLITE_OK`를 돌려주면서도 WAL을 다 비우지 않으므로, 호출자는 체크포인트가 끝난 줄 알고 WAL이 남아 있는 상태로 진행한다.
- **고치는 방법** — `logFrames`·`checkpointedFrames`를 받아 둘이 다르면 `SQLITE_CHECKPOINT_RESTART`로 한 번 더 시도하거나 결과를 호출자에게 알린다.

#### D25. `deleteAllData`가 `migration_markers`를 남긴다
- **파일:줄** — `Packages/TaptionPlanCore/Sources/TaptionPlanCore/DayStoreV3.swift:412-452`
- **문제** — 전체 삭제가 `raw_events`·`day_materialized`·`raw_digest_cache`·`device_outbox`·`raw_restore_receipts`를 지우지만 `migration_markers`는 남긴다. "데이터 전체 삭제 후 다시 가져오기" 흐름에서 예전 마이그레이션 완료 표시가 남아, 새 데이터에 필요한 마이그레이션을 건너뛸 수 있다. 스키마 수준 표시라 의도된 것일 수도 있다.
- **고치는 방법** — 의도인지 확인하고, 데이터 삭제의 일부라면 `migration_markers`도 함께 지우거나, 남기는 이유를 주석으로 남긴다.

#### D26. 복원 영수증이 손상되면 롤백이 영원히 실패하고, 이 API는 실사용처가 없다
- **파일:줄** — `Packages/TaptionPlanCore/Sources/TaptionPlanCore/DayStoreV3.swift:149-197` (154행 `JSONDecoder().decode`)
- **문제** — `finishRestoreSession(committed: false)`에서 영수증 JSON 복호화가 실패하면 트랜잭션 전체가 롤백되고 영수증이 남아, 다시 불러도 같은 곳에서 실패한다(독성 영수증). 또한 `restoreSessionID`·`finishRestoreSession`은 테스트에서만 쓰이고 실사용처가 없다.
- **고치는 방법** — 복호화에 실패한 영수증은 건너뛰고 지우거나 별도 에러로 보고해 롤백이 진행되게 한다. 실사용처가 없을 예정이면 API를 정리하거나 사용처를 문서화한다.

#### D27. 가게 이름에 "충전"이 들어간 결제가 충전으로 오인돼 빠진다
- **파일:줄** — `TaptionPlan/Core/LedgerCapture.swift:35-40` (39행)
- **문제** — `isTopUp`이 본문에 "충전"만 있고 `spendingCharges`("충전소"·"전기차"·"충전요금" 등)가 없으면 충전으로 본다. "충전"이 들어간 상호에서의 실제 결제(예: "배터리충전 5,000원 결제")가 가계부에서 빠진다.
- **고치는 방법** — "충전" 뒤에 금액이 바로 오는 형태("충전 50,000원")나 충전 대상("○○카드 충전") 패턴일 때만 충전으로 본다.

#### D28. 다건 알림 정규식이 " N건 "이 들어간 일반 결제를 안내로 오인한다
- **파일:줄** — `TaptionPlan/Core/LedgerCapture.swift:48`
- **문제** — `isNotice`의 `(?:^|\s)[0-9]+건(?:\s|$)`이 "스타벅스 2건 15,000원 결제" 같은 글도 안내로 빼 버린다. 건수가 들어간 결제 알림이 누락될 수 있다.
- **고치는 방법** — 건수와 함께 "합계"·"총"·"이용내역" 같은 집계 표현이 있을 때만 안내로 본다.

#### D29. 날짜 파싱이 월별 일수를 검증하지 않는다 (2월 31일 등)
- **파일:줄** — `TaptionPlan/Core/LedgerCapture.swift:190` (`(1...31).contains`), 583행 (`dayHeader` 동일)
- **문제** — `date`와 `dayHeader`가 일을 1~31로만 검사한다. "2월 31일" 같은 존재하지 않는 날짜가 들어오면 `Calendar.date(from:)`의 정규화 동작에 따라 다른 날짜(3월 3일 등)로 바뀌어 조용히 저장될 수 있다. (T-03과 같은 패턴)
- **고치는 방법** — 만든 `Date`의 월·일이 입력과 같은지 왕복 확인하고 다르면 `nil`을 돌려준다.

#### D30. 영수증 머리말("영수증" 등)이 가게 이름이 된다
- **파일:줄** — `TaptionPlan/Core/LedgerCapture.swift:529-532`
- **문제** — `LedgerReceiptReader.draft`가 가게 이름을 "글자가 있고 숫자가 없는 첫 줄"로 잡는다. 영수증 첫 줄이 "영수증"·"매출전표"·"현금영수증"이면 그 말이 가게 이름이 된다.
- **고치는 방법** — "영수증"·"매출전표"·"현금영수증"·"거래명세서" 같은 머리말을 제외하고 다음 줄을 본다.

#### D31. Keychain 비밀 읽기에서 키 형식 검증이 없다
- **파일:줄** — `Packages/TaptionAssistant/Sources/TaptionAssistantKit/AssistantSecrets.swift:33-39`
- **문제** — `AssistantKeychainSecrets.read`가 UTF-8 문자열이면 그대로 돌려준다. `TripRelay.key`는 `isValidKey`(43자 base64url)를 검사하는 것과 대조된다. 손상된 값이 들어가면 서버가 거부할 때까지만 알 수 있다.
- **고치는 방법** — `master`·`pendingMaster` 슬롯은 `TripRelay.isValidKey`로 검증하고, 형식이 다르면 `nil`을 돌려준다.

#### D32. 백업 교체 후 확인용 fetch가 실패하면 이미 교체된 파일을 실패로 보고한다
- **파일:줄** — `TaptionPlan/Core/TaptionBackupEngine.swift:444-457`
- **문제** — `write`가 `destination.replace`에 성공한 뒤 확인용 `fetch`를 하는데, 이 fetch가 실패하면(네트워크 등) 에러를 던져 백업을 실패로 보고한다. 실제로는 새 파일이 이미 올라가 있고, epoch 메타만 안 남았다. 다음 백업에서 다시 쓰기를 시도하므로 데이터 손실은 없지만 사용자에게 오해를 준다.
- **고치는 방법** — 확인용 fetch 실패를 "교체는 됐으나 확인 못 함"으로 구분해 결과에 알리거나, epoch 메타를 남기고 다음 백업에서 검증하게 한다.

#### D33. AI 작업 확인(ack) 목록이 300개로 잘리면 오래된 확인이 사라진다
- **파일:줄** — `Packages/TaptionAssistant/Sources/TaptionAssistantKit/AITaskQueue.swift:120-129`
- **문제** — `acked` 목록이 최신 300개만 유지된다. 확인 목록에서 밀려난 id의 업로드가 큐에 남아 있으면(응답 유실로 남은 경우) 다시 올려 서버가 끝난 일을 되살릴 수 있다. 서버가 id로 중복을 제거한다면 무해하다.
- **고치는 방법** — 서버의 id 중복 제거를 확인하고, 안 된다면 업로드 큐와 확인 목록의 보관 정책을 맞춘다.

#### D34. 공유 세션의 AsyncStream continuation을 끝내는 곳이 없다
- **파일:줄** — `Packages/TaptionTripShare/Sources/TaptionTripShare/ShareRoomSession.swift:15-19`
- **문제** — `events`·`locationEvents`의 continuation을 `finish()`하는 곳이 없다. 세션이 해제된 뒤에도 스트림을 들고 `for await`를 도는 구독자는 영원히 대기한다.
- **고치는 방법** — D6의 `deinit` 수정과 함께 두 continuation을 `finish()`한다.

### 3.3 중복 코드

#### D-01. 금액 표기 로직 중복
- **파일:줄** — `TaptionPlan/UI/MapHomeCalendarPolicies.swift:438` (`moneyText(_:language:)`) vs `TaptionPlan/Core/LedgerCore.swift:275` (`LedgerMoney.text(_:currency:language:)`)
- **문제** — `moneyText`가 `NumberFormatter`(.decimal, 0자리)로 숫자를 만들고 `"\(number)원"`/`"₩\(number)"`로 붙이는데, `LedgerMoney.text`의 KRW 분기와 완전히 같은 로직이다.
- **고치는 방법** — `moneyText`를 삭제하고 `LedgerMoney.text`를 부른다. (`moneyCellText`의 "1.2만"/"12k" 축약은 별개라 둔다.)

#### D-02. 거리 표기 3구현
- **파일:줄** — `TaptionPlan/UI/TripLiveLocationBand.swift:212`, `TaptionPlan/UI/TripImportSheet.swift:813`, 기준: `Packages/TaptionWatchSync/Sources/TaptionWatchSync/AppRegion.swift:63` (`AppRegion.distanceText(meters:compact:)`, 마일 대응·테스트 있음)
- **문제** — 기준이 있는데도 두 곳이 각자 구현한다. `TripLiveLocationBand`는 `%.1fkm`/`Int m` 수동 포맷(마일 미대응), `TripImportSheet`는 `Measurement.formatted`로 km만 낸다.
- **고치는 방법** — 두 곳을 `AppRegion.current.distanceText(meters:)`로 바꾼다. (`MapHomeDayTravelSummary.distanceText`는 이미 위임이라 건드리지 않는다 — C-06 참고.)

#### D-03. 시계 표기 `clock(minute:)` 동일 구현 2곳 + 유사 포맷 5곳
- **파일:줄** — `TaptionPlan/UI/TravelTodayCard.swift:261`, `TaptionPlan/UI/TravelPlanTable.swift:675` (글자 그대로 동일: `String(format: "%02d:%02d", minute / 60 % 24, minute % 60)`), 유사: `TaptionPlan/UI/TravelQuickEntrySheet.swift:58`, `TaptionPlan/UX/DailyCardBubblePrompt.swift:51`, `TaptionPlan/UI/PlanRealityGap.swift:271`, `TaptionPlan/UI/AssistantDataActions.swift:676,803` (`%02d` 전체 93곳)
- **문제** — 같은 시계 포맷이 여러 파일에 흩어져 있다.
- **고치는 방법** — `ClockText.minute(_:)` 같은 공용 헬퍼 하나를 만들고 일곱 곳을 바꾼다.

#### D-04. NumberFormatter를 호출마다 새로 만듦
- **파일:줄** — `TaptionPlan/UI/LedgerSheet.swift:516,610` (`plain(_:locale:)`, `LedgerNumber.parse(_:locale:)`)
- **문제** — 호출마다 `NumberFormatter()`를 만든다. 같은 파일의 `LedgerMoney`(`LedgerCore.swift:265`)는 `whole`·`cents`를 static으로 캐시한다.
- **고치는 방법** — 로케일별 포매터를 static 캐시로 바꾸거나 `LedgerMoney` 옆에 모은다. (PROPOSALS 9-1 DateFormatter 항목과 별개로 NumberFormatter만 해당.)

#### D-05. JSONDecoder/JSONEncoder 137·127곳 인라인 생성
- **파일:줄** — 전체 (`JSONDecoder()` 137곳, `JSONEncoder()` 127곳)
- **문제** — 각자 생성된다. 공유 인스턴스는 `TaptionPlan/Core/BiometricDataProtection.swift:126,133`과 `Packages/TaptionAssistant/Sources/TaptionAssistantKit/AITaskQueue.swift:234,240` 두 곳뿐이다. 날짜 전략 같은 설정이 파일마다 달라질 수 있다.
- **고치는 방법** — 용도별(기본·날짜 포함·스네이크 케이스) 공유 디코더/인코더를 한 곳에 두고 인라인 생성을 바꾼다. 설정이 실제로 다른 곳이 있는지는 먼저 확인한다.

#### D-06. 토큰 파싱 중복 + 죽은 함수
- **파일:줄** — `TaptionPlan/Core/RecordClockEngine.swift:52` (`compactParts(_:)`)
- **문제** — 위 함수(날씨 토큰 `"|"` 6조각 분리·온도 파싱)와 같은 파싱을 하고, 호출처도 없다.
- **고치는 방법** — 삭제한다. (죽은 코드 3.8에도 있음)

#### D-07. 밝기 읽기 반복
- **파일:줄** — `TaptionPlan/TaptionPlanApp.swift:377,389,396,405,418`, `TaptionPlan/Core/AppleSensorCollector+Updates.swift:446`
- **문제** — `Double(UIScreen.main.brightness)`가 6곳에 반복된다.
- **고치는 방법** — 밝기 읽기 헬퍼 하나(`SensorBrightness.now()` 등)로 모은다. `UIScreen.main` 교체(X-01)와 함께 처리한다.

### 3.4 일관성

#### C-01. 달력: `Calendar.current` 8곳 + 기본값 10곳 vs `.gregorian` 57곳
- **파일:줄** — `TaptionPlan/Core/SeasonPackAdapter.swift:29`, `TaptionPlan/UI/FirstRunTutorialGuides.swift:244,246`, `TaptionPlan/UI/FirstRunGuideStage.swift:447`, `TaptionPlan/UI/MapHomeAlarm.swift:595,598`, `TaptionPlan/UI/LocationAlwaysPrompt.swift:21`, `Packages/SeasonPackKit/Sources/SeasonPackKit/SeasonPackCenter.swift:72`; 기본값 `calendar: Calendar = .current` 10곳(`StayContext.swift:47`, `SeasonPackCenter.swift:64`, `SeasonPackWindows.swift:40`, `SeasonPackClock.swift:151`, `SeasonPackMemoStore.swift:23,34,50`, `GoogleCalendarAccount.swift:105`, `MapHomeTimeSidebarMath.swift:450`, `SeasonPackIconRegistry.swift:20`)
- **문제** — 코드베이스는 `Calendar(identifier: .gregorian)`이 표준(57곳)인데 이 8곳만 `Calendar.current`를 쓴다. `Calendar.current`는 사용자의 달력 설정(불교력 등)을 따라 날짜 계산이 달라질 수 있다.
- **고치는 방법** — 날짜 계산용은 `.gregorian` 기본값으로 바꾸고, 사용자 표시용으로 `current`가 필요한 곳만 남긴 뒤 주석으로 구분한다.

#### C-02. 시간대 폴백 불일치: `?? .current` 3곳 vs `?? .gmt`
- **파일:줄** — `TaptionPlan/UI/ArrivalCardView.swift:98`, `TaptionPlan/UI/TripImportSheet.swift:406`, `Packages/TaptionPlanStore/Sources/TaptionPlanStore/TaptionStoreColumnCoding.swift:1061` vs `.gmt` 사용처(`AssistantDataActions.swift:510`, `TripShareCreateSheet.swift:35`, `TripShareMapping.swift:75`, `TravelTrips.swift:132,256`)
- **문제** — `TimeZone(secondsFromGMT:)`가 실패하면 이 3곳은 `.current`로 떨어지는데, 같은 상황의 다른 곳은 `.gmt`로 떨어진다. 오프셋 파싱 실패 시 같은 입력이 다른 시각으로 보인다.
- **고치는 방법** — UTC 폴백으로 통일한다. (`.current`가 의도인 곳은 주석을 남긴다.)

#### C-03. 동명 타입 `SleepSession` 2개
- **파일:줄** — `Packages/TaptionClassifierEngine/Sources/TaptionClassifierEngine/SleepFusion.swift:14` vs `Packages/TaptionPlanStore/Sources/TaptionPlanStore/Snapshot/HealthAndSensorModels.swift:87`
- **문제** — 이름은 같은데 필드가 다르다(분류기: `interval`·`origin`·`score`·`evidence`, 저장소: `id`·`span`·`asleepDuration`·`stageDurations` 등). 앱은 `TaptionPlan/Core/FeatureModels.swift:37`의 `typealias SleepSession = TaptionPlanStore.SleepSession`으로 한쪽을 가려서 쓰고 있다.
- **고치는 방법** — 분류기 쪽을 `ClassifierSleepSession`으로 바꾸거나, 두 타입의 관계를 주석·문서로 고정한다.

#### C-04. 이동 수단 enum 2개 (`TransportMode` vs `TravelMode`)
- **파일:줄** — `Packages/TaptionClassifierEngine/Sources/TaptionClassifierEngine/ClassifierModels.swift:11` vs `Packages/TaptionPlanCore/Sources/TaptionPlanCore/Domain/TravelSegment.swift:3`
- **문제** — `TransportMode`(stationary 포함 10종)와 `TravelMode`(taxi 포함 10종)가 거의 같은데 따로 있고, 변환은 `TaptionPlan/Core/ClassifierAdapter.swift:221` `travelMode(_:)`에서 수동으로 한다(stationary→nil). 케이스를 한쪽에만 추가하면 컴파일은 깨지지만(스위치가 전체를 다룸) 의미가 어긋날 수 있다.
- **고치는 방법** — 하나로 합치거나, 합칠 수 없으면 두 enum 위에 "짝"이라는 주석과 변환 테스트를 둔다.

#### C-05. 분류 경로만 `preconditionFailure`로 크래시 (에러 처리 불일치)
- **파일:줄** — `Packages/TaptionActivityEngine/Sources/TaptionActivityEngine/ActivityClassifier.swift:84,127,220`, `TaptionPlan/Core/TaptionActivityEngineAdapter.swift:199,684,719`, `TaptionPlan/Core/TaptionActivityEngineAdapter+TravelMatching.swift:16`
- **문제** — 분류·정규화·인덱싱에서 취소·실패가 나면 `preconditionFailure`로 앱이 죽는다. 나머지 경로는 throws·Result·nil로 처리한다. "일어나면 안 되는 일"이라는 전제인데, 취소는 백그라운드에서 실제로 일어날 수 있다.
- **고치는 방법** — 의도된 결정이면 각 위치에 근거를 주석으로 남기고, 아니면 호출부로 에러를 올려서 조용히 건너뛰게 바꾼다.

#### C-06. 통과만 하는 위임 함수 (PROPOSALS 9-8 패턴과 동일)
- **파일:줄** — `TaptionPlan/UI/MapHomeSupportViews.swift:286` (`MapHomeDayTravelSummary.distanceText(_:)`)
- **문제** — `AppRegion.current.distanceText(meters:)`를 그대로 부르기만 한다. 9-8에서 같은 이유로 `MapHomeWBSPlaybackProjection.distanceMeters`를 삭제한 전례가 있다.
- **고치는 방법** — 호출부 2곳(`MapHomeView+Support2.swift:323`, `MapHomeView+Menu.swift:364`)을 `AppRegion` 직접 호출로 바꾸고 삭제한다.

### 3.5 하드코딩 — 나머지

#### L-05. 위젯 레인 제목 폴백 하드코딩 (호출처도 없음)
- **파일:줄** — `TaptionPlan/Core/WidgetShared.swift:64`
- **문제** — `TaptionWidgetLane.title`이 `rowKind?.title ?? "액션"`으로 한국어를 그대로 돌려준다. 바로 아래 `localizedTitle`이 번역을 처리하는데, `title` 자체는 호출처가 없다.
- **고치는 방법** — `title`을 삭제하고 `localizedTitle`만 남긴다.

#### L-06. 네트워크 타임아웃 매직 넘버 분산 (5·8·10·12·30초)
- **파일:줄** — `TaptionPlan/UI/MapHomeKakaoSearch.swift:134,150`(5초), `TaptionPlan/Core/BusStopCheck.swift:515`(8초), `TaptionPlan/Core/AnnouncementFeed.swift:233`(8초), `Packages/SeasonPackKit/Sources/SeasonPackKit/Store/SeasonPackFetcher.swift:32,43`(8초), `TaptionPlan/UI/TravelPlacePhotos.swift:304`(12초), `331,344,391,395`(10초), `Packages/TaptionAssistant/Sources/TaptionAssistantKit/TripRelay.swift:97`(10초), `Packages/SeasonPackKit/Sources/SeasonPackKit/Store/SeasonPackBackgroundEngine.swift:30,52`(30초)
- **문제** — 타임아웃이 8곳에 흩어져 있고 같은 8초·10초도 파일마다 따로 적혀 있다. (`SeasonPackFetcher`의 8초는 `StoreAndFetchTests.swift:202`에서 단언됨)
- **고치는 방법** — 용도별 상수(짧은 조회 5초·일반 10초·다운로드 30초 등)를 한 곳에 두고 바꾼다. 테스트가 단언하는 값은 함께 업데이트한다.

### 3.6 Deprecated / 구식 API

#### X-01. `UIScreen.main` 8곳 (iOS 16+ 소프트 deprecated)
- **파일:줄** — `TaptionPlan/TaptionPlanApp.swift:377,389,396,405,418`, `TaptionPlan/Core/AppleSensorCollector+Updates.swift:446`, `TaptionPlan/UI/MapHomePhotoLayer.swift:205`, `TaptionPlan/UI/MapHomeView+Map.swift:25`
- **문제** — `UIScreen.main`은 "'main' will be deprecated in a future version of iOS: Use a UIScreen instance found through context instead"라는 경고를 받는다. 밝기 6곳·스케일 1곳·너비 1곳이다. (배포 타깃 iOS 18.0)
- **고치는 방법** — 뷰 맥락이면 `windowScene.screen`·GeometryReader로 바꾸고, 백그라운드 센서 수집(밝기)처럼 윈도우가 없는 곳은 `UIApplication.shared.connectedScenes`에서 찾되 없으면 nil을 허용하는 헬퍼로 모은다(D-07과 함께).
- 확인 결과 없는 것 (다시 파지 말 것): `NavigationView` 0건, `presentationMode` 0건, `alert(isPresented:)`·`alert(item:)` 0건, `onChange(of:perform:)` 2인자 형태 0건(154곳 모두 iOS 17+ 형태), `NSLocalizedString` 0건, `UIApplication.shared.windows`·`keyWindow` 0건, `TextField` `onCommit` 0건, `NSKeyedArchiver` 구식 API 0건.

### 3.7 접근성 — Dynamic Type

#### A-02. Dynamic Type을 무시하는 고정 글자 크기 114곳
- **파일:줄** — 전체 (`.font(.system(size:` 245곳 중 `TaptionType.scaled`를 안 거치는 곳이 114곳 — 앱 82곳·위젯/워치 30곳·패키지 2곳)
- **문제** — 앱은 `TaptionType.scaled`(1.3배 상한)로 시스템 글자 크기를 반영하는데 이 호출부는 그걸 안 탄다. `TaptionType.snapped`의 11pt 하한도 안 지켜서 `TaptionPlan/UI/TripItemStatus.swift:179`(8pt), `TaptionPlan/UI/TravelPlanTable.swift:617`(10pt), `TaptionPlanWidget/TaptionScheduleWidgetView.swift:199`(8.5pt) 같은 곳이 있다.
- **고치는 방법** — 텍스트는 `.taptionStyle(_:)`·`.taptionFixed(size: TaptionType.scaled(...))`로 바꾸고, 아이콘용(`Image`의 `.font`)은 크기만 남겨도 되는지 따로 정한다. 위젯·워치는 "시스템 글꼴을 그대로 쓴다"는 정책(`TaptionFont.swift` 주석)이 있어 별도 판단이 필요하다. 많은 파일(`TravelPlanTable.swift` 14곳, `MapHomePlaceBookTools.swift` 14곳, `MapHomeView+Menu.swift` 13곳, `FirstRunGuideStage.swift` 11곳 순)이 있어 파일 단위로 나눠서 한다.

### 3.8 테스트 공백 — P1 (그 외)

#### T-16. AI 연결 DI 구조체·결과 타입 미테스트
- **파일:줄** — `Packages/TaptionAssistant/Sources/TaptionAssistantKit/AssistantEnvironment.swift:6`, `AssistantCommandTransport.swift`
- **문제** — `AssistantEnvironment`(생성 지점은 `TaptionPlan/UI/AssistantRegistration.swift:7` 한 곳)와 `AssistantCommandResult`·`AssistantCommandPolling`이 테스트에 안 나온다. `moveRules` 기본값(`{ _, _, _ in true }`)·`saveConnection` 기본값이 고정돼 있지 않다.
- **고치는 방법** — 기본 클로저 동작, 키 교체 시 규칙 이동 성공·실패 테스트 추가.

#### T-17. 시즌 팩 백그라운드 다운로드 완료 콜백 미테스트
- **파일:줄** — `Packages/SeasonPackKit/Sources/SeasonPackKit/Store/SeasonPackBackgroundEngine.swift:30,114`
- **문제** — `SeasonPackBackgroundEngine.handleEvents(forBackgroundURLSession:)`·`urlSessionDidFinishEvents(forBackgroundURLSession:)`가 테스트에 안 나온다. 백그라운드 세션 완료 후 시스템 완료 콜백을 부르는 경로라, 안 불리면 iOS가 앱을 깨운 채로 둔다.
- **고치는 방법** — 가짜 `URLSession`·완료 핸들러로 호출·미호출·두 번 호출 테스트 추가.

#### T-18. 클라우드 복구 정책 미테스트
- **파일:줄** — `TaptionPlan/Core/PlanRepository.swift`
- **문제** — `PlanCloudSnapshotRecoveryPolicy`·`CloudSyncDecision`·`TaptionRepositoryBackgroundExecution`·`PlanRepositorySelection`·`BackgroundTaskAssertion`이 테스트에 안 나온다.
- **고치는 방법** — 복구 정책별(덮기·합치기·버리기) 결정 테스트 추가.

#### T-19. Core Motion 히스토리 서비스 미테스트
- **파일:줄** — `TaptionPlan/Core/AppleMotionHistoryService.swift:7`
- **문제** — `AppleMotionHistoryService`가 테스트에 안 나온다. `SensorDataServices.swift:507`에서 주입받는데, 히스토리 조회 실패·빈 결과 분기가 고정돼 있지 않다.
- **고치는 방법** — `CMMotionActivityManager`를 감싼 프로토콜로 갈아 끼우거나, 조회 결과 매핑만 분리해 테스트한다.

#### T-20. 시즌 팩 어댑터·편집 스테이징 미테스트
- **파일:줄** — `TaptionPlan/Core/SeasonPackAdapter.swift`, `TaptionPlan/UX/ActivitySectionEditStaging.swift`, `TaptionPlan/UX/AppModel+FrequentPlaces.swift`(`FrequentPlaceKindChange`)
- **문제** — `SeasonPackAdapter`·`SeasonCardArt`·`ActivitySectionEditStaging`·`FrequentPlaceKindChange`가 테스트에 안 나온다.
- **고치는 방법** — 어댑터의 마운트·삭제·언어 전달, 편집 스테이징의 저장·버리기, 장소 종류 변경 테스트 추가.

#### T-21. Watch 동기화 저장소 읽기·지우기 미테스트
- **파일:줄** — `Packages/TaptionWatchSync/Sources/TaptionWatchSync/WatchSyncStores.swift`
- **문제** — `WatchActivityConfirmationStore`·`WatchActivityLearningStore`·`WatchLaunchReportStore`의 `read`·`clear`가 테스트에 안 나온다. (`TaptionWatchCommandCapabilityStore`는 `WatchSensorQueryPlanTests.swift:1874`에서 reconcile/consume/clear 테스트됨)
- **고치는 방법** — 저장→읽기→지우기 왕복 테스트 추가.

#### T-22. 하드웨어 의존 서비스 미테스트 (낮음 — 분리 후 테스트)
- **파일:줄** — `TaptionPlan/Core/ApplePhotoLibraryService.swift`(`PhotoServiceError`·`ApplePhotoLibraryService`), `TaptionPlan/Core/CurrentConnectedWiFiService.swift`, `TaptionPlan/Core/WidgetCommandStore.swift`(`TaptionWidgetCommandReceipts`)
- **문제** — 테스트에 안 나온다. 사진·Wi-Fi는 기기 권한이 필요해 시뮬레이터 테스트가 제한된다.
- **고치는 방법** — 권한·조회 부분을 프로토콜 뒤로 분리하고, 순수 매핑(오류 변환·수신 확인)만 테스트한다.

#### T-23. 에러 타입·작은 값 타입 미테스트 (낮음)
- **파일:줄** — `TaptionPlan/Core/BackupPasswordVault.swift`(`BackupPasswordStoreError`), `TaptionPlan/Core/GoogleCalendarAccount.swift`(`GoogleCalendarConfig`·`GoogleCalendarError`), `TaptionPlan/Core/HealthKitImportStore.swift`(`HealthKitImportStoreError`), `TaptionPlan/Core/TemplatesAndSettings.swift`(`CategoryError`·`CategoryDeletionResult`), `TaptionPlan/Core/FlightLookup.swift`(`FlightListResult`), `TaptionPlan/Core/FlightBriefing.swift`(`FlightBriefingScheduler`), `TaptionPlan/Core/PlanGoalEngines.swift`(`GoalActualMatchKind`·`GoalActualMatch`)
- **문제** — 타입만 테스트에 안 나온다.
- **고치는 방법** — 오류를 일으키는 경로 테스트를 넣을 때 함께 단언한다. 단독 테스트는 우선순위 낮음.

#### T-24. 패키지 공개 값 타입·정책 미테스트 (낮음 — 묶음)
- **문제** — 다음 공개 타입이 테스트에 안 나온다. 대부분 값 타입이라 단독 테스트보다 사용하는 쪽 테스트에 단언을 넣는 게 낫다.
  - `TaptionAssistant`: `AppleCloudQuota`·`AppleCloudFailure`·`AppleModelNotice`(`AppleModelRouter.swift`), `AssistantKeyScope`·`AssistantKeyPeriod`(`AssistantKeys.swift`), `AssistantLooseValue`(`AssistantJSON.swift`), `AssistantOperationReading`·`AssistantParsedOperation`(`AssistantOperationReading.swift`), `AssistantCatalogLimits`(`AssistantOperations+Catalog.swift`), `AssistantApproval`(`AssistantQuestion.swift`), `AssistantCoordinate`·`AssistantPlanTarget`·`AssistantSchedulePlace`·`AssistantScheduleExtras`·`AssistantScheduleTime`·`AssistantWhenChange`(`AssistantCommandValues.swift`)
  - `TaptionActivityEngine`: `ActivityEngineConfiguration`(`ActivityClassifier.swift`), `ActivityGapInferenceInput`·`ActivityGapInferenceSegment`·`ActivityGapInferenceConfiguration`(`ActivityGapInference.swift`), `ActivitySensorSource`(`ActivityModels.swift`), `ActivityDetailDefinition`·`ActivityMajorDefinition`(`ActivityTaxonomy.swift`), `ActivityDataTier`·`ActivityInferenceStatus`·`ActivityDataProvenance`·`ActivityAutomaticConfirmation`(`DataTrustModels.swift`), `ActivityPlaceKind`·`ActivityPlaceEvidence`(`PlaceActivityInference.swift`), `SleepInferenceState`·`SleepInferenceResult`(`SleepInference.swift`)
  - `TaptionClassifierEngine`: `ClassifierPipeline`·`IdleThresholds`(`ClassifierModels.swift` — T-02와 함께), `StayContextResult`·`RegisteredPlaceKind`(`StayContext.swift`), `ClassifiedStay`·`ClassifierRecord`·`ClassifierDayOutput`(`TaptionClassifier.swift`), `ClassifierConfidence`(`TravelSegmenter.swift`), `WindowFeatures`(`WindowFeatures.swift`)
  - `TaptionPlanCore`: `TaptionPlanNLEInputDecision`(`CoreEngineContracts.swift`), `TaptionPlanRawEventIdentifier`·`TaptionPlanRawEventPage`(`DayStoreV3Models.swift`), `TaptionInputFrameGate`·`TaptionTrailingInputScheduler`(`RuntimeEfficiency.swift`), `WatchHealthSnapshotRetryPolicy`(`WatchHealthSnapshotRetryPolicy.swift`), `TaptionPlanExternalCalendarProvider`·`TaptionPlanExternalCalendarPreferences`·`TaptionPlanMediaReferenceSource`·`TaptionPlanContentNode`·`TaptionPlanContentLink`·`TaptionPlanUserContent`(`StorageContracts.swift`)
  - `TaptionPlanStore`: `TaptionRawEvent`(`TaptionRawEvent.swift`), `PlanActualEdit`·`PlanActualStorage`(`PlanActualStorage.swift`), `PlanDataRepository`(`PlanDataRepository.swift` — SQLite 구현은 `SQLitePlanRepositoryTests`에서 테스트됨)
  - `TaptionRouteEngine`: `RouteGapInferenceInput`·`RouteGapInferenceDecision`·`RouteGapInferenceConfiguration`(`RouteGapInference.swift`), `RouteLoggerRouteFilterConfiguration`·`RouteSampleDecisionReason`·`RouteSampleDecision`(`RouteLoggerRouteFilter.swift`), `FareTrip`(`FareCalculator.swift`), `FareAgeBand`(`FareTable.swift`), `FlightLayover`(`FlightItinerary.swift`), `FlightArrival`(`FlightTimeMath.swift`), `MissingRouteEvidence`(`RouteEvidence.swift`), `TravelLossyMap`(`TravelBundledData.swift`)
  - `TaptionTripShare`: `ShareContentVersion`·`ShareOwnExpenseVisibility`(`ShareContent.swift`), `ShareReadOnlyReason`(`ShareError.swift`), `ShareReceivedLocation`(`ShareLocation.swift`), `ShareSessionStatus`·`ShareEndReason`·`ShareLocalItem`·`ShareLockState`·`ShareUnreadableItem`·`ShareEditOutcome`·`ShareEditConflict`·`ShareSnapshotStore`(`ShareSessionTypes.swift`), `ShareMemberEvent`·`ShareSocketResponse`·`ShareSocketEvent`(`ShareSocketMessages.swift`), `ShareHTTPRequest`·`ShareHTTPResponse`·`ShareSocketClosed`(`ShareTransport.swift`), `ShareWriteReceipt`·`ShareGroupChange`(`ShareWire.swift`)
  - `TaptionWatchSync`: `WatchAmbientChunkVerdict`(`WatchAmbientChunkInterpreter.swift`), `TaptionWatchActivityConfirmation`·`WatchActivityPattern`·`WatchActivityPatternSample`·`TaptionWatchActivitySuggestion`(`WatchBehaviorRules.swift`), `TaptionWatchMeasurementSource`·`TaptionWatchMeasurementSnapshot`·`TaptionWatchAlertKind`·`TaptionWatchAlert`·`TaptionWatchWidgetRefreshPolicy`·`TaptionWatchHealthSnapshot`·`TaptionWatchSleepSegment`·`TaptionWatchSleepDuration`·`TaptionWatchLocationPoint`(`WatchSyncMeasurements.swift`), `TaptionWatchWorkoutStartGate`·`TaptionWatchWorkoutFinishState`·`TaptionWatchWorkoutPurgeIntentStore`·`TaptionWatchWorkoutPurgeReconciliation`·`TaptionWatchPurgeSequence`·`TaptionWatchAmbientQueueAdoption`·`TaptionWatchAmbientOutboxFlushPolicy`·`TaptionWatchAmbientOutboxReadFailurePolicy`·`TaptionWatchAmbientSampleDeduplicationPolicy`·`TaptionWatchDurableSpoolPolicy`·`TaptionWatchDurableSpoolCodec`·`TaptionWatchWorkoutLifecycleBarrier`·`TaptionWatchAccelerationArchiveAppendIndex`·`TaptionWatchAmbientRevisionError`·`TaptionWatchPurgeGenerationPolicy`(`WatchSyncOutbox.swift`)
  - `SeasonPackKit`: `SeasonPackValidationResult`(`SeasonPackValidation.swift`), `SeasonPackAnchor`(`SeasonPackHost.swift`), `SeasonPackOverlay`(`SeasonPackOverlay.swift`), `SeasonPackDownloadResult`(`SeasonPackDownloader.swift`), `SeasonPackRefreshResult`(`SeasonPackFetcher.swift`), `SeasonPackLoader`·`SeasonPackInstallRecord`(`SeasonPackStore.swift`), `SeasonPackDefaultsClockStorage`(`SeasonPackClock.swift` — 시계 본체는 테스트됨)
- **고치는 방법** — 각 타입을 쓰는 쪽의 기존 테스트에 단언을 추가한다. 뷰 타입(`SeasonPackMenuView`·`SeasonPackHouseView` 등)은 단위 테스트 대상이 아니므로 제외.

### 3.9 죽은 코드 (저장소 전체 Swift에서 정의 1회만 확인 — 삭제 전 빌드로 확인)

전부 internal/public이라 삭제하면 컴파일이 검증한다.

#### 패키지 (5건)
- `Packages/SeasonPackKit/Sources/SeasonPackKit/Store/SeasonPackStore.swift:184` — `SeasonPackStore.totalBytes()` — 공개 함수인데 호출처가 없다. 삭제하거나, 설정 화면의 용량 표시에 연결한다.
- `Packages/TaptionActivityEngine/Sources/TaptionActivityEngine/ActivityClassifier.swift:206` — `reclassifyTail(existing:appendedEvidence:overrides:)` — `append`를 그대로 부르는 통과 함수이고 호출처가 없다. 삭제한다.
- `Packages/TaptionPlanStore/Sources/TaptionPlanStore/Snapshot/MovementModels.swift:237` — `TravelSegmentGroup` — 공개 구조체인데 참조가 없다. 삭제한다.
- `Packages/TaptionPlanStore/Sources/TaptionPlanStore/Snapshot/TimelineModels.swift:141` — `TimelineViewport` — 공개 구조체인데 참조가 없다. 삭제한다.
- `Packages/TaptionTripShare/Sources/TaptionTripShare/ShareRoomSession+Editing.swift:145` — `extendLocks()` — 공개 함수인데 호출처가 없다. 주석에 "평소에는 60초마다 스스로 한다"고 적혀 있어 수동 연장이 필요 없을 수 있다. 자동 연장만으로 충분하면 삭제하고, 수동 새로고침 UI가 필요하면 연결한다.

#### 앱 Core (8건)
- `TaptionPlan/Core/AppleHealthService.swift:29` — `HealthBackgroundRefreshCoordinator.receiveUpdate()` — HealthKit 백그라운드 갱신을 받는 진입점인데 호출처가 없다. `register`는 `AppModel.swift:745`에서 불리고, 실제 백그라운드 갱신은 `TaptionPlanBackgroundRefresh`(`TaptionPlanApp.swift:307`)로 가는 것으로 보인다. 백그라운드 갱신 경로를 확인하고, 안 쓰면 삭제한다.
- `TaptionPlan/Core/CarAudioTravelConfirmation.swift:161` — `matchedName(in:)` — 호출처가 없다. 삭제한다.
- `TaptionPlan/Core/DayPhaseEngine.swift:283` — `completePhasesAcrossDays(actuals:travel:stays:placeKinds:in:calendar:asOf:)` — 호출처가 없다. 삭제한다.
- `TaptionPlan/Core/LedgerCapture.swift:291` — `inlineMerchant(_:)` — 한 줄 알림 가게 찾기인데 호출처가 없다. 삭제하거나, 결제 문자 파싱에서 실제로 쓰는 경로가 있으면 연결한다.
- `TaptionPlan/Core/LocationPrivacyAndTravelDistance.swift:11` — `widgetSafe(places:travel:)` — 호출처가 없다. 삭제한다.
- `TaptionPlan/Core/RecordClockEngine.swift:52` — `compactParts(_:)` — 호출처가 없고 위 함수와 같은 파싱을 한다(D-06). 삭제한다.
- `TaptionPlan/Core/SubwayCatalog.swift:1070` — `bestRoute(_:)` — 호출처가 없다. 삭제한다.
- `TaptionPlan/Core/SubwayTravelSegmentEngine.swift:140` — `mergingRestoredTravel(existing:readings:userTransitLocations:)` — 클라우드 복원 뒤 지하철 구간을 다시 만드는 함수인데 호출처가 없다. 복원 경로에서 빠져 있으면 복원 뒤 지하철 구간이 안 살아난다. 복원 흐름에 연결하거나 삭제한다.

#### 앱 UX — AppModel 확장 (40건, 파일별 묶음)
- `TaptionPlan/UX/AppModel+ActualEditing.swift:112` — `correctActualFragment(_:displayedSpan:startAt:endAt:with:)` — 삭제한다.
- `TaptionPlan/UX/AppModel+Backup.swift:243` — `validateBiometricProtectedData()` — T-08 참고. 보안 기능이라 삭제보다 연결을 먼저 검토한다.
- `TaptionPlan/UX/AppModel+FrequentPlaces.swift:5,254,359,803,833` — `confirmPlace(_:)`·`calibrateFrequentPlaceFloor(_:)`·`deleteFrequentPlaceFloorReference(_:)`·`confirmFloorTransition(_:)`·`photoThumbnailData(_:)` — 삭제한다. 층 교정 UI가 이 함수들을 쓸 계획이면 연결한다.
- `TaptionPlan/UX/AppModel+LocationCollection.swift:219,238,334` — `setGPSLoggingPreset(_:)`·`setGPSLoggingIntervalMinutes(_:)`·`startTracking()` — GPS 기록 시작·설정 함수인데 호출처가 없다. 수집 시작이 다른 경로로 가는지 확인이 필요하다. 수집 시작 경로를 확인하고, 안 쓰면 삭제한다.
- `TaptionPlan/UX/AppModel+Memos.swift:12,19,448,508` — `closeMemoEntry(_:)`·`moveMemoEntry(_:)`·`toggleVoiceMemo(_:)`·`toggleVoicePlayback(_:)` — 삭제한다.
- `TaptionPlan/UX/AppModel+Navigation.swift:5,26,41,49,54,66,96,124` — `selectTab(_:)`·`openGroup(_:)`·`openGoalDetail(_:)`·`closeGoalDetail()`·`closeCurrentGroup()`·`selectScale(_:)`·`shiftReviewDate(by:)`·`returnToNow()` — 내비게이션 헬퍼 8개가 전부 호출처가 없다. 내비게이션이 `NavigationModels` 상태 직접 조작으로 바뀐 것으로 보인다. (직접 대조 확인함 — 파일 밖 호출처 0건) 삭제한다.
- `TaptionPlan/UX/AppModel+Permissions.swift:305` — `requestAppUsageAuthorization()` — 삭제한다.
- `TaptionPlan/UX/AppModel+Plans.swift:204,343,413,741,1009` — `connectActionItem(_:)`·`connectRecordNode(_:)`·`updateRoutineActualInterval(_:)`·`addPlanToCalendar(_:)`·`setTimelineRowOrder(_:)` — 삭제한다.
- `TaptionPlan/UX/AppModel+Settings.swift:12,19,56,64,70,118` — `setStartScale(_:)`·`setRememberLastScale(_:)`·`toggleSetupCategory(_:)`·`cancelInitialCategorySelection()`·`applyInitialCategorySelection()`·`setMapDisplayProvider(_:)` — 삭제한다.
- `TaptionPlan/UX/AppModel+WatchHealth.swift:168` — `clearWatchLaunchReport()` — 삭제한다.
- `TaptionPlan/UX/AppModel+WidgetLiveActivity.swift:72,78,261` — `setWidgetPhotosVisible(_:)`·`refreshWidgetNow()`·`pausePlan(_:)` — 삭제한다.
- `TaptionPlan/UX/AppModel.swift:892` — `refreshBiometricDataProtectionStatus()` — 생체 보호 상태를 새로고침하는 함수인데 호출처가 없다. T-08과 함께 본다. 상태 표시 경로에 연결하거나 삭제한다.

#### 앱 UI (4건)
- `TaptionPlan/UI/MapHomeLaunchPrompts.swift:260` — `MapHomeTodoButton` — 정의만 있고 호출처 0곳. 타입째 지우고 Debug 빌드로 확인한다. (HOME_UX_REVIEW.md "따로 확인할 것"에서도 지적됨)
- `TaptionPlan/UI/MapHomeView+Support2.swift:542` — `MapHomeView`의 `header` 뷰 — 호출처 없음. 지우고 Debug 빌드로 확인한다. (HOME_UX_REVIEW.md에서도 지적됨)
- `TaptionPlan/UI/MapHomeView.swift:162-163, 677` — 홈 배치 설정이 저장만 되고 읽히지 않음. `@AppStorage`로 `layoutStyleRaw`를 저장(기본값 `.classic`)하지만 `layoutStyle`은 `.tabBar`로 고정. `TaptionPlanTests/MapHomeLiveMapTests.swift:1161-1164`의 시험은 여전히 "기본은 classic"을 확인해 코드와 시험이 어긋난다. (가) 시험 옵션을 다시 넣을 계획이 없으면 AppStorage 저장 줄과 classic 관련 시험 기대값을 정리한다. (나) 나중에 되살릴 거면 주석으로 "지금은 tabBar 고정, 설정값 미사용"을 명시하고 시험 기대값을 실제 동작에 맞춘다. HOME_UX_REVIEW.md는 "시험 옵션을 다시 넣을 때 되살려 쓸 수 있다"고 적어 두었으므로, 지우기 전에 대표 확인이 필요할 수 있다.
- `TaptionPlan/UI/MapHomeView+Map.swift:1127-1138` — `mapControls`가 `Color.clear`를 돌려주면서 `.taptionShadow(.floating)`을 붙임. 투명한 뷰의 그림자는 화면에 아무것도 그리지 않는다. 그림자 수식어를 뺀다. (이 함수는 `MapHomeView+Timeline.swift:173`에서 간격용으로 쓰이고 있으니 함수 자체는 지우지 않는다.)

#### 서버 (1건)
- `server/trip-relay/src/store.js:153` — `TASK_CLAIM_MS` — 어디에서도 쓰이지 않는 죽은 export. 실제 값은 `LIMITS.taskClaimMs`가 들고 있다. 지운다. (S22와 함께)

#### 제외한 오탐 (죽은 코드가 아님)
- `SeasonPackBackgroundEngine.urlSessionDidFinishEvents` — `URLSessionDelegate` 메서드라 시스템이 부른다.
- `AddFlightAlertIntent`·`AddSharedTextIntent`·`AddPaymentNotificationIntent` — `AppIntent`는 시스템이 자동 발견한다. `AppShortcutsProvider` 등록이 없어도 단축어에서 쓸 수 있다.
- `MapHomeBenchHomeZoom` 2정의 — `#if DEBUG || BENCH` / `#else`로 나뉜 의도된 정의다.
- `TaptionWidgetLane.title` — 호출처는 없지만 L-05에서 다룬다.
- `ShareFakeTransport` — 테스트 지원 타깃(`TaptionTripShareTesting`)이며 7개 테스트 파일이 import한다.

### 3.10 방어적 코딩 (낮음)

#### `AITaskProducer`의 force unwrap — 안전하나 전제가 안 적혀 있음
- **파일:줄** — `TaptionPlan/UX/AITaskProducer.swift:69-87` (`trip.first!`, `trip.last!`, `run.first!`, `run[0]`)
- **확인** — `transitTrips`(`:112-135`)는 빈 배열을 절대 안 넣고, `fragmentRuns`(`:137-152`)는 2개 이상인 묶음만 넣으므로 지금은 안전하다. 다만 이 전제가 코드 어디에도 안 적혀 있어 나중에 건드리면 크래시가 날 수 있다.
- **고치는 방법** — `transitTrips`·`fragmentRuns`에 "빈 배열을 돌려주지 않는다"는 주석을 달거나, 호출부에서 `guard let first = trip.first`로 바꾼다.

#### `StickerArtEngine`의 `as! CTFont`
- **파일:줄** — `TaptionPlan/UI/StickerArtEngine.swift:292`
- **확인** — 글자 런의 글꼴 속성은 실제로 항상 CTFont라 지금은 안전하다.
- **고치는 방법** — `as?` + `continue`로 바꿔 혹시 모를 경우에도 크래시가 안 나게 한다.

#### 반복 생성되는 `ISO8601DateFormatter` (자잘함)
- **파일:줄** — `TaptionPlan/Core/FlightLookup.swift:95` (`parseISO` 호출마다 생성), `TaptionPlan/Core/DiagnosticsLogSupport.swift:590, 745`, `TaptionPlan/Core/ShareTextRouter.swift:16`
- **문제** — 동작은 맞지만 호출마다 포매터를 새로 만든다.
- **고치는 방법** — 정적 공유 포매터로 바꾼다. (`GoogleCalendarAccount.swift:445`의 `rfc3339`처럼 이미 정적으로 둔 곳이 있으니 같은 방식을 따른다.)

### 3.11 운영 콘솔 강화 (낮음)

#### 팩 id·버전 형식 검증 없음
- **파일:줄** — `tools/admin-console/server.mjs:296, 308` (`buildId`와 `.bpack` 파일 이름에 `pack.id`·`pack.version`을 그대로 씀)
- **확인** — `pack`은 로컬 seed 매니페스트에서 오고, 경로는 `execFile`(셸 없음)로 실행돼 셸 주입은 없다. 다만 매니페스트의 id에 `../` 같은 값이 있으면 `BUILD_ROOT` 밖으로 파일을 쓸 수 있다.
- **고치는 방법** — `localPacks()`에서 id·버전을 `^[A-Za-z0-9._-]+$` 같은 형식으로 검증하고, 맞지 않으면 목록에서 빼고 오류를 표시한다. 로컬 전용 도구라 우선순위는 낮다.

---

## 4. 이미 알려진 항목 — 확인됨 (다시 제안하지 않음)

- **REFACTOR_TOP20** (`docs/REFACTOR_TOP20.md`): 13개 완료 + RFT1116A02 4개 완료. 남은 것은 `MapHomeTimeSidebar.swift`, `AppShellView.swift` 2개뿐이고 둘 다 "성능 작업 뒤"로 문서에 적혀 있다.
- **PROPOSALS 9절**: 9-1 DateFormatter 중복은 2단계에서 일부 완료(`AssistantActivityBuilder.Stamp.instantParser`로 통합, 두 곳 사본 제거). 9-2 UserDefaults 키는 `playbackVideoMusic` 4곳 상수화 완료. 9-5 긴 함수는 `performSensorTimelineRefresh`(534줄)가 RFT1116A03으로 나뉘었고, `TravelModeClassifier.classify`(839줄)·`receiveEnvelope`(254줄)는 시험을 먼저 늘린 뒤로 문서에 남아 있다. 9-6 번호 붙은 확장 파일(`MapHomeView+Support2.swift` 등)은 여전히 존재한다. 9-4 거리 함수 사본, 9-8 통과만 하는 함수(`distanceMeters` 삭제 완료)는 이번 검토에서 제외했다.
- **실기기 UI 시험 건너뜀**: AGENTS.md 4절 대표 결정(2026-11-18) "「Timed out while enabling automation mode」로 막혀 건너뛰고 시뮬레이터 결과로 남김".
- **CI `DayStoreV3Tests.testConcurrentColdOpensInitializeOneV3Schema` "database is locked" 간헐 실패**: 테스트는 `Packages/TaptionPlanCore/Tests/TaptionPlanCoreTests/DayStoreV3Tests.swift:53`. 코드상 경로: 두 연결이 동시에 빈 DB를 열면 한쪽이 `BEGIN IMMEDIATE`에서 5초 `busy_timeout`을 넘겨 실패할 수 있다(`DayStoreV3+Schema.swift:7, 74`). 기존 스키마 경로의 `CREATE INDEX/TABLE IF NOT EXISTS`(:25-72행)도 트랜잭션 밖에서 실행돼 같은 락 경합에 노출된다.
- **AIR1114A01 (서버 동시 완료 덮어쓰기)**: 직접 덮어쓰기는 막혀 있다 — `src/state.js:227-235 taskFinish`가 DO 안에서 직렬로 돌며, 끝난 일은 `already_finished`(232행), 남이 맡은 일은 `not_claimer`(233행)로 거절한다. `taskClaim`(`state.js:211`)도 DO 직렬화 안에서만 맡는다. 잔여: `taskFinish`의 맡은이 검사는 `processing` 상태일 때만 한다(233행). `waiting`·`asked` 상태의 일은 맡지 않고도 어떤 연결이든 끝낼 수 있어, 두 AI가 같은 일을 보고 결과를 내면 나중 것이 409로 버려진다(선착순, 병합 없음).
- **P13 (옛 KV 일 코드·옛 별칭·옛 키 제거)**: `LEGACY_PLAINTEXT_UNTIL`(`src/crypto.js`)이 2026-11-15로 이미 지났고 평문 경로는 죽은 코드가 됐지만, P13 범위라 제안하지 않는다.
- **PROPOSALS 8절 가계부 파싱 11가지 빈틈 — 코드 대조 결과**: 수정됨 7개(1 가게 이름 카드사 접두, 2 카드 이름 오인식, 3 승인거절 지출 처리, 4 결제대금 이중 계산, 5 시각·금액 오인식, 6 한 줄 알림 가게 이름, 11 붙여넣기·영수증 AI 전송 — `looksLikePayment`가 `SiriIntents.swift:119`, `LedgerSheet.swift:183`, `AITaskProducer.swift:215`에 연결됨). 부분 1개(7 외화는 수정됨, 날짜 없는 시각·"11월10일"은 여전히 미지원). 확인됨 3개(8 급여·환급 입금 버려짐, 9 취소가 수입으로 들어가고 원결제 미연결, 10 중복 판정이 문자·알림끼리만).
- **TravelModeView.swift actor 격리 CI 실패**: 대표 지시로 건드리지 않음.
- **S17 서울 버스 평문 HTTP**: AGENTS.md 4절 대표 결정이라 기록만 한다(2.1 참고).

---

## 5. 확인했지만 문제없던 것 (다시 파지 말 것)

### 앱
- `MapHomePhotoLayer.swift:446`의 `as! AVPlayerLayer`: `layerClass`를 `AVPlayerLayer`로 재정의해둬(`:445`) 안전.
- `ActivityClassificationLockEngine.swift`·`LedgerCapture.swift`·`ShareScheduleParser.swift`의 `bestMatch!`·`best!`·`found!`: 같은 식에서 nil 검사를 먼저 해 단락 평가로 안전.
- `OfflineVectorTileCache.swift:131`의 `as! NSMutableURLRequest`: `mutableCopy()`는 항상 `NSMutableURLRequest`를 돌려줘 안전.
- `fatalError` 2곳: `init(coder:)` 미지원용 관용구라 문제 없음. `try!`은 테스트 밖 코드에 없음.
- `DateFormatter` 고정 형식 사용처: `en_US_POSIX` 로케일을 제대로 지정하고 있음.
- `MapHomeTimeSidebar` 접근성 이름 한국어 고정(HOME_UX_REVIEW 지적): 이미 `AppLanguagePreference.text`로 고쳐짐.
- `MapHomeSupportViews.swift:385`의 `Text("지도 호스트 ...")`: DEBUG 전용 미리보기(`-pinPreview`)라 사용자 노출 없음.
- `TaptionPlan/AppSecrets.xcconfig`: 비밀값은 로컬 파일(`AppSecrets.local.xcconfig`, gitignore)에만 두고 커밋 파일에는 없음.
- `tools/admin-console/server.mjs`: 127.0.0.1 전용, Host 검사, 일회용 토큰(`timingSafeEqual`), CORS 미응답, 정적 파일은 고정 목록 조회, `execFile` 셸 없음 — 보안 설계가 잘 돼 있음. `/api/config`의 예외는 설정 검증만 빼는 것이고 토큰 검사는 모든 라우트에 적용됨.
- `print()` 디버그 출력은 전부 DEBUG/BENCH 게이트 안에 있음. logger `privacy:.public` 보간은 개수·오류 설명만 있고 좌표·건강 원본 값 없음. Watch 코드에 force unwrap 없음.
- **가계부 정산**: `LedgerSettlement.transfers`·`LedgerFX.krwPerUnit`·`LedgerSplit.even`·`greedy`·`zeroSumGroups`는 `LedgerTests.swift`에서 충분히 테스트됨(나머지 분배, 결정성 20회 반복 포함).
- **백업 V2**: `TaptionBackupV2Tests.swift`에 틀린 비밀번호·변조 파일·부분 실패·덮어쓰기 규칙·코덱 3종(`none`·`lzfse`·`zlib`) 테스트가 있다. `TaptionBackupCodec`·`TaptionBackupDestination`·`TaptionRestoreStaging`·`TaptionStoreV2Error` 모두 테스트됨.
- **공유 암호화**: `ShareCryptoTests`에 잘못된 키·버전·컨텍스트(방·항목·종류·에포크) 테스트가 있다.
- **키체인**: `AssistantKeychainSecrets` 읽기·쓰기 왕복과 범위 키 저장·삭제가 `AssistantRelayTests.swift:360`에서 테스트됨. `AssistantRelayGate`도 `AssistantReviewFixTests.swift:158`에서 테스트됨.
- **항공 알림 병합**: `FlightMergeOutcome`은 `FlightAlertMergeTests`에서 `outcomes` 단언으로 전 케이스 테스트됨.
- **시즌 팩 시계**: `SeasonPackClock`의 서버 앵커·기기 점프·하이워터·48시간 오프라인·첫 실행이 `WindowsAndClockTests`에서 테스트됨.
- **그 외 테스트 확인됨**: `TaptionRobustScalarFilter`(3건), `TaptionWatchAmbientRevisionPolicy`·`TaptionWatchAmbientOutboxRetryPolicy`, `FloorHeightEstimator`, `MotionKindResolver`, `SleepTravelReconciliationEngine`, `ActivityCorrectionEngine`, `RecordAnalysisCategoryNormalizer`, `TaptionWatchAlertPolicy`, `TaptionWatchCommandCapabilityStore`(reconcile/consume/clear), `LedgerTripMath.sheet`, `LedgerBudget.id`·디코딩 실패.
- `DayStoreV3` actor의 `nonisolated(unsafe) var database`: 비격리 접근은 `deinit`의 `sqlite3_close`뿐이고, 진행 중 메서드가 `self`를 강하게 잡으므로 경합이 없다.
- `DayStoreV3.appendRawEvents`·`finishRestoreSession`의 루프 안 `defer { sqlite3_finalize }`: `defer`는 반복마다 실행되므로 문이 쌓이지 않는다.
- `TaptionBackupFileReader.decode`의 트레일러·해시 검증: 줄을 핸들러에 넘기기 전에 검증하지 않는다는 점이 주석으로 명시돼 있고, 엔진은 준비 저장소에 모았다가 커밋하므로 설계상 맞다.
- `TaptionRestoreStaging.commit`의 메모 2단계 커밋: "메모 남음" 표시와 `recover`의 멱등 재시도가 설계돼 있다(D3의 meta 읽기 실패 경로만 예외).
- `ShareCipher.open`의 슬라이스: `raw.count >= overheadBytes` 검사가 있어 범위를 벗어나지 않는다.
- `ShareItemContext.aad`의 `|` 구분자: roomID·itemID는 URL-safe base64url, kind는 고정 enum raw 값이라 `|`가 들어갈 수 없어 모호성이 없다.
- `ShareInvite.make()`의 `!`: `roomID()`는 22자 base64url, `linkSecret()`은 32바이트를 항상 만들므로 안전하다.
- `TaptionDataFileLock.acquire`의 무한 대기: 호출처가 모두 `try await` 컨텍스트이고 루프 안에서 `Task.checkCancellation()`을 하므로 취소가 먹힌다.
- `TaptionBackupCodec.compress`·`deriveKey`의 `baseAddress!`: 호출 전에 비어 있지 않음을 검사한다.
- 줄 수: `scripts/architecture-metrics.py` 기준 236,050줄(783개 파일). `docs/architecture-baseline.json`의 250,477줄은 다른 기준(테스트 포함)으로 보이며, 현재 `--check` 기준으로는 상한 위반이 아님.
- Deprecated 없음: `NavigationView`·`presentationMode`·구 alert·구 `onChange` 2인자·`NSLocalizedString`·`UIApplication.shared.windows`·`keyWindow`·`TextField` `onCommit`·구식 `NSKeyedArchiver` 모두 0건.

### 서버
- 카카오 길찾기 `summary=false`(`src/directions.js`): 공식 문서에 `summary: false`는 "요약 정보와 상세 정보 반환(기본값)"으로 확인됨. 정상.
- IP DO 알람의 카운터 삭제(`src/state.js` `countDaily`·`alarm`): `expire: true`인 카운터 쓰기마다 알람이 다음 날 00:01로 다시 설정돼, 새벽 0시~1분 사이 쓰기가 지워지는 일은 사실상 없다.
- OAuth refresh 회전·재시도(`src/oauth.js`·`src/state.js` `useRefresh`·`commitRefresh`): nonce 고정 + `refreshHash === next`면 성공 처리로 동시 새로고침·재시도가 같은 토큰으로 수렴한다. 커밋 실패 뒤에도 옛 토큰으로 다시 시도하면 스스로 복구된다.
- PIN 초기화·폐기 뒤 남은 access wrap: wrap이 KV에 남아도 DO의 `admit`이 `key:<entry>` 폐기 표시를 보고 401로 막는다. 이중 방어 확인됨.
- CORS(`src/index.js:517-518`): `*`는 `/mcp`·`/oauth/register`·`/oauth/token`·공개 메타데이터에만 열려 있고, 쿠키 인증이 없어 `*`가 세션 탈취로 이어지지 않는다. 키는 Authorization 헤더로만 오간다.
- 키·토큰 로그 노출: `src/`에 `console.*`이 없고, `wrangler.toml`에서 Workers Logs를 끄기로 돼 있다. 오류 응답에 키·좌표가 섞이지 않게 상류 원문을 버리는 곳(`directions`·`flights`·`expressway`·`relayBus`)도 확인됨.
- 공유 방 속도 제한(`src/share.js`): `rate()`·`locRates`가 메모리 기반이라 DO가 잠들면 0부터 시작하지만, 코드 주석에 명시돼 있고 잠들려면 비활성 기간이 필요해 지속 남용에는 악용하기 어렵다.
- D1 어댑터(`src/d1kv.js`): 이중 읽기·지연 이관·삭제 표식·`INSERT OR IGNORE` 경합 처리·list 키셋 페이지네이션이 일관되게 짜여 있다.
- 잘 돼 있는 테스트: OAuth 전체 흐름(등록·승인·PKCE·회전·병렬 새로고침·재사용 시 폐기)은 `test/phase3.test.mjs:266-377`과 `test/rev06.test.mjs`에서, PIN 잠금은 `test/phase3.test.mjs:120`에서, 변조된 암호문 삭제는 `test/index.test.mjs:266`에서, 환율 stale 폴백은 `test/polish.test.mjs:155-169`에서 확인한다.

---

## 6. 큰 기능 제안 (뒤로 미룸)

이번 검토는 대표의 방향("손봐야 할 곳·보완할 문제 찾기")에 따라 디테일한 수정 대상에 집중했고, 큰 기능 아이디어는 별도로 제안하지 않았다. 참고로 이미 문서에 남아 있는 큰 방향은 `docs/AI_RELAY_PLAN.md`(P13 정리), `docs/NEXT_PLAN.md`, `docs/PROPOSALS.md`에 있고, 대표의 핵심 방향(음성 대화 → 일정 실시간 반영, 중계 서버 WebSocket 확장)은 별도 논의 사항이다.

---

## 부록 — 분야별 원본 보고서

- [server.md](server.md) — 서버 24건(S1–S24) + 테스트 공백 9건, 전수 근거
- [data.md](data.md) — 데이터·동시성·백업 34건(D1–D34), PROPOSALS 8절 대조표 포함
- [quality.md](quality.md) — 테스트 공백·중복·일관성·하드코딩·접근성·죽은 코드 전수
- [my-findings.md](my-findings.md) — CI·조용한 실패·죽은 코드 등 직접 확인 항목 초안
