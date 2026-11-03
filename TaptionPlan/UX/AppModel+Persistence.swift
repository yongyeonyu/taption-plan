import Foundation
import TaptionPlanCore

extension AppModel {
    var visibleDataSpan: TimeSpan {
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

    var currentDeviceDataSpan: TimeSpan {
        TimelineAggregationEngine().interval(
            for: .day,
            containing: .now
        )
    }

    var startupHealthSpan: TimeSpan {
        SleepAnalysisEngine.overnightSpan(containing: .now)
    }

    var recentHealthSpan: TimeSpan {
        let now = Date.now
        let start = Calendar.autoupdatingCurrent.date(
            byAdding: .day,
            value: -31,
            to: Calendar.autoupdatingCurrent.startOfDay(for: now)
        ) ?? now.addingTimeInterval(-31 * 86_400)
        return TimeSpan(start: start, end: now)
    }

    var periodicHealthSpan: TimeSpan {
        let now = Date.now
        return TimeSpan(
            start: now.addingTimeInterval(
                -HealthRefreshPolicy.periodicLookback
            ),
            end: now
        )
    }

    var hasCurrentDataGeneration: Bool {
        dataDeletionGeneration
            == TaptionDataDeletionFence.currentGeneration()
    }

    func allowsRepositoryLoadAttempt() -> Bool {
        !isCommerceLocked
            && !isDeletingUserData
            && TaptionDataDeletionFence.allows(
                generation: dataDeletionGeneration
            )
    }

    func acceptsDataMutation(capturedAt: Date? = nil) -> Bool {
        !repositoryLoadFailed && !isStartupSnapshotPartial
            && allowsRepositoryLoadAttempt()
            && TaptionDataDeletionFence.allows(
                generation: dataDeletionGeneration,
                capturedAt: capturedAt
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

    func saveToRepository(
        _ value: TaptionDataSnapshot,
        expectedRevision: UInt64? = nil,
        requiresCurrentRevision: Bool = true,
        actualEdit: PlanActualEdit? = nil
    ) async throws -> Bool {
        guard hasCurrentDataGeneration else {
            throw RepositoryError.staleGeneration
        }
        if let expectedRevision, expectedRevision != snapshotRevision {
            return false
        }
        try Task.checkCancellation()
        let previous = repositoryWriteTask
        let generation = dataDeletionGeneration
        repositoryWriteSequence &+= 1
        let sequence = repositoryWriteSequence
        // A caller disappearing must not discard an accepted local write.
        let task = Task { @MainActor [self] in
            _ = await previous?.result
            guard generation == dataDeletionGeneration,
                  hasCurrentDataGeneration else {
                throw RepositoryError.staleGeneration
            }
            if requiresCurrentRevision,
               let expectedRevision, expectedRevision != snapshotRevision {
                return false
            }
            try await repository.save(value, actualEdit: actualEdit)
            return !requiresCurrentRevision || expectedRevision == nil
                || expectedRevision == snapshotRevision
        }
        repositoryWriteTask = task
        defer {
            if repositoryWriteSequence == sequence { repositoryWriteTask = nil }
        }
        return try await task.value
    }

    @discardableResult
    func persist(allowingDeletion: Bool = false, actualEdit: PlanActualEdit? = nil) async -> Bool {
        guard hasCurrentDataGeneration,
              allowingDeletion || !isDeletingUserData else { return false }
        if isSensorTimelineRefreshing { userEditedDuringSensorRefresh = true }
        activeDataMutationCount += 1
        defer { activeDataMutationCount -= 1 }
        guard !repositoryLoadFailed else {
            Self.integrationLogger.error(
                "Persistence blocked after repository load failure; preserving existing data"
            )
            return false
        }
        do {
            normalizeLocalRecordsIfNeeded()
            var value = snapshotForPersistence()
            value.updatedAt = .now
            var visibleValue = value
            visibleValue.memos = snapshot.memos
            let sourceRevision = snapshotRevision
            guard try await saveToRepository(
                value,
                expectedRevision: sourceRevision,
                requiresCurrentRevision: false,
                actualEdit: actualEdit
            ) else { return false }
            if snapshotRevision == sourceRevision {
                assignTimestampOnlySnapshot(visibleValue)
            }
            schedulePostSaveRefresh()
            publishWidgetPayload()
            await reconcileSensorCollectionLiveActivity(isForeground: isSceneActive)
            if permissionState(for: .notifications).isGranted,
               snapshot.settings.notificationsEnabled {
                do {
                    try await notificationScheduler.synchronize(
                        plans: snapshot.plans
                    )
                } catch {
                    userFacingError = AppLanguagePreference.text(
                        korean: "계획 알림을 갱신하지 못했습니다. \(error.localizedDescription)",
                        english: "Could not update plan notifications. \(error.localizedDescription)"
                    )
                }
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            userFacingError = AppLanguagePreference.text(
                korean: "변경 내용을 저장하지 못했습니다. \(error.localizedDescription)",
                english: "Could not save changes. \(error.localizedDescription)"
            )
            TaptionPlanDiagnosticsLogger.shared.record(
                "local_persistence_failed",
                level: .error,
                fields: ["error": String(describing: type(of: error))]
            )
            return false
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

    nonisolated static func cloudPortableSnapshot(
        _ source: TaptionDataSnapshot
    ) -> TaptionDataSnapshot {
        var value = PlanCloudSnapshotRecoveryPolicy.iCloudSafe(source)
        value.calendarEvents = []
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
        value.settings.transitBoardingDecisions = []
        value.settings.predictedRouteDecisions = []
        value.settings.movementCorrections = []
        value.settings.calendarTitleDetails = [:]
        value.settings.activityCorrections = [:]
        // 거절한 자리는 이 기기의 위치 기록에서만 나온 좌표다. 자주가는 곳
        // 자체와 달리 사용자가 적은 값이 아니므로 기기에 남긴다.
        value.settings.dismissedPlaceSuggestions = []
        return value
    }

    func mergeDeviceLocalData(
        cloud: TaptionDataSnapshot,
        local: TaptionDataSnapshot
    ) -> TaptionDataSnapshot {
        var value = cloud
        let cloudSleepSpans = TaptionActivityEngineAdapter
            .migratedConfirmedSleepSpans(
                existing: cloud.settings.confirmedSleepSpans,
                corrections: cloud.settings.activityCorrections,
                actuals: cloud.actuals
            )
        let localSleepSpans = TaptionActivityEngineAdapter
            .migratedConfirmedSleepSpans(
                existing: local.settings.confirmedSleepSpans,
                corrections: local.settings.activityCorrections,
                actuals: local.actuals
            )
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
        value.stickers = deviceRecords(
            local.stickers,
            recoveringMissingFrom: value.stickers,
            id: \.id
        ).sorted { $0.updatedAt < $1.updatedAt }
        value.calendarEvents = local.calendarEvents
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
        value.settings.gpsLoggingPreferences =
            local.settings.gpsLoggingPreferences
        value.settings.mapCategoryColors =
            local.settings.mapCategoryColors
        value.settings.mapUserActivityCategories =
            local.settings.mapUserActivityCategories
        value.settings.mapMemoDisplayFilter =
            local.settings.mapMemoDisplayFilter
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
        value.settings.transitBoardingDecisions =
            local.settings.transitBoardingDecisions
        value.settings.predictedRouteDecisions = local.settings.predictedRouteDecisions
        value.settings.movementCorrections =
            local.settings.movementCorrections
        value.settings.calendarTitleDetails =
            local.settings.calendarTitleDetails
        value.settings.activityCorrections =
            local.settings.activityCorrections
        value.settings.confirmedSleepSpans =
            AppFeatureSettings.normalizedConfirmedSleepSpans(
                cloudSleepSpans + localSleepSpans
            )
        value.settings.confirmedSleepSpans =
            TaptionActivityEngineAdapter.migratedConfirmedSleepSpans(
                existing: value.settings.confirmedSleepSpans,
                corrections: value.settings.activityCorrections,
                actuals: value.actuals
            )
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
        value.settings.weatherSidebarVisible = local.settings.weatherSidebarVisible
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
        value.actuals = TaptionActivityEngineAdapter.applyingConfirmedSleepSpans(
            value.settings.confirmedSleepSpans,
            to: value.actuals
        )
        // iCloud can still hand back placeholder plans written by an older
        // build on this or another device.
        MemoShellPlanMigration.apply(to: &value)
        return value
    }

    func deviceRecords<Element, ID: Hashable>(
        _ local: [Element],
        recoveringMissingFrom cloud: [Element],
        id: KeyPath<Element, ID>
    ) -> [Element] {
        var seen = Set(local.map { $0[keyPath: id] })
        return local + cloud.filter { seen.insert($0[keyPath: id]).inserted }
    }

    func preparedCloudMergedSnapshot(
        _ value: TaptionDataSnapshot,
        preservingUpdatedAt updatedAt: Date
    ) -> TaptionDataSnapshot {
        var content = value
        content.settings.confirmedSleepSpans =
            TaptionActivityEngineAdapter.migratedConfirmedSleepSpans(
                existing: content.settings.confirmedSleepSpans,
                corrections: content.settings.activityCorrections,
                actuals: content.actuals
            )
        content.actuals = TaptionActivityEngineAdapter.applyingConfirmedSleepSpans(
            content.settings.confirmedSleepSpans,
            to: content.actuals
        )
        content.updatedAt = updatedAt
        return content
    }

    func assignCommittedCloudSnapshot(
        _ content: TaptionDataSnapshot
    ) {
        guard content != snapshot else { return }
        snapshot = content
    }

    private func refreshReviewArchives(
        force: Bool,
        asOf: Date = .now
    ) async {
        let interval = max(
            60,
            snapshot.settings.gpsLoggingPreferences.interval
        )
        if !force, let lastReviewArchiveRefreshAt,
           lastReviewArchiveRefreshRevision == timelineRevision,
           asOf.timeIntervalSince(lastReviewArchiveRefreshAt) < interval {
            return
        }
        let source = snapshotForPersistence()
        let revision = timelineRevision
        let refreshTask = Task.detached(priority: .utility) {
            try ReviewReportArchiveEngine.refreshed(
                snapshot: source,
                asOf: asOf
            )
        }
        let reports: [YearlyReviewArchive]
        do {
            reports = try await withTaskCancellationHandler {
                try await refreshTask.value
            } onCancel: {
                refreshTask.cancel()
            }
        } catch is CancellationError {
            return
        } catch {
            TaptionPlanDiagnosticsLogger.shared.record(
                "review_archive_refresh_failed",
                level: .error,
                fields: ["error": String(describing: type(of: error))]
            )
            return
        }
        guard !Task.isCancelled, acceptsDataMutation(),
              revision == timelineRevision else { return }
        lastReviewArchiveRefreshAt = asOf
        lastReviewArchiveRefreshRevision = revision
        guard reports != snapshot.yearlyReports else { return }
        snapshot.yearlyReports = reports
    }

    func schedulePostSaveRefresh() {
        postSaveRefreshRequested = true
        guard isSceneActive, postSaveRefreshTask == nil else { return }
        postSaveRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.postSaveRefreshTask = nil
                if self.postSaveRefreshRequested, self.isSceneActive,
                   self.acceptsDataMutation() {
                    self.schedulePostSaveRefresh()
                }
            }
            while self.postSaveRefreshRequested, self.isSceneActive,
                  self.acceptsDataMutation(), !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1.5)) }
                catch { return }
                guard self.isSceneActive, !Task.isCancelled else { return }
                self.postSaveRefreshRequested = false
                await self.refreshReviewArchives(force: false)
                guard self.isSceneActive, !Task.isCancelled else { return }
                await self.persistDeviceLocalSnapshot()
                guard self.isSceneActive, !Task.isCancelled else { return }
                await self.synchronizeCloud(showErrors: false)
            }
        }
    }

