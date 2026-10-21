# 코드 리뷰 노트 (읽기 전용)

작성일: 2026-10-21. 수정은 하지 않았습니다. 수정 전 각 항목을 실제 코드에서 다시 확인하세요.

## 커버리지와 신뢰도

- 5개 영역을 읽기 전용 에이전트로 나눠 검토했습니다. 전체 정독이 끝난 영역은 없습니다.
  - MapHome UI(`TaptionPlan/UI/MapHome*.swift`): 약 48회 도구 호출로 주요 구간을 봤습니다.
  - Core 엔진(`TaptionPlan/Core/`): 10회 호출이었고 대부분 위험 패턴 위주로 확인했습니다.
  - UX·나머지 UI(`TaptionPlan/UX/`, `TaptionPlan/UI/` 비-MapHome): 13회 호출로, 약 7만 줄 중 일부만 봤습니다. 에이전트가 직접 누락을 밝혔습니다.
  - Packages·Watch·Widget: 30회 호출. `WatchWorkoutManager.swift`, `WatchConnectivityController.swift`는 구간별로만 봤습니다.
  - 나머지(`TaptionPlan/` 기타): 테스트 파일은 훑기만 했습니다. `ContentView.swift`(Watch), `WatchLaunchDiagnostics.swift`는 읽지 않았습니다.
- `ScheduleView.swift`(약 1.2만 줄), `ReviewView.swift`, `SettingsView.swift`는 거의 읽지 않았습니다.
- 표기: **[확인]** 은 해당 줄을 직접 읽어 확인한 항목입니다. **[추정]** 은 흐름 추론이나 호출부 미확인 상태입니다. 나머지는 에이전트가 읽은 내용 기준입니다.

## 우선 확인 (높음·중간 중 영향 큼)

### 센서·저장 데이터 유실

- `TaptionPlan/Core/WatchSensorQueryPlan.swift:132-146` **[확인]** `succeeded`가 같은 실행 안의 앞 토막 실패를 무시하고 워터마크를 뒤로 옮깁니다. 실패한 구간이 다시 읽히지 않아 센서 원본이 유실될 수 있습니다.
- `TaptionPlanWatch/WatchConnectivityController.swift:604-611` 센서 요약·가속도·건강 스냅샷은 `transferUserInfo` 예약 직후 spool에서 지워집니다. 실패 콜백이 `ambientDeliveryID`가 없으면 바로 반환해 재전송이 없습니다. [추정: 실패 빈도]
- `TaptionPlanWatch/WatchConnectivityController.swift:911-916` 전체 삭제 시 `ambientDeliveryID`가 있는 대기 전송만 취소합니다. 요약·가속도·건강 전송은 취소하지 않아 삭제 뒤에도 과거 데이터가 iPhone으로 다시 올 수 있습니다.
- `TaptionPlanWatch/WatchAmbientSensorRecorder.swift:207-216` [추정] `accelerometerData`가 nil을 줘도 성공으로 기록하고 워터마크를 전진시켜, 조회되지 않은 구간이 영구히 건너뛰어질 수 있습니다.
- `TaptionPlanWatch/WatchConnectivityController.swift:445-451`, `:545-551` [추정] 가속도 청크·건강 스냅샷을 `transferUserInfo`와 `sendMessage`로 함께 보내고 전달 ID가 없어, 수신 측이 중복 제거하지 않으면 두 번 저장됩니다.
- `TaptionPlanWatch/WatchConnectivityController.swift:493-508` [추정] 명령·확인 응답 등 같은 envelope을 두 경로로 보냅니다. iPhone이 중복 제거하지 않으면 명령이 두 번 적용됩니다.
- `TaptionPlanWatch/WatchConnectivityController.swift:1328-1376` [추정] 비동기 센서 flush에 in-flight 가드가 없어 트리거가 겹치면 같은 스냅샷이 두 번 전송될 수 있습니다.
- `TaptionPlanWatch/WatchAmbientSensorRecorder.swift:202-243` [추정] 창 조회가 중간에 실패해도 부분 표본이 남아, 다음 drain이 같은 sequence로 내용이 다른 요약을 만들고 DB `payloadConflict`가 날 수 있습니다.
- `TaptionPlan/Core/SensorDataServices.swift:351` `SensorReadingArchive.init`이 실행마다 레거시 `sensor-readings-v1.jsonl`을 마이그레이션 없이 삭제합니다. 이 파일에만 있던 센서 원본은 복구할 수 없습니다.
- `TaptionPlan/Core/SensorFusion.swift:5129-5143` **[확인 가능]** `resolvingOverlaps`에서 우선순위가 높은 구간이 기존 구간 안에 완전히 포함되면 뒤쪽 조각 `[segment.end, last.end]`이 버려집니다. 예: 10:00–11:00 자동차 안의 10:20–10:25 지하철이면 10:25–11:00 구간이 사라집니다.
- `TaptionPlan/Core/SensorFusion.swift:3277-3279` [추정] 체류 구간 분할이 직전 표본이 아니라 그룹 첫 표본 기준이라, 같은 자리에서 약 2분 단위로 계속 쪼개질 수 있습니다.

