import Foundation
import Observation
import UIKit
import WidgetKit

@MainActor
@Observable
final class AppModel {
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

    private(set) var snapshot: TaptionDataSnapshot = .empty
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
    private(set) var sleepSessions: [SleepSession] = []
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
    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?

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
            StoreKitPurchaseService()
    ) {
        if let repository {
            self.repository = repository
        } else if let sharedRepository = try? FilePlanRepository.appGroup() {
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
        self.voiceMemoPlayer.onFinish = { [weak self] in
            self?.playingVoiceAttachmentID = nil
        }
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
        let component: Calendar.Component
        switch selectedScale {
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        case .year: component = .year
        }
        selectedDate = Calendar.autoupdatingCurrent.date(
            byAdding: component,
            value: direction,
            to: selectedDate
        ) ?? selectedDate
        Task { await refreshEnabledData() }
    }

    func returnToNow() {
        selectedDate = .now
        Task { await refreshEnabledData() }
    }

    func openDeepLink(_ url: URL) {
        guard let link = TaptionDeepLink(url: url) else { return }
        if link == .today {
            selectedTab = .schedule
            selectedScale = .day
            selectedDate = .now
            detail = nil
            return
        }

        guard case .plan(let planID) = link,
              let plan = snapshot.plans.first(where: { $0.id == planID }) else {
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

    func bootstrap() async {
        guard !isBootstrapped else {
            await refreshPermissionStates()
            resumeSensorCollectionIfNeeded()
            return
        }
        guard bootstrapTask == nil else { return }

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                var loaded = try await repository.load()
                if loaded.categories.isEmpty {
                    loaded.categories = CategoryCatalog.builtIn
                }
                snapshot = loaded
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
                await refreshEnabledData()
                await refreshStore(showErrors: false)
                resumeSensorCollectionIfNeeded()
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
        await applyPendingWidgetCommands(repositoryAlreadyLoaded: false)
        await refreshPermissionStates()
        await refreshStore(showErrors: false)
        resumeSensorCollectionIfNeeded()
        await persist()
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

    func enableLocationCollection(always: Bool = false) async {
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
        snapshot.settings.backgroundPreciseLocationEnabled = always && refreshed.isGranted

        if refreshed.isGranted {
            sensorService.startCollection(
                configuration: SensorCollectionConfiguration(
                    highAccuracyDuringMovement: true,
                    collectsDeviceMotion: true,
                    allowsBackgroundLocation: always,
                    minimumEmissionInterval: 1
                )
            )
            isSensorCollecting = true
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

    func refreshEnabledData() async {
        guard !isRefreshingIntegrations else { return }
        isRefreshingIntegrations = true
        if permissionState(for: .photos).isGranted, settings.showsPhotos {
            refreshPhotos()
        }
        if permissionState(for: .calendar).isGranted,
           !settings.selectedCalendarIDs.isEmpty {
            refreshCalendarEvents()
        }
        if settings.healthEnabled {
            await refreshHealthData()
        }
        if settings.locationEnabled {
            await refreshSensorTimeline()
        }
        await persist()
        isRefreshingIntegrations = false
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

    var selectedMemoPlan: PlanRecord? {
        guard let selectedMemoPlanID else { return nil }
        return snapshot.plans.first { $0.id == selectedMemoPlanID }
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
        startAt: Date,
        duration: TimeInterval,
        parentID: UUID? = nil
    ) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, duration > 0 else { return }
        let plan: PlanRecord
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
                categoryID: categoryID
            )
        }
        snapshot.plans.append(plan)
        snapshot.plans.sort { $0.span.start < $1.span.start }
        Task { await persist() }
    }

    func updatePlan(
        _ planID: UUID,
        title: String,
        categoryID: String,
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

    func refreshSensorTimeline() async {
        guard let sensorService else { return }
        let span = TimelineAggregationEngine().interval(
            for: .day,
            containing: selectedDate
        )
        do {
            let readings = try await sensorService.archivedReadings(in: span)
            guard !readings.isEmpty else { return }

            let knownNames = snapshot.places.reduce(into: [String: String]()) {
                $0[$1.placeKey] = $1.displayName
            }
            var places = PlaceDetectionEngine().detectStays(
                readings: readings,
                knownNames: knownNames
            )
            for index in places.indices
                where places[index].displayName == "자동 감지 장소" {
                guard let point = places[index].point,
                      let name = await placeNameResolver.displayName(
                          latitude: point.latitude,
                          longitude: point.longitude
                      ) else {
                    continue
                }
                places[index].displayName = name
            }

            let travel = MovementRouteBuilder().build(
                stays: places,
                readings: readings
            )
            var floors: [FloorTransition] = []
            for place in places {
                let relevant = readings.filter {
                    place.span.contains($0.timestamp)
                }
                if let floor = FloorEstimator().estimate(
                    readings: relevant,
                    placeKey: place.placeKey,
                    baselineFloor: place.floor
                ) {
                    floors.append(floor)
                }
            }

            snapshot.places.removeAll {
                $0.span.intersection(with: span) != nil
            }
            snapshot.travel.removeAll {
                $0.span.intersection(with: span) != nil
            }
            snapshot.floorTransitions.removeAll {
                $0.span.intersection(with: span) != nil
            }
            snapshot.places.append(contentsOf: places)
            snapshot.travel.append(contentsOf: travel)
            snapshot.floorTransitions.append(contentsOf: floors)
            snapshot.places.sort { $0.span.start < $1.span.start }
            snapshot.travel.sort { $0.span.start < $1.span.start }
            snapshot.floorTransitions.sort { $0.span.start < $1.span.start }

            if snapshot.settings.weatherEnabled,
               let point = readings.last?.point {
                await refreshWeather(at: point, in: span)
            }
        } catch {
            userFacingError =
                "위치·이동 기록을 정리하지 못했습니다. \(error.localizedDescription)"
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
        guard let index = snapshot.travel.firstIndex(where: {
            $0.id == travelID
        }) else {
            return
        }
        snapshot.travel[index].mode = mode
        snapshot.travel[index].confidence = .high
        snapshot.travel[index].isConfirmed = true
        if !snapshot.travel[index].evidence.contains("사용자 교정") {
            snapshot.travel[index].evidence.append("사용자 교정")
        }
        Task { await persist() }
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
            snapshot.actuals.removeAll {
                $0.source == .healthKit
                    && $0.span().intersection(with: span) != nil
            }
            snapshot.actuals.append(contentsOf: freshActuals)
            snapshot.actuals.sort { $0.startedAt < $1.startedAt }
            sleepSessions = freshSessions
        } catch {
            userFacingError = "건강 데이터를 읽지 못했습니다. \(error.localizedDescription)"
        }
    }

    private func resumeSensorCollectionIfNeeded() {
        guard settings.locationEnabled,
              permissionState(for: .location).isGranted,
              let sensorService else {
            isSensorCollecting = false
            return
        }
        sensorService.startCollection(
            configuration: SensorCollectionConfiguration(
                highAccuracyDuringMovement: true,
                collectsDeviceMotion: true,
                allowsBackgroundLocation: settings.backgroundPreciseLocationEnabled,
                minimumEmissionInterval: 1
            )
        )
        isSensorCollecting = true
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
        let weekStart = calendar.dateInterval(
            of: .weekOfYear,
            for: dayStart
        )?.start ?? dayStart
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)
            ?? weekStart.addingTimeInterval(7 * 86_400)
        let span = TimeSpan(start: weekStart, end: weekEnd)
        let items = snapshot.plans
            .filter { $0.span.intersection(with: span) != nil }
            .sorted { $0.span.start < $1.span.start }
            .map { plan in
                let category = snapshot.categories.first {
                    $0.id == plan.categoryID
                }
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
                    categoryHex: category?.lightHex
                )
            }
        let payload = TaptionWidgetPayload(
            generatedAt: .now,
            viewportStart: weekStart,
            viewportEnd: weekEnd,
            items: items,
            catStyle: snapshot.settings.catStyle.rawValue,
            hidesSensitiveContent: !snapshot.settings.showsPhotosInWidgets
        )
        do {
            try TaptionWidgetSharedStore.writePayload(payload)
            WidgetCenter.shared.reloadTimelines(ofKind: TaptionWidgetKind.schedule)
        } catch {
            userFacingError = "위젯 데이터를 갱신하지 못했습니다. \(error.localizedDescription)"
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
        let start = Calendar.autoupdatingCurrent.date(
            byAdding: .day,
            value: -31,
            to: Calendar.autoupdatingCurrent.startOfDay(for: selectedDate)
        ) ?? selectedDate.addingTimeInterval(-31 * 86_400)
        return TimeSpan(start: start, end: .now)
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
        value.actuals.removeAll { $0.source == .healthKit }
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
        return value
    }

    private func mergeDeviceLocalData(
        cloud: TaptionDataSnapshot,
        local: TaptionDataSnapshot
    ) -> TaptionDataSnapshot {
        var value = cloud
        let deviceActuals = local.actuals.filter { $0.source == .healthKit }
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
        value.settings.weatherEnabled = local.settings.weatherEnabled
        value.settings.notificationsEnabled =
            local.settings.notificationsEnabled
        return value
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
