# Taption Plan 다음 채팅 인계 프롬프트

## 2026-08-31 WEAT831001 / WATCH83101 · 유료 출시 보완 최신 상태

현재 작업 디렉터리는 `/Users/u_mo_c/Documents/taption plan`이며 build 120 소스 커밋은 `256ac7d32933359c986027a1d2f22915790df1bd`이다. 해당 커밋은 `main`/`origin/main`에 push했고, build 120 TestFlight 업로드·처리·내부 그룹 연결까지 완료했다.

반영된 보완:

- 지도 메모를 `ActionMemo`의 원본 시간·좌표·계획 연결로 생성하고, 선택 날짜·표시 필터에 맞춰 지도에 표시하며, 추가·편집 화면에서 시간·좌표를 readback한다.
- 새 지도 메모 편집을 취소하거나 닫으면 draft를 정본과 Cloud tombstone에 남기지 않고, 저장할 때만 유지한다.
- 지도 메모 초안을 일반 삭제 경로에서 제거해 저장 기록과 Cloud tombstone이 남지 않도록 했다.
- 지도 메모를 계획 종료 시각에 만들 때 종료된 계획에 연결하지 않도록 시간 구간을 시작 포함·종료 미만으로 판정한다.
- 지도 메모 편집 중 센서·알림 저장이 발생해도 미저장 draft는 저장소에서 제외하고 화면 상태만 유지한다.
- 저장된 지도 메모의 시간을 편집하면 새 계획 구간에 재연결하고, 계획 밖이면 독립 메모로 분리한다.
- 표시 메뉴에서 모든 지도 메모와 일정 관련 메모 필터를 사용자가 선택하고 저장할 수 있다.
- 일간 지도 재생 중에는 playhead 시각까지의 지도 메모만 표시하고, playhead와 같은 시각의 메모는 포함한다. 정적 지도는 선택 날짜 전체를 표시한다.
- Cloud에서 연결된 계획이 삭제돼도 지도 메모의 원문·좌표·발생 시각·카테고리는 보존하고 고아 계획 연결만 해제한다.
- 로컬에서 계획 또는 하위 계획을 삭제해도 연결된 지도 메모를 삭제하지 않고 계획 연결만 해제해 독립 기록으로 보존한다.
- 센서 권한이 없어도 수동 기록과 지도 메모는 사용 가능하게 두고, 자동 기록에 필요한 위치 항상 허용·정확한 위치·동작 권한만 별도 안내한다.
- 14일 체험 기록은 키체인·iCloud와 함께 로컬 `UserDefaults` fallback에 저장해 종료·재실행 뒤에도 복귀한다.
- 미래 날씨를 기존 관측값과 구분하는 `WeatherContext.isForecast`를 추가하고, WeatherKit/Open-Meteo의 미래 hourly context를 최대 16일 범위로 SQLite 정본에 저장·복원한다.
- Watch 측정 시각과 iPhone 실제 수신 시각을 분리해 영속 receipt로 기록하고, Watch 데이터 메뉴와 설정 메뉴에 `최근 수신 시각` 또는 `최근 수신 시각 없음`을 항상 표시한다. 기존 receipt는 legacy 측정 시각을 초기 수신 시각으로 읽는다.
- WatchConnectivity envelope 도착 시각을 sensor/health callback에 그대로 전달해 AppModel 처리 지연이 메뉴의 수신 시각을 바꾸지 않도록 했다.
- 값이 비어 있는 health snapshot도 유효한 `health` receipt로 기록해 `지금 가져오기`가 빈 응답을 받았을 때도 최신 수신 시각이 갱신되도록 했다.
- `지금 가져오기` 요청이 실제 전송된 경우 메뉴·설정에 요청 시각을 표시하고, Watch envelope을 받으면 요청 표시를 지우고 최신 수신 시각으로 전환한다. 연결 불가·Watch 미설치 상태에서는 대기 표시를 만들지 않는다.
- App Store 상품을 아직 불러오지 못한 상태에서는 실제 스토어 가격을 추정해 표시하지 않고, 가격이 확인된 경우에만 현지화된 금액을 보여 주도록 했다. 체험 재사용 안내도 실제 기기·iCloud 기록 범위에 맞췄다.
- Pro 상품은 `com.taption.plan.pro` ID뿐 아니라 StoreKit `nonConsumable` 타입까지 일치할 때만 구매 대상으로 사용한다.
- 지하철 후보·예상경로·Watch 진단을 추가했다. iCloud 조회 범위는 2026-08-31 00:00~12:28 KST, Watch 재현 위치는 `설정 > Apple Watch 데이터`, 당시 iPhone·Watch 연결 및 Watch 잠금 해제 상태는 사용자 확인이며 지도 메뉴는 제외한다.
- `transit_boarding_candidates_evaluated`와 `expected_route_requests_built`/`expected_route_projection_built`/`expected_route_network_resolution`/`expected_route_state_applied` 로그로 역 후보 누락, 자동차 fallback, forecast gap·중복·겹침을 구분한다. Watch는 요청 ID로 버튼 탭부터 envelope 수신·decode·receipt 반영까지 연결한다.
- 메뉴 iCloud 백업은 별도 `TaptionLogs` export와 다르다. `Taption Plan/2026-08.taptionbackup` 및 `Raw Sensors/2026-08.rawsensorbackup`가 2026-08-31 12:47에 갱신됐고, 월간 payload를 읽기 전용으로 복호화해 내부 readback까지 완료했다. 백업 내부에는 8/31 새 예상경로 투영 로그가 없어, 새 진단 빌드의 화면 재현과 로그 readback이 다음 단계다.
- 위 월간 백업을 읽기 전용으로 복호화한 결과 00:00~12:28 KST 여행 구간 7개 중 09:31~10:06 KST 지하철 1개(`인천2호선·공항철도`)가 저장되어 있었다. Raw sensor 684건과 envelope 706건은 모두 iPhone source였고 Watch source·역/철도 플래그·역 이름은 0건이었다. 백업 내부 8/31 Watch 요청은 `reachable=false`였으며 새 예상경로 진단 이벤트는 없어, Watch 전달 문제와 점선 중복 문제를 새 빌드로 분리 재현해야 한다.

검증:

- `TaptionPlanTests` 전체 852건 성공. 지도 메모 핵심·종료 시각 경계·시간 재연결·재생 playhead cutoff·무결성·draft 저장 경쟁·초안 삭제 tombstone 방지·로컬/Cloud 계획 삭제 보존·체험 fallback·미래 예보·Watch receipt를 포함하고, 가격 표시 정확성 UI 변경도 컴파일한 상태로 직렬 재실행 성공.
- 최신 전체 XCTest 결과: `/tmp/TaptionPlan-full-2026-08-31-watch-feedback-final.xcresult` (`852 passed / 0 failed / 0 skipped`).
- 결제 상품 타입 보강 기준 XCTest: `/tmp/TaptionPlan-full-2026-08-31-paid-type.xcresult` (`852 passed / 0 failed / 0 skipped`).
- iOS Simulator `MAP30CNT01 Test`에서 체험 시작 후 종료·재실행 지도 복귀, 권한 안내, `지도 메모 추가` 화면의 날짜·시간·위도·경도, 취소 복귀를 확인했다.
- iPhone 14 Pro 최신 product-type 보강 소스 서명 Debug `1.0 (119)` 빌드·설치와 `Taption Plan com.taption.plan 1.0 119` readback, launch exit 0을 확인했다. iPhone 미러링으로 실제 지도 화면은 확인했지만, 터치 시 iPhone 사용 중으로 미러링이 종료되어 직접 터치·저장 readback은 아직 없다.
- 유선 iPad Pro 최신 소스 서명 Debug `1.0 (119)` 설치(`databaseSequenceNumber: 6160`)와 `Taption Plan com.taption.plan 1.0 119` readback, launch exit 0을 확인했다. CoreDevice에서 화면 캡처·직접 터치 경로는 확보하지 못해 실제 터치 증거는 미완료다.
- 최신 iphoneos Debug 빌드: `/tmp/TaptionPlan-device-build-20260831-paid-type/Build/Products/Debug-iphoneos/TaptionPlan.app`, `** BUILD SUCCEEDED **`; iPhone 14 Pro 설치·readback·launch exit 0 확인.
- 수신 요청 대기 표시를 포함한 최신 iphoneos Debug 빌드: `/tmp/TaptionPlan-device-build-20260831-watch-feedback/Build/Products/Debug-iphoneos/TaptionPlan.app`, `** BUILD SUCCEEDED **`; 재설치 중 CoreDevice 연결 timeout으로 이 변경분의 설치 readback은 미완료.
- 09:35:56 iPhone 미러링 `다시 시도` 후에도 “iPhone을 찾을 수 없음”으로 종료됐고, CoreDevice 재확인에서 iPhone·Apple Watch 모두 `unavailable`이었다.
- Apple Watch 최신 Watch 앱 설치를 시도했으나 `available (paired)`가 일시 표시된 직후 CoreDevice가 기기 식별자를 찾지 못했고, 09:10:58~09:11:54 재확인도 계속 `unavailable`이었다. Watch 설치·수신·동기화는 미완료다.
- 최신 dirty 소스 iOS Release generic build: `/tmp/TaptionPlan-release-20260831-paid-type/Build/Products/Release-iphoneos/TaptionPlan.app` 성공; embedded Watch app·Widget 포함.
- 최신 dirty 소스 watchOS Release generic build: `/tmp/TaptionPlan-watch-release-20260831-paid-type/Build/Products/Release-watchos/TaptionPlanWatch.app` 성공.
- 수신 요청 대기 표시 포함 최신 dirty 소스 iOS Release generic build: `/tmp/TaptionPlan-release-20260831-watch-feedback/Build/Products/Release-iphoneos/TaptionPlan.app` 성공; embedded Watch app·Widget 포함.
- 수신 요청 대기 표시 포함 최신 dirty 소스 watchOS Release generic build: `/tmp/TaptionPlan-watch-release-20260831-watch-feedback/Build/Products/Release-watchos/TaptionPlanWatch.app` 성공.
- 이번 route/Watch 보정 후 `RouteTimelineDataTests`와 `WatchSensorQueryPlanTests` 단독 실행은 각각 exit 0이고, watchOS Debug generic build도 exit 0이다. 기존 전체 XCTest 852건 결과와 별도로 현재 변경 파일 기준 focused 회귀 증거로 기록한다.
- build 120 Release archive/export는 `/private/tmp/taption-rel8310001.xcarchive` 및 `/tmp/taption-rel8310001-export/TaptionPlan.ipa`에서 성공했고, IPA SHA-256은 `65003366d03503c02afd87d8fc17a301ce75e08ea5cb9ba0a5986c605d562d39`, deep codesign 검증도 통과했다.
- build 120은 Delivery UUID `d0c6d36b-5978-40c0-9027-bb3169d0cae6`로 업로드되어 `VALID`·`APP_STORE_ELIGIBLE`·App Store Connect 등록을 확인했다. `TP Taption Plan 내부 테스트` 그룹 상세에서 `1.0 (120) · 테스트 중`을 확인했고, 테스터 화면은 1명 노출 상태이며 설치 표시는 아직 기존 `1.0 (119)`이다.

남은 게이트:

- 결제 모델: 무료 다운로드 + 14일 체험 + Pro 1회 영구 구매안으로 진행하기로 결정했다. Chrome 로그인은 확인했지만 `유료 앱 계약`이 `신규`이고 `com.taption.plan.pro` 상품이 없어 계약 활성화·상품 생성·판매 가능 상태·sandbox 구매/복원은 외부 게이트로 남아 있다 (`temp.md`의 `PAID831001`).
- iPhone 미러링 재연결을 위해 잠금 상태로 전환한 뒤 실제 화면·터치·지도 메모 저장 readback. 현재 지도 화면 진입만 확인했고 터치 시 연결이 종료됐다.
- Apple Watch 현장 설치·실제 수신·동기화. 메뉴의 수신 시각 구현과 receipt 단위 테스트는 완료했지만, 현재 Watch는 `unavailable`이라 실제 콜백 readback은 미완료다.
- build 120의 iPhone 14 Pro 설치·실제 화면/터치·Watch 수신 readback.
- App Store Connect는 09:55:39 KST Chrome에서 `axony99@gmail.com` 로그인과 `Taption Plan` 접근을 확인했다. 기존 TestFlight build 119는 `제출 준비 완료`, `TP Taption Plan 내부 테스트` 그룹에 노출되고 그룹 상세는 1명의 테스터·80개 빌드, 테스터 `axony99@gmail.com`의 `설치됨 1.0 (119)`로 readback했다. 다만 비즈니스의 `유료 앱 계약`은 `신규`이고, 앱 내 구입 목록은 비어 있어 `com.taption.plan.pro`가 아직 App Store Connect에 생성되지 않았다.