### 백업·복원

- `TaptionPlan/Core/TaptionBackupEngine.swift:333-355` `supersetViolation`이 행 수·마지막 시각·수정 시각만 비교하고 id를 보지 않습니다. 개수만 같으면 원격 백업이 로컬 내용으로 덮어써질 수 있습니다. [추정: 트리거 조건] (기존 검사가 있어 중간으로 낮춤)
- `TaptionPlan/Core/TaptionBackupEngine.swift:489-503` 복원 적용이 2,000행 배치마다 따로 커밋됩니다. 중간 배치에서 `readingConflict`가 나면 앞 배치만 남은 부분 복원 상태가 됩니다.
- `TaptionPlan/Core/PlanBackupEngineAdapter.swift:10-31` 비밀번호 입력 전에 백업 월 파일 이름·크기·봉인 여부를 목록으로 보여 줍니다. 프로젝트 규칙(목록은 비밀번호 입력 후)과 어긋납니다.
- `Packages/TaptionPlanCore/Sources/TaptionPlanCore/StorageContracts.swift:382-404` 봉투 디코더가 `mediaReferences`·`contentLinks`·`externalCalendarPreferences`를 `decodeIfPresent` 없이 요구합니다. 같은 파일의 `MemoRecord`는 `decodeIfPresent`를 씁니다. 이 필드가 나중에 추가됐다면 기존 v2 기록 디코드가 실패합니다. [추정]
- `Packages/TaptionPlanCore/Sources/TaptionPlanCore/DayStoreV3.swift:402-410` [추정] `finishRestoreSession(committed:false)` 루프에서 receipt 하나의 디코드가 실패하면 트랜잭션 전체가 롤백되고, receipt가 남아 매번 같은 실패가 반복될 수 있습니다.
- `Packages/TaptionPlanCore/Sources/TaptionPlanCore/DayStoreV3.swift:2186-2197` [추정] 빈 `Data`를 bind하면 `baseAddress`가 nil이라 NULL로 바인딩되고, `payload NOT NULL` 제약에 걸려 빈 payload 원시 이벤트 append가 실패합니다.
- `Packages/TaptionPlanCore/Sources/TaptionPlanCore/DayStoreV3.swift:1298-1305` [추정] rawDigest 읽기 경로가 `BEGIN IMMEDIATE` 쓰기 트랜잭션으로 캐시를 기록해, 다른 연결과 경합하면 5초 뒤 읽기 API가 throw합니다.
- `Packages/TaptionPlanCore/Sources/TaptionPlanCore/DayStoreV3.swift:116-123` [추정] 공개 생성자 `TaptionPlanRawEventCursor(after:)`는 `scanState`가 nil이라 쓰기 뒤 stale 검사가 없어, 쓰기 뒤에 이 커서를 저장하면 이벤트가 건너뛰거나 중복될 수 있습니다.

### 앱 상태·동시성

