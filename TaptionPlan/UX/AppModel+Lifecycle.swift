import Foundation
import TaptionPlanCore

extension AppModel {
    func sceneBecameActive() async {
        SensorBackgroundWakeNotification.cancel()
        isCommerceLocked = false
        let wasSceneActive = isSceneActive
        isSceneActive = true
        isSceneInBackground = false
        if let securityService {
            if !isBootstrapped {
                securityService.handleLaunch()
            } else if !wasSceneActive {
                securityService.handleForeground()
            }
            securityStatus = securityService.status
            if isAppLocked {
                TaptionExternalPrivacyStore.setLocked(true)
            }
        }
        await prepareStartupSettings()
        if hasPreparedStartupSettings && !isBootstrapped {
            Task { @MainActor [weak self] in await self?.bootstrapLocalSnapshot() }
        } else {
            await bootstrapLocalSnapshot()
        }
        updateForegroundLiveLocationTracking()
        startCurrentActivitySyncIfNeeded()
        if isAppLocked {
            await concealExternalSurfaces()
        } else {
            setExternalPrivacyLocked(false)
        }
        guard !wasSceneActive else { return }
        scheduleNearbyMemoSync()
        // 비활성이라 미뤄 둔 기록 정리·저장을 여기서 이어서 끝낸다.
        scheduleBootstrapPreparation()
        if !pendingSensorAnalysisRevisions.isEmpty {
            startSensorAnalysis(immediately: false)
        }
        scheduleWatchHealthRefresh()
        scheduleForegroundPreparation()
        if postSaveRefreshRequested { schedulePostSaveRefresh() }
        // 앱으로 돌아오면 곧바로 지금 활동을 다시 확인해 밖의 화면과 맞춘다.
        await publishCurrentActivityIfChanged()
        // 지나간 날은 한 번 확정해 두고 다시 계산하지 않는다.
        // 확정은 하루치 원본을 읽으므로, 앱을 여는 일과 겹치지 않게 잠시 뒤에 한다.
        await reloadSealedDaysIfNeeded()
        scheduleDaySealing()
    }

