# Taption Plan 실기기 검증 큐

구현·빌드·업로드·설치·실행·실제 화면 터치는 서로 다른 게이트로 기록한다. 설치·실행만으로 UI 동작을 완료 처리하지 않는다.

## 2026-08-30 RELWSYNC2A · Apple Watch 동기화 수정 릴리스

- 변경: Watch의 수동 동기화가 로컬 센서·HealthKit drain과 대기 큐 전송을 수행하고, iPhone의 Watch v3 병합 실패는 `watch_day_database_merge_failed` 진단 이벤트로 남긴다. 원본 데이터·provenance는 변경하지 않았다.
- 자동 검증: `swift test --package-path Packages/TaptionPlanCore` 36/36 통과. 직렬 Plan 전체 XCTest 824/824 통과, 결과 bundle `/private/tmp/taption-plan-relsync2a-ios-serial.xcresult`. iOS·Watch Debug build exit 0, `git diff --check` 통과. 병렬 실행에서만 공유 시뮬레이터 상태로 `testActivitySectionSaveOverridesTravelAndSupportsImmediateReedit`가 3회 실패했고, 동일 테스트 직렬 실행 및 직렬 전체 실행은 통과했다.
- Release archive/export: `/private/tmp/taption-plan-relsync2a-v117.xcarchive`, `/private/tmp/taption-plan-relsync2a-v117-export/TaptionPlan.ipa`; IPA `com.taption.plan / 1.0 / 117`, `unzip -t`·`codesign --verify --deep --strict` 통과, SHA-256 `3a1eea30bd7bc7fcdfde2bd7bc8135da4f472be416987fc56ffb548acc745e65`.
- TestFlight: 업로드 성공. Delivery UUID `40d3c4ec-d471-4d0e-bc06-6bd4117610d5`; build `117`, processing `VALID`, audience `APP_STORE_ELIGIBLE`, App Store Connect 등록 확인.
- 내부 테스트 readback: `TP Taption Plan 내부 테스트` 그룹 `b4857e5e-d1ff-4bc2-b9ad-a69bcd4603fd`가 internal group으로 확인됐고, 그룹 builds 목록에 build `117`이 `VALID`로 노출됐다. 그룹 테스터 화면 1명, state `INSTALLED` 노출을 확인했다.
- 커밋·원격: 구현 커밋 `1edd1007f556775bed29429521e0a7c5eb7eef29` 후 증거 문서 커밋을 추가했으며, 최종 SHA는 문서 커밋 후 readback한다. Plan worktree와 WBS checkout의 기존 dirty 변경은 보존한다.
- 실기기 게이트: 이번 요청은 TestFlight 빌드업 범위이며 iPhone 14 Pro·Apple Watch 설치·실제 화면·터치는 수행하지 않았다. 등록된 실기기는 `unavailable` 상태이므로 해당 게이트는 미완료로 유지한다.

## 2026-08-30 WSYNC83022 · Apple Watch 동기화 점검

- 원인: Watch 화면의 `지금 가져오기`가 Watch 센서/HealthKit drain을 호출하지 않고 iPhone 설정 payload 재전송(`refreshRequest`)만 수행했다. 또한 iPhone v3 Watch 병합 오류가 `try?`로 조용히 버려져 원인 확인이 어려웠다.
- 수정: 수동 동기화가 Watch의 `syncNow()`를 실행하고, 대기 중인 센서·건강 큐를 즉시 재전송하도록 연결했다. iPhone의 Watch v3 병합 실패는 `watch_day_database_merge_failed` 진단 이벤트로 남긴다. Watch 원본 데이터와 provenance는 변경하지 않았다.
- 자동 검증: `TaptionPlanWatch` Debug watchOS Simulator build exit 0, Plan 전체 XCTest 824/824 통과, `git diff --check` 통과.
- 실기기 게이트: `xcrun devicectl list devices`에서 등록된 iPhone 14 Pro·Apple Watch SE·iPad가 모두 `unavailable`이라 실제 Watch 동기화·수신 날짜·원본 readback은 확인하지 못했다. 추정으로 완료 처리하지 않는다.

## 2026-08-30 REVUP83021 · 다방면 코드리뷰 및 릴리스 준비

