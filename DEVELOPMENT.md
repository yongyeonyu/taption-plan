# Taption Plan 개발 문서

## 2026-09-21 · legacy migration과 transit POI refresh

- `LFR0921A01`: legacy JSONL 파일 미존재만 빈 입력으로 처리한다. 권한/I/O 읽기 오류는 migration 완료 marker 전에 전파해 원본을 복구한 뒤 재시도할 수 있게 했다.
- `RVR0921A01`: transit POI 검색은 bootstrap 완료 및 active scene에서만 예약하고, resolver 완료 뒤에도 active 상태를 확인해 백그라운드 결과 게시를 막는다. UI 배치는 바꾸지 않았다.
- `MCR0921A01`: materialized rollback 비교는 SQLite `REAL`에 저장된 Unix seconds 표현끼리 수행한다. Foundation `Date` reference-date 왕복에서 내부 Double이 1 ULP 달라져 CAS가 실패하던 경계를 회귀 테스트로 고정했다.
- `DVT0921A01`: Device Hub에서 iPhone 14 Pro/iOS 27.0에 로컬 Debug build 149를 설치·실행했다. map/timeline 화면이 렌더링됐고 `testPlanDayDatabaseRemovesMaterializationInvalidatedDuringCommit` 실기기 XCTest가 1/1 통과했다. 상세는 `test.md`; 장시간 background CPU/watchdog soak 및 TestFlight 검증은 하지 않았다.
- `MPC0921A01`: 날짜 레일의 중첩 후보 탐색을 우선순위 heap sweep으로 바꾸고, 병합 출처 ID는 accumulator에서 모아 결과 생성 때 한 번만 정렬한다. 날짜 세대 변경은 stale 읽기 결과를 차단하며, day snapshot 재기반은 이미 정규화된 원본 표본을 재사용해 취소 가능한 utility worker에서 처리한다. UI 배치·저장 계약은 바꾸지 않았다.

## 2026-09-21 · review fixes and latest device readback

- `MIG0921B01`, `INI0921B01`, `RCE0921B01`, `GEO0921B01`, `HKD0921B01`, `WPI0921B01`, `HCR0921B01`, `WAM0921B01`: corrected Watch migration/live event identity, concurrent SQLite cold-open initialization, corrupt materialized-row cleanup races, latest route-input invalidation, HealthKit sync/delete ordering and cursor compatibility, idempotent Watch workout purge, and bounded ambient sample-ID retention. Core/Activity/Route/PlanEngine SwiftPM suites pass 157/157; focused app/Watch XCTest coverage remains separate.
- Concurrent V3 cold open initially surfaced `SQLITE_BUSY` while enabling WAL. Added a bounded retry for `PRAGMA journal_mode=WAL` only; the cold-open regression and full Core suite then passed.
- `DVI0921B01`: the earlier check could only launch the installed 1.0 (149) build because Device Hub CUA failed with `failed to write kernel assets`; direct input and current-checkout inclusion were unverified then. The later `DHB0921C01` run built, installed, and directly exercised the current checkout; see `test.md`.
- `DHB0921C01`: current-source iPhone 14 Pro/iOS 27.2 Debug build and Device Hub date/play input smoke passed. Date moved 9/21→9/22→9/21; Play/Pause toggled and the app remained foreground. The shared App Group path stayed the same; the app-specific container UUID changed, so private-container continuity is unverified. No data erase or TestFlight upload was performed.

## 2026-09-21 API0921A01 · umbrella engine facade

- 항상 `"1"`만 반환하던 `TaptionPlanEngine.version`과 고정값 assertion을 제거하고 Core·Activity·Route의 re-export 경계만 유지했다. Facade consumer test target은 umbrella package만 의존한다.
- Facade SwiftPM test 1/1 PASS; iPhone 14 Pro/iOS 27.2 Debug build exit 0. `test.md`에 검증 기록을 남겼다.

## 2026-09-21 WPD0921A01 · locked HealthKit workout purge