    /// 앱이 안정된 뒤에 지나간 날을 확정한다(시작 화면·지도 적재와 겹치지 않게).
    private func scheduleDaySealing() {
        daySealingTask?.cancel()
        daySealingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self else { return }
            await self.sealSettledDays()
            self.daySealingTask = nil
        }
    }

    func handleMemoryPressure() {
        TaptionPlanDiagnosticsLogger.shared.record("application_memory_warning", level: .notice)
        dayLoadCoordinator?.handleMemoryPressure()
        MapHomeDayCacheEviction.removeAll()
        let repository = self.repository
        Task { await repository.handleMemoryPressure() }
    }

    private func scheduleForegroundPreparation() {
        foregroundPreparationTask?.cancel()
        foregroundPreparationGeneration &+= 1
        let generation = foregroundPreparationGeneration
        foregroundPreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.foregroundPreparationGeneration == generation {
                    self.foregroundPreparationTask = nil
                }
            }
            await Task.yield()
            guard !Task.isCancelled,
                  self.isSceneActive,
                  self.foregroundPreparationGeneration == generation else {
                return
            }

            await self.refreshPermissions()
            guard !Task.isCancelled,
                  self.isSceneActive,
                  self.foregroundPreparationGeneration == generation else {
                return
            }
            self.updateForegroundLiveLocationTracking()

            await self.applyPendingLocationTrackingRequest()
            await self.hydrateLatestMapLocationAnchor()
            self.applyPendingLocationTrackingGuidance()
            self.airPodsActivityService.start { [weak self] observation in
                self?.applyAirPodsActivity(observation)
            }
            self.scheduleForegroundRefresh()
        }
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

    func hydrateLatestMapLocationAnchor() async {
        guard settings.locationEnabled,
              permissionState(for: .location).isGranted,
              let sensorService else {
            return
        }
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: .now)
        guard latestMapAnchorHydratedDay != dayStart else { return }
        let span = TimelineAggregationEngine().interval(
            for: .day,
            containing: .now
        )
        guard let readings = try? await sensorService.archivedReadings(in: span) else {
            return
        }
        latestMapAnchorHydratedDay = dayStart
        guard let latest = MapCurrentLocationAnchorPolicy.latestValidReading(
            in: readings
        ) else { return }
        if latestSensorReading != latest {
            latestSensorReading = latest
        }
    }

    func sceneEnteredBackground() async {
        // Checkpoint, final persist and backup below need more time than iOS
        // gives a suspending scene, so hold an assertion until they finish.
        let backgroundAssertion = BackgroundTaskAssertion()
        backgroundAssertion.begin(name: "TaptionPlan.sceneBackground") {}
        defer { backgroundAssertion.end() }
        isSceneActive = false
        isSceneInBackground = true
        stopCurrentActivitySync()
        updateForegroundLiveLocationTracking()
        let cancelledSensorTimeline = sensorTimelineTask
        sensorTimelineTask?.cancel()
        cancelSensorAnalysisUntilForeground()
        postSaveRefreshTask?.cancel()
        if postSaveRefreshTask != nil { postSaveRefreshRequested = true }
        selectedDateRefreshGeneration &+= 1
        selectedDateRefreshTask?.cancel()
        selectedDateRefreshTask = nil
        daySealingTask?.cancel()
        daySealingTask = nil
        calendarStoreRefreshTask?.cancel()
        calendarStoreRefreshTask = nil
        dayLoadCoordinator?.prepareForBackground()
        foregroundPreparationGeneration &+= 1
        foregroundPreparationTask?.cancel()
        foregroundPreparationTask = nil
        if securityStatus.settings.lockOnLaunch
            || securityStatus.settings.lockOnForeground {
            await concealExternalSurfaces()
        }
        for observation in airPodsActivityService.stop(at: .now) {
            applyAirPodsActivity(observation)
        }
        await resumeSensorCollectionAndRestoreTrackingIfNeeded()
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = nil
        deferredVisibleRefreshTask?.cancel()
        deferredVisibleRefreshTask = nil
        foregroundHealthRefreshTask?.cancel()
        foregroundHealthRefreshTask = nil
        liveWeatherRefreshTask?.cancel()
        if let rawDeviceDataArchive {
            try? await rawDeviceDataArchive.checkpoint()
        }
        // A refresh that is still unwinding makes the persist below defer to
        // a trailing write, which may never run once the app is suspended.
        _ = await cancelledSensorTimeline?.value
        await persistDeviceLocalSnapshot(force: true)
        await repository.handleMemoryPressure()
    }

    func suspendForCommerceLock() async {
        isCommerceLocked = true
        isSceneActive = false
        cancelSensorAnalysisUntilForeground()
        await concealExternalSurfaces()
        selectedDateRefreshGeneration &+= 1
        selectedDateRefreshTask?.cancel()
        selectedDateRefreshTask = nil
        calendarStoreRefreshTask?.cancel()
        calendarStoreRefreshTask = nil
        foregroundPreparationGeneration &+= 1
        foregroundPreparationTask?.cancel()
        foregroundPreparationTask = nil
        await sensorService?.stopCollectionAndWait()
        sensorBackgroundCoordinator.cancel()
        SensorBackgroundWakeNotification.cancel()
        syncSensorBackgroundState()
        isSensorCollecting = false
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = nil
        deferredVisibleRefreshTask?.cancel()
        deferredVisibleRefreshTask = nil
        foregroundHealthRefreshTask?.cancel()
        foregroundHealthRefreshTask = nil
        liveWeatherRefreshTask?.cancel()
        if activeTrackingSession != nil {
            await stopTracking()
        }
    }

    private func applyAirPodsActivity(
        _ observation: AirPodsActivityObservation
    ) {
        guard acceptsDataMutation(
            capturedAt: observation.endedAt ?? observation.startedAt
        ),
        !snapshot.settings.suppressedActualIDs.contains(observation.id)
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

    /// 알람 확인으로 실제 기록을 남긴다. 시작(출근·등교·기상)은 열린 기록을 만들고, 끝(퇴근·하교)은 같은 종류의 열린 기록을 닫는다.
    func confirmAlarmRecord(categoryID: String, title: String, at date: Date, opens: Bool) {
        guard acceptsDataMutation() else { return }
        if opens {
            snapshot.actuals.append(ActualRecord(
                id: UUID(),
                planID: nil,
                routineID: nil,
                title: title,
                categoryID: categoryID,
                startedAt: date,
                endedAt: nil,
                source: .manual,
                confidence: .high,
                createdAt: .now,
                behavior: nil,
                evidence: ["알람 확인"],
                modelVersion: nil
            ))
        } else if let index = snapshot.actuals.indices
            .filter({ snapshot.actuals[$0].categoryID == categoryID && snapshot.actuals[$0].endedAt == nil })
            .max(by: { snapshot.actuals[$0].startedAt < snapshot.actuals[$1].startedAt }),
                  date >= snapshot.actuals[index].startedAt {
            snapshot.actuals[index].endedAt = date
            snapshot.actuals[index].manuallyCorrected = true
        } else {
            return
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
            if let lastForegroundRefreshAt = self.lastForegroundRefreshAt,
               Date.now.timeIntervalSince(lastForegroundRefreshAt) < 5 {
                self.foregroundRefreshTask = nil
                return
            }
            self.watchConnectivityService.refreshConnectionState()
            self.refreshWatchLaunchReport()
            await self.configureHealthBackgroundDeliveryIfNeeded(
                showErrors: false
            )
            self.startForegroundHealthRefreshIfNeeded()
            await self.refreshPermissionStates()
            await self.waitForBootstrapPreparation()
            await self.applyPendingWidgetCommands(
                repositoryAlreadyLoaded: false
            )
            await self.resumeSensorCollectionAndRestoreTrackingIfNeeded()
            await self.refreshEnabledData(
                includesCurrentDeviceDay: true,
                dataSpan: self.currentDeviceDataSpan,
                healthSpan: self.startupHealthSpan,
                includesHealth: false
            )
            self.lastForegroundRefreshAt = .now
            self.foregroundRefreshTask = nil
            self.scheduleDeferredVisibleRefresh()
            self.scheduleCalendarStoreRefresh()
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
            await self.synchronizeCloud(showErrors: false)
            await self.persistDeviceLocalSnapshot()
            self.deferredVisibleRefreshTask = nil
        }
    }

    /// Refreshes device-backed records and republishes the shared widget
    /// payload when iOS wakes the app without presenting its UI. 화면이 떠 있으면 물러난다.
    func performBackgroundRefresh(
        wakeReason: SensorWakeReason = .bgAppRefresh
    ) async -> Bool {
        let logger = TaptionPlanDiagnosticsLogger.shared
        let operation = logger.beginOperation(
            "background_refresh",
            fields: ["wake_reason": wakeReason.rawValue]
        )
        // 배너는 앞선 실패나 적재 회복으로 지워지기도 한다. 이번 작업이 오류를 새웠는지만 성패로 본다.
        let errorAtStart = userFacingError
        var succeeded = false
        defer {
            logger.finishOperation(
                operation,
                outcome: Task.isCancelled ? "cancelled" : (succeeded ? "success" : "failure"),
                fields: ["wake_reason": wakeReason.rawValue, "sensor_collecting": String(isSensorCollecting)]
                    .merging(BackgroundRefreshUserErrorDiagnostics.fields(atStart: errorAtStart, atEnd: userFacingError)) { _, new in new }
            )
        }
        Self.integrationLogger.notice("Background model refresh started")
        receiveSensorWake(wakeReason)
        await bootstrap()
        await waitForBootstrapPreparation()
        // 화면이 떠 있으면 배경 갱신은 물러난다. 같은 일을 화면 쪽이 곧바로 하므로, 여기서 또 하면 저장소와 CPU를 나눠 써 시작이 느려진다(2026-10-28 로그).
        if isSceneActive { logger.record("background_refresh_yielded"); succeeded = true; return succeeded }
        await applyPendingWidgetCommands(repositoryAlreadyLoaded: false)
        await refreshPermissionStates()
        let samplingWindow = settings.sensorCollectionProfile.samplingWindowDuration
        let sensorService = self.sensorService
        let persistenceToken = sensorService?.persistenceToken() ?? 0
        await self.resumeSensorCollectionAndRestoreTrackingIfNeeded()
        if isSensorCollecting, let sensorService {
            sensorService.requestImmediateSample()
            // BG refresh tasks may be terminated as soon as this method
            // returns. Wait for the archive consumer to confirm one write,
            // rather than assuming the sampling window completed it.
            let waitStartedAt = Date()
            let didPersist = await sensorService.waitForPersistedReading(
                after: persistenceToken,
                timeout: samplingWindow + 2
            )
            if didPersist {
                let savedToken = sensorService.persistenceToken()
                _ = sensorBackgroundCoordinator.markSaved(
                    persistedToken: savedToken
                )
                syncSensorBackgroundState()
            } else {
                TaptionPlanDiagnosticsLogger.shared.record(
                    "sensor_background_sample_not_persisted",
                    level: .notice,
                    fields: [
                        "stream_live": String(
                            sensorService.isCollectionLive()
                        ),
                        "archive_error": sensorService
                            .lastPersistenceErrorDescription ?? "none",
                        "wait_ms": String(
                            Int(Date().timeIntervalSince(waitStartedAt) * 1_000)
                        ),
                        "window_s": String(Int(samplingWindow)),
                    ]
                )
                if !sensorService.isCollectionLive() {
                    isSensorCollecting = false
                    sensorBackgroundCoordinator.endSession()
                    syncSensorBackgroundState()
                }
            }
        }
        await refreshEnabledData(
            includesCurrentDeviceDay: true,
            persistDeviceSnapshot: false
        )
        await persist()
        await reconcileSensorCollectionLiveActivity(isForeground: false)
        // 새 오류가 서지 않았으면 성공이다. 앞서 남은 배너는 이번 작업의 실패가 아니다.
        succeeded = userFacingError == errorAtStart || userFacingError == nil
        Self.integrationLogger.notice(
            "Background model refresh finished: success=\(succeeded, privacy: .public), snapshotUpdated=\(self.snapshot.updatedAt.timeIntervalSince1970, privacy: .public)"
        )
        return succeeded
    }

    func performHealthBackgroundRefresh() async {
        await handleObservedHealthChange()
        await reconcileSensorCollectionLiveActivity(isForeground: false)
    }
}
