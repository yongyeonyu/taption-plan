# 검증 기록

현재 실행 근거만 간결하게 유지합니다. 이전 상세 개발·검증 기록은 Git 이력에 보존했습니다. `build/validation/`은 로컬 증거이며 Git에 포함되지 않습니다.

## HOF0926A01 · Kiro → Codex UI 인계 확인 (2026-09-26)

- `AGENTS.md`, 최신 `temp.md`, 관련 `test.md`, `CODEX_HANDOFF.md` 및 Git 이력을 대조했다. 기존 CODEX_HANDOFF.md의 35커밋·빌드 156·push 지시는 과거 스냅샷이며 이번 실행 지시로 사용하지 않았다.
- 시작 당시 main HEAD는 `1e283ec08e6d9d3588fe75272511f060e2330f42`, origin/main과 서버 main은 `07e848f24c1d103037666d72a2ab8cd5b93771d6`이었다. `git rev-list --left-right --count origin/main...HEAD` 결과 `0 58`로 전체 미push 58개를 확인했다. 전달된 UI 커밋 목록은 그 일부였다.
- 인계 확인 중 다른 작업에서 `520075e`·`c5e9dbb` 커밋이 추가됐다. 이후 HEAD·origin/main·`git ls-remote --exit-code origin refs/heads/main`의 서버 main이 모두 `c5e9dbbe39f8f5e43ee2a47a8cf43971d911d57b`로 일치했고 비교 결과는 `0 0`이었다. 따라서 최종 확인 기준 미push 커밋은 0개다. 이 세션에서 커밋·push를 실행한 것은 아니다.
- 시작 당시 앱·위젯의 `Localizable.xcstrings`, temp.md·test.md가 수정됐고 `.kiro/`, CODEX_HANDOFF.md가 미추적이었다. 기존 작업은 되돌리지 않았다. 다른 작업에서 해당 변경을 커밋했고, 이번 세션의 후속 변경 범위는 temp.md·test.md 인계 기록이다.
- `TaptionPlan.xcodeproj/project.pbxproj`의 `CURRENT_PROJECT_VERSION` 8곳은 모두 157이다. 이는 소스 설정 확인이며 기기 설치본이나 TestFlight 상태 확인은 아니다. `git diff 1e283ec..HEAD -- TaptionPlan/UI/MapHomeView.swift TaptionPlan.xcodeproj/project.pbxproj`는 비어 있어 동시 커밋에서 두 파일이 바뀌지 않았음을 확인했다.
- `MapHomeView.swift` 소스 대조: historical=`timelineRouteOverlays.dropLast()`, active=`last`, 발자국 입력은 전체 overlays다. `makeTimelineRouteOverlays`는 확정 지하철과 유효좌표 2개 미만을 제외한다. `fmap_route_projection`의 `dropped_short`는 유효성 검사 전 좌표 수를 세므로 필터 후 부족한 경우를 전부 집계하지 못한다. FMAP 원인은 아직 확정하지 않았다.
- FMAP0926R06·PAW0926T05 실기기 확인, HUD0926M08 통합 방식·지표 결정은 열린 상태다. 전달된 시간 카드 높이·화랑이 직접 탭·최신 UI 실기기 확인을 각각 TIM0926C01·CAT0926T01·UIV0926A01로 temp.md에 기록했다. 기존 완료 표시 항목의 구현은 반복하지 않았다.
- 문서 변경의 `git diff --check -- temp.md test.md`를 통과했다. 확인을 마친 HOF0926A01만 temp.md에서 제거하고 실기기·설계 대기 항목은 유지했다.
- 제한: 이 세션에서 앱 소스 변경·새 빌드·테스트·설치·실기기 영상 판독·ASC 조회는 수행하지 않았다. 기능 검증을 완료했다고 보고하지 않는다.

## SEP0926A01 · TaptionPlan 인계 프로토콜 및 main 정리 (2026-09-26)

- 대상 변경은 `temp.md`, `test.md`, 신규 `CODEX_HANDOFF_20260926.md` 세 파일이다. ShotGuide 및 앱 소스는 수정하지 않았다.
- `git diff --check` 통과. 앱·위젯 `Localizable.xcstrings` JSON 파싱 통과. 시작 시 `HEAD`/`origin/main`/서버 main은 `c5e9dbb`, ahead/behind `0/0`이었다.
- 기존 인계가 지목한 `build/validation/GIT0926P01/build-final.log`는 존재하지 않았다. 대신 고정 DerivedData `build/ArchiveDD`로 Debug 빌드를 실행해 `build/validation/GIT0926P01/build-sep0926a01.log`에서 `** BUILD SUCCEEDED **`, 종료 코드 0을 확인했다. 매크로 검증 스킵 및 `-Xfrontend -disable-sandbox` 플래그를 사용했다.
- 앱 소스 변경이 없는 문서 정리이므로 단위 테스트와 실기기 검증은 실행하지 않았다. 기존 UI·센서·백업의 실기기 대기 상태는 temp.md에서 유지한다.
- 커밋 `3cf1717` push 성공: `c5e9dbb..3cf1717 main -> main`. `git ls-remote origin refs/heads/main`의 readback은 `3cf1717ea03ebc2f453759ca1fb38847e3899bb2`다.
- push 뒤에 이 검증 기록을 정리하면서 생긴 후속 기록 커밋도 별도 push하고, 최종 HEAD·원격 main·워크트리 상태를 다시 확인한다.