    func invalidateReviewArchives(
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

    @discardableResult
    func persistDeviceLocalSnapshot(force: Bool = false) async -> Bool {
        guard acceptsDataMutation() else { return false }
        guard !isSensorTimelineRefreshing else {
            scheduleTrailingDeviceLocalPersist()
            return false
        }
        activeDataMutationCount += 1
        defer { activeDataMutationCount -= 1 }
        guard !repositoryLoadFailed else {
            Self.integrationLogger.error(
                "Device persistence blocked after repository load failure; preserving existing data"
            )
            return false
        }
        // Location and HealthKit callbacks can converge at the same moment.
        // Coalesce those device-only commits so one sensor tick does not
        // trigger duplicate disk writes, widget serialization and timeline
        // reload requests. The coalesced change must still reach disk, so a
        // trailing write is scheduled instead of being dropped.
        if !force, repositoryWriteTask != nil {
            scheduleTrailingDeviceLocalPersist()
            return false
        }
        if !force, let lastDeviceSnapshotPersistAt,
           Date.now.timeIntervalSince(lastDeviceSnapshotPersistAt) < 1.5 {
            scheduleTrailingDeviceLocalPersist()
            return false
        }
        pendingDeviceLocalPersistTask?.cancel()
        pendingDeviceLocalPersistTask = nil
        do {
            normalizeLocalRecordsIfNeeded()
            var value = snapshotForPersistence()
            value.updatedAt = .now
            var visibleValue = value
            visibleValue.memos = snapshot.memos
            let sourceRevision = snapshotRevision
            guard try await saveToRepository(
                value,
                expectedRevision: sourceRevision,
                requiresCurrentRevision: false
            ) else { return false }
            if snapshotRevision == sourceRevision {
                assignTimestampOnlySnapshot(visibleValue)
            }
            lastDeviceSnapshotPersistAt = .now
            publishWidgetPayload()
            return true
        } catch is CancellationError {
            if isSceneActive { scheduleTrailingDeviceLocalPersist() }
            return false
        } catch {
            userFacingError = AppModelMessage
                .sensorSaveFailed(error.localizedDescription).text()
            return false
        }
    }

    private func normalizeLocalRecordsIfNeeded() {
        guard needsLocalRecordNormalization else { return }
        if snapshot.actuals.contains(where: {
            $0.source.usesAutomaticClassification && !$0.isClassificationLocked
        }) {
            snapshot.actuals = ActivityClassificationLockEngine
                .lockingAutomaticClassifications(snapshot.actuals)
        }
        if snapshot.travel.contains(where: { !$0.isClassificationLocked }) {
            snapshot.travel = snapshot.travel.map { segment in
                var value = segment
                value.isClassificationLocked = true
                return value
            }
        }
        applyStoredActivityCorrections()
        needsLocalRecordNormalization = false
    }

    func snapshotForPersistence() -> TaptionDataSnapshot {
        var value = snapshot
        value.memos.removeAll { pendingMapMemoIDs.contains($0.id) }
        return value
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