## 2026-08-31 REL83054A01 · 전달 완료 및 다음 채팅 인계

다음 채팅은 `/Users/u_mo_c/Documents/taption plan`에서 Taption Plan 작업을 이어간다. 아래 완료 증거를 기준으로 중복 실행하지 않는다.

완료 증거:

- 구현 커밋·푸시 완료: `cd70e1bac554d5a70cd6f6d8061799b9849aba4e`; 인계 문서 커밋 후 최신 `HEAD`·`origin/main`: `129df8bd1d43f90a437b2c6efa4b8c99a1dd62f7`; worktree clean.
- 앱·Widget·Watch·Watch Widget `1.0 (119)` 확인.
- Release archive: `/private/tmp/taption-rel83054a01.xcarchive`; export: `/private/tmp/taption-rel83054a01-export/TaptionPlan.ipa`.
- IPA SHA-256: `46567f352e3f369394471a9df9aa22089497b6d63c0f1cf9fbdca6cf77022378`; `codesign --verify --deep --strict` 통과.
- TestFlight upload 성공: Delivery UUID `02b51851-6c12-402d-b3d4-cbc561b9e7c9`; build `119`, `VALID`, `APP_STORE_ELIGIBLE`.
- `TP Taption Plan 내부 테스트` 그룹 연결·build `119` 노출 readback 완료; 테스터 1명 `INSTALLED` readback.
- iPhone 14 Pro(`00008120-00092C3E14F0201E`)에 설치·실행 완료; `com.taption.plan / 1.0 / 119` readback.
- WBS 저장소와 iPhone·Apple Watch 원본 sensor record/provenance는 수정하지 않았다. 사용자가 삭제한 `temp.md`, `test.md`도 복구하지 않았다.

현재 자동 검증:

- `swift test --package-path Packages/TaptionActivityEngine`: 6/6
- `swift test --package-path Packages/TaptionPlanCore`: 36/36
- `swift test --package-path Packages/TaptionRouteEngine`: 14/14
- `swift build --package-path Packages/TaptionPlanEngine`: 통과
- iOS Simulator 전체 XCTest: 835/835, `/private/tmp/taption-rel83054a-sim.xcresult`
- `git diff --check`: 통과

다음 채팅에서 남은 게이트:

- iPhone 지도·날씨·목요일 경로·졸라맨·지도 비율·좌우 핸들·롱프레스·Dynamic Island 실제 화면/터치
- Apple Watch 설치·수신·오늘 활동/수면 provenance·iPhone projection·동기화
- iPhone cold/warm 날짜 로딩 p95와 실제 signpost 집계
- iPhone 14 Pro에서 지도·날씨·목요일 경로·졸라맨·지도 비율·좌우 핸들·롱프레스·Dynamic Island 실제 화면/터치
- Apple Watch 설치·수신·오늘 활동/수면 provenance·iPhone projection·동기화 실제 readback
- iPhone cold/warm 날짜 로딩 p95와 실제 signpost 집계

실행 규칙:

- 먼저 `AGENTS.md`와 이 문서를 읽고 현재 `HEAD`, `origin/main`, dirty 상태, 기기 상태를 직접 확인한다.
- source/provenance를 덮어쓰지 않고 불변 파생 projection으로만 수정한다. WBS dirty 파일은 읽기 전용이다.
- 실기기·권한·계정·App Store Connect가 막히면 추정으로 완료하지 말고 명령·오류·미완료 게이트를 이 문서에 기록한다.
- TestFlight는 이미 processing `VALID`, 내부 그룹 연결, 그룹 내 build·tester 노출까지 확인했다. 새 업로드 전에는 build number를 올린다.

다음 실행 규칙:

- 먼저 `AGENTS.md`와 이 문서를 읽고 현재 `HEAD`, `origin/main`, dirty 상태, 기기 상태를 직접 확인한다.
- 실제 화면·터치·Watch 동기화 증거가 없으면 완료로 추정하지 않는다. `temp.md`와 `test.md`는 사용자가 삭제했으므로 복구하지 않는다.
- source/provenance를 덮어쓰지 않고 불변 파생 projection으로만 수정하며 WBS dirty 파일은 읽기 전용이다.

## 2026-08-30 WACT83023A · Watch 설치 상태·오늘 활동/수면·오른쪽 핸들

- `WCSession` 활성화 전의 일시적 설치 false를 화면에 노출하지 않고, 활성화 완료·reachable·Watch 상태 변경 시 데이터 동기화를 재요청하도록 수정했다. iOS Debug 산출물의 `com.taption.plan.watchkitapp` 임베드, companion bundle 연결, iOS·Watch `1.0 (117)`을 readback했다.
- Watch 확정 activity를 iPhone 추정 movement보다 우선하고 명시 이동 경로는 이동 알고리즘 결과를 계속 우선한다. Watch activity/sleep 수신 시 시작일·종료일 day snapshot을 무효화해 같은 날짜 키로 활동·수면·졸라맨을 재투영한다. 원본 센서 record와 provenance는 수정하지 않았으며, 실제 수면 구간을 aggregate 값으로 추정하지 않는다.
- 오른쪽 핸들은 미래 영역 입력을 허용하되 선택값은 현재 시각 상한으로 clamp한다. WBS 방식의 `opacity(0.001)` hit-test 레이어와 z-index로 즉시 드래그·탭·더블탭을 유지했다.
- 검증: `swift test --package-path Packages/TaptionPlanCore` 36/36, 집중 XCTest `MapHomeStickmanTests` 25건 및 `TimeScaleTests` 전체, iOS·Watch Debug simulator build, `git diff --check` 통과. XCTest 결과: `/tmp/taption-plan-wact83023a-tests/Logs/Test/Test-TaptionPlan-2026.08.30_16-40-46-+0900.xcresult`.
- 실기기 미완료: 연결된 iPhone/Apple Watch가 없어 Watch 앱 설치·오늘 activity/sleep 동기화 및 HealthKit readback, 오른쪽 핸들 직접 터치를 확인하지 못했다. 추정으로 완료 처리하지 말고 `temp.md`의 `WACT83023A`를 유지한다.
- 다음 실행자는 실기기 연결 후 Watch 설치 상태·오늘 activity/sleep provenance·졸라맨 매칭과 오른쪽 핸들 터치를 확인하고, 증거 확보 시에만 큐 항목을 삭제한다. 이번 실행에서는 커밋·푸시·TestFlight 업로드를 수행하지 않았다.