- `TaptionPlan/Core/TaptionStoreRepository.swift:62-70` [추정] `load()`가 throw해도 `known`이 부분 상태로 남아, 다음 `save()`가 스냅샷에 없는 행을 삭제 표시할 수 있습니다.
- `TaptionPlan/Core/PlanRepository.swift:202-216` 삭제 마커의 pid가 살아 있거나 `EPERM`이면 모든 저장을 막습니다. pid가 재사용되면 저장이 계속 실패할 수 있습니다.
- `TaptionPlan/Core/BiometricDataProtection.swift:197-209` `@MainActor` 클래스에서 스냅샷 JSON 인코딩·LZFSE·AES·파일 쓰기를 동기로 실행해 메인 스레드를 막습니다. [추정: 체감]
- `TaptionPlan/Core/WidgetShared.swift:2785-2792` 명령 파일을 읽고 삭제하는 사이에 위젯 확장이 추가한 명령을 잠금 없이 삭제해 적용되지 않을 수 있습니다.
- `TaptionPlanWidget/TaptionPlanWidget.swift:2173-2179`, `:2218-2225` [추정] 위젯 인텐트가 load→apply→save를 앱과 잠금 없이 수행해 앱의 동시 저장을 덮어쓸 수 있습니다.
- `TaptionPlanWidget/TaptionPlanWidget.swift:2189-2192` [추정] 공유 저장소 저장 뒤 `writePayload`가 던지면 인텐트가 실패하고 명령이 큐에 들어가지 않아 앱과 위젯 상태가 어긋납니다.
- `TaptionPlanWidget/TaptionPlanWidget.swift:2218-2225` 저장이 `try?`로 무시된 뒤에도 미저장 스냅샷으로 위젯 페이로드를 씁니다.
- `TaptionPlan/Core/PlanDayDatabase.swift:317-332` `cachedSnapshot`이 `source`·`sourceRevision`을 버리고 이전 스냅샷을 돌려줘, 편집 뒤에도 옛 계획이 로드 완료 전까지 보입니다.
- `TaptionPlan/TaptionPlanApp.swift:101-102` [추정] 백그라운드 깨움의 `backgroundTaskInstance()`가 UI용 `AppModel`과 별개 인스턴스를 만들 수 있어 두 인스턴스가 같은 저장소에 동시에 씁니다 (`TaptionPlan/UX/AppModel.swift:868-873`, `1622-1623` 관련).
- `TaptionPlan/TaptionPlanApp.swift:191-198` [추정] `sensorRecoveryTask`를 취소하지 않아 같은 모델의 백그라운드 새로고침과 겹칠 수 있습니다.
- `TaptionPlan/TaptionPlanApp.swift:140` `try? await ... add(request)`로 센서 깨움 알림 등록 실패를 무시합니다.

### 시간·날짜 계산

- `TaptionPlan/UX/AppModel.swift:4710` `synchronizeCloud`가 취소·실패와 무관하게 끝에서 `isCloudSyncing = false`를 실행해, 겹쳐 시작된 새 동기화 중에도 진행 표시가 꺼질 수 있습니다.
- `TaptionPlan/UX/AppModel.swift:4713-4717` `startManualCloudSync`가 이전 `cloudSyncTask`를 취소만 하고 기다리지 않아, 두 작업의 마지막 상태 갱신이 겹칩니다.
- `TaptionPlan/UX/AppModel.swift:4445` `refreshEnabledData`가 `isRefreshingIntegrations`이면 요청을 조용히 버려, 그 사이 바뀐 날짜·옵션의 갱신이 누락될 수 있습니다. [추정: 호출부별 재시도]
- `TaptionPlan/UX/AppModel.swift:2781-2783` 선택 날짜 갱신 Task가 플래그를 타임아웃 없이 폴링합니다. 리셋 경로가 없으면 무한 대기합니다. [추정: 4488-4491의 defer 여부 미확인]
- `TaptionPlan/UX/AppModel.swift:10057` `TransitBoardingDecisionEngine.applying(...)[0]`이 결과가 정확히 1개라고 가정합니다. 빈 결과면 크래시입니다. [추정: 엔진 본문 미확인]
- `TaptionPlan/UI/AddPlanSheet.swift:951-961` 목표 종료일 계산에서 사용자 지정 범위는 `startOfDay`를, 기본 범위는 정규화하지 않은 `startAt`을 써서 같은 기간이 경로에 따라 다르게 계산됩니다.
- `TaptionPlan/UI/AddPlanSheet.swift:998` 캘린더 연산 실패 시 `months * 30 * 86_400`으로 대체해 실제 월 길이와 어긋납니다. (발생 가능성 낮음)
- `TaptionPlan/Core/RouteTimelineData.swift:1910-1912` `Dictionary.values` 순서로 구간을 모아, 같은 시작 시각 구간의 순서가 실행마다 달라져 이동 모드 선택이 비결정적일 수 있습니다. [추정]
- `TaptionPlan/Core/PlanningEngine.swift:1955-1963` 사진 묶음이 시작점이 아니라 직전 사진과의 간격으로 묶여, 20분 간격 연속 촬영이면 하루 종일 한 묶음이 될 수 있습니다. [의도 추정]
- `TaptionPlan/Core/WatchSyncModels.swift:3127-3139` 요약 보존 함수는 `startedAt <= cutoff`이면 `endedAt > cutoff`여도 전체를 버리는데, 청크 쪽은 시작 시각을 잘라 두 규칙이 맞지 않습니다. [추정]

### Watch·워크아웃

