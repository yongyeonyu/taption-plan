import CoreMotion
import Foundation
@preconcurrency import ActivityKit
import CoreLocation
import Observation
import OSLog
import UIKit
import WidgetKit
import TaptionPlanCore

@MainActor
@Observable
final class AppModel {
    private(set) static weak var applicationInstance: AppModel?

    static func backgroundTaskInstance() -> AppModel {
        if let applicationInstance { return applicationInstance }
        // Every UI-less wake builds a whole model; record the cost so the
        // decision to keep one alive rests on measured time, not a guess.
        let started = ContinuousClock.now
        let model = AppModel(registersHealthBackgroundHandler: false)
        applicationInstance = model
        let elapsed = started.duration(to: .now).components
        TaptionPlanDiagnosticsLogger.shared.record(
            "background_model_created",
            fields: ["init_ms": String(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)]
        )
        return model
    }

    static let integrationLogger = Logger(
        subsystem: "com.taption.plan",
        category: "AutomaticRecords"
    )
    static let mapLocationReadingTimeout: TimeInterval = 3
    static let weatherPreviewRefreshInterval: TimeInterval = 30 * 60
    static let weatherPreviewMaximumDays = 7
    /// 지난 날 날씨 고정: 한 번에 거슬러 가는 최대 일수와 시도 간격.
    static let weatherFixBackfillDays = 3
    static let weatherFixRetryInterval: TimeInterval = 30 * 60
    static let weatherFixedThroughDayKey = "taption.weather.fixed-through-day-v1"
    var selectedTab: RootTab = .schedule
    var selectedScale: TimeScale = .day
    var selectedDate: Date = .now {
        didSet {
            guard !Calendar.autoupdatingCurrent.isDate(
                oldValue, inSameDayAs: selectedDate
            ) else { return }
            scheduleSelectedDateRefresh()
        }
    }
    var isAddPlanPresented = false
    var addPlanContext: AddPlanContext = .quick
    var selectedAction: QuickActionItem?
    var planEditorRequest: PlanEditorRequest?
    var selectedPhotoCluster: PhotoCluster?
    var detail: AppDetail?
    /// 지도 홈이 아직 소비하지 않은 이동 요청. 위젯·알림·URL이 남기고,
    /// `MapHomeView`가 화면을 옮긴 뒤 nil로 되돌린다.
    var pendingMapHomeRoute: MapHomeRoute?
    var selectedGroupPlanID: UUID?
    var selectedGoalPlanID: UUID?
    var groupNavigationPath: [UUID] = []
    /// 메모 입력은 항목을 먼저 고르지 않는다. 시간표 메모 줄에서 바로 열리며,
    /// 새 메모가 놓일 순간과 그 자리에 이미 있던 메모만 들고 있으면 된다.
    var memoEntry: MemoEntry?
    var selectedCatCoat: CatCoat = .calico {
        didSet {
            HwarangCoat.selected = .named(selectedCatCoat.catStyle.rawValue)
            HwarangCoat.selectedName = selectedCatCoat.displayName
            MapHomeCustomAnimations.register(snapshot.settings.mapUserActivityCategories)
        }
    }
    /// 기록 탭은 시간표와 같은 배율을 쓰되, 기록 전용 년 보기는 유지한다.
    var reviewScale: TimeScale = .week
    var isPermissionOnboardingPresented = false
    var permissionOnboardingStartFeature: PermissionFeature?
    var pendingSetupCategoryIDs: Set<String> = []
    var isEditingSetupCategories = false

    /// 앱 데이터 전체. 관찰을 직접 다룬다: 저장 뒤 `updatedAt`만 바뀐 대입은 관찰자를 깨우지 않아,
    /// 내용이 그대로인 저장이 지도 홈 전체를 다시 평가하지 않는다(ARC1103A01).
    var snapshot: TaptionDataSnapshot {
        get {
            access(keyPath: \.snapshot)
            return snapshotStorage
        }
        set { commitSnapshot(newValue) }
    }
    @ObservationIgnored private var snapshotStorage: TaptionDataSnapshot = .empty
    /// 마지막으로 바뀐 `snapshot.updatedAt`. 저장 시각을 지켜보는 화면은 `snapshot` 대신 이것을 읽는다.
    private(set) var snapshotSavedAt: Date = .distantPast
    /// 내용이 바뀔 때만 오른다. `snapshotRevision`과 달리 시각만 바뀐 저장에는 오르지 않는다.
    @ObservationIgnored private(set) var snapshotContentRevision: UInt64 = 0

