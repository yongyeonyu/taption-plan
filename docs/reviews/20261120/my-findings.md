# 코드 검토 — 내 직접 확인 항목 (초안)

검토 기준: `main` `e6a4445` (2026-11-20, `git pull` 뒤). Claude Code가 바로 수정할 수 있게 파일·위치·문제·고치는 방법을 적었다. 아래는 내가 직접 코드로 확인한 것만 모은 것이고, 최종 `review.md`에는 세 분야(서버·데이터·품질) 병렬 검토 결과와 합쳐 정리한다.

## 1. CI가 테스트를 안 돌리는 곳 (높음)

### 1-1. CI packages job이 11개 패키지 중 4개만 테스트
- 위치: `.github/workflows/ci.yml` packages job — `for package in TaptionPlanCore TaptionRouteEngine TaptionActivityEngine TaptionPlanEngine`
- 문제: `TaptionAssistant`(테스트 8개 파일), `TaptionClassifierEngine`(3개), `TaptionPlanStore`(13개), `TaptionTripShare`(7개), `TaptionWatchSync`(7개), `SeasonPackKit`(8개)의 테스트가 CI에서 전혀 돌지 않는다. 회귀가 CI를 통과해 main에 들어갈 수 있다.
- 고치기: 루프에 6개 패키지를 추가한다. `TaptionLedgerCore`는 테스트 파일이 0개라(값 타입 2개 파일만) 일단 목록에서 빼고, 별도 항목(아래 5-1)으로 테스트를 더한 뒤 추가한다.

### 1-2. CI relay job이 trip-relay를 테스트하지 않음
- 위치: `.github/workflows/ci.yml` relay job — `npm test`를 `server/airkorea-proxy`에서만 실행
- 문제: 주 중계 서버 `server/trip-relay`(`package.json`의 `test`: `node --test test/*.test.mjs`, 약 280건)가 CI에서 돌지 않는다. 서버 회귀가 배포 전에 안 잡힌다.
- 고치기: relay job에 `npm test`(working-directory `server/trip-relay`) 단계를 추가한다. `tools/admin-console/server.test.mjs`도 같은 job에서 `node --test`로 돌리는 것을 함께 검토한다.

### 1-3. CI에서 앱 단위 테스트(`TaptionPlanTests`, 약 3,064건)가 돌지 않음
- 위치: `.github/workflows/ci.yml` app job — `xcodebuild build`만 하고 `test`가 없음
- 문제: 앱 전체 단위 테스트가 로컬에서만 돌고 CI에서는 빌드 성공 여부만 확인한다.
- 고치기: 별도 job으로 `xcodebuild test -only-testing:TaptionPlanTests`(시뮬레이터)를 추가한다. 시간·비용이 크면 대표와 상의해 nightly로 돌리는 것도 방법이다. 단, `TravelModeView.swift` actor 격리 오류로 app job이 이미 실패 중인데, 이는 대표 지시로 건드리지 않는 항목이므로(아래 "건드리지 말 것" 참고) 테스트 job 추가와는 별개로 다룬다.

## 2. 조용히 실패하는 곳 (중간)

### 2-1. 여행 공유 `probe()`가 모든 오류를 삼킴
- 위치: `Packages/TaptionTripShare/Sources/TaptionTripShare/ShareRoomSession.swift:229-240`
- 문제: `probe()`의 `catch {}`가 방 삭제·비밀번호 변경·네트워크 오류를 모두 삼키고 상태도 바꾸지 않는다. 주석에는 "나갔는지·방이 없는지·비밀번호가 바뀌었는지·인터넷이 없는지"를 본다고 적혀 있지만, 오류가 나면 UI는 아무것도 알 수 없다.
- 고치기: `ShareError` 종류별로 나눈다. 방 없음·비밀번호 변경이면 끝 상태로 바꾸고 알림(`emit`)을 보내고, 네트워크 오류면 로그만 남긴 뒤 다음 재시도를 기다린다.