## 2026-08-30 TMAL83024A · temp.md 전체 실행 및 Release 118

- `temp.md` 잔여 항목의 자동 검증을 재실행했다. Package `36/36`, Plan 전체 XCTest exit 0, `git diff --check` 통과.
- 앱·Widget·Watch·Watch Widget을 `1.0 (118)`로 통일했고 Release archive/export 성공: `/private/tmp/taption-plan-tmal83024a-v118.xcarchive`, `/tmp/taption-plan-tmal83024a-v118-export/TaptionPlan.ipa`.
- IPA SHA-256은 `8d2042df30abdab09b58661fc8bf9bea54e9c4d286500870e1e030f0265648d6`; archive 앱 codesign verify 및 embedded Watch/Widget readback 통과.
- TestFlight 업로드 성공: Delivery UUID `37749dc1-33c0-42b8-864b-7733173fde22`; build 118 `VALID / APP_STORE_ELIGIBLE`. `TP Taption Plan 내부 테스트` 그룹 연결과 그룹 빌드·테스터 1명 노출을 readback했다.
- 연결된 iPhone/Apple Watch가 없어 설치·실행·실제 터치, Watch 동기화·오늘 activity/sleep provenance, Dynamic Island는 미완료로 유지했다. 증거 없는 항목은 `temp.md`에서 삭제하지 않는다.
- 다음 단계는 Plan 변경을 `main`에 커밋·푸시한 뒤 IPA를 TestFlight에 업로드하고 `TP Taption Plan 내부 테스트` 그룹의 build 118 연결·노출을 readback하는 것이다.

## 2026-08-30 RELWSYNC2A · Apple Watch 동기화 수정 릴리스 완료

- Watch 수동 동기화가 로컬 센서·HealthKit drain과 대기 큐 전송을 수행하도록 수정했고, iPhone v3 병합 실패는 진단 이벤트로 기록한다. 원본 iPhone·Apple Watch record와 provenance는 보존했다.
- `swift test --package-path Packages/TaptionPlanCore` 36/36, 직렬 Plan 전체 XCTest 824/824, iOS·Watch Debug build, `git diff --check`가 통과했다. 병렬 XCTest의 공유 시뮬레이터 간섭 실패는 직렬 재실행에서 통과했다.
- Release archive/export: `/private/tmp/taption-plan-relsync2a-v117.xcarchive`, `/private/tmp/taption-plan-relsync2a-v117-export/TaptionPlan.ipa`; `com.taption.plan / 1.0 / 117`, IPA SHA-256 `3a1eea30bd7bc7fcdfde2bd7bc8135da4f472be416987fc56ffb548acc745e65`, 서명 검증 통과.
- TestFlight Delivery UUID `40d3c4ec-d471-4d0e-bc06-6bd4117610d5`; build 117 `VALID / APP_STORE_ELIGIBLE`. `TP Taption Plan 내부 테스트` 그룹에 연결했고 그룹 builds 목록과 테스터 화면(1명, `INSTALLED`)에 노출됨을 readback했다.
- 구현 커밋은 `1edd1007f556775bed29429521e0a7c5eb7eef29`이며, 증거 문서 커밋 후 local `HEAD`와 `origin/main` SHA 일치 및 clean을 readback했다. WBS checkout의 기존 dirty 파일은 보존했다.
- iPhone 14 Pro·Apple Watch 설치/실제 화면/터치는 이번 요청 범위 밖이며 실기기 `unavailable`로 미검증 상태다.

## 2026-08-30 REVUP83021 · 코드리뷰 및 TestFlight 전달 인계

이번 실행은 DB·날짜 로딩·Watch 저장 경계를 다방면 리뷰하고, 원본 iPhone·Apple Watch record/provenance와 WBS checkout을 건드리지 않은 채 최소 수정한 뒤 TestFlight build 116을 전달하는 것이다.

- strict legacy read, 동일 raw ID 충돌, materialized raw count overflow는 fail-closed로 처리한다.
- Watch raw 저장이 성공한 뒤에만 전송하고 실패하면 재큐한다. 수신·migration provenance는 `source-device:appleWatch + transport:WatchConnectivity`로 일치시킨다.
- 날짜 load coordinator는 요청 token, 최신 요청 취소, 월 prefetch 취소 전달, bounded LRU를 사용하며 DB query/decode/projection signpost는 예외에도 종료한다.
- 앱·Widget·Watch·Watch Widget build number는 `1.0 (116)`으로 맞췄다. TestFlight 재업로드에는 기존 115와 다른 116이 필요하다.

자동 검증 증거:

- `swift test --package-path Packages/TaptionPlanCore`: 36/36 통과.
- Plan 전체 XCTest: 824/824 통과, 실패·스킵 0. 결과: `/private/tmp/taption-plan-revup83021-full.xcresult`
- 관련 focused XCTest: 149/149 통과. 결과: `/private/tmp/taption-plan-revup83021-focused-3.xcresult`
- iOS·Watch·Watch Widget Debug 통합 빌드 exit 0, 세 산출물 모두 `1.0 (116)` readback.
- `git diff --check` 통과. WBS `/Users/u_mo_c/Documents/Taption WBS`는 기존 dirty `temp.md`를 보존했다.

최종 전달 증거:

- Release archive/export: `/private/tmp/taption-plan-revup83021.xcarchive`, `/private/tmp/taption-plan-revup83021-export/TaptionPlan.ipa`; `com.taption.plan / 1.0 / 116`, Apple Distribution 서명, `codesign --verify --deep --strict` 통과, IPA SHA-256 `071417e1e551baee7d87f693fe18d840391137670e147fdcab979c38e398aa01`.
- TestFlight: Delivery UUID `d73bcf5e-ecda-41a9-984b-aa7e6d3f1ccf`; build `116`, processing `VALID`, audience `APP_STORE_ELIGIBLE`, App Store Connect 존재 확인.
- 내부 테스트: `TP Taption Plan 내부 테스트` 그룹에 build `116` 연결 및 builds 노출 readback 완료. 그룹 테스터 1명은 `INSTALLED` 상태로 확인했다.
- 커밋·원격: `b3e4d5a3654001fc969a28e71dc90fece025b337`가 local `HEAD`와 `origin/main`에 동일하고 Plan worktree clean.

