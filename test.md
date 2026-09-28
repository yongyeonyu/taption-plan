# 검증 기록

## TFL0928C01 · main 반영 및 TestFlight 163 (2026-09-28)

- 배포 전 App Store Connect API readback에서 최근 빌드 162 `VALID`, 최고 번호 162를 확인했다. 기록 `build/validation/TFL0928C01/asc-builds-before.json`.
- 앱 전체 테스트: **1,427 통과, 1 건너뜀, 0 실패 (총 1,428)**. 건너뜀은 `FeatureEngineTests.testStoreKitProductPurchaseEntitlementAndRestore`이며 iOS 26.5 StoreKitTest 환경 보호 항목이다. 구매/IAP를 검증하지 않았다. `build/validation/TFL0928C01/app-tests.xcresult`, `app-tests.log`.
- 366개 `HomeEvolution` SVG 모두 고유, 인접 레벨 365쌍 차이 확인. `CURRENT_PROJECT_VERSION` 8개 설정 및 앱·iPhone Widget·Watch·Watch Widget `CFBundleVersion`을 163으로 맞췄다. 테스트 플라이트 Release archive·처리·내부 그룹 결과는 이어서 기록한다.

## UNCF0928A1 · 미확인 입력 대분류 확정 유지 (2026-09-28)

- 앱 부팅 전 레일을 `.wholeDayUnconfirmed`로 임시 채우던 부모 상태와 빈 `MapHomeTimeSidebarRailSnapshot`의 fallback을 제거했다. `model.isBootstrapped` 전에는 레일·현재 활동 표시를 비우고 시간 편집 및 미확인 입력 콜백을 막는다. 데이터 로드 완료 후 실제 미확인 구간은 이전 정책대로 표시한다.
- 미확인 공백에서 업무 대분류를 저장한 뒤 같은 repository로 `AppModel`을 새로 만들고 다시 부팅하는 테스트에서 업무 분류가 유지됐다. 이후 같은 시간에 겹치는 HealthKit 자동 활동을 추가해도 수동 확정 분류가 우선하며 확인 대상에서 빠진다.
- 요청 회귀 6종 통과: `FeatureEngineTests.testConfirmedUnconfirmedCategorySurvivesReloadAndLateAutomaticRecord`, `testActivitySectionSaveOverridesTravelAndSupportsImmediateReedit`, `testPartialUnconfirmedEditPreservesSourceOutsideSelectedSpan`, `TimeScaleTests.testMapHomeSidebarRailSnapshotIndexesOnlyVisibleIntervals`, `testQuestionMarkMarkersOnlyExistForActualVisibleUnconfirmedActivity`, `testQuickConfirmedIntervalDisappearsFromUnconfirmedReview`. 결과 `build/validation/UNCF0928A1/app-tests.xcresult`, `app-regressions.xcresult`, `unconfirmed-review.xcresult`; 모든 실행 `TEST SUCCEEDED`.
- generic iOS Debug `BUILD SUCCEEDED`: `build/validation/UNCF0928A1/ios-debug.log`. `git diff --check` 통과.
- iPhone 11 Pro에 Debug 1.0(162)을 설치하고 실행했다. 첫 화면 캡처 `build/validation/UNCF0928A1/iphone11-startup.png`에서는 로딩용 가짜 `?`가 보이지 않았다. 재실행 명령의 첫 두 캡처는 검은 화면이었고, 프로세스를 종료한 뒤 새로 실행하자 지도가 표시됐다(`iphone11-relaunch-fresh.png`). 이 캡처에는 13:50 선택 시각 옆에 실제 미확인 마커가 하나 나타났지만, 그 구간이 사용자가 이전에 확정한 바로 그 구간인지는 화면 자료만으로 식별할 수 없다. 따라서 해당 구간의 실기기 저장·재진입 확인은 미완료다.

## LOC0928A01 · 등록 장소 마커 지도 팔레트 통일 (2026-09-28)

- 집·회사·학교·학원·운동·취미·식당·사용자 장소의 색을 저채도 어스톤으로 바꿨다. 지도 랜드마크 기호는 모두 크림 표면·지도 라인 테두리·갈색 계열 그림자가 있는 같은 크기의 배지로 표시한다. 집 그림에도 은은한 크림 배경과 지도 테두리를 적용했다. 라벨과 위치 목록 썸네일은 같은 장소 강조색을 쓴다.
- `FeatureEngineTests.testRegisteredLocationTintsUseDistinctParchmentMapColors`, `testMapHomeLocationHierarchyKeepsConfiguredAndUserDestinationsDistinct`, `testRegisteredPlaceIconCenterMatchesStoredCoordinate`, `testCatTapRoutingAcceptsOnlyTapsInsideMarkerBounds` 통과(4/4). 결과 `build/validation/LOC0928A01/app-tests.xcresult`.
- generic iOS Debug `BUILD SUCCEEDED`: `build/validation/LOC0928A01/ios-debug.log`; `git diff --check` 통과. 실기기 지도 화면은 미확인이다.

## BAK0928A01 · 수동 백업을 자동 설정과 분리 (2026-09-28)

- `FeatureEngineTests.testManualCloudBackupWorksWhenAutomaticBackupIsDisabled` 및 `testManualCloudBackupRejectsIncompleteSensorArchiveBeforeReplacingGeneration` 통과(2/2): 월별 자동 백업 off + PIN 상태에서 수동 저장은 성공하고, 센서 raw archive가 불완전하면 이전 세대와 raw 자료를 보존한다. `build/validation/BAK0928A01/app-tests-retry.xcresult`.
- `SecurityBackupCoreTests.testCloudBackupAndAppLockRequirePIN` 통과(1/1). 수동 generation 저장도 PIN이 없으면 `.pinRequiredForCloudBackup`로 거부한다. `build/validation/BAK0928A01/pin-guard-tests.xcresult`.
- generic iOS Debug `BUILD SUCCEEDED`: `build/validation/TRN0928A01/build.log`; `git diff --check` 통과. 실제 iCloud 계정으로의 백업과 기기 설정 화면은 미검증이다.

## TRN0928A01 · 기차 이동에서 지하철 카탈로그 경로 생성 (2026-09-28)

- `.train` 이동 시간 안의 센서 표본에서 지하철 카탈로그 경로가 유효하게 복원될 때 지도에 추정 스타일 경로를 표시한다. 현재 재생 시점 이후 표본은 사용하지 않고, 역 순서/노선 증거가 부족하면 경로를 만들지 않는다. 경로 복원 엔진은 유효한 카탈로그 노선이 붙은 `.train` 추론도 지하철 세그먼트로 정규화한다. 복원된 지도 캐시는 첫 렌더에서 최신 센서 기반 추정 경로를 다시 계산한다.
- `FeatureEngineTests.testTrainMovementDrawsEstimatedSubwayCatalogRouteOnlyWithRailEvidence`, `testSparseRailEndpointsRestoreSubwayWithoutRoadFalsePositive`, `testMapHomeSubwayOverlayDoesNotDrawUnconfirmedWholeRoute`, `testRailEndpointsBridgeThirtyMinuteGPSGapOnlyOnCatalogRoute` 통과(4/4). 결과 `build/validation/TRN0928A01/app-tests.xcresult`.
- generic iOS Debug `BUILD SUCCEEDED`: `build/validation/TRN0928A01/build.log`; `git diff --check` 통과. 실기기 지도 표시는 아직 미확인이다.

## CBG0928A01 · 화랑이 장면 배경·크기 통일 (2026-09-28)

- 지도 고양이 20개 동작마다 배경 아이콘과 의미 색상을 연결했다. 회사·학교·수면·식사·운동·취미·이동·교통 등 각 상황의 심볼을 낮은 대비로 장면 뒤에 배치하고 장면 캔버스 안에서 원형 클립한다.
- 동작별 개별 스케일(운동·수면 포함)을 없애고 캔버스 폭의 86%로 공통 크기 비율을 사용한다. 30·36·42pt 크기 및 0/무한 입력 경계 검사 포함.
- `MapHomeStickmanTests.testCatSceneBackgroundCoversEveryActionWithConsistentSpriteScale` 통과. 최종 `focused-verified.xcresult`, 로그 `build/validation/CBG0928A01/focused-verified.log`.
- generic iOS Debug `BUILD SUCCEEDED`: `build/validation/CBG0928A01/ios-debug-final.log`; `git diff --check` 통과. 전체 동작의 실제 지도 화면은 아직 기기에서 확인하지 않아 `temp.md`에 대기로 남긴다.

## WPL0928A01 · 현재·예보 날씨 알약 배경 (2026-09-28)

- 현재 관측 배경은 순백색, 미래 예보 배경은 불투명 `tpSurface`로 지정하고 두 배경 모두 alpha 1로 렌더한다. 예보 아이콘·온도 텍스트만 기존 비활성 표시 opacity 0.58을 유지한다.
- `TimeScaleTests.testWeatherTimelineDimsForecastsAndScalesWidgetsToEightyPercent` 통과. 같은 결과 번들에서 배경 스타일·불투명도 assertion 확인. generic iOS Debug와 `git diff --check` 통과.

## TF0928B162 · `?` 조건부 표시 TestFlight 162 (2026-09-28)

- QMRK0928A1 포함 main 커밋 `25322bb` 푸시 완료. 빌드 162로 앱·Widget·Watch·Watch Widget 버전을 맞췄다. IPA 내부 네 번들의 `CFBundleVersion` 모두 162.
- iOS Debug 및 Watch Debug 빌드 통과. Release archive 및 Production CloudKit entitlement 포함 IPA export 통과.
- App Store Connect 업로드 성공, Delivery UUID `46a8ee1e-cded-4fcf-aef7-4b06c89a3cd3`; 처리 상태 `VALID`. `TP Taption Plan 내부 테스트` 그룹 연결 후 API readback에서 빌드 노출과 테스터 1명을 확인했다. 근거 `build/validation/TF0928B162/testflight-readback.json`; archive/export/upload 로그는 같은 경로.
- iPhone 11 Pro에 build 162 설치 및 실행 성공. 기기의 앱 목록에서 버전 1.0 (162), 실행 프로세스 PID 2688을 확인했다. 요약 `build/validation/TF0928B162/iphone-device-readback.json`; 원본 devicectl 결과는 같은 폴더. iPhone 18 Pro Max는 현재 `unavailable`.
- App Store Connect 웹 그룹 화면과 기기 화면에서 실제 `?` 표시/숨김 동작은 아직 확인하지 않았다. iPhone 11은 실행까지만 확인했으며 QMRK0928A1 및 TF0928B162는 해당 확인이 끝날 때까지 열린 상태로 둔다.

## QMRK0928A1 · 미확인 `?` 마커 조건부 표시 (2026-09-28)

- `MapHomeTimeSidebarRailSnapshot`은 표시용 입력이 비면 하루 전체 `.wholeDayUnconfirmed` 구간을 합성한다. 이전 `?` 계산은 이 표시 snapshot에서 시작해 원본 구간이 없는 날에도 마커를 만들 수 있었다.
- 마커는 이제 실제 입력 `segments`에서 날짜 정책과 현재 보이는 시간 범위를 적용해 만든다. 빈 원본, 확정 구간만 있는 날, 현재 날짜의 미래 구간, 화면에 보이지 않는 구간은 마커 대상이 아니다. 시간 레일의 표시용 합성 구간은 기존 동작대로 유지한다.
- `TimeScaleTests.testQuestionMarkMarkersOnlyExistForActualVisibleUnconfirmedActivity` 통과(1/1): 빈 입력·확정만·미래·화면 밖에서 0개, 실제 보이는 미확인 구간만 반환. 결과 `build/validation/QMRK0928A1/questionmark-focused.xcresult`, 로그 `questionmark-focused.log`.
- generic iOS Debug `BUILD SUCCEEDED`: `build/validation/QMRK0928A1/ios-debug.log`; `git diff --check` 통과. 실기기에서 두 상태 화면을 보기 전까지 기기 검증은 대기한다.

## ALLT0927A1 · iPhone 11 Pro current Debug 160 실행 확인 (2026-09-28)

- 현재 소스에서 빌드한 signed Debug 앱을 연결된 iPhone 11 Pro (`iPhone12,3`, iOS 26.7/23H24)에 update-in-place 설치했다. 기존 앱 데이터를 초기화하지 않았다. `devicectl` 설치 성공 로그/JSON: `build/validation/ALLT0927A1/iphone11-session-20260928/install-debug-160.log/json`; 앱 목록 readback은 `com.taption.plan`, version 1.0, build 160.
- 앱 실행 명령 성공 후 settled screenshot에서 지도 홈, 날짜 헤더, 오른쪽 시간 레일/날씨, 집·불·고양이 마커 및 왼쪽 Undo/Redo가 보인다: `build/validation/ALLT0927A1/iphone11-session-20260928/debug-settled.png`. 기기 프로세스 목록에서 `TaptionPlan` 프로세스가 확인됐다. 첫 실행 직후의 전환 애니메이션 캡처는 `debug-after-launch.png`이며 판정에는 사용하지 않았다.
- 실행 전후 시스템 crash-log 목록에 새 Taption Plan 항목이 없고 기존 9/27 보고서 3건만 보였다. 이는 짧은 시작·화면 확인에서 새 충돌이 관찰되지 않았다는 근거이며, 장시간 백그라운드 복귀 안정성이나 0xDEAD10CC 재발 부재를 입증하지 않는다.
- 화면상 Undo/Redo 컨트롤 존재는 확인했지만 조작/기록 변경/복구는 하지 않았다. HealthKit 온보딩, 터치, 빠른 입력 저장, GPS 이동·회색 예측 경로, 회사·학교 고양이, 집 탭, 날씨 상태, 백업/계정/캘린더/Watch/수면은 미검증이다. 따라서 연결된 요청은 열린 상태다.

- 같은 current Debug 1.0(160)을 iPad Pro 12.9-inch (6th gen, iPad14,6)에 update-in-place 설치하고 앱 실행 및 화면 캡처를 완료했다 (`build/validation/ALLT0927A1/ipad-session-20260928/`). 화면은 온보딩 1/4의 위치·이동 단계다. 앱 설치 당시 권한 상태를 관찰했을 뿐, 버튼을 누르거나 권한을 변경하지 않았다. iPad readback은 시작·온보딩 표시까지만 확인한다.
- iPhone 18 Pro Max는 현재 연결 목록에서 `unavailable`이므로 current Debug 설치/로그 수집을 하지 못했다. 대표님 제공 영상·로그 분석을 기다린다.

## ALLT0927A1 · 최신 자동 검증 요약 (2026-09-28)

- 현재 작업 트리에서 앱 전체 테스트 **1,421 통과, 1 건너뜀, 0 실패 (총 1,422)**. 유일한 skip은 `FeatureEngineTests.testStoreKitProductPurchaseEntitlementAndRestore`; iOS 26.5 StoreKitTest가 `SKInternalErrorDomain Code 3`으로 시작되지 않았다. 원본 `build/validation/ALLT0927A1/app-tests-current-20260928.log` 및 `.xcresult`.
- Swift package 테스트: TaptionPlanCore 101/101, TaptionRouteEngine 39건 통과, TaptionActivityEngine 33/33, TaptionPlanEngine 1/1. 로그는 `package-core-20260928.log`, `package-route-20260928.log`, `package-activity-20260928.log`, `package-plan-20260928.log`.
- generic iOS Debug 및 Watch Debug 빌드 모두 성공. 로그 `ios-debug-current-20260928.log`, `watch-debug-current-20260928.log`. 전체 앱 테스트에는 GPS gap 보간·2행 카테고리 회귀가 포함됐다.

