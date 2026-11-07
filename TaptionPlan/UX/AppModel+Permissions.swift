import Foundation
import UIKit
import TaptionPlanCore

extension AppModel {
    var currentAltitudeStatus: String? {
        guard let estimate = latestAltitudeEstimate else { return nil }
        let altitude = Int(estimate.seaLevelAltitudeMeters.rounded())
        let accuracy = Int(estimate.verticalAccuracyMeters.rounded())
        return AppLanguagePreference.text(
            korean: "\(estimate.floor)층 추정 · 해발 \(altitude)m · ±\(accuracy)m",
            english: "Estimated floor \(estimate.floor) · \(altitude) m above sea level · ±\(accuracy) m"
        )
    }

    var canShiftToPreviousPeriod: Bool {
        canShiftSelectedDate(by: -1)
    }

    var canShiftToNextPeriod: Bool {
        canShiftSelectedDate(by: 1)
    }

    var integrationStatusSummary: String {
        if isRefreshingIntegrations {
            return AppLanguagePreference.text(
                korean: "연동 확인 중",
                english: "Checking integrations"
            )
        }
        let enabled = [
            settings.showsPhotos
                && permissionState(for: .photos).isGranted,
            !settings.selectedCalendarIDs.isEmpty
                && permissionState(for: .calendar).isGranted,
            settings.healthEnabled,
            settings.locationEnabled,
        ].filter { $0 }.count
        return AppLanguagePreference.text(
            korean: enabled == 0
                ? "기기 안에 안전하게 저장"
                : "연동 \(enabled)개 사용 중",
            english: enabled == 0
                ? "Stored securely on this device"
                : "\(enabled) integrations in use"
        )
    }

    var healthIntegrationSummary: String {
        let deviceRecords = snapshot.actuals.filter {
            $0.source == .healthKit || $0.source == .appleWatch
        }
        let health = settings.healthEnabled
            ? AppLanguagePreference.text(
                korean: "원본 \(healthSyncOverview.totalSampleCount)건 · 일과 \(deviceRecords.count)건",
                english: "\(healthSyncOverview.totalSampleCount) source samples · \(deviceRecords.count) daily records"
            )
            : AppLanguagePreference.text(
                korean: "건강 연결 꺼짐",
                english: "Health connection off"
            )
        return "HealthKit · \(health)"
    }

    var healthSyncStatus: String {
        if let healthSyncProgress {
            return "\(healthSyncProgress.completedTypes)/\(healthSyncProgress.totalTypes)"
        }
        if healthSyncOverview.failedTypeCount > 0 {
            return AppLanguagePreference.text(
                korean: "완료 \(healthSyncOverview.completedTypeCount) · 오류 \(healthSyncOverview.failedTypeCount)",
                english: "Done \(healthSyncOverview.completedTypeCount) · Errors \(healthSyncOverview.failedTypeCount)"
            )
        }
        return AppLanguagePreference.text(
            korean: "\(healthSyncOverview.completedTypeCount)개 유형",
            english: "\(healthSyncOverview.completedTypeCount) types"
        )
    }

    var healthSyncDetail: String {
        if let healthSyncProgress {
            return AppLanguagePreference.text(
                korean: "\(healthSyncProgress.typeName) · \(healthSyncProgress.importedSamples)건 가져옴",
                english: "\(healthSyncProgress.typeName) · \(healthSyncProgress.importedSamples) imported"
            )
        }
        if let error = healthSyncOverview.lastError {
            return AppLanguagePreference.text(
                korean: "일부 건강 유형 재시도 필요 · \(error)",
                english: "Some Health types need a retry · \(error)"
            )
        }
        if let last = healthSyncOverview.lastSyncedAt {
            let lastText = last.formatted(date: .omitted, time: .shortened)
            return AppLanguagePreference.text(
                korean: "전체 이력·증분 원본 · 마지막 \(lastText)",
                english: "Full history · incremental source · last \(lastText)"
            )
        }
        return AppLanguagePreference.text(
            korean: "사용자가 허용한 전체 이력 · 기기 로컬 저장",
            english: "Full history you allowed · stored locally on this device"
        )
    }