    private func commitSnapshot(_ newValue: TaptionDataSnapshot) {
        let isTimestampOnly = timestampOnlySnapshotAssignment
        timestampOnlySnapshotAssignment = false
        if repositoryLoadFailed || isStartupSnapshotPartial { return }
        let oldValue = snapshotStorage
        if isTimestampOnly {
            snapshotStorage = newValue
            if oldValue.updatedAt != newValue.updatedAt {
                snapshotRevision &+= 1
                activityClassificationRevisionFence.advance(to: snapshotRevision)
                snapshotSavedAt = newValue.updatedAt
            }
            return
        }
        if oldValue == newValue {
            snapshotStorage = newValue
            return
        }
        withMutation(keyPath: \.snapshot) { snapshotStorage = newValue }
        noteSnapshotMutationForSensorRefresh()
        snapshotRevision &+= 1
        snapshotContentRevision &+= 1
        activityClassificationRevisionFence.advance(to: snapshotRevision)
        if oldValue.updatedAt != newValue.updatedAt { snapshotSavedAt = newValue.updatedAt }

        // Device snapshots are frequent. Keep a separate revision for
        // changes that alter rows, blocks or their detail targets so the
        // Gantt layout cache survives ordinary live collection.
        if oldValue.actuals != newValue.actuals
            || oldValue.places != newValue.places
            || oldValue.travel != newValue.travel {
            dayProjectionRevision &+= 1
            needsLocalRecordNormalization = true
        }
        if oldValue.settings.activityCorrections != newValue.settings.activityCorrections
            || oldValue.settings.confirmedSleepSpans != newValue.settings.confirmedSleepSpans {
            needsLocalRecordNormalization = true
        }
        if oldValue.weather != newValue.weather
            || oldValue.plans != newValue.plans
            || oldValue.actuals != newValue.actuals
            || oldValue.travel != newValue.travel
            || oldValue.places != newValue.places
            || oldValue.calendarEvents != newValue.calendarEvents
            || oldValue.photos != newValue.photos
            || oldValue.categories != newValue.categories
            || oldValue.recordLinks != newValue.recordLinks
            || oldValue.memos != newValue.memos
            || oldValue.settings.timelineRowOrder
                != newValue.settings.timelineRowOrder {
            timelineRevision &+= 1
        }
    }
    @ObservationIgnored var snapshotRevision: UInt64 = 0
    var canUndo = false
    var canRedo = false
    @ObservationIgnored var userEditUndoHistory: [AppModelHistoryItem] = []
    @ObservationIgnored var userEditRedoHistory: [AppModelHistoryItem] = []
    @ObservationIgnored let activityClassificationRevisionFence =
        ActivityClassificationRevisionFence()
    @ObservationIgnored var dayProjectionRevision: UInt64 = 0
    var rawDayRevisionSignal: UInt64 = 0
    @ObservationIgnored var rawDayRevisions: [Date: UInt64] = [:]
    @ObservationIgnored var daySourceFingerprintCache = TaptionBoundedCache<
        Date, (revision: UInt64, value: String?)
    >(capacity: 42)
    @ObservationIgnored var timelineRevision: UInt64 = 0
    var backupRestoreRevision: UInt64 = 0
    @ObservationIgnored var timestampOnlySnapshotAssignment = false
    @ObservationIgnored var needsLocalRecordNormalization = true
    var isBootstrapped = false
    var hasPreparedStartupSettings = false
    @ObservationIgnored var isStartupSnapshotPartial = false
    /// 저장소를 읽지 못한 상태에서 빈 스냅샷을 저장하면 기존 기록을
    /// 덮어쓸 수 있다. 복구 가능한 저장본을 다시 읽기 전까지 저장을 막는다.
    @ObservationIgnored var repositoryLoadFailed = false
    @ObservationIgnored var pendingMapMemoIDs = Set<UUID>()
    var isRefreshingIntegrations = false
    var isRequestingPermission = false
    var isSensorCollecting = false
    private(set) var sensorStorageErrorDescription: String?
    var sensorCollectionSessionState: SensorCollectionSessionState =
        .stopped
    var sensorCollectionSessionID: UUID?
    var sensorCollectionStartedAt: Date?
    var lastSensorWakeReason: SensorWakeReason?
    var lastSensorSavedAt: Date?
    var sensorSaveToken = 0
    var isCloudSyncing = false
    var isExportingDiagnostics = false
    /// 내보내기 상태는 키로 저장하고, 보여 줄 때 현재 언어로 바꾼다(언어를 바꿔도 맞게 나온다).
    var diagnosticsExportStatusKey: DiagnosticsExportStatusKey = .ready
    var diagnosticsExportStatus: String { diagnosticsExportStatusKey.localized }
    var cloudUnavailableReason: CloudUnavailableReason?
    var isRecordingVoiceMemo = false
    var playingVoiceAttachmentID: UUID?
    var sensorAvailability: SensorHardwareAvailability?
    var latestSensorReading: SensorReading?
    var latestHeartRate: Double?
    var latestHeartRateUpdatedAt: Date?
    var latestMapAnchorHydratedDay: Date?
    var liveRouteState: LiveRouteState = .empty
    var activeTrackingSession: TrackingSession?
    var trackingSessionWasRecovered = false
    var latestAltitudeEstimate: CalibratedAltitudeEstimate?
    var floorCalibrationNotice: String? = nil
    /// 층 보정 표본을 모으는 중일 때만 값이 있다. 화면은 이 값으로 진행을
    /// 보여 주고, 끝나기 전에는 아무것도 기록되지 않는다.
    var floorCalibrationSampling: FloorCalibrationSampling?
    var watchLaunchReport: (report: String, receivedAt: Date)?
    /// 등록하지 않았는데 자주 간 자리 하나. 설정 화면을 열 때만 다시 구하고,
    /// 한 번에 하나만 보여 준다.
    var frequentPlaceSuggestion: FrequentPlaceSuggestion?
    var sleepSessions: [SleepSession] = []
    /// 워치 기록이 늦게 도착해 아이폰 추정을 갈아 끼운 기록. 앱을 다시 켜면
    /// 세션 자체가 HealthKit에서 다시 계산되므로 이 목록도 함께 비워진다.
    var sleepReconciliations: [SleepReconciliation] = []
    var lastHealthRefreshAt: Date?
    var healthSyncOverview = HealthKitSyncOverview(states: [])
    var healthSyncProgress: HealthKitSyncProgress?
    var isHealthHistorySyncRunning = false
    var appleWatchConnectionState: AppleWatchConnectionState = .unsupported
    var appleWatchLastDataReceivedAt: Date?
    var appleWatchAppVersion: TaptionWatchAppVersion?
    var appleWatchReceivedDataKinds: Set<AppleWatchDataKind> = []
    var appleWatchDataSyncRequestedAt: Date?
    var appleWatchDataSyncRequestStatus:
        AppleWatchDataSyncRequestStatus?
    @ObservationIgnored var appleWatchDataSyncRequestID: String?
    /// 첫 실행 안내를 닫은 기록. 기기 저장소에서 읽어 오고, 바뀔 때만 다시
    /// 넣어 화면이 갱신되게 한다.
    var dismissedAppleWatchPrompts: Set<AppleWatchOnboardingPrompt> =
        AppleWatchOnboardingStore().dismissed
    var hasSeenWatchAppInstalled =
        AppleWatchOnboardingStore().hasSeenWatchAppInstalled
    @ObservationIgnored
    let watchOnboardingStore = AppleWatchOnboardingStore()
    @ObservationIgnored
    let appleWatchDataReceiptStore: AppleWatchDataReceiptStore
    var appUsageAuthorizationState: ScreenTimeAuthorizationState = .unavailable
    var lastAppUsageRefreshAt: Date?
    var appUsageRecordCount = 0
    var appUsageTotalDuration: TimeInterval = 0
    var biometricDataProtectionStatus: BiometricDataProtectionStatus =
        .notProtected
    /// Cloud-backup PIN and the optional local app-lock gate are independent:
    /// normal planning remains usable when no security credential is set.
    var securityStatus = PlanSecurityStatus(
        settings: PlanAppLockSettings(),
        state: .unlocked,
        hasPIN: false,
        failedAttempts: 0,
        retryAfter: nil,
        latestSuccessfulBackupDate: nil
    )
    var backupActivity: PlanBackupActivity = .idle
    var backupListings: [PlanBackupListingRow] = []
    var backupListingError: String?
    var isRefreshingBackupListings = false
    /// 지금 형식으로 열 수 없어 목록에서 뺀 백업 파일 수.
    var backupUnsupportedFileCount = 0
    /// 겹친 새로고침 중 마지막 요청의 결과만 화면에 올린다.
    var backupListingGeneration = 0
    var lastBackupReport: PlanBackupReport?
    /// 기록 ID → 앱 토큰. 스크린 타임 데이터는 민감하므로 저장하지 않고
    /// 새로 고칠 때마다 메모리에만 채운다.
    var appUsageTokenIndex: [UUID: Data] = [:]
    var userFacingError: String?
    @ObservationIgnored var lastAutoFloorCalibrationKey: String? = nil
    @ObservationIgnored var altitudeSpikeGate = AltitudeSpikeGate()
    @ObservationIgnored var altitudeGatePlaceID: UUID? = nil
    @ObservationIgnored var calibrationNoticeTask: Task<Void, Never>?