- 리뷰 수정: legacy JSON/v2 원본의 strict read가 손상·누락·동일 ID 충돌을 조용히 버리지 않고 fail-closed하도록 보강했다. SQLite v3 materialized raw count overflow도 거부한다.
- 리뷰 수정: Watch raw 저장 실패 시 WatchConnectivity 전송을 진행하지 않고 재큐하며, Watch 수신·legacy migration provenance를 동일하게 맞춰 저장 중 migration 경합에서 payload conflict가 나지 않게 했다.
- 리뷰 수정: 날짜 coordinator의 in-flight 요청에 토큰을 붙여 취소된 이전 작업이 새 작업을 제거·캐시하지 못하게 했고, 월 prefetch 취소가 현재 load까지 전달되게 했다. DB/day query·decode·projection signpost는 예외 시에도 종료된다. legacy archive가 준비되지 않으면 migration을 시작하지 않는다.
- `swift test --package-path Packages/TaptionPlanCore`: 36/36 통과.
- Plan focused XCTest(`SensorDayStoreTests`, `TimeScaleTests`, `SQLitePlanRepositoryTests`): 149/149 통과. 결과 bundle: `/private/tmp/taption-plan-revup83021-focused-3.xcresult`
- Plan 전체 XCTest: 824/824 통과, 실패·스킵 0. 결과 bundle: `/private/tmp/taption-plan-revup83021-full.xcresult`
- Debug 통합 빌드: `xcodebuild -quiet -project TaptionPlan.xcodeproj -scheme TaptionPlan -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build` exit 0.
- Debug 산출물 readback: iOS `com.taption.plan / 1.0 / 116`, Watch `com.taption.plan.watchkitapp / 1.0 / 116`, Watch Widget `com.taption.plan.watchkitapp.widget / 1.0 / 116`.
- Release archive/export: `/private/tmp/taption-plan-revup83021.xcarchive`, `/private/tmp/taption-plan-revup83021-export/TaptionPlan.ipa`; bundle `com.taption.plan / 1.0 / 116`, export 서명 Apple Distribution, `codesign --verify --deep --strict` 통과, IPA SHA-256 `071417e1e551baee7d87f693fe18d840391137670e147fdcab979c38e398aa01`.
- TestFlight 업로드: 성공. Delivery UUID `d73bcf5e-ecda-41a9-984b-aa7e6d3f1ccf`; `altool --build-status` 및 App Store Connect API readback에서 build `116`, processing `VALID`, audience `APP_STORE_ELIGIBLE`, `IS-ON-APP-STORE-CONNECT: true`.
- 내부 테스트 readback: `TP Taption Plan 내부 테스트` 그룹 `b4857e5e-d1ff-4bc2-b9ad-a69bcd4603fd`의 builds 관계와 builds 화면에 build `116` 노출 확인. 그룹 테스터 1명, state `INSTALLED` 확인.
- 커밋·원격: `b3e4d5a3654001fc969a28e71dc90fece025b337`가 local `HEAD`와 `origin/main`에 동일하고 Plan worktree clean.
- `git diff --check`: 통과. WBS checkout `/Users/u_mo_c/Documents/Taption WBS`는 기존 dirty `temp.md`만 보존했고 수정하지 않았다.
- 아직 확인하지 않은 외부 게이트: iPhone 14 Pro 실기기 touch/실행, Apple Watch 원본·동기화, 목요일 재생·지도 비율·WBS 스타일·Dynamic Island, cold/warm p95와 실제 signpost 집계. TestFlight 처리와 내부 그룹 노출은 위 API/readback으로 완료했다.

## 2026-08-30 DBRUN83019 · DBIMP83020 날짜 로딩 DB 최적화