## BAK0922I01 · 백업 복호 실패 시 새 아카이브 재봉인 (2026-09-23, A안)

- 로그 확정(9/22): `icloud_backup_automatic` 반복 실패 — error_code 4(invalidArchive)/6(accountUnavailable), 동시각 `cloud_account_status`는 전부 authorized. 계정은 정상, 기기 이전 키 불일치가 원인.
- 원인: `PlanMonthlyArchivePreparation.prepare`가 같은 달 기존 아카이브를 병합하려 PIN키→계정키로 복호 시도, 둘 다 실패(iPhone 14 키로 봉인) 시 invalidArchive throw → 매 백업 실패.
- 수정(A안): 두 키 모두 복호 실패 시 병합을 건너뛰고 이번 기기 데이터를 이번 기기 키로 새로 봉인해 저장(inheritedGenerationID=nil). accountMismatch는 그대로 throw, load 시 tamper/무결성 검증 불변. 스키마 변경 없음. 옛 아카이브는 이번 기기에서 어차피 복호 불가라 복구 가능 데이터 손실 없음. 스냅샷·raw 두 경로 공통(prepare 3675·3940).
- 검증: `TaptionPlanTests/SecurityBackupCoreTests` 103/103 PASS(신규 `testUndecodablePreviousArchiveResavesFreshInsteadOfFailing` 포함 — 다른 키로 봉인된 이전 아카이브가 있어도 새 백업 성공+새 키로 재복호 확인). tamper 테스트(invalidArchive 기대) 불변. 증거: `build/validation/BAK0922I01/backup-tests-r2.xcresult`.
- 한계: 시뮬 검증. 실기기에서 대표님이 PIN 입력 후 iCloud 백업 성공 전환·그룹 노출 확인 필요.

## GPS0922J01 · sparse-connection 불가능속도 차단 (2026-09-23)

- 로그 확정(9/22): 점프는 forecast가 아니라 actual leg 열(projection_actual_movement_count=890, forecast_same_endpoint_pairs=0). actual leg 생성은 연속 reading쌍을 `RouteSparseConnectionPolicy.breaksConnection`으로만 걸러왔다.
- 원인: `breaksConnection`이 gap>5분 AND 거리>1km 일 때만 끊어, **gap이 5분 이하이면 아무리 멀어도(회사↔집) 연결**돼 재생 시 직선 점프가 생겼다.
- 수정: `RouteSparseConnectionPolicy.breaksConnection`에 불가능속도 규칙 추가 — 거리/gap > 55m/s(≈198km/h, 라우트 필터 unknown-mode 상한과 동일)이면 gap 길이와 무관하게 끊는다. 기존 두-임계 규칙은 유지. 원본 raw는 보존, 파생 재생 leg만 영향.
- 검증: 패키지 `TaptionRouteEngine` 39/39 PASS(+1 신규 `sparseConnectionBreaksOnImpossibleSpeedWithinShortGap`, 기존 `sparseConnectionBreaksOnlyPastBothThresholds` 불변). 증거: swift test 로그.
- 한계: 시뮬/유닛 검증. 실기기에서 9/22 같은 날 재생 시 점프가 사라지는지 확인 필요.

## SLP0922S01 · 워치리스 수면 게이트 완화 (2026-09-23)

