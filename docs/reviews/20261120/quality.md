# taption-plan 테스트 공백·코드 품질 검토

- 날짜: 2026-11-20
- 기준 커밋: `e6a4445` (main, HSW1120A01)
- 범위: `TaptionPlan/`, `Packages/*/Sources`, `TaptionPlanTests/`, 각 패키지 `Tests/` (server/trip-relay는 참고만, 실기기 UI 시험은 대표 결정으로 제외)
- 방법: 패키지별 Sources 공개 타입 ↔ Tests 대조(스크립트), 앱 타깃 Core/UX 타입 ↔ TaptionPlanTests 대조, `rg` 패턴 검색 후 실제 코드 확인. "테스트 없음"은 타입·함수 이름이 전체 테스트에 한 번도 안 나오는 것으로 확인한 것만 적었다. 죽은 코드는 저장소 전체 Swift에서 정의 1회만 나오는 것으로 확인한 것만 적었다.
- 배포 타깃: iOS 18.0 (`IPHONEOS_DEPLOYMENT_TARGET = 18.0`)
- 이 문서는 검토만 한다. 코드를 고치지 않았다.

## 0. 이미 알려진 항목 — 확인됨 (다시 제안하지 않음)

- `docs/REFACTOR_TOP20.md` 상위 20개: 13개 완료 + RFT1116A02 4개 완료. 남은 것은 `TaptionPlan/UI/MapHomeTimeSidebar.swift`, `TaptionPlan/UI/AppShellView.swift` 2개뿐이고 둘 다 "성능 작업 뒤"로 문서에 적혀 있다. 확인됨.
- `docs/PROPOSALS.md` 9절: 9-1 DateFormatter 중복은 2단계에서 일부 완료(`AssistantActivityBuilder.Stamp.instantParser`로 통합, 두 곳 사본 제거). 9-2 UserDefaults 키는 `playbackVideoMusic` 4곳 상수화 완료. 9-5 긴 함수는 `performSensorTimelineRefresh`(534줄)가 RFT1116A03으로 나뉘었고, `TravelModeClassifier.classify`(839줄)·`receiveEnvelope`(254줄)는 시험을 먼저 늘린 뒤로 문서에 남아 있다. 9-6 번호 붙은 확장 파일(`MapHomeView+Support2.swift` 등)은 여전히 존재한다. 확인됨.
- 실기기 UI 시험 시간 초과로 건너뜀: `AGENTS.md` 4절 대표 결정(2026-11-18) "「Timed out while enabling automation mode」로 막혀 건너뛰고 시뮬레이터 결과로 남김". 확인됨.
- 9-4 거리 함수 사본, 9-8 통과만 하는 함수(`distanceMeters` 삭제 완료)는 이번 검토에서 제외했다.

---

## 1. 테스트 공백 — P0 (돈·백업·분류·보안 핵심)

### T-01. 이동 수단 점수 로직 전체 미테스트
- `Packages/TaptionClassifierEngine/Sources/TaptionClassifierEngine/ModeScorer.swift:26` — 문제: `ModeScorer.score(_:)`와 `WindowScore.best()`가 테스트에 한 번도 안 나온다. 속도 프로파일·Core Motion 가중치·비행기 최소속도(`airplaneMinimumSpeed = 55.0`)·배 속도 범위(`shipSpeedRange = 4.0...17.0`)가 분류 결과를 직접 정하는데 고정된 테스트가 없다. — 고치는 방법: `TaptionClassifierEngineTests`에 속도별 `best()` 단언(걷기 1.3m/s·자동차 12m/s·비행기 200m/s 부근), 55m/s 경계, 배 범위 경계(4·17), `bestSpeed == nil` + `isIdle` 분기, Core Motion 분기별 점수 테스트 추가.

### T-02. 분류 파이프라인 구간·지점 연산 미테스트
- `Packages/TaptionClassifierEngine/Sources/TaptionClassifierEngine/ClassifierModels.swift:4,50,59,68,156,160,166,179` — 문제: `ClassifierPipeline.modelVersion(_:)`·`isIdle(accelerationStandardDeviationG:rotationRate:)`, `ClassifierPoint.bearing(to:)`·`centroid(_:)`, `ClassifierInterval.overlap(with:)`·`intersection(with:)`·`union(_:gap:)`·`subtracting(_:from:)`가 테스트에 안 나온다. `distance(to:)`만 `ClassifierEngineTests.swift:178`에서 1회 간접 사용. — 고치는 방법: 겹침 없음/부분 겹침/포함, `union` 빈틈(gap) 경계, `subtracting` 자르기, `bearing` 0/360 경계, `centroid` 빈 배열(nil), `isIdle` 임계값 테스트 추가.

### T-03. 시즌 팩 날짜 파싱 미테스트 + 월/일 범위 검증 없음
- `Packages/SeasonPackKit/Sources/SeasonPackKit/Scheduler/SeasonPackWindows.swift:11-30` — 문제: `SeasonPackDateParsing.localDateTime(_:calendar:)`·`hourMinute(_:)` 테스트 0건. 더구나 월·일 범위 검사가 없어 `calendar.date(from:)`이 "2026-13-40" 같은 값을 굴려서 다음 해 날짜로 만들어 버린다(시각만 0...23·0...59 검사). 매니페스트 오타가 조용히 잘못된 기간이 된다. — 고치는 방법: 월 1...12·일 1...31(해당 월 일수) 검증 추가 후, 정상/날짜만/시각 포함/무효 월·일·시각 테스트 추가.

### T-04. 백업 경로 대체 엔진 전체 미테스트
- `TaptionPlan/Core/PlanBackupRouteFallbackEngine.swift:11` — 문제: `PlanBackupRouteFallbackEngine` 전체가 테스트에 안 나온다. 백업 경로가 막혔을 때 대체 경로를 고르는 엔진인데, 간격 상한(`maximumRouteGap = 15 * 60`, :13) 경계 동작이 고정돼 있지 않다. — 고치는 방법: 간격 15분 경계(바로 아래/위), 대체 경로 선택·포기 케이스 테스트 추가.

### T-05. 되돌리기 기록 타입 미테스트
- `TaptionPlan/UX/AppModel+EditHistory.swift` — 문제: `AppModelHistoryChange`·`AppModelHistoryEntry`·`AppModelHistoryItem`이 테스트에 안 나온다. 사용자 편집 되돌리기의 기록 형식이라, 형식이 깨지면 되돌리기가 조용히 안 된다. — 고치는 방법: 기록 생성→직렬화→복원 왕복, 되돌리기 적용·무시 케이스 테스트 추가.

### T-06. Watch 하루 저장소 미테스트 (Watch 테스트 타깃 자체가 없음)
- `TaptionPlan/Core/WatchDayDatabase.swift:6` — 문제: `actor WatchDayDatabase`가 테스트에 안 나온다. `TaptionPlanWatch/`에는 테스트 타깃이 아예 없고, 앱 테스트의 Watch 관련 파일(`FeatureEngineTests+Watch.swift` 등)은 이 actor를 안 건드린다. — 고치는 방법: 앱 테스트 타깃에서 `WatchDayDatabase`를 직접 두는 단위 테스트를 넣거나, Watch 테스트 타깃 신설 여부를 대표에게 묻는다.

