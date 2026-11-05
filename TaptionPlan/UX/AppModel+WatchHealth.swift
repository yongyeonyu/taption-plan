import Foundation
import TaptionPlanCore

extension AppModel {
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
        UserDefaults.standard.set(
            true,
            forKey: Self.watchDataSyncProfileConfiguredKey
        )
        guard snapshot.settings.watchDataSyncProfile != profile else {
            return
        }
        snapshot.settings.watchDataSyncProfile = profile
        publishWatchPayload()
        Task { await persist() }
    }

    func requestWatchDataSync(source: String = "settings_button") {
        scheduleWatchHealthRefresh()
        guard AppleWatchLink.isEnabled() else { return }
        watchConnectivityService.requestWatchDataSync()
    }

    private func applyWatchCollectionDefaultsIfNeeded(_ state: AppleWatchConnectionState) {
        guard let profiles = AppleWatchCollectionDefaults.enabledProfiles(
            acceleration: snapshot.settings.watchAccelerationProfile,
            dataSync: snapshot.settings.watchDataSyncProfile,
            state: state,
            alreadyApplied: UserDefaults.standard.bool(forKey: AppleWatchCollectionDefaults.appliedKey)
        ) else { return }
        UserDefaults.standard.set(true, forKey: AppleWatchCollectionDefaults.appliedKey)
        snapshot.settings.watchAccelerationProfile = profiles.acceleration
        snapshot.settings.watchDataSyncProfile = profiles.dataSync
        publishWatchPayload()
        Task { await persist() }
    }

    func applyAppleWatchLinkChange() {
        publishWatchPayload()
    }

    func scheduleWatchHealthRefresh() {
        guard isBootstrapped, isSceneActive, !isAppLocked, watchHealthRefreshTask == nil else { return }
        watchHealthRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.watchHealthRefreshTask = nil }
            let action = TaptionWatchHealthLaunchPolicy.action(
                isPaired: self.watchConnectivityService.isWatchPaired,
                healthEnabled: self.settings.healthEnabled,
                hasRequestedAuthorization: UserDefaults.standard.bool(
                    forKey: Self.healthAuthorizationRequestedKey
                )
            )
            guard self.isSceneActive, !self.isAppLocked else { return }
            switch action {
            case .requestAuthorization:
                await self.requestHealth()
            case .refresh:
                do {
                    if try await self.healthService.authorizationRequestState() == .notDetermined {
                        await self.requestHealth()
                        return
                    }
                } catch {
                    // Already connected HealthKit remains queryable if request-status lookup fails.
                }
                await self.refreshHealthData(in: self.startupHealthSpan, showErrors: false, forceRawSync: true)
                await self.persistDeviceLocalSnapshot()
            case .none:
                break
            }
        }
    }

    func applyAppleWatchDataSyncLiveFailure(requestID: String) {
        guard appleWatchDataSyncRequestID == requestID,
              appleWatchDataSyncRequestedAt != nil else { return }
        appleWatchDataSyncRequestStatus = .backgroundQueued
        TaptionPlanDiagnosticsLogger.shared.record(
            "watch_data_sync_live_failure_applied",
            level: .notice,
            fields: ["request_id": requestID]
        )
    }

    func refreshAppleWatchConnectionState() {
        watchConnectivityService.refreshConnectionState()
        refreshWatchLaunchReport()
    }

    /// 페어링 완료 이벤트에서도 HealthKit 연결을 확인한다.
    func applyAppleWatchConnectionState(_ state: AppleWatchConnectionState) {
        let changed = appleWatchConnectionState != state
        let version = watchConnectivityService.watchAppVersion
        if appleWatchAppVersion != version { appleWatchAppVersion = version }
        applyWatchCollectionDefaultsIfNeeded(state)
        scheduleWatchHealthRefresh()
        if changed {
            appleWatchConnectionState = state
            // Reachability is not part of the Watch payload itself. Reset the
            // identity so a newly reachable companion receives the latest
            // queue once, without restoring the old duplicate-send loop.
            lastWatchPayloadIdentity = nil
            publishWatchPayload()
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

    /// 건강 앱 조회와 Watch 앱 수집을 함께 알리는 안내.
    var appleWatchCompanionRow: AppleWatchCompanionRow {
        AppleWatchCompanionRow(
            subtitle: AppLanguagePreference.text(
                korean: "건강 앱과 Watch 앱의 데이터를 가져옵니다",
                english: "Imports data from the Health app and the Watch app"
            ),
            value: settings.healthEnabled
                ? AppLanguagePreference.text(korean: "건강 연결", english: "Health connected")
                : AppLanguagePreference.text(korean: "권한 필요", english: "Permission needed"),
            detail: AppLanguagePreference.text(
                korean: "앱을 열면 건강 앱을 조회하고, Watch 앱은 저전력으로 움직임을 모아 보냅니다. Watch 상태에 따라 최신 데이터가 늦게 도착할 수 있습니다.",
                english: "Health data is fetched when you open the app, and the Watch app sends motion data in low-power mode. The latest data may arrive late depending on the Watch."
            )
        )
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

    func applyWatchCommand(_ command: TaptionWatchCommand) async {
        // 애플워치 연동을 끄면 워치에서 온 명령을 받지 않는다.
        guard UserDefaults.standard.object(forKey: "appleWatchLinkEnabled") as? Bool ?? true else { return }
        guard !TaptionExternalPrivacyStore.isLocked,
              acceptsDataMutation(capturedAt: command.requestedAt) else {
            return
        }
        activeDataMutationCount += 1
        defer { activeDataMutationCount -= 1 }
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

    func applyWatchHealthSnapshot(
        _ snapshot: TaptionWatchHealthSnapshot,
        receivedAt: Date,
        requestID: String?
    ) async {
        guard let snapshot = snapshot.retainingData(
            after: TaptionDataDeletionFence.cutoff(),
            receivedAt: receivedAt
        ) else {
            TaptionPlanDiagnosticsLogger.shared.record(
                "watch_health_snapshot_ignored",
                level: .notice,
                fields: ["reason": "deletion_or_invalid_timestamp"]
            )
            return
        }
        guard acceptsDataMutation(capturedAt: snapshot.capturedAt) else {
            return
        }
        let rawPayloadFingerprint = (
            try? RawDeviceDataEnvelope.payloadEncoder().encode(snapshot)
        ).map(TaptionPlanCanonicalStorage.checksum)
        guard WatchHealthSnapshotRetryPolicy.accepts(
            capturedAt: snapshot.capturedAt,
            fingerprint: rawPayloadFingerprint,
            receivedAt: receivedAt,
            lastAppliedAt: lastWatchHealthSnapshotCapturedAt,
            rawRetryAt: lastWatchHealthSnapshotRawRetryAt,
            rawRetryFingerprint:
                lastWatchHealthSnapshotRawRetryFingerprint,
            lastRawRetryAttemptAt:
                lastWatchHealthSnapshotRawRetryAttemptAt
        ) else {
            TaptionPlanDiagnosticsLogger.shared.record(
                "watch_health_snapshot_ignored",
                fields: ["reason": "stale_or_duplicate"]
            )
            return
        }
        activeDataMutationCount += 1
        defer { activeDataMutationCount -= 1 }
        var dataKinds: Set<AppleWatchDataKind> = [.health]
        if snapshot.workoutCount > 0 {
            dataKinds.insert(.activity)
        }
        TaptionPlanDiagnosticsLogger.shared.record(
            "watch_health_snapshot_apply_started",
            fields: [
                "workout_count": String(snapshot.workoutCount),
                "sleep_minutes": String(snapshot.sleepMinutes ?? 0),
                "sleep_payload_present": String(
                    !(snapshot.sleepSegments?.isEmpty ?? true)
                ),
                "sleep_segment_count": String(
                    snapshot.sleepSegments?.count ?? 0
                ),
                "data_kinds": dataKinds.map(\.rawValue)
                    .sorted().joined(separator: ","),
                "health_enabled": String(settings.healthEnabled),
            ]
        )
        let isRawRetry = snapshot.capturedAt
            == lastWatchHealthSnapshotCapturedAt
        if isRawRetry {
            lastWatchHealthSnapshotRawRetryAttemptAt = receivedAt
            let rawArchived = await archiveRawDeviceData(
                source: .appleWatch,
                kind: "watch-health-snapshot",
                payload: snapshot,
                capturedAt: snapshot.capturedAt
            )
            guard rawArchived else {
                TaptionPlanDiagnosticsLogger.shared.record(
                    "watch_health_snapshot_raw_retry_failed",
                    level: .error,
                    fields: [
                        "captured_at": String(
                            snapshot.capturedAt.timeIntervalSince1970
                        ),
                    ]
                )
                return
            }
            lastWatchHealthSnapshotRawRetryAt = nil
            lastWatchHealthSnapshotRawRetryFingerprint = nil
            lastWatchHealthSnapshotRawRetryAttemptAt = nil
            noteAppleWatchDataReceived(
                dataKinds,
                measuredAt: snapshot.capturedAt,
                receivedAt: receivedAt,
                requestID: requestID
            )
            return
        }
        let rawArchived = await archiveRawDeviceData(
            source: .appleWatch,
            kind: "watch-health-snapshot",
            payload: snapshot,
            capturedAt: snapshot.capturedAt
        )
        if !rawArchived {
            TaptionPlanDiagnosticsLogger.shared.record(
                "watch_health_snapshot_raw_persistence_failed",
                level: .error,
                fields: [
                    "captured_at": String(
                        snapshot.capturedAt.timeIntervalSince1970
                    ),
                    "derived_fallback": "true",
                ]
            )
        }
        guard acceptsDataMutation(capturedAt: snapshot.capturedAt) else {
            return
        }
        guard WatchHealthSnapshotRetryPolicy.accepts(
            capturedAt: snapshot.capturedAt,
            fingerprint: rawPayloadFingerprint,
            receivedAt: receivedAt,
            lastAppliedAt: lastWatchHealthSnapshotCapturedAt,
            rawRetryAt: lastWatchHealthSnapshotRawRetryAt,
            rawRetryFingerprint:
                lastWatchHealthSnapshotRawRetryFingerprint,
            lastRawRetryAttemptAt:
                lastWatchHealthSnapshotRawRetryAttemptAt
        ) else {
            return
        }
        lastWatchHealthSnapshotCapturedAt = snapshot.capturedAt
        lastWatchHealthSnapshotRawRetryAt = rawArchived ? nil : snapshot.capturedAt
        lastWatchHealthSnapshotRawRetryFingerprint = rawArchived
            ? nil
            : rawPayloadFingerprint
        lastWatchHealthSnapshotRawRetryAttemptAt = rawArchived
            ? nil
            : receivedAt
        if rawArchived {
            noteAppleWatchDataReceived(
                dataKinds,
                measuredAt: snapshot.capturedAt,
                receivedAt: receivedAt,
                requestID: requestID
            )
        }
        var watchSleepSessionCount = 0
        if let segments = snapshot.sleepSegments, !segments.isEmpty {
            let sleepSegments = segments.compactMap { segment -> SleepSegment? in
                guard let stage = SleepStage(rawValue: segment.stage),
                      segment.endDate > segment.startDate else {
                    return nil
                }
                return SleepSegment(
                    id: segment.id,
                    stage: stage,
                    span: TimeSpan(
                        start: segment.startDate,
                        end: segment.endDate
                    ),
                    sourceName: segment.sourceName,
                    sourceBundleIdentifier: segment.sourceBundleIdentifier,
                    deviceName: segment.deviceName,
                    timeZoneIdentifier: segment.timeZoneIdentifier,
                    isUserEntered: segment.isUserEntered
                )
            }
            let sessions = SleepAnalysisEngine().sessions(from: sleepSegments)
            watchSleepSessionCount = sessions.count
            if !sessions.isEmpty {
                let overnightSpan = SleepAnalysisEngine.overnightSpan(
                    containing: snapshot.capturedAt
                )
                let installation = SleepSessionInstallation.installing(
                    sessions,
                    into: sleepSessions,
                    inside: overnightSpan,
                    replacing: { $0.isAppleWatchConfirmed }
                )
                sleepSessions = installation.sessions
                applySleepReconciliations(installation.reconciliations)
                self.snapshot.actuals.removeAll {
                    $0.source == .appleWatch
                        && AutomaticRecordTimelineEngine.isSleep($0)
                        && $0.span(asOf: snapshot.capturedAt).intersection(
                            with: overnightSpan
                        ) != nil
                }
                self.snapshot.actuals = SleepActualReconciliationEngine.applying(
                    self.snapshot.actuals,
                    sessions: sessions,
                    inside: overnightSpan,
                    asOf: snapshot.capturedAt
                )
            }
        }
        let shouldRefreshHealth = settings.healthEnabled
            && (lastHealthRefreshAt.map {
                Date.now.timeIntervalSince($0)
                    >= HealthRefreshPolicy.foregroundInterval
            } ?? true)
        if shouldRefreshHealth {
            await refreshHealthData(showErrors: false)
        }
        await persistDeviceLocalSnapshot()
        TaptionPlanDiagnosticsLogger.shared.record(
            "watch_health_snapshot_applied",
            fields: [
                "workout_count": String(snapshot.workoutCount),
                "sleep_minutes": String(snapshot.sleepMinutes ?? 0),
                "sleep_segment_count": String(
                    snapshot.sleepSegments?.count ?? 0
                ),
                "sleep_sessions_created": String(watchSleepSessionCount),
                "health_refresh_requested": String(shouldRefreshHealth),
            ]
        )
    }

    func isWatchSummaryAtHome(
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
}