- `TaptionPlanWatch/WatchWorkoutManager.swift:848-882` `deleteAllLocalData` 후반에 실패하면 session·builder는 nil인데 `isActive`·`startedAt`·`linkedPlan`은 남습니다. `stop()`은 session 가드로 nil을 반환해 앱을 재시작하기 전까지 운동을 끝낼 수 없습니다.
- `TaptionPlanWatch/WatchWorkoutManager.swift:1085-1112` 여러 호출자가 공유하는 `healthSnapshotTask`를 한 호출자의 `onCancel`이 취소해, 수동 동기화(`syncNow`)의 스냅샷까지 취소될 수 있습니다.
- `TaptionPlanWatch/WatchWorkoutManager.swift:2282-2287` `didChangeTo`가 비어 있어, 시스템이 세션을 ended·paused로 바꿔도 `isActive`와 센서 상태가 갱신되지 않습니다.
- `TaptionPlanWatch/WatchWorkoutManager.swift:1475-1478` `reset()`은 delegate만 nil로 하고 `end`·`discardWorkout`을 호출하지 않습니다. `stop()`의 `finishWorkout` 실패 경로(799-806)에서도 builder 정리가 빠집니다. [추정]
- `TaptionPlanWatch/WatchWorkoutManager.swift:1114-1128` 필수 HealthKit 타입 하나라도 nil이면 권한 요청 없이 return하고, 호출자는 성공으로 진행합니다. [추정]
- `TaptionPlanWatch/WatchConnectivityController.swift:94-95`, `:110`, `:192-200` `prepare()`가 이전 실행 로그를 메모리 `pendingLaunchReport`로만 잡은 뒤 파일을 바로 비웁니다. 전송 전에 다시 죽으면 첫 번째 크래시 기록이 사라집니다.
- `TaptionPlanWatch/WatchConnectivityController.swift:1199-1211` [추정] `handledWorkoutRequestIDs`가 101번째 요청에서 통째로 리셋되어, 이전 요청이 재전달되면 start·stop이 다시 실행될 수 있습니다.
- `TaptionPlanWatch/WatchConnectivityController.swift:1127-1141` [추정] 재시도 Task가 세션 비활성 상태를 만나면 재예약 없이 반환해, 다음 외부 트리거 전까지 outbox 재전송이 멈춥니다.
- `TaptionPlanWatch/WatchConnectivityController.swift:1453-1455` [추정] 전송 실패 시 `cachePending`이 이미 대기열에 있는 요약을 다시 넣어 중복 방지 정책이 없으면 중복 적재됩니다.
- `TaptionPlanWatch/WatchAmbientSensorRecorder.swift:194-195` [추정] `armedAt`이 없으면 시퀀스 기준점을 `windows[0].start`로 잡아, 실행마다 같은 표본의 시퀀스가 달라질 수 있습니다.
- `TaptionPlanWatch/ContentView.swift:257-261` 확인 버튼을 연속으로 누르면 같은 token의 confirmation이 중복 전송됩니다. acknowledged 상태는 전송 후에야 설정됩니다.
- `TaptionPlanWatch/WatchConnectivityController.swift` ↔ `TaptionPlan/Core/WatchSyncModels.swift:3290-3300` 수신 바이트 상한(요약 2MB, 건강 512KB)이 요소 상한보다 작아, 정상 크기 운동 요약이 `payload_too_large`로 거부되고 응답이 없어 송신 측이 무한 재시도할 수 있습니다. [추정]
- `TaptionPlan/Core/WatchConnectivitySupport.swift:1050-1058` 요약이 너무 크면 함수가 `return`해, 같은 봉투의 청크·건강 스냅샷·확인 응답이 처리되지 않고 누락됩니다.
- `TaptionPlan/Core/WatchSyncModels.swift:978-989` 앰비언트 샘플 키 집합이 추가만 되고 비워지지 않아 장기 실행 시 메모리가 늘어납니다. [추정]
- `TaptionPlan/Core/WatchAmbientSummaryAccumulator.swift:266-268` 백그라운드 요약을 `workoutKind: .walking`으로 찍어 소비 측이 걷기 운동으로 오인할 수 있습니다. [추정]
- `Packages/TaptionPlanCore/Sources/TaptionPlanCore/WatchHealthLaunchPolicy.swift:6-14` [추정] `healthEnabled`만으로 `.refresh`를 반환하고 권한 요청 이력을 보지 않아, 권한을 한 번도 요청하지 않은 설치에서 건강 조회가 빈 결과로 끝날 수 있습니다.

### 위젯·LiveActivity