- SQLite v3 자동 검증: `swift test --package-path Packages/TaptionPlanCore` 36/36 통과. 날짜·디바이스·timestamp/sequence/id 인덱스와 `EXPLAIN QUERY PLAN`, append-only 중복/충돌, provenance digest, materialized 교체, v2 읽기 전용 거부·sidecar 미생성 테스트를 포함한다.
- Plan focused XCTest: `SensorDayStoreTests`, `TimeScaleTests`, `SQLitePlanRepositoryTests` 148/148 통과. 결과 bundle: `/private/tmp/taption-plan-dbimp83020-focused-3.xcresult`
- Debug 통합 빌드: `xcodebuild -quiet -project TaptionPlan.xcodeproj -scheme TaptionPlan -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build` exit 0. 산출물은 `/Users/u_mo_c/Library/Developer/Xcode/DerivedData/TaptionPlan-gvqtjbpzkfvutrdlxdzhdyhsyane/Build/Products/Debug-iphonesimulator/TaptionPlan.app`, `Debug-watchsimulator/TaptionPlanWatch.app`, `Debug-watchsimulator/TaptionPlanWatchWidget.appex`에 생성됐다.
- 산출물 readback: iOS `com.taption.plan / 1.0 / 115`, Watch `com.taption.plan.watchkitapp / 1.0 / 115`, Watch Widget `com.taption.plan.watchkitapp.widget / 1.0 / 115`.
- 저장 경계: iPhone·Watch SQLite v3를 분리하고 raw/provenance는 append-only로 유지한다. 구 JSON/v2 SQLite는 읽기 전용 재구축 입력으로만 사용하며, migration 성공 전 materialized row를 활성화하지 않고 재검증 실패 시 fail-closed한다. 구 DB와 임시 백업은 삭제하지 않았다.
- 로드 경계: `PlanDayLoadCoordinator`가 `day_key + source_revision + projection_version`으로 snapshot을 공유하고 동일 날짜 coalescing, 최신 요청 취소, 월 프리패치, bounded LRU/메모리 압력 축출을 수행한다. 로딩 중 기존 화면은 유지하고 상태를 표시한다.
- `git diff --check`: 통과. WBS checkout `/Users/u_mo_c/Documents/Taption WBS`의 기존 dirty `temp.md`와 소스 변경은 건드리지 않았다.
- 미측정: iPhone 14 Pro cold p95 `≤500ms`, warm p95 `≤50ms` 수치와 실제 `os_signpost` 집계. 실기기에서 v3 migration/readback, Watch raw/provenance·동기화, 목요일 재생·졸라맨, 지도 비율, 핸들·롱프레스, WBS 스타일·Dynamic Island는 확인하지 않아 미완료로 유지한다.

## 2026-08-30 BTCH830Q16 · temp.md 전체 실행 자동 검증

- `SENS830Q14`: `ActivitySensorEvidenceFusion`이 겹치는 Watch+iPhone evidence를 하나의 결합 projection으로 만들고 Watch 행동·confidence를 우선한다. `ActivityClassificationProjection`은 version 1과 기존 9개 major ID만 허용하며 invalid major를 `activity`로 파생 정규화하고 locked override를 보존한다. Plan adapter는 이동 알고리즘 결과가 없는 Watch 이동수단 hint를 major/detail로 확정하지 않는다.
- `WBSI830Q08`: `RoutePlaybackProjection`이 누적거리 보간, 1% look-ahead 8방향, `floor(progress × 24)` frame index, 동일 route/marker coordinate를 제공하고 잘못된 좌표를 파생 projection에서 제외한다.
- `swift test --package-path Packages/TaptionActivityEngine`: 6건 통과.
- `swift test --package-path Packages/TaptionRouteEngine`: 14건 통과.
- `swift test --package-path Packages/TaptionPlanCore`: 30건 통과.
- `xcodebuild test ... -only-testing:TaptionPlanTests/TaptionActivityEngineAdapterTests`: 10건 통과. 결과 bundle: `/private/tmp/taption-plan-btch830q16-uit30-tests/Logs/Test/Test-TaptionPlan-2026.08.30_12-20-02-+0900.xcresult`
- 잠금 분류 보강 후 동일 adapter XCTest 재실행: 10건 통과. 결과 bundle: `/private/tmp/taption-plan-btch830q16-final-tests3/Logs/Test/Test-TaptionPlan-2026.08.30_12-31-47-+0900.xcresult`
- 관련 지도·재생·사이드바·졸라맨·분류 회귀 XCTest: 최종 소스에서 688건 통과. 결과 bundle: `/private/tmp/taption-plan-btch830q16-regression-final.xcresult`
- 현재 소스 Debug 빌드: iOS `/private/tmp/taption-plan-btch830q16-ios-build2/Build/Products/Debug-iphoneos/TaptionPlan.app`, Watch `/private/tmp/taption-plan-btch830q16-watch-build2/Build/Products/Debug-watchos/TaptionPlanWatch.app`, Watch Widget `/private/tmp/taption-plan-btch830q16-watch-build2/Build/Products/Debug-watchos/TaptionPlanWatchWidget.appex`; 모두 `1.0 (115)` readback.
- `git diff --check`: 통과. WBS checkout 상태는 기존 `TaptionTripUITests/TaptionTripUITests.swift`, `temp.md` dirty를 그대로 보존했다.
- 원본 보호: iPhone·Apple Watch SensorReading과 provenance 저장 모델은 수정하지 않고 복사 기반 evidence/projection만 추가했다. WBS checkout도 수정하지 않았다.
- 실기기 게이트: iPhone 14 Pro·Apple Watch의 provenance/실제 화면, 목요일 경로 재생·졸라맨·지도 비율·좌우 핸들·Dynamic Island는 이번 실행에서 확인하지 못해 미완료로 유지한다.