### 2-2. 여행 공유 잠금 갱신 실패를 삼키고 성공으로 보고
- 위치: `Packages/TaptionTripShare/Sources/TaptionTripShare/ShareRoomSession.swift:590-604` (`renewLocks()`)
- 문제: `.locked`가 아닌 오류(네트워크 등)는 `catch {}`로 삼키고 `return true`를 돌려준다. 호출부(`:585`)는 false일 때만 갱신 태스크를 멈추므로, 실패가 반복돼도 로그 한 줄 없이 계속 시도한다.
- 고치기: 오류를 로그로 남긴다. 일시적 실패는 다음 틱에 다시 시도하는 지금 동작을 유지하되, 연속 실패 횟수를 세어 일정 횟수 넘으면 상태를 `offline`으로 바꾸는 것을 검토한다.

### 2-3. Watch 요약 저장 실패가 로그 없이 사라짐
- 위치: `TaptionPlan/UX/AppModel+WatchSummary.swift:658-668` (`persistWatchSummaryForDelivery`의 `catch { }`), 같은 파일의 `applyWatchSensorSummary`에 `return false` 경로가 약 15곳(165·172·184·188·199·203·217·287·291·344·382·388·414·429·432행 등)
- 문제: Watch 요약 저장·적용이 실패하면 false만 돌려주고 어디에도 원인이 남지 않는다. Watch 동기화 문제를 나중에 추적할 길이 없다.
- 고치기: `persistWatchSummaryForDelivery`의 catch에서 `integrationLogger`로 오류를 남긴다. `applyWatchSensorSummary`의 주요 실패 지점에도 짧은 로그(어느 분기에서 멈췄는지)를 더한다. 좌표·건강 원본 값은 로그에 넣지 않는다.

### 2-4. 임시 파일 정리 실패를 삼킴 (낮음)
- 위치: `TaptionPlan/Core/PlanRepository.swift:711` (`catch {}` after `removeItem`)
- 문제: 임시 파일 삭제가 실패하면 조용히 넘어가 임시 파일이 쌓일 수 있다.
- 고치기: 실패 횟수를 세어 디버그 로그로 남기거나, 반환값에 실패 개수를 포함한다. 동작 변경은 필요 없다.

## 3. 죽은 코드 (낮음~중간)

### 3-1. `MapHomeTodoButton` 미사용
- 위치: `TaptionPlan/UI/MapHomeLaunchPrompts.swift:260` (정의만 있고 호출처 0곳)
- 고치기: 타입째 지우고 Debug 빌드로 확인한다. (HOME_UX_REVIEW.md "따로 확인할 것"에서도 지적됨)

### 3-2. `MapHomeView`의 `header` 뷰 미사용
- 위치: `TaptionPlan/UI/MapHomeView+Support2.swift:542` (`var header: some View`, 호출처 없음)
- 고치기: 지우고 Debug 빌드로 확인한다. (HOME_UX_REVIEW.md "따로 확인할 것"에서도 지적됨)

### 3-3. 홈 배치 설정이 저장만 되고 읽히지 않음
- 위치: `TaptionPlan/UI/MapHomeView.swift:162-163` (`@AppStorage`로 `layoutStyleRaw` 저장, 기본값 `.classic`), 같은 파일 `:677` (`var layoutStyle: MapHomeLayoutStyle { .tabBar }`로 고정)
- 문제: 저장된 설정값을 아무 데서도 읽지 않는다. `TaptionPlanTests/MapHomeLiveMapTests.swift:1161-1164`의 시험은 여전히 "기본은 classic"을 확인해 코드와 시험이 어긋난다.
- 고치기: 둘 중 하나. (가) 시험 옵션을 다시 넣을 계획이 없으면 AppStorage 저장 줄과 classic 관련 시험 기대값을 정리한다. (나) 나중에 되살릴 거면 주석으로 "지금은 tabBar 고정, 설정값 미사용"을 명시하고 시험 기대값을 실제 동작에 맞춘다. HOME_UX_REVIEW.md는 "시험 옵션을 다시 넣을 때 되살려 쓸 수 있다"고 적어 두었으므로, 지우기 전에 대표 확인이 필요할 수 있다.