- `TaptionPlanWidget/TaptionPlanWidget.swift:3623-3626`, `:3702-3706` [추정] `ProgressView(timerInterval: startedAt...endsAt)`는 `endsAt < startedAt`이면 범위 생성에서 트랩합니다. `TaptionPlan/Core/LiveActivitySupport.swift:476`이 종료 상태의 `endsAt`을 `min(.now, plan.span.end)`로 써서 계획 시작 전에 끝내면 역전될 수 있습니다.
- `TaptionPlanWidget/TaptionPlanWidget.swift:2364-2370` [추정] `Int(heartRate.rounded())`가 매우 큰 유한값에서 트랩합니다.
- `TaptionPlanWidget/TaptionPlanWidget.swift:252-261` 뷰 init마다 앱그룹 스냅샷을 메인 스레드에서 동기로 읽고 디코드해, 페이로드가 크면 프레임이 지연됩니다.
- `TaptionPlanWidget/TaptionPlanWidget.swift:2253-2266` `Scanner.scanHexInt64` 실패 시 0(검정)이 되고 8자리 ARGB를 잘못 해석해, 잘못된 `categoryHex`가 조용히 검은색으로 보입니다.
- `TaptionPlanWidget/TaptionPlanWidget.swift:2220-2222` [추정] 위젯 버튼으로 `locationEnabled = true`를 설정할 때 위치 권한 상태를 확인하지 않습니다.
- `TaptionPlanWidget/TaptionPlanWidget.swift:3722`, `:349-353`, `:411` 잠금 화면 "종료", 빈 상태 안내, 접근성 라벨 "GPS 트래킹 권한 안내 열기"가 한국어로 하드코딩되어 언어 설정을 따르지 않습니다.
- `TaptionPlan/Core/StoreKitSupport.swift:79-82` 저장된 `startedAt`이 아주 먼 미래이면 `Int(ceil(...))` 변환이 트랩해, `TaptionProAccessController.init`에서 매 실행 크래시가 날 수 있습니다 (값이 기기에 영속).
- `TaptionPlan/Core/StoreKitSupport.swift:667-671` `UInt64(... * 1e9)` 상한 곱이 2^64 근처가 되어 먼 미래 `startedAt`에서 트랩 가능. [추정]
- `TaptionPlan/Core/StoreKitSupport.swift:445-452` 검증 실패 거래를 `finish()` 없이 끝내 다음 실행마다 `Transaction.updates`로 다시 전달됩니다.
- `TaptionPlan/Core/LiveActivitySupport.swift:252-281` `stop`이 `await activity.end` 뒤에 `self.activity = nil`을 실행해, 그 사이 새로 요청된 activity 참조가 사라집니다. [추정]

### 지도 홈 (MapHome)