    var widgetSyncStatus: TaptionWidgetSyncStatus {
        TaptionWidgetSyncStatus.compare(
            groundTruth: TaptionWidgetSharedStore.readGroundTruthPayload(),
            cached: TaptionWidgetSharedStore.readPayload()
        )
    }

    var widgetSyncStatusText: String {
        widgetSyncStatus.displayName
    }

    var widgetSyncDiagnosticsText: String {
        TaptionWidgetSharedStore.diagnostics().summary
    }

    var diagnosticsLatestLogSummary: String {
        let defaults = UserDefaults(
            suiteName: TaptionWidgetSharedStore.appGroupIdentifier
        ) ?? .standard
        guard let fileName = defaults.string(
            forKey: Self.diagnosticsLatestFileKey
        ),
        let savedAt = defaults.object(
            forKey: Self.diagnosticsLatestSavedAtKey
        ) as? Date else {
            return AppLanguagePreference.text(
                korean: "최신 로그 없음",
                english: "No recent log"
            )
        }
        let savedText = savedAt.formatted(date: .abbreviated, time: .shortened)
        return AppLanguagePreference.text(
            korean: "최신 \(fileName) · \(savedText)",
            english: "Latest \(fileName) · \(savedText)"
        )
    }

    var appUsageStatusText: String {
        guard appUsageAuthorizationState == .approved else {
            return appUsageAuthorizationState.displayName
        }
        guard lastAppUsageRefreshAt != nil else {
            return AppLanguagePreference.text(
                korean: "동기화 대기",
                english: "Waiting to sync"
            )
        }
        guard let total = ScreenTimeUsageRecordEngine
            .localizedDurationText(appUsageTotalDuration) else {
            return AppLanguagePreference.text(
                korean: "오늘 기록 없음",
                english: "No records today"
            )
        }
        return AppLanguagePreference.text(
            korean: "오늘 \(total) · \(appUsageRecordCount)개",
            english: "Today \(total) · \(appUsageRecordCount) items"
        )
    }

    var cloudStatusText: String {
        if isCloudSyncing {
            return AppLanguagePreference.text(korean: "동기화 중", english: "Syncing")
        }
        if let cloudUnavailableReason { return cloudUnavailableReason.statusLabel }
        return permissionState(for: .cloud).settingsLabel
    }

    var cloudStatusGuidance: String? {
        isCloudSyncing ? nil : cloudUnavailableReason?.guidance
    }