## ALLT0927A1 · 전체 앱 회귀·현재 Debug 기기 실행 (2026-09-28)

- 현재 수정 작업 트리 전체 앱 테스트 **1,427 통과, 1 건너뜀, 0 실패 (총 1,428)**. StoreKit 상품 구매/복원 테스트 1건은 iOS 26.5의 기존 시뮬레이터 환경 보호 skip이며, 별도 판매 검증으로 계산하지 않았다. 과거 실패 13건은 이번 전체 실행에서 재현되지 않았다. 결과 `build/validation/ALLT0927A1/current/app-tests.xcresult`, 로그 `app-tests.log`.
- TaptionPlanCore 101/101, TaptionRouteEngine 39/39, TaptionActivityEngine 33/33, TaptionPlanEngine 1/1 통과. 출력 로그는 `build/validation/ALLT0927A1/current/*-package.log`.
- generic iOS Debug 및 Watch·Watch Widget Debug 빌드 모두 `BUILD SUCCEEDED`: `build/validation/ALLT0927A1/current/ios-debug.log`, `watch-debug.log`. 앱·iPhone Widget·Watch 앱·Watch Widget 산출물의 bundle ID와 build 162를 각각 확인했다.
- 현재 소스 Debug 1.0(162)을 iPhone 11 Pro에 update-in-place 설치·실행했다. 캡처 `build/validation/ALLT0927A1/current/iphone11-after-launch.png`에는 지도 홈, 집·화랑이, 시간축, 날씨 및 Undo/Redo 컨트롤이 보인다. 터치/저장·실제 이동은 검증하지 않았다.
- 같은 Debug 1.0(162)을 iPad Pro에 설치·실행했다. 캡처 `build/validation/ALLT0927A1/current/ipad-after-load.png`는 온보딩 1/4 위치 단계다. 권한 버튼을 누르지 않았으므로 온보딩 진행 검증은 미완료다. iPhone 18 Pro Max는 연결할 수 없어 실기기 검증을 못 했다.
- `git diff --check` 통과. 4개 Swift package 테스트를 동시에 별도 빌드하려던 후속 실행은 디스크 부족으로 실패했다. 이 재실행 실패를 테스트 실패나 통과로 계산하지 않으며, 앞서 완료된 package 결과는 별도 출력으로 통과 확인했다. 임시 package scratch 폴더만 제거해 여유 공간을 회복했다.
- 실기기 캡처 `build/validation/ALLT0927A1/current/iphone11-after-relaunches.png`에서 오른쪽 시간축이 헤더 아래부터 하단 콘텐츠 영역까지 확장되고 00–24 시간 라벨 및 활동 구간이 서로 겹치지 않는 것을 확인했다. MARG270927 실기기 화면 기준을 통과했다. 짧은 레일의 조작 간격은 회귀 테스트 기준으로 확인했다.

## TF0928B161 · TestFlight/CloudKit 환경 제약 확인 (2026-09-28)