### T-07. Watch 행동 CoreML 브리지 미테스트
- `Packages/TaptionWatchSync/Sources/TaptionWatchBehaviorML/WatchBehaviorModel.swift:9` — 문제: `WatchBehaviorModel.load(bundle:resource:)`·`predict(features:)`가 테스트에 안 나온다. `WatchWorkoutManager.swift:104`에서 `load()` 결과를 쓰는데, 모델이 없을 때 nil 경로조차 고정돼 있지 않다. — 고치는 방법: 모델 없는 번들에서 `load()`가 nil을 돌려주는 테스트부터 추가. `predict`는 작은 테스트용 `.mlmodelc` 픽스처가 필요하면 별도 작업으로 나눈다.

### T-08. 생체 보호 백업 검증 진입점이 호출처 없음 (죽은 코드 + 보안 기능 미연결)
- `TaptionPlan/UX/AppModel+Backup.swift:243` — 문제: `validateBiometricProtectedData()`가 저장소 전체에서 정의 1회만 나온다. 생체 보호 스냅샷의 `validate()`를 부르는 유일한 진입점인데 아무 데서도 안 불러서, 보호된 백업이 깨졌는지 확인하는 길이 없다. — 고치는 방법: 백업 목록·복원 전 검증 흐름에 연결하거나, 의도적으로 안 쓰는 거면 함수와 `BiometricDataProtectionStatus` 표시를 함께 삭제. (죽은 코드 9절에도 있음)

### T-09. StoreKit 순수 로직 미테스트 (테스트 인프라 import만 있음)
- `TaptionPlan/Core/StoreKitSupport.swift:6,34,51` — 문제: `TaptionCommercePolicy.isSupportedProProductType(_:)`·`grantsProAccess(_:)`, `TaptionProAccessState`, `TaptionProTrialPolicy.merged(_:)`·`state(_:)`가 테스트에 안 나온다. `TaptionPlanTests/FeatureEngineTests+Planning.swift:4-5`는 `StoreKit`·`StoreKitTest`를 import만 하고 쓰지 않는다. IAP 판매는 보류 중(`AGENTS.md` 4절)이지만 체험·접근 판정은 순수 로직이라 지금 테스트할 수 있다. — 고치는 방법: 체험 합치기(중복·만료), 접근 상태 판정, Pro 제품 타입 판정 테스트 추가. 미사용 import는 정리.

### T-10. 정산 원 단위 변환 경계 미테스트
- `Packages/TaptionLedgerCore/Sources/TaptionLedgerCore/LedgerTrips.swift:192` — 문제: `LedgerSplit.won(_:)`의 경계 분기(비유한→0, |금액| ≥ 1e15→0)가 테스트에 안 나온다. `even`·`transfers`·`greedy`·`zeroSumGroups`는 `LedgerTests.swift:1578` `LedgerSplitTests`에서 충분히 테스트됨. — 고치는 방법: `won(.nan)`·`won(.infinity)`·`won(1e15)`·`won(-1e15)` 단언 추가.

### T-11. 환율 파싱·집계 경계 미테스트
- `Packages/TaptionLedgerCore/Sources/TaptionLedgerCore/LedgerCore.swift:92,163` — 문제: `LedgerFX.parse(_:)`와 `LedgerEntry.countedKRW`가 테스트에 직접 안 나온다. `krwPerUnit`·`signedKRW`(취소 건 0, `LedgerReviewTests.swift:50`)는 테스트됨. — 고치는 방법: `parse`에 잘못된 JSON·빈 데이터·통화 빠짐 케이스, `countedKRW`에 취소/미취소·`amountKRW == nil` 케이스 추가.

### T-12. 센서 하루 파생 타입 미테스트 (리팩토링으로 새로 만든 타입)
- `TaptionPlan/UX/SensorTimelineDerivation.swift`, `TaptionPlan/UX/AppModel+SensorRefreshEvidence.swift`, `TaptionPlan/UX/AppModel+SensorRefreshRebuild.swift` — 문제: `SensorStayDerivation`·`SensorTravelDerivation`·`SensorRefreshEvidence`·`SensorRouteEvidence`·`SensorDayDerivation`이 테스트에 안 나온다. RFT1116A03에서 `performSensorTimelineRefresh`를 나누며 만든 타입들인데, `SensorTimelineRefreshTests`는 결과·되돌리기·취소만 고정하고 이 파생 타입들을 직접 안 건드린다. — 고치는 방법: 체류·이동 파생(경계 시각·빈 구간), 근거 읽기(지문 같은 날·다시 만드는 날) 테스트 추가.

### T-13. 휴식 쪼개기 미테스트 + 제목 하드코딩
- `TaptionPlan/Core/WorkBreakPattern.swift:5,81` — 문제: `WorkBreakPattern.splitting(records:readings:asOf:)`가 테스트에 안 나온다. 회사 체류 중 휴식을 가르는 분류 로직인데, 갈라진 조각 제목이 `value.title = "휴식"`으로 하드코딩돼 있다. — 고치는 방법: 휴식 구간 분리·최소 길이·경계 테스트 추가. 제목은 분류 카탈로그의 "휴식" 상수를 쓰거나 번역 경로로 옮긴다(6절 L-04와 함께).

### T-14. 통행료·대중교통 요금 러너 미테스트
- `TaptionPlan/Core/LedgerTollGate.swift`, `TaptionPlan/Core/LedgerTransitFare.swift` — 문제: `LedgerTollFareStore`·`LedgerTollGateRunner`·`LedgerTollKakaoRunner`·`LedgerTransitFareRunner`가 테스트에 안 나온다. `LedgerTollGateTests.swift`는 게이트 정책만 테스트하고 실제 요금 조회 러너는 안 건드린다. 돈이 걸린 외부 조회라 실패·재시도 경로가 고정돼 있지 않다. — 고치는 방법: 가짜 요금표·가짜 응답으로 성공·빈 결과·오류·재시도 테스트 추가.

### T-15. 단축어 진입점 미테스트
- `TaptionPlan/Core/FlightIntents.swift:22,56` — 문제: `FlightIntentRunner.run(_:now:)`·`SharedTextIntentRunner.run(_:now:container:)`이 테스트에 안 나온다. 단축어 자동화가 부르는 진입점인데, 앱 미준비 시 보관함(`FlightInbox.stash`·`FlightShareStore.enqueue`) 분기가 고정돼 있지 않다. (Intent 타입 자체는 시스템이 발견하므로 살아 있다 — 9절 제외 목록 참고) — 고치는 방법: 준비됨/미준비·항공 알림/일반 글·읽기 실패 케이스 테스트 추가.

---

## 2. 테스트 공백 — P1 (그 외)

### T-16. AI 연결 DI 구조체·결과 타입 미테스트
- `Packages/TaptionAssistant/Sources/TaptionAssistantKit/AssistantEnvironment.swift:6`, `AssistantCommandTransport.swift` — 문제: `AssistantEnvironment`(생성 지점은 `TaptionPlan/UI/AssistantRegistration.swift:7` 한 곳)와 `AssistantCommandResult`·`AssistantCommandPolling`이 테스트에 안 나온다. `moveRules` 기본값(`{ _, _, _ in true }`)·`saveConnection` 기본값이 고정돼 있지 않다. — 고치는 방법: 기본 클로저 동작, 키 교체 시 규칙 이동 성공·실패 테스트 추가.