## 2026-08-30 MAPM830Q15 · 지도 롱프레스 추가 메뉴

- 변경: Apple MapKit 및 호환 벡터 지도 롱프레스에서 `위치 추가`와 `스티커 메모 추가` 선택 메뉴를 표시한다. 위치는 기존 위치 추가 sheet로, 스티커 메모는 롱프레스한 좌표로 기존 편집 sheet에 연결한다.
- 메모 모드: 햄버거 메뉴의 `메모 모드` 토글을 제거하고 지도 스티커 선택·편집을 항상 활성화했다. 기존 메모 데이터와 저장 형식은 변경하지 않았다.
- 자동 검증: `TimeScaleTests.testMapLongPressOffersLocationAndStickerMemoActions` 및 `TimeScaleTests` 전체 통과. `git diff --check` 통과.
- 실기기 게이트: iPhone에서 실제 롱프레스·메뉴 선택·위치 저장·스티커 좌표 저장 화면은 이번 실행에서 확인하지 못해 미완료로 남긴다.

## 2026-08-30 SLPW830Q13 · Apple Watch 확정 수면 우선·졸라맨 행동

- 변경: `SleepSession`의 Apple Watch provenance와 실제 수면 시간으로 불변 파생 확정 상태를 만들고, HealthKit에서 파생된 수면 ActualRecord source도 `.appleWatch`로 보존했다. 지도 졸라맨은 확정 수면을 이동 경로·센서·재생 모드보다 먼저 `.sleeping`으로 표시하며, 명시적 수동 수정은 유지한다.
- 원본 보호: iPhone·Apple Watch raw record, HealthKit source metadata, provenance payload는 수정하지 않았다.
- 자동 검증: `MapHomeStickmanTests` 전체 통과, `FeatureEngineTests` 전체 통과, `TimeScaleTests` 전체 통과. Apple Watch 수면이 지하철 경로보다 우선하고 `.sleeping`으로 매핑되는 테스트와 iPhone-only sleep 비우선 테스트를 포함한다.
- 패키지 검증: `swift test --package-path Packages/TaptionPlanCore` 성공.
- 빌드 검증: TaptionPlan Debug simulator build 성공, TaptionPlanWatch Debug generic watchOS build 성공.
- 실기기 게이트: 연결된 Apple Watch의 수면 provenance readback과 해당 시각의 실제 졸라맨 화면 확인은 이번 실행에서 수행하지 못해 미완료로 남긴다.

## 2026-08-30 IPHN830Q12 · 수정본 iPhone 재설치

- 현재 워크트리 기준 개발 서명 Debug build 성공: `/private/tmp/taption-plan-iphn830q12-device/Build/Products/Debug-iphoneos/TaptionPlan.app`
- iPhone 14 Pro 설치·실행 성공: `com.taption.plan`
- 앱 목록 readback: `Taption Plan / 1.0 / 115`

## 2026-08-30 DRAG830Q11 · 오른쪽 사이드바 즉시 드래그

- 원인: Plan 핸들의 `minimumDistance = 1`과 일반 탭 제스처 조합이 첫 드래그 샘플을 지연시킬 수 있었다. WBS `ConnectorView`의 핸들은 `DragGesture(minimumDistance: 0)`을 고우선순위로 사용하고 탭을 동시 처리한다.
- 수정: Plan 좌우 선택 핸들의 드래그 임계값을 `0`으로 변경하고 단일 탭을 `simultaneousGesture`로 변경했다. 오른쪽 터치 높이 `132pt`, 시각 크기 `44pt`, 비중첩 hit zone은 유지했다.
- iPhone 14 Pro `TimeScaleTests`: 전체 선택 테스트 통과. `testMapHomeTimeSidebarHandleStartsOnTouchLikeWBS`, 오른쪽 1.5배 영역, 양쪽 비중첩 영역 포함.
- iPhone 14 Pro 설치·실행 readback: `Taption Plan / com.taption.plan / 1.0 / 115` 성공.
- 실제 화면·손가락 드래그: iPhone 미러링이 `iPhone을 찾을 수 없음`을 표시해 미완료. 코드·자동 테스트·설치 성공을 실제 터치 완료로 승격하지 않는다.

