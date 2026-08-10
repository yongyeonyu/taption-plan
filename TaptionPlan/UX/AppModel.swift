import Foundation
import CoreLocation
import Observation
import OSLog
import UIKit
import WidgetKit

@MainActor
@Observable
final class AppModel {
    private static let integrationLogger = Logger(
        subsystem: "com.taption.plan",
        category: "AutomaticRecords"
    )

    var selectedTab: RootTab = .schedule
    var selectedScale: TimeScale = .day
    var selectedDate: Date = .now
    var isAddPlanPresented = false
    var addPlanContext: AddPlanContext = .quick
    var selectedAction: QuickActionItem?
    var planEditorRequest: PlanEditorRequest?
    var selectedPhotoCluster: PhotoCluster?
    var detail: AppDetail?
    var selectedGroupPlanID: UUID?
    var selectedGoalPlanID: UUID?
    var groupNavigationPath: [UUID] = []
    /// 메모 입력은 항목을 먼저 고르지 않는다. 시간표 메모 줄에서 바로 열리며,
    /// 새 메모가 놓일 순간과 그 자리에 이미 있던 메모만 들고 있으면 된다.
    private(set) var memoEntry: MemoEntry?
    var selectedCatCoat: CatCoat = .calico
    /// 기록 탭도 시간표와 같은 배율(일·주·월·년)을 쓴다.
    var reviewScale: TimeScale = .week
    var isPermissionOnboardingPresented = false
    private(set) var permissionOnboardingStartFeature: PermissionFeature?
    private(set) var pendingSetupCategoryIDs: Set<String> = []
    private(set) var isEditingSetupCategories = false

    private(set) var snapshot: TaptionDataSnapshot = .empty {
        didSet {
            snapshotRevision &+= 1

            // Device snapshots are frequent. Keep a separate revision for
            // changes that alter rows, blocks or their detail targets so the
            // Gantt layout cache survives ordinary live collection.
            let timestampOnly = timestampOnlySnapshotAssignment
            timestampOnlySnapshotAssignment = false
            if !timestampOnly
                && (oldValue.weather != snapshot.weather
                    || oldValue.plans != snapshot.plans
                    || oldValue.actuals != snapshot.actuals
                    || oldValue.travel != snapshot.travel
                    || oldValue.places != snapshot.places
                    || oldValue.calendarEvents != snapshot.calendarEvents
                    || oldValue.photos != snapshot.photos
                    || oldValue.categories != snapshot.categories
                    || oldValue.recordLinks != snapshot.recordLinks
                    || oldValue.memos != snapshot.memos
                    || oldValue.settings.timelineRowOrder
                        != snapshot.settings.timelineRowOrder) {
                timelineRevision &+= 1
            }
        }
    }
    @ObservationIgnored private(set) var snapshotRevision: UInt64 = 0
    @ObservationIgnored private(set) var timelineRevision: UInt64 = 0
    @ObservationIgnored private var timestampOnlySnapshotAssignment = false
    private(set) var isBootstrapped = false
    /// 저장소를 읽지 못한 상태에서 빈 스냅샷을 저장하면 기존 기록을
    /// 덮어쓸 수 있다. 복구 가능한 저장본을 다시 읽기 전까지 저장을 막는다.
    @ObservationIgnored private var repositoryLoadFailed = false
    private(set) var isRefreshingIntegrations = false
    private(set) var isSensorCollecting = false
    private(set) var isCloudSyncing = false
    private(set) var isExportingDiagnostics = false
    private(set) var diagnosticsExportStatus = "준비됨"
    private(set) var cloudUnavailableReason: CloudUnavailableReason?
    private(set) var isRecordingVoiceMemo = false
    private(set) var playingVoiceAttachmentID: UUID?
    private(set) var isStoreLoading = false
    private(set) var hasProAccess = false
    private(set) var proProduct: StoreProductPresentation?
    private(set) var storeStatusMessage = "App Store 확인 중"
    private(set) var sensorAvailability: SensorHardwareAvailability?
    private(set) var latestSensorReading: SensorReading?
    private(set) var liveRouteState: LiveRouteState = .empty
    private(set) var activeTrackingSession: TrackingSession?
    private(set) var trackingSessionWasRecovered = false
    private(set) var latestAltitudeEstimate: CalibratedAltitudeEstimate?
    private(set) var floorCalibrationNotice: String? = nil
    /// 층 보정 표본을 모으는 중일 때만 값이 있다. 화면은 이 값으로 진행을
    /// 보여 주고, 끝나기 전에는 아무것도 기록되지 않는다.
    private(set) var floorCalibrationSampling: FloorCalibrationSampling?
    private(set) var watchLaunchReport: (report: String, receivedAt: Date)?
    /// 등록하지 않았는데 자주 간 자리 하나. 설정 화면을 열 때만 다시 구하고,
    /// 한 번에 하나만 보여 준다.
    private(set) var frequentPlaceSuggestion: FrequentPlaceSuggestion?
    private(set) var sleepSessions: [SleepSession] = []
    private(set) var lastHealthRefreshAt: Date?
    private(set) var appleWatchConnectionState: AppleWatchConnectionState = .unsupported
    /// 첫 실행 안내를 닫은 기록. 기기 저장소에서 읽어 오고, 바뀔 때만 다시
    /// 넣어 화면이 갱신되게 한다.
    private(set) var dismissedAppleWatchPrompts: Set<AppleWatchOnboardingPrompt> =
        AppleWatchOnboardingStore().dismissed
    private(set) var hasSeenWatchAppInstalled =
        AppleWatchOnboardingStore().hasSeenWatchAppInstalled
    @ObservationIgnored
    private let watchOnboardingStore = AppleWatchOnboardingStore()
    private(set) var appUsageAuthorizationState: ScreenTimeAuthorizationState = .unavailable
    private(set) var lastAppUsageRefreshAt: Date?
    private(set) var appUsageRecordCount = 0
    private(set) var appUsageTotalDuration: TimeInterval = 0
    /// 기록 ID → 앱 토큰. 스크린 타임 데이터는 민감하므로 저장하지 않고
    /// 새로 고칠 때마다 메모리에만 채운다.
    private(set) var appUsageTokenIndex: [UUID: Data] = [:]
    var userFacingError: String?
    @ObservationIgnored private var lastAutoFloorCalibrationKey: String? = nil
    @ObservationIgnored private var altitudeSpikeGate = AltitudeSpikeGate()
    @ObservationIgnored private var altitudeGatePlaceID: UUID? = nil
    @ObservationIgnored private var calibrationNoticeTask: Task<Void, Never>?

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

    var appUsageStatusText: String {
        guard appUsageAuthorizationState == .approved else {
            return appUsageAuthorizationState.displayName
        }
        guard lastAppUsageRefreshAt != nil else { return "동기화 대기" }
        guard let total = ScreenTimeUsageRecordEngine
            .durationText(appUsageTotalDuration) else {
            return "오늘 기록 없음"
        }
        return "오늘 \(total) · \(appUsageRecordCount)개"
    }