### T-17. 시즌 팩 백그라운드 다운로드 완료 콜백 미테스트
- `Packages/SeasonPackKit/Sources/SeasonPackKit/Store/SeasonPackBackgroundEngine.swift:30,114` — 문제: `SeasonPackBackgroundEngine.handleEvents(forBackgroundURLSession:)`·`urlSessionDidFinishEvents(forBackgroundURLSession:)`가 테스트에 안 나온다. 백그라운드 세션 완료 후 시스템 완료 콜백을 부르는 경로라, 안 불리면 iOS가 앱을 깨운 채로 둔다. — 고치는 방법: 가짜 `URLSession`·완료 핸들러로 호출·미호출·두 번 호출 테스트 추가.

### T-18. 클라우드 복구 정책 미테스트
- `TaptionPlan/Core/PlanRepository.swift` — 문제: `PlanCloudSnapshotRecoveryPolicy`·`CloudSyncDecision`·`TaptionRepositoryBackgroundExecution`·`PlanRepositorySelection`·`BackgroundTaskAssertion`이 테스트에 안 나온다. — 고치는 방법: 복구 정책별(덮기·합치기·버리기) 결정 테스트 추가.

### T-19. Core Motion 히스토리 서비스 미테스트
- `TaptionPlan/Core/AppleMotionHistoryService.swift:7` — 문제: `AppleMotionHistoryService`가 테스트에 안 나온다. `SensorDataServices.swift:507`에서 주입받는데, 히스토리 조회 실패·빈 결과 분기가 고정돼 있지 않다. — 고치는 방법: `CMMotionActivityManager`를 감싼 프로토콜로 갈아 끼우거나, 조회 결과 매핑만 분리해 테스트한다.

### T-20. 시즌 팩 어댑터·편집 스테이징 미테스트
- `TaptionPlan/Core/SeasonPackAdapter.swift`, `TaptionPlan/UX/ActivitySectionEditStaging.swift`, `TaptionPlan/UX/AppModel+FrequentPlaces.swift`(`FrequentPlaceKindChange`) — 문제: `SeasonPackAdapter`·`SeasonCardArt`·`ActivitySectionEditStaging`·`FrequentPlaceKindChange`가 테스트에 안 나온다. — 고치는 방법: 어댑터의 마운트·삭제·언어 전달, 편집 스테이징의 저장·버리기, 장소 종류 변경 테스트 추가.

### T-21. Watch 동기화 저장소 읽기·지우기 미테스트
- `Packages/TaptionWatchSync/Sources/TaptionWatchSync/WatchSyncStores.swift` — 문제: `WatchActivityConfirmationStore`·`WatchActivityLearningStore`·`WatchLaunchReportStore`의 `read`·`clear`가 테스트에 안 나온다. (`TaptionWatchCommandCapabilityStore`는 `WatchSensorQueryPlanTests.swift:1874`에서 reconcile/consume/clear 테스트됨) — 고치는 방법: 저장→읽기→지우기 왕복 테스트 추가.

### T-22. 하드웨어 의존 서비스 미테스트 (낮음 — 분리 후 테스트)
- `TaptionPlan/Core/ApplePhotoLibraryService.swift`(`PhotoServiceError`·`ApplePhotoLibraryService`), `TaptionPlan/Core/CurrentConnectedWiFiService.swift`, `TaptionPlan/Core/WidgetCommandStore.swift`(`TaptionWidgetCommandReceipts`) — 문제: 테스트에 안 나온다. 사진·Wi-Fi는 기기 권한이 필요해 시뮬레이터 테스트가 제한된다. — 고치는 방법: 권한·조회 부분을 프로토콜 뒤로 분리하고, 순수 매핑(오류 변환·수신 확인)만 테스트한다.

### T-23. 에러 타입·작은 값 타입 미테스트 (낮음)
- `TaptionPlan/Core/BackupPasswordVault.swift`(`BackupPasswordStoreError`), `TaptionPlan/Core/GoogleCalendarAccount.swift`(`GoogleCalendarConfig`·`GoogleCalendarError`), `TaptionPlan/Core/HealthKitImportStore.swift`(`HealthKitImportStoreError`), `TaptionPlan/Core/TemplatesAndSettings.swift`(`CategoryError`·`CategoryDeletionResult`), `TaptionPlan/Core/FlightLookup.swift`(`FlightListResult`), `TaptionPlan/Core/FlightBriefing.swift`(`FlightBriefingScheduler`), `TaptionPlan/Core/PlanGoalEngines.swift`(`GoalActualMatchKind`·`GoalActualMatch`) — 문제: 타입만 테스트에 안 나온다. — 고치는 방법: 오류를 일으키는 경로 테스트를 넣을 때 함께 단언한다. 단독 테스트는 우선순위 낮음.

