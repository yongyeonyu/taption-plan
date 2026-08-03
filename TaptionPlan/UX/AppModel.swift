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
    var selectedMemoPlanID: UUID?
    var selectedCatCoat: CatCoat = .calico
    var reviewScale: ReviewScale = .week
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
    private(set) var isRefreshingIntegrations = false
    private(set) var isSensorCollecting = false
    private(set) var isCloudSyncing = false
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
    var floorCalibrationPrompt: FloorCalibrationPrompt? = nil
    private(set) var sleepSessions: [SleepSession] = []
    private(set) var lastHealthRefreshAt: Date?
    private(set) var appleWatchConnectionState: AppleWatchConnectionState = .unsupported
    private(set) var appUsageAuthorizationState: ScreenTimeAuthorizationState = .unavailable
    var userFacingError: String?
    @ObservationIgnored private var lastFloorCalibrationPromptKey: String? = nil

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

    @ObservationIgnored private let repository: any PlanDataRepository
    @ObservationIgnored private let calendarService: AppleCalendarService
    @ObservationIgnored private let photoService: ApplePhotoLibraryService
    @ObservationIgnored private let healthService: AppleHealthService
    @ObservationIgnored private let sensorService: AppleSensorDataService?
    @ObservationIgnored private let weatherService: AppleWeatherContextService
    @ObservationIgnored private let airQualityService: AirQualityContextService
    @ObservationIgnored private let cloudSyncService: CloudKitSnapshotSyncService?
    @ObservationIgnored private let placeNameResolver: PlaceNameResolver
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
    @ObservationIgnored private var isHealthBackgroundDeliveryConfigured = false
    @ObservationIgnored private var sensorAnalysisDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var finalizedTrackingSessionIDs = Set<UUID>()
    @ObservationIgnored private var liveWeatherRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var lastLiveEnvironmentPoint: GeoPoint?
    @ObservationIgnored private var lastLiveEnvironmentAt: Date?
    @ObservationIgnored private var lastLiveEnvironmentFailureAt: Date?
    @ObservationIgnored private var lastTrackingSessionRecoveryPersistAt: Date?
    @ObservationIgnored private var lastDeviceSnapshotPersistAt: Date?
    @ObservationIgnored private var liveMergeCacheKey: LiveMergeCacheKey?
    @ObservationIgnored private var liveMergeCacheValue: [SensorReading] = []
    @ObservationIgnored private var sensorRefreshFingerprints:
        [Date: SensorRefreshFingerprint] = [:]

    // Keep the live route bounded without shifting the whole array on every
    // GPS tick.  Trimming in batches makes long running sessions amortized
    // O(1) per append while preserving the same 4,000-point render limit.
    private static let liveRouteHardLimit = 4_000
    private static let liveRouteSoftLimit = 4_512

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
        calendarService: AppleCalendarService = AppleCalendarService(),
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
        voiceMemoRecorder: VoiceMemoRecorder = VoiceMemoRecorder(),
        voiceMemoPlayer: VoiceMemoPlayer = VoiceMemoPlayer(),
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
        screenTimeUsageService: ScreenTimeUsageService =
            ScreenTimeUsageService()
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
        self.calendarService = calendarService
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
        self.voiceMemoRecorder = voiceMemoRecorder
        self.voiceMemoPlayer = voiceMemoPlayer
        self.liveActivityController = liveActivityController
        self.notificationScheduler = notificationScheduler
        self.purchaseService = purchaseService
        self.watchConnectivityService = watchConnectivityService
        self.airPodsActivityService = airPodsActivityService
        self.screenTimeUsageService = screenTimeUsageService
        self.appUsageAuthorizationState = screenTimeUsageService.authorizationState
        self.watchSensorArchive = try?
            AppleWatchSensorActivityArchive.applicationSupport()
        self.rawDeviceDataArchive = rawArchive
        Self.integrationLogger.notice(
            "Repository selected: \(repositorySource, privacy: .public)"
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
            onStatusChange: { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.appleWatchConnectionState = state
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
        switch detail {
        case nil, .group, .goal, .locationTimeline:
            true
        default:
            false
        }
    }

    var settings: AppFeatureSettings {
        snapshot.settings
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
        selectedTab = tab
        detail = nil
        groupNavigationPath = []
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
        Self.normalizeRecordRelationships(in: &loaded)
        loaded.actuals = ActualRecordSuppressionEngine.visibleRecords(
            from: loaded.actuals,
            suppressedIDs: loaded.settings.suppressedActualIDs
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

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                var source = try await repository.load()
                source.weather = WeatherTimelineEngine.coalesced(source.weather)
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
                scheduleBootstrapPreparation()
            } catch {
                var fallback = TaptionDataSnapshot.empty
                fallback.categories = CategoryCatalog.builtIn
                snapshot = fallback
                isBootstrapped = true
                userFacingError = "저장된 데이터를 불러오지 못했습니다. \(error.localizedDescription)"
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
        airPodsActivityService.start { [weak self] observation in
            self?.applyAirPodsActivity(observation)
        }
        scheduleForegroundRefresh()
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

    func refreshAppUsageAuthorizationState() {
        appUsageAuthorizationState = screenTimeUsageService.authorizationState
        snapshot.settings.permissions[.appUsage] = switch appUsageAuthorizationState {
        case .approved: .authorized
        case .denied: .denied
        case .notDetermined: .notDetermined
        case .unavailable: .unavailable
        }
    }

    func requestAppUsageAuthorization() async {
        guard !isRefreshingIntegrations else { return }
        isRefreshingIntegrations = true
        do {
            try await screenTimeUsageService.requestAuthorization()
            refreshAppUsageAuthorizationState()
            await persist()
        } catch {
            refreshAppUsageAuthorizationState()
            userFacingError = "앱 사용시간 권한을 허용하지 못했습니다."
        }
        isRefreshingIntegrations = false
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
        await persist()
    }

    func disableLocationCollection() async {
        sensorService?.stopCollection()
        isSensorCollecting = false
        snapshot.settings.locationEnabled = false
        snapshot.settings.backgroundPreciseLocationEnabled = false
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
        isRefreshingIntegrations = true
        defer { isRefreshingIntegrations = false }
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
            }
            return
        }
        isCloudSyncing = true
        if await cloudSyncService.isSchemaUnavailable() {
            snapshot.settings.permissions[.cloud] = .unavailable
            isCloudSyncing = false
            return
        }
        let state = await cloudSyncService.accountState()
        snapshot.settings.permissions[.cloud] = state
        guard state.isGranted else {
            isCloudSyncing = false
            return
        }

        do {
            let localDeviceData = snapshot
            let (cloudValue, _) = try await cloudSyncService.synchronize(
                local: cloudPortableSnapshot(snapshot)
            )
            snapshot = mergeDeviceLocalData(
                cloud: cloudValue,
                local: localDeviceData
            )
            try await repository.save(snapshot)
            publishWidgetPayload()
        } catch {
            if CloudKitErrorPolicy.isProductionSchemaUnavailable(error)
                || error is RepositoryError
                    && (error as? RepositoryError) == .cloudSchemaUnavailable {
                snapshot.settings.permissions[.cloud] = .unavailable
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
        snapshot.settings.reduceMotion = enabled
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
        Task { await persist() }
    }

    func setWatchDataSyncProfile(
        _ profile: TaptionWatchDataSyncProfile
    ) {
        guard snapshot.settings.watchDataSyncProfile != profile else {
            return
        }
        snapshot.settings.watchDataSyncProfile = profile
        Task { await persist() }
    }

    func requestWatchDataSync() {
        watchConnectivityService.requestWatchDataSync()
    }

    func refreshAppleWatchConnectionState() {
        watchConnectivityService.refreshConnectionState()
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
        snapshot = empty
        pendingSetupCategoryIDs = Set(empty.categories.map(\.id))
        isEditingSetupCategories = false
        selectedGroupPlanID = nil
        groupNavigationPath = []
        selectedMemoPlanID = nil
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

    var selectedMemoPlan: PlanRecord? {
        guard let selectedMemoPlanID else { return nil }
        return snapshot.plans.first { $0.id == selectedMemoPlanID }
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

    func openMemo(for planID: UUID?) {
        selectedMemoPlanID = planID
            ?? selectedGroupPlanID
            ?? snapshot.plans.first?.id
        detail = .memo
    }

    @discardableResult
    func memoPlan(
        forCategoryID categoryID: String,
        categoryName: String,
        near date: Date
    ) -> PlanRecord {
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: date)
        let existing = snapshot.plans
            .filter {
                $0.categoryID == categoryID
                    && $0.title == "메모 - \(categoryName)"
                    && calendar.isDate($0.span.start, inSameDayAs: date)
            }
            .sorted { $0.createdAt < $1.createdAt }
            .first
        if let existing { return existing }

        let minuteStart = calendar.date(
            bySettingHour: calendar.component(.hour, from: date),
            minute: calendar.component(.minute, from: date),
            second: 0,
            of: dayStart
        ) ?? date
        let plan = PlanRecord(
            title: "메모 - \(categoryName)",
            span: TimeSpan(
                start: minuteStart,
                end: minuteStart.addingTimeInterval(60)
            ),
            categoryID: categoryID,
            isImportant: false
        )
        snapshot.plans.append(plan)
        snapshot.plans.sort { $0.span.start < $1.span.start }
        Task { await persist() }
        return plan
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

    func addMemo(
        text: String,
        kind: MemoKind,
        to planID: UUID? = nil
    ) {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = planID ?? selectedMemoPlanID
        guard !cleanText.isEmpty, let destination,
              snapshot.plans.contains(where: { $0.id == destination }) else {
            return
        }
        snapshot.memos.append(
            ActionMemo(planID: destination, kind: kind, text: cleanText)
        )
        Task { await persist() }
    }

    func addMemo(
        text: String,
        kind: MemoKind,
        toTargetID targetID: String,
        planID: UUID? = nil
    ) {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = planID ?? selectedMemoPlanID
        guard !cleanText.isEmpty, !targetID.isEmpty, let destination,
              snapshot.plans.contains(where: { $0.id == destination }) else {
            return
        }
        snapshot.memos.append(
            ActionMemo(
                planID: destination,
                targetID: targetID,
                kind: kind,
                text: cleanText
            )
        )
        Task { await persist() }
    }

    func deleteMemo(_ memoID: UUID) {
        snapshot.memos.removeAll { $0.id == memoID }
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

    func addAttachmentMemo(
        kind: MemoKind,
        attachmentKind: AttachmentKind,
        localIdentifier: String,
        text: String? = nil,
        to planID: UUID? = nil
    ) {
        let destination = planID ?? selectedMemoPlanID
        guard let destination,
              snapshot.plans.contains(where: { $0.id == destination }) else {
            return
        }
        let fallbackText = attachmentKind == .photo ? "사진 메모" : "음성 메모"
        snapshot.memos.append(
            ActionMemo(
                planID: destination,
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
        )
        Task { await persist() }
    }

    func toggleVoiceMemo(
        kind: MemoKind,
        to planID: UUID? = nil
    ) async {
        let destination = planID ?? selectedMemoPlanID
        guard destination != nil else {
            userFacingError = "음성 메모를 연결할 계획을 먼저 선택해 주세요."
            return
        }

        if isRecordingVoiceMemo {
            guard let url = voiceMemoRecorder.stop() else {
                isRecordingVoiceMemo = false
                return
            }
            isRecordingVoiceMemo = false
            addAttachmentMemo(
                kind: kind,
                attachmentKind: .audio,
                localIdentifier: url.path,
                to: destination
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
            userFacingError =
                "음성 녹음을 시작하지 못했습니다. \(error.localizedDescription)"
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
        snapshot.recordLinks.removeAll {
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
            snapshot.recordLinks.removeAll {
                $0.fromNodeID == sourceNodeID
            }
        } else {
            snapshot.recordLinks.removeAll {
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
        snapshot.plans.removeAll { deletedIDs.contains($0.id) }
        snapshot.memos.removeAll {
            deletedIDs.contains($0.planID)
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
        snapshot.recordLinks.removeAll { link in
            recordNodePlanID(link.fromNodeID).map(deletedIDs.contains) == true
                || recordNodePlanID(link.toNodeID).map(deletedIDs.contains) == true
        }
        selectedMemoPlanID = nil
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

    func deleteActual(_ actualID: UUID) async {
        guard let actual = snapshot.actuals.first(where: {
            $0.id == actualID
        }) else {
            userFacingError = "삭제할 실제 기록을 찾지 못했습니다."
            return
        }

        snapshot.settings.suppressedActualIDs.insert(actualID)
        snapshot.actuals.removeAll { $0.id == actualID }
        snapshot.recordLinks.removeAll {
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
        snapshot.actuals = AppleWatchSensorActivityEngine.upserting(
            summary,
            into: snapshot.actuals,
            linkedPlan: linkedPlan,
            atHome: isWatchSummaryAtHome(summary)
        )
        snapshot.actuals = ActualRecordSuppressionEngine.visibleRecords(
            from: snapshot.actuals,
            suppressedIDs: snapshot.settings.suppressedActualIDs
        )
        await persistDeviceLocalSnapshot()
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

    func refreshSensorTimeline(containing date: Date? = nil) async {
        guard let sensorService else { return }
        let span = TimelineAggregationEngine().interval(
            for: .day,
            containing: date ?? selectedDate
        )
        let archivedReadings: [SensorReading]
        do {
            archivedReadings = try await sensorService.archivedReadings(
                in: span
            )
        } catch {
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
        if archivedReadings.isEmpty,
           photoLocationReadings.isEmpty,
           motionActivities.isEmpty,
           healthMovementEvidence.isEmpty {
            return
        }

        let readings = AppleDeviceGroundTruthEngine
            .applyingMotionHistory(
                to: (archivedReadings + photoLocationReadings)
                    .sorted { $0.timestamp < $1.timestamp },
                activities: motionActivities
            )
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
            healthEvidence: healthMovementEvidence
        )
        let travel = MovementCorrectionEngine.applying(
            snapshot.settings.movementCorrections,
            to: inferredTravel,
            places: basePlaces
        )

        snapshot.travel.removeAll {
            $0.span.intersection(with: span) != nil
        }
        if !readings.compactMap(\.point).isEmpty {
            snapshot.places.removeAll {
                $0.span.intersection(with: span) != nil
            }
            snapshot.floorTransitions.removeAll {
                $0.span.intersection(with: span) != nil
            }
            snapshot.places.append(contentsOf: places)
            snapshot.floorTransitions.append(contentsOf: floors)
        }
        snapshot.travel.append(contentsOf: travel)
        snapshot.places.sort { $0.span.start < $1.span.start }
        snapshot.travel.sort { $0.span.start < $1.span.start }
        snapshot.floorTransitions.sort { $0.span.start < $1.span.start }

        if snapshot.settings.locationEnabled || snapshot.settings.weatherEnabled {
            await refreshWeather(
                for: basePlaces,
                in: span,
                fallbackReading: latestReadingWithPoint
            )
        }
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

    func setFrequentPlaceToCurrentLocation(
        _ placeID: UUID,
        floor: Int
    ) {
        guard (-20...200).contains(floor), floor != 0 else {
            userFacingError = "층수는 지하 20층부터 지상 200층 사이로 입력해 주세요."
            return
        }
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
        snapshot.settings.frequentPlaces[index].setLocation(
            from: reading,
            floor: floor
        )
        floorCalibrationPrompt = nil
        lastFloorCalibrationPromptKey = nil
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

    func clearFrequentPlaceLocation(_ placeID: UUID) {
        guard let index = snapshot.settings.frequentPlaces.firstIndex(where: {
            $0.id == placeID
        }) else {
            return
        }
        snapshot.settings.frequentPlaces[index].clearLocation()
        floorCalibrationPrompt = nil
        lastFloorCalibrationPromptKey = nil
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

    func addFrequentPlaceFloorCalibration(
        _ placeID: UUID,
        floor: Int
    ) {
        guard (-20...200).contains(floor), floor != 0,
              let reading = latestSensorReading,
              reading.point != nil,
              let index = snapshot.settings.frequentPlaces.firstIndex(where: {
                  $0.id == placeID
              }) else {
            userFacingError = "현재 위치·고도 센서를 읽은 뒤 다시 시도해 주세요."
            return
        }
        snapshot.settings.frequentPlaces[index].addFloorCalibration(
            from: reading,
            floor: floor
        )
        floorCalibrationPrompt = nil
        lastFloorCalibrationPromptKey = nil
        snapshot.settings.frequentPlaces =
            AppFeatureSettings.mergedFrequentPlaces(
                snapshot.settings.frequentPlaces
            )
        updateFloorEstimate(with: reading)
        Task {
            await persist()
            await refreshSensorTimeline(containing: selectedDate)
        }
    }

    func acceptFloorCalibrationPrompt() {
        guard let prompt = floorCalibrationPrompt else { return }
        addFrequentPlaceFloorCalibration(
            prompt.placeID,
            floor: prompt.suggestedFloor
        )
    }

    func dismissFloorCalibrationPrompt() {
        floorCalibrationPrompt = nil
    }

    /// 자주가는 곳의 감지 반경과 건물별 층고를 저장합니다.
    /// 층고는 기압/상대고도 차이를 층수로 환산할 때 사용됩니다.
    func updateFrequentPlaceDetails(
        _ placeID: UUID,
        name: String,
        radiusMeters: Double,
        floorHeightMeters: Double,
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
        snapshot.settings.frequentPlaces[index].floorHeightMeters = min(
            max(floorHeightMeters, 2.2),
            5.0
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
        if !snapshot.floorTransitions[index].evidence.contains("사용자 확인") {
            snapshot.floorTransitions[index].evidence.append("사용자 확인")
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
        snapshot.settings.permissions[.photos] = photoService.permissionState()
        if !permissionState(for: .photos).isGranted {
            snapshot.settings.showsPhotos = false
            snapshot.settings.showsPhotosInWidgets = false
            snapshot.photos = []
        }
        snapshot.settings.permissions[.calendar] = calendarService.permissionState()
        if !permissionState(for: .calendar).isGranted {
            snapshot.settings.selectedCalendarIDs = []
            snapshot.calendarEvents = []
        }
        do {
            snapshot.settings.permissions[.health] =
                try await healthService.authorizationRequestState()
        } catch {
            snapshot.settings.permissions[.health] = healthService.permissionState()
        }
        if let sensorService {
            snapshot.settings.permissions[.location] =
                sensorService.locationPermissionState()
            snapshot.settings.permissions[.motion] =
                sensorService.motionPermissionState()
            snapshot.settings.backgroundPreciseLocationEnabled =
                snapshot.settings.locationEnabled
                && sensorService.hasAlwaysLocationAuthorization()
            sensorAvailability = sensorService.hardwareAvailability()
            if !permissionState(for: .location).isGranted {
                sensorService.stopCollection()
                isSensorCollecting = false
                snapshot.settings.locationEnabled = false
                snapshot.settings.backgroundPreciseLocationEnabled = false
            }
        } else {
            snapshot.settings.permissions[.location] = .unavailable
            snapshot.settings.permissions[.motion] = .unavailable
            snapshot.settings.locationEnabled = false
            snapshot.settings.backgroundPreciseLocationEnabled = false
        }
        snapshot.settings.permissions[.notifications] =
            await notificationScheduler.authorizationState()
        if !permissionState(for: .notifications).isGranted {
            snapshot.settings.notificationsEnabled = false
        }
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

        do {
            let span = requestedSpan ?? recentHealthSpan
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
            snapshot.actuals = AppleDeviceGroundTruthEngine
                .replacingHealthKitActuals(
                    existing: snapshot.actuals,
                    with: visibleFreshActuals,
                    inside: span
                )
            sleepSessions.removeAll {
                $0.span.intersection(with: span) != nil
            }
            sleepSessions.append(contentsOf: freshSessions)
            sleepSessions.sort { $0.span.start < $1.span.start }
            lastHealthRefreshAt = .now
            Self.integrationLogger.notice(
                "HealthKit refresh completed: actuals=\(freshActuals.count, privacy: .public), sleepSessions=\(freshSessions.count, privacy: .public), periodic=\(requestedSpan != nil, privacy: .public)"
            )
        } catch {
            Self.integrationLogger.error(
                "HealthKit refresh failed: \(error.localizedDescription, privacy: .public)"
            )
            if showErrors {
                userFacingError =
                    "건강 데이터를 읽지 못했습니다. \(error.localizedDescription)"
            }
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
                "HealthKit background delivery enabled for activity and sleep"
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
                    guard let reference = place.point,
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
        latestAltitudeEstimate = FloorCalibrationEngine().estimate(
            reading: reading,
            calibration: calibration
        )
        guard let estimate = latestAltitudeEstimate else { return }
        let knownFloors = calibration.knownFloors
        guard !knownFloors.contains(estimate.floor),
              abs(estimate.floor - calibration.referenceFloor) >= 1,
              estimate.confidence != .low else {
            return
        }
        let key = "\(match.id.uuidString):\(estimate.floor)"
        guard lastFloorCalibrationPromptKey != key else { return }
        lastFloorCalibrationPromptKey = key
        floorCalibrationPrompt = FloorCalibrationPrompt(
            placeID: match.id,
            placeName: match.name,
            suggestedFloor: estimate.floor,
            measuredAltitudeMeters: estimate.seaLevelAltitudeMeters
        )
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
                await self.persistDeviceLocalSnapshot()
            } catch {
                self.lastLiveEnvironmentFailureAt = date
                Self.integrationLogger.info(
                    "Live weather context unavailable: \(error.localizedDescription, privacy: .public)"
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
        }

        // This refresh runs as part of automatic sensor analysis.  A weather
        // provider outage must never interrupt an exercise session (or show a
        // modal alert during background collection).  Keep existing context
        // data and let the next refresh retry instead.
        if let firstError, contexts.isEmpty {
            Self.integrationLogger.info(
                "Stored weather refresh unavailable: \(firstError.localizedDescription, privacy: .public)"
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
        } catch {
            Self.integrationLogger.info(
                "Stored weather fallback unavailable: \(error.localizedDescription, privacy: .public)"
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
        let activeActualPairs: [(UUID, ActualRecord)] = snapshot.actuals
            .compactMap { actual in
                guard let planID = actual.planID,
                      actual.endedAt == nil else {
                    return nil
                }
                return (planID, actual)
            }
        let activeActualsByPlanID = Dictionary(
            activeActualPairs,
            uniquingKeysWith: { current, candidate in
                current.startedAt >= candidate.startedAt
                    ? current
                    : candidate
            }
        )
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
            requestImmediateWidgetRefresh()
        } catch {
            Self.integrationLogger.error(
                "Widget ground-truth publish failed: \(error.localizedDescription, privacy: .public)"
            )
            userFacingError = "위젯 데이터를 갱신하지 못했습니다. \(error.localizedDescription)"
        }
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
            generatedAt: .now,
            viewportStart: now,
            viewportEnd: weekEnd,
            items: watchItems,
            catStyle: snapshot.settings.catStyle.rawValue,
            reducesMotion: snapshot.settings.reduceMotion,
            todaySummary: TaptionWatchDaySummaryFactory.make(
                plans: snapshot.plans,
                actuals: snapshot.actuals,
                at: .now,
                calendar: calendar
            ),
            accelerationSettings: TaptionWatchAccelerationSettings(
                profile: snapshot.settings.watchAccelerationProfile
            ),
            dataSyncProfile: snapshot.settings.watchDataSyncProfile
        )
        try? watchConnectivityService.update(payload: watchPayload)
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
        do {
            var value = snapshot
            value.updatedAt = .now
            assignTimestampOnlySnapshot(value)
            try await repository.save(value)
            if permissionState(for: .cloud).isGranted,
               let cloudSyncService {
                do {
                    let uploaded = try await cloudSyncService.upload(
                        cloudPortableSnapshot(value)
                    )
                    var uploadedValue = snapshot
                    uploadedValue.updatedAt = uploaded.updatedAt
                    assignTimestampOnlySnapshot(uploadedValue)
                    try await repository.save(uploadedValue)
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
                        throw error
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
        }
    }

    private func cloudPortableSnapshot(
        _ source: TaptionDataSnapshot
    ) -> TaptionDataSnapshot {
        var value = source
        value.actuals.removeAll {
            $0.source == .healthKit
                || $0.source == .appleWatch
                || $0.source == .motion
                || $0.source == .media
                || $0.source == .call
        }
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
        value.settings.movementCorrections = []
        return value
    }

    private func mergeDeviceLocalData(
        cloud: TaptionDataSnapshot,
        local: TaptionDataSnapshot
    ) -> TaptionDataSnapshot {
        var value = cloud
        let deviceActuals = local.actuals.filter {
            $0.source == .healthKit
                || $0.source == .appleWatch
                || $0.source == .motion
                || $0.source == .media
                || $0.source == .call
        }
        let cloudIDs = Set(value.actuals.map(\.id))
        value.actuals.append(contentsOf: deviceActuals.filter {
            !cloudIDs.contains($0.id)
        })
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
        value.settings.movementCorrections =
            local.settings.movementCorrections
        // Weather is sampled with device location and remains device ground
        // truth, just like the corresponding place and movement records.
        value.weather = WeatherTimelineEngine.coalesced(local.weather)
        value.settings.suppressedActualIDs.formUnion(
            local.settings.suppressedActualIDs
        )
        value.settings.weatherEnabled = local.settings.weatherEnabled
        value.settings.notificationsEnabled =
            local.settings.notificationsEnabled
        value.actuals = ActualRecordSuppressionEngine.visibleRecords(
            from: value.actuals,
            suppressedIDs: value.settings.suppressedActualIDs
        )
        return value
    }

    private func persistDeviceLocalSnapshot() async {
        // Location and HealthKit callbacks can converge at the same moment.
        // Coalesce those device-only commits so one sensor tick does not
        // trigger duplicate disk writes, widget serialization and timeline
        // reload requests. The in-memory ground truth remains current and the
        // next scheduled commit catches any change inside this short window.
        if let lastDeviceSnapshotPersistAt,
           Date.now.timeIntervalSince(lastDeviceSnapshotPersistAt) < 1.5 {
            return
        }
        lastDeviceSnapshotPersistAt = .now
        do {
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