남은 물리·성능 게이트:

- iPhone 14 Pro 설치·실행·실제 touch, Apple Watch 원본·동기화, 목요일 재생·지도 비율·WBS 스타일·Dynamic Island, cold/warm p95와 실제 signpost 집계는 실기기 증거가 없어 미완료로 유지한다. TestFlight 처리와 내부 그룹 노출은 위 readback으로 완료했다.

중단 조건: WBS dirty 파일 또는 iPhone·Watch 원본 수정이 필요하면 중단한다. 서명·App Store Connect 인증·처리·내부 그룹 노출이 막히면 오류와 미완료 게이트를 `test.md`에 기록한다.

## 2026-08-30 DBRUN83019 · DBIMP83020 날짜 로딩 DB 최적화 최신 인계

이번 실행의 목표는 날짜 변경 지연을 줄이면서 iPhone·Apple Watch 원본과 provenance를 보존하는 SQLite v3 저장·로드 경계를 Plan에 적용하는 것이다.

- iPhone과 Watch에 각각 `taption-plan-iphone-v3.sqlite`, `taption-plan-watch-v3.sqlite`를 만들고 raw event를 append-only로 보존한다. `day_materialized`는 날짜별 파생 bundle만 저장한다.
- 날짜·디바이스·시간 복합 인덱스, prepared statement, WAL, bounded LRU를 적용했고, `EXPLAIN QUERY PLAN`에서 날짜 인덱스 검색을 검증했다.
- 기존 JSON/v2 SQLite는 읽기 전용 입력으로 백그라운드 재구축한다. 날짜별 count·범위·digest/provenance 검증, 불일치 1회 재생성, 2차 실패 fail-closed marker를 구현했다. 전체 검증과 새 앱 readback 전에는 구 DB·백업을 삭제하지 않는다.
- `PlanDayLoadCoordinator`가 공통 날짜 소비 경계로 동작한다: `day_key + source_revision + projection_version` snapshot, 동일 날짜 coalescing, 최신 요청 취소, 월 프리패치, bounded LRU/메모리 압력 축출, 기존 화면 유지+로딩 상태.
- Watch raw를 Watch DB에 먼저 저장하고 iPhone에는 source/provenance 포함 idempotent batch merge한다. 단일 날짜 센서 소비는 coordinator를 통과한다.

자동 검증 증거:

- `swift test --package-path Packages/TaptionPlanCore`: 36/36 통과.
- Plan focused XCTest(`SensorDayStoreTests`, `TimeScaleTests`, `SQLitePlanRepositoryTests`): 148/148 통과. 결과: `/private/tmp/taption-plan-dbimp83020-focused-3.xcresult`
- iOS·Watch·Watch Widget Debug simulator build: exit 0. 산출물: `/Users/u_mo_c/Library/Developer/Xcode/DerivedData/TaptionPlan-gvqtjbpzkfvutrdlxdzhdyhsyane/Build/Products/`
- `git diff --check`: 통과. WBS 저장소 `/Users/u_mo_c/Documents/Taption WBS`는 수정하지 않았다.

다음 실행자는 cold/warm 날짜 전환 p95와 실제 signpost를 iPhone 14 Pro에서 측정하고, v3 migration/readback, Watch provenance·동기화, 목요일 재생·졸라맨·지도 비율·좌우 핸들·롱프레스·WBS 스타일·Dynamic Island를 실제 화면/터치로 확인한다. 증거가 없는 항목은 `temp.md`에서 삭제하지 않는다. 구 DB 삭제, 커밋·푸시, TestFlight, iPhone 설치는 이 계획 범위 밖이다.

중단 조건: WBS dirty 작업본을 수정해야 하거나 원본 iPhone·Watch record/provenance 덮어쓰기가 필요하면 중단한다. 실기기·권한·계정 게이트가 막히면 명령·오류·미완료 범위를 `test.md`에 기록하고 추정으로 완료 처리하지 않는다.

## 2026-08-30 BTCH830Q16 · temp.md 전체 실행 최신 상태

- `SENS830Q14`를 구현했다. Watch+iPhone가 겹치는 시각에는 Watch 행동을 우선한 결합 evidence를 사용하고, Watch가 없으면 iPhone evidence만 사용한다. 이동수단 상세는 Plan 이동 알고리즘 결과가 있을 때만 projection한다.
- `ActivityClassificationProjection` version 1에 기존 9개 major ID와 manual/locked override 보존 경계를 추가했다. raw iPhone·Apple Watch reading과 provenance는 변경하지 않았다.
- `RoutePlaybackProjection`에 누적거리 재생, 1% look-ahead 8방향, 24프레임 결정 index, route/marker 동일 좌표 projection을 추가했다.
- 자동 검증: ActivityEngine 6건, RouteEngine 14건, PlanCore 30건, 잠금 분류 보강 후 `TaptionActivityEngineAdapterTests` 10건, 관련 지도·재생·사이드바·졸라맨·분류 회귀 688건 통과. 최종 회귀 결과 bundle: `/private/tmp/taption-plan-btch830q16-regression-final.xcresult`. 최종 소스 Debug 빌드는 iOS `/private/tmp/taption-plan-btch830q16-ios-build2/Build/Products/Debug-iphoneos/TaptionPlan.app`, Watch `/private/tmp/taption-plan-btch830q16-watch-build2/Build/Products/Debug-watchos/TaptionPlanWatch.app`, Widget `/private/tmp/taption-plan-btch830q16-watch-build2/Build/Products/Debug-watchos/TaptionPlanWatchWidget.appex`에서 `1.0 (115)`를 readback했다.
- 실기기 iPhone/Apple Watch provenance·화면, 목요일 경로 재생·졸라맨·지도 비율·좌우 핸들·Dynamic Island는 미완료로 유지한다. 추정으로 완료 처리하지 않는다.

Taption Plan 작업을 이어간다. 작업 디렉터리는 `/Users/u_mo_c/Documents/taption plan`이다.

## 2026-08-30 RELD830Q10 · 전달 게이트 최신 기록