### T-24. 패키지 공개 값 타입·정책 미테스트 (낮음 — 묶음)
- 문제: 다음 공개 타입이 테스트에 안 나온다. 대부분 값 타입이라 단독 테스트보다 사용하는 쪽 테스트에 단언을 넣는 게 낫다.
  - `TaptionAssistant`: `AppleCloudQuota`·`AppleCloudFailure`·`AppleModelNotice`(`AppleModelRouter.swift`), `AssistantKeyScope`·`AssistantKeyPeriod`(`AssistantKeys.swift`), `AssistantLooseValue`(`AssistantJSON.swift`), `AssistantOperationReading`·`AssistantParsedOperation`(`AssistantOperationReading.swift`), `AssistantCatalogLimits`(`AssistantOperations+Catalog.swift`), `AssistantApproval`(`AssistantQuestion.swift`), `AssistantCoordinate`·`AssistantPlanTarget`·`AssistantSchedulePlace`·`AssistantScheduleExtras`·`AssistantScheduleTime`·`AssistantWhenChange`(`AssistantCommandValues.swift`)
  - `TaptionActivityEngine`: `ActivityEngineConfiguration`(`ActivityClassifier.swift`), `ActivityGapInferenceInput`·`ActivityGapInferenceSegment`·`ActivityGapInferenceConfiguration`(`ActivityGapInference.swift`), `ActivitySensorSource`(`ActivityModels.swift`), `ActivityDetailDefinition`·`ActivityMajorDefinition`(`ActivityTaxonomy.swift`), `ActivityDataTier`·`ActivityInferenceStatus`·`ActivityDataProvenance`·`ActivityAutomaticConfirmation`(`DataTrustModels.swift`), `ActivityPlaceKind`·`ActivityPlaceEvidence`(`PlaceActivityInference.swift`), `SleepInferenceState`·`SleepInferenceResult`(`SleepInference.swift`)
  - `TaptionClassifierEngine`: `ClassifierPipeline`·`IdleThresholds`(`ClassifierModels.swift` — T-02와 함께), `StayContextResult`·`RegisteredPlaceKind`(`StayContext.swift`), `ClassifiedStay`·`ClassifierRecord`·`ClassifierDayOutput`(`TaptionClassifier.swift`), `ClassifierConfidence`(`TravelSegmenter.swift`), `WindowFeatures`(`WindowFeatures.swift`)
  - `TaptionPlanCore`: `TaptionPlanNLEInputDecision`(`CoreEngineContracts.swift`), `TaptionPlanRawEventIdentifier`·`TaptionPlanRawEventPage`(`DayStoreV3Models.swift`), `TaptionInputFrameGate`·`TaptionTrailingInputScheduler`(`RuntimeEfficiency.swift`), `WatchHealthSnapshotRetryPolicy`(`WatchHealthSnapshotRetryPolicy.swift`), `TaptionPlanExternalCalendarProvider`·`TaptionPlanExternalCalendarPreferences`·`TaptionPlanMediaReferenceSource`·`TaptionPlanContentNode`·`TaptionPlanContentLink`·`TaptionPlanUserContent`(`StorageContracts.swift`)
  - `TaptionPlanStore`: `TaptionRawEvent`(`TaptionRawEvent.swift`), `TaptionStoreV2Error`는 5개 테스트 파일에서 언급됨(제외). `ActivityCorrectionOption`·`ActivityCorrectionEngine`은 2개 파일에서 언급됨(제외). `PlanActualEdit`·`PlanActualStorage`(`PlanActualStorage.swift`), `PlanDataRepository`(`PlanDataRepository.swift` — SQLite 구현은 `SQLitePlanRepositoryTests`에서 테스트됨), `RecordAnalysisScope`·`RecordAnalysisCategoryNormalizer` 등은 5개 파일에서 언급됨(제외)
  - `TaptionRouteEngine`: `RouteGapInferenceInput`·`RouteGapInferenceDecision`·`RouteGapInferenceConfiguration`(`RouteGapInference.swift`), `RouteLoggerRouteFilterConfiguration`·`RouteSampleDecisionReason`·`RouteSampleDecision`(`RouteLoggerRouteFilter.swift`), `FareTrip`(`FareCalculator.swift`), `FareAgeBand`(`FareTable.swift`), `FlightLayover`(`FlightItinerary.swift`), `FlightArrival`(`FlightTimeMath.swift`), `MissingRouteEvidence`(`RouteEvidence.swift`), `TravelLossyMap`(`TravelBundledData.swift`)
  - `TaptionTripShare`: `ShareContentVersion`·`ShareOwnExpenseVisibility`(`ShareContent.swift`), `ShareReadOnlyReason`(`ShareError.swift`), `ShareReceivedLocation`(`ShareLocation.swift`), `ShareSessionStatus`·`ShareEndReason`·`ShareLocalItem`·`ShareLockState`·`ShareUnreadableItem`·`ShareEditOutcome`·`ShareEditConflict`·`ShareSnapshotStore`(`ShareSessionTypes.swift`), `ShareMemberEvent`·`ShareSocketResponse`·`ShareSocketEvent`(`ShareSocketMessages.swift`), `ShareHTTPRequest`·`ShareHTTPResponse`·`ShareSocketClosed`(`ShareTransport.swift`), `ShareWriteReceipt`·`ShareGroupChange`(`ShareWire.swift`)
  - `TaptionWatchSync`: `WatchAmbientChunkVerdict`(`WatchAmbientChunkInterpreter.swift`), `TaptionWatchActivityConfirmation`·`WatchActivityPattern`·`WatchActivityPatternSample`·`TaptionWatchActivitySuggestion`(`WatchBehaviorRules.swift`), `TaptionWatchMeasurementSource`·`TaptionWatchMeasurementSnapshot`·`TaptionWatchAlertKind`·`TaptionWatchAlert`·`TaptionWatchWidgetRefreshPolicy`·`TaptionWatchHealthSnapshot`·`TaptionWatchSleepSegment`·`TaptionWatchSleepDuration`·`TaptionWatchLocationPoint`(`WatchSyncMeasurements.swift` — `TaptionWatchAlertPolicy`는 `WatchMeasurementAlertTests`에서 테스트됨), `TaptionWatchWorkoutStartGate`·`TaptionWatchWorkoutFinishState`·`TaptionWatchWorkoutPurgeIntentStore`·`TaptionWatchWorkoutPurgeReconciliation`·`TaptionWatchPurgeSequence`·`TaptionWatchAmbientQueueAdoption`·`TaptionWatchAmbientOutboxFlushPolicy`·`TaptionWatchAmbientOutboxReadFailurePolicy`·`TaptionWatchAmbientSampleDeduplicationPolicy`·`TaptionWatchDurableSpoolPolicy`·`TaptionWatchDurableSpoolCodec`·`TaptionWatchWorkoutLifecycleBarrier`·`TaptionWatchAccelerationArchiveAppendIndex`·`TaptionWatchAmbientRevisionError`·`TaptionWatchPurgeGenerationPolicy`(`WatchSyncOutbox.swift` — `TaptionWatchAmbientRevisionPolicy`·`TaptionWatchAmbientOutboxRetryPolicy`는 테스트됨)
  - `SeasonPackKit`: `SeasonPackValidationResult`(`SeasonPackValidation.swift`), `SeasonPackAnchor`(`SeasonPackHost.swift`), `SeasonPackOverlay`(`SeasonPackOverlay.swift`), `SeasonPackDownloadResult`(`SeasonPackDownloader.swift`), `SeasonPackRefreshResult`(`SeasonPackFetcher.swift`), `SeasonPackLoader`·`SeasonPackInstallRecord`(`SeasonPackStore.swift`), `SeasonPackDefaultsClockStorage`(`SeasonPackClock.swift` — 시계 본체는 테스트됨)
- 고치는 방법: 각 타입을 쓰는 쪽의 기존 테스트에 단언을 추가한다. 뷰 타입(`SeasonPackMenuView`·`SeasonPackHouseView` 등)은 단위 테스트 대상이 아니므로 제외.

---

## 3. 중복 코드 (PROPOSALS 9절에 없는 것만)

### D-01. 금액 표기 로직 중복
- `TaptionPlan/UI/MapHomeCalendarPolicies.swift:438` — 문제: `moneyText(_:language:)`가 `NumberFormatter`(.decimal, 0자리)로 숫자를 만들고 `"\(number)원"`/`"₩\(number)"`로 붙이는데, `TaptionPlan/Core/LedgerCore.swift:275` `LedgerMoney.text(_:currency:language:)`의 KRW 분기와 완전히 같은 로직이다. — 고치는 방법: `moneyText`를 삭제하고 `LedgerMoney.text`를 부른다. (`moneyCellText`의 "1.2만"/"12k" 축약은 별개라 둔다.)

### D-02. 거리 표기 3구현
- `TaptionPlan/UI/TripLiveLocationBand.swift:212`, `TaptionPlan/UI/TripImportSheet.swift:813` — 문제: `AppRegion.distanceText(meters:compact:)`(`Packages/TaptionWatchSync/Sources/TaptionWatchSync/AppRegion.swift:63`, 마일 대응·테스트 있음)가 있는데도 두 곳이 각자 구현한다. `TripLiveLocationBand`는 `%.1fkm`/`Int m` 수동 포맷(마일 미대응), `TripImportSheet`는 `Measurement.formatted`로 km만 낸다. — 고치는 방법: 두 곳을 `AppRegion.current.distanceText(meters:)`로 바꾼다. (`MapHomeDayTravelSummary.distanceText`는 이미 위임이라 건드리지 않는다.)