- `TaptionPlan/UI/MapHomeScreenRecording.swift:69-88` `stop()`이 실패하면 `isRecording`을 먼저 false로 바꾸고 nil을 반환합니다. OS 쪽 녹화가 남아 있어도 다음 `start()`가 "이미 녹화 중"으로 막히고, 정지 재시도 경로가 없습니다.
- `TaptionPlan/UI/MapHomeView.swift:14187-14197`, `:14350-14354` `isGrowthCalloutVisible`은 false로만 초기화되고, true로 바꾸는 `toggleGrowthCallout()`은 호출되지 않아 집 성장 콜아웃이 항상 숨겨져 있고 터치가 막혀 있습니다 (grep 확인).
- `TaptionPlan/UI/MapHomeView.swift:9990-9994` `refreshRouteProjection()`이 호출될 때마다 `invalidateRouteData()`가 그라데이션·서브웨이·경계 캐시를 모두 비웁니다. 재생 중 0.25초 간격과 실시간 센서 갱신마다 캐시가 무력화됩니다.
- `TaptionPlan/UI/MapHomeView.swift:5997-6004`, `:9305-9322` [추정] 과거 날짜 재생이 끝나면 `selectedTimelineMinute`가 1440으로 고정되는데, `timelineDate(forMinute:)`가 이를 다음 날 0시로 해석해 메모·스티커가 다른 날짜로 저장될 수 있습니다.
- `TaptionPlan/UI/MapHomeView.swift:1699-1713`, `:5178-5216` [추정] 성장 기록 Codable에 비옵셔널 필드가 추가된 뒤 예전 JSON을 읽으면 디코드가 실패하고, `refreshHomeGrowth`가 초기값을 다시 저장해 기존 기록을 덮어쓸 수 있습니다.
- `TaptionPlan/UI/MapHomeView.swift:17536-17545`, `:3658-3666` [추정] Apple 지도 안개 입력이 재생 위치를 포함해 틱마다 바뀌고, 매번 기존 오버레이를 제거한 뒤 다시 넣어 재생 중 MapKit 오버레이가 프레임마다 교체됩니다.
- `TaptionPlan/UI/MapHomeLocationPresentation.swift:301-372` [추정] 행동 판정 캐시 키가 초 미만까지 포함한 Date와 입력 배열 해시라서, 재생 중 거의 항상 빗나갑니다. 128개를 넘으면 캐시 전체를 지우고, 매 호출마다 O(n) 해시를 합니다.
- `TaptionPlan/UI/MapHomeView.swift:8209-8218`, `:8331-8345` [추정] `lastKnownCoordinate`가 `currentDayReadings.last(where:)`를 body마다 평가하는데, 이 함수는 하루치 기록을 병합·정렬하므로 비용이 큽니다.
- `TaptionPlan/UI/MapHomeView.swift:2994-3009` 센서 입력이 바뀔 때마다 예상 경로 재계산을 예약해, GPS 주기마다 하루 전체 요청 목록을 다시 만듭니다. [추정]
- `TaptionPlan/UI/MapHomeView.swift:17347-17349`, `:17762-17778` `didAdd`마다 `normalizeAnnotationLayerOrder`가 `mapView.annotations` 전체를 순회해 발자국이 많을 때 O(N²)이 됩니다. [추정]
- `TaptionPlan/UI/MapHomeView.swift:14715-14731` `layoutSubviews`마다 MKMapView를 못 찾으면 창 전체 뷰 트리를 순회합니다. [추정]
- `TaptionPlan/UI/MapHomeView.swift:956-966`, `:3021-3025` `cachedWeatherContexts`가 날씨 갱신마다 병합만 되고 상한이 없습니다. [추정: coalesce 정리 여부]
- `TaptionPlan/UI/MapHomeView.swift:5812-5818` `photoClusters`가 카메라 거리에 따라 매 프레임 다시 계산되고 묶기가 O(N·K)입니다. [추정]
- `TaptionPlan/UI/MapHomeView.swift:10372-10387` `setMapPosition`이 호출마다 진단 로그를 남기고, 재생 중 8ms 게이트로 초당 최대 약 120회 불립니다. 로그가 많습니다. [추정]
- `TaptionPlan/UI/MapHomeView.swift:8069` 환승 후보 캐시 키의 설정 해시를 `hashValue` XOR로 만들어 서로 다른 설정이 같은 키가 될 수 있습니다. [추정]
- `TaptionPlan/UI/MapHomeView.swift:16861-16866` UIColor 성분을 `UInt32(red * 255)`로 바로 변환해, 성분이 0~1 밖이면 트랩하고 인접 색끼리 캐시 키가 충돌합니다. [추정]
- `TaptionPlan/UI/MapHomeView.swift:17560-17561`, `TaptionPlan/UI/MapHomeVectorMap.swift:1178-1185` `Dictionary(uniqueKeysWithValues:)`에 중복 id가 들어오면 트랩합니다. [추정: 현재 id 규칙상 드묾]
- `TaptionPlan/UI/MapHomeTimeSidebar.swift:1557-1570` `onDisappear`가 `handleTouchStartUptime`(1132)을 초기화하지 않아, 취소된 드래그의 시작 시각이 다음 제스처의 더블탭 판정에 남을 수 있습니다.
- `TaptionPlan/UI/MapHomeTimeSidebar.swift:2887-2908` `maximumSelectableMinute`은 다른 날짜에 1439, `defaultTimelineMinute`은 1440을 반환하고 `.current` 캘린더를 써서 시간 상한 계산이 일관되지 않습니다.
- `TaptionPlan/UI/MapHomeTimeSidebar.swift:2284-2290`, `:2333` [추정] 날씨 레일 `Entry.id`가 `context.id`라서, 같은 날씨 컨텍스트가 두 구간에 걸치면 `ForEach` id가 중복됩니다.
- `TaptionPlan/UI/MapHomePhotoLayer.swift:105-134` PhotoKit 요청이 Task 취소와 연결되지 않아, 앨범을 빨리 넘기면 iCloud 다운로드가 끝까지 진행됩니다. `resumed` 플래그를 콜백 사이에서 공유합니다. [추정]
- `TaptionPlan/UI/MapHomePhotoLayer.swift:156-158` `.task(id:)`로 identifier가 바뀔 때 이전 이미지를 지우지 않아, 새 사진이 로드되기 전까지 다른 사진이 잠깐 보입니다.
- `TaptionPlan/UI/MapHomeCalendarSheet.swift:243-250` 달이 바뀔 때 `.task` 본문에서 `logStatuses`(MapHomeView.swift 2734-2741)를 메인 액터에서 동기 호출합니다. [추정]
- `TaptionPlan/UI/MapHomeScreenRecording.swift:7-30` `MapHomeRecordingLayers` 합성 Codable은 저장 JSON에 키가 없으면 decode가 실패하고, `init(rawValue:)`가 모든 레이어 설정을 기본값으로 되돌립니다. [추정: 나중에 추가된 키 기준]
- `TaptionPlan/UI/MapHomeView.swift:3392-3394` `usesVectorRoadMap`이 항상 false라서 10638·10810·10874의 분기가 죽은 코드입니다. 값이 바뀌면 숨은 버그가 됩니다.
- `TaptionPlan/UI/MapHomeVectorMap.swift:1256` `activeCasingLayer`는 선언만 있고 쓰이지 않습니다 (죽은 코드).