    func permissionState(for feature: PermissionFeature) -> PermissionState {
        snapshot.settings.permissions[feature] ?? .notDetermined
    }

    func requiredPermissionGate(
        liveActivitiesEnabled: Bool
    ) -> RequiredPermissionGate {
        // 위치·동작은 저장된 캐시가 아니라 지금 시스템 상태를 읽는다. 설정 앱에서
        // 허용하고 돌아온 직후에도 카드가 남지 않게 하기 위해서다.
        var permissions = snapshot.settings.permissions
        if let sensorService {
            permissions[.location] = sensorService.locationPermissionState()
            permissions[.motion] = sensorService.motionPermissionState()
        }
        return RequiredPermissionGate.evaluate(
            RequiredPermissionSnapshot(
                permissions: permissions,
                locationAlwaysAuthorized:
                    sensorService?.hasAlwaysLocationAuthorization() == true,
                locationPrecise:
                    sensorService?.hasPreciseLocationAuthorization() == true,
                healthKitRequestCompleted: UserDefaults.standard.bool(
                    forKey: Self.healthAuthorizationRequestedKey
                ),
                liveActivitiesEnabled: liveActivitiesEnabled
            )
        )
    }

    func requestRequiredPermission(
        _ permission: RequiredPermission
    ) async {
        switch permission {
        case .locationAlways:
            if sensorService?.locationPermissionState() == .denied {
                openSystemSettings()
            } else {
                await enableLocationCollection(always: true, opensSettingsWhenBlocked: true)
            }
        case .locationPrecise:
            if sensorService?.hasPreciseLocationAuthorization() != true {
                openSystemSettings()
            }
        case .motion:
            guard let sensorService else { return }
            if sensorService.motionPermissionState() == .denied {
                openSystemSettings()
            } else {
                snapshot.settings.permissions[.motion] =
                    await sensorService.requestMotionPermission()
                await persist()
            }
        case .healthKitRequestCompleted:
            await requestHealth()
        case .calendar:
            if calendarService.permissionState() == .denied {
                openSystemSettings()
            } else {
                await requestCalendar()
            }
        case .notifications:
            if await notificationScheduler.authorizationState() == .denied {
                openSystemSettings()
            } else {
                await requestNotifications()
            }
        case .liveActivities:
            openSystemSettings()
        }
        await refreshPermissions()
    }

    func activateRequiredSensorCollection() async {
        snapshot.settings.sensorCollectionProfile = .balanced
        await enableLocationCollection(always: true)
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        UIApplication.shared.open(url)
    }