### D-03. 시계 표기 `clock(minute:)` 동일 구현 2곳 + 유사 포맷 5곳
- `TaptionPlan/UI/TravelTodayCard.swift:261`, `TaptionPlan/UI/TravelPlanTable.swift:675` — 문제: `String(format: "%02d:%02d", minute / 60 % 24, minute % 60)`이 두 파일에 글자 그대로 같다. 비슷한 시계 포맷이 `TaptionPlan/UI/TravelQuickEntrySheet.swift:58`, `TaptionPlan/UX/DailyCardBubblePrompt.swift:51`, `TaptionPlan/UI/PlanRealityGap.swift:271`, `TaptionPlan/UI/AssistantDataActions.swift:676,803`에 더 있다(`%02d` 전체 93곳). — 고치는 방법: `ClockText.minute(_:)` 같은 공용 헬퍼 하나를 만들고 일곱 곳을 바꾼다.

### D-04. NumberFormatter를 호출마다 새로 만듦
- `TaptionPlan/UI/LedgerSheet.swift:516,610` — 문제: `plain(_:locale:)`과 `LedgerNumber.parse(_:locale:)`이 호출마다 `NumberFormatter()`를 만든다. 같은 파일의 `LedgerMoney`(`LedgerCore.swift:265`)는 `whole`·`cents`를 static으로 캐시한다. — 고치는 방법: 로케일별 포매터를 static 캐시로 바꾸거나 `LedgerMoney` 옆에 모은다. (9-1 DateFormatter 항목과 별개로 NumberFormatter만 해당.)

### D-05. JSONDecoder/JSONEncoder 137·127곳 인라인 생성
- 전체 — 문제: `JSONDecoder()` 137곳, `JSONEncoder()` 127곳이 각자 생성된다. 공유 인스턴스는 `TaptionPlan/Core/BiometricDataProtection.swift:126,133`과 `Packages/TaptionAssistant/Sources/TaptionAssistantKit/AITaskQueue.swift:234,240` 두 곳뿐이다. 날짜 전략 같은 설정이 파일마다 달라질 수 있다. — 고치는 방법: 용도별(기본·날짜 포함·스네이크 케이스) 공유 디코더/인코더를 한 곳에 두고 인라인 생성을 바꾼다. 설정이 실제로 다른 곳이 있는지는 먼저 확인한다.

### D-06. 토큰 파싱 중복 + 죽은 함수
- `TaptionPlan/Core/RecordClockEngine.swift:52` — 문제: `compactParts(_:)`가 위 함수(날씨 토큰 `"|"` 6조각 분리·온도 파싱)와 같은 파싱을 하고, 호출처도 없다. — 고치는 방법: 삭제한다. (9절 죽은 코드에도 있음)

### D-07. 밝기 읽기 반복
- `TaptionPlan/TaptionPlanApp.swift:377,389,396,405,418`, `TaptionPlan/Core/AppleSensorCollector+Updates.swift:446` — 문제: `Double(UIScreen.main.brightness)`가 6곳에 반복된다. — 고치는 방법: 밝기 읽기 헬퍼 하나(`SensorBrightness.now()` 등)로 모은다. `UIScreen.main` 교체(7절 X-01)와 함께 처리한다.

---

## 4. 일관성

### C-01. 달력: `Calendar.current` 8곳 + 기본값 10곳 vs `.gregorian` 57곳
- `TaptionPlan/Core/SeasonPackAdapter.swift:29`, `TaptionPlan/UI/FirstRunTutorialGuides.swift:244,246`, `TaptionPlan/UI/FirstRunGuideStage.swift:447`, `TaptionPlan/UI/MapHomeAlarm.swift:595,598`, `TaptionPlan/UI/LocationAlwaysPrompt.swift:21`, `Packages/SeasonPackKit/Sources/SeasonPackKit/SeasonPackCenter.swift:72` — 문제: 코드베이스는 `Calendar(identifier: .gregorian)`이 표준(57곳)인데 이 8곳만 `Calendar.current`를 쓴다. `Calendar.current`는 사용자의 달력 설정(불교력 등)을 따라 날짜 계산이 달라질 수 있다. 기본값으로 `calendar: Calendar = .current`를 받는 곳도 10곳 있다(`StayContext.swift:47`, `SeasonPackCenter.swift:64`, `SeasonPackWindows.swift:40`, `SeasonPackClock.swift:151`, `SeasonPackMemoStore.swift:23,34,50`, `GoogleCalendarAccount.swift:105`, `MapHomeTimeSidebarMath.swift:450`, `SeasonPackIconRegistry.swift:20`). — 고치는 방법: 날짜 계산용은 `.gregorian` 기본값으로 바꾸고, 사용자 표시용으로 `current`가 필요한 곳만 남긴 뒤 주석으로 구분한다.

### C-02. 시간대 폴백 불일치: `?? .current` 3곳 vs `?? .gmt`
- `TaptionPlan/UI/ArrivalCardView.swift:98`, `TaptionPlan/UI/TripImportSheet.swift:406`, `Packages/TaptionPlanStore/Sources/TaptionPlanStore/TaptionStoreColumnCoding.swift:1061` — 문제: `TimeZone(secondsFromGMT:)`가 실패하면 이 3곳은 `.current`로 떨어지는데, 같은 상황의 다른 곳(`AssistantDataActions.swift:510`, `TripShareCreateSheet.swift:35`, `TripShareMapping.swift:75`, `TravelTrips.swift:132,256`)은 `.gmt`로 떨어진다. 오프셋 파싱 실패 시 같은 입력이 다른 시각으로 보인다. — 고치는 방법: UTC 폴백으로 통일한다. (`.current`가 의도인 곳은 주석을 남긴다.)

### C-03. 동명 타입 `SleepSession` 2개
- `Packages/TaptionClassifierEngine/Sources/TaptionClassifierEngine/SleepFusion.swift:14` vs `Packages/TaptionPlanStore/Sources/TaptionPlanStore/Snapshot/HealthAndSensorModels.swift:87` — 문제: 이름은 같은데 필드가 다르다(분류기: `interval`·`origin`·`score`·`evidence`, 저장소: `id`·`span`·`asleepDuration`·`stageDurations` 등). 앱은 `TaptionPlan/Core/FeatureModels.swift:37`의 `typealias SleepSession = TaptionPlanStore.SleepSession`으로 한쪽을 가려서 쓰고 있다. — 고치는 방법: 분류기 쪽을 `ClassifierSleepSession`으로 바꾸거나, 두 타입의 관계를 주석·문서로 고정한다.

### C-04. 이동 수단 enum 2개 (`TransportMode` vs `TravelMode`)
- `Packages/TaptionClassifierEngine/Sources/TaptionClassifierEngine/ClassifierModels.swift:11` vs `Packages/TaptionPlanCore/Sources/TaptionPlanCore/Domain/TravelSegment.swift:3` — 문제: `TransportMode`(stationary 포함 10종)와 `TravelMode`(taxi 포함 10종)가 거의 같은데 따로 있고, 변환은 `TaptionPlan/Core/ClassifierAdapter.swift:221` `travelMode(_:)`에서 수동으로 한다(stationary→nil). 케이스를 한쪽에만 추가하면 컴파일은 깨지지만(스위치가 전체를 다룸) 의미가 어긋날 수 있다. — 고치는 방법: 하나로 합치거나, 합칠 수 없으면 두 enum 위에 "짝"이라는 주석과 변환 테스트를 둔다.