- Plan `main` 커밋·원격 푸시 후 clean을 확인하고 WBS 저장소의 dirty 변경은 보존했다.
- Release archive/export가 `/private/tmp/taption-plan-reld830q10-auto.xcarchive` 및 `/private/tmp/taption-plan-reld830q10-export/TaptionPlan.ipa`에서 성공했다.
- TestFlight upload Delivery UUID: `f29953e9-7f46-40da-a5a3-e62b1c543d4f`
- App Store Connect build `1.0 (115)`는 `VALID / APP_STORE_ELIGIBLE`이며 `TP Taption Plan 내부 테스트` 그룹에 연결되고 그룹 목록에 노출됐다.
- IPA는 `com.taption.plan`, Apple Distribution, beta entitlement, `1.0 (115)`로 readback됐다.
- iPhone 14 Pro에 동일 소스의 개발 서명 Debug 앱 `/private/tmp/taption-plan-reld830q10-device/Build/Products/Debug-iphoneos/TaptionPlan.app`을 설치·실행했다. `com.taption.plan / 1.0 / 115` 앱 목록 readback 성공. TestFlight 그룹 노출과 iPhone 직접 설치·실제 화면·터치는 독립 게이트로 기록한다.

## 2026-08-30 WBSI830Q08 · DATA830Q09 최신 인계

이번 실행의 목표는 Taption WBS의 데이터 관리·불러오기 경계까지 Plan에 적용하는 것이다.

- WBS 저장소 `/Users/u_mo_c/Documents/Taption WBS`의 현재 dirty 작업본은 읽기 전용 기준으로만 사용한다. WBS 소스와 WBS `temp.md`는 수정하지 않는다.
- Plan의 SQLite 정본, `RawDeviceDataDayArchive` 원본 envelope, `SensorReadingArchive`를 유지하고, iPhone·Apple Watch raw record와 provenance를 덮어쓰지 않는다.
- WBS의 `정본 로드 → 정상화된 일 단위 파생본 → 화면 캐시` 경계를 Plan의 `PlanDayDataSnapshot`으로 적용한다. snapshot은 source revision·updatedAt을 고정하고 actual/place/travel/reading을 해당 날짜로만 투영한다.
- 중복 센서 ID는 결정적으로 하나로 정리하고 시간순으로 읽는다. 날짜 경계와 15분 초과 GPS 공백은 재생 projection에서 분리한다. 빈 로드는 기존 당일 경로를 지우지 않는다.
- 지도는 Apple `mutedStandard`·flat·muted·light·POI 제외·교통량 숨김·paper `#FCF9F4`로 실행한다. 기존 MapDisplayStyle raw value와 MapLibre 코드는 호환성을 위해 읽되 기본 실행 경로에 노출하지 않는다.
- 지도 현재 위치·나침반·재생·스크럽은 중심/방위만 갱신하고 zoom/span/distance/pitch를 보존한다. 실제 경로·이동·체류 순서와 누적거리 보간, 1% look-ahead 8방향, 목적지 30m 체류를 유지한다.
- 졸라맨은 18개 Codable action, WBS 2등신 비율·갈색 `#916446` 선·회색 `#B7B1A8` 머리·24프레임/12fps를 사용하며 heading은 계산만 하고 몸·얼굴·머리는 회전하지 않는다.
- 좌우 핸들은 같은 동작을 사용하고 오른쪽 터치 높이는 88pt의 1.5배인 132pt다. 입력은 240Hz까지 받되 화면 반영은 최대 60Hz로 합치고 종료값은 즉시 반영한다.

현재 자동 검증 증거:

- 전체 `TaptionPlanTests`: 815건 통과. 결과: `/Users/u_mo_c/Library/Developer/Xcode/DerivedData/TaptionPlan-gvqtjbpzkfvutrdlxdzhdyhsyane/Logs/Test/Test-TaptionPlan-2026.08.30_04-43-27-+0900.xcresult`
- `swift test --package-path Packages/TaptionRouteEngine`: 11건 통과
- `swift test --package-path Packages/TaptionActivityEngine`: 4건 통과
- `swift test --package-path Packages/TaptionPlanCore`: 30건 통과
- `git diff --check`: 통과
- iOS Simulator `MAP30CNT01 Test`에서 자동 테스트를 실행했다. 실기기 화면·터치·Dynamic Island·Watch 지연 동기화는 설치 후 별도 게이트로 확인해야 한다.

다음 실행 순서:

1. 이 문서와 `AGENTS.md`, `DEVELOPMENT.md`, `temp.md`, `test.md`를 읽고 Plan/WBS dirty 상태와 SHA를 다시 확인한다.
2. 최신 Debug `1.0 (115)`를 iPhone 14 Pro에 설치하고 `com.taption.plan` 버전·실행을 readback한다.
3. PIN 해제 후 목요일 경로 재생, 실제/예상 경로 색상, 졸라맨 경로 추종·비회전, 현재 위치·나침반·재생 중 지도 비율 고정, 좌우 핸들 1.5배 터치를 실제 화면에서 확인한다.
4. Apple Watch 원본 데이터·provenance 불변 및 동기화, Widget/Live Activity/Dynamic Island를 별도 readback한다.
5. 증거를 `test.md`에 기록하고, 물리 게이트가 모두 닫힌 항목만 `temp.md`에서 삭제한다.
6. 승인된 Plan 파일만 `main`에 `fix: port WBS map playback and speed up sidebar`로 커밋·푸시하고 로컬/원격 SHA와 clean worktree를 확인한다.

중단 조건:

- WBS dirty 파일의 소유권이 불명확하거나 WBS를 수정해야 하면 즉시 중단하고 보고한다.
- 원본 iPhone·Watch record 또는 provenance를 수정해야 하는 설계가 나오면 파생 projection으로 전환하고 중단한다.
- 실기기 잠금·권한·서명·계정 게이트가 막히면 추정으로 완료하지 말고 명령·오류·미완료 범위를 `test.md`에 남긴다.

먼저 `AGENTS.md`를 끝까지 읽고 현재 상태를 직접 확인한다. 아래 기록의 SHA·기기·권한·TestFlight 상태는 시점 정보이므로 최신 사실로 가정하지 않는다.

```sh
cd "/Users/u_mo_c/Documents/taption plan"
git status --short --branch
git log -5 --oneline --decorate
git rev-parse HEAD origin/main
git diff --check
sed -n '1,520p' DEVELOPMENT.md
test -f temp.md && sed -n '1,240p' temp.md || true
xcrun devicectl list devices
xcrun devicectl device info apps --device C44AF739-127D-572D-AD83-417C7E879045
```

## 2026-08-29 DOC9M4K7P2 최신 인계 상태