## 2026-08-30 RELD830Q10 · main/TestFlight/iPhone 전달

- Plan 저장소 `main`은 커밋·원격 푸시 후 clean 상태이며 WBS 저장소의 dirty 변경은 건드리지 않았다.
- Release archive/export 성공: `/private/tmp/taption-plan-reld830q10-auto.xcarchive`, `/private/tmp/taption-plan-reld830q10-export/TaptionPlan.ipa`
- TestFlight upload 성공: Delivery UUID `f29953e9-7f46-40da-a5a3-e62b1c543d4f`
- App Store Connect processing readback: build `1.0 (115)`, `VALID`, `APP_STORE_ELIGIBLE`, App Store Connect 등록 확인
- `TP Taption Plan 내부 테스트` 그룹에 build 115 연결 성공, 그룹 빌드 목록에서 동일 build UUID·버전·처리 상태 노출 readback 성공
- IPA 서명 readback: Apple Distribution, beta entitlement 활성, bundle `com.taption.plan`, version `1.0 (115)`
- iPhone 14 Pro 개발 서명 Debug build 성공: `/private/tmp/taption-plan-reld830q10-device/Build/Products/Debug-iphoneos/TaptionPlan.app`
- iPhone 14 Pro 설치·실행 성공: `com.taption.plan`; 앱 목록 readback `Taption Plan / 1.0 / 115`. TestFlight 업로드/그룹 노출은 설치·실제 화면·터치와 별도 게이트다.

## 2026-08-30 WBSI830Q08 · DATA830Q09 데이터 로드·지도·사이드바 통합

- WBS 기준 대조: `ScheduleStore`/`WorkspacePersistence`의 정규화된 단일 원본 로드와 파생 presentation 경계를 읽기 전용으로 확인했다. WBS 저장소와 WBS `temp.md`는 수정하지 않았다.
- Plan 데이터 경계: `PlanDayDataSnapshot`이 Plan snapshot revision·updatedAt을 고정하고, SQLite 정본의 iPhone/Watch raw archive를 변경하지 않은 채 선택일 actual/place/travel/sensor 배열을 파생한다. 중복 센서는 ID 기준 결정적으로 정리하고 날짜 범위를 제한한다.
- 앱 전체 XCTest: `TaptionPlanTests` 815/815 통과. 결과: `/Users/u_mo_c/Library/Developer/Xcode/DerivedData/TaptionPlan-gvqtjbpzkfvutrdlxdzhdyhsyane/Logs/Test/Test-TaptionPlan-2026.08.30_04-43-27-+0900.xcresult`
- Package 테스트: `TaptionRouteEngine` 11/11, `TaptionActivityEngine` 4/4, `TaptionPlanCore` 30/30 통과.
- 자동 계약: 오른쪽 핸들 터치 높이 132pt(기존 88pt 대비 면적 1.5배), 240Hz 입력/60Hz 출력, 날짜·15분 GPS 경계, 누적거리 재생, 목요일 단조 이동·비회전, 현재 위치·나침반 camera scale 보존 테스트 통과.
- 지도 실행 경로: Apple muted standard/flat/light/POI 제외/교통량 숨김/paper `#FCF9F4`로 고정하고, 기존 MapLibre 코드는 호환성 경로로 유지했다.
- 원본 불변: Apple iPhone/Watch 기록은 복사본 기반 분류·지도 projection만 수행하며 저장 원본과 provenance를 덮어쓰지 않는다.
- `git diff --check`: 통과.
- iPhone 14 Pro Debug build: `/private/tmp/taption-plan-wbsi830q08-device/Build/Products/Debug-iphoneos/TaptionPlan.app` 생성 성공. 앱·Widget·Watch bundle 모두 `1.0 (115)`로 artifact readback했다.
- iPhone 14 Pro 설치: `xcrun devicectl device install app` 성공. `com.taption.plan / 1.0 / 115` 설치 readback 성공.
- iPhone 14 Pro 실행: `xcrun devicectl device process launch` 성공. `com.taption.plan` launch readback 성공.
- 실기기 화면·터치: iPhone 미러링이 `연결이 중단됨`으로 종료됐다. 미러링 화면은 “Mac 근처·전원·최근 잠금 해제·Bluetooth/Wi-Fi 확인”을 표시했으며, 목요일 재생·졸라맨 추종/비회전·지도 비율·양쪽 핸들 실제 터치 readback은 미완료다.
- Apple Watch: CoreDevice 상태 `unavailable`로 원본 데이터·동기화·실제 Watch 화면 readback 미완료. Dynamic Island도 실기기 화면 연결 실패로 미완료다.