### 기타 메모리·캐시

- `TaptionPlan/Core/AppleIntegrations.swift:4039-4250` `AppleTransportContextService.cache`가 약 111m 격자 키로 쌓이기만 하고 상한·제거가 없습니다. (같은 파일 4433행의 512 상한과 대비)
- `TaptionPlan/Core/AppleIntegrations.swift:1567-1577` 날씨 재조회 실패 시 이전 관측을 재사용하면서 `observedAt`을 현재 시각으로 덮어써, 오래된 날씨가 현재값처럼 보입니다.
- `TaptionPlan/Core/AppleIntegrations.swift:4691-4699` 알림 트리거 날짜 구성요소에 timeZone이 없어, 시간대가 바뀌면 절대 시각이 아니라 기기 벽시계 시각에 울립니다. [추정: 의도일 수 있음]
- `TaptionPlan/Core/HealthKitImportCoordinator.swift:710-727` 운동 경로 좌표를 상한 없이 모아 base64로 레코드 본문에 넣습니다. 장시간 운동이면 수 MB 행이 생기고 LZFSE·체크섬 규칙을 따르지 않습니다. (AppleIntegrations는 20,000 상한이 있음)
- `TaptionPlan/Core/HealthKitImportCoordinator.swift:1308-1320` 저장된 앵커나 커서 디코딩이 실패하면 해당 종류가 매 동기화마다 실패하고 재설정 경로가 없습니다. [추정: 발생 빈도]
- `TaptionPlan/Core/HealthKitImportCoordinator.swift:363-366` `includeAncillary` 인자가 본문에서 쓰이지 않고, 활동 요약·문서·복약 경로가 호출되지 않아 해당 자동 기록이 저장되지 않습니다. 의도된 보류인지 확인이 필요합니다.
- `TaptionPlan/Core/HealthKitImportCoordinator.swift:52-57` `countsExistingAsUpdated: true`에 전체 기존 ID를 넘겨 변경 없는 항목이 매번 updatedCount에 포함됩니다. (현재 호출 경로 없음)
- `TaptionPlan/Core/WidgetPayloadFactory.swift:58-73` [추정] 비UUID 캘린더 이벤트 id에 빌드마다 `UUID()`를 새로 만들어 지문이 매번 바뀌고, 동기화 상태가 계속 대기로 남습니다.
- `TaptionPlan/Core/RecordSummaryEngine.swift:1210-1229` 조각마다 `UUID()`를 새로 만들어 같은 편집을 다시 해도 식별자가 달라져 선택·병합 기준이 흔들립니다.
- `TaptionPlan/Core/RecordSummaryEngine.swift:77-130` `categoryCache`가 제거 경로 없이 기록 종류·근거 조합마다 늘어납니다.
- `TaptionPlan/Core/RecordSummaryEngine.swift:582-587` `Dictionary(uniqueKeysWithValues:)`가 `yearlyReports`의 시작 날짜 중복에서 트랩합니다. [추정]
- `TaptionPlan/Core/FeatureModels.swift:449-466` `MovementPresentation.modeCache`가 상한 없이 키를 쌓아 메모리가 단조 증가합니다.
- `TaptionPlan/Core/FeatureModels.swift:61-107`, `:492-505` 부분 문자열 분류로 "remember"의 `rem`이 수면으로, "business"의 `bus`가 이동으로 오분류됩니다.
- `TaptionPlan/Core/SubwayCatalog.swift:953-965` [추정] `shortestPath`가 nil인 구간을 `continue`로 건너뛰어, 연결되지 않은 두 역이 인접 노선으로 저장됩니다.
- `TaptionPlan/Core/StationaryContextClassifier.swift:493-494` 겹치는 원시 가속도 표본이 3개 미만이면 Watch 행동 근거 검사 전에 반환해, 집·회사 정지 문맥 근거에서 빠집니다.
- `TaptionPlan/Core/RouteTimelineData.swift:948-953` `Dictionary(uniqueKeysWithValues:)`에 같은 `place.id`의 `PlaceStay`가 두 개 들어오면 트랩합니다. [추정]
- `TaptionPlan/Core/RouteTimelineData.swift:1523-1532` 비throw 오버로드가 `try?`로 `CancellationError`를 삼켜 빈 결과를 반환하고, `MapHomeWBSPlaybackProjection.make`가 이를 확인 없이 씁니다.
- `TaptionPlan/Core/TemplatesAndSettings.swift:56-64` `makeCustom`이 `darkHex`·`actualHex`를 검증하지 않고 저장합니다. [추정]
- `TaptionPlan/Core/TemplatesAndSettings.swift:92-98` `reordered`의 `Dictionary(uniqueKeysWithValues:)`가 중복 ID 입력에서 트랩합니다. [추정: 외부 호출 경로]
- `TaptionPlan/Core/DiagnosticsLogSupport.swift:136-146` 건강 필터가 `fields`만 가리고 `metrics`는 통과시켜, 건강 수치가 metrics로 기록되면 내보내기 로그에 원본이 남습니다. [추정: 호출부]
- `TaptionPlan/Core/DiagnosticsLogSupport.swift:826-835` staging 디렉터리를 만든 뒤 `copyItem`이 실패하면 그 디렉터리를 지우지 않아 임시 파일이 쌓입니다.
- `TaptionPlan/Core/BiometricDataProtection.swift:112-114` 아카이브의 `compressedByteCount`·`jsonByteCount`를 검증하지 않고, 비throw 해제 함수가 실패 시 압축 원본을 그대로 돌려줘 원인을 가립니다.
- `TaptionPlan/Core/TaptionBackupEngine.swift:243-270` 월별 백업 루프가 취소를 확인하지 않고 모든 오류(취소 포함)를 파일별 `.failed`로 바꿔, UI 취소가 백업을 멈추지 못합니다.
- `TaptionPlan/Core/TaptionBackupEngine.swift` ↔ `TaptionPlan/Core/TaptionStoreV2.swift:952-977` 범위 지문이 `COUNT(*)`와 `MAX(rowid)`만 봐서, await 사이 최신 행이 교체되면 지문이 같아 편집본이 지워질 수 있습니다. (조건이 좁음)