- STK9V6Q2M4 구현과 개발문서 변경은 기능·개발문서 커밋 `eb66bf3a166f0ff67f834f1c5c049a1bcd38b2b9`로 `origin/main`에 푸시했다. 이 인계 파일을 추가한 커밋까지 포함한 최신 SHA는 아래 시작 명령으로 다시 확인한다.
- 지도 Canvas 졸라맨은 18개 행동의 관절·시점·소품을 재설계했다. 활동은 정면→왼쪽 옆→오른쪽 옆, 걷기·달리기·일반 이동·버스·선박·자전거는 옆면, 업무는 오른쪽 사선 뒤, 학교·식사·운동은 왼쪽 사선 앞, 취미·미확인은 정면, 수면은 옆면, 차량은 정면이다.
- 업무 모니터 텍스트·키보드 입력, 학교 책장 넘김, 취미 마이크·노래 입 모양, 수면 침대·베개·이불·호흡·Z, 차량 운전대, 선박 난간·물결, 비행기 큰 창·탑승자, 2량 지하철 큰 창·정면 승객·손잡이, 버스 손잡이, 자전거 페달을 포함한다.
- `자가용` 데이터는 지도 렌더링에서 `.car`로 통합했으며 Live Activity의 별도 `privateVehicle` 계약은 유지한다. 예상경로·재생 위치 투영과 12프레임/Reduce Motion 계약도 유지한다.
- 최신 소스 기준 generic iOS Debug build, iOS Simulator `build-for-testing`, `git diff --check`가 통과했다. 사용 가능한 iOS Simulator 기기는 없고, 최종 렌더 세부 패치 후 iPhone 14 Pro 재실행은 잠금 상태로 `deviceprep`에서 차단됐다.
- iPhone 14 Pro `MapHomeStickmanTests` 20/20과 앱 실행은 최종 렌더 세부 패치 전 통과 기록이다. 최종 소스의 실제 화면·터치·18개 동작 시각 확인은 아직 닫지 않는다. 이번 변경에는 archive/upload/TestFlight 실행 기록이 없다.
- 다음 채팅은 먼저 기기 잠금을 해제한 뒤 최신 Debug 앱을 설치·실행하고, 지도 현재/과거 위치·예상경로·재생에서 18개 동작과 경로 이동을 실제 터치·화면으로 확인한다. 그 뒤 로그와 관련 XCTest를 다시 기록한다.

### 새 채팅에서 지킬 범위

- `AGENTS.md`와 `DEVELOPMENT.md`를 먼저 읽고, `temp.md`에 새 요청을 영문·숫자 10자리 ID로 기록한다. 대표님이 `ㄱㄱ` 또는 `전체 진행`이라고 하기 전에는 구현하지 않는다.
- 현재 요청 범위 밖의 UI/UX·지도 제공자·서명·배포 설정은 임의로 바꾸지 않는다. 실기기 설치·실행·화면 터치·HealthKit/Watch·archive/upload·TestFlight 내부 그룹 readback을 서로 다른 게이트로 기록한다.
- 워크트리가 dirty이면 기존 변경을 먼저 보존하고, 새 파일·DerivedData·테스트 결과를 정리할 때는 저장소 증거와 다른 프로젝트 공유 산출물을 삭제하지 않는다.

## 2026-08-28 인계 상태

- 구현 커밋 `b707adf`와 최신 인계 문서가 `main`에 push되었고 현재 워크트리는 clean이다. 다음 채팅에서 위 명령으로 최신 HEAD와 원격을 다시 readback한다.
- 앱은 `com.taption.plan`, 최신 TestFlight 기준 버전 `1.0 (109)`이며 `TP Taption Plan 내부 테스트`에서 `테스트 중`이다.
- 이번 변경에서 generic iOS Debug build와 generic iOS `build-for-testing`, Release archive/export/upload가 성공했다. 서명 Debug 앱 `1.0 (109)`을 iPhone 14 Pro와 Apple Watch SE에, `1.0 (108)`을 iPad Pro에 설치·launch했다. `MapHomeStickmanTests` 16건도 통과했다.
- 최신 iPhone 전체 XCTest는 783건 중 781건 통과했다. 실패 2건은 저장소에 없는 `TaptionPlan/Localizable.xcstrings`와 `.cat-visual-check/cat_sheet_x4.png` fixture다.
- iPad Pro 12.9-inch 전체 XCTest도 783건 중 781건 통과했으며, 동일한 2개 fixture 누락으로 실패했다.
- 누락으로 기록된 두 fixture 테스트는 현재 iPhone·iPad targeted 재실행에서 모두 통과했으며, 전체 재실행 재시도는 로컬 `4FWG8XXYM` iOS Development 인증서·프로파일 부재로 빌드 단계에서 중단됐다.
- 현재 사용 가능한 iOS Simulator가 없고, iPhone 미러링도 기기가 사용 중이라 잠금 전 연결 시간이 초과되어 지도/HealthKit 실제 touch readback은 `test.md`에 미검증 게이트로 남겼다. iPad는 서명 Debug `1.0 (108)` 설치·launch까지 readback했지만 화면·터치는 별도 미검증이다.
- iPhone 14 Pro(CoreDevice `C44AF739-127D-572D-AD83-417C7E879045`, UDID `00008120-00092C3E14F0201E`, iOS 26.6.1)의 현재 설치 앱은 `com.taption.plan`, 버전 `1.0 (109)`이며 이번 서명 Debug 앱으로 갱신·launch했다.
- Apple Watch SE(CoreDevice `9229A9F2-B4F1-5A44-ACFA-0E5B00F3B3AF`)의 현재 설치 앱은 `com.taption.plan.watchkitapp`, 버전 `1.0 (109)`이며 이번 서명 Debug 앱으로 갱신·launch했다.
- build 108은 App Store Connect `제출 준비 완료` 처리 후 `TP Taption Plan 내부 테스트`에 연결했고, 그룹 빌드 화면에서 `1.0 (108) · 테스트 중 · iOS`를 readback했다.
- build 109는 App Store Connect `제출 준비 완료` 처리 후 `TP Taption Plan 내부 테스트`에 연결했고, 그룹 빌드 화면에서 `1.0 (109) · 테스트 중 · iOS`를 readback했다.
- 현재 iPad에는 서명 Debug `1.0 (108)`이 설치·launch되어 있다. TestFlight Distribution IPA 직접 설치는 Beta entitlement 제약으로 별도 미완료다.
- `temp.md`는 현재 비어 있으며, iPhone 미러링 잠금·실제 화면/터치, HealthKit 권한·원본, Watch 지연 동기화, Dynamic Island, IAP 외부 게이트가 `test.md`에 남아 있다.
- DerivedData·xcresult·저장소의 재생성 캐시는 작업 종료 때 삭제했다.

