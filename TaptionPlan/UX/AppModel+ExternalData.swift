import Foundation
import TaptionPlanCore
import UIKit

extension AppModel {
    func refreshEnabledData(
        includesCurrentDeviceDay: Bool = false,
        dataSpan: TimeSpan? = nil,
        healthSpan: TimeSpan? = nil,
        includesHealth: Bool = true,
        persistDeviceSnapshot: Bool = true,
        force: Bool = false
    ) async {
        await waitForBootstrapPreparation()
        guard !Task.isCancelled, acceptsDataMutation(), !isRefreshingIntegrations else { return }
        activeDataMutationCount += 1
        defer { activeDataMutationCount -= 1 }
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: selectedDate)
        let refreshKey = [
            selectedScale.rawValue,
            String(dayStart.timeIntervalSinceReferenceDate),
            String(includesCurrentDeviceDay),
            String(settings.hashValue),
            dataSpan.map { String($0.start.timeIntervalSinceReferenceDate) }
                ?? "visible",
            healthSpan.map { String($0.start.timeIntervalSinceReferenceDate) }
                ?? "default",
        ].joined(separator: "|")
        let uptime = ProcessInfo.processInfo.systemUptime
        guard integrationRefreshGate.shouldStart(
            key: refreshKey,
            nowUptime: uptime,
            force: force
        ) else {
            integrationRefreshSkipCount += 1
            if uptime - lastIntegrationSkipLogUptime >= 5 {
                lastIntegrationSkipLogUptime = uptime
                TaptionPlanDiagnosticsLogger.shared.record(
                    "integration_refresh_skipped",
                    fields: [
                        "reason": "same_window",
                        "count": String(integrationRefreshSkipCount),
                    ]
                )
            }
            return
        }
        let startedAt = uptime
        TaptionPlanDiagnosticsLogger.shared.record(
            "integration_refresh_started",
            fields: [
                "scale": selectedScale.rawValue,
                "day_start": String(dayStart.timeIntervalSince1970),
                "current_day": String(includesCurrentDeviceDay),
            ]
        )
        isRefreshingIntegrations = true
        var calendarRetryForceWide: Bool?
        defer {
            isRefreshingIntegrations = false
            if !Task.isCancelled {
                integrationRefreshGate.commit(
                    key: refreshKey,
                    nowUptime: ProcessInfo.processInfo.systemUptime
                )
            }
            TaptionPlanDiagnosticsLogger.shared.record(
                "integration_refresh_finished",
                fields: [
                    "actuals": String(snapshot.actuals.count),
                    "travel": String(snapshot.travel.count),
                    "weather": String(snapshot.weather.count),
                    "duration_ms": String(
                        Int(
                            (ProcessInfo.processInfo.systemUptime - startedAt)
                                * 1_000
                        )
                    ),
                ]
            )
            if let calendarRetryForceWide {
                scheduleCalendarStoreRefresh(
                    forceWide: calendarRetryForceWide
                )
            }
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
        defer { photoTask?.cancel() }
        if permissionState(for: .calendar).isGranted,
           !settings.selectedCalendarIDs.isEmpty {
            await Task.yield()
            let now = Date.now
            let lastAutomaticRefresh = UserDefaults.standard.object(
                forKey: Self.calendarAutomaticRefreshKey
            ) as? Date
            let refreshesAutomaticRange =
                includesCurrentDeviceDay
                && CalendarSyncPolicy.shouldRefreshAutomaticRange(
                    lastRefresh: lastAutomaticRefresh,
                    now: now
                )
            var completed = true
            for span in CalendarSyncPolicy.refreshSpans(
                requested: refreshSpan,
                includesCurrentDeviceDay: includesCurrentDeviceDay,
                refreshesAutomaticRange: refreshesAutomaticRange,
                now: now
            ) {
                completed = await refreshCalendarEvents(in: span) && completed
            }
            if !completed {
                calendarRetryForceWide = refreshesAutomaticRange
            }
            if refreshesAutomaticRange, completed {
                UserDefaults.standard.set(
                    now,
                    forKey: Self.calendarAutomaticRefreshKey
                )
            }
        }
        guard !Task.isCancelled, acceptsDataMutation() else { return }
        if includesHealth && settings.healthEnabled {
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
            // 잠긴 기기에서 HealthKit이 답하지 못하는 것은 배경에서 정상이다.
            await refreshHealthData(in: healthSpan, showErrors: isSceneActive)
        }
        guard !Task.isCancelled, acceptsDataMutation() else { return }
        let appUsageSpan = selectedScale == .day
            ? refreshSpan
            : currentDeviceDataSpan
        await refreshAppUsageData(in: appUsageSpan)
        guard !Task.isCancelled, acceptsDataMutation() else { return }
        if settings.locationEnabled
            || settings.healthEnabled
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
        guard !Task.isCancelled, acceptsDataMutation() else { return }
        if let photoTask, let photoSpan {
            replacePhotos(await photoTask.value, in: photoSpan)
        }
        await refreshFutureWeatherPreviewIfNeeded()
        logAutomaticRecordSummary()
        // Save raw device records locally before any potentially slow cloud
        // request. Automatic interpretations remain separate projections.
        if persistDeviceSnapshot {
            await persistDeviceLocalSnapshot()
        }
    }