- Apple documents `finishWorkout()` returning `(nil, nil)` as a successful save whose `HKWorkout` object is unavailable while the device is locked ([finishWorkout](https://developer.apple.com/documentation/healthkit/hkworkoutbuilder/finishworkout%28completion%3A%29)). Each Watch workout now carries a generated purge UUID in custom HealthKit metadata. A purge overlapping finish persists that ID before waiting; reconciliation deletes only workouts matching that metadata and requires `deleteObjects` to report at least one deleted sample ([deleteObjects](https://developer.apple.com/documentation/healthkit/hkhealthstore/deleteobjects%28of%3Apredicate%3Awithcompletion%3A%29)). Zero/error retains the intent for retry; a non-nil finish result still deletes the exact returned object.
- `WatchWorkoutStartGateTests` 9/9 PASS on iPhone 17 Pro/iOS 26.5 (`build/validation/WPD0921A01-watchworkout-class-r1.xcresult`); generic watchOS Simulator Debug build PASS, zero warnings (`build/validation/WPD0921A01-watch-build-r1.xcresult`). Locked-device HealthKit deletion and paired-Watch/Device Hub input remain unverified.

## 2026-09-21 WPI0921B01 · idempotent locked-workout purge retry

- After a successful zero-count `deleteObjects` retry, query HealthKit with the exact purge UUID. Remove the durable intent only when that app-owned workout is absent; an existing match or query error leaves it queued. `testLockedFinishWithoutSampleKeepsPurgeIntentUntilDeletionIsConfirmed` passes 1/1 (`build/validation/WPI0921B01/watch-purge-intent-final.xcresult`). Physical Watch HealthKit deletion remains unverified.

## 2026-09-22 WOF0922R01 / WFF0922R01 · Watch purge interleavings

- Ambient outbox flush now owns its in-flight task. Purge invalidates its generation, cancels and awaits the flush before deleting the database, and the flush rechecks that generation before processing results and before every reliable transfer.
- A `finishWorkout()` error after an uncertain HealthKit save transitions to `failedMayHavePersisted`; the generated purge UUID remains durable until reconciliation confirms deletion. A genuinely pre-save failure still removes the unused intent.
- `WatchSensorQueryPlanTests` 45/45 and generic watchOS Simulator Debug build pass. Paired Watch transfer, forced-process restart recovery, and physical HealthKit deletion remain separate runtime gates.

## 2026-09-22 REV0921A01 · Activity/Route adapter integration

- Current iOS app integration XCTest for `RouteTimelineDataTests`, `TaptionActivityEngineAdapterTests`, and `TaptionRouteEngineAdapterTests` passed 132/132 on the iPhone 17 Pro iOS 26.5 validation simulator: `build/validation/REV0921A01/adapters-route-current-r2.xcresult`. This covers the cancellation-aware Activity evidence/quality paths, route adapter merge cancellation, playback lower-bound behavior, and route timeline projection. It does not close MapKit/device-only, raw-restore, Plan-day rollback, or Watch paired-device gates.
- The current Debug product used for this run includes the embedded Watch target; generic watchOS Debug and iOS Debug builds also pass. No UI layout or storage contract was changed for this verification.

## 2026-09-22 REV0922A01 · storage concurrency follow-up

- `PlanDayDatabase.load()` now holds the day write fence while reading the materialized row, both raw digests, validating the projection, and repairing a bad row. Materialized replacement uses an existing-row CAS so an older projection cannot overwrite a newer writer. The Core package CAS regression and Plan-day cancellation/rollback regressions pass.
- `TaptionPlanDayLRUCache` now single-flights same-key misses and rejects late loader results after an explicit insert/remove. The full TaptionPlanCore suite passes 94/94, including the new concurrent-loader regression.
- `MigratingPlanRepository` clears only the completed migration task that owns its request ID, including failure/cancellation. A failed primary migration now retries on the next load in the same process; the iOS regression passes 4/4 with no test/runtime warnings. The only build warning remains the pre-existing `AppleIntegrations.swift:4494` `@preconcurrency` warning.

## 2026-09-20 BUG1909R01 · build 149 iPhone watchdog/CPU and background file lock

- iPhone 14 Pro/iOS 26.6.2 TestFlight build 149의 9/17 3건·9/18 2건 crash report는 모두 `FRONTBOARD/0x8BADF00D` 30초 scene-update watchdog이다. Crash thermal state는 nominal이며 app/dSYM UUID `e97cfbeb-cbdb-36e9-bce0-bcf848553542`가 일치한다. 심볼화한 9/18 21:36 main-thread stack은 `RouteTimelineDataEngine.category(at:in:through:)`가 각 sample/segment마다 전체 actuals를 filter하고 winner를 찾는 경로다. 9/17 3건 및 9/18 22:58 stack은 `ActivityClassificationEngine.classification(for:overrides:)`의 샘플별 전체 override filter/sort, comparator 내 반복 `UUID.uuidString` 생성 경로다. 예외는 앱 배열 범위 오류가 아니라 OS watchdog SIGKILL이다.
- CPU resource report 8건(9/18 21:27·21:49·22:05, 9/19 15:13·15:25·15:30·15:37·15:43)은 비전면/사용자 idle 상태에서 48 CPU초/49–55초, 87–99% CPU를 기록했다. 9/18 초반 두 건은 activity classifier, 22:05는 expected-route/WBS projection 및 sleep span 계산, 9/19 다섯 건은 live route/WBS refresh와 일부 review archive/persist 경로를 가리킨다. 9/20 CPU report는 없지만, 같은 날 00:15:54에는 별도 Plan crash report가 확인됐다.
- `BKG0920A01`: build 149의 새 report는 `EXC_CRASH/SIGKILL`, `RUNNINGBOARD/0xDEAD10CC`이며 dSYM UUID `e97cfbeb-cbdb-36e9-bce0-bcf848553542`와 일치한다. `sceneEnteredBackground → saveCloudBackupOnBackground → cloudRawSensorPayload → SensorReadingArchive.readings/loadEvents/decodeReadings` 호출 중 worker가 `DeviceMotionSnapshot` 등을 decode하고, 해당 메서드의 바깥 `defer`까지 shared App Group `TaptionDataFileLock`을 계속 보유했다. 이는 decoder 예외나 이전 `0x8BADF00D` watchdog이 아니라 background suspension 시 파일 잠금을 놓지 못한 종료다. iCloud raw backup이 월초부터 누적된 센서 기록을 한 번에 읽는 경로라 데이터가 많을수록 잠금 보유 구간이 길어졌다.
- classifier override를 한 번 정규화해 우선순위 heap sweep으로 조회하고 tie-break는 UUID 바이트 비교로 바꿨다. route category도 선택일 actuals에서 interval index를 만들고 sample/segment 조회를 binary search로 교체했다. 분류 계산/병합은 utility detached 작업으로 옮기고 취소·오래된 revision 결과를 버린다. MapHomeView는 inactive scene에서 live/expected route 및 WBS 파생 계산을 취소·차단하고, expected route 갱신을 100ms 합친다. 센서 원본·저장 계약·UI 배치는 유지했다.
- 일반 센서/raw archive 조회는 iOS background assertion 아래에서 SQLite event snapshot을 잠근 뒤 canonical payload decode를 lock 밖에서 128-event async batch로 수행하고, batch 경계에서 cancellation·deletion generation을 확인한다. 최초 legacy migration도 legacy/raw/tracking decode·정규화를 lock 밖에서 수행하고 256-event 단위 idempotent SQLite transaction과 최종 marker commit만 잠근다. 각 batch는 cancellation·deletion generation·migration marker를 확인하며 동시 migration도 중복 제거된다. legacy repair는 원본 event 비교 및 삭제 generation 검증 후 다시 잠근다. 일자 memory reprojection은 per-day invalidation generation과 DB write-lock 안의 commit guard로 무효화된 projection의 materialized 저장을 막는다. Watch sleep 총시간은 보낼 segment 목록의 2,000개 상한을 적용하기 전에 전체 보존 구간에서 계산한다.
- `BKU0920A01`: raw archive 저장소의 `accountUnavailable`은 손상 상태로 변환하지 않고 복원 package 로딩까지 전달한다. iCloud 파일 미다운로드·일시 접근 실패는 부분 복원이 적용되지 않아 재시도 가능하며, 손상 archive는 기존 snapshot-only 결과를 유지한다.
- `QCP0920R01`: detached sensor quality projection의 취소를 scalar filter와 route adapter/filter 루프까지 전달하고 256개 단위로 확인한다. 취소는 scalar robust filter와 route filtering 내부에서 각각 검증했다.
- `RSE0920R01`: stale day projection이 invalidation 후 남기던 append-only sensor raw event를 exact-event CAS rollback으로 제거한다. 같은 키가 바뀐 동시 writer row는 삭제하지 않는다.
- `DNL0920R01`/`DHE0920R01`: legacy SQLite key의 embedded NUL을 domain, id, snapshot, map, metadata/migration key 경계에서 거부하고, snapshot equality/hash는 SQLite BINARY domain과 동일한 UTF-8 byte identity를 사용한다.
- `CAS0920R01`: materialized rollback CAS가 generatedAt·firstTimestamp·lastTimestamp까지 모든 저장 열을 비교한다.
- `WRS0920A02`: commerce lock 변경은 이미 진행 중인 workout teardown reset token을 무효화하지 않는다. `WPD0920A01`: purge 중 HealthKit에 저장된 workout은 삭제 완료까지 추적하고 삭제 실패 시 purge를 실패시킨다. HealthKit 실기기 삭제 검증은 미완료다.
- `RCL0920A03`: file-backed raw archive restore는 1 MiB FileHandle read와 1 MiB base64 decode chunk 사이, JSON payload scan 중 65,536자 간격으로 cancellation을 확인한다. JSONEncoder의 escaped slash와 v1 archive 형식을 유지한다. `SecurityBackupCoreTests` 80/80 PASS (`build/validation/RCL0920A03-security-backup-full-final.xcresult`).
- 관련 검증: TaptionPlanCore 69/69, route/activity adapter와 Watch gate 및 stale-save iPhone Simulator 33/33 PASS (`build/validation/WPD0920A01-watch-cleanup-regressions.xcresult`); watchOS Simulator Debug build exit 0.
- 현재 통합 검증: TaptionPlan iPhone 17 Pro Simulator 1,168 PASS·1 SKIP·0 FAIL (`build/validation/BUG1909R01-full-current.xcresult`); skip은 iOS 26.5 StoreKitTest `SKInternalErrorDomain Code 3`. SwiftPM packages Core/Activity/Route/PlanEngine은 69/69·19/19·25/25·1/1 PASS.
- `xcodebuild analyze -project TaptionPlan.xcodeproj -scheme TaptionPlan -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`: exit 0. 기존 사용자 변경인 `AppleIntegrations.swift:4470`의 `@preconcurrency AVAudioPlayerDelegate` 무효 경고 1건만 출력되어 해당 파일은 수정하지 않았다.
- `RTE0920A01`: route time-coordinate index가 필터링된 route segment 경계를 유지해 15분 초과 GPS 공백을 보간하지 않는다. 비정렬 segment는 시작 시각으로 정규화하고 겹치는 구간의 전체 마지막 시각도 올바르게 clamp한다. RouteEngine package 23/23, app adapter 12/12, generic iOS Debug build exit 0.
- `WCH0920A01`: Watch 로컬 전체 삭제가 운동 시작 도중 실행되면 purge generation으로 대기 중인 시작을 무효화하고, 삭제 중 새 시작을 막는다. HealthKit 권한·collection·metadata await 뒤마다 세대를 확인하며 concurrent purge도 모두 끝날 때까지 차단한다. gate XCTest 2/2, generic watchOS Simulator build PASS.
- `WCE0920A01`: iPhone `systemCrashLogs`에서 WatchOS 26.6 build 149 종료 보고서 7건(최신 9/20 11:18:16)을 확인했다. 모두 `EXC_BREAKPOINT/SIGTRAP`, app/dSYM UUID `9f183f95-a2de-3306-b09f-f77c51112a04` 일치, utility queue의 동일한 `WatchConnectivityController.requestSync()` error callback에서 발생했다. 11:02·11:18 보고서도 exact build-149 dSYM으로 `closure #1 in WatchConnectivityController.requestSync() +120`에 심볼화됐다. iPhone에 설치된 앱은 여전히 build 149이므로 두 보고서는 수정 전 Watch 바이너리의 반복이며 수정본 런타임 검증은 아니다. 해당 one-way `sendMessage` callback은 source에서 제거했고, generic watchOS Simulator Debug build는 PASS·exit 0.
- `WST0920A01`/`WCH0920R01`: workout start가 `beginCollection`/`addMetadata`에서 await 중 purge가 시작되면 늦게 끝난 HealthKit 세션을 정리하지 못할 수 있었다. stop/reset도 sensor·HealthKit await 뒤 오래된 결과로 상태를 비우거나 오류를 게시하고, 설정 동기화가 purge 중 주변기록을 다시 arm할 수 있었다. start/stop/reset은 gate로 직렬화하고 각 await 뒤 generation을 확인하며, stale start의 해당 session/builder만 end/discard하고 모든 ambient refresh는 purge/reset 중 거부한다. 후속 리뷰에서 purge가 start/stop teardown과 동시에 공용 HealthKit 객체를 end/discard하는 경합, reset 중 도착한 `didFailWithError` callback 누락을 추가로 확인했다. lifecycle barrier로 purge가 진행 중 teardown 완료를 기다리게 하고, reset 중 실패 callback은 최종 오류로 보존한다. `SecurityBackupCoreTests` 77개와 `WatchWorkoutStartGateTests` 7개, 총 84/84 PASS (`build/validation/WCR0920B01/regression.xcresult`). 페어링 Watch 런타임 검증은 미완료.
- `PGR0920A01`: 리뷰에서 manager가 Watch acceleration/ambient archive를 삭제한 뒤 controller가 fallible SQLite purge를 하던 순서를 확인했다. DB purge가 실패해도 원본이 사라지고 ambient outbox가 재전송될 수 있었다. 모든 producer/writer를 정지한 뒤 SQLite purge를 먼저 수행하고, 성공한 경우에만 manager archive/메모리 상태를 지우도록 단일 purge 흐름을 재배치했다. 실패 뒤 outbox 자동 재전송은 중단한다. SQLite 실패 시 manager stores 보존 XCTest 포함 Watch deletion payload suite 14/14 PASS (`build/validation/PGR0920A01/purge-related-tests.xcresult`); 테스트 실행에서 iOS/embedded Watch Debug target이 빌드됐다. 실제 HealthKit/페어링 Watch purge는 미검증이다.
- `LQA0920A01`: legacy ambient 배열을 SQLite outbox에 snapshot 저장하는 동안 추가된 항목까지 제거하던 경쟁을 고쳤다. 성공한 snapshot과 정확히 같은 값만 legacy 큐에서 빼고 이후 도착·수정된 값은 남긴다. 공용 제거 함수가 Watch controller에서 호출되며 회귀 XCTest 1/1 PASS (`build/validation/LQA0920A01/ambient-adoption.xcresult`).
- `RTA0920A01`: ambient `transferUserInfo` 실패 callback만, delivery ID·활성 세션·비-purge 조건에서 지연 outbox flush를 예약하도록 했다. 성공이나 ACK 대기 상태에서는 재전송하지 않는다. retry eligibility XCTest를 포함한 Watch shared-model test 2/2 PASS (`build/validation/LQA0920A01/ambient-policies.xcresult`); 실물 Watch 재시도는 별도 확인 대기다.
- `LCK0920A01`: commerce lock 전환이 workout start generation도 무효화하도록 했다. `applySettings`가 await 전에 gate를 갱신하고 권한·collection·metadata await 뒤의 기존 generation guard가 대기 중 잠긴 시작을 폐기한다. 잠금 대기 회귀 포함 Watch gate·sensor suite 70/70 PASS, generic watchOS Simulator Debug build PASS·exit 0.
- `ORD0920A01`: Watch acceleration flush append task를 enqueue 순서대로 연결하고 취소된 대기 task는 파일 쓰기를 건너뛴다. 따라서 기존 bounded per-session sequence watermark가 더 높은 batch를 먼저 기록해 앞 batch를 버리는 경합을 막는다. 역순 chunk file 저장·재로딩 회귀 포함 SensorDayStore/gate suite 70/70 PASS; generic watchOS Simulator Debug build PASS·exit 0. 페어링 Watch runtime 검증은 별도 게이트다.
- `WCF0920A01`: 오래된 `HKWorkoutSession` 실패 callback이 뒤늦게 `reset()`을 호출해 새 운동을 지울 수 있었다. callback 객체와 현재 session의 identity를 확인하고, reset에서 session·builder delegate를 해제한다. generic watchOS Simulator Debug build PASS; 실제 HealthKit 지연 callback 재현은 Watch에서 미확인.
- `WLP0920A01`: MainActor로 지연된 CoreLocation callback은 현재 운동 시각을 검사하지 않아 이전 운동 좌표가 새 운동 경로에 섞일 수 있었다. 현재 운동 시작 시각보다 오래된 위치를 거부하는 정책을 적용하고, 이전 운동 위치 배제 XCTest를 추가했다.
- `WAD0920A01`: iPhone 저장 실패 시 ambient recorder watermark가 그대로라 같은 session/sequence 표본이 재생된다. Watch의 월별 JSONL append는 세션별 최대 sequence를 재구성해 이미 쓴 표본을 건너뛰고, write 실패 시 index를 무효화해 다음 시도에서 파일 상태를 다시 읽는다. 중복 drain XCTest와 watchOS Debug build로 확인했다.
- `WDR0920A01`: pending ambient session으로 재조회할 때 표본 ordinal을 1부터 다시 매기던 문제를 고쳤다. sequence를 고정 query anchor(`highWater` 또는 `armedAt`)와 sample timestamp에서 계산하고, JSONL append index는 재시도 session의 실제 sequence 집합으로 중복을 제거해 더 낮은 새 sequence도 저장한다. workout session은 기존 단조 sequence 규칙을 유지한다. iPhone Simulator 24/24, index regression 2/2, generic watchOS Simulator Debug build PASS.
- `WPC0920A01` (실물 연동 검증 대기): ambient raw event와 immutable delivery payload를 SQLite outbox에 함께 기록하고 iPhone durable 저장 ACK까지 재전송한다. 10분 summary revision·변경된 chunk ID 및 iPhone stable-sample merge로 늦은 표본을 보존한다. ACK와 페이지 flush가 겹칠 때 후속 flush 요청을 보존한다. Core 73/73, iPhone Simulator 집중 회귀 30/30, generic watchOS Debug build PASS (`build/validation/WPC0920A01`); 실제 Watch↔iPhone 비활성·재시작·ACK 연결 검증은 미완료다.
- `WCR0920A01`: 레거시 Watch archive의 restore receipt는 이전 전체 청크 배열을 저장한다. restore가 repository 저장을 await하는 동안 새 Watch 청크가 추가되면 실패 rollback이 그 새 기록까지 지울 수 있었다. actor 안에서 restore를 commit/rollback까지 추적하고, 동시 기록은 정상 저장한 뒤 ID와 최신 보존시각으로 요약해 실패 시 이전 상태에 합친다. 동시 read와 추가 restore는 transaction 종료까지 대기한다. `SensorDayStoreTests` 61/61 PASS (`build/validation/WCR0920A01/sensor-day-tests-final4.xcresult`).
- `APP0920A01`: incremental activity append에서 마지막 sample을 override가 여러 span으로 나누면 prior tail과 rebuilt tail의 경계가 어긋나 마지막 fragment를 중복 추가할 수 있었다. 마지막 evidence 시각을 prior final segment가 포함하지 않는 경우 full classification으로 fallback한다. 경계 split 회귀 포함 Activity package 19/19 PASS.
- `BMS0920A01`: cloud raw backup 수집이 sensor/envelope/Watch archive 읽기 오류를 빈 데이터로 숨기고, 기존 snapshot의 raw generation이 사라진 경우에도 incoming payload로 새 세대를 만들 수 있었다. read 실패를 전파하고 committed raw marker의 generation이 없으면 저장을 거부한다. 누락 archive 이후 비어 있지 않은 replacement 거부 회귀 포함 `SecurityBackupCoreTests` 74/74 PASS (`build/validation/WCR0920A01/security-backup-final.xcresult`).
- `RST0920A01`: raw 복원은 월별 암호문을 하나씩 처리하고, file-backed store의 파일 read/envelope decode 및 payload decrypt/decompress/Codable decode/ID merge를 MainActor 밖에서 실행한다. archive 경계 cancellation은 그대로 전파한다. 최신 `SecurityBackupCoreTests`+Watch gate 통합 회귀는 84/84 PASS (`build/validation/RST0920A01/stream-io-final2.xcresult`). 단일 월 v1/v2 blob peak, 전체 merge result 집적, `AppModel.applyCloudBackup` preflight/rollback 비용은 남아 있어 v3 chunk/staging/commit 설계가 필요하다. 이는 iPhone watchdog/CPU stack의 직접 원인이 아니다.
- `RVA0920R01`: 호출처가 없는 `AppModel.reviewArchives(for:asOf:)` private wrapper를 제거했다. 유일한 실제 경로 `refreshReviewArchives`는 이미 detached utility 계산과 revision 검사·반영을 직접 수행하므로 중복 wrapper만 정리했으며 동작은 바뀌지 않았다. 관련 archive/recovery XCTest 5/5 PASS (`build/validation/RVA0920R01/review-archive-suite.xcresult`).
- `RAC0920R01`: scene background 진입은 `postSaveRefreshTask`를 취소하지만, 그 안에서 await하던 detached review archive 계산에는 취소를 전달하지 않아 stale 결과 반영은 막더라도 background CPU 작업이 끝까지 돌 수 있었다. detached task 취소 handler와 일별 소스 분배·archive 날짜 루프의 cancellation checkpoint를 추가했다. source hierarchy와 report 값은 변경하지 않으며 revision/scene guard도 유지한다. 관련 archive/recovery 및 취소 회귀 6/6 PASS (`build/validation/RAC0920R01/archive-cancellation.xcresult`).
- `QCP0920R01`: source audit에서 `sensorTimelineTask`의 취소가 독립 `Task.detached` 안의 센서 scalar quality 계산까지 전달되지 않는 것을 확인했다. detached worker에 cancellation handler를 연결하고 scalar 입력/결정 루프를 256개 단위로 취소 확인한다. 동기 `qualityProjection(from:)` 계약과 출력은 유지한다. scalar 단계 테스트는 통과했지만 `RouteLoggerRouteFilter`의 현재 동기 실행과 정렬은 중간 취소가 불가능해 한 번 시작된 route projection은 반환까지 계속될 수 있다. 이 경로는 제공된 OS report의 직접 심볼 스택 원인으로 확인된 것은 아니며, 물리 iPhone post-fix CPU 로그도 아직 없다.
- `RIX0920A01`: `RouteTimeCoordinateIndex.sample(at:)`가 segment 전체를 선형 순회하던 부분을 start upper-bound와 prefix-maximum end lower-bound로 바꿔 O(log S) interval 조회로 만들었다. 중첩·정렬되지 않은 segment와 gap `nil` 계약을 보존한다. RouteEngine tests 24/24 및 generic iOS Debug build PASS·exit 0.
- `BGC0920A01`: monthly raw backup은 generation별 불변 파일을 먼저 기록하고, v3 snapshot에는 raw archive 존재 marker를 authenticated metadata에 포함한다. 이전 raw 파일과 legacy 고정 경로를 읽기 호환으로 보존하고, 복원은 snapshot generation과 일치하는 파일만 쓴다. marker가 가리키는 raw archive를 아직 읽을 수 없으면 부분 복원 대신 retryable `accountUnavailable`을 반환한다. v1/v2 metadata 인증은 바뀌지 않는다.
- `DPR0920A01`: day projection commit이 freshness 취소 뒤 stale raw 이벤트만 남기던 경로를 보강했다. 교체 전 projection을 보존하고, 저장된 현재 값이 stale projection과 정확히 일치할 때만 transaction 안에서 이전 projection으로 CAS 복구해 신규 writer 값을 덮지 않는다.
- `SRP0920A01`: 센서 raw-event repair는 decode 전 원본 event와 저장 시점 event가 동일할 때만 SQLite transaction 안에서 조건부 upsert한다. decode 동안 같은 ID에 기록된 최신 payload는 복구 데이터가 덮지 않는다.
- `MIG0920A01`: legacy raw 이벤트 여러 건이 신규 import ID와 충돌할 때 첫 충돌만 지우고 한 번 재시도하던 migration을, 서로 다른 legacy provenance 충돌을 반복 해결하는 방식으로 보강했다. 같은 충돌 재발은 무한 재시도 없이 실패한다. 복수 충돌 import·unmarked 기록 보존 XCTest와 materialized rollback의 stale writer 보호 CAS 회귀를 추가했다. 취소 테스트는 raw archive 읽기가 파일 잠금 대기 중 취소된 뒤 잠금을 해제하고 기록을 보존하는지 확인한다.
- `TST0920A01`: `SensorReadingArchive`와 `RawDeviceDataDayArchive` decode를 128-event async batch로 나누고 batch 사이 actor yield, cancellation/deletion-generation 재검사를 적용했다. 2,346 legacy readings 및 300 raw envelopes의 multi-batch read/repair, stale generation rejection을 검증했다. 정확히 batch 중간에 삭제를 실행하는 결정적 회귀는 아직 없다.
- `MLK0920A01`: 최초 sensor migration의 legacy/raw/tracking source decode·event encode를 shared lock 밖으로 옮겼다. 256-event idempotent SQLite batch와 completion marker를 잠금 안에서 처리하고 매 batch마다 cancellation·deletion generation을 검사한다. 동시 640-event migration 10회 반복 및 backup/sensor 통합 회귀로 검증했다. full source aggregation의 peak memory와 exact mid-decode deletion test는 별도 항목이다.
- `REF0920A01`: 동작·패키지 버전과 무관하게 항상 `"1"`을 반환하던 테스트 전용 `TaptionPlanEngine.version` API를 제거하고 umbrella re-export smoke test만 유지한다.
- `GEN0920A01`: 같은 달의 최신 스냅샷에 이미 커밋된 raw archive가 있고 새 월간 generation에 raw 샘플이 없으면 기존 데이터를 보존해 새 generation ID로 다시 묶는다. 새 스냅샷 저장 실패 시 이전 raw archive를 되돌린다. AppModel 진단도 빈 데이터를 저장했다고 기록하지 않는다.
- `COR0920A01`: raw backup set에서 malformed, 크기 초과/거부 또는 120개 제한으로 누락된 파일이 있으면 일부 월만 `.available`로 복원하지 않고 archive set을 invalid로 처리해 snapshot-only 경로로 제한한다. Snapshot archive의 기존 누락 파일 복구 동작은 유지한다.
- 인접 리뷰에서 sampleCount 중복, 요청 span 밖 센서 근거, migration 광역 삭제, source 변경 reprojection 미저장, Watch 주변 센서 재시도 ID, 운동 시작 중복/실패 cleanup, HealthKit 조회 오류 성공 오판정, 겹친 수면 시간 중복 합산을 수정했다. 독립 검토 `REV1909R01`은 watchdog 변경에서 수정이 필요한 회귀를 찾지 못했다. package 검토 `PKGA0920R1`은 현재 추가로 안전하게 추출할 경계가 없다고 판단했다. Activity/Route target에서 실제 import가 없던 PlanCore 의존성만 제거했다. `RST0920A01` 복원에서 ciphertext 전량 보유와 동기 decode/merge의 MainActor 점유는 줄였으나, 월 단위 v1/v2 단일 blob과 전체 merge 결과는 여전히 메모리에 올라간다. v1/v2 호환 v3 청크 인증·압축과 로컬 stage/전체 검증/bounded commit/rollback이 함께 필요한 저장 계약 확장이라 별도 구현 항목으로 남긴다. 이는 확인된 iPhone watchdog/CPU stack의 원인은 아니다.
- `DGD0920A01`/`EVK0920A01`: raw digest 스캔 후 별도 autocommit 저장 전 다른 SQLite connection이 event/cache를 갱신하면 stale digest가 다시 저장될 수 있어, version 재확인과 cache 저장을 `BEGIN IMMEDIATE` transaction으로 묶고 기존 파생 cache는 1회 무효화한다. Batch identity는 구분자 결합 문자열 대신 domain→id tuple로 비교한다. Core package XCTest 57/57 PASS, generic iOS Debug build PASS·exit 0.
- raw backup 복원 보강 `BKU0920A01`/`GEN0920A01`/`COR0920A01`: `SecurityBackupCoreTests` 64 PASS·0 FAIL (`build/validation/BKU0920A01/security-backup-suite.xcresult`), generic iOS Debug build PASS·exit 0. 수정본은 실기기에 설치하지 않았다.
- 검증: cooperative decode/migration 변경 후 전체 iPhone 17 Pro Simulator suite 1,142 PASS·기존 StoreKit 1 SKIP·0 FAIL (`build/validation/MLK0920A01-full-retry.xcresult`; StoreKitTest `SKInternalErrorDomain Code 3`만 스킵). `SensorDayStoreTests` 57/57, combined `SecurityBackupCoreTests`+`SensorDayStoreTests` 130/130 및 concurrent migration 10/10도 PASS다. Core 60/60, Activity 17/17, Route 24/24, PlanEngine umbrella 1/1 PASS. 추가로 Activity classifier의 512개 중첩·만료 override 전 구간을 naive priority reference와 비교하는 XCTest를 넣고 package 18/18 PASS를 확인했다. 현재 소스 generic iOS device Debug exit 0 및 `.app` 산출물은 `build/validation/TST0920A01-cooperative-DD/Build/Products/Debug-iphoneos/TaptionPlan.app`이다. iOS Simulator Debug·`analyze`·watchOS Simulator Debug 및 Watch start gate 2/2도 PASS다.
- 수정본의 실제 iPhone 설치/실행·장시간 CPU 및 post-fix OS log는 별도 기기 게이트다. 현재 기기 설치본은 TestFlight build 149이며 이번 local 수정은 미설치다. TestFlight 업로드·설치는 하지 않았다.

## 2026-09-22 CPU0922A01 · iOS 27.2 CPU report provenance와 post-fix readback

- `TaptionPlan.cpu_resource-2026-09-22-080234.ips`는 iPhone 14 Pro/iOS 27.2에서 08:00:59–08:02:31 KST 동안 전면 앱이 90초 CPU/92초, 98%를 사용한 보고서다. 앱은 1.0 (149)이지만 loader UUID `2F36B41C-34A7-3E71-A53B-B117730689BE`가 현재 로컬 Debug loader와 같아 새 TestFlight Release 재발로 분류하지 않는다.
- 보고서 시작은 Device Hub 9/9 화면 재실행 시각과 정확히 일치하고, 08:01 캡처에는 `Taption Plan 645 ms` microhang이 보인다. 이 실행은 10,000 actual 재생 baseline p95 882.187ms가 확인된 actual-index 수정 전이다. 따라서 보고서는 재생 tick마다 actual을 다시 정렬하던 기존 경로의 현장 증거이며, 09:51 이후 적용한 `RouteTimelineDataEngine.ActualIndex` 수정 뒤 재발 증거가 아니다.
- 수정본은 같은 기기에서 p95 25.023ms, 전체 `RouteTimelineDataTests` 94/94를 통과했다. 최신 앱을 데이터 삭제 없이 재설치한 뒤 180초 생존과 신규 TaptionPlan CPU/Hang report 없음도 readback했다. 11:10 KST 추가 조회에서도 앱 PID 1217·위젯 PID 1218이 실행 중이고 TaptionPlan OS report는 기존 9/21 HangTracer와 08:02 CPU report뿐이다.
- iOS 27 Instruments 장시간 recording은 1.3초 뒤 채널 disconnect 또는 Xcode 내부 assertion으로 trace가 무효화되어 정량 근거에서 제외했다. 정확한 9/9 장시간 재생과 9/20 file-lock 동일 workload는 별도 미완료 게이트로 유지한다.

## 2026-09-22 STO0922D01 · 영구 저장소 선택 fail-closed

- `AppModel.init`은 app-group SQLite가 열려도 legacy 파일 저장소 하나가 실패하면 정상 SQLite를 버릴 수 있었고, 모든 SQLite가 실패해도 파일 저장소가 열리면 이를 사용하지 못하는 조합이 있었다. 모든 durable 저장소가 실패하면 live 앱에서 `InMemoryPlanRepository`로 내려가 저장된 것처럼 보인 변경이 재실행 후 사라질 수 있었다.
- `PlanRepositoryResolver`가 app-group SQLite, application-support SQLite, durable 파일 저장소 순으로 한 번만 선택하고, legacy 저장소가 없더라도 정상 SQLite를 유지한다. durable 저장소가 하나도 없으면 load/save/delete가 명시적으로 실패하는 `UnavailablePlanRepository`를 선택한다. Preview와 테스트의 명시적 repository 주입은 유지한다.
- iPhone 17 Pro/iOS 26.5 Simulator에서 정상 app-group SQLite 유지, SQLite 실패 시 durable 파일 fallback, 모든 저장소 실패 시 fail-closed 회귀 3/3 PASS·실패/스킵/runtime warning 0: `build/validation/STO0922D01-repository-failclosed-r2.xcresult`. 전체 앱과 테스트 타깃 컴파일도 성공했고 build error/warning/analyzer warning은 0이다.

## 2026-09-22 RPF0922D01 · DLF0922D01 · 백업 삭제-fence 정리

- raw sensor restore 비동기 경계 뒤 연속 실행되던 동일 preparation-fence 검사를 하나 제거했다. 비동기 작업 전후의 취소·PIN·삭제-generation 검사는 그대로 유지한다.
- legacy raw 저장 도중 데이터 삭제 generation이 전진하면 방금 쓴 파일도 제거한다. 일반 Task 취소에서는 기존 merged legacy 파일을 보존한다. 월간 generation의 snapshot commit 직전 삭제가 시작되면 이미 stale인 snapshot을 다시 읽지 않고 고유 staged raw 파일을 제거한다.
- 관련 경계 5/5 통과 후 `SecurityBackupCoreTests` 전체 직렬 97/97 PASS·실패/스킵/runtime warning 0: `build/validation/RPF0922D01/security-backup-focused-r4.xcresult`, `build/validation/RPF0922D01/security-backup-full-serial-r5.xcresult`. 재빌드 error/warning/analyzer warning은 0이다.
- 같은 checkout은 iPhoneOS 27.0 SDK의 generic iOS Debug 빌드·서명·embedded iPhone/Watch/widget 검증까지 성공했고 error/warning/analyzer warning은 0이다: `build/validation/REV0922D01/current-ios27-device-build.xcresult`.

## 2026-09-22 STF0922D02 · 저장소 load 실패 후 편집 fail-closed

- durable 저장소 load 실패 뒤 `persist()`만 거부하고 먼저 바뀐 메모리 snapshot을 남기던 경로를 막았다. bootstrap이 만든 안전한 fallback snapshot을 유지하고, 공통 mutation gate와 snapshot backstop이 이후 계획·설정 변경을 즉시 거부한다.
- 최초 backstop은 `@Observable` didSet 안에서 무조건 재할당해 재귀 SIGSEGV를 냈다: `build/validation/STF0922D02-repository-load-failclosed.xcresult`. 내부 복원 중임을 표시하는 guard를 추가한 뒤 단독 회귀 1/1과 기존 저장 취소·실패 회귀를 포함한 4/4가 통과했다: `build/validation/STF0922D02-repository-load-failclosed-r2.xcresult`, `build/validation/STF0922D02-repository-load-failclosed-regression-r3.xcresult`. 실패·스킵·runtime warning은 0이다.
- 최종 checkout의 iPhoneOS 27.0 SDK generic iOS Debug 빌드·서명·embedded iPhone/Watch/widget 검증이 성공했고 error/warning/analyzer warning은 0이다: `build/validation/STF0922D02-current-ios27-device-build.xcresult`.

## 2026-09-22 SRA0922D03 · PDR0922D04 · WSG0922D05 전체 회귀 안정화

- 센서 분석 회귀를 실제 active scene에서 실행하고 `AppleSensorDataService`에 기존 append 주입과 대칭인 archive-read loader를 추가했다. 열린 SQLite 디렉터리를 삭제하던 실패 주입을 결정적 loader 오류로 바꿔 pending day·retry 계약은 유지하면서 libsqlite API 위반을 제거했다.
- Plan-day 동시 복구 테스트는 load가 write lock 안에서 materialized row를 읽는 현재 계약에 맞춰, lock 해제 전 설치된 valid row를 snapshot으로 반환하고 row를 보존함을 검증한다.
- Watch 재시작 테스트는 삭제 cutoff를 격리해 이전 테스트 상태가 5분 전 payload를 정상 폐기하지 않게 했다. ACK 전 snapshot commit 계약은 그대로 검증한다.
- 관련 focused 5/5와 Watch 반복 5/5가 통과했다: `build/validation/SRA0922D03-focused-r1.xcresult`, `build/validation/WSG0922D05-watch-gate-r2.xcresult`. 최종 전체 앱 회귀는 1,301 PASS·기존 StoreKit 1 SKIP·0 FAIL·runtime warning 0이다: `build/validation/SRA0922D03-full-app-r3.xcresult`.
- 최종 checkout의 iPhoneOS 27.0 SDK generic iOS Debug 빌드·서명·embedded iPhone/Watch/widget 검증이 성공했고 error/warning/analyzer warning은 0이다: `build/validation/SRA0922D03-current-ios27-device-build.xcresult`.

## 2026-09-22 IOS0922D06 · 최신 checkout iOS 27 물리 기기 검증

- iPhoneOS 27.0 SDK로 빌드된 signed Debug 1.0 (149)을 iPhone 14 Pro/iOS 27.2에 앱·사용자 데이터 삭제 없이 교체 설치했다. 앱의 최소 지원 버전은 iOS 18.0을 유지하며, iOS 27 전용으로 deployment target을 올리지는 않았다.
- 설치·foreground launch 뒤 15초와 45초 readback에서 앱 PID 1698과 widget PID 1699가 동일하게 생존했다. 지도·9월 22일·시간축·날씨·재생 화면은 오류 팝업 없이 렌더링됐다: `build/validation/IOS0922D06/device-install.json`, `device-launch.json`, `device-process-readback-45s.json`, `device-after-45s.png`.
- WBS 공항 endpoint 항공 판정과 9월 9일 인천국제공항→수완나품 구간의 `비행기` 저장·재설치 readback은 선행 `I27A092201` 근거를 유지한다. 이번 검증은 최신 전체 회귀 안정화 뒤 설치·실행 smoke이며 TestFlight 업로드는 하지 않았다.

## 2026-09-22 REV0922E01 · iOS 27 정적 분석·패키지 경계 재검증

- 현재 checkout을 iPhoneOS 27.0 generic device 대상으로 `xcodebuild analyze`해 analyzer warning 0·error 0으로 통과했다: `build/validation/REV0922E01/ios27-static-analyze.xcresult`. 유일한 일반 warning은 제품 소스가 아니라 Xcode의 `StoreKitTest.framework` 헤더가 iOS 18부터 deprecated된 `SKPaymentTransactionState`를 선언한 SDK 경고다.
- 현재 Swift Package 테스트는 TaptionPlanCore 94/94, TaptionActivityEngine 28/28, TaptionRouteEngine 38/38, TaptionPlanEngine facade 1/1로 모두 통과했다: `build/validation/REV0922E01/PlanCore.log`, `ActivityEngine.log`, `RouteEngine.log`, `PlanEngine.log`.
- 앱 소스가 하위 Route engine을 직접 import하지 않는 package facade 경계 검사도 통과했다: `scripts/check-app-engine-import-boundary.sh`. 자동 분석은 통과했지만 대규모 diff의 후속 수동 감사는 `temp.md`에서 계속 추적한다.

## 2026-09-22 RRL0922E02 · repository load 실패 후 자동 복구

- durable repository load가 한 번 실패하면 편집을 막는 fail-closed 상태가 `bootstrap()` 재진입까지 차단해, 일시적 파일 보호·접근 오류가 풀려도 앱 재실행 전에는 회복하지 못하던 경로를 수정했다.
- 삭제 generation·commerce·전체 삭제 gate는 그대로 유지하고 repository read만 다시 시도한다. 성공 전에는 fallback snapshot과 편집 차단을 유지하며, 성공하면 durable snapshot을 먼저 복원한 뒤 mutation을 재허용한다. 실패 중 `addPlan`은 되돌린 계획 ID를 성공처럼 반환하지 않고 `nil`을 반환한다.
- focused 2/2와 저장 취소·동시 편집을 포함한 6/6이 통과했다: `build/validation/RRL0922E02/repository-retry-r1.xcresult`, `repository-persistence-regression-r2.xcresult`. 최종 전체 앱 회귀는 1,302 PASS·기존 StoreKit 1 SKIP·0 FAIL·runtime warning 0이다: `full-app-r3.xcresult`.
- iPhoneOS 27.0 SDK generic iOS Debug 빌드·서명·embedded Watch/widget 검증도 error/warning/analyzer warning 0으로 통과했다: `current-ios27-device-build-r4.xcresult`.
- 같은 산출물을 iPhone 14 Pro/iOS 27.2에 사용자 데이터 삭제 없이 교체 설치·foreground launch했고 15초 뒤 앱 PID 1778·widget PID 1779와 지도·시간축 화면을 확인했다: `device-install.json`, `device-launch.json`, `device-process-15s.json`, `device-after-15s.png`.

## 2026-09-22 MFG0922E03 · fail-closed 편집 성공값 일치

- repository load 실패 중 snapshot은 되돌아가지만 메모·지도 메모·사용자 행동분류·대분류·스티커·사용자 교통 위치·자주가는 곳 제안 API가 성공 ID나 `true`를 반환하던 경로를 막았다. 각 사용자 편집 진입점은 공통 mutation gate를 먼저 검사해 저장 불가 상태에서 `nil` 또는 `false`를 반환하며, 지도 메모 draft ID와 자주가는 곳 제안 같은 비-snapshot 상태도 바꾸지 않는다.
- 저장소 실패 차단과 복구 후 편집 재허용 focused 2/2, 전체 앱 1,302 PASS·기존 StoreKit 1 SKIP·0 FAIL·runtime warning 0: `build/validation/MFG0922E03/mutation-gate-focused-r1.xcresult`, `full-app-r2.xcresult`.
- iPhoneOS 27.0 SDK generic Debug 빌드는 error/warning/analyzer warning 0으로 통과했다: `current-ios27-device-build-r3.xcresult`. 동일 산출물을 iPhone 14 Pro/iOS 27.2에 사용자 데이터 삭제 없이 설치·실행해 15초 뒤 앱 PID 1790·widget PID 1791과 지도·9월 22일·시간축 화면을 확인했다: `device-install.json`, `device-process-15s.json`, `device-after-15s.png`.

## 2026-09-22 WCA0922E04 · WatchConnectivity 선활성화

- Watch `prepare()`는 캐시와 durable retry 상태를 복원한 직후 `WCSession` delegate를 등록·활성화한다. legacy ambient 큐의 SQLite 이관은 이어지는 main-actor task에서 수행하고, 완료 후 활성 세션 flush를 다시 호출한다. 따라서 느리거나 실패한 이관이 백그라운드 수신 준비를 막지 않으며 기존 큐는 이관 성공 전까지 제거되지 않는다.
- `WatchSensorQueryPlanTests` 47/47 PASS·실패/스킵/runtime warning 0: `build/validation/WCA0922E04/watch-connectivity-regression-r1.xcresult`.
- iPhoneOS 27.0 SDK generic Debug 빌드·서명·embedded Watch/widget 검증 PASS, error/warning/analyzer warning 0: `build/validation/WCA0922E04/current-ios27-device-build-r2.xcresult`. paired Watch가 없어 실제 백그라운드 수신은 `WSD0922A01` 기기 게이트로 유지한다.

## 2026-09-22 BIO0922E05 · 생체보호 fallback 덮어쓰기 차단

- repository 첫 load 실패 뒤 생체보호 저장이 빈 fallback snapshot을 보호 archive에 쓰지 않도록, cloud backup과 같은 mutation gate를 저장소 접근보다 먼저 적용했다. 차단 시 `CancellationError`를 반환하며 보호 저장소를 열지 않는다.
- 저장소 실패 차단과 복구 focused 2/2 PASS·실패/스킵/runtime warning 0: `build/validation/BIO0922E05/biometric-failclosed-r1.xcresult`.
- iPhoneOS 27.0 SDK generic Debug 빌드·서명·embedded Watch/widget 검증 PASS, error/warning/analyzer warning 0: `build/validation/BIO0922E05/current-ios27-device-build-r1.xcresult`. iPhone 14 Pro/iOS 27.2에 사용자 데이터 삭제 없이 설치·실행했고 15초 뒤 app/widget PID 1845/1846 및 정상 지도 화면을 확인했다. Xcode Device Hub에서도 같은 iPhone 14 Pro/iOS 27.2와 실행 화면을 readback했다: `device-install.json`, `device-processes-15s.json`, `device-after-15s.png`, `device-hub-window.png`.

## 2026-09-22 HKD0922E06 · HealthKit 전체 snapshot 삭제 동기화

- `HKDocumentQuery`와 사용자 약물 전체 snapshot이 이전 UUID cursor 대비 추가·갱신·삭제를 같은 reconciliation 경계에서 계산한다. CDA 문서는 event delta와 sync state를 원자 적용하며, 손상 cursor는 빈 snapshot으로 덮지 않고 오류로 남겨 재시도한다. 수정 전부터 cursor에 없던 과거 삭제 문서는 소급 탐지하지 않는다.
- iPhone 17 Pro/iOS 26.5 Simulator `HealthKitIntegrationTests` 30/30 PASS·실패/스킵/runtime warning 0: `build/validation/HKD0922E06/healthkit-integration-r1.xcresult`.
- iPhoneOS 27.0 SDK generic Debug 빌드·서명·embedded Watch/widget 검증 PASS, error/warning/analyzer warning 0: `build/validation/HKD0922E06/current-ios27-device-build-r1.xcresult`. iPhone 14 Pro/iOS 27.2에 사용자 데이터 삭제 없이 설치·실행했고 15초 뒤 app/widget PID 1860/1861과 정상 지도 화면을 확인했다. 실제 Health 앱의 CDA 삭제 재현은 대표 데이터와 Health 권한이 필요해 별도 기기 게이트로 남긴다.

## 2026-09-22 HKC0922E07 · HealthKit checkpoint fail-closed

- 저장된 history cursor와 `HKQueryAnchor`가 decode되지 않으면 최초 동기화로 되돌리지 않고 명시 오류를 기록한다. legacy Date cursor 호환은 유지하며 기존 cursor·표본·추가/삭제 통계를 그대로 보존해 복구 후 재시도할 수 있다.
- 손상 history cursor의 전체 재수집 차단과 손상 anchor의 초기화 차단 focused 2/2 PASS. 전체 `HealthKitIntegrationTests` 32/32 PASS·실패/스킵/runtime warning 0: `build/validation/HKC0922E07/cursor-failclosed-focused-r2.xcresult`, `healthkit-integration-r3.xcresult`.
- iPhoneOS 27.0 SDK generic Debug 빌드·서명·embedded Watch/widget 검증 PASS, error/warning/analyzer warning 0: `build/validation/HKC0922E07/current-ios27-device-build-r4.xcresult`. iPhone 14 Pro/iOS 27.2에 사용자 데이터 삭제 없이 최신 Debug 1.0 (149)을 설치·실행했고 15초 뒤 app/widget PID 1878/1880 및 정상 지도 화면을 확인했다.

## 2026-09-22 ACT0922E08 · Activity 증분 상태 엔진 호환

- `ActivityClassificationState`가 생성 시점의 taxonomy와 engine configuration을 직렬화한다. `append`는 같은 엔진 상태에서만 tail 빠른 경로를 사용하고, 앱 업데이트 전 상태·구형 payload·수동 생성 상태는 현재 엔진으로 전체 재분류해 evidence와 segment span/sampleCount가 갈라지지 않게 한다.
- 서로 다른 유효 taxonomy 상태와 identity 필드가 없는 legacy Codable 상태 회귀를 포함해 TaptionActivityEngine 30/30 PASS. iPhoneOS 27.0 SDK generic Debug 빌드·서명·embedded Watch/widget 검증도 error/warning/analyzer warning 0으로 통과했다: `build/validation/ACT0922E08/current-ios27-device-build-r1.xcresult`.
- iPhone 14 Pro/iOS 27.2에 앱·사용자 데이터를 삭제하지 않고 최신 Debug 1.0 (149)을 교체 설치·실행했다. 15초 뒤 app/widget PID 1956/1957이 생존했고 Device Hub에서 정상 지도·9월 22일·시간축 화면을 확인했다. taxonomy 교체 자체는 package 회귀가 검증하며 Device Hub smoke는 legacy 사용자 데이터의 launch 호환만 확인한다.

## 2026-09-22 RFP0922E09 · 리뷰 보관 지문 생성 fail-closed

- `ReviewReportArchiveEngine`의 source fingerprint JSON 인코딩이 실패할 때 SHA-256 빈 해시로 대체하던 경로를 제거했다. NaN/Infinity 등 직렬화할 수 없는 원본은 기존 `refreshed` 오류 경계로 전파되어 오래된 일·월·연 리뷰 archive를 정상 캐시처럼 재사용하거나 새 archive를 게시하지 않는다.
- 빈 해시를 가진 기존 archive와 NaN 날씨 원본을 조합한 수정 전 재현은 실패했고, 수정 뒤 해당 회귀와 일·월·연 재생성·취소·과거 일 백업 보존 5/5가 통과했다: `build/validation/RFP0922E09/fingerprint-failclosed-r2.xcresult`, `review-archive-regression-r4.xcresult`.
- iPhoneOS 27.0 SDK generic Debug 빌드·서명·embedded Watch/widget 검증은 error/warning 0으로 통과했다: `build/validation/RFP0922E09/current-ios27-device-build-r5.xcresult`. iPhone 14 Pro/iOS 27.2에 사용자 데이터를 삭제하지 않고 Debug 1.0 (149)을 교체 설치·실행했고 15초 뒤 app/widget PID 1992/1993과 Device Hub의 정상 지도·9월 22일·시간축 화면을 확인했다. 비정상 숫자 주입 자체는 물리 사용자 데이터를 훼손하지 않고 simulator 회귀로 검증했다.

## 2026-09-22 PDS0922E10 · 지도 day snapshot 현재성 fail-closed

- 지도 화면의 day snapshot 현재성 판정을 `PlanDayDataSnapshot.matchesCurrentSource`로 모았다. source revision이 같으면 즉시 허용하고, revision이 다르면 두 fingerprint가 모두 존재하며 같은 경우에만 기존 snapshot을 재사용한다. 따라서 canonical 64MiB 상한 초과로 fingerprint가 둘 다 nil인 상태가 `nil == nil`로 오래된 일자 투영을 통과하지 않는다.
- 64MiB 초과 일자 원본과 서로 다른 revision을 사용한 수정 전 회귀가 `XCTAssertFalse`로 결함을 재현했고, 수정 뒤 단독 1/1 및 fingerprint·reprojection 인접 회귀 3/3이 통과했다: `build/validation/PDS0922E10/nil-fingerprint-currentness-r3.xcresult`, `day-snapshot-regression-r5.xcresult`.
- iPhoneOS 27.0 SDK generic Debug 빌드·서명·embedded Watch/widget 검증은 error/warning 0으로 통과했다: `build/validation/PDS0922E10/current-ios27-device-build-r6.xcresult`. iPhone 14 Pro/iOS 27.2에 사용자 데이터를 삭제하지 않고 Debug 1.0 (149)을 교체 설치·실행했고 15초 뒤 app/widget PID 2127/2128과 Device Hub의 정상 지도·시간축 화면을 확인했다.

## 2026-09-22 AST0922E11 · Activity persisted-state tail 복구

- 같은 engine identity를 가진 persisted state라도 마지막 segment 분류와 마지막 evidence의 현재 엔진 재분류가 다르면 증분 tail을 조립하지 않고 전체 evidence를 재분류한다. 손상·부분 저장 state의 stale category/span/sampleCount가 append 뒤 유지되지 않는다.
- 걷기 evidence에 수면 segment를 주입한 수정 전 회귀가 incremental/full 불일치를 검출했고, 수정 뒤 단독 1/1 및 TaptionActivityEngine 전체 31/31이 통과했다: `build/validation/AST0922E11/stale-segment-r1.log`, `stale-segment-r2.log`, `ActivityEngine-full-r3.log`.
- iPhoneOS 27.0 SDK generic Debug 빌드·서명·embedded Watch/widget 검증은 error/warning 0으로 통과했다: `build/validation/AST0922E11/current-ios27-device-build-r4.xcresult`. iPhone 14 Pro/iOS 27.2에 사용자 데이터를 삭제하지 않고 Debug 1.0 (149)을 교체 설치·실행했고 15초 뒤 app/widget PID 2150/2151과 Device Hub의 정상 지도·시간축 화면을 확인했다.

## 2026-09-22 HQR0922E12 · HealthKit 장기 record overlap 조회

- 고정 7일 lookback을 제거하고 저장된 HealthKit record의 최대 duration을 SQLite metadata로 단조 증가 유지한다. 조회는 이 duration만큼만 과거 day를 읽은 뒤 실제 interval intersection을 적용해, 7일보다 오래 시작된 record도 현재 일자와 겹치면 반환한다.
- metadata가 없는 기존 DB는 HealthKit event domain을 한 번 스캔해 최대 duration을 backfill하고 이후 bounded query를 사용한다. 삭제는 최대값을 줄이지 않아 stale underestimate를 만들지 않으며 전체 데이터 삭제는 DayStore metadata도 함께 제거한다.
- 30일 span 수정 전 회귀가 누락을 검출했고, 신규 저장·legacy backfill 2/2 및 `HealthKitIntegrationTests` 전체 34/34가 통과했다: `build/validation/HQR0922E12/long-span-query-r1.xcresult`, `long-span-query-r3.xcresult`, `healthkit-integration-r4.xcresult`.
- iPhoneOS 27.0 SDK generic Debug 빌드·서명·embedded Watch/widget 검증은 error/warning 0으로 통과했다: `build/validation/HQR0922E12/current-ios27-device-build-r5.xcresult`. iPhone 14 Pro/iOS 27.2에 사용자 데이터를 삭제하지 않고 Debug 1.0 (149)을 교체 설치·실행했고 15초 뒤 app/widget PID 2176/2178과 Device Hub의 정상 지도·시간축 화면을 확인했다.

## 2026-09-22 KCR0922E13 · Cloud recovery key fallback 보존

- CloudKit에서 기존 복구 키를 읽거나 새 키 저장을 확인한 경로는 먼저 로컬 Keychain에 키를 저장한 뒤에만 legacy iCloud Drive fallback을 삭제한다. Keychain 저장이 실패하면 오류를 전파하고 기존 fallback 키를 남겨 다음 오프라인 복원 가능성을 보존한다.
- 수정 전 회귀는 Keychain 쓰기 실패가 무시되고 fallback이 삭제되는 것을 검출했다. 수정 후 실패 시 보존·성공 시 이전 정리 2건과 `SecurityBackupCoreTests` 99/99가 통과했다: `build/validation/KCR0922E13/keychain-preservation-prefx-r1.xcresult`, `keychain-preservation-r2.xcresult`, `security-backup-r3.xcresult`.
- 전체 회귀 1,312건은 1,311 PASS·기존 StoreKit 1 SKIP·0 FAIL·runtime warning 0이다: `build/validation/KCR0922E13/full-app-r5.xcresult`. iPhoneOS 27.0 SDK 물리 기기 Debug 빌드·서명·embedded Watch/widget 검증도 warning/error 0으로 통과했다: `current-ios27-device-build-r4.xcresult`.
- iPhone 14 Pro/iOS 27.2에 사용자 데이터를 삭제하지 않고 Debug 1.0 (149)를 교체 설치·전면 실행했다. 15초 뒤 app/widget PID 2197/2198이 생존했고 Device Hub에서 선택 기기 iOS 27.2와 정상 지도·9월 22일·시간축 화면을 확인했다: `device-install.json`, `device-launch.json`, `device-apps.json`, `device-processes-15s.json`, `device-hub-iphone.png`.

## 2026-09-22 PCC0922E14 · Plan-day projection 취소 전파

- `PlanDayLoadCoordinator`의 source fingerprint와 snapshot projection detached worker에 부모 취소를 전달하고, source filter·readings projection·정렬·fingerprint 계산에 협력적 cancellation checkpoint를 적용했다. 취소 시 무거운 빈 snapshot을 다시 계산하지 않고 비완료 snapshot을 반환해 cache·DB 저장을 막는다.
- 수정 전 회귀는 cancellation closure가 한 번도 호출되지 않는 것을 검출했다. 수정 후 직접 취소와 sensor load 직후 부모 취소 회귀 2/2, `SensorDayStoreTests` 기존 전체 86/86, 앱 전체 1,314건 중 1,313 PASS·기존 StoreKit 1 SKIP·0 FAIL·runtime warning 0이다: `build/validation/PCC0922E14/prefix-r1.xcresult`, `cancellation-r4.xcresult`, `sensor-day-r3.xcresult`, `full-app-r5.xcresult`.
- iPhoneOS 27.0 SDK 물리 기기 Debug 빌드·서명·embedded Watch/widget 검증은 warning/error 0으로 통과했다: `current-ios27-device-build-r6.xcresult`. iPhone 14 Pro/iOS 27.2에 사용자 데이터를 삭제하지 않고 Debug 1.0 (149)를 교체 설치·실행했으며, 15초 뒤 app/widget PID 2231/2232와 Device Hub의 정상 9월 22일 지도·시간축 화면을 확인했다: `device-install.json`, `device-launch.json`, `device-apps.json`, `device-processes-15s.json`, `device-hub-iphone.png`.

## 2026-09-22 MSM0922E15 · 앱 로드 migration 선형화·취소 전파

- `MemoShellPlanMigration`이 plan마다 전체 actual/link를 재검색하던 O(plans × (actuals + links)) 경로를 actual 참조 ID와 link node ID의 단일 Set 인덱스로 교체했다. 메모와 계획 결과는 로컬 배열에서 완성한 뒤 마지막에 함께 반영해 취소 시 원본 snapshot을 변경하지 않는다.
- bootstrap/deep link/reset의 snapshot 정규화를 공용 detached worker로 합치고 부모 취소를 전달했다. repeat plan dedup, legacy memo migration, record relationship 정규화, 자동 분류 잠금의 대량 루프에도 cancellation checkpoint를 적용했다.
- 취소·기존 strict migration·앱 load 회귀 8/8, 최종 소스 전체 1,316건 중 1,315 PASS·기존 StoreKit 1 SKIP·0 FAIL·runtime warning 0이다: `build/validation/MSM0922E15/memo-bootstrap-r9.xcresult`, `full-app-r10.xcresult`. 수정 전 회귀 시도 2회는 XCTest runner가 시작되지 않아 결과 근거에서 제외했다.
- iPhoneOS 27.0 SDK 물리 기기 Debug 빌드·서명·embedded Watch/widget 검증은 warning/error 0으로 통과했다: `current-ios27-device-build-r11.xcresult`. iPhone 14 Pro/iOS 27.2에 사용자 데이터를 삭제하지 않고 Debug 1.0 (149)를 교체 설치·실행했으며, 15초 뒤 app/widget PID 2281/2282와 Device Hub의 정상 9월 22일 지도·시간축 화면을 확인했다: `device-install-current.json`, `device-launch-current.json`, `device-apps-current.json`, `device-processes-current-15s.json`, `device-hub-iphone-current.png`.

## 2026-09-22 ALM0922E16 · 자동 분류 잠금 병합 interval index

- 활동·이동 잠금 병합이 fresh마다 locked 전체를 검색하고 retained 판정에서 다시 역검색하던 O(locked×fresh) 경로를 시작 시각 정렬·prefix maximum end interval index로 교체했다. 활동은 source별 index를 사용하고, 20% overlap·최대 겹침·동률 시 기존 입력순 우선·지하철 검증 규칙은 유지한다.
- 신규 대량 비겹침·동률 회귀와 기존 잠금 회귀 7/7, `FeatureEngineTests` 611건 중 610 PASS·기존 StoreKit 1 SKIP, 전체 앱 1,319건 중 1,318 PASS·1 SKIP·0 FAIL·runtime warning 0이다: `build/validation/ALM0922E16/focused-r1.xcresult`, `feature-engine-r2.xcresult`, `full-app-r3.xcresult`.
- iPhoneOS 27.0 SDK에서 iPhone 14 Pro/iOS 27.2 대상 Debug 빌드·서명·embedded Watch/widget 검증은 warning/error/analyzer warning 0으로 통과했다: `ios27-device-build-r4.xcresult`. 사용자 데이터를 삭제하지 않고 Debug 1.0 (149)를 교체 설치·실행했으며 15초 뒤 app/widget PID 2306/2307과 Device Hub의 정상 9월 22일 지도·시간축 화면을 확인했다: `device-install-r5.json`, `device-launch-r5.json`, `device-processes-15s-r5.json`, `device-app-r5.json`, `iphone-current-r5.png`, `device-hub-iphone-current-r6.png`.

## 2026-09-22 BRI0922E17 · 백업 fallback endpoint index

- `PlanBackupRouteFallbackEngine`이 ID 없는 travel마다 전체 places를 출발·도착 후보로 두 번 검색하던 O(travel×places) 경로를 종료·시작 시각 정렬 endpoint index의 binary lookup으로 교체했다. 명시적 place ID와 지하철 좌표 우선, 2시간 경계, 동일 시각 첫 입력 우선 규칙은 유지한다.
- 동률·1,000개 대량 입력과 기존 fallback 회귀 8/8, `SecurityBackupCoreTests` 101/101, 전체 앱 1,321건 중 1,320 PASS·기존 StoreKit 1 SKIP·0 FAIL·runtime warning 0이다: `build/validation/BRI0922E17/focused-r1.xcresult`, `security-backup-r2.xcresult`, `full-app-r3.xcresult`.
- iPhoneOS 27.0 SDK에서 iPhone 14 Pro/iOS 27.2 대상 Debug 빌드·서명·embedded Watch/widget 검증은 warning/error/analyzer warning 0이다: `ios27-device-build-r4.xcresult`. 사용자 데이터를 삭제하지 않고 Debug 1.0 (149)를 교체 설치·실행했으며 15초 뒤 app/widget PID 2343/2345와 Device Hub의 정상 9월 22일 지도·시간축 화면을 확인했다: `device-install-r5.json`, `device-launch-r5.json`, `device-processes-15s-r5.json`, `device-app-r5.json`, `iphone-current-r5.png`, `device-hub-current-r5.png`.

## 2026-09-22 MRI0922E18 · 이동 구간 evidence index

- `MovementRouteBuilder`가 장소 쌍마다 전체 센서 배열을 세 번, HealthKit 근거를 한 번 반복 순회하던 `O(stays × evidence)` 경로를 timestamp binary range와 interval overlap index로 교체했다.
- 기존 센서 입력 순서, 시작·종료 경계 포함, HealthKit strict overlap, Taption WBS 공항 endpoint 비행 판정은 보존했다. 1,000개 장소·센서·HealthKit 비겹침 입력은 대규모 후보 조회 상한 회귀로 고정했다.
- 실행 경계는 앱 센서 모델과 WBS endpoint 정책을 함께 사용하므로 추가 Swift Package 분리 없이 app Core에 유지했다.

## 2026-09-22 SRI0922E19 · SensorFusion 공용 시간 인덱스

- 이동 구간 전용이던 timestamp/interval lookup을 `SensorEvidenceTimeIndex`로 공용화해 층 보정, 자주 가는 장소, 층 이동, 지하철 후보, Apple 모션 병합이 장소·구간마다 전체 센서 배열을 다시 훑던 `O(spans × evidence)` 경로를 제거했다.
- 센서 조회의 시작·종료 포함, 원래 입력 순서와 HealthKit strict overlap을 보존한다. 공용 index는 앱 내부 센서·Health 모델에 결합되므로 별도 Swift Package 공개 API로 확장하지 않고 app Core 내부 라이브러리 경계로 유지한다.
- 1,000개 비겹침 조회 상한과 기존 층·장소·지하철·모션 회귀를 포함해 집중 8/8, `FeatureEngineTests` 614 PASS·기존 StoreKit 1 SKIP, 전체 앱 1,324 PASS·1 SKIP·0 FAIL·runtime warning 0을 확인했다.

## 2026-09-22 MAI0922E20 · Apple 모션 기록 sweep index

- `AppleDeviceGroundTruthEngine.applyingMotionHistory`가 센서 표본마다 모든 모션 구간을 역검색하던 `O(readings × activities)` 경로를 시작 시각 정렬과 최신 시작 우선 max-heap sweep으로 교체했다.
- 시작·종료 시각 포함, unknown 무시, 기존 모션 보존, 원본 불변을 유지한다. 같은 시작 시각의 겹친 구간은 후입력을 우선해 결과를 결정적으로 만들고 동일 시각 센서도 입력 순서를 유지한다.
- 이 투영은 앱의 `SensorReading`·`MotionActivityRecord`를 직접 갱신하는 내부 경계라 별도 공개 Package로 옮기지 않았다. 1,000×1,000 비겹침 조회 상한, 전체 기능·앱 회귀와 iOS 27.2 실기기 실행을 통과했다.

## 2026-09-22 MFI0922E21 · 모션 계열 보정 시간 인덱스

- `AppleDeviceGroundTruthEngine.enforcingMotionFamily`가 보행 계열 이동 조각마다 모든 자동차 모션 구간과 센서 표본을 재검색하던 `O(segments × (activities + readings))` 경로를 자동차 겹침 prefix integral과 `SensorEvidenceTimeIndex` 조회로 교체했다.
- 겹친 자동차 구간의 중복 duration 합산, 센서 시작·종료 경계 포함, 분당 20걸음 임계값과 원본 불변을 유지한다. 1,000개 이동 조각의 비겹침 조회를 bounded work 회귀로 고정했다.
- 앱 내부 센서·모션 모델에 결합된 보정 경계라 별도 공개 Package로 옮기지 않았다. 집중 4/4, `FeatureEngineTests` 618 PASS·기존 StoreKit 1 SKIP, 전체 앱 1,328 PASS·1 SKIP·0 FAIL·runtime warning 0과 iOS 27.2 실기기 실행을 통과했다.

## 2026-09-22 STI0922E22 · 이동 병합 체류 interval index

- `AppleDeviceGroundTruthEngine.coalescingTravel`이 병합 후보 이동마다 전체 체류를 다시 훑던 `O(segments × stays)` 경로를 체류 시작 시각과 prefix maximum 종료 시각을 사용하는 binary lookup으로 교체했다.
- 정확히 180초인 체류 겹침, 짧은 체류 제외, 비정렬 입력과 기존 이동 병합 결과를 보존한다. 1,000개 이동·체류의 비겹침 조회를 bounded work 회귀로 고정했다.
- 앱 내부 `PlaceStay`·`TravelSegment` 정책에 결합된 경계라 별도 공개 Package로 옮기지 않았다. 집중 4/4와 `FeatureEngineTests` 620 PASS·기존 StoreKit 1 SKIP·0 FAIL·runtime warning 0, iOS 27.2 실기기 실행을 통과했다.

## 2026-09-22 AAI0922E23 · 모션 실제기록 중복 interval index

- `MotionActivityActualEngine.records`가 병합된 모션 구간마다 모든 기존 HealthKit·Apple Watch·장소 기록을 다시 훑던 `O(activities × existing)` 경로를 정지용·이동용 interval index의 binary candidate lookup으로 교체했다.
- 활동 길이의 50% 또는 30초 중 작은 겹침 임계값, 정확한 임계 경계, HealthKit/Watch 우선과 장소 문맥이 정지에만 우선하는 규칙을 보존한다. 1,000개 모션·기존 기록의 비겹침 조회를 bounded work 회귀로 고정했다.
- 앱 내부 `ActualRecord`·`MotionActivityRecord` 정책에 결합된 경계라 별도 공개 Package로 옮기지 않았다. 집중 4/4와 `FeatureEngineTests` 622 PASS·기존 StoreKit 1 SKIP·0 FAIL·runtime warning 0, iOS 27.2 실기기 실행을 통과했다.

## 2026-09-22 MTI0922E24 · 이동 병합 공용 interval index

- 앱 내부 `TimeSpanValueIndex`를 추출해 `MotionActivityActualEngine`과 `AppleDeviceGroundTruthEngine.mergingTravel`이 공유한다. strict overlap, 입력 순서, 최대 겹침 동률 시 첫 GPS, GPS > Watch > motion 우선순위와 원본 불변을 유지한다. 앱 모델에 결합된 경계라 공개 Swift Package API로 올리지 않았다.
- GPS·지하철·Watch·Core Motion 이동 후보는 interval index로 제한하고 센서·HealthKit 증거는 기존 `SensorEvidenceTimeIndex`를 공유한다. 비겹침 1,000×1,000 입력의 후보 검사 상한을 회귀로 고정했다.
- 집중 회귀 9/9와 `FeatureEngineTests` 629건 중 628 PASS·기존 StoreKit 1 SKIP·0 FAIL·xcresult runtime warning 0. iPhoneOS 27.0 SDK 물리 기기 Debug 빌드·deep/strict 서명·embedded Watch/widget 검증도 error/warning/analyzer warning 0으로 통과했다. 상세 증거는 `test.md`와 `build/validation/MTI0922E24/`에 기록했다.

## 2026-09-22 HPT0922A01 · backup diagnostics scan off MainActor

- iPhone 14 Pro build 149의 9/21 HangTracer는 launch 중 `cloudBackupPayload`가 diagnostics 파일을 읽고 개인 건강 필드를 redaction하느라 main runloop를 586ms 점유한 짧은 hang을 기록했다. 이 보고서는 30초 watchdog과 별개이며 현재 9/22 binary에서 재현됐다는 뜻은 아니다.
- `combinedLog`, redaction, backup snapshot/route/payload 구성은 utility detached task에서 수행한다. `DiagnosticsLogSupportTests` 10/10 PASS (`build/validation/HPT0922A01/DiagnosticsLogSupport-final.xcresult`), generic iOS Debug build exit 0. 최신 수정본의 물리 기기 OS-log readback은 BUG1909R01 기기 게이트로 남는다.

## 2026-09-20 DCE0920A01 · 미사용 route/timeline 코드 정리

- 호출처 없는 `DurationAxisText`, `FeatureSettingsStore`, `SensorCollectionLiveActivityError`, `WidgetActionService`, `RouteTimelineRenderProjection`, `RouteElement`/`RouteTimelineEngine`, `MovementCorrectionStore`를 제거했다. `GPSLoggerRouteFilter` wrapper는 삭제하고 기존 경계/정확도 테스트를 `TaptionRouteEngineAdapter.filteredReadings`에 직접 연결했다. production 호출처가 없던 speed-gradient 구현과 테스트도 제거해 지도 UI 동작은 바꾸지 않았다.
- `AppFeatureSettings`의 repository 저장/복원 경로와 문서상 향후 ML handoff 계약인 `WatchBehaviorTrainingSample`은 보존했다. RouteTimelineDataTests 76/76 PASS (`build/validation/DCE0920A01/RouteTimelineData-retry.xcresult`), generic iOS Debug build PASS·exit 0 (`build/validation/DCE0920A01/DerivedData`).

## 2026-09-13 TP0913F001 · GPS 공백 수정 149 배포

- E001 수정본 소스 `c4602ab` main push 및 네 번들 1.0(149) 배포 완료. 전체 회귀 1,113 PASS·기존 StoreKit 1 SKIP·0 FAIL, Debug·archive/export PASS. Apple VALID, 기존 Internal API 연결·웹 빌드/테스터 노출 확인 완료. 실제 설치/동작은 test.md의 별도 게이트로 유지한다.

## 2026-09-13 TP0913E001 · GPS 누락 구간 전용 예상 경로

- 예상 경로는 신뢰 가능한 실제 GPS 두 점 사이의 기존 시간/거리 단절 기준을 만족하는 구간에만 생성한다. 장소·일정·미확정 지하철 저장 노선만으로 전체 경로를 생성하지 않는다. GPS 전무·한쪽 끝만 존재·정차·명시적 수집 종료 및 확정 경로 중첩은 제외한다.
- 한 이동의 복수 공백을 독립 요청으로 처리하고, 서로 다른 공백 시간을 합쳐 정상 GPS 구간까지 늘리지 않는다. GPS가 뒤늦게 채워지면 해당 요청은 사라진다. WBS 지도 재생도 같은 요청과 공백 시간만 사용하며, 삭제된 장소 기반 예상 경로 생성/병합의 미사용 함수는 제거했다.
- 공백 ID는 부모 이동 ID와 저장 형식 기준 Unix 날짜 값으로 결정해 JSON 날짜 왕복 후에도 유지한다. 지도 overlay는 공백 ID와 부모 이동 ID를 구분하고, 캐시 알고리즘 v5로 이전 전체 예상 경로 preview를 무효화한다. 기존 요청/캐시 수 제한·원본 GPS·확정 노선·정차와 UI 배치는 보존했다.
- 새 TestFlight 배포는 이 요청 범위에 포함하지 않는다. 자동 검증과 실기기 검증은 test.md에 별도로 기록한다.

## 2026-09-13 TP0913D001 / TP0913C002 · 후보 148 백업 병합

- 금요일 원본 재조회 수정과 백업 병합 수정을 148에 통합한다. 최신 147 로그 `TaptionLogs-20260913-005952.txt`에서 raw 포함 자동 백업 17:26:37Z, 수동 17:26:52Z/17:27:03Z의 invalidArchive 종료가 확인됐다. snapshot-only 자동 백업의 17:14:41Z 성공과 구분한다.
- Date의 reference epoch와 Unix seconds JSON 사이 왕복에서 약 0.000000119초의 정밀도 차이를 재현했다. 같은 UUID의 같은 저장 표현을 엄격 Equatable 비교만으로 거부하던 병합을 수정했다. 값이 다른 경우에만 sorted-key 백업 JSON을 비교하며, 저장 표현이 다른 실제 충돌은 계속 거부한다. 시간 허용 오차나 필드 무시, 기존 기록 덮어쓰기 완화는 하지 않는다.
- 연속 full-raw 월별 백업 회귀는 첫 백업에서 읽은 날짜와 두 번째 원본 날짜의 불일치를 검증한다. 실제 충돌에는 `raw_sensor_archive_merge_conflict`와 기록 타입만 남겨 기기 실패 경로를 구분한다. PIN·키·UUID·좌표·payload는 로그에 넣지 않는다.
- 재현한 코드 결함과 실제 기기 오류의 정확한 실패 단계는 별개다. 실제 iCloud 백업·복원 성공과 금요일 화면 복구는 148 설치 후 별도 확인하며, 기존 원본/백업·PIN·키는 변경하지 않았다.
- 소스 `03365a4`의 최종 앱 회귀 1,105 PASS·기존 StoreKit 1 SKIP·0 FAIL, Debug 및 Release archive/export PASS. TestFlight 148 업로드/처리 VALID·Internal API 연결·웹 빌드/테스터 노출까지 완료했다. 실기기 결과는 test.md의 별도 게이트로 유지한다.

## 2026-09-13 TP0913C001 · 과거 지도 원본 재조회

- primary 센서 저장소와 V3 materialized 원본 digest는 별개다. 앱 재실행 후 과거 materialization의 V3 digest가 유효해도 primary 센서 원본이 최신이라는 보장은 없었다. 147 기기 로그에서 금요일 GPS 1,687건과 지도 캐시 57건 불일치를 확인했다.
- 지도는 기존 bounded preview를 먼저 보여준 뒤 `refreshRawReadings`로 primary 원본을 다시 읽는다. `forceReload`의 센서 재분류 호출과 분리해 즉시 화면 경로를 막지 않는다. 로딩 중 분류 source가 바뀌면 방금 읽은 원본으로 최신 source를 재투영한다.
- 지도 화살표/달력의 직접 날짜 대입도 선택일 갱신을 예약하도록 `selectedDate`의 실제 일자 변경 경계로 예약을 이동했다. 기존 debounce·foreground 제한은 유지하고 시간표의 중복 예약은 제거했다.
- 관련 최종 회귀 56/56 PASS·0 FAIL·0 SKIP, Debug generic iOS PASS. 재투영은 화면 반영 직전 동기 1회이며 반복 원본 조회를 하지 않는다. TP0913C002 백업은 최신 수동 작업 종료 로그가 없어 원인 확정 전이며 코드/원본을 변경하지 않았다. 실기기·배포 상태는 test.md에 별도로 기록한다.

## 2026-09-13 TP0913B001 · 화면 복귀·저장·일자 조회 구조 개편

- 승인 범위는 `temp.md` 통합 구현과 TestFlight 내부 배포다. 구매 잠금 해제 상태를 유지하고 계약 동의·심사 제출·유료화는 변경하지 않는다.
- 최신 iCloud `TaptionLogs-20260912-230334.txt`는 build 146이다. 날짜 로딩 최대 230,576ms, snapshot 대기 197,033ms, 센서 읽기 187,664ms, 통합 갱신 420,505ms·actuals 65,853건을 확인했다. 이 경과 시간에는 앱 중단·재개가 섞일 수 있다. `previous_session_unfinished`만으로 watchdog·메모리 종료·DEAD10CC를 확정하지 않는다. 일치하는 최신 OS crash report는 현재 Mac·ASC에서 확보되지 않았다.
- 로컬 snapshot을 먼저 공개한 뒤 불변 복사본의 정규화를 별도 작업에서 수행한다. 그동안 변경되면 최신 snapshot으로 재시도한다. 센서 갱신은 같은 일자/원본 revision/설정 요청을 합치고 교체·background 취소 후 파생값 반영을 차단한다.
- 일반 저장은 FIFO 로컬 커밋을 먼저 끝낸다. 접수된 로컬 편집은 호출 화면 task 취소와 수명을 분리하고, 최신 revision이 달라졌으면 오래된 값을 메모리에 다시 대입하거나 rollback하지 않는다. timestamp-only 저장은 전체 이력 비교·정규화를 재실행하지 않는다. background는 raw checkpoint와 강제 로컬 flush만 우선 수행한다.
- 보고서·CloudKit 후처리는 foreground에서 합쳐 지연 실행한다. 보고서 interval은 동일 timeline revision에서만 적용한다. 원본 센서 저장과 자동 기록 provenance는 기존 경계를 유지한다.
- 일자 preview API는 bounded last-known 메모리/SQLite materialized row만 읽는다. 날짜·버전·압축/checksum·삭제 generation 검증은 유지하고, stale source/raw 허용은 preview에만 한정한다. normal load 캐시를 오염시키지 않으며 fresh 결과 실패 시 마지막 완전 화면을 보존한다. projection/fingerprint 계산은 메인 스레드 밖으로 옮기고 저장 직후 중복 readback을 제거했다.
- iCloud 파일 읽기 불가·미다운로드·크기 변화와 JSON/무결성 실패를 분리한다. 최신 다운로드가 준비되지 않은 파일은 다운로드 요청 후 재시도하며, 부분 archive 목록으로 기존 월간 데이터를 덮지 않는다. 후속 정상 readback은 일시적 접근/동기화 상태 추론을 뒷받침하지만 과거 실패 원인의 OS 수준 확정은 아니다.
- 자동 foreground snapshot 백업의 복호화·병합·인코딩·압축·암호화를 Sendable 입력의 별도 `.utility` 계산으로 분리했다. 파일 접근/최종 쓰기는 MainActor 경계에 유지하고 PIN 변경·백업 삭제 preparation revision·데이터 삭제 generation·이전 월간 archive identity를 커밋 전에 재검증한다. 명시적 raw 전체 백업/복원은 별도 경로이며 비동기화 완료로 보고하지 않는다.
- 최종 앱 회귀 1,098건: 1,097 PASS·기존 StoreKit 1 SKIP·0 FAIL. 패키지 89/89 PASS. `unit-final.xcresult` summary로 개수를 확인했다. 자동 측정은 memory preview p95 0.005ms, 30일 일자 API cold p95 28.821ms/warm 0.092ms이며 실기기 frame 성능은 아니다.
- 검증·배포 증거는 `test.md`와 `build/validation/TP0913B001`에 기록한다. 실기기 설치·복귀 30회·30분 동작·새 iCloud 로그·PIN 복원은 자동 테스트와 별도다.
- 소스 `4631c77` main push, 147 Release archive/export·서명·검증·업로드·Apple `VALID`·Internal API 연결/readback 완료. Chrome Plan 그룹은 빈 페이지여서 웹 빌드/테스터 노출 게이트가 남아 있다. 실기기 unavailable로 실제 충돌 원인 확정·수정 후 재현 검증도 미완료다.

## 2026-09-11 TP0911B002 · CancellationError 저장 오류 통합 수정 및 TestFlight build 146

- 새 화면의 `센서 기록을 저장하지 못했습니다` 팝업과 TP0911A001의 `변경 내용을 저장하지 못했습니다` 팝업은 iCloud 권한 문제가 아니라 취소된 저장 작업을 실제 저장 실패로 승격하던 공통 경계가 원인이었다. 사용자가 올린 `TaptionLogs-20260911-105220.txt`(build 145)를 iCloud에서 readback했고, `local_persistence_failed` 4건이 모두 `CancellationError`였으며 `route_readings_load_failed`와 장시간 `background_refresh cancelled`도 함께 확인됐다.
- `AppModel`의 활동 저장 readback, 공통 `persist()`, 센서 로컬 snapshot 저장에서 `CancellationError`를 정상 취소로 종료하고 실제 오류만 기존 사용자 안내·진단 로그로 남기도록 최소 수정했다. 소스 커밋은 `6fd7326`이며 UI·iCloud 백업 포맷·기존 데이터는 변경하지 않았다.
- 관련 XCTest 2/2 PASS·0 FAIL·0 SKIP: 활동 편집 즉시 재편집과 저장 취소 무오류 노출 회귀. generic iOS Debug build도 exit 0으로 통과했다.
- Release archive/export 성공: `/var/folders/q1/0p9tcvnx7yx5l12y55zm4tdm0000gn/T/TP0911B002.WWAQCR1Zh2/TaptionPlan.xcarchive`, `/var/folders/q1/0p9tcvnx7yx5l12y55zm4tdm0000gn/T/TP0911B002.WWAQCR1Zh2/Export/TaptionPlan.ipa`; 네 번들 모두 `1.0 (146)`, IPA SHA-256 `6ae9d0761372eacffb4ca11cb0955b29e70c5bc031979aa773cfb195703583b6`, deep/strict 서명·Production iCloud entitlement 확인.
- `altool --validate-app` 및 업로드 성공. Delivery UUID `fca81e99-261d-42c7-8bd8-4bed334e6429`는 App Store Connect에서 `VALID`·`expired=false`다. `TP Taption Plan 내부 테스트`에 build 146을 연결했고 API에서 그룹 build 146과 내부 테스터 1명(`INSTALLED`)을 readback했다.
- Chrome App Store Connect 그룹 URL은 현재 `Unauthenticated`여서 브라우저 UI의 build/tester 노출은 확인하지 못했다. `INSTALLED`는 TestFlight 146 설치·실행 증거가 아니며, 실제 TestFlight 클라이언트 설치·launch·터치와 최신 iCloud 로그 readback은 별도 실기기 게이트다.

## 2026-09-10 TP0910A004 · iCloud 진단 오류·지연 수정 및 TestFlight build 145

- Plan iCloud Drive에는 월간 백업·raw sensor 파일만 있고 `TaptionLogs` readback은 없었다. 최신 Simulator 진단에서 반복된 `previous_session_unfinished` 3건은 비정상 종료 사실을 숨기지 않되 `.notice`로 낮췄다. 과거 로그의 부분 백업 누락·복구 가능한 legacy reading은 `.notice`, 복구 불가 reading과 후보가 모두 무효인 백업은 `.error`로 남겼다.
- 날짜 지도 로딩 지연 로그에서 map cache와 공유 `taption-data-v2.sqlite` 대기가 겹치던 경로를 확인했다. 선택적 지도 cache를 별도 `taption-map-cache-v1.sqlite`로 분리해 기존 백업·정본 데이터는 건드리지 않는다.
- 관련 XCTest 108/108 PASS·0 FAIL·0 SKIP, generic iOS Simulator Debug build PASS. Release archive/export 성공: `/private/tmp/TP0910A004.4Wj1gl/TaptionPlan.xcarchive`, `/private/tmp/TP0910A004.4Wj1gl/Export/TaptionPlan.ipa`; 앱·iOS Widget·Watch 앱·Watch Widget 모두 `1.0 (145)`, Apple Distribution, Production iCloud/TestFlight entitlement, IPA SHA-256 `c67ab9f15f7a32cf6e417da2bd9f6a676c7bb04442667c86ea4d4bad80bf2243`다.
- `altool --validate-app` 및 업로드 성공. Delivery UUID `a5a3ba33-8252-4fbb-b7c4-0104d59b7c57`, App Store Connect 처리 `VALID`·`APP_STORE_ELIGIBLE`·`expired=false`. `TP Taption Plan 내부 테스트`에 build 145를 연결했고 API에서 그룹 build 105개와 내부 테스터 1명(`INSTALLED`)을 readback했다.
- Chrome App Store Connect는 로그인 화면으로 열려 그룹·테스터 브라우저 UI readback은 미완료다. TestFlight 클라이언트 설치·launch·터치와 실제 기기 `로그 보내기` 후 iCloud `TaptionLogs` readback도 별도 게이트다.

## 2026-09-09 CRH909A001 · 실기기 크래시 진단 및 iCloud 로그 전송

- iPhone 14 Pro의 systemCrashLogs에서 확인된 TaptionPlan crash report는 `2026-09-08 15:02:01`, build 140, iOS 26.6.1이며 `EXC_CRASH/SIGKILL`, `RUNNINGBOARD/0xDEAD10CC`였다. Swift 예외나 faulting frame이 아니라 iOS 실행 관리자가 종료한 기록이며, 현재 build 142의 새 crash report는 확인되지 않았다. 원본은 `/tmp/CRH909A001/TaptionPlan-2026-09-08-150201.ips`에 보존했다.
- 다음 실행이 정상 종료 없이 끝났는지 `TaptionPlanDiagnosticsSession`이 기록하고, 설정의 기존 `로그 보내기`에서 iPhone·Watch 로그와 직전 비정상 종료 상태를 iCloud Drive `Documents/TaptionLogs`로 내보내도록 보강했다. 개인정보·좌표·원시 건강값은 기존 redaction을 유지한다. 기존 백업 파일은 건드리지 않는다.
- `DiagnosticsLogSupportTests` 10/10 PASS, iOS generic Debug build PASS. 실기기에는 Apple Development Debug `1.0 (144)`를 설치하고 launch PID를 확인했다. Release archive/export·altool 검증·업로드도 완료했고, App Store Connect에서 build 144 `제출 준비 완료`를 확인했다. `TP Taption Plan 내부 테스트`에 연결 후 그룹 빌드 화면에서 144와 1명 테스터 화면을 readback했다. 테스터 설치 표시는 아직 142다.

## 2026-09-08 REV908A001 · 다방면 코드리뷰 결과

- 저장·백업: snapshot 복원·저장에도 raw와 같은 크기 제한 검증을 추가해 대형 payload 메모리 할당을 거부한다. version 1 outer metadata 인증과 PIN 변경 migration은 기존 형식 호환을 깨지 않도록 별도 판매/복원 게이트로 남긴다.
- 지도·활동: 현재 위치 졸라맨이 MapKit stale 좌표로 덮어써지던 경로를 제거하고 모델 좌표 단일 소스를 사용한다. 등록 장소 좌표·업무·식사·수업·취미 소품 전용 렌더러는 유지한다.
- Watch·Live Activity: command token 단회 소비·source allowlist·현재 활동명 전달 및 구형 payload optional decode를 확인했다. 추가 결함은 확인하지 않았다.
- 릴리스·상거래: 구매 잠금 정책과 TestFlight entitlement를 확인했다. 계약·심사·유료화는 변경하지 않는다.
- 리뷰 결론: 백업 크기 제한과 현재 위치 좌표 단일 소스만 수정했다. Dynamic Island는 catalog title fallback을 보강했다. 현재 build 143을 새로 검증한다.

## 2026-09-08 BAK908A001 · v1 iCloud 백업 호환

- 실제 iCloud Drive에서 복사한 `2026-08.taptionbackup`, `2026-09.taptionbackup`, `Raw Sensors/2026-09.rawsensorbackup`의 envelope은 모두 version 1이었고, 원본은 `/tmp/BAK908A001.pgwpKC`에 보존했다. 세 파일의 ciphertext SHA256은 각 `payloadDigest`와 일치했다.
- build 141 이후 코드가 version 2와 AAD를 요구하면서 구형 파일을 읽기 전에 `invalidArchive`로 거부한 것이 화면 오류의 원인이다. version 1은 기존 AES-GCM 방식(추가 authenticated data 없음)으로만 읽고, version 2는 기존 metadata AAD 검증을 계속 적용한다. 키를 우회하거나 파일을 삭제·교체하지 않는다.
- `SecurityBackupCoreTests` 55/55 PASS·0 FAIL·0 SKIP: 실제 v1 snapshot/raw envelope 생성·digest 검증·복호화 회귀 포함. iOS Debug generic build PASS: `/tmp/BAK908A001.pgwpKC/{focused.xcresult,debug-device.log}`.
- 사용자의 PIN 없이는 실제 iCloud payload 복호화 성공을 확인할 수 없으므로 원본 데이터 내용과 실제 기기 복원은 별도 게이트다. 성공적인 다음 저장은 현재 v2 형식으로 기록하며 기존 파일 쓰기는 atomic 경로를 따른다.
- TestFlight build 142 archive/export·서명·altool 검증·업로드·처리 `VALID` PASS. Delivery UUID `ded15358-7e3b-4360-917a-7c264accfe48`, IPA SHA256 `b1994b9355c8f5b7b661b90eba459198b3f7184fea052c99b9a8f4be7d0391be`. Internal 그룹 API에 연결했고 1명 테스터를 readback했다. Chrome 페이지는 새로고침 뒤 접근성 트리가 비어 build 142 화면 재확인이 되지 않아, 브라우저 UI readback은 미완료로 남긴다.

## 2026-09-08 INT908A001 · 통합 수정 / build 141

- 소스 commit: `e170ba3`. 구매 비활성·만료 후 테스트 접근 허용은 유지한다. 계약 동의·심사 제출·유료화 재개는 수행하지 않는다.
- SET908A001: 설정 내부의 ‘전체 설정’ 버튼과 연결만 제거했다. 데이터 보호·설정 초기화·GPS 메뉴 및 저장 설정은 유지한다.
- DYN908A001: 센서/계획 Live Activity의 축소 화면에 기존 활동 그림과 현재 활동명을 표시한다. 현재 자동 기록 → 실행 중인 계획(예정 종료 초과 포함) → 확인 중 순서이며, 과거 선택 날짜는 참조하지 않는다. optional 상태 필드로 이전 payload를 읽고 확장/잠금 화면의 기존 내용은 유지한다.
- LOG908B001: 15:02:01 crash는 14:52:53 시작한 PID 12968의 `RUNNINGBOARD/0xDEAD10CC`다. `RawDeviceDataDayArchive.envelopes → decodedEnvelopes → checksum`에서 파일 lock이 유지되던 증거를 확인했다(`/private/tmp/BAK907A001-live.Fo650k`). raw DB 작업은 기존 background assertion 안에서 잠그고, decode는 잠금 밖에서 수행한다. legacy repair는 다시 잠금·generation 검증을 거치며 취소된 결과는 publish하지 않는다. 이는 BAK907A001의 암호화 실패 원인을 입증한 것이 아니다.

### SEC906P001 보안 수정 결과: fixed (코드·자동 검증)

- 원래 경로: Watch 메시지의 사용자가 정하는 UUID·planID·kind가 시각/100개 중복 검사만 거쳐 계획 변경 handler에 전달됐다. iPhone이 발행한 commandID/planID/kind/24시간 만료에 결합된 토큰을 영속 저장하고 handler 전에 단회 소비한다. 앱 잠금 시 수신과 최종 변경 경계에서 거부하며, 삭제·비공개 payload에서 grant를 폐기한다.
- Watch는 payload의 대응 grant로 명령을 구성한다. 기존 Watch UI에는 일반 계획 명령 송신 버튼이 없어 새 UI는 만들지 않았다. 활동 확인·센서 전송은 그대로 유지하며, 이전 payload는 optional decode하되 토큰 없는 명령 실행은 허용하지 않는다.
- HealthKit의 운동 actual·이동 근거·경로 보강에는 공통 소스 검사를 적용했다. Apple·Taption iPhone/Watch만 허용하고 외부 앱 및 유사 bundle 문자열은 거부한다. 원본 HealthKit 저장은 변경하지 않았다. 독립 검토에서 확인한 Taption Watch 연속 건강 추정 allowlist 누락도 보완했다.
- 변경 경계: `WatchSyncModels.swift`, `WatchConnectivitySupport.swift`, `WatchConnectivityController.swift`, `AppModel.swift`, `AppleIntegrations.swift`, `HealthKitBehaviorProjection.swift` 및 기존 테스트 파일. 별도 프레임워크·판매 정책 변경 없음.
- 원래 재사용 경로는 단회 소비/잘못된 ID·plan·kind·token/만료/100개 초과 grant 후 재사용·재조회 검증으로 거부됨을 확인했다. 정상 grant의 안정적 갱신·정상 1회 실행, Apple/Taption 소스와 기존 센서/캘린더 동작은 회귀로 확인했다. 실제 Watch 송신·프로세스 강제 종료 직후의 저장 내구성은 별도 실기기 검증이다.

### 검증 및 남은 게이트

- `git diff --check`: PASS. `xcodebuild test -scheme TaptionPlan` 집중 128/128 PASS, 전체 1,078 중 1,077 PASS·1 SKIP·0 FAIL. 기존 StoreKit iOS 26.5 Simulator 제한만 스킵했다. 독립 검토 반영 후 Watch/HealthKit/SensorDayStore 71/71 PASS·0 SKIP·0 FAIL. 각 실행 exit 0.
- `xcodebuild build -scheme TaptionPlan -configuration Debug -destination 'generic/platform=iOS' -allowProvisioningUpdates`: PASS·exit 0 (앱·Widget·Watch 포함).
- 증거: `/tmp/INT908A001.Cn2d4V/{focused,full,final-focused}.xcresult`, `debug-device.log`. `ponytail`로 기존 background assertion·아이콘·저장 패턴을 재사용하고 `fix-finding`으로 사전 경계 조사·독립 후보 검토·악성/정상 입력 회귀를 수행했다.
- BAK907A001: 최신 앱/iCloud 진단 로그와 실패 백업을 읽을 수 없어 암호화/무결성 실패의 직접 원인은 미확정이다. 기존 백업·사용자 데이터를 삭제하거나 교체하지 않았다. 신규 백업 round-trip·손상 거부·복원 실패 보존 회귀는 통과했지만 해당 사용자 백업 복원 성공은 미확인이다.
- 판매 준비: Pro `READY_TO_SUBMIT`, 앱 1.0 `PREPARE_FOR_SUBMISSION`, review detail 미생성. Chrome 인증 복구 후 비즈니스 화면에서 유료 앱 계약 ‘신규’와 법인 정보/규정 준수 잔여 항목을 확인했다. 계약 동의·심사 제출·유료화 재개는 하지 않았다.
- 기존 IAP 심사 메모는 체험 상태에서 구매 화면을 열도록 안내하므로 구매 비활성 141의 실제 진입 경로와 다르다. 유료화 재개 시 구매 진입/심사 메모를 함께 갱신하고 상품 조회·구매·복원을 검증해야 한다. 현재 상태만으로 상품 조회 실패의 단일 원인을 확정하지 않는다.
- Release archive/export 및 altool 검증·업로드 PASS(exit 0). 16:08 업로드 UUID `4a600796-ed30-4c23-9749-d4fb3b0af819`. IPA SHA256 `7409af24c84cceaccc5abae958c446adc71eeea9f3a92e6e994fa008a5a43131`, 앱·Widget·Watch·Watch Widget 모두 141, deep/strict 서명·Production iCloud·beta entitlement 확인.
- Apple 업로드 처리 `COMPLETE`(오류/경고 없음), build `VALID`. UUID `4a600796-ed30-4c23-9749-d4fb3b0af819`를 Internal 그룹 `b4857e5e-d1ff-4bc2-b9ad-a69bcd4603fd`에 추가(204)하고 그룹 API의 141·테스터 1명 `INSTALLED`를 readback했다. TestFlight iOS 화면에서도 141 ‘제출 준비 완료’와 내부 그룹명을 확인했다. 테스터 INSTALLED는 기존 140 설치이며 141 설치 증거가 아니다.
- Chrome 내부 그룹 빌드 탭에서 `1.0 (141)` ‘테스트 중’, 테스터 탭에서 1명·102개 빌드 및 기존 `1.0 (140)` 설치 상태를 확인했다. TFB907A001의 새 내부 배포 게이트는 141로 완료했으며 클라이언트 설치·구매 검증은 DEV903V001/IAP907A001 잔여 게이트로 유지한다.
- 현재 iPhone/Watch unavailable, iPad connected이며 TestFlight 클라이언트 설치·실행·터치·장시간 발열·실계정 캘린더 수신은 자동 테스트와 분리한다.

## 2026-09-08 WAK908C001 · 집/졸라맨 앞뒤 전환 재수정

- 최종 iPhone Debug build·deep/strict codesign·기존 데이터 유지 설치·`1.0 (140)`·`builtByDeveloper=true`·launch PID `12968` 확인: `/tmp/WAK908C001/final-device-build.log`, `install.json`, `apps.json`, `launch.json`. 사용자 겹침 화면 및 TestFlight 배포 확인은 별도다.

- 대표님이 WAK908B001 설치 후 집 마커와 졸라맨 순서가 여전히 바뀜을 확인했다. 완료 시점에 우선순위를 복구하는 방식만으로는 해결되지 않았다.
- Apple 졸라맨을 native annotation 목록에서 제거하고 지도 자체의 비상호작용 subview로 분리했다. 집 등 다른 annotation의 내부 정렬과 분리되며, 기존 지도 좌표 변환과 발끝 offset을 한 번만 적용한다. 기존 60Hz camera frame 경로에서 위치를 갱신하고 nil playback·detach에서 제거한다.
- 같은 좌표의 집 선택 및 거리 300/3,000/30,000에서 최상위 직접 subview·발끝 좌표를 검증했다. 관련 회귀 3/3 PASS·0 SKIP·0 FAIL 및 Simulator Debug build: `/tmp/WAK908C001/final-tests.xcresult`.

## 2026-09-08 WAK908B001 · 졸라맨을 지도 마커 최상단에 유지

- 아이폰 Debug build·deep/strict codesign·기존 데이터 유지 설치·`builtByDeveloper=true`·launch PID `12802` 확인: `/tmp/WAK908B001`. 실제 겹침/줌 화면과 TestFlight 배포는 별도다.

- 대표님이 다른 지도 마커보다 위에 표시하는 범위로 확정했다. 기존 Apple 최상위 설정이 annotation 추가 때만 재정렬되어, 콘텐츠·카메라·선택 갱신 후 보정이 빠져 있었다.
- 기존 최상위 설정을 `bringWalkerToFront`로 재사용해 콘텐츠 갱신·카메라 변경 완료·다른 마커 선택 후 졸라맨만 앞으로 올린다. 전체 annotation을 매번 순회하지 않으며 Vector의 기존 zIndex, 좌표 anchor, 검색창·시간표 계층은 유지한다.
- 관련 표시 순서 회귀 2/2 PASS·0 SKIP·0 FAIL 및 Simulator Debug build를 통과했다: `/tmp/WAK908B001/tests.xcresult`.

## 2026-09-08 CAN908A001 · 위치 기록 취소 팝업 제거

- 아이폰 Debug build·deep/strict codesign·기존 데이터 유지 설치·`1.0 (140)`·`builtByDeveloper=true`·launch PID `12388`를 확인했다: `/tmp/CAN908A001`. TestFlight 배포본은 별도다.

- `refreshSensorTimeline`이 `archivedReadings`의 `CancellationError`를 실제 읽기 실패와 같은 팝업으로 표시했다. 공통 파일 lock의 취소 검사 보강 뒤 화면에 드러난 경로다.
- 해당 취소는 별도로 종료하고 기존 오류 상태를 유지한다. 실제 파일 읽기 실패 알림은 유지했다.
- 실제 센서 archive를 사용한 취소/읽기 실패 구분과 보관 기록 보존 회귀 2/2 PASS·0 SKIP·0 FAIL, Simulator Debug build를 확인했다: `/tmp/CAN908A001/tests.xcresult`.

## 2026-09-08 LOG908A001 · SQLite 저장 중 백그라운드 종료 보강

- 최종 앱 저장소 회귀 18/18 PASS·0 SKIP·0 FAIL: `/tmp/LOG908A001/repository-r2.xcresult`; DayStore와 합계 37/37 PASS다. 설치 후 crash 목록에 새 TaptionPlan 보고서는 없었으며, 이는 짧은 확인 구간의 결과다.

- 아이폰 TestFlight build 140의 10:38·13:40 충돌은 모두 `RUNNINGBOARD/0xDEAD10CC`다. 일치하는 dSYM으로 오전은 WeatherContext 인코딩, 오후는 `DayStore.saveSnapshots`의 SQLite 트랜잭션으로 확인했다: `/tmp/LOG908A001`.
- 기존 인코딩 lock 분리에 더해 iOS 앱의 SQLite 저장·삭제 임계 구역에 background assertion을 적용했다. 만료 시 작업을 취소하고 SQLite progress callback으로 진행 중 트랜잭션을 중단·rollback한다. 위젯은 별도 컴파일 조건으로 UIApplication 호출을 제외했다.
- 저장 전 취소와 실제 write lock 획득 후 `SQLITE_INTERRUPT`·rollback·재시도를 포함한 DayStore 회귀 19/19를 통과했다. 아이폰 Debug build·deep/strict codesign·데이터 유지 설치·`builtByDeveloper=true`·launch PID `12262`를 확인했고 약 1분간 백그라운드 전환 후 같은 PID로 복귀했다. TestFlight 배포 및 장시간 반복 재현은 별도다.

## 2026-09-07 CRH907A001 · 백그라운드 충돌·지도 CPU 완화

- TestFlight build 140의 `0xDEAD10CC` 충돌은 연간 리뷰 payload를 인코딩하는 동안 SQLite 파일 lock을 유지한 저장 경로와 일치했다. 같은 빌드의 CPU 진단은 `MapHomeView` 생성 때 시간 레일 전체를 반복 계산하는 경로를 가리켰다.
- 모든 domain payload를 파일 lock 획득 전에 인코딩하도록 저장 임계 구역을 줄였고, 시간 레일은 초기 placeholder 뒤 기존 비동기 refresh에서 계산하도록 변경했다.
- SQLite 저장소·기능 엔진·시간축 회귀 727건 중 726 PASS·1 SKIP·0 FAIL 및 Simulator Debug build를 통과했다: `Test-TaptionPlan-2026.09.07_21-39-52-+0900.xcresult`. 실제 TestFlight 반복 실행·로그 생성 확인은 새 배포 후 물리 게이트다.

## 2026-09-07 ICO907A001 · 정적 활동 전용 아이콘

- 업무·식사·수업·취미 지도 마커에서 졸라맨을 제거하고 각각 모니터 글자, 그릇·포크·스푼, 책장, 음표 애니메이션으로 교체했다.
- Apple·Vector 공통 36×36 마커와 좌표 anchor·경로 테두리를 유지하고 Reduce Motion에서는 대표 프레임으로 정지한다.
- 지도 마커 회귀 37/37 PASS, 기능 회귀 557 PASS·1 SKIP·0 FAIL 및 Simulator Debug build를 통과했다: `Test-TaptionPlan-2026.09.07_18-17-34-+0900.xcresult`, `Test-TaptionPlan-2026.09.07_18-15-29-+0900.xcresult`.

## 2026-09-07 WAK907A001 · 졸라맨 좌표 anchor 통일

- Apple 지도는 졸라맨 중심을 경로 좌표에 붙이고 Vector 지도는 발끝을 붙여, 18pt 고정 차이가 줌아웃에서 큰 지리 오차처럼 보였다.
- 공통 `MapHomeStickmanAnnotationLayout.centerOffset`을 두고 Apple·Vector 모두 졸라맨 발끝을 선택 시각의 경로 좌표에 고정했다. 경로·카메라·등록 장소 마커는 변경하지 않았다.
- anchor 집중 회귀 1/1과 Simulator Debug build를 통과했다: `/tmp/WAK907A001-tests-r2.xcresult`. 실제 TestFlight 줌인·아웃 화면은 별도 물리 게이트다.

## 2026-09-07 IAP907B001 · 구매 임시 비활성화·TestFlight build 140

- `TaptionCommercePolicy.supportsPaidPurchase=false` 단일 정책으로 만료 체험과 무관하게 앱·백그라운드·Watch 접근을 허용했다. 구매 메뉴·paywall·상품 로드·구매·복원 호출은 차단하고 기존 StoreKit 구현은 재활성화용으로 보존했다.
- 정책·만료 접근·상품 미로드·구매/복원 무호출 회귀 2/2와 Release archive/export·`altool --validate-app`을 통과했다: `/tmp/IAP907B001-tests-r2.xcresult`, `/private/tmp/IAP907B001.jpbHS0`.
- 네 번들 모두 `1.0 (140)`, export IPA는 Apple Distribution 서명·`beta-reports-active=true`·`get-task-allow=false`, SHA-256 `ebf0161b10decb17765eda07f2dea6d3b304320ab79fea57cf103c14bdbf5147`다.
- Delivery/build UUID `c871d1f4-e933-411d-b840-0d59af3ba6be`는 처리 `COMPLETE`, build `VALID`·미만료다. `TP Taption Plan 내부 테스트` 연결 후 그룹 build 140과 내부 테스터 1명 `INSTALLED`를 API readback했다. TestFlight 클라이언트 설치·launch·구매 UI 비노출·실제 기능 테스트는 물리 게이트다.

## 2026-09-07 TFB907A001 · TestFlight build 139

- Debug 전용 체험 초기화는 `#if DEBUG`로 Release에서 제외하고, build 번호만 139로 올렸다. 개발자 초기화 회귀 1/1과 Simulator Release build를 통과했으며 Release 바이너리에 초기화 문구·심볼이 없음을 확인했다: `/tmp/TRY907A001-tests-r2.xcresult`, `/tmp/TRY907A001-release-dd`.
- Release archive/export와 `altool --validate-app`을 통과했다. 앱·iOS Widget·Watch 앱·Watch Widget 모두 `1.0 (139)`, export IPA는 Apple Distribution 서명·`beta-reports-active=true`·`get-task-allow=false`이며 SHA-256은 `65c95869f99112813f4d5f0fed5be638fab7e53b822da4a131567188113ddde5`다: `/private/tmp/TFB907A001.j36e1d`.
- Delivery/build UUID `23d0de21-0047-40f1-b681-30bbfb8d26ca`는 App Store Connect API에서 `VALID`·미만료다. `TP Taption Plan 내부 테스트`에 연결한 뒤 그룹 관계에서 build 139와 내부 테스터 1명(`INSTALLED`)을 readback했다.
- Chrome App Store Connect 세션은 인증 만료로 그룹 빌드·테스터 화면 readback을 완료하지 못했다. TestFlight 클라이언트 build 139 설치·샌드박스 Pro 구매·launch·실제 터치는 별도 물리 게이트다.

## 2026-09-06 DEV906I001 · 최신 iPhone 설치

- `main@7a490e9`의 Apple Development Debug를 deep/strict codesign 검증 후 iPhone 14 Pro에 기존 데이터 유지 설치했다.
- 앱 목록에서 `com.taption.plan 1.0 (138)`·`builtByDeveloper=true`를 확인하고 launch PID `16713`을 readback했다: `/private/tmp/DEV906I001-install.json`, `/private/tmp/DEV906I001-apps.json`, `/private/tmp/DEV906I001-launch.json`.
- 이는 TestFlight 클라이언트 설치 증거가 아니다.

## 2026-09-06 PIN906A001 · 등록 장소 좌표 anchor 정렬

- 등록 장소 좌표는 원본 그대로 전달됐지만, 130×138pt 카드의 하단을 좌표에 붙이는 Apple `centerOffset.y = -69`와 Vector `.bottom` anchor 때문에 축소할수록 아이콘이 실제 좌표와 떨어져 보였다.
- Apple·Vector 지도 모두 등록 장소 아이콘의 중심을 저장 좌표에 맞췄다. 라벨·레벨·저장 좌표와 다른 마커는 변경하지 않았다.
- anchor 계약 회귀와 직전 현재 위치 회귀 2/2, Simulator Debug build·설치·launch PID `17961`을 통과했다: `/private/tmp/PIN906A001-focused-r2.xcresult`.

## 2026-09-06 LOC906F001 · 현재 위치 이중 포커싱 제거

- 현재 위치 버튼이 저장된 좌표로 즉시 이동한 뒤 새 GPS 표본에서 다시 이동했다. `requiresFreshReading`도 캐시가 있으면 새 표본을 기다리지 않아 같은 이중 이동을 허용했다.
- 버튼 탭 중에는 카메라를 유지하고 새 표본 저장이 확인된 뒤 한 번만 포커싱한다. `locating` 상태의 위치 콜백은 카메라를 움직이지 않고, 새 표본이 없으면 기존 위치로 이동하지 않는다.
- 집중 회귀 1/1, Simulator Debug build·설치·launch PID `13086`을 통과했다: `/private/tmp/LOC906F001-focused-r3.xcresult`.

## 2026-09-06 SUB906R001 · 00:17 자동차 기록의 지하철 오탐

- 00:17 기록 당시 물리 앱은 build 137이었다. 같은 날짜 진단에서 철도·역 이름·대중교통·승차 후보·노선이 모두 0인데 재투영 뒤 `subway=1`과 잠금 5건이 생겼다: `/private/tmp/DAY906L001-current-iphone.jsonl`, `/private/tmp/DAY906L001-app-info.json`.
- 원인은 역 근처라는 단일 조건만으로 상대고도 하강에 지하철 점수를 주던 경로다. 역 인접만으로는 부족하게 하고 반복 철도 일치·좌표 궤적·역 상태·사용자 노선 중 하나가 확인될 때만 해당 점수를 적용한다.
- 실제 지하철 고도 하강 보존, 자동차 오탐 차단, iPhone 행동 라벨 차단, 무노선 잠금 재평가 회귀 4/4와 Simulator Debug build·launch PID `5406`을 통과했다: `/private/tmp/SUB906R001-focused-r4.xcresult`.
- 최신 Apple Development Debug `1.0 (138)`을 iPhone에 설치하고 `builtByDeveloper=true`·launch PID `16511`을 readback했다: `/private/tmp/SUB906R001-device-apps.json`, `/private/tmp/SUB906R001-device-launch.json`. 실제 자동차 이동 재현과 TestFlight 클라이언트 설치는 별도 게이트다.

## 2026-09-06 DOC906U001 · 졸라맨 현재 위치 중앙 포커싱 원인

- 현재 위치 버튼은 `requestAndFollowUserLocation` → `focusUserLocation` → `requestAppleMapCenter` → `MapHomeAppleCameraCommand.center` 경로로 카메라를 갱신하며, 졸라맨은 같은 지도 좌표를 annotation으로 표시한다.
- 원인은 `MapHomeCameraLayoutMath.targetPoint`가 `x = max(0, sidebarLeft) / 2`를 사용한다는 점이다. `sidebarLeft`는 `mapViewportSize.width - sidebarInteractionWidth`이므로 화면 전체 중앙이 아니라 우측 시간 사이드바를 제외한 왼쪽 영역의 중앙을 목표로 삼는다. 따라서 현재 위치와 졸라맨이 의도적으로 화면 왼쪽에 치우치며, `isMapCenteredOnUser` 판정도 같은 편향된 목표점을 사용한다: `TaptionPlan/UI/MapHomeView.swift:111-145, 1607-1655, 8138-8182, 13323-13378`.
- `NXT906P002`에서 target point의 x 기준을 `viewportSize.width / 2`로 통일하고 검색창 아래 여백을 반영하는 y 계산과 camera center 변환은 유지했다. 수학·카메라 command·버튼 상태 회귀 3/3과 Simulator Debug build·launch를 통과했으며, 실제 손가락 현재 위치 버튼과 TestFlight 화면은 별도 물리 게이트다.

## 2026-09-06 SUB906F001 지하철 오탐 수정·TestFlight build 138

- iCloud 진단에서 철도 경로·역 이름·대중교통 일치·승차 후보가 모두 0인데 `travel_mode_counts=walking=2,subway=1,car=2`, `subway_segment_count=1`, `classification_locked_count=5`가 남았다. 확정·유효 노선이 없는 이전 지하철 잠금이 새 분류 결과와 병합될 때 살아난 것이 원인이며, iPhone 행동 문자열을 Watch 보조 근거로 읽는 경로도 함께 차단했다: `/private/tmp/DAY906L001-current-iphone.jsonl`.
- `SensorFusion`은 Apple Watch 출처·신뢰도 조건을 만족한 행동만 지하철 보조 근거로 사용하고, `ActivityClassificationLockEngine`은 확정 또는 유효 노선이 없는 이전 지하철 잠금을 재평가한다. 지하철 관련 집중 XCTest 18/18, `TaptionActivityEngineAdapterTests` 16/16과 Swift Package 회귀를 통과했다. 기능 커밋은 `537f3c2`다.
- Release archive/export와 `altool --validate-app`을 통과했다. 앱·iOS Widget·Watch 앱·Watch Widget 모두 `1.0 (138)`, IPA SHA-256은 `9fa557d536c6002294abf2a3435c54f0c8742df533577f69d411f467eb9a36f7`이며 deep/strict codesign, `beta-reports-active=true`, Production iCloud, `get-task-allow=false`를 확인했다: `/private/tmp/SUB906F001-release`.
- TestFlight 업로드 Delivery UUID는 `9caa4563-2a99-4b1a-ab58-c5b4a74b663c`이고 App Store Connect API에서 build 138 `VALID`·`APP_STORE_ELIGIBLE`·`expired=false`를 readback했다. `TP Taption Plan 내부 테스트`에 build 138이 포함된 그룹 빌드 99개와 내부 테스터 1명(`INSTALLED`)을 확인했다.
- TestFlight 클라이언트에서 build 138을 설치·실행한 뒤 실제 사용자 데이터로 지하철 오탐이 사라지는지 확인하는 물리 게이트는 남아 있다.

## 2026-09-06 PAY906Q001 · 데이터 무결성·지도 상호작용 보강

- raw 복원 도중 iPhone·Watch 원본 병합이 하나라도 실패하면 새 snapshot과 파생 기록을 공개하지 않고 기존 기록을 유지한다. Watch 가속도 chunk도 암호화 백업 payload에 그대로 보존하며, 같은 identity의 동일 재전송은 무시하고 내용이 다른 충돌 재전송은 거부해 원본 덮어쓰기를 막는다.
- 캘린더 계정 교체·권한 재허용 때 live 캘린더 목록을 복구하고, 이동된 반복 일정은 원래 occurrence로 병합해 누락·중복을 막는다.
- canonical DB가 준비된 뒤에는 앱 시작·날짜 변경마다 대용량 legacy Watch JSON을 다시 읽지 않는다. 지도 일자 payload도 generation·revision·원본·화면 파생값 signature가 같으면 중복 변환·SQLite 저장을 건너뛴다.
- 지도 카메라 좌표 변환은 최대 60Hz gate 전에 실행하지 않고 gesture 종료값은 즉시 반영한다. 검증된 snapshot 전 stale cache 게시와 동일 좌표 재중심화를 막고, 실제 대중교통 경로는 기존 갈색 실선·공백 예상 지하철은 같은 계열 점선으로 표시한다. 현재 위치 버튼과 승차 후보도 기존 색상·SF Symbol 체계를 재사용한다.
- 지도 메모는 기존 `note.text`·금색 계열로 메뉴와 지도 동작의 의미를 맞췄고, 대중교통 sheet도 기존 transit 색을 재사용한다. Vector 임시 대중교통 마커의 anchor를 Apple 지도와 같은 하단으로 맞추고 검색 핀·스티커·메모의 터치 영역을 최소 44pt로 보장했다. Apple 지도 annotation과 root map 접근성 라벨은 현재 언어를 반영하며 사용되지 않던 선택 상태는 삭제했다.
- 최신 전체 회귀는 1,050건 중 1,049 passed·기존 iOS 26.5 StoreKit 시스템 skip 1·failed 0이다: `/private/tmp/PAY906Q001-latest-analyze/full.xcresult`. iOS static analyzer는 analyzer 경고·오류 0이며, Xcode StoreKitTest SDK 헤더의 폐기 경고 1건만 남았다: `/private/tmp/PAY906Q001-latest-analyze/analyze.xcresult`. 30일 날짜 조회 cold/warm p95는 `25.605708ms`/`0.009167ms`다.
- iOS static analyze를 통과했고 일반 시뮬레이터 전후 1206×2622 비교에서 레이아웃·날씨 간격·현재 위치 제어의 기존 시각 체계 유지를 확인했다. 메모 메뉴 수정 전후를 같은 상태로 나란히 비교해 아이콘·색 의미가 기존 디자인 토큰으로 통일된 것도 확인했다: `/private/tmp/PAY906Q001-iphone-r7.xelGu4/analyze.log`, `/private/tmp/PAY906Q001-design-audit-final/02-before-after.png`, `/private/tmp/PAY906Q001-design-audit-r2/11-before-after-memo.png`.
- 최신 일반 Apple Development Debug `1.0 (137)`을 deep/strict codesign 검증 후 iPhone 14 Pro(iOS 26.6.1)에 설치하고 developer app 버전 readback·launch PID `14539`를 확인했다: `/private/tmp/PAY906Q001-style-iphone-r1.k3QEtD`. 위치 버튼 집중 Simulator XCTest 1/1도 통과했다: `/private/tmp/PAY906Q001-style-simtest-r1.3FJtFo/focused.xcresult`. 실제 두 손가락 pinch·장시간 전력·Watch/실계정 캘린더·실데이터 대중교통/메모 마커·VoiceOver는 물리 데이터 게이트다.
- 후속 무결성 리뷰에서 snapshot 저장 실패가 먼저 병합한 iPhone·Watch raw를 남기던 경로를 확인했다. 각 저장소가 실제 추가한 ID만 반환하고 역순 삭제하도록 보상 처리해 기존 원본은 보존한다. raw 복원·Watch 회귀 7/7, 캘린더 선택 범위 회귀 2/2, 카메라 단일 갱신 회귀 4/4, TaptionPlanCore 52/52를 통과했다: `/private/tmp/RAWAUD9061-focused/cloud-regression.xcresult`, `/private/tmp/RAWAUD9061-focused/calendar-regression.xcresult`, `/private/tmp/RAWAUD9061-focused/map-camera-regression.xcresult`, `/private/tmp/RAWAUD9061-focused/map-current-location-regression.xcresult`.
- 최신 전체 소스의 일반 Debug `1.0 (137)`은 테스트 번들 0개·deep/strict codesign을 통과했고 iPhone 설치·developer app readback·launch PID `14718`을 확인했다. Debug dylib SHA-256은 `c6fb740fbd97837e99e48905fe2490da4a2f2f1aa602b9745ee9d2ce813cadf2`다: `/private/tmp/PAY906Q001-iphone-final-r5/evidence.md`.

## 2026-09-06 RTE906C001 · 반복 날짜 전체 로드 제거

- 최신 실기기 로그에서 한 날짜를 약 160분 동안 169회 다시 투영했고, 완료된 지도 날짜 로드 88회의 평균은 `699ms`, 최대는 `2,335ms`였다. 60초 반복 전체 조회와 같은 날 자동 분류 변경에 따른 task 재시작이 겹친 것이 원인이었다: `/private/tmp/DAY906L001-live-log-r1/attachments/ED73066A-9479-4D4D-96A6-CC04E4238F71.json`.
- 현재 위치·경로는 기존 실시간 센서 콜백으로 증분 갱신하고 백그라운드 복귀 때만 다시 읽도록 60초 전체 조회를 삭제했다. 날짜 로드 task도 날짜·부트스트랩·과거 일자의 raw 변경에만 재시작하며 실제·장소·이동 변경은 기존 `onChange` 투영 경로를 사용한다.
- task key 집중 회귀 1/1과 Simulator·iPhone Debug 빌드를 통과했다. iPhone 14 Pro에 개발자 앱 `1.0 (137)`을 설치해 버전·launch PID `15114`를 readback했다: `/private/tmp/RTE906C001-focused.xcresult`, `/private/tmp/RTE906C001-device-evidence.md`. 실제 날짜 전환 손가락 체감은 별도 물리 게이트다.

## 2026-09-06 SLP906C001 · iPhone 수면 보완 경로 연결

- iCloud 진단의 반복 `sleep_inference_completed: conditions_or_continuity_not_met`와 코드 경로를 대조한 결과, 백그라운드 표본·화면 원본 누락을 처리하는 `PhoneSleepFallbackEngine`이 구현·테스트돼도 `AppModel`에서는 strict 규칙 엔진만 호출하던 연결 누락을 확인했다.
- strict 결과가 없을 때만 기존 iPhone fallback을 호출해 화면 원본 누락·희소 표본을 보완하고, HealthKit·Watch 수면과 겹치는 후보 차단과 엔진/후보 수 로그를 유지한다. strict 결과는 우선 보존한다.
- TaptionActivityEngine 패키지 14/14와 앱 타깃 집중 회귀 2/2(수면 fallback·날짜 task)를 실패·스킵 없이 통과했다. 시뮬레이터 단일 arm64 실행 결과는 `/private/tmp/SLP906C001-focused-r2.xcresult`이며, 이전 디스크 부족 산출물은 정리했다.

## 2026-09-06 DAT906L001 · 날짜 데이터 재조회 지연 제거

- 실기기 로그에서 지도 날짜 로드 `snapshot_wait_ms`가 4~9초까지 늘었고, `day_snapshot_load_finished`의 `sensor_ms`가 5~8초를 차지했다. source fingerprint만 바뀐 경우에도 raw digest가 유효한 materialized day를 버리고 센서 아카이브 전체를 다시 읽은 것이 원인이었다: `/private/tmp/DAY906L001-current-iphone.jsonl`.
- 메모리·SQLite materialized day의 raw digest가 유효하면 기존 readings를 재사용해 현재 source만 재투영한다. raw가 없거나 불완전할 때만 센서 아카이브 전체 조회를 수행하며 `reprojected_memory_raw`·`reprojected_database_raw`를 진단 로그에 남긴다.
- source 변경 재투영·강제 재로드 회귀 2/2와 30일 날짜 조회 성능 1/1을 실패·스킵 없이 통과했다. cold/warm p95는 `33.542666ms`/`0.04725ms`다: `/private/tmp/DAT906L001-tests-r2.xcresult`, `/private/tmp/DAT906L001-p95.xcresult`. 실제 iPhone 날짜 전환 손가락 체감은 별도 물리 게이트다.

## 2026-09-06 SEC906D001·SEC906K001·SEC906R001·SEC906C001·SEC906W001 · 입력·백업 경계 보강

- iCloud 백업 파일은 파일당 512MiB·전체 2GiB·최대 120개를 초과하면 읽지 않고, CloudKit inline/asset 입력도 압축 해제 상한 전에 거절한다. 백업 외부 메타데이터는 AES-GCM AAD에 묶어 월·계정·생성시각·generation 변조를 거부하며 raw payload의 월 키도 검증한다.
- 앱 잠금 PIN 실패 횟수·30초 차단 시각을 보호 저장소에 영속화해 재실행 우회를 막고, 기존 iCloud 문서 복구 키는 기기 보호 저장소로 한 번만 마이그레이션한 뒤 문서에서 제거한다.
- Watch envelope·가속도/경로/행동/수면 배열과 HealthKit route 누적에 바이트·개수 상한을 적용하고, Watch 활동 확인은 iPhone이 발급한 단회 confirmation token·제안·세션에 묶어 재생·임의 기록을 거부한다.
- 보안 3건·Watch query 22건(총 25/25), iOS Simulator Debug build가 실패·스킵 없이 통과했다: `/private/tmp/SEC906-final-derived/Logs/Test/Test-TaptionPlan-2026.09.06_14-12-59-+0900.xcresult`, `/private/tmp/SEC906-final-r2.log`. 최신 소스를 iPhone 14 Pro에 서명 빌드·설치·launch하고 `com.taption.plan 1.0 (137)` readback까지 확인했다: `/private/tmp/DATE906-final-device-build-r2.log`, `/private/tmp/DATE906-final-install-r2.json`, `/private/tmp/DATE906-final-launch-r2.json`. 표준 보안 스캔은 원본 snapshot 기준 low 1·medium 5 findings를 sealed report로 남겼고, 현재 worktree 수정은 별도 회귀로 검증했다: `/private/var/folders/q1/0p9tcvnx7yx5l12y55zm4tdm0000gn/T/codex-security-scans-jOiTAE/taption-plan/7b2a61a770171093367b712f8229d15c7252c6d8_20260906T043235Z_hqq8_odl/report.md`. Watch command capability·HealthKit source allowlist와 실제 Watch 수신은 별도 게이트다.

## 2026-09-06 BKP906C001 · iCloud 자동 백업 재시도 제한

- 실기기 로그에서 iCloud 계정 불가 상태의 포그라운드 자동 백업이 9회 반복됐고, 매번 약 0.5MB payload를 만든 뒤 `1,069~1,794ms`에 실패했다: `/private/tmp/DAY906L001-live-log-r1/attachments/ED73066A-9479-4D4D-96A6-CC04E4238F71.json`.
- 최근 성공 또는 계정 불가 실패 뒤 1시간 동안 포그라운드 자동 백업만 건너뛴다. 수동 백업과 00:00 백업은 그대로 유지하며 성공 시 제한을 즉시 해제한다.
- 실행 조건 회귀 1/1과 암호화·무결성·복원 보안 회귀 50/50을 실패·스킵 없이 통과했다: `/private/tmp/BKP906C001-focused.xcresult`, `/private/tmp/BKP906C001-security.xcresult`.

## 2026-09-06 ASC906R001 · 판매 상태 최신 readback

- App Store Connect API에서 앱 버전 `1.0`은 `PREPARE_FOR_SUBMISSION`, 연결 build `137`은 `VALID`·미만료로 다시 확인했다. `TP Taption Plan 내부 테스트` 그룹 관계에는 build 137이 포함되고 테스터는 1명이다.
- 비소모성 `com.taption.plan.pro`는 `READY_TO_SUBMIT`, 미국 기준 `USD 9.99`, 한국·미국 포함 175개 지역, 한국어·영어 현지화와 심사 이미지 `COMPLETE`를 유지한다. iPhone 6.7형 스크린샷 2장도 `COMPLETE`다.
- review submission은 0건이고 버전 심사 연락처·submission 객체가 아직 없으며 앱 판매 지역 resource도 미생성(404)이다. Paid Apps Agreement는 브라우저 로그인 만료로 API에서 판정할 수 없고, 첫 IAP 버전 연결과 함께 외부 제출 게이트로 유지한다: `/private/tmp/ASC906R001-live.r2SanN`.

## 2026-09-06 DIG906C001 · 중복 raw digest 캐시 보존

- 기존 `appendRawEvents`는 동일 identity·payload의 멱등 재전송도 신규 삽입 확인 전에 영구 digest를 삭제했고, 그 삭제를 변경으로 인식해 메모리 캐시까지 비웠다. 반복 Watch/iPhone 동기화가 raw를 바꾸지 않아도 다음 날짜 조회에서 전체 digest를 다시 계산하는 CPU·배터리 회귀였다.
- 실제 삽입된 identity가 속한 날짜만 같은 SQLite transaction에서 digest를 무효화하도록 바꿨다. 완전 중복 append는 receipt가 비고 메모리·영구 digest를 그대로 유지한다.
- 집중 회귀 1/1과 TaptionPlanCore 전체 52/52, iOS·Watch 포함 unsigned Debug device build를 통과했다: `/private/tmp/DIG906C001-core-r3.log`, `/private/tmp/DIG906C001-core-full-r1.log`, `/private/tmp/DIG906C001-ios-device-build-r1.log`.

## 2026-09-06 MAT906C001 · 중복 Watch 날짜 캐시 보존

- 최신 실기기 진단에는 일자 snapshot 204회 중 `rebuilt_memory` 109회, 변경 없음 Watch payload skip 83회와 Watch payload delivery 80회가 함께 기록됐다. 저장 흐름 대조에서 동일 Watch 요약·가속도 재전송도 materialized day를 무조건 삭제해 다음 날짜 조회를 재생성시키는 남은 원인을 확인했다: `/private/tmp/DAY906L001-live-log-r1/attachments/ED73066A-9479-4D4D-96A6-CC04E4238F71.json`.
- Watch/iPhone 저장소에 실제 새 identity가 삽입된 날짜만 캐시를 무효화한다. 완전 중복 요약·가속도는 raw와 materialized day를 그대로 유지한다.
- 중복 전송 회귀 2/2와 날짜 저장소 전체 41/41, 30일 cold/warm 성능 회귀 및 앱·Widget·Watch Debug 빌드를 통과했다: `/private/tmp/MAT906C001-focused.xcresult`, `/private/tmp/MAT906C001-store-suite.xcresult`.
- 최신 일반 Apple Development Debug `1.0 (137)`을 deep/strict codesign 후 iPhone 14 Pro에 설치하고 developer app 버전 readback을 확인했다. launch는 앱 결함이 아니라 기기 잠금으로 iOS가 거부해 잠금 해제 뒤 재확인한다: `/private/tmp/MAT906C001-iphone-build.log`, `/private/tmp/MAT906C001-iphone-install.json`, `/private/tmp/MAT906C001-iphone-launch.log`.

## 2026-09-06 DAY906L001 · 날짜 데이터 로딩 지연

- iPhone 앱 그룹의 센서 SQLite와 진단 로그를 LLDB로 직접 readback했다. 최대 `78,239ms`였던 센서 조회는 pre-canonical JSON 2,346건을 손상으로 오인해 이벤트마다 대용량 legacy/raw/tracking 원본을 다시 훑고, 실패한 일회성 migration을 실행마다 반복한 것이 주원인이었다.
- 조회마다 외부 원본을 소스별 한 번만 UUID 인덱싱하고 SQLite 안의 구형 JSON은 외부 탐색 없이 현재 envelope로 자가 복구한다. raw digest는 쓰기 때 무효화되는 SQLite 캐시로 재사용하며 지도 캐시와 정본 일자 조회도 동시에 시작한다.
- migration 검증이 SQLite `REAL` 왕복에서 생기는 `Date` 1 ULP 차이를 데이터 손상으로 판정하던 결함도 실제 실패 이벤트로 재현했다. 저장 형식으로 정규화한 시각과 event count·SHA-256을 비교하도록 고쳐 `25일`, exact digest `50일`, iPhone `153,480건`, Watch `910건`의 migration 완료를 실기기 로그에서 확인했다.
- iPhone 14 Pro(iOS 26.6.1) 집중 XCTest 12/12, 실패·스킵 0이며 30일 cold/warm p95는 `39.534583ms`/`0.010958ms`다: `/private/tmp/DAY906L001-iphone-tests-r14.xcresult`. TaptionPlanCore도 51/51 통과했다: `/private/tmp/DAY906L001-core-tests-r2.log`.
- migration 다음 실행에는 재시도가 없었고 후속 날짜 지도 로드는 `277~577ms`, 일자 snapshot은 `179~443ms`였다: `/private/tmp/DAY906L001-fixed-iphone-r6.jsonl`. 일반 Debug `1.0 (137)`을 다시 빌드·서명 검증·설치·launch하고 PID `14347`을 readback했다: `/private/tmp/DAY906L001-iphone-build-r9.log`.
- 후속 리뷰에서 지도 캐시를 정본 일자 snapshot보다 먼저 판정해 cold/date-change마다 캐시를 버리고 경로를 재생성하던 경로를 수정했다. 정본과 캐시는 병렬 로드하고 완전한 snapshot의 revision·원본 fingerprint가 맞을 때만 캐시를 적용하며, 과거 일자는 해당 일자의 raw 변경 때만 다시 계산한다.
- 캐시·raw revision·복원 원자성·카메라 projection 집중 회귀 8/8과 Core 51/51을 통과했다: `/private/tmp/DAY906L001-followup-r3.ZyrSYM/focused.xcresult`. 최신 일반 Debug `1.0 (137)`도 테스트 번들 0개·deep/strict codesign·iPhone 설치·developer app readback·launch PID `14486`을 통과했다: `/private/tmp/DAY906L001-iphone-followup.zeZ8iP`.
- 최신 앱 그룹 로그 4,040건에서 일자 snapshot 204회 중 DB cache hit은 1회뿐이고 109회가 재생성이었다. 지도 cache도 실행 중 바뀌는 전역 revision 69회와 무관한 snapshot 시각 20회 때문에 폐기되어 지도 날짜 로드 p95가 `1,845ms`까지 늘었다: `/private/tmp/DAY906L001-live-log-r1/attachments/ED73066A-9479-4D4D-96A6-CC04E4238F71.json`.
- 캐시 유효성을 해당 날짜의 실제·장소·이동 내용 SHA-256과 raw digest로 판정해 앱 재실행·다른 날짜 변경에도 보존하고, iPhone·Watch 원본 조회를 병렬화했다. iPhone 회귀 42/42와 기존 payload 호환 Simulator 회귀 8/8은 실패·스킵 0이며 30일 cold/warm p95는 `38.536208ms`/`0.052541ms`다: `/private/tmp/DAY906L001-regression-r3/regression.xcresult`, `/private/tmp/DAY906L001-compat-r7/compat.xcresult`.
- 테스트 번들이 없는 최신 일반 Debug `1.0 (137)`을 deep/strict codesign 후 iPhone에 설치하고 developer app readback·launch PID `14690`을 확인했다. Debug dylib SHA-256은 `fe4b7a8a561e87f38e1aa7201bfd7b86f4ae8941345c43ba41828f25557abe2d`이며 증적은 `/private/tmp/DAY906L001-iphone-final2.9Jm4eN`이다.

## 2026-09-06 IAP905G002 · 구매 즉시 권한·복원

- iPhone 14 Pro(iOS 26.6.1) StoreKit 실행에서 상품 조회와 검증 구매는 성공했지만, 거래를 먼저 `finish()`한 직후 `currentEntitlements` 반영이 늦어 구매 뒤에도 UI가 잠길 수 있는 순서 결함을 재현했다.
- 검증 거래를 컨트롤러에 반환해 `.purchased`를 먼저 적용한 뒤 완료하고 transaction update도 같은 순서를 사용한다. 이미 현재 권한이 있으면 복원은 즉시 성공해 불필요한 App Store 인증창을 띄우지 않는다.
- 수정 후 StoreKit 집중 1/1과 상거래·체험·철회 회귀 10/10, 실패·스킵 0을 실기기에서 통과했다: `/private/tmp/IAP905G002-iphone-r2.S0jnmI/storekit.xcresult`, `/private/tmp/IAP905G002-commerce-r3.8ddFUJ/commerce.xcresult`.
- 최신 전체 소스의 iPhone clean Debug build·설치·launch와 앱 `1.0 (137)`, PID `13950` readback까지 통과했다: `/private/tmp/IAP905G002-iphone-build-r4.log`.
- 권한이 누락된 계정에서 강제 `AppStore.sync()`를 실행하면 시스템 App Store 인증이 표시되므로 사용자 탭이 있는 수동 복원 게이트로 유지한다.

## 2026-09-06 DEV903V001 · iPhone 실기기 설치·설정 진입 보강

- iPhone 14 Pro(iOS 26.6.1)와 Apple Watch SE 연결을 확인했다. 기존 설치 앱 `1.0 (137)`은 교체 전 launch했고, 최신 소스의 Apple Development Debug `1.0 (137)`도 빌드·deep/strict codesign·설치·launch 및 실행 프로세스 PID `13362`를 readback했다.
- Watch 자동 가져오기·가속도 수집·모든 권한 승인 제어가 비활성 레거시 `SettingsView`에만 있어 현재 지도 UI에서 접근할 수 없던 결함을 확인했다. 지도 설정 목록에 기존 `SettingsView`를 여는 `전체 설정` 진입점 하나만 추가해 제어를 중복 구현하지 않았다.
- 실기기 Debug 빌드는 `/private/tmp/DEV903V001-iphone-settings-r1.log`에서 `BUILD SUCCEEDED`; 앱 버전 `1.0 (137)`, Debug dylib SHA-256 `7bd3355fa7bcebfa9c47d087d072fb882563e2f8c75d23e192583a67b184ec06`이다.
- 직전 동일 지도·핀치 코드의 iPhone 집중 XCTest는 3/3 통과했다: `/private/tmp/DEV903V001-iphone-focused-r1.xcresult`. 실제 두 손가락 터치, 새 `전체 설정` 버튼 터치, 장시간 발열·배터리는 iPhone Mirroring 원격 레이어가 자동 클릭을 받지 않아 물리 확인 게이트로 남긴다.
- Watch Debug `1.0 (137)` 설치와 새 Watch 접촉 시각 갱신은 확인했지만, Watch launch는 활성 시스템 상태 때문에 시계 화면 이탈이 거부됐다. TestFlight 배포본은 기존 build 137이며 이번 소스 변경은 아직 업로드하지 않았다.

## 2026-09-06 ALG904A001 · 전체 기록 알고리즘·성능·배터리 리뷰

- 활동 융합, 경로 공백, 센서 저장·필터, HealthKit·Watch 수신, 지도 실시간 투영과 POI 검색을 함께 검토해 정확성·무결성·전력 결함을 수정했다.
- 활동 융합은 전수 비교 대신 시간 버킷을 사용하고, 비정상 시각은 원본 근거에 보존하되 분류 입력에서는 제외한다. 긴 저속 공백은 거부하되 역·대중교통 근거가 있는 버스·지하철·열차·선박 구간은 유지한다.
- HealthKit 수면을 한 번만 조회하고 UUID 집합으로 delta를 계산한다. Watch receipt는 일자 저장 성공 뒤에만 기록하며, 같은 시각의 원본 재시도는 동일 SHA-256 payload·60초 제한·raw-only로 처리해 파생 기록 중복을 막는다.
- 손상된 센서 범위는 incomplete로 전파해 캐시하지 않는다. 현재 위치·보간 freshness를 분 단위로 제한하고, POI 검색은 30초 gate·취소·task/data generation 검증으로 백그라운드 전력과 삭제 후 stale 게시를 막는다.
- Swift Package 86/86, 집중 XCTest 7/7, 전체 앱 1,031건 중 1,030 passed·기존 iOS 26.5 StoreKit 시스템 skip 1·failed 0을 통과했다: `/private/tmp/ALG904A001-app-r3.9gBYjO/focused.xcresult`, `/private/tmp/ALG904A001-full-r2.ByyHu3/full.xcresult`.
- 30일 로드는 cold/warm p95 `32.998416ms`/`0.006625ms`, NLE 240Hz projection p95 `0.000042ms`다. generic iOS·watchOS Debug와 iOS static analyze가 모두 exit 0이며, 재설치한 iPhone Simulator는 안정화 뒤 CPU 5회 `0.0%`, RSS 약 `183.5MiB`였다: `/private/tmp/ALG904A001-build-r1.TPiSR6`.
- 보안 diff scan은 17개 변경 파일 coverage `complete`, 보고 대상 취약점 0건으로 봉인했다: `/private/var/folders/q1/0p9tcvnx7yx5l12y55zm4tdm0000gn/T/codex-security-scans-jOiTAE/taption-plan/af7352832651ca69d5863cff8dc36b0c8d2dbdc0_20260905T162732Z_ehr2iwgg/report.md`. 실기기 pinch·장시간 발열/배터리·실제 Watch/HealthKit 수신은 별도 게이트다.

## 2026-09-06 ASC906A001 · App Store 판매 초안 보강

- App Store version `1.0`에 TestFlight build 137(`1b26a479-4bd6-49df-bda2-2f1bf1f0d28a`)을 연결하고 `VALID`·미만료·`APP_STORE_ELIGIBLE`·비면제 암호화 사용 `false`를 API로 재조회했다.
- 한국어 설명·키워드·지원 URL, 앱 부제·개인정보처리방침/개인정보 선택 URL, `2026 Taption` 저작권, 생활/건강 및 피트니스 카테고리와 제3자 지도 콘텐츠 사용 선언을 입력했다. 공개 `PRIVACY.md`·`SUPPORT.md`는 GitHub에서 HTTP 200을 확인했다.
- 연령등급 문항은 광고·채팅·UGC·웹 접근·의료 조언 없음, 건강·웰니스 주제 있음으로 실제 기능에 맞춰 완료했다. 175개 지역 결과는 9+ 172개, 한국 전체이용가 1개, 10+ 1개, 12+ 1개다.
- 상품은 `com.taption.plan.pro` 비소모성 `READY_TO_SUBMIT`, 앱 버전은 `PREPARE_FOR_SUBMISSION`이며 심사 제출은 만들지 않았다. 첫 IAP는 App Store Connect 웹에서 새 앱 버전과 함께 추가해야 한다.
- 개인정보 없는 iPhone 6.7형 스크린샷 2장을 등록하고 두 asset의 `COMPLETE`와 세트 2건을 API로 재조회했다. 심사 연락처·판매 지역·앱 개인정보 수집 답변·Paid Apps Agreement·DSA·비규제 의료기기 선언은 사용자·법적 판단이 필요한 게이트로 남긴다.
- API 증적은 `/private/tmp/IAP905G002-api.3i778W`, 원본 스크린샷은 `/private/tmp/ASC906A001-screenshot.sGrWXW`에 보존한다. JWT·복구 키·개인 연락처는 저장하지 않았다.

## 2026-09-05 BAK905I001 · 실제 iCloud 암호화 백업 readback

- iCloud Drive에 내려온 8·9월 snapshot·raw 파일과 32바이트 계정 복구 키를 일회성 macOS 검증기로 읽어, 실제 AES-GCM key unwrap·payload decrypt·LZFSE 해제·JSON v1·월/generation 쌍을 모두 확인했다.
- 8월 snapshot은 route 2,516건·평문 5,402,225바이트, raw는 reading 15,369건·envelope 12,876건·평문 82,658,944바이트다. 9월은 route 2,728건·평문 8,819,231바이트, raw reading 7,403건·envelope 19,132건·평문 146,067,067바이트다.
- 좌표·건강값·복구 키는 출력하지 않았고 검증기 소스·바이너리는 삭제했다. 증적은 `/private/tmp/BAK905I001-live.5vfwUn/live-backup-readback.log`에 보존한다. 앱 UI의 실제 복원 적용·merge readback은 실기기 게이트로 남긴다.

## 2026-09-05 BAK905H010·REL905H011 · raw 실패 롤백·build 137

- 월간 전체 백업이 raw 파일을 먼저 갱신한 뒤 snapshot 저장에 실패하면, generation 불일치로 새 raw를 제외하면서 직전 정상 raw 파일까지 잃는 부분 커밋 결함을 수정했다.
- raw 병합 때 이미 읽은 기존 archive를 재사용해 snapshot 실패 시 되돌리고, 기존 archive가 없으면 미커밋 raw를 삭제한다. 추가 의존성·래퍼·중복 raw 읽기는 없다.
- 집중 회귀 1/1, 보안·백업 50/50, 앱 전체 1,027건 중 1,026 passed·기존 iOS 26.5 StoreKit 시스템 skip 1·failed 0을 통과했다: `/private/tmp/BAK905H010-focused.K2HmMB/focused.xcresult`, `/private/tmp/BAK905H010-focused.K2HmMB/security-suite.xcresult`, `/private/tmp/BAK905H010-focused.K2HmMB/full.xcresult`.
- 배포 소스 `a6e770f64491e97896136a1b7692620bf6c0c62b`를 `main`에 푸시하고 네 번들을 `1.0 (137)`로 archive/export했다. archive는 `/private/tmp/REL905H011-release.nFPbOf/TaptionPlan-1.0-137.xcarchive`, IPA는 `/private/tmp/REL905H011-release.nFPbOf/Export/TaptionPlan.ipa`, IPA SHA-256은 `18e5516b30726c1ba7862907062c7421ef743fff7f12165bf0e40f0b0a07d405`다.
- 배포본은 Apple Distribution, privacy manifest 5개, `beta-reports-active=true`, iCloud `Production`, `get-task-allow=false`, deep/strict codesign과 Apple 서버 사전 검증을 통과했다.
- Delivery/build UUID `1b26a479-4bd6-49df-bda2-2f1bf1f0d28a`는 `VALID`·미만료·`APP_STORE_ELIGIBLE`이다. `TP Taption Plan 내부 테스트` 추가 후 build 137 포함·그룹 빌드 98개·내부 테스터 1명 `INSTALLED`를 API readback했다.

## 2026-09-05 BAK905H008·REL905H009 · raw 복원 연속성·build 136

- 포그라운드의 가벼운 스냅샷 백업이 새 generation ID로 월간 파일을 덮어써, 기존 암호화 raw 센서 백업이 다음 전체 백업 전까지 복원에서 제외될 수 있는 결함을 수정했다.
- raw를 새로 저장하지 않을 때는 기존 월간 스냅샷의 generation ID를 보존하고, 포그라운드 경로는 raw 없는 새 generation 대신 스냅샷 저장을 사용한다. 별도 계층이나 의존성은 추가하지 않았다.
- 실제 iCloud 2026-09 스냅샷·raw 센서 백업은 JSON v1 구조, 암호화 payload와 이중 wrapped key, 저장 SHA-256 digest 일치를 확인했다. PIN 복호화·실제 복원은 잠긴 실기기 게이트로 남겼다.
- 보안·백업 회귀 50/50, 앱 전체 1,027건 중 1,026 passed·1 known StoreKit system skip·0 failed를 통과했다: `/private/tmp/BAK905H008-focused.b6Zr0b/security-suite.xcresult`, `/private/tmp/BAK905H008-focused.b6Zr0b/full.xcresult`.
- 배포 소스 `f76af5a9dd23e880f00c9d3b5cf2b6b173efe83b`를 `main`에 푸시하고 네 번들을 `1.0 (136)`으로 archive/export했다. IPA SHA-256은 `32486649b566c61a3270ee0424e8d99a50a4c176c3200ea9f0edb1c24c639b86`이다.
- 배포본의 privacy manifest, Apple Distribution, `beta-reports-active=true`, iCloud `Production`, `get-task-allow=false`, deep/strict codesign을 확인했다.
- Delivery/build UUID `85cabd56-8654-4124-b660-9e8793fe4853`은 `VALID`·미만료·`APP_STORE_ELIGIBLE`이다. Internal 그룹 추가 후 build 136 포함·그룹 빌드 97개·내부 테스터 1명을 API readback했다.

## 2026-09-05 REL905H007 · build 135 정확도·성능 보강 릴리스

- 자동 기록·경로 생성·행동 분류·센서/Watch 분기·지도 상호작용을 다방면 검토해 확인된 결함을 최소 수정했다. 불완전 일자 캐시, stale projection/migration, 과도한 날짜 조회, 경로 opacity·MapKit overlay 교체, 현재 위치 중복 표시, Watch 유료 잠금 우회를 바로잡았다.
- 전체 앱 테스트는 1,027건 중 1,026건 통과·실패 0·iOS 26.5 StoreKit 시스템 결함 1건만 skip했다. 집중 회귀 6/6, 성능 회귀 4/4, 30일 로드 cold/warm p95 `33.154708ms`/`0.007334ms`, generic iOS·watchOS Debug와 정적 분석을 통과했다.
- 배포 소스 `1ca699e5f0da06c18dd453b31c688c5b38405a31`을 `main`에 푸시하고 앱·iOS Widget·Watch 앱·Watch Widget을 `1.0 (135)`로 archive/export했다. IPA SHA-256은 `f2f5ef3b106fb37c480b1e365888fe66844c4c111c0d06b990b9c7bc110807e3`이다.
- 배포 IPA는 Apple Distribution 서명, `beta-reports-active=true`, iCloud `Production`, `get-task-allow=false`, privacy manifest와 deep/strict codesign을 확인했다.
- App Store Connect 업로드 Delivery/build UUID는 `365a5ef7-dfda-447f-8b4c-3c807f1ef37e`이며 `VALID`·미만료·`APP_STORE_ELIGIBLE`이다. `TP Taption Plan 내부 테스트`에 API로 추가한 뒤 build 135 포함·그룹 빌드 96개·내부 테스터 1명을 readback했다.
- TestFlight 클라이언트의 build 135 실기기 설치·실행, 장시간 발열/배터리, 두 손가락 pinch, iPhone/Watch 실제 센서·수면·지하철 수신은 별도 물리 게이트로 남긴다.

## 2026-08-30 DOCS83047A · 문서 범위 정리

- 사용자 선택 3에 따라 현재 구현 범위와 직접 연결되지 않은 `ACTION_ITEMS.md`와 구현 전 아이디어 문서 `GAME_plan.md`를 삭제했다.
- 현재 유지 문서는 Taption Plan의 구현·기획·검증·인계에 직접 쓰이는 자료로 한정한다. 원본 센서·Watch 데이터와 WBS 저장소는 수정하지 않았다.

## 2026-08-30 MDCL83048A · 전체 Markdown 범위 점검

- 저장소의 `.md` 파일 전체를 확인한 결과, 남은 `AGENTS.md`, `DEVELOPMENT.md`, `NEXT_CHAT_PROMPT.md`, `README.md`, `SENSOR_FUSION_SOURCES.md`, `STICKMAN_ANIMATION_GUIDE.md`, `design-qa.md`, `plan.md`, `temp.md`, `test.md`는 모두 Taption Plan의 개발 규칙·구현·기획·검증·인계에 직접 연결된다.
- 프로젝트와 무관한 `.md` 파일은 추가로 확인되지 않아 삭제하지 않았다. 삭제된 문서는 `DOCS83047A` 기록을 따른다.

## 2026-08-30 DOCS83044A · 문서 기준 및 최신 검증

- 개발 문서는 Taption Plan의 구현·기획·검증·인계에 직접 쓰이는 자료만 유지한다. `AGENTS.md`, `README.md`, `DEVELOPMENT.md`, `NEXT_CHAT_PROMPT.md`, `plan.md`, `SENSOR_FUSION_SOURCES.md`, `STICKMAN_ANIMATION_GUIDE.md`, `design-qa.md`, `temp.md`, `test.md`는 현재 기능 또는 개발 운영을 설명하므로 보존한다. `README.md`가 참조하는 `ui-draft-iphone.html`도 보존한다.
- 프로젝트와 무관하거나 현재 개발 범위를 벗어난 문서는 `DOCS83047A`에서 삭제했다. 판단이 불명확한 자료는 삭제하지 않는다.
- 자동 검증은 `TaptionActivityEngine` 6/6, `TaptionPlanCore` 36/36, `TaptionRouteEngine` 14/14 통과이며 `TaptionPlanEngine`은 소스 빌드와 테스트 target 없음 확인을 완료했다. `git diff --check`도 통과했다.
- iPhone 14 Pro Debug build·설치·실행·readback은 `com.taption.plan` `1.0 (118)`로 통과했다. Watch Debug build와 `com.taption.plan.watchkitapp` `1.0 (118)` 설치·실행 readback도 통과했다.
- 전체 XCTest의 직전 동일 checkout 실행은 XCTest 820건과 Swift Testing 15건, 실패 0건이다. 이번 재시도는 Swift frontend 컴파일 정체로 exit 75 중단되어 새 성공 증거로 대체하지 않는다.
- 실기기 화면·터치, 날씨 범위/갱신, 목요일 경로·졸라맨, Dynamic Island, Watch raw/provenance 동기화, DB cold/warm p95는 `temp.md` 11개 잔여 게이트와 `test.md`에 미완료로 유지한다. 원본 센서·Watch 데이터와 WBS 저장소는 수정하지 않는다.

## 2026-08-19 Map Home·보안·경로 갱신

- 확대된 시간 레일은 플레이헤드를 화면의 고정 위치에 두고 시간 축·세그먼트·경로 축만 스크롤한다. 플레이헤드 아래의 시간이 바뀌면 해당 시각의 저장 위치를 다시 조회해 지도 위치를 갱신한다.
- 과거 날짜의 경로는 현재 시각으로 잘라내지 않고 해당 날짜의 종료 시각까지 투영해 누적 경로를 표시한다. 원본 GPS가 있는 구간만 경로로 연결하고 원본 데이터는 보존한다.
- Face ID 시스템 인증 중 발생하는 `inactive → active` 전환을 새 잠금 진입으로 처리하지 않아 인증 재시도·재잠금 루프를 방지한다. 실제 백그라운드 복귀 잠금은 유지한다.

### 이번 검증

- `TimeScaleTests`, `RouteTimelineDataTests`, `SecurityBackupCoreTests` 선택 테스트 통과
- iOS Debug 빌드 통과
- iPhone 14 Pro에 `com.taption.plan` 설치 및 실행 확인

다음 채팅에서는 실기기에서 확대 레일의 고정 플레이헤드·시간별 지도 위치 갱신과 과거 경로 표시를 직접 재확인하고, 새 기능 수정 시 관련 테스트와 Debug 빌드를 함께 실행한다.

## 자동 기록 파이프라인

원본 센서와 HealthKit 자료는 수정하지 않고 다음 순서로 파생 기록을 만든다.

```text
iPhone GPS/Core Motion + Apple Watch 센서
        ↓
세션별 정규화·정확도 필터·중앙값 보정
        ↓
층수/장소 보정 + 이동수단 판정
        ↓
일간 시간표·상세 카드·Apple 지도 경로
```

### 고도와 층수

- `CLFloor`는 한 번의 값으로 확정하지 않고 같은 층이 연속으로 확인될 때만 전이를 만든다.
- GPS 수직·수평 정확도, 기압, 상대고도, 보행 계단 카운터를 함께 사용한다.
- 상대고도와 기압은 같은 `altimeterSessionID` 안에서만 중앙값을 계산한다.
- 등록 장소에 사용자가 지정한 기준 층이 있으면 자동 추정값으로 덮지 않는다. 실제 층 이동은 별도의 안정화된 전이로 기록한다.
- 원본 `SensorReading`은 보존하고 `PlaceStay.floor`, `FloorTransition` 같은 파생값만 재계산한다.

### 지하철 이동

- `SubwayStationCatalog`은 국내 도시철도 노선 순서와 역 좌표를 보관한다.
- 역 근접성, 철도 경로, GPS 약화, 상대고도 하강, 걸음 수, Apple Watch 진동을 결합한다.
- 두 역 이상이 시간순으로 확인되면 노선 그래프에서 최단 경로와 환승역을 계산한다.
- 지도에는 역 핀과 역 좌표를 잇는 파생 경로선을 표시한다. 원시 GPS는 별도로 보존한다.
- 현재 검증 경로: `마곡나루 → 검암(환승) → 가정` = `공항철도 → 인천2호선`.

## 코드 리뷰 기준

- 센서 원본과 사용자 편집값을 섞지 않는다.
- 반복 계산은 세션·노선 카탈로그를 재사용하고, 고빈도 제스처에서 전체 시간표를 다시 계산하지 않는다.
- 자동 판정은 근거 문자열을 함께 저장하고, 확정되지 않은 값은 낮은 신뢰도로 표시한다.
- iCloud 진단 로그는 개인정보 보호상 좌표와 원시 건강값을 포함하지 않는다. 과거 경로 복구에는 원시 센서 저장소가 필요하다.

### iCloud CloudKit Production

- iCloud Drive의 진단 로그가 내려오는 것과 CloudKit 동기화 스키마가 배포된 것은 별개다.
- `iCloud.com.taption.plan` Production 환경에 `TaptionSnapshot` 레코드 타입과 `schemaVersion`, `updatedAt`, `payload`, `payloadAsset` 필드를 배포한 뒤 TestFlight 빌드를 검증한다.
- 스키마가 없으면 앱은 로컬 저장을 계속하고 설정에 `서버 설정 필요`를 표시하며, 오류 유형·코드만 진단 로그에 남긴다. 스키마 배포 후 설정의 iCloud 행을 눌러 재시도한다.

## 검증

```sh
xcodebuild test \
  -project TaptionPlan.xcodeproj \
  -scheme TaptionPlan \
  -destination 'platform=iOS Simulator,id=81DFCD1F-F2FA-48FC-8DFE-F43DD6D1637A'

xcodebuild build \
  -project TaptionPlan.xcodeproj \
  -scheme TaptionPlan \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO
```

실기기 설치는 Xcode에서 연결된 iPhone을 대상으로 수행한다. 설치 성공은 시뮬레이터 빌드 성공과 별도로 기록한다.

## 2026-08-23 REFA042A01 리팩토링·릴리스 기록

이번 요청은 센서 수집과 보안 경로처럼 장애 비용이 큰 부분을 먼저 고친 뒤,
반복 계산·강제 언래핑·릴리스 문서를 정리하는 순서로 처리했다.

### 우선순위 10개

1. 배터리 절약 센서 간격과 전원 정책을 실제 계약(15분·동작 센서 비수집)에 맞춤
2. 백그라운드 센서 샘플을 시간 경과가 아니라 보관 완료 토큰으로 확인
3. 포그라운드·백그라운드의 센서 시작/복구 순서를 한 메서드로 통합
4. 위치 이벤트로 재실행된 앱을 별도 BGTask 사유로 기록
5. PIN·CloudKit·생체키 생성에서 빈 버퍼 강제 언래핑 제거
6. 백업 암호화 키 생성 실패를 0 바이트 키로 진행하지 않고 오류로 중단
7. 경로·집계·팔레트·축 눈금의 강제 언래핑 제거
8. NLE 테스트의 불필요한 `var` 경고 제거
9. 포그라운드/자정 백업의 중복 처리와 진단 이벤트 통합
10. Debug·XCTest·archive/export·TestFlight를 독립 게이트로 문서화

### 코드 리뷰에서 다음 채팅으로 넘긴 항목

- `MapHomeView`·`AppModel`의 대규모 파일 분해는 동작 회귀 범위가 커서 별도 단계로 유지한다.
- 센서 분류 결과를 Dynamic Island에 실시간 반영하는 coordinator는 제품 상태 계약과
  실기기 확인이 필요하므로 이번 릴리스에는 추가하지 않는다.
- 앱 아이콘과 햄버거 홈 아이콘의 바이너리 해시가 다른 문제는 동일 이미지 교체 후
  시각 검증을 포함한 별도 asset 작업으로 남긴다.
- iOS가 강제 종료된 앱을 임의로 재실행하지 않는 제한과 BGTask의 최소 실행 시각은
  제품 문구·QA에서 “백그라운드”와 “스와이프 종료”를 분리해 설명한다.

### 검증 결과

- `git diff --check`: 통과
- iOS Simulator Debug build (`REFA042A01` DerivedData): `BUILD SUCCEEDED`
- XCTest 대상 실행: 두 시뮬레이터에서 테스트 러너가 연결 전 부트스트랩 크래시를 내어
  테스트 본문은 실행되지 않았다. 동일한 환경의 기존 전체 실행 기준은 505개 통과이며,
  CloudKit 복구는 시뮬레이터 entitlement 환경에서 별도 실패한다.
- 직전 TestFlight build 71은 운영 AdMob ID·무알파 앱 아이콘·배포 서명을 확인해 업로드했고,
  이번 변경을 포함한 build 72도 같은 검증을 거쳐 업로드했다.

### 다음 릴리스 게이트

1. `main` 커밋 후 원격 SHA 확인
2. Release archive/export에서 build 72, 운영 AdMob ID, 무알파 아이콘, Apple Distribution 서명 확인
3. IPA를 App Store Connect에 업로드하고 Delivery UUID·처리 상태 기록
4. 연결된 iPhone 설치·실행은 TestFlight 처리 완료와 별도로 확인

### build 72 업로드 결과

- Delivery UUID: `58eaab2b-f245-4b90-800e-a07f3ecddc3b`
- App Store Connect 업로드: 성공
- 현재 처리 상태: `PROCESSING` (TestFlight 노출 전)

## 2026-08-23 build 74 Pro·지도·센서 릴리스

- 사용자 추가 지하철역과 지하철 Wi-Fi 증거를 이동 판정 우선순위에 반영했다.
- 지도 길게 누르기 후 지하철역·버스 정류장을 추가하면 위치 이름 편집 화면으로 바로 연결한다.
- GPS 기록 간격에 1초·10초·30초를 추가하고 지도 상세도·축소 반응·시간 레일 표시를 정리했다.
- 광고 SDK·광고 설정·배너 영역을 제거하고 14일 앱 자체 체험과 `com.taption.plan.pro` 비소모성 영구 구매·복원을 추가했다. 체험 시작은 Keychain과 iCloud KVS에 보존하며 가장 이른 시작 시각과 가장 늦은 관측 시각으로 재설치·시계 역행을 방어한다. 기존 기록도 `startedAt` 기준 14일로 재계산한다.
- C2 고양이 벡터 아이콘을 iPhone 일반·다크·틴트와 Watch 아이콘에 동일 원본으로 반영했다.
- `BATCH2WK01`에서 지도 오버레이 핀치 전달·위치 추가 취소·저장 위치 이동/편집·사용자 위치 관리 UI·실제 헤딩 나침반·선택 날씨 배경을 통합했다.
- CloudKit 비공개 복구 백업은 계정 복구 키를 먼저 가져와 아카이브 키를 감싸도록 수정했다.

### 검증 및 배포

- 전체 XCTest: 518/518 통과, 실패·스킵 0; Pro 14일 경계·기존 만료 기록 재계산·시계 역행, 나침반·핀치·저장 위치·날씨 상태 회귀 테스트 포함
- iOS Simulator Debug build 통과
- iPhone 14 Pro 설치·실행·readback: `1.0 (74)`
- 기능 소스 커밋: `a2e3c5b`, `origin/main` 푸시 확인
- Release IPA: Apple Distribution 서명, build 74, iCloud KVS 권한 포함, GoogleMobileAds 미포함, 앱 아이콘 1024px·무알파 확인
- TestFlight 업로드 성공: Delivery UUID `bd78668d-fb43-40dd-9d32-5ac0817dcdf1`
- 처리 상태: `VALID`
- 내부 그룹: `TP Taption Plan 내부 테스트`에 build 74 자동 연결, 그룹 관계에서 build 74 노출과 내부 테스터 1명 확인

### 남은 외부 게이트

App Store Connect의 Paid Apps Agreement는 `신규` 상태이며 법인 정보 업데이트 후 계약·세금·은행 정보 완료가 필요하다. 이 절차 전에는 실제 US$0.99 비소모성 상품 생성과 TestFlight 구매 성공 검증을 완료할 수 없다. 로컬 StoreKit 구성과 앱 내 결제 경로는 준비되어 있다.

## 2026-08-24 build 77 다방면 코드 리뷰 릴리스

- 1초 GPS 경로 투영의 반복 전체 스캔과 누적 배열 복사를 제거하고, 경로 오버레이를 캐시해 재생 입력을 24Hz 예산으로 제한했다.
- 분류 시작·자정·DST 하루 끝 경계와 비유한 GPS 정확도·고도 값을 보정했다.
- 지도 컨트롤의 길게 누르기 충돌과 Safe Area 좌표계 불일치를 수정했다.
- 앱 잠금 시 iPhone Widget·Watch·Live Activity의 민감 정보를 숨기고, iCloud 복구 키의 평문 문서 fallback을 제거했다.
- 신규 PIN은 PBKDF2-HMAC-SHA256 600,000회로 파생하며 기존 verifier는 호환 유지한다. 난수 생성 실패는 fail-closed 처리한다.
- 전체 XCTest 576/576, 정적 분석, iPhone·Widget·Watch Debug 빌드와 Release archive/export를 통과했다.
- iPhone 14 Pro에는 직전 `1.0 (76)` 설치·readback이 완료됐다. build 77 Debug 설치는 기기 잠금으로 개발자 이미지 마운트가 거부되어 재시도가 필요하다.
- TestFlight Delivery UUID: `f962c2b8-f430-44e0-88a8-0a00b7b489c4`; 처리 상태 `VALID`/`제출 준비 완료`.
- `TP Taption Plan 내부 테스트` 그룹 관계와 App Store Connect 실제 화면에서 build 77 노출을 확인했다.

## 2026-08-25 build 88 센서·경로·스플래시 통합

- GPS와 센서 수집 프로필을 정확도 우선·1초 간격으로 고정했다. 저장돼 있던 이전 간격과 배터리 최소 설정도 앱 로드·동기화 시 실시간 기준으로 정규화한다.
- 위치 항상 허용·정확한 위치·동작·HealthKit·사진·캘린더·알림·앱 사용 기록·Live Activity 권한을 `RequiredPermissionGate`로 확인한다. 빠진 권한이 있으면 메인 기록 화면을 잠그고 권한 카드에서 요청 또는 시스템 설정으로 이동한다.
- 이동 경로가 저장된 GPS에 없거나 비어 있는 구간은 `MKDirections` 예상 경로를 화면 표시용으로 계산한다. 자동차·택시·버스는 자동차, 지하철·기차는 대중교통, 걷기·자전거·달리기는 도보 경로를 사용하며 확정된 지하철 노선 경로와 원본 센서 자료는 우선·보존한다.
- 예상 경로는 요청 단위 캐시와 선택 시각 절단을 사용하고, 경로가 없을 때 지도 자동 카메라가 현재 위치로 되돌아가지 않도록 지도 중심 계산에 함께 반영한다. 지도 단일 손가락 이동 시작은 즉시 현재위치 추적을 해제한다.
- 과거 위치 마커는 분홍색 팬토그래픽 사람 모양으로 표시하고 접근성 라벨을 유지한다.
- 기존 앱 아이콘 스타일과 배경은 유지하면서 새 `TaptionPlanLaunchCat.svg`에 몸통·앞발·뒷발·수염을 추가했다. SwiftUI 오버레이용 투명 `LaunchIcon`과 네이티브 시작 화면용 불투명 `NativeLaunchIcon`을 분리해 동일한 중앙 배치를 사용한다.

### 검증 및 기기 설치

- 전체 XCTest: 636/636 통과
- iOS Debug 빌드: 통과
- 연결된 iPhone 14 Pro에 현재 작업본 설치·실행: `com.taption.plan` `1.0 (88)`
- 기기 프로세스 readback: `TaptionPlan` PID `49149`
- `git diff --check`: 통과
- 이번 배치에서는 TestFlight archive/upload를 수행하지 않았다. App Store Connect Paid Apps Agreement `신규` 및 실제 `com.taption.plan.pro` 상품 생성 게이트는 계속 `IAP73PAID1`로 유지한다.

## 2026-08-26 경로·분류 잠금·NLE 반응성 통합

- `TaptionPlanCore`는 일자 단위 SQLite 저장소와 generation 기반 NLE 입력 예산을 제공한다. 고빈도 제스처 입력은 최대 60Hz로 제한하고 제스처 종료 최종값은 즉시 반영한다.
- `TaptionActivityEngine`은 상세·대분류 taxonomy와 센서 근거 분류를 담당하며, 자동 생성된 수면·이동·HealthKit·위치·지하철 분류와 `TravelSegment`는 저장 후 다시 분류되지 않는다. 사용자 편집만 저장된 결과를 덮어쓰며 원본 센서 자료는 보존한다.
- `TaptionRouteEngine`은 동일 시각 중복 우선순위, 2D constant-velocity Kalman 필터, 정지 드리프트 억제, 정확도 경계, 불가능한 점프·15분 공백 세그먼트 분리와 RDP 표시 축약을 담당한다.
- 앱 시작은 로컬 스냅샷과 일자 데이터를 먼저 hydrate한 뒤 홈을 연다. 사이드바·경로·지도 파생값은 캐시하고 드래그 중 전체 일자 재계산을 피한다.
- 지도 현재·과거 위치는 MapKit의 투명 위치 앵커를 따라가는 SwiftUI overlay 졸라맨으로 표시해 모든 지도 annotation보다 앞에 둔다. 추적 중 선택 시각 위치를 중앙에 유지하고, 지도 이동 시 추적을 해제하며 핀치 줌·사이드바 핸들의 터치 영역을 확장했다.
- 지하철 확정 구간은 저장된 선로 기반 확정 경로와 분류를 유지한다. 예상·점선 경로 오버레이는 비활성화했다. 재생 속도는 걷기·달리기는 빠르게, 자동차·자전거·지하철·기차·배·비행기는 느리게 적용한다.
- GPS·센서 수집 간격 슬라이더를 복원했다. Dynamic Island 우측 파형은 GPS 주기의 절반을 전체 폭으로 사용하고 실제 센서 저장 시 ECG 1회 펄스 후 평선으로 돌아간다. 1초 주기에서는 시간 진행을 표시하지 않는다.

### 검증 및 배포

- 전체 XCTest: 695/695 통과, 실패·스킵 0
- `TaptionPlanCore`: 24/24, `TaptionActivityEngine`: 4/4, `TaptionRouteEngine`: 11/11 통과
- iOS Simulator Debug build: 통과
- 서명된 iPhone Debug build: build 95로 통과
- iPhone 14 Pro 설치·실행·readback: `com.taption.plan` `1.0 (95)`, `TaptionPlan` PID `55910`
- `git diff --check`: 통과
- 이번 배치에서는 TestFlight archive/upload를 수행하지 않았다.
- Paid Apps Agreement·세금/은행 정보·실제 `com.taption.plan.pro` 상품 생성과 Sandbox 구매·복원은 `IAP73PAID1` 외부 게이트로 유지한다.

## 2026-08-26 build 96 경로·센서·UI 통합 TestFlight

- Release archive/export: `1.0 (96)`, `com.taption.plan`, Apple Distribution 서명, IPA 검증 성공
- TestFlight 업로드 성공: Delivery UUID `932ca076-b9ed-4a5f-9598-c7ba2c45b2f9`
- App Store Connect 처리 상태: `VALID` / `APP_STORE_ELIGIBLE`
- `TP Taption Plan 내부 테스트` 그룹에 build 96 연결 및 그룹 builds 관계 노출 확인
- 이번 빌드의 실기기 설치·실행은 별도 게이트로 남긴다.

## 2026-08-26 build 97 엔진·저장소·실시간 UI 통합

- `TaptionPlanEngine` umbrella Swift Package를 추가하고 Core·Activity·Route 엔진의 공개 경계를 하나로 묶었다.
- SQLite 정본과 센서·지도 캐시의 Codable payload를 binary plist + LZFSE(가능한 경우) + 원본 바이트 수 + SHA-256 envelope로 통일했다. 이전 JSON payload는 호환하지 않는다.
- 일자 데이터·지도 캐시에 bounded LRU와 지연 로딩·메모리 압력 축출을 적용하고, NLE 파생 projection은 generation으로 오래된 계산을 폐기한다.
- GPS 임시 역 위치, 지하철 확정 경로, 속도 기반 경로 팔레트, 현재 위치 전면 annotation, 날씨·미세먼지 색상, 시작 화면 `Taption Plan`/0–100% 진행 표시, 첨부 고양이 아이콘·스플래시를 통합했다.
- Dynamic Island는 우측에서 좌측으로 흐르는 파형만 표시하며 센서 저장 시 1회 ECG 펄스 후 평선으로 돌아간다. 외부 수신 센서는 지원된 provenance일 때만 빨간색으로 표시하고, 우측 상단 2px 단일 점을 1초 주기로 점멸한다.

### 검증 및 배포

- `TaptionPlanCore`: 28/28, `TaptionActivityEngine`: 4/4, `TaptionRouteEngine`: 11/11, 앱 XCTest: 695/695, 어댑터 Swift 테스트: 10/10 통과
- iOS Simulator Debug build: `BUILD SUCCEEDED`
- Release archive/export: `1.0 (97)`, `com.taption.plan`, IPA 검증 성공 (`d8f6ab1d458daecf4df5a2ddacc2b32a4d7793207e2c9e0f4f4d508b34d2b5bb`)
- TestFlight 업로드 성공: Delivery UUID `785306ae-b642-4679-a0ed-123ca25e1565`
- App Store Connect 처리 상태: `VALID` / `APP_STORE_ELIGIBLE`, `IS-ON-APP-STORE-CONNECT: true`
- `TP Taption Plan 내부 테스트` 그룹에 build 97 연결, builds 관계에서 build 97 노출 확인
- 실기기 설치·실행·readback은 별도 게이트이며, 다른 앱의 센서 사용 감지는 iOS 공개 API 제한으로 추정하지 않는다.
- Paid Apps Agreement·세금/은행 정보·실제 `com.taption.plan.pro` 상품과 Sandbox 구매·복원은 `IAP73PAID1` 외부 게이트로 유지한다.

## 2026-08-26 WXHIDE97A1 날씨 카드 완성 스냅샷 게이트

- 시간 레일 핸들 왼쪽에 붙던 compact 날씨 케이스를 제거했다.
- 날씨 카드는 수집 시각·비 stale 상태·조건·심볼·유한 온도가 모두 준비된 스냅샷만 표시한다. 미세먼지 응답이 포함된 경우 PM10·PM2.5·제공자도 유효해야 하며, 부분 응답은 카드 전체를 숨긴다.
- `TimeScaleTests` 111/111 통과, iOS Simulator Debug build 성공.
- build 97에는 포함되지 않았고 아래 build 98 TestFlight에 포함했다.

## 2026-08-26 build 98 날씨 게이트 TestFlight

- Release archive/export: `1.0 (98)`, `com.taption.plan`, Apple Distribution 서명, IPA 검증 성공 (`15f52d1ef05620b71189c6e1806bf0a5e3642878cb15c5be7325ff4ba595e876`)
- TestFlight 업로드 성공: Delivery UUID `e5c531e6-6f53-41ab-b6e7-982e73a626c6`
- App Store Connect 처리 상태: `VALID` / `APP_STORE_ELIGIBLE`
- `TP Taption Plan 내부 테스트` 그룹 연결 및 그룹 빌드 목록에서 build 98 노출 확인
- 실기기 설치·실행·readback은 별도 게이트로 남긴다.

## 2026-08-26 build 99 센서·메뉴·백업 게이트 TestFlight

- Release archive/export: `1.0 (99)`, IPA SHA-256 `6701314b618ac7c452e60f1ab285b163a07dad8697df771c4bd35921acb44dde`
- TestFlight 업로드·처리 상태 `VALID` 확인, `TP Taption Plan 내부 테스트` 그룹 연결 및 build 99 노출 확인
- GPS 주기 설정 저장·수집 주기 동기화, 미세먼지 기반 날씨 색상·사용자 팔레트·백업 최근 날짜·메뉴 축소를 포함한다.

## 2026-08-26 build 100 센서 복원·날씨 캐시·식당 분류 통합

- 위치 백업 경로 투영에 비현실적 GPS 도약·정확도 필터를 적용하고 원본 센서 아카이브는 보존한다.
- 복원 후 지하철 이동을 재분류·병합하고 확정 이동은 유지한다. 오늘 수면 조회 구간은 전날 18:00부터 당일 12:00까지로 고정했다.
- 날씨 완성 스냅샷을 로컬 캐시해 시간 사이드바 조절 후에도 표시를 유지한다.
- 식당 장소를 여러 곳 등록할 수 있고 15분 이상 체류만 식사로 분류한다. 식당 아이콘·색상·편집 UI를 연결했다.
- Dynamic Island 확장 파형은 전체 폭을 우→좌로 흐르고, compact 좌·우 영역은 연속 위상을 공유한다. 센서 주기 절반 동안 ECG 펄스가 진행되고 우측에만 2px 로깅 점이 점멸한다.

### 검증 및 배포

- 전체 XCTest 성공(실패·스킵 0), iOS Simulator Debug build 성공
- Release archive/export: `1.0 (100)`, Apple Distribution 서명, IPA SHA-256 `7a38f3a513a3b050c2defaee9253994d89b81f3b9af27162ed4583616a74d1e8`
- TestFlight 업로드 성공: Delivery UUID `9daf4383-c3d7-499d-b7a3-1e158b8b27c0`
- App Store Connect 처리 상태 `VALID` / `APP_STORE_ELIGIBLE`
- `TP Taption Plan 내부 테스트` 그룹에 build 100 연결 및 그룹 builds 관계 노출 확인
- 실기기 설치·실행·readback은 별도 게이트이며 Paid Apps Agreement·상품 생성·Sandbox 구매/복원은 `IAP73PAID1` 외부 게이트로 유지한다.

## 2026-08-26 build 101 식당·수면·Dynamic Island 수정 TestFlight

- 등록 식당 체류를 15분 이상일 때 `식사`로 자동 분류하고 여러 식당·수동 식사 기록을 보존한다.
- 오늘 센서 원본을 전날 18:00부터 당일 12:00까지 다시 분석해 수면 결과를 갱신하고, 데이터가 부족하면 기존 결과를 보존한다.
- 식당 위치 아이콘의 일반 사용자 지점 라벨을 식당으로 보정하고, Dynamic Island 파형 이동·평선·2px 스캔 효과를 반영했다.

### 검증 및 배포

- 전체 XCTest 성공(실패·스킵 0), iOS Simulator Debug build 성공
- Release archive/export: `1.0 (101)`, Apple Distribution 서명, IPA SHA-256 `4a47982d8e89cd64ac58f0ade6c645abf4b450144c2b17af55a77e08349f572d`
- TestFlight 업로드 성공: Delivery UUID `f8661c57-3157-41e3-9e86-dcb295ee3215`
- App Store Connect 처리 상태 `VALID` / `APP_STORE_ELIGIBLE`, Apple ID `6797370230`
- `TP Taption Plan 내부 테스트` 그룹에 build 101 연결 및 그룹 builds 관계 노출 확인
- 기능 커밋 `2c1278d`, `origin/main` 푸시 확인
- 실기기 설치·실행·readback은 별도 게이트이며 Paid Apps Agreement·상품 생성·Sandbox 구매/복원은 `IAP73PAID1` 외부 게이트로 유지한다.

## 2026-08-26 build 102 센서 상태 미터·Dynamic Island 파형 TestFlight

- 센서별 최근 10개 수집 상태를 누적 미터로 표시하고 수집·지연·대기 상태를 구분한다.
- Dynamic Island 확장 영역 전체에 무노이즈 파형과 1초 스캔 효과를 적용하고 센서 저장 시 펄스를 반영한다.

### 검증 및 배포

- 센서 미터·상태·1초 파형 주기 XCTest 3건 통과, generic iOS Release archive 컴파일 통과
- Release archive/export: `1.0 (102)`, Apple Distribution 서명, IPA SHA-256 `47d417a4d51758f514c105ab3a3ec7ff578370ac052d91cf3dd195a616de0ee9`
- TestFlight 업로드 성공: Delivery UUID `9bec24ce-e0da-4868-8398-5c75e8b3421b`
- App Store Connect 처리 상태 `VALID` / `APP_STORE_ELIGIBLE`, Apple ID `6797370230`
- `TP Taption Plan 내부 테스트` 그룹에 build 102 연결 및 그룹 builds 관계 노출 확인
- 기능 커밋 `16d864b`, `origin/main` 푸시 확인
- 실기기 설치·실행·readback은 별도 게이트이며 Paid Apps Agreement·상품 생성·Sandbox 구매/복원은 `IAP73PAID1` 외부 게이트로 유지한다.

## 2026-08-27 Dynamic Island 앱 아이콘·재생 경로 마무리

- `SensorCollectionLiveActivity`의 Dynamic Island 확장형 leading 영역에 `SensorCollectionAppIcon`을 연결했다.
- compact leading은 센서 수집 중 항상 앱 아이콘을 렌더링하고 비수집 상태에는 고정된 투명 프레임을 사용해 회색 플레이스홀더가 나타나지 않게 했다. compact trailing 심박 HUD의 기존 10초 표시 정책은 유지한다.
- 위젯 전용 `SensorCollectionAppIcon` 리소스가 `Assets.car`에 포함되는 것을 확인했다.
- 재생 시작 시 기존 경로 투영을 비우고 원본 센서 읽기를 다시 준비하며, 재생 중 플레이헤드가 이동할 때마다 경로·현재 위치를 갱신해 시간에 따라 경로가 생성되도록 했다. 경로 절단 시각은 선택된 플레이헤드를 상한으로 사용한다.

### 검증 및 설치

- `git diff --check`: 통과
- `TaptionPlanWidget` Debug 시뮬레이터 빌드: 성공
- 서명된 iPhone Debug 빌드: `1.0 (102)` 성공
- 연결된 iPhone 14 Pro(`C44AF739-127D-572D-AD83-417C7E879045`)에 `com.taption.plan` 설치·실행 성공
- `origin/main` 푸시 커밋: `5bcd766 fix: show app icon in sensor live activity`
- 실기기 앱 설치·실행은 확인했지만 Dynamic Island 확장/축소 터치와 센서 실시간 렌더링은 별도 수동 게이트로 남긴다.

### 저장소 정리

- 이번 작업에서 생성한 실기기 빌드 산출물과 오래된 Taption Plan DerivedData·임시 테스트 캐시를 삭제했다.
- 테스트 결과·릴리스 아카이브·시각 QA 증거와 다른 프로젝트가 공유하는 시뮬레이터 데이터는 보존했다.
- 현재 Git 워크트리는 clean이며 `main`과 `origin/main`이 일치한다.

## 2026-08-27 HZ240827A1 240Hz 입력 예산 전수 점검

- `TimelineInteractionFrameGate`에 240Hz 입력·60Hz 표시 기준과 zero timestamp 중복 발행 방지를 명시했다.
- MiniTimeSliceEditor·TimeSlider·메모·실제 기록 핸들·상세 패널·LocationTimeline·MapHome 보조 제스처의 중간 상태 변경을 60Hz로 합치고, 제스처 종료값은 즉시 반영한다.
- 재생 중 경로 투영과 지도 포커스는 각각 30Hz로 제한하고, 기존 NLE·MapKit·구간 경계·Review 게이트를 유지했다.

### 검증

- `TimeScaleTests` 전체가 `Taption-Compact-iPhone` 시뮬레이터에서 `TEST SUCCEEDED`로 통과했다. 240Hz 입력→60Hz 표시와 30Hz 재생 카메라 계약 테스트를 포함한다.
- `TaptionPlanCore` `CoreEngineContractsTests` 8/8 통과, synthetic 240Hz handler p95 `0.000042ms`로 입력 예산 4.17ms 이내다.
- `git diff --check`: 통과
- 최종 변경의 테스트 빌드 컴파일은 성공했으나, 별도 Debug 링크 재빌드는 호스트 여유 공간 108MiB에서 `errno=28`로 중단됐다. 실기기 Animation Hitches/Instruments와 실제 터치 검증은 별도 런타임 게이트로 남긴다.

## 2026-08-27 build 103 균형형 백그라운드 경로 보정 TestFlight

- 균형형 GPS 프로필의 자동 이동 승격을 실시간·균형형 주기에 맞게 허용하고, 10초 후보 판정이 끝나기 전에 샘플링 스트림이 종료되지 않도록 보정했다. 이로써 백그라운드 경로의 불필요한 공백을 줄인다.
- 기존 Dynamic Island 앱 아이콘 변경을 함께 포함해 compact·expanded 표시에서 회색 플레이스홀더 대신 앱 아이콘을 사용한다.

### 검증 및 배포

- `FeatureEngineTests.testAutomaticTrackingPromotionAndStopPolicy` 통과, 전체 앱 XCTest `test-without-building` 종료 코드 0, iOS Simulator Debug build 성공
- Release archive/export: `1.0 (103)`, `com.taption.plan`, Apple Distribution 서명, IPA SHA-256 `1dd71f0b94415a27aa6dd6053aef972a12357b26e4dfccea4132efac3716ab51`
- TestFlight 업로드 성공: Delivery UUID `a14a666d-08b0-4ec2-b510-7e40aa73feae`
- App Store Connect 처리 상태 `VALID` / `APP_STORE_ELIGIBLE`, Apple ID `6797370230`
- `TP Taption Plan 내부 테스트` 그룹에 build 103 연결 및 그룹 builds 관계에서 build 103 노출 확인
- 기능 커밋 `2d6ae63`, `origin/main` 푸시 확인
- 실기기 설치·실행·readback은 별도 게이트이며 Paid Apps Agreement·상품 생성·Sandbox 구매/복원은 `IAP73PAID1` 외부 게이트로 유지한다.

## 2026-08-27 I143RAWLOG 예상경로·센서 raw iCloud 분리 저장

- 오늘 iCloud 백업의 09:28:33~11:00:59 지하철 이동에는 정밀 iPhone GPS 원본이 있었지만, 대중교통 판정 플래그·확정 지하철 경로·역 근거가 없었다. 따라서 예상경로 조건은 충족했는데 `MapHomeView`의 `Map` 콘텐츠에 계산된 `visibleExpectedRouteOverlays`를 삽입하지 않아 표시되지 않았고, 초기 센서 읽기 완료 뒤 재요청도 없어 첫 로드에서 누락될 수 있었다.
- 예상경로를 점선 `MapPolyline`으로 지도에 렌더링하고, 센서 읽기 병합 후 예상경로 갱신을 다시 요청하도록 수정했다. 확정 지하철 경로와 예상경로의 표시 경계는 유지한다.
- 기존 월간 계획 백업과 분리해 `iCloud Drive/Taption Plan/Raw Sensors/YYYY-MM.rawsensorbackup`에 저장한다. 저장 대상은 영구 보존된 비HealthKit 센서 읽기·raw envelope이며, AES-GCM·TPZ1/LZFSE·SHA-256 무결성·iCloud 계정 복구 키를 사용한다. HealthKit 원본과 Apple Watch 건강 스냅샷은 저장하지 않는다.

### 검증

- iCloud 백업·진단·센서 DB 읽기 전용 대조: 오늘 route point 152개, 가장 긴 GPS 공백 약 64분 44초, `TaptionLogs` 파일 없음, 지하철 구간은 미확정·대중교통 플래그 없음
- `RouteTimelineDataTests` 및 `SecurityBackupCoreTests` 대상 XCTest 성공
- raw 암호화·분리 경로·HealthKit/Watch 건강 스냅샷 제외 회귀 테스트 성공
- iOS generic Debug build 성공, `git diff --check` 통과

## 2026-08-27 STICK827C3 졸라맨 지도 재생·경로 미리보기

- 회사는 컴퓨터·책상, 학교는 독서·책상, 수면은 침대·`zzz`, 식사는 식탁, 걷기·자전거·자동차·버스·2량 지하철 탑승을 단순 선화 Canvas 포즈로 표시한다.
- 현재 시각과 하루 재생 플레이헤드에서 같은 상태 판정기를 사용하고, 재생 중 30Hz fractional 시각으로 포즈·현재 위치를 함께 갱신한다. Reduce Motion에서는 정지 포즈를 사용한다.
- Taption WBS의 지도 재생 방식을 적용해 확정 지하철 경로는 역 좌표 투영을 사용하고, 일반 경로는 기존 RouteTimeline projection과 MapKit 예상경로를 공유한다. 예상경로는 도로 경로가 준비되기 전에도 시작·끝 직선 fallback을 표시하며, 부분 경로는 정점 개수가 아닌 거리 기준으로 절단한다.
- 기존 `RouteSpeedGradient` 속도별 색상, 실제·예상 경로 구분, 원본 센서·기록은 변경하지 않았다.
- 회사 위치가 새로 업무로 확정됐을 때 이전 `unknownStay` 자동분류 잠금이 덮어쓰지 않도록 보정하고, 사용자 수동 분류 잠금은 유지한다.

### 검증

- `MapHomeStickmanTests`, `RouteTimelineDataTests`, 회사 `unknownStay` 잠금 회귀 테스트 성공
- iOS generic Debug build 성공, `git diff --check` 통과
- Debug 앱을 iOS Simulator에 설치·실행했으나 지도 진입 전 `14일 무료 체험` 화면에서 멈췄다. 구매·구독 동작은 실행하지 않아 지도·실제 터치 시각 검증은 별도 게이트로 남긴다.

## 2026-08-27 build 104 파스텔 MapHome 활동 UI TestFlight

- 흰색 시간 사이드바·인접 날씨·기존 왼쪽 하단 네 가지 컨트롤을 유지하면서 MapHome 색상과 카드·버튼을 파스텔 조합으로 정리했다.
- 대분류 활동 핸들을 선화 졸라맨 포즈로 표시하고 회사·학교·수면·식사·걷기·자전거·자동차·지하철 상태별 애니메이션을 재생 시각과 현재 시각에 공통 적용했다.
- 240Hz 제스처 입력·60Hz 화면 갱신·30Hz 재생 경계를 유지하고 실제·예상 경로와 속도별 색상 표현을 보존했다.

### 검증 및 배포

- `FeatureEngineTests`·`TimeScaleTests` 대상 XCTest 581/581 통과, iOS Simulator Debug build 성공
- Release archive/export: `1.0 (104)`, `com.taption.plan`, Apple Distribution 서명, IPA SHA-256 `b5d49cd87d056349cdb5aa983cb3f36412711d26d2bbc43e309c8b3fb185e7a6`
- TestFlight 업로드 성공: Delivery UUID `36e77558-44a9-4389-ac82-d00a245e6078`
- App Store Connect 처리 상태 `VALID` / `APP_STORE_ELIGIBLE`, beta 상태 `IN_BETA_TESTING`
- `TP Taption Plan 내부 테스트` 그룹에 build 104 연결 및 그룹 builds 관계에서 build 104 노출 확인
- main 기능·빌드·서명 수정 커밋 `e579b09`, `f7ed488`, `de21ee4`, `origin/main` 일치 확인
- 실기기 설치·실행·readback은 iPhone 연결·잠금 해제 후 별도 게이트로 남긴다.

## 2026-08-27 build 106 대분류 졸라맨 Dynamic Island 통합

- 첨부 시안은 화면 구성·문구·색상 복제 없이 단순 선화, 얼굴 표정, 준비·이동·동작 원칙만 참고했다.
- 지도·활동 카드·핸들에 공통 얼굴과 표정, 바닥 그림자, 활동별 분주한 Canvas 동작을 적용했다. 회사·학교·수면·식사·걷기·자전거·자동차·버스·2량 지하철·머무름의 의미와 기존 지도 전면 표시·Reduce Motion·30% 축소를 유지한다.
- Live Activity 대분류 상태를 위젯 공유 코드에서 10개 졸라맨 동작으로 해석하고, Dynamic Island compact leading·minimal·expanded leading에서 SwiftUI Canvas 애니메이션으로 표시한다. 기존 타이머·파형·종료 동작은 유지한다.

### 검증 및 배포

- `MapHomeStickmanTests` 및 전체 `TaptionPlanTests`: `TEST SUCCEEDED`
- iOS generic Debug build: `BUILD SUCCEEDED`
- Release archive/export: `1.0 (106)`, `com.taption.plan`, Apple Distribution 서명, IPA SHA-256 `f5d66d090d3eea06e3628ff775ba1698a7289ca80e47ec629fe5cad0ce25aadc`
- TestFlight 업로드 성공: Delivery UUID `41dc832d-5a98-4a77-8122-aad743df6e28`
- App Store Connect 처리 상태: `VALID` / `APP_STORE_ELIGIBLE`, `is-on-app-store-connect: true`, build 106 `제출 준비 완료` 노출 확인
- 기능·빌드 커밋 `b67b9bb`, `origin/main` 푸시 확인
- `TP Taption Plan 내부 테스트` 그룹 연결 완료: 빌드 목록에서 build 106이 그룹에 연결된 것을 확인했다.
- 그룹 화면(`/testflight/groups/b4857e5e-d1ff-4bc2-b9ad-a69bcd4603fd`)의 빌드 탭에서 `1.0 (106)`, `테스트 중`, `iOS` 노출을 확인했다.

## 2026-08-27 ZIDX27A1B2 지도 졸라맨 최전면 고정

- MapKit `Annotation`의 내부 정렬은 SwiftUI `zIndex`로 보장되지 않아 장소·검색 핀이 졸라맨을 가릴 수 있었다. 졸라맨은 지도 내부의 1pt 투명 위치 앵커만 따라가고, 실제 Canvas는 모든 지도 annotation 위의 SwiftUI overlay에서 렌더링하도록 분리했다.
- 앵커 좌표는 240Hz 입력을 직접 상태에 전달하지 않고 최대 60Hz로 합치며, 카메라·타임라인 상호작용 종료 시 최신 좌표를 즉시 반영한다. 검색·사이드바·메뉴·상단 헤더는 기존대로 졸라맨보다 위에 유지한다.

### 검증

- 전체 `TaptionPlanTests` 732/732와 Swift Testing 10/10 통과, iOS generic Debug build 성공, `git diff --check` 통과
- 시뮬레이터에서 현재 위치와 인천광역시청 검색 핀을 같은 좌표에 표시했을 때 두 접근성 요소가 유지되고 화면에는 졸라맨이 최전면으로 표시되는 것을 확인했다. 현재 위치 이동과 연속 확대 뒤에도 표시가 유지됐다.
- iPhone 14 Pro에 `1.0 (106)` Debug 재설치·실행 및 PID 6805 readback을 확인했다. 15초 실행 콘솔에서 기존 `AttributeGraph` cycle 재발은 없었다.

## 2026-08-27 SLEEP827B2 07:15 수면 누락 원본 점검

- 연결된 iPhone 앱 컨테이너의 `sensor-readings-v1.jsonl` 15,826건을 읽기 전용으로 확인했다. 최신 원본은 2026-08-25 22:17:35 KST이며 2026-08-27 07:00~07:30 KST 표본은 0건이다.
- 따라서 앱 센서 원본만으로는 07:15 전후 수면 종료를 재구성할 수 없다. HealthKit 수면 원본은 별도 보관 정책상 앱 raw/iCloud 센서 백업에 포함되지 않고 현재 앱에는 원본 readback 화면이 없어, HealthKit의 실제 종료 시각은 이번 점검에서 확정하지 않았다.

## 2026-08-29 REL29TF7Q2 이동 후보·경로·Watch 동기화 릴리스

- OpenFreeMap/MapLibre 소스와 공개 경계는 보존하되 현재 런타임과 설정 메뉴는 Apple 지도 표준 스타일로 고정한다.
- 지하철역·기차역·버스 정류장·공항·항구 후보는 실제 동력 이동이 끝났고 분류 또는 기록 경로가 불확실한 경우에만 만든다. 확정됐거나 GPS 경로가 완전한 이동은 후보와 점선 예상 경로를 만들지 않는다.
- 오늘 날짜 재생은 현재 시각에서 멈추며 다시 재생하면 자정부터 시작한다. 재생 tick마다 전체 경로를 정규화하지 않고 화면 갱신 예산 안에서 기존 투영을 재사용한다.
- Apple Watch 수신 자료는 iPhone 수신 시각이 아니라 각 payload의 실제 측정 시각을 종류별로 보존한다. 지연·미래·역순 payload가 최근 수신 상태를 거짓으로 갱신하지 않으며 재실행 뒤에도 마지막 측정 시각을 복원한다.
- 12프레임 보행에서 지지 발의 접지 종료를 정확히 7/12 위상에 맞춰 경계 직전의 미세한 발 들림을 없앤다.
- TestFlight 배포 대상은 `1.0 (111)`이다. 직전 build 110은 App Store Connect에 이미 등록돼 있어 재사용하지 않는다.

### 검증 및 배포

- 전체 `TaptionPlanTests` 797/797 통과, 실패·스킵 0; generic iOS Debug build와 `git diff --check` 통과.
- 기능·빌드 커밋 `834a146`을 `origin/main`에 푸시하고 원격 SHA 일치를 확인했다.
- Release archive/export: `1.0 (111)`, `com.taption.plan`, Apple Distribution 서명, Store 프로비저닝, IPA SHA-256 `9699c711070d01b684454541be3043097379e1a032209f1104e95fba36349ea2`; App Store Connect 사전 검증 통과.
- TestFlight 업로드 성공: Delivery UUID `b70dc4c7-06e1-4bc8-85a9-13377ff1dcfa`; 처리 상태 `VALID`, 내부 상태 `IN_BETA_TESTING`.
- `TP Taption Plan 내부 테스트` 그룹에 build 111을 연결했다. 그룹 빌드 화면에서 `1.0 (111) · 테스트 중 · iOS`, 테스터 화면에서 내부 테스터 1명과 `설치됨 1.0 (111)` 노출을 확인했다.
- 실기기 설치·실행·HealthKit/Watch 실제 수신은 이번 TestFlight 업로드와 별도 게이트다.

## 2026-08-29 STK9V6Q2M4 졸라맨 18개 동작 재설계

- `MapHomeStickmanRenderer`의 졸라맨을 기존 Canvas 계약(64×56 좌표계, 진분홍 선화, 12프레임, Reduce Motion)을 유지한 채 관절·얼굴·소품이 함께 보이는 형태로 다시 구성했다.
- 시점은 걷기·달리기·일반 이동·버스·선박·자전거를 옆면, 업무를 오른쪽 사선 뒤, 학교·식사·운동을 왼쪽 사선 앞, 취미·미확인을 정면, 수면을 옆면, 차량을 정면으로 고정한다. 활동은 정면→왼쪽 옆→오른쪽 옆 순으로 12프레임을 순환한다.
- 업무는 모니터의 타이핑 텍스트와 키보드 입력을, 학교는 책·페이지 넘김을, 취미는 마이크·음표·노래하는 입 모양을, 수면은 침대·베개·이불·호흡·Z를, 미확인은 고개 갸웃과 물음표를 표시한다.
- 차량은 운전대와 정면 운전 자세로 통합하고 `자가용` 데이터도 `.car` 렌더링으로 통합했다. 선박은 난간과 물결 흔들림, 비행기는 큰 창과 탑승자, 2량 지하철은 큰 창·앞쪽 정면 승객·손잡이, 버스는 손잡이를 추가했다.
- 자전거는 옆면 페달 회전, 걷기·달리기는 보폭·접지 기반 동작을 유지하며, 모든 이동 동작은 기존 경로·재생 위치 투영과 함께 사용한다.
- 분류 회귀 기대값은 `TaptionPlanTests/FeatureEngineTests.swift`에서 `자가용 → .car`로 갱신했다. Live Activity의 별도 `privateVehicle` 계약은 변경하지 않았다.

### 검증 및 게이트

- 최신 소스 기준 generic iOS Debug build와 iOS Simulator `build-for-testing` 성공, `git diff --check` 통과
- iPhone 14 Pro `MapHomeStickmanTests` 20/20과 앱 실행은 최종 렌더 세부 패치 전 서명 Debug 상태에서 통과했다.
- 최종 렌더 세부 패치 후 동일 테스트 재시도는 iPhone 잠금 상태의 `deviceprep` 차단으로 중단됐다. 따라서 최종 소스의 실기기 화면·터치·동작 시각 검증은 미완료다.
- 현재 환경에는 사용 가능한 iOS Simulator 기기가 없어 Simulator 화면 검증을 완료할 수 없다. TestFlight archive/upload와 내부 그룹 readback은 이번 변경의 별도 미실행 게이트다.
- 새 채팅 인계 프롬프트는 `NEXT_CHAT_PROMPT.md`에 최종 푸시 SHA와 남은 실기기 게이트를 기록한다.

## 2026-08-31 ARC831A001 엔진·센서·저장소 통합 계획

- `TaptionPlanCore`는 Foundation 기반 공유 계약, 정본 payload, SQLite day-store와 원본을 변경하지 않는 범용 센서 품질 판정을 소유한다. 앱·Widget·Watch가 공유하는 App Group 식별자도 Core 계약으로 단일화한다.
- `TaptionActivityEngine`은 확정된 수면·운동·수동·잠금 기록을 hard anchor로 보존하고, 센서 근거가 있는 미확인 구간만 시간 연속성 기반으로 추론한다. 근거가 없거나 충돌하면 미확인으로 남긴다.
- `TaptionRouteEngine`은 GPS 정확도·물리 속도·Kalman innovation gate·정지 드리프트 억제를 하나의 원본 보존형 경로 필터로 통합한다. 경로 공백은 시간·거리·양 끝점·이동수단 근거를 모두 만족할 때만 파생 예상 경로로 연결한다.
- `TaptionPlanEngine`은 세 leaf package의 umbrella 공개 경계로 앱에서 실제 사용한다. MapKit·HealthKit·ActivityKit·CloudKit·SwiftUI 어댑터는 앱 target에 남기고, Widget·Watch target의 대규모 소스 재배치는 이번 안정화 범위에서 제외한다.
- SQLite는 schema 생성을 단일 transaction으로 묶고 raw event batch에 prepared statement를 재사용한다. canonical payload는 최대 크기와 선언된 원본 바이트 수를 검증하며, materialized day는 iPhone·Watch 원본 digest와 일치할 때만 사용한다. startup에는 `PRAGMA optimize`를 적용한다.
- 백업 복원은 staged snapshot을 정본 저장소에 먼저 저장하고 성공 뒤에만 메모리 상태를 publish한다. snapshot과 raw route는 부분 성공 상태를 명시하며, 실패 시 기존 메모리 snapshot을 유지한다. 월별 센서 chunk는 재실행 뒤 기존 번호 다음부터 이어 쓴다.
- 지도·타임라인 UI와 원본 센서·확정 기록은 변경하지 않는다. 각 변경은 package 단위 테스트, 앱 회귀 테스트, Debug build, Release archive 순으로 검증한 뒤 TestFlight 내부 그룹과 테스터 화면까지 readback한다.

### 검증 및 배포

- `TaptionPlanCore` 40건, `TaptionActivityEngine` 8건, `TaptionRouteEngine` 16건, `TaptionPlanEngine` 1건 등 package 65건과 앱 XCTest 848건·Swift Testing 18건이 모두 통과했다.
- generic iOS Debug·Release 빌드와 Release archive/export가 통과했다. 앱·Widget·Watch·Watch Widget은 모두 `1.0 (121)`이며 Apple Distribution 서명, Production iCloud, TestFlight entitlement와 deep codesign을 확인했다.
- 배포 소스 커밋 `53e18940bbf13459927d23053ad783f0b8431294`를 `origin/main`에 먼저 푸시했다. IPA SHA-256은 `3957d7f3800314fc9af6f201a3a4ad3ef20548120f6917072337ef187dffa667`이다.
- TestFlight Delivery UUID `d1cf40bf-7b56-42ef-a7cb-12d82067734c`는 처리 `COMPLETE`, 오류·처리 경고 0, App Store Connect에서 `제출 준비 완료`로 readback했다. MapLibre 외부 framework dSYM 미포함은 심볼 업로드 경고로 별도 기록하며 앱 업로드는 수락됐다.
- `TP Taption Plan 내부 테스트`에 build 121을 연결했다. 그룹 상세는 `내부 그룹 · 1명의 테스터 · 82개의 빌드`, 빌드 탭은 `1.0 (121) · 테스트 중 · iOS`, 테스터 탭은 내부 테스터 1명을 표시한다. 현재 설치 표시는 `1.0 (120)`이므로 build 121 설치·실행·실제 터치와 Apple Watch 현장 수신은 별도 게이트다.

## 2026-09-02 REL902A001 · CLN902A001 최신 배포·문서·저장소 정리

- build 126 배포 소스는 `6b302ea2f9bca3f818c829514af1ee147b83be47`이며, Release archive/export·Apple Distribution 서명·네 번들 `1.0 (126)`·deep/strict codesign·`altool --validate-app` 검증을 완료했다.
- TestFlight Delivery UUID는 `8e66a688-a922-4f76-b761-4da7b3faadb1`이고 App Store Connect API에서 build 126 `VALID`·`APP_STORE_ELIGIBLE`·`expired=false`를 확인했다. `TP Taption Plan 내부 테스트`(ID `b4857e5e-d1ff-4bc2-b9ad-a69bcd4603fd`)에 연결되어 그룹 빌드 87개와 내부 테스터 1명을 API readback했다.
- App Store Connect 그룹 빌드·테스터 화면은 Chrome과 in-app Browser가 로그인 화면으로 열려 자격 증명을 입력하지 않았으므로 남은 게이트다. Apple Watch 현장 수신과 Paid Apps Agreement·IAP·Sandbox 구매/복원도 기존 미완료 게이트로 유지한다.
- CLN902A001에서 종료된 구형 iOS Simulator 5대의 device data를 삭제했다. iOS/watchOS 26.5 runtime은 보존했다. 이후 다른 작업이 새 iPad Simulator `2CD5BB05-7C63-4D44-A0B3-170F83F62210`를 부팅해 실행한 XCTest는 중단하지 않았다.
- `/private/tmp`에서 문서 증적·현재 TestFlight archive·활성 카메라 로그를 제외한 소유 가능한 이전 임시 산출물 2,387개 약 27.92G를 정리했고, root 소유 `FTABHarvest` 1개는 보존했다. `XCTestDevices`·Xcode `DerivedData`는 0B, Xcode `Archives` 1.4G는 보존했다.
- 정리 readback은 `/private/tmp` 50G, 데이터 볼륨 여유 61G, 사용자 휴지통 0개다. `.codex`, 소스, 현재 실행 중인 WBS33 XCTest 산출물, REL902A001 release 증적, 활성 카메라 로그는 삭제하지 않았다.

## 2026-09-02 REL902A002 GTR 데이터 신뢰도·추론 통합

- 활동·수면·장소·이동·센서 판정에 `ActivityDataProvenance`를 연결해 원본 관측, 보조 데이터, 예상 데이터, 사용자 교정을 구분한다. 원본 센서와 확정 기록은 보존하고 화면·정본 이벤트에는 provenance marker를 함께 기록한다.
- 수면 추론은 iPhone 원본의 화면 꺼짐·무사용·이동 없음·충전/자택/야간 보조 조건을 모두 만족하고 5분 지속될 때만 자동 예상 기록을 만든다. 기존 자동 잠금과 사용자 확인 교정은 별도 상태로 유지한다.
- 장소·활동 분류와 GPS 공백 경로는 근거·confidence·model version을 유지하며, `Review`·`Schedule`·`MapHome`은 실제/보조/예상/미확인 신뢰도 라벨과 이동수단을 동일하게 투영한다. 원본 GPS와 예상 경로를 섞어 덮어쓰지 않는다.
- 앱·iOS Widget·Watch 앱·Watch Widget의 배포 build number를 `1.0 (127)`로 올렸다. 배포 소스 커밋은 `311b5832cc9819e91f16c79af2970eb7a6dbc51b`이며 `main`·`origin/main`·원격 main이 일치한다.

### 검증

- `TaptionActivityEngine` package 12/12, `TaptionRouteEngine` package 17/17 통과
- `TaptionPlan` 전체 XCTest 900/900 통과: iPad Pro (12.9-inch) (6th generation), iOS 26.5, `/tmp/GTR902A001-full-tests/Logs/Test/Test-TaptionPlan-2026.09.02_22-52-06-+0900.xcresult`
- 앱 target generic iOS Debug build 통과: `/private/tmp/GTR902A001-app-target-auto/Build/Products/Debug-iphonesimulator/TaptionPlan.app`
- Release archive/export 통과: `/private/tmp/REL902A002-release-v2/TaptionPlan-1.0-127.xcarchive`, `/private/tmp/REL902A002-release-v2/Export/TaptionPlan.ipa`; IPA SHA-256 `05f179337b4bdaa5c7dcd887adc1f5246ccd27de00d0d394210829f2c99c8aa0`
- 앱·iOS Widget·Watch 앱·Watch Widget 모두 `1.0 (127)`, Apple Distribution 서명·Production iCloud·TestFlight entitlement·deep/strict codesign 및 `altool --validate-app` 통과
- TestFlight 업로드 성공: Delivery UUID `3297b1a2-fde1-40b3-b219-b99f13cf4c1e`; App Store Connect API 처리 상태 `VALID`·`APP_STORE_ELIGIBLE`·`expired=false`
- `TP Taption Plan 내부 테스트`(ID `b4857e5e-d1ff-4bc2-b9ad-a69bcd4603fd`)에 build 127 연결 성공. 그룹 빌드 API에서 build 127과 전체 88개 빌드, 테스터 API에서 내부 테스터 1명(`axony99@gmail.com`, `INSTALLED`)을 readback했다.
- App Store Connect 그룹 빌드·테스터 실제 화면은 Chrome과 in-app Browser 모두 로그인 화면으로 열려 자격 증명을 입력하지 않았으므로 UI readback만 남은 게이트다.

## 2026-09-03 TF26PUSH01 build 128 TestFlight·기기 readback

- build number를 `1.0 (128)`로 올린 배포 소스 `84448b8aa8fc7b9de35b2903561a90095c2bee62`를 `main`에 커밋·푸시했다.
- `TaptionPlanCore` 40건, `TaptionActivityEngine` 12건, `TaptionRouteEngine` 17건, `TaptionPlanEngine` 1건 package 테스트가 모두 통과했다.
- Release archive/export 성공: `/private/tmp/TF26PUSH01-release-r2/TaptionPlan-1.0-128.xcarchive`, `/private/tmp/TF26PUSH01-release-r2/Export/TaptionPlan.ipa`; IPA SHA-256 `b6532fc4be01c52a03fe1ef85f60b3bdb5156f77901cdd7483812834db9154e6`.
- 앱·iOS Widget·Watch 앱·Watch Widget 모두 `1.0 (128)`, Apple Distribution 서명·Production iCloud·TestFlight entitlement·deep/strict codesign·`altool --validate-app` 통과.
- TestFlight 업로드 성공: Delivery UUID `3ce79d87-b2cd-429e-b988-816d0b9af84a`; App Store Connect API에서 build 128 `VALID`·`expired=false`를 확인했다.
- `TP Taption Plan 내부 테스트`에 build 128 연결 성공. 그룹 빌드 API에서 전체 89개와 build 128, 내부 테스터 API에서 1명(`axony99@gmail.com`, `INSTALLED`)을 readback했다.
- iPhone 14 Pro(`C44AF739-127D-572D-AD83-417C7E879045`) TestFlight 화면에서 Taption Plan 업데이트를 수행했고, `devicectl`로 `com.taption.plan` `1.0 (128)` 설치와 PID `26948` launch를 readback했다.
- iPad Pro(`4CEC6BE9-E528-52A1-AB94-654A6CDA7E5E`)는 현재 `1.0 (125)`이며 TestFlight 앱이 설치돼 있지 않다. beta IPA의 CoreDevice 직접 설치는 `0xe800801f Attempted to install a Beta profile without the proper entitlement`로 거부되어 TestFlight 앱을 통한 iPad 128 다운로드·설치·launch는 미완료다.
- App Store Connect 그룹 빌드·테스터 실제 화면은 로그인 화면으로 열려 자격 증명을 입력하지 않았으므로 UI readback은 미완료다.

## 2026-09-03 SLP903TF02 수면 연결 복구·TestFlight build 129

- 오늘 iCloud 월간·raw 센서 백업은 정상 갱신됐지만 Watch 건강 스냅샷이 `health_enabled=false`로 처리되어 HealthKit 수면 조회가 생략된 것이 누락 원인이었다.
- 오늘 수면 기록이 없고 건강 연동이 꺼진 경우 일정 화면에 원인 안내와 명시적 `수면 연결` 버튼을 표시한다. 버튼은 기존 HealthKit 권한 요청·전체 이력 동기화 경로를 사용하며 백그라운드에서 권한을 임의 활성화하지 않는다.
- 배포 소스 `3544ff8baf551cbe0b0817029e5ad5962048a6fa`, 전체 XCTest 901/901, generic iOS Debug build, Release archive/export, 네 번들 `1.0 (129)`, Production iCloud/TestFlight entitlement, deep/strict codesign과 `altool --validate-app`을 확인했다.
- archive `/private/tmp/SLP903TF02-release/TaptionPlan-1.0-129.xcarchive`, IPA `/private/tmp/SLP903TF02-release/Export/TaptionPlan.ipa`, SHA-256 `3acc55045b44c3bbc94e6172edf43f372ab9efba467b347e65b8aec2d546c723`이다.
- TestFlight Delivery UUID `411a22f3-430a-48fb-bde7-03269ca710e6`은 API에서 `VALID`·`APP_STORE_ELIGIBLE`·`expired=false`다. `TP Taption Plan 내부 테스트` 연결 후 그룹 build 90개 중 build 129와 내부 테스터 1명(`INSTALLED`)을 readback했다.
- 실제 iPhone에서 `수면 연결` 탭·HealthKit 수면 권한 승인·오늘 기록 재조회와 build 129 설치·launch는 사용자가 돌아온 뒤 확인할 별도 물리 게이트다.

## 2026-09-03 SID903A001 날짜 전환 사이드바 분류 유지

- 날짜 변경 시 지도 일자 상태 초기화가 사이드바 레일을 하루 전체 `미확인`으로 먼저 덮어쓰는 원인을 확인했다.
- 경로 상태를 초기화할 때 선택한 날짜의 저장 actual·travel을 즉시 다시 투영해 대분류를 유지하도록 수정했다.
- 서로 다른 날짜의 `업무`·`수업` 분류가 섞이거나 미확인으로 소실되지 않는 집중 XCTest와 Debug 테스트 빌드를 통과했다: `/private/tmp/SID903A001-focused-r2.xcresult`.

## 2026-09-03 TF903B013X TestFlight build 130

- 날짜 전환 사이드바 대분류 유지 수정이 포함된 배포 소스 `1829efb1d02c7e81724787e5c787a9d4fff260a1`를 main에 푸시했다.
- 전체 XCTest 902/902, 실패·스킵 0을 통과했다: `/private/tmp/TF903B013X-full.xcresult`.
- Release archive/export와 네 번들 `1.0 (130)`, Production iCloud/TestFlight entitlement, deep/strict codesign, `altool --validate-app`을 확인했다.
- archive `/private/tmp/TF903B013X-release/TaptionPlan-1.0-130.xcarchive`, IPA `/private/tmp/TF903B013X-release/Export/TaptionPlan.ipa`, SHA-256 `0904b72f68a00f32bd7cd29b48c027acfb4764c684d3696265b1fb1035218fa8`이다.
- Delivery UUID `064f2803-95d1-458b-96bc-819b087c13c9`은 API에서 `VALID`·`APP_STORE_ELIGIBLE`·`expired=false`다. 내부 그룹 연결 후 그룹 build 91개 중 build 130과 내부 테스터 1명(`INSTALLED`)을 readback했다.

## 2026-09-03 REL903TF01 TestFlight build 131

- Apple Watch 자동 가져오기·가속도 설정을 Watch 앱 행 바로 아래로 이동하고, 이동이 아닌 졸라맨 동작은 정지 프레임으로 고정했다.
- 기능 소스 `4c5d9aaf76ef558ec3302f2763bb27562eac45aa`, 배포 소스 `cceb9f655c76b4e5981891ed7f80c89f03b6a2cc`를 `main`에 푸시했다. 비이동 동작 회귀 XCTest와 Debug 테스트 빌드가 통과했다.
- Release archive/export 성공: `/private/tmp/taption-rel903-build131/TaptionPlan-1.0-131.xcarchive`, `/private/tmp/taption-rel903-build131/Export/TaptionPlan.ipa`; 네 번들 모두 `1.0 (131)`, deep/strict codesign과 `altool --validate-app` 통과, IPA SHA-256 `4435667dba069fda3706217b5c6af8947cef75eb72689525bc2fd75dd603f6f8`.
- Delivery/build UUID `805169b0-e3d9-41b2-883d-475504a3884d`는 API에서 `VALID`·`expired=false`다. `TP Taption Plan 내부 테스트` 연결 후 그룹 build 92개 중 build 131과 내부 테스터 1명(`axony99@gmail.com`, `INSTALLED`)을 readback했다.
- build 131 실기기 설치·launch와 실제 Watch 설정·비이동 정지 화면 확인은 별도 물리 게이트다.

## 2026-09-04 LOG904TF01 진단 로그·TestFlight build 132

- 잠긴 걷기 판정보다 최신 유효 지하철 노선을 우선하도록 수정하고, 이동 판정에는 지하철 노선/모드 불일치·잠금 수, 권한 흐름에는 안내 사유·HealthKit 요청/완료/실패를 진단 로그로 남긴다. 기존 예상경로 생성 이벤트와 `health_refresh_completed`의 수면 세션 수도 함께 확인할 수 있다.
- 집중 XCTest 4/4와 Release archive/export, `altool --validate-app`을 통과했다. 배포 소스 `f3425f951d9b05e67be39fcab62847244e77d31f`, 네 번들 `1.0 (132)`, archive `/private/tmp/taption-rel904-build132/TaptionPlan.xcarchive`, IPA `/private/tmp/taption-rel904-build132/Export/TaptionPlan.ipa`, SHA-256 `afc0a852750c0b67e017453a5b9c3aea05cf6b41bb89be211185496ac4de0b5b`다.
- Delivery/build UUID `5d01450c-2c10-4b8f-bcff-8852258fe2f1`은 API에서 `VALID`·`APP_STORE_ELIGIBLE`·`expired=false`다. `TP Taption Plan 내부 테스트` 연결 후 그룹 build 93개 중 build 132와 내부 테스터 1명(`axony99@gmail.com`, `INSTALLED`)을 readback했다.
- build 132 설치·launch 및 지하철·예상경로·수면 iCloud 로그 확인은 대표님 테스트 뒤 진행할 물리 게이트다.

## 2026-09-04 TFB904A133 실행 성능·TestFlight build 133

- 실행마다 30일 파생 데이터를 다시 만들고 불완전 day DB 마이그레이션과 원시 센서 백업을 반복하던 경로를 제거·복구형으로 바꾼 기능 커밋은 `8d041e9284d8393cbbf1157cf2b795c1cb6b51cf`, build 133 배포 소스는 `3930b808c86f20b003e474c56846252156303b41`이다.
- 관련 XCTest 4/4와 generic iOS Simulator Debug build가 통과했다. Release archive/export 및 `altool --validate-app`도 통과했고, 앱·iOS Widget·Watch 앱·Watch Widget 모두 `1.0 (133)`, Apple Distribution 서명, `beta-reports-active=true`, `get-task-allow=false`다.
- archive `/private/tmp/TFB904A133-release/TaptionPlan-1.0-133.xcarchive`, IPA `/private/tmp/TFB904A133-release/Export/TaptionPlan.ipa`, SHA-256 `422bcb43a8822b7eac2ff7935471acecddd5a46c2ade6a506ccf6cebdda92f4a`다.
- Delivery/build UUID `bc2b0f81-83f2-4001-80f2-19707a1b1fcc`는 `BUILD-STATUS: VALID`, `IMPORT-STATUS: VALID`, `APP_STORE_ELIGIBLE`, `expired=false`다. `TP Taption Plan 내부 테스트` 연결 후 API에서 그룹 build 94개 중 build 133과 내부 테스터 1명(`INSTALLED`)을 readback했다.
- Chrome 그룹 빌드 화면에서 `1.0 (133) · 테스트 중 · iOS`, 테스터 화면에서 내부 테스터 1명과 그룹 전체 94개 빌드를 확인했다. 테스터 설치 표시는 기존 `1.0 (132)`이므로 build 133 TestFlight 설치·launch·실제 발열은 별도 물리 게이트다.
- 디스크 확보를 위해 재생성 가능한 성능 검증·build 132·build 133 DerivedData 약 3.2G를 영구 삭제했다. build 132/133 archive·IPA와 build 133 XCTest 결과는 보존했다.

## 2026-09-04 REL904A001 센서 위치·수면·경로·지하철 수정 및 TestFlight build 134

- iCloud 로그에서 현재위치 점과 졸라맨의 좌표 소스 분리, iPhone 수면 표본 역순으로 인한 0초 provenance, 8분·6.7km 경로 공백 기준 불일치, 후속 재분석의 중간 신뢰도 지하철 덮어쓰기를 확인하고 수정했다.
- `TaptionActivityEngine` package 12/12, iOS 집중 XCTest 3/3, Debug build가 통과했다. 배포 소스 커밋 `f99d72b93919e8646a6fc7d9908330e524eb6034`를 `main`에 커밋·푸시했다.
- Release archive/export 성공: `/private/tmp/taption-rel904-build134/TaptionPlan.xcarchive`, `/private/tmp/taption-rel904-build134/Export/TaptionPlan.ipa`; 네 번들 `1.0 (134)`, IPA SHA-256 `225ba74b3de11b05e1c4a530d20a21b495b34ca0b22f8af503184b9dabf45851`이다.
- `altool --validate-app` 및 업로드 성공. Delivery UUID `a3581625-8668-4d3a-85c1-240078bc054e`는 App Store Connect API에서 `VALID`, `expired=false`로 readback했다.
- `TP Taption Plan 내부 테스트`에 build 134 연결 후 그룹 빌드 API에서 build 134와 내부 테스터 1명을 readback했다. TestFlight 설치·실행·발열·실제 수면·지하철 화면은 별도 물리 게이트다.

## 2026-09-06 SEC906P002 HealthKit 자동 추정 source 경계

- HealthKit 원본 import와 provenance는 그대로 보존하고, 자동 행동·생체 추정에는 `com.apple.Health`, `com.apple.health`, `com.taption.plan` source만 사용하도록 제한했다. 사용자 입력 기록은 source와 관계없이 명시적 기록으로 보존한다.
- 다른 앱 source의 연속 심박·에너지·생체값이 자동 활동으로 투영되지 않는 회귀를 추가했다.
- `HealthKitIntegrationTests` 21/21 통과: `/private/tmp/SEC906P002-health-derived/Logs/Test/Test-TaptionPlan-2026.09.06_14-46-36-+0900.xcresult`.

## 2026-09-22 RSC0922C01 클라우드 복원 동시 변경 보호

- `AppModel.applyCloudBackup`가 첫 비동기 작업 전에 원본 snapshot과 revision을 캡처하고, 복원 중 로컬 권한·교통 설정은 해당 snapshot에서 가져오도록 했다. 저장은 캡처한 revision을 조건으로 수행하며, 진행 중 로컬 변경으로 commit이 거절되면 삽입한 raw sensor receipt를 되돌리고 복원 snapshot을 게시하지 않는다.
- 저장소 commit을 멈춘 동안 로컬 메모를 추가하는 회귀에서 복원은 `.unchanged`를 반환하고 로컬 메모는 앱 snapshot·저장소에 남으며 복원 reading은 삭제됨을 확인했다. iOS 26.5 iPhone 17 Pro Simulator 1/1 통과: `build/validation/RSC0922C01-final.xcresult`.

## 2026-09-22 BGR0922C01 · WPR0922C01 백업·Watch purge 경합

- 월 raw backup 생성은 snapshot commit이 취소/실패하면 현재 snapshot의 generation 참조를 다시 읽은 뒤에만 staged raw를 삭제한다. 참조 여부 readback이 실패하면 snapshot/raw 한 쌍을 보존한다. commit 후 cancellation, rollback-save 실패, snapshot readback 실패, commit 전 cancellation 회귀가 통과했다.
- Watch manual HealthKit sync는 purge 중 새 admission을 거부하고 ambient drain 뒤 시작 generation을 재검사한다. periodic health-sync restart도 purge 중 차단한다. 회귀는 purge 전 대기 요청·purge 중 신규 요청·purge 후 신규 요청을 확인한다.
- 복원 동시성·백업 3경로·Watch gate 총 5개 XCTest가 iOS 26.5 iPhone 17 Pro Simulator에서 통과했다: `build/validation/WPR0922C01-final2.xcresult`.