## 반영된 구현

### HealthKit 전체 이력·원본

- `HealthKitTypeCatalog`가 공개 HealthKit 타입군을 카탈로그화하고 타입별 최소 OS·단위·민감도·조회 방식을 관리한다.
- 타입별 anchor와 불변 원본을 파일 보호된 로컬 SQLite에 저장하고, UUID·기간·값·단위·source revision·device·사용자 입력·시간대·삭제 이력을 보존한다.
- 전체 이력은 월 단위 체크포인트로 재개 가능하게 가져오며, observer와 anchored query로 추가·삭제분을 증분 동기화한다.
- HealthKit 원본은 iCloud·CloudKit·위젯 payload·일반 센서 raw export에서 제외한다.
- 운동·수면·명시적 복약/건강 이벤트와 개인 기준선을 충족한 연속 생체값은 비의료 행동 후보로 projection하고 근거 provenance를 유지한다.
- 건강관리 대분류가 시간 레일·색상·위젯 분류에 추가됐다.
- 실기기에서 표준 권한 요청에 vision prescription·blood pressure correlation·food correlation을 함께 넘기면 `NSInvalidArgumentException`으로 종료되는 문제를 수정했다. correlation은 구성 quantity 타입 권한을 사용하고 vision prescription은 per-object authorization 경로를 사용한다.

### 지도·경로·센서

- MapLibre Native와 OpenFreeMap 벡터 소스를 사용한 `벡터 야간`, `벡터 밝은 지도`, `벡터 고대비`, `벡터 파스텔` 스타일이 지도 스타일 선택에 추가됐다.
- 벡터 지도는 라벨·상점 POI를 제외하고 건물·도로·물·토지, 노란 경로, 삼각형 플레이어, 기존 위치·장소·대중교통 annotation overlay를 표시한다.
- 실제/예상/지하철 경로와 플레이헤드 위치·방향·추적/팬/줌 상태를 MapLibre에서도 유지한다.
- raw 위치의 자정 경계·선택일 구간 조회와 지하철 GPS 공백의 예상 경로 projection을 보강했다. 확정 선로는 정본으로 우선하고 추정 경로는 점선으로 구분한다.
- `BCH828STK1`/`STK828M5Q2`에서 하단 팝업 스티커 메뉴를 복구하고, 지도 메모를 `전부 보기`/`해당되는 것만 보기`로 필터링한다. 스티커는 지도·일정에 각각 추가할 수 있으며, 스티커 모드에서 지도 스티커와 지도 메모를 탭해 위치·시간·내용을 수정하거나 삭제할 수 있다. 저장 스냅샷·Cloud tombstone·구버전 메모 decode를 보강했다.
- 센서 day-store 원본과 월별 raw archive, iCloud에서 제외되는 로컬 원본 정책을 유지한다.
- 3분 이상 체류한 등록 위치·MapKit 주변 5종 교통 후보에 물음표와 탑승/삭제 메뉴를 제공하고, 삭제 결정은 장소 종류·좌표·체류 구간으로 근방 재생성 후보까지 억제한다.
- `MAP28FIXQ1`에서 MapKit POI 이름·식별자·좌표·도착 분이 바뀌어도 삭제 후보를 억제하고, 100m 이내 인접 후보를 함께 숨기도록 보강했다. MapLibre viewport는 최신값 coalescing, transient overlay, 후보 presentation cache로 부모 전체 재평가를 줄이며 지도 계산은 최대 60Hz, 부모 readback은 15Hz로 제한한다.

### 졸라맨 자연스러운 동작

- 18개 행동의 관절을 IK로 연결하고, 보행 접지·스윙·달리기 체공·골반 이동·팔/다리 반대 위상·자전거 페달 위상을 적용했다.
- 기존 진분홍 단색, 둥근 선, 64×56 좌표계, 소품과 렌더러 인터페이스는 유지한다.

### 졸라맨·사이드바·위젯

- 지도 졸라맨은 모든 annotation보다 앞에 표시하고 사이드바 핸들에서는 제거했다.
- 대분류와 이동 상세별 졸라맨/소품 애니메이션, 걷기 배경 이동, Dynamic Island/Live Activity 표현과 재현 기준은 `STICKMAN_ANIMATION_GUIDE.md`에 정리돼 있다.
- 날씨는 사이드바에 붙여 표시하고, 시간 핸들 및 대분류 색상·건강관리 색상과 위젯 표현을 통합했다.
- 고빈도 사이드바 입력은 최대 60Hz 렌더 예산으로 합치고 제스처 종료 최종값은 즉시 반영한다.

## 아직 실기기에서 확인할 항목

1. `HLTH28P7Q4`: iPhone에서 새 HealthKit 권한 시트와 vision prescription per-object 선택을 직접 완료한 뒤 전체 이력 진행률·원본 건수·source/device provenance를 읽는다.
2. 페어링 Apple Watch 데이터의 지연 도착, 백그라운드 observer 전달, 재실행 후 anchor 증분 동기화를 실기기에서 확인한다. Watch가 offline이면 완료로 처리하지 않는다.
3. `SLEEP827B2`: 2026-08-27 07:15 전후 HealthKit 수면 원본 종료 시각과 걸음/화면 사용 근거를 앱 진단 경로에서 대조한다. 확인되지 않은 휴대폰 터치 시각을 수면 원본으로 만들지 않는다.
4. `NXT27AUG01`: Dynamic Island compact/expanded, 재생·사이드바 실제 터치, 졸라맨 최전면, MapLibre 4개 스타일, 지하철 확정/예상 경로를 iPhone 화면에서 수동 확인한다.
5. `IAP73PAID1`은 Paid Apps Agreement·세금/은행·상품 연결·Sandbox 구매/복원 전까지 완료 처리하지 않는다.
6. `STK28NAT9Q`: iPhone에서 18개 졸라맨 동작의 렌더링·전환을 실제 화면으로 확인한다.

새 요청은 영문·숫자 10자리 ID로 `temp.md`에 먼저 기록하고, 대표님의 `ㄱㄱ` 또는 `전체 진행` 승인 뒤 실행한다. 완료된 항목만 큐에서 제거한다.