    /// Publishes the latest HealthKit/Watch and sensor records before a
    /// routine dashboard is shown. Automatic evidence is ground truth, so a
    /// dashboard must not wait for the next foreground polling interval.
    func refreshConnectedRecordsNow(force: Bool = true) async {
        await bootstrap()
        await refreshEnabledData(
            includesCurrentDeviceDay: true,
            force: force
        )
    }

    func synchronizeCloud(showErrors: Bool = true) async {
        guard !Task.isCancelled, acceptsDataMutation() else { return }
        activeDataMutationCount += 1
        defer { activeDataMutationCount -= 1 }
        guard let cloudSyncService, !isCloudSyncing else {
            if cloudSyncService == nil {
                snapshot.settings.permissions[.cloud] = .unavailable
                cloudUnavailableReason = .unsupportedBuild
            }
            return
        }
        isCloudSyncing = true
        if showErrors {
            // Settings에서 사용자가 다시 누른 경우에는 이전 Production 스키마
            // 실패를 캐시하지 않고 즉시 재확인한다. 자동 저장은 반복 요청을
            // 만들지 않도록 서비스의 보호 상태를 유지한다.
            await cloudSyncService.resetSchemaAvailability()
        }
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
            let sourceRevision = snapshotRevision
            let (cloudValue, _) = try await cloudSyncService.synchronize(
                local: Self.cloudPortableSnapshot(snapshot)
            )
            guard sourceRevision == snapshotRevision,
                  acceptsDataMutation() else {
                isCloudSyncing = false
                return
            }
            let committed = preparedCloudMergedSnapshot(
                mergeDeviceLocalData(
                    cloud: cloudValue,
                    local: localDeviceData
                ),
                preservingUpdatedAt: localDeviceData.updatedAt
            )
            var persisted = committed
            persisted.memos.removeAll {
                pendingMapMemoIDs.contains($0.id)
            }
            if try await saveToRepository(
                persisted,
                expectedRevision: sourceRevision
            ) {
                assignCommittedCloudSnapshot(committed)
                publishWidgetPayload()
            }
        } catch is CancellationError {
            // Deletion cancels the registered manual task; do not surface a
            // cancellation as a failed user-initiated sync.
        } catch {
            if CloudKitErrorPolicy.isProductionSchemaUnavailable(error)
                || error is RepositoryError
                    && (error as? RepositoryError) == .cloudSchemaUnavailable {
                snapshot.settings.permissions[.cloud] = .unavailable
                cloudUnavailableReason = .schemaMissing
                TaptionPlanDiagnosticsLogger.shared.record(
                    "cloud_sync_schema_unavailable",
                    level: .error,
                    fields: CloudKitErrorPolicy.diagnosticFields(for: error)
                )
                Self.integrationLogger.error(
                    "CloudKit production schema is unavailable; local data remains authoritative"
                )
            } else if showErrors {
                TaptionPlanDiagnosticsLogger.shared.record(
                    "cloud_sync_failed",
                    level: .error,
                    fields: CloudKitErrorPolicy.diagnosticFields(for: error)
                )
                userFacingError = AppLanguagePreference.text(
                    korean: "iCloud와 동기화하지 못했습니다. \(error.localizedDescription)",
                    english: "Could not sync with iCloud. \(error.localizedDescription)"
                )
            }
        }
        isCloudSyncing = false
    }

    func startManualCloudSync() {
        let previous = cloudSyncTask
        previous?.cancel()
        cloudSyncTask = Task { @MainActor [weak self] in
            await previous?.value
            await self?.synchronizeCloud()
        }
    }

    func refreshPhotos() {
        let span = visibleDataSpan
        replacePhotos(photoService.moments(in: span), in: span)
    }

    private func replacePhotos(_ fresh: [PhotoMoment], in span: TimeSpan) {
        snapshot.photos.removeAll { span.contains($0.capturedAt) }
        snapshot.photos.append(contentsOf: fresh)
        snapshot.photos.sort { $0.capturedAt < $1.capturedAt }
    }

    func refreshCalendarEvents() async {
        await refreshCalendarEvents(in: visibleDataSpan)
    }

    func scheduleCalendarStoreRefresh(forceWide: Bool = false) {
        guard isBootstrapped,
              isSceneActive,
              permissionState(for: .calendar).isGranted,
              !snapshot.settings.selectedCalendarIDs.isEmpty else { return }
        calendarStoreRefreshRequiresWide =
            calendarStoreRefreshRequiresWide || forceWide
        calendarStoreRefreshTask?.cancel()
        calendarStoreRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled,
                  let self,
                  self.isSceneActive,
                  self.permissionState(for: .calendar).isGranted,
                  !self.snapshot.settings.selectedCalendarIDs.isEmpty else {
                return
            }
            let forceWide = self.calendarStoreRefreshRequiresWide
            self.calendarStoreRefreshRequiresWide = false
            let now = Date.now
            let lastAutomaticRefresh = UserDefaults.standard.object(
                forKey: Self.calendarAutomaticRefreshKey
            ) as? Date
            let refreshesAutomaticRange =
                CalendarSyncPolicy.shouldRefreshAutomaticRange(
                    lastRefresh: lastAutomaticRefresh,
                    now: now,
                    force: forceWide
                )
            let spans = CalendarSyncPolicy.refreshSpans(
                requested: self.visibleDataSpan,
                includesCurrentDeviceDay: true,
                refreshesAutomaticRange: refreshesAutomaticRange,
                now: now
            )
            var completed = false
            for attempt in 0..<2 {
                if attempt > 0 {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled, self.isSceneActive else { return }
                }
                completed = true
                for span in spans {
                    completed = await self.refreshCalendarEvents(in: span)
                        && completed
                }
                if completed { break }
            }
            if refreshesAutomaticRange, completed {
                UserDefaults.standard.set(
                    now,
                    forKey: Self.calendarAutomaticRefreshKey
                )
            }
            await self.persistDeviceLocalSnapshot()
        }
    }

    @discardableResult
    func refreshCalendarEvents(in span: TimeSpan) async -> Bool {
        snapshot.calendarEvents = snapshot.calendarEvents.map {
            $0.normalizedForDisplay()
        }
        guard !snapshot.settings.selectedCalendarIDs.isEmpty else { return false }
        let liveCalendarIDs = calendarService.calendars().map(\.id)
        guard !liveCalendarIDs.isEmpty else {
            TaptionPlanDiagnosticsLogger.shared.record(
                "calendar_refresh_deferred_empty_store",
                level: .notice
            )
            return false
        }
        let reconciledCalendarIDs = CalendarSyncPolicy.reconciledCalendarIDs(
            existing: snapshot.settings.selectedCalendarIDs,
            live: liveCalendarIDs
        )
        let liveIDs = Set(liveCalendarIDs)
        guard CalendarSyncPolicy.hasCompleteSelection(
            selected: Set(reconciledCalendarIDs),
            live: liveIDs
        ) else {
            TaptionPlanDiagnosticsLogger.shared.record(
                "calendar_refresh_deferred_partial_store",
                level: .notice
            )
            return false
        }
        snapshot.settings.selectedCalendarIDs = reconciledCalendarIDs
        let selected = Set(reconciledCalendarIDs)
        guard let fresh = await calendarService.events(
            in: span,
            selectedCalendarIDs: selected
        ) else {
            TaptionPlanDiagnosticsLogger.shared.record(
                "calendar_refresh_deferred_background_store",
                level: .notice
            )
            return false
        }
        guard !Task.isCancelled,
              permissionState(for: .calendar).isGranted,
              Set(snapshot.settings.selectedCalendarIDs) == selected else {
            return false
        }
        snapshot.calendarEvents = CalendarSyncPolicy.mergingEvents(
            existing: snapshot.calendarEvents,
            fresh: fresh,
            in: span,
            liveCalendarIDs: liveIDs
        )
        return true
    }

    /// 워치 기록이 아이폰 추정을 갈아 끼운 결과를 쌓는다.
    func applySleepReconciliations(_ records: [SleepReconciliation]) {
        sleepReconciliations = SleepReconciliationLedger.appending(
            records,
            to: sleepReconciliations
        )
    }

    func refreshHealthData(
        in requestedSpan: TimeSpan? = nil,
        showErrors: Bool = true,
        forceRawSync: Bool = false
    ) async {
        guard acceptsDataMutation(), !isHealthRefreshRunning else { return }
        // 잠긴 기기에서는 HealthKit이 읽기를 거절한다. 실패를 만들지 않고 잠금이 풀린 뒤 다시 읽는다.
        guard UIApplication.shared.isProtectedDataAvailable else {
            deferHealthRefreshUntilUnlock(fields: ["stage": "before_read"])
            return
        }
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
            do {
                healthSyncOverview = try await healthService
                    .synchronizeChanges(force: forceRawSync)
            } catch {
                Self.integrationLogger.error(
                    "HealthKit incremental raw sync failed: \(error.localizedDescription, privacy: .public)"
                )
            }
            async let nonSleepActualValues = healthService.nonSleepActuals(
                in: span
            )
            async let sessions = healthService.sleepSessions(in: span)
            async let importedValues = healthService.importedActuals(in: span)
            let freshSessions = try await sessions
            let directActuals = try await nonSleepActualValues
                + healthService.sleepActuals(from: freshSessions)
            let importedActuals = (try? await importedValues) ?? []
            var actualsByID = importedActuals.reduce(
                into: [UUID: ActualRecord]()
            ) { result, actual in
                result[actual.id] = actual
            }
            for actual in directActuals {
                actualsByID[actual.id] = actual
            }
            let freshActuals = actualsByID.values.sorted {
                if $0.startedAt != $1.startedAt {
                    return $0.startedAt < $1.startedAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
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
            let stableHealthActuals = ActivityClassificationLockEngine
                .mergingLockedClassifications(
                    existing: existingHealthActuals,
                    fresh: visibleFreshActuals,
                    inside: span
                )
            let existingSleepSessions = sleepSessions.filter {
                $0.span.intersection(with: span) != nil
            }
            if Set(existingHealthActuals) != Set(visibleFreshActuals) {
                await archiveRawDeviceData(
                    source: .healthKit,
                    kind: "health-actuals",
                    payload: freshActuals,
                    capturedAt: span.end
                )
            }
            if Set(existingSleepSessions) != Set(freshSessions) {
                await archiveRawDeviceData(
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
                        with: stableHealthActuals,
                        inside: span
                    )
            } else {
                Self.integrationLogger.notice(
                    "HealthKit returned no actuals; preserving existing records"
                )
            }
            if !freshSessions.isEmpty {
                let installation = SleepSessionInstallation.installing(
                    freshSessions,
                    into: sleepSessions,
                    inside: span
                )
                sleepSessions = installation.sessions
                applySleepReconciliations(installation.reconciliations)
            } else {
                Self.integrationLogger.notice(
                    "HealthKit returned no sleep sessions; preserving existing records"
                )
            }
            let coveredAutomaticIDs = SleepActualReconciliationEngine
                .coveredAutomaticIDs(
                    in: snapshot.actuals,
                    by: sleepSessions,
                    inside: span,
                    asOf: min(span.end, .now)
                )
            let reconciledActuals = SleepActualReconciliationEngine.applying(
                snapshot.actuals,
                sessions: sleepSessions,
                inside: span,
                asOf: min(span.end, .now)
            )
            if reconciledActuals != snapshot.actuals {
                snapshot.actuals = reconciledActuals
            }
            // 잠금 중 못 읽은 수면이 나중에 들어와도 그 밤의 자동 이동을 다시 판정한다(CAT1029A01).
            let sleepTravel = SleepTravelReconciliationEngine.reconciled(snapshot.travel, sessions: sleepSessions, inside: span)
            if sleepTravel != snapshot.travel { snapshot.travel = sleepTravel }
            // A previous manual correction can otherwise be reapplied by the
            // next persistence pass and turn the authoritative sleep window
            // back into an activity. Keep its time edit only when the record
            // was not covered by HealthKit sleep.
            for id in coveredAutomaticIDs {
                snapshot.settings.activityCorrections.removeValue(forKey: id)
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
            if HealthRefreshErrorPolicy.isProtectedDataUnavailable(error) {
                deferHealthRefreshUntilUnlock(
                    fields: healthFields.merging(["stage": "read"]) { _, new in new }
                        .merging(TaptionDiagnosticError.compactFields(for: error)) { _, new in new }
                )
                return
            }
            Self.integrationLogger.error(
                "HealthKit refresh failed: \(error.localizedDescription, privacy: .public)"
            )
            if HealthRefreshErrorPolicy.showsBanner(for: error, showErrors: showErrors) {
                userFacingError = AppLanguagePreference.text(
                    korean: "건강 데이터를 읽지 못했습니다. \(error.localizedDescription)",
                    english: "Could not read Health data. \(error.localizedDescription)"
                )
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

    private func deferHealthRefreshUntilUnlock(fields: [String: String]) {
        isHealthRefreshDeferredUntilUnlock = true
        TaptionPlanDiagnosticsLogger.shared.record(
            "health_refresh_deferred",
            level: .notice,
            fields: fields.merging(["reason": "protected_data_unavailable"]) { _, new in new }
        )
    }

    /// 잠금이 풀려 보호된 자료를 다시 읽을 수 있게 되면, 잠긴 동안 미룬 건강 갱신을 한 번 한다.
    func retryDeferredHealthRefreshIfNeeded() async {
        guard isHealthRefreshDeferredUntilUnlock, acceptsDataMutation(),
              settings.healthEnabled else { return }
        isHealthRefreshDeferredUntilUnlock = false
        activeDataMutationCount += 1
        defer { activeDataMutationCount -= 1 }
        TaptionPlanDiagnosticsLogger.shared.record("health_refresh_retry_after_unlock")
        await refreshHealthData(in: periodicHealthSpan, showErrors: false)
        logAutomaticRecordSummary()
        await persistDeviceLocalSnapshot()
    }

    func refreshAppUsageData(
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
            if let screenTimeError = error as? ScreenTimeUsageError {
                switch screenTimeError {
                case .dataAccessUnavailable, .dataAccessNotGranted:
                    appUsageAuthorizationState = .dataAccessUnavailable
                    snapshot.settings.permissions[.appUsage] = .unavailable
                default:
                    break
                }
            }
            if showErrors {
                userFacingError = AppLanguagePreference.text(
                    korean: "앱 사용시간을 읽지 못했습니다. \(error.localizedDescription)",
                    english: "Could not read app usage time. \(error.localizedDescription)"
                )
            }
            TaptionPlanDiagnosticsLogger.shared.record(
                "screen_time_refresh_failed",
                level: .error,
                fields: TaptionDiagnosticError.fields(for: error)
            )
        }
    }

    func handleObservedHealthChange() async {
        guard acceptsDataMutation() else { return }
        activeDataMutationCount += 1
        defer { activeDataMutationCount -= 1 }
        receiveSensorWake(.healthKitBackgroundDelivery)
        await bootstrap()
        guard acceptsDataMutation(), settings.healthEnabled else { return }
        await refreshHealthData(
            in: periodicHealthSpan,
            showErrors: false
        )
        logAutomaticRecordSummary()
        await persistDeviceLocalSnapshot()
    }

    func startForegroundHealthRefreshIfNeeded() {
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

    func configureHealthBackgroundDeliveryIfNeeded(
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
                "HealthKit background delivery enabled for available sample types"
            )
        } catch {
            Self.integrationLogger.error(
                "HealthKit background delivery failed: \(error.localizedDescription, privacy: .public)"
            )
            if showErrors {
                userFacingError = AppLanguagePreference.text(
                    korean: "건강 데이터 자동 갱신을 켜지 못했습니다. ",
                    english: "Could not turn on automatic Health data refresh. "
                ) + error.localizedDescription
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
}

/// 진단 기록기는 앱에 있어, 지운 수를 남기는 갱신 경로만 앱에 둔다(판정은 TaptionPlanStore).
extension SleepTravelReconciliationEngine {
    /// HealthKit 갱신 경로용. 지운 수를 진단에 남긴다.
    static func reconciled(
        _ travel: [TravelSegment],
        sessions: [SleepSession],
        inside span: TimeSpan
    ) -> [TravelSegment] {
        let kept = removingAutomaticTravel(travel, sessions: sessions, inside: span, asOf: min(span.end, .now))
        if kept.count != travel.count {
            TaptionPlanDiagnosticsLogger.shared.record(
                "sleep_travel_removed",
                fields: ["removed": String(travel.count - kept.count)]
            )
        }
        return kept
    }
}
