import Foundation
import TaptionPlanCore

extension AppModel {
    // MARK: 백업 (월 단위 엔진)

    var backupDestinationAvailable: Bool { backupService != nil }

    func setLocalMonthsToKeep(_ months: Int) {
        guard let securityService else { return }
        securityService.setLocalMonthsToKeep(months)
        securityStatus = securityService.status
    }

    /// 백업·로컬 정리에 쓰는 비밀번호를 확인한다. 등록된 비밀번호와 같아야 하며 틀린 횟수가 세어진다.
    private func authorizeBackupPassword(_ password: String) throws {
        guard let securityService else { throw PlanSecurityError.invalidCredential }
        defer { securityStatus = securityService.status }
        guard securityService.hasPIN else { throw PlanSecurityError.pinRequiredForCloudBackup }
        try securityService.verifyPIN(password, unlocking: false)
    }

    /// iCloud Drive의 백업 파일 목록. 비밀번호(`password`)를 넣은 뒤에만 보여 준다.
    /// 겹쳐 부르면 마지막 요청의 결과만 올린다.
    func refreshBackupListings(password: String? = nil) async {
        backupListingGeneration &+= 1
        let generation = backupListingGeneration
        guard let backupService, let password, !password.isEmpty else {
            applyBackupListings([], unsupported: 0, error: nil)
            isRefreshingBackupListings = false
            return
        }
        isRefreshingBackupListings = true
        do {
            let rows = try await backupService.listings(password: password)
            let unsupported = await backupService.unsupportedFileCount()
            guard generation == backupListingGeneration else { return }
            applyBackupListings(rows, unsupported: unsupported, error: nil)
        } catch {
            guard generation == backupListingGeneration else { return }
            applyBackupListings([], unsupported: 0, error: PlanBackupPresenter.message(for: error))
        }
        isRefreshingBackupListings = false
    }

    private func applyBackupListings(_ rows: [PlanBackupListingRow], unsupported: Int, error: String?) {
        if backupListings != rows { backupListings = rows }
        if backupUnsupportedFileCount != unsupported { backupUnsupportedFileCount = unsupported }
        if backupListingError != error { backupListingError = error }
    }

    /// 저장소가 바뀐 뒤(복원·로컬 정리) 메모리 상태를 저장소에서 다시 만든다.
    /// repository의 known 캐시도 `load()`가 함께 갱신한다.
    private func beginBackupOperation(_ activity: PlanBackupActivity) -> Bool {
        guard !backupActivity.isBusy, acceptsDataMutation() else { return false }
        backupActivity = activity
        activeDataMutationCount += 1
        return true
    }

    /// 백업 중일 때만 진행 값을 바꾼다(끝난 뒤 늦게 도착한 알림은 무시).
    private func updateBackupProgress(completed: Int, total: Int) {
        guard case .backingUp = backupActivity else { return }
        let next = PlanBackupActivity.backingUp(completed: completed, total: max(total, 1))
        if backupActivity != next { backupActivity = next }
    }

    private func endBackupOperation(_ report: PlanBackupReport) {
        activeDataMutationCount -= 1
        backupActivity = .idle
        lastBackupReport = report
        securityStatus = securityService?.status ?? securityStatus
    }

    /// 진행 중 편집이 저장소에 반영된 뒤에 백업·복원이 시작되게 한다.
    private func flushPendingWrites() async {
        _ = await persist()
        _ = await repositoryWriteTask?.result
    }