    /// 자동 기록이 하나도 없고 필요한 연동이 꺼져 있을 때만 알린다. 연동은
    /// 켜져 있는데 보이는 구간에만 기록이 없는 경우는 정상이므로 알리지
    /// 않는다.
    var timelineIntegrationNotice: [String]? {
        guard snapshot.actuals.isEmpty,
              snapshot.travel.isEmpty,
              snapshot.places.isEmpty,
              snapshot.calendarEvents.isEmpty,
              snapshot.photos.isEmpty,
              snapshot.plans.isEmpty else {
            return nil
        }
        var missing: [String] = []
        if !settings.locationEnabled
            || !permissionState(for: .location).isGranted {
            missing.append(AppLanguagePreference.text(
                korean: "위치·이동",
                english: "Location & movement"
            ))
        }
        if !settings.healthEnabled {
            missing.append(AppLanguagePreference.text(
                korean: "건강 데이터",
                english: "Health data"
            ))
        }
        if settings.selectedCalendarIDs.isEmpty {
            missing.append(AppLanguagePreference.text(
                korean: "캘린더",
                english: "Calendar"
            ))
        }
        return missing.isEmpty ? nil : missing
    }

    var needsSleepConnectionNotice: Bool {
        guard selectedScale == .day,
              !settings.healthEnabled,
              Calendar.autoupdatingCurrent.isDateInToday(selectedDate) else {
            return false
        }
        let today = daySpan(containing: selectedDate)
        return !snapshot.actuals.contains {
            ($0.categoryID == "sleep"
                || $0.behavior == WatchBehaviorKind.sleep.rawValue)
                && $0.span(asOf: today.end).intersection(with: today) != nil
        }
    }