### 3-4. 투명 뷰에 붙은 그림자 (자잘함)
- 위치: `TaptionPlan/UI/MapHomeView+Map.swift:1127-1138` (`mapControls`가 `Color.clear`를 돌려주면서 `.taptionShadow(.floating)`을 붙임)
- 문제: 투명한 뷰의 그림자는 화면에 아무것도 그리지 않는다.
- 고치기: 그림자 수식어를 뺀다. (이 함수는 `MapHomeView+Timeline.swift:173`에서 간격용으로 쓰이고 있으니 함수 자체는 지우지 않는다.)

## 4. 번역·접근성 하드코딩 (중간)

### 4-1. `Text("카운터 상세")` 한국어 고정
- 위치: `TaptionPlan/UI/MapHomeCounterDetailSheet.swift:309`
- 문제: 제목이 한국어로 고정돼 다른 언어에서도 한국어로 보인다.
- 고치기: `language.text("카운터 상세", "Counter details")`로 바꾼다(주변 코드가 쓰는 방식과 동일).

### 4-2. 집 관련 접근성 이름 한국어 고정 (3곳)
- 위치: `TaptionPlan/UI/MapHomeMapAnnotations.swift:112` ("집 레벨 ..."), `:225` ("집 성장과 오늘 하루 요약 보기"), `:249` ("집 레벨 ... · 성장 카드와 오늘 하루 요약 열기")
- 문제: VoiceOver 이름이 한국어로 고정돼 있다.
- 고치기: `language.text(한국어, 영어)`로 바꾼다.

### 4-3. 사진 개수 접근성 이름 한국어 고정
- 위치: `TaptionPlan/UI/MapHomePhotoLayer.swift:334` (`.accessibilityLabel(Text("사진 \(count)장"))`)
- 문제: 위와 동일.
- 고치기: `language.text("사진 \(count)장", "\(count) photos")`로 바꾼다.

## 5. 테스트 공백 (중간)

### 5-1. `TaptionLedgerCore`에 테스트 파일이 없음
- 위치: `Packages/TaptionLedgerCore/` (소스 `LedgerCore.swift`, `LedgerTrips.swift` 2개, Tests 디렉토리 없음)
- 문제: 가계부 값 타입·여행 장부 타입에 단위 테스트가 없다. `LedgerMessageParser` 테스트는 앱 테스트(`TaptionPlanTests/LedgerMessageAccuracyTests.swift` 등)에 있지만, 패키지 자체의 Codable 왕복·정산 계산 등은 직접 테스트가 없다.
- 고치기: `Packages/TaptionLedgerCore/Tests/TaptionLedgerCoreTests/`를 만들고 Codable 왕복·금액 합계·정산 계산 테스트를 더한다. 그 뒤 CI packages job 목록(1-1)에도 추가한다.

## 6. 방어적 코딩 (낮음)

### 6-1. `AITaskProducer`의 force unwrap — 안전하나 전제가 안 적혀 있음
- 위치: `TaptionPlan/UX/AITaskProducer.swift:69-87` (`trip.first!`, `trip.last!`, `run.first!`, `run[0]`)
- 확인: `transitTrips`(`:112-135`)는 빈 배열을 절대 안 넣고, `fragmentRuns`(`:137-152`)는 2개 이상인 묶음만 넣으므로 지금은 안전하다. 다만 이 전제가 코드 어디에도 안 적혀 있어 나중에 건드리면 크래시가 날 수 있다.
- 고치기: `transitTrips`·`fragmentRuns`에 "빈 배열을 돌려주지 않는다"는 주석을 달거나, 호출부에서 `guard let first = trip.first`로 바꾼다.

### 6-2. `StickerArtEngine`의 `as! CTFont`
- 위치: `TaptionPlan/UI/StickerArtEngine.swift:292`
- 확인: 글자 런의 글꼴 속성은 실제로 항상 CTFont라 지금은 안전하다.
- 고치기: `as?` + `continue`로 바꿔 혹시 모를 경우에도 크래시가 안 나게 한다.

### 6-3. 반복 생성되는 `ISO8601DateFormatter` (자잘함)
- 위치: `TaptionPlan/Core/FlightLookup.swift:95` (`parseISO` 호출마다 생성), `TaptionPlan/Core/DiagnosticsLogSupport.swift:590, 745`, `TaptionPlan/Core/ShareTextRouter.swift:16`
- 문제: 동작은 맞지만 호출마다 포매터를 새로 만든다.
- 고치기: 정적 공유 포매터로 바꾼다. (`GoogleCalendarAccount.swift:445`의 `rfc3339`처럼 이미 정적으로 둔 곳이 있으니 같은 방식을 따른다.)