    /// 지금 백업: 사용자가 입력한 비밀번호로 로컬 데이터가 있는 모든 달과 설정 파일을 iCloud Drive에 올린다.
    func backUpNow(password: String, now: Date = .now) async {
        guard beginBackupOperation(.backingUp(completed: 0, total: 1)) else {
            lastBackupReport = Self.backupBusyReport(.backup)
            return
        }
        let logger = TaptionPlanDiagnosticsLogger.shared
        let operation = logger.beginOperation("icloud_backup_manual")
        var report: PlanBackupReport
        do {
            try authorizeBackupPassword(password)
            guard let backupService else { throw TaptionBackupError.destinationUnavailable("engine unavailable") }
            await flushPendingWrites()
            let results = try await backupService.backupAll(password: password, now: now) { [weak self] completed, total in
                Task { @MainActor in self?.updateBackupProgress(completed: completed, total: total) }
            }
            let items = results.map(PlanBackupPresenter.item(for:))
            if items.contains(where: { $0.kind == .done || $0.kind == .unchanged }) {
                securityService?.recordSuccessfulBackup(at: now)
            }
            let written = items.filter { $0.kind == .done }.count
            let rejected = items.filter { $0.kind == .rejected }.count
            report = PlanBackupReport(
                operation: .backup, finishedAt: now, items: items, failure: nil,
                summary: AppLanguagePreference.text(
                    korean: "백업 완료: 올림 \(written)개, 거부됨 \(rejected)개",
                    english: "Backup finished: \(written) uploaded, \(rejected) rejected"
                )
            )
            logger.finishOperation(operation, outcome: "success", fields: [
                "written": String(written), "rejected": String(rejected), "files": String(items.count),
            ])
        } catch {
            let message = PlanBackupPresenter.message(for: error)
            report = PlanBackupReport(
                operation: .backup, finishedAt: now, items: [], failure: message,
                summary: AppLanguagePreference.text(korean: "백업 실패: ", english: "Backup failed: ") + message
            )
            logger.finishOperation(operation, outcome: "failure", error: error)
        }
        endBackupOperation(report)
        await refreshBackupListings(password: password)
    }

    /// 백업 후 로컬 정리: 끝난 달 중 백업을 다시 읽어 검증한 달만 이 기기에서 지운다.
    func offloadLocalMonths(password: String, now: Date = .now) async {
        guard beginBackupOperation(.offloading) else {
            lastBackupReport = Self.backupBusyReport(.offload)
            return
        }
        var report: PlanBackupReport
        do {
            try authorizeBackupPassword(password)
            guard let backupService, let securityService else {
                throw TaptionBackupError.destinationUnavailable("engine unavailable")
            }
            await flushPendingWrites()
            let results = try await backupService.offload(
                password: password, now: now, keepRecentMonths: securityService.localMonthsToKeep
            )
            let items = results.map(PlanBackupPresenter.item(for:))
            let sealed = items.filter { $0.kind == .done }.count
            if sealed > 0 { try await reloadSnapshotAfterStoreChange() }
            report = PlanBackupReport(
                operation: .offload, finishedAt: now, items: items, failure: nil,
                summary: AppLanguagePreference.text(
                    korean: "로컬 정리 완료: \(sealed)개 달을 정리, \(items.count - sealed)개 달은 건너뜀",
                    english: "Cleanup finished: \(sealed) months cleared, \(items.count - sealed) skipped"
                )
            )
        } catch {
            let message = PlanBackupPresenter.message(for: error)
            report = PlanBackupReport(
                operation: .offload, finishedAt: now, items: [], failure: message,
                summary: AppLanguagePreference.text(korean: "로컬 정리 실패: ", english: "Cleanup failed: ") + message
            )
        }
        endBackupOperation(report)
        await refreshBackupListings(password: password)
    }

    /// 백업 한 개(월 또는 설정)를 비밀번호로 복원한다. 로컬에서 정리한 달을 다시 불러오는 데도 쓴다.
    /// 복원은 기존 로컬 행보다 새 것만 가져오고, 끝나면 repository를 다시 불러온다.
    func restoreBackup(_ scope: TaptionBackupScope, password: String, now: Date = .now) async {
        let name = PlanBackupPresenter.name(of: scope)
        guard beginBackupOperation(.restoring(name)) else {
            lastBackupReport = Self.backupBusyReport(.restore)
            return
        }
        var report: PlanBackupReport
        do {
            guard let backupService else { throw TaptionBackupError.destinationUnavailable("engine unavailable") }
            await flushPendingWrites()
            let summary = try await backupService.restore(scope, password: password)
            try await reloadSnapshotAfterStoreChange()
            let detail = AppLanguagePreference.text(
                korean: "센서 \(summary.newReadings)행 추가, 기록 \(summary.changedRecords)개 반영",
                english: "\(summary.newReadings) sensor rows added, \(summary.changedRecords) records applied"
            )
            report = PlanBackupReport(
                operation: .restore, finishedAt: now,
                items: [PlanBackupItem(name: name, kind: .done, detail: detail)], failure: nil,
                summary: AppLanguagePreference.text(korean: "\(name) 복원 완료", english: "Restored \(name)")
            )
        } catch {
            let message = PlanBackupPresenter.message(for: error)
            report = PlanBackupReport(
                operation: .restore, finishedAt: now, items: [], failure: message,
                summary: AppLanguagePreference.text(korean: "복원 실패: ", english: "Restore failed: ") + message
            )
        }
        endBackupOperation(report)
        await refreshBackupListings(password: password)
    }