    @ObservationIgnored let repository: any PlanDataRepository
    @ObservationIgnored let biometricProtectedSnapshotStore:
        BiometricProtectedSnapshotStore?
    @ObservationIgnored let calendarService: AppleCalendarService
    @ObservationIgnored let photoService: ApplePhotoLibraryService
    @ObservationIgnored let healthService: AppleHealthService
    @ObservationIgnored let sensorService: AppleSensorDataService?
    @ObservationIgnored let weatherService: AppleWeatherContextService
    /// 날씨를 못 가져온 이유를 화면에 보여주기 위한 상태(값이 바뀔 때만 갱신한다).
    var weatherStatus = WeatherServiceStatus()
    @ObservationIgnored let airQualityService: AirQualityContextService
    @ObservationIgnored let cloudSyncService: CloudKitSnapshotSyncService?
    @ObservationIgnored let securityService: PlanSecurityService?
    @ObservationIgnored let backupService: PlanBackupEngineAdapter?
    @ObservationIgnored let placeNameResolver: PlaceNameResolver
    @ObservationIgnored let transportContextService:
        AppleTransportContextService
    @ObservationIgnored let voiceMemoRecorder: VoiceMemoRecorder
    @ObservationIgnored let voiceMemoPlayer: VoiceMemoPlayer
    @ObservationIgnored let liveActivityController: TaptionLiveActivityController
    @ObservationIgnored let notificationScheduler: PlanNotificationScheduler
    @ObservationIgnored let nearbyMemoScheduler = NearbyMemoNotificationScheduler()
    @ObservationIgnored var nearbyMemoSyncTask: Task<Void, Never>?
    @ObservationIgnored let watchConnectivityService: AppleWatchConnectivityService
    @ObservationIgnored let airPodsActivityService: AirPodsActivityService
    @ObservationIgnored let screenTimeUsageService: ScreenTimeUsageService
    @ObservationIgnored let rawDeviceDataArchive:
        RawDeviceDataDayArchive?
    @ObservationIgnored let dayDatabase: PlanDayDatabase?
    @ObservationIgnored let dayLoadCoordinator: PlanDayLoadCoordinator?
    /// 확정한 하루 요약을 보관하는 저장소(본 저장소와 같은 파일).
    @ObservationIgnored let daySealStore: TaptionStoreV2?
    /// 확정한 하루 요약. 지나간 날의 경로·시급·날씨·요약을 다시 계산하지 않고 여기서 읽는다.
    var sealedDays: [Date: TaptionSealedDay] = [:]
    /// 확정 요약을 마지막으로 읽은 시각(장면이 다시 활성화될 때 한 번만 읽는다).
    @ObservationIgnored var sealedDaysLoadedAt: Date?
    @ObservationIgnored var isSealingSettledDays = false
    @ObservationIgnored var daySealingTask: Task<Void, Never>?
    @ObservationIgnored var classificationBackfillTask: Task<Void, Never>?
    @ObservationIgnored var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored var startupSettingsTask: Task<Void, Never>?
    @ObservationIgnored var bootstrapPreparationTask: Task<Void, Never>?
    @ObservationIgnored var permissionRefreshTask: Task<Void, Never>?
    @ObservationIgnored var needsBootstrapPreparation = false
    @ObservationIgnored var foregroundPreparationTask:
        Task<Void, Never>?
    @ObservationIgnored var foregroundPreparationGeneration = 0
    @ObservationIgnored var foregroundRefreshTask: Task<Void, Never>?
    @ObservationIgnored var deferredVisibleRefreshTask: Task<Void, Never>?
    @ObservationIgnored var lastForegroundRefreshAt: Date?
    @ObservationIgnored var foregroundHealthRefreshTask:
        Task<Void, Never>?
    /// 지금 대분류가 바뀌었는지 30초마다 확인해 다이나믹 아일랜드·잠금화면·워치를 함께 갱신한다.
    @ObservationIgnored var currentActivitySyncTask:
        Task<Void, Never>?
    /// 마지막으로 외부 화면(아일랜드·잠금화면·워치)에 알린 대분류.
    @ObservationIgnored var lastPublishedCurrentActivity:
        (categoryID: String, title: String)?
    @ObservationIgnored var calendarStoreRefreshTask:
        Task<Void, Never>?
    @ObservationIgnored var calendarStoreRefreshRequiresWide = false
    @ObservationIgnored var selectedDateRefreshTask:
        Task<Void, Never>?
    @ObservationIgnored var selectedDateRefreshGeneration = 0
    @ObservationIgnored var widgetReloadFollowupTask:
        Task<Void, Never>?
    @ObservationIgnored var isSceneActive = false
    /// 화면이 백그라운드로 내려간 뒤인지. 이 상태에서는 새 저장을 시작하지 않는다.
    @ObservationIgnored var isSceneInBackground = false
    @ObservationIgnored var isCommerceLocked = false
    @ObservationIgnored var isHealthRefreshRunning = false
    /// 잠긴 기기에서 건강 갱신을 미뤘는지. 보호된 자료가 다시 열리면 한 번 읽는다(BGR1028A01).
    @ObservationIgnored var isHealthRefreshDeferredUntilUnlock = false
    @ObservationIgnored var isSensorTimelineRefreshing = false
    /// A user edit saved while a sensor refresh was running. Rolling the whole
    /// snapshot back to the pre-refresh copy would silently delete that edit.
    @ObservationIgnored var userEditedDuringSensorRefresh = false
    @ObservationIgnored var isDeletingUserData = false
    @ObservationIgnored var dataDeletionGeneration =
        TaptionDataDeletionFence.currentGeneration()
    @ObservationIgnored var repositoryWriteTask: Task<Bool, Error>?
    @ObservationIgnored var repositoryWriteSequence: UInt64 = 0
    @ObservationIgnored var snapshotWriteLedger = SnapshotWriteLedger()
    @ObservationIgnored var lastPersistWasCancelled = false
    @ObservationIgnored var sensorTimelineTask: Task<Bool, Never>?
    @ObservationIgnored var sensorTimelineRequestID: UUID?
    @ObservationIgnored var sensorTimelineRequestKey: String?
    @ObservationIgnored var postSaveRefreshTask: Task<Void, Never>?
    @ObservationIgnored var postSaveRefreshRequested = false
    @ObservationIgnored var activeDataMutationCount = 0
    @ObservationIgnored var lastWatchHealthSnapshotCapturedAt: Date?
    @ObservationIgnored var lastWatchHealthSnapshotRawRetryAt: Date?
    @ObservationIgnored var lastWatchHealthSnapshotRawRetryFingerprint:
        String?
    @ObservationIgnored var lastWatchHealthSnapshotRawRetryAttemptAt:
        Date?
    @ObservationIgnored var isAppUsageRefreshRunning = false
    @ObservationIgnored var isHealthBackgroundDeliveryConfigured = false
    @ObservationIgnored var sensorAnalysisDebounceTask: Task<Void, Never>?
    @ObservationIgnored var sensorAnalysisTaskGeneration = 0
    @ObservationIgnored let sensorAnalysisDebounceDelay: Duration
    @ObservationIgnored var sensorAnalysisRequestRevision: UInt64 = 0
    @ObservationIgnored var pendingSensorAnalysisRevisions: [Date: UInt64] = [:]
    @ObservationIgnored var finalizedTrackingSessionIDs = Set<UUID>()
    @ObservationIgnored var latestWatchSummaryVersion:
        [UUID: WatchSummaryVersion] = [:]
    @ObservationIgnored var appliedWatchSummaryVersion:
        [UUID: WatchSummaryVersion] = [:]
    @ObservationIgnored var restoredWatchSummarySessions = Set<UUID>()
    @ObservationIgnored var finalizedWatchSummarySessionIDs = Set<UUID>()
    @ObservationIgnored var liveWeatherRefreshTask: Task<Void, Never>?
    @ObservationIgnored var lastLiveEnvironmentPoint: GeoPoint?
    @ObservationIgnored var lastLiveEnvironmentAt: Date?
    @ObservationIgnored var lastLiveEnvironmentFailureAt: Date?
    @ObservationIgnored var lastFutureWeatherRefreshAt: Date?
    @ObservationIgnored var lastFutureWeatherPoint: GeoPoint?
    @ObservationIgnored var weatherFixTask: Task<Void, Never>?
    @ObservationIgnored var lastWeatherFixAttemptAt: Date?
    @ObservationIgnored var lastTrackingSessionRecoveryPersistAt: Date?
    @ObservationIgnored var lastDeviceSnapshotPersistAt: Date?
    @ObservationIgnored var lastReviewArchiveRefreshAt: Date?
    @ObservationIgnored var lastReviewArchiveRefreshRevision: UInt64?
    @ObservationIgnored var pendingWatchActivitySuggestion:
        TaptionWatchActivitySuggestion?
    @ObservationIgnored var pendingDeviceLocalPersistTask: Task<Void, Never>?
    @ObservationIgnored var cloudSyncTask: Task<Void, Never>?
    @ObservationIgnored var liveMergeCacheKey: LiveMergeCacheKey?
    @ObservationIgnored var liveMergeCacheValue: [SensorReading] = []
    @ObservationIgnored var sensorRefreshFingerprints:
        [Date: SensorRefreshFingerprint] = [:]
    @ObservationIgnored var integrationRefreshGate =
        TimelineIntegrationRefreshGate()
    @ObservationIgnored var integrationRefreshSkipCount = 0
    @ObservationIgnored var lastIntegrationSkipLogUptime: TimeInterval = 0
    @ObservationIgnored var lastWidgetPayloadIdentity:
        TaptionWidgetPayload?
    @ObservationIgnored var lastWidgetPayloadInput: [Double]?
    @ObservationIgnored var lastWatchPayloadIdentity:
        TaptionWatchPayload?
    @ObservationIgnored var widgetPayloadSkipCount = 0
    @ObservationIgnored var watchPayloadSkipCount = 0
    @ObservationIgnored var lastWidgetSkipLogUptime: TimeInterval = 0
    @ObservationIgnored var lastWatchSkipLogUptime: TimeInterval = 0
    @ObservationIgnored let sensorBackgroundCoordinator =
        SensorBackgroundCoordinator.shared