    /// Re-reads the system permission centers when Settings becomes visible.
    /// The saved snapshot is only a cache; iOS permissions can change while
    /// the app is suspended or in Settings.
    func refreshPermissions() async {
        if let permissionRefreshTask {
            await permissionRefreshTask.value
            return
        }
        let generation = dataDeletionGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.dataDeletionGeneration == generation {
                    self.permissionRefreshTask = nil
                }
            }
            await self.bootstrap()
            guard !Task.isCancelled, self.dataDeletionGeneration == generation,
                  self.acceptsDataMutation() else { return }
            let revision = self.snapshotRevision
            await self.refreshPermissionStates()
            guard !Task.isCancelled, self.dataDeletionGeneration == generation,
                  self.acceptsDataMutation() else { return }
            self.refreshAppUsageAuthorizationState()
            if self.snapshotRevision != revision {
                await self.persistDeviceLocalSnapshot()
            }
        }
        permissionRefreshTask = task
        await task.value
    }

    /// 설치 후 첫 실행에서만 권한 안내를 띄운다. 권한은 기기마다 다르므로
    /// iCloud로 오가는 스냅샷이 아니라 기기 저장소에 표시 여부를 남긴다.
    func presentPermissionOnboardingIfNeeded() {
        let defaults = UserDefaults.standard
        if [PermissionFeature.location, .photos, .calendar, .notifications]
            .allSatisfy({ permissionState(for: $0).isGranted }) {
            if settings.healthEnabled { return }
        }
        let reason: String
        if defaults.bool(forKey: Self.permissionOnboardingKey) {
            guard !settings.healthEnabled,
                  !defaults.bool(forKey: Self.healthPermissionReminderKey)
            else { return }
            defaults.set(true, forKey: Self.healthPermissionReminderKey)
            permissionOnboardingStartFeature = .health
            reason = "missing_health_retry"
        } else {
            permissionOnboardingStartFeature = nil
            reason = "initial"
        }
        isPermissionOnboardingPresented = true
        TaptionPlanDiagnosticsLogger.shared.record(
            "permission_onboarding_presented",
            fields: [
                "reason": reason,
                "health_state": permissionState(for: .health).rawValue,
                "health_enabled": String(settings.healthEnabled),
            ]
        )
    }

    /// 안내 시트가 없을 때 위치 권한이 비어 있으면 시작하자마자 시스템 팝업으로 묻는다.
    /// '항상' 승격 팝업은 iOS가 한 번만 보여 주므로 실제로 보낸 뒤에만 기록한다(`LocationAlwaysUpgradePolicy`).
    func requestMissingLocationPermissionAtLaunch() async {
        guard !isPermissionOnboardingPresented, let sensorService else { return }
        let tutorial = FirstRunTutorialStore()
        guard LocationAlwaysUpgradePolicy.shouldRequestAtLaunch(
            status: sensorService.locationAuthorizationStatus(),
            allowsUnaskedPrompts: tutorial.allowsUnaskedPermissionPrompts,
            tutorialFinished: tutorial.outcome == .completed || tutorial.outcome == .skipped,
            alreadyRequested: LocationAlwaysUpgradePolicy.wasRequested()
        ) else { return }
        await enableLocationCollection(always: true)
    }

    func presentPermissionOnboarding(for feature: PermissionFeature? = nil) {
        permissionOnboardingStartFeature = feature
        isPermissionOnboardingPresented = true
        TaptionPlanDiagnosticsLogger.shared.record(
            "permission_onboarding_presented",
            fields: [
                "reason": "settings",
                "start_feature": feature?.rawValue ?? "all",
                "health_state": permissionState(for: .health).rawValue,
            ]
        )
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
        let state = screenTimeUsageService.authorizationState
        if appUsageAuthorizationState != state { appUsageAuthorizationState = state }
        let permission: PermissionState = switch state {
        case .approved: .authorized
        case .denied: .denied
        case .notDetermined: .notDetermined
        case .unavailable, .requiresCurrentSystem, .dataAccessUnavailable:
            .unavailable
        }
        if snapshot.settings.permissions[.appUsage] != permission {
            snapshot.settings.permissions[.appUsage] = permission
        }
    }

    func requestAppUsageAuthorization(
        openSettingsIfNeeded: Bool = true
    ) async {
        guard !isRequestingPermission else { return }
        isRequestingPermission = true
        defer { isRequestingPermission = false }
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
            if openSettingsIfNeeded,
               appUsageAuthorizationState == .dataAccessUnavailable {
                openAppUsageSettings()
            }
            userFacingError = error.localizedDescription
        }
    }

    /// Screen Time은 앱 안에서 권한을 다시 승인할 수 없는 상태가 있다.
    /// 공개된 iOS URL은 앱의 설정 화면까지이므로, 시스템 설정에서 Screen
    /// Time의 앱 및 웹사이트 활동·데이터 공유를 확인하도록 바로 보낸다.
    func openAppUsageSettings() {
        guard let url = URL(
            string: UIApplication.openSettingsURLString
        ) else { return }
        UIApplication.shared.open(url)
    }

    func requestPhotos() async {
        guard !isRequestingPermission else { return }
        isRequestingPermission = true
        defer { isRequestingPermission = false }
        let state = await photoService.requestAccess()
        snapshot.settings.permissions[.photos] = state
        snapshot.settings.showsPhotos = state.isGranted
        if state.isGranted {
            refreshPhotos()
        }
        await persist()
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

    @discardableResult
    func requestCalendar() async -> Bool {
        guard !isRequestingPermission else { return false }
        isRequestingPermission = true
        defer { isRequestingPermission = false }
        if calendarService.permissionState() == .denied {
            snapshot.settings.permissions[.calendar] = .denied
            openSystemSettings()
            return true
        }
        do {
            let granted = try await calendarService.requestFullAccess()
            let state: PermissionState = granted ? .authorized : .denied
            snapshot.settings.permissions[.calendar] = state
            if granted {
                if snapshot.settings.selectedCalendarIDs.isEmpty {
                    snapshot.settings.selectedCalendarIDs = calendarService
                        .calendars()
                        .map(\.id)
                }
                await refreshCalendarEvents()
                UserDefaults.standard.removeObject(
                    forKey: Self.calendarAutomaticRefreshKey
                )
            } else {
                snapshot.calendarEvents.removeAll { !$0.isGoogleAccountEvent }
                calendarStoreRefreshTask?.cancel()
                calendarStoreRefreshTask = nil
                calendarStoreRefreshRequiresWide = false
            }
            await persist()
            return true
        } catch {
            let state = calendarService.permissionState()
            snapshot.settings.permissions[.calendar] = state
            if !state.isGranted {
                snapshot.calendarEvents.removeAll { !$0.isGoogleAccountEvent }
                calendarStoreRefreshTask?.cancel()
                calendarStoreRefreshTask = nil
                calendarStoreRefreshRequiresWide = false
            }
            userFacingError = AppLanguagePreference.text(
                korean: "캘린더를 연결하지 못했습니다. \(error.localizedDescription)",
                english: "Could not connect Calendar. \(error.localizedDescription)"
            )
            return false
        }
    }

    func setCalendarEnabled(_ enabled: Bool) async {
        if enabled {
            await requestCalendar()
            return
        }
        calendarStoreRefreshTask?.cancel()
        calendarStoreRefreshTask = nil
        calendarStoreRefreshRequiresWide = false
        snapshot.settings.selectedCalendarIDs = []
        snapshot.calendarEvents.removeAll { !$0.isGoogleAccountEvent }
        await persist()
    }

    @discardableResult
    func requestHealth() async -> Bool {
        guard !isRequestingPermission else { return false }
        isRequestingPermission = true
        defer { isRequestingPermission = false }
        TaptionPlanDiagnosticsLogger.shared.record(
            "health_authorization_requested",
            fields: [
                "previous_state": permissionState(for: .health).rawValue,
            ]
        )
        let watchDataSyncProfile =
            TaptionWatchDataSyncProfile.profileAfterHealthAuthorization(
                current: snapshot.settings.watchDataSyncProfile,
                userDidSetProfile: UserDefaults.standard.bool(
                    forKey: Self.watchDataSyncProfileConfiguredKey
                )
            )
        do {
            let granted = try await healthService.requestReadAccess()
            UserDefaults.standard.set(
                true,
                forKey: Self.healthAuthorizationRequestedKey
            )
            snapshot.settings.healthEnabled = granted
            snapshot.settings.permissions[.health] = granted ? .authorized : .denied
            TaptionPlanDiagnosticsLogger.shared.record(
                "health_authorization_completed",
                fields: ["granted": String(granted)]
            )
            await persist()
            // 권한 응답은 배경 데이터 새로고침 상태와 별도로 완료 처리한다.
            // 전체 이력 동기화는 길어질 수 있어 백그라운드에서 진행한다.
            if granted {
                snapshot.settings.watchDataSyncProfile = watchDataSyncProfile
                Task { @MainActor in
                    await refreshHealthData(in: startupHealthSpan, forceRawSync: true)
                    await synchronizeHealthHistory(showErrors: true)
                    await refreshHealthData()
                    await configureHealthBackgroundDeliveryIfNeeded(
                        showErrors: true
                    )
                    startForegroundHealthRefreshIfNeeded()
                    publishWatchPayload()
                    await persist()
                }
            }
            return true
        } catch {
            snapshot.settings.healthEnabled = false
            snapshot.settings.permissions[.health] = .denied
            TaptionPlanDiagnosticsLogger.shared.record(
                "health_authorization_failed",
                level: .error,
                fields: TaptionDiagnosticError.fields(for: error)
            )
            userFacingError = AppLanguagePreference.text(
                korean: "건강 데이터를 연결하지 못했습니다. \(error.localizedDescription)",
                english: "Could not connect Health data. \(error.localizedDescription)"
            )
            return false
        }
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
        snapshot.actuals.removeAll {
            $0.source == .healthKit || $0.source == .appleWatch
        }
        sleepSessions = []
        sleepReconciliations = []
        lastHealthRefreshAt = nil
        healthSyncOverview = HealthKitSyncOverview(states: [])
        healthSyncProgress = nil
        await persist()
    }

    func synchronizeHealthHistory(showErrors: Bool = true) async {
        guard settings.healthEnabled, !isHealthHistorySyncRunning else {
            return
        }
        isHealthHistorySyncRunning = true
        defer {
            isHealthHistorySyncRunning = false
            healthSyncProgress = nil
        }
        do {
            healthSyncOverview = try await healthService
                .synchronizeFullHistory { [weak self] progress in
                    await MainActor.run {
                        self?.healthSyncProgress = progress
                    }
                }
            TaptionPlanDiagnosticsLogger.shared.record(
                healthSyncOverview.failedTypeCount == 0
                    ? "health_history_sync_completed"
                    : "health_history_sync_partial",
                level: healthSyncOverview.failedTypeCount == 0
                    ? .info
                    : .error,
                fields: [
                    "types": String(healthSyncOverview.completedTypeCount),
                    "errors": String(healthSyncOverview.failedTypeCount),
                    "samples": String(healthSyncOverview.totalSampleCount),
                    "deletions": String(healthSyncOverview.totalDeletedCount),
                ]
            )
        } catch {
            Self.integrationLogger.error(
                "HealthKit history sync failed: \(error.localizedDescription, privacy: .public)"
            )
            if showErrors {
                userFacingError = AppLanguagePreference.text(
                    korean: "건강 전체 이력을 가져오지 못했습니다. \(error.localizedDescription)",
                    english: "Could not import the full Health history. \(error.localizedDescription)"
                )
            }
            TaptionPlanDiagnosticsLogger.shared.record(
                "health_history_sync_failed",
                level: .error,
                fields: TaptionDiagnosticError.fields(for: error)
            )
        }
    }

    @discardableResult
    func requestNotifications() async -> Bool {
        guard !isRequestingPermission else { return false }
        isRequestingPermission = true
        defer { isRequestingPermission = false }
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
            return true
        } catch {
            snapshot.settings.permissions[.notifications] =
                await notificationScheduler.authorizationState()
            snapshot.settings.notificationsEnabled = false
            userFacingError = AppLanguagePreference.text(
                korean: "계획 알림을 켜지 못했습니다. \(error.localizedDescription)",
                english: "Could not turn on plan notifications. \(error.localizedDescription)"
            )
            return false
        }
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

    func clearError() {
        userFacingError = nil
    }

    func refreshPermissionStates() async {
        let generation = dataDeletionGeneration
        guard !Task.isCancelled, acceptsDataMutation() else { return }
        var healthState = PermissionState.unavailable
        do {
            healthState = try await healthService.authorizationRequestState()
        } catch {
            healthState = healthService.permissionState()
        }
        guard !Task.isCancelled, dataDeletionGeneration == generation,
              acceptsDataMutation() else { return }
        let availability = await sensorService?.hardwareAvailability()
        let notificationState = await notificationScheduler.authorizationState()
        guard !Task.isCancelled, dataDeletionGeneration == generation,
              acceptsDataMutation() else { return }
        if let sensorService, !sensorService.locationPermissionState().isGranted {
            await sensorService.stopCollectionAndWait()
            guard !Task.isCancelled, dataDeletionGeneration == generation,
                  acceptsDataMutation() else { return }
        }

        // 사진 상태 조회만으로 시스템 팝업이 뜨는 런타임이 있어 튜토리얼 전에는 묻지 않는다.
        let photoState = FirstRunTutorialStore().defersPermissionPrompts
            ? permissionState(for: .photos)
            : photoService.permissionState()
        let calendarState = calendarService.permissionState()
        let locationState = sensorService?.locationPermissionState() ?? .unavailable
        var updatedSettings = snapshot.settings
        let previousCalendarState = updatedSettings.permissions[.calendar] ?? .notDetermined
        updatedSettings.permissions[.photos] = photoState
        updatedSettings.permissions[.calendar] = calendarState
        updatedSettings.permissions[.health] = healthState
        updatedSettings.permissions[.location] = locationState
        updatedSettings.permissions[.motion] = sensorService?.motionPermissionState() ?? .unavailable
        updatedSettings.permissions[.notifications] = notificationState
        if !photoState.isGranted {
            updatedSettings.showsPhotos = false
            updatedSettings.showsPhotosInWidgets = false
            if !snapshot.photos.isEmpty { snapshot.photos = [] }
        }
        if calendarState.isGranted, !previousCalendarState.isGranted {
            UserDefaults.standard.removeObject(forKey: Self.calendarAutomaticRefreshKey)
            if updatedSettings.selectedCalendarIDs.isEmpty {
                updatedSettings.selectedCalendarIDs = calendarService.calendars().map(\.id)
            }
        } else if !calendarState.isGranted {
            calendarStoreRefreshTask?.cancel()
            calendarStoreRefreshTask = nil
            calendarStoreRefreshRequiresWide = false
            if snapshot.calendarEvents.contains(where: { !$0.isGoogleAccountEvent }) { snapshot.calendarEvents.removeAll { !$0.isGoogleAccountEvent } }
        }
        if healthState == .authorized {
            UserDefaults.standard.set(true, forKey: Self.healthAuthorizationRequestedKey)
        }
        if let availability, sensorAvailability != availability {
            sensorAvailability = availability
        }
        if let sensorService {
            if locationState.isGranted {
                updatedSettings.locationEnabled = true
                updatedSettings.backgroundPreciseLocationEnabled = sensorService.hasAlwaysLocationAuthorization()
            } else {
                sensorBackgroundCoordinator.cancel()
                syncSensorBackgroundState()
                if isSensorCollecting { isSensorCollecting = false }
                updatedSettings.backgroundPreciseLocationEnabled = false
            }
        } else {
            if sensorStorageErrorDescription == nil { updatedSettings.locationEnabled = false }
            updatedSettings.backgroundPreciseLocationEnabled = false
        }
        if !notificationState.isGranted { updatedSettings.notificationsEnabled = false }
        migratePermissionFlagsIfNeeded(
            settings: &updatedSettings,
            photos: photoState, calendar: calendarState, health: healthState,
            location: locationState, notifications: notificationState
        )
        if updatedSettings != snapshot.settings { snapshot.settings = updatedSettings }
    }

    private func migratePermissionFlagsIfNeeded(
        settings: inout AppFeatureSettings,
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
        settings.showsPhotos = photos.isGranted
        settings.healthEnabled = health.isGranted
        settings.locationEnabled = location.isGranted
        settings.notificationsEnabled = notifications.isGranted
        if calendar.isGranted, settings.selectedCalendarIDs.isEmpty {
            settings.selectedCalendarIDs = calendarService.calendars().map(\.id)
        }
        UserDefaults.standard.set(true, forKey: Self.permissionFlagsMigrationKey)
    }
}