    var cloudStatusText: String {
        if isCloudSyncing { return "동기화 중" }
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
            missing.append("위치·이동")
        }
        if !settings.healthEnabled { missing.append("건강·Apple Watch") }
        if settings.selectedCalendarIDs.isEmpty { missing.append("캘린더") }
        if !settings.showsPhotos { missing.append("사진") }
        if appUsageAuthorizationState != .approved {
            missing.append("앱 사용시간")
        }
        return missing.isEmpty ? nil : missing
    }

    @ObservationIgnored private let repository: any PlanDataRepository
    @ObservationIgnored private let calendarService: AppleCalendarService
    @ObservationIgnored private let photoService: ApplePhotoLibraryService
    @ObservationIgnored private let healthService: AppleHealthService
    @ObservationIgnored private let sensorService: AppleSensorDataService?
    @ObservationIgnored private let weatherService: AppleWeatherContextService
    @ObservationIgnored private let airQualityService: AirQualityContextService
    @ObservationIgnored private let cloudSyncService: CloudKitSnapshotSyncService?
    @ObservationIgnored private let placeNameResolver: PlaceNameResolver
    @ObservationIgnored private let transportContextService:
        AppleTransportContextService
    @ObservationIgnored private let voiceMemoRecorder: VoiceMemoRecorder
    @ObservationIgnored private let voiceMemoPlayer: VoiceMemoPlayer
    @ObservationIgnored private let liveActivityController: TaptionLiveActivityController
    @ObservationIgnored private let notificationScheduler: PlanNotificationScheduler
    @ObservationIgnored private let purchaseService: StoreKitPurchaseService
    @ObservationIgnored private let watchConnectivityService: AppleWatchConnectivityService
    @ObservationIgnored private let airPodsActivityService: AirPodsActivityService
    @ObservationIgnored private let screenTimeUsageService: ScreenTimeUsageService
    @ObservationIgnored private let watchSensorArchive:
        AppleWatchSensorActivityArchive?
    @ObservationIgnored private let rawDeviceDataArchive:
        RawDeviceDataMonthlyArchive?
    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored private var bootstrapPreparationTask: Task<Void, Never>?
    @ObservationIgnored private var foregroundRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var deferredVisibleRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var lastForegroundRefreshAt: Date?
    @ObservationIgnored private var foregroundHealthRefreshTask:
        Task<Void, Never>?
    @ObservationIgnored private var widgetReloadFollowupTask:
        Task<Void, Never>?
    @ObservationIgnored private var isSceneActive = false
    @ObservationIgnored private var isHealthRefreshRunning = false
    @ObservationIgnored private var isAppUsageRefreshRunning = false
    @ObservationIgnored private var isHealthBackgroundDeliveryConfigured = false
    @ObservationIgnored private var sensorAnalysisDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var finalizedTrackingSessionIDs = Set<UUID>()
    @ObservationIgnored private var liveWeatherRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var lastLiveEnvironmentPoint: GeoPoint?
    @ObservationIgnored private var lastLiveEnvironmentAt: Date?
    @ObservationIgnored private var lastLiveEnvironmentFailureAt: Date?
    @ObservationIgnored private var lastTrackingSessionRecoveryPersistAt: Date?
    @ObservationIgnored private var lastDeviceSnapshotPersistAt: Date?
    @ObservationIgnored private var lastReviewArchiveRefreshAt: Date?
    @ObservationIgnored private var pendingWatchActivitySuggestion:
        TaptionWatchActivitySuggestion?
    @ObservationIgnored private var pendingDeviceLocalPersistTask: Task<Void, Never>?
    @ObservationIgnored private var liveMergeCacheKey: LiveMergeCacheKey?
    @ObservationIgnored private var liveMergeCacheValue: [SensorReading] = []
    @ObservationIgnored private var sensorRefreshFingerprints:
        [Date: SensorRefreshFingerprint] = [:]

    // Keep the live route bounded without shifting the whole array on every
    // GPS tick.  Trimming in batches makes long running sessions amortized
    // O(1) per append while preserving the same 4,000-point render limit.
    private static let liveRouteHardLimit = 4_000
    private static let liveRouteSoftLimit = 4_512

    private static let permissionOnboardingKey =
        "taption.permission-onboarding.v1"
    private static let permissionFlagsMigrationKey =
        "taption.permission-flags-sync.v2"

    private struct LiveMergeCacheKey: Equatable {
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

    private struct SensorRefreshFingerprint: Hashable {
        let readingCount: Int
        let latestReadingID: UUID?
        let latestMotionEnd: Date?
        let pedometerEnd: Date?
        let latestHealthEvidenceEnd: Date?
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
        transportContextService: AppleTransportContextService =
            AppleTransportContextService(),
        voiceMemoRecorder: VoiceMemoRecorder? = nil,
        voiceMemoPlayer: VoiceMemoPlayer? = nil,
        liveActivityController: TaptionLiveActivityController =
            TaptionLiveActivityController(),
        notificationScheduler: PlanNotificationScheduler =
            PlanNotificationScheduler(),
        purchaseService: StoreKitPurchaseService =
            StoreKitPurchaseService(),
        watchConnectivityService: AppleWatchConnectivityService =
            AppleWatchConnectivityService(),
        airPodsActivityService: AirPodsActivityService =
            AirPodsActivityService(),
        screenTimeUsageService: ScreenTimeUsageService? = nil
    ) {
        let repositorySource: String
        if let repository {
            self.repository = repository
            repositorySource = "injected"
        } else if let sharedRepository = try? FilePlanRepository.appGroup(),
                  let legacyRepository =
                    try? FilePlanRepository.applicationSupport() {
            self.repository = MigratingPlanRepository(
                primary: sharedRepository,
                legacy: legacyRepository
            )
            repositorySource = "app-group+migration"
        } else if let sharedRepository =
                    try? FilePlanRepository.appGroup() {
            self.repository = sharedRepository
            repositorySource = "app-group"
        } else if let fileRepository = try? FilePlanRepository.applicationSupport() {
            self.repository = fileRepository
            repositorySource = "application-support"
        } else {
            self.repository = InMemoryPlanRepository()
            repositorySource = "in-memory"
        }
        let rawArchive = try? RawDeviceDataMonthlyArchive.applicationSupport()
        self.calendarService = calendarService ?? AppleCalendarService()
        self.photoService = photoService
        self.healthService = healthService
        self.sensorService = sensorService
            ?? (try? AppleSensorDataService.applicationSupport(
                rawArchive: rawArchive
            ))
        self.weatherService = weatherService
        self.airQualityService = airQualityService
        self.cloudSyncService = cloudSyncService
        self.placeNameResolver = placeNameResolver
        self.transportContextService = transportContextService
        self.voiceMemoRecorder = voiceMemoRecorder ?? VoiceMemoRecorder()
        self.voiceMemoPlayer = voiceMemoPlayer ?? VoiceMemoPlayer()
        self.liveActivityController = liveActivityController
        self.notificationScheduler = notificationScheduler
        self.purchaseService = purchaseService
        self.watchConnectivityService = watchConnectivityService
        self.airPodsActivityService = airPodsActivityService
        self.screenTimeUsageService =
            screenTimeUsageService ?? ScreenTimeUsageService()
        self.appUsageAuthorizationState =
            self.screenTimeUsageService.authorizationState
        self.watchSensorArchive = try?
            AppleWatchSensorActivityArchive.applicationSupport()
        self.rawDeviceDataArchive = rawArchive
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
        self.sensorService?.onReadingPersisted = { [weak self] reading in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleLiveSensorReading(reading)
            }
        }
        self.watchConnectivityService.activate(
            onCommand: { [weak self] command in
                Task { @MainActor [weak self] in
                    await self?.applyWatchCommand(command)
                }
            },
            onSensorSummary: { [weak self] summary in
                Task { @MainActor [weak self] in
                    await self?.applyWatchSensorSummary(summary)
                }
            },
            onHealthSnapshot: { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    await self?.applyWatchHealthSnapshot(snapshot)
                }
            },
            onActivityConfirmation: { [weak self] confirmation in
                Task { @MainActor [weak self] in
                    await self?.applyWatchActivityConfirmation(confirmation)
                }
            },
            // Watch settings are owned by the iPhone. Older Watch builds may
            // still send a location toggle; ignore it and restore the iPhone
            // value instead of letting the Watch mutate app settings.
            onLocationTracking: { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.bootstrap()
                    self.publishWatchPayload()
                }
            },
            onStatusChange: { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.applyAppleWatchConnectionState(state)
                }
            }
        )
        Task { [weak self] in
            await HealthBackgroundRefreshCoordinator.shared.register {
                [weak self] in
                await self?.handleObservedHealthChange()
            }
        }
    }

    var showsBottomBar: Bool {
        true
    }

    var settings: AppFeatureSettings {
        snapshot.settings
    }

    /// 자동 기록의 원본은 보존하고, 시간표와 상세 화면에 표시할 활동만
    /// 사용자가 교정한다. 교정표는 기록 ID로 저장되어 다음 센서 갱신에도
    /// 같은 결과를 복원한다.
    func updateActualActivity(
        _ actualID: UUID,
        with option: ActivityCorrectionOption
    ) async {
        guard snapshot.actuals.contains(where: { $0.id == actualID }) else {
            return
        }
        snapshot.settings.activityCorrections[actualID] = option.correction
        if option.isCustom {
            snapshot.settings.customActivityLabels =
                AppFeatureSettings.normalizedActivityLabels(
                    snapshot.settings.customActivityLabels + [option.title]
                )
        }
        snapshot.actuals = ActivityCorrectionEngine.applying(
            snapshot.settings.activityCorrections,
            to: snapshot.actuals
        )
        snapshot.actuals.sort { $0.startedAt < $1.startedAt }
        await persist()
    }

    /// 자동 기록의 센서 원본은 그대로 두고, 화면에 표시할 시간만 조정한다.
    func updateActualSpan(
        _ actualID: UUID,
        startAt: Date,
        endAt: Date
    ) async {
        guard endAt > startAt,
              let actual = snapshot.actuals.first(where: { $0.id == actualID })
        else { return }

        var correction = snapshot.settings.activityCorrections[actualID]
            ?? ActivityCorrection(
                title: actual.title,
                behavior: actual.behavior,
                categoryID: actual.categoryID
            )
        correction.startedAt = startAt
        correction.endedAt = endAt
        snapshot.settings.activityCorrections[actualID] = correction
        snapshot.actuals = ActivityCorrectionEngine.applying(
            snapshot.settings.activityCorrections,
            to: snapshot.actuals
        )
        snapshot.actuals.sort { $0.startedAt < $1.startedAt }
        await persist()
    }

    /// 화면에서만 채워졌던 미확인 구간을 사용자가 결정한 파생 기록으로 남긴다.
    /// 센서·HealthKit 원본은 수정하거나 삭제하지 않는다.
    func classifyUnconfirmedSpan(
        _ span: TimeSpan,
        with option: ActivityCorrectionOption
    ) async {
        guard span.duration > 0 else { return }
        let alreadySaved = snapshot.actuals.contains { actual in
            actual.source == .manual
                && actual.manuallyCorrected
                && actual.title == option.title
                && actual.categoryID == option.categoryID
                && actual.behavior == option.behavior
                && actual.startedAt == span.start
                && actual.endedAt == span.end
        }
        guard !alreadySaved else { return }
        if option.isCustom {
            snapshot.settings.customActivityLabels =
                AppFeatureSettings.normalizedActivityLabels(
                    snapshot.settings.customActivityLabels + [option.title]
                )
        }
        snapshot.actuals.append(
            ActualRecord(
                planID: nil,
                title: option.title,
                categoryID: option.categoryID,
                startedAt: span.start,
                endedAt: span.end,
                source: .manual,
                confidence: .high,
                behavior: option.behavior,
                evidence: ["사용자가 미확인 구간을 분류함"],
                modelVersion: "manual-gap-classification-v1",
                manuallyCorrected: true
            )
        )
        snapshot.actuals.sort { $0.startedAt < $1.startedAt }
        await persist()
    }

    private func applyStoredActivityCorrections() {
        let corrected = ActivityCorrectionEngine.applying(
            snapshot.settings.activityCorrections,
            to: snapshot.actuals
        )
        guard corrected != snapshot.actuals else { return }
        snapshot.actuals = corrected
    }

    var currentAltitudeStatus: String? {
        guard let estimate = latestAltitudeEstimate else { return nil }
        return "\(estimate.floor)층 추정 · 해발 \(Int(estimate.seaLevelAltitudeMeters.rounded()))m · ±\(Int(estimate.verticalAccuracyMeters.rounded()))m"
    }

    var canShiftToPreviousPeriod: Bool {
        canShiftSelectedDate(by: -1)
    }

    var canShiftToNextPeriod: Bool {
        canShiftSelectedDate(by: 1)
    }

    var integrationStatusSummary: String {
        if isRefreshingIntegrations {
            return "연동 확인 중"
        }
        let enabled = [
            settings.showsPhotos
                && permissionState(for: .photos).isGranted,
            !settings.selectedCalendarIDs.isEmpty
                && permissionState(for: .calendar).isGranted,
            settings.healthEnabled,
            settings.locationEnabled,
        ].filter { $0 }.count
        return enabled == 0 ? "기기 안에 안전하게 저장" : "연동 \(enabled)개 사용 중"
    }

    var appleWatchIntegrationSummary: String {
        let deviceRecords = snapshot.actuals.filter {
            $0.source == .healthKit || $0.source == .appleWatch
        }
        let health = settings.healthEnabled
            ? "건강 기록 \(deviceRecords.count)건 · 5분 갱신"
            : "건강 연결 꺼짐"
        return "\(appleWatchConnectionState.settingsLabel) · \(health)"
    }

    func selectTab(_ tab: RootTab) {
        if TaptionProductScope.automaticLoggingOnly, tab == .goals {
            selectedTab = .schedule
            detail = nil
            groupNavigationPath = []
            return
        }
        if tab == .review, reviewScale != .day {
            reviewScale = .day
        }
        selectedTab = tab
        detail = nil
        groupNavigationPath = []
        if tab == .schedule || tab == .review {
            Task { await refreshConnectedRecordsNow() }
        }
    }

    func openGroup(_ planID: UUID) {
        if groupNavigationPath.last != planID {
            if let current = groupNavigationPath.last,
               snapshot.plans.contains(where: {
                   $0.id == planID && $0.parentID == current
               }) {
                groupNavigationPath.append(planID)
            } else {
                groupNavigationPath = [planID]
            }
        }
        selectedGroupPlanID = planID
        detail = .group
    }

    func openGoalDetail(_ planID: UUID) {
        guard snapshot.plans.contains(where: { $0.id == planID }) else { return }
        selectedGoalPlanID = planID
        selectedGroupPlanID = nil
        groupNavigationPath = []
        detail = .goal
    }

    func closeGoalDetail() {
        selectedGoalPlanID = nil
        detail = nil
    }

    func closeCurrentGroup() {
        if groupNavigationPath.count > 1 {
            groupNavigationPath.removeLast()
            selectedGroupPlanID = groupNavigationPath.last
            detail = .group
        } else {
            groupNavigationPath = []
            selectedGroupPlanID = nil
            detail = nil
        }
    }

    func selectScale(_ scale: TimeScale) {
        guard selectedScale != scale else { return }
        selectedScale = scale
        if settings.rememberLastScale {
            snapshot.settings.startScale = scale.timelineLevel
        }
        Task {
            await refreshEnabledData(persistDeviceSnapshot: false)
            if settings.rememberLastScale {
                await persist()
            }
        }
    }

    func shiftSelectedDate(by direction: Int) {
        guard canShiftSelectedDate(by: direction),
              let targetDate = TimelinePeriodNavigationEngine()
                .adjacentDate(
                    from: selectedDate,
                    level: selectedScale.timelineLevel,
                    direction: direction
                ) else {
            return
        }
        selectedDate = targetDate
        Task { await refreshEnabledData() }
    }

    /// 기록 탭은 시간표와 배율이 따로다. 원형 시간표를 옆으로 넘길 때는
    /// 기록 배율을 쓰되 데이터 경계는 시간표와 똑같이 지킨다.
    func shiftReviewDate(by direction: Int) {
        let navigation = TimelinePeriodNavigationEngine()
        let level = reviewScale.timelineLevel
        guard navigation.canNavigate(
            from: selectedDate,
            level: level,
            direction: direction,
            snapshot: snapshot
        ),
            let targetDate = navigation.adjacentDate(
                from: selectedDate,
                level: level,
                direction: direction
            ) else {
            return
        }
        selectedDate = targetDate
        Task { await refreshEnabledData() }
    }

    private func canShiftSelectedDate(by direction: Int) -> Bool {
        TimelinePeriodNavigationEngine().canNavigate(
            from: selectedDate,
            level: selectedScale.timelineLevel,
            direction: direction,
            snapshot: snapshot
        )
    }

    func returnToNow() {
        selectedDate = .now
        Task { await refreshEnabledData() }
    }

    func openDeepLink(_ url: URL) async {
        guard let link = TaptionDeepLink(url: url) else { return }
        switch link {
        case .today:
            selectedTab = .schedule
            selectedScale = .day
            selectedDate = .now
            detail = nil
            return
        case .catPicker:
            selectedTab = .settings
            detail = .catPicker
            return
        case .plan(let planID):
            guard let plan = await planForDeepLink(planID) else {
                selectedTab = .schedule
                selectedScale = .day
                selectedDate = .now
                detail = nil
                selectedAction = nil
                publishWidgetPayload()
                return
            }

            selectedTab = .schedule
            selectedScale = .day
            selectedDate = plan.span.start
            detail = nil
            selectedAction = QuickActionItem(
                planID: plan.id,
                title: plan.title,
                time:
                    "\(plan.span.start.formatted(date: .omitted, time: .shortened)) → "
                    + plan.span.end.formatted(date: .omitted, time: .shortened),
                context: "계획 \(Int(plan.span.duration / 60))분"
            )
        }
    }

    private func planForDeepLink(_ planID: UUID) async -> PlanRecord? {
        if let plan = snapshot.plans.first(where: { $0.id == planID }) {
            return plan
        }
        await applyPendingWidgetCommands(repositoryAlreadyLoaded: false)
        if let plan = snapshot.plans.first(where: { $0.id == planID }) {
            return plan
        }
        guard var loaded = try? await repository.load() else {
            return nil
        }
        loaded = Self.preparedLoadedSnapshot(loaded)
        snapshot = loaded
        publishWidgetPayload()
        return snapshot.plans.first { $0.id == planID }
    }

    private nonisolated static func preparedLoadedSnapshot(
        _ source: TaptionDataSnapshot
    ) -> TaptionDataSnapshot {
        var loaded = source
        loaded.plans = Self.deduplicatedGeneratedRepeatPlans(loaded.plans)
        if loaded.categories.isEmpty {
            loaded.categories = CategoryCatalog.builtIn
        } else {
            for category in CategoryCatalog.builtIn
            where !loaded.categories.contains(where: {
                $0.id == category.id
            }) {
                loaded.categories.append(category)
            }
        }
        Self.migrateLegacyFloorCalibration(in: &loaded)
        MemoShellPlanMigration.apply(to: &loaded)
        Self.normalizeRecordRelationships(in: &loaded)
        loaded.actuals = ActualRecordSuppressionEngine.visibleRecords(
            from: loaded.actuals,
            suppressedIDs: loaded.settings.suppressedActualIDs
        )
        loaded.actuals = ActivityCorrectionEngine.applying(
            loaded.settings.activityCorrections,
            to: loaded.actuals
        )
        loaded.weather = WeatherTimelineEngine.coalesced(loaded.weather)
        return loaded
    }

    /// A repeat rule is materialized as one child plan per matching day. If
    /// an older build saved the same generated child twice, keep the first
    /// record and remove only the exact generated duplicate. User-created
    /// overlapping plans remain untouched and continue to be shown separately.
    private nonisolated static func deduplicatedGeneratedRepeatPlans(
        _ plans: [PlanRecord]
    ) -> [PlanRecord] {
        var seen = Set<String>()
        return plans.filter { plan in
            guard plan.origin == .repeatRule else { return true }
            let key = [
                plan.parentID?.uuidString ?? "-",
                plan.categoryID,
                String(Int(plan.span.start.timeIntervalSinceReferenceDate.rounded())),
                String(Int(plan.span.end.timeIntervalSinceReferenceDate.rounded())),
            ].joined(separator: "|")
            return seen.insert(key).inserted
        }
    }

    /// Converts legacy action/routine pointers into the canonical relation
    /// rules used by the timeline graph. Repeat segments are projections of a
    /// root routine and therefore never remain as direct automatic links.
    private nonisolated static func normalizeRecordRelationships(
        in snapshot: inout TaptionDataSnapshot
    ) {
        let plansByID = Dictionary(
            snapshot.plans.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        func rootRoutineID(for id: UUID) -> UUID? {
            var currentID: UUID? = id
            var visited = Set<UUID>()
            while let current = currentID,
                  visited.insert(current).inserted,
                  let plan = plansByID[current] {
                if GoalRecordPolicy.isGoal(plan) { return plan.id }
                currentID = plan.parentID
            }
            return nil
        }

        for index in snapshot.actuals.indices {
            var actual = snapshot.actuals[index]
            let linkedPlan = actual.planID.flatMap { plansByID[$0] }
            let linkedRoutine = actual.routineID.flatMap(rootRoutineID)
            if AutomaticRecordTimelineEngine.linksOnlyToRoutine(actual) {
                actual.routineID = linkedRoutine
                    ?? linkedPlan.flatMap { rootRoutineID(for: $0.id) }
                actual.planID = nil
            } else if let linkedPlan {
                if linkedPlan.origin == .repeatRule
                    || GoalRecordPolicy.isGoal(linkedPlan) {
                    actual.routineID = linkedRoutine
                        ?? rootRoutineID(for: linkedPlan.id)
                    actual.planID = nil
                } else {
                    actual.planID = linkedPlan.id
                    actual.routineID = linkedRoutine
                        ?? rootRoutineID(for: linkedPlan.id)
                }
            } else {
                actual.planID = nil
                actual.routineID = linkedRoutine
            }
            snapshot.actuals[index] = actual
        }

        func canonicalNodeID(_ raw: String) -> String? {
            let prefixes = ["routine.", "action."]
            guard let prefix = prefixes.first(where: { raw.hasPrefix($0) }) else {
                return raw.hasPrefix("automatic.") ? raw : nil
            }
            guard let id = UUID(uuidString: String(raw.dropFirst(prefix.count))),
                  let plan = plansByID[id] else {
                return nil
            }
            if GoalRecordPolicy.isGoal(plan) || plan.origin == .repeatRule,
               let root = rootRoutineID(for: plan.id) {
                return "routine.\(root.uuidString)"
            }
            return "action.\(id.uuidString)"
        }

        var seen = Set<String>()
        snapshot.recordLinks = snapshot.recordLinks
            .sorted { $0.createdAt < $1.createdAt }
            .compactMap { link in
                guard let from = canonicalNodeID(link.fromNodeID),
                      let to = canonicalNodeID(link.toNodeID),
                      from != to else { return nil }
                let key = "\(from)->\(to)"
                guard seen.insert(key).inserted else { return nil }
                var normalized = link
                normalized.fromNodeID = from
                normalized.toNodeID = to
                return normalized
            }
    }

    func bootstrap() async {
        guard !isBootstrapped else {
            return
        }
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }

        TaptionPlanDiagnosticsLogger.shared.record("bootstrap_started")
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                var source = try await repository.load()
                repositoryLoadFailed = false
                source.weather = WeatherTimelineEngine.coalesced(source.weather)
                source.actuals = ActivityCorrectionEngine.applying(
                    source.settings.activityCorrections,
                    to: source.actuals
                )
                // Publish the local snapshot first. Normalizing historical
                // records and loading device integrations can be expensive;
                // neither should hold the first timeline frame hostage.
                snapshot = source
                selectedScale = TimeScale(timelineLevel: source.settings.startScale)
                selectedCatCoat = CatCoat(catStyle: source.settings.catStyle)
                if source.updatedAt == .distantPast,
                   source.plans.isEmpty {
                    openInitialSetup()
                }
                isBootstrapped = true
                publishWatchPayload()
                TaptionPlanDiagnosticsLogger.shared.record(
                    "bootstrap_local_snapshot_loaded",
                    fields: [
                        "plans": String(source.plans.count),
                        "actuals": String(source.actuals.count),
                        "places": String(source.places.count),
                    ]
                )
                scheduleBootstrapPreparation()
            } catch {
                repositoryLoadFailed = true
                var fallback = TaptionDataSnapshot.empty
                fallback.categories = CategoryCatalog.builtIn
                snapshot = fallback
                isBootstrapped = true
                userFacingError = "저장된 데이터를 불러오지 못했습니다. \(error.localizedDescription)"
                TaptionPlanDiagnosticsLogger.shared.record(
                    "bootstrap_failed",
                    level: .error,
                    fields: ["error": String(describing: type(of: error))]
                )
            }
            bootstrapTask = nil
        }
        bootstrapTask = task
        await task.value
    }

    private func scheduleBootstrapPreparation() {
        guard bootstrapPreparationTask == nil else { return }
        bootstrapPreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Give SwiftUI a complete frame before touching the full record
            // graph. This is intentionally a yield, not a fixed sleep.
            await Task.yield()
            guard !Task.isCancelled else {
                self.bootstrapPreparationTask = nil
                return
            }
            let source = snapshot
            let loaded = await Task.detached(priority: .utility) {
                Self.preparedLoadedSnapshot(source)
            }.value
            guard !Task.isCancelled else {
                self.bootstrapPreparationTask = nil
                return
            }
            snapshot = loaded
            selectedScale = TimeScale(timelineLevel: loaded.settings.startScale)
            selectedCatCoat = CatCoat(catStyle: loaded.settings.catStyle)
            await applyPendingWidgetCommands(repositoryAlreadyLoaded: true)
            bootstrapPreparationTask = nil
        }
    }

    private func waitForBootstrapPreparation() async {
        await bootstrapPreparationTask?.value
    }

    func sceneBecameActive() async {
        isSceneActive = true
        await bootstrap()
        await applyPendingLocationTrackingRequest()
        applyPendingLocationTrackingGuidance()
        airPodsActivityService.start { [weak self] observation in
            self?.applyAirPodsActivity(observation)
        }
        scheduleForegroundRefresh()
    }

    private func applyPendingLocationTrackingRequest() async {
        guard let enabled = TaptionLocationTrackingRequestStore.take() else {
            return
        }
        if enabled {
            await enableLocationCollection()
        } else {
            await disableLocationCollection()
        }
    }

    private func applyPendingLocationTrackingGuidance() {
        guard TaptionLocationTrackingRequestStore.takeGuidanceRequest() else {
            return
        }
        presentPermissionOnboarding(for: .location)
    }

    func sceneEnteredBackground() async {
        isSceneActive = false
        for observation in airPodsActivityService.stop(at: .now) {
            applyAirPodsActivity(observation)
        }
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = nil
        deferredVisibleRefreshTask?.cancel()
        deferredVisibleRefreshTask = nil
        foregroundHealthRefreshTask?.cancel()
        foregroundHealthRefreshTask = nil
        if let rawDeviceDataArchive {
            await Task.detached(priority: .utility) {
                try? rawDeviceDataArchive.flushPendingWrites()
            }.value
        }
        await persist()
    }

    private func applyAirPodsActivity(
        _ observation: AirPodsActivityObservation
    ) {
        guard !snapshot.settings.suppressedActualIDs.contains(observation.id)
        else { return }
        let source: ActualSource
        let behavior: String
        switch observation.kind {
        case .music:
            source = .media
            behavior = "music"
        case .call:
            source = .call
            behavior = "call"
        }
        let actual = ActualRecord(
            id: observation.id,
            planID: nil,
            routineID: nil,
            title: observation.title,
            categoryID: "activity",
            startedAt: observation.startedAt,
            endedAt: observation.endedAt,
            source: source,
            confidence: .high,
            createdAt: observation.startedAt,
            behavior: behavior,
            evidence: ["AirPods · (observation.routeName)"],
            modelVersion: "airpods-observer-v1"
        )
        if let index = snapshot.actuals.firstIndex(where: {
            $0.id == observation.id
        }) {
            guard snapshot.actuals[index] != actual else { return }
            snapshot.actuals[index] = actual
        } else {
            snapshot.actuals.append(actual)
        }
        snapshot.actuals.sort { $0.startedAt < $1.startedAt }
        Task { await persistDeviceLocalSnapshot() }
    }

    private func scheduleForegroundRefresh() {
        guard foregroundRefreshTask == nil else { return }
        foregroundRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Two yields leave room for SwiftUI to commit the loaded snapshot
            // and present the first timeline before integrations enumerate
            // Photos, Calendar and HealthKit.
            await Task.yield()
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, self.isSceneActive else {
                self.foregroundRefreshTask = nil
                return
            }
            self.watchConnectivityService.refreshConnectionState()
            self.refreshWatchLaunchReport()
            await self.configureHealthBackgroundDeliveryIfNeeded(
                showErrors: false
            )
            self.startForegroundHealthRefreshIfNeeded()
            if let lastForegroundRefreshAt = self.lastForegroundRefreshAt,
               Date.now.timeIntervalSince(lastForegroundRefreshAt) < 5 {
                self.foregroundRefreshTask = nil
                return
            }
            await self.refreshPermissionStates()
            await self.waitForBootstrapPreparation()
            await self.applyPendingWidgetCommands(
                repositoryAlreadyLoaded: false
            )
            self.resumeSensorCollectionIfNeeded()
            await self.restoreTrackingSessionIfNeeded()
            await self.refreshEnabledData(
                includesCurrentDeviceDay: true,
                dataSpan: self.currentDeviceDataSpan,
                healthSpan: self.startupHealthSpan
            )
            self.lastForegroundRefreshAt = .now
            self.foregroundRefreshTask = nil
            self.scheduleDeferredVisibleRefresh()
        }
    }

    private func scheduleDeferredVisibleRefresh() {
        guard deferredVisibleRefreshTask == nil else { return }
        deferredVisibleRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled, self.isSceneActive else {
                self.deferredVisibleRefreshTask = nil
                return
            }
            await self.refreshStore(showErrors: false)
            await self.synchronizeCloud(showErrors: false)
            await self.persistDeviceLocalSnapshot()
            self.deferredVisibleRefreshTask = nil
        }
    }

    /// Refreshes device-backed records and republishes the shared widget
    /// payload when iOS wakes the app without presenting its UI.
    func performBackgroundRefresh() async -> Bool {
        Self.integrationLogger.notice("Background model refresh started")
        await bootstrap()
        await waitForBootstrapPreparation()
        await applyPendingWidgetCommands(repositoryAlreadyLoaded: false)
        await refreshEnabledData(includesCurrentDeviceDay: true)
        await persist()
        let success = userFacingError == nil
        Self.integrationLogger.notice(
            "Background model refresh finished: success=\(success, privacy: .public), snapshotUpdated=\(self.snapshot.updatedAt.timeIntervalSince1970, privacy: .public)"
        )
        return success
    }

    func permissionState(for feature: PermissionFeature) -> PermissionState {
        snapshot.settings.permissions[feature] ?? .notDetermined
    }

    /// Re-reads the system permission centers when Settings becomes visible.
    /// The saved snapshot is only a cache; iOS permissions can change while
    /// the app is suspended or in Settings.
    func refreshPermissions() async {
        await bootstrap()
        await refreshPermissionStates()
        refreshAppUsageAuthorizationState()
        await persistDeviceLocalSnapshot()
    }

    /// 설치 후 첫 실행에서만 권한 안내를 띄운다. 권한은 기기마다 다르므로
    /// iCloud로 오가는 스냅샷이 아니라 기기 저장소에 표시 여부를 남긴다.
    func presentPermissionOnboardingIfNeeded() {
        guard !UserDefaults.standard.bool(
            forKey: Self.permissionOnboardingKey
        ) else { return }
        permissionOnboardingStartFeature = nil
        isPermissionOnboardingPresented = true
    }

    func presentPermissionOnboarding(for feature: PermissionFeature) {
        permissionOnboardingStartFeature = feature
        isPermissionOnboardingPresented = true
    }

    func finishPermissionOnboarding() async {
        UserDefaults.standard.set(true, forKey: Self.permissionOnboardingKey)
        isPermissionOnboardingPresented = false
        permissionOnboardingStartFeature = nil
        await refreshPermissionStates()
        refreshAppUsageAuthorizationState()
        await persist()
    }

    func refreshAppUsageAuthorizationState() {
        appUsageAuthorizationState = screenTimeUsageService.authorizationState
        snapshot.settings.permissions[.appUsage] = switch appUsageAuthorizationState {
        case .approved: .authorized
        case .denied: .denied
        case .notDetermined: .notDetermined
        case .unavailable, .requiresCurrentSystem, .dataAccessUnavailable:
            .unavailable
        }
    }

    func requestAppUsageAuthorization() async {
        guard !isRefreshingIntegrations else { return }
        isRefreshingIntegrations = true
        defer { isRefreshingIntegrations = false }
        do {
            if screenTimeUsageService.authorizationState != .approved {
                try await screenTimeUsageService.requestAuthorization()
            }
            refreshAppUsageAuthorizationState()
            await refreshAppUsageData(
                in: currentDeviceDataSpan,
                showErrors: true
            )
            await persist()
        } catch {
            refreshAppUsageAuthorizationState()
            userFacingError = error.localizedDescription
        }
    }

    func requestPhotos() async {
        guard !isRefreshingIntegrations else { return }
        isRefreshingIntegrations = true
        let state = await photoService.requestAccess()
        snapshot.settings.permissions[.photos] = state
        snapshot.settings.showsPhotos = state.isGranted
        if state.isGranted {
            refreshPhotos()
        }
        await persist()
        isRefreshingIntegrations = false
    }

    func setPhotosEnabled(_ enabled: Bool) async {
        if enabled {
            await requestPhotos()
            return
        }
        snapshot.settings.showsPhotos = false
        snapshot.settings.showsPhotosInWidgets = false
        snapshot.photos = []
        await persist()
    }

    func requestCalendar() async {
        guard !isRefreshingIntegrations else { return }
        isRefreshingIntegrations = true
        do {
            let granted = try await calendarService.requestFullAccess()
            let state: PermissionState = granted ? .authorized : .denied
            snapshot.settings.permissions[.calendar] = state
            if granted {
                let ids = calendarService.calendars().map(\.id)
                snapshot.settings.selectedCalendarIDs = ids
                refreshCalendarEvents()
            }
            await persist()
        } catch {
            snapshot.settings.permissions[.calendar] = calendarService.permissionState()
            userFacingError = "캘린더를 연결하지 못했습니다. \(error.localizedDescription)"
        }
        isRefreshingIntegrations = false
    }

    func setCalendarEnabled(_ enabled: Bool) async {
        if enabled {
            await requestCalendar()
            return
        }
        snapshot.settings.selectedCalendarIDs = []
        snapshot.calendarEvents = []
        await persist()
    }

    func requestHealth() async {
        guard !isRefreshingIntegrations else { return }
        isRefreshingIntegrations = true
        do {
            let granted = try await healthService.requestReadAccess()
            snapshot.settings.healthEnabled = granted
            snapshot.settings.permissions[.health] = granted ? .authorized : .denied
            if granted {
                await refreshHealthData()
                await configureHealthBackgroundDeliveryIfNeeded(
                    showErrors: true
                )
                startForegroundHealthRefreshIfNeeded()
            }
            await persist()
        } catch {
            snapshot.settings.healthEnabled = false
            snapshot.settings.permissions[.health] = .denied
            userFacingError = "건강 데이터를 연결하지 못했습니다. \(error.localizedDescription)"
        }
        isRefreshingIntegrations = false
    }

    func setHealthEnabled(_ enabled: Bool) async {
        if enabled {
            await requestHealth()
            return
        }
        snapshot.settings.healthEnabled = false
        foregroundHealthRefreshTask?.cancel()
        foregroundHealthRefreshTask = nil
        await healthService.disableBackgroundDelivery()
        isHealthBackgroundDeliveryConfigured = false
        snapshot.actuals.removeAll { $0.source == .healthKit }
        sleepSessions = []
        lastHealthRefreshAt = nil
        await persist()
    }

    func requestNotifications() async {
        guard !isRefreshingIntegrations else { return }
        isRefreshingIntegrations = true
        do {
            let state = try await notificationScheduler.requestPermission()
            snapshot.settings.permissions[.notifications] = state
            snapshot.settings.notificationsEnabled = state.isGranted
            if state.isGranted {
                try await notificationScheduler.synchronize(
                    plans: snapshot.plans
                )
            }
            await persist()
        } catch {
            snapshot.settings.permissions[.notifications] =
                await notificationScheduler.authorizationState()
            snapshot.settings.notificationsEnabled = false
            userFacingError =
                "계획 알림을 켜지 못했습니다. \(error.localizedDescription)"
        }
        isRefreshingIntegrations = false
    }

    func setNotificationsEnabled(_ enabled: Bool) async {
        if enabled {
            await requestNotifications()
            return
        }
        snapshot.settings.notificationsEnabled = false
        await notificationScheduler.cancelAllPlanReminders()
        await persist()
    }

    func refreshStore(showErrors: Bool = true) async {
        guard !isStoreLoading else { return }
        isStoreLoading = true
        hasProAccess = await purchaseService.hasProEntitlement()
        do {
            proProduct = try await purchaseService.loadProProduct()
            if hasProAccess {
                storeStatusMessage = "영구 사용 중"
            } else if let proProduct {
                storeStatusMessage = "\(proProduct.displayPrice) · 한 번만 결제"
            } else {
                storeStatusMessage = "App Store 상품 준비 중"
            }
        } catch {
            proProduct = nil
            storeStatusMessage = hasProAccess
                ? "영구 사용 중"
                : "App Store 상품 준비 중"
            if showErrors {
                userFacingError =
                    "구매 정보를 불러오지 못했습니다. \(error.localizedDescription)"
            }
        }
        isStoreLoading = false
    }

    func purchasePro() async {
        guard !isStoreLoading, !hasProAccess else { return }
        isStoreLoading = true
        do {
            switch try await purchaseService.purchasePro() {
            case .purchased:
                hasProAccess = true
                storeStatusMessage = "영구 사용 중"
            case .pending:
                storeStatusMessage = "구매 승인 대기 중"
            case .cancelled:
                break
            }
        } catch {
            userFacingError =
                "구매를 완료하지 못했습니다. \(error.localizedDescription)"
        }
        isStoreLoading = false
    }

    func restorePurchases() async {
        guard !isStoreLoading else { return }
        isStoreLoading = true
        do {
            hasProAccess = try await purchaseService.restorePurchases()
            storeStatusMessage = hasProAccess
                ? "영구 사용 중"
                : "복원할 구매 내역 없음"
        } catch {
            userFacingError =
                "구매 내역을 복원하지 못했습니다. \(error.localizedDescription)"
        }
        isStoreLoading = false
    }

    func enableLocationCollection(always: Bool = true) async {
        guard let sensorService else {
            snapshot.settings.permissions[.location] = .unavailable
            userFacingError = "이 기기에서는 위치·동작 센서를 사용할 수 없습니다."
            return
        }

        sensorAvailability = sensorService.hardwareAvailability()
        let state = sensorService.locationPermissionState()
        snapshot.settings.permissions[.location] = state
        snapshot.settings.permissions[.motion] = sensorService.motionPermissionState()

        if state == .notDetermined
            || (always && state == .authorized) {
            sensorService.requestLocationPermission(always: always)
            try? await Task.sleep(for: .milliseconds(700))
        }

        let refreshed = sensorService.locationPermissionState()
        snapshot.settings.permissions[.location] = refreshed
        snapshot.settings.permissions[.motion] = sensorService.motionPermissionState()
        snapshot.settings.locationEnabled = refreshed.isGranted
        snapshot.settings.backgroundPreciseLocationEnabled =
            always && sensorService.hasAlwaysLocationAuthorization()

        if refreshed.isGranted {
            sensorService.startCollection(
                configuration: .configured(
                    for: settings.sensorCollectionProfile,
                    allowsBackgroundLocation: always
                )
            )
            isSensorCollecting = true
        }
        if always,
           refreshed.isGranted,
           !snapshot.settings.backgroundPreciseLocationEnabled {
            userFacingError =
                "장소를 자동 기록하려면 위치 접근을 ‘항상’으로 허용해주세요."
        }
        publishWatchPayload()
        await persist()
    }

    func disableLocationCollection() async {
        sensorService?.stopCollection()
        isSensorCollecting = false
        snapshot.settings.locationEnabled = false
        snapshot.settings.backgroundPreciseLocationEnabled = false
        publishWatchPayload()
        await persist()
    }

    func refreshEnabledData(
        includesCurrentDeviceDay: Bool = false,
        dataSpan: TimeSpan? = nil,
        healthSpan: TimeSpan? = nil,
        persistDeviceSnapshot: Bool = true
    ) async {
        await waitForBootstrapPreparation()
        guard !isRefreshingIntegrations else { return }
        TaptionPlanDiagnosticsLogger.shared.record(
            "integration_refresh_started",
            fields: [
                "scale": selectedScale.rawValue,
                "current_day": String(includesCurrentDeviceDay),
            ]
        )
        isRefreshingIntegrations = true
        defer {
            isRefreshingIntegrations = false
            TaptionPlanDiagnosticsLogger.shared.record(
                "integration_refresh_finished",
                fields: [
                    "actuals": String(snapshot.actuals.count),
                    "travel": String(snapshot.travel.count),
                    "weather": String(snapshot.weather.count),
                ]
            )
        }
        let refreshSpan = dataSpan ?? visibleDataSpan
        let photoSpan = permissionState(for: .photos).isGranted
            && settings.showsPhotos
            ? refreshSpan
            : nil
        let photoTask = photoSpan.map { span in
            Task.detached(priority: .utility) { [photoService] in
                photoService.moments(in: span)
            }
        }
        if permissionState(for: .calendar).isGranted,
           !settings.selectedCalendarIDs.isEmpty {
            await Task.yield()
            refreshCalendarEvents(in: refreshSpan)
        }
        if settings.healthEnabled {
            do {
                if try await healthService.authorizationRequestState()
                    == .notDetermined {
                    let completed = try await healthService.requestReadAccess()
                    snapshot.settings.permissions[.health] = completed
                        ? .authorized
                        : .notDetermined
                }
            } catch {
                Self.integrationLogger.error(
                    "HealthKit authorization refresh failed: \(error.localizedDescription, privacy: .public)"
                )
            }
            await refreshHealthData(in: healthSpan)
        }
        let appUsageSpan = selectedScale == .day
            ? refreshSpan
            : currentDeviceDataSpan
        await refreshAppUsageData(in: appUsageSpan)
        if settings.locationEnabled
            || settings.weatherEnabled
            || hasPhotoLocations(in: refreshSpan) {
            if includesCurrentDeviceDay {
                await refreshSensorTimeline(containing: .now)
            }
            if !includesCurrentDeviceDay
                || !Calendar.autoupdatingCurrent.isDateInToday(selectedDate) {
                await refreshSensorTimeline(containing: selectedDate)
            }
        }
        if let photoTask, let photoSpan {
            replacePhotos(await photoTask.value, in: photoSpan)
        }
        logAutomaticRecordSummary()
        // Calendar, HealthKit, Watch, location and motion records are device
        // ground truth. Save them locally before any potentially slow cloud
        // request so opening the app always updates today's timeline first.
        if persistDeviceSnapshot {
            await persistDeviceLocalSnapshot()
        }
    }

    /// Publishes the latest HealthKit/Watch and sensor records before a
    /// routine dashboard is shown. Automatic evidence is ground truth, so a
    /// dashboard must not wait for the next foreground polling interval.
    func refreshConnectedRecordsNow() async {
        await bootstrap()
        await refreshEnabledData(includesCurrentDeviceDay: true)
    }

    func synchronizeCloud(showErrors: Bool = true) async {
        guard let cloudSyncService, !isCloudSyncing else {
            if cloudSyncService == nil {
                snapshot.settings.permissions[.cloud] = .unavailable
                cloudUnavailableReason = .unsupportedBuild
            }
            return
        }
        isCloudSyncing = true
        if await cloudSyncService.isSchemaUnavailable() {
            snapshot.settings.permissions[.cloud] = .unavailable
            cloudUnavailableReason = .schemaMissing
            isCloudSyncing = false
            return
        }
        let (state, reason) = await cloudSyncService.accountAvailability()
        snapshot.settings.permissions[.cloud] = state
        cloudUnavailableReason = reason
        guard state.isGranted else {
            isCloudSyncing = false
            return
        }

        do {
            let localDeviceData = snapshot
            let (cloudValue, _) = try await cloudSyncService.synchronize(
                local: cloudPortableSnapshot(snapshot)
            )
            assignCloudMergedSnapshot(mergeDeviceLocalData(
                cloud: cloudValue,
                local: localDeviceData
            ))
            await refreshReviewArchives(force: true)
            try await repository.save(snapshot)
            publishWidgetPayload()
        } catch {
            if CloudKitErrorPolicy.isProductionSchemaUnavailable(error)
                || error is RepositoryError
                    && (error as? RepositoryError) == .cloudSchemaUnavailable {
                snapshot.settings.permissions[.cloud] = .unavailable
                cloudUnavailableReason = .schemaMissing
                Self.integrationLogger.error(
                    "CloudKit production schema is unavailable; local data remains authoritative"
                )
            } else if showErrors {
                userFacingError =
                    "iCloud와 동기화하지 못했습니다. \(error.localizedDescription)"
            }
        }
        isCloudSyncing = false
    }

    func selectCatCoat(_ coat: CatCoat) {
        selectedCatCoat = coat
        snapshot.settings.catStyle = coat.catStyle
        publishWatchPayload()
        Task { await persist() }
    }

    func setStartScale(_ scale: TimeScale) {
        snapshot.settings.startScale = scale.timelineLevel
        selectedScale = scale
        Task { await persist() }
    }

    func setRememberLastScale(_ enabled: Bool) {
        snapshot.settings.rememberLastScale = enabled
        if enabled {
            snapshot.settings.startScale = selectedScale.timelineLevel
        }
        Task { await persist() }
    }

    func setReduceMotion(_ enabled: Bool) {
        guard snapshot.settings.reduceMotion != enabled else { return }
        snapshot.settings.reduceMotion = enabled
        publishWatchPayload()
        Task { await persist() }
    }

    func setSensorCollectionProfile(
        _ profile: SensorCollectionProfile
    ) {
        guard snapshot.settings.sensorCollectionProfile != profile else {
            return
        }
        snapshot.settings.sensorCollectionProfile = profile
        if settings.locationEnabled,
           permissionState(for: .location).isGranted,
           let sensorService {
            sensorService.startCollection(
                configuration: .configured(
                    for: profile,
                    allowsBackgroundLocation:
                        settings.backgroundPreciseLocationEnabled
                )
            )
            isSensorCollecting = true
        }
        Task { await persist() }
    }

    func setWatchAccelerationProfile(
        _ profile: TaptionWatchAccelerationProfile
    ) {
        guard snapshot.settings.watchAccelerationProfile != profile else {
            return
        }
        snapshot.settings.watchAccelerationProfile = profile
        publishWatchPayload()
        Task { await persist() }
    }

    func setWatchDataSyncProfile(
        _ profile: TaptionWatchDataSyncProfile
    ) {
        guard snapshot.settings.watchDataSyncProfile != profile else {
            return
        }
        snapshot.settings.watchDataSyncProfile = profile
        publishWatchPayload()
        Task { await persist() }
    }

    func requestWatchDataSync() {
        watchConnectivityService.requestWatchDataSync()
    }

    func refreshAppleWatchConnectionState() {
        watchConnectivityService.refreshConnectionState()
        refreshWatchLaunchReport()
    }

    /// 워치는 나중에 페어링될 수도, 앱이 나중에 설치될 수도 있다. 세션이
    /// 상태를 알릴 때마다 여기로 들어와 안내가 따라 바뀐다.
    func applyAppleWatchConnectionState(_ state: AppleWatchConnectionState) {
        if appleWatchConnectionState != state {
            appleWatchConnectionState = state
        }
        // 설치를 한 번 확인했으면 사용자가 나중에 지우더라도 다시 권하지 않는다.
        guard state == .background || state == .reachable,
              !hasSeenWatchAppInstalled else {
            return
        }
        watchOnboardingStore.markWatchAppInstalled()
        hasSeenWatchAppInstalled = true
    }

    /// 지금 보여 줄 첫 실행 안내. 없으면 아무것도 띄우지 않는다.
    var appleWatchOnboardingPrompt: AppleWatchOnboardingPrompt? {
        AppleWatchOnboarding.prompt(
            for: appleWatchConnectionState,
            dismissed: dismissedAppleWatchPrompts,
            hasSeenWatchAppInstalled: hasSeenWatchAppInstalled
        )
    }

    /// 설정에 늘 남는 워치 앱 줄.
    var appleWatchCompanionRow: AppleWatchCompanionRow {
        AppleWatchOnboarding.companionRow(for: appleWatchConnectionState)
    }

    /// 한 번 닫으면 그 안내는 다시 뜨지 않는다.
    func dismissAppleWatchPrompt(_ prompt: AppleWatchOnboardingPrompt) {
        guard !dismissedAppleWatchPrompts.contains(prompt) else { return }
        watchOnboardingStore.dismiss(prompt)
        dismissedAppleWatchPrompts.insert(prompt)
    }

    func refreshWatchLaunchReport() {
        watchLaunchReport = WatchLaunchReportStore.read()
    }

    func clearWatchLaunchReport() {
        WatchLaunchReportStore.clear()
        watchLaunchReport = nil
    }

    func startTracking(_ kind: TrackingKind) async {
        guard kind != .automatic else { return }
        if !settings.locationEnabled
            || !permissionState(for: .location).isGranted {
            await enableLocationCollection(always: true)
        }
        guard let sensorService,
              permissionState(for: .location).isGranted else {
            userFacingError = "위치 권한을 허용해야 걷기·달리기 경로를 기록할 수 있습니다."
            return
        }
        if activeTrackingSession != nil {
            await stopTracking()
        }
        // Exercise records remain unlinked until the user taps an item in the
        // detail panel. Time/category overlap is not an implicit relationship.
        let linkedPlanID: UUID? = nil
        let session = sensorService.beginTracking(
            kind: kind,
            linkedPlanID: linkedPlanID
        )
        activeTrackingSession = session
        TaptionPlanDiagnosticsLogger.shared.record(
            "tracking_started",
            fields: ["kind": kind.rawValue]
        )
        trackingSessionWasRecovered = false
        TrackingSessionRecoveryStore.save(session)
        lastTrackingSessionRecoveryPersistAt = .now
        liveRouteState = LiveRouteState(
            session: session,
            readings: [],
            lastUpdatedAt: .now
        )
        try? watchConnectivityService.requestWorkout(
            TaptionWatchWorkoutRequest(
                sessionID: session.id,
                action: .start,
                kind: kind == .running ? .running : .walking,
                linkedPlanID: linkedPlanID
            )
        )
        do {
            _ = try await healthService.startWatchWorkout(kind: kind)
        } catch {
            Self.integrationLogger.info(
                "Watch workout wake was unavailable: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func stopTracking() async {
        guard let completed = sensorService?.endTracking()
            ?? activeTrackingSession.map({ session in
                var value = session
                value.endedAt = .now
                return value
            }) else {
            return
        }
        finalizeTrackingSession(completed)
        TaptionPlanDiagnosticsLogger.shared.record(
            "tracking_stopped",
            fields: [
                "kind": completed.kind.rawValue,
                "duration_seconds": String(
                    Int((completed.endedAt ?? .now).timeIntervalSince(
                        completed.startedAt
                    ))
                ),
            ]
        )
        TrackingSessionRecoveryStore.clear()
        lastTrackingSessionRecoveryPersistAt = nil
        try? watchConnectivityService.requestWorkout(
            TaptionWatchWorkoutRequest(
                sessionID: completed.id,
                action: .stop,
                kind: completed.kind == .running ? .running : .walking,
                linkedPlanID: completed.linkedPlanID
            )
        )
        activeTrackingSession = nil
        trackingSessionWasRecovered = false
        liveRouteState.session = nil
        scheduleSensorAnalysis(
            containing: completed.startedAt,
            immediately: true
        )
    }

    func liveSensorReadings(in span: TimeSpan) -> [SensorReading] {
        liveRouteState.readings.filter { span.contains($0.timestamp) }
    }

    func mergingLiveSensorReadings(
        _ archived: [SensorReading],
        in span: TimeSpan
    ) -> [SensorReading] {
        let cacheKey = LiveMergeCacheKey(
            spanStart: span.start.timeIntervalSinceReferenceDate,
            spanEnd: span.end.timeIntervalSinceReferenceDate,
            archivedCount: archived.count,
            archivedFirstID: archived.first?.id,
            archivedLastID: archived.last?.id,
            archivedFirstTimestamp: archived.first?.timestamp,
            archivedLastTimestamp: archived.last?.timestamp,
            liveCount: liveRouteState.readings.count,
            liveLastUpdatedAt: liveRouteState.lastUpdatedAt
        )
        if liveMergeCacheKey == cacheKey {
            return liveMergeCacheValue
        }

        let live = liveSensorReadings(in: span)
        guard !live.isEmpty else {
            liveMergeCacheKey = cacheKey
            liveMergeCacheValue = archived
            return archived
        }

        // Both sources are chronological: the archive reader and the live
        // route append path preserve timestamp order. Merge them linearly so
        // a live GPS tick does not sort and allocate the entire route again.
        var merged: [SensorReading] = []
        merged.reserveCapacity(archived.count + live.count)
        var seen = Set<UUID>()
        seen.reserveCapacity(archived.count + live.count)
        var archivedIndex = 0
        var liveIndex = 0

        while archivedIndex < archived.count || liveIndex < live.count {
            let takeArchived: Bool
            if liveIndex == live.count {
                takeArchived = true
            } else if archivedIndex == archived.count {
                takeArchived = false
            } else {
                // Keep the archive first for equal timestamps, matching the
                // previous stable-sort behavior when an ID is duplicated.
                takeArchived = archived[archivedIndex].timestamp
                    <= live[liveIndex].timestamp
            }

            let reading: SensorReading
            if takeArchived {
                reading = archived[archivedIndex]
                archivedIndex += 1
            } else {
                reading = live[liveIndex]
                liveIndex += 1
            }
            if seen.insert(reading.id).inserted {
                merged.append(reading)
            }
        }
        liveMergeCacheKey = cacheKey
        liveMergeCacheValue = merged
        return merged
    }

    func setWidgetPhotosVisible(_ visible: Bool) {
        snapshot.settings.showsPhotosInWidgets =
            visible && permissionState(for: .photos).isGranted
        Task { await persist() }
    }

    func refreshWidgetNow() {
        publishWidgetPayload()
    }

    func exportSnapshotURL() throws -> URL {
        let data = try SnapshotExporter.jsonData(snapshot)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaptionPlanExport", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let year = Calendar.autoupdatingCurrent.component(
            .year,
            from: selectedDate
        )
        let url = directory.appendingPathComponent(
            "Taption-Plan-\(year).json"
        )
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    func exportDiagnosticsToICloud() async {
        guard !isExportingDiagnostics else { return }
        isExportingDiagnostics = true
        diagnosticsExportStatus = "전송 중"
        defer { isExportingDiagnostics = false }
        TaptionPlanDiagnosticsLogger.shared.record(
            "diagnostics_export_requested"
        )
        do {
            let watchLog = await watchConnectivityService
                .requestDiagnosticsLog()
                ?? WatchLaunchReportStore.read()?.report
            let builder = try TaptionPlanDiagnosticsLogPackageBuilder
                .applicationSupport()
            let package = try builder.makePackage(
                summary: diagnosticsSummary,
                iphoneLog: TaptionPlanDiagnosticsLogger.shared.combinedLog(),
                watchLog: watchLog
            )
            let destination = try await Task.detached(priority: .utility) {
                try TaptionPlanDiagnosticsICloudExporter().export(package)
            }.value
            diagnosticsExportStatus = "전송됨"
            TaptionPlanDiagnosticsLogger.shared.record(
                "diagnostics_export_completed",
                fields: ["file": destination.lastPathComponent]
            )
        } catch {
            diagnosticsExportStatus = "실패"
            TaptionPlanDiagnosticsLogger.shared.record(
                "diagnostics_export_failed",
                level: .error,
                fields: ["error": String(describing: type(of: error))]
            )
            userFacingError = error.localizedDescription
        }
    }

    private var diagnosticsSummary: [String: String] {
        let bundle = Bundle.main
        return [
            "app_version": bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "unknown",
            "build": bundle.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "unknown",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "plans": String(snapshot.plans.count),
            "actuals": String(snapshot.actuals.count),
            "travel": String(snapshot.travel.count),
            "places": String(snapshot.places.count),
            "weather": String(snapshot.weather.count),
            "calendar_events": String(snapshot.calendarEvents.count),
            "photos": String(snapshot.photos.count),
            "memos": String(snapshot.memos.count),
            "watch_connection": appleWatchConnectionState.rawValue,
            "sensor_collecting": String(isSensorCollecting),
            "location_enabled": String(settings.locationEnabled),
            "health_enabled": String(settings.healthEnabled),
            "cloud_status": cloudStatusText,
            "widget_sync": widgetSyncStatusText,
        ]
    }

    func deleteAllUserData() async {
        sensorService?.stopCollection()
        TrackingSessionRecoveryStore.clear()
        activeTrackingSession = nil
        trackingSessionWasRecovered = false
        liveRouteState = .empty
        isSensorCollecting = false
        await notificationScheduler.cancelAllPlanReminders()
        var empty = TaptionDataSnapshot.empty
        empty.categories = CategoryCatalog.builtIn
        empty.settings.permissions = snapshot.settings.permissions
        empty.settings.permissions[.cloud] =
            snapshot.settings.permissions[.cloud] ?? .notDetermined
        empty.settings.cloudResetAt = .now
        snapshot = empty
        pendingSetupCategoryIDs = Set(empty.categories.map(\.id))
        isEditingSetupCategories = false
        selectedGroupPlanID = nil
        groupNavigationPath = []
        memoEntry = nil
        sleepSessions = []
        try? await sensorService?.deleteArchivedReadings()
        await persist()
    }

    var setupCategories: [CategoryDefinition] {
        snapshot.categories.sorted { $0.sortOrder < $1.sortOrder }
    }

    var selectedSetupCategoryCount: Int {
        if !isEditingSetupCategories {
            return snapshot.categories.filter { !$0.isHidden }.count
        }
        return pendingSetupCategoryIDs.count
    }

    func openInitialSetup() {
        let visibleIDs = Set(
            snapshot.categories.filter { !$0.isHidden }.map(\.id)
        )
        pendingSetupCategoryIDs = visibleIDs.isEmpty
            ? Set(snapshot.categories.map(\.id))
            : visibleIDs
        isEditingSetupCategories = true
        detail = .categorySetup
    }

    func toggleSetupCategory(_ categoryID: String) {
        if pendingSetupCategoryIDs.contains(categoryID) {
            pendingSetupCategoryIDs.remove(categoryID)
        } else {
            pendingSetupCategoryIDs.insert(categoryID)
        }
    }

    func cancelInitialCategorySelection() {
        isEditingSetupCategories = false
        pendingSetupCategoryIDs = []
        detail = nil
    }

    func applyInitialCategorySelection() async {
        guard !pendingSetupCategoryIDs.isEmpty else {
            userFacingError = "대분류를 하나 이상 선택해 주세요."
            return
        }
        snapshot.categories = snapshot.categories.map { category in
            var updated = category
            updated.isHidden = !pendingSetupCategoryIDs.contains(category.id)
            return updated
        }
        await persist()
        isEditingSetupCategories = false
        detail = nil
    }

    /// 메모 입력의 유일한 입구. 계획도 기록도 고르지 않고 순간만 받는다.
    /// `memoIDs` 가 비어 있지 않으면 그 자리에 이미 있던 메모를 펼친다.
    func openMemoEntry(at instant: Date, memoIDs: [UUID] = []) {
        memoEntry = MemoEntry(occurredAt: instant, memoIDs: memoIDs)
        detail = .memo
    }

    func closeMemoEntry() {
        memoEntry = nil
        detail = nil
    }

    /// 메모가 놓일 순간을 옮긴다. 손가락으로만 움직이므로 키보드는 메모 글에만
    /// 쓰인다.
    func moveMemoEntry(to instant: Date) {
        guard memoEntry?.occurredAt != instant else { return }
        memoEntry?.occurredAt = instant
    }

    var memoEntryMemos: [ActionMemo] {
        guard let memoEntry, !memoEntry.memoIDs.isEmpty else { return [] }
        let ids = Set(memoEntry.memoIDs)
        return snapshot.memos
            .filter { ids.contains($0.id) }
            .sorted { $0.occurredAt < $1.occurredAt }
    }

    /// 시간표 메모 줄이 읽는 값. 항목에 붙은 메모도 결국 한 순간에 놓이므로
    /// 줄 하나가 그 기간의 메모를 전부 보여 준다.
    func timelineMemos(in span: TimeSpan) -> [ActionMemo] {
        snapshot.memos.filter {
            $0.occurredAt >= span.start && $0.occurredAt < span.end
        }
    }

    @discardableResult
    func addMemoAtEntryInstant(text: String, kind: MemoKind) -> UUID? {
        guard let entry = memoEntry,
              let id = addMemo(
                  text: text,
                  kind: kind,
                  categoryID: MemoTimelineEngine.categoryID,
                  on: entry.occurredAt
              ) else {
            return nil
        }
        memoEntry?.memoIDs.append(id)
        return id
    }

    func addAttachmentMemoAtEntryInstant(
        kind: MemoKind,
        attachmentKind: AttachmentKind,
        localIdentifier: String,
        text: String? = nil
    ) {
        guard let entry = memoEntry else { return }
        let fallbackText = attachmentKind == .photo ? "사진 메모" : "음성 메모"
        let memo = ActionMemo(
            categoryID: MemoTimelineEngine.categoryID,
            occurredAt: entry.occurredAt,
            kind: kind,
            text: text?.trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty ?? fallbackText,
            attachments: [
                MemoAttachment(
                    kind: attachmentKind,
                    localIdentifier: localIdentifier
                ),
            ]
        )
        snapshot.memos.append(memo)
        memoEntry?.memoIDs.append(memo.id)
        Task { await persist() }
    }

    func memos(for planID: UUID?) -> [ActionMemo] {
        guard let planID else { return [] }
        return snapshot.memos
            .filter {
                $0.planID == planID
                    && ($0.targetID == nil
                        || $0.targetID == "plan.\(planID.uuidString)")
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func memos(forTargetID targetID: String?) -> [ActionMemo] {
        guard let targetID, !targetID.isEmpty else { return [] }
        return snapshot.memos
            .filter { $0.targetID == targetID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Notes left on a category row. They belong to the category and the day,
    /// not to a plan, so nothing has to be invented to store them.
    func memos(forCategoryID categoryID: String?, on date: Date) -> [ActionMemo] {
        guard let categoryID, !categoryID.isEmpty else { return [] }
        let calendar = Calendar.autoupdatingCurrent
        return snapshot.memos
            .filter {
                $0.planID == nil
                    && $0.targetID == nil
                    && $0.categoryID == categoryID
                    && calendar.isDate($0.occurredAt, inSameDayAs: date)
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func addMemo(
        text: String,
        kind: MemoKind,
        to planID: UUID
    ) {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty,
              let plan = snapshot.plans.first(where: { $0.id == planID })
        else {
            return
        }
        snapshot.memos.append(
            ActionMemo(
                planID: planID,
                categoryID: plan.categoryID,
                occurredAt: plan.span.start,
                kind: kind,
                text: cleanText
            )
        )
        Task { await persist() }
    }

    @discardableResult
    func addMemo(
        text: String,
        kind: MemoKind,
        categoryID: String,
        on date: Date
    ) -> UUID? {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty, !categoryID.isEmpty else { return nil }
        let memo = ActionMemo(
            categoryID: categoryID,
            occurredAt: date,
            kind: kind,
            text: cleanText
        )
        snapshot.memos.append(memo)
        Task { await persist() }
        return memo.id
    }

    func deleteMemo(_ memoID: UUID) {
        guard let memo = snapshot.memos.first(where: { $0.id == memoID }) else {
            return
        }
        invalidateReviewArchives(dates: [memo.occurredAt])
        snapshot.settings.cloudDeletedRecordKeys.insert(
            CloudBackupRecordKey.memo(memoID)
        )
        snapshot.memos.removeAll { $0.id == memoID }
        memoEntry?.memoIDs.removeAll { $0 == memoID }
        Task { await persist() }
    }

    func updateMemo(
        _ memoID: UUID,
        text: String,
        kind: MemoKind
    ) {
        guard let index = snapshot.memos.firstIndex(where: {
            $0.id == memoID
        }), let updated = ActionMemoEditingEngine.updating(
            snapshot.memos[index],
            text: text,
            kind: kind
        ) else {
            return
        }
        snapshot.memos[index] = updated
        Task { await persist() }
    }

    /// 음성 메모도 붙일 항목을 찾지 않는다. 메모 입력이 열려 있으면 그 순간에
    /// 놓인다.
    func toggleVoiceMemo(kind: MemoKind) async {
        guard memoEntry != nil else { return }

        if isRecordingVoiceMemo {
            guard let url = voiceMemoRecorder.stop() else {
                isRecordingVoiceMemo = false
                return
            }
            isRecordingVoiceMemo = false
            addAttachmentMemoAtEntryInstant(
                kind: kind,
                attachmentKind: .audio,
                localIdentifier: url.path
            )
            return
        }

        voiceMemoPlayer.stop()
        playingVoiceAttachmentID = nil
        let granted = await voiceMemoRecorder.requestPermission()
        snapshot.settings.permissions[.microphone] =
            granted ? .authorized : .denied
        guard granted else {
            userFacingError = "음성 메모를 사용하려면 마이크 권한이 필요합니다."
            await persist()
            return
        }

        do {
            let root = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            _ = try voiceMemoRecorder.start(
                in: root.appendingPathComponent(
                    "TaptionPlan/VoiceMemos",
                    isDirectory: true
                )
            )
            isRecordingVoiceMemo = true
            await persist()
        } catch {
            isRecordingVoiceMemo = false
            let reason = (error as? VoiceMemoRecordingError)?.localizedDescription
                ?? "마이크 입력 장치를 확인해 주세요."
            userFacingError =
                "음성 녹음을 시작하지 못했습니다. \(reason)"
        }
    }

    func toggleVoicePlayback(_ attachment: MemoAttachment) {
        guard attachment.kind == .audio else { return }
        if playingVoiceAttachmentID == attachment.id {
            voiceMemoPlayer.stop()
            playingVoiceAttachmentID = nil
            return
        }
        do {
            try voiceMemoPlayer.play(
                filePath: attachment.localIdentifier
            )
            playingVoiceAttachmentID = attachment.id
        } catch {
            playingVoiceAttachmentID = nil
            userFacingError =
                "음성 메모를 재생하지 못했습니다. \(error.localizedDescription)"
        }
    }

    @discardableResult
    func addPlan(
        title: String,
        categoryID: String,
        middleCategoryName: String? = nil,
        subCategoryName: String? = nil,
        startAt: Date,
        duration: TimeInterval,
        parentID: UUID? = nil,
        repeatRules: [GoalRepeatRule]? = nil
    ) -> UUID? {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, duration > 0 else { return nil }
        let cleanedRepeatRules = Self.cleanGoalRepeatRules(repeatRules)
        var plan: PlanRecord
        if let parentID,
           let parent = snapshot.plans.first(where: { $0.id == parentID }) {
            let childDuration = min(duration, parent.span.duration)
            let latestStart = parent.span.end.addingTimeInterval(-childDuration)
            let adjustedStart = min(
                max(startAt, parent.span.start),
                latestStart
            )
            do {
                plan = try GoalDecompositionEngine.makeChild(
                    parent: parent,
                    title: cleanTitle,
                    span: TimeSpan(
                        start: adjustedStart,
                        end: adjustedStart.addingTimeInterval(childDuration)
                    ),
                    categoryID: categoryID
                )
                plan.repeatRules = cleanedRepeatRules
                plan.middleCategoryName = Self.cleanHierarchyName(
                    middleCategoryName
                )
                plan.subCategoryName = Self.cleanHierarchyName(
                    subCategoryName
                )
            } catch {
                userFacingError = "상위 루틴 안에 계획을 배치하지 못했습니다."
                return nil
            }
        } else {
            plan = PlanRecord(
                title: cleanTitle,
                span: TimeSpan(
                    start: startAt,
                    end: startAt.addingTimeInterval(duration)
                ),
                categoryID: categoryID,
                middleCategoryName: Self.cleanHierarchyName(
                    middleCategoryName
                ),
                subCategoryName: Self.cleanHierarchyName(subCategoryName),
                repeatRules: cleanedRepeatRules
            )
        }
        snapshot.plans.append(plan)
        if plan.parentID == nil,
           let rules = plan.repeatRules {
            snapshot.plans.append(
                contentsOf: repeatActionItems(for: plan, rules: rules)
            )
        }
        snapshot.plans.sort { $0.span.start < $1.span.start }
        Task { await persist() }
        return plan.id
    }

    private static func cleanHierarchyName(_ value: String?) -> String? {
        let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean?.isEmpty == false ? clean : nil
    }

    func updatePlan(
        _ planID: UUID,
        title: String,
        categoryID: String,
        middleCategoryName: String? = nil,
        subCategoryName: String? = nil,
        span: TimeSpan,
        parentID: UUID?,
        isImportant: Bool,
        repeatRules: [GoalRepeatRule]? = nil
    ) {
        guard let index = snapshot.plans.firstIndex(where: {
            $0.id == planID
        }) else {
            userFacingError = "수정할 계획을 찾지 못했습니다."
            return
        }
        guard !snapshot.plans[index].isFixed else {
            userFacingError = "캘린더 고정 일정은 캘린더에서 수정해 주세요."
            return
        }
        let cleanTitle = title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !cleanTitle.isEmpty, span.duration > 0 else {
            userFacingError = "계획 이름과 시간을 확인해 주세요."
            return
        }
        let cleanedRepeatRules = Self.cleanGoalRepeatRules(repeatRules)

        var updated = snapshot.plans[index]
        updated.title = cleanTitle
        updated.categoryID = categoryID
        updated.middleCategoryName = Self.cleanHierarchyName(
            middleCategoryName
        )
        updated.subCategoryName = Self.cleanHierarchyName(subCategoryName)
        updated.span = span
        updated.parentID = parentID
        updated.isImportant = isImportant
        updated.repeatRules = cleanedRepeatRules
        updated.updatedAt = .now

        var candidate = snapshot.plans
        candidate[index] = updated
        candidate.removeAll {
            $0.parentID == planID && $0.origin == .repeatRule
        }
        do {
            try PlanHierarchy.validate(candidate)
            if let parentID,
               let parent = candidate.first(where: {
                   $0.id == parentID
               }),
               (span.start < parent.span.start
                   || span.end > parent.span.end) {
                throw PlanningError.childOutsideParent
            }
            let children = PlanHierarchy.children(
                of: planID,
                in: candidate
            )
            guard children.allSatisfy({
                span.start <= $0.span.start && $0.span.end <= span.end
            }) else {
                throw PlanningError.childOutsideParent
            }
            if parentID == nil,
               Self.isGoalTitle(cleanTitle),
               let rules = cleanedRepeatRules {
                candidate.append(
                    contentsOf: repeatActionItems(for: updated, rules: rules)
                )
                try PlanHierarchy.validate(candidate)
            }
            snapshot.plans = candidate.sorted {
                $0.span.start < $1.span.start
            }
            Task { await persist() }
        } catch PlanningError.parentCycle {
            userFacingError = "계획을 자기 하위 루틴 안으로 옮길 수 없습니다."
        } catch {
            userFacingError =
                "상위·하위 계획의 기간 안에서 시간을 정해 주세요."
        }
    }

    /// Attach an existing action item to a routine without creating a
    /// duplicate plan. Re-selecting a routine moves an already grouped action
    /// after validating the new parent, so the detail tab can expose a single
    /// "루틴 연결/변경" action.
    func connectActionItem(
        _ planID: UUID,
        toGoal goalID: UUID
    ) async {
        guard let planIndex = snapshot.plans.firstIndex(where: {
            $0.id == planID
        }), let target = snapshot.plans.first(where: { $0.id == goalID }),
              GoalRecordPolicy.isGoal(target) else {
            userFacingError = "연결할 루틴 또는 액션아이템을 찾지 못했습니다."
            return
        }
        let plan = snapshot.plans[planIndex]
        guard plan.origin != .repeatRule,
              !GoalRecordPolicy.isGoal(plan),
              !AutomaticRecordTimelineEngine.isRoutineOnlyCategory(
                  plan.categoryID
              ) else {
            userFacingError = "반복 세그먼트와 루틴은 액션아이템으로 연결할 수 없습니다."
            return
        }
        do {
            var candidatePlans = snapshot.plans
            if let planIndex = candidatePlans.firstIndex(where: { $0.id == planID }) {
                // Clear the old parent first. PlanHierarchy.attach then
                // validates the same action against the new routine's span.
                candidatePlans[planIndex].parentID = nil
            }
            let attached = try PlanHierarchy.attach(
                child: candidatePlans[planIndex],
                to: goalID,
                in: candidatePlans
            )
            candidatePlans[planIndex] = attached
            try PlanHierarchy.validate(candidatePlans)
            snapshot.plans = candidatePlans
            snapshot.plans.sort { lhs, rhs in
                if lhs.span.start == rhs.span.start {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.span.start < rhs.span.start
            }
            await persist()
        } catch PlanningError.childOutsideParent {
            userFacingError = "액션아이템의 시간이 루틴 기간 안에 있어야 합니다."
        } catch PlanningError.parentCycle {
            userFacingError = "루틴의 하위 항목을 다시 연결할 수 없습니다."
        } catch {
            userFacingError = "액션아이템을 루틴에 연결하지 못했습니다."
        }
    }

    /// Attach an existing activity/actual record to a goal. This is a
    /// lightweight evidence link; it deliberately does not move the record
    /// or create a hierarchy child plan.
    func connectActualRecord(
        _ actualID: UUID,
        toGoal goalID: UUID
    ) async {
        guard let actualIndex = snapshot.actuals.firstIndex(where: {
            $0.id == actualID
        }), let goal = snapshot.plans.first(where: {
            $0.id == goalID && !$0.isFixed && $0.status != .skipped
        }) else {
            userFacingError = "연결할 실제 기록 또는 루틴을 찾지 못했습니다."
            return
        }

        let actual = snapshot.actuals[actualIndex]
        guard actual.span().intersection(with: goal.span) != nil else {
            userFacingError = "실제 기록 시간이 루틴 기간 안에 있어야 합니다."
            return
        }

        guard GoalRecordPolicy.isGoal(goal)
                || (goal.origin != .repeatRule && goal.origin != .calendar) else {
            userFacingError = "반복 세그먼트와 일정은 연결 대상으로 사용할 수 없습니다."
            return
        }

        guard !AutomaticRecordTimelineEngine.linksOnlyToRoutine(actual)
                || GoalRecordPolicy.isGoal(goal) else {
            userFacingError = "수면·활동 기록은 루틴에만 연결할 수 있습니다."
            return
        }

        if GoalRecordPolicy.isGoal(goal) {
            snapshot.actuals[actualIndex].routineID = goal.id
            snapshot.actuals[actualIndex].planID = nil
        } else {
            snapshot.actuals[actualIndex].planID = goal.id
            snapshot.actuals[actualIndex].routineID = routineAncestorID(
                for: goal.id
            )
        }
        removeRecordLinks {
            $0.fromNodeID == "automatic.actual.\(actualID.uuidString)"
        }
        await persist()
    }

    /// Create a relationship only after the user explicitly taps the source
    /// record and chooses a routine/action. Activity records use their typed
    /// fields so routine progress can count them; location/travel/calendar
    /// records are retained as generic graph links.
    func connectRecordNode(
        _ sourceNodeID: String,
        to planID: UUID
    ) async {
        guard let target = snapshot.plans.first(where: { $0.id == planID }) else {
            userFacingError = "연결할 루틴 또는 액션아이템을 찾지 못했습니다."
            return
        }
        guard GoalRecordPolicy.isGoal(target)
                || (target.origin != .repeatRule && target.origin != .calendar) else {
            userFacingError = "반복 세그먼트와 일정은 연결 대상으로 사용할 수 없습니다."
            return
        }
        let targetNodeID = "\(GoalRecordPolicy.isGoal(target) ? "routine" : "action").\(planID.uuidString)"
        guard sourceNodeID != targetNodeID else {
            userFacingError = "같은 항목에는 연결할 수 없습니다."
            return
        }

        if sourceNodeID.hasPrefix("automatic.actual."),
           let actualID = UUID(
               uuidString: String(sourceNodeID.dropFirst("automatic.actual.".count))
           ), let actualIndex = snapshot.actuals.firstIndex(where: {
               $0.id == actualID
           }) {
            guard !AutomaticRecordTimelineEngine.linksOnlyToRoutine(
                snapshot.actuals[actualIndex]
            ) || GoalRecordPolicy.isGoal(target) else {
                userFacingError = "수면·활동 기록은 루틴에만 연결할 수 있습니다."
                return
            }
            if GoalRecordPolicy.isGoal(target) {
                snapshot.actuals[actualIndex].routineID = planID
                snapshot.actuals[actualIndex].planID = nil
            } else {
                snapshot.actuals[actualIndex].planID = planID
                snapshot.actuals[actualIndex].routineID = routineAncestorID(
                    for: planID
                )
            }
            removeRecordLinks {
                $0.fromNodeID == sourceNodeID
            }
        } else {
            removeRecordLinks {
                $0.fromNodeID == sourceNodeID
            }
            snapshot.recordLinks.append(
                RecordLink(fromNodeID: sourceNodeID, toNodeID: targetNodeID)
            )
        }
        await persist()
    }

    /// Save the portion of a routine that was actually performed.  The
    /// interval is deliberately kept as a separate ActualRecord so the
    /// planned block remains intact and the dashboard can distinguish a full
    /// completion from a partial run.
    func updateRoutineActualInterval(
        planID: UUID,
        actualID: UUID? = nil,
        startedAt: Date,
        endedAt: Date?
    ) async {
        guard let planIndex = snapshot.plans.firstIndex(where: { $0.id == planID }) else {
            userFacingError = "루틴을 찾지 못했습니다."
            return
        }
        let minimumEnd = startedAt.addingTimeInterval(60)
        let normalizedEnd = endedAt.map { max(minimumEnd, $0) }
        let existingIndex = actualID.flatMap { id in
            snapshot.actuals.firstIndex(where: { $0.id == id })
        } ?? snapshot.actuals.lastIndex(where: {
            $0.planID == planID && $0.source == .manual
        })
        let routineID = routineAncestorID(for: planID)

        if let actualIndex = existingIndex {
            snapshot.actuals[actualIndex].planID = planID
            snapshot.actuals[actualIndex].routineID = routineID
            snapshot.actuals[actualIndex].startedAt = startedAt
            snapshot.actuals[actualIndex].endedAt = normalizedEnd
            snapshot.actuals[actualIndex].title = snapshot.plans[planIndex].title
            snapshot.actuals[actualIndex].categoryID = snapshot.plans[planIndex].categoryID
        } else {
            snapshot.actuals.append(
                ActualRecord(
                    planID: planID,
                    routineID: routineID,
                    title: snapshot.plans[planIndex].title,
                    categoryID: snapshot.plans[planIndex].categoryID,
                    startedAt: startedAt,
                    endedAt: normalizedEnd,
                    source: .manual,
                    confidence: .high
                )
            )
        }

        let performed = normalizedEnd.map {
            max(0, $0.timeIntervalSince(startedAt))
        } ?? 0
        let planned = snapshot.plans[planIndex].span.duration
        if planned > 0, performed >= planned * 0.999 {
            snapshot.plans[planIndex].status = .completed
        } else if snapshot.plans[planIndex].status == .completed {
            snapshot.plans[planIndex].status = .planned
        }
        snapshot.plans[planIndex].updatedAt = .now
        await persist()
    }

    private func routineAncestorID(for planID: UUID) -> UUID? {
        var currentID: UUID? = planID
        var visited = Set<UUID>()
        while let id = currentID,
              visited.insert(id).inserted,
              let plan = snapshot.plans.first(where: { $0.id == id }) {
            if GoalRecordPolicy.isGoal(plan) { return plan.id }
            currentID = plan.parentID
        }
        return nil
    }

    private static func cleanGoalRepeatRules(
        _ rules: [GoalRepeatRule]?
    ) -> [GoalRepeatRule]? {
        let cleaned = (rules ?? []).compactMap { rule -> GoalRepeatRule? in
            let weekdays = Set(rule.weekdays.filter { (1...7).contains($0) })
            guard !weekdays.isEmpty else { return nil }
            var value = rule
            value.name = Self.cleanHierarchyName(rule.name)
            value.weekdays = weekdays
            value.startMinuteOfDay = min(
                23 * 60 + 59,
                max(0, rule.startMinuteOfDay)
            )
            value.endMinuteOfDay = min(
                23 * 60 + 59,
                max(0, rule.endMinuteOfDay)
            )
            return value
        }
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func isGoalTitle(_ title: String) -> Bool {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.hasPrefix(GoalRecordPolicy.currentPrefix)
            || clean.hasPrefix(GoalRecordPolicy.legacyPrefix)
    }

    private func repeatActionItems(
        for goal: PlanRecord,
        rules: [GoalRepeatRule],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [PlanRecord] {
        guard !rules.isEmpty, goal.span.duration >= 60 else { return [] }

        let goalName = cleanGoalDisplayName(goal.title)
        let middleName = Self.cleanHierarchyName(goal.middleCategoryName)
            ?? goalName
        var cursor = calendar.startOfDay(for: goal.span.start)
        let lastDay = calendar.startOfDay(for: goal.span.end)
        var values: [PlanRecord] = []
        var safetyCounter = 0

        while cursor <= lastDay, safetyCounter < 5_000 {
            safetyCounter += 1
            let weekday = calendar.component(.weekday, from: cursor)
            for rule in rules where rule.weekdays.contains(weekday) {
                guard let rawStart = calendar.date(
                    byAdding: .minute,
                    value: rule.startMinuteOfDay,
                    to: cursor
                ) else {
                    continue
                }
                let endBase: Date
                if rule.endMinuteOfDay <= rule.startMinuteOfDay {
                    endBase = calendar.date(
                        byAdding: .day,
                        value: 1,
                        to: cursor
                    ) ?? cursor.addingTimeInterval(86_400)
                } else {
                    endBase = cursor
                }
                guard let rawEnd = calendar.date(
                    byAdding: .minute,
                    value: rule.endMinuteOfDay,
                    to: endBase
                ) else {
                    continue
                }

                let start = max(rawStart, goal.span.start)
                let end = min(rawEnd, goal.span.end)
                guard end.timeIntervalSince(start) >= 60 else {
                    continue
                }

                values.append(
                    PlanRecord(
                        title: repeatActionTitle(
                            goalName: goalName,
                            rule: rule
                        ),
                        span: TimeSpan(start: start, end: end),
                        categoryID: goal.categoryID,
                        middleCategoryName: middleName,
                        subCategoryName: repeatRuleDisplayName(rule),
                        parentID: goal.id,
                        origin: .repeatRule
                    )
                )
            }

            guard let nextDay = calendar.date(
                byAdding: .day,
                value: 1,
                to: cursor
            ) else {
                break
            }
            cursor = nextDay
        }

        return values.sorted { $0.span.start < $1.span.start }
    }

    private func cleanGoalDisplayName(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix: String
        if trimmed.hasPrefix(GoalRecordPolicy.currentPrefix) {
            prefix = GoalRecordPolicy.currentPrefix
        } else if trimmed.hasPrefix(GoalRecordPolicy.legacyPrefix) {
            prefix = GoalRecordPolicy.legacyPrefix
        } else {
            return trimmed
        }
        let clean = trimmed.dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? trimmed : String(clean)
    }

    private func repeatActionTitle(
        goalName: String,
        rule: GoalRepeatRule
    ) -> String {
        guard let ruleName = repeatRuleDisplayName(rule),
              !ruleName.isEmpty,
              ruleName != goalName else {
            return goalName
        }
        return "\(goalName) · \(ruleName)"
    }

    private func repeatRuleDisplayName(_ rule: GoalRepeatRule) -> String? {
        let clean = Self.cleanHierarchyName(rule.name)
        return clean ?? Self.repeatWeekdayText(rule.weekdays)
    }

    private static func repeatWeekdayText(_ weekdays: Set<Int>) -> String {
        let normalized = Set(weekdays.filter { (1...7).contains($0) })
        if normalized == [1, 2, 3, 4, 5, 6, 7] { return "매일" }
        if normalized == [2, 3, 4, 5, 6] { return "주중" }
        if normalized == [1, 7] { return "주말" }
        let labels = [
            2: "월", 3: "화", 4: "수", 5: "목",
            6: "금", 7: "토", 1: "일",
        ]
        return [2, 3, 4, 5, 6, 7, 1]
            .filter { normalized.contains($0) }
            .compactMap { labels[$0] }
            .joined(separator: "·")
    }

    func deletePlan(_ planID: UUID) async {
        guard let plan = snapshot.plans.first(where: {
            $0.id == planID
        }) else {
            return
        }
        let descendants = (try? PlanHierarchy.descendants(
            of: planID,
            in: snapshot.plans
        )) ?? []
        let deletedIDs = Set([planID] + descendants.map(\.id))
        invalidateReviewArchives(
            spans: ([plan] + descendants).map(\.span),
            dates: snapshot.memos.compactMap { memo in
                memo.planID.map(deletedIDs.contains) == true
                    ? memo.occurredAt
                    : nil
            }
        )
        snapshot.settings.cloudDeletedRecordKeys.formUnion(
            deletedIDs.map(CloudBackupRecordKey.plan)
        )
        snapshot.settings.cloudDeletedRecordKeys.formUnion(
            snapshot.memos.compactMap { memo in
                memo.planID.map(deletedIDs.contains) == true
                    ? CloudBackupRecordKey.memo(memo.id)
                    : nil
            }
        )
        snapshot.plans.removeAll { deletedIDs.contains($0.id) }
        snapshot.memos.removeAll {
            $0.planID.map(deletedIDs.contains) == true
        }
        snapshot.actuals = snapshot.actuals.map { actual in
            guard actual.planID.map(deletedIDs.contains) == true
                || actual.routineID.map(deletedIDs.contains) == true else {
                return actual
            }
            var preserved = actual
            if preserved.planID.map(deletedIDs.contains) == true {
                preserved.planID = nil
            }
            if preserved.routineID.map(deletedIDs.contains) == true {
                preserved.routineID = nil
            }
            return preserved
        }
        removeRecordLinks { link in
            recordNodePlanID(link.fromNodeID).map(deletedIDs.contains) == true
                || recordNodePlanID(link.toNodeID).map(deletedIDs.contains) == true
        }
        selectedGroupPlanID = nil
        groupNavigationPath.removeAll {
            deletedIDs.contains($0)
        }
        try? await liveActivityController.stop(
            plan: plan,
            catStyle: snapshot.settings.catStyle
        )
        await persist()
    }

    private func recordNodePlanID(_ nodeID: String) -> UUID? {
        for prefix in ["routine.", "action."] where nodeID.hasPrefix(prefix) {
            return UUID(uuidString: String(nodeID.dropFirst(prefix.count)))
        }
        return nil
    }

    private func removeRecordLinks(
        where shouldRemove: (RecordLink) -> Bool
    ) {
        snapshot.settings.cloudDeletedRecordKeys.formUnion(
            snapshot.recordLinks.lazy
                .filter(shouldRemove)
                .map { CloudBackupRecordKey.link($0.id) }
        )
        snapshot.recordLinks.removeAll(where: shouldRemove)
    }

    func deleteActual(_ actualID: UUID) async {
        guard let actual = snapshot.actuals.first(where: {
            $0.id == actualID
        }) else {
            userFacingError = "삭제할 실제 기록을 찾지 못했습니다."
            return
        }

        invalidateReviewArchives(spans: [actual.span()])
        snapshot.settings.suppressedActualIDs.insert(actualID)
        snapshot.actuals.removeAll { $0.id == actualID }
        removeRecordLinks {
            $0.fromNodeID == "automatic.actual.\(actualID.uuidString)"
                || $0.toNodeID == "automatic.actual.\(actualID.uuidString)"
        }

        if actual.endedAt == nil,
           let planID = actual.planID,
           let planIndex = snapshot.plans.firstIndex(where: {
               $0.id == planID
           }),
           snapshot.plans[planIndex].status == .running {
            snapshot.plans[planIndex].status = .planned
            snapshot.plans[planIndex].updatedAt = .now
            try? await liveActivityController.stop(
                plan: snapshot.plans[planIndex],
                catStyle: snapshot.settings.catStyle
            )
        }

        await persist()
    }

    func addPlanToCalendar(_ planID: UUID) async {
        guard let index = snapshot.plans.firstIndex(where: {
            $0.id == planID
        }) else {
            userFacingError = "캘린더로 보낼 계획을 찾지 못했습니다."
            return
        }
        if snapshot.plans[index].externalEventID != nil {
            return
        }
        if !permissionState(for: .calendar).isGranted {
            await requestCalendar()
        }
        guard permissionState(for: .calendar).isGranted else {
            userFacingError = "캘린더 권한을 허용해 주세요."
            return
        }
        do {
            let calendarID = snapshot.settings.selectedCalendarIDs.first
            let eventID = try calendarService.addPlan(
                snapshot.plans[index],
                to: calendarID
            )
            snapshot.plans[index].externalCalendarID = calendarID
            snapshot.plans[index].externalEventID = eventID
            snapshot.plans[index].updatedAt = .now
            refreshCalendarEvents()
            await persist()
        } catch {
            userFacingError =
                "계획을 캘린더에 추가하지 못했습니다. \(error.localizedDescription)"
        }
    }

    func movePlan(_ planID: UUID, by delta: TimeInterval) {
        guard let index = snapshot.plans.firstIndex(where: {
            $0.id == planID
        }) else {
            return
        }
        do {
            let moved = try ScheduleEditEngine.move(
                snapshot.plans[index],
                by: delta
            )
            if let parentID = moved.parentID,
               let parent = snapshot.plans.first(where: {
                   $0.id == parentID
               }),
               (moved.span.start < parent.span.start
                   || moved.span.end > parent.span.end) {
                throw PlanningError.childOutsideParent
            }

            let descendants = try PlanHierarchy.descendants(
                of: planID,
                in: snapshot.plans
            )
            let appliedDelta = moved.span.start.timeIntervalSince(
                snapshot.plans[index].span.start
            )
            snapshot.plans[index] = moved
            for descendant in descendants {
                guard let childIndex = snapshot.plans.firstIndex(where: {
                    $0.id == descendant.id
                }) else {
                    continue
                }
                snapshot.plans[childIndex] = try ScheduleEditEngine.move(
                    descendant,
                    by: appliedDelta
                )
            }
            snapshot.plans.sort { $0.span.start < $1.span.start }
            Task { await persist() }
        } catch PlanningError.fixedPlan {
            userFacingError = "캘린더의 고정 일정은 이곳에서 옮길 수 없습니다."
        } catch PlanningError.childOutsideParent {
            userFacingError = "하위 계획은 상위 루틴 기간 안에서만 옮길 수 있습니다."
        } catch {
            userFacingError = "계획을 옮기지 못했습니다."
        }
    }

    func resizePlan(
        _ planID: UUID,
        startDelta: TimeInterval? = nil,
        endDelta: TimeInterval? = nil
    ) {
        guard let index = snapshot.plans.firstIndex(where: {
            $0.id == planID
        }) else {
            return
        }
        let plan = snapshot.plans[index]
        do {
            let resized = try ScheduleEditEngine.resize(
                plan,
                newStart: startDelta.map {
                    plan.span.start.addingTimeInterval($0)
                },
                newEnd: endDelta.map {
                    plan.span.end.addingTimeInterval($0)
                }
            )
            if let parentID = resized.parentID,
               let parent = snapshot.plans.first(where: {
                   $0.id == parentID
               }),
               (resized.span.start < parent.span.start
                   || resized.span.end > parent.span.end) {
                throw PlanningError.childOutsideParent
            }
            let children = PlanHierarchy.children(of: planID, in: snapshot.plans)
            guard children.allSatisfy({
                resized.span.start <= $0.span.start
                    && $0.span.end <= resized.span.end
            }) else {
                throw PlanningError.childOutsideParent
            }
            snapshot.plans[index] = resized
            Task { await persist() }
        } catch PlanningError.childOutsideParent {
            userFacingError =
                "상위·하위 계획의 기간을 벗어나지 않도록 길이를 조절해 주세요."
        } catch {
            userFacingError = "계획 길이를 조절하지 못했습니다."
        }
    }

    @discardableResult
    func addCustomCategory(
        name: String,
        icon: CategoryIcon,
        lightHex: String
    ) -> CategoryDefinition? {
        do {
            let category = try CategoryCatalog.makeCustom(
                name: name,
                icon: icon,
                lightHex: lightHex,
                existing: snapshot.categories
            )
            snapshot.categories.append(category)
            snapshot.categories.sort { $0.sortOrder < $1.sortOrder }
            Task { await persist() }
            return category
        } catch {
            userFacingError = "대분류를 추가하지 못했습니다. \(error.localizedDescription)"
            return nil
        }
    }

    func updateCategory(
        _ categoryID: String,
        name: String,
        icon: CategoryIcon,
        lightHex: String,
        hidden: Bool
    ) {
        guard let index = snapshot.categories.firstIndex(where: {
            $0.id == categoryID
        }) else {
            return
        }
        let cleanName = name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !snapshot.categories.contains(where: {
            $0.id != categoryID
                && $0.name.localizedCaseInsensitiveCompare(cleanName)
                    == .orderedSame
        }) else {
            userFacingError = "같은 이름의 대분류가 이미 있습니다."
            return
        }
        do {
            snapshot.categories[index] = try CategoryCatalog.update(
                snapshot.categories[index],
                name: cleanName,
                icon: icon,
                lightHex: lightHex,
                hidden: hidden
            )
            Task { await persist() }
        } catch {
            userFacingError =
                "대분류를 수정하지 못했습니다. \(error.localizedDescription)"
        }
    }

    func moveCategory(_ categoryID: String, by offset: Int) {
        let sorted = snapshot.categories.sorted {
            $0.sortOrder < $1.sortOrder
        }
        guard let index = sorted.firstIndex(where: {
            $0.id == categoryID
        }) else {
            return
        }
        let destination = index + offset
        guard sorted.indices.contains(destination) else { return }
        var orderedIDs = sorted.map(\.id)
        orderedIDs.swapAt(index, destination)
        applyCategoryOrder(orderedIDs)
    }

    func moveCategories(
        fromOffsets source: IndexSet,
        toOffset destination: Int
    ) {
        snapshot.categories = CategoryCatalog.moving(
            snapshot.categories,
            fromOffsets: source,
            toOffset: destination
        )
        Task { await persist() }
    }

    private func applyCategoryOrder(_ orderedIDs: [String]) {
        snapshot.categories = CategoryCatalog.reordered(
            snapshot.categories,
            orderedIDs: orderedIDs
        )
        Task { await persist() }
    }

    func setTimelineRowOrder(_ orderedIDs: [String]) {
        let normalized = AppFeatureSettings.normalizedTimelineRowOrder(
            orderedIDs
        )
        guard snapshot.settings.timelineRowOrder != normalized else {
            return
        }
        snapshot.settings.timelineRowOrder = normalized
        Task { await persist() }
    }

    func deleteCustomCategory(
        _ categoryID: String,
        reassigningTo replacementID: String
    ) {
        do {
            let result = try CategoryCatalog.deleting(
                categoryID: categoryID,
                reassigningTo: replacementID,
                categories: snapshot.categories,
                plans: snapshot.plans,
                actuals: snapshot.actuals
            )
            snapshot.categories = result.categories
            snapshot.plans = result.plans
            snapshot.actuals = result.actuals
            Task { await persist() }
        } catch {
            userFacingError =
                "대분류를 삭제하지 못했습니다. \(error.localizedDescription)"
        }
    }

    func performQuickAction(
        _ action: WidgetAction,
        planID: UUID,
        at date: Date = .now
    ) async {
        guard let index = snapshot.plans.firstIndex(where: { $0.id == planID }) else {
            userFacingError = "선택한 계획을 찾지 못했습니다."
            return
        }
        let plan = snapshot.plans[index]
        do {
            switch action {
            case .complete, .stopCurrentActivity:
                let result = QuickActionEngine.complete(
                    plan: plan,
                    actuals: snapshot.actuals,
                    at: date,
                    copyPlannedDurationWhenMissing: action == .complete
                )
                snapshot.plans[index] = result.plan
                snapshot.actuals = result.actuals
                try? await liveActivityController.stop(
                    plan: result.plan,
                    catStyle: snapshot.settings.catStyle
                )
            case .postponeThirtyMinutes:
                snapshot.plans[index] = try QuickActionEngine.postpone(plan: plan)
            case .moveToNextFreeTime:
                let occupied = snapshot.plans
                    .filter { $0.id != planID && $0.status != .skipped }
                    .map(\.span)
                    + snapshot.calendarEvents.map(\.span)
                snapshot.plans[index] = try QuickActionEngine.moveToNextFreeTime(
                    plan: plan,
                    occupied: occupied,
                    after: date
                )
            }
            await persist()
        } catch {
            userFacingError = "계획을 처리하지 못했습니다. \(error.localizedDescription)"
        }
    }

    func startPlan(_ planID: UUID, at date: Date = .now) async {
        guard let index = snapshot.plans.firstIndex(where: { $0.id == planID }) else {
            userFacingError = "선택한 계획을 찾지 못했습니다."
            return
        }
        let result = QuickActionEngine.start(
            plan: snapshot.plans[index],
            actuals: snapshot.actuals,
            at: date
        )
        snapshot.plans[index] = result.plan
        snapshot.actuals = result.actuals
        do {
            _ = try await liveActivityController.start(
                plan: result.plan,
                catStyle: snapshot.settings.catStyle
            )
        } catch LiveActivityError.unavailable {
            // The plan timer still works when Live Activities are disabled.
        } catch {
            userFacingError = "Live Activity를 시작하지 못했습니다. \(error.localizedDescription)"
        }
        await persist()
    }

    func pausePlan(_ planID: UUID, at date: Date = .now) async {
        guard let index = snapshot.plans.firstIndex(where: { $0.id == planID }) else {
            userFacingError = "선택한 계획을 찾지 못했습니다."
            return
        }
        snapshot.plans[index].status = .planned
        snapshot.plans[index].updatedAt = date
        if let actualIndex = snapshot.actuals.lastIndex(where: {
            $0.planID == planID && $0.endedAt == nil
        }) {
            snapshot.actuals[actualIndex].endedAt = max(
                snapshot.actuals[actualIndex].startedAt,
                date
            )
        }
        try? await liveActivityController.stop(
            plan: snapshot.plans[index],
            catStyle: snapshot.settings.catStyle
        )
        await persist()
    }

    func skipPlan(_ planID: UUID) async {
        guard let index = snapshot.plans.firstIndex(where: { $0.id == planID }) else {
            userFacingError = "선택한 계획을 찾지 못했습니다."
            return
        }
        snapshot.plans[index] = QuickActionEngine.skip(plan: snapshot.plans[index])
        await persist()
    }

    private func applyWatchCommand(_ command: TaptionWatchCommand) async {
        switch command.kind {
        case .start:
            await startPlan(command.planID, at: command.requestedAt)
        case .complete:
            await performQuickAction(
                .complete,
                planID: command.planID,
                at: command.requestedAt
            )
        case .postponeThirtyMinutes:
            await performQuickAction(
                .postponeThirtyMinutes,
                planID: command.planID,
                at: command.requestedAt
            )
        case .skip:
            await skipPlan(command.planID)
        case .stopCurrentActivity:
            await performQuickAction(
                .stopCurrentActivity,
                planID: command.planID,
                at: command.requestedAt
            )
        }
    }

    private func applyWatchSensorSummary(
        _ summary: TaptionWatchSensorSummary
    ) async {
        if summary.isFinal {
            if activeTrackingSession?.id == summary.sessionID {
                activeTrackingSession = nil
                trackingSessionWasRecovered = false
                liveRouteState.session = nil
            }
            TrackingSessionRecoveryStore.clear()
            lastTrackingSessionRecoveryPersistAt = nil
        } else if summary.isAmbient != true,
                  activeTrackingSession?.id != summary.sessionID {
            let kind: TrackingKind = summary.workoutKind == .running
                ? .running
                : .walking
            let session = TrackingSession(
                id: summary.sessionID,
                kind: kind,
                startedAt: summary.startedAt,
                linkedPlanID: summary.linkedPlanID,
                sourceDevice: .appleWatch,
                iPhoneActive: false,
                watchActive: true,
                wasAutomaticallyDetected: false
            )
            activeTrackingSession = session
            liveRouteState = LiveRouteState(
                session: session,
                readings: [],
                lastUpdatedAt: summary.endedAt
            )
            TrackingSessionRecoveryStore.save(session)
            lastTrackingSessionRecoveryPersistAt = summary.endedAt
        }
        archiveRawDeviceData(
            source: .appleWatch,
            kind: "watch-sensor-summary",
            payload: summary,
            capturedAt: summary.endedAt
        )
        if let watchSensorArchive {
            do {
                try await watchSensorArchive.record(summary)
            } catch {
                userFacingError =
                    "Apple Watch 센서 기록을 저장하지 못했습니다. "
                    + error.localizedDescription
            }
        }
        let atHome = isWatchSummaryAtHome(summary)
        let resolution = WatchActivityPersonalizationEngine.resolve(
            summary,
            atHome: atHome,
            learnedSamples: WatchActivityLearningStore.read()
        )
        var interpretedSummary = summary
        if let learned = resolution.learnedBehavior {
            interpretedSummary.behavior = learned.kind
            interpretedSummary.behaviorConfidenceScore = learned.confidenceScore
            interpretedSummary.behaviorEvidence = Array(Set(
                (summary.behaviorEvidence ?? []) + learned.evidence
            )).sorted()
            interpretedSummary.behaviorModelVersion = learned.modelVersion
        }
        let previousSuggestion = pendingWatchActivitySuggestion
        if let suggestion = resolution.suggestion {
            pendingWatchActivitySuggestion = mergingWatchSuggestion(suggestion)
        } else if resolution.learnedBehavior != nil
                    || (pendingWatchActivitySuggestion?.sensorSessionID
                        == summary.sessionID && summary.isFinal) {
            pendingWatchActivitySuggestion = nil
        }
        if previousSuggestion != pendingWatchActivitySuggestion {
            publishWatchPayload()
        }
        if summary.isAmbient != true, let sensorService {
            let routePoints = summary.routePoints ?? []
            let watchAccelerationAverageG = summary.accelerometerAverageG.map {
                SensorVector3(x: $0.x, y: $0.y, z: $0.z)
            }
            let routeSpeeds = routePoints.compactMap(\.speedMetersPerSecond)
                .filter { $0.isFinite && $0 >= 0 }
            let routeAverageSpeed = routeSpeeds.isEmpty
                ? nil
                : routeSpeeds.reduce(0, +) / Double(routeSpeeds.count)
            let behavior = summary.behavior.map {
                WatchBehaviorInference(
                    kind: $0,
                    confidenceScore: summary.behaviorConfidenceScore ?? 0.5,
                    evidence: summary.behaviorEvidence ?? [],
                    modelVersion: summary.behaviorModelVersion
                        ?? WatchBehaviorClassifier.rulesVersion
                )
            } ?? WatchBehaviorClassifier.classify(
                WatchBehaviorInput(
                    workoutKind: summary.workoutKind,
                    duration: summary.endedAt.timeIntervalSince(
                        summary.startedAt
                    ),
                    accelerometerSampleCount: summary.accelerometerSampleCount,
                    accelerometerStandardDeviationG:
                        summary.accelerometerStandardDeviationG,
                    accelerometerMeanJerkGPerSecond:
                        summary.accelerometerMeanJerkGPerSecond,
                    peakAccelerationG: summary.peakAccelerationG,
                    peakRotationRateRadiansPerSecond:
                        summary.peakRotationRateRadiansPerSecond,
                    steps: summary.stepCount,
                    distanceMeters: summary.distanceMeters,
                    floorsAscended: summary.floorsAscended,
                    floorsDescended: summary.floorsDescended,
                    averageHeartRate: summary.averageHeartRate,
                    gpsAverageSpeedMetersPerSecond: routeAverageSpeed,
                    gpsAvailable: !routePoints.isEmpty,
                    gpsLossRatio: routePoints.isEmpty ? 1 : 0
                )
            )
            let watchMotion: MotionKind = switch behavior.kind {
            case .running: .running
            case .walking, .stairsUp, .stairsDown: .walking
            case .cycling: .cycling
            case .automotive, .publicTransit, .subway: .automotive
            case .stationary, .standing, .sitting, .lying, .elevator,
                 .exercise, .brushingTeeth, .eating, .typing, .housework,
                 .showering,
                 .sleep, .unknown:
                .stationary
            }
            let behaviorSegments = summary.behaviorSegments ?? []
            func behaviorAt(_ date: Date) -> WatchBehaviorInference {
                guard let segment = behaviorSegments.first(where: {
                    $0.startedAt <= date && date < $0.endedAt
                }) else { return behavior }
                return WatchBehaviorInference(
                    kind: segment.behavior,
                    confidenceScore: segment.confidenceScore,
                    evidence: segment.evidence,
                    modelVersion: segment.modelVersion
                )
            }
            func motionKind(for inference: WatchBehaviorInference) -> MotionKind {
                switch inference.kind {
                case .running: .running
                case .walking, .stairsUp, .stairsDown: .walking
                case .cycling: .cycling
                case .automotive, .publicTransit, .subway: .automotive
                default: .stationary
                }
            }
            var readings = routePoints.enumerated().map { offset, point in
                let pointBehavior = behaviorAt(point.capturedAt)
                return SensorReading(
                    id: point.id,
                    timestamp: point.capturedAt,
                    point: GeoPoint(
                        latitude: point.latitude,
                        longitude: point.longitude,
                        altitude: point.altitude,
                        horizontalAccuracy: point.horizontalAccuracy,
                        verticalAccuracy: point.verticalAccuracy
                    ),
                    speedMetersPerSecond: point.speedMetersPerSecond,
                    courseDegrees: point.courseDegrees,
                    motion: motionKind(for: pointBehavior),
                    motionConfidence: ConfidenceLevel(
                        score: pointBehavior.confidenceScore
                    ),
                    relativeAltitudeMeters: summary.relativeAltitudeMeters,
                    pressureKilopascals: summary.pressureKilopascals,
                    floorsAscended: summary.floorsAscended,
                    floorsDescended: summary.floorsDescended,
                    stepCount: summary.stepCount,
                    walkingRunningDistanceMeters: summary.distanceMeters,
                    watchAccelerationAverageG: watchAccelerationAverageG,
                    watchAccelerationStandardDeviationG:
                        summary.accelerometerStandardDeviationG,
                    watchAccelerationMeanJerkGPerSecond:
                        summary.accelerometerMeanJerkGPerSecond,
                    gpsAvailable: true,
                    watchWorkoutKind: summary.workoutKind.rawValue,
                    behavior: pointBehavior.kind.rawValue,
                    behaviorConfidenceScore: pointBehavior.confidenceScore,
                    behaviorEvidence: pointBehavior.evidence,
                    behaviorModelVersion: pointBehavior.modelVersion,
                    trackingSessionID: summary.sessionID,
                    trackingKind: summary.workoutKind == .running
                        ? .running
                        : .walking,
                    sourceDevice: .appleWatch,
                    sequence: summary.sequence * 10_000 + offset,
                    trackingSessionEnded: false
                )
            }
            if readings.isEmpty,
               summary.accelerometerSampleCount > 0,
               !summary.isFinal {
                readings.append(
                    SensorReading(
                        id: summary.isFinal ? summary.sessionID : UUID(),
                        timestamp: summary.endedAt,
                        motion: watchMotion,
                        motionConfidence: .medium,
                        relativeAltitudeMeters: summary.relativeAltitudeMeters,
                        pressureKilopascals: summary.pressureKilopascals,
                        floorsAscended: summary.floorsAscended,
                        floorsDescended: summary.floorsDescended,
                        stepCount: summary.stepCount,
                        walkingRunningDistanceMeters: summary.distanceMeters,
                        watchAccelerationAverageG: watchAccelerationAverageG,
                        watchAccelerationStandardDeviationG:
                            summary.accelerometerStandardDeviationG,
                        watchAccelerationMeanJerkGPerSecond:
                            summary.accelerometerMeanJerkGPerSecond,
                        gpsAvailable: false,
                        watchWorkoutKind: summary.workoutKind.rawValue,
                        behavior: behavior.kind.rawValue,
                        behaviorConfidenceScore: behavior.confidenceScore,
                        behaviorEvidence: behavior.evidence,
                        behaviorModelVersion: behavior.modelVersion,
                        trackingSessionID: summary.sessionID,
                        trackingKind: summary.workoutKind == .running
                            ? .running
                            : .walking,
                        sourceDevice: .appleWatch,
                        sequence: summary.sequence * 10_000,
                        trackingSessionEnded: summary.isFinal
                    )
                )
            }
            if summary.isFinal {
                readings.append(
                    SensorReading(
                        id: summary.sessionID,
                        timestamp: summary.endedAt,
                        motion: watchMotion,
                        motionConfidence: ConfidenceLevel(
                            score: behavior.confidenceScore
                        ),
                        relativeAltitudeMeters: summary.relativeAltitudeMeters,
                        pressureKilopascals: summary.pressureKilopascals,
                        floorsAscended: summary.floorsAscended,
                        floorsDescended: summary.floorsDescended,
                        stepCount: summary.stepCount,
                        walkingRunningDistanceMeters: summary.distanceMeters,
                        watchAccelerationAverageG: watchAccelerationAverageG,
                        watchAccelerationStandardDeviationG:
                            summary.accelerometerStandardDeviationG,
                        watchAccelerationMeanJerkGPerSecond:
                            summary.accelerometerMeanJerkGPerSecond,
                        gpsAvailable: false,
                        watchWorkoutKind: summary.workoutKind.rawValue,
                        behavior: behavior.kind.rawValue,
                        behaviorConfidenceScore: behavior.confidenceScore,
                        behaviorEvidence: behavior.evidence,
                        behaviorModelVersion: behavior.modelVersion,
                        trackingSessionID: summary.sessionID,
                        trackingKind: summary.workoutKind == .running
                            ? .running
                            : .walking,
                        sourceDevice: .appleWatch,
                        sequence: summary.sequence * 10_000 + routePoints.count,
                        trackingSessionEnded: true
                    )
                )
            }
            do {
                try await sensorService.recordExternalReadings(readings)
            } catch {
                Self.integrationLogger.error(
                    "Watch route archive failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        let linkedPlan = summary.linkedPlanID.flatMap { planID in
            snapshot.plans.first { $0.id == planID }
        }
        if resolution.suggestion == nil {
            snapshot.actuals = AppleWatchSensorActivityEngine.upserting(
                interpretedSummary,
                into: snapshot.actuals,
                linkedPlan: linkedPlan,
                atHome: atHome
            )
        } else {
            // 답변 전에는 후보를 최종 활동으로 보이지 않는다. 원시 센서와
            // 요약 아카이브는 위에서 이미 보존했다.
            snapshot.actuals.removeAll {
                $0.source == .appleWatch
                    && !$0.manuallyCorrected
                    && ($0.id == summary.sessionID
                        || $0.sensorChunkID == summary.sessionID)
            }
        }
        snapshot.actuals = ActualRecordSuppressionEngine.visibleRecords(
            from: snapshot.actuals,
            suppressedIDs: snapshot.settings.suppressedActualIDs
        )
        await persistDeviceLocalSnapshot()
    }

    /// Watch의 답을 파생 기록과 개인화 표본에 반영한다. 원시 센서 아카이브는
    /// 수정하지 않으며 같은 패턴이 충분히 쌓이기 전까지 자동 확정하지 않는다.
    private func applyWatchActivityConfirmation(
        _ confirmation: TaptionWatchActivityConfirmation
    ) async {
        guard !WatchActivityConfirmationStore.read().contains(where: {
            $0.id == confirmation.id
        }) else { return }
        WatchActivityConfirmationStore.append(confirmation)
        let suggestion = pendingWatchActivitySuggestion.flatMap {
            confirmation.suggestionID == nil
                || $0.id == confirmation.suggestionID ? $0 : nil
        }
        let label = confirmation.isCorrect
            ? confirmation.observedBehavior
            : confirmation.correctedBehavior
        if let label, let pattern = confirmation.pattern ?? suggestion?.pattern {
            WatchActivityLearningStore.append(
                WatchActivityPatternSample(
                    id: confirmation.id,
                    capturedAt: confirmation.respondedAt,
                    pattern: pattern,
                    label: label
                )
            )
        }
        if let label,
           let sessionID = confirmation.sensorSessionID
                ?? suggestion?.sensorSessionID {
            let previous = snapshot.actuals.first {
                $0.id == sessionID && $0.source == .appleWatch
            }
            snapshot.actuals.removeAll {
                $0.source == .appleWatch
                    && !$0.manuallyCorrected
                    && ($0.id == sessionID || $0.sensorChunkID == sessionID)
            }
            snapshot.actuals.append(
                ActualRecord(
                    id: sessionID,
                    planID: nil,
                    title: label.title,
                    categoryID: watchCategoryID(for: label),
                    startedAt: confirmation.observedStartedAt,
                    endedAt: confirmation.observedEndedAt,
                    source: .appleWatch,
                    confidence: .high,
                    createdAt: previous?.createdAt
                        ?? confirmation.observedStartedAt,
                    behavior: label.rawValue,
                    evidence: Array(Set(
                        (suggestion?.evidence ?? []) + ["사용자 확인"]
                    )).sorted(),
                    sensorChunkID: sessionID,
                    modelVersion:
                        WatchActivityPersonalizationEngine.modelVersion,
                    manuallyCorrected: true
                )
            )
            snapshot.actuals.sort { $0.startedAt < $1.startedAt }
        }
        if confirmation.suggestionID == nil
            || pendingWatchActivitySuggestion?.id == confirmation.suggestionID {
            pendingWatchActivitySuggestion = nil
        }
        Self.integrationLogger.notice(
            "Watch activity confirmation received: correct=\(confirmation.isCorrect, privacy: .public)"
        )
        await persistDeviceLocalSnapshot()
    }

    private func mergingWatchSuggestion(
        _ candidate: TaptionWatchActivitySuggestion
    ) -> TaptionWatchActivitySuggestion {
        guard let current = pendingWatchActivitySuggestion,
              current.sensorSessionID == candidate.sensorSessionID,
              current.proposedBehavior == candidate.proposedBehavior,
              candidate.startedAt <= current.endedAt.addingTimeInterval(10 * 60)
        else { return candidate }
        var merged = candidate
        merged.id = current.id
        merged.startedAt = min(current.startedAt, candidate.startedAt)
        merged.evidence = Array(Set(current.evidence + candidate.evidence))
            .sorted()
        return merged
    }

    private func watchCategoryID(for behavior: WatchBehaviorKind) -> String {
        if behavior.isMovement { return "movement" }
        if behavior == .sleep { return "sleep" }
        return "activity"
    }

    private func applyWatchHealthSnapshot(
        _ snapshot: TaptionWatchHealthSnapshot
    ) async {
        archiveRawDeviceData(
            source: .appleWatch,
            kind: "watch-health-snapshot",
            payload: snapshot,
            capturedAt: snapshot.capturedAt
        )
        await persistDeviceLocalSnapshot()
    }

    private func isWatchSummaryAtHome(
        _ summary: TaptionWatchSensorSummary
    ) -> Bool {
        let homes = snapshot.settings.frequentPlaces.filter {
            $0.kind == .home && $0.point != nil
                && $0.isAutomaticRecordingEnabled
        }
        guard !homes.isEmpty else { return false }
        let span = TimeSpan(start: summary.startedAt, end: summary.endedAt)
        if snapshot.places.contains(where: { place in
            guard place.span.intersection(with: span) != nil else { return false }
            return homes.contains { home in
                place.displayName == home.name
                    || place.placeKey == home.stablePlaceKey
            }
        }) {
            return true
        }
        if summary.routePoints?.contains(where: { point in
            let coordinate = GeoPoint(
                latitude: point.latitude,
                longitude: point.longitude,
                altitude: point.altitude,
                horizontalAccuracy: point.horizontalAccuracy,
                verticalAccuracy: point.verticalAccuracy
            )
            return homes.contains {
                guard let homePoint = $0.point else { return false }
                return distanceMeters(coordinate, homePoint) <= $0.radiusMeters
            }
        }) == true {
            return true
        }
        guard let latestSensorReading,
              let point = latestSensorReading.point,
              abs(latestSensorReading.timestamp.timeIntervalSince(summary.endedAt)) <= 10 * 60 else {
            return false
        }
        return homes.contains {
            guard let homePoint = $0.point else { return false }
            return distanceMeters(point, homePoint) <= $0.radiusMeters
        }
    }

    private func archiveRawDeviceData<T: Encodable>(
        source: RawDeviceDataSource,
        kind: String,
        payload: T,
        capturedAt: Date = .now
    ) {
        guard let rawDeviceDataArchive else { return }
        do {
            let envelope = try RawDeviceDataEnvelope(
                capturedAt: capturedAt,
                source: source,
                kind: kind,
                payload: payload
            )
            try rawDeviceDataArchive.append(envelopes: [envelope])
        } catch {
            Self.integrationLogger.error(
                "Raw device data archive failed: \(kind, privacy: .public) \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// 이번 갱신이 실제로 신호를 들여다본 구간. 사진·건강 앱에서 메운 점은
    /// 연속 수집이 아니라 드문드문한 복원이므로 근거로 세지 않는다.
    private static func sensorEvidenceSpan(
        readings: [SensorReading],
        activities: [MotionActivityRecord],
        inside span: TimeSpan
    ) -> TimeSpan? {
        let moments = readings.map(\.timestamp)
            + activities.flatMap { [$0.span.start, $0.span.end] }
        guard let start = moments.min(), let end = moments.max() else {
            return nil
        }
        return TimeSpan(start: start, end: end).intersection(with: span)
    }

    /// 정지 구간을 "정지·휴식" 한 덩어리로 남기지 않고 장소·캘린더·시간
    /// 문맥으로 바꾼다. 새 권한이나 새 수집 없이 이미 모은 신호만 쓴다.
    private func applyStationaryContextRecords(
        stays: [PlaceStay],
        stationarySpans: [TimeSpan],
        travel: [TravelSegment],
        readings: [SensorReading],
        evidence: TimeSpan?,
        inside span: TimeSpan
    ) async {
        let watchSummaries: [TaptionWatchSensorSummary]
        if let watchSensorArchive {
            watchSummaries =
                (try? await watchSensorArchive.summaries(in: span)) ?? []
        } else {
            watchSummaries = []
        }
        let contextRecords = StationaryContextActualEngine.records(
            stays: stays,
            placeKinds: FrequentPlaceResolutionEngine()
                .kindsByPlaceKey(settings.frequentPlaces),
            placeAnchors: FrequentPlaceResolutionEngine()
                .anchorsByPlaceKey(settings.frequentPlaces),
            stationarySpans: stationarySpans,
            readings: readings,
            calendarEvents: snapshot.calendarEvents,
            actuals: snapshot.actuals,
            travel: travel.filter {
                $0.span.intersection(with: span) != nil
            },
            watchSummaries: watchSummaries,
            inside: span
        ).filter { !snapshot.settings.suppressedActualIDs.contains($0.id) }
        // 판독은 7일만 남는다. 그보다 오래된 날을 열면 문맥을 다시 만들 근거가
        // 없는데, 그때 저장된 기록까지 지우면 되살릴 길이 없다. 이번 갱신이
        // 실제로 들여다본 구간과 새로 만든 기록의 구간만 갈아끼운다.
        let refreshed = contextRecords.map { $0.span(asOf: span.end) }
            + [evidence].compactMap { $0?.intersection(with: span) }
        snapshot.actuals.removeAll { actual in
            guard actual.source == .location,
                  actual.modelVersion
                    == StationaryContextClassifier.modelVersion else {
                return false
            }
            let stored = actual.span(asOf: span.end)
            return refreshed.contains {
                $0.intersection(with: stored) != nil
            }
        }
        guard !contextRecords.isEmpty else { return }
        snapshot.actuals = StationaryContextActualEngine
            .suppressingStationaryMotion(
                snapshot.actuals,
                coveredBy: contextRecords,
                asOf: span.end
            ) + contextRecords
        snapshot.actuals.sort { $0.startedAt < $1.startedAt }
    }

    func refreshSensorTimeline(containing date: Date? = nil) async {
        guard let sensorService else { return }
        let span = TimelineAggregationEngine().interval(
            for: .day,
            containing: date ?? selectedDate
        )
        let archivedReadings: [SensorReading]
        TaptionPlanDiagnosticsLogger.shared.record(
            "sensor_timeline_refresh_started"
        )
        do {
            archivedReadings = try await sensorService.archivedReadings(
                in: span
            )
        } catch {
            TaptionPlanDiagnosticsLogger.shared.record(
                "sensor_timeline_read_failed",
                level: .error,
                fields: ["error": String(describing: type(of: error))]
            )
            userFacingError =
                "위치 기록을 읽지 못했습니다. \(error.localizedDescription)"
            return
        }
        if Calendar.autoupdatingCurrent.isDate(span.start, inSameDayAs: .now),
           let latest = archivedReadings.max(by: {
               $0.timestamp < $1.timestamp
           }) {
            // Seed the live map anchor when the app is reopened before the
            // next Core Location callback arrives. Historical-day refreshes
            // must never replace the current-location anchor.
            latestSensorReading = latest
        }
        let motionActivities =
            (try? await sensorService.motionActivities(in: span)) ?? []
        TaptionPlanDiagnosticsLogger.shared.record(
            "sensor_timeline_evidence_loaded",
            fields: [
                "gps": String(archivedReadings.count),
                "motion": String(motionActivities.count),
            ]
        )
        let pedometer =
            try? await sensorService.pedometerSummary(in: span)
        let iPhonePedometerEvidence =
            await sensorService.pedometerEvidence(for: motionActivities)
        let healthKitMovementEvidence: [AppleMovementEvidence]
        if settings.healthEnabled {
            healthKitMovementEvidence =
                (try? await healthService.movementEvidence(in: span)) ?? []
        } else {
            healthKitMovementEvidence = []
        }
        let refreshFingerprint = SensorRefreshFingerprint(
            readingCount: archivedReadings.count,
            latestReadingID: archivedReadings.last?.id,
            latestMotionEnd: motionActivities.map(\.span.end).max(),
            pedometerEnd: pedometer?.span.end,
            latestHealthEvidenceEnd: healthKitMovementEvidence
                .map(\.span.end)
                .max(),
            settingsHash: settings.hashValue
        )
        let latestReadingWithPoint = archivedReadings
            .filter { $0.point != nil }
            .max { $0.timestamp < $1.timestamp }
        let fingerprintUnchanged =
            sensorRefreshFingerprints[span.start] == refreshFingerprint
        if fingerprintUnchanged {
            guard (settings.locationEnabled || settings.weatherEnabled),
                  weatherNeedsRefresh(for: latestReadingWithPoint) else {
                return
            }
            await refreshWeather(
                for: snapshot.places.filter {
                    $0.span.intersection(with: span) != nil
                },
                in: span,
                fallbackReading: latestReadingWithPoint
            )
            return
        }
        sensorRefreshFingerprints[span.start] = refreshFingerprint
        if !motionActivities.isEmpty {
            let existingAutomatic = snapshot.actuals.filter {
                $0.source != .motion
            }
            let generatedMotionActuals = MotionActivityActualEngine.records(
                from: motionActivities,
                existing: existingAutomatic,
                inside: span
            ).filter {
                    !snapshot.settings.suppressedActualIDs.contains($0.id)
            }
            Self.integrationLogger.notice(
                "Motion history refresh: activities=\(motionActivities.count, privacy: .public), generated=\(generatedMotionActuals.count, privacy: .public), spanStart=\(span.start.timeIntervalSince1970, privacy: .public), observationEnd=\(min(span.end, Date.now).timeIntervalSince1970, privacy: .public)"
            )
            snapshot.actuals.removeAll {
                $0.source == .motion
                    && $0.modelVersion
                        != ChargingInactivitySleepEngine.modelVersion
                    && $0.span(asOf: span.end).intersection(with: span) != nil
            }
            snapshot.actuals.append(contentsOf: generatedMotionActuals)
            snapshot.actuals.sort { $0.startedAt < $1.startedAt }
        }
        archiveRawDeviceData(
            source: .iPhoneMotion,
            kind: "motion-activities",
            payload: motionActivities,
            capturedAt: span.end
        )
        if let pedometer {
            archiveRawDeviceData(
                source: .iPhonePedometer,
                kind: "pedometer-summary",
                payload: pedometer,
                capturedAt: span.end
            )
        }
        archiveRawDeviceData(
            source: .healthKit,
            kind: "movement-evidence",
            payload: healthKitMovementEvidence,
            capturedAt: span.end
        )
        let healthMovementEvidence =
            iPhonePedometerEvidence + healthKitMovementEvidence
        let photoLocationReadings = photoBackfillReadings(
            in: span,
            existingReadings: archivedReadings
        )
        // 다른 앱·Apple Watch가 HealthKit에 남긴 경로로 빈 구간을 채운다.
        let healthRouteReadings: [SensorReading]
        if settings.healthEnabled {
            healthRouteReadings = HealthRouteMergeEngine.merging(
                (try? await healthService.workoutRouteReadings(in: span)) ?? [],
                into: archivedReadings
            )
        } else {
            healthRouteReadings = []
        }
        if archivedReadings.isEmpty,
           photoLocationReadings.isEmpty,
           healthRouteReadings.isEmpty,
           motionActivities.isEmpty,
           healthMovementEvidence.isEmpty {
            return
        }

        var readings = AppleDeviceGroundTruthEngine
            .applyingMotionHistory(
                to: (
                    archivedReadings
                        + photoLocationReadings
                        + healthRouteReadings
                ).sorted { $0.timestamp < $1.timestamp },
                activities: motionActivities
            )
        readings = await transportContextService.enriching(readings)
        let knownPlaces = snapshot.places
        let knownNames = knownPlaces.reduce(into: [String: String]()) {
            $0[$1.placeKey] = $1.displayName
        }
        var detectedPlaces = PlaceDetectionEngine().detectStays(
            readings: readings,
            knownNames: knownNames
        )
        for index in detectedPlaces.indices
            where detectedPlaces[index].displayName == "자동 감지 장소" {
            guard let point = detectedPlaces[index].point,
                  let name = await placeNameResolver.displayName(
                      latitude: point.latitude,
                      longitude: point.longitude
                  ) else {
                continue
            }
            detectedPlaces[index].displayName = name
        }

        detectedPlaces = FrequentPlaceResolutionEngine().applying(
            settings.frequentPlaces,
            to: detectedPlaces,
            readings: readings
        )

        let floorTimeline = FloorTimelineEngine().apply(
            readings: readings,
            to: detectedPlaces,
            knownPlaces: knownPlaces
        )
        let basePlaces = floorTimeline.places
        let walkingLocations = WalkingLocationEngine()
            .build(readings: readings)
            .filter { walkingLocation in
                !basePlaces.contains { place in
                    guard let placePoint = place.point,
                          let walkingPoint = walkingLocation.point,
                          place.span.intersection(
                              with: walkingLocation.span
                          ) != nil else {
                        return false
                    }
                    return distanceMeters(placePoint, walkingPoint) <= 100
                }
            }
        let places = basePlaces + walkingLocations
        let floors = floorTimeline.transitions
        let inferredTravel = AppleDeviceGroundTruthEngine.mergingTravel(
            gpsSegments: MovementRouteBuilder().build(
                stays: basePlaces,
                readings: readings,
                healthEvidence: healthMovementEvidence
            ),
            motionActivities: motionActivities,
            pedometer: pedometer,
            healthEvidence: healthMovementEvidence,
            readings: readings
        )
        let travel = AppleDeviceGroundTruthEngine.coalescingTravel(
            AppleDeviceGroundTruthEngine.resolvingOverlaps(
                AppleDeviceGroundTruthEngine.enforcingMotionFamily(
                    MovementCorrectionEngine.applying(
                        snapshot.settings.movementCorrections,
                        to: inferredTravel,
                        places: basePlaces
                    ),
                    activities: motionActivities,
                    readings: readings
                )
            ),
            stays: basePlaces,
            maximumGap: max(
                5 * 60,
                snapshot.settings.sensorCollectionProfile.interval + 60
            )
        )

        // A photo location is only a fallback anchor. It must not erase a
        // previously recorded route when the sensor archive is temporarily
        // unavailable. HealthKit workout routes are valid primary evidence.
        let hasPrimaryLocationEvidence = archivedReadings.contains {
            $0.point != nil
        } || healthRouteReadings.contains {
            $0.point != nil
        }

        if hasPrimaryLocationEvidence {
            snapshot.travel.removeAll {
                $0.span.intersection(with: span) != nil
            }
            snapshot.places.removeAll {
                $0.span.intersection(with: span) != nil
            }
            snapshot.floorTransitions.removeAll {
                $0.span.intersection(with: span) != nil
            }
            snapshot.places.append(contentsOf: places)
            snapshot.floorTransitions.append(contentsOf: floors)
            snapshot.travel.append(contentsOf: travel)
        }
        snapshot.places.sort { $0.span.start < $1.span.start }
        snapshot.travel.sort { $0.span.start < $1.span.start }
        snapshot.floorTransitions.sort { $0.span.start < $1.span.start }

        // 이번 갱신에서 만든 이동과 장소를 모두 확정한 다음에 정지 구간
        // 문맥을 붙인다. 예전 이동만 보고 있으면 "대기"를 찾을 수 없었다.
        await applyStationaryContextRecords(
            stays: places,
            stationarySpans: motionActivities
                .filter { $0.motion == .stationary }
                .map(\.span),
            travel: travel,
            readings: readings,
            evidence: Self.sensorEvidenceSpan(
                readings: archivedReadings,
                activities: motionActivities,
                inside: span
            ),
            inside: span
        )
        applyChargingInactivitySleepRecords(
            readings: readings,
            inside: span
        )

        if snapshot.settings.locationEnabled || snapshot.settings.weatherEnabled {
            await refreshWeather(
                for: basePlaces,
                in: span,
                fallbackReading: latestReadingWithPoint
            )
        }
    }

    private func applyChargingInactivitySleepRecords(
        readings: [SensorReading],
        inside span: TimeSpan
    ) {
        let evidence = readings.filter { $0.powerState != nil }
        guard !evidence.isEmpty else { return }
        let prior = snapshot.actuals.filter {
            $0.modelVersion != ChargingInactivitySleepEngine.modelVersion
        }
        let watchAvailable = appleWatchConnectionState != .unsupported
            && appleWatchConnectionState != .notPaired
            || readings.contains { $0.sourceDevice == .appleWatch }
            || prior.contains {
                $0.source == .appleWatch
                    && $0.span(asOf: span.end).intersection(with: span) != nil
            }
        let records = ChargingInactivitySleepEngine.records(
            readings: readings,
            actuals: prior,
            inside: span,
            watchAvailable: watchAvailable,
            maximumSampleGap: max(
                20 * 60,
                settings.sensorCollectionProfile.interval * 1.6 + 60
            )
        ).filter { !snapshot.settings.suppressedActualIDs.contains($0.id) }
        let evidenceSpan = TimeSpan(
            start: evidence.map(\.timestamp).min() ?? span.start,
            end: evidence.map(\.timestamp).max() ?? span.start
        )
        snapshot.actuals.removeAll { actual in
            actual.modelVersion == ChargingInactivitySleepEngine.modelVersion
                && actual.span(asOf: span.end)
                    .intersection(with: evidenceSpan) != nil
        }
        snapshot.actuals.append(contentsOf: records)
        snapshot.actuals.sort { $0.startedAt < $1.startedAt }
    }

    func setWeatherEnabled(_ enabled: Bool) async {
        snapshot.settings.weatherEnabled = enabled
        snapshot.settings.permissions[.weather] =
            enabled ? .authorized : .denied
        if enabled {
            await refreshSensorTimeline()
        }
        await persist()
    }

    func confirmTravel(_ travelID: UUID, mode: TravelMode) {
        confirmTravel([travelID], mode: mode)
    }

    func confirmTravel(_ travelIDs: [UUID], mode: TravelMode) {
        let ids = Set(travelIDs)
        var corrections = snapshot.settings.movementCorrections
        var didChange = false
        for index in snapshot.travel.indices
        where ids.contains(snapshot.travel[index].id) {
            let wasChanged = snapshot.travel[index].mode != mode
            corrections = MovementCorrectionEngine.recording(
                mode: mode,
                for: snapshot.travel[index],
                places: snapshot.places,
                existing: corrections
            )
            snapshot.travel[index].mode = mode
            snapshot.travel[index].confidence = .high
            snapshot.travel[index].isConfirmed = true
            snapshot.travel[index].evidence.removeAll {
                $0.hasPrefix("사용자 확인") || $0 == "사용자 교정"
            }
            snapshot.travel[index].evidence.append(
                wasChanged ? "사용자 확인 · 수단 수정" : "사용자 확인"
            )
            didChange = true
        }
        guard didChange else { return }
        snapshot.settings.movementCorrections = corrections
        Task { await persist() }
    }

    func forgetTravelConfirmation(_ travelID: UUID) {
        forgetTravelConfirmations([travelID])
    }

    func forgetTravelConfirmations(_ travelIDs: [UUID]) {
        let ids = Set(travelIDs)
        var corrections = snapshot.settings.movementCorrections
        var earliestStart: Date?
        for index in snapshot.travel.indices
        where ids.contains(snapshot.travel[index].id) {
            let segment = snapshot.travel[index]
            let correction = MovementCorrectionEngine.correction(
                for: segment,
                places: snapshot.places,
                in: corrections
            )
            corrections = MovementCorrectionEngine.removingCorrection(
                for: segment,
                places: snapshot.places,
                from: corrections
            )
            snapshot.travel[index].mode = correction?.inferredMode ?? segment.mode
            snapshot.travel[index].confidence =
                correction?.inferredConfidence ?? .medium
            snapshot.travel[index].isConfirmed = false
            snapshot.travel[index].evidence.removeAll {
                $0.hasPrefix("사용자 확인") || $0 == "사용자 교정"
            }
            earliestStart = min(earliestStart ?? segment.span.start, segment.span.start)
        }
        guard let earliestStart else { return }
        snapshot.settings.movementCorrections = corrections
        Task {
            await persist()
            await refreshSensorTimeline(containing: earliestStart)
            await persistDeviceLocalSnapshot()
        }
    }

    func sensorReadings(in span: TimeSpan) async -> [SensorReading] {
        guard let sensorService else {
            return photoBackfillReadings(in: span, existingReadings: [])
        }
        let archived = (try? await sensorService.archivedReadings(in: span)) ?? []
        return (archived + photoBackfillReadings(
            in: span,
            existingReadings: archived
        ))
        .sorted { $0.timestamp < $1.timestamp }
    }

    private func photoBackfillReadings(
        in span: TimeSpan,
        existingReadings: [SensorReading]
    ) -> [SensorReading] {
        let locationGap: TimeInterval = 5 * 60
        let existingLocationTimes = existingReadings
            .filter { $0.point != nil }
            .map(\.timestamp)
        return snapshot.photos
            .filter {
                span.contains($0.capturedAt)
                    && $0.location != nil
                    && !$0.isHiddenFromTimeline
            }
            .filter { photo in
                !existingLocationTimes.contains {
                    abs($0.timeIntervalSince(photo.capturedAt)) <= locationGap
                }
            }
            .map { photo in
                SensorReading(
                    id: UUID(),
                    timestamp: photo.capturedAt,
                    point: photo.location,
                    motion: .stationary,
                    motionConfidence: .low,
                    gpsAvailable: false,
                    watchWorkoutKind: "사진 위치"
                )
            }
    }

    private func hasPhotoLocations(in span: TimeSpan) -> Bool {
        snapshot.photos.contains {
            span.contains($0.capturedAt)
                && $0.location != nil
                && !$0.isHiddenFromTimeline
        }
    }

    func confirmPlace(_ placeID: UUID, name: String, floor: Int?) {
        guard let index = snapshot.places.firstIndex(where: {
            $0.id == placeID
        }) else {
            return
        }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanName.isEmpty {
            snapshot.places[index].displayName = cleanName
        }
        snapshot.places[index].floor = floor
        snapshot.places[index].confidence = .high
        snapshot.places[index].isConfirmed = true
        Task { await persist() }
    }

    /// 좌표만 잡아 준다. 기준 층은 사용자가 고르지 않고 현재 추정값 →
    /// 기존 기준 → 1층 순으로 정하며, 이후 층은 자동 보정이 이어받는다.
    func setFrequentPlaceToCurrentLocation(_ placeID: UUID) {
        guard let index = snapshot.settings.frequentPlaces.firstIndex(where: {
            $0.id == placeID
        }) else {
            return
        }
        guard let reading = latestSensorReading,
              reading.point != nil else {
            userFacingError =
                "현재 위치를 아직 읽지 못했습니다. 위치 권한을 켠 뒤 잠시 후 다시 시도해 주세요."
            return
        }
        // 층수는 앱의 추정에서 가져오지 않는다. 추정이 틀린 상태에서 자리를
        // 다시 잡으면 그 틀린 층이 곧 이 건물의 기준으로 굳는다. 층은 아래
        // "이 층으로 보정"에서 사용자가 직접 확인한 값만 받는다.
        let floor = snapshot.settings.frequentPlaces[index].floor
            ?? lastManuallyConfirmedFloor(forPlaceID: placeID)
            ?? 1
        snapshot.settings.frequentPlaces[index].setLocation(
            from: reading,
            floor: floor
        )
        lastAutoFloorCalibrationKey = nil
        snapshot.settings.floorCalibration = nil
        snapshot.settings.frequentPlaces =
            AppFeatureSettings.mergedFrequentPlaces(
                snapshot.settings.frequentPlaces
            )
        snapshot.places = FrequentPlaceResolutionEngine().applying(
            snapshot.settings.frequentPlaces,
            to: snapshot.places,
            readings: [reading]
        )
        updateFloorEstimate(with: reading)
        Task {
            await persist()
            await refreshSensorTimeline(containing: selectedDate)
        }
    }

    func setFrequentPlaceLocation(
        _ placeID: UUID,
        latitude: Double,
        longitude: Double
    ) {
        guard let index = snapshot.settings.frequentPlaces.firstIndex(where: {
            $0.id == placeID
        }) else {
            return
        }
        snapshot.settings.frequentPlaces[index].setMapLocation(
            GeoPoint(
                latitude: latitude,
                longitude: longitude,
                altitude: 0,
                horizontalAccuracy: 25,
                verticalAccuracy: -1
            )
        )
        lastAutoFloorCalibrationKey = nil
        snapshot.settings.floorCalibration = nil
        snapshot.settings.frequentPlaces =
            AppFeatureSettings.mergedFrequentPlaces(
                snapshot.settings.frequentPlaces
            )
        Task {
            await persist()
            await refreshSensorTimeline(containing: selectedDate)
        }
    }

    func clearFrequentPlaceLocation(_ placeID: UUID) {
        guard let index = snapshot.settings.frequentPlaces.firstIndex(where: {
            $0.id == placeID
        }) else {
            return
        }
        if let point = snapshot.settings.frequentPlaces[index].point {
            rememberDismissedPlaceSuggestion(at: point)
        }
        snapshot.settings.frequentPlaces[index].clearLocation()
        lastAutoFloorCalibrationKey = nil
        if let latestSensorReading {
            updateFloorEstimate(with: latestSensorReading)
        } else {
            latestAltitudeEstimate = nil
        }
        Task {
            await persist()
            await refreshSensorTimeline(containing: selectedDate)
        }
    }

    /// 스테퍼가 미리 채울 값. 앱이 추정한 층은 절대 쓰지 않는다. 고치려는
    /// 값이 곧 기본값이 되면 사용자는 틀린 층을 그대로 확인하게 된다.
    /// 사용자가 직접 확인한 기준점이 없으면 미리 채울 값도 없다. 이력에 남은
    /// 옛 "수동" 기록은 이 화면이 추정값을 미리 채워 주던 시절의 것이라
    /// 사용자가 골랐다고 믿을 수 없다.
    func lastManuallyConfirmedFloor(forPlaceID placeID: UUID) -> Int? {
        settings.frequentPlaces
            .first { $0.id == placeID }?
            .floorReferencePoints
            .last(where: \.isManual)?
            .floor
    }

    /// 사용자가 "지금 이 층"이라고 알려 주면 그 자리의 기압을 이 장소의
    /// 기준으로 삼는다. 층 높이는 묻지 않는다. 서로 다른 층 기준이 둘 이상
    /// 모이면 `FrequentPlace.calibrateCurrentFloor` 가 그 차이로 구한다.
    ///
    /// 기압계 한 표본은 흔들린다. 그 한 번으로 영구 기준을 박으면 흔들림이
    /// 이 건물의 모든 층 추정에 남으므로, 짧은 묶음을 모아 중앙값으로 줄인
    /// 뒤에만 기록한다. 묶음이 모자라거나 흔들리면 아무것도 남기지 않는다.
    func calibrateFrequentPlaceFloor(_ placeID: UUID, floor: Int) async {
        guard snapshot.settings.frequentPlaces.contains(where: {
            $0.id == placeID
        }) else {
            return
        }
        guard latestSensorReading?.point != nil else {
            userFacingError =
                "현재 위치를 아직 읽지 못했습니다. 위치 권한을 켠 뒤 잠시 후 다시 시도해 주세요."
            return
        }
        guard let sensorService else { return }
        guard floorCalibrationSampling == nil else { return }
        floorCalibrationSampling = FloorCalibrationSampling(
            placeID: placeID,
            floor: floor,
            collected: 0,
            target: AltitudeBurstReducer.requestedSampleCount
        )
        let samples = await sensorService.captureAltitudeBurst { collected in
            self.floorCalibrationSampling?.collected = collected
        }
        floorCalibrationSampling = nil
        // 사용자가 화면을 떠났으면 조용히 접는다. 절반만 잰 값으로 기준을
        // 남기지도, 뒤늦게 오류를 띄우지도 않는다.
        guard !Task.isCancelled else { return }
        guard let anchor = latestSensorReading, anchor.point != nil else {
            userFacingError =
                "현재 위치를 아직 읽지 못했습니다. 위치 권한을 켠 뒤 잠시 후 다시 시도해 주세요."
            return
        }
        switch AltitudeBurstReducer.reduce(samples) {
        case let .tooFewSamples(collected):
            userFacingError = collected == 0
                ? "기압 센서를 읽지 못해 보정을 취소했습니다. 위치 기록을 켠 뒤 다시 시도해 주세요."
                : "표본이 \(collected)개뿐이라 보정을 취소했습니다. 잠시 후 다시 시도해 주세요."
        case let .tooNoisy(spread):
            userFacingError = String(
                format:
                    "고도가 %.1fm나 흔들려 보정을 취소했습니다. 한자리에 선 채로 다시 시도해 주세요.",
                spread
            )
        case let .reduced(sample, _):
            commitFloorCalibration(
                placeID,
                floor: floor,
                reading: anchor.replacingAltitude(with: sample)
            )
        }
    }

    private func commitFloorCalibration(
        _ placeID: UUID,
        floor: Int,
        reading: SensorReading
    ) {
        guard let index = snapshot.settings.frequentPlaces.firstIndex(where: {
            $0.id == placeID
        }) else {
            return
        }
        snapshot.settings.frequentPlaces[index].calibrateCurrentFloor(
            to: floor,
            from: reading
        )
        appendFloorCalibrationEvent(
            FloorCalibrationEvent(
                placeID: placeID,
                placeName: snapshot.settings.frequentPlaces[index].name,
                floor: floor,
                seaLevelAltitudeMeters: reading.point?.altitude,
                isAutomatic: false,
                capturedAt: reading.timestamp
            )
        )
        lastAutoFloorCalibrationKey = nil
        snapshot.settings.floorCalibration = nil
        snapshot.settings.frequentPlaces =
            AppFeatureSettings.mergedFrequentPlaces(
                snapshot.settings.frequentPlaces
            )
        // 기준이 바뀌면 직전 고도와의 연속성 판정은 무효다. 새 기준의 첫
        // 추정이 스파이크로 걸리면 화면이 옛 층에 그대로 머문다.
        altitudeGatePlaceID = nil
        updateFloorEstimate(with: reading)
        Task {
            await persist()
            await reapplyStoredFloors(forPlaceID: placeID)
            await refreshSensorTimeline(containing: selectedDate)
        }
    }

    /// 잘못 들어간 기준점 하나를 지운다. 이 장소의 위치와 나머지 기준은
    /// 그대로 둔다.
    func deleteFrequentPlaceFloorReference(_ placeID: UUID, floor: Int) {
        guard let index = snapshot.settings.frequentPlaces.firstIndex(where: {
            $0.id == placeID
        }), snapshot.settings.frequentPlaces[index].removeFloorReference(
            floor: floor
        ) else {
            return
        }
        lastAutoFloorCalibrationKey = nil
        snapshot.settings.floorCalibration = nil
        altitudeGatePlaceID = nil
        if let latestSensorReading {
            updateFloorEstimate(with: latestSensorReading)
        } else {
            latestAltitudeEstimate = nil
        }
        Task {
            await persist()
            await reapplyStoredFloors(forPlaceID: placeID)
            await refreshSensorTimeline(containing: selectedDate)
        }
    }

    /// 기준점을 고치면 그 기준으로 매긴 지난 기록도 다시 매겨야 한다. 원본
    /// 표본은 그대로 두고 파생된 층수만 다시 구한다. 기록이 스스로 근거를
    /// 지녔으면 보관 기간과 무관하게 다시 매기고, 옛 기록은 7일 보관분과
    /// 기록에 남은 대표 GPS 고도 순으로 보완한다.
    func reapplyStoredFloors(forPlaceID placeID: UUID) async {
        guard let place = settings.frequentPlaces.first(where: {
            $0.id == placeID
        }) else {
            return
        }
        let legacy = snapshot.places.filter {
            $0.placeKey == place.stablePlaceKey && $0.floorEvidence == nil
        }
        var readings: [SensorReading] = []
        if let sensorService,
           let start = legacy.map(\.span.start).min(),
           let end = legacy.map(\.span.end).max() {
            readings = (try? await sensorService.archivedReadings(
                in: TimeSpan(start: start, end: end)
            )) ?? []
        }
        let engine = FrequentPlaceResolutionEngine()
        let recomputedPlaces = engine.reapplyingFloors(
            of: place,
            to: snapshot.places,
            readings: readings
        )
        let recomputedTransitions = engine.reapplyingFloors(
            of: place,
            to: snapshot.floorTransitions
        )
        var changed = false
        if recomputedPlaces != snapshot.places {
            snapshot.places = recomputedPlaces
            changed = true
        }
        if recomputedTransitions != snapshot.floorTransitions {
            snapshot.floorTransitions = recomputedTransitions
            changed = true
        }
        guard changed else { return }
        await persist()
    }

    private func appendFloorCalibrationEvent(_ event: FloorCalibrationEvent) {
        snapshot.settings.floorCalibrationHistory.append(event)
        let overflow = snapshot.settings.floorCalibrationHistory.count - 100
        if overflow > 0 {
            snapshot.settings.floorCalibrationHistory.removeFirst(overflow)
        }
    }

    /// 자동 층 보정은 사용자 조작 없이 이 경로로만 쌓인다.
    @discardableResult
    private func recordFloorCalibration(
        placeID: UUID,
        floor: Int,
        reading: SensorReading,
        seaLevelAltitudeMeters: Double?
    ) -> Bool {
        guard reading.point != nil,
              let index = snapshot.settings.frequentPlaces.firstIndex(where: {
                  $0.id == placeID
              }) else {
            return false
        }
        // 사용자가 확인한 기준과 같은 높이를 다른 층이라고 주장하는 자동
        // 보정은 거절된다. 그때는 이력도 알림도 남기지 않는다.
        guard snapshot.settings.frequentPlaces[index].addFloorCalibration(
            from: reading,
            floor: floor
        ) else {
            return false
        }
        appendFloorCalibrationEvent(
            FloorCalibrationEvent(
                placeID: placeID,
                placeName: snapshot.settings.frequentPlaces[index].name,
                floor: floor,
                seaLevelAltitudeMeters: seaLevelAltitudeMeters,
                isAutomatic: true,
                capturedAt: reading.timestamp
            )
        )
        snapshot.settings.frequentPlaces =
            AppFeatureSettings.mergedFrequentPlaces(
                snapshot.settings.frequentPlaces
            )
        Task {
            await persist()
            await refreshSensorTimeline(containing: selectedDate)
        }
        return true
    }

    private func showFloorCalibrationNotice(_ text: String) {
        calibrationNoticeTask?.cancel()
        floorCalibrationNotice = text
        calibrationNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.floorCalibrationNotice = nil
        }
    }

    /// 자주가는 곳의 이름과 감지 범위를 저장합니다. 건물의 층 높이는 여기서
    /// 받지 않습니다. 사용자가 알려 준 현재 층수에서 앱이 직접 구합니다.
    func updateFrequentPlaceDetails(
        _ placeID: UUID,
        name: String,
        radiusMeters: Double,
        minimumDwellMinutes: Int,
        isAutomaticRecordingEnabled: Bool
    ) {
        guard let index = snapshot.settings.frequentPlaces.firstIndex(where: {
            $0.id == placeID
        }) else {
            return
        }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanName.isEmpty {
            snapshot.settings.frequentPlaces[index].name = cleanName
        }
        snapshot.settings.frequentPlaces[index].radiusMeters = min(
            max(radiusMeters, 30),
            500
        )
        snapshot.settings.frequentPlaces[index].minimumDwellMinutes = min(
            max(minimumDwellMinutes, 1),
            240
        )
        snapshot.settings.frequentPlaces[index]
            .isAutomaticRecordingEnabled = isAutomaticRecordingEnabled
        snapshot.settings.frequentPlaces[index].updatedAt = .now
        snapshot.settings.frequentPlaces =
            AppFeatureSettings.mergedFrequentPlaces(
                snapshot.settings.frequentPlaces
            )
        if let latestSensorReading {
            updateFloorEstimate(with: latestSensorReading)
        }
        Task {
            await persist()
            await refreshSensorTimeline(containing: selectedDate)
        }
    }

    func addCustomFrequentPlace(name: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            userFacingError = "장소 이름을 입력해 주세요."
            return
        }
        guard !snapshot.settings.frequentPlaces.contains(where: {
            $0.name.localizedCaseInsensitiveCompare(cleanName) == .orderedSame
        }) else {
            userFacingError = "같은 이름의 자주가는 곳이 이미 있습니다."
            return
        }
        snapshot.settings.frequentPlaces.append(
            FrequentPlace(kind: .custom, name: cleanName)
        )
        Task { await persist() }
    }

    func renameFrequentPlace(_ placeID: UUID, name: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        guard let index = snapshot.settings.frequentPlaces.firstIndex(where: {
            $0.id == placeID
        }) else {
            return
        }
        snapshot.settings.frequentPlaces[index].name = cleanName
        snapshot.settings.frequentPlaces[index].updatedAt = .now
        Task {
            await persist()
            await refreshSensorTimeline(containing: selectedDate)
        }
    }

    func deleteFrequentPlace(_ placeID: UUID) {
        guard let target = snapshot.settings.frequentPlaces.first(where: {
            $0.id == placeID
        }) else {
            return
        }
        if let point = target.point {
            rememberDismissedPlaceSuggestion(at: point)
        }
        guard target.kind == .custom else {
            snapshot.settings.frequentPlaces =
                snapshot.settings.frequentPlaces.map { place in
                    guard place.id == placeID else { return place }
                    return FrequentPlace(kind: place.kind)
                }
            Task { await persist() }
            return
        }
        snapshot.settings.frequentPlaces.removeAll { $0.id == placeID }
        Task { await persist() }
    }

    // MARK: - 등록하지 않은 자주 가는 곳

    /// 설정 화면을 열 때만 다시 구한다. 저장된 체류만 읽으므로 새 위치 수집도,
    /// 새 권한도 필요 없다.
    func refreshFrequentPlaceSuggestion() {
        frequentPlaceSuggestion = UnregisteredPlaceSuggestionEngine()
            .suggestion(
                places: snapshot.places,
                frequentPlaces: snapshot.settings.frequentPlaces,
                dismissed: snapshot.settings.dismissedPlaceSuggestions
            )
    }

    /// 제안한 자리를 사용자가 고른 종류로 등록한다. 좌표는 이미 모은 체류에서
    /// 나오므로 사용자는 종류만 고르면 된다. 이름과 반경은 이어서 열리는 기존
    /// 설정 화면에서 고친다.
    @discardableResult
    func registerFrequentPlaceSuggestion(
        as kind: FrequentPlaceKind
    ) -> UUID? {
        guard let suggestion = frequentPlaceSuggestion else { return nil }
        let reading = SensorReading(
            timestamp: suggestion.lastVisitedAt,
            point: suggestion.point
        )
        let index: Int
        if kind != .custom,
           let empty = snapshot.settings.frequentPlaces.firstIndex(where: {
               $0.kind == kind && $0.point == nil
           }) {
            index = empty
        } else {
            // 이름을 지어내지 않는다. 역지오코딩이 붙여 준 이름이 없으면
            // 좌표를 그대로 넣고 사용자가 고치게 둔다.
            snapshot.settings.frequentPlaces.append(
                FrequentPlace(
                    kind: kind,
                    name: suggestion.suggestedName
                        ?? Self.coordinateLabel(suggestion.point)
                )
            )
            index = snapshot.settings.frequentPlaces.count - 1
        }
        let floor = snapshot.settings.frequentPlaces[index].floor ?? 1
        snapshot.settings.frequentPlaces[index].setLocation(
            from: reading,
            floor: floor
        )
        snapshot.settings.frequentPlaces =
            AppFeatureSettings.mergedFrequentPlaces(
                snapshot.settings.frequentPlaces
            )
        let placeID = snapshot.settings.frequentPlaces[index].id
        snapshot.places = FrequentPlaceResolutionEngine().applying(
            snapshot.settings.frequentPlaces,
            to: snapshot.places,
            readings: [reading]
        )
        frequentPlaceSuggestion = nil
        Task {
            await persist()
            await refreshSensorTimeline(containing: selectedDate)
        }
        return placeID
    }

    /// 거절은 영구히 기억한다. 같은 곳을 매주 다시 묻는 것이 한 번도 묻지
    /// 않는 것보다 나쁘다.
    func dismissFrequentPlaceSuggestion() {
        guard let suggestion = frequentPlaceSuggestion else { return }
        rememberDismissedPlaceSuggestion(at: suggestion.point)
        frequentPlaceSuggestion = nil
        Task { await persist() }
    }

    static func coordinateLabel(_ point: GeoPoint) -> String {
        String(
            format: "%.5f, %.5f",
            point.latitude,
            point.longitude
        )
    }

    /// 자주가는 곳에서 지운 자리도 같은 목록에 넣는다. 지우자마자 "등록할
    /// 까요?"가 다시 뜨면 지운 것이 지워지지 않은 셈이다.
    private func rememberDismissedPlaceSuggestion(at point: GeoPoint) {
        let radius = UnregisteredPlaceSuggestionEngine().dismissalRadiusMeters
        guard !snapshot.settings.dismissedPlaceSuggestions.contains(where: {
            distanceMeters($0.point, point) <= radius
        }) else {
            return
        }
        snapshot.settings.dismissedPlaceSuggestions.append(
            DismissedPlaceSuggestion(point: point)
        )
        if let suggestion = frequentPlaceSuggestion,
           distanceMeters(suggestion.point, point) <= radius {
            frequentPlaceSuggestion = nil
        }
    }

    func confirmFloorTransition(
        _ transitionID: UUID,
        toFloor: Int?
    ) {
        guard let index = snapshot.floorTransitions.firstIndex(where: {
            $0.id == transitionID
        }) else {
            return
        }
        snapshot.floorTransitions[index].toFloor = toFloor
        snapshot.floorTransitions[index].confidence = .high
        if !snapshot.floorTransitions[index].isUserConfirmed {
            snapshot.floorTransitions[index].evidence.append(
                FloorTransition.userConfirmedEvidence
            )
        }
        if let toFloor,
           let placeIndex = snapshot.places.firstIndex(where: {
               $0.placeKey == snapshot.floorTransitions[index].placeKey
                   && $0.span.contains(
                       snapshot.floorTransitions[index].span.end
                   )
           }) {
            snapshot.places[placeIndex].floor = toFloor
            snapshot.places[placeIndex].confidence = .high
            snapshot.places[placeIndex].isConfirmed = true
        }
        Task { await persist() }
    }

    func photoThumbnailData(
        localIdentifier: String,
        size: CGSize
    ) async throws -> Data {
        try await photoService.thumbnailJPEG(
            localIdentifier: localIdentifier,
            size: size
        )
    }

    func clearError() {
        userFacingError = nil
    }

    private func refreshPermissionStates() async {
        let photoState = photoService.permissionState()
        snapshot.settings.permissions[.photos] = photoState
        if !permissionState(for: .photos).isGranted {
            snapshot.settings.showsPhotos = false
            snapshot.settings.showsPhotosInWidgets = false
            snapshot.photos = []
        }
        let calendarState = calendarService.permissionState()
        snapshot.settings.permissions[.calendar] = calendarState
        if !permissionState(for: .calendar).isGranted {
            snapshot.settings.selectedCalendarIDs = []
            snapshot.calendarEvents = []
        }
        var healthState = PermissionState.unavailable
        do {
            healthState = try await healthService.authorizationRequestState()
        } catch {
            healthState = healthService.permissionState()
        }
        snapshot.settings.permissions[.health] = healthState
        var locationState = PermissionState.unavailable
        if let sensorService {
            locationState = sensorService.locationPermissionState()
            snapshot.settings.permissions[.location] = locationState
            snapshot.settings.permissions[.motion] =
                sensorService.motionPermissionState()
            snapshot.settings.backgroundPreciseLocationEnabled =
                snapshot.settings.locationEnabled
                && sensorService.hasAlwaysLocationAuthorization()
            sensorAvailability = sensorService.hardwareAvailability()
            if !permissionState(for: .location).isGranted {
                // 권한이 없는 동안 수집만 멈춘다. locationEnabled를 지우면
                // iOS 설정에서 권한을 다시 허용해도 기록이 재개되지 않는다.
                sensorService.stopCollection()
                isSensorCollecting = false
                snapshot.settings.backgroundPreciseLocationEnabled = false
            }
        } else {
            snapshot.settings.permissions[.location] = .unavailable
            snapshot.settings.permissions[.motion] = .unavailable
            snapshot.settings.locationEnabled = false
            snapshot.settings.backgroundPreciseLocationEnabled = false
        }
        let notificationState = await notificationScheduler.authorizationState()
        snapshot.settings.permissions[.notifications] = notificationState
        if !permissionState(for: .notifications).isGranted {
            snapshot.settings.notificationsEnabled = false
        }
        migratePermissionFlagsIfNeeded(
            photos: photoState,
            calendar: calendarState,
            health: healthState,
            location: locationState,
            notifications: notificationState
        )
    }

    private func migratePermissionFlagsIfNeeded(
        photos: PermissionState,
        calendar: PermissionState,
        health: PermissionState,
        location: PermissionState,
        notifications: PermissionState
    ) {
        guard !UserDefaults.standard.bool(forKey: Self.permissionFlagsMigrationKey)
        else { return }
        let granted = [photos, calendar, health, location, notifications]
            .contains(where: \.isGranted)
        guard granted else { return }
        snapshot.settings.showsPhotos = photos.isGranted
        snapshot.settings.healthEnabled = health.isGranted
        snapshot.settings.locationEnabled = location.isGranted
        snapshot.settings.notificationsEnabled = notifications.isGranted
        if calendar.isGranted, snapshot.settings.selectedCalendarIDs.isEmpty {
            snapshot.settings.selectedCalendarIDs = calendarService.calendars().map(\.id)
        }
        UserDefaults.standard.set(true, forKey: Self.permissionFlagsMigrationKey)
    }

    private func refreshPhotos() {
        let span = visibleDataSpan
        replacePhotos(photoService.moments(in: span), in: span)
    }

    private func replacePhotos(_ fresh: [PhotoMoment], in span: TimeSpan) {
        snapshot.photos.removeAll { span.contains($0.capturedAt) }
        snapshot.photos.append(contentsOf: fresh)
        snapshot.photos.sort { $0.capturedAt < $1.capturedAt }
    }

    private func refreshCalendarEvents() {
        refreshCalendarEvents(in: visibleDataSpan)
    }

    private func refreshCalendarEvents(in span: TimeSpan) {
        if !snapshot.settings.selectedCalendarIDs.isEmpty {
            snapshot.settings.selectedCalendarIDs =
                calendarService.calendars().map(\.id)
        }
        let selected = Set(snapshot.settings.selectedCalendarIDs)
        let fresh = calendarService.events(in: span, selectedCalendarIDs: selected)
        let freshIDs = Set(fresh.map(\.id))
        snapshot.calendarEvents.removeAll {
            freshIDs.contains($0.id)
                || $0.span.intersection(with: span) != nil
        }
        snapshot.calendarEvents.append(contentsOf: fresh)
        snapshot.calendarEvents.sort { $0.span.start < $1.span.start }
    }

    private func refreshHealthData(
        in requestedSpan: TimeSpan? = nil,
        showErrors: Bool = true
    ) async {
        guard !isHealthRefreshRunning else { return }
        isHealthRefreshRunning = true
        defer { isHealthRefreshRunning = false }
        let span = requestedSpan ?? recentHealthSpan
        let healthFields = [
            "periodic": String(requestedSpan != nil),
            "start": String(Int(span.start.timeIntervalSince1970)),
            "end": String(Int(span.end.timeIntervalSince1970)),
        ]
        TaptionPlanDiagnosticsLogger.shared.record(
            "health_refresh_started",
            fields: healthFields
        )

        do {
            async let actualValues = healthService.actuals(in: span)
            async let sessions = healthService.sleepSessions(in: span)
            let (freshActuals, freshSessions) = try await (actualValues, sessions)
            let visibleFreshActuals = ActualRecordSuppressionEngine
                .visibleRecords(
                    from: freshActuals,
                    suppressedIDs: snapshot.settings.suppressedActualIDs
                )
                .map { actual in
                    guard actual.categoryID == "sleep"
                        || actual.title.localizedCaseInsensitiveContains("수면")
                        || actual.title.localizedCaseInsensitiveContains("sleep") else {
                        return actual
                    }
                    var value = actual
                    value.behavior = WatchBehaviorKind.sleep.rawValue
                    value.evidence = Array(
                        Set(value.evidence + ["HealthKit 수면 기록"])
                    ).sorted()
                    value.modelVersion = "healthkit-sleep-v1"
                    return value
                }
            let existingHealthActuals = snapshot.actuals.filter {
                ($0.source == .healthKit || $0.source == .appleWatch)
                    && $0.span(asOf: span.end).intersection(with: span) != nil
            }
            let existingSleepSessions = sleepSessions.filter {
                $0.span.intersection(with: span) != nil
            }
            if Set(existingHealthActuals) != Set(visibleFreshActuals) {
                archiveRawDeviceData(
                    source: .healthKit,
                    kind: "health-actuals",
                    payload: freshActuals,
                    capturedAt: span.end
                )
            }
            if Set(existingSleepSessions) != Set(freshSessions) {
                archiveRawDeviceData(
                    source: .healthKit,
                    kind: "sleep-sessions",
                    payload: freshSessions,
                    capturedAt: span.end
                )
            }
            // HealthKit can legally return an empty result while its daemon,
            // Watch delivery, or authorization is catching up. An empty
            // refresh is not evidence that previously saved records vanished.
            if !visibleFreshActuals.isEmpty {
                snapshot.actuals = AppleDeviceGroundTruthEngine
                    .replacingHealthKitActuals(
                        existing: snapshot.actuals,
                        with: visibleFreshActuals,
                        inside: span
                    )
            } else {
                Self.integrationLogger.notice(
                    "HealthKit returned no actuals; preserving existing records"
                )
            }
            if !freshSessions.isEmpty {
                sleepSessions.removeAll {
                    $0.span.intersection(with: span) != nil
                }
                sleepSessions.append(contentsOf: freshSessions)
                sleepSessions.sort { $0.span.start < $1.span.start }
            } else {
                Self.integrationLogger.notice(
                    "HealthKit returned no sleep sessions; preserving existing records"
                )
            }
            lastHealthRefreshAt = .now
            Self.integrationLogger.notice(
                "HealthKit refresh completed: actuals=\(freshActuals.count, privacy: .public), sleepSessions=\(freshSessions.count, privacy: .public), periodic=\(requestedSpan != nil, privacy: .public)"
            )
            TaptionPlanDiagnosticsLogger.shared.record(
                "health_refresh_completed",
                fields: healthFields.merging([
                    "actuals": String(freshActuals.count),
                    "sleep_sessions": String(freshSessions.count),
                ]) { _, new in new }
            )
        } catch {
            Self.integrationLogger.error(
                "HealthKit refresh failed: \(error.localizedDescription, privacy: .public)"
            )
            if showErrors {
                userFacingError =
                    "건강 데이터를 읽지 못했습니다. \(error.localizedDescription)"
            }
            TaptionPlanDiagnosticsLogger.shared.record(
                "health_refresh_failed",
                level: .error,
                fields: healthFields.merging(
                    TaptionDiagnosticError.fields(for: error)
                ) { _, new in new }
            )
        }
    }

    private func refreshAppUsageData(
        in span: TimeSpan,
        showErrors: Bool = false
    ) async {
        refreshAppUsageAuthorizationState()
        guard appUsageAuthorizationState == .approved,
              !isAppUsageRefreshRunning else {
            return
        }
        isAppUsageRefreshRunning = true
        defer { isAppUsageRefreshRunning = false }

        do {
            let samples = try await screenTimeUsageService.usage(in: span)
            let fresh = ScreenTimeUsageRecordEngine.records(
                from: samples,
                suppressedIDs: snapshot.settings.suppressedActualIDs
            )
            if !samples.isEmpty {
                let updated = ScreenTimeUsageRecordEngine.replacing(
                    existing: snapshot.actuals,
                    with: fresh,
                    inside: span
                )
                if snapshot.actuals != updated {
                    snapshot.actuals = updated
                }
            } else {
                Self.integrationLogger.notice(
                    "Screen Time returned no samples; preserving existing records"
                )
            }
            appUsageRecordCount = fresh.count
            appUsageTotalDuration = fresh.reduce(into: 0) {
                $0 += $1.span(asOf: span.end).duration
            }
            appUsageTokenIndex = ScreenTimeUsageRecordEngine
                .applicationTokenIndex(from: samples)
            lastAppUsageRefreshAt = .now
            Self.integrationLogger.notice(
                "Screen Time refresh completed: samples=\(samples.count, privacy: .public), records=\(fresh.count, privacy: .public)"
            )
            TaptionPlanDiagnosticsLogger.shared.record(
                "screen_time_refresh_completed",
                fields: [
                    "samples": String(samples.count),
                    "records": String(fresh.count),
                ]
            )
        } catch {
            Self.integrationLogger.error(
                "Screen Time refresh failed: \(error.localizedDescription, privacy: .public)"
            )
            if showErrors {
                userFacingError = "앱 사용시간을 읽지 못했습니다. \(error.localizedDescription)"
            }
            TaptionPlanDiagnosticsLogger.shared.record(
                "screen_time_refresh_failed",
                level: .error,
                fields: TaptionDiagnosticError.fields(for: error)
            )
        }
    }

    private func handleObservedHealthChange() async {
        await bootstrap()
        guard settings.healthEnabled else { return }
        await refreshHealthData(
            in: periodicHealthSpan,
            showErrors: false
        )
        logAutomaticRecordSummary()
        await persistDeviceLocalSnapshot()
    }

    private func startForegroundHealthRefreshIfNeeded() {
        foregroundHealthRefreshTask?.cancel()
        foregroundHealthRefreshTask = nil
        guard isSceneActive, settings.healthEnabled else { return }

        foregroundHealthRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        for: .seconds(
                            HealthRefreshPolicy.foregroundInterval
                        )
                    )
                } catch {
                    return
                }
                guard let self, !Task.isCancelled,
                      self.isSceneActive,
                      self.settings.healthEnabled else {
                    return
                }
                await self.refreshHealthData(
                    in: self.periodicHealthSpan,
                    showErrors: false
                )
                self.logAutomaticRecordSummary()
                await self.persistDeviceLocalSnapshot()
            }
        }
    }

    private func configureHealthBackgroundDeliveryIfNeeded(
        showErrors: Bool
    ) async {
        guard settings.healthEnabled,
              !isHealthBackgroundDeliveryConfigured else {
            return
        }
        do {
            try await healthService.enableBackgroundDelivery()
            isHealthBackgroundDeliveryConfigured = true
            Self.integrationLogger.notice(
                "HealthKit background delivery enabled for routes, activity, sleep and vitals"
            )
        } catch {
            Self.integrationLogger.error(
                "HealthKit background delivery failed: \(error.localizedDescription, privacy: .public)"
            )
            if showErrors {
                userFacingError =
                    "건강 데이터 자동 갱신을 켜지 못했습니다. "
                    + error.localizedDescription
            }
        }
    }

    private func logAutomaticRecordSummary() {
        let today = TimelineAggregationEngine().interval(
            for: .day,
            containing: .now
        )
        let calendarCount = snapshot.calendarEvents.filter {
            $0.span.intersection(with: today) != nil
        }.count
        let placeCount = snapshot.places.filter {
            $0.span.intersection(with: today) != nil
        }.count
        let travelCount = snapshot.travel.filter {
            $0.span.intersection(with: today) != nil
        }.count
        let activityCount = AutomaticRecordTimelineEngine.activities(
            from: snapshot.actuals,
            inside: today
        ).count
        Self.integrationLogger.notice(
            "Today automatic records: schedules=\(calendarCount, privacy: .public), locations=\(placeCount, privacy: .public), movements=\(travelCount, privacy: .public), activities=\(activityCount, privacy: .public)"
        )
    }

    private func resumeSensorCollectionIfNeeded() {
        guard settings.locationEnabled,
              permissionState(for: .location).isGranted,
              let sensorService else {
            isSensorCollecting = false
            return
        }
        sensorService.startCollection(
            configuration: .configured(
                for: settings.sensorCollectionProfile,
                allowsBackgroundLocation:
                    settings.backgroundPreciseLocationEnabled
            )
        )
        isSensorCollecting = true
    }

    private func restoreTrackingSessionIfNeeded() async {
        guard activeTrackingSession == nil,
              settings.locationEnabled,
              permissionState(for: .location).isGranted,
              let sensorService,
              var session = TrackingSessionRecoveryStore.read() else {
            return
        }

        let now = Date.now
        // A running/walking session left open for more than a day is almost
        // certainly a stale crash record rather than a real workout.
        guard session.endedAt == nil,
              now.timeIntervalSince(session.startedAt) <= 24 * 60 * 60 else {
            TrackingSessionRecoveryStore.clear()
            return
        }

        session.endedAt = nil
        let restored = sensorService.resumeTracking(session)
        activeTrackingSession = restored
        trackingSessionWasRecovered = true
        lastTrackingSessionRecoveryPersistAt = now
        let readings = (try? await sensorService.archivedReadings(
            for: restored,
            through: now
        )) ?? []
        let routeReadings = readings
            .filter {
                guard let point = $0.point else { return false }
                return point.horizontalAccuracy >= 0
                    && point.horizontalAccuracy <= 50
            }
            .suffix(4_000)
        liveRouteState = LiveRouteState(
            session: restored,
            readings: Array(routeReadings),
            lastUpdatedAt: readings.last?.timestamp ?? restored.startedAt
        )
        TrackingSessionRecoveryStore.save(restored)
        Self.integrationLogger.notice(
            "Recovered tracking session \(restored.id.uuidString, privacy: .public) with \(readings.count, privacy: .public) archived samples"
        )
    }

    private func updateFloorEstimate(
        with reading: SensorReading
    ) {
        latestSensorReading = reading
        guard let point = reading.point,
              let match = settings.frequentPlaces
                .compactMap({ place -> (FrequentPlace, Double)? in
                    guard place.isAutomaticRecordingEnabled,
                          let reference = place.point,
                          place.floorCalibration != nil else {
                        return nil
                    }
                    let distance = distanceMeters(point, reference)
                    return distance <= place.radiusMeters
                        ? (place, distance)
                        : nil
                })
                .min(by: { $0.1 < $1.1 })?.0,
              let calibration = match.floorCalibration else {
            latestAltitudeEstimate = nil
            return
        }
        guard let estimate = FloorCalibrationEngine().estimate(
            reading: reading,
            calibration: calibration
        ) else {
            latestAltitudeEstimate = nil
            return
        }
        if altitudeGatePlaceID != match.id {
            altitudeGatePlaceID = match.id
            altitudeSpikeGate.reset()
        }
        // 튀는 고도 표본은 이상치로 스킵하고 직전 추정을 유지한다.
        guard altitudeSpikeGate.accept(estimate.seaLevelAltitudeMeters) else {
            return
        }
        latestAltitudeEstimate = estimate
        let knownFloors = calibration.knownFloors
        guard !knownFloors.contains(estimate.floor),
              abs(estimate.floor - calibration.referenceFloor) >= 1,
              estimate.confidence != .low else {
            return
        }
        let key = "\(match.id.uuidString):\(estimate.floor)"
        guard lastAutoFloorCalibrationKey != key else { return }
        lastAutoFloorCalibrationKey = key
        // 보정은 사용자 확인 없이 감지된 위치의 장소에 바로 적용하고
        // 결과만 알린다. 이미 알고 있는 층이면 위 guard에서 끝난다.
        if recordFloorCalibration(
            placeID: match.id,
            floor: estimate.floor,
            reading: reading,
            seaLevelAltitudeMeters: estimate.seaLevelAltitudeMeters
        ) {
            showFloorCalibrationNotice(
                "\(match.name) \(FloorLabel.korean(estimate.floor)) 고도 보정을 적용했습니다."
            )
        }
    }

    private func handleLiveSensorReading(_ reading: SensorReading) {
        updateFloorEstimate(with: reading)
        let session: TrackingSession?
        if let sessionID = reading.trackingSessionID,
           let kind = reading.trackingKind {
            if activeTrackingSession?.id == sessionID {
                session = activeTrackingSession
            } else {
                session = TrackingSession(
                    id: sessionID,
                    kind: kind,
                    startedAt: reading.timestamp,
                    linkedPlanID: nil,
                    sourceDevice: reading.sourceDevice ?? .iPhone,
                    wasAutomaticallyDetected: kind != .automatic
                        && reading.sourceDevice == .iPhone
                )
                activeTrackingSession = session
            }
            if liveRouteState.session?.id != sessionID {
                liveRouteState.readings = []
            }
        } else {
            session = activeTrackingSession
        }

        if let session {
            let shouldPersistSession = reading.trackingSessionEnded == true
                || lastTrackingSessionRecoveryPersistAt.map {
                    reading.timestamp.timeIntervalSince($0) >= 30
                } ?? true
            if shouldPersistSession {
                if reading.trackingSessionEnded == true {
                    TrackingSessionRecoveryStore.clear()
                    lastTrackingSessionRecoveryPersistAt = nil
                } else {
                    TrackingSessionRecoveryStore.save(session)
                    lastTrackingSessionRecoveryPersistAt = reading.timestamp
                }
            }
        }

        if let point = reading.point {
            if point.horizontalAccuracy >= 0,
               point.horizontalAccuracy <= 50 {
                let lastPoint = liveRouteState.readings.last?.point
                let shouldAppend = lastPoint.map {
                    distanceMeters($0, point) >= 2
                } ?? true
                if shouldAppend {
                    liveRouteState.readings.append(reading)
                    if liveRouteState.readings.count > Self.liveRouteSoftLimit {
                        liveRouteState.readings.removeFirst(
                            liveRouteState.readings.count - Self.liveRouteHardLimit
                        )
                    }
                }
            }
            refreshCurrentEnvironmentIfNeeded(
                point: point,
                at: reading.timestamp
            )
        }
        liveRouteState.session = session
        liveRouteState.lastUpdatedAt = reading.timestamp

        if reading.trackingSessionEnded == true,
           var completed = session {
            completed.endedAt = reading.timestamp
            if reading.sourceDevice != .appleWatch {
                finalizeTrackingSession(completed)
            }
            activeTrackingSession = nil
            trackingSessionWasRecovered = false
            liveRouteState.session = nil
            scheduleSensorAnalysis(
                containing: reading.timestamp,
                immediately: true
            )
        } else {
            scheduleSensorAnalysis(
                containing: reading.timestamp,
                immediately: false
            )
        }
    }

    private func scheduleSensorAnalysis(
        containing date: Date,
        immediately: Bool
    ) {
        if !immediately, sensorAnalysisDebounceTask != nil {
            return
        }
        if immediately {
            sensorAnalysisDebounceTask?.cancel()
        }
        sensorAnalysisDebounceTask = Task { [weak self] in
            if !immediately {
                try? await Task.sleep(for: .seconds(120))
            }
            guard !Task.isCancelled, let self else { return }
            await self.refreshSensorTimeline(containing: date)
            await self.persistDeviceLocalSnapshot()
            self.sensorAnalysisDebounceTask = nil
        }
    }

    private func refreshCurrentEnvironmentIfNeeded(
        point: GeoPoint,
        at date: Date
    ) {
        // Weather is part of the automatic sensor record. Location collection
        // enables it even when the legacy weather toggle is still off.
        guard settings.locationEnabled || settings.weatherEnabled else {
            return
        }
        let movedFarEnough = lastLiveEnvironmentPoint.map {
            distanceMeters($0, point) >= 3_000
        } ?? true
        // Keep environment samples on the same cadence as the configured
        // GPS/sensor duty cycle.  The provider caches the value, so a one-
        // minute accuracy profile does not imply a one-minute network call.
        let collectionInterval = settings.sensorCollectionProfile.interval
        let agedEnough = lastLiveEnvironmentAt.map {
            date.timeIntervalSince($0) >= collectionInterval
        } ?? true
        let retryAllowed = lastLiveEnvironmentFailureAt.map {
            date.timeIntervalSince($0) >= 60
        } ?? true
        guard movedFarEnough || agedEnough,
              retryAllowed,
              liveWeatherRefreshTask == nil else { return }
        liveWeatherRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer { self.liveWeatherRefreshTask = nil }
            do {
                var context = try await self.weatherService.context(
                    latitude: point.latitude,
                    longitude: point.longitude,
                    at: date
                )
                context.point = point
                context.placeName = "현재 위치"
                context.airQuality = try? await self.airQualityService.context(
                    latitude: point.latitude,
                    longitude: point.longitude,
                    at: date
                )
                self.archiveRawDeviceData(
                    source: .gps,
                    kind: "weather-context",
                    payload: context,
                    capturedAt: date
                )
                self.lastLiveEnvironmentPoint = point
                self.lastLiveEnvironmentAt = date
                self.lastLiveEnvironmentFailureAt = nil
                self.snapshot.weather.removeAll {
                    abs($0.observedAt.timeIntervalSince(date)) < 5 * 60
                        && $0.placeID == nil
                }
                self.snapshot.weather.append(context)
                self.coalesceWeatherSnapshot()
                TaptionPlanDiagnosticsLogger.shared.record(
                    "live_environment_refreshed",
                    fields: [
                        "air_quality": String(context.airQuality != nil),
                    ]
                )
                await self.persistDeviceLocalSnapshot()
            } catch {
                self.lastLiveEnvironmentFailureAt = date
                Self.integrationLogger.info(
                    "Live weather context unavailable: \(error.localizedDescription, privacy: .public)"
                )
                TaptionPlanDiagnosticsLogger.shared.record(
                    "live_environment_failed",
                    level: .error,
                    fields: ["error": String(describing: type(of: error))]
                )
            }
        }
    }

    private func finalizeTrackingSession(_ session: TrackingSession) {
        guard finalizedTrackingSessionIDs.insert(session.id).inserted else {
            return
        }
        let end = max(session.startedAt, session.endedAt ?? .now)
        let kind = session.kind == .running ? "달리기" : "걷기"
        let linkedPlan = session.linkedPlanID.flatMap { planID in
            snapshot.plans.first { $0.id == planID }
        }
        snapshot.actuals.append(
            ActualRecord(
                id: session.id,
                planID: linkedPlan?.id,
                title: linkedPlan?.title ?? kind,
                categoryID: linkedPlan?.categoryID ?? "activity",
                startedAt: session.startedAt,
                endedAt: end,
                source: session.sourceDevice == .appleWatch
                    ? .appleWatch
                    : .location,
                confidence: .high
            )
        )
    }

    private nonisolated static func migrateLegacyFloorCalibration(
        in snapshot: inout TaptionDataSnapshot
    ) {
        guard let calibration = snapshot.settings.floorCalibration else {
            return
        }
        defer { snapshot.settings.floorCalibration = nil }
        guard calibration.isCaptured,
              let point = calibration.referencePoint,
              let index = snapshot.settings.frequentPlaces.firstIndex(where: {
                  $0.kind == .home
              }) else {
            return
        }
        let existingPoint =
            snapshot.settings.frequentPlaces[index].point
        if let existingPoint,
           distanceMeters(existingPoint, point)
            > snapshot.settings.frequentPlaces[index].radiusMeters {
            return
        }
        if existingPoint == nil {
            snapshot.settings.frequentPlaces[index].point = point
        }
        if snapshot.settings.frequentPlaces[index].floor == nil {
            snapshot.settings.frequentPlaces[index].floor =
                calibration.referenceFloor
        }
        snapshot.settings.frequentPlaces[index]
            .referenceRelativeAltitudeMeters =
                snapshot.settings.frequentPlaces[index]
                    .referenceRelativeAltitudeMeters
                ?? calibration.referenceRelativeAltitudeMeters
        snapshot.settings.frequentPlaces[index]
            .referencePressureKilopascals =
                snapshot.settings.frequentPlaces[index]
                    .referencePressureKilopascals
                ?? calibration.referencePressureKilopascals
        snapshot.settings.frequentPlaces[index]
            .referenceAltimeterSessionID =
                snapshot.settings.frequentPlaces[index]
                    .referenceAltimeterSessionID
                ?? calibration.referenceAltimeterSessionID
        snapshot.settings.frequentPlaces[index].floorCapturedAt =
            snapshot.settings.frequentPlaces[index].floorCapturedAt
            ?? calibration.capturedAt
        snapshot.settings.frequentPlaces[index].updatedAt =
            calibration.capturedAt ?? .now
    }

    private func weatherNeedsRefresh(for reading: SensorReading?) -> Bool {
        guard let reading, let point = reading.point else { return false }
        let latest = snapshot.weather
            .filter { context in
                guard let contextPoint = context.point,
                      context.placeID == nil else { return false }
                return distanceMeters(contextPoint, point) < 1_000
            }
            .max { $0.observedAt < $1.observedAt }
        guard let latest else { return true }
        return reading.timestamp.timeIntervalSince(latest.observedAt)
            >= settings.sensorCollectionProfile.interval
    }

    private func refreshWeather(
        for places: [PlaceStay],
        in span: TimeSpan,
        fallbackReading: SensorReading? = nil
    ) async {
        let locatedPlaces = places.filter { $0.point != nil }
        if locatedPlaces.isEmpty,
           let fallbackReading,
           let point = fallbackReading.point {
            await refreshWeather(
                at: point,
                observedAt: fallbackReading.timestamp
            )
            return
        }
        guard !locatedPlaces.isEmpty else { return }

        var contexts: [WeatherContext] = []
        var firstError: Error?
        for place in locatedPlaces {
            guard let point = place.point else { continue }
            do {
                var context = try await weatherService.context(
                    latitude: point.latitude,
                    longitude: point.longitude,
                    at: place.span.end
                )
                context.observedAt = place.span.end
                context.placeID = place.id
                context.placeName = place.displayName
                context.point = point
                context.airQuality = try? await airQualityService.context(
                    latitude: point.latitude,
                    longitude: point.longitude,
                    at: place.span.end
                )
                archiveRawDeviceData(
                    source: .gps,
                    kind: "weather-context",
                    payload: context,
                    capturedAt: place.span.end
                )
                contexts.append(context)
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        if !contexts.isEmpty {
            snapshot.weather.removeAll {
                $0.placeID != nil
                    && $0.observedAt >= span.start
                    && $0.observedAt <= span.end
            }
            snapshot.weather.append(contentsOf: contexts)
            coalesceWeatherSnapshot()
            TaptionPlanDiagnosticsLogger.shared.record(
                "stored_environment_refreshed",
                fields: ["contexts": String(contexts.count)]
            )
        }

        // This refresh runs as part of automatic sensor analysis.  A weather
        // provider outage must never interrupt an exercise session (or show a
        // modal alert during background collection).  Keep existing context
        // data and let the next refresh retry instead.
        if let firstError, contexts.isEmpty {
            Self.integrationLogger.info(
                "Stored weather refresh unavailable: \(firstError.localizedDescription, privacy: .public)"
            )
            TaptionPlanDiagnosticsLogger.shared.record(
                "stored_environment_failed",
                level: .error,
                fields: [
                    "error": String(describing: type(of: firstError)),
                ]
            )
        }
    }

    private func refreshWeather(
        at point: GeoPoint,
        observedAt: Date,
        placeID: UUID? = nil,
        placeName: String? = "현재 위치"
    ) async {
        do {
            var context = try await weatherService.context(
                latitude: point.latitude,
                longitude: point.longitude,
                at: observedAt
            )
            context.observedAt = observedAt
            context.placeID = placeID
            context.placeName = placeName
            context.point = point
            context.airQuality = try? await airQualityService.context(
                latitude: point.latitude,
                longitude: point.longitude,
                at: observedAt
            )
            archiveRawDeviceData(
                source: .gps,
                kind: "weather-context",
                payload: context,
                capturedAt: observedAt
            )
            snapshot.weather.removeAll {
                $0.placeID == placeID
                    && abs($0.observedAt.timeIntervalSince(observedAt)) < 5 * 60
            }
            snapshot.weather.append(context)
            coalesceWeatherSnapshot()
            TaptionPlanDiagnosticsLogger.shared.record(
                "stored_environment_fallback_refreshed",
                fields: [
                    "air_quality": String(context.airQuality != nil),
                ]
            )
        } catch {
            Self.integrationLogger.info(
                "Stored weather fallback unavailable: \(error.localizedDescription, privacy: .public)"
            )
            TaptionPlanDiagnosticsLogger.shared.record(
                "stored_environment_fallback_failed",
                level: .error,
                fields: ["error": String(describing: type(of: error))]
            )
        }
    }

    private func coalesceWeatherSnapshot() {
        snapshot.weather = WeatherTimelineEngine.coalesced(snapshot.weather)
    }

    private func applyPendingWidgetCommands(
        repositoryAlreadyLoaded: Bool
    ) async {
        guard let commands = try? TaptionWidgetSharedStore.takeCommands(),
              !commands.isEmpty else {
            return
        }
        if !repositoryAlreadyLoaded,
           commands.contains(where: {
               $0.appliedToSharedRepository == true
           }),
           let reloaded = try? await repository.load() {
            snapshot = reloaded
        }
        for command in commands {
            guard command.appliedToSharedRepository != true else {
                continue
            }
            do {
                snapshot = try TaptionWidgetCommandEngine.apply(
                    command,
                    to: snapshot
                )
            } catch {
                userFacingError = "위젯 요청을 반영하지 못했습니다. \(error.localizedDescription)"
            }
        }
    }

    private func publishWidgetPayload() {
        let calendar = Calendar.autoupdatingCurrent
        let now = Date.now
        let payload = TaptionWidgetPayloadFactory.make(
            from: snapshot,
            now: now,
            calendar: calendar
        )
        do {
            try TaptionWidgetSharedStore.writePayload(payload)
            let locationCount = payload.items.filter {
                $0.resolvedLane == .location
            }.count
            let movementCount = payload.items.filter {
                $0.resolvedLane == .movement
            }.count
            Self.integrationLogger.notice(
                "Widget ground-truth publish: snapshotUpdated=\(self.snapshot.updatedAt.timeIntervalSince1970, privacy: .public), generated=\(payload.generatedAt.timeIntervalSince1970, privacy: .public), fingerprint=\(payload.sourceFingerprint ?? "none", privacy: .public), items=\(payload.items.count, privacy: .public), locations=\(locationCount, privacy: .public), movements=\(movementCount, privacy: .public)"
            )
            TaptionPlanDiagnosticsLogger.shared.record(
                "widget_payload_published",
                fields: [
                    "items": String(payload.items.count),
                    "locations": String(locationCount),
                    "movements": String(movementCount),
                ]
            )
            requestImmediateWidgetRefresh()
        } catch {
            Self.integrationLogger.error(
                "Widget ground-truth publish failed: \(error.localizedDescription, privacy: .public)"
            )
            userFacingError = "위젯 데이터를 갱신하지 못했습니다. \(error.localizedDescription)"
            TaptionPlanDiagnosticsLogger.shared.record(
                "widget_payload_failed",
                level: .error,
                fields: ["error": String(describing: type(of: error))]
            )
        }
        publishWatchPayload(now: now, calendar: calendar)
    }

    /// The iPhone snapshot is the only Watch settings source. This method is
    /// intentionally separate from widget serialization so a settings toggle
    /// reaches the Watch immediately, before disk or iCloud work finishes.
    private func publishWatchPayload(
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        let dayStart = calendar.startOfDay(for: now)
        let weekStart = calendar.dateInterval(
            of: .weekOfYear,
            for: dayStart
        )?.start ?? dayStart
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)
            ?? weekStart.addingTimeInterval(7 * 86_400)
        let categoriesByID = Dictionary(
            snapshot.categories.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let activeActualsByPlanID = Dictionary(
            snapshot.actuals.compactMap { actual -> (UUID, ActualRecord)? in
                guard let planID = actual.planID,
                      actual.endedAt == nil else { return nil }
                return (planID, actual)
            },
            uniquingKeysWith: { current, candidate in
                current.startedAt >= candidate.startedAt
                    ? current
                    : candidate
            }
        )
        // Watch payloads are a live execution queue, not a copy of the
        // historical timeline.  Keep a currently-running item even when it
        // started before this moment, include upcoming items through the
        // current week, and omit ended/completed/skipped records entirely.
        let watchItems = snapshot.plans
            .filter { plan in
                guard plan.span.end > now,
                      plan.span.start < weekEnd else {
                    return false
                }
                return plan.status == .planned || plan.status == .running
            }
            .sorted { $0.span.start < $1.span.start }
            .map { plan in
                let category = categoriesByID[plan.categoryID]
                let activeActual = activeActualsByPlanID[plan.id]
                return TaptionWatchPlanItem(
                    id: plan.id,
                    title: plan.title,
                    categoryID: plan.categoryID,
                    startsAt: plan.span.start,
                    endsAt: plan.span.end,
                    status: plan.status.rawValue,
                    actualStartedAt: activeActual?.startedAt,
                    categoryName: category?.name,
                    categoryHex: category?.lightHex,
                    isGoal: GoalRecordPolicy.isGoal(plan),
                    parentID: plan.parentID
                )
            }
        let watchPayload = TaptionWatchPayload(
            generatedAt: now,
            viewportStart: now,
            viewportEnd: weekEnd,
            items: watchItems,
            catStyle: snapshot.settings.catStyle.rawValue,
            reducesMotion: snapshot.settings.reduceMotion,
            todaySummary: TaptionWatchDaySummaryFactory.make(
                plans: snapshot.plans,
                actuals: snapshot.actuals,
                at: now,
                calendar: calendar
            ),
            accelerationSettings: TaptionWatchAccelerationSettings(
                profile: snapshot.settings.watchAccelerationProfile
            ),
            dataSyncProfile: snapshot.settings.watchDataSyncProfile,
            locationTrackingEnabled: snapshot.settings.locationEnabled,
            locationPermissionState:
                snapshot.settings.permissions[.location]?.rawValue,
            activitySuggestion: pendingWatchActivitySuggestion.flatMap {
                now.timeIntervalSince($0.endedAt) <= 2 * 3_600 ? $0 : nil
            }
        )
        do {
            try watchConnectivityService.update(payload: watchPayload)
            TaptionPlanDiagnosticsLogger.shared.record(
                "watch_settings_queued",
                fields: [
                    "acceleration": snapshot.settings
                        .watchAccelerationProfile.displayName,
                    "data_sync": snapshot.settings
                        .watchDataSyncProfile.displayName,
                    "location": String(snapshot.settings.locationEnabled),
                ]
            )
        } catch {
            TaptionPlanDiagnosticsLogger.shared.record(
                "watch_settings_publish_failed",
                level: .error,
                fields: ["error": String(describing: type(of: error))]
            )
        }
    }

    private func requestImmediateWidgetRefresh() {
        widgetReloadFollowupTask?.cancel()
        Self.integrationLogger.notice("Widget timeline reload requested")
        WidgetCenter.shared.reloadTimelines(ofKind: TaptionWidgetKind.schedule)
        WidgetCenter.shared.reloadAllTimelines()
        widgetReloadFollowupTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            WidgetCenter.shared.reloadTimelines(
                ofKind: TaptionWidgetKind.schedule
            )
            WidgetCenter.shared.reloadAllTimelines()
            Self.integrationLogger.notice("Widget timeline reload follow-up requested")
        }
    }

    private var visibleDataSpan: TimeSpan {
        let calendar = Calendar.autoupdatingCurrent
        let level = selectedScale.timelineLevel
        let aggregation = TimelineAggregationEngine(calendar: calendar)
        let navigation = TimelinePeriodNavigationEngine(calendar: calendar)
        let center = aggregation.interval(for: level, containing: selectedDate)
        let previous = navigation.adjacentDate(
            from: selectedDate,
            level: level,
            direction: -1
        ).map { aggregation.interval(for: level, containing: $0) }
        let next = navigation.adjacentDate(
            from: selectedDate,
            level: level,
            direction: 1
        ).map { aggregation.interval(for: level, containing: $0) }
        return TimeSpan(
            start: previous?.start ?? center.start,
            end: next?.end ?? center.end
        )
    }

    private var currentDeviceDataSpan: TimeSpan {
        TimelineAggregationEngine().interval(
            for: .day,
            containing: .now
        )
    }

    private var startupHealthSpan: TimeSpan {
        let calendar = Calendar.autoupdatingCurrent
        let now = Date.now
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(
            byAdding: .day,
            value: -1,
            to: today
        ) ?? now.addingTimeInterval(-2 * 86_400)
        return TimeSpan(start: start, end: now)
    }

    private var recentHealthSpan: TimeSpan {
        let now = Date.now
        let start = Calendar.autoupdatingCurrent.date(
            byAdding: .day,
            value: -31,
            to: Calendar.autoupdatingCurrent.startOfDay(for: now)
        ) ?? now.addingTimeInterval(-31 * 86_400)
        return TimeSpan(start: start, end: now)
    }

    private var periodicHealthSpan: TimeSpan {
        let now = Date.now
        return TimeSpan(
            start: now.addingTimeInterval(
                -HealthRefreshPolicy.periodicLookback
            ),
            end: now
        )
    }

    private func assignTimestampOnlySnapshot(_ value: TaptionDataSnapshot) {
        // Persisting a sensor snapshot updates only the envelope timestamp.
        // Mark that assignment so didSet does not compare every historical
        // plan, actual, place and route just to discover that the collections
        // are unchanged.
        timestampOnlySnapshotAssignment = true
        snapshot = value
    }

    private func persist() async {
        guard !repositoryLoadFailed else {
            Self.integrationLogger.error(
                "Persistence blocked after repository load failure; preserving existing data"
            )
            return
        }
        do {
            applyStoredActivityCorrections()
            await refreshReviewArchives(force: true)
            var value = snapshot
            value.updatedAt = .now
            assignTimestampOnlySnapshot(value)
            try await repository.save(value)
            if permissionState(for: .cloud).isGranted,
               let cloudSyncService {
                do {
                    let localDeviceData = snapshot
                    let uploaded = try await cloudSyncService.upload(
                        cloudPortableSnapshot(value)
                    )
                    assignCloudMergedSnapshot(mergeDeviceLocalData(
                        cloud: uploaded,
                        local: localDeviceData
                    ))
                    try await repository.save(snapshot)
                } catch {
                    if CloudKitErrorPolicy.isProductionSchemaUnavailable(error)
                        || error is RepositoryError
                            && (error as? RepositoryError)
                                == .cloudSchemaUnavailable {
                        snapshot.settings.permissions[.cloud] = .unavailable
                        Self.integrationLogger.error(
                            "CloudKit production schema is unavailable; local save completed"
                        )
                    } else {
                        Self.integrationLogger.error(
                            "CloudKit upload deferred; local save completed: \(error.localizedDescription, privacy: .public)"
                        )
                        TaptionPlanDiagnosticsLogger.shared.record(
                            "cloud_upload_deferred",
                            level: .notice,
                            fields: ["error": String(describing: type(of: error))]
                        )
                    }
                }
            }
            publishWidgetPayload()
            if permissionState(for: .notifications).isGranted,
               snapshot.settings.notificationsEnabled {
                do {
                    try await notificationScheduler.synchronize(
                        plans: snapshot.plans
                    )
                } catch {
                    userFacingError =
                        "계획 알림을 갱신하지 못했습니다. \(error.localizedDescription)"
                }
            }
        } catch {
            userFacingError = "변경 내용을 저장하지 못했습니다. \(error.localizedDescription)"
            TaptionPlanDiagnosticsLogger.shared.record(
                "local_persistence_failed",
                level: .error,
                fields: ["error": String(describing: type(of: error))]
            )
        }
    }

    /// 기기 센서에서만 만들어지는 자동 기록. iCloud로 내보내지 않고 기기
    /// 저장본을 원본으로 유지한다. 새 자동 기록 종류를 더할 때 이 판단을
    /// 두 곳에 나눠 적으면 한쪽이 빠지므로 한 자리에서 본다.
    private nonisolated static func isDeviceLocalActual(
        _ actual: ActualRecord
    ) -> Bool {
        switch actual.source {
        case .healthKit, .appleWatch, .motion, .location, .media, .call,
             .appUsage:
            true
        case .manual, .timer, .calendar, .photo:
            false
        }
    }

    private func cloudPortableSnapshot(
        _ source: TaptionDataSnapshot
    ) -> TaptionDataSnapshot {
        var value = source
        value.actuals.removeAll(where: Self.isDeviceLocalActual)
        value.photos = []
        value.memos = value.memos.map { memo in
            var portable = memo
            portable.attachments = []
            return portable
        }
        value.places = value.places.map(LocationPrivacyFilter.timelineSafe)
        value.travel = value.travel.map { segment in
            var safe = segment
            safe.evidence = []
            return safe
        }
        value.settings.floorCalibration = nil
        value.settings.floorCalibrationHistory = []
        value.settings.movementCorrections = []
        value.settings.activityCorrections = [:]
        // 거절한 자리는 이 기기의 위치 기록에서만 나온 좌표다. 자주가는 곳
        // 자체와 달리 사용자가 적은 값이 아니므로 기기에 남긴다.
        value.settings.dismissedPlaceSuggestions = []
        return value
    }

    private func mergeDeviceLocalData(
        cloud: TaptionDataSnapshot,
        local: TaptionDataSnapshot
    ) -> TaptionDataSnapshot {
        var value = cloud
        let deviceActuals = local.actuals.filter(Self.isDeviceLocalActual)
        let cloudIDs = Set(value.actuals.map(\.id))
        value.actuals.append(contentsOf: deviceActuals.filter {
            !cloudIDs.contains($0.id)
        })
        value.places = deviceRecords(
            local.places,
            recoveringMissingFrom: value.places,
            id: \.id
        ).sorted { $0.span.start < $1.span.start }
        value.travel = deviceRecords(
            local.travel,
            recoveringMissingFrom: value.travel,
            id: \.id
        ).sorted { $0.span.start < $1.span.start }
        value.floorTransitions = deviceRecords(
            local.floorTransitions,
            recoveringMissingFrom: value.floorTransitions,
            id: \.id
        ).sorted { $0.span.start < $1.span.start }
        value.photos = local.photos
        value.settings.permissions = local.settings.permissions
        value.settings.showsPhotos = local.settings.showsPhotos
        value.settings.showsPhotosInWidgets =
            local.settings.showsPhotosInWidgets
        value.settings.selectedCalendarIDs =
            local.settings.selectedCalendarIDs
        value.settings.healthEnabled = local.settings.healthEnabled
        value.settings.locationEnabled = local.settings.locationEnabled
        value.settings.backgroundPreciseLocationEnabled =
            local.settings.backgroundPreciseLocationEnabled
        value.settings.sensorCollectionProfile =
            local.settings.sensorCollectionProfile
        value.settings.watchAccelerationProfile =
            local.settings.watchAccelerationProfile
        value.settings.watchDataSyncProfile =
            local.settings.watchDataSyncProfile
        value.settings.timelineRowOrder =
            AppFeatureSettings.normalizedTimelineRowOrder(
                local.settings.timelineRowOrder
            )
        value.settings.floorCalibration = nil
        value.settings.floorCalibrationHistory =
            local.settings.floorCalibrationHistory
        value.settings.movementCorrections =
            local.settings.movementCorrections
        value.settings.activityCorrections =
            local.settings.activityCorrections
        value.settings.customActivityLabels =
            AppFeatureSettings.normalizedActivityLabels(
                local.settings.customActivityLabels
            )
        value.settings.dismissedPlaceSuggestions =
            local.settings.dismissedPlaceSuggestions
        // Weather is sampled with device location and remains device ground
        // truth, just like the corresponding place and movement records.
        value.weather = WeatherTimelineEngine.coalesced(local.weather)
        value.settings.suppressedActualIDs.formUnion(
            local.settings.suppressedActualIDs
        )
        value.settings.cloudDeletedRecordKeys.formUnion(
            local.settings.cloudDeletedRecordKeys
        )
        value.settings.cloudResetAt = [
            value.settings.cloudResetAt,
            local.settings.cloudResetAt,
        ].compactMap { $0 }.max()
        value.settings.weatherEnabled = local.settings.weatherEnabled
        value.settings.notificationsEnabled =
            local.settings.notificationsEnabled
        value.actuals = ActualRecordSuppressionEngine.visibleRecords(
            from: value.actuals,
            suppressedIDs: value.settings.suppressedActualIDs
        )
        value.actuals = ActivityCorrectionEngine.applying(
            value.settings.activityCorrections,
            to: value.actuals
        )
        // iCloud can still hand back placeholder plans written by an older
        // build on this or another device.
        MemoShellPlanMigration.apply(to: &value)
        return value
    }

    private func deviceRecords<Element, ID: Hashable>(
        _ local: [Element],
        recoveringMissingFrom cloud: [Element],
        id: KeyPath<Element, ID>
    ) -> [Element] {
        var seen = Set(local.map { $0[keyPath: id] })
        return local + cloud.filter { seen.insert($0[keyPath: id]).inserted }
    }

    private func assignCloudMergedSnapshot(_ value: TaptionDataSnapshot) {
        guard value != snapshot else { return }
        var content = value
        content.updatedAt = snapshot.updatedAt
        if content == snapshot {
            assignTimestampOnlySnapshot(value)
        } else {
            snapshot = value
        }
    }

    private func refreshReviewArchives(
        force: Bool,
        asOf: Date = .now
    ) async {
        let interval = max(
            60,
            snapshot.settings.sensorCollectionProfile.interval
        )
        if !force, let lastReviewArchiveRefreshAt,
           asOf.timeIntervalSince(lastReviewArchiveRefreshAt) < interval {
            return
        }
        let source = snapshot
        let revision = timelineRevision
        let reports = await Task.detached(priority: .utility) {
            ReviewReportArchiveEngine.refreshed(
                snapshot: source,
                asOf: asOf
            )
        }.value
        guard revision == timelineRevision else { return }
        lastReviewArchiveRefreshAt = asOf
        guard reports != snapshot.yearlyReports else { return }
        snapshot.yearlyReports = reports
    }

    private func invalidateReviewArchives(
        spans: [TimeSpan] = [],
        dates: [Date] = []
    ) {
        let calendar = Calendar.autoupdatingCurrent
        var starts = Set(dates.map(calendar.startOfDay))
        for span in spans {
            var day = calendar.startOfDay(for: span.start)
            while day < span.end {
                starts.insert(day)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day)
                else { break }
                day = next
            }
        }
        guard !starts.isEmpty else { return }
        snapshot.yearlyReports = snapshot.yearlyReports.compactMap { year in
            let days = year.days.filter { !starts.contains($0.span.start) }
            guard !days.isEmpty else { return nil }
            return ReviewArchiveHierarchy.year(
                span: year.span,
                days: days,
                asOf: .now,
                calendar: calendar
            )
        }
        lastReviewArchiveRefreshAt = nil
    }

    private func persistDeviceLocalSnapshot() async {
        guard !repositoryLoadFailed else {
            Self.integrationLogger.error(
                "Device persistence blocked after repository load failure; preserving existing data"
            )
            return
        }
        // Location and HealthKit callbacks can converge at the same moment.
        // Coalesce those device-only commits so one sensor tick does not
        // trigger duplicate disk writes, widget serialization and timeline
        // reload requests. The coalesced change must still reach disk, so a
        // trailing write is scheduled instead of being dropped.
        if let lastDeviceSnapshotPersistAt,
           Date.now.timeIntervalSince(lastDeviceSnapshotPersistAt) < 1.5 {
            scheduleTrailingDeviceLocalPersist()
            return
        }
        pendingDeviceLocalPersistTask?.cancel()
        pendingDeviceLocalPersistTask = nil
        lastDeviceSnapshotPersistAt = .now
        do {
            applyStoredActivityCorrections()
            await refreshReviewArchives(force: false)
            var value = snapshot
            value.updatedAt = .now
            assignTimestampOnlySnapshot(value)
            try await repository.save(value)
            publishWidgetPayload()
        } catch {
            userFacingError =
                "센서 기록을 저장하지 못했습니다. \(error.localizedDescription)"
        }
    }

    private func scheduleTrailingDeviceLocalPersist() {
        guard pendingDeviceLocalPersistTask == nil else { return }
        pendingDeviceLocalPersistTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self else { return }
            self.pendingDeviceLocalPersistTask = nil
            await self.persistDeviceLocalSnapshot()
        }
    }
}

enum TaptionWatchDaySummaryFactory {
    static func make(
        plans: [PlanRecord],
        actuals: [ActualRecord],
        at date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> TaptionWatchDaySummary {
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(
            byAdding: .day,
            value: 1,
            to: dayStart
        ) ?? dayStart.addingTimeInterval(86_400)
        let day = TimeSpan(start: dayStart, end: dayEnd)
        let scheduled = plans.filter {
            $0.status != .skipped && $0.span.intersection(with: day) != nil
        }
        let recordedSpans: [TimeSpan] = actuals.compactMap {
            $0.span(asOf: date).intersection(with: day)
        }
        let activeCategoryIDs: Set<String> = [
            "movement",
            "exercise",
            "health",
        ]
        let activeSpans: [TimeSpan] = actuals.compactMap { actual -> TimeSpan? in
            guard activeCategoryIDs.contains(actual.categoryID) else {
                return nil
            }
            return actual.span(asOf: date).intersection(with: day)
        }
        return TaptionWatchDaySummary(
            date: dayStart,
            scheduledCount: scheduled.count,
            completedCount: scheduled.filter {
                $0.status == .completed
            }.count,
            recordedMinutes: minutes(in: recordedSpans),
            activeMinutes: minutes(in: activeSpans)
        )
    }

    private static func minutes(in spans: [TimeSpan]) -> Int {
        let ordered = spans.sorted { $0.start < $1.start }
        guard var current = ordered.first else { return 0 }
        var duration: TimeInterval = 0
        for span in ordered.dropFirst() {
            if span.start <= current.end {
                current.end = max(current.end, span.end)
            } else {
                duration += current.duration
                current = span
            }
        }
        duration += current.duration
        return max(0, Int((duration / 60).rounded()))
    }
}

extension PermissionState {
    var isGranted: Bool {
        self == .authorized || self == .limited
    }

    var settingsLabel: String {
        switch self {
        case .notDetermined: "연결하기"
        case .denied: "권한 필요"
        case .limited: "일부 허용"
        case .authorized: "연결됨"
        case .unavailable: "사용 불가"
        }
    }
}

private extension TimeScale {
    init(timelineLevel: TimelineLevel) {
        switch timelineLevel {
        case .day: self = .day
        case .week: self = .week
        case .month: self = .month
        case .year: self = .year
        }
    }
}

private extension CatCoat {
    init(catStyle: CatStyle) {
        switch catStyle {
        case .white: self = .white
        case .calico: self = .calico
        case .mackerel: self = .mackerel
        case .black: self = .black
        case .gray: self = .gray
        case .cheese: self = .cheese
        case .cow: self = .cow
        }
    }

    var catStyle: CatStyle {
        switch self {
        case .white: .white
        case .calico: .calico
        case .mackerel: .mackerel
        case .black: .black
        case .gray: .gray
        case .cheese: .cheese
        case .cow: .cow
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