    // Keep the live route bounded without shifting the whole array on every
    // GPS tick.  Trimming in batches makes long running sessions amortized
    // O(1) per append while preserving the same 4,000-point render limit.
    static let liveRouteHardLimit = 4_000
    static let liveRouteSoftLimit = 4_512

    nonisolated static let permissionOnboardingKey =
        "taption.permission-onboarding.v1"
    static let healthAuthorizationRequestedKey =
        "taption.health-authorization-requested.v1"
    static let healthPermissionReminderKey =
        "taption.health-permission-reminder.v1"
    static let watchDataSyncProfileConfiguredKey =
        "taption.watch-data-sync-profile-configured.v1"
    static let watchSummaryHighWaterKeyPrefix =
        "taption.watch-summary-high-water.v1."
    static let watchSummaryAppliedHighWaterKeyPrefix =
        "taption.watch-summary-applied-high-water.v1."
    static let permissionFlagsMigrationKey =
        "taption.permission-flags-sync.v2"
    static let calendarAutomaticRefreshKey =
        "taption.calendar-automatic-refresh.v1"
    static let diagnosticsLatestFileKey =
        "taption.diagnostics.latest.file.v1"
    static let diagnosticsLatestSavedAtKey =
        "taption.diagnostics.latest.saved-at.v1"

    @ObservationIgnored var watchHealthRefreshTask: Task<Void, Never>?

    /// 분류 파이프라인 재계산(날짜별 한 번, 표식은 앱 저장소 meta). 저장소를 주입한 시험에서는 nil이다.
    @ObservationIgnored var classificationRecompute: ClassificationRecomputeCoordinator?

    struct LiveMergeCacheKey: Equatable {
        let spanStart: TimeInterval
        let spanEnd: TimeInterval
        let archivedCount: Int
        let archivedFirstID: UUID?
        let archivedLastID: UUID?
        let archivedFirstTimestamp: Date?
        let archivedLastTimestamp: Date?
        let liveCount: Int
        let liveLastUpdatedAt: Date?
    }

    struct SensorRefreshFingerprint: Hashable {
        let readingCount: Int
        let latestReadingID: UUID?
        let latestMotionEnd: Date?
        let motionHash: Int
        let pedometerEnd: Date?
        let pedometerHash: Int?
        let latestHealthEvidenceEnd: Date?
        let healthEvidenceHash: Int
        let watchSummaryCount: Int
        let latestWatchSummaryEnd: Date?
        let watchAccelerationSampleCount: Int
        let latestWatchAccelerationSampleAt: Date?
        let transportEnrichmentModelVersion: Int
        let settingsHash: Int
    }