### C-05. 분류 경로만 `preconditionFailure`로 크래시 (에러 처리 불일치)
- `Packages/TaptionActivityEngine/Sources/TaptionActivityEngine/ActivityClassifier.swift:84,127,220`, `TaptionPlan/Core/TaptionActivityEngineAdapter.swift:199,684,719`, `TaptionPlan/Core/TaptionActivityEngineAdapter+TravelMatching.swift:16` — 문제: 분류·정규화·인덱싱에서 취소·실패가 나면 `preconditionFailure`로 앱이 죽는다. 나머지 경로는 throws·Result·nil로 처리한다. "일어나면 안 되는 일"이라는 전제인데, 취소는 백그라운드에서 실제로 일어날 수 있다. — 고치는 방법: 의도된 결정이면 각 위치에 근거를 주석으로 남기고, 아니면 호출부로 에러를 올려서 조용히 건너뛰게 바꾼다.

### C-06. 통과만 하는 위임 함수 (PROPOSALS 9-8 패턴과 동일)
- `TaptionPlan/UI/MapHomeSupportViews.swift:286` — 문제: `MapHomeDayTravelSummary.distanceText(_:)`가 `AppRegion.current.distanceText(meters:)`를 그대로 부르기만 한다. 9-8에서 같은 이유로 `MapHomeWBSPlaybackProjection.distanceMeters`를 삭제한 전례가 있다. — 고치는 방법: 호출부 2곳(`MapHomeView+Support2.swift:323`, `MapHomeView+Menu.swift:364`)을 `AppRegion` 직접 호출로 바꾸고 삭제한다.

---

## 5. 하드코딩 — 번역 카탈로그를 안 타는 문구

앱은 `language.text(한국어, 영어)`(`UIPhrase`, `scripts/l10n` 추출 대상)와 `language.runtimeText`로 번역한다. 아래는 둘 다 안 타는 곳이다.

### L-01. 오류 알림 제목·버튼 하드코딩
- `TaptionPlan/UI/AppShellView.swift:180,183` — 문제: `.alert("확인해 주세요", ...)` 제목과 `Button("확인")`이 한국어 그대로 박혀 있다. — 고치는 방법: `language.text("확인해 주세요", "Please check")`, `language.text("확인", "OK")`로 바꾼다.

### L-02. 시트 제목 하드코딩
- `TaptionPlan/UI/MapHomeCounterDetailSheet.swift:309` — 문제: `Text("카운터 상세")`가 그대로 박혀 있다. — 고치는 방법: `language.text("카운터 상세", "Counter details")`로 바꾼다.

### L-03. 접근성 라벨 하드코딩 4곳
- `TaptionPlan/UI/MapHomeMapAnnotations.swift:112,225,249`, `TaptionPlan/Core/CatAnimationShared.swift:311`, `TaptionPlan/UI/MapHomePhotoLayer.swift:334` — 문제: `.accessibilityLabel("집 레벨 ...")`, `.accessibilityLabel("집 성장과 오늘 하루 요약 보기")`, `.accessibilityLabel("집 레벨 ... · 성장 카드와 오늘 하루 요약 열기")`, `.accessibilityLabel("고양이 애니메이션")`, `.accessibilityLabel(Text("사진 \(count)장"))`이 번역 경로를 안 탄다. VoiceOver가 영어로 설정돼도 한국어로 읽힌다. — 고치는 방법: `language.text`/`language.runtimeText`로 바꾼다.

### L-04. 분류 근거(evidence) 문자열 한국어 전용 + UI 노출
- `Packages/TaptionClassifierEngine/Sources/TaptionClassifierEngine/ModeScorer.swift:41`("가속도·회전 정지" 등), `TaptionPlan/Core/WorkBreakPattern.swift:12,81`("화면을 켠 채 폰을 손에 듦", 제목 "휴식"), `TaptionPlan/Core/AppleWatchSensorActivityEngine.swift:36,39,212,325,328,331`("심박수", "걸음·거리", "집 위치 내 지속 움직임" 등), `TaptionPlan/UI/MapHomeNLESubActivity.swift:201,211,241`("자동 기록", "이동 구간 판정", "일정 '\(...)'") — 문제: 근거 문자열이 한국어로만 만들어지는데, `MapHomeNLESubActivity.swift:199-201` `recordEvidence`가 `actual.evidence.first`를 후보 화면의 근거로 그대로 보여 준다. 영어 사용자는 근거가 한국어로 보인다. — 고치는 방법: 근거를 코드(키)로 저장하고 표시할 때 번역하거나, 최소한 UI에 노출되는 근거만 `language.text`로 바꾼다. 근거 문자열을 파싱하는 곳(`MapHomeApplePlaybackMath.swift:437` "노선 " 접두사 등)이 있어 형식을 바꾸면 함께 고쳐야 한다.

### L-05. 위젯 레인 제목 폴백 하드코딩 (호출처도 없음)
- `TaptionPlan/Core/WidgetShared.swift:64` — 문제: `TaptionWidgetLane.title`이 `rowKind?.title ?? "액션"`으로 한국어를 그대로 돌려준다. 바로 아래 `localizedTitle`이 번역을 처리하는데, `title` 자체는 호출처가 없다. — 고치는 방법: `title`을 삭제하고 `localizedTitle`만 남긴다.

### L-06. 네트워크 타임아웃 매직 넘버 분산 (5·8·10·12·30초)
- `TaptionPlan/UI/MapHomeKakaoSearch.swift:134,150`(5초), `TaptionPlan/Core/BusStopCheck.swift:515`(8초), `TaptionPlan/Core/AnnouncementFeed.swift:233`(8초), `Packages/SeasonPackKit/Sources/SeasonPackKit/Store/SeasonPackFetcher.swift:32,43`(8초), `TaptionPlan/UI/TravelPlacePhotos.swift:304`(12초), `331,344,391,395`(10초), `Packages/TaptionAssistant/Sources/TaptionAssistantKit/TripRelay.swift:97`(10초), `Packages/SeasonPackKit/Sources/SeasonPackKit/Store/SeasonPackBackgroundEngine.swift:30,52`(30초) — 문제: 타임아웃이 8곳에 흩어져 있고 같은 8초·10초도 파일마다 따로 적혀 있다. (`SeasonPackFetcher`의 8초는 `StoreAndFetchTests.swift:202`에서 단언됨) — 고치는 방법: 용도별 상수(짧은 조회 5초·일반 10초·다운로드 30초 등)를 한 곳에 두고 바꾼다. 테스트가 단언하는 값은 함께 업데이트한다.

---

## 6. Deprecated / 구식 API (배포 타깃 iOS 18.0)

### X-01. `UIScreen.main` 8곳 (iOS 16+ 소프트 deprecated)
- `TaptionPlan/TaptionPlanApp.swift:377,389,396,405,418`, `TaptionPlan/Core/AppleSensorCollector+Updates.swift:446`, `TaptionPlan/UI/MapHomePhotoLayer.swift:205`, `TaptionPlan/UI/MapHomeView+Map.swift:25` — 문제: `UIScreen.main`은 "'main' will be deprecated in a future version of iOS: Use a UIScreen instance found through context instead"라는 경고를 받는다. 밝기 6곳·스케일 1곳·너비 1곳이다. — 고치는 방법: 뷰 맥락이면 `windowScene.screen`·GeometryReader로 바꾸고, 백그라운드 센서 수집(밝기)처럼 윈도우가 없는 곳은 `UIApplication.shared.connectedScenes`에서 찾되 없으면 nil을 허용하는 헬퍼로 모은다(D-07과 함께).