- 로그 확정: iPhone 18 진단 패키지 TaptionLogs-20260923-014921(9/20~9/22)에서 `sleep_inference_completed` 61회 전부 `reason=conditions_or_continuity_not_met` — 워치리스 경로가 매 윈도 실행됐으나 보조조건 게이트에서 전량 탈락.
- 수정(2파일, `TaptionActivityEngineAdapter.strictSleepActuals`만): (1) homePoint 있을 때 `minimumSupportingConditions`를 3→2로. (2) `ambientIsDark`가 밝기 nil(화면 꺼짐)이면 화면 꺼짐 자체를 어두움 근거로 인정(`?? (screenIsOn==false ? true : nil)`). 공유 `SleepInferenceEngine` 게이트·기본 config는 미변경(기존 동작 보존).
- 검증: 패키지 `TaptionActivityEngine` 33/33 PASS(`testSleepDoesNotInferWithOnlyTwoSupportingConditions`·`testSleepRequiresCoreAndAllSupportingConditionsForFiveMinutes` 포함 — 엔진 기본 동작 불변 확인). 앱 `TaptionPlanTests/TaptionActivityEngineAdapterTests` 26/26 PASS, 신규 회귀 2건 포함: `watchlessSleepFiresWhenScreenOffAtHomeWithoutCharger`(무충전·화면꺼짐·집=수면 생성), `watchlessSleepStaysEmptyWhenPhoneIsUsedAndMoving`(이동·화면켜짐=수면 아님, 과확정 방지). Xcode 27 매크로 플러그인 오류는 `-skipPackagePluginValidation -Xfrontend -disable-sandbox`로 회피. 증거: `build/validation/SLP0922S01/adapter-tests-r2.xcresult`.
- 한계: `CODE_SIGNING_ALLOWED=NO` 시뮬 빌드라 실기기 설치·실제 취침 데이터 표시는 별도 검증 필요. 실기기 재현(무충전 야간 취침 후 수면 표시)으로 최종 확인해야 함.

## KIR0923A01 · 2026-09-23 Kiro 인수인계 준비

- 환경: Apple Silicon arm64, macOS 26.6.2 (25G83), Xcode 27.0 (27A266a), Swift 6.4. 프로젝트 언어 모드 6.0, iOS 18/watchOS 11 이상, 네 번들 버전 1.0(149).
- 기존 구현·회귀·개발 기록을 `a8e3d5c` 커밋으로 보존하고 `KIRO_HANDOFF.md`에 환경·명령·아키텍처·다음 개발 범위를 통합했다.
- 삭제: `DEVELOPMENT.md`, `NEXT_CHAT_PROMPT.md`, `plan.md`, `design-qa.md`, `STICKMAN_ANIMATION_GUIDE.md`, `SENSOR_FUSION_SOURCES.md`, `ui-draft-iphone.html`.
- 유지: `AGENTS.md`, README, 지원·개인정보 문서, 미완료 요청과 이번 검증 기록. 기존 로컬 전용 `temp.md`는 미완료 항목을 압축해 인수인계 자료로 함께 추적한다. `.codex/`·`.workbuddy-ai/`는 로컬에 보존하고 Git에서 제외했다. 사용자 데이터·기존 빌드 증거·다른 프로젝트 작업은 삭제하지 않았다.
- 기준 파일 281개 중 276개는 SHA-256이 동일하다. 검증에서 발견한 아래 비일자 snapshot 호환 회귀의 최소 수정 5개 파일만 변경했다. 문서·`.gitignore`는 정리 대상이라 이 비교에서 제외했다. 증거: `build/validation/KIR0923A01/preservation-check.json`.
- README/인수인계의 로컬 링크, 문서 내 shell 예제 구문, 앱 엔진 import 경계와 `git diff --check` 통과. 원격 fetch 시 기존 main은 origin/main과 일치했으며 새 브랜치는 만들지 않았다.
- 최종 검증: 패키지 Core 99/99·Activity 33/33·Route 38/38·facade 1/1 PASS(총 171), 앱 전체 1,344 PASS·기존 StoreKit 1 SKIP·0 FAIL·runtime warning 0. StoreKit 스킵은 iOS 26.5 Simulator의 SKInternalErrorDomain Code 3 제한이다.
- 최종 iOS·watchOS generic device Debug 빌드 모두 PASS, error/warning/analyzer warning 0. `CODE_SIGNING_ALLOWED=NO` 빌드이므로 서명·실기기 설치 검증을 뜻하지 않는다.
- 실행 증거: `build/validation/KIR0923A01/TaptionPlanCore-final.log`, `TaptionActivityEngine.log`, `TaptionRouteEngine.log`, `TaptionPlanEngine-final.log`, `app-tests-r3.xcresult`, `ios-debug-r3.xcresult`, `watch-debug-r3.xcresult` 및 각 summary JSON.
- 소스·인수인계 정리 커밋 `881d433b111e8e411e6cd8535e195c8dc79e2dc2`를 main에 푸시한 뒤 HEAD·origin/main·서버 refs/heads/main 일치와 빈 `git status --porcelain=v1`을 확인했다. 이 완료 증거에 따라 `KIR0923A01`을 요청 큐에서 제거했다.

## HKD0923A01 · HealthKit·계획 저장소의 비일자 snapshot 호환