    init(
        repository: (any PlanDataRepository)? = nil,
        calendarService: AppleCalendarService? = nil,
        photoService: ApplePhotoLibraryService = ApplePhotoLibraryService(),
        healthService: AppleHealthService = .shared,
        sensorService: AppleSensorDataService? = nil,
        weatherService: AppleWeatherContextService =
            AppleWeatherContextService(),
        airQualityService: AirQualityContextService =
            AirQualityContextService(),
        cloudSyncService: CloudKitSnapshotSyncService? =
            CloudKitSnapshotSyncService.automatic(),
        placeNameResolver: PlaceNameResolver = PlaceNameResolver(),
        transportContextService: AppleTransportContextService? = nil,
        voiceMemoRecorder: VoiceMemoRecorder? = nil,
        voiceMemoPlayer: VoiceMemoPlayer? = nil,
        liveActivityController: TaptionLiveActivityController =
            TaptionLiveActivityController(),
        notificationScheduler: PlanNotificationScheduler =
            PlanNotificationScheduler(),
        watchConnectivityService: AppleWatchConnectivityService =
            AppleWatchConnectivityService(),
        airPodsActivityService: AirPodsActivityService =
            AirPodsActivityService(),
        screenTimeUsageService: ScreenTimeUsageService? = nil,
        securityService: PlanSecurityService? = nil,
        backupEngine: TaptionBackupEngine? = nil,
        rawDeviceDataArchive: RawDeviceDataDayArchive? = nil,
        appleWatchDataReceiptStore: AppleWatchDataReceiptStore =
            AppleWatchDataReceiptStore(),
        registersHealthBackgroundHandler: Bool = true,
        startsCommerceLocked: Bool = false,
        dayDatabase: PlanDayDatabase? = nil,
        sensorAnalysisDebounceDelay: Duration = .seconds(120)
    ) {
        isCommerceLocked = startsCommerceLocked
        self.sensorAnalysisDebounceDelay = sensorAnalysisDebounceDelay
        let repositorySource: String
        if let repository {
            self.repository = repository
            repositorySource = "injected"
        } else {
            let selection: PlanRepositorySelection
            if let store = try? TaptionStoreV2.applicationSupport() {
                selection = PlanRepositorySelection(
                    repository: TaptionStoreRepository(
                        store: store,
                        memoStore: try? TaptionStoreV2.applicationSupportMemos()
                    ),
                    source: "taption-store"
                )
            } else {
                selection = PlanRepositorySelection(
                    repository: UnavailablePlanRepository(),
                    source: "unavailable"
                )
            }
            self.repository = selection.repository
            repositorySource = selection.source
        }
        let protectionStore = try? BiometricProtectedSnapshotStore.applicationSupport()
        self.biometricProtectedSnapshotStore = protectionStore
        self.biometricDataProtectionStatus = protectionStore?.status ?? .unavailable
        let rawArchive = rawDeviceDataArchive
            ?? (try? RawDeviceDataDayArchive.applicationSupport())
        self.calendarService = calendarService ?? AppleCalendarService()
        self.photoService = photoService
        self.healthService = healthService
        if let sensorService {
            self.sensorService = sensorService
            self.sensorStorageErrorDescription = nil
        } else {
            do {
                self.sensorService = try AppleSensorDataService.applicationSupport()
                self.sensorStorageErrorDescription = nil
            } catch {
                self.sensorService = nil
                self.sensorStorageErrorDescription = error.localizedDescription
                TaptionPlanDiagnosticsLogger.shared.record(
                    "sensor_archive_initialization_failed",
                    level: .error,
                    fields: TaptionDiagnosticError.fields(for: error)
                )
            }
        }
        self.weatherService = weatherService
        self.airQualityService = airQualityService
        self.cloudSyncService = cloudSyncService
        self.securityService = securityService ?? PlanSecurityService()
        if let backupEngine {
            self.backupService = PlanBackupEngineAdapter(engine: backupEngine)
        } else if repository == nil, let store = try? TaptionStoreV2.applicationSupport() {
            self.backupService = PlanBackupEngineAdapter(
                engine: TaptionBackupEngine(
                    store: store,
                    memoStore: try? TaptionStoreV2.applicationSupportMemos(),
                    destination: TaptionICloudDriveBackupDestination()
                ))
        } else {
            self.backupService = nil
        }
        self.securityStatus = self.securityService?.status ?? PlanSecurityStatus(
            settings: PlanAppLockSettings(), state: .unlocked, hasPIN: false,
            failedAttempts: 0, retryAfter: nil,
            latestSuccessfulBackupDate: nil
        )
        self.placeNameResolver = placeNameResolver
        self.transportContextService = transportContextService
            ?? AppleTransportContextService()
        self.voiceMemoRecorder = voiceMemoRecorder ?? VoiceMemoRecorder()
        self.voiceMemoPlayer = voiceMemoPlayer ?? VoiceMemoPlayer()
        self.liveActivityController = liveActivityController
        self.notificationScheduler = notificationScheduler
        self.watchConnectivityService = watchConnectivityService
        self.appleWatchDataReceiptStore = appleWatchDataReceiptStore
        self.airPodsActivityService = airPodsActivityService
        self.screenTimeUsageService =
            screenTimeUsageService ?? ScreenTimeUsageService()
        self.appUsageAuthorizationState =
            self.screenTimeUsageService.authorizationState
        self.rawDeviceDataArchive = rawArchive
        let resolvedDayDatabase = dayDatabase
            ?? (try? PlanDayDatabase.applicationSupport())
        self.dayDatabase = resolvedDayDatabase
        self.dayLoadCoordinator = PlanDayLoadCoordinator()
        // 확정 요약은 본 저장소와 같은 파일에 둔다. 저장소를 주입받은 시험에서는 확정을 쓰지 않는다.
        self.daySealStore = repository == nil ? (try? TaptionStoreV2.applicationSupport()) : nil
        self.classificationRecompute = daySealStore.map {
            ClassificationRecomputeCoordinator(markers: StoreClassificationRecomputeMarkers(store: $0))
        }
        let watchReceipt = appleWatchDataReceiptStore.load()
        self.appleWatchLastDataReceivedAt = watchReceipt.latestDataAt
        self.appleWatchReceivedDataKinds = watchReceipt.recentKinds()
        Self.integrationLogger.notice(
            "Repository selected: \(repositorySource, privacy: .public)"
        )
        TaptionPlanDiagnosticsLogger.shared.record(
            "app_model_initialized",
            fields: ["repository": repositorySource]
        )
        self.voiceMemoPlayer.onFinish = { [weak self] in
            self?.playingVoiceAttachmentID = nil
        }
        self.sensorService?.onLiveReadingPreview = { [weak self] reading in
            Task { @MainActor [weak self] in
                self?.applyLiveReadingPreview(reading)
            }
        }
        self.sensorService?.onReadingsPersisted = { [weak self] readings in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let accepted = readings.filter {
                    self.acceptsDataMutation(capturedAt: $0.timestamp)
                }
                guard !accepted.isEmpty else { return }
                self.sensorStorageErrorDescription = nil
                self.invalidateRawDays(accepted.map(\.timestamp))
                self.handlePersistedSensorReadings(accepted)
            }
        }
        self.sensorService?.onPersistenceFailed = { [weak self] description in
            Task { @MainActor [weak self] in
                guard let self, self.acceptsDataMutation() else { return }
                self.sensorStorageErrorDescription = description
                self.isSensorCollecting = false
                self.sensorBackgroundCoordinator.endSession()
                self.syncSensorBackgroundState()
            }
        }
        self.watchConnectivityService.activate(
            onCommand: { [weak self] command in
                Task { @MainActor [weak self] in
                    await self?.applyWatchCommand(command)
                }
            },
            onSensorSummary: { [weak self] summary, receivedAt, requestID, deliveryID in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let persisted = await self.applyWatchSensorSummary(
                        summary,
                        receivedAt: receivedAt,
                        requestID: requestID
                    )
                    if persisted, let deliveryID {
                        self.watchConnectivityService
                            .acknowledgeAmbientDelivery(deliveryID)
                    }
                }
            },
            onAccelerationChunk: { [weak self] chunk, receivedAt, requestID, deliveryID in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let persisted = await self.applyWatchAccelerationChunk(
                        chunk,
                        receivedAt: receivedAt,
                        requestID: requestID
                    )
                    if persisted, let deliveryID {
                        self.watchConnectivityService
                            .acknowledgeAmbientDelivery(deliveryID)
                    }
                }
            },
            onHealthSnapshot: { [weak self] snapshot, receivedAt, requestID in
                Task { @MainActor [weak self] in
                    await self?.applyWatchHealthSnapshot(
                        snapshot,
                        receivedAt: receivedAt,
                        requestID: requestID
                    )
                }
            },
            onActivityConfirmation: { [weak self] confirmation, receivedAt in
                Task { @MainActor [weak self] in
                    await self?.applyWatchActivityConfirmation(
                        confirmation,
                        receivedAt: receivedAt
                    )
                }
            },
            // Watch settings are owned by the iPhone. Older Watch builds may
            // still send a location toggle; ignore it and restore the iPhone
            // value instead of letting the Watch mutate app settings.
            onLocationTracking: { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.acceptsDataMutation() else { return }
                    await self.bootstrap()
                    guard self.acceptsDataMutation() else { return }
                    self.publishWatchPayload()
                }
            },
            onStatusChange: { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.applyAppleWatchConnectionState(state)
                }
            },
            onDataSyncLiveFailure: { [weak self] requestID in
                Task { @MainActor [weak self] in
                    self?.applyAppleWatchDataSyncLiveFailure(
                        requestID: requestID
                    )
                }
            }
        )
        if registersHealthBackgroundHandler {
            Self.applicationInstance = self
            Task { [weak self] in
                await HealthBackgroundRefreshCoordinator.shared.register {
                    [weak self] in
                    guard let self else { return false }
                    await self.handleObservedHealthChange()
                    return true
                }
            }
        }
    }

    var showsBottomBar: Bool {
        true
    }

    var settings: AppFeatureSettings {
        snapshot.settings
    }

    /// 차량 오디오 기기 등록 목록을 바꾼다(CAR1029A01). 다음 이동 분류부터 반영된다.
    func updateCarAudioNames(registered: [String], recent: [String]) async {
        snapshot.settings.registeredCarAudioNames = registered
        snapshot.settings.recentCarAudioNames = recent
        await persist()
    }

    func refreshBiometricDataProtectionStatus() {
        biometricDataProtectionStatus = biometricProtectedSnapshotStore?.status
            ?? .unavailable
    }

    var isAppLocked: Bool {
        if case .locked = securityStatus.state { return true }
        return false
    }

    /// 이 기기에 보관된 6자리 비밀번호. 백업·복원·로컬 정리에 쓰며, 없으면 한 번 입력받는다.
    var rememberedBackupPassword: String? { securityService?.rememberedPassword }

    func configureBackupPIN(_ pin: String) throws {
        guard let securityService else { throw PlanSecurityError.invalidCredential }
        try securityService.setPIN(pin)
        securityStatus = securityService.status
    }

    func configureAppLock(_ settings: PlanAppLockSettings) throws {
        guard let securityService else { throw PlanSecurityError.invalidCredential }
        try securityService.setAppLockSettings(settings)
        securityStatus = securityService.status
        scheduleNearbyMemoSync()
        if !settings.lockOnLaunch && !settings.lockOnForeground {
            setExternalPrivacyLocked(false)
        }
    }

    func unlockApp(withPIN pin: String) throws {
        guard let securityService else { throw PlanSecurityError.invalidCredential }
        defer { securityStatus = securityService.status }
        try securityService.unlock(withPIN: pin)
        setExternalPrivacyLocked(false)
        scheduleWatchHealthRefresh()
    }

    func unlockAppWithBiometrics() async throws {
        guard let securityService else { throw PlanSecurityError.biometricUnavailable }
        try await securityService.unlockWithBiometrics()
        securityStatus = securityService.status
        setExternalPrivacyLocked(false)
        scheduleWatchHealthRefresh()
    }

    #if DEBUG
    @ObservationIgnored private var hasRunCurrentIslandVerification = false

    func recordRequestedCurrentIslandVerification() {
#if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--verify-current-island"),
              !hasRunCurrentIslandVerification, !isAppLocked,
              let reading = latestSensorReading else { return }
        let projection = currentLiveActivityProjection()
        let published = Activity<SensorCollectionActivityAttributes>.activities.first {
            $0.attributes.sessionID == sensorCollectionSessionID
        }?.content.state
        let action = TaptionLiveActivityCatPolicy.action(categoryID: projection.categoryID, title: projection.title)
        let bitmap = TaptionCatAtlasBitmap.image(style: settings.catStyle.rawValue, action: action, frame: published?.currentActivityFrame ?? 0)
        let report: [String: Any] = [
            "projectionCategoryID": projection.categoryID,
            "publishedCategoryID": published?.currentActivityCategoryID ?? "none",
            "publishedMatchesProjection": published?.currentActivityCategoryID == projection.categoryID,
            "latestMotion": reading.motion.rawValue,
            "motionConfidence": reading.motionConfidence.rawValue,
            "sampleAgeSeconds": Date.now.timeIntervalSince(reading.timestamp),
            "appBitmapAvailable": bitmap != nil,
            "bitmapWidth": bitmap?.size.width ?? 0,
            "bitmapHeight": bitmap?.size.height ?? 0,
            "frame": published?.currentActivityFrame ?? 0,
        ]
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TaptionPlanIslandVerification", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("DYN1001B01-\(UUID().uuidString).json"), options: .atomic)
            hasRunCurrentIslandVerification = true
        } catch {
            Self.integrationLogger.error("Island verification metadata write failed")
        }
#endif
    }

    #endif
}