    private static func backupBusyReport(_ operation: PlanBackupReport.Operation) -> PlanBackupReport {
        let message = PlanSecurityError.backupInProgress.localizedDescription()
        return PlanBackupReport(operation: operation, finishedAt: .now, items: [], failure: message, summary: message)
    }

    /// iCloud 백업 파일을 모두 지운다. **되돌릴 수 없으므로 사용자 확인 뒤에만 부른다.**
    /// 실패한 파일이 있으면 이름을 담아 던진다. 성공하면 마지막 백업 시각도 지운다.
    func deleteAllBackupFiles(confirmed: Bool) async throws {
        guard confirmed else { throw CancellationError() }
        guard let backupService else { throw TaptionBackupError.destinationUnavailable("engine unavailable") }
        let result = try await backupService.deleteAllBackups()
        if !result.failed.isEmpty || !(result.remaining ?? []).isEmpty {
            throw BackupDeletionError(names: result.failed.map(\.name) + (result.remaining ?? []))
        }
        securityService?.clearLatestBackupDate()
        securityStatus = securityService?.status ?? securityStatus
        backupListings = []
    }

    private struct BackupDeletionError: LocalizedError {
        let names: [String]
        var errorDescription: String? { names.joined(separator: ", ") }
    }

    func protectCurrentDataWithBiometrics() async throws {
        guard acceptsDataMutation() else { throw CancellationError() }
        guard let biometricProtectedSnapshotStore else {
            throw BiometricDataProtectionError.invalidArchive
        }
        biometricDataProtectionStatus = try await biometricProtectedSnapshotStore
            .protect(snapshot)
    }

    func validateBiometricProtectedData() async throws {
        guard let biometricProtectedSnapshotStore else {
            throw BiometricDataProtectionError.archiveMissing
        }
        biometricDataProtectionStatus = try await biometricProtectedSnapshotStore
            .validate()
    }