## 2026-08-30 ZOOM830Q01 재생 중 지도 줌 고정

- 재생 중 비동기 예상 경로·캐시·초기 위치 처리의 자동 region/viewport 재적용을 차단하고, 재생 위치 중심 추적은 유지
- `TimeScaleTests` targeted 통과: `/tmp/taption-plan-zoom830q01-tests/Logs/Test/Test-TaptionPlan-2026.08.30_01-30-07-+0900.xcresult`
- Debug simulator build 통과
- 현재 수정본 iPhone 설치·재생 화면·터치 readback은 새 서명 빌드의 Xcode 계정/프로파일 부재 및 iPhone 미러링 잠금 대기로 보류

## 2026-08-29 NCP829R001 최신 인계 실행

- 저장소: `main`/`origin/main` `c06f12e`, `git diff --check` 통과
- 서명 Debug `1.0 (114)` 빌드·iPhone 14 Pro 설치·앱 `com.taption.plan` readback 성공
- iPhone `MapHomeStickmanTests`: 20/20 통과 (`/tmp/taption-plan-NCP829R001-device-tests-team.xcresult`)
- 실제 화면·터치: 지도 홈, 재생 시작/중지와 시간·경로 갱신, 과거 날짜 이동 후 복귀, 시간 레일 이동, 팬 후 현재 위치 재중앙화, 확대·축소, 나침반 회전/북쪽 복귀, 사이드바 열기/닫기, 표시 설정 확장, 수면 포즈(약 10:59) 확인
- Dynamic Island 상단 터치는 Taption Plan 화면이 아닌 다른 여행 앱 Live Activity를 열었으므로 Plan 기능 증거로 사용하지 않음
- 미완료: 최종 소스의 18개 동작 전체 화면 매트릭스, Plan Dynamic Island compact/expanded, HealthKit/Watch 지연 동기화·원본 readback, IAP 외부 게이트
- 현재 앱은 PIN 화면으로 재잠금되어 다음 수동 검증은 대표님이 PIN을 직접 입력한 뒤 이어야 함

## 2026-08-29 IPDL829A01 iPhone 다운로드

- `main` `c06f12e`에서 서명 Debug `1.0 (114)` 빌드 성공
- iPhone 14 Pro 설치 성공: `com.taption.plan`
- 설치 readback: `Taption Plan / com.taption.plan / 1.0 / 114`
- 실행 readback 성공: PID `6709`
- 실제 화면·터치는 기존 `NCP829R001` 별도 게이트로 유지

## 2026-08-29 WBSM829Q01 WBS Apple 지도·경로 이식

- `MapHomeView.swift`: Apple 경로 화면을 네이티브 `MKMapView`·`MKPolyline`·`MKAnnotation` 브리지로 전환하고 OpenFreeMap/MapLibre 선택은 유지
- `MKDirections` endpoint 캐시, 자동차·대중교통·도보 우선순위 fallback, 실패 시 기존 endpoint 직선 경로 보존
- 실측 센서 경로와 예상 경로를 분리하고, 예상 경로 walker는 거리 기반 polyline·시간축 보간과 진행 방향을 사용
- `RouteTimelineDataTests`, `TimeScaleTests` 실행 통과
- 서명 Debug `1.0 (114)` 빌드·iPhone 14 Pro 설치 성공, `com.taption.plan` 실행 PID `7123` readback
- iPhone 미러링은 `iPhone 사용 중`으로 연결되지 않아 Apple 지도 화면·터치 readback은 보류

## 2026-08-30 WALK830Q01 이동 경로 졸라맨 추적·방향 안정화