### X-02. 확인 결과 없는 것 (다시 파지 말 것)
- `NavigationView` 0건, `presentationMode` 0건, `alert(isPresented:)`·`alert(item:)` 0건, `onChange(of:perform:)` 2인자 형태 0건(154곳 모두 iOS 17+ 형태), `NSLocalizedString` 0건, `UIApplication.shared.windows`·`keyWindow` 0건, `TextField` `onCommit` 0건, `NSKeyedArchiver` 구식 API 0건.

---

## 7. 접근성

### A-01. `accessibilityLabel` 없는 이미지 전용 버튼 4곳
- `TaptionPlan/UI/LedgerSheet.swift:218,222` — 문제: 월 이동 버튼(`chevron.left`·`chevron.right`)에 라벨이 없어 VoiceOver가 "버튼"으로만 읽는다. — 고치는 방법: `language.text("이전 달", "Previous month")`·`language.text("다음 달", "Next month")` 라벨 추가.
- `TaptionPlan/UI/MapHomePlaceBookTools.swift:840,842` — 문제: 여행 정류장 순서 이동 버튼(`chevron.up`·`chevron.down`)에 라벨이 없다. 바로 옆 `:844` 삭제 버튼은 `.accessibilityLabel(language.text("삭제", "Delete"))`이 있다. — 고치는 방법: `language.text("위로 이동", "Move up")`·`language.text("아래로 이동", "Move down")` 라벨 추가.

### A-02. Dynamic Type을 무시하는 고정 글자 크기 114곳
- 전체 — 문제: `.font(.system(size:` 245곳 중 `TaptionType.scaled`를 안 거치는 곳이 114곳(앱 82곳·위젯/워치 30곳·패키지 2곳)이다. 앱은 `TaptionType.scaled`(1.3배 상한)로 시스템 글자 크기를 반영하는데 이 호출부는 그걸 안 탄다. `TaptionType.snapped`의 11pt 하한도 안 지켜서 `TaptionPlan/UI/TripItemStatus.swift:179`(8pt), `TaptionPlan/UI/TravelPlanTable.swift:617`(10pt), `TaptionPlanWidget/TaptionScheduleWidgetView.swift:199`(8.5pt) 같은 곳이 있다. — 고치는 방법: 텍스트는 `.taptionStyle(_:)`·`.taptionFixed(size: TaptionType.scaled(...))`로 바꾸고, 아이콘용(`Image`의 `.font`)은 크기만 남겨도 되는지 따로 정한다. 위젯·워치는 "시스템 글꼴을 그대로 쓴다"는 정책(`TaptionFont.swift` 주석)이 있어 별도 판단이 필요하다. 많은 파일(`TravelPlanTable.swift` 14곳, `MapHomePlaceBookTools.swift` 14곳, `MapHomeView+Menu.swift` 13곳, `FirstRunGuideStage.swift` 11곳 순)이 있어 파일 단위로 나눠서 한다.

### A-03. 오탐 제외
- `TaptionPlan/UI/MapHomeView+Menu.swift:1107`은 라벨 안에 `Label(title, ...)` 텍스트가 있어 VoiceOver가 제목을 읽는다. 제외.

---

## 8. 죽은 코드 (저장소 전체 Swift에서 정의 1회만 확인)

삭제 전 빌드로 확인한다. 전부 internal/public이라 삭제하면 컴파일이 검증한다.

### 패키지 (5건)
- `Packages/SeasonPackKit/Sources/SeasonPackKit/Store/SeasonPackStore.swift:184` — `SeasonPackStore.totalBytes()` — 문제: 공개 함수인데 호출처가 없다. — 고치는 방법: 삭제하거나, 설정 화면의 용량 표시에 연결한다.
- `Packages/TaptionActivityEngine/Sources/TaptionActivityEngine/ActivityClassifier.swift:206` — `reclassifyTail(existing:appendedEvidence:overrides:)` — 문제: `append`를 그대로 부르는 통과 함수이고 호출처가 없다. — 고치는 방법: 삭제한다.
- `Packages/TaptionPlanStore/Sources/TaptionPlanStore/Snapshot/MovementModels.swift:237` — `TravelSegmentGroup` — 문제: 공개 구조체인데 참조가 없다. — 고치는 방법: 삭제한다.
- `Packages/TaptionPlanStore/Sources/TaptionPlanStore/Snapshot/TimelineModels.swift:141` — `TimelineViewport` — 문제: 공개 구조체인데 참조가 없다. — 고치는 방법: 삭제한다.
- `Packages/TaptionTripShare/Sources/TaptionTripShare/ShareRoomSession+Editing.swift:145` — `extendLocks()` — 문제: 공개 함수인데 호출처가 없다. 주석에 "평소에는 60초마다 스스로 한다"고 적혀 있어 수동 연장이 필요 없을 수 있다. — 고치는 방법: 자동 연장만으로 충분하면 삭제하고, 수동 새로고침 UI가 필요하면 연결한다.

### 앱 Core (8건)
- `TaptionPlan/Core/AppleHealthService.swift:29` — `HealthBackgroundRefreshCoordinator.receiveUpdate()` — 문제: HealthKit 백그라운드 갱신을 받는 진입점인데 호출처가 없다. `register`는 `AppModel.swift:745`에서 불리고, 실제 백그라운드 갱신은 `TaptionPlanBackgroundRefresh`(`TaptionPlanApp.swift:307`)로 가는 것으로 보인다. — 고치는 방법: 백그라운드 갱신 경로를 확인하고, 안 쓰면 삭제한다.
- `TaptionPlan/Core/CarAudioTravelConfirmation.swift:161` — `matchedName(in:)` — 문제: 호출처가 없다. — 고치는 방법: 삭제한다.
- `TaptionPlan/Core/DayPhaseEngine.swift:283` — `completePhasesAcrossDays(actuals:travel:stays:placeKinds:in:calendar:asOf:)` — 문제: 호출처가 없다. — 고치는 방법: 삭제한다.
- `TaptionPlan/Core/LedgerCapture.swift:291` — `inlineMerchant(_:)` — 문제: 한 줄 알림 가게 찾기인데 호출처가 없다. — 고치는 방법: 삭제하거나, 결제 문자 파싱에서 실제로 쓰는 경로가 있으면 연결한다.
- `TaptionPlan/Core/LocationPrivacyAndTravelDistance.swift:11` — `widgetSafe(places:travel:)` — 문제: 호출처가 없다. — 고치는 방법: 삭제한다.
- `TaptionPlan/Core/RecordClockEngine.swift:52` — `compactParts(_:)` — 문제: 호출처가 없고 위 함수와 같은 파싱을 한다(D-06). — 고치는 방법: 삭제한다.
- `TaptionPlan/Core/SubwayCatalog.swift:1070` — `bestRoute(_:)` — 문제: 호출처가 없다. — 고치는 방법: 삭제한다.
- `TaptionPlan/Core/SubwayTravelSegmentEngine.swift:140` — `mergingRestoredTravel(existing:readings:userTransitLocations:)` — 문제: 클라우드 복원 뒤 지하철 구간을 다시 만드는 함수인데 호출처가 없다. 복원 경로에서 빠져 있으면 복원 뒤 지하철 구간이 안 살아난다. — 고치는 방법: 복원 흐름에 연결하거나 삭제한다.