- App Store Connect API build 목록에서 최고 번호 1.0(160), 상태 `VALID`를 확인했다. `altool --build-status`에서도 delivery UUID `a40c7d53-56ae-429f-9ec8-14afdb85f529`의 160 `VALID`를 재확인했다. API 응답은 `build-status-160-recheck.json`에 보관했다.
- 161 archive를 생성하고 archive 내 앱 `com.taption.plan`, iPhone 위젯, Watch 앱 번들이 모두 build 161인지 확인했다. `archive-161.log`, `TaptionPlan161.xcarchive`.
- 기존 export options의 `iCloudContainerEnvironment=Production`은 현재 승인된 Development-only 조건에 맞지 않았다. 이를 `Development`로 변경해 `app-store-connect` export를 시도했으나 Xcode가 `value "Development" is not allowed`로 거부했다. `export-161.log`, `export-161/ExportOptions.plist`.
- Apple 설명에 따르면 TestFlight로 배포하는 앱은 CloudKit Development 환경을 사용할 수 없으며 Production만 사용한다: [Apple Testing Your CloudKit App](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitQuickStart/TestingYourApp/TestingYourApp.html), [CKContainer](https://developer.apple.com/documentation/cloudkit/ckcontainer?language=_3). 사용자가 이후 Production 사용을 명시 허용했다. `Development` export는 실패했지만 `Production` export는 성공했고 exported app entitlement readback이 Production이다. Internal-only option을 적용했고, 업로드·처리·그룹 검증은 후속 상태다.

## SK0928B001 · StoreKitTest 건너뜀 단독 재검증 (2026-09-28)

- `FeatureEngineTests.testStoreKitProductPurchaseEntitlementAndRestore`의 iOS 26.5 simulator skip을 단독 검증 목적으로 일시 우회해 실제 테스트를 시작했다. `SKTestSession` 초기화·상품 identifier 설정부터 `SKInternalErrorDomain Code 3`이 재발했고, 이후 `StoreProductPresentation`이 nil이라 `XCTUnwrap` 실패했다. 1개 실행·1개 실패. 로그 `build/validation/SK0928B001-storekit-test-rerun-20260928.log`; xctest stdout/stderr는 result bundle staging 안에 저장된다.
- 실패 원인은 앱 구매 entitlement assertion 전에 StoreKitTest session이 configuration/transaction override를 설정하지 못한 테스트 런타임 오류다. SKTestSession 정리 호출도 같은 Code 3을 반환했다. 실제 상품 로드가 없어 구매/복원 로직 결과는 검증하지 못했다.
- 이전의 iOS 26.5 환경 보호 skip을 테스트 소스에 복구했다. 판매/IAP 동작을 바꾸지 않았고 실제 구매도 하지 않았다. 다른 iOS 런타임이나 physical-device StoreKit configuration으로 실행하기 전까지 skip은 유지한다.

## TF0928B161 · TestFlight 1.0(161) Production 내부 빌드 생성 (2026-09-28)

- 최신 앱 소스의 Release archive 성공: `build/validation/ALLT0927A1/archive-161.log`, `TaptionPlan161.xcarchive`. archive 앱/위젯/Watch 앱 번들의 `CFBundleVersion`은 모두 161.
- Development CloudKit export를 Xcode가 거부한 뒤 사용자가 Production을 허용했다. `testFlightInternalTestingOnly=true`, `iCloudContainerEnvironment=Production`으로 export 성공. IPA `build/validation/ALLT0927A1/export-161-production/TaptionPlan.ipa` (47 MB); 앱·iPhone widget·Watch app·Watch widget 네 번들 1.0(161), 앱 서명 entitlement Production을 확인했다. export 로그 `export-161-production.log`.
- 업로드 전까지 TestFlight Processing/그룹 연결 여부는 미확인이다. 공개 App Store 제출은 하지 않는다.
- iOS Debug 1.0(161) `BUILD SUCCEEDED`: `build/validation/ALLT0927A1/ios-debug-161-final.log`; Watch Debug 1.0(161) `BUILD SUCCEEDED`: `watch-debug-161-final.log`. Debug 앱·iPhone widget·Watch app 번들의 `CFBundleVersion`도 모두 161.
- `altool --upload-app` 성공, Delivery UUID `84e88d1b-9cb6-4545-9939-c68ee91ef642`; 로그 `upload-161.log`. 최초 `altool --build-status` 조회가 응답하지 않아 중단했다. 즉시 App Store Connect API 목록 readback에는 161이 아직 나타나지 않았고, 그룹 연결/테스터 노출도 미확인이다. 공개 App Store 제출은 하지 않았다.
- 후속 App Store Connect API readback에서 빌드 161 `VALID`, `TP Taption Plan 내부 테스트` 내부 그룹 `buildAttached=true`, 테스터 수 1을 확인했다. 검증 결과 `build/validation/ALLT0927A1/testflight-161-readback.json`. App Store Connect 웹 UI는 `authResult=FAILED` 로그인 화면을 반환해 그룹 화면 캡처는 확보하지 못했다.
- 커밋 `3709724` (`Implement timeline, GPS, and location presentation updates`)를 `main`에 push했다. 빌드 161은 해당 커밋의 1.0(161) Release archive에서 업로드됐다.

## ALLT0927A1 · iPhone 11 Pro build 160 기기 확인 시도 (2026-09-28)

- 대상 기기 정보: iPhone 11 Pro (`iPhone12,3`), iOS 26.7 (23H24), paired·wired, Developer Mode enabled. readback: `build/validation/ALLT0927A1/iphone11-details-current.json`.
- 최신 소스의 Release archive 앱(`com.taption.plan`, 1.0/160)을 CoreDevice가 저장소 경로에서 열지 못해 첫 설치 시도는 sandbox bookmark 오류로 실패했다. archive 제품을 `/tmp/taption-iphone11-160/TaptionPlan.app`로 복사한 뒤 재설치했고, `devicectl`이 `App installed` 및 성공 JSON (`outcome=success`, database sequence 2984)을 반환했다. 근거: `iphone11-install-160-success.log/json`.
- 앱 프로세스 실행, 실행 프로세스 목록, 앱 번들 목록 readback은 각각 15–20초 후 CoreDevice timeout이었다. 새 `0xDEAD10CC` 로그 확인용 system crash-log 복사도 CoreDevice에서 응답이 오지 않아 중단했다. 설치는 반복 확인(성공 readback DB sequence 2984)했지만 실행 여부·앱 목록은 원격 readback 불가다. 관련 근거는 `iphone11-install-160-success.log/json`, `iphone11-launch-160-retry.log/json`, `iphone11-processes-after-launch.log/json`, `iphone11-apps-readback-160-final.log/json`, `iphone11-apps-readback-160.log/json`, `iphone11-launch-160.log`, `iphone11-launch-start-stopped.log`.
- 따라서 성공 판정은 1.0/160 앱 설치까지만이다. 앱 시작·백그라운드 복귀·Crash 재발·HealthKit 온보딩·지도/시간 레일·미확인 구간 저장·Undo/Redo·집 카드·실기기 GPS·날씨 표시 등 UI와 센서 결과는 확인하지 못했다. 사용자가 조작/증거를 주지 않은 기능은 통과 처리하지 않는다.
- 요청 ID의 자동 테스트·Debug/Release 빌드 근거는 기존 각 섹션에 유지한다. 설치 이후 UI/센서 실증은 ALLT0927A1 및 연결된 항목에서 계속 대기한다.


## ALLT0927A1 · main push·TestFlight 160 제출 및 2대 기기 확인 시도 (2026-09-28)

- `main` 커밋 `d85addc1ac71aa2cc85c4169d75a3d338177b976` (`Complete map, onboarding, and backup improvements`)을 push했고 원격 `origin/main`과 HEAD가 일치하며 워크트리는 clean이었다.
- App Store Connect 전체 빌드 135개를 확인했다. 최고 빌드는 159 (`VALID`), 160은 없었고, `TP Taption Plan 내부 테스트` 그룹은 내부 그룹이며 테스터 1명이 등록돼 있었다.
- 최신 `main`에서 iOS Release archive 성공: `build/validation/ALLT0927A1/archive-160.log`, `TaptionPlan160.xcarchive`; 앱 번들 `com.taption.plan`, 버전 `1.0(160)` 확인. App Store Connect export 성공, IPA 47 MB: `build/validation/ALLT0927A1/export-160.log`, `export-160/TaptionPlan.ipa`.
- `altool --upload-app`는 오류 없이 업로드 성공, Delivery UUID `a40c7d53-56ae-429f-9ec8-14afdb85f529`; 증거 `build/validation/ALLT0927A1/upload-160.log`.
- 확인 제한: 업로드 후 여러 차례 ASC REST 조회에서 160이 인덱스되지 않았고 내부 그룹 빌드 목록에는 기존 159가 최신으로 남아 있었다. `altool --build-status`는 응답을 끝내지 못했다. 따라서 처리 완료·그룹 연결·테스터 노출은 미확인이다.
- iPhone 11 Pro (`00008030-001628201AD2802E`) 및 iPhone 18 Pro Max (`00008160-000E195A1140000A`)는 USB 연결 상태이나 TestFlight에서 160을 내려받을 수 있는 단계가 아니었다. `devicectl` 앱 인벤토리 조회도 응답 지연으로 중단되어 두 기기의 설치/버전은 확인하지 못했다. TestFlight 설치 완료로 처리하지 않는다.
- 이전 검증 로그나 기기에 남아 있을 수 있는 160의 직접 개발 설치 결과를 TestFlight 다운로드 증거와 혼동하지 않는다. 전체 ALLT0927A1과 배포/기기 단계는 계속 열린 상태다.


현재 실행 근거만 간결하게 유지합니다. 이전 상세 개발·검증 기록은 Git 이력에 보존했습니다. `build/validation/`은 로컬 증거이며 Git에 포함되지 않습니다.

## BKM0928A01 · raw 구버전 전환·불변 파일 공개·manifest 참조 (2026-09-28)

- `saveMonthlyGeneration`이 snapshot-only 백업에도 존재하지 않는 raw generation을 발행하던 결함을 수정했다. manifest는 실제 저장된 raw 세대만 참조하며, raw 입력 없이 이전 raw를 보존하는 경우도 회귀로 확인했다.
- `FilePlanCloudRawSensorBackupStore.save`의 generation 덮어쓰기를 막고 snapshot/raw가 같은 불변 파일 writer를 사용하게 했다. complete-protection staging에 기록·fsync한 뒤 같은 디렉터리의 최종 경로에 덮어쓰기 없이 원자적으로 공개한다. 동일 바이트 재시도는 성공, 다른 내용·경로/세대 불일치는 거부한다. protection 실패 시 최종 파일이 생기지 않고 staging이 정리됨을 확인했다.
- V1·V2·V3 snapshot/raw 파일을 실제 file store에 시드해 다음 백업의 V4 전환, legacy 원본 바이트 보존, 서비스 재생성 후 복원, 다음 V4 저장을 각각 확인했다. 현재 월의 다음 백업 경로 검증이며 과거 월 일괄 migration/복원 recovery journal의 완료 근거는 아니다.
- 백업 회귀 **122/122 통과, 실패 0, 건너뜀 0**. 결과 `build/validation/BKM0928A01/backup-tests-03.xcresult`, 로그 `backup-tests-03.log`, summary `backup-tests-03-summary.json`. 최초 실행은 기존 손상 fixture가 저장 API로 불변 세대를 덮어쓰려다 1건 실패해 직접 디스크 손상 주입으로 고쳤다. 두 번째 실행은 새 fixture의 현재 시각 JSON 왕복 정밀도 비교 1건 실패로 고정 시각을 사용했다. 두 실패 로그도 보존했다.
- generic iOS Debug 빌드 성공: `build/validation/BKM0928A01/ios-debug-01.log`. `git diff --check` 통과. 동작 변경은 백업 앱 코드로 한정돼 기존 Core/package 결과를 재사용했다. 선행 전체 앱 1,412 통과/1 건너뜀은 ALLT0927A1의 이전 실행이며 이번 테스트 수와 합산하지 않는다.
- 제한: 이번 후속 빌드는 기기에 재설치하지 않았다. 실기기/iCloud Drive/CloudKit Development 동작, DB/file bounded streaming, 보호된 SQLite 복원 staging/recovery journal, 강제 종료로 남은 staging 정리는 미확인·미완료다. push·TestFlight 업로드를 실행하지 않았으며 전체 ALLT0927A1은 계속 열린 상태다.

## ALLT0927A1 · 저장소 잠금·HealthKit 온보딩 1차 수정 (2026-09-27)

- `SQLitePlanRepository`의 load/save/delete는 `TaptionPlanDayStore` actor의 동기 격리 클로저에서 flock과 SQLite 작업을 마치고 결과 row만 반환한다. 잠금 경합 시에는 잠금을 잡지 않은 채 비동기 재시도하며, snapshot Codable 디코딩도 잠금 해제 후 수행한다. deletion marker와 generation 갱신은 여전히 SQLite 삭제와 같은 잠금 임계 구역에 있다. 파일 snapshot 저장 경로도 동기 임계 구역으로 바꿨다.
- `testSQLiteRepositoryRetriesFileLockWithoutHoldingItAcrossSuspension`: 외부 잠금 점유 중 load 취소 응답, 잠금 해제 후 저장소 재접근을 검사해 통과했다. `testExclusiveFileAccessIsNonblockingAndReleasesOnThrow` 포함 TaptionPlanCore 101/101 통과. 로그: `build/validation/ALLT0927A1/core-tests-final.log`, `focused-app-tests.log`.
- HealthKit·캘린더·알림·위치 등 권한 요청 전용 상태를 통합 데이터 refresh 상태에서 분리했다. 온보딩 진행 모델은 요청 완료 시에만 다음 단계로 이동하며 실패한 “모두 허용”은 해당 단계에서 멈춘다. `testPermissionOnboardingDoesNotAdvanceWhenRequestDidNotComplete` 통과.
- iOS Simulator 앱 테스트 2/2 통과 (`** TEST SUCCEEDED **`), test 빌드 완료. 로그에 SDK StoreKit 헤더의 기존 deprecated 경고 1건이 있으나 앱 소스 오류는 없다. `git diff --check` 통과.
- 기존 전체 앱 테스트에서 실패한 16개를 개별 재실행해 16/16 통과했다. 실제 수정은 스틱맨 action cache가 destination/sleep input을 키에 누락한 문제였고, 나머지는 최신 RPG 지도·시간 레일·영어 카탈로그 동작에 맞춰 회귀 기대를 갱신했다. `build/validation/ALLT0927A1/failure-regressions-01.log`, `failure-regressions-01.xcresult`.
- V4 snapshot 파일은 timestamped immutable generation으로 저장하고 raw generation ID와 snapshot ID를 분리해 CloudKit Development manifest에 각각 기록한다. 같은 월의 snapshot은 parent ID를 보존해 같은 parent에서 갈라진 generation을 복원 시 병합한다. 순차 snapshot은 최신 내용이 조상보다 우선해 설정이 되돌아가지 않는다. 저장 후 readback과 삭제 generation 검사도 유지한다.
- 새 manifest·immutable 경로·동일 월 동시 세대 병합 3/3, 그 뒤 SecurityBackupCore 전체 113/113 통과. 로그: `snapshot-generation-tests-01.log`, `security-backup-suite-02.log`; 결과 `snapshot-generation-tests-01.xcresult`, `security-backup-suite-02.xcresult`. 기존 manifest JSON decode 호환과 snapshot 덮어쓰기 거부도 포함한다.
- 전체 앱 테스트를 새 iPhone 17 Pro 시뮬레이터(iOS 26.5)에서 직렬 실행해 **1,412 통과·1 건너뜀·실패 0(총 1,413)**을 확인했다. 과거 전체 테스트 실패 16건도 이 결과에 포함되어 통과했다. 유일한 건너뜀은 `testStoreKitProductPurchaseEntitlementAndRestore`; iOS 26.5 StoreKitTest의 `SKInternalErrorDomain Code 3`로 실행되지 않았다. IAP 판매 작업은 계속 보류한다. 기존 검증 시뮬레이터에서는 테스트 번들 설치 경로가 사라져 케이스 시작 전 실패했으므로, 그 결과는 테스트 실패로 세지 않고 새 시뮬레이터에서 재실행했다. 최종 결과 `build/validation/ALLT0927A1/app-tests-full-final2.xcresult`, 로그 `app-tests-full-final2.log`.
- V1·V2·V3 snapshot archive를 다음 저장 시 V4 immutable generation으로 전환하면서 구버전 원본을 남기는 회귀 3/3 통과. 로그 `legacy-migration-final.log`, 결과 `legacy-migration-final.xcresult`. V4 snapshot paging은 source payload 전체와 암호화 frame을 여전히 메모리에 둔다.
- V3 raw archive 복호 뒤 같은 payload를 V4로 재봉인하고 기존 generation 파일을 남기는 집중 회귀 1/1 통과. 로그 `legacy-raw-v3-reseal.log`, 결과 `legacy-raw-v3-reseal.xcresult`. 이 테스트는 다음 저장 경로와 원본 보존을 확인하지만 DB cursor streaming·복원 staging을 검증하지 않는다.
- App Store Connect API readback에서 기존 1.0(159)이 `VALID`임을 확인했다. 다음 번호 160으로 앱·위젯·Watch·Watch 위젯의 Debug/Release `CURRENT_PROJECT_VERSION` 8곳과 네 개 Info.plist의 `CFBundleVersion`을 맞췄다. 최종 iOS 및 Watch generic Debug 빌드가 모두 성공했고, 산출물의 네 번들 ID에서 1.0(160)을 각각 읽었다. 로그 `ios-debug-final.log`, `watch-debug-final.log`.
- 서명된 Debug 1.0(160)을 iPhone 11 Pro·iPhone 18 Pro Max·iPad Pro에 설치했다. iPhone 18과 iPad `devicectl` 앱 목록 readback은 160이다. iPhone 11 설치 명령은 성공했으나 이후 앱 목록 조회가 timeout 내 응답하지 않아 기기 버전 readback은 대기한다. Watch 직접 설치는 연결 터널 생성 timeout으로 실패했다. 설치본을 실행하거나 화면을 조작하지 않아 실기기 기능 검증은 아니다. 설치 로그 `install-iphone11.log`, `install-iphone18.log`, `install-ipad.log`, `install-watch.log`.
- TestFlight 160 업로드는 아직 하지 않았다. 앱 실행 후 권한 화면·GPS·UI·백업·Watch 계정 연동을 사용자가 확인할 수 있도록 실기기 검증을 대기한다.
- 한 번의 사용자 실기기 세션에서 확인할 체크리스트를 `build/validation/ALLT0927A1/device-session-checklist.md`에 준비하고 Codex 패널에 열었다. 체크 결과는 아직 입력되지 않았으며 어느 기능도 설치만으로 통과 처리하지 않는다.
- README, AGENTS, DEVELOPMENT, 활성 인계 진입점과 지원·개인정보 문서를 대조했다. AGENTS/DEVELOPMENT에 네 번들 `CFBundleVersion` 산출물 readback과 Watch Debug 명령을 명시해 번호 불일치 재작업을 막고, README·지원 문서는 이미 짧은 진입점 구조라 유지했다. 날짜가 붙은 보관 인계문은 역사 자료로 남겼다. 최종 문서·소스 `git diff --check` 통과.
- iPhone 11 실기기 재설치·시작·백그라운드 복귀와 새 충돌 로그, HealthKit 권한 화면 전환은 아직 확인하지 않아 CRAS270927/HK270927A1은 열린 상태다.

## CRAS270927 · iPhone 11 Pro 충돌 보고서 분석 (2026-09-27)

- iPhone 11 Pro (iPhone12,3, iOS 26.7/23H24)에서 iOS의 “Taption Plan 앱이 충돌함” 안내와 현재 화면을 확인했다: `build/validation/CRAS270927/iphone11-current-screen.png`. 공유 버튼은 누르지 않고 기기의 시스템 충돌 로그를 로컬로 복사했다.
- 기기에서 가져온 세 보고서 모두 `EXC_CRASH(SIGKILL)`, `RUNNINGBOARD` 종료 코드 `3735883980` (`0xDEAD10CC`)다. 21:27:31과 21:28:20 보고서는 1.0(158), 21:29:19 보고서는 1.0(159)에서 났다. 원본: `build/validation/CRAS270927/TaptionPlan-2026-09-27-212731.ips`, `TaptionPlan-2026-09-27-212820.ips`, `TaptionPlan-2026-09-27-212919.ips`. 같은 종료가 158에서 이미 발생해 159 설치 시간 초과가 최초 원인은 아니다.
- 159 보고서의 동시 실행 cooperative 스레드는 `AppModel.bootstrap()` → `MigratingPlanRepository.load()` → `SQLitePlanRepository.load()` → `loadFromStore()` / snapshot decode → `PlaceStay.init(from:)` → `TimeSpan.init(from:)`에 있었다. `TaptionPlan/Core/PlanRepository.swift`의 `load()`는 `.lock` 파일 flock을 잡은 뒤 `defer`로 해제하며, 그 사이 `await loadFromStore()`와 Codable 디코딩이 실행된다. 시작 호출은 `TaptionPlan/UX/AppModel.swift`의 `bootstrap()`에서 확인했다.
- Apple은 `0xDEAD10CC`를 앱이 정지 중 파일 또는 SQLite 데이터베이스 잠금을 보유해 OS가 종료한 경우로 설명한다: [Apple EXC_CRASH (SIGKILL) 문서](https://developer.apple.com/documentation/xcode/sigkill?language=objc). 보고서의 `RUNNINGBOARD` 종료와 시작 로드 스택, 코드의 flock 범위가 서로 일치하므로 시작 로드 잠금 유지가 강하게 의심되는 원인이다. 정확히 어느 잠금이 종료 조건을 유발했는지는 보고서만으로 확정할 수 없어 수정·재현이 남아 있다.
- 진단 범위에는 코드 수정, 테스트, 빌드가 포함되지 않았다. `temp.md`의 CRAS270927은 잠금 범위 수정과 동시 읽기/쓰기 회귀 테스트, iPhone 11 시작·백그라운드 복귀 후 새 보고서 확인 전까지 열린 상태다.

## INST270927 · iPhone 11/18 Debug 앱 설치 (2026-09-27)

- 현재 서명된 로컬 Debug 앱 `com.taption.plan` 1.0(159)을 iPhone 11 Pro (iPhone12,3, iOS 26.7)와 iPhone 18 Pro Max (iPhone19,7, iOS 27.2)에 설치했다. TestFlight 업로드·배포는 하지 않았다.
- iPhone 11 Pro는 시작 전 1.0(158)이었다. 설치 명령은 120초 시간 제한을 반환했지만 설치 후 기기 앱 목록에서 1.0(159)을 읽어 확인했다. 로그: `build/validation/INST270927/iphone11-install.log`.
- iPhone 18 Pro Max 설치 명령은 성공했다. 설치 후 두 기기의 앱 목록에서 `com.taption.plan` 1.0(159)을 확인했다. 로그: `build/validation/INST270927/iphone18-install.log` 및 `iphone11-install.log`.
- 제한: 앱을 실행하거나 화면·기능 동작을 확인하지 않았다. 설치 및 버전 readback은 기능 검증을 뜻하지 않는다.

## MARG270927 · 오른쪽 시간 레일 화면 높이·내부 여백 (2026-09-27)

- 오른쪽 시간 레일의 720pt 최대 높이 제한을 없애 상단 날짜 헤더 아래 20pt부터 하단 32pt 여백까지 화면 가용 높이를 사용한다. 활동 구간·시간 라벨의 공통 트랙 위아래 여백은 10pt에서 20pt로 늘렸다.
- 짧은 화면에서는 시간 라벨 행 간격이 최소 24pt가 되도록 전체 보기의 시각 라벨 일부를 생략한다. 충분히 긴 레일에서는 00–24시 라벨을 모두 표시한다.
- 시뮬레이터 회귀 7개 통과: `testTimeSidebarUsesItsOwnExpandedTopAndBottomMargins`, `testMapHomeTimeSidebarTapMapsAndClampsToVisibleRail`, `testFullDayTimelineSpacesHourLabelsOnCompactRail`, `testTimeSidebarHourLabelsKeepAnInnerTrailingMargin`, `testExpandedSidebarRulerSeparatesHourAndMinuteLabels`, `testWeatherTimelineCapsulesAttachFlushToSidebarPanel`, `testWeatherTimelineKeepsItsCenterWhenPlayheadOverlaps`. 최종 근거: `build/validation/MARG270927/layout-tests-final2.log` 및 `layout-tests-final2.xcresult` (`** TEST SUCCEEDED **`).
- 첫 테스트 실행에서는 중앙 탭 좌표가 기존 10pt inset 기준(160pt)이라 새 20pt inset에서 720분 대신 672분으로 매핑됐다. 중앙 좌표를 170pt로 갱신한 뒤 최종 선택 테스트 전부 통과했다. 초기 결과는 `build/validation/MARG270927/layout-tests.log`에 보존했다.
- generic iOS Debug 빌드 통과: `build/validation/MARG270927/debug-build-final.log` (`** BUILD SUCCEEDED **`). 최종 `git diff --check` 통과.
- 제한: 시뮬레이터 수학·레이아웃 테스트로 실제 iPhone별 화면 캡처나 터치 체감까지 확인하지 않았다.

## UN270927B1 · 미확인 세그먼트별 빠른 입력 (2026-09-27)

- 오른쪽 시간 레일의 공용 `?` 버튼을 없애고, 현재 표시 영역에 있는 입력 가능한 각 미확인 세그먼트 옆에 버튼을 배치했다. 가까운 버튼은 시간순을 유지하며 44pt 터치 영역이 가능한 범위에서 겹치지 않도록 조정한다. 오늘의 미래 구간은 표시 대상에서 제외한다.
- 각 버튼은 해당 구간 하나만 시트에 전달한다. 날짜 선택을 숨기고 해당 구간만 입력·저장하며, 빠른 저장 성공 시 시트를 닫는다.
- 시뮬레이터 회귀 7개 통과: `testUnconfirmedReviewTargetShowsAndSelectsOnlyItsSegment`, `testUnconfirmedReviewMarkersStayInRailAndSeparateNearbySegments`, `testUnconfirmedReviewIncludesOnlySortedUnconfirmedIntervals`, `testUnconfirmedReviewClipsTodayAtCurrentMinute`, `testUnconfirmedReviewAvailabilityIgnoresFutureAndConfirmedIntervals`, `testQuickConfirmedIntervalDisappearsFromUnconfirmedReview`, `testPartialUnconfirmedEditPreservesSourceOutsideSelectedSpan`. 근거: `build/validation/UN270927B1/final/focused-tests.log` 및 `focused-tests.xcresult` (`** TEST SUCCEEDED **`).
- generic iOS Debug 빌드 통과: `build/validation/UN270927B1/final/debug-build.log` (`** BUILD SUCCEEDED **`). `git diff --check` 통과.
- 제한: 실기기 화면에서 모든 구간 버튼의 위치·개별 터치·저장 결과는 확인하지 않았다. 빌드와 시뮬레이터 테스트만으로 실기기 기능을 판정하지 않는다.

## RST0920A01 · V4 snapshot/raw pages·CloudKit manifest CAS 부분 구현 (2026-09-27)

- 월 snapshot과 raw archive 쓰기를 V4 페이지 frame으로 전환했다. 기본 한도는 256행/1MiB, 하드 상한은 1,024행/4MiB이며 페이지별 압축·GCM 인증과 metadata/page-index AAD를 적용했다. V1–V3 decoder 호환은 보존했다.
- V4는 페이지별 GCM tag를 각각 검증한다. 한 페이지 인증이 실패하면 해당 페이지를 건너뛰고 남은 페이지의 정상 기록을 복원하며, 유효 페이지가 없으면 archive 오류를 반환한다. 회귀 `testRawSensorV4RestoreSkipsOneCorruptPage`가 300개 중 손상되지 않은 256개 복원을 확인한다.
- Snapshot V4는 각 자료형과 route point를 별도 256행/1MiB 페이지로 분리한다. `testSnapshotV4PagesRoundTripAcrossRoutePointBoundary`에서 300개 route point 페이지 경계 왕복 및 페이지 변조 거부를 확인했다. 저장 원본 모델과 전체 암호화 frame은 메모리에 남으므로 end-to-end memory bound는 아직 보장되지 않는다.
- 개발 빌드에서만 CloudKit manifest actor를 사용한다. device/month generation 참조를 merge하고 change-tag 충돌은 최대 3회 재시도한다. 오프라인 pending 참조는 로컬 보호 파일에 보존한다. retention은 manifest 및 snapshot 참조를 보호하고 미참조 raw generation을 월별 10개 유지한다. Production CloudKit 경로는 비활성이다.
- SecurityBackupCore 111/111 통과, 실패 0: `build/ArchiveDD/Logs/Test/Test-TaptionPlan-2026.09.27_06-10-31-+0900.xcresult` (`** TEST SUCCEEDED **`). 손상 페이지 집중 테스트와 snapshot V4 targeted tests도 통과: `build/validation/RST0920A01/raw-partial-restore-test.log`, `v4-page-and-generation-tests.log`, `v4-page-targeted-final.log`. 앱 iOS Debug 빌드 통과: `build/validation/RST0920A01/app-debug-v4-pages-final.log` (`** BUILD SUCCEEDED **`). `git diff --check` 통과.
- 미완료: DB cursor/file 기반 bounded streaming, V1–V3 자동 1회 migration, 보호된 SQLite staging/recovery journal, snapshot immutable generation 및 기기 간 payload 재병합, 실제 CloudKit Development 기기 경합. 시뮬레이터 테스트는 CloudKit 실서비스 검증을 뜻하지 않는다.

## CAT0926T01 · UIV0926A01 실기기 녹화 판독 (2026-09-27)

- 사용자가 제공한 카메라롤 저장 원본 `/Users/u_mo_c/Downloads/ScreenRecording_09-27-2026 03-59-48_1.MP4`를 판독했다(19.606초, 1126×2436, 60fps). 판독 프레임은 `build/validation/RST0927A01/video-frames/half/`에 보관했다.
- 화랑이·모닥불 마커가 화면에 있는 상태에서 지도가 여러 차례 이동하고, 상세 도로 수준에서 인천·김포권까지 줌 아웃되는 화면 변화를 확인했다. 이 영상 범위에서 마커 주변 지도 팬·핀치줌 통과는 확인됐다.
- 시간축의 00–24 시간 라벨과 활동 색상 스트립, 날씨 아이콘·기온 캡슐을 확인했다. 왼쪽 메뉴와 줌 컨트롤의 하단은 오른쪽 시간 레일 하단과 거의 같은 선에 놓였다.
- 집 상태 콜아웃과 Lv.1 캠프파이어·화랑이 마커는 표시됐다. 화랑이 정지 탭으로 `.cat` 상세 시트가 열리는 장면, 레벨 캡슐 탭으로 하루 요약이 열리는 장면은 영상에서 확인되지 않았다. 따라서 CAT0926T01의 직접 탭과 DYS0927A01의 요약 탭은 미완료로 유지한다.
- FMAP0926R06 경로 재생·진단 로그, PAW0926T05 발자국, 성장 보상 선택 반영도 이 영상만으로 판정하지 않았다.

## MAP0927F01 · Map Home 터치·카메라 반응 개선 (2026-09-27)

- 원인: MapKit 카메라 시작 delegate가 지도 내부 전체 뷰·제스처를 재귀 순회했고, 가시 영역 프레임마다 화랑이 오버레이의 z 위치를 재설정하고 맨 앞으로 재배치했다. MapKit 네이티브 pan/pinch와 메인 스레드 작업이 경쟁했다.
- 수정: 카메라 시작 시 재귀 검색을 제거하고 제스처 연결 스캔은 최대 초당 1회로 제한했다. 화랑이 오버레이의 레이어 승격은 처음 붙을 때만 수행하고, 이동 중에는 좌표 추적만 유지한다.
- 회귀 2개 통과: `testWalkerViewportUpdatesDoNotRestackMapSubviews`, `testWalkerOverlayStaysOutsideAnnotationOrderingAndKeepsFootCoordinate`. 결과 `build/ArchiveDD/Logs/Test/Test-TaptionPlan-2026.09.27_04-16-13-+0900.xcresult` (`** TEST SUCCEEDED **`).
- iOS Debug 빌드 통과: `build/validation/MAP0927F01/build.log` (`** BUILD SUCCEEDED **`). `git diff --check` 통과.
- 서명된 Debug 빌드를 iPhone 11 Pro `00008030-001628201AD2802E`에 설치·실행했다. `devicectl` 앱 목록에서 `com.taption.plan` 1.0/157 readback 완료: `build/validation/MAP0927F01/iphone11-readback.txt`.
- 제한: 설치·실행만으로 손가락 입력 체감은 검증되지 않았다. 실제 드래그·핀치 반응은 카메라롤 저장 영상으로 재확인해야 하며, 그 전에는 기능 통과로 처리하지 않는다.

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

## HME0926A01 · 집 성장·HUD·시간축 부분 구현 검증 (2026-09-26)

- `TaptionPlan/UI/MapHomeView.swift`: 로컬 날짜별 실제 기록/미확인 조건, 하루 +1 성장·연속일/주간 보상 데이터, 연도 archive, 집 레벨 핀과 2월 29일 표시, 하루요약 시트 걸음 수 반영. 앱 활성 복귀 시 오늘 상태를 재평가하고, 현재 시각 이후의 미완성 시간축 구간은 달성 대상에서 제외한다.
- `TaptionPlan/UI/MapHomeTimeSidebar.swift`: 선택 시각 ±1시간만 감싸는 라운드 카드 프레임 및 경계 클리핑.
- `TaptionPlan/Assets.xcassets/HomeEvolution001.imageset`…`HomeEvolution366.imageset`: 366개 기본 SVG 성장 그림. Contents.json 참조 및 SVG 파싱 366/366 통과. 이는 국가별 랜드마크 변형의 완성이 아니다.
- `TaptionPlanTests/FeatureEngineTests.swift`: `MapHomeTimeRailCardTests`, `MapHomeGrowthPolicyTests` 실행 성공. 로그: `build/validation/HME0926A01/feature-tests-final.log` (`** TEST SUCCEEDED **`).
- 앱 Debug 빌드 성공: `build/validation/HME0926A01/app-debug-build-final.log` (`** BUILD SUCCEEDED **`), 고정 `build/ArchiveDD`, `-skipPackagePluginValidation`, `-disable-sandbox` 사용. `git diff --check` 통과.
- 미완료: 주간 보상 선택·땅 직접 연결 배치·화랑이 액세서리 보관함 UI, 실사용 가능한 세계 랜드마크 카탈로그/아트, 전년도 집 열람. 이 기능은 현재 데이터 정책/기본 그림 단계에 머물러 있다. iPhone 실기기 UI/일자 경계 검증도 하지 않았다.
- 첫 검증 기록 시점에는 커밋·push·설치 전이었다. 이후 `f90a7d4` (`HME0926A01: add daily home growth foundation`)를 `main`에 push했고, 서버 `refs/heads/main` readback도 `f90a7d4c13323724c3fb2f20e699283b10a1d10e`였다.
- 서명된 Debug 앱(build 157, bundle `com.taption.plan`)을 iPhone 11 Pro `00008030-001628201AD2802E`, iPhone 18 Pro Max `00008160-000E195A1140000A`, iPad Pro 12.9-inch 6세대 `00008112-000964980E45401E`에 설치했다. 각 기기 `devicectl device info apps` readback에서 앱과 build 157 노출을 확인했다. 이 확인은 설치만 입증하며 실행·UI 기능 검증은 아니다. TestFlight 배포는 하지 않았다.

## SBR0926A01 · 좌우 사이드바 및 홈 성장 콜아웃 (2026-09-26)

- 선택 시안의 하단 탐험 HUD를 제거했다. 홈 마커에 레벨·오늘 성장 상태 콜아웃을 표시하고, 마커 탭으로 하루 요약 시트를 연다.
- 지도 왼쪽 조작 독과 오른쪽 시간축을 공통 뷰포트 프레임에 배치해 시작·끝 높이를 맞췄다. 왼쪽 버튼과 줌을 한 레일 안에서 위·아래로 나누고, 오른쪽 시간축과 크림 종이 표면·테두리·라운드를 통일했다.
- `TaptionPlanTests/MapHomeTimeRailCardTests` 통과: `build/validation/SBR0926A01/rail-tests.log` (`** TEST SUCCEEDED **`). 화면 높이 812·1024pt에서 공통 시작/끝선과 680pt 최대 높이를 검사했다.
- iOS generic Debug 빌드 통과: `build/validation/SBR0926A01/app-debug-build.log` (`** BUILD SUCCEEDED **`). `git diff --check` 통과.
- 시뮬레이터 미리보기: `build/validation/SBR0926A01/simulator-preview.png`. 좌우 사이드바 상·하단 정렬 및 하단 HUD 제거를 확인했다. 시뮬레이터에는 저장된 집 위치가 없어 집 성장 콜아웃은 화면에서 직접 확인하지 못했다. 실기기 저장 영상과 제스처 확인은 남아 있다.
- 변경은 커밋·push·실기기 설치하지 않았다.

## RST0920A01 · 손상 raw 월 건너뛰기 (2026-09-26)

- `PlanRawSensorRestoreAccumulator`는 계정 키로 복호 시도한 raw archive의 decode 실패를 월 단위로 격리한다. 해당 월은 건너뛰며 정상 월 payload를 유지하고, 모든 raw가 손상된 경우에는 `.invalidArchive`를 보고한다.
- 서로 다른 월에 정상 raw와 손상 raw가 있을 때 정상 센서 ID만 복원되는 테스트를 추가했다. 단일 손상 raw는 `.invalidArchive`, 월간 중복 ID 충돌은 기존처럼 전체 raw 복원을 거부한다.
- 대상 테스트 3개 통과: `testRawRestoreSkipsOneCorruptMonthAndKeepsValidMonths`, `testRawRestoreRejectsAValidArchiveSetWithCorruptMonth`, `testRawRestoreRejectsConflictingIDsAcrossMonths`.
- 실행: `xcodebuild test -project TaptionPlan.xcodeproj -scheme TaptionPlan -destination 'platform=iOS Simulator,id=5484EA8D-B979-498B-9BA8-6A4AEFFC9B8B' -derivedDataPath build/ArchiveDD -skipPackagePluginValidation COMPILER_INDEX_STORE_ENABLE=NO OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox'`와 위 세 `-only-testing` 필터. 결과 `build/ArchiveDD/Logs/Test/Test-TaptionPlan-2026.09.26_23-00-10-+0900.xcresult`, `** TEST SUCCEEDED **`.
- V4 청크 포맷·마이그레이션·CloudKit CAS·세대 보존은 아직 구현/검증 전이다.

## HME0926A01 · 주간 집 성장 UI·랜드마크 카탈로그 (2026-09-26)

- 하루 요약에서 집 성장 화면으로 진입하는 버튼을 연결했다. 화면에는 연간 단계 그림/레벨/연속일, 보상 후보 3개 선택, 보상 땅 연결 배치, 화랑이 액세서리 보관·착용, 전년도 집 보관 내역이 표시된다.
- 한국·일본·미국·영국·프랑스·이탈리아·중국·스페인·태국·호주 각 5개씩 총 50개 후보를 구성했다. 땅 배치 저장은 optional 필드로 추가해 기존 저장 JSON과 호환되게 했다.
- `MapHomeGrowthPolicyTests` 통과(11개): 기존 성장/366개 리소스 검증에 더해 10개국×5 후보, 주간 후보 3개, 연결 땅 중복 방지/인접성을 확인했다. 로그 `build/ArchiveDD/Logs/Test/Test-TaptionPlan-2026.09.26_23-07-47-+0900.xcresult`.
- 화랑이 액세서리는 인벤토리에서 착용/해제하고 지도 마커에도 표시되도록 연결했다. 저장 호환 테스트에서 새 땅 배치 필드 없이 저장된 구버전 시즌 JSON을 정상 decode하는 것을 확인했다.
- 최종 관련 회귀 재실행: `MapHomeGrowthPolicyTests` 12개와 raw 복원 3개 통과. 로그 `build/validation/HME0926A01/combined-regressions-final.log`, 결과 `build/ArchiveDD/Logs/Test/Test-TaptionPlan-2026.09.26_23-20-08-+0900.xcresult`.
- generic iOS Debug 빌드 통과: `build/validation/HME0926A01/app-debug-final.log` (`** BUILD SUCCEEDED **`). 이 빌드와 App Group 주입 반영본을 iPhone 11 Pro·iPhone 18 Pro Max·iPad Pro에 설치했고 각 기기에서 `com.taption.plan` 버전 1.0 / 빌드 157을 readback했다. 설치는 UI 기능 검증이 아니다.
- 아직 남음: 실기기 레이아웃/보상 경험 확인. 과거 집은 연도·레벨·진화/땅 요약으로 열람 가능하며 별도 집 화면은 없다.
- 2026-09-27 에셋 재검증: 랜드마크 후보 50개 모두 고유 image set과 파일 참조를 가지며, 50개 SVG XML 파싱 오류가 없었다. 기존 366단계 집 그림은 보존되어 있다.

## PKG0920A01 · App Group host 주입

- Core에 `TaptionPlanAppGroupProviding`, 고정 provider, 동기화된 주입 API를 추가했다. 앱·Watch·iPhone 위젯·Watch 위젯의 초기화에서 기존 `group.com.taption.plan`을 host가 주입하며, Core는 기본값 fallback을 유지한다. `TaptionPlanDeviceLocalStorage`도 공통 주입 식별자로 컨테이너를 찾는다.
- package contract 테스트에서 provider 변경, 빈 식별자 무시, reset 후 기존 기본 ID 회귀를 통과했다. 명령 `swift test --package-path Packages/TaptionPlanCore --scratch-path build/validation/PKG0920A01/core-tests --filter CoreEngineContractsTests/testSharedContainerUsesHostProviderAndPreservesDefaultIdentifier`.
- 전체 Core package 100/100 통과: `build/validation/PKG0920A01/core-tests-final.log`. 앱 generic Debug 빌드 통과. 최종 설치본은 위 HME 기록의 세 기기 readback에 포함.
- 아직 남음: Watch/Widget 실제 프로세스별 App Group 데이터 연속성과 기존 컨테이너 파일 readback 실기기 검증.

## BRT0920A01 · generation 정리의 참조 안전성 (2026-09-26)

- 코드 검토에서 File raw store가 같은 달 generation 파일을 수정 시각 기준 최근 10개로 pruning하면서 snapshot의 committed ID나 다른 기기의 offline 참조를 조회하지 않는 점을 확인했다. 삭제 오류도 `try?`로 무시했다.
- 참조를 확인할 CloudKit manifest가 아직 없으므로 자동 pruning을 제거해 저장된 generation을 보존한다. 정리 정책은 참조 목록을 제공하는 CAS manifest 구현 뒤 다시 연결해야 한다.
- 12개 raw generation을 저장한 뒤 모두 남는 것, committed generation 보존, 손상 월 일부 복원 회귀 통과. 로그 `build/validation/HME0926A01/backup-safety-regressions-final.log`, 결과 `build/ArchiveDD/Logs/Test/Test-TaptionPlan-2026.09.26_23-27-19-+0900.xcresult`.
- 최근 10개 제한·offline 참조 확인·삭제 실패 재시도는 미완료다.

## OVL0926U01 · 집 성장 콜아웃과 화랑이 마커 겹침 (2026-09-26)

- 제공된 실기기 캡처(`/Users/u_mo_c/Downloads/스크린샷, 2026-09-26 오후 11.25.49.png`)에서 집 성장 카드의 오늘 상태가 화랑이 마커에 가려지는 것을 확인했다. `MapHomePlacePin`에서 카드만 위로 42pt 이동했다. 마커, 지도 제스처, 레일 프레임은 바꾸지 않았다.
- `git diff --check` 통과. 앱 Debug 빌드 `build/validation/OVL0926U01/app-debug.log`: `** BUILD SUCCEEDED **`.
- 해당 빌드를 iPhone 11 Pro `00008030-001628201AD2802E`, iPhone 18 Pro Max `00008160-000E195A1140000A`, iPad Pro 12.9-inch 6세대 `00008112-000964980E45401E`에 설치했다. `devicectl device info apps`에서 세 기기 모두 `com.taption.plan` 버전 1.0 / 빌드 157을 readback했다.
- 제공 캡처는 수정 전 화면이며, 수정 후 화랑이·상태 문구 가시성과 지도 제스처는 실제 기기 화면/저장 영상으로 재확인해야 한다. 설치 성공만으로 UI 검증을 통과 처리하지 않는다.

## MUI0926D01 · 지도 홈 좌우 메뉴·통합 집 마커 디자인 시안 (2026-09-26)

- 제공된 실기기 지도 캡처를 참조해 별도 이미지 시안 5개를 생성했다. 왼쪽 독은 짧은 세로형, 하단 가로형, 2×2 압축형 등으로 나누고, 우측 시간 레일과 일체형 집·화랑이 이미지를 각 시안에 반영했다.
- 생성 파일: `/Users/u_mo_c/.codex/generated_images/01a0dd4c-fef3-72b2-b39e-e5c1f14ab959/exec-22014dda-1366-4bd0-8e5e-4fe4b9287477.png`, `exec-4b86347d-336c-4d6c-9176-10f0295247af.png`, `exec-ddcea126-843b-45b4-b74e-f68ab709cf8b.png`, `exec-21e25b2e-34aa-480f-9398-ad7436eaa53e.png`, `exec-ff79150a-f068-4596-8ac4-82d9511cc3b3.png`.
- 시안 이미지 자체는 코드 반영이나 실기기 검증이 아니다. 사용자가 선택한 조합의 구현·검증 내역은 아래 기록한다.

## MUI0926D01 · 선택 시안 구현 및 검증 (2026-09-27)

- 사용자가 시안 2의 우측 레일과 시안 4의 왼쪽 메뉴·집/화랑이 구성 조합을 선택했고, 추가로 좌우 레일 높이를 맞추고 아래로 이동하도록 요청했다. 통합 검토 이미지: `/Users/u_mo_c/.codex/generated_images/01a0dd4c-fef3-72b2-b39e-e5c1f14ab959/exec-55ee3e14-ac51-47e7-8370-383ee257c2df.png`; 높이 맞춤 보정 시안: `/Users/u_mo_c/.codex/generated_images/01a0dd4c-fef3-72b2-b39e-e5c1f14ab959/exec-86bf3272-951e-41f3-a02b-3b1916f66030.png`.
- 공통 레일을 28pt 아래로 이동하되 높이는 유지했다. 우측 레일의 바깥 여백을 줄여 화면 오른쪽에 붙이고, 배경 숫자 트랙을 둥근 실루엣으로 클립했다. 선택 시간 표시는 좁은 캡슐 형태로 바꿨다.
- 집 위치의 사용자 설정 반경 안에 표시 위치가 들어오면 집 안에 작은 흰 고양이를 합성하고, 별도 고양이 마커와 플레이어 방향 화살표를 숨긴다. 집 밖에서는 기존 성장 아트와 별도 화랑이를 유지한다. 기존 액세서리·윤달 표시는 통합 마커에서도 보존한다.
- 신규 `MapHomePresencePolicyTests` 2개와 `MapHomeTimeRailCardTests` 4개, 기존 `MapHomeGrowthPolicyTests`를 실행해 통과했다. 로그 `build/validation/MUI0926D01/ui-tests.log`; xcresult `build/ArchiveDD/Logs/Test/Test-TaptionPlan-2026.09.27_00-17-41-+0900.xcresult`.
- Generic iOS Debug 빌드 통과: `build/validation/MUI0926D01/app-debug.log` (`** BUILD SUCCEEDED **`). 동일 빌드를 iPhone 11 Pro `00008030-001628201AD2802E`, iPhone 18 Pro Max `00008160-000E195A1140000A`, iPad Pro 12.9-inch 6세대 `00008112-000964980E45401E`에 설치했다. 세 기기 모두 `com.taption.plan` 버전 1.0 / 빌드 157 readback.
- 아직 실제 실행 화면·지도 팬/핀치·집 반경 합성 상태를 카메라롤 저장 영상으로 확인하지 않았다. 설치만으로 기능 검증을 완료 처리하지 않는다.

## MUI0927A02 · 선택 시안과 실 UI 일치 보정 (2026-09-27)

- 선택 시안의 왼쪽 압축 메뉴와 분리 줌을 지도 하단에 배치하고, 집 안 화랑이 통합 마커를 기존 `MapHomeHouseMarker` 그림으로 구성하도록 수정했다.
- `MapHomeTimeRailCardTests`, `MapHomePresencePolicyTests`, `MapHomeGrowthPolicyTests` 통과. 로그 `build/validation/MUI0927A02/ui-tests.log`; xcresult `build/ArchiveDD/Logs/Test/Test-TaptionPlan-2026.09.27_00-37-56-+0900.xcresult`.
- Generic iOS Debug 빌드 통과: `build/validation/MUI0927A02/app-debug.log`. 해당 산출물을 iPhone 11 Pro `00008030-001628201AD2802E`에 설치·실행했고 `devicectl`에서 `com.taption.plan` 버전 1.0/빌드 157을 readback했다.
- 실기기 화면과 지도 제스처는 별도 증거 대기이며, 빌드·설치만으로 완료 처리하지 않는다.

## MAP0927T03 · 집 성장 그림 정합 및 지도 드래그 (2026-09-27)

- 집 안 마커 배경을 고정 집 이미지에서 `MapHomeGrowthPolicy.artworkName(level:)`이 반환하는 동일 연도 단계 그림으로 바꾸고 화랑이를 합성했다. 집 위치 마커의 hit-testing을 꺼 UIKit 지도가 집/고양이 영역에서 직접 드래그를 받을 수 있게 했다.
- `MapHomeGrowthPolicyTests`, `MapHomeTimeRailCardTests`, `MapHomePresencePolicyTests` 통과(총 18개). 로그 `build/validation/MAP0927T03/ui-tests.log`; xcresult `build/ArchiveDD/Logs/Test/Test-TaptionPlan-2026.09.27_00-47-52-+0900.xcresult`.
- 앱 Debug 빌드 통과: `build/validation/MAP0927T03/app-debug.log`. 산출물을 iPhone 11 Pro `00008030-001628201AD2802E`에 설치·실행했고 `com.taption.plan` 버전 1.0/빌드 157을 readback했다.
- 수정 화면·팬/핀치 동작은 아직 실제 기기 카메라롤 저장 증거로 확인하지 않았다. 사이드바 시안은 선택 전이므로 코드 반영하지 않았다.
- 사이드바 이미지 시안(최근 캡처를 참조): `/Users/u_mo_c/.codex/generated_images/01a0dd4c-fef3-72b2-b39e-e5c1f14ab959/exec-1a505b1a-8c2e-40fe-a219-26c034d99860.png`, `/Users/u_mo_c/.codex/generated_images/01a0dd4c-fef3-72b2-b39e-e5c1f14ab959/exec-7a2aaf6a-8278-44be-84e3-4d38d0cd4efb.png`, `/Users/u_mo_c/.codex/generated_images/01a0dd4c-fef3-72b2-b39e-e5c1f14ab959/exec-e67e30f5-51de-4424-992d-3942c1f73116.png`.
- 사용자가 2안을 고르며 활동 카테고리 색상 세그먼트가 보여야 한다고 보정 요청했다. 지속 시간에 비례한 연속 색상 구간이 있는 수정 시안 `/Users/u_mo_c/.codex/generated_images/01a0dd4c-fef3-72b2-b39e-e5c1f14ab959/exec-3679919c-2b7b-42eb-bf32-114a6d2f6615.png` 생성. 최종 시안 확인 후 구현한다.
- 후속으로 왼쪽 메뉴의 4개 조작(메뉴·검색·현재 위치·방향)과 아래 분리형 확대/축소 전체를 유지하도록 요청해 최종 검토 시안 `/Users/u_mo_c/.codex/generated_images/01a0dd4c-fef3-72b2-b39e-e5c1f14ab959/exec-70032c3e-37d8-4364-b2c9-357c4ed8822d.png`를 생성했다. 구현 전 최종 확인 대기.
- 좌우 사이드바 하단 위치와 화면 아래 여백을 동일하게 하고 오른쪽 시간축을 아래로 연장하도록 추가 요청받아 시안 `/Users/u_mo_c/.codex/generated_images/01a0dd4c-fef3-72b2-b39e-e5c1f14ab959/exec-f6b3f2d7-b50e-4eba-9e06-6743ab3098c6.png`로 보정했다. 구현 전 최종 확인 대기.

## WTH0927A05 · 시간축 왼쪽 날씨 시안 5개 (2026-09-27)

- 매시간 00–24 표시, 활동 색상 세그먼트, 전체 좌측 조작 버튼, 좌우 같은 하단 여백을 유지하며 날씨 레이아웃 다섯 안을 생성했다. 최종 선택 전 코드는 변경하지 않았다.
- 시안 순서: `/Users/u_mo_c/.codex/generated_images/01a0dd4c-fef3-72b2-b39e-e5c1f14ab959/exec-d20af15e-a2e2-469e-a231-af615941d298.png`, `/Users/u_mo_c/.codex/generated_images/01a0dd4c-fef3-72b2-b39e-e5c1f14ab959/exec-0775b59d-fca1-4b6d-ba64-c325e04bc308.png`, `/Users/u_mo_c/.codex/generated_images/01a0dd4c-fef3-72b2-b39e-e5c1f14ab959/exec-af7d62a2-06e3-4601-bb9f-eeff12be9445.png`, `/Users/u_mo_c/.codex/generated_images/01a0dd4c-fef3-72b2-b39e-e5c1f14ab959/exec-f8da4268-2ce0-4861-a18d-c26fbe66b7ed.png`, `/Users/u_mo_c/.codex/generated_images/01a0dd4c-fef3-72b2-b39e-e5c1f14ab959/exec-6b9a9ece-7d54-4956-9914-f0eecc3d844e.png`.
- 사용자가 3안을 선택해 날씨 셀을 카드 없는 세로형 기호·기온으로 바꾸고 날씨 항목 사이 최소 간격을 확보했다. 전체 하루 보기 시간 눈금은 00–24 매시간 모두 표시한다. 활동 색상 띠, 전체 왼쪽 조작 메뉴, 좌우 레일 정렬은 유지했다.
- 자동 테스트 22개 통과: `build/validation/WTH0927A05/tests.log`, xcresult `build/ArchiveDD/Logs/Test/Test-TaptionPlan-2026.09.27_01-39-16-+0900.xcresult`. iOS Debug 빌드 성공: `build/validation/WTH0927A05/build.log`.
- iPhone 11 Pro `00008030-001628201AD2802E` 설치·실행 완료, `com.taption.plan` 버전 1.0/빌드 157 readback: `build/validation/WTH0927A05/install.log`. 기기 화면 캡처·카메라롤 영상은 아직 판독하지 않아 시각 기능 검증은 대기한다.

## WTH0927A06 · 날씨 전용 레일 / HSM0927A06 · 집 성장 요약 펼침 (2026-09-27)

- 3안 적용: 지도 위 작은 날씨 텍스트 대신 시간 레일에 붙는 크림색 세로 레일에 예보 시각·아이콘·기온을 정렬했다. 예보가 비어 있으면 선택 시간 위치에 `날씨 없음`을 표시한다. 레일 행은 최소 44pt 간격을 확보하고, 기존 활동 색 띠·매시간 눈금은 유지했다.
- 집 요약은 화랑이가 집에 있을 때도 집 그림 위에 표시한다. 기본 캡슐은 레벨·오늘 상태·진행을 보여주며, 캡슐을 누르면 연속일과 대기 주간 보상이 펼쳐진다. 지도 드래그를 위해 집 그림과 화랑이 이미지 자체의 hit-testing은 끈다.
- 관련 테스트 20개 통과: `build/validation/WTH0927A06-tests.log`, xcresult `build/ArchiveDD/Logs/Test/Test-TaptionPlan-2026.09.27_02-10-01-+0900.xcresult`. 앱 iOS Debug 빌드 성공: `build/validation/WTH0927A06-build.log`.
- iPhone 11 Pro `00008030-001628201AD2802E`에 설치·실행했고 앱 `com.taption.plan` 1.0/157 readback: `build/validation/WTH0927A06-install.log`. 실제 화면 가독성, 요약 펼침, 지도 드래그는 카메라롤 저장 화면/영상 판독 전까지 미검증이다.

## DYS0927A01 · 레벨 버튼이 하루 요약을 하단에서 열기 (2026-09-27)

- 집 성장 캡슐의 집 아이콘·레벨 영역을 누르면 기존 `MapHomeDaySummarySheet`를 표시하도록 연결했다. 펼침 화살표는 연속일·주간 보상 요약을 열고 닫는다.
- 관련 회귀 테스트 18개 통과: `build/validation/DYS0927A01/tests.log`, xcresult `build/ArchiveDD/Logs/Test/Test-TaptionPlan-2026.09.27_02-14-27-+0900.xcresult`. 앱 iOS Debug 빌드 성공: `build/validation/DYS0927A01/build.log`.
- iPhone 11 Pro `00008030-001628201AD2802E` 설치·실행, `com.taption.plan` 1.0/157 readback: `build/validation/DYS0927A01/install.log`. 실제 레벨 탭 후 하단 시트 표시 여부는 카메라롤 증거로 확인 대기.

## SBW0927A01 · 시간 사이드바·날씨 배치 참고 시안 적용 (2026-09-27)

- 긴 날씨 패널을 제거하고 시간 레일 왼쪽에 아이콘·기온 가로 캡슐을 예보 시각 높이로 표시했다. 캡슐 폭은 60pt, 시간 레일은 44pt로 줄였다. 기존 활동 색상 띠, 매시간 00–24 눈금, 선택 시간 표시는 보존했고 왼쪽 메뉴·좌우 하단 정렬은 변경하지 않았다.
- 회귀 테스트 5개 통과: `build/validation/SBW0927A01/targeted-tests.log` (`testWeatherTimelineCapsulesAttachFlushToSidebarPanel`, `testWeatherTimelineKeepsItsCenterWhenPlayheadOverlaps`, `testWeatherRailKeepsTheSelectedValueWithoutStackingLabels`, `testSidebarSelectionTimeBlockFitsTheExistingRailWidth`, `testSidebarHandleLaneContainsExpandedHitAreaWithoutRailOverlap`). xcresult `build/ArchiveDD/Logs/Test/Test-TaptionPlan-2026.09.27_02-39-38-+0900.xcresult`.
- 앱 generic iOS Debug 빌드 성공: `build/validation/SBW0927A01/build.log`. 빌드 후 수정된 미사용 좌표 계산도 제거했으며 재빌드에서 경고 없이 통과했다.
- 전체 `TimeScaleTests` 실행에서 sidebar 스타일 상수, ruler 폭/선택 시간 폭, 지도 스타일 및 기존 하단 정렬 등 이 요청 바깥 실패가 발생해 실행을 중단했다. 변경에 직접 대응하는 세 테스트는 별도 실행해 모두 통과했다. 중단 로그: `build/validation/SBW0927A01/test.log`.
- 실기기 설치·실행은 완료했으나 실제 화면을 카메라롤 저장 파일로 판독하지 않았다. 캡슐 판독성과 겹침은 해당 증거 확인 전까지 대기한다.
- 요청된 iPhone 11 Pro `00008030-001628201AD2802E`에 위 빌드를 설치·실행했고, `devicectl`에서 `com.taption.plan` 버전 1.0 / 빌드 157 readback을 확인했다. 기록 `build/validation/SBW0927A01/install.log`.
- 설치본 화면을 캡처해 `build/validation/SBW0927A01/device-screen.png`에서 가로 날씨 캡슐, 활동 색상 띠, 매시간 눈금, 선택 시간 캡슐 간 간격 및 좌우 하단 정렬을 확인했다. 이는 직접 기기 screenshot이며, 프로젝트 기준의 카메라롤 저장 영상 판독과는 구분한다.

## 전체 temp 실행 · 2026-09-27 진행 기록

- 화랑이 지도 탭은 `SpatialTapGesture` 좌표를 현재 화랑이 중심점과 비교해 반경 36pt 안 정지 탭에서 기존 `.cat` 상세를 연다. 드래그/핀치 핸들러는 변경하지 않았다. 기하 경계 회귀 테스트 `testCatTapRoutingAcceptsOnlyTapsInsideMarkerBounds` 통과: `build/validation/RST0927A01/test-cat-tap.log`.
- 집 성장 주간 후보 50개에 각기 별도 SVG 에셋을 생성하고 후보 카드에 연결했다. 366단계 SVG는 수정하지 않았다. SVG XML parse 통과, asset 포함 앱 Debug 빌드 성공: `build/validation/RST0927A01/build-landmark-assets.log`.
- 백업 V4/CloudKit CAS는 아직 구현하지 않았다. 현 구조는 월 archive 전체 payload 단일 AES-GCM, iCloud 파일 저장이며 raw 조회 page cursor만 256행·1MiB 기본 제한을 제공한다. staging/recovery journal 및 offline/referenced-generation-aware CloudKit manifest가 없어 기존 복원·혼합 버전 계약을 더 설계 중이다. 기존 Core 테스트 baseline 100/100은 `build/validation/RST0927A01/core-tests.log`에 있다.
- 최종 변경 화랑이 집/이동 좌표 경계 테스트 통과: `build/validation/RST0927A01/test-growth-cat-assets-final.log`. 후보 50개/국가당 5개 및 에셋 이름 회귀 테스트 통과: `build/validation/RST0927A01/test-landmark-catalog.log`. 최신 generic iOS Debug 빌드 성공: `build/validation/RST0927A01/build-final.log`.
- 전체 진행 중 재실행한 지도 오버레이 카메라 갱신 회귀와 화랑이 좌표 탭 회귀가 통과했다. `build/validation/RST0927A01/open-items-regression.log`; 랜드마크 국가·후보 회귀도 개별 재실행 통과했다. `build/validation/RST0927A01/test-landmark-catalog-final.log`.
- build 157을 iPhone 11 Pro·iPhone 18 Pro Max·iPad Pro에 설치하고 `com.taption.plan` 1.0/157을 readback했다. 로그: `build/validation/RST0927A01/install-iphone11.log`, `install-iphone18.log`, `install-ipad.log` 및 해당 `readback-*.txt`. 설치본 화면·제스처는 카메라롤 영상 검증 전이라 미판정이다.
- 실기기 기능, 카메라롤 영상, Watch/App Group 연속성, GPS·수면·백업·캘린더·장시간 사용은 판정하지 않았다.
# TF0927A001 · main push 및 TestFlight 빌드 (2026-09-27)

- App Store Connect API readback에서 앱 `com.taption.plan`의 최신 처리 완료 빌드는 157이었다. 새 TestFlight 빌드 중복을 피하려고 앱·Widget·Watch 타깃 `CURRENT_PROJECT_VERSION`을 158로 올렸다.
- `swift test --package-path Packages/TaptionPlanCore`: 100/100 통과. 기존 백업 회귀 111개 통과 근거는 `build/validation/RST0920A01/security-backup-regressions-final.log`에 보존돼 있다.
- 이번 전체 앱 시뮬레이터 테스트 시도에서 13개 테스트 실패가 기록됐고, 시뮬레이터가 앱을 다시 시작하지 못한 뒤 진단 수집이 정지해 결과 번들이 완성되지 않았다. 로그: `build/validation/TF0927A001/app-tests.log`. 실패: `MapHomeStickmanTests.testDestinationActionsUseCompanySchoolAndRestaurantSemantics`, `MapHomeStickmanTests.testIPhoneOnlySleepDoesNotClaimAppleWatchPriority`, `TimeScaleTests.testExpandedSidebarRulerLabelsStartAfterTickColumn`, `TimeScaleTests.testLegacyMapStylesRemainDecodableButRuntimeIsWBSApple`, `TimeScaleTests.testMapDisplayStyleIncludesSimplifiedAndUnknownValuesFallback`, `TimeScaleTests.testMapDisplayStyleNormalizesPersistedAndMissingValuesToWBSApple`, `TimeScaleTests.testMapHomeOverlayUsesSharedBottomMarginAndUniformControlSpacing`, `TimeScaleTests.testMapHomeVectorStylesKeepOnlyStyledRoadMapLayers`, `TimeScaleTests.testSidebarRulerFontStaysFixedAcrossAllZoomSteps`, `TimeScaleTests.testSidebarSelectionHandleUsesApprovedWhiteAndDeepPinkStyle`, `LocalizationCatalogTests.testEveryCatalogKeyHasAnEnglishValue`, `FeatureEngineTests.testMapHomePastelPaletteKeepsCategoriesVisuallySeparated`, `FeatureEngineTests.testMapHomeSidebarUsesDistinctMajorCategoryVisuals`. 이 실패들은 통과로 처리하지 않는다.
- 랜드마크 에셋 검증 스크립트에서 10개국 50개 asset catalog와 SVG XML 50개가 모두 유효했다. `git diff --check`도 통과했다.
- main 변경 커밋 `94859b9`를 `origin/main`에 push하고 `git ls-remote`로 동일 SHA를 확인했다. archive `build/ArchiveDD/Archives/TaptionPlan-158.xcarchive`는 `** ARCHIVE SUCCEEDED **`; export/upload 로그 `build/validation/TF0927A001/export.log`에 `Upload succeeded`, `Uploaded TaptionPlan`, `** EXPORT SUCCEEDED **`가 기록됐다.
- App Store Connect 빌드 ID `dba98e5e-61e0-4997-8639-5217b656f8ab`, 버전 1.0(158), `processingState=VALID`를 API로 확인했다. `TP Taption Plan 내부 테스트` 그룹 ID `b4857e5e-d1ff-4bc2-b9ad-a69bcd4603fd`에 연결하고 그룹 `/builds` 목록에서 158을 readback했다. App Store Connect 그룹 화면에도 `빌드 1.0 (158) 내부`가 표시되고 상태 `테스트 중`, 그룹 테스터 1명으로 확인했다.
- 배포 프로파일이 없어 App Store Connect API로 App/Widget/Watch/Watch Widget의 App Store 프로파일을 만들고 수동 배포 서명에 사용했다. API key 인증을 Xcode export에 전달해야 했으며 인증 정보는 저장소에 기록하지 않았다.
- Xcode archive 경고: MapLibre.framework의 dSYM UUID `19E85E5A-837A-3278-87A6-FA63D4B799E5`가 포함되지 않아 해당 프레임워크 crash symbolication은 제한될 수 있다. 업로드와 Apple 처리에는 영향이 없었다.
- 전체 앱 테스트는 위 13개 실패 및 시뮬레이터 재실행/진단 수집 오류로 완주하지 못했다. 이 실패들은 해결·통과 처리하지 않았고 별도 재검토가 필요하다. Core 100/100과 보존된 SecurityBackupCore 111/111 결과만 통과 근거로 남긴다.

## UNQ0927A001 · 미확인 활동 빠른 입력 및 시간 눈금 inset (2026-09-27)

- 오른쪽 시간 사이드바의 `?` 버튼을 추가해 미확인 시간 구간만 시간순으로 확인한다. 구간을 누르면 목록 시트를 닫고 기존 활동 구간 편집기로 연결한다. 확인할 구간이 없으면 완료 안내를 표시한다.
- 시간 레일의 숫자 눈금에 6pt 안쪽 여백을 적용했다. 분 단위 눈금 위치와 활동 색상 레일은 유지했다.
- 회귀 테스트 2개 통과: 미확인 구간 필터/정렬 및 중앙 분 선택, 사이드바 숫자 inset. 실행 로그 `build/validation/UNQ0927A001/targeted-tests.log`, xcresult `build/ArchiveDD/Logs/Test/Test-TaptionPlan-2026.09.27_15-20-08-+0900.xcresult`.
- generic iOS Debug 빌드 성공: `build/validation/UNQ0927A001/debug-build.log`. `git diff --check` 통과.
- 실기기 시각 판독은 하지 않았다. `?` 버튼 위치와 시트 전환 체감은 기기 화면으로 별도 확인이 필요하다.

## UNQ0927B01 · HME0927B02 · CAT0927B03–CAT0927B08 (2026-09-27)

- 미확인 목록에서 최근 7일 전부터 오늘까지 날짜를 바로 이동하고, 각 구간의 활동 칩을 눌러 기존 `ActivitySectionEditRequest` 저장 경로로 즉시 입력한다. 오늘의 미래 구간은 목록에 내지 않으며, 저장 실패는 행 안에 표시한다. 시간 행을 누르면 기존 상세 편집기로 이동한다.
- 최근 7일의 미완료일은 전체 구간을 확인한 직후 날짜당 한 번만 해당 연도의 집 레벨을 올린다. 소급 보상은 연속 달성·주간 후보·땅·화랑이 액세서리를 지급하지 않는다. 연말 완료는 이전 연도 집 archive에 적용한다. 정상 일일 달성과 소급 달성의 중복 지급을 막는다.
- 화랑이 재생 간격을 기존의 약 4배로 늘렸다. 미확인은 갸웃·물음표, 업무는 모니터 앞 왕복, 공부는 책 앞 왕복, 취미는 순환 음표, 수면은 호흡·Zzz, 운동은 회전하는 캣휠과 달리기 포즈를 표시한다. 지도 마커와 작은 글리프에 같은 표현을 사용한다.
- 관련 23개 테스트 통과: `build/validation/MULT0927B01/targeted-tests-final.log`, xcresult `build/ArchiveDD/Logs/Test/Test-TaptionPlan-2026.09.27_15-43-54-+0900.xcresult`. 날짜 경계, 중복 보상, 액세서리 미지급, 구형 성장 데이터 디코딩, 미확인 구간 입력 후 목록 제외, 카테고리 동작·속도를 확인했다.
- 지난 날짜 보상 시 미정산 날짜의 실제 기록을 다시 판정하도록 마무리한 뒤 집 성장 정책 17개를 재실행해 통과했다: `build/validation/MULT0927B01/growth-final.log`.
- 앱 generic iOS Debug 빌드 성공: `build/validation/MULT0927B01/debug-build.log`. `git diff --check` 통과. 시뮬레이터 실행 화면 `build/validation/MULT0927B01/simulator-home.png`에서 오른쪽 `?` 진입점과 시간 눈금의 배치를 확인했다.
- 실제 기기에서 빠른 입력 저장·집 레벨 보상 readback·화랑이 동작 속도 및 표현은 아직 판독하지 않았다. 시뮬레이터 홈 화면 캡처는 이 검증을 대체하지 않는다.
## REV0927C01 · 빠른 입력 원본 보존·자정 정산·버튼 터치 영역 (2026-09-27)

- 부분 편집에서 선택 범위 바깥의 수동 기록을 별도 조각으로 남기고, 저장소 재조회 시 해당 조각까지 확인하도록 수정했다. 소급 보상이 거절돼도 먼저 수행한 미정산 날짜의 정산 결과를 저장한다. `?` 버튼의 표시 원형은 26pt로 유지하고 실제 터치 영역은 44pt로 확대했다.
- 회귀 테스트 2개 통과: 원본 미확인 기록의 편집 범위 밖 보존과 보상 거절 시 자정 정산. 로그 `build/validation/REV0927C01/targeted-tests.log`, xcresult `build/ArchiveDD/Logs/Test/Test-TaptionPlan-2026.09.27_16-35-37-+0900.xcresult`.
- generic iOS Debug `BUILD SUCCEEDED`: `build/validation/REV0927C01/debug-build.log`. `git diff --check` 통과.
- 실기기에서 빠른 입력 저장 결과와 버튼 터치감은 확인하지 않았으므로 `temp.md`의 검증 대기로 유지한다.

## TFL0927C01 · main push 및 TestFlight 159 (2026-09-27)

- 지도 UI·빠른 입력·성장 보상 변경을 `0e1977e`로, 앱·Widget·Watch·Watch Widget의 Info.plist 빌드 번호 159 정정을 `6cb630e`로 main에 커밋·push했다. 첫 archive는 프로젝트 설정만 159이고 Info.plist가 158이라 업로드가 중복 번호로 거절됐다. 네 Info.plist를 수정한 최종 archive의 앱·Widget·Watch 번들 번호가 159임을 확인했다.
- 최종 archive `build/ArchiveDD/Archives/TaptionPlan-159-final.xcarchive`가 `ARCHIVE SUCCEEDED`, `build/validation/TFL0927C01/export-final.log`에 `Upload succeeded`, `Uploaded TaptionPlan`, `EXPORT SUCCEEDED`가 기록됐다. 첫 실패와 수정 근거는 같은 폴더의 `export.log`, `archive-final.log`에 보존했다.
- App Store Connect API에서 빌드 ID `d5a86231-c08b-4dc2-859f-5d00211b1020`, 버전 159, `processingState=VALID`를 확인한 뒤 `TP Taption Plan 내부 테스트` 그룹에 연결했다. 그룹 빌드 화면에서 `1.0 (159) 내부`가 `테스트 중`으로 표시되고, 그룹에 테스터 1명·빌드 118개가 표시됨을 확인했다.
- 이번 배포는 설치·실기기 기능 검증을 대신하지 않는다. 앞선 전체 앱 테스트의 미해결 실패 13개도 통과로 처리하지 않았다.

## D270927A01 · 개발 문서 정합성·작업 문맥 절약 (2026-09-27)

- `README.md`를 짧은 시작점으로 바꾸고, 개발 규칙은 `AGENTS.md`, 구조·명령은 새 `DEVELOPMENT.md`, 상태·근거는 기존 `temp.md`·`test.md`의 요청 ID 구간에서 읽도록 나눴다.
- Codex/Kiro의 활성 인계문은 각각 5줄로 줄였다. 과거 Codex 9/25 push 문서와 Kiro 9/23 상세 인계문은 원문 본문을 날짜가 명시된 보관본으로 옮기고, 보관 안내를 덧붙였다. Codex 9/26 인계에도 오래된 상태를 따르지 말라는 표시를 추가했다. `PRIVACY.md`, `SUPPORT.md`, 기존 미완료 요청과 검증 기록은 변경하지 않았다.
- 12개 Markdown 문서의 로컬 링크·끝 공백·충돌 표시를 확인해 통과했다. `git diff --check`도 통과했다. `xcodebuild -list`에서 `TaptionPlan` scheme과 대상 프로젝트를 확인하고 개발 안내의 소스 경로를 현재 저장소와 대조했다.
- 이 변경은 문서 전용이므로 앱 테스트·빌드는 실행하지 않았다. 문서 명령은 예시이며 실제 동작 변경 시 관련 테스트와 Debug 빌드를 별도로 실행한다.

## HK270927A1 · 첫 실행 HealthKit 허용 후 온보딩 정체 확인 (2026-09-27)

- `AppShellView`에서 현재 단계의 `허용하기`·`건너뛰기` 두 버튼은 `model.isRefreshingIntegrations`에 함께 비활성화되지만, 하단 `모두 허용`은 `isRequesting`만 검사한다.
- 첫 활성화는 지연 foreground refresh를 예약한다. `refreshEnabledData`도 같은 `isRefreshingIntegrations`를 켠다. 그 사이 `requestHealth`는 무표시로 반환할 수 있고, 온보딩 `request(_:)`는 요청이 실제 수행됐는지와 무관하게 `advance()`를 호출한다. 따라서 첨부 화면처럼 개별 버튼이 비활성화되고 하단 전체 허용만 동작하는 경로가 코드상 가능하며, 전체 허용 경로는 권한 요청을 건너뛴 채 넘어갈 수도 있다.
- 기존 `FeatureEngineTests`에는 온보딩 표시 조건 테스트는 있지만 이 화면의 버튼 잠금·요청 진행 중 전환 테스트는 없다. 스크린샷의 희미한 버튼과 코드의 비활성화 조건이 일치한다. 단, 기기 로그나 실행 중 상태를 받지 않아 해당 캡처 순간 어떤 refresh가 잠금을 잡았는지까지는 확인하지 못했다.
- 소스는 수정하지 않았고 앱 테스트·빌드는 실행하지 않았다. 수정과 동적 검증은 `temp.md` HK270927A1에 열린 항목으로 남겼다.
- 사용자가 로그 업로드를 알린 뒤 현재 대화 첨부와 `~/Downloads` 최상위 파일을 재확인했다. 확인된 것은 이미지와 화면 녹화뿐이며 `.log`, `.ips`, `.crash` 진단 파일은 없어 로그 기반 재현 원인은 여전히 확인하지 못했다.

## UI270927A1 · 오른쪽 시간축 여백·미확인 입력 버튼 (2026-09-27)

- 시간축만 상단 20pt·하단 32pt 여백으로 확장하고 눈금 안쪽 여백을 10pt로 줄였다. 지도 조작 버튼 레일은 기존 위치를 유지한다. `?` 버튼은 시간축 하단으로 옮겼으며, 선택 날짜에서 현재까지 입력할 미확인 구간이 있을 때만 활성화된다.
- 신규 테스트 2개 통과: `testTimeSidebarUsesItsOwnExpandedTopAndBottomMargins`, `testUnconfirmedReviewAvailabilityIgnoresFutureAndConfirmedIntervals`. 기존 회귀 테스트 5개 통과: 미확인 구간 정렬, 오늘 현재 시각 자르기, 빠른 확정 후 목록 제거, 시간축 탭 매핑, 고주사율 드래그 결과 일치. 7개 선택 테스트 결과는 `build/validation/UI270927A1/final-tests.log`에 있다.
- iOS generic Debug 빌드 `BUILD SUCCEEDED`; `git diff --check` 통과. 최종 빌드 로그는 `build/validation/UI270927A1/debug-build-final.log`다.
- 시뮬레이터 단위 테스트는 통과했지만 실기기에서 간격·터치와 저장 동작은 확인하지 않았다. 해당 확인은 `temp.md` UI270927A1에 열린 상태로 둔다.

## GPS270927A · 포그라운드 실시간 현재 위치·이동 경로 (2026-09-27)

- 원인은 기본 위치 수집이 선택된 GPS 간격마다 짧은 표본 창을 열고 닫아, 앱을 켜 두어도 지속적인 `didUpdateLocations` 흐름이 없던 점이다. 지도는 이미 저장된 현재 위치와 `liveRouteState`를 그리므로 수집 간격이 화면 갱신을 제한했다.
- 위치 기록이 켜져 있고 위치 권한이 허용된 동안 앱이 active이면 Core Location을 정밀도 우선, 5m 이동 간격으로 유지한다. 중복 fix는 건너뛰고 0.5초보다 자주 저장하지 않는다. 새 위치를 SQLite 보관소에 즉시 기록한 뒤 기존 persisted-reading 콜백으로 현재 핀과 경로를 갱신한다. 앱이 background로 가면 포그라운드 모드를 끄고 기존 듀티사이클/Always 권한 기반 수집 정책을 사용한다. 새 Always 권한 요청은 추가하지 않았다.
- 새 회귀 테스트 3개 통과: 활성 화면·설정·권한 게이트, 5분 표본 간격 중 연속 위치 fix 출력, 포그라운드 경로점 즉시 저장. 기존 collector stream 교체 테스트 1개와 `testLiveRouteRequiresPreciseAvailableGPS` 1개도 통과했다. 총 5개 선택 테스트 실패·건너뜀 0건이며 로그·xcresult는 `build/validation/GPS270927A/` 아래에 있다.
- generic iOS Debug 빌드 성공: `build/validation/GPS270927A/debug-build.log`; `git diff --check` 통과. 시뮬레이터에서 자동 검증했으며 실제 기기 GPS·화면 경로·백그라운드 전환은 확인하지 않았다. 이동 경로 선은 기존 정책상 정밀 GPS fix를 요구한다. 실기기 확인은 `temp.md` GPS270927A에 남겼다.

## HOM270927A · 집 마커 탭으로 레벨 플로팅 카드 열기 (2026-09-27)

- 집 레벨·오늘 상태 카드를 기본 숨김 처리하고 집 그림 중앙 탭으로 열고 닫게 했다. 숨겨진 카드가 공간을 계속 차지해 집 핀의 좌표가 열릴 때 이동하지 않는다. 화랑이가 집에 있을 때는 집 아이콘 탭과 화랑이 탭 영역을 분리해 기존 화랑이 상세 진입을 보존했다. VoiceOver에는 성장 정보 표시/숨김 동작을 제공한다.
- 회귀 테스트 2개 통과: `testCatTapRoutingAcceptsOnlyTapsInsideMarkerBounds`, `testHomeIconTapRoutingSeparatesHouseFromHomeCat`. 로그 `build/validation/HOM270927A/tap-routing-final.log`, 결과 `build/validation/HOM270927A/tap-routing-final.xcresult`.
- generic iOS Debug 빌드 `BUILD SUCCEEDED`: `build/validation/HOM270927A/debug-build-final.log`. `git diff --check` 통과.
- 시뮬레이터에서 탭 라우팅 단위 테스트만 실행했다. 기본 카드 가시성·열기/닫기·지도 팬/핀치와 화랑이 상세 탭의 실제 화면 동작은 실기기에서 추가 확인 전이며 `temp.md`에 대기로 남겼다.

## WTH270927B · 현재 날씨 강조·미래 예보 흐리게·위젯 20% 축소 (2026-09-27)

- 관측 날씨(`isForecast != true`)는 불투명도 100%, 미래 예보(`isForecast == true`)는 58%로 표시하고 예보의 접근성 값을 비활성 상태로 알린다. 날씨 캡슐은 기존 60×28pt에서 48×22.4pt로, 내부 아이콘·기온·간격·테두리·그림자도 80%로 줄였다. 축소 후에도 캡슐 우측과 시간 레일 간격은 기존 4pt 정렬을 유지한다.
- 회귀 테스트 5개 통과: `testWeatherTimelineDimsForecastsAndScalesWidgetsToEightyPercent`, `testWeatherTimelineCapsulesAttachFlushToSidebarPanel`, `testWeatherTimelineKeepsItsCenterWhenPlayheadOverlaps`, `testMapHomeWeatherCollapsesConcurrentLocationStreamsForDisplay`, `testMapHomeWeatherPrefersObservedOverSameSignatureForecast`. 로그 `build/validation/WTH270927B/final-tests.log`, 결과 `build/validation/WTH270927B/final-tests.xcresult`.
- generic iOS Debug 빌드 `BUILD SUCCEEDED`: `build/validation/WTH270927B/debug-build.log`. `git diff --check` 통과.
- 시뮬레이터에서 정책·정렬 단위 테스트만 실행했다. 실제 화면에서 축소된 글자 가독성과 현재/미래 대비는 별도 화면 확인 전이라 `temp.md`에 대기 중이다.

## UR270927A1 · 왼쪽 하단 실행취소/다시실행 (2026-09-27)

- 지도 왼쪽 조작 레일의 줌 버튼 아래에 실행취소·다시실행을 세로로 추가했다. 가능한 이력이 없으면 흐리게 표시하고 누를 수 없게 한다. 실행 중 최대 40개의 사용자 일정·수동 활동 편집 이력을 유지하며, 자동 센서 원본은 되돌리지 않는다. 새 편집은 다시실행 이력을 지운다.
- 선택 테스트 3개 통과, 실패·건너뜀 0건: `testActivityEditUndoRedoPreservesAutomaticRecordsAndClearsRedo`(활동 변경 왕복, HealthKit 기록 보존, 새 편집 뒤 다시실행 무효화), `testUserPlanUndoRedo`(사용자 계획 추가 왕복), 기존 `testActivitySectionSaveOverridesTravelAndSupportsImmediateReedit`. 로그·xcresult는 `build/validation/UR270927A1/final-tests.log`, `final-tests.xcresult`에 있다. 첫 컴파일 시 테스트의 `XCTUnwrap`에 `try` 누락이 확인되어 수정한 뒤 최종 테스트를 재실행해 통과했다.
- generic iOS Debug `BUILD SUCCEEDED`: `build/validation/UR270927A1/final-debug-build.log`. `git diff --check` 통과.
- 테스트는 시뮬레이터에서 실행했다. 이번 빌드는 iPhone에 설치하지 않았고, 실제 화면에서 왼쪽 하단 위치·터치감은 확인하지 않았다. 이 화면 확인은 `temp.md`에 대기로 남긴다.

## IN270927A1 · iPhone 18 Pro Max 현재 작업본 설치 (2026-09-27)

- 현재 연결된 실기기는 iPhone 18 Pro Max(`iPhone19,7`, UDID `00008160-000E195A1140000A`), iOS 27.2로 확인했다. 기기 정보 readback은 `build/validation/IN270927A1/device-details.txt` 및 `.json`에 있다.
- 최신 generic iOS Debug 산출물 `com.taption.plan` 1.0/159를 기기에 설치했다. `devicectl` 설치 성공 로그·JSON은 `build/validation/IN270927A1/install.log`, `install.json`; 앱 목록 readback에서 `Taption Plan · com.taption.plan · 1.0 · 159`를 확인했다: `readback.txt`, `readback.json`.
- 사용 요청은 설치였으므로 앱을 실행하거나 화면 기능을 판정하지 않았다. 설치와 readback은 날씨/UI 기기 검증을 의미하지 않는다.

## CAT0928A01 · 회사 넥타이 업무 포즈·학교 안경 학습 포즈 (2026-09-28)

- `MapHomeStickmanAction`에 실제 등록 장소 전용 `.company`/`.school` 표현 상태를 추가했다. resolver는 회사 체류를 회사 업무, 학교 체류를 학교 학습으로 구분하고, 앱 사이드바의 work/study 라벨에서도 회사/학교가 명시될 때만 전용 표현을 선택한다. 일반 업무·수업 카테고리, 독서, 학원은 기존 표현을 유지한다.
- 전용 회사/학교 화랑이는 각각 앉은 포즈로 모니터/책 앞 좌우 움직임을 유지하고, 지도 마커에서만 넥타이/안경 overlay를 표시한다. 다른 고양이 마커와 실제 활동 분류·저장 데이터는 변경하지 않았다.
- `MapHomeStickmanTests` 집중 회귀 3개 통과(실패 0, 건너뜀 0): `testCatActivityScenesUseRequestedActionsAndQuarterSpeed`, `testDestinationActionsUseCompanySchoolAndRestaurantSemantics`, `testMapStickmanResolvesMajorCategoryBeforeActivityDetail`. 최종 결과 `build/validation/CAT0928A01/cat-focused-tests-final4.xcresult` 3/3 통과(실패·건너뜀 0), 로그 `cat-focused-tests-final4.log`. 중간 실행에서 발견된 일반 업무 포즈 회귀와 resolver category alias 문제를 수정한 뒤 이 결과로 확인했다. 첫 실행에서 드러난 상태 수·일반 걷기 기대값 차이는 전용 회사/학교로 수정 후 재검증했다.
- 최종 generic iOS Debug `BUILD SUCCEEDED`: `build/validation/CAT0928A01/ios-debug-build-final.log`. `git diff --check` 통과.
- 실기기 화면 캡처는 하지 않았다. 실제 회사/학교 체류 데이터에서 넥타이·안경 및 모니터·책 포즈가 보이는지는 기기 확인 전까지 `temp.md`에 대기한다.

## UIX0928A01 · 미확인 활동 대분류 2행 전체 표시 (2026-09-28)

- 빠른 입력 대분류 8개를 기존 순서대로 4열×2행으로 배치했다. 버튼별 즉시 저장 동작·색상은 유지했다.
- `TimeScaleTests.testUnconfirmedQuickCategoriesFitInTwoOrderedRows` 통과(1/1): `build/ArchiveDD/Logs/Test/Test-TaptionPlan-2026.09.28_10-38-38-+0900.xcresult`; 같은 실행에 GPS 집중 테스트가 포함됐다.
- generic iOS Debug 빌드는 `build/validation/GPSX0928A1/ios-debug-build-final.log`에서 성공했다. `git diff --check` 통과.
- 실기기 화면은 아직 확인하지 않아 좁은 화면에서의 시각적 겹침/터치감은 `temp.md`에 대기한다.

## GPSX0928A1 · GPS 공백의 회색 예상 발자국 (2026-09-28)

- 지도에만 제한된 GPS 공백 보간을 추가했다. 정규화된 시간순 route readings에서 서로 이웃한 두 기록이 모두 정밀 iPhone GPS fix일 때만 같은 날 45초~5분, 25~600m, 정확도 각 50m 이하, 평균 이동속도 3m/s 이하 구간을 선형 보간한다. 최대 24개 보간 좌표를 약 25m 간격으로 만든다.
- 보간 좌표는 `SensorReading`이나 저장소에 기록하지 않는다. 기존 실측 발자국은 청록색으로 유지하고 예측 발자국만 회색으로 렌더링한다. GPS 외 기록을 건너뛰어 앞뒤를 잇지 않고, Watch·종료 세션·장시간/장거리/부정확 구간은 생략한다.
- `RouteTimelineDataTests.testGPSGapPredictionAddsOnlyBoundedDisplayCoordinates`와 `testGPSGapPredictionRejectsLongInaccurateAndWatchGaps`, `TimeScaleTests.testUnconfirmedQuickCategoriesFitInTwoOrderedRows`가 모두 통과(3/3, 실패/건너뜀 0). 실행 로그 `build/validation/GPSX0928A1/focused-tests-final2.log`, xcresult `build/ArchiveDD/Logs/Test/Test-TaptionPlan-2026.09.28_10-38-38-+0900.xcresult`.
- generic iOS Debug `BUILD SUCCEEDED`: `build/validation/GPSX0928A1/ios-debug-build-final.log`; `git diff --check` 통과.
- 실기기에서 실제 GPS 공백 구간을 재현한 화면은 아직 확인하지 않았다. 예측은 지도 표시용 직선 보간이며 실제 도로·실제 이동 경로를 보장하지 않으므로 화면 확인 전에는 기능의 기기 검증을 완료 처리하지 않는다.

## DINA0928A1 · Dynamic Island 현재 대분류 화랑이·활동명 표시 (2026-09-28)

- 현재 구현이 요청을 이미 충족한다. 센서 수집 Live Activity와 활동 타이머 Live Activity 모두 compactLeading에서 현재 대분류 ID/이름으로 화랑이 동작을 선택하고, compactTrailing에서 같은 현재 활동명을 표시한다. 예를 들어 `movement` 상태에서는 왼쪽이 이동 동작으로 애니메이션되고 오른쪽은 `이동`이다. 실제 현재 활동 projection은 시작 상태에 전달되며 센서 수집 reconciliation 때 갱신된다. 따라서 소스 변경은 하지 않았다.
- `FeatureEngineTests.testLiveActivityContentStateOptionalFieldsDecodeAndRoundTrip` 1/1 통과, `MapHomeStickmanTests.testLiveActivityStickmanResolvesEveryMajorCategory` 1/1 통과. 각각의 xcresult/log는 `build/validation/DINA0928A1/compact-tests.xcresult`, `compact-tests.log`, `category-action-test-verified.xcresult`, `category-action-test-verified.log`에 있다. 첫 resolver 실행은 잘못 지정한 test class로 인해 0건이었으며 성공 근거에 포함하지 않는다.
- 위젯 extension을 포함한 generic iOS Debug `BUILD SUCCEEDED`: `build/validation/DINA0928A1/ios-debug-build.log`. `git diff --check` 통과.
- 실기기 Dynamic Island 캡처는 이번에 확인하지 않았다. 자동 테스트·빌드는 통과했으나 실제 기기의 표시 결과까지 검증한 것은 아니다.

## RPL0928A01 · 9월 24일 기록 재생에서 화랑이·이동 경로 누락 조사 (2026-09-28)

- iCloud 앱 컨테이너의 최신 로그 `TaptionLogs-20260928-123536.txt`에서 9월 24일의 날짜 snapshot 3건을 집계했다. 완료된 snapshot은 `readings=0`, `readings_with_point=0`, `travel=0`, `subway_segment_count=0`, `subway_route_count=0`이었다. 같은 시점 `fmap_route_projection`도 `segment_count=0`, `overlay_count=0`, `overlay_coordinate_total=0`, `dropped_short=0`, `dropped_subway_confirmed=0`으로 끝났고 날짜 로드는 완료됐다.
- 진단은 저장된 활동 항목의 존재와 별개로, 해당 날짜 지도 재생에 공급된 GPS/이동 원본이 없어서 화랑이 좌표와 이동 경로가 생성되지 않았음을 보여준다. 렌더러가 생성된 경로를 누락한 증거는 없다. 이 로그만으로 사용자가 말한 활동 기록 자체의 원본/건수까지 확인할 수는 없다. 원본 위치·건강 데이터는 출력하지 않았다.
- 판정: 현재 증거 기준 데이터 부재로 설명되므로 코드 결함으로 오판하지 않고 조사 요청을 닫는다. GPS가 저장된 9월 24일 기록이 있다고 확인되는 별도 증거가 생기면 새 조사로 연다. 9월 24일 화면을 직접 조작해 캡처한 것은 아니므로 실기기 UI 확인을 완료로 주장하지 않는다.

## HGR0928A01 · 집 성장 초반 단계·투명 마커 크기 (2026-09-28)

- Lv.1 모닥불은 그대로 두고 Lv.2 야영 흔적, Lv.3 천막, Lv.4 개방형 비가림막, Lv.5 목재 골조, Lv.6 지붕을 얹는 오두막, Lv.7 첫 완성 집으로 SVG를 교체했다. 하루 한 단계 성장, 기존 `HomeEvolution001...366` 이름과 연도별 365/366 단계는 보존했다.
- 지도 집 아이콘의 흰색 광륜·크림색 원판·테두리를 제거했다. 투명 여백이 있는 SVG 캔버스는 48pt로 유지해 실제 집 그림이 약 34pt로 보이며 `MapHomeStickmanMarker.size` 36pt에 가깝게 맞춘다. 집 안 화랑이 합성 그림도 같은 48pt 집 크기를 쓰고, 집 상세 탭의 18pt 반경과 48pt 터치 프레임은 유지했다.
- 성장 정책 테스트 18/18 통과(`testAll366EvolutionIllustrationsArePackaged` 포함). 집 아이콘·화랑이 탭 분리 회귀 1/1 통과. 결과 `build/validation/HGR0928A01/growth-policy-tests.xcresult`, `growth-tests.xcresult`; 최초 잘못된 테스트 클래스 경로로 실행해 0건 나온 결과는 성공 근거에 포함하지 않는다.
- generic iOS Debug `BUILD SUCCEEDED`: `build/validation/HGR0928A01/ios-debug.log`. 첫 7개 SVG와 366개 전체 SVG·이미지 세트 존재 및 XML 파싱을 검사했고, `git diff --check` 통과했다. 별도 에셋 미리보기로 Lv.2/3/4/5/6/7 그림을 육안 확인했다.
- 이번 Debug 변경본은 iPhone에 설치하지 않았다. 지도 화면에서 흰색 배경 제거, 화랑이 대비 크기 및 실제 보이는 크기는 기기 캡처 전이라 `temp.md`에 확인 대기로 남긴다.

## HGV0928A01 · 연간 집 성장 경로와 에셋 구조 조사 (2026-09-28)

- 구현을 읽어보면 집 그림은 분기하지 않는다. `artworkName(level:)`가 현재 시즌 레벨과 `HomeEvolutionNNN`을 직접 연결하고, 실제 일 기록이 있고 미확인 구간이 0인 날짜를 닫을 때 하루 최대 +1, 현지 연도의 365/366에서 상한을 둔다. 해가 바뀌면 이전 시즌을 archive하고 Lv.1부터 새로 시작한다.
- 별도 분기는 7일 연속마다 생기는 주간 보상이다. 50개 랜드마크 후보(10개국×5개) 중 3개를 보여 주고 하나를 고르면 진화 후보 ID·연결 배치용 땅 조각·액세서리 ID를 보관한다. 땅 배치와 액세서리 착용은 각각 별도 동작이며, 이 선택은 `HomeEvolution` 그림의 레벨/경로를 변경하지 않는다.
- 자산 검사는 366개 SVG와 카탈로그가 전부 존재하고 파싱됨을 확인했다. SVG의 `Lv.숫자` 텍스트만 정규화해 본문을 문자열 비교하면 총 178개 패턴이며, Lv.8–366은 359개 레벨에 171개 패턴이다. 일부 본문이 반복되며 최장 반복 그룹은 14레벨이다. 이는 SVG 문자열의 정확한 본문 중복 측정이지, 사람 눈에 비슷해 보이는 모양을 합산한 수는 아니다. 별도 랜드마크 에셋은 50개다.
- 레벨 1–7을 한 줄 성장, 매주 보상 선택을 옆 분기로 나타낸 경로도 SVG/PNG를 생성하고 화면으로 확인했다: `build/validation/HGV0928A01/home-growth-path.svg`, `home-growth-path-preview.svg.png`. 원본 코드 파일을 바꾸지 않는 조사·시각화 작업이다.
- SVG 파싱/카탈로그 수와 카운트 검사 통과, `git diff --check` 통과.
- 후속 화면 요청: Lv.8–14의 실제 SVG 7개를 동일한 96×96 viewBox로 나란히 배치한 연락 시트를 생성·육안 확인했다. 파일은 `build/validation/HGV0928A01/levels-8-14-contact.svg`와 `levels-8-14-contact.svg.png`에 있다. 이 구간은 모두 완성된 집이며, 화단·관목·나무·높이 등의 작은 장식 차이가 주 변화다.

## M1280928A1 · Lv.1–28 첫 달 성장 에셋 재구성 (2026-09-28)

- `scripts/generate_home_evolution_artwork.py`의 층수 규칙을 조정했다. 기존 Lv.1–7 도입 그림은 유지하고, Lv.8–14는 1층, Lv.15–21은 2층, Lv.22–28은 3층으로 구성한다. 이후에는 12주 단위로 층이 추가되어 기존 최대 8층 상한을 유지한다. 각 레벨에는 7일 팔레트 순환과 날짜별 주변 소품/강조 요소가 적용된다.
- 48pt 마커 비율 연락 시트를 렌더링해 Lv.1–14와 Lv.15–28의 단계별 실루엣 및 일별 팔레트·장식 변화를 육안 확인했다: `build/validation/M1280928A1/lv1-14.svg.png`, `lv15-28.svg.png` (편집 가능한 SVG 원본도 같은 폴더).
- `PYTHONDONTWRITEBYTECODE=1 python3 scripts/generate_home_evolution_artwork.py --check`: 366개 SVG 본문 모두 고유, 365개 연속 레벨 쌍 모두 다름, 카탈로그 검증 통과.
- `MapHomeGrowthPolicyTests` 18/18 통과, 실패·건너뜀 0: `build/validation/M1280928A1/growth-tests.xcresult`, 로그 `growth-tests.log` (iPhone 17 Pro, iOS 26.5 시뮬레이터).
- iOS generic Debug 빌드 성공: `build/validation/M1280928A1/ios-debug.log`. `git diff --check` 통과.
- 테스트는 성장 정책과 번들 에셋을 검증한다. 실제 iPhone 지도에서 업데이트된 집 그림이 표시되는 장면은 아직 촬영하지 않았다.

## DLY0928A01 · 매일 눈에 띄는 집 성장 변화 (2026-09-28)

- `scripts/generate_home_evolution_artwork.py`를 추가해 기존 Lv.1–7 소개 그림을 보존하고 Lv.8–366을 결정론적으로 생성한다. 일별 7색 지붕/벽 팔레트와 큰 주변 장식을 바꾸며 건물 층과 실루엣을 키운다. 층 간격은 M1280928A1에서 첫 4주 주 1층, 이후 12주 1층으로 조정했다. 기존 `HomeEvolutionNNN` 파일명·96×96 투명 SVG viewBox·레벨 직접 매핑은 유지했다.
- `python3 scripts/generate_home_evolution_artwork.py --check`: 366/366 SVG XML 유효, `Lv.N` 레벨 문구를 제외한 그림 본문 고유 366/366, 인접 레벨 차이 365/365. `--write`로 결과를 재생성하고 다시 `--check`를 통과했다.
- `MapHomeGrowthPolicyTests` 18/18 통과(366개 에셋 bundle 포함): `build/validation/DLY0928A01/growth-tests.xcresult`, 로그 `growth-tests.log`. iOS generic Debug `BUILD SUCCEEDED`: `build/validation/DLY0928A01/ios-debug.log`. `git diff --check` 통과.
- Lv.8–21 연락 시트를 48pt 지도 마커 비율로 렌더링해 색·장식 변화와 15레벨부터의 주간 건축 변화가 읽히는지 육안 확인했다: `build/validation/DLY0928A01/daily-evolution-contact.svg.png`; 편집 가능한 원본은 `daily-evolution-contact.svg`.
- 시각화 수치는 SVG 본문 구조 고유성 검사와 연락 시트 육안 확인 기준이다. 실제 iPhone 지도에 업데이트 에셋이 표시되는 장면은 촬영하지 않았다. HGV0928A01의 178 패턴 수치는 DLY 변경 전의 과거 스냅샷이다.