- 경로 재생 좌표와 동일한 거리 기반 시간축 보간에 look-ahead heading을 적용하고, Apple/벡터 지도에 공통 사용
- Apple `MKAnnotation` 좌표 직접 KVO 갱신, annotation transform 애니메이션 제거, heading을 8방향으로 안정화
- 벡터 지도 졸라맨에도 재생 경로 heading 적용
- `RouteTimelineDataTests`, `TimeScaleTests` 통과
- 서명 Debug `1.0 (114)` 빌드·iPhone 14 Pro 설치·`com.taption.plan` 실행 readback 성공
- 실제 화면: 수정 빌드 Plan 지도 홈 연결 확인 후 PIN 화면 재잠금 확인
- 실제 터치·재생: PIN은 대표님이 직접 입력해야 하므로 경로 재생·졸라맨 이동·방향 readback 보류

## 2026-08-30 STYLE830Q2 WBS 지도·경로·졸라맨 스타일 동기화

- WBS 토큰을 Plan 공통 스타일로 연결: paper `#FCF9F4`, 실제 경로 teal `#458B88` 2.2pt/0.96, 예상 경로 terracotta `#C65D4D` 1.8pt/0.78 dashed `[4, 3]`
- Apple 지도 standard/simplified를 WBS muted standard·flat·light 구성으로 맞추고, MapLibre runtime style 변환을 제거해 저장된 벡터 스타일이 실제 렌더러에 전달되도록 수정
- 실제/예상 경로 모두 거리 기반 시간축 좌표를 사용하고, 재생 졸라맨은 경로 progress phase를 공유하며 marker 전체 회전을 제거
- `RouteTimelineDataTests`, `TimeScaleTests`: targeted rerun 통과 (`/tmp/taption-plan-style830q2-tests/Logs/Test/Test-TaptionPlan-2026.08.30_01-08-07-+0900.xcresult`)
- 서명 Debug `1.0 (114)` build 성공: `/private/tmp/taption-plan-style830q2-device/Build/Products/Debug-iphoneos/TaptionPlan.app`
- iPhone 14 Pro `com.taption.plan` 설치·실행·Version `1.0 (114)` readback 성공
- 실제 화면·터치: iPhone 미러링이 `iPhone 사용 중` 상태라 잠금 후 연결이 필요하여 목요일 경로 재생·스타일·졸라맨 이동 readback 보류

## 2026-08-28 실행 기록

- generic iOS Debug build: 성공
- generic iOS `build-for-testing`: 성공
- iOS Simulator: 사용 가능한 기기 없음
- iPhone 14 Pro 서명 Debug build/install/launch: 성공
- iPhone XCTest 전체: 775건 중 773건 통과, 2건 실패
- iPhone XCTest 대상 변경: `MapHomeStickmanTests` 13건 + 근방 후보 삭제 회귀 1건, 14건 모두 통과
- 전체 XCTest 실패 원인: 저장소에 없는 `TaptionPlan/Localizable.xcstrings`와 `.cat-visual-check/cat_sheet_x4.png` fixture
- iPhone 미러링: 기기가 사용 중이라 잠금 전 연결 시간 초과, 화면·터치 readback 미검증
- iPad Pro 12.9-inch 서명 Debug build/install/launch: 성공, `com.taption.plan` `1.0 (107)` readback
- iPad 대상 회귀 XCTest: 교통 후보 6건 + MapLibre viewport 최종 flush 1건, 7건 모두 통과
- Release build `1.0 (108)` archive/export/upload: 성공, App Store Connect processing `제출 준비 완료`
- `TP Taption Plan 내부 테스트` 그룹: build `1.0 (108)` 연결·`테스트 중`·iOS 노출 readback 성공
- iPad TestFlight 직접 설치: Distribution IPA의 Beta entitlement 제약으로 미완료; iPad에는 서명 Debug `1.0 (107)`만 설치·launch됨

## STK828M5Q2 · BCH828STK1

- 신규 기능: 하단 스티커 메뉴 복구, `전부 보기`/`해당되는 것만 보기` 지도 메모 필터, 지도·일정 스티커 추가, 스티커 모드 편집·삭제
- 신규 회귀 XCTest: `MapHomeStickmanTests` 16건 중 신규 3건 포함 전체 통과
- iPad Pro 12.9-inch 서명 Debug `1.0 (108)` 설치·실행 readback: 성공
- Release `1.0 (109)` archive/export/upload: 성공, Delivery UUID `f363e054-23cd-483a-89ba-3d981792f515`
- App Store Connect processing: `제출 준비 완료`
- `TP Taption Plan 내부 테스트`: build `1.0 (109)` 연결·`테스트 중`·iOS 노출 readback 성공
- iOS Simulator: 사용 가능한 기기 없음; 지도 스티커·메모 실제 화면·터치는 별도 미검증