    /// 이 기기의 모든 기록을 지운다. `includingBackups`가 true일 때만 iCloud Drive의 백업 파일도 지운다
    /// (되돌릴 수 없으므로 호출하는 화면이 사용자 확인을 받아야 한다).
    func deleteAllUserData(includingBackups: Bool = false) async {
        guard acceptsDataMutation() || (isStartupSnapshotPartial && allowsRepositoryLoadAttempt()) else { return }
        isDeletingUserData = true
        let deletionCutoff = Date.now
        dataDeletionGeneration = TaptionDataDeletionFence.advance(
            at: deletionCutoff
        )
        defer {
            sensorService?.finishDataDeletion()
            TaptionDataDeletionFence.finish(
                generation: dataDeletionGeneration
            )
            isDeletingUserData = false
        }
        foregroundPreparationGeneration &+= 1
        let pendingTasks = [
            bootstrapTask,
            startupSettingsTask,
            bootstrapPreparationTask,
            permissionRefreshTask,
            foregroundPreparationTask,
            foregroundRefreshTask,
            deferredVisibleRefreshTask,
            foregroundHealthRefreshTask,
            calendarStoreRefreshTask,
            selectedDateRefreshTask,
            widgetReloadFollowupTask,
            calibrationNoticeTask,
            sensorAnalysisDebounceTask,
            liveWeatherRefreshTask,
            pendingDeviceLocalPersistTask,
            postSaveRefreshTask,
            cloudSyncTask,
        ].compactMap { $0 }
        pendingTasks.forEach { $0.cancel() }
        let pendingSensorTimeline = sensorTimelineTask
        pendingSensorTimeline?.cancel()
        bootstrapTask = nil
        startupSettingsTask = nil
        hasPreparedStartupSettings = false
        isStartupSnapshotPartial = false
        bootstrapPreparationTask = nil
        permissionRefreshTask = nil
        needsBootstrapPreparation = false
        foregroundPreparationTask = nil
        foregroundRefreshTask = nil
        deferredVisibleRefreshTask = nil
        foregroundHealthRefreshTask = nil
        calendarStoreRefreshTask = nil
        calendarStoreRefreshRequiresWide = false
        selectedDateRefreshGeneration &+= 1
        selectedDateRefreshTask = nil
        widgetReloadFollowupTask = nil
        calibrationNoticeTask = nil
        sensorAnalysisDebounceTask = nil
        sensorAnalysisTaskGeneration &+= 1
        pendingSensorAnalysisRevisions.removeAll(keepingCapacity: false)
        liveWeatherRefreshTask = nil
        pendingDeviceLocalPersistTask = nil
        postSaveRefreshTask = nil
        postSaveRefreshRequested = false
        cloudSyncTask = nil
        _ = airPodsActivityService.stop(at: deletionCutoff)
        await sensorService?.prepareForDataDeletion()
        await dayLoadCoordinator?.invalidateAll()
        MapHomeDayCacheEviction.removeAll()
        sensorBackgroundCoordinator.cancel()
        syncSensorBackgroundState()
        for task in pendingTasks { await task.value }
        _ = await pendingSensorTimeline?.value
        while isHealthRefreshRunning || activeDataMutationCount > 0 {
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                userFacingError = AppLanguagePreference.text(
                    korean: "데이터 삭제가 취소되었습니다. 다시 시도해 주세요.",
                    english: "Data deletion was cancelled. Please try again."
                )
                return
            }
        }
        _ = voiceMemoRecorder.stop()
        voiceMemoPlayer.stop()
        isRecordingVoiceMemo = false
        playingVoiceAttachmentID = nil
        await liveActivityController.concealAll()
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
        sleepReconciliations = []
        pendingMapMemoIDs.removeAll()
        finalizedTrackingSessionIDs.removeAll()
        latestWatchSummaryVersion.removeAll()
        appliedWatchSummaryVersion.removeAll()
        restoredWatchSummarySessions.removeAll()
        Self.clearPersistedWatchSummaryHighWater()
        finalizedWatchSummarySessionIDs.removeAll()
        pendingWatchActivitySuggestion = nil
        latestSensorReading = nil
        latestMapAnchorHydratedDay = nil
        lastLiveEnvironmentPoint = nil
        lastLiveEnvironmentAt = nil
        lastLiveEnvironmentFailureAt = nil
        lastReviewArchiveRefreshAt = nil
        UserDefaults.standard.removeObject(
            forKey: Self.calendarAutomaticRefreshKey
        )
        liveMergeCacheKey = nil
        liveMergeCacheValue = []
        sensorRefreshFingerprints.removeAll()
        lastWatchHealthSnapshotCapturedAt = nil
        lastWatchHealthSnapshotRawRetryAt = nil
        lastWatchHealthSnapshotRawRetryFingerprint = nil
        lastWatchHealthSnapshotRawRetryAttemptAt = nil
        var deletionFailures: [String] = []
        func recordDeletionFailure(_ label: String, _ error: Error) {
            deletionFailures.append(label)
            Self.integrationLogger.error(
                "Data deletion failed: \(label, privacy: .public), \(error.localizedDescription, privacy: .public)"
            )
        }
        if let cloudSyncService {
            do {
                try await cloudSyncService.deleteSnapshot()
            } catch {
                recordDeletionFailure(
                    AppLanguagePreference.text(korean: "iCloud 동기화 기록", english: "iCloud sync records"),
                    error)
            }
        } else if permissionState(for: .cloud).isGranted {
            recordDeletionFailure(
                AppLanguagePreference.text(korean: "iCloud 동기화 기록", english: "iCloud sync records"),
                CancellationError())
        }
        do {
            try await repository.deleteAll()
        } catch {
            recordDeletionFailure(
                AppLanguagePreference.text(korean: "앱 기록", english: "App records"),
                error)
        }
        if let sensorService {
            do {
                try await sensorService.deleteArchivedReadings(
                    generation: dataDeletionGeneration
                )
            } catch {
                recordDeletionFailure(
                    AppLanguagePreference.text(korean: "iPhone 센서 원본", english: "iPhone sensor source data"),
                    error)
            }
        }
        do {
            try await healthService.deleteImportedData(
                generation: dataDeletionGeneration
            )
        } catch {
            recordDeletionFailure(
                AppLanguagePreference.text(korean: "건강 데이터 원본", english: "Health source data"),
                error)
        }
        healthSyncOverview = HealthKitSyncOverview(states: [])
        lastHealthRefreshAt = nil
        if let rawDeviceDataArchive {
            do {
                try await rawDeviceDataArchive.deleteAll(
                    generation: dataDeletionGeneration
                )
            } catch {
                recordDeletionFailure(
                    AppLanguagePreference.text(korean: "기기 원본", english: "Device source data"),
                    error)
            }
        }
        if watchConnectivityService.watchDataDeletionRequired(),
           !(await watchConnectivityService.requestWatchDataDeletion(
               generation: dataDeletionGeneration
           )) {
            recordDeletionFailure(
                AppLanguagePreference.text(korean: "Watch 본체 확인", english: "Watch device check"),
                CancellationError())
        }
        if let dayDatabase {
            do {
                try await dayDatabase.deleteAll(
                    generation: dataDeletionGeneration
                )
            } catch {
                recordDeletionFailure(
                    AppLanguagePreference.text(korean: "날짜별 원본", english: "Per-day source data"),
                    error)
            }
        }
        if let biometricProtectedSnapshotStore {
            do {
                try biometricProtectedSnapshotStore.deleteStoredSnapshot()
            } catch {
                recordDeletionFailure(
                    AppLanguagePreference.text(korean: "보호된 스냅샷", english: "Protected snapshot"),
                    error)
            }
        }
        biometricDataProtectionStatus = biometricProtectedSnapshotStore?.status
            ?? .unavailable
        if includingBackups {
            backupActivity = .deleting
            defer { backupActivity = .idle }
            do {
                try await deleteAllBackupFiles(confirmed: true)
            } catch {
                recordDeletionFailure(
                    AppLanguagePreference.text(korean: "iCloud 백업", english: "iCloud backup"),
                    error)
            }
        }
        securityStatus = securityService?.status ?? securityStatus
        appleWatchDataReceiptStore.clear()
        watchConnectivityService.clearLocalState()
        appleWatchLastDataReceivedAt = nil
        appleWatchReceivedDataKinds = []
        WatchActivityConfirmationStore.clear()
        WatchActivityLearningStore.clear()
        WatchLaunchReportStore.clear()
        WatchDiagnosticsLogStore.clear()
        watchLaunchReport = nil
        do {
            try TaptionWidgetSharedStore.deleteAll()
        } catch {
            recordDeletionFailure(
                AppLanguagePreference.text(korean: "위젯 공유 기록", english: "Widget shared records"),
                error)
        }
        do {
            try TaptionPlanDiagnosticsLogPackageBuilder.applicationSupport()
                .deleteAll()
        } catch {
            recordDeletionFailure(
                AppLanguagePreference.text(korean: "진단 로그", english: "Diagnostics log"),
                error)
        }
        do {
            try TaptionPlanDiagnosticsICloudExporter().deleteAll()
        } catch {
            recordDeletionFailure(
                AppLanguagePreference.text(korean: "iCloud 진단 로그", english: "iCloud diagnostics log"),
                error)
        }
        let diagnosticsDefaults = UserDefaults(
            suiteName: TaptionWidgetSharedStore.appGroupIdentifier
        ) ?? .standard
        diagnosticsDefaults.removeObject(forKey: Self.diagnosticsLatestFileKey)
        diagnosticsDefaults.removeObject(forKey: Self.diagnosticsLatestSavedAtKey)
        diagnosticsExportStatusKey = .ready
        if let applicationSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            try? FileManager.default.removeItem(
                at: applicationSupport.appendingPathComponent(
                    "TaptionPlan/VoiceMemos",
                    isDirectory: true
                )
            )
        }
        try? FileManager.default.removeItem(
            at: FileManager.default.temporaryDirectory.appendingPathComponent(
                "TaptionPlanExport",
                isDirectory: true
            )
        )
        TaptionPlanDiagnosticsLogger.shared.clear()
        // The replacement snapshot is post-deletion state, so release the
        // cross-process fence before writing it. `isDeletingUserData` still
        // blocks ordinary mutations until this method returns.
        TaptionDataDeletionFence.finish(
            generation: dataDeletionGeneration
        )
        if deletionFailures.isEmpty,
           !(await persist(allowingDeletion: true)) {
            deletionFailures.append(AppLanguagePreference.text(
                korean: "빈 저장본",
                english: "Empty snapshot"
            ))
        }
        if !deletionFailures.isEmpty {
            userFacingError = AppLanguagePreference.text(
                korean: "일부 데이터를 삭제하지 못했습니다: ",
                english: "Some data could not be deleted: "
            ) + deletionFailures.joined(separator: ", ")
            TaptionPlanDiagnosticsLogger.shared.record(
                "user_data_deletion_incomplete",
                level: .error,
                fields: ["stores": deletionFailures.joined(separator: ",")]
            )
        }
    }
}