### 앱 UX — AppModel 확장 (40건, 파일별 묶음)
- `TaptionPlan/UX/AppModel+ActualEditing.swift:112` — `correctActualFragment(_:displayedSpan:startAt:endAt:with:)` — 고치는 방법: 삭제한다.
- `TaptionPlan/UX/AppModel+Backup.swift:243` — `validateBiometricProtectedData()` — T-08 참고. 보안 기능이라 삭제보다 연결을 먼저 검토한다.
- `TaptionPlan/UX/AppModel+FrequentPlaces.swift:5,254,359,803,833` — `confirmPlace(_:)`·`calibrateFrequentPlaceFloor(_:)`·`deleteFrequentPlaceFloorReference(_:)`·`confirmFloorTransition(_:)`·`photoThumbnailData(_:)` — 고치는 방법: 삭제한다. 층 교정 UI가 이 함수들을 쓸 계획이면 연결한다.
- `TaptionPlan/UX/AppModel+LocationCollection.swift:219,238,334` — `setGPSLoggingPreset(_:)`·`setGPSLoggingIntervalMinutes(_:)`·`startTracking()` — 문제: GPS 기록 시작·설정 함수인데 호출처가 없다. 수집 시작이 다른 경로로 가는지 확인이 필요하다. — 고치는 방법: 수집 시작 경로를 확인하고, 안 쓰면 삭제한다.
- `TaptionPlan/UX/AppModel+Memos.swift:12,19,448,508` — `closeMemoEntry(_:)`·`moveMemoEntry(_:)`·`toggleVoiceMemo(_:)`·`toggleVoicePlayback(_:)` — 고치는 방법: 삭제한다.
- `TaptionPlan/UX/AppModel+Navigation.swift:5,26,41,49,54,66,96,124` — `selectTab(_:)`·`openGroup(_:)`·`openGoalDetail(_:)`·`closeGoalDetail()`·`closeCurrentGroup()`·`selectScale(_:)`·`shiftReviewDate(by:)`·`returnToNow()` — 문제: 내비게이션 헬퍼 8개가 전부 호출처가 없다. 내비게이션이 `NavigationModels` 상태 직접 조작으로 바뀐 것으로 보인다. — 고치는 방법: 삭제한다.
- `TaptionPlan/UX/AppModel+Permissions.swift:305` — `requestAppUsageAuthorization()` — 고치는 방법: 삭제한다.
- `TaptionPlan/UX/AppModel+Plans.swift:204,343,413,741,1009` — `connectActionItem(_:)`·`connectRecordNode(_:)`·`updateRoutineActualInterval(_:)`·`addPlanToCalendar(_:)`·`setTimelineRowOrder(_:)` — 고치는 방법: 삭제한다.
- `TaptionPlan/UX/AppModel+Settings.swift:12,19,56,64,70,118` — `setStartScale(_:)`·`setRememberLastScale(_:)`·`toggleSetupCategory(_:)`·`cancelInitialCategorySelection()`·`applyInitialCategorySelection()`·`setMapDisplayProvider(_:)` — 고치는 방법: 삭제한다.
- `TaptionPlan/UX/AppModel+WatchHealth.swift:168` — `clearWatchLaunchReport()` — 고치는 방법: 삭제한다.
- `TaptionPlan/UX/AppModel+WidgetLiveActivity.swift:72,78,261` — `setWidgetPhotosVisible(_:)`·`refreshWidgetNow()`·`pausePlan(_:)` — 고치는 방법: 삭제한다.
- `TaptionPlan/UX/AppModel.swift:892` — `refreshBiometricDataProtectionStatus()` — 문제: 생체 보호 상태를 새로고침하는 함수인데 호출처가 없다. T-08과 함께 본다. — 고치는 방법: 상태 표시 경로에 연결하거나 삭제한다.

### 제외한 오탐 (죽은 코드가 아님)
- `SeasonPackBackgroundEngine.urlSessionDidFinishEvents` — `URLSessionDelegate` 메서드라 시스템이 부른다.
- `AddFlightAlertIntent`·`AddSharedTextIntent`·`AddPaymentNotificationIntent` — `AppIntent`는 시스템이 자동 발견한다. `AppShortcutsProvider` 등록이 없어도 단축어에서 쓸 수 있다.
- `MapHomeBenchHomeZoom` 2정의 — `#if DEBUG || BENCH` / `#else`로 나뉜 의도된 정의다.
- `TaptionWidgetLane.title` — 호출처는 없지만 L-05에서 다룬다.
- `ShareFakeTransport` — 테스트 지원 타깃(`TaptionTripShareTesting`)이며 7개 테스트 파일이 import한다.

---

## 9. 확인 결과 문제없음 (다시 파지 말 것)

- **가계부 정산**: `LedgerSettlement.transfers`·`LedgerFX.krwPerUnit`·`LedgerSplit.even`·`greedy`·`zeroSumGroups`는 `LedgerTests.swift`에서 충분히 테스트됨(나머지 분배, 결정성 20회 반복 포함). `TaptionLedgerCore`에 Tests 디렉터리는 없지만 앱 테스트가 기능을 커버한다.
- **백업 V2**: `TaptionBackupV2Tests.swift`에 틀린 비밀번호·변조 파일·부분 실패·덮어쓰기 규칙·코덱 3종(`none`·`lzfse`·`zlib`) 테스트가 있다. `TaptionBackupCodec`·`TaptionBackupDestination`·`TaptionRestoreStaging`·`TaptionStoreV2Error` 모두 테스트됨.
- **공유 암호화**: `ShareCryptoTests`에 잘못된 키·버전·컨텍스트(방·항목·종류·에포크) 테스트가 있다. `ShareWriteOutcome`·`ShareConflict`는 케이스명(`.done`·`.conflict`)으로 테스트됨.
- **키체인**: `AssistantKeychainSecrets` 읽기·쓰기 왕복과 범위 키 저장·삭제가 `AssistantRelayTests.swift:360`에서 테스트됨. `AssistantRelayGate`도 `AssistantReviewFixTests.swift:158`에서 테스트됨.
- **항공 알림 병합**: `FlightMergeOutcome`은 `FlightAlertMergeTests`에서 `outcomes` 단언으로 전 케이스 테스트됨.
- **시즌 팩 시계**: `SeasonPackClock`의 서버 앵커·기기 점프·하이워터·48시간 오프라인·첫 실행이 `WindowsAndClockTests`에서 테스트됨.
- **그 외 테스트 확인됨**: `TaptionRobustScalarFilter`(3건), `TaptionWatchAmbientRevisionPolicy`·`TaptionWatchAmbientOutboxRetryPolicy`, `FloorHeightEstimator`, `MotionKindResolver`, `SleepTravelReconciliationEngine`, `ActivityCorrectionEngine`, `RecordAnalysisCategoryNormalizer`, `TaptionWatchAlertPolicy`, `TaptionWatchCommandCapabilityStore`(reconcile/consume/clear), `LedgerTripMath.sheet`, `LedgerBudget.id`·디코딩 실패.
- **Deprecated 없음**: X-02 목록 참고.