## REL28TRN01 · test.md 전체 실행 후속

- iPhone 14 Pro 서명 Debug `1.0 (109)` 설치·실행 readback: 성공
- Apple Watch SE 서명 Debug `1.0 (109)` 설치·실행 readback: 성공
- iPhone 전체 XCTest: 783건 중 781건 통과, 2건 실패
- iPad Pro 12.9-inch 전체 XCTest: 783건 중 781건 통과, 2건 실패
- 실패 2건: 저장소에 없는 `TaptionPlan/Localizable.xcstrings`, `.cat-visual-check/cat_sheet_x4.png` fixture
- 위 두 fixture 테스트를 iPhone·iPad에서 targeted 재실행: 모두 통과
- 전체 XCTest 재실행 재시도: 현재 로컬 `4FWG8XXYM` iOS Development 인증서·프로파일 부재로 빌드 단계 중단
- HealthKit·Watch·지도·스티커 관련 단위/통합 테스트: 전체 실행 범위에서 통과
- iPhone 미러링: iPhone 잠금 전 연결 시간 초과 상태로 실제 화면·터치 readback 미완료
- 지도·교통·스티커·Dynamic Island의 실제 화면·터치, HealthKit 권한/원본, Watch 지연 동기화, IAP 외부 계약·Sandbox 구매는 외부/수동 게이트로 남김

## TRN828Q7A1 · BUG28P9K3X · DEL28Q9M4X

- 대상: iPhone 14 Pro 및 연결 가능한 iPad, 최신 검증 빌드
- 지도 후보: 3분 미만은 미표시, 3분 이상은 `?` 표시
- 후보 메뉴: 지하철·버스·기차·비행기·배 탑승 선택과 삭제 버튼을 실제 터치
- 삭제: 100m 이내의 같은 체류 구간 또는 5분 이내 인접 체류 후보를 종류·POI ID와 관계없이 한 번에 숨김
- 보존: 등록 교통 위치·원본 GPS·이미 확정된 이동 기록이 삭제되지 않음
- 재실행: 삭제 결정이 저장 후 재실행에도 유지됨
- 지도 경로: Apple MapKit과 MapLibre에서 후보 표시·탭·삭제를 각각 확인
- 상태: 컴파일·실기기 대상 XCTest 완료 · Simulator/실기기 화면·터치 대기

## MAP828R5K2

- Apple 지도와 MapLibre 제공자 전환을 실제 터치
- MapLibre 4개 스타일과 오버레이·경로·플레이어 위치를 확인
- 지도 검색·줌·팬·사이드바 가림 및 접근성 라벨을 확인
- 상태: 코드 검증·실기기 대상 XCTest 완료 · 실기기 화면·터치 대기

## HLTH28P7Q4 · SLEEP827B2

- iPhone HealthKit 권한 시트와 유형별 권한 결과를 readback
- 전체 이력 진행률·원본 건수·source/device provenance를 확인
- 페어링 Apple Watch 데이터의 지연 도착·백그라운드 observer·재실행 anchor 증분을 확인
- 2026-08-27 07:15 전후 수면 원본과 걸음·화면 사용 시각을 대조
- 확인되지 않은 휴대폰 터치 시각을 수면 종료로 추정하지 않음
- 상태: 코드 검증·실기기 대상 XCTest 완료 · 실기기 HealthKit/Watch readback 대기

## NXT27AUG01 · IAP73PAID1

- Dynamic Island compact/expanded 센서 실시간 화면 확인
- 재생·사이드바·졸라맨 최전면·지하철 확정/예상 경로 확인
- `NEXT_CHAT_PROMPT.md`의 커밋·빌드·기기·TestFlight 상태를 최신 readback으로 갱신
- Paid Apps Agreement·세금/은행·상품 연결·Sandbox 구매/복원 전까지 IAP 게이트 미완료
- 상태: 인계 문서 갱신 완료 · 실기기 화면·터치 및 IAP 외부 게이트 대기
