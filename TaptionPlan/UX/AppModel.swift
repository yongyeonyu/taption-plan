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
    var groupNavigationPath: [UUID] = []
    var selectedMemoPlanID: UUID?
    var selectedCatCoat: CatCoat = .calico
    var reviewScale: ReviewScale = .week
    var pendingProfileSelection: ProfileSelection =
        TemplateCatalog.representativeSelections[0]

    private(set) var snapshot: TaptionDataSnapshot = .empty {
        didSet {
            snapshotRevision &+= 1
        }
    }
    @ObservationIgnored private(set) var snapshotRevision: UInt64 = 0
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
    private(set) var latestAltitudeEstimate: CalibratedAltitudeEstimate?
    private(set) var sleepSessions: [SleepSession] = []
    private(set) var appleWatchConnectionState: AppleWatchConnectionState = .unsupported
    var userFacingError: String?

    @ObservationIgnored private let repository: any PlanDataRepository
    @ObservationIgnored private let calendarService: AppleCalendarService
    @ObservationIgnored private let photoService: ApplePhotoLibraryService
    @ObservationIgnored private let healthService: AppleHealthService
    @ObservationIgnored private let sensorService: AppleSensorDataService?
    @ObservationIgnored private let weatherService: AppleWeatherContextService
    @ObservationIgnored private let cloudSyncService: CloudKitSnapshotSyncService?
    @ObservationIgnored private let placeNameResolver: PlaceNameResolver
    @ObservationIgnored private let voiceMemoRecorder: VoiceMemoRecorder
    @ObservationIgnored private let voiceMemoPlayer: VoiceMemoPlayer
    @ObservationIgnored private let liveActivityController: TaptionLiveActivityController
    @ObservationIgnored private let notificationScheduler: PlanNotificationScheduler
    @ObservationIgnored private let purchaseService: StoreKitPurchaseService
    @ObservationIgnored private let watchConnectivityService: AppleWatchConnectivityService
    @ObservationIgnored private let watchSensorArchive:
        AppleWatchSensorActivityArchive?
    @ObservationIgnored private let rawDeviceDataArchive:
        RawDeviceDataMonthlyArchive?
    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored private var lastForegroundRefreshAt: Date?

    init(
        repository: (any PlanDataRepository)? = nil,
        calendarService: AppleCalendarService = AppleCalendarService(),
        photoService: ApplePhotoLibraryService = ApplePhotoLibraryService(),
        healthService: AppleHealthService = AppleHealthService(),
        sensorService: AppleSensorDataService? = nil,
        weatherService: AppleWeatherContextService =
            AppleWeatherContextService(),
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
            AppleWatchConnectivityService()
    ) {
        if let repository {
            self.repository = repository
        } else if let sharedRepository = try? FilePlanRepository.appGroup(),
                  let legacyRepository =
                    try? FilePlanRepository.applicationSupport() {
            self.repository = MigratingPlanRepository(
                primary: sharedRepository,
                legacy: legacyRepository
            )
        } else if let sharedRepository =
                    try? FilePlanRepository.appGroup() {
            self.repository = sharedRepository
        } else if let fileRepository = try? FilePlanRepository.applicationSupport() {
            self.repository = fileRepository
        } else {
            self.repository = InMemoryPlanRepository()
        }
        self.calendarService = calendarService
        self.photoService = photoService
        self.healthService = healthService
        self.sensorService = sensorService ?? (try? AppleSensorDataService.applicationSupport())
        self.weatherService = weatherService
        self.cloudSyncService = cloudSyncService
        self.placeNameResolver = placeNameResolver
        self.voiceMemoRecorder = voiceMemoRecorder
        self.voiceMemoPlayer = voiceMemoPlayer
        self.liveActivityController = liveActivityController
        self.notificationScheduler = notificationScheduler
        self.purchaseService = purchaseService
        self.watchConnectivityService = watchConnectivityService
        self.watchSensorArchive = try?
            AppleWatchSensorActivityArchive.applicationSupport()
        self.rawDeviceDataArchive = try?
            RawDeviceDataMonthlyArchive.applicationSupport()
        self.voiceMemoPlayer.onFinish = { [weak self] in
            self?.playingVoiceAttachmentID = nil
        }
        self.sensorService?.onReadingPersisted = { [weak self] reading in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateFloorEstimate(with: reading)
                await self.refreshSensorTimeline(
                    containing: reading.timestamp
                )
                await self.persistDeviceLocalSnapshot()
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
            onStatusChange: { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.appleWatchConnectionState = state
                }
            }
        )
    }

    var showsBottomBar: Bool {
        switch detail {
        case nil, .group, .locationTimeline:
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
            ? "건강 기록 \(deviceRecords.count)건 동기화"
            : "건강 연결 꺼짐"
        return "\(appleWatchConnectionState.settingsLabel) · \(health)"
    }

    func selectTab(_ tab: RootTab) {
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
        selectedScale = scale
        if settings.rememberLastScale {
            snapshot.settings.startScale = scale.timelineLevel
            Task { await persist() }
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

    func openDeepLink(_ url: URL) {
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
            guard let plan = snapshot.plans.first(where: {
                $0.id == planID
            }) else {
                userFacingError = "위젯에서 선택한 계획을 찾지 못했습니다."
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

    func bootstrap() async {
        guard !isBootstrapped else {
            await refreshPermissionStates()
            resumeSensorCollectionIfNeeded()
            return
        }
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                var loaded = try await repository.load()
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
                migrateLegacyFloorCalibration(in: &loaded)
                loaded.actuals = ActualRecordSuppressionEngine.visibleRecords(
                    from: loaded.actuals,
                    suppressedIDs: loaded.settings.suppressedActualIDs
                )
                snapshot = loaded
                try await repository.save(snapshot)
                publishWidgetPayload()
                selectedScale = TimeScale(timelineLevel: loaded.settings.startScale)
                selectedCatCoat = CatCoat(catStyle: loaded.settings.catStyle)
                pendingProfileSelection =
                    loaded.profile ?? TemplateCatalog.representativeSelections[0]
                if loaded.updatedAt == .distantPast,
                   loaded.profile == nil,
                   loaded.plans.isEmpty {
                    detail = .onboarding
                }
                await applyPendingWidgetCommands(
                    repositoryAlreadyLoaded: true
                )
                isBootstrapped = true
                await synchronizeCloud(showErrors: false)
                await refreshPermissionStates()
                resumeSensorCollectionIfNeeded()
                await refreshEnabledData(
                    includesCurrentDeviceDay: true
                )
                await refreshStore(showErrors: false)
                await persist()
                lastForegroundRefreshAt = .now
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

    func sceneBecameActive() async {
        await bootstrap()
        watchConnectivityService.refreshConnectionState()
        if let lastForegroundRefreshAt,
           Date.now.timeIntervalSince(lastForegroundRefreshAt) < 5 {
            return
        }
        await applyPendingWidgetCommands(repositoryAlreadyLoaded: false)
        await refreshPermissionStates()
        resumeSensorCollectionIfNeeded()
        await refreshEnabledData(
            includesCurrentDeviceDay: true
        )
        await refreshStore(showErrors: false)
        await persist()
        lastForegroundRefreshAt = .now
    }

    func sceneEnteredBackground() async {
        await persist()
    }

    func permissionState(for feature: PermissionFeature) -> PermissionState {
        snapshot.settings.permissions[feature] ?? .notDetermined
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
        snapshot.actuals.removeAll { $0.source == .healthKit }
        sleepSessions = []
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
        includesCurrentDeviceDay: Bool = false
    ) async {
        guard !isRefreshingIntegrations else { return }
        isRefreshingIntegrations = true
        defer { isRefreshingIntegrations = false }
        if permissionState(for: .photos).isGranted, settings.showsPhotos {
            refreshPhotos()
        }
        if permissionState(for: .calendar).isGranted,
           !settings.selectedCalendarIDs.isEmpty {
            refreshCalendarEvents()
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
            await refreshHealthData()
        }
        if settings.locationEnabled || hasPhotoLocations(in: visibleDataSpan) {
            if includesCurrentDeviceDay {
                await refreshSensorTimeline(containing: .now)
            }
            if !includesCurrentDeviceDay
                || !Calendar.autoupdatingCurrent.isDateInToday(selectedDate) {
                await refreshSensorTimeline(containing: selectedDate)
            }
        }
        logAutomaticRecordSummary()
        // Calendar, HealthKit, Watch, location and motion records are device
        // ground truth. Save them locally before any potentially slow cloud
        // request so opening the app always updates today's timeline first.
        await persistDeviceLocalSnapshot()
    }

    func synchronizeCloud(showErrors: Bool = true) async {
        guard let cloudSyncService, !isCloudSyncing else {
            if cloudSyncService == nil {
                snapshot.settings.permissions[.cloud] = .unavailable
            }
            return
        }
        isCloudSyncing = true
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
            if showErrors {
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

    func setWidgetPhotosVisible(_ visible: Bool) {
        snapshot.settings.showsPhotosInWidgets =
            visible && permissionState(for: .photos).isGranted
        Task { await persist() }
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
        isSensorCollecting = false
        await notificationScheduler.cancelAllPlanReminders()
        var empty = TaptionDataSnapshot.empty
        empty.categories = CategoryCatalog.builtIn
        empty.settings.permissions = snapshot.settings.permissions
        empty.settings.permissions[.cloud] =
            snapshot.settings.permissions[.cloud] ?? .notDetermined
        snapshot = empty
        pendingProfileSelection = TemplateCatalog.representativeSelections[0]
        selectedGroupPlanID = nil
        groupNavigationPath = []
        selectedMemoPlanID = nil
        sleepSessions = []
        try? await sensorService?.deleteArchivedReadings()
        await persist()
    }

    var pendingTemplateApplication: TemplateApplication? {
        try? TemplateCatalog.apply(pendingProfileSelection)
    }

    var currentProfileDisplayName: String {
        guard let profile = snapshot.profile,
              let application = try? TemplateCatalog.apply(profile) else {
            return "미설정"
        }
        return application.displayName
    }

    var selectedMemoPlan: PlanRecord? {
        guard let selectedMemoPlanID else { return nil }
        return snapshot.plans.first { $0.id == selectedMemoPlanID }
    }

    func openInitialSetup() {
        pendingProfileSelection =
            snapshot.profile ?? TemplateCatalog.representativeSelections[0]
        detail = .onboarding
    }

    func selectTemplate(_ selection: ProfileSelection) {
        pendingProfileSelection = selection
    }

    func selectTemplateRole(_ roleID: String) {
        pendingProfileSelection.roleID = roleID
    }

    func toggleTemplateSituation(_ situationID: String) {
        if let index = pendingProfileSelection.situationIDs.firstIndex(
            of: situationID
        ) {
            pendingProfileSelection.situationIDs.remove(at: index)
        } else if pendingProfileSelection.situationIDs.count < 2 {
            pendingProfileSelection.situationIDs.append(situationID)
        } else {
            userFacingError = "상황은 최대 2개까지 조합할 수 있습니다."
        }
    }

    func toggleTemplateGoal(_ goalID: String) {
        if let index = pendingProfileSelection.goalIDs.firstIndex(of: goalID) {
            pendingProfileSelection.goalIDs.remove(at: index)
        } else if pendingProfileSelection.goalIDs.count < 2 {
            pendingProfileSelection.goalIDs.append(goalID)
        } else {
            userFacingError = "목표는 최대 2개까지 조합할 수 있습니다."
        }
    }

    func applyPendingTemplate(at date: Date = .now) async {
        do {
            let application = try TemplateCatalog.apply(
                pendingProfileSelection
            )
            let visibleIDs = Set(application.visibleCategoryIDs)
            snapshot.categories = snapshot.categories.map { category in
                var updated = category
                if category.isBuiltIn {
                    updated.isHidden = !visibleIDs.contains(category.id)
                    if let displayName =
                        application.categoryDisplayNames[category.id] {
                        updated.name = displayName
                    } else if let original = CategoryCatalog.builtIn.first(
                        where: { $0.id == category.id }
                    ) {
                        updated.name = original.name
                    }
                }
                return updated
            }

            let goalPlans = try TemplateCatalog.makeGoalPlans(
                for: pendingProfileSelection,
                startingAt: Calendar.autoupdatingCurrent.startOfDay(for: date)
            )
            for goal in goalPlans where !snapshot.plans.contains(where: {
                $0.parentID == nil
                    && $0.title == goal.title
                    && $0.categoryID == goal.categoryID
            }) {
                snapshot.plans.append(goal)
            }
            snapshot.plans.sort { $0.span.start < $1.span.start }
            snapshot.profile = pendingProfileSelection
            await persist()
        } catch {
            userFacingError = "시작 구성을 적용하지 못했습니다. \(error.localizedDescription)"
        }
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
            .filter { $0.planID == planID }
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

    func addPlan(
        title: String,
        categoryID: String,
        middleCategoryName: String? = nil,
        subCategoryName: String? = nil,
        startAt: Date,
        duration: TimeInterval,
        parentID: UUID? = nil
    ) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, duration > 0 else { return }
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
                plan.middleCategoryName = Self.cleanHierarchyName(
                    middleCategoryName
                )
                plan.subCategoryName = Self.cleanHierarchyName(
                    subCategoryName
                )
            } catch {
                userFacingError = "상위 목표 안에 계획을 배치하지 못했습니다."
                return
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
                subCategoryName: Self.cleanHierarchyName(subCategoryName)
            )
        }
        snapshot.plans.append(plan)
        snapshot.plans.sort { $0.span.start < $1.span.start }
        Task { await persist() }
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
        isImportant: Bool
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
        updated.updatedAt = .now

        var candidate = snapshot.plans
        candidate[index] = updated
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
            snapshot.plans = candidate.sorted {
                $0.span.start < $1.span.start
            }
            Task { await persist() }
        } catch PlanningError.parentCycle {
            userFacingError = "계획을 자기 하위 목표 안으로 옮길 수 없습니다."
        } catch {
            userFacingError =
                "상위·하위 계획의 기간 안에서 시간을 정해 주세요."
        }
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
            guard actual.planID.map(deletedIDs.contains) == true else {
                return actual
            }
            var preserved = actual
            preserved.planID = nil
            return preserved
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

    func deleteActual(_ actualID: UUID) async {
        guard let actual = snapshot.actuals.first(where: {
            $0.id == actualID
        }) else {
            userFacingError = "삭제할 실제 기록을 찾지 못했습니다."
            return
        }

        snapshot.settings.suppressedActualIDs.insert(actualID)
        snapshot.actuals.removeAll { $0.id == actualID }

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
            userFacingError = "하위 계획은 상위 목표 기간 안에서만 옮길 수 있습니다."
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
        let linkedPlan = summary.linkedPlanID.flatMap { planID in
            snapshot.plans.first { $0.id == planID }
        }
        snapshot.actuals = AppleWatchSensorActivityEngine.upserting(
            summary,
            into: snapshot.actuals,
            linkedPlan: linkedPlan
        )
        snapshot.actuals = ActualRecordSuppressionEngine.visibleRecords(
            from: snapshot.actuals,
            suppressedIDs: snapshot.settings.suppressedActualIDs
        )
        await persistDeviceLocalSnapshot()
    }

    private func archiveRawDeviceData<T: Encodable>(
        source: RawDeviceDataSource,
        kind: String,
        payload: T,
        capturedAt: Date = .now
    ) {
        guard let rawDeviceDataArchive else { return }
        do {
            try rawDeviceDataArchive.append(
                source: source,
                kind: kind,
                payload: payload,
                capturedAt: capturedAt
            )
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
        let places = floorTimeline.places
        let floors = floorTimeline.transitions
        let inferredTravel = AppleDeviceGroundTruthEngine.mergingTravel(
            gpsSegments: MovementRouteBuilder().build(
                stays: places,
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
            places: places
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

        if snapshot.settings.weatherEnabled,
           let point = readings.last?.point {
            await refreshWeather(at: point, in: span)
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
        let fresh = photoService.moments(in: span)
        snapshot.photos.removeAll { span.contains($0.capturedAt) }
        snapshot.photos.append(contentsOf: fresh)
        snapshot.photos.sort { $0.capturedAt < $1.capturedAt }
    }

    private func refreshCalendarEvents() {
        let span = visibleDataSpan
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

    private func refreshHealthData() async {
        do {
            let span = recentHealthSpan
            async let actualValues = healthService.actuals(in: span)
            async let sessions = healthService.sleepSessions(in: span)
            let (freshActuals, freshSessions) = try await (actualValues, sessions)
            archiveRawDeviceData(
                source: .healthKit,
                kind: "health-actuals",
                payload: freshActuals,
                capturedAt: span.end
            )
            archiveRawDeviceData(
                source: .healthKit,
                kind: "sleep-sessions",
                payload: freshSessions,
                capturedAt: span.end
            )
            snapshot.actuals = AppleDeviceGroundTruthEngine
                .replacingHealthKitActuals(
                    existing: snapshot.actuals,
                    with: ActualRecordSuppressionEngine.visibleRecords(
                        from: freshActuals,
                        suppressedIDs: snapshot.settings.suppressedActualIDs
                    ),
                    inside: span
                )
            sleepSessions = freshSessions
            Self.integrationLogger.notice(
                "HealthKit refresh completed: actuals=\(freshActuals.count, privacy: .public), sleepSessions=\(freshSessions.count, privacy: .public)"
            )
        } catch {
            Self.integrationLogger.error(
                "HealthKit refresh failed: \(error.localizedDescription, privacy: .public)"
            )
            userFacingError = "건강 데이터를 읽지 못했습니다. \(error.localizedDescription)"
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
    }

    private func migrateLegacyFloorCalibration(
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

    private func refreshWeather(at point: GeoPoint, in span: TimeSpan) async {
        do {
            let context = try await weatherService.context(
                latitude: point.latitude,
                longitude: point.longitude
            )
            snapshot.weather.removeAll {
                $0.observedAt >= span.start && $0.observedAt <= span.end
            }
            snapshot.weather.append(context)
            snapshot.weather.sort { $0.observedAt < $1.observedAt }
        } catch {
            userFacingError =
                "현재 날씨를 불러오지 못했습니다. \(error.localizedDescription)"
        }
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
        let dayStart = calendar.startOfDay(for: .now)
        let widgetStart = calendar.date(
            byAdding: .day,
            value: -1,
            to: dayStart
        ) ?? dayStart.addingTimeInterval(-86_400)
        let widgetEnd = calendar.date(
            byAdding: .day,
            value: 8,
            to: dayStart
        ) ?? dayStart.addingTimeInterval(8 * 86_400)
        let widgetSpan = TimeSpan(start: widgetStart, end: widgetEnd)
        let weekStart = calendar.dateInterval(
            of: .weekOfYear,
            for: dayStart
        )?.start ?? dayStart
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)
            ?? weekStart.addingTimeInterval(7 * 86_400)
        let span = TimeSpan(start: weekStart, end: weekEnd)
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
        let planItems = snapshot.plans
            .filter { $0.span.intersection(with: widgetSpan) != nil }
            .sorted { $0.span.start < $1.span.start }
            .map { plan in
                let category = categoriesByID[plan.categoryID]
                return TaptionWidgetItem(
                    id: plan.id,
                    title: snapshot.settings.showsPhotosInWidgets
                        ? plan.title
                        : "계획",
                    categoryID: plan.categoryID,
                    startsAt: plan.span.start,
                    endsAt: plan.span.end,
                    status: plan.status.rawValue,
                    isFixed: plan.isFixed,
                    categoryName: category?.name,
                    categoryHex: category?.lightHex,
                    lane: .action
                )
            }
        let calendarItems = snapshot.calendarEvents
            .filter { $0.span.intersection(with: widgetSpan) != nil }
            .map { event in
                TaptionWidgetItem(
                    id: UUID(uuidString: event.id) ?? UUID(),
                    title: snapshot.settings.showsPhotosInWidgets
                        ? event.title
                        : "일정",
                    categoryID: "calendar",
                    startsAt: event.span.start,
                    endsAt: event.span.end,
                    status: PlanStatus.planned.rawValue,
                    isFixed: true,
                    categoryName: "캘린더",
                    categoryHex: "#BEDAE3",
                    lane: .schedule
                )
            }
        let locationItems = snapshot.places
            .filter { $0.span.intersection(with: widgetSpan) != nil }
            .map { place in
                return TaptionWidgetItem(
                    id: place.id,
                    title: TaptionWidgetContentPolicy.locationTitle(
                        displayName: place.displayName,
                        floor: place.floor
                    ),
                    categoryID: "location",
                    startsAt: place.span.start,
                    endsAt: place.span.end,
                    status: "recorded",
                    isFixed: true,
                    categoryName: "위치",
                    categoryHex: "#BEDAE3",
                    lane: .location
                )
            }
        let movementItems = snapshot.travel
            .filter { $0.span.intersection(with: widgetSpan) != nil }
            .map { travel in
                TaptionWidgetItem(
                    id: travel.id,
                    title: widgetTravelModeName(travel.mode),
                    categoryID: "movement",
                    startsAt: travel.span.start,
                    endsAt: travel.span.end,
                    status: "recorded",
                    isFixed: true,
                    categoryName: "이동",
                    categoryHex: "#D2AE76",
                    lane: .movement
                )
            }
        let activityItems = AutomaticRecordTimelineEngine.activities(
            from: snapshot.actuals,
            inside: widgetSpan
        ).map { actual in
            TaptionWidgetItem(
                id: actual.id,
                title: actual.title,
                categoryID: actual.categoryID,
                startsAt: actual.startedAt,
                endsAt: actual.endedAt ?? .now,
                status: "recorded",
                isFixed: true,
                categoryName: "활동",
                categoryHex: "#7CA980",
                lane: .activity
            )
        }
        let items = (
            planItems
                + calendarItems
                + locationItems
                + movementItems
                + activityItems
        )
            .sorted { $0.startsAt < $1.startsAt }
        let weather = snapshot.weather.min {
            abs($0.observedAt.timeIntervalSinceNow)
                < abs($1.observedAt.timeIntervalSinceNow)
        }
        let payload = TaptionWidgetPayload(
            generatedAt: .now,
            viewportStart: widgetStart,
            viewportEnd: widgetEnd,
            items: items,
            catStyle: snapshot.settings.catStyle.rawValue,
            hidesSensitiveContent: !snapshot.settings.showsPhotosInWidgets,
            weatherSymbolName: weather?.symbolName,
            temperatureCelsius: weather?.temperatureCelsius,
            reducesMotion: snapshot.settings.reduceMotion
        )
        do {
            try TaptionWidgetSharedStore.writePayload(payload)
            WidgetCenter.shared.reloadTimelines(ofKind: TaptionWidgetKind.schedule)
        } catch {
            userFacingError = "위젯 데이터를 갱신하지 못했습니다. \(error.localizedDescription)"
        }
        let watchItems = snapshot.plans
            .filter { $0.span.intersection(with: span) != nil }
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
                    categoryHex: category?.lightHex
                )
            }
        let watchPayload = TaptionWatchPayload(
            generatedAt: .now,
            viewportStart: weekStart,
            viewportEnd: weekEnd,
            items: watchItems,
            catStyle: snapshot.settings.catStyle.rawValue,
            reducesMotion: snapshot.settings.reduceMotion,
            todaySummary: TaptionWatchDaySummaryFactory.make(
                plans: snapshot.plans,
                actuals: snapshot.actuals,
                at: .now,
                calendar: calendar
            )
        )
        try? watchConnectivityService.update(payload: watchPayload)
    }

    private func widgetTravelModeName(_ mode: TravelMode) -> String {
        switch mode {
        case .walking: "걷기"
        case .running: "달리기"
        case .cycling: "자전거"
        case .bus: "버스"
        case .subway: "지하철"
        case .taxi: "택시"
        case .car: "자가용"
        case .train: "기차"
        case .airplane: "비행기"
        case .ship: "배"
        }
    }

    private var visibleDataSpan: TimeSpan {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.date(
            byAdding: .month,
            value: -1,
            to: calendar.startOfDay(for: selectedDate)
        ) ?? selectedDate.addingTimeInterval(-31 * 86_400)
        let end = calendar.date(
            byAdding: .month,
            value: 13,
            to: start
        ) ?? selectedDate.addingTimeInterval(366 * 86_400)
        return TimeSpan(start: start, end: end)
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

    private func persist() async {
        do {
            var value = snapshot
            value.updatedAt = .now
            snapshot = value
            try await repository.save(value)
            if permissionState(for: .cloud).isGranted,
               let cloudSyncService {
                let uploaded = try await cloudSyncService.upload(
                    cloudPortableSnapshot(value)
                )
                snapshot.updatedAt = uploaded.updatedAt
                try await repository.save(snapshot)
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
            $0.source == .healthKit || $0.source == .appleWatch
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
            $0.source == .healthKit || $0.source == .appleWatch
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
        value.settings.floorCalibration = nil
        value.settings.movementCorrections =
            local.settings.movementCorrections
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
        do {
            var value = snapshot
            value.updatedAt = .now
            snapshot = value
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