- 최초 전체 실행에서 `HealthKitImportStore`가 기존 `0000-00-00` snapshot을 조회할 때 Core의 강화된 날짜 검증이 `invalidDay`를 반환했다. 동기화 gate 진입 전 실패해 후속 테스트도 대기했다. 최초 결과는 673 PASS·1 SKIP·4 FAIL(직접 오류·시간초과·후속 오류·중단 포함), exit 75이며 통과 결과로 사용하지 않는다: `build/validation/KIR0923A01/app-tests.xcresult`.
- `TaptionPlanDayStore`에 기본 false인 비일자 snapshot 허용 옵션을 추가하고 HealthKit 저장소와 SQLite 계획 저장소만 명시적으로 사용한다. 기존 SQLite 키·payload·anchor·revision·원자적 event/checkpoint 갱신은 유지하며 스키마 migration은 하지 않는다. event·map·V3 및 일반 저장소 날짜 검증은 유지한다.
- 새 회귀는 기존 SQLite row의 읽기, event/checkpoint 갱신 후 재열기, 일반 저장소 기본 거부, 비일자 event/map·부분 무효 날짜 거부를 검사한다.
- HealthKit 집중 35/35 PASS. 중간 전체 실행은 계획 저장소의 같은 키 호환 누락으로 1,331 PASS·1 SKIP·13 FAIL이었다. 소비자와 직접 readback하는 테스트를 수정한 뒤 최종 전체 1,344 PASS·1 SKIP·0 FAIL 및 iOS/Watch Debug 빌드로 저장·재열기·revision·Watch summary ACK 경로까지 통과했다. 완료 항목을 요청 큐에서 제거했다.

## 선행 실기기 증거와 아직 남은 검증

- 2026-09-22 iPhone의 날짜·지도 재생 입력, 9/9 항공 경로 readback 및 일부 실제 저장 재열기는 기존 기록에서 확인됐다. 같은 날 iPad Debug 설치·실행은 첫 권한 화면까지 확인했고 후속 UX는 미완료다. 이전 전체 테스트 통과 수를 이번 최종 소스의 전체 검증으로 재사용하지 않는다.
- 2026-09-23 iPhone 18 Pro Max 대상 profile을 포함한 Debug 149 설치·foreground 실행과 약 1분 app/widget 생존, 새 OS crash report 없음이 기록됐다. 이는 TestFlight 설치나 정확한 9/9 장시간 CPU workload 완료가 아니다: `build/validation/HAR0922A01/device-targeted-build.xcresult`, `device-targeted-install.json`, `device-targeted-processes.json`.
- Watch는 paired/developer mode enabled 상태에서도 tunnel disconnected/timeout이었다. 실제 강제 종료 후 재전송·ACK/receipt 전환·HealthKit 삭제는 미검증이다.
- WeatherKit capability·entitlement와 대상 기기 profile은 확인했으나 실제 provider/401 해소 로그는 없었다. iCloud 실제 PIN 복원·다중 기기 경합, 장시간 CPU/file-lock workload도 별도 남아 있다.
- 마지막 배포 기록은 2026-09-13 TestFlight 149의 처리·`TP Taption Plan 내부 테스트` 그룹 빌드·테스터 노출 확인이다. 그 이후 코드와 이번 정리는 새 TestFlight 업로드가 아니다. 이번에는 ASC live 조회·실기기 설치·실제 판매 작업을 수행하지 않았다.

## GIT0926P01 — 워크트리 정리 및 main push (2026-09-26)
- 사용자 승인: 두 프로젝트 기존 변경 보존 후 main 커밋·push.
- 사전 확인: `git fetch origin`, `git status --short`, `git rev-list --left-right --count origin/main...HEAD`; 원격 전용 커밋 0개. JSON 문자열 카탈로그·Kiro 설정, plist, scheme XML 파싱 통과.
- 실행 명령: `xcodebuild build -project TaptionPlan.xcodeproj -scheme TaptionPlan -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath build/ArchiveDD -skipPackagePluginValidation COMPILER_INDEX_STORE_ENABLE=NO OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox'`.
- 최초 빌드는 디스크 부족으로 실패. `xcodebuild clean`도 공간 부족으로 실패하여 알려진 로컬 DerivedData의 재생성 가능한 중간파일·모듈캐시·인덱스만 정리. 소스, Logs, xcresult, SourcePackages, 배포 archive/export는 보존.
- 런타임 `.kiro/settings/.kirocrew-cli-settings.lock`은 파일 유지 후 `.git/info/exclude`로 로컬 제외. 그 외 기존 변경 파일은 커밋 대상으로 보존.
- 산출물: `/Users/u_mo_c/Documents/taption plan/build/validation/GIT0926P01/`; 실기기 기능 검증은 수행하지 않음.
- 최종 앱타깃 빌드: `build/validation/GIT0926P01/build-final.log`의 BUILD SUCCEEDED, 종료 0 확인. push 및 원격 HEAD/clean readback은 같은 폴더 `git-readback.txt`에 기록.