## 7. 운영 콘솔 강화 (낮음)

### 7-1. 팩 id·버전 형식 검증 없음
- 위치: `tools/admin-console/server.mjs:296, 308` (`buildId`와 `.bpack` 파일 이름에 `pack.id`·`pack.version`을 그대로 씀)
- 확인: `pack`은 로컬 seed 매니페스트에서 오고, 경로는 `execFile`(셸 없음)로 실행돼 셸 주입은 없다. 다만 매니페스트의 id에 `../` 같은 값이 있으면 `BUILD_ROOT` 밖으로 파일을 쓸 수 있다.
- 고치기: `localPacks()`에서 id·버전을 `^[A-Za-z0-9._-]+$` 같은 형식으로 검증하고, 맞지 않으면 목록에서 빼고 오류를 표시한다. 로컬 전용 도구라 우선순위는 낮다.

## 건드리지 말 것 (확인됨)

- `TaptionPlan/UI/TravelModeView.swift`의 actor 격리 CI 실패: 대표 지시로 건드리지 않음. CI 개선 제안(1-3)과는 별개로 다룰 것.
- Muse 제공자 추가 작업 중인 파일: `TaptionPlan/UI/AssistantAIProvider.swift`, `AssistantConnectView.swift`, `AssistantConnectGuide.swift`, `AITaskPanel.swift`, `TaptionPlanTests/AssistantPhase3Tests.swift`, `docs/AI_ASSISTANT_GUIDE.md`, `docs/ACTIVITY_RELAY_API.md` — 이 파일들과 겹치는 변경은 제안하지 않음.
- AGENTS.md §4 "대표 결정" 항목(백업 비밀번호 6자리, 좌표 예외, PCC 스위치 등)은 새 지시 없이 변경 금지.

## 확인했지만 문제 아닌 것

- `MapHomePhotoLayer.swift:446`의 `as! AVPlayerLayer`: `layerClass`를 `AVPlayerLayer`로 재정의해둬(`:445`) 안전.
- `ActivityClassificationLockEngine.swift`·`LedgerCapture.swift`·`ShareScheduleParser.swift`의 `bestMatch!`·`best!`·`found!`: 같은 식에서 nil 검사를 먼저 해 단락 평가로 안전.
- `OfflineVectorTileCache.swift:131`의 `as! NSMutableURLRequest`: `mutableCopy()`는 항상 `NSMutableURLRequest`를 돌려줘 안전.
- `fatalError` 2곳: `init(coder:)` 미지원용 관용구라 문제 없음. `try!`은 테스트 밖 코드에 없음.
- `DateFormatter` 고정 형식 사용처: `en_US_POSIX` 로케일을 제대로 지정하고 있음.
- `MapHomeTimeSidebar` 접근성 이름 한국어 고정(HOME_UX_REVIEW 지적): 이미 `AppLanguagePreference.text`로 고쳐짐.
- `MapHomeSupportViews.swift:385`의 `Text("지도 호스트 ...")`: DEBUG 전용 미리보기(`-pinPreview`)라 사용자 노출 없음.
- `TaptionPlan/AppSecrets.xcconfig`: 비밀값은 로컬 파일(`AppSecrets.local.xcconfig`, gitignore)에만 두고 커밋 파일에는 없음.
- `tools/admin-console/server.mjs`: 127.0.0.1 전용, Host 검사, 일회용 토큰(`timingSafeEqual`), CORS 미응답, 정적 파일은 고정 목록 조회, `execFile` 셸 없음 — 보안 설계가 잘 돼 있음. `/api/config`의 예외는 설정 검증만 빼는 것이고 토큰 검사는 모든 라우트에 적용됨.
- 줄 수: `scripts/architecture-metrics.py` 기준 236,050줄(783개 파일). `docs/architecture-baseline.json`의 250,477줄은 다른 기준(테스트 포함)으로 보이며, 현재 `--check` 기준으로는 상한 위반이 아님.