### UI·UX 기타

- `TaptionPlan/UX/NavigationModels.swift:650-656` `format`마다 `DateFormatter`를 새로 만듭니다. 목록 행이나 뷰 갱신에서 반복 호출되면 비용이 커집니다. [추정: 호출 빈도]
- `TaptionPlan/UI/DetailViews.swift:2930-2938` `ApplicationTokenCache`가 상한 없는 static 딕셔너리라 토큰이 쌓일수록 메모리가 늘어납니다. [추정]
- `TaptionPlan/UI/ScheduleView.swift:83`, `:2816`, `:10196-10270` 배열 인덱스는 빈 배열을 가드하고 있어 문제로 기록하지 않았습니다. (직접 읽어 확인)

## 범위 밖·미확인 (다음 리뷰 대상)

- `TaptionPlan/UI/ScheduleView.swift`(약 1.2만 줄), `TaptionPlan/UI/ReviewView.swift`, `TaptionPlan/UI/SettingsView.swift`, `TaptionPlan/UI/GoalsView.swift`: 거의 읽지 않았습니다.
- `TaptionPlan/UX/AppModel.swift`(약 1.4만 줄): 4700~4720, 2780, 4440, 10050 근처만 확인했습니다.
- `TaptionPlanWatch/WatchWorkoutManager.swift`, `TaptionPlanWatch/WatchConnectivityController.swift`, `TaptionPlanWatch/ContentView.swift`, `TaptionPlanWatch/WatchLaunchDiagnostics.swift`: 구간별로만 봤습니다.
- `TaptionPlan/Core/LiveActivitySupport.swift`: 도구 호출 8회로 전체 정독이 아닐 수 있습니다.
- 테스트(`TaptionPlanTests/`, `Packages/.../Tests/`): 단언을 훑었을 뿐 검토하지 않았습니다.

## 다음 단계 제안

1. 위 "우선 확인" 섹션에서 **[확인]** 항목과 데이터 유실 항목부터 줄 단위로 다시 읽어 재현 조건을 확정합니다.
2. 범위 밖 파일을 2,000줄 단위로 나눠 다시 리뷰합니다. 특히 `ScheduleView.swift`, `AppModel.swift`, `WatchWorkoutManager.swift`입니다.
3. 수정은 항목별로 `temp.md`에 요청 ID를 만든 뒤 진행합니다 (AGENTS.md 규칙).
