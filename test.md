# Taption Plan 실기기 검증

## 2026-09-21 DHB0921C01 · latest-source Device Hub input smoke

- Current-checkout signed iPhone Debug build completed with `** BUILD SUCCEEDED **` (`build/validation/DHB0921C01/device-debug-build-final.log`). The build exposed two compile errors: a default argument referenced covariant `Self`, and `[RouteSample]` was sorted through a `[SensorReading]` helper; both were fixed. The existing `AppleIntegrations.swift:4494` ineffective `@preconcurrency` warning remains.
- Installed and foreground-launched `com.taption.plan` on iPhone 14 Pro/iOS 27.2 without an uninstall, erase, or app-data reset. Readback: version 1.0 (149), app PID 1640, widget PIDs 1642/1650. Launch screenshot: `build/validation/DHB0921C01/device-after-launch.png`.
- Device Hub screen-sharing input moved the date 9/21→9/22→9/21 (`devicehub-date-next-cgevent.png`, `devicehub-date-restored.png`) and toggled Play→Pause→Play→Pause (`devicehub-play-start.png`, `devicehub-play-paused.png`, `devicehub-play-resume.png`, `devicehub-final-paused.png`). Device Hub session view: `devicehub-zoomed.png`. The final screen remains on 9/21 with playback paused.
- `group.com.taption.plan` stayed at `/private/var/mobile/Containers/Shared/AppGroup/1994D500-181A-4605-922F-D502FE93F791`. The app-specific container changed from `11376562-CD27-413D-8DD1-0608D64A186E` to `05EA89FB-E34C-4CE6-95A6-2A8B247EE621`; private-container continuity is unverified. No UI Automation approval, passcode, TestFlight upload, or data deletion was used.
- SwiftPM suites: TaptionPlanCore 90/90, TaptionActivityEngine 28/28, TaptionRouteEngine 38/38, TaptionPlanEngine 1/1 (157/157 total). The concurrent cold-open test first reproduced `SQLITE_BUSY` at WAL activation; a bounded retry for `PRAGMA journal_mode=WAL` fixed the regression.
- This was a short foreground smoke, not a background CPU/watchdog soak or post-fix OS-log readback; those gates remain open.

## 2026-09-21 MPC0921A01 · 날짜 reset·시간 레일 성능

- 1만 개 겹침 후보 시험에서 기존 경계별 전체 후보 재검색과 출처 UUID 재정렬을 heap sweep·누적 집합으로 바꿨다. 동일 `testMapHomeTimeRailDenseCandidateScale` XCTest case elapsed가 iPhone 17 Pro Simulator/iOS 26.5에서 4.1816초에서 0.1399초로 감소했다(약 30배; case 전체 시간 기준).
- 날짜 변경 generation의 stale worker 차단, 날짜별 source 재기반·취소 가능한 정렬 및 출처 ID 병합을 포함한 focused XCTest 7/7 PASS: `build/validation/MPC0921A01-verified-tests.xcresult`. 현재 소스 signed iPhone Debug build도 exit 0: `build/validation/MPC0921A01-device-build-latest.log`.
- iPhone 14 Pro/iOS 27.0의 앞선 rail-fix Debug 설치(1.0/149)는 app/widget PID 2787/2788로 foreground 실행됐고, 지도·9/21 날짜·시간표·재생 컨트롤이 `build/validation/MPC0921A01-device-after-launch.png`에 보인다. 뒤이어 추가한 snapshot rebase worker는 물리 앱에 재설치하지 않았다. Device Hub CUA는 `failed to write kernel assets`로 시작되지 않아 날짜·재생 터치는 미검증이다.
- 설치 readback에서 app-specific data container 경로는 바뀌었고 `group.com.taption.plan` App Group 경로는 유지됐다. 주 SQLite 저장소는 App Group을 사용하지만 음성 메모 등 app-specific 데이터 보존은 확인되지 않았다. 데이터 초기화 명령은 실행하지 않았다.

## 2026-09-21 DHB0921A01 · CoreDevice latest-source readback

- 13:58 KST 현재 checkout의 iPhone 14 Pro/iOS 27.0 (24A437) Debug 빌드가 exit 0으로 끝났다(기존 `AppleIntegrations.swift:4470` `@preconcurrency` 경고). 앱 데이터를 초기화하지 않고 `com.taption.plan`을 교체 설치·전면 실행했으며, 버전 1.0 (149), app PID 2763 및 widget PID 2764/2767을 readback했다. 약 10초 뒤 캡처 `build/validation/DHB0921A01/devicehub-request-postinstall-2026-09-21.png`에서 9/21 지도·시간표·재생 컨트롤 렌더링을 확인했다. Device Hub CUA는 `failed to write kernel assets`로 시작되지 않아 실제 날짜/재생 터치와 XCTest는 미검증이다. Apple Watch SE도 unavailable이므로 WPD HealthKit 삭제 경로의 실기기 확인은 별도 미완료다.

- 17:43 KST current-source device smoke: iPhone 14 Pro/iOS 27.2 (24B5084k), `com.taption.plan` Debug 1.0 (149) build succeeded and installed/launched without a reset command; app/widget PID 970/973 stayed present and `build/validation/DHB0921A01-live-postinstall-r4.png` shows the 9/21 map, time rail, and playback control. Build/install/launch evidence: `build/validation/DHB0921A01-current-source-device-build-r4.log`, `DHB0921A01-device-install-r4.json`, `DHB0921A01-device-launch-r4.json`. Device Hub CUA still fails to write kernel assets, so date/play taps on this source were not tested. App Group path stayed the same, but the app-specific data-container UUID changed during install; continuity of app-private files is unverified.

## 2026-09-21 BGA0921A01 · background sensor-analysis deferral

- `testSensorAnalysisDefersBackgroundReadingsAndCoalescesOnForeground` passed 1/1 with 0 failures (`build/validation/BGA0921A01-background-analysis-r4.xcresult`). Current-source signed Debug build for iPhone 14 Pro/iOS 27.2 succeeded (`build/validation/DHB0921A01-current-source-device-build-r5.log`); app `com.taption.plan` 1.0 (149) was installed and foreground-launched, with app/widget PIDs 980/981/986 still present after about 15 seconds. The post-launch capture shows the 9/21 map, time rail and playback control (`build/validation/DHB0921A01-device-after-launch-r5.png`).
- The App Group container path remained unchanged, but the app-specific data-container UUID changed from `D8048704-6F7A-43D7-A0B7-7EEDF505C6EB` to `92CB59B0-BB14-42C0-8C70-6A0ACDB71A93`; continuity of app-private files is unverified. No erase or uninstall was issued. Device Hub CUA still fails to write kernel assets, so current-build date/play taps and a physical background-transition/CPU soak were not verified. Install/launch/process evidence is in `build/validation/DHB0921A01-device-install-r5.json`, `DHB0921A01-device-launch-r5.json`, and `DHB0921A01-device-processes-final-r5.json`.

## 2026-09-21 RCS0921A01 · latest coordinate route invalidation

- route-preparation signature에 latest sensor coordinate(latitude/longitude)를 포함해 UUID/timestamp가 그대로여도 좌표만 바뀌면 재준비된다. `testRouteReadingsPreparationSignatureChangesWhenLatestCoordinateChanges`는 그 조건을 회귀로 고정한다.
- `RouteTimelineDataTests` 83/83 PASS·0 fail/skip/runtime warning (`build/validation/RCS0921A01-route-coordinate.xcresult`); generic iOS Debug build exit 0 (`build/validation/RCS0921A01-debug-build.log`). 기존 AppleIntegrations `@preconcurrency` 경고만 남았다. 직접 날짜/재생 터치는 Device Hub CUA 초기화 실패로 별도 미검증이다.

## 2026-09-21 GAP0921A01 · ambient sample-gap summary regression

- Watch 기록기와 iOS 테스트가 같은 `WatchAmbientSummaryAccumulator` 생산 코드를 사용한다. 12.5Hz synthetic vectors 51개/38개 사이 6초 gap을 같은 10분 창에서 입력해 실제 summary 두 개와 고유 ID를 확인했고, post-gap analyzer 첫 window가 새 표본부터 2.56초로 다시 시작함을 검증한다.
- `WatchSensorQueryPlanTests.testAmbientGapProducesSeparateProductionSummariesInSameWindow` iPhone 17 Pro Simulator/iOS 26.5에서 1/1 PASS·0 fail/skip/runtime warning: `build/validation/GAP0921A01/ambient-gap-window-reset.xcresult` (실행 로그 `build/validation/GAP0921A01/window-reset-test.log`). `TaptionPlanWatch` generic watchOS Simulator Debug build도 exit 0.

## 2026-09-21 MID0921A01 · legacy Watch ambient 중복 제거

- 기존 세션과 다른 UUID로 다시 들어온 ambient summary는 session/sequence/window metadata를 제외한 동일 내용일 때만 막고, 내용이 달라진 late summary는 보존한다. acceleration chunk는 이미 저장된 timestamp stable ID만 제거해 새 late sample을 남긴다. 실제 `WatchDayDatabase.enqueueAmbientBatch` 호출부가 두 shared policy를 사용함을 확인했다.
- `WatchSensorQueryPlanTests` 39/39 PASS·0 fail/skip/runtime warning (`build/validation/MID0921A01-cross-session-r2.xcresult`). 두 신규 회귀 `testLegacyAmbientSummaryOverlapOnlySuppressesExactCrossSessionDuplicate`, `testLegacyAmbientChunkOverlapDropsOnlyPreviouslyStoredSamples` 포함. generic iOS Debug 빌드 성공 (`build/validation/MID0921A01-cross-session-debug-build.log`); 기존 `AppleIntegrations.swift:4470` 경고만 남았다. 실제 Watch 전달은 별도 하드웨어 검증이다.

## 2026-09-21 DLS0921A01 / TSN0921A01 · 최신 소스 Device Hub 확인

- TaptionActivityEngine 25/25, TaptionRouteEngine 35/35 SwiftPM 테스트 PASS. 현재 checkout Debug 앱을 iPhone 14 Pro/iOS 27.0(24A437)에 설치·foreground 실행했고, 앱 PID 2241/widget PID 2246 readback과 지도·날짜·시간표 화면을 확인했다. 증거: `build/validation/DLS0921A01/TSN0921A01/iphone14pro-postfix.png`, `iphone14pro-postfix-12s.png`.
- 실기기 Xcode XCTest는 빌드 성공 후 test runner가 `CoreDeviceError 10004`(실행된 앱 PID 확인 불가)로 시작하지 않아 테스트 0건이다. CUA도 `failed to write kernel assets`로 초기화되지 않아 날짜/재생 터치는 미검증이다. TestFlight 업로드 및 앱 데이터 초기화는 하지 않았다. XCTest/직접 조작 게이트가 남아 두 항목은 미완료다.
- 09:05–09:07 KST 재검증 당시 iPhone 14 Pro 실기기 XCTest 44/44 PASS·실패/건너뜀/runtime warning 0 (`build/validation/DLS0921A01/TSN0921A01/iphone14pro-devicehub-r4.xcresult`, 실행 로그 `iphone14pro-devicehub-r4.log`). 경로 날짜변경선·timestamp 필터·RDP 급회전 보존과 route/activity adapter 테스트가 포함됐다. `com.taption.plan` 1.0 (149)을 foreground 실행해 지도·날짜·시간표 화면을 캡처했다 (`iphone14pro-devicehub-after-launch.png`). 당시에는 전체 앱 회귀 재실행이 남아 DLS/TSN 종료를 보류했다. Device Hub CUA가 초기화되지 않아 날짜/재생 직접 터치는 계속 미검증이다.
- 09:17–09:23 KST 최종-source 검증: 전체 iPhone 17 Pro Simulator XCTest 1,229 PASS·1 skip·0 FAIL/runtime warning 0 (`full-app-regressions-r3.xcresult`). iPhone 14 Pro/iOS 27.0(24A437)에서는 경로·timestamp·RDP, Watch 중복 인덱스, 백업 보간·센서 복구/마이그레이션 관련 실기기 XCTest 50/50 PASS·skip/FAIL/runtime warning 0 (`iphone14pro-devicehub-final-r5.xcresult`, `iphone14pro-devicehub-final-r5.log`). 앱 `com.taption.plan` 1.0(149) foreground 실행 후 지도·날짜·시간표 화면을 캡처했다 (`iphone14pro-devicehub-final.png`). Device Hub CUA는 재초기화 후에도 `failed to write kernel assets`였으므로 날짜/재생 직접 터치는 미검증이며, CoreDevice 실기기 XCTest·launch·화면 캡처로 대체 확인했다. TestFlight 업로드·앱 데이터 초기화는 하지 않았다.

## 2026-09-21 AFW0921A01 · Watch/iPhone 활동 증거 융합

- `ActivityEvidenceSweepIndex`가 timestamp group cursor와 연결된 live-member 제거를 사용한다. 4,000개씩의 동일시각 iPhone/Watch 미매칭 표본 회귀에서 비교 작업량 상한을 확인했다. `swift test -j 4` 25/25 PASS, dense sweep 0.041초 (`build/validation/AFW0921A01/taption-activity-engine.log`).

## 2026-09-21 SID0921A01 · Activity 안정 ID 단일 구현

- `ActivityStableID.uuid(seed:)`는 `TaptionActivityEngine/ActivityModels.swift`의 단일 구현이며 classifier와 앱 adapter가 공용 API를 호출한다. `testStableUUIDGoldenSeedsRemainUnchanged`를 포함한 패키지 테스트 25/25 PASS (`build/validation/AFW0921A01/taption-activity-engine.log`). 별도 HealthKit import/projection의 다른 ID hash는 seed·식별 계약이 달라 합치지 않았다.

## 2026-09-21 RBC0921A01 · 불완전 센서 백업 generation 보존

- AppModel end-to-end regression은 손상된 센서 event archive의 `isComplete == false`를 만들고, 수동 iCloud 백업이 `.invalidArchive`로 거부되며 기존 snapshot/raw generation과 성공 시각이 변하지 않는지 확인한다.
- `testManualCloudBackupRejectsIncompleteSensorArchiveBeforeReplacingGeneration` iPhone 17 Pro Simulator 1/1 PASS·0 FAIL (`build/validation/RBC0921A01/incomplete-cloud-backup-r3.xcresult`, exit 0). 첫 실행의 실패는 fixture SQLite 파일 상위 임시 폴더 미생성이었고, 폴더 생성 후 통과했다. 실기기 설치/백업 복원은 수행하지 않았다.

## 2026-09-21 WAG0921A01 · Watch ambient high-water 복원

- Watch ambient sequence는 지속 무장 시점 이후 마이크로초 단위다. 이를 10분 창 번호로 변환해 거대한 날짜 범위와 `dayKeys` 전체 순회를 만들던 경로를 제거했다. V3 raw store의 `(device, domain, id)` 인덱스를 이용한 printable-ASCII ID-prefix latest query를 추가하고, iPhone/Watch store 결과와 legacy archive를 session ID별 sequence/revision으로 병합한다.
- `DayStoreV3Tests.testLatestRawEventUsesIdentifierPrefixAcrossDaysAndRevisions` 통과. TaptionPlanCore 전체 85/85 PASS (`build/validation/WAG0921A01/core-suite.log`).
- iPhone 14 Pro/iOS 27 실기기에서 하루 누적 microsecond sequence, 이전 날짜의 동일-session 요약, stale UserDefaults high-water, 더 큰 sequence를 가진 다른 session의 legacy archive를 조합한 재시작 회귀 1/1 PASS (`build/validation/WAG0921A01/ambient-highwater-on-iphone-r5.xcresult`, `iphone-focused-r5.log`). stale 요약은 저장되지만 최신 V3 요약과 high-water는 유지된다.
- 실기기 Debug test build 중 발견한 biometric keychain 및 transport service의 main-actor default-argument 오류를 actor-isolated initializer 본문에서 생성하도록 수정했고, 해당 transport XCTest 두 개도 `@MainActor`로 지정했다. 최신 physical test build 및 회귀가 통과했다.

## 2026-09-21 BKG0921A01 / RBL0921A01 / RST0921A01 · 백업 세대 삭제 경합 및 legacy 복원

- `saveMonthlyGeneration`은 recovery-key 대기 뒤 준비 revision을 검사했지만, 캡처한 revision을 내부 snapshot 저장/commit까지 전달하지 않았다. 이제 `saveMonthlyArchive`에서 commit CAS까지 전달해 준비 도중 credential revision이 바뀌면 commit이 취소되고 rollback 정리가 실행된다.
- raw 저장 전·후와 snapshot commit 전·후 삭제 fence, stale write 정리, 삭제 중 rollback 차단을 포함한 interleaving 회귀를 확인했다. Restore는 snapshot 월과 snapshot이 없는 generation-less raw 월을 함께 열거하며, snapshot-only 월의 stale raw archive는 연결하지 않는다.
- 첫 실행에서 rollback 재현 테스트가 revision 전달 누락을 잡았고, legacy 복원 테스트의 `.empty` 재생성 비교가 불안정해 저장 직후 readback snapshot을 기준으로 고쳤다. 수정 후 `SecurityBackupCoreTests` 89/89 PASS·0 FAIL/SKIP·runtimeWarnings 0 (`build/validation/BKG0921A01/security-backup-core-r2.xcresult`). generic iOS Debug build exit 0 (`build/validation/BKG0921A01/device-debug-build.log`); 기존 `AppleIntegrations.swift:4470` 경고만 남음. 실기기 설치/Device Hub 조작은 이 저장소 변경에서 수행하지 않았다.

## 2026-09-21 MAL0921A01 · malformed legacy JSONL migration 재시도

- JSONL streaming decoder는 malformed row에서 오류를 전파하고 completion marker 기록을 보류한다. 앞서 저장한 valid batch는 stable ID로 중복 없이 재사용되며, legacy 원본을 valid/malformed/valid에서 valid/valid로 복구한 뒤 재시도하면 전체 3개 event가 복원된다.
- `SensorDayStoreTests.testSensorMigrationKeepsMalformedLegacyRowsAndCanRetry` current-source iPhone 17 Pro Simulator 1/1 PASS·0 FAIL/SKIP·runtimeWarnings 0 (`build/validation/MAL0921A01/malformed-jsonl-retry-r2.xcresult`). 기존 simulator가 제거되어 전용 validation simulator를 생성해 실행했다.

## 2026-09-21 CAC0921A01 · Plan-day cache invalidate/cancel 경합

- `PlanDayLoadCoordinator`는 database cache read await 뒤 day invalidation generation을 비교해 stale cache 대신 재로드하고, task cancellation은 incomplete 결과로 종료해 sensor loader 재실행을 막는다. 기존 current-source 경계가 큐 진단을 이미 충족했다.
- `testPlanDayLoadCoordinatorRetriesCacheReadInvalidatedWhileBlocked` 및 `testPlanDayLoadCoordinatorDoesNotRetryCancelledBlockedCacheRead` 2/2 PASS·0 FAIL/SKIP·runtimeWarnings 0 (`build/validation/CAC0921A01/cache-invalidation.xcresult`). 동시 취소+revision 무효화 경계는 아래 CAN0921A01에서 별도 재현·수정했다.

## 2026-09-21 CAN0921A01 · 캐시 무효화와 취소 동시 경합

- database cache read가 대기 중일 때 날짜 무효화와 요청 취소가 겹치면, 무효화 분기가 취소된 요청에서 비구조 재시도를 시작해 sensor load/save를 계속하는 결함을 red 회귀 (`build/validation/CAN0921A01/cancel-plus-invalidation-red.xcresult`)로 재현했다.
- `cacheReadInFlight` 구간에는 무효화가 기존 task 취소를 유예해 revision 변경만 있을 때 재시도할 수 있게 하고, 실제 취소가 함께 오면 먼저 incomplete로 종료한다. 회귀는 재호출 0회와 기존 DB reading 보존을 확인한다.
- 취소+무효화 및 무효화 단독 테스트가 iPhone 17 Pro Simulator 2/2 PASS (`cancelled-cache-save-guard-simulator-final.xcresult`), iPhone 14 Pro/iOS 27.0 2/2 PASS·0 FAIL/SKIP·runtimeWarnings 0 (`cancelled-cache-save-guard-on-device.xcresult`).

## 2026-09-21 UNI0921A01 / OBD0921A01 · SQLite BINARY 식별자 일치

- raw domain membership은 UTF-8 바이트 exact 비교로 처리해 NFC/NFD 도메인 중 지정된 행만 교체하고, outbox 삭제는 요청 ID 배열을 그대로 순회한다.
- `testRawReplacementPreservesByteDistinctStoredDomain` 및 `testOutboxDeletionUsesByteExactIDs` PASS. TaptionPlanCore 전체 85/85 PASS, DayStoreV3 39/39 PASS·실패 0 (`build/validation/UNI0921A01/core-suite.log`).

## 2026-09-21 AUD0921A01 · 최신 소스 Device Hub 확인

- 현재 checkout generic iOS Debug 빌드 PASS (`build/validation/AUD0921A01-r4/generic-device-debug-r2.log`). TaptionPlanCore 84/84, Activity 23/23, RouteEngine 35/35, PlanEngine 1/1 SwiftPM tests PASS; MapHome 경로 날짜 필터/취소/RDP 취소/playback/240Hz gate 집중 XCTest 5/5 PASS (`map-route-regressions.xcresult`). iPhone 14 Pro 실기기 XCTest 1/1 PASS (`physical-focused-r2.xcresult`).
- 현재 산출물 `PhysicalDeviceDerivedData/Build/Products/Debug-iphoneos/TaptionPlan.app`을 iPhone 14 Pro/iOS 27.0에 설치하고 foreground launch했다. Device Hub 및 CoreDevice 캡처에서 지도·날짜·타임라인 화면을 확인했고, 재확인 시 TaptionPlan PID 1777 및 widget PID 1778이 유지됐다. 설치 앱 readback은 `com.taption.plan` 1.0 (149). 화면 증거: `iphone14-pro-stable.png`, `device-hub-after-start.png`, 실행 뒤 `iphone14-pro-devicehub-play-r3.png`.
- Device Hub 날짜 다음/재생 버튼에 좌표 클릭을 시도했지만 화면에서 날짜는 9월 21일로 유지되고 재생 아이콘도 삼각형 그대로여서 직접 상호작용은 확인되지 않았다. 전체 최신-source Simulator suite, 장시간 CPU soak, post-fix OS unified-log/crash-log readback은 미완료다. `idevicesyslog`는 CoreDevice로 연결된 해당 iPhone을 찾지 못해 로그 archive를 수집하지 않았다. TestFlight 업로드는 하지 않았다.

## 2026-09-21 WPD0921A01 · locked workout purge reconciliation

- Apple documents a `finishWorkout()` result of nil with no error as a saved workout whose sample is unavailable while the device is locked. The Watch builder now writes an app-specific purge UUID into HealthKit metadata; purge persists an in-flight intent, deletes through the exact metadata predicate, and reports success only when HealthKit returns a positive deleted-object count. A zero count or error preserves the ID for retry; the ordinary non-nil result continues to delete the exact `HKWorkout` object.
- `WatchWorkoutStartGateTests`: 9/9 PASS, 0 failed/skipped, no runtime warnings on iPhone 17 Pro/iOS 26.5 (`build/validation/WPD0921A01-watchworkout-class-r1.xcresult`). The dedicated locked-nil regression persists the intent across defaults instances, keeps it pending when deletion count is zero, and clears it only after a positive count.
- Generic watchOS Simulator Debug build PASS, zero build warnings/errors (`build/validation/WPD0921A01-watch-build-r1.xcresult`). The HealthKit store itself was not exercised on a locked physical Watch; Device Hub touch verification remains unavailable because CUA initialization fails with `failed to write kernel assets`.

## 2026-09-21 DHB0921A01 · Device Hub foreground launch

- iPhone 14 Pro/iOS 27.0 (24A437)에 현재 checkout의 Debug 빌드를 설치하고 foreground 실행했다. Device Hub에서 해당 iPhone을 선택해 map/timeline 화면이 렌더링된 것을 readback했고, 실행 20초 뒤 Taption Plan PID 1460과 widget PID 1461이 유지됐다. 앱 정보는 1.0 (149); TestFlight 업로드·앱 데이터 초기화는 하지 않았다.
- 전체 iPhone 17 Pro Simulator suite 1,200 PASS·1 SKIP·0 FAIL (`build/validation/DHB0921A01/simulator-verified.xcresult`). 실기기 증거는 `build/validation/DHB0921A01/device-build.log`, `device-install.log`, `device-processes-after-20s.log`, `device-installed-app.log`, `iphone14-pro.png`, `device-hub-window.png`에 보존했다.
- CUA 화면 캡처는 계속 `failedToCreateImageDestination`였으나 Device Hub 창을 별도 화면 캡처해 시각 확인했다. Device Hub 화면을 통한 터치 자동화는 macOS Accessibility 권한 오류(-1723)로 실행되지 않아 날짜 이동/재생 조작, 장시간 CPU soak, post-fix OS crash-log readback은 미검증이다. 기존 화면 smoke와 targeted XCTest는 아래 DVT0921A01에 별도 기록돼 있다.
- 02:53–02:57 KST 재확인: Device Hub에서 iPhone 14 Pro(iOS 27.0/24A437)를 선택한 상태이며, CoreDevice screenshot에서도 날짜·지도·타임라인 화면이 유지되고 앱/widget PID 1460/1461이 실행 중이다 (`build/validation/DHB0921A01/iphone14-pro-current.png`, `device-hub-current.png`). 재연결한 CUA는 `failed to write kernel assets`로 초기화되지 않았고, 이번에는 공용 `/tmp/.taption-build.lock`을 다른 프로젝트가 보유해 새 빌드/XCTest를 시작하지 않았다. 실제 날짜 이동·재생 터치는 여전히 미검증이다.
- 03:18–03:19 KST CoreDevice 재확인: iPhone 14 Pro의 설치 앱은 `com.taption.plan` 1.0 (149). foreground launch 후 지도·날짜·타임라인 화면 캡처와 약 22초 뒤 앱/widget PID 1622/1624를 확인했다 (`build/validation/DHB0921A01/iphone14-pro-installed-149-0318.png`). 이는 설치된 149 앱의 smoke이며 현재 미빌드 소스 변경분 검증은 아니다. 공용 빌드 잠금은 타 프로젝트의 iPad 실기기 테스트가 보유 중이었다. Device Hub 터치 자동화, 날짜/재생 상호작용 및 최신 수정본 설치 검증은 미완료다.
- 05:39 KST CoreDevice read-only 재확인: iPhone 14 Pro/iOS 27.0은 연결·잠금 해제 상태이고 `com.taption.plan` 1.0(149)이 설치돼 있다. 프로세스 목록에는 TaptionPlan PID 1777/widget PID 1778이 있었지만 화면 캡처는 다른 카메라 UI를 보여 전면 앱은 확정하지 않았다. 카메라 세션을 중단할 수 있어 앱 전환은 보류했다. Device Hub CUA 초기화는 `failed to write kernel assets`로 실패했다. 기기 화면 증거는 `build/validation/RBC0921A01/devicehub-20260921.png`; Taption Plan의 최신 소스 동작/조작 검증은 미실시.
- 07:16–07:24 KST 현재 checkout Debug 빌드(1.0/149)를 iPhone 14 Pro에 설치·foreground launch하고 Device Hub 및 CoreDevice 화면에서 지도·날짜·타임라인을 확인했다. 해당 실행의 취소+무효화/무효화 단독 실기기 XCTest 2/2 PASS. 화면 증거는 `build/validation/CAN0921A01/devicehub-iphone14pro-final.png`, `iphone14pro-final.png`다. 날짜/재생 좌표 입력 뒤에도 날짜 9/21·재생 삼각형 그대로라 직접 터치 전달은 미확인; CUA는 kernel-assets 초기화 오류로 연결되지 않았다. 앱 데이터 초기화·TestFlight 업로드는 하지 않았다.
- 07:40–07:48 KST 최신 checkout Debug 빌드 성공 후 iPhone 14 Pro/iOS 27.0(24A437)에 같은 bundle `com.taption.plan` 1.0(149)을 데이터 초기화 없이 설치·전면 실행했다. 지도·날짜·시간표가 렌더링되고 20초 뒤에도 앱/widget PID 2125/2126이 유지됐다. `RouteTimelineDataTests`의 비유한 timestamp 정규화와 날짜변경선 최단경도 재생 보간 실기기 테스트 2/2 PASS, 실패·skip·runtime warning 0; 테스트 후 재실행 화면 및 PID 2135/2133 readback. 증거는 `build/validation/DHB0921A01/current-source-device-build.log`, `current-source-device-install.log`, `current-source-after-launch-0742.png`, `current-source-after-20s-0743.png`, `current-source-route-device-tests.xcresult`, `current-source-final-0748.png`다. CUA는 `failed to write kernel assets`로 초기화되지 않아 날짜/재생 터치는 미검증. `/usr/bin/log collect`는 기기 로그 수집에 root가 필요하다고 거부했고, `devicectl sysdiagnose`도 DiagnoseError 0으로 실패해 post-fix OS 로그와 장시간 CPU soak은 미검증이다. TestFlight 업로드는 하지 않았다.

## 2026-09-21 DVT0921A01 · Device Hub iPhone 14 Pro 검증

- iPhone 14 Pro/iOS 27.0(24A437)에 현재 소스 Debug 앱을 설치해 실행했다. bundle `com.taption.plan`, version 1.0 (build 149); 기존 TestFlight 149 앱 바이너리는 같은 bundle ID의 로컬 Debug 빌드로 교체됐다. Device Hub 화면에서 map/timeline 화면이 정상 렌더링됨을 확인했다. 앱 삭제/데이터 초기화와 TestFlight 업로드는 하지 않았다.
- `SensorDayStoreTests.testPlanDayDatabaseRemovesMaterializationInvalidatedDuringCommit` 실기기 XCTest 1/1 PASS, 0 fail/skip (`build/validation/DVT0921A01/rollback-on-device.xcresult`). XCTest summary runtimeWarnings 0. `TaptionPlanCore.DayStoreV3Tests` macOS SwiftPM suite 37/37 PASS, including SQLite `Date` representation regression; device Debug build reported `BUILD SUCCEEDED`.
- XCTest 실행 로그에서 재발한 `0x8BADF00D`/`0xDEAD10CC` 또는 app crash는 없었다. Apple CoreMotion preferences/PerfPowerTelemetry/Maps usage access-denied 로그는 있었지만 XCTest 및 화면 동작을 막지 않았다. 장시간 idle/background CPU soak은 별도 검증으로 남는다.
- 06:03–06:04 KST 추가 실기기 smoke: CoreDevice로 기존 로컬 Debug 149 앱을 전면 활성화하고 지도·날짜·시간표 렌더링 및 20초 뒤 앱/widget PID 1777/1778 유지를 확인했다 (`build/validation/DHB0921A01/iphone14-pro-followup-2026-09-21.png`, `iphone14-pro-followup-2026-09-21-after-20s.png`). 기존 프로세스가 유지돼 cold start는 아니며, 이번 실행에서 재빌드·재설치·버튼 조작은 하지 않았다. Device Hub CUA는 `failed to write kernel assets`로 초기화되지 않았고, 공용 빌드 잠금은 타 프로젝트의 iPad Simulator 테스트가 사용 중이라 최신 소스 실기기 XCTest는 보류했다.

- Device Hub 추가 확인: Xcode 27 Device Hub에서 iPhone 14 Pro/iOS 27.0에 실행 중인 Taption Plan 화면을 확인했다 (`build/validation/DHB0921A01/devicehub-current-foreground-2026-09-21.png`). 포인터 입력 시험 뒤 선택 날짜가 9/21에서 9/19로 표시돼 좌표-컨트롤 대응은 신뢰할 수 없었다 (`build/validation/DHB0921A01/iphone-after-cg-day-tap-2026-09-21.png`). 추가 조작 중 화면에 `'XCTest' 앱을 사용하려면 iPhone 암호 입력 / Enable UI Automation` 대화상자가 나타났다 (`build/validation/DHB0921A01/iphone-after-today-button-2026-09-21.png`). CoreDevice readback은 `passcodeRequired=false`, `unlockedSinceBoot=true`, TaptionPlan PID 2459 유지로 크래시는 확인되지 않았다. 암호 입력이나 UI Automation 활성화는 하지 않았으며, 직접 날짜/재생 입력 검증은 기기 소유자 조치 대기.
- 10:14–10:17 KST 최신 소스 Device Hub smoke: Debug build 성공 후 iPhone 14 Pro에 데이터 초기화 없이 설치했고 `com.taption.plan` 1.0 (149)을 readback했다. foreground launch 성공(PID 2565); 20초 뒤 앱 PID 2565와 widget PID 2566/2570이 유지됐다. 다만 Device Hub 화면은 iOS 앱 사용 시간 제한 안내로 덮여 앱 화면 상호작용은 막혀 있었다. 제한 연장/해제나 암호 입력은 하지 않았다. 증거: `current-source-device-build-r2.log`, `current-source-devicehub-install.json`, `current-source-devicehub-launch.json`, `current-source-devicehub-after-launch-2026-09-21.png`, `current-source-devicehub-after-20s-2026-09-21.png`. 따라서 설치·실행·liveness smoke만 확인했으며 날짜/재생 조작 및 장시간 CPU soak은 미검증이다.
- 10:33 KST Device Hub/CoreDevice 재확인: iPhone 14 Pro는 연결·잠금 해제 상태이고 `com.taption.plan` 1.0 (149)이 설치돼 있으며 앱 PID 2565와 widget PID 2566/2570이 살아 있다. 새 기기 캡처 `build/validation/DHB0921A01/device-current-readback-2026-09-21.png`는 현재 전면이 iOS 앱 사용시간 제한 화면임을 보여 앱 UI가 가려져 있다. CUA 초기화도 `failed to write kernel assets`로 실패했다. 제한·암호·권한은 건드리지 않았으므로 날짜/재생 상호작용은 대표님이 기기에서 사용시간을 허용한 뒤 재개한다.

- 최신 CoreDevice 실행/렌더링 재확인: Device Hub CUA는 여전히 failed to write kernel assets로 초기화되지 않는다. CoreDevice로 com.taption.plan만 전면 실행하고 화면을 캡처했으며(터치·암호·스크린타임 해제·UI Automation 승인 없음), iPhone 14 Pro에서 9/21 지도·날짜·타임라인과 재생 컨트롤 표시를 확인했다. 설치 버전 1.0(149), 앱 PID 2565/widget PID 2566·2570 생존. 증거: build/validation/DHB0921A01/device-plan-foreground-readback-2026-09-21.png. 실기기 실행·렌더링만 확인했으며 날짜 이동과 재생 동작은 미검증이다.
- 11:35 KST CoreDevice 재확인에서 iPhone 14 Pro가 연결·잠금 해제 상태이며 `com.taption.plan` 1.0(149), 앱 PID 2565와 widget PID 2566/2570이 실행 중이다. 새 캡처 `build/validation/DHB0921A01/device-current-recheck-2026-09-21.png`에는 지도·9/21 날짜·재생 컨트롤이 보이고 화면 가림은 없었다. Device Hub CUA 재초기화는 계속 `failed to write kernel assets`로 실패하여 터치 기반 날짜/재생 동작은 미검증이다.
- 11:50 KST 최신-source physical Device Hub smoke: signed Debug 앱을 iPhone 14 Pro에 데이터 초기화 없이 설치하고 foreground launch했다. `com.taption.plan` 1.0(149), 앱 PID 2655/widget PID 2656을 readback했고 15초 뒤 새 화면 캡처에서 지도·9/21 날짜·시간표·재생 컨트롤이 유지됐다 (`build/validation/MID0921A01-physical-device-build.log`, `MID0921A01-device-install.json`, `MID0921A01-device-launch.json`, `MID0921A01-device-after-launch.png`). CUA 재초기화가 `failed to write kernel assets`로 실패해 날짜 이동/재생 터치는 미검증이다.
- 12:13 KST CoreDevice 화면 재확인(Device Hub 터치 미완료): 연결 iPhone 14 Pro의 최초 캡처는 ShotGuide 화면이어서 `com.taption.plan` 1.0(149)을 앱 데이터 초기화·재설치 없이 foreground launch했다. 후속 기기 캡처에서 9/21 날짜, 지도, 시간표와 재생 컨트롤을 확인했고 앱/widget PID 2655/2656이 유지됐다 (`build/validation/DHB0921A01/devicehub-operation-initial-2026-09-21-1213.png`, `devicehub-operation-launch-2026-09-21-121329.json`, `devicehub-operation-afterlaunch-2026-09-21-1213.png`). 이 실행에서 날짜 이동·재생 버튼은 누르지 않았다. Device Hub CUA 입력은 `failed to write kernel assets` 초기화 오류, 직접 UI automation은 기존 기기 승인 대기 상태로 미검증이다.
- 13:16–13:17 KST 최종 소스 검증: focused HealthKit 회귀 5/5 PASS, 0 fail (`build/validation/HCP0921A01-healthkit-fix-r11.xcresult`): page-failure 후 cursor/count/record 보존, date cursor의 PropertyList 왕복, gate 및 실제 coordinator sample-sync 직렬화, activity-summary DateComponents calendar. 물리 iPhone 14 Pro/iOS 27.0용 signed Debug 재빌드 성공 (`build/validation/DHB0921A01-device-build-r2.log`), 기존 데이터 초기화 없이 `com.taption.plan` 1.0(149)을 교체 설치·foreground launch했다. PID 2736/widget 2737이 15초 후에도 유지되고 9/21 지도·시간표·재생 컨트롤이 캡처에 보인다 (`build/validation/DHB0921A01-device-after-runtime-r2.png`). CUA 초기화 오류로 실제 날짜/재생 터치는 미검증이며, idevicesyslog가 CoreDevice local-network 연결에 붙지 않아 post-fix OS 로그는 수집하지 못했다.

- 15:20–15:21 KST Device Hub 실제 입력 smoke: iPhone 14 Pro/iOS 27.0의 이미 설치된 `com.taption.plan` 1.0(149)에서 날짜를 9/21→9/22→9/21로 이동·복원했고, 재생은 Play→Pause(02:37) 후 15:20까지 진행해 Play 상태로 종료됐다. 앱/widget PID 2787/2788이 유지됐다. 증거: `build/validation/DHB0921A01/devicehub-date-next-recheck-2026-09-21.png`, `devicehub-date-restored-2026-09-21.png`, `devicehub-play-start-2026-09-21.png`, `devicehub-play-progress-2026-09-21.png`. CUA 커널 자산 오류는 계속됐지만 Xcode Device Hub의 직접 입력은 동작했다. 사용자 데이터가 있는 app-specific container를 보존하기 위해 14:58 산출물은 재설치하지 않아 최신 source의 실기기 반영은 미확인이다. 장시간 CPU soak과 post-fix OS log readback도 미완료다.

## 2026-09-21 DHV0921A01 · 최신 소스 Device Hub 동작 검증

- iPhone 14 Pro/iOS 27.2에서 현재 checkout signed Debug 빌드가 성공했고, `com.taption.plan`에 데이터 초기화·앱 삭제 없이 교체 설치·foreground launch했다. 앱 readback은 1.0 (149), PID 882; widget PID 883/893이었다. 빌드·설치·실행 증거: `build/validation/DHV0921A01-device-debug-build.log`, `build/validation/DHV0921A01-device-install.json`, `build/validation/DHV0921A01-device-launch.json`, `build/validation/DHV0921A01-device-processes-final.json`, `build/validation/DHV0921A01-devicehub-after-launch.png`.
- Device Hub 직접 입력으로 날짜 9/21→9/22→9/21을 이동·복원했다. 재생 입력 시 Pause 상태와 진행 중인 시간 표시를 확인하고, Pause 뒤 Play 상태로 복귀했다. 증거: `build/validation/DHV0921A01-devicehub-date-next-verified.png`, `build/validation/DHV0921A01-devicehub-date-restored-after-settle.png`, `build/validation/DHV0921A01-devicehub-play-pause-verified.png`, `build/validation/DHV0921A01-devicehub-play-paused.png`.
- 동작 smoke 동안 앱/widget 프로세스가 유지됐다. 이는 짧은 인터랙션 검증이며 장시간 CPU soak, post-fix OS log readback, 동일 workload watchdog 재현은 별도 미완료다.

## 2026-09-21 CRW0921R01 / REV0921A01 · 복원 취소 경로 후속 검토

- 독립 Luna xHigh 리뷰에서 raw restore의 PIN 실패 후 iCloud 키 재시도가 월별 archive를 다시 읽고 budget을 초기화하는 경로를 찾았다. 계정 키 fallback을 현재 적재된 archive에 적용하고 이후 월에도 재사용하도록 바꿨으며, 전체 2차 restore pass를 제거했다. `testRawRestoreAccountKeyFallbackReusesLoadedArchiveAndByteBudget`를 추가했다.
- `CloudRestoreReadingPreparation`은 입력 배열의 CoW 복사 대신 취소 검사 간격을 둔 새 배열 누적으로 변경했다. 복원 혼합 유효/무효 표본 회귀와 Plan-day Watch append 이후 실제 `Task.cancel()` rollback 회귀를 추가했다. DBR 독립 리뷰는 correctness 결함을 찾지 못했으나 XCTest 미실행이다.
- `swiftc -frontend -parse` 대상 10개 파일 PASS, `git diff --check` 및 app/engine import boundary PASS. XCTest·Debug 빌드는 실행하지 않았다. 이후 다른 Taption 프로젝트의 Xcode test가 공유 `/tmp/.taption-build.lock`을 획득했고 가용 공간은 229MiB로 내려갔다. 활성 빌드는 중단하지 않았다.
- 22:12 KST 정적 검증: 변경·신규 Swift 68개 파일 frontend parse PASS, 4개 Swift package manifest `dump-package` PASS, Xcode project `plutil -lint` PASS, app/engine 및 package/UI-framework import 경계 PASS, `git diff --check` PASS. 공유 build lock은 없지만 여유 공간 365MiB라 XCTest·Debug 빌드는 실행하지 않았다.

## 2026-09-21 DHR0921A01 · 최신 변경 실기기 검증

- iPhone 14 Pro/iOS 27.2 (24B5084k)에서 현재 소스 Debug 빌드 및 RouteTimelineDataTests 87/87 통과, 실패·건너뜀·XCTest runtime warning 0: `build/validation/DHR0921A01/route-device-tests-r1.xcresult`. 기존 `AppleIntegrations.swift:4470`의 무효한 `@preconcurrency` 빌드 경고 1건은 남았다.
- `com.taption.plan` 1.0 (149)을 전면 실행해 앱 PID 1024·widget PID 1020과 9/21 지도·시간표·재생 컨트롤 렌더링을 확인했다. 화면: `build/validation/DHR0921A01/devicehub-after-device-tests.png`; 실행 readback: `build/validation/DHR0921A01/device-launch.json`.
- Device Hub CUA는 초기화 및 Xcode 앱 연결 모두 `failed to write kernel assets`로 실패해 최신 바이너리에서 날짜/재생 직접 입력은 검증하지 못했다. 앱 삭제·데이터 초기화·UI Automation 승인·TestFlight 업로드는 하지 않았다.
- 재시도에서도 CUA가 같은 커널 자산 오류로 초기화되지 않았다. 대신 연결된 iPhone 14 Pro 화면을 `devicectl`로 다시 캡처해 9/21 지도·시간표·재생 UI와 앱 PID 1076/widget PID 1074 실행을 확인했다: `build/validation/DHR0921A01/devicehub-current-check.png`. 이 readback은 직접 터치 동작 증거를 대체하지 않는다.
- FUS Debug 테스트 뒤 `com.taption.plan` 1.0 (149)을 다시 foreground launch해 앱 PID 1126·widget PID 1123과 9/21 지도·날짜·시간표·재생 화면을 확인했다: `build/validation/FUS0921A01/app-launch.json`, `app-after-launch.png`. Device Hub 직접 날짜/재생 입력은 CUA 초기화 오류로 계속 미확인이다.
- 20:19 KST 재시도에서 CUA `getState`, `getApp("Device Hub")`, 문서 재연결 및 커널 reset 후 `getState`가 모두 `failed to write kernel assets`로 실패했다. iPhone 14 Pro는 `devicectl` 연결 상태이며 Taption Plan 1.0 (149), PID 1126/widget 1123을 확인하고 화면을 캡처했다: `build/validation/DHR0921A01/devicehub-cua-unavailable-check.png`. 날짜/재생 터치 동작은 검증되지 않았다.
- 21:15 KST 새 CUA JS 세션 reset 후 `getState`를 재시도했지만 같은 커널 자산 오류로 시작하지 못했다. `devicectl`에서는 iPhone 14 Pro가 available이었으나 `com.taption.plan` 실행 프로세스는 검색되지 않았다. 앱을 띄우거나 터치한 증거는 없으며 Device Hub 직접 조작 검증은 미완료다.
- 22:00 KST 재시도에서도 CUA `rewriteDocumentation` 및 세션 reset 후 `getState`가 `failed to write kernel assets`로 실패했다. `devices://device/open`을 열고 기존 데이터 그대로 설치된 `com.taption.plan` 1.0(149)을 launch했으며, 캡처에 9/21 지도·시간표·Play 화면이 보이고 app/widget PID 1126/1123은 15초 뒤에도 유지됐다. 증거: `devicehub-retry-2026-09-21.png`, `devicehub-retry-apps.json`, `devicehub-retry-processes.json`. 직접 Device Hub 날짜/재생 입력은 미검증이며, 현재 checkout의 미빌드 변경 검증도 저장 공간 266MiB로 보류했다.
- 22:32 KST DVI0921B01 재확인: CUA `getState`와 `getApp("Device Hub")`가 다시 `failed to write kernel assets`로 실패했다. iPhone 14 Pro/iOS 27.2의 설치본 `com.taption.plan` 1.0(149), app/widget PID 1126/1123을 CoreDevice에서 확인하고 기존 데이터 그대로 foreground launch했다. 캡처 `build/validation/DHR0921A01/devicehub-recheck-after-launch-2026-09-21-2233.png`에서 지도·9/21·시간표·재생 UI가 렌더링됐다. 날짜/Play/Pause 직접 입력은 미검증이며, 현재 checkout의 미빌드 변경은 여유 공간 351MiB로 보류했다. 설치·기기 데이터 삭제, 암호 입력, UI Automation 승인은 하지 않았다.

## 2026-09-21 REV0921B01 · review fix regressions

- Added regressions for Watch ambient migration/live identity across midnight and revision, concurrent SQLite cold opens, corrupt-row repair while cleanup waits for its lock, approximate-route accuracy/GPS input changes, HealthKit deletion during an in-flight history page, legacy HealthKit cursor decoding, zero-count Watch purge reconciliation, and bounded ambient sample-ID overlap retention.
- Static parse and XCTest/Debug results are pending. Free space is 351MiB; the Xcode build/test gate remains closed. No app build or test was started.
- 22:59 KST follow-up: `swiftc -frontend -parse` passed for the 12 changed Swift files and `git diff --check` passed. `devicectl` reconfirmed iPhone 14 Pro/iOS 27.2, installed `com.taption.plan` 1.0 (149), and app/widget PID 1126/1123; available space is now 322MiB and no shared build lock is present. Device Hub direct input and current-checkout binary behavior remain unverified; XCTest/Debug were not run.

## 2026-09-21 AEV0921A01 · activity evidence travel 구간 sweep

- `evidence(from:travel:)`의 reading×travel 전체 `first` 탐색을 정렬 sweep + 입력순서 min-heap으로 교체했다. 겹치는 travel의 기존 배열 우선순위, 양끝 포함, Foundation `Date` NaN 비교 결과를 기준 구현과 대조한다.
- iPhone 14 Pro/iOS 27.2 실기기에서 `TaptionActivityEngineAdapterTests` 21/21 PASS·실패/건너뜀/runtime warning 0 (`build/validation/AEV0921A01/device-focused-r5.xcresult`). 밀집 회귀는 8,001 readings·4,000 travel intervals, 경계/겹침 회귀 포함이다. `RouteTimelineDataTests` 87/87 PASS는 같은 기기에서 별도 결과 `build/validation/DHR0921A01/route-device-tests-r1.xcresult`로 확인했다.
- 최신 앱 `com.taption.plan` 1.0 (149)을 foreground launch해 PID 1076/widget 1074와 지도·날짜·시간표·재생 컨트롤을 확인했다: `build/validation/AEV0921A01/device-after-final-r5.png`, `device-launch-r5.json`. 직접 Device Hub 터치는 CUA 초기화 오류로 미검증이다.

## 2026-09-21 PKG0921A01 · app engine import boundary

- `ScheduleView`를 이미 app target dependency로 연결되고 `TaptionRouteEngine`을 재수출하는 `TaptionPlanEngine` facade로 통일했다. 앱 전용 `TaptionPlan` 소스에서 하위 경로 엔진 직접 import를 거부하는 `scripts/check-app-engine-import-boundary.sh` 검사 PASS.
- iPhone 14 Pro/iOS 27.2 대상 Debug build exit 0. 기존 `AppleIntegrations.swift:4470`의 무효한 `@preconcurrency` 경고 1건은 남았으며, 이 import 경계 변경을 위해 앱 재설치나 UI 변경은 하지 않았다.

## 2026-09-21 FUS0921A01 · activity fusion 취소·revision 경계

- input/output 전체 정렬을 안정적인 bottom-up merge sort로 바꾸고 정렬·sweep·index 순회에서 256개 작업마다 cancellation/revision closure를 확인한다. iPhone/Watch 매칭, UUID tie-break, stable ID 결과 회귀를 유지했다.
- snapshot revision fence가 바뀌면 detached classification이 중간에 취소되고, retry는 nil 결과보다 revision 불일치를 먼저 확인해 최신 snapshot을 다시 분류한다. 이 stale 중간 취소·최신 revision commit 회귀를 추가했다.
- SwiftPM `TaptionActivityEngineTests` 27/27 PASS; 4,096개 정렬 중 merge 작업 상한 취소와 8,000개 밀집 fusion operation bound 통과. iPhone 14 Pro/iOS 27.2에서 `FeatureEngineTests.testActivityClassificationRetryCancelsStaleFusionAndCommitsLatestRevision` 1/1 PASS; Debug test build exit 0: `build/validation/FUS0921A01/fusion-device-r4.xcresult`.
- 해당 빌드의 앱을 실기기에서 재실행해 PID 1126/widget 1123과 정상 화면을 확인했다. 직접 Device Hub 입력은 CUA 오류로 별도 미검증이다.

## 2026-09-21 BRD0921A01 / WNF0921A01 / TRV0921A01 · restore/purge/classification 경합

- 두 `loadLatestBackupPackage` overload가 PIN verifier·preparation revision·deletion generation을 캡처하고, raw restore 및 cloud recovery key 대기 뒤 매번 유효성을 재검사하도록 했다. raw restore store에는 actor-isolated async 경계를 두어 취소 가능한 file restore를 유지하고, 결정적 interleaving 회귀에서 전체 삭제 중 대기하던 두 overload 모두 `CancellationError`로 끝나며 삭제된 archive를 반환하지 않음을 확인했다.
- Watch 비주변 summary/chunk flush는 DB append 완료 후 취소·purge 상태를 먼저 검사하는 공용 queue/transfer 정책을 사용한다. purge 삭제 실패를 끼운 회귀에서 pending 두 큐가 유지되고 재시도 후 각 항목이 한 번만 전송 예약된다.
- Activity classification revision retry가 매 회 최신 snapshot의 travel·actuals·corrections를 사용한다. 첫 시도 도중 travel과 revision을 바꾸는 회귀가 최신 snapshot 결과의 commit을 확인했다.
- 현재 소스 집중 XCTest 3/3 PASS (`build/validation/BRD0921A01-WNF0921A01-focused-r3.xcresult`, `build/validation/BRD0921A01-WNF0921A01-focused-r3.log`); Watch target Debug build 성공 (`build/validation/WNF0921A01/watch-target-build2.log`); TRV 집중 XCTest 1/1 PASS (`build/validation/TRV0921A01/focused-r2.xcresult`, `focused-r2-test.log`).

## 2026-09-21 BKL0921A01 · legacy raw archive generation cap

- `SecurityBackupCoreTests.testLegacyRawRestoreIgnoresGenerationCountAndCapsLegacyFiles` 1/1 PASS. 120개의 UUID generation 파일과 legacy raw archive가 함께 있어도 복원 enumeration 및 실제 raw restore가 성공하고, legacy archive 자체가 제한을 초과하면 `.invalidArchive`로 거부함을 확인했다. 증거: `build/validation/BKL0921A01/legacy-raw-generation-cap-r2.xcresult`, `build/validation/BKL0921A01/focused-test-r2.log`.

## 2026-09-21 CCL0921A01 · classifier cancellation checkpoints

- `TaptionActivityEngine` SwiftPM tests 26/26 PASS. 4만 evidence 회귀가 normalize·sort·dedup·segment construction 각 단계의 협력 취소를 확인했다. 증거: `build/validation/CCL0921A01/activity-classifier-package-tests.log`.

## 2026-09-21 WAO0921A01 / PAR0921A01 · Watch overlap과 backup 취소

- 현재 소스 iPhone Debug build는 `build/validation/DHB0921A01/current-source-device-build-r2.log`에서 성공했다. Watch sensor query plan의 legacy `armedAt` 복원 및 high-water 3분 overlap은 회귀 테스트로 검증했다.
- iPhone 17 Pro/iOS 26.5 Simulator에서 전체 `WatchSensorQueryPlanTests`와 대형 unknown-boolean-array 취소 테스트를 실행해 36/36 PASS, 0 fail/skip, runtimeWarnings 0을 확인했다 (`build/validation/WAO0921A01/watch-and-parser.xcresult`). 포함 회귀: `testLegacyHighWaterWithoutPendingSessionSurvivesRecorderRearm`, `testLegacyHighWaterOverlapIsRereadAndStableSampleIDsDeduplicateIt`, `testAmbientSampleArchiveKeepsOneValuePerStableSampleID`, `testRawSensorArchiveDecoderChecksCancellationInsideUnknownBooleanArray`.
- 실제 Apple Watch sensor late-arrival 및 WatchConnectivity 전달은 이 Simulator 결과로 대체하지 않으며 별도 하드웨어 게이트로 남긴다.
- ACK0921A03 코드 감사: 진행 중 flush의 중복 호출은 후속 flush로 보존된다. outbox read 실패 시 요청·추적 delivery ID를 재예약하고 둘 다 비어 있으면 `outbox-read` sentinel로 전체 재조회한다. `testUnrelatedOutboxReadFailureRetainsTrackedAcknowledgementRetries`가 tracked-ID/sentinel 정책을 확인하며 위 36/36 결과에 포함됐다. 별도 interleaving 오류 주입 테스트는 없지만 현재 제어 흐름상 pending ID 고립 결함은 재현되지 않아 코드 변경 없이 항목을 닫았다.
- ACK0921A02 / WSP0921A01 코드 감사: ACK retry count 8에서도 재시도 허용, 지연은 5분으로 상한 처리하며 상태를 저장·복원한다. Watch fallback spool은 41 summary/121 chunk까지 eviction 없이 보존하고, DB append가 성공한 뒤에만 정확히 commit된 값을 제거한다; append 실패는 queue를 유지한다. `testAmbientAcknowledgementRetryPersistsAndBackoffCapsWithoutAttemptLimit` 및 `testFallbackSensorSpoolHasNoEvictionAndRemovesOnlyCommittedSnapshots`가 위 36/36 결과에서 통과했다. Watch 실기기 delivery는 별도 검증 게이트다.

## 2026-09-21 API0921A01 / API0921A02 · Swift package 공개 API 회귀

- 현재 소스 SwiftPM 테스트: TaptionPlanCore 85/85, TaptionActivityEngine 25/25, TaptionRouteEngine 36/36, TaptionPlanEngine 1/1 PASS, 전부 실패 0 (`build/validation/API0921A01/TaptionPlanCore.log`, `TaptionActivityEngine.log`, `TaptionRouteEngine.log`, `TaptionPlanEngine.log`).
- 이전 실행 당시에는 기존 `Set<String>` 반환 시그니처와 exact-identifier 대안 컴파일, `TaptionPlanEngine.version == "1"` 및 umbrella re-export 회귀가 포함됐다. Xcode 빌드 락 안에서 실행했다.
- 후속 API0921A01 정리에서 의미가 없는 `version` 상수와 고정 assertion을 제거하고 umbrella re-export만 유지했다. facade test target은 `TaptionPlanEngine`만 import/depend하며 PlanCore·Activity·Route 타입을 소비한다. SwiftPM 1/1 PASS, iPhone 14 Pro/iOS 27.2 Debug build exit 0.

## 2026-09-21 ACK0921A01 / MIG0921A01 · Watch ACK 재시도와 불완전 archive 차단

- `SensorDayStoreTests` + `WatchSensorQueryPlanTests` 전체 집중 회귀가 iPhone 17 Pro/iOS 26.5 Simulator 115/115 PASS, 실패·skip·runtime warning 0 (`build/validation/ACK0921A01-MIG0921A01/full-focused.xcresult`, `full-focused.log`). 별도 최초 focused set도 5/5 PASS (`build/validation/MIG0921A01-strict-read-ACK0921A01/focused.xcresult`). 포함: `testPendingAmbientOutboxItemsRemainRetryableUntilAcknowledged`, `testAmbientAcknowledgementDeletionFailureSchedulesRetry`, retry/backoff·outbox-read 실패 회귀, `testAllReadingsForMigrationRejectsIncompleteArchive`.
- Watch outbox는 ACK 전 pending ID를 다시 예약하고 ACK 저장 실패 시 해당 ID의 재시도를 예약한다. 일반 archive 조회의 부분 복구 동작은 유지하고 Plan-day migration 진입만 불완전 archive에서 거부한다. Simulator test build에서 Watch 타깃을 watchOS Simulator Debug로 컴파일했다; 페어링 Watch 실기기 전달은 별도 게이트다.
- Plan-day migration의 전체 기록 배열·월 payload·날짜 dictionary 문제는 남아 있어 V3 계약 유지+초과 시 안전 중단과 V4 paged readings 저장 중 선택이 필요하다.

## 2026-09-21 LEG0921A01 · snapshot-only generation의 stale raw 격리

- `SecurityBackupCoreTests.testRestoreDoesNotAssociateStaleLegacyRawWithSnapshotOnlyGeneration`는 final full iPhone 17 Pro Simulator suite r3에서 PASS했다. xcresult readback: 1,229 passed, 1 skipped, 0 failed, runtime warnings 0 (`build/validation/DLS0921A01/TSN0921A01/full-app-regressions-r3.xcresult`; test log의 개별 method도 passed 확인). generation 없는 과거 raw를 snapshot-only generation에 결합하지 않는 동작을 유지한다.

## 2026-09-21 LFR0921A01 · legacy migration 읽기 실패 보존

- `Data(contentsOf:)` 실패를 빈 migration 입력으로 삼지 않고, 파일 미존재 외 오류는 완료 marker를 기록하기 전에 전파한다. 읽기 실패 후 legacy 원본 복구 및 재시도에서 행이 들어오는 회귀를 포함한 집중 테스트 1/1 PASS. 결합 결과 `build/validation/RVR0921A01/focused.xcresult` (iPhone 17 Pro Simulator/iOS 26.5).

## 2026-09-21 RVR0921A01 · transit POI active-scene gate

- 비활성 scene의 POI refresh 예약을 차단하고 resolver 완료 시 active scene을 다시 확인한다. 활성/bootstrap 정책 XCTest 1/1 PASS; 위 집중 결과에서 두 회귀 모두 2/2 PASS. generic iOS Debug build exit 0, bundle `com.taption.plan` build 149 (`build/validation/RVR0921A01/derivedData/Build/Products/Debug-iphoneos/TaptionPlan.app`). 실기기 설치/TestFlight 배포는 하지 않았다.

## 2026-09-21 AWW0921A01 · Watch 운동 동률 결정성

- 동일 구간의 Apple Watch 걷기·달리기 workout은 겹침 길이를 우선 비교하고, 동률은 `TravelMode` 선언 순서로 선택한다. 입력 순서를 뒤집어도 걷기·high confidence 결과가 같은 회귀 테스트 1/1 PASS (iPhone 17 Pro Simulator/iOS 26.5, `build/validation/AWW0921A01/watch-workout-tie.xcresult`). generic iOS Debug build exit 0, 앱 산출 확인 (`build/validation/AWW0921A01/derivedData/Build/Products/Debug-iphoneos/TaptionPlan.app`). 실기기 설치/TestFlight 배포는 하지 않았다.

## 2026-09-20 BUG1909R01 · iPhone build 149 watchdog/CPU 원인

- iPhone 14 Pro/iOS 26.6.2 build 149 OS crash report 5건(9/17 3건·9/18 2건)은 모두 `FRONTBOARD/0x8BADF00D` scene-update 30초 watchdog이다. Crash thermal state는 nominal, dSYM UUID 일치는 `e97cfbeb-cbdb-36e9-bce0-bcf848553542`다. 9/18 21:36 main-thread stack은 route sample/segment마다 full actuals를 filter/max하는 `RouteTimelineDataEngine.category(at:in:through:)`; 9/17 3건과 9/18 22:58은 full overrides를 매 샘플 filter/sort하는 `ActivityClassificationEngine.classification(for:overrides:)`를 가리킨다. 정렬 중 `UUID.uuidString` 반복 생성도 확인했다.
- CPU report 8건(9/18 3건·9/19 5건)은 비전면/idle 상태에서 48 CPU초/49–55초, 87–99% CPU를 기록했다. classifier와 함께 expected/live route 및 WBS projection의 반복 동기 계산이 보이며 일부 AppModel review archive/persist task도 sample에 포함된다. 9/20 CPU report는 없지만, 같은 날 00:15의 background file-lock crash는 별도 `BKG0920A01`로 확인했다.
- 수정: Activity override heap sweep·UUID bytes tie-break·취소 가능한 utility 분류/병합; day-scoped Route CategoryIndex sweep; inactive scene에서 live/expected route·WBS 계산 취소/차단 및 expected-route 100ms coalescing. UI 배치, 원본 센서, 저장 계약, TestFlight 상태는 변경하지 않았다.
- 검증: Core 54/54·Activity 17/17·Route 20/20·PlanEngine umbrella 1/1·HealthKit focused 24/24; 전체 iPhone 17 Pro Simulator XCTest 1,121건 중 1,120 PASS·기존 StoreKit 1 SKIP·0 FAIL. 최종 결과 `build/validation/BUG1909R01/final-tests.xcresult`. generic iOS Debug build, `analyze`, Watch scheme Debug build PASS.
- `PKGA0920R1`: Activity/Route package source에서 참조하지 않던 PlanCore manifest dependency 제거 후 `swift test` 각각 17/17·20/20 PASS. 통합 generic iOS Debug build도 `CODE_SIGNING_ALLOWED=NO`로 PASS. 기기 설치·TestFlight 배포는 하지 않았다.
- 전체 앱 회귀 재실행 뒤 Swift Package 경계도 개별 검증했다: TaptionPlanCore 60/60, TaptionActivityEngine 17/17, TaptionRouteEngine 24/24, TaptionPlanEngine umbrella 1/1 PASS·0 failures. 이후 512개 중첩·만료 classifier override를 naive 우선순위 참조 구현과 전 timestamp에서 비교하는 회귀를 추가하고 Activity package 18/18 PASS를 재확인했다.
- 9/20 10:18 KST current-state package rerun: TaptionPlanCore 60/60, Activity 19/19, Route 25/25 (10:12 KST), PlanEngine umbrella 1/1 PASS. DayStore 30-day cold/warm p95 was 0.053292/0.017375 ms. These are SwiftPM macOS Debug results, not iOS build or physical-device evidence.
- 실기기 수정본 설치/실행·장시간 CPU 재측정·신규 crash readback은 미실시이며 별도 게이트다. TestFlight 업로드·설치는 하지 않았다.
- 9/20 02:41 KST read-only 기기 확인: iPhone 14 Pro에 Taption Plan 1.0(149)이 설치되어 있고, `systemCrashLogs`상 최신 TaptionPlan 종료는 수정 전 00:15:55 보고서다. 9/20 TaptionPlan CPU-resource 보고서는 없다. 이번 로컬 수정본은 설치되지 않아 post-fix 기기 결과로 해석하지 않는다.
- `IOS920E001` fresh readback: CoreDevice local-network로 연결한 iPhone 14 Pro의 현재 설치본은 여전히 1.0(149)이다. 보관함에서 TaptionPlan 앱 종료 7건과 CPU-resource 18건을 확인했다. 최신 앱 종료는 9/20 00:15:55 KST `0xDEAD10CC` raw-archive/background-lock 보고서이고, 최신 CPU 보고서는 9/19 15:43 KST 약 48 CPU초/49초(99%)다. 별도 Watch 종료의 최신 proxied report는 9/20 11:18:18 KST, Watch build 149 `EXC_BREAKPOINT/SIGTRAP`; Watch dSYM UUID 일치 및 `requestSync()` callback 원인은 아래 WCE0920A01과 같다. 두 report 계열 모두 수정 전 build 149이며 수정본의 기기 런타임 재발 증거는 아니다.
- 이번 turn 재확인: 물리 iPhone 14 Pro는 연결 상태이며 `com.taption.plan`은 여전히 1.0(149)이다. 로컬 수정본 설치나 기기 조작은 하지 않았으므로 post-fix 런타임 증거는 없다.
- 9/21 00:19 KST fresh `systemCrashLogs` readback: iPhone 14 Pro still runs pre-fix TestFlight 149. The newest iOS app termination remains 9/20 00:15:55 `0xDEAD10CC`; the newest app CPU report is 9/19 15:43:26, 48 CPU seconds in 48.26 seconds (99%, thermal pressure 0). The proxied Watch report remains 9/20 11:18:18. No newer TaptionPlan iOS/CPU/Watch report was listed. The crash's app UUID matches 149 dSYM UUID `e97cfbeb-cbdb-36e9-bce0-bcf848553542`; focused copies are preserved in `build/validation/BUG1909R01/current-readback-20260921/`. Local fixes remain uninstalled, so this confirms the prior-build diagnosis, not post-fix runtime behavior.
- 현재 소스 iPhone 17 Pro Simulator 전체 XCTest 1,168 PASS·1 SKIP·0 FAIL (`build/validation/BUG1909R01-full-current.xcresult`); 유일한 skip은 iOS 26.5 StoreKitTest `SKInternalErrorDomain Code 3`. 독립 SwiftPM macOS Debug 재검증: TaptionPlanCore 69/69 (30-day cold/warm p95 0.028375/0.028250 ms), TaptionActivityEngine 19/19, TaptionRouteEngine 25/25, TaptionPlanEngine 1/1 PASS.
- `PRV0920A01` review fix: override-split ActivitySegments now carry matching provenance spans; the focused split regression and full `TaptionActivityEngine` SwiftPM suite pass 19/19, including the 512-override reference comparison. `git diff --check` passes; no device/TestFlight change.
- `RAT0920A01` review fix: low-confidence route boundaries now advance a monotonic nearest-segment cursor instead of rescanning every segment. The earlier-segment tie rule is covered; full `TaptionRouteEngine` SwiftPM suite passes 27/27 and `git diff --check` passes.
- `GPI0920A01` review fix: equally supported route modes with the same semantic priority now resolve by stable `rawValue` order instead of dictionary iteration order. Reversed-input regression and full `TaptionRouteEngine` SwiftPM suite pass 28/28 (`swift test --package-path Packages/TaptionRouteEngine`). Generic iOS Debug build exits 0 and produces `build/validation/GPI0920A01/DerivedData/Build/Products/Debug-iphoneos/TaptionPlan.app` (bundle `com.taption.plan`, build 149); existing `AppleIntegrations.swift:4470` conformance warning remains. No UI, device, or TestFlight changes.
- `FLR0920A01` review fix: place and walking-location floor votes now share one deterministic selector; equal counts choose the lower floor, matching `FloorCalibrationEngine`. Reversed-input regressions for both detectors pass 1/1 on iPhone 17 Pro Simulator/iOS 26.5 (`build/validation/FLR0920A01/focused-fixed.xcresult`); generic iOS Debug build exits 0 and produces `build/validation/FLR0920A01/DeviceDebugDerivedData/Build/Products/Debug-iphoneos/TaptionPlan.app` (bundle `com.taption.plan`, build 149). No physical-device install or TestFlight upload.
- `CSE0920A01` review fix: stationary-context calendar selection preserves attendee-count priority, then prefers greater stay overlap and stable calendar/id/title order. The reversed meal/meeting input regression passes 1/1 on iPhone 17 Pro Simulator/iOS 26.5 (`build/validation/CSE0920A01/focused.xcresult`); generic iOS Debug build exits 0 and produces `build/validation/FLR0920A01/DeviceDebugDerivedData/Build/Products/Debug-iphoneos/TaptionPlan.app` (bundle `com.taption.plan`, build 149). No UI, device, or TestFlight changes.
- `TMC0920A01` review fix: tied Core Motion evidence now prefers stationary/unknown before movement, and tied travel candidates use `TravelMode` declaration order. Automotive/stationary and reversed iPhone workout evidence regression passes 1/1 on iPhone 17 Pro Simulator/iOS 26.5 (`build/validation/TMC0920A01/focused.xcresult`); generic iOS Debug build exits 0 with bundle `com.taption.plan`, build 149. No physical-device install or TestFlight upload.
- `MCE0920A01` review fix: movement-correction ties retain score and recency priority, then choose a stable correction ID. Reversed-order apply/query/remove regression passes 1/1 on iPhone 17 Pro Simulator/iOS 26.5 (`build/validation/MCE0920A01/focused.xcresult`); generic iOS Debug build exits 0 with bundle `com.taption.plan`, build 149. No physical-device install or TestFlight upload.
- `UPS0921A01` review fix: unregistered-place recommendations now resolve equal visit counts and last-visit times by stable suggestion ID. The broader 10-test suggestion suite, including reversed-input coverage, passes on iPhone 17 Pro Simulator/iOS 26.5 (`build/validation/UPS0921A01/suggestion-suite-r1.xcresult`); generic iOS Debug build exits 0 with bundle `com.taption.plan`, build 149. No physical-device install or TestFlight upload.
- `CLT0921A01` review fix: equal-time stays are ordered by place key/ID, and exactly equidistant stays join the first stable cluster. The boundary/reversed-input regression is included in the same 10/10 iPhone 17 Pro Simulator result (`build/validation/UPS0921A01/suggestion-suite-r1.xcresult`).
- Earlier broad verification sweep: TaptionPlanCore 81/81, TaptionActivityEngine 19/19, TaptionRouteEngine 27/27, and TaptionPlanEngine umbrella 1/1 SwiftPM tests pass. DayStore 30-day cold/warm p95 is 0.027042/0.019292 ms; NLE 240Hz p95 is 0.000042 ms. Generic iOS Debug build exited 0 and produced `build/validation/PRV0920A01/DerivedData/Build/Products/Debug-iphoneos/TaptionPlan.app` (version 1.0, build 149). This sweep predates GPI0920A01; the changed Route package and app were rebuilt as recorded above. `git diff --check` passes. No physical-device install or TestFlight upload was performed.
- generic iOS static analysis exit 0. Existing `AppleIntegrations.swift:4470` `@preconcurrency` conformance warning remains; that user-modified file was preserved.
- 최신 checkout 통합 회귀: `RouteTimelineDataTests` + `TaptionRouteEngineAdapterTests` 89/89 PASS·0 FAIL·0 SKIP (`build/validation/PKG920P001/app-focused.xcresult`); generic iOS Debug build PASS·exit 0 (`build/validation/PKG920P001/ios-debug.log`). SwiftPM `TaptionPlanCore` 77/77, `TaptionRouteEngine` 26/26 PASS. 이 검증은 iPhone 17 Pro Simulator/macOS package test이며 실물 기기 설치·TestFlight 검증이 아니다.
- `AppModel.applyCloudBackup` pre-cancel regression: 1/1 PASS·0 FAIL·0 SKIP (`build/validation/RST0920A01/restore-cancel.xcresult`, iPhone 17 Pro Simulator). TestFlight·실기기 설치 없음.
- `AppModel.applyCloudBackup` raw-preflight `CancellationError` propagation: 1/1 PASS·0 FAIL·0 SKIP (`build/validation/RST0920A01/restore-preflight-verified.xcresult`, iPhone 17 Pro Simulator/iOS 26.5). The fixture uses a location-bearing reading because the raw export policy drops readings without a route point; no physical device/TestFlight installation.
- BUG1909R01 수정 직후 통합 회귀: `SecurityBackupCoreTests`+`SensorDayStoreTests` 123/123 PASS·0 FAIL·0 SKIP (`build/validation/BUG1909R01-reviewed-tests5.xcresult`, iPhone 17 Pro Simulator, iOS 26.5). 당시 Core/Activity/Route/PlanEngine package는 각각 59/59·17/17·24/24·1/1 PASS. 이후 migration 회귀 123건 및 Core 60건 결과는 아래 MIG0920A01에 기록했다.
- 첫 검증 simulator에서는 XCTest test case 진입 전 `The test runner hung before establishing connection`으로 종료됐다. 첨부 spindump는 해당 프로세스의 `TaptionPlanApp.$main`/Mach message 대기만 보였고 테스트는 0건 실행됐다. 독립 validation simulator에서 재실행해 123건 전부 통과했다 (`build/validation/BUG1909R01-runner-diagnostics/`).

## 2026-09-20 QCP0920R01 / RSE0920R01 / DNL0920R01 / DHE0920R01 / CAS0920R01 / WRS0920A02

- sensor timeline 취소는 detached quality worker에 전달하고 scalar 및 route filtering 내부에서 cooperative check한다. 잘못 설정됐던 취소 회귀 checkpoint를 robust filter 내부로 옮겼다.
- stale source invalidation이 append 이후 발생하면 해당 save가 새로 넣은 raw sensor event만 exact-row CAS로 rollback한다. stale event append 재현·수정 회귀와 동시 교체 event 보존 회귀를 포함한다.
- legacy SQLite event/snapshot/map/migration key의 embedded NUL을 거부하고, snapshot equality/hash를 SQLite byte-exact domain identity에 맞췄다. materialized rollback CAS는 generatedAt/firstTimestamp/lastTimestamp도 비교한다.
- commerce lock이 진행 중 workout reset teardown을 무효화하지 않도록 gate를 분리했다.
- TaptionPlanCore 69/69 PASS (`swift test --package-path Packages/TaptionPlanCore`; cold/warm 30-day p95 0.028792/0.017542 ms). Route/activity adapter, Watch gate, stale-save focused iPhone 17 Pro Simulator 회귀 33/33 PASS (`build/validation/WPD0920A01-watch-cleanup-regressions.xcresult`).

## 2026-09-20 WPD0920A01 · purge와 HealthKit 저장 workout 경합

- stop 중 purge가 시작된 뒤 `finishWorkout()`이 `HKWorkout`을 저장할 수 있다. 이제 stale reset 경로가 반환 workout을 별도 보유해 HealthKit에서 삭제하며, 삭제가 실패하면 purge를 성공 처리하지 않고 workout 참조를 다음 시도까지 유지한다.
- watchOS Simulator Debug build PASS·exit 0. HealthKit 삭제 성공/실패 callback 및 페어링 Watch 런타임은 직접 검증되지 않았다.

## 2026-09-20 PGR0920A01 · DB purge 실패 시 Watch 원본 보존

- 기존 순서는 manager archive·메모리 삭제 뒤 SQLite purge를 수행해, DB 삭제 실패가 반환돼도 Watch 원본이 이미 삭제될 수 있었다. 재시도 defer도 보존된 ambient outbox를 다시 전송할 수 있었다.
- producer/writer 정지와 대기 뒤 SQLite purge를 먼저 수행하고, 성공 후에만 manager archive를 제거한다. purge 실패 시 자동 outbox 재전송을 하지 않는다.
- `WatchDeletionPayloadTests` 14/14 PASS·0 FAIL·0 SKIP (`build/validation/PGR0920A01/purge-related-tests.xcresult`). `TaptionPlan` iPhone 17 Pro Simulator 테스트 빌드에서 embedded Watch Debug target도 컴파일됐다. HealthKit 실패 경로와 페어링 Watch 런타임은 미검증이다.

## 2026-09-20 RCL0920A03 · raw archive restore 파일 읽기 취소

- 최대 512 MiB raw archive restore 파일 읽기를 1 MiB `FileHandle` chunk로 나누고 cancellation을 전달한다. JSON envelope도 streaming scanner로 읽고, 큰 `encryptedPayload` base64는 JSON escaped slash를 보존하면서 1 MiB씩 decode해 65,536자 단위로 cancellation을 확인한다.
- file-read cancellation·payload 내부 cancellation·escaped-base64 slash·v1 archive compatibility 집중 회귀 4/4 PASS (`build/validation/RCL0920A03-parser-final.xcresult`). 전체 `SecurityBackupCoreTests` 80/80 PASS·0 FAIL·0 SKIP (`build/validation/RCL0920A03-security-backup-full-final.xcresult`).

## 2026-09-20 REF0920A01 · 미사용 위젯 snapshot 경로 정리

- 전체 Swift 참조를 확인해 production 경로에서 사용하지 않는 `WidgetTimelineItem`, `WidgetSnapshot`, `WidgetSnapshotFactory`와 전용 테스트만 제거했다. 실제 위젯 payload 경로와 production에서 쓰이는 `WidgetAction`은 유지했다.
- net 71줄 감소. `FeatureEngineTests.testCatMotionRespectsReduceMotion` 통과; 앱·테스트 target 빌드 포함 결과는 `build/validation/BUG1909R01-widget-prune.xcresult`에 있다. `git diff --check` 통과.

## 2026-09-20 REV0920A01 · 백업 전체 삭제와 generation 저장 경합

- 원인: `saveMonthlyGeneration`이 cloud key await 뒤에 준비 revision을 확인하지 않아, 대기 중 `deleteAllBackups()`가 두 저장소를 비워도 재개된 작업이 raw archive와 snapshot을 다시 쓸 수 있었다.
- 수정: await 전 PIN·준비 revision·data-deletion generation을 캡처하고, 재개 직후 모두 재검증해 stale 저장을 취소한다. 잠금 provider로 삭제 도중을 재현하는 `testAsyncMonthlyGenerationCannotRecreateDeletedBackups`를 추가했다.
- `SecurityBackupCoreTests` 70/70 PASS·0 FAIL·0 SKIP (`build/validation/BUG1909R01-security-backup-regression.xcresult`).

## 2026-09-20 BKR0920A01 · 비동기 백업 삭제 경합

- `saveRawSensorArchive()`와 `loadLatestBackup()`의 계정 키 대기 중 전체 백업 삭제 또는 PIN 변경이 일어나도 작업이 stale 상태를 검사하지 않고 원시 파일/스냅샷을 다시 쓸 수 있었다. await 전 verifier·준비 revision·data deletion generation을 캡처하고 재개 직후 재검증해 오래된 작업을 취소한다.
- 삭제 후 raw 저장 방지, 대기 중 PIN 교체 취소, 계정 키 fallback 중 삭제 후 snapshot 재저장 방지 테스트를 추가했다. `SecurityBackupCoreTests` 73/73 PASS·0 FAIL·0 SKIP (`build/validation/BKR0920A01-security-suite.xcresult`).
- BKR 최초 전체 앱 회귀에서 cold-load p95가 100.605666ms로 100ms 한도를 0.605666ms 초과했으나, 단독 재실행 1/1 및 추가 반복 3/3 통과 후 전체 재실행도 1,140 PASS·기존 StoreKit 1 SKIP·0 FAIL로 완료됐다 (`build/validation/BKR0920A01-full-retry.xcresult`). 진단용 직렬 전체 재실행은 XCTest runner가 시작되기 전 Xcode test-log finalization에서 6분 고착되어 중단했으며 유효 결과가 아니다.

## 2026-09-20 MIG0920A01 · migration 충돌과 저장 경쟁 회귀

- legacy raw-event migration이 서로 다른 여러 import 충돌 중 첫 건만 정리해 다음 충돌에서 멈추던 결함을 수정했다. legacy provenance가 일치하는 충돌만 반복 제거·재시도하며, 동일 충돌이 되풀이되면 중단한다. 복수 충돌 import와 unmarked 원본 보존을 검증했다.
- 최초 migration 통합 `SecurityBackupCoreTests`+`SensorDayStoreTests` 123/123 PASS·0 FAIL·0 SKIP (`build/validation/MIG0920A01-final-tests.xcresult`). Core package 60/60 PASS; stale materialized rollback이 별도 SQLite writer의 최신 값을 보존하는 회귀도 포함한다. 최신 통합 재실행 결과는 아래 TST0920A01에 기록한다.
- generic iOS Simulator Debug, `analyze`, watchOS Simulator Debug 모두 종료 코드 0이며 앱 산출물이 생성됐다. 실기기 수정본 설치·실행과 TestFlight 배포는 미실시다.

## 2026-09-20 TST0920A01 · 센서 아카이브 취소 전파

- `SensorReadingArchive.decodeReadings`와 `RawDeviceDataDayArchive.decodedEnvelopes`를 128개 이벤트 단위 async batch로 바꿔 batch 사이에 actor를 양보하고 task cancellation 및 deletion generation을 확인한다. 2,346개 legacy repair와 300개 raw-envelope 다중 batch 회귀가 통과했다.
- cooperative decode와 최초 migration 잠금 분리 후 `SensorDayStoreTests` 57/57, `SecurityBackupCoreTests`+`SensorDayStoreTests` 통합 130/130 PASS·0 FAIL·0 SKIP (`build/validation/MLK0920A01-final-integrated.xcresult`). 동일 legacy 원본에 대한 concurrent migration 10/10 반복 PASS (`build/validation/MLK0920A01-concurrent-stress.xcresult`). 최신 전체 앱 suite 1,142 PASS·기존 StoreKit 1 SKIP·0 FAIL (`build/validation/MLK0920A01-full-retry.xcresult`); `testThirtyDayAppColdAndWarmLoadP95StaysInteractive`도 통과했다. 현재 소스 generic iOS Debug exit 0 및 `.app` 생성도 확인했다.
- 내부 batch/repair 경계에서 정지 가능한 테스트 checkpoint를 주입해 decode 중 취소 후 원본 보존·재시도 및 repair 직전 삭제 후 stale write 거부를 결정적으로 검증했다. iPhone 17 Pro Simulator focused XCTest 2/2 PASS (`build/validation/TST0920A01-checkpoint-retests-verified.xcresult`). 최초 실행 실패는 fixture가 직접 연 SQLite의 상위 임시 디렉터리를 만들지 않은 테스트 설정 오류였으며, fixture 생성 순서를 고친 후 통과했다.
- 현재 Swift Package 재실행: PlanCore 60/60, Activity 17/17, Route 24/24, umbrella PlanEngine 1/1 PASS·실패 0. PlanCore의 30일 cold/warm p95는 각 30.667ms·19.083ms.

## 2026-09-20 MLK0920A01 · 최초 센서 migration 잠금 구간

- 원인: migration marker가 없는 최초 접근에서 legacy JSON/raw/tracking source decode·event encode가 shared App Group lock 및 background assertion 안에서 실행됐다.
- 수정: marker 조회, 각 256-event append transaction, 최종 marker commit만 잠금 안에서 수행하고 source decode·정규화는 잠금 밖에서 한다. 매 batch 전 task cancellation·deletion generation·완료 marker를 재검사한다. `appendUniqueEvents`의 동일 ID 동일 payload 중복 제거 계약을 사용해 동시 migration이 안전하게 합류한다.
- 검증: 같은 640개 legacy 원본에 대한 두 archive 인스턴스 동시 migration과 최종 행 수/marker readback 회귀 추가. focused test 10/10 반복, `SensorDayStoreTests` 57/57, `SecurityBackupCoreTests`+`SensorDayStoreTests` 130/130, generic iOS Debug exit 0. full raw-source 집계의 메모리 peak는 이 변경 범위에 포함되지 않는다.

## 2026-09-20 DGD0920A01 / EVK0920A01 · SQLite digest cache와 raw event identity

- Digest 스캔 후 별도 autocommit 저장 전 다른 SQLite connection이 event/cache를 갱신할 수 있던 경합을, `BEGIN IMMEDIATE` 안의 version 재확인·저장으로 닫았다. 구버전에서 남을 수 있는 파생 digest cache는 migration marker로 1회 비운다. Batch 중복 검증은 `domain|id` 문자열 충돌 대신 중첩 map으로 tuple identity를 유지한다.
- `TaptionPlanCore` XCTest 57/57 PASS, generic iOS Debug build PASS·exit 0 (`build/validation/DGD0920A01/DerivedData/Build/Products/Debug-iphoneos/TaptionPlan.app`). 회귀는 delimiter 포함 identity, 오래된 persisted cache 재오픈 무효화, 동시 append/digest 후 신규 store readback을 포함한다. 수정본 실기기 설치 및 TestFlight 배포는 하지 않았다.

## 2026-09-20 RTE0920A01 · GPS route gap interpolation

- `RouteTimeCoordinateIndex`와 app adapter가 route segment 경계를 유지하도록 변경했다. 15분 초과 GPS 공백 내부 시각은 좌표를 합성하지 않고 `nil`을 반환한다. segment 입력이 시간순이 아니거나 구간이 겹쳐도 index 양 끝점 조회는 전체 범위를 사용한다.
- RouteEngine package 23/23 PASS; `TaptionRouteEngineAdapterTests` 12/12 PASS (`build/validation/RTE0920A01/adapter-tests-verified.xcresult`, 0 fail/skip); generic iOS Debug build exit 0, 실행 파일 산출 확인.
- iPhone 설치/실행 및 TestFlight 배포는 하지 않았다.

## 2026-09-20 WCH0920A01 · Watch 삭제와 운동 시작 경합

- HealthKit 권한·운동 collection·metadata 작업이 await 중일 때 로컬 전체 삭제가 완료되면, 오래된 start continuation이 재개되어 운동 세션을 다시 시작할 수 있었다. Purge generation과 active purge set으로 stale 시작을 폐기하고 삭제 중 신규 시작을 차단한다.
- `WatchWorkoutStartGateTests` 2/2 PASS (`build/validation/WCH0920A01/watch-gate-tests.xcresult`); generic watchOS Simulator build PASS. Watch 실기기 동작은 미확인이다.

## 2026-09-20 WST0920A01 · Watch workout start/stop/reset와 삭제 경합

- 시작 세대가 stale일 때 `beginCollection`/`addMetadata` 이후 단순 반환하면 HealthKit 세션·builder가 남을 수 있었다. stop/reset이 await 중 purge가 끼어들면 늦은 결과로 상태 변경·오류 게시·ambient recording 재시작을 할 수 있었다. stale start 정리와 stop/reset await 경계의 gate 검사를 추가하고, 설정·동기화 경로를 포함한 ambient refresh는 purge/reset 중 차단한다.
- `WatchWorkoutStartGateTests` 5/5 PASS (`build/validation/WST0920A01-final/gate-tests.xcresult`); generic watchOS Simulator Debug build PASS·exit 0 (`build/validation/WST0920A01-reset/watch-DD`). 실제 HealthKit workout 수명주기는 페어링 Watch에서 확인하지 않았다.

## 2026-09-20 WCF0920A01 · 이전 HealthKit 세션 오류 callback 차단

- 이전 workout session의 늦은 `didFailWithError`가 현재 운동까지 reset할 수 있던 경로를, callback session이 현재 session과 동일할 때만 reset하도록 제한했다. 정상 reset도 HealthKit session/builder delegate를 해제한다.
- generic watchOS Simulator Debug build PASS·exit 0 (`build/validation/WST0920A01-reset/watch-DD`). HealthKit 지연 callback 자체는 시뮬레이터에서 재현할 수 없어 직접 런타임 미검증이며, 같은 변경군의 위치 세대/ambient archive 재시도 정책 XCTest 2/2 PASS (`build/validation/WCF0920A01/watch-data-tests-retry.xcresult`).

## 2026-09-20 WLP0920A01 · 이전 운동 위치 유입 차단

- 비동기로 전달된 CoreLocation 점은 현재 운동 시작 시각 이후의 timestamp만 route에 추가하도록 제한했다. 운동 A의 늦은 위치가 운동 B에 포함되지 않는 정책 회귀를 위 결과에서 검증했다.

## 2026-09-20 WAD0920A01 · ambient 원본 archive 재시도 멱등화

- 전송 실패 후 같은 recorder watermark가 재처리되어도 월별 JSONL에 session/sequence 기준으로 이미 저장된 표본을 다시 추가하지 않는다. 앱 재시작 시 파일에서 sequence index를 재구성하며, write 오류 시 캐시를 버려 부분 기록을 다시 확인한다. sequence-index XCTest는 `watch-data-tests-retry.xcresult`에서 통과했고 generic watchOS Simulator Debug build도 통과했다. 실물 Watch archive 재시도 동작은 미검증.

## 2026-09-20 WDR0920A01 · late ambient 표본 재시도 sequence 안정화

- pending ambient session의 표본 번호가 재조회 때마다 1부터 초기화돼 늦게 도착한 앞쪽 표본이 기존 sequence를 밀어내는 문제를 수정했다. 고정된 query anchor와 sample timestamp로 sequence/ID를 결정하고, append index는 pending session의 실제 기록 sequence만 기억해 미기록의 낮은 sequence는 수용하고 재전송은 거른다.
- `WatchSensorQueryPlanTests` 24/24 PASS (`build/validation/WDR0920A01/ambient-retry-r2.xcresult`), `WatchWorkoutDataIsolationTests` 2/2 PASS (`build/validation/WDR0920A01/ambient-index.xcresult`), generic watchOS Simulator Debug PASS·exit 0 (`build/validation/WDR0920A01/watch-debug.log`). 실물 Watch runtime 검증은 하지 않았다.

## 2026-09-20 WPC0920A01 · ambient durable 재시도 및 append 충돌 방지 (실물 연동 확인 대기)

- Watch는 ambient raw event와 immutable delivery payload를 SQLite outbox에 한 트랜잭션으로 저장하고, iPhone의 durable 저장 ACK까지 재전송한다. 고정 10분 구간의 summary revision과 변경된 acceleration chunk ID를 사용해 늦은 표본을 append-only 저장소에서 새 revision으로 보존한다. iPhone은 최신 summary revision과 stable sample ID를 병합한다. ACK 처리와 50건 페이지 flush가 겹쳐도 다음 조회 요청을 잃지 않도록 보완했다.
- Core 73/73 PASS (`build/validation/WPC0920A01/core-final.log`); iPhone 17 Pro/iOS 26.5 Simulator의 Watch query 및 revision/archive 집중 회귀 30/30 PASS (`build/validation/WPC0920A01/ambient-outbox-final2.xcresult`); purge 포함 generic watchOS Simulator Debug PASS (`build/validation/WPC0920A01/watch-debug-final2.log`). 실물 Watch↔iPhone 연결에서 비활성/재시작/ACK 재전송 동작은 미검증이며, 코드 변경만으로 실기기 원인을 확인했다고 간주하지 않는다.

## 2026-09-20 LQA0920A01 · legacy ambient snapshot 보존

- SQLite outbox에 넣은 snapshot과 정확히 동일한 legacy ambient summary/chunk만 기존 큐에서 제거하도록 공유 함수를 적용했다. 저장 await 중 새로 도착했거나 같은 ID의 내용이 갱신된 항목은 유지한다.
- `SensorDayStoreTests/testLegacyAmbientAdoptionRemovesOnlyPersistedSnapshotValues` PASS in 2/2 focused tests (`build/validation/LQA0920A01/ambient-policies.xcresult`). iOS 26.5 Simulator test build also compiled embedded Watch and Widget targets. Watch 실기기 실행은 하지 않았다.

## 2026-09-20 RTA0920A01 · ambient outbox 실패 재시도

- 실패한 `transferUserInfo` 중 delivery ID가 있고 세션이 활성 상태이며 purge 중이 아닐 때만 5초 지연 outbox flush를 예약한다. 성공/ACK callback에는 재전송을 걸지 않는다.
- `SensorDayStoreTests/testAmbientOutboxRetryPolicyRequiresFailedActiveDeliveryOutsidePurge` PASS with LQA regression, 2/2 focused tests (`build/validation/LQA0920A01/ambient-policies.xcresult`). 실물 Watch 연결에서 callback 후 재전송까지는 미검증이다.

## 2026-09-20 WFB0920A01 · WVR0920A01 · Watch 테스트 삭제 cutoff 격리

- Simulator App Group UserDefaults에 이전 실행의 `TaptionPlan.dataDeletionCutoff`가 남아, 현재 시각보다 오래된 Watch summary를 `retainingData`가 archive 저장 전에 정상 거부했다. 이에 따라 fallback readback과 최신 ambient revision snapshot 검증이 모두 실패했다. 제품 삭제 fence 변경은 불필요하다.
- 두 테스트에서 이전 cutoff를 보존한 뒤 제거하고 종료 시 복구하도록 수정했다. fallback 테스트는 `AppModel.bootstrap()`도 전달 전에 완료한다. 전체 `SensorDayStoreTests` 직렬 실행은 71/71 PASS·0 FAIL·0 SKIP (`build/validation/LQA0920A01/sensor-day-final-fence.xcresult`, iPhone 17 Pro Simulator/iOS 26.5); 수정 전 69 PASS/2 FAIL은 Simulator에 남은 cutoff state 때문이었다. 수정본 parse와 `git diff --check`도 통과했다.

## 2026-09-20 WCR0920A01 · 레거시 Watch 복원 rollback 중 동시 기록 보존

- `recordForRestore`가 이전 청크 snapshot을 저장하고 반환한 뒤 repository commit을 기다리는 동안 actor가 다른 Watch append를 처리할 수 있었다. 실패 rollback이 이전 전체 snapshot을 덮어써 그 사이 들어온 새 청크가 사라지는 경합을 확인했다.
- archive restore transaction을 repository save 성공까지 유지한다. 동시 chunk append는 정상 저장하고 현재 남아 있는 동시 ID와 최신 보존시각을 추적해 rollback 시 원본과 합친다. 읽기·추가 restore는 transaction 종료까지 기다리고, 취소된 대기 reader는 transaction 해제 후에도 continuation을 남기지 않는다. 네 legacy restore 회귀를 포함한 전체 `SensorDayStoreTests` 61/61 PASS (`build/validation/WCR0920A01/sensor-day-tests-final4.xcresult`, iPhone 17 Pro Simulator/iOS 26.5). 실기기 설치는 하지 않았다.

## 2026-09-20 APP0920A01 · activity incremental tail 중복

- override가 마지막 sample을 여러 span으로 나눌 때 incremental append가 기존 뒤 fragment를 중복 추가하던 회귀를 재현 테스트로 확인하고, 마지막 evidence 시각이 기존 최종 segment 밖이면 전체 재분류하도록 수정했다. 새 회귀를 포함한 Activity package `swift test` 19/19 PASS.
- generic iOS device Debug build PASS·exit 0 (`build/validation/TST0920A01-cooperative-DD/Build/Products/Debug-iphoneos/TaptionPlan.app`). 물리 iPhone 설치·실행은 하지 않았다.

## 2026-09-20 BMS0920A01 · 누락된 committed raw archive 교체 거부

- 기존 snapshot이 raw generation을 가리키지만 파일이 없을 때, 비어 있지 않은 새 payload가 이를 덮어 새 generation을 확정하던 회귀를 실패 테스트로 재현했다. AppModel raw archive read 오류를 백업 저장까지 전파하고, 참조된 generation이 없으면 commit을 거부하도록 수정했다.

## 2026-09-20 TIF0920A01 · App Group 삭제 fence 테스트 격리

- 공유 suite의 기존 `dataDeletionCutoff`·active marker를 보존하고 fixture 종료 때 복구한다. `advance`가 갱신하는 generation은 단조 증가 의미를 지키도록 되돌리지 않는다.
- Watch fallback/revision, stale/canceled sensor read, cached day snapshot, repository deletion fence 테스트 6/6 PASS·0 FAIL·0 SKIP (`build/validation/TIF0920A01/fence-isolation.xcresult`, iPhone 17 Pro Simulator iOS 26.5); `git diff --check` PASS.
- 전체 직렬 `SensorDayStoreTests`와 repository deletion fence 테스트 72/72 PASS·0 FAIL·0 SKIP (`build/validation/TIF0920A01/sensor-day-isolation-full.xcresult`, iPhone 17 Pro Simulator iOS 26.5).

## 2026-09-20 RST0920A01 · raw restore 순차 검증 및 취소 전파

- 복원 중 월별 raw 암호문을 전체 배열에 동시에 쌓지 않고 snapshot별로 하나씩 읽는다. file-backed store의 파일 read/outer envelope decode와 payload decrypt/decompress/Codable decode/ID-conflict merge는 MainActor 밖에서 수행한다. archive 경계 cancellation을 확인하고 `CancellationError`를 `.invalidArchive`로 바꾸지 않는다.
- 최신 통합 회귀에서 `SecurityBackupCoreTests` 77건과 `WatchWorkoutStartGateTests` 7건, 총 84/84 PASS·0 FAIL·0 SKIP (`build/validation/RST0920A01/stream-io-final2.xcresult`, iPhone 17 Pro Simulator iOS 26.5); `git diff --check` PASS.
- `RSM0920A01`: AppModel restore merge now uses a UUID-to-index table and sorts the unique reading buffer in place; the idempotent route/raw duplicate case and conflicting duplicate rejection both pass 2/2 on iPhone 17 Pro Simulator iOS 26.5 (`build/validation/RST0920A01/apply-restore-index.xcresult`). `git diff --check` PASS; v3 staging and bounded apply remain open.
- Shared UUID-index buffer now also backs monthly archive merge and multi-month restore accumulation, avoiding concatenation and full-value dictionaries; full `SecurityBackupCoreTests` passes 81/81·0 FAIL·0 SKIP (`build/validation/RST0920A01/indexed-payload-buffer.xcresult`, iPhone 17 Pro Simulator iOS 26.5).
- `rawEventPage` snapshot-bound cursor and byte-cap regressions, including inserts/replacements/deletes from another SQLite connection: TaptionPlanCore 81/81 PASS·0 FAIL; `DayStoreV3Tests` 36/36 PASS (`swift test --package-path Packages/TaptionPlanCore`, macOS 27.0).
- 남은 범위: 단일 월 v1/v2 blob의 decrypt/decompress/decode peak, 전체 merge result 메모리 집적, `AppModel.applyCloudBackup`의 preflight·순차 apply/rollback은 미해결이며 temp.md의 v3 chunk/staging 항목을 유지한다. 물리 iPhone·Watch 및 TestFlight는 검증하지 않았다.

## 2026-09-20 WCH0920R01 · Watch lifecycle/purge 코드리뷰 수정

- 독립 리뷰에서 purge가 진행 중인 workout start/stop teardown과 겹쳐 공유 HealthKit session/builder를 동시에 end/discard할 수 있는 경합과, reset 중 도착한 `didFailWithError` callback이 reset 중복 방지로 버려지는 문제를 확인했다.
- purge가 진행 중인 lifecycle 정리가 끝날 때까지 기다리도록 barrier를 추가하고, reset 중 발생한 failure callback은 최종 `errorMessage`로 보존한다. gate 상태 및 barrier waiter 완료 순서를 검증하는 회귀를 추가했다.
- `SecurityBackupCoreTests`+`WatchWorkoutStartGateTests` 통합 회귀 84/84 PASS (`build/validation/WCR0920B01/regression.xcresult`). 실제 페어링 Watch 동작은 미확인이다.

## 2026-09-20 RVA0920R01 · 미사용 review archive wrapper 제거

- `AppModel.reviewArchives(for:asOf:)`는 호출처가 없고 `refreshReviewArchives`가 동일 detached 계산을 직접 수행해 중복 private wrapper만 제거했다.
- review archive/recovery 관련 XCTest 5/5 PASS·0 FAIL·0 SKIP, iPhone 17 Pro iOS 26.5 Simulator: `build/validation/RVA0920R01/review-archive-suite.xcresult`. 테스트 scheme의 iOS·Widget·Watch Debug 대상 컴파일도 완료했고 `git diff --check` PASS.
- 첫 시도는 컴파일 중 `ENOSPC`로 테스트가 시작되지 않았다 (`review-archive.xcresult`). 테스트 코드를 실패로 계산하지 않았으며, 생성된 iOS Simulator 중간 산출물만 제거한 뒤 재시도하여 위 5건이 모두 통과했다.

## 2026-09-20 RAC0920R01 · background review archive 계산 취소

- `sceneEnteredBackground()`가 `postSaveRefreshTask`를 취소해도 해당 task가 기다리는 detached archive refresh는 독립적으로 계속 실행될 수 있었다. stale revision guard가 반영은 차단했지만 CPU 사용은 계산 종료까지 지속될 수 있었다.
- await cancellation을 detached worker에 전달하고, archive 생성 시 입력 기록·다일 span 분배·일/년 경계에서 취소를 확인한다. 취소 시 `CancellationError`로 종료하며 정상 출력·기존 데이터 계약은 그대로다.
- review archive/recovery 및 장기 span 협력 취소 회귀 6/6 PASS·0 FAIL·0 SKIP, iPhone 17 Pro iOS 26.5 Simulator: `build/validation/RAC0920R01/archive-cancellation.xcresult`. 테스트 scheme의 Debug 의존 대상 컴파일 완료, `git diff --check` PASS.
- `SecurityBackupCoreTests` 74/74 PASS·0 FAIL·0 SKIP (`build/validation/WCR0920A01/security-backup-final.xcresult`); generic iOS device Debug build PASS·exit 0 (`build/validation/TST0920A01-cooperative-DD/Build/Products/Debug-iphoneos/TaptionPlan.app`). 물리 iPhone 설치·실데이터 변경·TestFlight 업로드는 하지 않았다.

## 2026-09-20 QCP0920R01 · sensor quality detached cancellation

- `swift test --package-path Packages/TaptionPlanCore`: 65/65 PASS, including cancellation during a 1,024-value scalar pass.
- iPhone 17 Pro iOS 26.5 Simulator `TaptionActivityEngineAdapterTests`: 18/18 PASS, including adapter cancellation propagation; result `build/validation/QCP0920R01/quality-cancellation.xcresult`. The test action compiled the iOS Debug app/test host. `git diff --check` PASS.
- Physical iPhone install/runtime and post-fix OS CPU log were not checked. The synchronous route-filter pass still cannot be interrupted mid-computation.

## 2026-09-20 DCE0920A01 · unused route/timeline cleanup

- `RouteTimelineDataTests` 76/76 PASS·0 FAIL·0 SKIP on `BKU0920A01 Validation iPhone`, iOS 26.5 (`build/validation/DCE0920A01/RouteTimelineData-retry.xcresult`). Generic iOS Debug build PASS·exit 0; built app `build/validation/DCE0920A01/DerivedData/Build/Products/Debug-iphoneos/TaptionPlan.app`.
- First test attempt on `ASC906A001 iPhone` was interrupted before any test case ran: testmanagerd launched the app but the test runner never connected (`waiting for workers to materialize`). It is not counted as a test result; the serial retry on the dedicated Validation iPhone passed.

## 2026-09-20 WCE0920A01 · WatchConnectivity callback actor trap

- iPhone `systemCrashLogs`에서 동기화된 WatchOS 26.6 build 149 보고서 7건(01:27:41, 02:36:20, 02:36:57, 02:37:20, 10:33:05, 11:02:21, 11:18:16 +0900)을 확보했다. 모두 `EXC_BREAKPOINT/SIGTRAP`, 앱 UUID와 build-149 dSYM UUID `9f183f95-a2de-3306-b09f-f77c51112a04` 일치, utility operation queue stack이 `WatchConnectivityController.requestSync()`의 `sendMessage` error callback으로 심볼화된다. 보고서 원본은 `build/validation/WCE0920A01/device-logs/`에 보존했다.
- iPhone에서 최신 동기화 로그 4건(04:38:01, 05:23:40, 05:33:10, 05:48:13 +0900)을 추가 readback했다. 모두 build 149·동일 dSYM UUID·`EXC_BREAKPOINT/SIGTRAP`이며 같은 `requestSync()` error callback frame으로 심볼화되어 수정 전 바이너리에서의 재발임을 확인했다. 현재 checkout은 one-way `sendMessage` error callback을 `nil`로 바꿨지만 이 수정은 build 149에 포함되지 않았다. 직접 확인한 임시 로그 사본은 분석 후 정리했다.
- 9/20 10:51 KST physical iPhone `systemCrashLogs` direct readback found one newer proxied Watch report at 10:33:05. It is WatchOS 26.6 build 149, same app/dSYM UUID, `EXC_BREAKPOINT/SIGTRAP`, utility queue; the exact build-149 dSYM resolves the first app frame to `closure #1 in WatchConnectivityController.requestSync() +120`. The report is preserved at `build/validation/WCE0920A01/device-logs/TaptionPlanWatch-2026-09-20-103305.ips`. This is another pre-fix 149 report, not evidence against the current source fix. The paired devices are visible, but no install or TestFlight action was taken.
- Current direct iPhone readback found two newer proxied Watch reports at 11:02:21 and 11:18:16. Both carry Watch build 149 and the same UUID, `EXC_BREAKPOINT/SIGTRAP`, UTILITY queue, and exact dSYM symbol `closure #1 in WatchConnectivityController.requestSync() +120`. Copies are preserved as `build/validation/WCE0920A01/device-logs/TaptionPlanWatch-2026-09-20-110223.ips` and `...111818.ips`. The iPhone app readback is build 149; the reports themselves are pre-fix Watch build-149 binaries and do not demonstrate a regression in current source. The paired Watch connection could not be established for direct installed-app readback; no install or TestFlight action was taken.
- Fresh physical iPhone app/log re-read in this continuation could not mount the developer disk image because the phone was locked. This attempt provides no newer installed-build or crash-log evidence; the 11:18 readback remains the latest successful one.
- The same iPhone `systemCrashLogs` readback found only one iOS `TaptionPlan` crash dated 9/20 (00:15:55, `0xDEAD10CC`) and no 9/20 `TaptionPlan.cpu_resource` report; the newer reports are Watch crashes proxied through iPhone.
- Same-day physical iPhone `cpu_resource` readback lists only `cloudd` and `knowledgeconstructiond`; no TaptionPlan CPU-resource report was present. This is separate from the five proxied Watch crash reports.
- 해당 callback과 같은 형태의 센서/가속도/Health one-way callbacks를 제거했다. reliable `transferUserInfo`는 유지했다. generic watchOS Simulator Debug build PASS·exit 0 (`build/validation/WCE0920A01/DerivedData`). 수정본 물리 Watch 설치·실행은 아직 하지 않았다.
- `RDC0920A01`: raw restore cancellation checkpoints between decrypt/decompress/decode stages preserve `CancellationError`; the focused cancellation case passes on iPhone 17 Pro Simulator as part of 4/4 (`build/validation/RDC0920A01/watch-sync-tests-r2.xcresult`). The updated Watch summary/outbox suite passes 3/3 (`watch-sync-tests-r4.xcresult`). Generic `TaptionPlanWatch` watchOS Simulator Debug build passed after purge/outbox changes; no physical Watch install, TestFlight upload, or paired-device runtime check was performed.

## 2026-09-20 RIX0920A01 · route segment lookup cost

- Initial interval-index verification: RouteEngine package tests 24/24 PASS, including overlapping interval first-match behavior; generic iOS Debug build PASS·exit 0 (`build/validation/RIX0920A01/DerivedData/Build/Products/Debug-iphoneos/TaptionPlan.app`).
- Follow-up equal-start tie-break: reversed-input regression passes; RouteEngine package Debug tests 25/25 PASS (`swift test --package-path Packages/TaptionRouteEngine`, 2026-09-20 10:12 KST).
- `git diff --check` clean.
- Simulator/package verification only; no physical device install or TestFlight upload.

## 2026-09-20 BKG0920A01 · background raw backup file-lock 종료

- iPhone 14 Pro/iOS 26.6.2의 `TaptionPlan-2026-09-20-001555.ips`: TestFlight build 149, `EXC_CRASH/SIGKILL`, `RUNNINGBOARD/0xDEAD10CC`, 앱 UUID와 dSYM UUID `e97cfbeb-cbdb-36e9-bce0-bcf848553542` 일치. 캡처는 00:15:54 KST, 프로세스 시작은 00:15:22 KST다.
- worker stack은 `SensorVector3`·`DeviceMotionSnapshot`·`SensorReading` decode → `TaptionPlanCanonicalStorage.decode` → `SensorReadingArchive.decodeReadings/loadEvents/readings` → `AppModel.cloudRawSensorPayload/saveCloudBackupOnBackground/sceneEnteredBackground` 순서다. main thread는 UIKit run loop에 idle했고, 따라서 Swift decode 예외가 아니라 background 전환 중 공유 App Group file lock을 놓지 못한 종료로 판정했다. 이전 9/17–9/18 `0x8BADF00D` scene watchdog 및 9/18–9/19 CPU 보고와는 별개의 경로다.
- 수정: `SensorReadingArchive`는 iOS background assertion 안에서 migration과 SQLite event snapshot까지만 잠그고, payload decode를 lock 밖에서 수행한다. repair write는 lock을 다시 얻고 data-deletion generation을 확인한다. 월간 raw backup에서 쓰는 ranged/all-readings 경로 모두 적용했다. 같은 회귀 작업에서 stale memory reprojection은 날짜별 invalidation generation과 DB write-lock commit guard를 추가했고, Watch 수면 시간은 전 구간으로 계산한 뒤 전달용 목록만 2,000개로 제한한다.
- 검증: `SensorDayStoreTests`와 `WatchSensorQueryPlanTests` 76 PASS·0 FAIL·0 SKIP (`build/validation/BKG0920A01-focused-rerun.xcresult`); 최종 generic iOS Debug `CODE_SIGNING_ALLOWED=NO` PASS·exit 0. 이 검증은 Simulator/빌드 증거이며 수정본을 iPhone에 설치하거나 TestFlight에 업로드하지 않았다.

## 2026-09-20 BKU0920A01 · raw backup 복원 무결성 보강

- `BKU0920A01`: 아직 내려받지 않은 iCloud raw 파일의 `accountUnavailable`을 복원까지 전파해 sync/async 경로 모두 snapshot-only 부분 복원을 적용하지 않고 재시도하도록 했다.
- `GEN0920A01`: 같은 달의 커밋된 raw 백업이 있는데 새 generation의 raw 샘플이 비었을 때, 원본 데이터를 새 generation에 보존하고 snapshot/raw ID를 일치시킨다. 스냅샷 저장 실패 롤백을 유지한다.
- `COR0920A01`: raw archive set 일부가 손상·거부·제한 초과로 빠지면 일부 월만 정상 복원한 것으로 표시하지 않는다. 손상 snapshot archive의 기존 허용 동작은 바꾸지 않았다.
- 검증: `SecurityBackupCoreTests` 64 PASS·0 FAIL (`build/validation/BKU0920A01/security-backup-suite.xcresult`), generic iOS Debug build PASS·exit 0. 수정본 물리 iPhone 설치/실행은 하지 않았다.

## 2026-09-20 RAW0920A02 / DID0920A01 / NUL0920A01 / IDN0920A01 · SQLite identity와 raw archive marker

- 이전 snapshot이 없는 달의 snapshot-only 저장도 같은 월·계정의 generationless raw archive를 확인하고 marker를 보존한다. 계정 불일치·잘못된 generation은 저장을 거부한다. 회귀는 raw 단독 저장 → snapshot-only 저장 → 최신 package 복원 순서다.
- `testSnapshotOnlySavePreservesStandaloneRawArchiveWithoutPreviousSnapshot` 회귀는 수정 전 실패, 수정 후 관련 `SecurityBackupCoreTests` 2/2 PASS.
- 새로 발견한 `TaptionPlan-2026-09-20-050854.ips`는 iPhone 앱 충돌이 아니라 Mac `CoreSimulator`의 테스트 프로세스 보고서다. 스택은 `testCommittedRawGenerationSurvivesRestartWithAnOrphanPresent`를 가리켰고, 현재 동일 focused XCTest는 1/1 PASS (`build/validation/BUG1909R01-orphan-retest.xcresult`).
- raw event ID/domain과 insertion receipt의 동등성·hash를 UTF-8 바이트 기준으로 맞췄고, NUL 포함 ID/domain은 append·replace·delete·lookup 전 거부한다. 공개 `Set<String>` 교체 selector는 기존 Swift 동등성 의미를 유지하며, 선택된 도메인의 저장된 NFC/NFD byte spelling을 모두 교체한다.
- 레거시 `DayStore`도 SQLite BINARY ID/domain과 byte-exact `EventIdentifier`, `Event` equality/hash, validation·conditional repair·receipt·lookup/delete를 일치시켰다. V3 static digest는 SQL BINARY ID/domain ordering을 사용한다. NFC/NFD 동시 ID의 저장·receipt·복구·삭제, 동일 ID의 정규형 도메인 충돌, static/SQLite digest 동등성 회귀를 추가했다.
- `swift test --package-path Packages/TaptionPlanCore`: 64/64 PASS·0 FAIL. UTF-8 identity 및 digest-order 회귀 포함; 30일 cold/warm read p95 0.027583/0.017708 ms.
- 변경 후 `TaptionPlan` generic iOS Debug build exit 0; `build/validation/TST0920A01-cooperative-DD/Build/Products/Debug-iphoneos/TaptionPlan.app` bundle version 149, ID `com.taption.plan` readback. 기존 `AVAudioPlayerDelegate` concurrency warning과 exit 0 diagnostic line은 있으나 최종 exit와 산출물을 확인했다.
- 검증은 macOS SwiftPM Debug, focused Simulator XCTest, generic iOS Debug build다. 물리 기기 설치·TestFlight 업로드는 하지 않았다.

## 2026-09-20 CAN0920A01 · 월간 백업 snapshot 직전 취소 경계

- `commitMonthlyArchive`는 snapshot 저장 바로 전에 task 취소, preparation revision, data-deletion generation을 다시 검사한다. raw generation stage 뒤 취소되는 경우 snapshot은 미커밋이고 staged raw generation은 catch 경로에서 삭제되며 성공 시각을 기록하지 않는다.
- 결정적 취소 회귀 1/1 PASS (`build/validation/CAN0920A01/monthly-cancel.xcresult`); 전체 `SecurityBackupCoreTests` 76/76 PASS·0 FAIL·0 SKIP (`build/validation/CAN0920A01/security-backup.xcresult`).
- 시뮬레이터 검증만 수행했으며 기기 설치·TestFlight 업로드는 하지 않았다.

## 2026-09-20 LCK0920A01 / ORD0920A01 · Watch 운동 잠금과 acceleration flush 순서

- `WatchWorkoutStartGate`가 commerce lock 전환 때 generation을 증가시키고 잠금 중 시작/기존 token 수락을 거부한다. `WatchWorkoutManager.applySettings`에서 await 전에 전달하며, authorization·collection·metadata 뒤의 gate 검사로 대기 중 잠긴 workout을 폐기한다. `testCommerceLockDuringAuthorizationWaitRejectsPendingStart` PASS.
- Watch의 acceleration append task는 이전 task 완료 뒤 실행되며 취소된 queued task는 append하지 않는다. iPhone의 Watch archive에 sequence 2 뒤 sequence 1을 기록하고 새 archive 인스턴스로 다시 읽는 `testOutOfOrderWatchAccelerationChunksPersistAndReadBack` 회귀 PASS; 두 sample 모두 보존·순서 정렬을 확인했다.
- `WatchWorkoutStartGateTests` + `SensorDayStoreTests` 70/70 PASS·0 FAIL·0 SKIP (`build/validation/ORD0920A01/final.xcresult`); generic watchOS Simulator Debug build PASS·exit 0 (`build/validation/ORD0920A01/watch-DD`). 물리 Watch 설치·실행은 하지 않았다.

## 2026-09-13 TP0913F001 · TestFlight 149 배포

- 대표님 승인으로 TP0913E001 GPS 공백 전용 예상 경로 수정본을 1.0(149)에 통합했다. 앱·Widget·Watch·Watch Widget 버전 149. 최종 전체 앱 회귀 총 1,114건 중 1,113 PASS·기존 StoreKit 1 SKIP·0 FAIL, generic iOS Debug PASS, 각각 exit 0. 증거는 unit.xcresult·unit.log·debug.log다.
- 증거 폴더: build/validation/TP0913F001. 실제 기기 설치·GPS 공백 표시/재수신 제거·백업과 복귀 안정성은 배포 게이트와 별개다.
- 소스 `c4602ab1dd428ef90f458b02f6c6bec36ace1b8a` main push 완료. Release archive/export PASS·exit 0, 네 번들 1.0(149)·IPA strict/deep codesign PASS. Production iCloud, beta-reports-active=true, get-task-allow=false 확인. 앱/IPA/dSYM UUID `E97CFBEB-CBDB-36E9-BCE0-BCF848553542` 일치. IPA SHA256 `ca81b66b1d143e3e1acef0e1ecd1eba369d5e3b094e0e61046f5d396704e4a70`. 사용 중이 아닌 검증용 압축 해제 복사본만 휴지통으로 옮겼으며 IPA/archive/dSYM은 보존했다.
- Apple 사전 검증·업로드 PASS·exit 0, 2026-09-13 12:35 KST. Delivery UUID `56dd19b2-3aa4-4be2-b38f-35d4ebdfa0c4`. Apple 처리 VALID, 기존 `TP Taption Plan 내부 테스트`에 149 연결/API readback 완료·테스터 1명 확인(asc-internal.log).
- Chrome 그룹 빌드 화면의 `1.0 (149) 테스트 중`, 테스터 탭 1명·그룹 빌드 109개 노출 확인 완료. 설치 표시 버전은 148이므로 149 클라이언트 설치/실제 GPS 공백 표시·재수신 후 제거는 별도 게이트다. 새 테스터·권한·계약·심사·구매 로직 변경은 없다.

## 2026-09-13 TP0913E001 · GPS 공백 전용 예상 경로

- 최종 `build/validation/TP0913E001/unit-final.xcresult`: 총 1,114건, 1,113 PASS·기존 StoreKit 1 SKIP·0 FAIL, 테스트 exit 0. 전체 앱 회귀에 GPS 정상 연속·복수 공백/서로 다른 안정 ID·정차·양 끝 부족·수집 종료(좌표 없는 종료 marker 포함)·확정 이동 중첩·늦은 GPS 유입·날짜 JSON 왕복 ID·WBS 공백 시간·확정 지하철 보존을 포함했다.
- 첫 `unit.xcresult`는 이전 전체 지하철 예상 경로를 기대한 테스트와 희소 GPS fixture에서 실패했다. 기존 테스트의 잘못된 배열 인덱스 접근으로 테스트 프로세스도 종료됐으며 앱 실기기 충돌 증거가 아니다. 새 계약에 맞게 fixture/검증을 갱신한 최종 전체 실행은 실패 0건이다.
- 실제 GPS/백업 원본은 변경하지 않았다. 최종 generic iOS Debug PASS·exit 0(`debug.log`). 이 수정의 TestFlight 업로드·실기기 표시 검증은 하지 않았다. 배포된 148과 이번 로컬 변경을 구분한다.

## 2026-09-13 TP0913D001 · 통합 후보 148

- 네 번들 `1.0 (148)`: 금요일 원본 재조회와 백업 날짜 직렬화 동등성 수정을 통합했다. 최초 `unit.xcresult`와 진단 이벤트 포함 최종 `unit-final.xcresult` 모두 총 1,106건 중 1,105 PASS·기존 StoreKit 1 SKIP·0 FAIL, exit 0. 최종 generic iOS Debug도 PASS·exit 0이다. 증거는 `build/validation/TP0913D001/unit-final.log`, `debug.log`다.
- 새 로그 `TaptionLogs-20260913-005952.txt`에서 147 raw 포함 자동 백업 17:26:37Z와 수동 17:26:52Z/17:27:03Z의 invalidArchive 실패 종료를 확인했다. 증거 사본은 `build/validation/TP0913D001/diagnostics-before.txt`다. 아래 C002의 종료 로그 미확인 상태를 이 결과로 갱신한다.
- `testConsecutiveFullRawBackupsAcceptEquivalentPersistedDates`는 날짜 JSON 왕복의 약 0.000000119초 차이를 재현하고, 같은 원본으로 연속 full-raw 월별 백업·복원이 되는지 검증한다. 실제 충돌 거부 테스트도 유지했다. 실제 기기 오류가 이 경로였는지는 아직 미확정이며, 원본/백업·키/PIN은 보존했다.
- TestFlight 배포 게이트는 완료했다. 실제 148 설치 후 금요일 경로·iCloud 백업/복원 확인은 별도 실기기 게이트다.
- 소스 `03365a4eb6396f93f4854e79d48f4445b62585c3` main push 후 Release archive/export PASS·exit 0. IPA 네 번들 모두 1.0(148), strict/deep codesign PASS, Production iCloud·beta-reports-active=true·get-task-allow=false 확인. 앱/IPA/dSYM UUID `231C20D4-0678-3AF2-BE58-C42D8D0A3505` 일치. IPA SHA256 `0499a411e1f2ac17c0ecfe3c53d85df19a0a0a2444eaacab7b26854f32300b9d`. 사용 중이 아닌 검증용 압축 해제 복사본만 휴지통으로 옮겼으며 IPA·archive·dSYM·테스트 증거는 보존했다.
- Apple 사전 검증과 업로드 PASS·exit 0. Delivery UUID `eb429725-dd18-4a40-a21e-123cac2fbcf0`, 2026-09-13 03:41 KST. Apple 처리 `VALID`, `TP Taption Plan 내부 테스트` API build 148 연결/readback 및 테스터 1명 확인 완료. `validate.log`·`upload.log`·`asc-internal.log`에 기록했다.
- Chrome의 실제 그룹 빌드 화면에서 `1.0 (148)`·`테스트 중`, 테스터 탭에서 내부 테스터 1명·전체 빌드 108개를 확인했다. 테스터의 설치 표시 버전은 여전히 147이며 148 실기기 설치 증거가 아니다. 이전 147 웹 빈 화면 게이트도 해소됐다. 현재 iPhone/iPad/Watch는 devicectl unavailable, 실제 백업/복원·금요일 표시·장시간 복귀 검증은 남아 있다.

## 2026-09-13 TP0913C001 · 금요일 기록 누락

- 사용자 iCloud `TaptionLogs-20260913-002628.txt`는 build 147이다. 9/11 원본 GPS 1,687건 조회(17:06:18Z)와 지도 materialization 57건 재사용(17:23/17:26Z)이 동시에 확인됐다. 증거 사본은 `build/validation/TP0913C001/diagnostics-before.txt`, SHA256 `e53ca3ab65a82d819d00feafbe302963cde6deaa50d6f99007cd0477812f2a2c`.
- 지도 날짜 직접 대입의 선택일 갱신 누락을 공통 날짜 observer로 수정했다. 캐시 preview 이후 primary 센서 원본을 재조회하며, 조회 중 source가 바뀌면 원본 캐시를 재사용해 최신 분류로 재투영한다. 센서 재분류는 원본 조회와 분리하고 원본/백업 파일과 UI 배치는 보존했다.
- `focused.xcresult`: 55 PASS·0 FAIL·0 SKIP. 최종 `final.xcresult`: 56 PASS·0 FAIL·0 SKIP, 실행 exit 0. 선택일 직접 대입·빠른 연속 날짜 변경·같은 날/백그라운드 무갱신 4건, AppModel 원본 갱신 1건, 재투영 시 원본/최신 분류 보존 1건, SensorDayStoreTests 50건(별도 primary 저장소 진전/오래된 materialization 회귀 포함).
- 최종 Debug generic iOS PASS·exit 0(`debug-final.log`). 재투영은 비동기 재조회 반복 대신 화면 반영 직전 동기 1회로 수행한다. 현재 소스는 147 배포 후 변경본이며 이 수정의 TestFlight 배포·금요일 실제 화면 복구는 아직 미확인이다. 기기는 unavailable이어서 설치/터치 검증으로 계산하지 않는다.

## 2026-09-13 TP0913C002 · 백업 오류 확인 대기

- 새 로그의 수동 백업은 17:26:25Z 시작했고 17:26:28Z에 로그가 전송되어 해당 종료 이벤트가 없다. 구버전 15:35:12Z invalid=2/valid=0을 현재 오류 원인으로 확정하지 않는다. 147 자동 snapshot 백업은 17:14:41Z 성공했다.
- 읽기 전용 점검에서 snapshot 백업 2개 JSON·파일명/monthKey·크기·ciphertext digest는 정상이다. 실제 GCM 복호화는 키/PIN 없이 검증하지 않았다. 새 실패 로그가 필요하며 백업 소스와 원본 파일은 변경하지 않았다.

## 2026-09-13 TP0913B001 · 통합 후보 검증

- 작업 후보는 앱·Widget·Watch·Watch Widget `1.0 (147)`이다. 최종 앱 회귀는 총 1,098건 중 1,097 PASS·기존 StoreKit 1 SKIP·0 FAIL, `unit-final.xcresult` summary `Passed`로 확인했다. 취소된 로컬 편집 보존·동시 편집·백그라운드 보고서 미실행·preview 무쓰기/삭제 fence·PIN/백업 변경 중 async 커밋 거부·삭제 후 백업 재생성 방지를 포함한다.
- 패키지 회귀: Core 54, Activity 14, Route 20, umbrella PlanEngine 1 — 총 89 PASS·0 FAIL·0 SKIP, 실행 종료 코드 0. 증거: `build/validation/TP0913B001/package-*.log`.
- 첫 앱 전체 실행은 XCTest 1,067건(1,065 PASS·1 기존 StoreKit SKIP·1 새 테스트 기대값 실패), Swift Testing 27 PASS였다. 실패는 동일 source의 유효 DB 캐시를 재사용하는 정상 경로에 sensor 재호출 1회를 기대한 테스트이며, preview가 strict cache를 seed하지 않는 직접 검증으로 수정했다. 최초 iOS 다운로드 상태 API 컴파일 실패도 수정했다. 이 실행은 최종 PASS로 계산하지 않는다.
- 1차 측정: 65,853 synthetic history의 메모리 preview 30회 p95 0.010ms; 30일×1,440 readings 정상 일자 로드 cold p95 24.984ms, warm 0.094ms. 캐시/API 측정이며 실제 화면 frame·실기기 resume p95가 아니다. 운영 로그의 중단 포함 수분 경과와 직접 배수 비교하지 않는다.
- 최종 동일 측정: memory preview p95 0.005ms, cold 28.821ms, warm 0.092ms. 증거 `unit-final.log`이며 자동 성능 회귀 threshold도 통과했다.
- generic iOS Debug build PASS(`debug-device.log`). Simulator 147 launch PID `18064` → 지도 9/13에서 9/12로 날짜 전환 → 메뉴 하단 `Taption Plan 1.0 (빌드 147)` → 설정/데이터 보호 `iCloud 로그 업로드`·`로그 업로드` 표시를 AX로 확인했다. 홈으로 background 전환 후 동일 PID `18064`로 복귀해 지도 화면·9/12 상태를 다시 확인했고 오류 팝업은 없었다. 1회 Simulator 확인이며 실기기 30회 검증이나 실제 iCloud 전송 성공을 뜻하지 않는다.
- 소스 `4631c77` main push, Release archive/export PASS. 네 번들 모두 `1.0 (147)`, exported IPA deep/strict codesign PASS·Production iCloud·beta-reports-active=true·get-task-allow=false. IPA SHA256 `d52d266f16b362d7a0a7a2a9a25606c0f52266d9407312d5b3e1e9f61f36f46a`, 앱/dSYM UUID 일치 `6B86AFEC-5D80-3298-B77B-5DE50B4FE8F0`. archive·Export·로그는 `build/validation/TP0913B001`에 보존한다.
- iPhone·iPad·Watch는 `devicectl`에서 unavailable. 최신 OS crash/dSYM 대조, TestFlight 클라이언트 147 설치 provenance·launch, 화면 켜기/복귀 30회 및 30분 사용, 날짜 이동·저장/대분류 편집, 새 로그 업로드 후 오류/지연 readback은 미확인이다.
- 캘린더 계정 교체/재허용·반복 일정, Watch 원본 실수신, 지도 두 손가락 조작·VoiceOver/발열·PIN 기반 실제 iCloud 복원은 기존 요청 ID의 실기기 게이트를 최신 후보로 통합한다. 판매 계약·첫 IAP 연결/심사·유료화는 이번 승인 범위에서 제외한다.
- Chrome은 초기 로그인 실패 이후 team/Plan 그룹 URL까지 이동했지만 새로고침·직접 재진입에도 AX 본문과 실제 화면이 비어 있다. 확장 탭 접근도 `Debugger unattached`로 실패해 native Chrome으로 재확인했다. API와 별도로 그룹 빌드·테스터 웹 화면 readback이 남아 있으므로 릴리스 완료로 보고하지 않는다.
- `altool --validate-app` 및 업로드 exit 0, Delivery UUID `43f84236-1f6b-4ba3-9923-5c70ce4fd148`. Apple 처리 `VALID`·`expired=false`, `TP Taption Plan 내부 테스트` API 연결 후 build 147 readback `groupBuildVerified=true`, 테스터 1명 `INSTALLED` 확인. 이는 147 클라이언트 설치 증거가 아니다. `validate.log`/`upload.log`/`internal-readback.log` 보존.
- 정리: 활성 사용이 없음을 `lsof`·프로세스로 확인한 이전 기본 Plan DerivedData의 `Build/Intermediates.noindex` 1.3GB와 `Index.noindex` 150MB만 삭제했다. 재빌드 가능한 캐시이며 Logs/TestResults/Products·현재 후보·다른 프로젝트·사용자 백업·휴지통은 보존했다.
- 서명 검증용 IPA 압축 해제 사본 104MB도 `lsof` 확인 후 삭제했다. 원본 IPA·archive·dSYM·검증 로그는 보존해 재생성할 수 있다.

## 2026-09-11 TP0911B002 · CancellationError 저장 오류 통합 수정 및 TestFlight build 146

- 새 화면의 `센서 기록을 저장하지 못했습니다`와 TP0911A001의 활동 저장 팝업을 함께 수정했다. iCloud에서 사용자가 올린 `TaptionLogs-20260911-105220.txt`(build 145)를 readback했고, 저장 취소가 `local_persistence_failed`로 기록된 원인을 확인했다. `local_persistence_failed` 4건은 모두 `CancellationError`였다.
- 활동 저장 readback·공통 저장·센서 snapshot 저장의 `CancellationError`는 사용자 오류로 표시하지 않고, 실제 저장소 오류만 기존 안내·로그로 남긴다. 소스 커밋 `6fd7326`.
- 회귀 XCTest 2/2 PASS·0 FAIL·0 SKIP, generic iOS Debug build PASS, Release archive/export·deep/strict 서명·Production iCloud entitlement PASS. 네 번들 `1.0 (146)`, IPA SHA-256 `6ae9d0761372eacffb4ca11cb0955b29e70c5bc031979aa773cfb195703583b6`.
- `altool --validate-app`·업로드 PASS. Delivery UUID `fca81e99-261d-42c7-8bd8-4bed334e6429`, App Store Connect `VALID`·`expired=false`. `TP Taption Plan 내부 테스트`에 연결 후 API에서 build 146과 내부 테스터 1명(`INSTALLED`)을 readback했다.
- Chrome 그룹 URL은 `Unauthenticated`여서 브라우저 UI build/tester 노출은 미확인이다. 테스터 `INSTALLED`는 146의 TestFlight 설치·launch 증거가 아니다. 수정 전 build 145의 최신 `TaptionLogs-20260911-105220.txt`는 readback했으며, 수정 후 build 146 TestFlight 클라이언트 설치·launch·터치와 새 로그 readback은 별도 실기기 게이트다.

## 2026-09-10 TP0910A004 · iCloud 진단 오류·지연 수정 및 TestFlight build 145

- 최신 Plan 진단 readback에서 `previous_session_unfinished` 반복 기록, 부분 iCloud 백업/복구 가능한 legacy reading의 오류 등급, 공유 SQLite와 map cache 대기 지연을 분리해 확인하고 수정했다. map cache는 별도 SQLite로 분리했으며 기존 백업·정본 데이터는 보존했다.
- 관련 XCTest 108/108 PASS·0 FAIL·0 SKIP, Debug build PASS, Release archive/export 및 `altool --validate-app` PASS. 네 번들 `1.0 (145)`, Delivery UUID `a5a3ba33-8252-4fbb-b7c4-0104d59b7c57`, App Store Connect `VALID`·`APP_STORE_ELIGIBLE`이다.
- `TP Taption Plan 내부 테스트` 연결 후 API에서 build 145와 내부 테스터 1명(`INSTALLED`)을 readback했다. Chrome 그룹·테스터 화면은 App Store Connect 로그인 화면으로 전환되어 UI readback은 미완료다.
- 실제 TestFlight 클라이언트 145 설치·launch·터치 및 설정 `로그 보내기` 후 iCloud `TaptionLogs` readback은 실기기 게이트로 남긴다.

## 2026-09-09 CRH909A001 · 크래시 진단 및 로그 전송

- iPhone 14 Pro crash report readback: build 140, `EXC_CRASH/SIGKILL`, `RUNNINGBOARD/0xDEAD10CC`, 2026-09-08 15:02:01. 현재 build 142 신규 crash report는 없음. 원본 `/tmp/CRH909A001/TaptionPlan-2026-09-08-150201.ips`.
- DiagnosticsLogSupportTests 10/10 PASS. generic Debug build PASS. Apple Development Debug `1.0 (144)` 설치·launch readback PASS. Release build 144 `제출 준비 완료`, Internal 그룹 연결 및 그룹 빌드 144/테스터 화면 노출 PASS. 테스터 설치 표시는 142다.
- 설정 `로그 보내기`를 실제로 눌러 iCloud Drive `TaptionLogs` 파일 생성·Watch 로그 수신·비정상 종료 marker 반영을 확인하는 실기기 게이트가 남아 있다.

## 2026-09-08 REV908A001 · 코드리뷰 게이트

- 저장·백업, 지도·활동, Watch·Live Activity, 릴리스 경계 리뷰에서 snapshot 크기 제한·좌표 단일 소스·활동명 fallback을 수정했다. v1 outer metadata/PIN 변경 migration은 별도 복원 게이트다.
- 자동 테스트·Debug·Release·TestFlight 처리·Internal 그룹/API/UI·실기기 설치/실행은 서로 분리해 기록한다. build 143 실기기 설치·터치·발열·Watch 수신은 배포 후 확인한다.

## 2026-09-08 BAK908A001 · 구형 백업 호환 회귀

- 실제 iCloud 파일 3건을 읽기 전용 복사했고 모두 version 1·ciphertext SHA256/digest 일치: `/tmp/BAK908A001.pgwpKC`.
- version 1은 구형 AES-GCM 추가 인증 데이터 없음 경로로 읽고, version 2 AAD 검증은 유지한다. SecurityBackupCoreTests 55/55 PASS·0 SKIP·0 FAIL, iOS Debug generic build PASS.
- PIN 입력이 필요한 실제 복호화·복원·TestFlight 기기 화면은 아직 미확인이다. 원본 백업은 삭제·덮어쓰지 않았다.
- build 142 TestFlight archive/export·검증·업로드·처리 `VALID`·Internal API 연결 및 테스터 1명 readback PASS. Delivery `ded15358-7e3b-4360-917a-7c264accfe48`. Chrome 새로고침 후 페이지 AX가 비어 그룹 UI의 142 노출은 미확인이다.

## 2026-09-08 INT908A001 · build 141 검증

- 소스 `e170ba3`: 전체 1,077 PASS·1 기존 StoreKit SKIP·0 FAIL, 후속 집중 71/71 PASS, 앱·Widget·Watch Debug device build PASS. `/tmp/INT908A001.Cn2d4V`.
- Release archive/export·서명·altool 검증/업로드 exit 0. 141 `VALID`·Internal 그룹 API 연결/141 readback·Chrome 그룹의 `1.0 (141)` ‘테스트 중’ 및 테스터 1명 화면 노출 PASS. UUID `4a600796-ed30-4c23-9749-d4fb3b0af819`. 테스터 화면은 기존 140 설치를 표시하므로 141 설치/launch는 미확인이다.
- SET908A001·DYN908A001·SEC906P001·LOG908B001의 코드 변경 및 자동 검증 완료. iPhone/Watch 현재 unavailable이라 새 버전 설치·실행·실제 다이나믹 아일랜드는 아직 미확인이다.
- TestFlight 후 확인: 업무↔이동 활동 아이콘/문구, 과거 날짜를 열어도 현재 활동 유지, 데이터 보호·초기화/GPS 메뉴 유지, 집/졸라맨 겹침·pinch, 반복 launch/background와 로그 저장.
- Watch/HealthKit/캘린더: 실제 페어링 전송·토큰 소비 후 중복 무실행, Apple/Taption 운동 유지·외부 운동 자동 판정 제외·원본 보존, 계정 교체·권한 재허용·이동 반복 일정. iPad/TestFlight 실행과 장시간 발열·전력은 별도 게이트다.
- BAK907A001 사용자 iCloud 백업 실패 원인은 미확정. 기존 파일을 보존하고 재현 동작/진단 로그를 요청했다. 백업 성공으로 보고하지 않는다.

## 2026-09-08 WAK908C001 · 졸라맨 전용 표시층

- 최종 iPhone Debug build·서명·설치·`builtByDeveloper=true`·launch PID `12968`를 확인했다: `/tmp/WAK908C001/final-device-build.log`, `install.json`, `apps.json`, `launch.json`.

- 기존 WAK908B001은 사용자 실화면에서 집과의 앞뒤 전환이 재발했다. 졸라맨을 지도 native annotation 정렬에서 분리했다.
- 동일 좌표 집 선택·3단계 줌에서도 졸라맨이 지도의 직접 subview 최상단에 남고 발끝 좌표가 일치하는 회귀 및 기존 계층 회귀 3/3 PASS·0 SKIP·0 FAIL: `/tmp/WAK908C001/final-tests.xcresult`.
- 이 회귀는 UIKit 계층과 좌표 검증이며 실제 사용자 화면의 장시간 겹침/드래그 렌더 확인과 구분한다.

## 2026-09-08 WAK908B001 · 졸라맨 지도 마커 최상단

- iPhone Debug build·서명·설치·`1.0 (140)`·`builtByDeveloper=true`·launch PID `12802` 확인: `/tmp/WAK908B001/device-build.log`, `install.json`, `apps.json`, `launch.json`.

- Apple 마커 우선순위와 지도/검색 UI 계층 회귀 2/2 PASS·0 SKIP·0 FAIL, Simulator Debug build: `/tmp/WAK908B001/tests.xcresult`.
- 실제 겹친 장소·메모 마커 선택 및 줌 조작 중 졸라맨 표시 확인은 물리 화면 검증으로 남긴다.

## 2026-09-08 CAN908A001 · 위치 기록 취소 팝업

- iPhone Debug build·서명·설치·`builtByDeveloper=true`·launch PID `12388` 확인: `/tmp/CAN908A001/device-build.log`, `install.json`, `apps.json`, `launch.json`. 실제 사용자 화면 재확인과 TestFlight 배포는 별도다.

- 취소된 센서 읽기는 기존 오류 상태를 덮어쓰지 않고 false로 종료한다. 실제 archive 경로가 파일에 막힌 경우에는 기존 읽기 오류 알림이 표시된다.
- 관련 Simulator 회귀 2/2 PASS·0 SKIP·0 FAIL, exit 0 및 Debug build: `/tmp/CAN908A001/tests.xcresult`.

## 2026-09-08 LOG908A001 · 아이폰 저장 중 종료 수정

- 최종 SQLitePlanRepositoryTests는 18/18 PASS·0 SKIP·0 FAIL, exit 0: `/tmp/LOG908A001/repository-r2.xcresult`. 설치·백그라운드·복귀 후 crash 목록의 최신 보고서는 수정 전 13:40 기록 그대로다: `/tmp/LOG908A001/crashes-after.json`.

- 원본: TestFlight build 140, 10:38·13:40 `0xDEAD10CC`; `/tmp/LOG908A001/morning.ips`, `/tmp/LOG908A001/latest.ips`.
- DayStore 회귀 19/19 PASS·0 SKIP: `/tmp/LOG908A001/package-tests-r3.log`. 트랜잭션 시작을 두 번째 SQLite 연결로 확인한 뒤 취소하여 `SQLITE_INTERRUPT`, 원상 복구, 재저장을 검증했다.
- iPhone Debug build·서명 검증·설치·`1.0 (140)`·`builtByDeveloper=true`·launch PID `12262` 확인: `/tmp/LOG908A001/device-build.log`, `install.json`, `apps-after.json`, `launch.json`. 설정 앱으로 전환한 뒤 약 1분 후 동일 PID로 복귀했다: `background-settings.json`, `resume.json`, `processes.json`.
- 첫 Simulator XCTest는 testmanagerd 연결 대기 중 중단했으며 테스트 통과로 계산하지 않는다. 장시간 저장·잠금·반복 백그라운드와 TestFlight 설치는 별도 검증이다.

## 2026-09-07 CRH907A001 백그라운드 충돌·지도 CPU 완화

- build 140 충돌 stack과 일치하도록 대용량 payload 인코딩을 파일 lock 밖으로 이동했고, `MapHomeView` 초기화 중 시간 레일 전체 계산을 기존 비동기 refresh로 넘겼다.
- SQLite 저장소·기능 엔진·시간축 회귀 727건 중 726 PASS·1 SKIP·0 FAIL 및 Simulator Debug build를 통과했다: `/Users/u_mo_c/Library/Developer/Xcode/DerivedData/TaptionPlan-gvqtjbpzkfvutrdlxdzhdyhsyane/Logs/Test/Test-TaptionPlan-2026.09.07_21-39-52-+0900.xcresult`.
- TestFlight build 140 자체는 수정 전 바이너리다. 수정본의 반복 launch·백그라운드 전환·진단 로그 및 SQLite 저장은 새 빌드에서 별도 확인한다.

## 2026-09-07 LOG907B001 iPhone 컨테이너·충돌 로그 수집

- Wi-Fi 연결된 iPhone 14 Pro에서 TestFlight `Taption Plan 1.0 (140)` 앱 컨테이너 240MB와 앱 그룹 컨테이너를 읽기 전용으로 수집했다: `/tmp/LOG907B001`.
- 17:32:15·17:33:08 충돌은 모두 `SIGKILL`·`RUNNINGBOARD`·`0xDEAD10CC`였고, 19:42·19:48·20:26에는 CPU resource 진단이 연속 기록됐다.
- build 140 dSYM으로 CPU stack을 symbolicate해 `AppShellView`→`MapHomeView`→`MapHomeTimeRailSegmentEngine.makeSegments` 반복 평가와 `AppModel.startSensorAnalysis` 경로를 확인했다. 수정·재빌드는 아직 수행하지 않았다.

## 2026-09-07 ICO907A001 정적 활동 전용 아이콘

- 업무·식사·수업·취미는 졸라맨 없이 각각 모니터 글자, 그릇·포크·스푼, 책장, 음표 애니메이션을 사용한다.
- 공통 마커·좌표 anchor·Reduce Motion 계약을 유지했고 지도 마커 회귀 37/37 PASS, 기능 회귀 557 PASS·1 SKIP·0 FAIL 및 Simulator Debug build를 통과했다.
- 실제 지도에서 네 상태의 모양·움직임과 줌인·아웃 좌표 고정 확인은 물리 iPhone 게이트다.

## 2026-09-07 WAK907A001 졸라맨 좌표 표시

- Apple 지도와 Vector 지도의 졸라맨 발끝 anchor를 동일한 경로 좌표로 통일했다.
- anchor 회귀 1/1과 Simulator Debug build가 통과했다: `/tmp/WAK907A001-tests-r2.xcresult`.
- TestFlight에서 같은 시각을 유지한 채 줌인·아웃했을 때 발끝이 동일 경로 좌표에 남는지 실제 터치 확인은 별도 게이트다.

## 2026-09-07 IAP907B001 구매 비활성화·TestFlight build 140

- 구매 정책 OFF에서 만료 기록도 접근 허용, 상품 미로드, 직접 구매·복원 무호출을 집중 XCTest 2/2로 확인했다: `/tmp/IAP907B001-tests-r2.xcresult`.
- Release archive/export·배포 서명·TestFlight entitlement·`altool --validate-app` 통과, 네 번들 `1.0 (140)`, IPA SHA-256 `ebf0161b10decb17765eda07f2dea6d3b304320ab79fea57cf103c14bdbf5147`: `/private/tmp/IAP907B001.jpbHS0`.
- Delivery/build UUID `c871d1f4-e933-411d-b840-0d59af3ba6be`는 `COMPLETE`·`VALID`·미만료이며 Internal 그룹 build 140과 테스터 1명 `INSTALLED`를 API readback했다.
- TestFlight 앱에서 build 140 설치·launch·구매 UI 비노출·만료 상태의 전체 기능 접근은 물리 게이트다.

## 2026-09-07 TFB907A001 TestFlight build 139

- 개발자 체험 초기화 집중 XCTest 1/1과 Simulator Release build가 통과했고, Release 바이너리에는 Debug 초기화 경로가 없다: `/tmp/TRY907A001-tests-r2.xcresult`, `/tmp/TRY907A001-release-dd`.
- 네 번들 `1.0 (139)` Release archive/export·배포 서명·TestFlight entitlement·`altool --validate-app`을 통과했다. IPA SHA-256은 `65c95869f99112813f4d5f0fed5be638fab7e53b822da4a131567188113ddde5`다: `/private/tmp/TFB907A001.j36e1d`.
- Delivery/build UUID `23d0de21-0047-40f1-b681-30bbfb8d26ca`는 `VALID`·미만료이며 내부 그룹 관계에서 build 139와 테스터 1명 `INSTALLED`를 API readback했다.
- Chrome 세션 인증 만료로 그룹 빌드·테스터 화면 확인은 미완료다. TestFlight 앱의 build 139 설치·샌드박스 Pro 구매·launch·실제 기능 테스트도 물리 게이트다.

## 2026-09-06 DEV906I001 iPhone 설치

- 최신 `main@7a490e9` Apple Development Debug를 deep/strict codesign 후 iPhone 14 Pro에 설치했다.
- `com.taption.plan 1.0 (138)`·`builtByDeveloper=true`·launch PID `16713`을 readback했다: `/private/tmp/DEV906I001-install.json`, `/private/tmp/DEV906I001-apps.json`, `/private/tmp/DEV906I001-launch.json`.
- 실제 등록 장소 축소 화면 터치와 TestFlight 클라이언트는 별도 게이트다.

## 2026-09-06 PIN906A001 등록 장소 좌표 표시

- Apple·Vector 지도 등록 장소 카드의 하단 anchor를 제거하고 아이콘 중심을 저장 좌표에 일치시켰다.
- anchor·현재 위치 회귀 2/2와 Simulator Debug build·설치·launch PID `17961`이 통과했다: `/private/tmp/PIN906A001-focused-r2.xcresult`.
- 실제 축소 화면의 손가락 확인은 물리 iPhone 게이트다.

## 2026-09-06 LOC906F001 현재 위치 이중 포커싱

- 캐시 좌표 선이동과 새 GPS 후속 이동을 제거하고, 새 표본 저장 뒤 한 번만 포커싱하도록 수정했다.
- 위치 갱신 게이트 회귀 1/1과 Simulator Debug build·설치·launch PID `13086`이 통과했다: `/private/tmp/LOC906F001-focused-r3.xcresult`.
- 실제 손가락 탭과 GPS 이동은 물리 iPhone 게이트다.

## 2026-09-06 SUB906R001 00:17 지하철 오탐

- 00:17 당시 설치본은 build 137이며, 동일 날짜 진단은 철도·역·대중교통·후보·노선 0인데 지하철 1건과 잠금 5건을 기록했다.
- 역 인접만으로 상대고도 하강 점수를 주지 않도록 수정했다. 관련 Simulator XCTest 4/4, Debug build, 설치·launch PID `5406`이 통과했다: `/private/tmp/SUB906R001-focused-r4.xcresult`.
- 최신 Apple Development Debug `1.0 (138)`의 iPhone build·설치·`builtByDeveloper=true`·launch PID `16511`을 readback했다: `/private/tmp/SUB906R001-device-install.json`, `/private/tmp/SUB906R001-device-apps.json`, `/private/tmp/SUB906R001-device-launch.json`. 실제 자동차 이동 재현은 미완료다.

## 2026-09-06 NXT906P002 졸라맨 중앙 포커싱

- 현재 위치 목표점 x를 전체 viewport 중앙으로 통일하고 검색창 아래 y 여백은 유지했다. 수학 회귀 1/1과 camera command·버튼 상태 회귀 2/2가 실패·스킵 없이 통과했다: `/private/tmp/NXT906P002-focused.xcresult`, `/private/tmp/NXT906P002-camera-command-r2.xcresult`.
- 최종 소스의 Simulator Debug build가 통과했다. 물리 iPhone은 `unavailable`이라 실제 손가락 현재 위치 버튼·TestFlight 화면 중앙 정렬은 별도 게이트다.

# 2026-09-06 SUB906F001 지하철 오탐 수정·TestFlight build 138

- iCloud 로그에서 `reading_rail_match_count=0`, `reading_station_name_count=0`, `reading_transit_match_count=0`, `candidate_count=0`인데 `subway_segment_count=1`이 남아 미확정 잠금 보존을 원인으로 확정했다: `/private/tmp/DAY906L001-current-iphone.jsonl`.
- Apple Watch 출처·신뢰도 조건을 지하철 행동 보조 근거에 적용하고, 노선 없는 미확정 잠금은 새 이동 결과로 재평가했다. 지하철 집중 18/18, `TaptionActivityEngineAdapterTests` 16/16, Swift Package 회귀가 통과했다.
- Release archive/export·`altool --validate-app` 통과, 네 번들 `1.0 (138)`, IPA SHA-256 `9fa557d536c6002294abf2a3435c54f0c8742df533577f69d411f467eb9a36f7`: `/private/tmp/SUB906F001-release`.
- TestFlight 업로드 Delivery UUID `9caa4563-2a99-4b1a-ab58-c5b4a74b663c`; API readback에서 build 138 `VALID`·`APP_STORE_ELIGIBLE`·`expired=false`, 내부 그룹 build 99개 중 build 138과 내부 테스터 1명(`INSTALLED`)을 확인했다.
- build 138 TestFlight 설치·실행 및 실제 사용자 기록 재검증은 물리 게이트다.

## 2026-09-06 PAY906Q001 데이터·지도 집중 검증

- iPhone 14 Pro(iOS 26.6.1)에서 raw 복원 실패 원자성, Watch 원본 보존, 캘린더 계정·반복 일정 병합, 지도 cache·pinch 재중심화 회귀 11/11을 실패·스킵 없이 통과했다: `/private/tmp/PAY906Q001-focused-r1.xcresult`.
- 날씨 rail 간격과 pinch 유지 추가 회귀는 iPhone 17 Pro iOS 26.5 Simulator에서 2/2 통과했다: `/private/tmp/PAY906Q001-weather-r2.xcresult`.
- 같은 Watch summary/chunk identity의 동일 재전송은 no-op, 다른 payload는 거부하는 원본 불변 회귀 2/2를 통과했다: `/private/tmp/PAY906Q001-focused-r4.XPUojy/focused-r2.xcresult`.
- 최신 전체 XCTest·Swift Testing은 1,050건 중 1,049 passed·1 skipped·0 failed다: `/private/tmp/PAY906Q001-latest-analyze/full.xcresult`. skip은 iOS 26.5 Simulator의 기존 `SKInternalErrorDomain Code=3` StoreKitTest 시스템 오류다. 최신 iOS static analyzer도 analyzer 경고·오류 0이며 Xcode StoreKitTest SDK 헤더 폐기 경고 1건만 보고했다: `/private/tmp/PAY906Q001-latest-analyze/analyze.xcresult`.
- 30일 날짜 조회 cold/warm p95는 `25.605708ms`/`0.009167ms`, legacy 100건 복구는 `46.960084ms`, inline legacy 2,346건은 `118.320083ms`다.
- XCTest 산출물이 없는 일반 시뮬레이터 앱을 설치·launch하고 동일 1206×2622 전후 화면에서 레이아웃·날씨 라벨·현재 위치 버튼을 함께 비교했다: `/private/tmp/PAY906Q001-design-audit-final/02-before-after.png`.
- 메모 메뉴의 수정 전후를 동일 1206×2622 상태로 결합 비교해 `note.text`·금색 계열 통일과 레이아웃 유지가 보였다: `/private/tmp/PAY906Q001-design-audit-r2/11-before-after-memo.png`. Vector 임시 마커 anchor와 44/48pt hit target, Apple annotation 언어별 접근성 라벨은 코드·빌드로 확인했지만 실데이터 마커와 VoiceOver 낭독은 별도 물리 게이트다.
- 최신 일반 Debug `1.0 (137)`은 테스트 번들 없이 deep/strict codesign 후 iPhone 설치·developer app 버전 readback·launch PID `14539`를 통과했다: `/private/tmp/PAY906Q001-style-iphone-r1.k3QEtD`. 위치 버튼 회귀는 iPhone 17 Pro iOS 26.5 Simulator에서 1/1 통과했다: `/private/tmp/PAY906Q001-style-simtest-r1.3FJtFo/focused.xcresult`.
- 현재 launch의 앱 진단 파일은 생성되지 않아 새 runtime 로그 readback은 확보하지 못했다. 실제 두 손가락 pinch·장시간 발열/배터리·Watch/캘린더 실계정 수신·대중교통 경로 화면은 별도 물리 게이트다.
- snapshot 저장 실패 뒤 새 raw만 되돌리는 복원·Watch 회귀 7/7, 사용자가 선택한 캘린더가 새 live 캘린더 때문에 확대되지 않는 회귀 2/2, pending viewport 중복 재중심화를 막는 카메라 회귀 4/4와 TaptionPlanCore 52/52를 통과했다: `/private/tmp/RAWAUD9061-focused/cloud-regression.xcresult`, `/private/tmp/RAWAUD9061-focused/calendar-regression.xcresult`, `/private/tmp/RAWAUD9061-focused/map-camera-regression.xcresult`, `/private/tmp/RAWAUD9061-focused/map-current-location-regression.xcresult`.
- 최신 일반 Debug `1.0 (137)`은 테스트 번들 0개·deep/strict codesign 후 iPhone 설치·developer app 버전 readback·launch PID `14718`을 통과했다. Debug dylib SHA-256은 `c6fb740fbd97837e99e48905fe2490da4a2f2f1aa602b9745ee9d2ce813cadf2`다: `/private/tmp/PAY906Q001-iphone-final-r5/evidence.md`.

## 2026-09-06 RTE906C001 반복 날짜 로드 회귀

- 지도 화면의 60초 전체 날짜 재조회와 같은 날 소스 변경에 따른 task 재시작을 제거했다. task key 집중 회귀 1/1, generic Simulator Debug와 iPhone Debug build가 통과했다: `/private/tmp/RTE906C001-focused.xcresult`.
- iPhone 14 Pro(iOS 26.6.1)에 개발자 서명 `1.0 (137)`을 설치하고 버전·launch·프로세스 PID `15114`를 readback했다. Debug dylib SHA-256은 `4b9b38e2a70842f1768b66497be61cbb0d910b46b5b48a0334aefa6308da465c`다: `/private/tmp/RTE906C001-device-evidence.md`.
- 설치·실행은 통과했지만 실제 손가락 날짜 전환 지연과 60초 이후 로그 횟수는 별도 실기기 사용 게이트다.

## 2026-09-06 SLP906C001 iPhone 수면 fallback 회귀

- strict 수면 결과가 없을 때만 `PhoneSleepFallbackEngine`을 연결하고, 화면 원본이 비거나 백그라운드 표본 간격이 긴 iPhone 기록을 보완하도록 수정했다. HealthKit·Watch 수면과 겹치는 후보는 기존 차단 규칙을 유지한다.
- TaptionActivityEngine 14/14와 앱 타깃 집중 회귀 2/2(수면 fallback·날짜 task)를 실패·스킵 없이 통과했다: `/private/tmp/SLP906C001-focused-r2.xcresult`.

## 2026-09-06 DAT906L001 날짜 데이터 재조회 지연

- 실기기 로그에서 날짜 로드 `snapshot_wait_ms` 4~9초의 대부분이 `sensor_ms` 5~8초였고, source fingerprint 변경만으로 raw 센서 아카이브 전체를 다시 읽는 경로가 원인이었다: `/private/tmp/DAY906L001-current-iphone.jsonl`.
- raw digest가 유효한 메모리·materialized day readings를 재사용해 현재 source만 재투영하고, raw 불일치·불완전 때만 센서 전체 조회로 fallback한다. 재사용 경로는 `reprojected_memory_raw`·`reprojected_database_raw` 로그로 구분한다.
- source 변경·강제 재로드 회귀 2/2, 30일 cold/warm 날짜 조회 성능 1/1, 실패·스킵 0이다. p95는 `33.542666ms`/`0.04725ms`다: `/private/tmp/DAT906L001-tests-r2.xcresult`, `/private/tmp/DAT906L001-p95.xcresult`.

## 2026-09-06 SEC906D001·SEC906K001·SEC906R001·SEC906C001·SEC906W001 백업·입력 경계 회귀

- 백업 파일·CloudKit payload 크기 제한, PIN 실패 상태 영속화, AAD 메타데이터 인증, 문서 복구 키 기기 이전, Watch/HealthKit route·배열 상한과 confirmation token 검증을 반영했다.
- 보안 회귀 3/3와 Watch query 22/22, 총 25/25·실패 0·스킵 0 및 Simulator Debug build가 통과했다: `/private/tmp/SEC906-final-derived/Logs/Test/Test-TaptionPlan-2026.09.06_14-12-59-+0900.xcresult`.
- iPhone 14 Pro에 최신 수정본을 서명 빌드·설치·launch하고 `com.taption.plan 1.0 (137)` readback까지 확인했다: `/private/tmp/DATE906-final-device-build-r2.log`, `/private/tmp/DATE906-final-install-r2.json`, `/private/tmp/DATE906-final-launch-r2.json`. Watch 원본 수신과 일반 Watch command capability는 별도 게이트로 남긴다.

## 2026-09-06 SEC906P002 HealthKit 자동 추정 source 경계

- HealthKit raw import/provenance는 보존하면서 자동 연속 추정은 Apple Health/Taption source bundle allowlist로 제한했다. 사용자 입력 기록은 별도 명시적 기록으로 유지한다.
- 다른 앱 source의 연속 심박값이 자동 actual을 만들지 않는 회귀를 포함해 `HealthKitIntegrationTests` 21/21 통과, 실패·스킵 0이다: `/private/tmp/SEC906P002-health-derived/Logs/Test/Test-TaptionPlan-2026.09.06_14-46-36-+0900.xcresult`.

## 2026-09-06 BKP906C001 자동 백업 재시도 회귀

- 최근 성공 또는 iCloud 계정 불가 실패 뒤 1시간 동안 포그라운드 자동 백업을 건너뛰고, 경계 시각부터 다시 허용하는 회귀 1/1을 통과했다: `/private/tmp/BKP906C001-focused.xcresult`.
- 수동·00:00 백업 경로는 변경하지 않았고 암호화·무결성·복원 회귀 50/50, 실패·스킵 0을 확인했다: `/private/tmp/BKP906C001-security.xcresult`.

## 2026-09-06 ASC906R001 판매 상태 readback

- API readback에서 앱 버전 `1.0`은 `PREPARE_FOR_SUBMISSION`, build `137`은 `VALID`·미만료이고 Internal 그룹 build 관계에 포함됐다. 그룹 테스터는 1명이며 review submission은 0건이다.
- Pro 상품은 `READY_TO_SUBMIT`, 미국 `USD 9.99`, 175개 지역, 현지화 2건과 심사 이미지 `COMPLETE`다. 버전 한국어 메타데이터와 iPhone 6.7형 스크린샷 2장도 존재·`COMPLETE`다: `/private/tmp/ASC906R001-live.r2SanN`.
- 심사 연락처·version submission·앱 판매 지역 resource·첫 IAP 연결과 API 밖의 Paid Apps Agreement 확인은 남은 외부 게이트다.

## 2026-09-06 DIG906C001 중복 raw 캐시 회귀

- 같은 raw를 다시 append해도 신규 receipt 0건·digest 메모리 캐시 1건 유지·digest 불변임을 집중 회귀 1/1로 확인했다. TaptionPlanCore 전체 52/52도 실패·스킵 없이 통과했다: `/private/tmp/DIG906C001-core-r3.log`, `/private/tmp/DIG906C001-core-full-r1.log`.
- iOS·Widget·Watch·Watch Widget을 포함한 generic iOS Debug build가 통과했다: `/private/tmp/DIG906C001-ios-device-build-r1.log`. 최초 dual-architecture Simulator build는 코드 오류가 아닌 디스크 부족으로 중단됐고, 이번에 생성한 DerivedData와 사용되지 않던 Taption Plan DerivedData만 정리한 뒤 device build로 재검증했다.

## 2026-09-06 MAT906C001 중복 Watch 날짜 캐시 회귀

- 변경 없는 Watch 요약·가속도 재전송 뒤에도 materialized day가 남고 raw event count가 각 저장소 1건으로 유지되는 집중 회귀 2/2를 통과했다: `/private/tmp/MAT906C001-focused.xcresult`.
- `SensorDayStoreTests` 전체 41/41, 실패·스킵 0이며 30일 날짜 조회 성능 회귀와 Debug 앱·Widget·Watch 빌드도 통과했다: `/private/tmp/MAT906C001-store-suite.xcresult`.
- iPhone 14 Pro에는 deep/strict codesign을 통과한 일반 Debug `1.0 (137)` 설치와 developer app 버전 readback까지 완료했다. 기기가 잠겨 launch는 iOS에서 거부됐으며 실제 날짜 전환 체감과 함께 잠금 해제 뒤 확인한다: `/private/tmp/MAT906C001-iphone-install.json`, `/private/tmp/MAT906C001-iphone-launch.log`.

## 2026-09-06 DAY906L001 날짜 로딩 성능

- iPhone 14 Pro(iOS 26.6.1)에서 legacy/envelope 복구, migration, 불완전 projection, 캐시 무효화·축출과 30일 성능 집중 XCTest 12/12를 실패·스킵 없이 통과했다: `/private/tmp/DAY906L001-iphone-tests-r14.xcresult`.
- 실기기에서 최대 `78,239ms`였던 센서 조회는 pre-canonical JSON 2,346건의 반복 외부 복구와 실패한 migration 재시도가 원인이었다. SQLite `REAL` 시각의 1 ULP 왕복 차이 회귀를 포함해 수정했고 migration `25일`·iPhone `153,480건`·Watch `910건` 완료를 로그로 readback했다: `/private/tmp/DAY906L001-fixed-iphone-r6.jsonl`.
- 실기기 30일 cold/warm p95는 `39.534583ms`/`0.010958ms`, migration 이후 후속 지도 날짜 로드는 `277~577ms`, snapshot은 `179~443ms`다. TaptionPlanCore 51/51도 통과했다: `/private/tmp/DAY906L001-core-tests-r2.log`.
- XCTest 주입물을 제거한 일반 Apple Development Debug `1.0 (137)`을 다시 빌드·deep/strict codesign·설치·launch하고 앱 PID `14347`을 readback했다: `/private/tmp/DAY906L001-iphone-build-r9.log`. 실제 손가락 체감은 별도 물리 게이트다.
- 정본 snapshot 전 stale 지도 캐시 게시 차단, raw 일자 revision 재조회, 복원 부분쓰기 방지와 60/30Hz 카메라 projection 회귀 8/8을 실패·스킵 없이 통과했다: `/private/tmp/DAY906L001-followup-r3.ZyrSYM/focused.xcresult`.
- 최신 일반 Debug `1.0 (137)`은 테스트 번들 0개·deep/strict codesign·iPhone 설치·developer app 버전 readback·launch PID `14486`을 통과했다. Debug dylib SHA-256은 `58e2719718ff44e3e1770709710a7219ac0579a77e71926939c55f8f89337726`이며 증적은 `/private/tmp/DAY906L001-iphone-followup.zeZ8iP`다.
- 최신 실기기 로그 4,040건은 일자 snapshot 204회 중 DB cache 1회·재생성 109회, 지도 cache 거부 89회(`source_revision_mismatch` 69회·`source_updated_at_mismatch` 20회)를 보였다. 지도 날짜 로드 p95는 `1,845ms`였다: `/private/tmp/DAY906L001-live-log-r1/attachments/ED73066A-9479-4D4D-96A6-CC04E4238F71.json`.
- 전역 실행 revision 대신 해당 날짜 내용 fingerprint와 raw digest를 사용하도록 수정한 뒤 iPhone 날짜 저장·migration·cache·Watch 회귀 42/42와 기존 payload 호환 Simulator 회귀 8/8을 실패·스킵 없이 통과했다. 30일 cold/warm p95는 `38.536208ms`/`0.052541ms`다: `/private/tmp/DAY906L001-regression-r3/regression.xcresult`, `/private/tmp/DAY906L001-compat-r7/compat.xcresult`.
- 테스트 번들 없는 최신 Debug `1.0 (137)`을 deep/strict codesign·설치하고 developer app 버전 readback·launch PID `14690`을 확인했다. Debug dylib SHA-256은 `fe4b7a8a561e87f38e1aa7201bfd7b86f4ae8941345c43ba41828f25557abe2d`이며 증적은 `/private/tmp/DAY906L001-iphone-final2.9Jm4eN`이다. 실제 날짜 전환 손가락 체감은 별도 물리 게이트다.

## 2026-09-06 IAP905G002 StoreKit 실기기 회귀

- iPhone 14 Pro(iOS 26.6.1) 최초 실행에서 상품 조회·검증 구매 결과는 성공했지만 구매 직후 entitlement가 아직 반영되지 않아 1/1 실패했고, 검증 거래 완료가 UI 잠금 해제보다 앞선 결함을 확인했다: `/private/tmp/IAP905G002-iphone.ebJ0XY/storekit.log`.
- 구매 상태를 먼저 적용한 뒤 거래를 완료하고, 이미 current entitlement가 있으면 인증 없이 복원하도록 수정했다.
- 수정본 StoreKit 집중 1/1과 상거래 잠금·14일 체험·시계 역행·상품형·철회·구매·외부 구매 인식·복원 10/10이 실패·스킵 0으로 통과했다: `/private/tmp/IAP905G002-iphone-r2.S0jnmI/storekit.xcresult`, `/private/tmp/IAP905G002-commerce-r3.8ddFUJ/commerce.xcresult`.
- 최신 전체 소스의 iPhone clean Debug build·설치·launch와 앱 `1.0 (137)`, PID `13950` readback까지 통과했다: `/private/tmp/IAP905G002-iphone-build-r4.log`.
- entitlement가 실제로 누락된 계정의 강제 `AppStore.sync()`는 시스템 계정 인증이 필요한 별도 수동 게이트다.

## 2026-09-06 DEV903V001 iPhone·Watch 실기기 확인

- iPhone 14 Pro(iOS 26.6.1)에 최신 Apple Development Debug `1.0 (137)`을 빌드·설치·launch했고 앱 프로세스 PID `13362`와 버전을 readback했다. 빌드·서명 증적은 `/private/tmp/DEV903V001-iphone-settings-r1.log`이며 Debug dylib SHA-256은 `7bd3355fa7bcebfa9c47d087d072fb882563e2f8c75d23e192583a67b184ec06`이다.
- 교체 전 설치돼 있던 `1.0 (137)`도 launch했지만 설치 provenance를 TestFlight로 확정하지 않았으므로, 최신 개발자 설치와 TestFlight 클라이언트 설치를 같은 PASS로 합치지 않는다.
- 실제 iPhone에서 날짜 ±1일·±7일 이동, 지도 +/-와 한 손가락 pan, 권한 완료 상태에서 온보딩 비노출을 확인했다. 직전 동일 지도·핀치 코드의 물리 iPhone 집중 XCTest는 3/3 통과·실패/스킵 0이다: `/private/tmp/DEV903V001-iphone-focused-r1.xcresult`.
- Watch 자동 가져오기·가속도 수집·모든 권한 승인은 비활성 레거시 설정에만 있어 접근 불가였고, 현재 지도 설정에 기존 `SettingsView` 진입점 하나를 연결했다. 변경 소스의 iPhone 빌드·설치·launch는 통과했지만 iPhone Mirroring 자동 클릭이 원격 화면에 전달되지 않아 새 버튼과 실제 두 손가락 pinch는 물리 터치 미확인이다.
- Apple Watch SE에는 Debug `1.0 (137)`을 설치했고 iPhone의 최근 Watch 접촉 시각 갱신을 확인했다. Watch 앱 launch는 `Navigation away from clock is not allowed due to one or more active system states`로 거부돼 화면·센서 실수신·수면 반영은 미확인이다.
- `xctrace` Time Profiler는 연결된 iPhone을 인식했지만 boot 대기 timeout으로 trace를 만들지 못했다. 장시간 발열·배터리와 TestFlight build 137 클라이언트 provenance/launch는 계속 별도 게이트다.

## 2026-09-06 ALG904A001 전체 기록 경로 회귀

- Swift Package는 TaptionActivityEngine 14/14, TaptionRouteEngine 20/20, TaptionPlanCore 51/51, TaptionPlanEngine 1/1—총 86/86 통과했다.
- Watch 원본 제한 재시도·HealthKit 수면 delta·손상 센서 cache·POI 삭제 fence 등 집중 XCTest 7/7 통과: `/private/tmp/ALG904A001-app-r3.9gBYjO/focused.xcresult`.
- 전체 XCTest·Swift Testing은 1,031건 중 1,030 passed·1 skipped·0 failed다: `/private/tmp/ALG904A001-full-r2.ByyHu3/full.xcresult`. skip은 iOS 26.5 Simulator의 기존 StoreKit 시스템 오류다.
- 전체 회귀가 검출한 대중교통 예상경로 누락은 근거가 있는 버스·지하철·열차·선박에 저속 endpoint 예외를 적용한 뒤 집중 1/1과 전체 회귀로 재검증했다: `/private/tmp/ALG904A001-route-r1.T6fuAE/route.xcresult`.
- generic iOS·watchOS Debug와 iOS static analyze는 모두 exit 0이다: `/private/tmp/ALG904A001-build-r1.TPiSR6`. 앱 30일 load p95는 cold `32.998416ms`, warm `0.006625ms`다.
- 최신 iPhone Simulator 앱 설치·launch PID `73497`을 readback했고 안정화 뒤 5회 CPU `0.0%`, RSS `187,920~187,984KiB`였다. 이는 실기기 장시간 발열·배터리 검증이 아니다.
- 보안 diff scan은 17/17 변경 파일을 검토하고 malformed timestamp, Watch raw replay, 삭제 후 POI 게시 후보를 수정·검증해 최종 보고 대상 0건으로 완료했다: `/private/var/folders/q1/0p9tcvnx7yx5l12y55zm4tdm0000gn/T/codex-security-scans-jOiTAE/taption-plan/af7352832651ca69d5863cff8dc36b0c8d2dbdc0_20260905T162732Z_ehr2iwgg/report.md`.

## 2026-09-06 ASC906A001 App Store 판매 초안 readback

- App Store version `1.0`과 build 137의 exact ID 관계, `VALID`·미만료·`APP_STORE_ELIGIBLE`·비면제 암호화 사용 `false`를 API로 확인했다.
- 공개 개인정보처리방침·지원 문서 HTTP 200과 한국어 설명·키워드·부제·지원/개인정보/개인정보 선택 URL·저작권·생활/건강 및 피트니스 카테고리·제3자 콘텐츠 선언의 저장값을 재조회했다.
- 연령등급 전 문항을 채웠고 175개 지역 결과는 9+ 172개·한국 전체이용가 1개·10+ 1개·12+ 1개다.
- 앱 버전은 계속 `PREPARE_FOR_SUBMISSION`이고 review submission은 0개다. 개인정보 없는 iPhone 6.7형 스크린샷 2장의 asset `COMPLETE`와 세트 2건을 API로 확인했다. 심사 연락처·판매 지역·앱 개인정보 수집 답변·Paid Apps Agreement·DSA/비규제 의료기기 선언·첫 IAP 웹 추가는 미완료다.
- 증적: `/private/tmp/IAP905G002-api.3i778W`, `/private/tmp/ASC906A001-screenshot.sGrWXW`.

## 2026-09-05 BAK905I001 실제 iCloud 백업 복호화

- iCloud의 8·9월 snapshot·raw 파일을 실제 32바이트 계정 복구 키로 AES-GCM key unwrap·payload decrypt하고 LZFSE·JSON v1·월/generation 쌍까지 검증했다: `/private/tmp/BAK905I001-live.5vfwUn/live-backup-readback.log`.
- 8월은 route 2,516건, raw reading 15,369건·envelope 12,876건이며 9월은 route 2,728건, raw reading 7,403건·envelope 19,132건이다. 네 payload 모두 무결성·복호화·압축 해제가 정상이다.
- 좌표·건강값·복구 키는 출력하지 않았고 일회성 검증기 소스·바이너리는 삭제했다. 앱 UI에서 복원 적용·merge한 뒤 데이터 readback하는 단계는 실기기 미완료다.

## 2026-09-05 BAK905H010·REL905H011 raw 실패 롤백·TestFlight build 137

- 월간 raw 저장 뒤 snapshot 커밋이 실패할 때 직전 정상 raw가 덮어써지던 결함을 수정했다. 병합 중 이미 읽은 archive를 되돌리며, 이전 파일이 없으면 미커밋 raw만 삭제한다.
- 집중 회귀 1/1, `SecurityBackupCoreTests` 50/50, 앱 전체 1,027건 중 1,026 passed·1 skipped·0 failed다: `/private/tmp/BAK905H010-focused.K2HmMB/focused.xcresult`, `/private/tmp/BAK905H010-focused.K2HmMB/security-suite.xcresult`, `/private/tmp/BAK905H010-focused.K2HmMB/full.xcresult`. skip은 iOS 26.5 Simulator의 기존 StoreKit 시스템 오류다.
- 배포 소스 `a6e770f64491e97896136a1b7692620bf6c0c62b`에서 앱·iOS Widget·Watch 앱·Watch Widget을 모두 `1.0 (137)`로 archive/export했다. archive·IPA deep/strict codesign, privacy manifest 5개, Apple Distribution, `beta-reports-active=true`, iCloud `Production`, `get-task-allow=false`와 Apple 서버 사전 검증을 통과했다.
- archive는 `/private/tmp/REL905H011-release.nFPbOf/TaptionPlan-1.0-137.xcarchive`, IPA는 `/private/tmp/REL905H011-release.nFPbOf/Export/TaptionPlan.ipa`, SHA-256은 `18e5516b30726c1ba7862907062c7421ef743fff7f12165bf0e40f0b0a07d405`다.
- Delivery/build UUID `1b26a479-4bd6-49df-bda2-2f1bf1f0d28a`는 `VALID`·미만료·`APP_STORE_ELIGIBLE`이다. `TP Taption Plan 내부 테스트` 추가 후 build 137 포함·그룹 빌드 98개·내부 테스터 1명 `INSTALLED`를 API readback했다.
- TestFlight 클라이언트 build 137 설치·launch·실제 백업 복원·터치·장시간 발열/배터리는 별도 미완료 게이트다.

## 2026-09-05 BAK905H008·REL905H009 raw 복원·TestFlight build 136

- raw를 생략한 포그라운드 스냅샷 저장이 새 generation ID로 월간 파일을 덮어써 기존 raw 백업을 복원 대상에서 제외할 수 있던 결함을 수정했다. 같은 달의 기존 generation ID를 보존하고 포그라운드 경로는 스냅샷 저장 API를 사용한다.
- 원본 백업 연속성 집중 회귀 1/1, `SecurityBackupCoreTests` 50/50, 앱 전체 1,027건 중 1,026 passed·1 skipped·0 failed다: `/private/tmp/BAK905H008-focused.b6Zr0b/result.xcresult`, `/private/tmp/BAK905H008-focused.b6Zr0b/security-suite.xcresult`, `/private/tmp/BAK905H008-focused.b6Zr0b/full.xcresult`. skip은 iOS 26.5 Simulator의 기존 StoreKit 시스템 오류다.
- 실제 iCloud의 `2026-09.taptionbackup`과 `2026-09.rawsensorbackup`은 JSON v1, 암호화 payload·PIN/account wrapped key 포함, 저장 digest와 암호문 SHA-256 일치를 확인했다. 실기기 PIN 복호화·복원 적용은 확인하지 않았다.
- 배포 소스 `f76af5a9dd23e880f00c9d3b5cf2b6b173efe83b`에서 네 번들을 `1.0 (136)`으로 archive/export했다. archive·IPA deep/strict codesign과 네 privacy manifest, 배포 IPA의 Apple Distribution·`beta-reports-active=true`·iCloud `Production`·`get-task-allow=false`를 확인했다.
- IPA SHA-256은 `32486649b566c61a3270ee0424e8d99a50a4c176c3200ea9f0edb1c24c639b86`; Delivery/build UUID는 `85cabd56-8654-4124-b660-9e8793fe4853`이며 `VALID`·미만료·`APP_STORE_ELIGIBLE`이다.
- `TP Taption Plan 내부 테스트`에 build 136을 추가했고 API readback에서 build 136 `VALID`, 그룹 빌드 97개, 내부 테스터 1명을 확인했다.
- TestFlight 클라이언트 build 136 설치·launch·실제 백업 복원·터치·장시간 발열/배터리는 별도 미완료 게이트다.

## 2026-09-05 REL905H007 TestFlight build 135

- 배포 소스 `1ca699e5f0da06c18dd453b31c688c5b38405a31`에서 앱·iOS Widget·Watch 앱·Watch Widget을 모두 `1.0 (135)`로 archive/export했다.
- 전체 앱 테스트는 1,027건 중 1,026 passed·1 skipped·0 failed, 집중 회귀 6/6, 성능 회귀 4/4이며 iOS·watchOS Debug와 앱 정적 분석을 통과했다. skip 1건은 iOS 26.5 Simulator의 `SKInternalErrorDomain Code 3` StoreKit 시스템 결함이다.
- archive와 IPA의 deep/strict codesign, 네 번들의 privacy manifest를 확인했다. 배포 IPA는 Apple Distribution, `beta-reports-active=true`, iCloud `Production`, `get-task-allow=false`; SHA-256은 `f2f5ef3b106fb37c480b1e365888fe66844c4c111c0d06b990b9c7bc110807e3`이다.
- App Store Connect 업로드에 성공했다: Delivery/build UUID `365a5ef7-dfda-447f-8b4c-3c807f1ef37e`, `BUILD-STATUS: VALID`, `IMPORT-STATUS: VALID`, `APP_STORE_ELIGIBLE`, `PROCESSINGSTATE: VALID`, `expired=false`.
- `TP Taption Plan 내부 테스트`에 build 135를 추가했고 API readback에서 build 135 `VALID`·미만료, 그룹 빌드 96개, 내부 테스터 1명을 확인했다.
- TestFlight 클라이언트의 build 135 실기기 설치·launch·실제 화면/터치·장시간 발열/배터리는 별도 미완료 게이트다.

## 2026-09-05 DEV905H006 iPad 최신 소스 설치

- iPad Pro 12.9-inch 6세대(iPadOS 26.6.1, 유선 연결, 개발자 모드)에 최신 dirty 소스의 iOS 실기기 앱·XCTest 번들을 Apple Development로 서명해 `build-for-testing`했다: `/private/tmp/DEV905H006-ipad.wmSSIl/build-for-testing.log`.
- 앱과 내장 Watch·Widget 서명 검증 후 `com.taption.plan` 1.0(134)을 설치했고 기기 앱 목록에서 같은 버전을 readback했다.
- 설치 후 실행은 `FBSOpenApplicationErrorDomain Code 7 / Locked`로 거부됐다: `/private/tmp/DEV905H006-ipad.wmSSIl/launch.log`. 잠금 해제 전에는 첫 화면·StoreKit 실거래 XCTest·터치 판정을 통과로 처리하지 않는다.
- 설치 뒤 재생성 가능한 이 프로젝트 전용 DerivedData는 제거했고 테스트·설치 로그는 보존했다.

## 2026-09-05 REL905H005 판매 상태 API 재검증

- App Store Connect API에서 Taption Plan 앱과 TestFlight 1.0(134) `VALID`·미만료, `TP Taption Plan 내부 테스트` 연결, 내부 테스터 1명을 다시 확인했다.
- `com.taption.plan.pro`는 비소모성 `READY_TO_SUBMIT`; 한국어·영어 현지화, 미국 기준 `USD 9.99`, 한국·미국 포함 175개 지역, 새 지역 자동 추가, 1206×2622 심사 이미지 `COMPLETE`, 상품 버전 1 `PREPARE_FOR_SUBMISSION`이다.
- 현재 API 키는 앱 버전 조회를 403으로 거부하고 계약 목록은 공개 API 경로가 없어, Paid Apps Agreement와 앱 버전 상품 연결은 App Store Connect 브라우저 재인증 게이트로 유지한다.

## 2026-09-05 OPT905H004 다방면 코드 리뷰·후속 최적화

- 지도 시각·지도/데이터 런타임·상거래/Watch 경계를 세 갈래로 검토했으며 P0는 없고 확인된 P1을 모두 최소 수정했다.
- 불완전 일자 projection은 저장·메모리 캐시하지 않아 다음 조회에서 복구하며, 원본 revision 변경으로 중단된 legacy migration은 최신 revision으로 다시 예약한다.
- 날짜 전환 시 3일 전체 공급자 강제 조회를 제거하고 선택 일자와 overnight 수면 구간만 증분 조회한다. 지도 로드 key에도 projection revision을 포함해 stale 화면을 막았다.
- 실제 경로의 선택 opacity를 두 지도 렌더러에 보존하고 MapKit은 변경된 polyline만 교체한다. gesture 시작 시 최신 pinch·pan recognizer를 연결하고 native 현재위치 점은 숨겨 같은 좌표의 졸라맨 하나만 표시한다. 집 마커도 기존 평면 SF Symbol 체계로 통일했다.
- 유료 권한 확인 전 iPhone 데이터 변경을 차단하고 Watch payload에 잠금 상태를 전달해 가속도·건강 동기화·위치·운동을 중단한다. 구형 Watch payload는 선택 필드로 계속 decode한다.
- 신규 집중 회귀 6/6과 성능·경로 회귀 4/4가 통과했다: `/private/tmp/PRD904A001-p1-focus-r3.cIOcqn/result.xcresult`, `/private/tmp/PRD904A001-p1-perf.ErbfPz/result.xcresult`. 앱 30일 load p95는 cold `33.154708ms`, warm `0.007334ms`다.
- 최신 전체 검증은 총 1,027건 중 1,026 통과·실패 0·스킵 1이다: `/private/tmp/OPT905H004-full.9nXS8G/result.xcresult`. 스킵은 iOS 26.5 Simulator의 기존 StoreKit `SKInternalErrorDomain Code 3`에만 한정된다.
- Watch 단독 Debug build와 전체 앱 정적 분석도 exit 0이며, iPhone·Watch 실제 센서 수신과 장시간 발열·배터리·pinch는 `DEV903V001` 실기기 게이트로 유지한다.

## 2026-09-05 ALG905H003 전체 알고리즘·성능·배터리 리뷰

- 센서·HealthKit·Watch·행동·지하철·경로·캘린더·iCloud 백업을 병렬 검토하고 확인된 정확도·성능 결함을 최소 수정했다.
- GPS 정밀도 기준과 지하철 연속 관측 조건을 수집·복원 경로에 동일 적용했고, 조밀한 지하철 후보 생성은 인접 최단 경로를 한 번만 계산하도록 바꿨다. HealthKit 무변경 foreground 조회 간격은 15분으로 늘렸다.
- 예상 경로는 실제 정밀 경로가 완성되면 도착 시각 이후에도 제거하고 stale 생성 경로를 재사용하지 않는다. 재생 WBS leg는 분 단위 색인으로 조회하며 정확한 분 경계와 DST 23·25시간을 회귀 검증했다.
- 캘린더 부분 응답은 선택·기존 일정을 보존하고 최신 날짜 요청만 100ms debounce 후 재조회한다. iCloud 월별 raw→snapshot 저장에 같은 generation ID를 부여하고 같은 세대만 복원하며 손상 파일은 파일 단위로 격리한다.
- Watch ambient drain은 요약마다 전체 가속도 배열을 재필터링하던 경로를 순차 커서 O(N+M)로 바꾸고, 가속도 청크·요약을 SQLite 한 번에 저장한다. 운동 중 표본 수 UI 갱신은 25Hz에서 1Hz로 줄였으며 행동 창이 전진할 때만 보존 배열을 정리한다.
- 집중 회귀는 센서·지하철 6/6(`/private/tmp/SHE905H001-r2.sSQPZB/result.xcresult`, 96역 조밀 경로 0.831초)과 시간·백업 경계 3/3(`/private/tmp/EDGE905H001-r5.ByXdTJ/result.xcresult`) 통과했다.
- Swift Package 회귀는 Core 50/50, Activity 12/12, Route 18/18, PlanEngine 1/1로 총 81/81 통과했다.
- 최종 전체 XCTest는 1,024 통과·0 실패·1 건너뜀, 총 1,025건이다: `/private/tmp/ALG905H003-final.UCNk7Q/result.xcresult`. 건너뜀 1건은 iOS 26.5 Simulator의 기존 `SKInternalErrorDomain Code 3` StoreKit 시스템 결함이다.
- generic iOS Simulator Debug build, Swift parse, `git diff --check`, 단일 아키텍처 Xcode 정적 분석이 모두 통과했다. iPhone·Watch 장시간 발열·배터리와 실제 HealthKit·Watch 수신은 `DEV903V001` 실기기 게이트로 유지한다.

## 2026-09-05 TRK905H001 자동 추적 세션 복원

- 자동 감지 수집기는 걷기·달리기를 `walking`·`running`으로 저장하지만 AppModel은 `automatic` 종류만 자동 세션으로 재구성해, 재시작 뒤 자동 종료가 빠지고 고정밀 센서가 계속 실행될 수 있었다.
- `SensorReading` 원본에 선택형 자동 감지 여부를 저장하고 이를 복원에 우선 사용했다. 구형 원본은 기존 `automatic` 규칙으로 읽으며 수동 걷기는 수동으로 유지한다.
- 자동 걷기·수동 걷기·구형 자동 세션 집중 XCTest 1/1 통과, 실패·스킵 0: `/private/tmp/TRK905H001.yGj1cw/result.xcresult`. Swift parse와 `git diff --check`도 통과했다.

## 2026-09-05 WCM905H001 Watch 명령 시각 검증

- Watch 센서·건강 payload와 달리 일정 명령에는 수신 시각 상한이 없어, 크게 틀어진 Watch 시계가 미래의 실행·완료·연기 기록을 만들 수 있는 누락을 확인했다.
- 기존 5분 clock-skew 정책을 명령 decode 직후와 중복 ID 저장 전에 적용했다. 지연 도착한 과거 명령은 그대로 허용하고 5분을 넘는 미래 명령만 거부한다.
- `WatchDeletionPayloadTests` 10/10 통과, 실패·스킵 0: `/private/tmp/WCM905H001.ShgOVY/result.xcresult`. Swift parse와 `git diff --check`도 통과했다.
- 현재 CoreDevice readback은 iPad 연결, iPhone·Apple Watch unavailable이다. iOS 26.6.1 iPad StoreKit 실기기 XCTest는 빌드·서명 뒤 기기 잠금으로 실행 직전 중단했으며, 실제 Watch 명령 송수신도 기존 실기기 게이트로 유지한다.

## 2026-09-05 ALG904A001·CAC905H001·EXP905H001·WDI905H001·SEN905H001 추가 리뷰

- 변경 60개 소스·테스트 파일을 저장소·센서/HealthKit/Watch·지도/경로/UI 세 영역으로 병렬 검토했다. 보안 diff scan은 coverage `complete`, 보고 대상 취약점 0건으로 완료됐다: `/private/var/folders/q1/0p9tcvnx7yx5l12y55zm4tdm0000gn/T/codex-security-scans-kQTEid/taption-plan/9684e36b705bb0acfdea29298a04397951e403e8_20260905T092546Z_mfy6cpty/report.md`.
- 성능·배터리 보정은 raw digest 캐시를 64일 LRU로 제한하고, 센서 분석을 날짜별 pending·최대 120초 묶음으로 합치며 자정 경계 시작·종료일을 모두 처리한다. DB 읽기 실패 날짜는 제거하지 않고 동일 cadence로 재시도한다.
- Watch 삭제는 성공 generation을 Watch 로컬에 보존하고 실시간·보장 전송의 중복 요청을 직렬화했다. 삭제 후 재생되는 과거 명령, 저장 중 삭제 fence, 미래시각 건강·가속도·행동·확인 payload와 내부 수면·표본·경로를 차단하거나 경계에서 절단한다.
- 구형 Watch 수면 합계는 삭제 경계 뒤 구간 근거가 없으면 제거하고, 수신 허용 상한을 걸친 수면 구간은 유효 부분만 남겨 재계산한다. Watch 최종 요약과 가속도 청크는 자정을 넘으면 양일 분석을 직접 예약한다.
- 개인 기록 내보내기는 앱 전용 임시 폴더의 이전 파일을 지우고 공유 종료 시 현재 파일도 삭제하며, 전체 기록·위치 포함 범위와 파일명을 실제 payload에 맞췄다.
- TaptionPlanCore 50/50과 내보내기 집중 회귀를 통과했다. 최신 Watch 삭제·미래시각·수면 9건, 다중 날짜 분석·DB 실패 재시도 2건은 공용 빌드 락 안에서 11/11 통과했고 iOS 앱·embedded Watch Debug 산출물을 함께 빌드했다: `/Users/u_mo_c/Library/Developer/Xcode/DerivedData/TaptionPlan-gvqtjbpzkfvutrdlxdzhdyhsyane/Logs/Test/Test-TaptionPlan-2026.09.05_19-49-25-+0900.xcresult`.
- Swift parse와 `git diff --check`를 통과했다. 실물 Watch 삭제·센서 수신·수면 반영, iPhone 장시간 발열/배터리와 지도 두 손가락 pinch는 자동 검증 범위 밖이라 기존 실기기 게이트로 유지한다.

## 2026-09-05 PAY905A001 유료 상품 준비

- App Store Connect API 사전 조회에서 앱 `6797370230`의 앱 내 구입은 0건이었고, TestFlight build `134`는 `VALID`·만료 아님·내부 그룹 1개 연결 상태였다.
- `com.taption.plan.pro`를 비소모성 상품으로 생성했다: 상품 ID `6808848628`, 이름 `Taption Plan Pro Lifetime`.
- 한국어·영어 현지화 2건, 미국 기준 소비자가 `USD 9.99`·개발자 수익 `USD 8.49`, 신규 지역 자동 제공과 175개 판매 지역(미국·한국 포함)을 API readback했다.
- 심사용 구매 화면 `/private/tmp/PRD904A001-iap-review.png`를 업로드했고 asset 상태 `COMPLETE`, 심사 메모 저장 후 상품 상태 `READY_TO_SUBMIT`을 readback했다.
- 로컬 StoreKit 구성 가격도 `0.99`에서 `9.99`로 맞췄고 product ID·상품 타입·가격 JSON 검증과 `git diff --check`를 통과했다.
- StoreKitTest 자동검증은 실제 `Product.products`·`Product.purchase`·`Transaction.currentEntitlements`·`AppStore.sync` 경로를 사용하며, 구성 파일은 테스트 번들에만 포함하고 실기기 테스트 타깃을 앱과 같은 개발팀으로 서명했다.
- Xcode 26.6의 iOS 26.5 Simulator 두 기기에서 CLI·IDE 모두 `SKInternalErrorDomain Code 3` 시스템 결함이 재현돼 해당 runtime만 명시적으로 건너뛴다. 전체 앱 결과는 `988 passed / 0 failed / 1 skipped`, 총 989건이다: `/private/tmp/IAP905G002-full-r2.xcresult`.
- iOS 26.6.1 iPad용 테스트 번들은 서명·빌드됐지만 기기가 잠겨 실제 구매·권한·복원 실행 직전 취소됐다. 잠금 해제 뒤 같은 테스트의 1/1 통과가 남아 있다.
- iPhone 시뮬레이터에서 권한 안내는 전체 건너뛰기 뒤 한 번만 재표시되고 세 번째 실행부터 숨겨짐을 확인했다. 지도 렌더·확대 버튼·16회 날짜 왕복·접근성 XXXL을 확인했고, idle CPU 5회 모두 `0.0%`, 날짜 왕복 20초 평균 `2.55%`·최대 `26.00%`였다.
- 상품 제출은 보류했다. Chrome의 계약 페이지는 `authResult=FAILED` 로그인 화면으로 열렸고 자격 증명은 입력하지 않았다. Paid Apps Agreement 활성 상태, sandbox/TestFlight 상품 조회·구매·복원, 앱 버전 연결·심사 제출은 별도 외부 게이트다.

## 2026-09-05 ALG904A001·PRD904A001 코드 리뷰·성능·배터리 회귀

- iCloud 원본 readback: actual 39건, travel 4,667건/33일, weather 5,675건, calendar 104건, floor 1,688건, raw reading 7,403건, envelope 19,132건이었다. Watch acceleration·Watch sleep 원본은 0건이고 당시 `health_enabled=false`였다.
- 날씨 envelope 13,673건은 실제 관측 시각 97개·fetch 232회·위치 bucket 53개로 중복이 컸다. raw 압축 해제 예상 크기 `146,067,067 bytes`가 기존 64MiB 제한을 넘었고, 일자 DB fallback이 이동 4,667건 전체를 후보화했다.
- 확정 결함 수정: MapKit recognizer 재부착·1Hz 탐색 제한, 일자 캐시의 불필요한 강제 재생성, timestamp-only 전체 projection 무효화, 파생 projection 누적, 동기식 진단 로그, Watch raw 이중 저장 일부 실패 readback, legacy Watch 가속도 이관 누락, cold background wake 중복 센서·Watch 소유, HealthKit callback burst·query 취소 누락·부분 실패 은폐, 이동 후보 task 고착, background 날씨 작업, Watch 자동 동기화 burst.
- 저장·전력 결함 수정: 다중 저장 실패 rollback, 전역 삭제 fence, 삭제 뒤 새 세대 빈 스냅샷 저장, raw 내부 checksum·byte count 검증과 안정적 identity, 첫·마지막 즉시 저장을 포함한 최대 5개/5초 센서 batch, background refresh 단일 저장, 동일 파생 raw 멱등 저장, Watch 로컬 archive 우선 보존, iPhone sensor generation·실패 batch 재큐잉, Watch purge 중 지연 저장 취소, 백업 부분 삭제 시 성공일 보존.
- 추가 최적화: 일시적 빈 캘린더 응답에서 선택·cache 보존, 권한 재허용·EventKit 변경 시 광역 갱신과 평시 6시간 cadence, background 날씨 cancellation fence, iPhone background wake 기반 Watch 자동 재무장, 과거 날짜의 60초 route polling 중단, Debug frame probe 환경변수 opt-in, 1시간 지난 CloudKit 업로드 임시 파일 정리.
- 알고리즘·복원 수정: 부정확·근사·비정상 GPS를 실제 경로·재생·보행·지하철·예상경로에서 제외하고 긴 공백은 직선 보간하지 않는다. segment-local 증거·역 간격 guard·O(n log n) 겹침 정리, source-safe 복원, Watch purge command·ACK와 지연 저장 fence를 적용했다.
- 날씨 raw는 256MiB 제한과 checksum·byte count 검증을 유지하면서 같은 예보 시각의 최신 revision만 채택하고, 기기 위치를 forecast stream identity에서 제외한 뒤 화면 값 변화만 저장한다. 이 결함은 첫 전체 실행에서 회귀 테스트 실패 1건으로 검출·수정했다.
- 캘린더는 source/timezone/floating/original component·external recurrence occurrence를 보존하고 provider/account/occurrence 중복을 제거했다. SQLite 정본은 유지하며 CSV는 교환용 export/import로만 제한한다.
- 시각 체계 수정: 실제 경로 teal, 예상 경로 red dash, 대중교통 gold를 공통 theme token으로 통일하고 장소·학원 아이콘 및 대중교통 라벨 가독성을 일치시켰다.
- 무결성·성능·스타일 집중 XCTest 9/9, 실패·스킵 0: `/private/tmp/PRD904A001-review-focused-final.xcresult`.
- HealthKit·Watch legacy 집중 XCTest 18/18, 실패·스킵 0: `/private/tmp/PRD904A001-health-storage-focused.xcresult`.
- 캘린더·CloudKit 임시 파일·백업 실패 집중 XCTest 5/5, 실패·스킵 0: `/private/tmp/PRD904A001-followup-focused-v2.xcresult`.
- Swift Package: TaptionPlanCore 49/49, TaptionActivityEngine 12/12, TaptionRouteEngine 18/18, TaptionPlanEngine 1/1—총 80/80 통과. raw digest는 쓰기 변경 시만 무효화하고 다른 SQLite 연결의 commit은 `data_version`으로 감지한다. 최신 30일 day store p95는 cold `5.280917ms`, warm `0.0315ms`다.
- 삭제 fence 활성 중 저장 거부와 해제 뒤 새 세대 저장 성공 회귀 18/18 통과: `/private/tmp/ALG904A001-deletion-focus-r4.S7hOjq/result.xcresult`.
- 임시 DB 격리·30일 로드 집중 XCTest 3/3 통과: `/private/tmp/PRD904A001-digest-cache-r4.JjAEIC/focused.xcresult`. 앱 30일 load p95는 cold `51.037208ms`, warm `0.007792ms`다.
- 최신 전체 앱 검증은 XCTest와 Swift Testing 총 1,005건 중 1,004 통과·실패 0·스킵 1: `/private/tmp/PRD904A001-digest-cache-r4.JjAEIC/full-final.xcresult`. 스킵은 iOS 26.5 StoreKitTest `SKInternalErrorDomain Code 3` 시스템 결함에만 한정된다. 이 실행의 앱 30일 load p95는 cold `35.755208ms`, warm `0.008375ms`, 이동 4,667건 겹침 정리 평균은 약 `0.007s`다.
- 최신 변경 기준 generic iOS Debug build, generic watchOS Debug build, iOS static analyze가 각각 exit 0으로 통과했다: `/private/tmp/PRD904A001-digest-cache-r4.JjAEIC`.
- iCloud snapshot·raw backup·진단 로그에서 HealthKit·Watch·수면 정보와 파생 보고서를 제외하고, 기존 iCloud 건강 로그를 1회 삭제한다. App Group과 `Application Support/TaptionPlan`은 시스템 iCloud 백업 제외 속성을 적용했으며 Simulator에서 `com.apple.metadata:com_apple_backup_excludeItem`을 readback했다.
- 앱·iOS Widget·Watch 앱·Watch Widget에 Required Reason API privacy manifest를 포함해 모두 `plutil` 검증했다. Release archive/export는 `/private/tmp/PRD904A001-release-r1/TaptionPlan-1.0-134.xcarchive`, `/private/tmp/PRD904A001-release-r1/Export/TaptionPlan.ipa`이며 네 번들 모두 `1.0 (134)`, Apple Distribution, Production iCloud, `beta-reports-active=true`, `get-task-allow=false`, deep/strict codesign을 통과했다. IPA SHA-256은 `2680e24aaa97f6a019d8ff7fe95f6f62522e53bef5a5a384276065c1ab34f224`다.
- Swift parse, `git diff --check`, StoreKit JSON 구문 검증을 통과했다. Xcode 설치본에는 별도 `privacytool` 실행 파일이 없어 archive 내 매니페스트 존재·plist 구문·번들 서명으로 검증했다.
- 최신 iPad Simulator 산출물을 재설치·launch해 PID `39271`을 readback했다. 5초 뒤 CPU `5.2%`에서 이후 4회 `0.0%`로 안정화됐고 RSS 약 `263~267MiB`였으며 crash 없이 유지됐다.
- 최신 iPhone Simulator에서 권한 안내의 건강 데이터만 `연결 필요`이고 위치·캘린더는 `연결됨`인 상태를 readback했다. 전체 건너뛰기 후 지도 확대 3회와 날짜 왕복 20회를 실제 UI로 수행해 오늘 화면으로 정상 복귀했고, 이후 CPU 5회 모두 `0.0%`, RSS 약 `300MiB`로 안정화됐다. 화면 증적: `/private/tmp/PRD904A001-digest-cache-r4.JjAEIC/latest-map-clean.png`.
- 자동 검증은 실제 두 손가락 pinch, 장시간 발열·배터리, iPhone/Watch 센서 실수신, Apple·Google·Naver 실제 계정, StoreKit sandbox 및 App Store Connect 판매 상태를 증명하지 않는다.

## 2026-09-05 ALG904A001·PRD904A001 현재 기기 readback

- 최신 dirty 소스의 Apple Development 서명 Debug `Taption Plan com.taption.plan 1.0 (134)`를 iPhone 14 Pro(`C44AF739-127D-572D-AD83-417C7E879045`)에 설치하고 앱 목록과 실행 중 PID `8297`을 readback했다. 이는 TestFlight 설치가 아니다.
- 앱 시작 시 CloudKit 전용 임시 파일은 `59개·172,184,964 bytes(164.2MiB)`에서 `0개`로 정리됐고, 최신 1시간 파일과 무관 파일 보존은 회귀 테스트로 확인했다.
- iPad Pro(`4CEC6BE9-E528-52A1-AB94-654A6CDA7E5E`)에 같은 최신 Apple Development 서명 Debug `Taption Plan 1.0 (134)`를 설치하고 앱 목록에서 버전을 readback했다. 반복 launch는 잠긴 기기에서 `FBSOpenApplicationErrorDomain code 7 · Locked`로 거부되어 실행·화면·터치는 미완료다. Apple Watch(`9229A9F2-B4F1-5A44-ACFA-0E5B00F3B3AF`)는 `unavailable`이다.
- 위 결과는 최신 dirty 소스 설치·프로세스 실행·임시 파일 정리만 증명한다. TestFlight 1.0(134) 설치, 화면·두 손가락 터치, 장시간 발열·전력, 센서 정확도와 Watch 실제 수신·purge ack는 별도 게이트다.

## 2026-08-31

- 대상: iPhone 14 Pro (`C44AF739-127D-572D-AD83-417C7E879045`)
- 서명 Debug 최신 소스 빌드: 성공 (`1.0 (119)`, `com.taption.plan`, `/tmp/TaptionPlan-device-build-20260831-paid-type/Build/Products/Debug-iphoneos/TaptionPlan.app`)
- 설치: 성공 (최신 product-type 보강 소스)
- 설치 readback: `xcrun devicectl device info apps`에서 `Taption Plan com.taption.plan 1.0 119` 확인
- 최신 소스 재실행: 성공 (`xcrun devicectl device process launch`, exit 0)
- 수신 요청 대기 표시를 포함한 최신 Debug 빌드(`/tmp/TaptionPlan-device-build-20260831-watch-feedback/Build/Products/Debug-iphoneos/TaptionPlan.app`)는 재설치 중 CoreDevice 연결 timeout으로 설치 readback을 확보하지 못함
- 09:35:56 미러링 `다시 시도` 후에도 “iPhone을 찾을 수 없음”으로 종료됐고, CoreDevice 재확인에서 iPhone·Apple Watch 모두 `unavailable`
- 화면: iPhone 미러링으로 Taption Plan 실제 지도 화면 진입 확인
- 터치: 미완료. 터치 시도 직후 `iPhone 사용 중`으로 미러링이 종료되고 `연결하려면 iPhone을 잠그십시오` 안내가 표시되어 직접 터치·저장 readback을 확보하지 못함
- Apple Watch: 메뉴의 최신 실제 수신 시각 표시와 receipt 저장·복원 단위 테스트는 통과했지만, 현장 설치·수신·동기화는 미완료. `available (paired)`가 일시 표시된 뒤 설치 명령에서 CoreDevice가 기기를 찾지 못했고, 09:10:58~09:11:54 재확인은 계속 `unavailable`이었다

## 2026-08-31 iPad 보조 검증

- 대상: iPad Pro (12.9-inch) (6th generation), `4CEC6BE9-E528-52A1-AB94-654A6CDA7E5E`
- 최신 소스 서명 Debug `1.0 (119)` 설치: 성공 (`databaseSequenceNumber: 6160`)
- 설치 readback: `Taption Plan com.taption.plan 1.0 119` 확인
- 최신 소스 launch: 성공 (`xcrun devicectl device process launch` exit 0)
- 화면·터치: CoreDevice에 screenshot/직접 터치 경로가 없어 미완료. `idevicescreenshot`은 이 CoreDevice UDID를 찾지 못함

## 2026-08-31 시뮬레이터·자동 검증

- 대상: `MAP30CNT01 Test` (`37ED8B8E-1EA0-43DF-BC49-D43B91CC3A0A`)
- 무료 체험 시작 후 앱 종료·재실행: 지도 복귀 확인
- 사이드 메뉴: 자동 센서 권한이 없어도 수동 기록·지도 메모 사용 가능 문구와 권한 요청 버튼 확인
- 지도 메모: 추가 화면에서 `지도 메모 추가`, 날짜·시간·위도·경도 표시 확인
- 지도 메모 취소: 편집 화면 취소 동작 후 지도 복귀 확인
- 지도 메모 draft: 취소 시 정본에 저장하지 않는 회귀 테스트 확인
- 관련 테스트: `TaptionPlanTests` 852건 성공 (`/tmp/TaptionPlan-full-2026-08-31-watch-feedback-final.xcresult`, `852 passed / 0 failed / 0 skipped`)
- 결제 상품 타입 보강 기준 XCTest: 852건 성공 (`/tmp/TaptionPlan-full-2026-08-31-paid-type.xcresult`, `852 passed / 0 failed / 0 skipped`)
- 최신 dirty 소스 iOS Release generic build: 성공 (`1.0 (119)`, `/tmp/TaptionPlan-release-20260831-paid-type/Build/Products/Release-iphoneos/TaptionPlan.app`); embedded Watch app과 Widget 포함
- 최신 dirty 소스 watchOS Release generic build: 성공 (`1.0 (119)`, `/tmp/TaptionPlan-watch-release-20260831-paid-type/Build/Products/Release-watchos/TaptionPlanWatch.app`)
- 수신 요청 대기 표시 포함 최신 dirty 소스 iOS Release generic build: 성공 (`1.0 (119)`, `/tmp/TaptionPlan-release-20260831-watch-feedback/Build/Products/Release-iphoneos/TaptionPlan.app`); embedded Watch app·Widget 포함
- 수신 요청 대기 표시 포함 최신 dirty 소스 watchOS Release generic build: 성공 (`1.0 (119)`, `/tmp/TaptionPlan-watch-release-20260831-watch-feedback/Build/Products/Release-watchos/TaptionPlanWatch.app`)
- 미래 예보: WeatherKit/Open-Meteo hourly forecast를 `isForecast`로 관측값과 구분하고 SQLite round-trip하는 회귀 테스트 통과
- Watch receipt: 측정 시각과 실제 수신 시각 분리, envelope 도착 시각의 callback 전달, 지연 payload의 최신 수신 판정, reload 보존 회귀 테스트 통과
- 빈 health 응답: 값이 없는 health snapshot도 `health` receipt와 최신 수신 시각을 기록하는 회귀 테스트 통과
- Watch 요청 피드백: 전송 접수 시 요청 시각을 표시하고 실제 envelope 수신 시 최신 수신 시각으로 전환하는 소스·컴파일 검증 완료. 실기기 버튼·수신 전환은 Watch 연결 불안정으로 미완료
- 계획 삭제 보존: 로컬 계획 삭제 후 연결된 지도 메모의 계획 연결만 해제되고 좌표·발생 시각·본문이 저장소 readback에 남는 회귀 테스트 통과
- 시간 경계: 계획 종료 시각의 지도 메모가 종료된 계획에 연결되지 않는 회귀 테스트 통과
- 동시 저장: 편집 중 미저장 지도 메모 draft가 저장소 readback에 남지 않는 회귀 테스트 통과
- 시간 재연결: 지도 메모를 다른 계획 시간으로 옮기면 재연결되고 계획 종료 시각에서는 독립 메모로 분리되는 회귀 테스트 통과
- 초안 삭제: 지도 메모 초안을 일반 삭제해도 저장소와 Cloud tombstone에 남지 않는 회귀 테스트 통과
- 재생 cutoff: 일간 지도 재생 중 playhead 이후 지도 메모를 숨기고 동시각 메모를 포함하는 회귀 테스트 통과
- 필터 UI: 표시 메뉴에서 모든 지도 메모/일정 관련 메모를 선택하고 설정이 저장되는 UI 경로 반영
- build 120 Release archive/export: 성공 (`/private/tmp/taption-rel8310001.xcarchive`, `/tmp/taption-rel8310001-export/TaptionPlan.ipa`); IPA SHA-256 `65003366d03503c02afd87d8fc17a301ce75e08ea5cb9ba0a5986c605d562d39`, `codesign --verify --deep --strict` 통과.
- build 120 TestFlight 업로드: 성공, Delivery UUID `d0c6d36b-5978-40c0-9027-bb3169d0cae6`; `BUILD-STATUS: VALID`, `IMPORT-STATUS: VALID`, `APP_STORE_ELIGIBLE`, App Store Connect 등록 및 version `120` readback.
- build 120을 `TP Taption Plan 내부 테스트`에 연결하고 그룹 상세에서 `1명의 테스터 · 81개의 빌드`, `1.0 (120) · 테스트 중` 노출을 확인했다. 테스터 화면은 1명 노출을 확인했으며, 현재 설치 표시는 기존 `1.0 (119)`이고 build 120 설치 readback은 아직 없다.
- `ARC831A001` 전체 검증: package 65건(`Core` 40, `Activity` 8, `Route` 16, `PlanEngine` 1), 앱 XCTest 848건과 Swift Testing 18건이 모두 통과했고 generic iOS Debug·Release 빌드와 Release archive/export가 성공했다.
- build 121 배포 소스는 `53e18940bbf13459927d23053ad783f0b8431294`; 앱·Widget·Watch·Watch Widget 모두 `1.0 (121)`, Apple Distribution 서명, Production iCloud, TestFlight entitlement, deep codesign을 확인했다. IPA SHA-256은 `3957d7f3800314fc9af6f201a3a4ad3ef20548120f6917072337ef187dffa667`이다.
- build 121 TestFlight 업로드: Delivery UUID `d1cf40bf-7b56-42ef-a7cb-12d82067734c`; upload state `COMPLETE`, 오류·처리 경고 0, App Store Connect `제출 준비 완료`를 readback했다. MapLibre 외부 framework dSYM 미포함은 심볼 업로드 경고이며 앱 업로드는 수락됐다.
- build 121을 `TP Taption Plan 내부 테스트`에 연결했다. 그룹 상세에서 `내부 그룹 · 1명의 테스터 · 82개의 빌드`, 빌드 화면에서 `1.0 (121) · 테스트 중 · iOS`, 테스터 화면에서 내부 테스터 1명 노출을 확인했다. 현재 설치 표시는 `1.0 (120)`이며 build 121 설치·실행·실제 화면/터치와 Watch 현장 수신은 미완료다.
- App Store Connect read-only 확인(09:55:39 KST): Chrome에서 `axony99@gmail.com` 계정으로 로그인된 세션과 `Taption Plan` 앱 접근을 확인했다.
- 기존 TestFlight build 119: `제출 준비 완료`, `TP Taption Plan 내부 테스트` 그룹 노출, 설치 1건을 확인했다. 그룹 상세는 `내부 그룹 · 1명의 테스터 · 80개의 빌드`, 테스터 `axony99@gmail.com`의 `설치됨 1.0 (119)` 및 2026년 8월 31일 readback을 확인했다.
- Paid Apps Agreement: 비즈니스 계약 표에서 `유료 앱 계약 · 신규`로 표시되어 활성 계약이 아니다. `무료 앱 계약`은 2026년 8월 19일~2027년 6월 3일 `활성화됨`이다.
- 앱 내 구입: `/apps/6797370230/distribution/iaps`가 빈 상태이며 `com.taption.plan.pro` 상품은 App Store Connect에 아직 생성되지 않았다. 계약 서명·상품 생성·sandbox 구매 검증은 미완료다

## 2026-08-31 지하철·예상경로·Apple Watch 진단

- iCloud 조회 범위: 2026-08-31 00:00~12:28 KST. 별도 `TaptionLogs` export는 2026-08-16이 최신이지만, 메뉴의 iCloud 백업 경로 `iCloud.com.taption.plan/Documents/Taption Plan/2026-08.taptionbackup`와 `Raw Sensors/2026-08.rawsensorbackup`가 2026-08-31 12:47에 갱신되어 백업 성공을 확인했다. 암호화 payload를 읽기 전용으로 복호화해 오전 여행 구간 7개 중 `09:31~10:06 KST` 지하철 1개와 `인천2호선·공항철도`를 확인했다.
- 같은 범위 raw sensor는 684건 모두 iPhone이며 Watch source는 0건, `nearbyStation`·철도/대중교통 플래그·역 이름은 모두 0건이었다. 따라서 백업은 존재하지만 이 백업 안에는 Watch 원본과 역 체류 근거가 들어오지 않았다.
- 역 후보 진단: `transit_boarding_candidates_evaluated`에 입력 reading·GPS/정확도·등록/주변 장소·powered travel·후보 수·후보명·연결 구간 수를 기록하도록 했다.
- 예상경로 진단: `expected_route_requests_built`, `expected_route_projection_built`, `expected_route_network_resolution`, `expected_route_state_applied`에 요청·중복 segment·forecast/gap·시간 겹침·동일 endpoint·generated 수와 phase를 기록하도록 했다. 백업은 성공했지만 payload가 암호화되어 포함 로그를 아직 직접 읽지 못했으므로 첨부 화면의 과다 점선 원인은 확정하지 않았다.
- Apple Watch 진단: `설정 메뉴 > Apple Watch 데이터`의 버튼 탭·전송 접수/거부·transport·envelope·sensor/health decode·receipt 저장·대기 해제를 요청 ID로 연결하도록 했다. 백업 내부의 8/31 Watch 요청은 `reachable=false`였고 envelope 수신 이벤트가 없었다. 당시 iPhone·Watch 연결 및 Watch 잠금 해제는 사용자 확인이지만, 실제 데이터 전달은 확인되지 않았고 현재 CoreDevice 재확인에서는 iPhone·Watch 모두 `unavailable`이다.
- 자동 검증: 역 후보 관련 XCTest 10건, `RouteTimelineDataTests` 단독 실행 exit 0, `WatchSensorQueryPlanTests` 단독 실행 exit 0, iOS Debug 및 watchOS Debug build 통과. forecast 투영에서 명시 이동과 겹치는 gap 및 동일 endpoint·시간 중복 이동을 제거하는 보정을 반영했다. 백업에 새 예상경로 진단 이벤트가 없고 오전 travel 자체에는 동일 endpoint 중복이 없어 점선 중복 원인은 미확정이며, 새 빌드 실기기 재현·Apple Watch 실제 수신 전환은 미완료다.
- `LIN8310001` 정합성 보정: visible forecast leg ID를 기준으로 재생 frame을 선택하고, MapKit 점선 좌표도 동일한 `MapHomeWBSPlaybackProjection`에서 잘라 사용하도록 통합했다. 재생 중 cutoff는 지연된 `routeProjection.cutoff`가 아닌 동일한 fractional playhead를 사용하며 `expected_route_playback_alignment` 진단 로그를 추가했다.
- `LIN8310001` 회귀: `RouteTimelineDataTests`·`TimeScaleTests` focused XCTest 통과, 전체 `TaptionPlanTests` 통과 (`/Users/u_mo_c/Library/Developer/Xcode/DerivedData/TaptionPlan-gvqtjbpzkfvutrdlxdzhdyhsyane/Logs/Test/Test-TaptionPlan-2026.08.31_18-41-48-+0900.xcresult`), iPhone 14 Pro 시뮬레이터 Debug build `** BUILD SUCCEEDED **`.
- `LIN8310001` 실제 iPhone 화면 재생·터치 및 Watch 현장 검증은 아직 수행하지 않았다.

## 2026-09-01 통합 검증

- `STK901A001`, `PAID831001`, `SUB8310001`, `WAT8310001`, `RTE8310001` 구현과 최종 P0/P1 읽기 전용 재리뷰를 완료했다.
- iPhone 14 Pro 시뮬레이터 전체 XCTest 874건 통과, 실패·건너뜀 0건 (`/private/tmp/taption-manager-final-full-alt.xcresult`).
- `REL901A001` 릴리스 회귀에서 철도 일치 1회만 있는 두 역 차량 이동의 지하철 오탐 경로를 차단했다. 두 역 sparse 복원·catalog 승차 후보는 철도 일치 최소 2회와 25% 비율 또는 연속 지하철 Wi-Fi를 요구하며, 세 역 이상 정합 경로와 Watch 진동·지하 신호 판정은 유지한다.
- `REL901A001` 관련 집중 XCTest 6건 통과, 실패·건너뜀 0건 (`/private/tmp/taption-rel901a001-rail-evidence-v4.xcresult`).
- build 122 최종 iPhone 14 Pro 시뮬레이터 전체 XCTest 876건 통과, 실패·건너뜀 0건 (`/private/tmp/taption-rel901a001-final-full-v3.xcresult`).
- 물리 iPhone 14 Pro에서 지하철 후보·예상경로 중복·Watch receipt 핵심 XCTest 5건 통과, 실패 0건 (`/private/tmp/taption-manager-device-focused.xcresult`).
- 현재 소스의 서명 Debug `1.0 (121)` 빌드·설치 후 앱 목록에서 버전과 빌드 번호를 readback했고, `com.taption.plan` 실행 및 PID `13753`을 확인했다.
- 물리 iPhone 사용은 Taption Cam `8/29 메인 개발`과 상호 메시지로 빈 슬롯을 확인한 뒤 진행했으며, 설치·실행 readback 직후 슬롯을 반환했다.
- 실제 Apple Watch envelope 수신과 설정 화면의 `수신 대기 → 최근 수신` 전환은 Watch가 CoreDevice에서 `unavailable`이라 현장 게이트로 유지한다.
- `REL901A001` 배포 소스는 `865588099a680d100080c891afed3de9cb8e41b0`이며 배포 시 `main`·`origin/main`·원격 main이 일치하고 tracked worktree가 clean이었다.
- iPhone 14 Pro에 build 122 Debug를 설치해 `Taption Plan com.taption.plan 1.0 122`를 readback하고 앱 실행 PID `14952`를 확인했다. Cam에서 반환받은 슬롯만 사용했고 ShotGuide `1.0.0 (57)`과 데이터는 보존했다.
- build 122 archive/export 성공: `/private/tmp/taption-rel901a001-build122/TaptionPlan-1.0-122.xcarchive`, `/private/tmp/taption-rel901a001-build122/Export/TaptionPlan.ipa`. IPA SHA-256은 `ad2bbab7dedee8e7d78eae0da325f6c4a407fd50eb13b64d5af53f85b7c9a309`이며 앱·iOS Widget·Watch·Watch Widget 모두 `1.0 (122)`, Apple Distribution 서명, Production iCloud, TestFlight entitlement, deep codesign을 확인했다.
- build 122 TestFlight 업로드 성공: Delivery UUID `1c4edd59-af22-4bba-a432-13e7778b3a32`; `BUILD-STATUS: VALID`, `IMPORT-STATUS: VALID`, `APP_STORE_ELIGIBLE`, `PROCESSINGSTATE: VALID`.
- App Store Connect API에서 build 122 `VALID`, `TP Taption Plan 내부 테스트` 관계 포함, 그룹 빌드 83개, 내부 테스터 1명을 readback했다.
- App Store Connect Chrome 화면에서 `TP Taption Plan 내부 테스트 · 1명의 테스터 · 83개의 빌드`, build `1.0 (122) · 테스트 중 · iOS`를 readback했다. 테스터 화면에는 내부 테스터 1명이 노출됐고 현재 설치 표시는 `1.0 (121)`이므로 build 122 설치로 과장하지 않는다.

### 미완료 게이트

- Apple Watch 현장 설치·수신·동기화 확인
- Paid Apps Agreement 활성화·`com.taption.plan.pro` 생성·sandbox 구매/복원 확인

## 2026-09-02 DEV901A001 실기기 이전 기록 정합성 검증

- 대상: iPhone 14 Pro (`C44AF739-127D-572D-AD83-417C7E879045`), iOS 26.6.1
- 최신 서명 Debug 설치·readback: `Taption Plan com.taption.plan 1.0 125`, launch 성공
- 실제 기기 XCTest: 라우트·재생·시간축·날씨 관련 203건 통과, 실패 0건 (`/private/tmp/DEV901A001-device-tests-v2.xcresult`)
- 최신 전체 시뮬레이터 XCTest: 894건 통과, 실패·건너뜀 0건 (`/private/tmp/DEV901A001-full-tests-v2.xcresult`)
- 정본 대조: 2026-08-31 actuals 0건, travel 153건(확정 2건), places 300건, 관측 weather 0건; 계산된 약 1,252분 미확인 구간은 저장 데이터와 일치
- 2026-09-01 weather 1,936건은 동시 위치·예보 context 중복이었고, MapHome 표시 투영에서 같은 분 대표값 1건으로 축약하는 회귀 테스트 통과
- 날짜 전환 stale 데이터·공백 재생 fallback·연속 GPS 이동의 예상 점선 회귀 수정은 실제 기기 테스트 대상에 포함되어 통과
## 2026-09-02 DEV901A001 iPhone Mirroring 화면 검증

- 대상: iPhone 14 Pro (`C44AF739-127D-572D-AD83-417C7E879045`), 설치 `Taption Plan 1.0 (125)`
- Mirroring에서 Plan 화면을 열고 2026-09-02 → 2026-09-01 날짜 이동, 2026-09-01 지도·weather rail 렌더링, 시간축 23:59 → 11:54 이동을 확인했다.
- 2026-09-01 재생에서 버튼이 일시정지 상태로 전환되고 선택 시간이 11:54 → 12:34 → 15:30으로 진행되며 지도 경로·졸라맨 표시가 stale 경로로 점프하지 않는 것을 확인했다. 정지 후 2026-09-02로 복귀했다.
- 2026-09-02 재생에서 선택 시간이 01:20 → 01:49로 진행되고 재생 중 경로가 비정상적으로 이전 날짜/마지막 leg를 재사용하지 않는 것을 확인했다.
- 지도 단일 손가락 이동, 확대/축소 컨트롤, 현재 위치 복원을 실제 터치로 확인했다. Mirroring 자동 입력 API에는 다중 손가락 pinch 입력이 없어 pinch 자체의 물리 latency는 직접 측정하지 못했으며, 해당 MagnificationGesture 입력 예산은 소스 회귀 테스트로 검증했다.

## 2026-09-02 REL902A001 TestFlight build-up

- 배포 소스는 `6b302ea2f9bca3f818c829514af1ee147b83be47`이며 `main`·`origin/main`이 일치한 상태에서 build number를 126으로 올렸다.
- Debug generic iOS build 성공: `1.0 (126)`, `/private/tmp/REL902A001-debug-derived/Build/Products/Debug-iphoneos/TaptionPlan.app`.
- Release archive/export 성공: `/private/tmp/REL902A001-release/TaptionPlan-1.0-126.xcarchive`, `/private/tmp/REL902A001-release/Export/TaptionPlan.ipa`. IPA SHA-256은 `5db4f2dbb11f7fa3ac64aca515dc6fd3474c35ecc6e19ddcff1373f56664ed25`이다.
- IPA의 앱·iOS Widget·Watch 앱·Watch Widget 모두 `1.0 (126)`, Apple Distribution 서명, `beta-reports-active=true`, `get-task-allow=false`, deep/strict codesign을 확인했다. `altool --validate-app`도 오류 없이 통과했다.
- TestFlight 업로드 성공: Delivery UUID `8e66a688-a922-4f76-b761-4da7b3faadb1`; App Store Connect API readback에서 build `126`이 `VALID`, `APP_STORE_ELIGIBLE`, `expired=false`로 확인됐다.
- `TP Taption Plan 내부 테스트`(internal group, ID `b4857e5e-d1ff-4bc2-b9ad-a69bcd4603fd`)에 build `126` 연결 성공. 그룹 빌드 API에서 `87개`와 build `126` `VALID`, 내부 테스터 API에서 `1명`(`axony99@gmail.com`)을 readback했다.
- App Store Connect 그룹 빌드 화면·테스터 화면은 연결된 Chrome과 in-app Browser가 로그인 화면으로 열려 계정 자격 증명을 입력하지 않았으므로 미완료 게이트로 남긴다.

## 2026-09-02 CLN902A001 저장공간 정리

- 정리 전 readback: 데이터 볼륨 여유 39GiB, `/private/tmp` 약 77G, CoreSimulator 약 26G.
- 종료 상태였던 iOS 26.5 Simulator 5대의 device data를 삭제했다: `37ED8B8E-1EA0-43DF-BC49-D43B91CC3A0A`, `A1BCAC6A-AA32-4D3F-90A9-FF3CBAE39CC1`, `3D26B7FD-55B0-4404-BA2F-44FE1C6FBB8D`, `4E0207AD-E023-4D87-8089-00F476421D04`, `75BE290F-DC49-4540-9901-127E6D0074A6`. iOS/watchOS 26.5 runtime은 보존했다.
- 문서에 남은 증적·REL902A001 release archive·활성 카메라 로그를 제외하고, 2026-09-01 이전 소유 가능한 `/private/tmp` 임시 산출물 2,387개 약 27.92G를 정리했다. root 소유 `FTABHarvest` 1개는 권한 보호로 보존했다.
- 정리 후 readback: `/private/tmp` 50G, 데이터 볼륨 여유 61GiB, CoreSimulator 2.1G. `XCTestDevices`·Xcode `DerivedData`는 0B, Xcode `Archives` 1.4G는 보존했다.
- 정리 직후 다른 작업이 iPad Simulator `2CD5BB05-7C63-4D44-A0B3-170F83F62210`를 부팅하고 `WBS33GOAL1` XCTest를 실행 중인 것을 확인해 해당 작업과 현재 산출물을 보존했다. CoreDevice가 사용 중인 `/private/tmp/CAM30LIBR1-stage4-REZrnD`와 `/private/tmp/CAM29LIVE3-camera-r4.jsonl`도 보존했다.
- 사용자 휴지통 readback은 0개이며, 현재 Taption Plan 소스·Git 상태와 build 126 release 증적은 삭제하지 않았다.

## 2026-09-02 REL902A002 TestFlight build-up

- 배포 소스 커밋 `311b5832cc9819e91f16c79af2970eb7a6dbc51b`을 `main`에 커밋·푸시했고, archive 시점 `main`·`origin/main`·원격 main 일치 및 tracked/untracked clean을 확인했다.
- Release archive/export 성공: `/private/tmp/REL902A002-release-v2/TaptionPlan-1.0-127.xcarchive`, `/private/tmp/REL902A002-release-v2/Export/TaptionPlan.ipa`; IPA SHA-256 `05f179337b4bdaa5c7dcd887adc1f5246ccd27de00d0d394210829f2c99c8aa0`.
- 앱·iOS Widget·Watch 앱·Watch Widget 모두 `1.0 (127)`, Apple Distribution 서명·Production iCloud·TestFlight entitlement·deep/strict codesign·`altool --validate-app` 통과.
- TestFlight 업로드 성공: Delivery UUID `3297b1a2-fde1-40b3-b219-b99f13cf4c1e`; App Store Connect API에서 build 127 `VALID`·`APP_STORE_ELIGIBLE`·`expired=false` 처리 완료를 확인했다.
- `TP Taption Plan 내부 테스트`(ID `b4857e5e-d1ff-4bc2-b9ad-a69bcd4603fd`)에 build 127 연결 성공. 그룹 빌드 API에서 전체 88개와 build 127, 테스터 API에서 내부 테스터 1명(`axony99@gmail.com`, `INSTALLED`)을 readback했다.
- App Store Connect 그룹 빌드·테스터 실제 화면은 Chrome과 in-app Browser가 로그인 화면으로 열려 자격 증명을 입력하지 않았으므로 UI readback은 미완료다. TestFlight build 127 실기기 설치·launch·실제 터치도 별도 게이트다.

## 2026-09-03 TF26PUSH01 build-up·기기 설치

- 배포 소스 `84448b8aa8fc7b9de35b2903561a90095c2bee62`를 `main`에 커밋·푸시하고 build number를 `128`로 올렸다.
- package 테스트: Core 40/40, Activity 12/12, Route 17/17, Engine 1/1 통과.
- Release archive/export 성공: `/private/tmp/TF26PUSH01-release-r2/TaptionPlan-1.0-128.xcarchive`, `/private/tmp/TF26PUSH01-release-r2/Export/TaptionPlan.ipa`; IPA SHA-256 `b6532fc4be01c52a03fe1ef85f60b3bdb5156f77901cdd7483812834db9154e6`.
- 앱·iOS Widget·Watch 앱·Watch Widget 모두 `1.0 (128)`, Apple Distribution 서명·Production iCloud·TestFlight entitlement·deep/strict codesign·`altool --validate-app` 통과.
- TestFlight 업로드 성공: Delivery UUID `3ce79d87-b2cd-429e-b988-816d0b9af84a`; App Store Connect API readback `VALID`, `APP_STORE_ELIGIBLE`, `expired=false`.
- `TP Taption Plan 내부 테스트` 연결 성공. 그룹 빌드 API readback은 전체 89개·build 128 `VALID`, 내부 테스터 1명(`axony99@gmail.com`, `INSTALLED`)이다.
- iPhone 14 Pro(`C44AF739-127D-572D-AD83-417C7E879045`) TestFlight 업데이트 후 `com.taption.plan` `1.0 (128)` 설치와 launch PID `26948`를 readback했다.
- iPad Pro(`4CEC6BE9-E528-52A1-AB94-654A6CDA7E5E`)는 현재 `Taption Plan 1.0 (125)`이다. CoreDevice로 beta IPA를 직접 설치할 수 없어(`0xe800801f`, beta profile entitlement 오류) TestFlight 앱을 통한 build 128 다운로드·설치·launch는 남은 게이트다.
- ASC 그룹·테스터 실제 화면은 로그인 필요로 미완료다. 관련 로그: `/private/tmp/TF26PUSH01-asc-readback.json`, `/private/tmp/TF26PUSH01-iphone-launch.json`, `/private/tmp/TF26PUSH01-ipad-before-apps.log`.

## 2026-09-03 SLP903TF02 수면 연결 복구·build 129

- iCloud 백업은 정상이고 Watch snapshot의 `health_enabled=false` 때문에 HealthKit 수면 refresh가 실행되지 않은 원인을 확인했다.
- 오늘 수면이 없고 건강 연동이 꺼진 경우만 `수면 연결` 안내를 표시하는 회귀 테스트를 포함해 전체 XCTest 901/901, 실패·스킵 0을 통과했다: `/private/tmp/SLP903TF02-full.xcresult`.
- generic iOS Debug build와 Release archive/export를 통과했다. 앱·iOS Widget·Watch 앱·Watch Widget 모두 `1.0 (129)`, Production iCloud/TestFlight entitlement와 deep/strict codesign, `altool --validate-app`이 정상이다.
- IPA SHA-256은 `3acc55045b44c3bbc94e6172edf43f372ab9efba467b347e65b8aec2d546c723`, Delivery UUID는 `411a22f3-430a-48fb-bde7-03269ca710e6`이다.
- App Store Connect API에서 build 129 `VALID`·`APP_STORE_ELIGIBLE`·`expired=false`, 내부 그룹 연결, 그룹 build 90개 중 build 129, 내부 테스터 1명(`axony99@gmail.com`, `INSTALLED`)을 readback했다.
- HealthKit 권한 승인과 오늘 수면 실제 생성은 사용자 탭이 필요한 별도 실기기 게이트다. iPad에는 TestFlight `4.3.0 (659.1)`이 설치돼 있으며 앱 build 129 다운로드·설치·launch가 남아 있다.

## 2026-09-03 SID903A001 날짜 전환 사이드바 회귀

- 날짜 전환 초기화에서 전체 `미확인` 대입을 제거하고 선택 날짜의 actual·travel 대분류를 즉시 투영한다.
- `TimeScaleTests.testMapHomeSidebarDateChangeProjectsTheSelectedDaysMajorCategories` 통과, 실패 0: `/private/tmp/SID903A001-focused-r2.xcresult`.
- 테스트 실행 과정의 Debug 앱·Widget·Watch target 빌드가 성공했다. 실제 기기 날짜 전환 화면 확인은 별도 게이트다.

## 2026-09-03 TF903B013X TestFlight build 130

- 전체 XCTest 902/902, 실패·스킵 0: `/private/tmp/TF903B013X-full.xcresult`.
- Release archive/export 성공. 앱·iOS Widget·Watch 앱·Watch Widget 모두 `1.0 (130)`, Production iCloud/TestFlight entitlement와 deep/strict codesign, `altool --validate-app` 통과.
- IPA SHA-256 `0904b72f68a00f32bd7cd29b48c027acfb4764c684d3696265b1fb1035218fa8`, Delivery UUID `064f2803-95d1-458b-96bc-819b087c13c9`.
- App Store Connect API에서 build 130 `VALID`·`APP_STORE_ELIGIBLE`·`expired=false`, 내부 그룹 연결, 그룹 build 91개 중 build 130, 내부 테스터 1명(`axony99@gmail.com`, `INSTALLED`)을 readback했다.
- build 130 실기기 설치·launch와 날짜 변경 실제 화면 확인은 별도 게이트다.

## 2026-09-03 REL903TF01 TestFlight build 131

- `MapHomeStickmanTests.testOnlyMovementStickmanActionsAnimate` 통과, 실패 0. 테스트 실행 과정의 Debug 앱·Widget·Watch target 빌드도 성공했다.
- Release archive/export 성공. 앱·iOS Widget·Watch 앱·Watch Widget 모두 `1.0 (131)`, deep/strict codesign과 `altool --validate-app` 통과.
- IPA SHA-256 `4435667dba069fda3706217b5c6af8947cef75eb72689525bc2fd75dd603f6f8`, Delivery/build UUID `805169b0-e3d9-41b2-883d-475504a3884d`.
- App Store Connect API에서 build 131 `VALID`·`expired=false`, 내부 그룹 연결, 그룹 build 92개 중 build 131, 내부 테스터 1명(`axony99@gmail.com`, `INSTALLED`)을 readback했다.
- build 131 실기기 설치·launch와 실제 Watch 설정·비이동 정지 화면 확인은 별도 게이트다.

## 2026-09-04 LOG904TF01 TestFlight build 132

- 지하철 잠금 교체·권한 재안내·진단 요약 집중 XCTest 4/4 통과, Release archive/export와 `altool --validate-app` 통과.
- 네 번들 `1.0 (132)`, IPA SHA-256 `afc0a852750c0b67e017453a5b9c3aea05cf6b41bb89be211185496ac4de0b5b`, Delivery/build UUID `5d01450c-2c10-4b8f-bcff-8852258fe2f1`.
- App Store Connect API에서 build 132 `VALID`·`APP_STORE_ELIGIBLE`·`expired=false`, 내부 그룹 연결, 그룹 build 93개 중 build 132, 내부 테스터 1명(`axony99@gmail.com`, `INSTALLED`)을 readback했다.
- build 132 설치·launch 및 지하철·예상경로·수면 로그 확인은 대표님 테스트 후 진행할 별도 실기기 게이트다.

## 2026-09-04 TFB904A133 TestFlight build 133

- 실행 성능 수정 커밋 `8d041e9284d8393cbbf1157cf2b795c1cb6b51cf`, 배포 소스 `3930b808c86f20b003e474c56846252156303b41` 기준 관련 XCTest 4/4와 generic iOS Simulator Debug build가 통과했다: `/private/tmp/TFB904A133-focused.xcresult`.
- Release archive/export와 `altool --validate-app` 통과. 네 번들 모두 `1.0 (133)`, Apple Distribution 서명, TestFlight entitlement 정상이다. IPA SHA-256은 `422bcb43a8822b7eac2ff7935471acecddd5a46c2ade6a506ccf6cebdda92f4a`다.
- Delivery/build UUID `bc2b0f81-83f2-4001-80f2-19707a1b1fcc`는 `VALID`·`APP_STORE_ELIGIBLE`·`expired=false`다. Internal 그룹 연결 후 API에서 그룹 build 94개 중 build 133과 내부 테스터 1명(`INSTALLED`)을 readback했다.
- Chrome 그룹 빌드 화면에서 build `1.0 (133) · 테스트 중 · iOS`, 테스터 화면에서 내부 테스터 1명과 그룹 `94개의 빌드`를 확인했다. 현재 설치 표시는 `1.0 (132)`이며 build 133 설치·launch·실제 화면·발열은 미확인이다.

## 2026-09-04 REL904A001 TestFlight build 134

- 위치·수면·경로·지하철 수정 후 `TaptionActivityEngine` 12/12, iOS 집중 XCTest 3/3, Debug build를 통과했다.
- `main` 커밋·푸시: `f99d72b93919e8646a6fc7d9908330e524eb6034`; Release archive/export 성공, 네 번들 `1.0 (134)`, IPA SHA-256 `225ba74b3de11b05e1c4a530d20a21b495b34ca0b22f8af503184b9dabf45851`.
- `altool --validate-app` 및 TestFlight 업로드 성공. Delivery UUID `a3581625-8668-4d3a-85c1-240078bc054e`; App Store Connect API에서 build 134 `VALID`·`expired=false` 확인.
- `TP Taption Plan 내부 테스트` 연결 성공. 그룹 빌드 API에서 build 134와 내부 테스터 1명을 readback했으며, 테스터 설치·실행은 아직 확인하지 않았다.

## 2026-09-22 RSC0922C01 클라우드 복원 동시 변경 회귀

- iOS 26.5 iPhone 17 Pro Simulator에서 `FeatureEngineTests.testCloudRestoreDoesNotReplaceConcurrentLocalSnapshotEdit` 1/1 통과, 실패·스킵 0: `build/validation/RSC0922C01-final.xcresult`.
- repository save를 정지한 동안 로컬 메모를 추가해, 복원 결과가 `.unchanged`이고 메모가 앱 snapshot·저장소에 유지되며 복원 raw reading은 rollback되는지 검증했다.
- 테스트 파일이 다른 소스 파일의 `private JSONEncoder.taptionPlan`을 참조하던 컴파일 오류를 테스트 전용 encoder로 고쳤다. 당시 공용 빌드 락과 낮은 여유 공간 때문에 후속 BGR/WPR 검증을 보류했으나, 락 해제 및 공간 회복 뒤 아래에서 5/5 통과했다.

## 2026-09-22 BGR0922C01 · WPR0922C01 후속 집중 검증

- iOS 26.5 iPhone 17 Pro Simulator에서 RSC restore race, snapshot commit 뒤 cancellation/rollback 실패, snapshot readback 실패, snapshot commit 전 cancellation, Watch purge 중 sync admission 총 5/5 통과, 실패·스킵 0: `build/validation/WPR0922C01-final2.xcresult`.
- 실패·불확실 readback에서 committed snapshot이 가리키는 raw generation을 보존함을 확인했다. Watch gate는 purge 전에 대기하던 요청을 무효화하고 purge 중 신규 sync를 거부하며 purge 후 새 요청은 허용한다. TestFlight 및 페어링 Watch 물리 동작은 이 회귀에 포함되지 않는다.

## 2026-09-22 DHV0922A01 · Device Hub iPhone current-state check

- iPhone 14 Pro/iOS 27.2에 설치된 `com.taption.plan` 1.0 (149)을 readback했다. 이번 검증은 재설치·초기화 없이 현재 설치본에서 진행했다.
- Device Hub에 직접 입력해 날짜를 9/21→9/22→9/21로 이동·복원하고 재생 아이콘을 Play→Pause→Play로 전환했다. 증거: `build/validation/DHV0922A01/devicehub-date-forward3.png`, `devicehub-date-restored.png`, `devicehub-play-running-attempt3.png`, `devicehub-play-paused.png`. 최종 날짜는 9/21, 재생은 정지 상태다.
- CUA `getState`/`getApp` 및 세션 재설정은 `failed to write kernel assets`로 실패했지만, Device Hub 직접 입력은 CoreGraphics 이벤트로 수행됐다. 최신 checkout의 이 설치본 반영 여부는 미확인이다: `AppModel.swift`/`RouteTimelineData.swift` 수정 시각은 9/22 01:57/01:45, 마지막 iPhone build log는 9/21 23:58이며 이번 검증에서는 재빌드·재설치를 하지 않았다.
- 최신 빌드 설치는 보류했다. 직전 설치에서 app data container 경로가 바뀐 기록이 있고 app-private Application Support에는 음성 메모·센서 archive가 저장될 수 있어 데이터 연속성을 보장할 수 없다. 이번 검증은 앱 데이터 초기화·설치·암호/UI Automation 변경 없이 끝냈다.
- 9/22 Device Hub 직접 입력 재검증: iPhone 14 Pro/iOS 27.2의 설치본 1.0 (149), app PID 1640·widget PID 1642/1650을 확인했다. 날짜는 9/21→9/22로 이동 후 9/21로 복원했다. 재생 입력으로 Pause 아이콘과 시간 진행을 확인했고, 정지 입력으로 Play 아이콘이 돌아온 뒤 2.5초간 타임라인 위치 16:46이 유지됐다. 최종 화면은 9/21·Play(정지) 상태다. 증거: `devicehub-ui-current-2026-09-22.png`, `devicehub-date-next-live-2026-09-22.png`, `devicehub-date-restored-day-live-2026-09-22.png`, `devicehub-play-live-2026-09-22.png`, `devicehub-pause-live-2026-09-22.png`, `devicehub-pause-stable-live-2026-09-22.png`.
- 설치/초기화는 하지 않았고 검증 전후 `dataContainerPath`는 동일했다. 최신 checkout은 아직 이 설치본에 포함되지 않았으며, 여유 공간 432MiB라 실기기 Debug 재빌드는 실행하지 않았다.

## 2026-09-22 RVR0922A01 · Watch summary snapshot high-water 회귀

- iOS 26.5 iPhone 17 Pro Simulator에서 `SensorDayStoreTests.testWatchSummaryHighWaterRestoresAcrossAppRestartDespiteStaleCache` 1/1 통과, 실패·스킵·runtime warning 0: `build/validation/RVR0922A01-watch-ack.xcresult`.
- 동반 `testSameVersionWatchRedeliveryCompletesUnappliedSnapshotBeforeAck`는 simulator가 `com.taption.plan` 실행 전 SpringBoard preflight `Busy`로 종료되어 test body에 진입하지 못했다. `build/validation/RVR0922A01-same-version-ack.xcresult`는 runner 실패(exit 65)이며 assertion 실패로 집계하지 않는다. 재실행은 하지 않았다.
- 후속으로 동일 테스트를 기존 현재 Debug 제품에서 `xcodebuild test-without-building`으로 재실행해 1/1 통과했다. 실패·스킵·runtime warning 0, exit 0: `build/validation/RVR0922A01-same-version-ack-current.xcresult`.

## 2026-09-22 SwiftPM package regression rerun

- 현재 checkout의 arm64e macOS host에서 TaptionPlanCore 90/90, TaptionActivityEngine 28/28, TaptionRouteEngine 38/38, TaptionPlanEngine 1/1 통과(157/157, 각 명령 exit 0). 별도 result bundle/log는 생성하지 않았다.

## 2026-09-22 RAW0921C01 / CRW0921R01 · raw restore byte budget

- `SecurityBackupCoreTests.testRawRestoreSharesByteBudgetAndDoesNotReadNextArchiveWhenExceeded`와 `testRawRestoreAccountKeyFallbackReusesLoadedArchiveAndByteBudget`를 iOS 26.5 iPhone 17 Pro Simulator에서 기존 현재 Debug 제품으로 재실행했다. 2/2 통과, 실패·스킵·runtime warning 0, exit 0: `build/validation/RAW0921C01-CRW0921R01-focused-retry2.xcresult`.
- 첫 실행은 SpringBoard preflight `Busy`로 test body 전 종료됐다. 전용 validation Simulator를 완전히 boot한 뒤 재실행했고 두 테스트가 모두 실행·통과했다.

## 2026-09-22 RSD0922A01 / RSI0922A01 · legacy archive cancellation and route signature

- Legacy `generationID == nil` raw save가 병합된 월 archive를 기록한 직후 취소되면 공용 cancellation 처리에서 경로를 삭제하던 동작을 고쳤다. staged generation만 삭제하고 legacy 월 파일은 유지한다. 새 regression은 첫 표본 저장 후 두 번째 병합 저장 직후 취소시키고 저장된 archive를 직접 decode해 두 표본이 모두 남는지 확인한다.
- `latestRouteInputSignature`가 `trackingSessionEnded` 상태를 반영하도록 하고, `true`와 `false`/`nil` 경계를 검증했다.
- 최종 iOS 26.5 iPhone 17 Pro Simulator Debug/XCTest `RSD0922A01-current-final.xcresult`: 3/3 통과, 실패·스킵·runtime warning 0, exit 0. 포함: legacy merged-save cancellation, staged-generation cancellation, route session-end signature.
- 첫 시도 `RSD0922A01-focused-current.xcresult`는 2/3 통과; 새 테스트가 snapshot을 seed하지 않은 채 snapshot restore API를 호출해 `archiveNotFound`로 실패했다. fixture를 직접 raw-store readback으로 바꾼 뒤 최종 3/3 재실행이 통과했다. 첫 실패 결과의 자동 simulator 진단은 600초 뒤 timeout됐다.

## 2026-09-22 DHV0922B01 · 최신 checkout Device Hub 실기기 검증

- iPhone 14 Pro/iOS 27.2용 signed Debug 빌드 첫 시도는 Swift 컴파일 중 디스크 부족(`No space left on device`)으로 종료됐다. Plan 전용 재생성 가능 Xcode 캐시를 확인·정리한 뒤 인덱싱을 끄고 재시도해 빌드 exit 0: `build/validation/DHV0922B01/device-debug-build.log`, `device-debug-build-retry.log`.
- 동일 bundle/team의 `com.taption.plan` 1.0(149)을 앱 삭제·데이터 초기화 없이 교체 설치하고 foreground launch했다. 설치 readback은 `device-install.json`; 입력 검증 뒤 process readback에서 app PID 1914와 widget PID 1915/1920이 계속 실행 중이었다 (`device-processes-after-playback.json`). 앱 컨테이너 UUID는 교체됐지만 App Group 경로는 동일하다. 새 컨테이너에 기존 `RawData/2026-08` 및 28.3MB `Sensors/sensor-readings-v1.jsonl`가 확인돼 일부 저장 자료 연속성은 readback했다. 이는 모든 app-private 데이터의 완전 보존 증명은 아니다.
- Device Hub 직접 입력으로 최신 소스 화면 날짜 9/22→9/23→9/22 왕복을 확인했다: `devicehub-latest-date-forward.jpg`, `devicehub-latest-date-restored.jpg`. 최종 화면은 9/22·재생 정지(Play)이며 `devicehub-latest-source-final-stopped.jpg`에 저장했다. CUA 초기화는 `failed to write kernel assets`로 실패해 CoreGraphics 포인터 이벤트와 Device Hub 캡처를 사용했다.
- Device Hub 타임라인 드래그로 오늘의 선택 시각을 00:06으로 이동하고, Play 뒤 Pause 아이콘과 00:34 진행을 캡처했다 (`devicehub-latest-timeline-start-0006.jpg`, `devicehub-latest-play-active-after-500ms.jpg`). 이후 현재 날짜의 재생 종료점 부근 05:11에서 Play 아이콘으로 돌아왔고, 2초 뒤 05:12에도 정지 상태가 유지됐다 (`devicehub-latest-play-pause-third.jpg`, `devicehub-latest-play-stable-after-pause.jpg`). 이는 재생 진행과 현재 날짜 끝의 자동 종료 증거다. 수동 Pause 입력으로 안정 정지됐다고 판정할 수는 없어 해당 부분은 미완료다.
- 06:04–06:09 KST 후속 검증: 과거 날짜 9/21에서 Device Hub Play가 04:39에 Pause 아이콘으로 진행됨을 확인하고, 수동 Pause 뒤 18:51에서 Play 아이콘으로 전환됐다. 추가 2.5초 readback에서도 18:51로 고정됐다 (`devicehub-window-play-coordinate-retest.jpg`, `devicehub-window-manual-pause-r2.jpg`, `devicehub-window-manual-pause-stable-r2-plus2s.jpg`). Pause 상태에서 재생을 재개해 23:45 진행을 확인했고, 1.5초 뒤 23:59에서 자동 정지됐다 (`devicehub-window-resume-retest-r2.jpg`, `devicehub-window-resumed-endpoint.jpg`). 종료 후 날짜를 9/22로 복원하고 06:08·Play(정지) 상태를 확인했다 (`devicehub-window-date-restored-r2.jpg`). 앱 1.0(149), app PID 1914·widget PID 1915/1920 readback: `device-app-after-manual-pause.json`, `device-processes-after-manual-pause.json`. CUA 초기화 오류는 계속됐으나 Device Hub 창에 CoreGraphics 입력을 사용했으며 앱 삭제·데이터 초기화·UI Automation 승인은 하지 않았다.
- 오늘 날짜의 재생 종료 시각은 코드상 현재 시각으로 제한된다. 따라서 기본값(현재 시각)에서의 짧은 시도는 곧바로 종료될 수 있다. 장시간 CPU soak, post-fix OS log readback, 9/20 file-lock 동일 workload 재현은 별도 미완료다.

## 2026-09-22 RCP0922A01 · expected-route cancellation

- readings/travel 필터링과 세션·확정구간·인접 이동 인덱스 구축을 256항목 주기로 취소 확인하도록 바꾸고, 정렬에는 취소 가능한 병합 정렬을 적용했다. 후보 병합 및 RouteSample 변환도 취소를 전파한다.
- iOS 26.5 iPhone 17 Pro Simulator에서 focused 취소 회귀 1/1, `RouteTimelineDataTests` 92/92 통과; 실패·스킵 0: `build/DerivedData-Verify/Logs/Test/Test-TaptionPlan-2026.09.22_05-31-26-+0900.xcresult`, `build/DerivedData-Verify/Logs/Test/Test-TaptionPlan-2026.09.22_05-33-10-+0900.xcresult`.

## 2026-09-22 RIP0922A01 · printable-ASCII prefix boundary

- `latestRawEvent(idPrefix:)`가 printable ASCII 최대값 `~`(0x7e)를 받아들이고 SQLite BINARY upper bound에 다음 바이트 `0x7f`를 쓰도록 수정했다. `~` ID 조회 회귀를 추가했다.
- TaptionPlanCore 92/92 테스트 통과; 실패·스킵 0. `git diff --check` 통과.

## 2026-09-22 RDM0922A01 · byte-exact domain replacement

- NFC/NFD처럼 canonical equivalent지만 UTF-8 바이트가 다른 도메인을 처리하도록 `exactDomains: [String]` API를 추가했다. 기존 `Set<String>` overload는 호환 유지한다.
- 두 byte-distinct 도메인을 동시에 replace하는 회귀 포함 TaptionPlanCore 92/92 통과; 실패·스킵 0.

## 2026-09-22 WSD0922A01 · durable Watch fallback spool

- summary/chunk은 SQLite 저장 뒤 `transferUserInfo` 예약 성공 항목만 fallback spool에서 제거하며, Health snapshot도 같은 scheduled-only 계약을 쓴다. transfer 예약 이전이나 취소/purge 시 queue를 보존한다.
- iOS 26.5 iPhone 17 Pro Simulator의 spool·Health·purge-cancel 회귀 3/3 통과: `build/DerivedData-Verify/Logs/Test/Test-TaptionPlan-2026.09.22_05-37-36-+0900.xcresult`. durable codec을 통한 새 프로세스 복원·미예약 항목 보존·재직렬화를 포함한 복구 회귀 5/5도 통과했다: `build/validation/REV0922C01-watch-recovery-tests.xcresult`. 강제 종료 뒤 실제 paired Watch 재전송은 아직 검증하지 않았다.

## 2026-09-22 WSQ0922A01 · no-database direct flush

- `dayDatabase == nil`인 summary/chunk 전송은 fallback spool 기록 후, reliable transfer 예약 성공에 한해 해당 항목을 commit/persist하도록 수정했다. 실패·취소 시 보존한다.
- 두 번 연속 flush에서 같은 summary/chunk가 중복 예약되지 않는 policy 회귀 1/1 통과: `build/DerivedData-Verify/Logs/Test/Test-TaptionPlan-2026.09.22_05-44-40-+0900.xcresult`. `TaptionPlanWatch` watchOS Simulator Debug build exit 0.

## 2026-09-22 WPF0922A01 · purge failure and ambient outbox retry

- purge 실패 뒤 `flushPendingAmbientOutbox`를 다시 호출하며, outbox read가 실패하고 추적 중인 ID도 없으면 generic retry sentinel을 예약한다.
- pending outbox 재시도와 read-failure policy 2/2 통과: `build/DerivedData-Verify/Logs/Test/Test-TaptionPlan-2026.09.22_05-39-31-+0900.xcresult`; DB purge failure 보존 1/1 통과: `build/DerivedData-Verify/Logs/Test/Test-TaptionPlan-2026.09.22_05-47-34-+0900.xcresult`. purge 실패 직후 outbox read 실패가 이어지는 결합 회귀를 포함한 복구 테스트 5/5 통과, 실패·스킵·runtime warning 0: `build/validation/REV0922C01-watch-recovery-tests.xcresult`.

## 2026-09-22 AVD0922A01 · iOS 27 SDK 음성 메모 delegate 경고 제거

- iOS 27 SDK에서 효과가 없다고 진단되는 `@preconcurrency AVAudioPlayerDelegate` attribute만 제거했다. 음성 메모 재생·종료 delegate 계약은 변경하지 않았다.
- iPhoneOS 27.0 SDK의 iPhone 14 Pro 서명 Debug 빌드 성공, warning/error 0: `build/validation/AVD0922A01/iphone27-debug-build.log`.
- iPhone 14 Pro/iOS 27.2(24B5089g)에 1.0(149)을 데이터 삭제 없이 재설치·실행했고, 15초 뒤 앱 PID 913·위젯 PID 915 유지: `build/validation/AVD0922A01/iphone27-install.json`, `iphone27-launch.json`, `iphone27-app-readback.json`, `iphone27-process-readback-stable.json`, `iphone27-device-details.json`.

## 2026-09-22 TRN0921C01 · MapKit 교통 앵커 iOS 27.2 실기기 검증

- 지하철·버스 컨텍스트의 종류별 전파 거리 상한 수정본을 iPhone 14 Pro/iOS 27.2(24B5089g)에서 실제 MapKit 검색으로 검증했다.
- 마곡나루→검암→가정 경로가 지하철로 확정되고 transfer station이 보존되는 통합 테스트 1/1 통과, 실패·스킵·runtime warning 0: `build/validation/TRN0921C01-mapkit-iphone27.xcresult`.

## 2026-09-22 MPR0921C01 · 재생 actual index 캐시와 iOS 27 성능

- 10,000개 자동 기록을 재생 틱마다 다시 정렬하던 경로의 iPhone 14 Pro/iOS 27.2 baseline p95는 882.187ms로 250ms 갱신 예산을 초과했다: `build/validation/MPR0921C01-actual-index-iphone27.xcresult`.
- 날짜별 `RouteTimelineDataEngine.ActualIndex`를 1회 생성하고 actual/day 변경 시에만 무효화하도록 리팩터링했다. 기존 직접 계산과 7개 cutoff 결과 동등성 통과.
- 수정 후 p95 25.023ms, 4회 갱신 CPU 평균 0.101초(약 25ms/회), 표준편차 0.074%로 개선됐고 집중 테스트 2/2 통과: `build/validation/MPR0921C01-actual-index-iphone27-r5.xcresult`.
- 같은 iPhone 14 Pro/iOS 27.2에서 `RouteTimelineDataTests` 전체 94/94 통과, 실패·스킵·runtime warning 0: `build/validation/MPR0921C01-route-timeline-full-iphone27.xcresult`.
- 최신 1.0(149)을 데이터 삭제 없이 재설치·실행했고 앱 PID 1005·위젯 PID 1006 및 지도·시간표·재생 UI를 기기 직접 캡처로 확인했다: `build/validation/MPR0921C01-final-install.json`, `MPR0921C01-final-launch.json`, `MPR0921C01-final-processes.json`, `MPR0921C01-final-screen.png`.

## 2026-09-22 IPD905G001 · iPadOS 27.0 최신 checkout 기동 검증

- iPad Pro 12.9-inch 6세대/iPadOS 27.0(24A437) 대상 iPhoneOS 27.0 SDK 서명 Debug 빌드 성공, warning/error 0: `build/validation/IPD905G001/ipad27-debug-build.log`.
- 데이터가 없던 기기에 1.0(149)을 설치·전면 실행했고 앱 PID 3037·위젯 PID 3042가 18초 이상 유지됐다: `build/validation/IPD905G001/ipad27-install.json`, `ipad27-launch.json`, `ipad27-app-readback.json`, `ipad27-process-stable.json`.
- 실제 화면은 첫 실행 동작·피트니스 권한 선택 단계까지 정상 표시됐다: `build/validation/IPD905G001/ipad27-screen.png`. 개인정보 권한은 임의 선택하지 않았으므로 이후 pinch/날짜/재생/VoiceOver 및 TestFlight 설치 provenance는 별도 미검증이다.

## 2026-09-22 HKD0921B01 · HealthKit delete/history serialization

- `deleteAll`, full-history sync, change sync, sample-change sync가 같은 `HealthKitSynchronizationGate`를 사용함을 소스에서 확인했다. history page를 latch로 보류한 동안 delete 완료를 막고, page release 후 delete가 완료되며 로컬 store가 비어 있음을 회귀로 검증했다.
- iOS 26.5 iPhone 17 Pro Simulator의 직렬화 및 delete/history 회귀 2/2 통과, 실패·스킵·runtime warning 0: `build/validation/HKD0921B01/healthkit-gate-regression.xcresult`.
- `HealthKitIntegrationTests` 전체 29/29 통과, 실패·스킵·runtime warning 0: `build/validation/HKD0921B01/healthkit-integration-final.xcresult`. 구버전 root `Date` plist fixture를 유효한 binary plist로 고친 뒤 cursor 왕복 단독 테스트도 1/1 통과했다: `build/validation/HKD0921B01/healthkit-cursor-fixed.xcresult`.

## 2026-09-22 WPI0921B01 · Watch workout purge intent confirmation

- `testLockedFinishWithoutSampleKeepsPurgeIntentUntilDeletionIsConfirmed` iOS 26.5 iPhone 17 Pro Simulator 1/1 통과, 실패·스킵 0: `build/validation/WPI0921B01/watch-purge-intent-final.xcresult`. mock reconciliation에서 0건 삭제 후 대상이 남으면 purge intent를 보존하고, 없음을 확인한 뒤에만 완료하며, 양수 삭제는 즉시 완료하는 경로를 검증했다. 실제 Watch/HealthKit 삭제 런타임은 별도 미검증이다.

## 2026-09-22 WOF0922R01 · ambient outbox flush와 purge 경합

- 비동기 `pendingAmbientOutbox` 조회가 purge와 겹칠 때, purge 진입 generation을 증가시키고 in-flight flush를 취소·대기한다. 조회 완료 뒤와 각 `transferUserInfo` 직전에 generation·purge·취소 상태를 다시 확인해 삭제된 outbox가 재전송되지 않게 했다.
- `testAmbientOutboxFlushGenerationRejectsResultsAfterPurge`를 포함한 `WatchSensorQueryPlanTests` 45/45 통과, 실패·스킵 0: `build/validation/WOFWFF0922A01/watch-regressions-r2.xcresult`. 실제 paired Watch transfer 런타임은 별도 미검증이다.

## 2026-09-22 WFF0922R01 · finishWorkout 모호한 오류의 purge intent 보존

- `finishWorkout()`이 저장 후 오류를 반환할 수 있으므로 `.finishing`을 `.failedMayHavePersisted`로 전환하고 생성된 purge UUID를 durable intent에 enqueue한다. pending workout 정리도 저장 가능 상태에서는 intent를 삭제하지 않고, HealthKit 삭제 확인에서만 제거한다.
- 같은 `WatchSensorQueryPlanTests` 45/45 실행에서 새 finish-state 회귀가 통과했고, watchOS Simulator Debug generic build도 exit 0이다. 실제 저장 후 throw 및 paired Watch HealthKit 삭제 callback은 런타임 미검증이다.

## 2026-09-22 REV0921A01 · Activity/Route adapter integration

- Current iOS app integration XCTest for `RouteTimelineDataTests`, `TaptionActivityEngineAdapterTests`, and `TaptionRouteEngineAdapterTests` passed 132/132 on iOS 26.5 iPhone 17 Pro Simulator; failures, skips, and runtime warnings are 0: `build/validation/REV0921A01/adapters-route-current-r2.xcresult`.
- The run covers the cancellation-aware Activity evidence/quality scans, route adapter cancellation-aware merge, playback lower-bound lookup, and route timeline projection. MapKit/device-only behavior, raw-restore integration, Plan-day rollback, and paired Watch runtime remain separate gates.

## 2026-09-22 REV0921A01 · restore/Watch summary/Plan-day follow-up

- Current restore, raw-budget, Plan-day rollback, and Watch summary redelivery focused tests passed 22/22 with no failures, skips, or runtime warnings: `build/validation/REV0921A01/restore-watch-current.xcresult`.
- The stale/non-final Watch fallback boundary passed separately 1/1: `build/validation/REV0921A01/watch-stale-summary-current.xcresult`.

## 2026-09-22 REV0922A01 · storage concurrency follow-up

- TaptionPlanCore full suite passed 94/94, failures 0, including materialized replacement CAS and same-key LRU single-flight/late-result regressions. The SwiftPM run used `build/validation/REV0922A01/PlanCore-current`.
- Current iOS Debug build-for-testing succeeded; the four focused Plan-day/migration regressions passed 4/4 with no failures, skips, or runtime warnings: `build/validation/REV0922A01/bug-fixes-current-r2.xcresult`. The migration case confirms a failed primary save is retried on the next load in the same process.

## 2026-09-22 MIG0921B01 · INI0921B01 · RCE0921B01 · GEO0921B01 · WAM0921B01 focused regression

- iOS 26.5 iPhone 17 Pro Simulator 4/4 통과, 실패·스킵·runtime warning 0: `build/validation/REG0922A01/ios-regression-gates.xcresult`. 검증 항목은 자정·revision 경계 Watch ambient migration 멱등성, corrupt-row 정리와 동시 repair 보존, 경로 준비 signature의 정확도/GPS/quality 경계, 30분 조회 창 뒤 overlap sample-date ledger 상한이다.
- TaptionPlanCore의 `testConcurrentColdOpensInitializeOneV3Schema` 1/1 통과(SwiftPM 출력, 별도 xcresult 없음). 같은 DB URL 동시 cold-open schema 초기화를 확인했다.

## 2026-09-22 HPT0922A01 · backup diagnostics launch hang

- iPhone 14 Pro build 149의 9/21 HangTracer에서 launch 중 `AppModel.cloudBackupPayload` → `TaptionPlanDiagnosticsLogger.combinedLog` → 개인 건강 필드 JSON redaction이 main runloop를 586ms 점유한 것을 확인했다. 기존 30초 watchdog 및 9/22 현재 binary의 재현과는 구분한다.
- 진단 로그 읽기/redaction과 cloud backup payload 구성을 utility detached task로 옮겼다. `DiagnosticsLogSupportTests` 10/10 통과, 실패·스킵·runtime warning 0: `build/validation/HPT0922A01/DiagnosticsLogSupport-final.xcresult`. 처음에는 민감값 `420`의 임의 부분문자열을 검사해 실패했다. 정확한 `sleep_minutes:420` JSON field 검사로 수정한 뒤 focused 1/1과 전체 클래스 10/10이 통과했다.
- generic iOS Debug build exit 0; 기존 `AppleIntegrations.swift:4494` `@preconcurrency` warning만 확인했다. Device Hub의 날짜/재생 동작은 최신 기록 DHV0922B01에서 통과했으나, 이 offload 변경 후 재설치나 새 OS-log readback은 하지 않았다. CUA 재초기화는 `failed to write kernel assets`였다. TestFlight 업로드는 하지 않았다.

## 2026-09-22 I27A092201 · WBS 항공 판정·iOS 27.2 실기기 readback

- Taption WBS의 공항 endpoint 우선 규칙과 항공 중 GPS 공백 fallback을 `MovementRouteBuilder`에 적용했다. 기존 센서 원본은 수정하지 않고, 공항 메타데이터·`nearAirport` 보강값으로 파생 `TravelSegment`만 비행기로 생성한다. 항구 endpoint는 WBS 우선순위대로 배로 남긴다.
- iOS 27.0 SDK focused 회귀 2/2 통과, 실패·스킵 0: `build/validation/I27A092201/ios27-wbs-tests-final.xcresult`. 검증은 공항 endpoint만 있고 비행 GPS가 없는 ICN→BKK 좌표와 항구 우선순위를 포함한다.
- iPhone 14 Pro/iOS 27.2에 signed Debug 1.0 (149)을 데이터 삭제·앱 삭제 없이 설치·실행했다. 최종 build/sign/install/launch 증거: `build/validation/I27A092201/iphone14-debug-build-final.log`, `iphone14-install-final.json`, `iphone14-launch-final.json`.
- Device Hub에서 9월 9일로 이동해 09:20–15:43 행동 구간을 `자동차`에서 `비행기`로 저장했다. 최종 재설치 뒤에도 9월 9일과 동일 구간 `비행기`가 readback됐다: `build/validation/I27A092201/devicehub-final-selected10.png`, `devicehub-final-editor-readback.png`.
- CUA는 계속 `failed to write kernel assets`였지만 Device Hub 직접 입력은 CoreGraphics 이벤트로 수행했다. 원본 센서·백업 파일은 변경하지 않았고, TestFlight 업로드는 하지 않았다.

## 2026-09-22 DHV0922C01 · 최신 checkout 재생 끝점·수동 정지 실기기 검증

- 최신 설치본의 9월 9일 23:59에서 Play를 누르면 00:00으로 순환하는 결함을 재현했다. 원인은 `startDayPlayback()`이 과거 날짜의 정상적인 1,440분 끝점 선택을 0분으로 먼저 덮어쓰는 중복 초기화였다. 해당 덮어쓰기를 제거하고 과거 날짜 끝점은 `playbackStartMinute`의 1,440분을 유지하도록 했다.
- iOS 27.0 SDK 전용 회귀 2/2 통과, 실패·스킵 0: `build/validation/DHV0922C01/playback-endpoint-tests.xcresult`. signed Debug build도 성공했고, iPhone 14 Pro/iOS 27.2에 앱 삭제·데이터 삭제 없이 1.0 (149)을 교체 설치·실행했다: `iphone14-debug-build.log`, `iphone14-install.json`, `iphone14-launch.json`.
- 최신 설치본 Device Hub에서 9월 9일 → 9월 10일 → 9월 9일 날짜 왕복을 확인했다: `date-forward-final.png`, `date-return-final.png`.
- 9월 9일 timeline 재생 뒤 10:07에서 수동 Pause를 누르고 2초 후에도 시간과 Play 아이콘이 그대로인 것을 확인했다: `manual-pause-confirmed.png`, `manual-pause-confirmed-stable.png`.
- 23:55에서 재생한 뒤 23:59에 자동 정지하고 2초 후에도 23:59·Play 상태를 유지해 00:00 순환이 사라진 것을 확인했다: `endpoint-selected-final.png`, `endpoint-auto-stop-final.png`, `endpoint-auto-stop-final-stable.png`.
- CoreDevice readback은 `com.taption.plan` 1.0 (149), 앱 PID 852와 widget PID 851/853을 확인했다. 이 최신 checkout 검증으로 기존 `DHR0921A01`, `DVI0921B01`, `PLB0921C01`, `DHV0922C01` Device Hub 재생 게이트를 닫았다. CUA는 계속 `failed to write kernel assets`여서 직접 입력을 사용했다.

## 2026-09-22 REV0922C01 · 분류 정렬·MapKit·migration 통합 회귀

- 분류 커밋 순서를 `ActivityClassificationRecordOrdering`으로 한곳에 모으고 시작 시각 다음 UUID exact 순서를 검증했다. 날짜선 viewport, 장기 actual migration range, 날짜 증가 실패/비진행/범위 초과, 지하철 450m·버스 140m 반경, MapKit 지하철 여정 보강과 도로 endpoint 오탐 방지까지 iOS 27.0 SDK focused 7/7 통과했다: `build/validation/REV0922C01-app-map-migration-tests.xcresult`.
- 컴파일에서 확인된 테스트 코드 경고 3건을 제거했다. 안정 정렬의 불필요한 `try`, purge 상태의 변경 가능한 sendable capture, Watch summary observer model의 불명확한 수명을 각각 정리했고 관련 회귀 3/3 통과·runtime warning 0: `build/validation/REV0922C01-warning-regressions.xcresult`.
- 같은 checkout의 TaptionPlanCore 92/92 통과 기록과 `DHV0922C01/iphone14-debug-build.log`의 signed iOS 27.2 실기기 Debug 빌드로 byte-exact ID, migration marker NUL 거부, map-cache UTF-8 identity, atomic revision 저장의 package·앱 링크 경계를 확인했다. 이 증거로 `APP0921C01`, `MAP0921C01`, `IDS0921R01`, `MRK0921C01`, `MCK0921C01`, `MCR0921C01`, `MDR0921C01`을 닫았다. 교통 anchor의 실제 iPhone MapKit readback은 `TRN0921C01`에 남긴다.

## 2026-09-22 CPU0922A01 · iOS 27.2 CPU report 원인 대조와 최신 소스 readback

- 새로 확인한 `TaptionPlan.cpu_resource-2026-09-22-080234.ips`는 08:00:59–08:02:31 KST, 전면 앱 90 CPU초/92초(98%)다. loader UUID `2F36B41C-34A7-3E71-A53B-B117730689BE`가 로컬 Debug loader와 일치하고, 시작 시각이 Device Hub의 9/9 재실행과 정확히 겹친다. 08:01 캡처의 `Taption Plan 645 ms` microhang도 같은 세션이다: `build/validation/BUG1909R01/postfix-readback-20260922/`.
- 이 보고서는 actual index 수정 전 실행이다. 같은 iPhone 14 Pro/iOS 27.2의 10,000 actual baseline p95 882.187ms는 수정 후 25.023ms로 감소했고 전체 `RouteTimelineDataTests` 94/94가 통과했다: `build/validation/MPR0921C01-actual-index-iphone27.xcresult`, `MPR0921C01-actual-index-iphone27-r5.xcresult`, `MPR0921C01-route-timeline-full-iphone27.xcresult`.
- 최신 수정본 재설치 뒤 180초 동안 앱이 생존했고 새 TaptionPlan CPU/Hang report가 생기지 않았다. 11:10 KST 추가 readback에서도 앱 PID 1217·위젯 PID 1218이 실행 중이고 목록에는 기존 9/21 HangTracer와 08:02 CPU report만 있다: `build/validation/BUG1909R01/postfix-soak-20260922/processes-latest.json`, `system-crash-logs-latest.json`.
- `xctrace` 장시간 기록은 iOS 27 recording channel disconnect와 Xcode 내부 assertion으로 유효한 장시간 trace를 만들지 못했다. 따라서 180초 생존·신규 OS report 없음까지만 통과로 기록하고, 정확한 9/9 장시간 재생 CPU soak와 9/20 file-lock 동일 workload 재현은 미완료로 유지한다.

## 2026-09-22 STO0922D01 · 영구 저장소 fail-closed 회귀

- app-group SQLite가 정상이고 legacy 파일 저장소가 없어도 SQLite를 유지하는 경로, SQLite가 모두 실패하면 durable 파일 저장소를 사용하는 경로, durable 저장소가 전부 실패하면 메모리 저장 대신 load/save/delete가 모두 실패하는 경로를 검증했다.
- iPhone 17 Pro/iOS 26.5 Simulator 3/3 통과, 실패·스킵·runtime warning 0: `build/validation/STO0922D01-repository-failclosed-r2.xcresult`. build error/warning/analyzer warning도 0이다.
- 첫 결과 `build/validation/STO0922D01-repository-failclosed.xcresult`는 제품 결함이 아니라 신규 테스트의 async autoclosure와 존재하지 않는 fixture 필드 컴파일 오류로 실패했으며, 테스트만 바로잡아 최종 결과를 다시 생성했다.

## 2026-09-22 RPF0922D01 · DLF0922D01 · 백업 삭제-fence 회귀

- restore preparation-fence 중복 제거, 삭제 generation 전진 뒤 legacy raw stale write 제거, snapshot commit 직전 삭제 시 staged raw 정리를 함께 검증했다. 관련 5/5 통과: `build/validation/RPF0922D01/security-backup-focused-r4.xcresult`.
- iPhone 17 Pro/iOS 26.5 Simulator `SecurityBackupCoreTests` 직렬 97/97 통과, 실패·스킵·runtime warning 0: `build/validation/RPF0922D01/security-backup-full-serial-r5.xcresult`. focused 재빌드 error/warning/analyzer warning도 0이다.
- 같은 checkout의 iPhoneOS 27.0 SDK generic iOS Debug 빌드·서명과 embedded iPhone/Watch/widget 검증 통과, error/warning/analyzer warning 0: `build/validation/REV0922D01/current-ios27-device-build.xcresult`.
- 최초 병렬 전체 실행은 삭제-fence 두 회귀를 실제로 검출했고, 첫 focused 재실행은 Simulator `Busy`로 러너가 시작되지 않았다. 대상 시뮬레이터 재부팅 뒤 직렬 재현·수정·전체 통과 결과만 최종 근거로 사용한다.

## 2026-09-22 STF0922D02 · 저장소 load 실패 후 편집 fail-closed

- `UnavailablePlanRepository`로 bootstrap load 실패를 주입한 뒤 계획 추가와 설정 변경이 fallback snapshot 및 revision을 바꾸지 않고 사용자 오류를 유지하는 단독 회귀 1/1 통과: `build/validation/STF0922D02-repository-load-failclosed-r2.xcresult`.
- 기존 저장 취소·실패·호출자 취소 회귀를 함께 실행해 4/4 통과, 실패·스킵·runtime warning 0: `build/validation/STF0922D02-repository-load-failclosed-regression-r3.xcresult`.
- 최초 단순 didSet 재할당 구현은 `@Observable` 재귀로 SIGSEGV가 발생했다: `build/validation/STF0922D02-repository-load-failclosed.xcresult`. 복원 guard를 추가한 최종 구현에서 재발하지 않았다.
- iPhoneOS 27.0 SDK generic iOS Debug 빌드·서명·embedded iPhone/Watch/widget 검증 성공, error/warning/analyzer warning 0: `build/validation/STF0922D02-current-ios27-device-build.xcresult`. 물리 기기의 저장소 장애 주입은 별도 미검증이다.

## 2026-09-22 SRA0922D03 · PDR0922D04 · WSG0922D05 전체 회귀 안정화

- 최초 전체 회귀 `build/validation/STF0922D02-full-app-r4.xcresult`는 XCTest 1,262개 중 센서 분석 5건, Plan-day 동시 복구 1건, Watch 재시작 1건의 assertion failure를 검출했다. focused 재현으로 제품 동작이 아니라 현재 실행·잠금·삭제-fence 계약과 어긋난 테스트 전제임을 확인했다.
- 센서 분석은 active scene과 초기 foreground 정착을 명시하고 archive-read loader로 결정적 읽기 실패를 주입했다. Plan-day는 write lock 해제 전 설치된 valid row 반환을 기대하도록 고쳤다. 관련 focused 5/5 통과: `build/validation/SRA0922D03-focused-r1.xcresult`.
- 첫 전체 재실행 `build/validation/SRA0922D03-full-app-r2.xcresult`에서 Watch 재시작 1건만 남았고, deletion cutoff를 fixture로 격리한 뒤 동일 테스트 반복 5/5 통과: `build/validation/WSG0922D05-watch-gate-r2.xcresult`.
- 최종 전체 앱 회귀 `build/validation/SRA0922D03-full-app-r3.xcresult`는 총 1,302개 중 1,301 PASS·기존 StoreKit 1 SKIP·0 FAIL·runtime warning 0이다.
- 최종 iPhoneOS 27.0 SDK generic iOS Debug 빌드·서명·embedded iPhone/Watch/widget 검증 통과, error/warning/analyzer warning 0: `build/validation/SRA0922D03-current-ios27-device-build.xcresult`. 실패 주입 회귀 수정이라 물리 기기 설치는 수행하지 않았다.

## 2026-09-22 IOS0922D06 · 최신 checkout iOS 27.2 Device Hub smoke

- 산출물 readback: `DTSDKName=iphoneos27.0`, `DTXcode=2700`, `MinimumOSVersion=18.0`, bundle `com.taption.plan` 1.0 (149), Apple Development 서명. generic device build는 `build/validation/SRA0922D03-current-ios27-device-build.xcresult`의 error/warning/analyzer warning 0 결과를 사용했다.
- 물리 iPhone 14 Pro는 iOS 27.2 (24B5089g), connected·paired·Developer Mode enabled 상태였다. 다른 Taption 프로젝트가 `/tmp/.taption-build.lock`을 소유해 재빌드하지 않고 12:28 생성된 현재 checkout 산출물을 사용했다.
- 앱·사용자 데이터를 삭제하지 않고 설치 성공: `build/validation/IOS0922D06/device-install.json`. foreground launch 성공: `device-launch.json`.
- launch 15초와 45초 뒤 앱 PID 1698·widget PID 1699가 동일하게 유지됐다: `device-process-readback.json`, `device-process-readback-45s.json`. 두 시점 모두 지도·9월 22일·시간축·날씨·재생 UI가 오류 팝업 없이 렌더링됐다: `device-after-15s.png`, `device-after-45s.png`.
- 9월 9일 인천국제공항→수완나품 항공 분류와 저장 지속성은 같은 코드의 선행 `I27A092201` Device Hub readback 및 iOS 27 focused 2/2로 검증돼 있다. 이번 smoke에서 해당 날짜 터치 동작은 반복하지 않았고 TestFlight 업로드도 하지 않았다.

## 2026-09-22 REV0922E01 · iOS 27 정적 분석·Swift Package 재검증

- 최신 소스 iPhone 17 Pro/iOS 26.5 Simulator 전체 XCTest 재검증은 1,344 PASS·기존 StoreKit 1 SKIP·0 FAIL·runtime warning 0: `build/validation/REV0922E01/full-app-r1.xcresult`.
- `xcodebuild analyze`, generic iOS, iPhoneOS 27.0 SDK: 성공·error 0·analyzer warning 0. 결과: `build/validation/REV0922E01/ios27-static-analyze.xcresult`, 로그: `ios27-static-analyze.log`.
- 최근 변경분까지 포함한 재실행도 `** ANALYZE SUCCEEDED **`이며 error 0, analyzer warning 0이다. 결과: `build/validation/REV0922E01/ios27-static-analyze-r2.xcresult`, 로그: `ios27-static-analyze-r2.log`.
- warning 1건은 `/Applications/Xcode.app/.../StoreKitTest.framework/Headers/SKTestTransaction.h`의 Apple SDK 내부 deprecated 선언이며 Taption Plan 소스 위치가 아니다.
- SwiftPM 현재 소스 재실행: TaptionPlanCore 94/94, TaptionActivityEngine 33/33, TaptionRouteEngine 38/38, TaptionPlanEngine 1/1 PASS·실패 0. 기존 증거 로그는 Core 94/94, Activity 28/28, Route 38/38, PlanEngine 1/1을 보존하고, 앱 전체 XCTest가 최신 package 통합 컴파일·실행을 함께 확인한다.
- DAY0920A01 후속: `TaptionPlanDayKey`에 고정폭 저장 키 파서와 calendar-neutral 저장 범위(year 1...9999, month 1...13, day 1...31)를 추가하고, DayStore/V3의 모든 SQLite read/write·raw/materialized 경계에서 invalid day를 거부하도록 보강했다. sentinel `(0,0,0)`, 음수·비정규 키·10000년 키 회귀를 포함한 TaptionPlanCore 97/97 PASS: `build/validation/REV0922E01/PlanCore-day-r1.log`.
- 새 DAY 패치가 포함된 전체 앱 XCTest 재실행 `build/validation/REV0922E01/full-app-r2.xcresult`은 앱 호스트가 실행된 뒤 XCTest waiter에서 약 9분 집계 없이 정지해 중단했으며 유효한 통과 결과로 계산하지 않는다. 패치 전 최신 전체 앱 결과 `full-app-r1.xcresult`와 새 Core 97/97로 범위를 분리했고, 같은 시각 WBS build lock이 연속 점유되어 새 generic iOS build는 시작하지 않았다.
- `scripts/check-app-engine-import-boundary.sh` PASS, `git diff --check` PASS. 이 자동 검증은 paired Watch·실제 HealthKit 삭제·iCloud 동시 기기 충돌이나 설계 선택 대기 항목을 대체하지 않는다.

## 2026-09-22 RRL0922E02 · repository load 실패 복구 회귀

- `UnavailablePlanRepository` 실패 중 fallback snapshot·revision이 유지되고 계획 추가가 `nil`을 반환하는 fail-closed 회귀와, 첫 load만 실패한 repository가 두 번째 bootstrap에서 저장 snapshot을 복원하고 편집을 다시 허용하는 회귀 2/2 PASS: `build/validation/RRL0922E02/repository-retry-r1.xcresult`.
- 저장 취소, 호출자 취소 뒤 accepted edit, 동시 편집 최신 snapshot, 센서 로컬 저장 실패를 함께 실행해 6/6 PASS·실패/스킵/runtime warning 0: `build/validation/RRL0922E02/repository-persistence-regression-r2.xcresult`.
- 전체 앱 회귀 총 1,303개 중 1,302 PASS·기존 StoreKit 1 SKIP·0 FAIL·runtime warning 0, build error/warning/analyzer warning 0: `build/validation/RRL0922E02/full-app-r3.xcresult`.
- iPhoneOS 27.0 SDK generic device Debug build·서명·embedded Watch/widget 검증 PASS, error/warning/analyzer warning 0: `build/validation/RRL0922E02/current-ios27-device-build-r4.xcresult`. 실제 파일 보호 오류를 물리 기기에서 강제로 주입하지는 않았다.
- 최신 Debug 1.0 (149)을 iPhone 14 Pro/iOS 27.2에 앱·사용자 데이터 삭제 없이 설치하고 foreground launch했다. 15초 뒤 앱 PID 1778·widget PID 1779가 생존했고 9월 22일 지도·시간축·날씨 UI가 오류 팝업 없이 렌더링됐다: `build/validation/RRL0922E02/device-install.json`, `device-launch.json`, `device-app-readback.json`, `device-process-15s.json`, `device-after-15s.png`.

## 2026-09-22 MFG0922E03 · fail-closed 편집 반환값 회귀

- repository load 실패 중 사용자 행동분류·메모·지도 메모 draft·대분류·지도 스티커·사용자 공항 등록이 각각 `false` 또는 `nil`을 반환하고 fallback snapshot/revision을 유지하며, 두 번째 bootstrap 복구 뒤 메모 생성은 다시 성공하는 focused 회귀 2/2 PASS: `build/validation/MFG0922E03/mutation-gate-focused-r1.xcresult`.
- 전체 앱 회귀 총 1,303개 중 1,302 PASS·기존 StoreKit 1 SKIP·0 FAIL·runtime warning 0, build error/warning/analyzer warning 0: `build/validation/MFG0922E03/full-app-r2.xcresult`.
- iPhoneOS 27.0 SDK generic device Debug build·서명·embedded Watch/widget 검증 PASS, error/warning/analyzer warning 0: `build/validation/MFG0922E03/current-ios27-device-build-r3.xcresult`.
- Device Hub의 iPhone 14 Pro/iOS 27.2에 최신 Debug 1.0 (149)을 사용자 데이터 삭제 없이 설치·foreground launch했다. 15초 뒤 앱 PID 1790·widget PID 1791이 생존했고 9월 22일 지도·시간축·날씨 UI가 오류 팝업 없이 렌더링됐다: `build/validation/MFG0922E03/device-details.json`, `device-install.json`, `device-app-readback.json`, `device-launch.json`, `device-process-15s.json`, `device-after-15s.png`.

## 2026-09-22 WCA0922E04 · WatchConnectivity 시작 순서 회귀

- legacy ambient 큐 이관보다 `WCSession` delegate 등록·활성화를 먼저 수행하고, 이관 완료 후 활성 세션 flush를 재호출하도록 변경했다. 이관 실패 시 기존 pending 배열은 유지된다.
- iPhone 17 Pro/iOS 26.5 Simulator `WatchSensorQueryPlanTests` 47/47 PASS·실패/스킵/runtime warning 0: `build/validation/WCA0922E04/watch-connectivity-regression-r1.xcresult`.
- iPhoneOS 27.0 SDK generic Debug 빌드·서명·embedded Watch/widget 검증 PASS, error/warning/analyzer warning 0: `build/validation/WCA0922E04/current-ios27-device-build-r2.xcresult`. paired Watch가 없어 실제 백그라운드 전달 재현은 수행하지 않았다.

## 2026-09-22 BIO0922E05 · 생체보호 저장 fail-closed

- repository 첫 load 실패 상태에서 `protectCurrentDataWithBiometrics()`가 `CancellationError`로 차단되고 fallback snapshot·revision이 유지되는 회귀를 기존 편집 차단·복구와 함께 실행해 2/2 PASS·실패/스킵/runtime warning 0: `build/validation/BIO0922E05/biometric-failclosed-r1.xcresult`.
- iPhoneOS 27.0 SDK generic Debug 빌드·서명·embedded Watch/widget 검증 PASS, error/warning/analyzer warning 0: `build/validation/BIO0922E05/current-ios27-device-build-r1.xcresult`.
- iPhone 14 Pro/iOS 27.2(24B5089g)에 최신 Debug 1.0 (149)을 앱·사용자 데이터 삭제 없이 교체 설치·foreground launch했다. 15초 뒤 app/widget PID 1845/1846이 생존했고 9월 22일 지도·시간축·날씨 UI가 오류 팝업 없이 렌더링됐다. Xcode Device Hub 창에서도 선택된 iPhone 14 Pro/iOS 27.2와 동일 실행 화면을 확인했다: `build/validation/BIO0922E05/device-details.json`, `device-install.json`, `device-apps.json`, `device-launch.json`, `device-processes-15s.json`, `device-after-15s.png`, `device-hub-window.png`.

## 2026-09-22 HKD0922E06 · HealthKit document deletion reconciliation

- 이전 UUID cursor의 삭제 문서, 유지 문서, 새 문서와 중복 UUID를 함께 주입해 추가/갱신/삭제 1/1/1 및 결정적 cursor를 확인했다. malformed cursor가 throw되어 기존 동기화 상태를 빈 snapshot으로 덮지 않는 회귀를 포함해 `HealthKitIntegrationTests` 30/30 PASS·실패/스킵/runtime warning 0: `build/validation/HKD0922E06/healthkit-integration-r1.xcresult`.
- iPhoneOS 27.0 SDK generic Debug 빌드·서명·embedded Watch/widget 검증 PASS, error/warning/analyzer warning 0: `build/validation/HKD0922E06/current-ios27-device-build-r1.xcresult`.
- iPhone 14 Pro/iOS 27.2(24B5089g)에 최신 Debug 1.0 (149)을 앱·사용자 데이터 삭제 없이 교체 설치·foreground launch했다. 15초 뒤 app/widget PID 1860/1861이 생존했고 9월 22일 지도·시간축·날씨 UI가 오류 팝업 없이 렌더링됐다. Device Hub 앱에서도 같은 iPhone 실행 화면을 readback했다: `build/validation/HKD0922E06/device-details.json`, `device-install.json`, `device-apps.json`, `device-launch.json`, `device-processes-15s.json`, `device-after-15s.png`, `device-hub-window.png`. CUA 연결은 기존 `failed to write kernel assets`로 실패했다. 실제 Health 앱에서 CDA 문서를 삭제하는 end-to-end 검증과 수정 전부터 cursor에 없던 과거 삭제의 소급 정리는 수행하지 않았다.

## 2026-09-22 HKC0922E07 · HealthKit malformed checkpoint fail-closed

- malformed history cursor가 `firstSampleDate`/history query를 호출하지 않고 기존 cursor·sample 7·added 7을 보존하는 회귀, malformed anchor가 기존 anchor·sample 5·added 8·deleted 3을 보존하는 회귀 2/2 PASS: `build/validation/HKC0922E07/cursor-failclosed-focused-r2.xcresult`. 첫 r1은 신규 테스트의 async XCTest autoclosure 컴파일 오류이며 제품 실패가 아니다.
- 전체 `HealthKitIntegrationTests` 32/32 PASS·실패/스킵/runtime warning 0: `build/validation/HKC0922E07/healthkit-integration-r3.xcresult`. iPhoneOS 27.0 SDK generic Debug 빌드·서명·embedded Watch/widget 검증 PASS, error/warning/analyzer warning 0: `current-ios27-device-build-r4.xcresult`.
- iPhone 14 Pro/iOS 27.2(24B5089g)에 최신 Debug 1.0 (149)을 앱·사용자 데이터 삭제 없이 교체 설치·foreground launch했다. 15초 뒤 app/widget PID 1878/1880이 생존했고 9월 22일 지도·시간축·날씨 UI가 오류 팝업 없이 렌더링됐다. Device Hub 앱에서도 같은 실행 화면을 readback했다: `build/validation/HKC0922E07/device-details.json`, `device-install.json`, `device-apps.json`, `device-launch.json`, `device-processes-15s.json`, `device-after-15s.png`, `device-hub-window.png`. 실제 기기 Health DB의 cursor를 손상시키는 파괴적 주입은 수행하지 않았다.

## 2026-09-22 ACT0922E08 · Activity incremental state compatibility

- 이전 taxonomy로 만든 정상 state에 현재 엔진으로 evidence를 append하면 evidence는 2개지만 segment가 이전 분류·sampleCount 1·1초 span에 남는 실패를 신규 회귀가 검출했다. 엔진 identity 불일치와 identity가 없는 legacy Codable 상태를 전체 재분류하도록 수정한 뒤 신규 2건을 포함한 TaptionActivityEngine 30/30 PASS·실패 0: `build/validation/ACT0922E08/ActivityEngine-full.log`.
- iPhoneOS 27.0 SDK generic Debug 빌드·서명·embedded Watch/widget 검증 PASS, error/warning/analyzer warning 0: `build/validation/ACT0922E08/current-ios27-device-build-r1.xcresult`, `current-ios27-device-build-r1.log`. import boundary와 `git diff --check`도 통과했다.
- iPhone 14 Pro/iOS 27.2에 앱·사용자 데이터 삭제 없이 최신 Debug 1.0 (149)을 교체 설치·foreground launch했다. 15초 뒤 app/widget PID 1956/1957이 유지되고 정상 지도·9월 22일·시간축 화면이 렌더링됐다: `device-details.json`, `device-install.json`, `device-apps.json`, `device-launch.json`, `device-processes-15s.json`, `device-after-15s.png`. Device Hub의 선택 기기와 live 화면 readback: `device-hub-screen.png`, `device-hub-runtime.png`.

## 2026-09-22 RFP0922E09 · Review archive fingerprint fail-closed

- 수정 전 회귀는 NaN 날씨 원본의 JSON 인코딩 실패가 SHA-256 빈 해시와 충돌해 기존 일 리뷰를 재사용하는 것을 검출했다: `build/validation/RFP0922E09/fingerprint-failclosed-r2.xcresult` (의도된 1 FAIL). fingerprint 오류 전파 수정 뒤 단독 1/1 PASS: `fingerprint-failclosed-r3.xcresult`.
- 일·월·연 archive 재생성, 장기 source 취소, 과거 일 백업 보존 및 신규 fail-closed 회귀 5/5 PASS·실패/스킵 0: `build/validation/RFP0922E09/review-archive-regression-r4.xcresult`.
- iPhoneOS 27.0 SDK generic Debug 빌드·서명·embedded Watch/widget 검증 PASS, error/warning 0: `build/validation/RFP0922E09/current-ios27-device-build-r5.xcresult`. import boundary와 `git diff --check`도 통과했다.
- iPhone 14 Pro/iOS 27.2에 앱·사용자 데이터 삭제 없이 Debug 1.0 (149)을 교체 설치·foreground launch했다. 15초 뒤 app/widget PID 1992/1993이 생존했고 Device Hub에서 같은 iPhone과 정상 9월 22일 지도·시간축·날씨 화면을 확인했다: `device-install.log`, `device-launch.log`, `device-process-after-15s.log`, `device-apps.log`, `device-hub-iphone-ios27-runtime-r2.png`. CUA는 기존 `failed to write kernel assets`로 실패해 Device Hub 직접 입력을 사용했다. 비정상 숫자는 simulator에서만 주입했다.

## 2026-09-22 PDS0922E10 · Plan-day nil fingerprint currentness

- canonical 64MiB 상한을 넘겨 이전 day snapshot과 현재 source fingerprint를 모두 nil로 만든 뒤 revision만 1→2로 바꾼 수정 전 회귀가 stale snapshot 허용을 검출했다: `build/validation/PDS0922E10/nil-fingerprint-currentness-r3.xcresult` (의도된 1 FAIL, `XCTAssertFalse`). NaN fixture를 사용한 r1/r2는 PropertyList codec이 NaN을 정상 직렬화해 테스트 전제가 틀린 결과이므로 제품 증거에서 제외한다.
- revision 동일, 서로 다른 revision·동일 nonnil fingerprint 허용과 서로 다른 revision·nil fingerprint 거부를 고정했다. 수정 뒤 단독 1/1 및 fingerprint·reprojection 인접 회귀 3/3 PASS: `nil-fingerprint-currentness-r4.xcresult`, `day-snapshot-regression-r5.xcresult`.
- iPhoneOS 27.0 SDK generic Debug 빌드·서명·embedded Watch/widget 검증 PASS, error/warning 0: `build/validation/PDS0922E10/current-ios27-device-build-r6.xcresult`. import boundary와 `git diff --check`도 통과했다.
- iPhone 14 Pro/iOS 27.2에 사용자 데이터 삭제 없이 Debug 1.0 (149)을 교체 설치·foreground launch했다. 15초 뒤 app/widget PID 2127/2128이 생존했고 Device Hub에서 같은 iPhone과 정상 9월 22일 지도·시간축·날씨 화면을 확인했다: `device-install.log`, `device-launch.log`, `device-process-after-15s.log`, `device-apps.log`, `device-hub-iphone-ios27-runtime-r3.png`. 64MiB 초과 원본은 simulator 회귀에서만 만들었다.

## 2026-09-22 AST0922E11 · Activity stale persisted segment recovery

- 정상 walking evidence/engine identity에 stale sleep segment를 주입한 수정 전 회귀는 append 후 evidence 2개에도 stale segment가 유지되어 full classification과 달라지는 것을 검출했다: `build/validation/AST0922E11/stale-segment-r1.log` (의도된 1 FAIL).
- 마지막 segment와 마지막 evidence tail 분류가 다르면 전체 재분류하도록 수정했다. 단독 1/1 PASS, TaptionActivityEngine 전체 31/31 PASS·실패 0: `stale-segment-r2.log`, `ActivityEngine-full-r3.log`.
- iPhoneOS 27.0 SDK generic Debug 빌드·서명·embedded Watch/widget 검증 PASS, error/warning 0: `build/validation/AST0922E11/current-ios27-device-build-r4.xcresult`. import boundary와 `git diff --check`도 통과했다.
- iPhone 14 Pro/iOS 27.2에 사용자 데이터 삭제 없이 Debug 1.0 (149)을 교체 설치·foreground launch했다. 15초 뒤 app/widget PID 2150/2151이 생존했고 Device Hub에서 같은 iPhone과 정상 9월 22일 지도·시간축·날씨 화면을 확인했다: `device-install.log`, `device-launch.log`, `device-process-after-15s.log`, `device-apps.log`, `device-hub-iphone-ios27-r2.png`. persisted-state 손상은 package 회귀에서만 주입했다.

## 2026-09-22 HQR0922E12 · HealthKit long-span overlap query

- 조회 시작 30일 전에 시작해 조회 구간까지 이어지는 HealthKit record가 기존 고정 7일 lookback에서 누락되는 것을 수정 전 회귀가 검출했다: `build/validation/HQR0922E12/long-span-query-r1.xcresult` (의도된 1 FAIL).
- 저장 시 최대 record duration metadata를 먼저 단조 증가시키고, metadata가 없는 legacy DB는 HealthKit event를 한 번 읽어 backfill한다. 신규 저장·legacy backfill 2/2 PASS: `long-span-query-r3.xcresult`.
- `HealthKitIntegrationTests` 전체 34/34 PASS·실패/스킵/runtime warning 0: `build/validation/HQR0922E12/healthkit-integration-r4.xcresult`. iPhoneOS 27.0 SDK generic Debug 빌드·서명·embedded Watch/widget 검증 PASS, error/warning 0: `current-ios27-device-build-r5.xcresult`. import boundary와 `git diff --check`도 통과했다.
- iPhone 14 Pro/iOS 27.2에 사용자 데이터 삭제 없이 Debug 1.0 (149)을 교체 설치·foreground launch했다. 15초 뒤 app/widget PID 2176/2178이 생존했고 Device Hub에서 같은 iPhone과 정상 9월 22일 지도·시간축·날씨 화면을 확인했다: `device-install.log`, `device-launch.log`, `device-process-after-15s.log`, `device-apps.log`, `device-hub-iphone-ios27-r2.png`. 장기 record는 simulator DB에서만 주입했다.

## 2026-09-22 KCR0922E13 · Cloud recovery key fallback 보존

- 수정 전 회귀에서 CloudKit 복구 키의 Keychain 저장 실패가 전파되지 않고 legacy iCloud Drive fallback이 삭제되는 결함을 재현했다: `build/validation/KCR0922E13/keychain-preservation-prefx-r1.xcresult` (의도된 1 FAIL, 2 assertion failures).
- Keychain 영속화 성공 후에만 legacy fallback을 삭제한다. 실패 시 기존 키 보존·성공 시 이전 정리 회귀 2/2와 `SecurityBackupCoreTests` 전체 99/99 PASS: `keychain-preservation-r2.xcresult`, `security-backup-r3.xcresult`.
- 전체 앱 회귀 1,312건은 1,311 PASS·기존 StoreKit 1 SKIP·0 FAIL·runtime warning 0: `full-app-r5.xcresult`. iPhoneOS 27.0 SDK 물리 기기 Debug 빌드·서명·embedded Watch/widget 검증 warning/error 0: `current-ios27-device-build-r4.xcresult`.
- iPhone 14 Pro/iOS 27.2에 사용자 데이터 삭제 없이 Debug 1.0 (149)를 교체 설치·실행했다. 15초 뒤 app/widget PID 2197/2198이 생존했고 Device Hub에서 선택 기기 iOS 27.2와 정상 지도·9월 22일·시간축 화면을 확인했다: `device-install.json`, `device-launch.json`, `device-apps.json`, `device-processes-15s.json`, `device-hub-iphone.png`.

## 2026-09-22 PCC0922E14 · Plan-day projection 취소 전파

- 수정 전 회귀는 `PlanDayDataSnapshot.make`가 전달된 cancellation closure를 호출하지 않고 1,024개 reading projection을 끝내는 결함을 검출했다: `build/validation/PCC0922E14/prefix-r1.xcresult` (의도된 1 FAIL).
- 직접 취소와 sensor loader가 반환되기 직전 부모 load 취소 회귀 2/2 PASS, 기존 `SensorDayStoreTests` 전체 86/86 PASS: `cancellation-r4.xcresult`, `sensor-day-r3.xcresult`.
- 전체 앱 회귀 1,314건은 1,313 PASS·기존 StoreKit 1 SKIP·0 FAIL·runtime warning 0: `full-app-r5.xcresult`. iPhoneOS 27.0 SDK 물리 기기 Debug 빌드·서명·embedded Watch/widget 검증 warning/error 0: `current-ios27-device-build-r6.xcresult`.
- iPhone 14 Pro/iOS 27.2에 사용자 데이터 삭제 없이 Debug 1.0 (149)를 교체 설치·foreground launch했다. 15초 뒤 app/widget PID 2231/2232가 생존했고 Device Hub에서 선택 기기 iOS 27.2와 정상 9월 22일 지도·시간축·날씨 화면을 확인했다: `device-install.json`, `device-launch.json`, `device-apps.json`, `device-processes-15s.json`, `device-hub-iphone.png`. CUA는 기존 `failed to write kernel assets`로 실패해 Device Hub window readback으로 확인했다.

## 2026-09-22 MSM0922E15 · 앱 로드 migration 선형화·취소 전파

- strict memo shell 판정·idempotency·legacy memo 도달성·앱 load와 cancellation 회귀 8/8 PASS: `build/validation/MSM0922E15/memo-bootstrap-r9.xcresult`. 첫 두 사전 실행은 XCTest runner 미기동 상태로 각각 중단해 제품 실패나 수정 전 회귀 근거로 계산하지 않았다.
- 최종 소스 전체 앱 회귀 1,316건은 1,315 PASS·기존 StoreKit 1 SKIP·0 FAIL·runtime warning 0: `full-app-r10.xcresult`. iPhoneOS 27.0 SDK 물리 기기 Debug 빌드·서명·embedded Watch/widget 검증 warning/error 0: `current-ios27-device-build-r11.xcresult`.
- iPhone 14 Pro/iOS 27.2에 사용자 데이터 삭제 없이 Debug 1.0 (149)를 교체 설치·foreground launch했다. 15초 뒤 app/widget PID 2281/2282가 생존했고 Device Hub에서 선택 기기 iOS 27.2와 정상 9월 22일 지도·시간축·날씨 화면을 확인했다: `device-install-current.json`, `device-launch-current.json`, `device-apps-current.json`, `device-processes-current-15s.json`, `device-hub-iphone-current.png`.

## 2026-09-22 ALM0922E16 · 자동 분류 잠금 병합 interval index

- 활동·이동 잠금의 기존 판정, 최대 overlap 동률 시 첫 입력 우선, 검증된 지하철 보존과 1,000×1,000 비겹침 입력의 bounded candidate 조회 회귀 7/7 PASS: `build/validation/ALM0922E16/focused-r1.xcresult`. `FeatureEngineTests`는 611건 중 610 PASS·기존 StoreKit 1 SKIP·실패/runtime warning 0: `feature-engine-r2.xcresult`.
- 최종 소스 전체 앱 회귀 1,319건은 1,318 PASS·기존 StoreKit 1 SKIP·0 FAIL·runtime warning 0: `full-app-r3.xcresult`. iPhoneOS 27.0 SDK의 iPhone 14 Pro/iOS 27.2 Debug 빌드·서명·embedded Watch/widget 검증은 warning/error/analyzer warning 0: `ios27-device-build-r4.xcresult`.
- iPhone 14 Pro/iOS 27.2에 사용자 데이터 삭제 없이 Debug 1.0 (149)를 교체 설치·foreground launch했다. 15초 뒤 app/widget PID 2306/2307이 생존했고 직접 기기 캡처와 Device Hub 선택 화면에서 9월 22일 지도·시간축·날씨 UI가 정상 렌더링됐다: `device-install-r5.json`, `device-launch-r5.json`, `device-processes-15s-r5.json`, `device-app-r5.json`, `iphone-current-r5.png`, `device-hub-iphone-current-r6.png`. CUA는 기존 `failed to write kernel assets`로 초기화되지 않아 Device Hub window 직접 선택·readback을 사용했다.

## 2026-09-22 BRI0922E17 · 백업 fallback endpoint index

- 동일 경계 장소의 기존 첫 입력 우선, 명시적 place ID·지하철 좌표 우선과 1,000 travel×1,001 places의 bounded endpoint 조회를 포함한 집중 회귀 8/8 PASS: `build/validation/BRI0922E17/focused-r1.xcresult`. `SecurityBackupCoreTests` 101/101 PASS·runtime warning 0: `security-backup-r2.xcresult`.
- 최종 소스 전체 앱 회귀 1,321건은 1,320 PASS·기존 StoreKit 1 SKIP·0 FAIL·runtime warning 0: `full-app-r3.xcresult`. iPhoneOS 27.0 SDK의 iPhone 14 Pro/iOS 27.2 Debug 빌드·서명·embedded Watch/widget 검증은 warning/error/analyzer warning 0: `ios27-device-build-r4.xcresult`.
- iPhone 14 Pro/iOS 27.2에 사용자 데이터 삭제 없이 Debug 1.0 (149)를 교체 설치·foreground launch했다. 15초 뒤 app/widget PID 2343/2345가 생존했고 직접 기기 캡처와 Device Hub 선택 화면에서 9월 22일 지도·시간축·날씨 UI가 정상 렌더링됐다: `device-install-r5.json`, `device-launch-r5.json`, `device-processes-15s-r5.json`, `device-app-r5.json`, `iphone-current-r5.png`, `device-hub-current-r5.png`.

## 2026-09-22 MRI0922E18 · 이동 구간 evidence index

- 입력 순서·경계 포함·WBS 공항 endpoint 판정과 1,000개 비겹침 evidence 조회 상한을 포함한 집중 회귀 4/4 PASS: `build/validation/MRI0922E18/focused-r1.xcresult`.
- `FeatureEngineTests` 전체 613건은 612 PASS·기존 StoreKit 1 SKIP·0 FAIL·runtime warning 0: `feature-engine-r2.xcresult`. 전체 앱 회귀 1,323건은 1,322 PASS·기존 StoreKit 1 SKIP·0 FAIL·xcresult runtime warning 0: `full-app-r3.xcresult`.
- iPhoneOS 27.0 SDK의 iPhone 14 Pro/iOS 27.2 Debug 빌드·서명·embedded Watch/widget 검증은 error/warning/analyzer warning 0: `ios27-device-build-r4.xcresult`.
- iPhone 14 Pro/iOS 27.2에 사용자 데이터 삭제 없이 Debug 1.0 (149)를 교체 설치·foreground launch했다. app/widget PID 2428/2429가 생존했고 직접 기기 캡처와 Device Hub 선택 화면에서 9월 22일 지도·시간축·날씨 UI가 오류 팝업 없이 정상 렌더링됐다: `device-details-r5.json`, `device-install-r5.json`, `device-app-r5.json`, `device-launch-r13.json`, `device-processes-r13.json`, `iphone-current-r13.png`, `device-hub-iphone-current-r13.png`.

## 2026-09-22 SRI0922E19 · SensorFusion 공용 시간 인덱스

- 공용 index의 입력 순서·inclusive 센서 경계·HealthKit strict overlap과 1,000×1,000 비겹침 조회 상한, 기존 층·장소·지하철·모션 병합을 묶은 집중 회귀 8/8 PASS: `build/validation/SRI0922E19/focused-r1.xcresult`.
- `FeatureEngineTests` 615건은 614 PASS·기존 StoreKit 1 SKIP·0 FAIL·runtime warning 0: `feature-engine-r1.xcresult`. 전체 앱 1,325건은 1,324 PASS·1 SKIP·0 FAIL·runtime warning 0: `full-r1.xcresult`.
- iPhoneOS 27.0 SDK의 iPhone 14 Pro/iOS 27.2 Debug 빌드·서명·embedded Watch/widget 검증은 error/warning/analyzer warning 0: `ios27-device-build-r1.xcresult`.
- iPhone 14 Pro/iOS 27.2에 앱·사용자 데이터 삭제 없이 Debug 1.0 (149)를 교체 설치·foreground launch했다. 15초 뒤 app/widget PID 2458/2459가 생존했고 직접 기기 캡처와 Device Hub 선택 화면에서 9월 22일 지도·시간축·날씨 UI가 오류 팝업 없이 정상 렌더링됐다: `device-install.json`, `device-apps.json`, `device-launch.json`, `device-processes-15s.json`, `iphone-current.png`, `device-hub-iphone.png`. CUA는 기존 `failed to write kernel assets`로 초기화되지 않아 Device Hub 창을 직접 readback했다.

## 2026-09-22 MAI0922E20 · Apple 모션 기록 sweep index

- 최초 집중 실행은 Swift 6 `compactMap` 반환 타입 추론 실패로 컴파일이 중단됐다(`focused-r1.xcresult`). 요소 타입을 명시한 뒤 원본 불변·inclusive 경계·최신 시작/동일 시작 후입력 우선과 1,000×1,000 비겹침 상한을 포함한 집중 회귀 4/4 PASS: `build/validation/MAI0922E20/focused-r2.xcresult`.
- `FeatureEngineTests` 617건은 616 PASS·기존 StoreKit 1 SKIP·0 FAIL·runtime warning 0: `feature-engine-r1.xcresult`. 전체 앱 1,327건은 1,326 PASS·1 SKIP·0 FAIL·runtime warning 0: `full-r1.xcresult`.
- iPhoneOS 27.0 SDK의 iPhone 14 Pro/iOS 27.2 Debug 빌드·서명·embedded Watch/widget 검증은 error/warning/analyzer warning 0: `ios27-device-build-r1.xcresult`.
- iPhone 14 Pro/iOS 27.2에 앱·사용자 데이터 삭제 없이 Debug 1.0 (149)를 교체 설치·foreground launch했다. 15초 뒤 app/widget PID 2472/2473가 생존했고 직접 기기 캡처와 Device Hub 선택 화면에서 9월 22일 지도·시간축·날씨 UI가 오류 팝업 없이 정상 렌더링됐다: `device-install.json`, `device-apps.json`, `device-launch.json`, `device-processes-15s.json`, `iphone-current.png`, `device-hub-iphone.png`.

## 2026-09-22 MFI0922E21 · 모션 계열 보정 시간 인덱스

- 겹친 자동차 구간의 duration 합산·inclusive 센서 경계·분당 20걸음 임계값과 1,000개 이동 조각의 bounded evidence 조회를 포함한 집중 회귀 4/4 PASS: `build/validation/MFI0922E21/focused-r1.xcresult`.
- `FeatureEngineTests` 619건은 618 PASS·기존 StoreKit 1 SKIP·0 FAIL·runtime warning 0: `feature-engine-r1.xcresult`. 전체 앱 1,329건은 1,328 PASS·1 SKIP·0 FAIL·runtime warning 0: `full-r1.xcresult`.
- iPhoneOS 27.0 SDK의 iPhone 14 Pro/iOS 27.2 Debug 빌드·deep/strict 서명·embedded Watch/widget 검증은 error/warning/analyzer warning 0: `ios27-device-build-r1.xcresult`.
- iPhone 14 Pro/iOS 27.2에 앱·사용자 데이터 삭제 없이 Debug 1.0 (149)를 교체 설치·foreground launch했다. 15초 뒤 app/widget PID 2494/2495가 생존했고 직접 기기 캡처와 Device Hub 선택 화면에서 9월 22일 지도·시간축·날씨 UI가 오류 팝업 없이 정상 렌더링됐다: `device-install.json`, `device-apps.json`, `device-launch.json`, `device-processes-15s.json`, `iphone-current.png`, `device-hub-iphone.png`.

## 2026-09-22 STI0922E22 · 이동 병합 체류 interval index

- 기존 이동 병합·180초 체류 경계·비정렬 체류와 1,000×1,000 비겹침 조회 상한을 포함한 집중 회귀 4/4 PASS: `build/validation/STI0922E22/focused-r1.xcresult`.
- `FeatureEngineTests` 621건은 620 PASS·기존 StoreKit 1 SKIP·0 FAIL·runtime warning 0: `feature-engine-r1.xcresult`. 직전 MFI0922E21 전체 앱 1,329건 PASS 뒤 변경 범위가 `coalescingTravel`과 해당 회귀에 한정되어, 대표님의 빠른 마무리 요청에 따라 전체 앱 중복 실행은 생략했다.
- iPhoneOS 27.0 SDK의 iPhone 14 Pro/iOS 27.2 Debug 빌드·deep/strict 서명·embedded Watch/widget 검증은 error/warning/analyzer warning 0: `ios27-device-build-r1.xcresult`.
- iPhone 14 Pro/iOS 27.2에 앱·사용자 데이터 삭제 없이 Debug 1.0 (149)를 교체 설치·foreground launch했다. 15초 뒤 app/widget PID 2507/2509가 생존했고 직접 기기 캡처와 Device Hub 선택 화면에서 9월 22일 지도·시간축·날씨 UI가 오류 팝업 없이 정상 렌더링됐다: `device-install.json`, `device-apps.json`, `device-launch.json`, `device-processes-15s.json`, `iphone-current.png`, `device-hub-iphone.png`.

## 2026-09-22 AAI0922E23 · 모션 실제기록 중복 interval index

- 기존 모션 기록 생성·정확한 20초 겹침 경계·장소 문맥의 정지 전용 우선순위와 1,000×1,000 비겹침 조회 상한을 포함한 집중 회귀 4/4 PASS: `build/validation/AAI0922E23/focused-r1.xcresult`.
- `FeatureEngineTests` 623건은 622 PASS·기존 StoreKit 1 SKIP·0 FAIL·runtime warning 0: `feature-engine-r1.xcresult`. 직전 MFI0922E21 전체 앱 통과 뒤 STI0922E22·AAI0922E23 변경은 `SensorFusion`의 해당 두 경로와 회귀에 한정되어 관련 기능 전체로 검증했다.
- iPhoneOS 27.0 SDK의 iPhone 14 Pro/iOS 27.2 Debug 빌드·deep/strict 서명·embedded Watch/widget 검증은 error/warning/analyzer warning 0: `ios27-device-build-r1.xcresult`.
- iPhone 14 Pro/iOS 27.2에 앱·사용자 데이터 삭제 없이 Debug 1.0 (149)를 교체 설치·foreground launch했다. 15초 뒤 app/widget PID 2554/2555가 생존했고 직접 기기 캡처와 다시 연 Device Hub 선택 화면에서 9월 22일 지도·시간축·날씨 UI가 오류 팝업 없이 정상 렌더링됐다: `device-install.json`, `device-apps.json`, `device-launch.json`, `device-processes-15s.json`, `iphone-current.png`, `device-hub-iphone.png`.

## 2026-09-22 MTI0922E24 · 이동 병합 공용 interval index

- strict overlap·입력 순서, GPS > Watch > motion 우선순위, 동일 지하철 overlap의 첫 GPS 유지, 접촉 경계 분리를 포함한 집중 회귀 9/9 PASS·실패/스킵 0: `build/validation/MTI0922E24/focused-r1.xcresult`.
- `FeatureEngineTests` 629건은 628 PASS·기존 StoreKit 1 SKIP·0 FAIL·xcresult runtime warning 0: `build/validation/MTI0922E24/feature-engine-r1.xcresult`. 로그의 suite 종료 뒤 `Unbalanced calls` 문구는 있었지만 xcresult runtime warning에는 기록되지 않았다.
- iPhoneOS 27.0 SDK의 iPhone 14 Pro/iOS 27.2 Debug 빌드·deep/strict 서명·embedded Watch/widget 검증은 error/warning/analyzer warning 0: `build/validation/MTI0922E24/ios27-device-build-r1.xcresult`, `ios27-device-build-r1.log`.
- 앱·사용자 데이터 삭제 없이 Debug 1.0 (149)를 교체 설치·foreground launch했다. 15초 뒤 app/widget PID 2658/2659가 생존했고 직접 기기 캡처와 Device Hub live 화면에서 9월 22일 지도·시간축·날씨 UI가 정상 렌더링됐다: `device-install.json`, `device-apps-after-install.json`, `device-launch.json`, `device-processes-after-15s.json`, `iphone-current.png`, `device-hub-iphone-screen.png`. Device Hub CUA는 `failed to write kernel assets`로 실패해 Accessibility 직접 선택·readback을 사용했다.

## 2026-09-22 HAR0922A01 · Codex 하네스 경량화

- `~/.codex` 42GB 중 archived sessions 24GB, sessions 6.2GB, thread history 7.6GB, logs 3.3GB는 보존 기록이며 프롬프트 캐시가 아니다. 재생성 가능한 cache 60MB·plugin cache 73MB도 모델 입력으로 주입되지 않아 삭제하지 않았다. 현재 실행 중인 다른 작업과 기록 DB를 보존했다.
- 전역 설정과 프로젝트 우선 설정을 TOML로 검증했다. 기본 `gpt-6-astra`/reasoning max, tool output 6,000, skill catalog 4,000, Luna/max 하위 에이전트 최대 4개, memory/chronicle 생성·주입 off다. 전역 백업은 `~/.codex/backups/HAR0922A01/`, 프로젝트 설정은 `.codex/config.toml`에 있다.
- `codex mcp list` readback에서 `aside`, 구형 computer-use, node_repl은 disabled이고 `cua_repl`만 enabled다. 데스크톱 앱에서는 `codex-app-tools`가 실행 인자로 강제 활성화된다.
- `codex debug prompt-input` readback은 memory summary/path 주입 0, skill catalog 5개, prompt 10,296 chars·약 2,860 tokens였다. 중간 기준 15개 skill·13,823 chars·약 3,840 tokens보다 약 980 tokens 감소했고, 기존 자동 memory summary 9,704 bytes도 새 작업에서 제외된다.
- 현재 열려 있는 작업은 생성 당시 하네스를 유지할 수 있어 중단하지 않았다. 데스크톱 앱을 모든 활성 작업이 끝난 뒤 재시작하면 전역 프로세스 축소가 완전히 반영된다.

## 2026-09-22 ACM0922E34 · Core Motion 수면 오분류

- Core Motion 보행·자동차는 수면으로 분류하지 않고 명시적 sleep stage만 수면으로 분류하도록 수정했다. `TaptionActivityEngine` package 회귀 33/33 PASS·exit 0: `build/validation/ACM0922E34/activity-engine-r3.log`.

## 2026-09-22 RTF0922E35 · 동일 시각 route 종료 플래그 보존

- 동일 timestamp 표본의 `trackingSessionEnded`를 입력 순서와 무관하게 보존하고 다음 GPS projection segment를 차단했다. focused app 회귀 2/2 PASS: `build/validation/0922-current-r4/focused.xcresult`, `focused.log`.

## 2026-09-22 RFM0922E28 · 공유 RawData 포맷 오인식

- tracking chunk 열거를 UUID session parent와 `.jsonl.zlib` 형식으로 제한해 raw monthly archive를 오인식하지 않도록 수정했다. `SensorDayStoreTests.testTrackingChunkArchiveIgnoresRawMonthlyArchiveFiles` 1/1 PASS: `build/validation/0922-current-r4/focused.xcresult`.

## 2026-09-22 CAK0922E29 · iCloud 계정별 복구 키 격리

- CloudKit account identity별 recovery-key bundle과 scoped iCloud fallback을 사용하고, Keychain 저장 성공 전 fallback을 삭제하지 않도록 수정했다. `SecurityBackupCoreTests` 집중 회귀 3/3 PASS·xcodebuild exit 0: `build/validation/0922-current-r4/security.xcresult`, `security.log`.

## 2026-09-22 HOR0922E30 · HealthKit observer 실패 재시도 유실

- scoped HealthKit 동기화 실패 시 관찰 타입을 재큐잉하고 실패 중 도착한 새 타입을 보존하도록 수정했다. `HealthKitIntegrationTests.testObservedHealthChangeQueueRequeuesFailedScopeWithoutDroppingNewEvents` 1/1 PASS: `build/validation/0922-current-r4/focused.xcresult`.

## 2026-09-22 PSC0922E32 · refresh 취소 후 부분 snapshot 저장

- sensor timeline refresh 취소·오류 시 snapshot/anchor/revision을 이전 값으로 복원하고 refresh 중 background persist를 지연하도록 수정했다. `FeatureEngineTests.testSensorTimelineCancellationKeepsErrorButReadFailureIsReported` 1/1 PASS: `build/validation/0922-current-r4/focused.xcresult`; 저장소 주입식 partial-write 회귀는 아직 별도 증거가 없다.

## 2026-09-22 WDR0922E31 · Watch 동시 data-sync request ID 경합

- `TaptionWatchDataSyncRequestGate`를 공용 값 타입으로 분리해 A 처리 중 B가 active ID를 교체하거나 완료할 수 없고, A 완료 뒤 B만 수락되도록 고정했다. 게이트 회귀 1/1 PASS, Watch/Widget 포함 앱 scheme 컴파일 성공: `build/validation/0922-current-r5/targeted.xcresult`, `targeted.log`.
- 실제 페어링 Watch에서의 전송·재시작·snapshot receipt readback은 별도 실기기 검증 범위로 남아 있다.

## 2026-09-22 ERD0922E33 · expected-route 진단 반복 쌍 스캔

- 시간 index와 bounded candidate slice, cancellation check를 적용했다. expected-route 회귀 3/3 PASS: `testExpectedRouteRequestWorkDoesNotRescanAllReadingsPerTravelSegment`, `testExpectedRouteRequestCancellationStopsReadingSortBeforeIndexBuild`, `testExpectedRouteRequestsEveryBoundedGPSGapWithStableDistinctIDs` in `build/validation/0922-current-r5/targeted.xcresult`.

## 2026-09-22 PFA0922E25 · 지도 탑승 후보 반복 전체 스캔

- `ReadingSpatialIndex`, `SensorEvidenceTimeIndex`, `TimeSpanValueIndex`로 장소·센서·이동 후보의 반복 전체 스캔을 bounded 조회로 바꾸고 원본 순서·경계·catalog/Watch 판정을 보존했다. SensorFusion/탑승 후보 대표·성능 회귀 9/9 PASS, 전체 targeted 회귀 13/13 PASS: `build/validation/0922-current-r5/targeted.xcresult`, `targeted.log`.

## 2026-09-23 HAR0922A01 · residual device and harness gates

- WeatherKit 계정 readback은 App Store Connect API에서 `com.taption.plan` bundle ID `7CZ37R5K4D`의 `bundleIdCapabilities` 목록에 `WEATHERKIT`가 포함된 것으로 확인됐다. Apple API는 해당 capability 단건 GET을 허용하지 않아 중복 변경은 하지 않았다. 기존 HTTP 401의 다음 검증은 새 프로파일을 포함한 현재 소스 서명 설치 후 실기기 재호출이다.
- 물리 iPhone 18 Pro Max의 기존 `com.taption.plan` 1.0 (149)을 앱 데이터 삭제 없이 재실행했다. 2026-09-22 23:54:35~23:57:41 KST, 18초 간격을 포함한 13회 CoreDevice 프로세스 readback에서 app PID 4766과 widget PID 4771이 계속 유지됐다. 해당 soak 뒤 `systemCrashLogs` 목록에 새 TaptionPlan crash/CPU log는 추가되지 않았다. 이 산출물은 build 149 설치 증거이며 최신 소스 수정본의 9/9 장시간 workload 완료로 계산하지 않는다.
- paired Apple Watch SE는 당시 잠시 `available (paired)`였지만 앱/프로세스 조회가 negotiated tunnel timeout으로 실패했고, 이후 `unavailable`로 전환됐다. details readback은 paired·developer mode enabled·watchOS 26.6·`tunnelState=disconnected`·`ddiServicesAvailable=false`였다. 강제 종료·실제 `transferUserInfo` 재전송·receipt 전환은 실행하지 않았고 WSD0922A01을 열린 상태로 유지한다.
- `REV0922E01/full-app-r2.log`의 전체 앱 고착은 테스트 케이스의 XCTest waiter가 아니라 Xcode `com.apple.dt.xctest.target-runner`가 worker materialization 및 crashed test operation restart를 기다린 상태였다(로그의 `Waiting for -runningDidFinish call`). 해당 실행은 유효 PASS로 계산하지 않으며, 현재 소스 focused waiter 재실행은 공유 build lock 뒤에서 대기 중이다.

## 2026-09-23 HAR0922A01 · 현재 소스 물리 설치 재검증

- generic iOS 27 Debug 산출물은 deep/strict 서명과 WeatherKit entitlement는 유효했지만, embedded profile의 `ProvisionedDevices`에 물리 iPhone 18 Pro Max UDID가 없어 설치가 `0xe8008012`로 거부됐다. 기기 지정 Debug 빌드는 같은 소스에서 성공했고 `device-targeted-build.log`/`device-targeted-build.xcresult`에 `** BUILD SUCCEEDED **`가 남았다.
- 기기 지정 profile `adef4656-a448-44ac-9a4a-46a1ba8f4154`는 대상 UDID를 포함하고 `com.apple.developer.weatherkit=true`를 유지했다. 사용자 데이터를 삭제하지 않고 `DeviceDerivedData/Build/Products/Debug-iphoneos/TaptionPlan.app`를 설치했으며 `device-targeted-install.json`에서 설치 성공을 readback했다.
- 설치 후 `com.taption.plan` 1.0 (149)을 readback하고 foreground launch했다. app PID 4919와 widget PID 4913/4920이 2026-09-23 00:14:22~00:15:24 KST 5회 프로세스 조회에서 유지됐다. 같은 시점 `systemCrashLogs`에는 9/23 신규 TaptionPlan crash/CPU report가 없었고, 앱 Diagnostics 파일의 최신 수정도 기존 9/20~9/21 기록이었다.
- Watch는 `available (paired)` 표시는 있었지만 실제 details/apps/processes 호출이 negotiated tunnel 응답 없이 대기해 제가 만든 조회만 취소했다. force-restart, `transferUserInfo` 재전송, receipt 전환은 실행·성공 처리하지 않았다.
- `testPlanDayLoadCoordinatorKeepsInvalidationUntilCanceledLoadSucceeds` 집중 XCTest는 다른 Taption UI 테스트가 공유 build lock을 점유해 실행 시작 전 대기만 했다. 약 17분 뒤 제 대기 셸만 중단했으며 lock을 강제 해제하지 않았다. `focused-waiter-r1.log`/result는 생성되지 않았고 PASS/FAIL로 계산하지 않는다.

## 2026-09-23 HAR0922A01 · 잔여 게이트 재시도 readback

- Device Hub에서 paired Apple Watch SE를 직접 선택해 watchOS 26.6·`Enable Developer Mode` 상태를 확인했다. 화면에는 `An error occurred — Connection timed out`가 표시됐고 CoreDevice details/apps/processes와 앱 launch도 같은 negotiated tunnel timeout으로 끝났다. `Device > Start`와 `Force Shut Down`은 연결 불가 상태에서 비활성화되어 있어 강제 재시작·`transferUserInfo` 재전송·receipt 전환을 실행하지 않았다. WSD0922A01은 닫지 않는다: `build/validation/HAR0922A01/devicehub-watch-select2.png`.
- 기기 지정 현재 소스 build 149를 foreground launch한 뒤 `weather-console-r3.log`에서 launch/exit 0만 확인했다. 새 WeatherKit provider/401 로그와 신규 앱 진단 파일은 생성되지 않았고, `devicectl diagnose`는 시스템 암호 프롬프트에서 중단해 unified log 증거로 사용하지 않는다. capability·entitlement 유효성은 확인됐지만 실제 WeatherKit 호출/401 해소는 미확정이다: `build/validation/HAR0922A01/weather-console-r3.log`, `weather-diagnostics-r3.json`.
- 같은 iPhone이 후속 Device Hub readback에서 잠금 상태가 되어 정확한 9/9 날짜 선택·장시간 재생 입력을 수행하지 못했다. 기존 build 149 단기 생존/CPU·crash readback은 정확한 9/9 workload 증거로 대체하지 않으며, BUG1909R01의 9/9 장시간 soak와 9/20 file-lock 동일 workload 재현은 열린 상태다.
- 현재 tracked diff는 72개가 아니라 74개 파일이며, 여기에 untracked source 3개와 작업 산출 디렉터리가 있다. Activity/Projection, PlanCore storage, Route index/playback, Watch/HealthKit, AppModel/UI integration 및 새 Route/Watch accumulator를 현재 소스와 HEAD 양쪽에서 수동 대조했다. 이번 read-only 감사에서 즉시 재현 가능한 신규 correctness·concurrency·data-loss 결함은 확정하지 않았고, storage V3/V4 memory-bound 선택과 위 실기기 게이트는 별도 열린 항목으로 유지한다. `git diff --check`와 기존 package/facade 회귀 결과는 유지하며, 수동 감사만으로 PASS를 주장하지 않는다.

## 2026-09-23 HAR0922A01 · 잔여 게이트 후속 검증

- 공유 build lock이 비어 있는 시점에 현재 소스 SwiftPM 회귀를 병렬 재실행했다: TaptionPlanCore 97/97, TaptionActivityEngine 33/33, TaptionRouteEngine 38/38, TaptionPlanEngine facade 1/1 PASS·0 FAIL.
- `testPlanDayLoadCoordinatorKeepsInvalidationUntilCanceledLoadSucceeds`를 `TRP0922A01 Validation iPhone` iOS 26.5 Simulator에서 실제 테스트 본문까지 재실행해 1/1 PASS·0 FAIL·0 SKIP·runtime warning 0을 확인했다: `build/validation/HAR0922A01/focused-waiter-r2.xcresult`. 시뮬레이터 콘솔의 App Group/HealthKit entitlement 경고는 서명 없는 테스트 호스트 환경에서만 발생했으며 테스트 결과에는 runtime warning으로 기록되지 않았다.
- `bash scripts/check-app-engine-import-boundary.sh` PASS, `git diff --check` PASS. 스크립트 파일 자체는 실행 bit가 없어 직접 실행은 거부됐지만 동일 파일을 `bash`로 실행해 검증했다.
- Apple Watch SE는 `devicectl list devices`에서 `connecting`, details readback은 paired·developer mode enabled·watchOS 26.6·booted를 반환했지만 tunnel은 `disconnected`이고 apps 조회는 `Network.NWError Code 60 / Operation timed out`로 실패했다. 따라서 force-restart·실제 `transferUserInfo` 재전송·receipt 전환은 여전히 실행하지 않았고 WSD0922A01은 열린 상태다.
- WeatherKit 실제 provider/401 readback과 정확한 9/9 장시간 재생 soak는 이번에도 물리 기기 UI 입력/로그 증거가 없어 닫지 않는다. 현재 닫힌 것은 코드 회귀·focused waiter뿐이다.
