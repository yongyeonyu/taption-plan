import Foundation
import TaptionPlanCore

extension AppModel {
    nonisolated static func preparedLoadedSnapshot(
        _ source: TaptionDataSnapshot,
        cancellationCheck: () throws -> Void
    ) rethrows -> TaptionDataSnapshot {
        try cancellationCheck()
        var loaded = source
        loaded.plans = try Self.deduplicatedGeneratedRepeatPlans(
            loaded.plans,
            cancellationCheck: cancellationCheck
        )
        try cancellationCheck()
        if loaded.categories.isEmpty {
            loaded.categories = CategoryCatalog.builtIn
        } else {
            for (index, category) in CategoryCatalog.builtIn.enumerated()
            where !loaded.categories.contains(where: {
                $0.id == category.id
            }) {
                if index.isMultiple(of: 32) { try cancellationCheck() }
                loaded.categories.append(category)
            }
        }
        try cancellationCheck()
        Self.migrateLegacyFloorCalibration(in: &loaded)
        try MemoShellPlanMigration.apply(
            to: &loaded,
            cancellationCheck: cancellationCheck
        )
        try Self.normalizeRecordRelationships(
            in: &loaded,
            cancellationCheck: cancellationCheck
        )
        try cancellationCheck()
        loaded.actuals = ActualRecordSuppressionEngine.visibleRecords(
            from: loaded.actuals,
            suppressedIDs: loaded.settings.suppressedActualIDs
        )
        try cancellationCheck()
        loaded.settings.confirmedSleepSpans =
            TaptionActivityEngineAdapter.migratedConfirmedSleepSpans(
                existing: loaded.settings.confirmedSleepSpans,
                corrections: loaded.settings.activityCorrections,
                actuals: loaded.actuals
            )
        try cancellationCheck()
        loaded.actuals = ActivityCorrectionEngine.applying(
            loaded.settings.activityCorrections,
            to: loaded.actuals
        )
        try cancellationCheck()
        loaded.actuals = TaptionActivityEngineAdapter.applyingConfirmedSleepSpans(
            loaded.settings.confirmedSleepSpans,
            to: loaded.actuals
        )
        try cancellationCheck()
        loaded.weather = WeatherTimelineEngine.coalesced(loaded.weather)
        try cancellationCheck()
        return loaded
    }

    nonisolated static func preparedLoadedSnapshotInBackground(
        _ source: TaptionDataSnapshot,
        lockingAutomaticClassifications: Bool = false,
        priority: TaskPriority? = .utility
    ) async throws -> TaptionDataSnapshot {
        let worker = Task.detached(priority: priority) {
            var loaded = source
            if lockingAutomaticClassifications {
                loaded.actuals = try ActivityClassificationLockEngine
                    .lockingAutomaticClassifications(
                        loaded.actuals,
                        cancellationCheck: { try Task.checkCancellation() }
                    )
                var travel: [TravelSegment] = []
                travel.reserveCapacity(loaded.travel.count)
                for (index, segment) in loaded.travel.enumerated() {
                    if index.isMultiple(of: 256) {
                        try Task.checkCancellation()
                    }
                    var value = segment
                    value.isClassificationLocked = true
                    travel.append(value)
                }
                loaded.travel = travel
            }
            loaded = try preparedLoadedSnapshot(
                loaded,
                cancellationCheck: { try Task.checkCancellation() }
            )
            loaded.actuals = try PlanActualStorage.reusingUnchangedStorage(loaded.actuals,
                previous: source.actuals, cancellationCheck: { try Task.checkCancellation() })
            return loaded
        }
        return try await withTaskCancellationHandler(operation: {
            try await worker.value
        }, onCancel: {
            worker.cancel()
        })
    }

    /// A repeat rule is materialized as one child plan per matching day. If
    /// an older build saved the same generated child twice, keep the first
    /// record and remove only the exact generated duplicate. User-created
    /// overlapping plans remain untouched and continue to be shown separately.
    private nonisolated static func deduplicatedGeneratedRepeatPlans(
        _ plans: [PlanRecord],
        cancellationCheck: () throws -> Void
    ) rethrows -> [PlanRecord] {
        try cancellationCheck()
        var seen = Set<String>()
        var deduplicated: [PlanRecord] = []
        deduplicated.reserveCapacity(plans.count)
        for (index, plan) in plans.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            guard plan.origin == .repeatRule else {
                deduplicated.append(plan)
                continue
            }
            let key = [
                plan.parentID?.uuidString ?? "-",
                plan.categoryID,
                String(Int(plan.span.start.timeIntervalSinceReferenceDate.rounded())),
                String(Int(plan.span.end.timeIntervalSinceReferenceDate.rounded())),
            ].joined(separator: "|")
            if seen.insert(key).inserted { deduplicated.append(plan) }
        }
        try cancellationCheck()
        return deduplicated
    }

    /// Converts legacy action/routine pointers into the canonical relation
    /// rules used by the timeline graph. Repeat segments are projections of a
    /// root routine and therefore never remain as direct automatic links.
    private nonisolated static func normalizeRecordRelationships(
        in snapshot: inout TaptionDataSnapshot,
        cancellationCheck: () throws -> Void
    ) rethrows {
        try cancellationCheck()
        var plansByID: [UUID: PlanRecord] = [:]
        plansByID.reserveCapacity(snapshot.plans.count)
        for (index, plan) in snapshot.plans.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            if plansByID[plan.id] == nil { plansByID[plan.id] = plan }
        }

        func rootRoutineID(for id: UUID) throws -> UUID? {
            var currentID: UUID? = id
            var visited = Set<UUID>()
            var depth = 0
            while let current = currentID,
                  visited.insert(current).inserted,
                  let plan = plansByID[current] {
                if depth.isMultiple(of: 64) { try cancellationCheck() }
                if GoalRecordPolicy.isGoal(plan) { return plan.id }
                currentID = plan.parentID
                depth += 1
            }
            return nil
        }

        for index in snapshot.actuals.indices {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            var actual = snapshot.actuals[index]
            let linkedPlan = actual.planID.flatMap { plansByID[$0] }
            let linkedRoutine = try actual.routineID.map(rootRoutineID) ?? nil
            let resolvedRoutine: UUID?
            if let linkedRoutine {
                resolvedRoutine = linkedRoutine
            } else if let linkedPlan {
                resolvedRoutine = try rootRoutineID(for: linkedPlan.id)
            } else {
                resolvedRoutine = nil
            }
            if AutomaticRecordTimelineEngine.linksOnlyToRoutine(actual) {
                actual.routineID = resolvedRoutine
                actual.planID = nil
            } else if let linkedPlan {
                if linkedPlan.origin == .repeatRule
                    || GoalRecordPolicy.isGoal(linkedPlan) {
                    actual.routineID = resolvedRoutine
                    actual.planID = nil
                } else {
                    actual.planID = linkedPlan.id
                    actual.routineID = resolvedRoutine
                }
            } else {
                actual.planID = nil
                actual.routineID = linkedRoutine
            }
            snapshot.actuals[index] = actual
        }

        func canonicalNodeID(_ raw: String) throws -> String? {
            let prefixes = ["routine.", "action."]
            guard let prefix = prefixes.first(where: { raw.hasPrefix($0) }) else {
                return raw.hasPrefix("automatic.") ? raw : nil
            }
            guard let id = UUID(uuidString: String(raw.dropFirst(prefix.count))),
                  let plan = plansByID[id] else {
                return nil
            }
            if GoalRecordPolicy.isGoal(plan) || plan.origin == .repeatRule,
               let root = try rootRoutineID(for: plan.id) {
                return "routine.\(root.uuidString)"
            }
            return "action.\(id.uuidString)"
        }

        let orderedLinks = try RouteTimelineCancellableSort.sorted(
            snapshot.recordLinks,
            by: { $0.createdAt < $1.createdAt },
            cancellationCheck: cancellationCheck
        )
        var seen = Set<String>()
        var normalizedLinks: [RecordLink] = []
        normalizedLinks.reserveCapacity(orderedLinks.count)
        for (index, link) in orderedLinks.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            guard let from = try canonicalNodeID(link.fromNodeID),
                  let to = try canonicalNodeID(link.toNodeID),
                  from != to else { continue }
            let key = "\(from)->\(to)"
            guard seen.insert(key).inserted else { continue }
            var normalized = link
            normalized.fromNodeID = from
            normalized.toNodeID = to
            normalizedLinks.append(normalized)
        }
        try cancellationCheck()
        snapshot.recordLinks = normalizedLinks
    }

    func bootstrap() async {
        await bootstrapLocalSnapshot()
        migrateLegacyStickersOnce()
        scheduleBootstrapPreparation()
        await waitForBootstrapPreparation()
        #if DEBUG
        await exportRawOnLaunchIfRequested()
        #endif
    }

    /// 예전 스티커 기록을 메모 하나로 한 번만 합친다. 스티커의 종류·색·시간·위치는 그대로 옮긴다.
    private func migrateLegacyStickersOnce() {
        let flagKey = "legacyStickersMergedIntoMemos.v1"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: flagKey), !snapshot.stickers.isEmpty else {
            defaults.set(true, forKey: flagKey)
            return
        }
        guard acceptsDataMutation() else { return }
        for sticker in snapshot.stickers {
            let body = [sticker.title, sticker.memo ?? ""]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            guard !body.isEmpty else { continue }
            let memo = ActionMemo(
                planID: nil,
                categoryID: MemoTimelineEngine.categoryID,
                occurredAt: sticker.occurredAt,
                mapPoint: sticker.point,
                isTimeless: false,
                kind: .idea,
                text: body,
                createdAt: sticker.createdAt,
                updatedAt: sticker.updatedAt
            )
            var merged = memo
            merged.stickerSymbol = sticker.systemImage
            merged.stickerColorHex = sticker.colorHex
            snapshot.memos.append(merged)
        }
        snapshot.stickers.removeAll()
        defaults.set(true, forKey: flagKey)
        Task { await persist() }
    }

    func prepareLocalDataForDisplay() async {
        await bootstrapLocalSnapshot()
    }

    func prepareStartupSettings() async {
        guard !isBootstrapped, !hasPreparedStartupSettings,
              allowsRepositoryLoadAttempt() else { return }
        if let startupSettingsTask { await startupSettingsTask.value; return }
        let generation = dataDeletionGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { startupSettingsTask = nil }
            do {
                guard let source = try await repository.loadStartupSnapshot() else { return }
                try Task.checkCancellation()
                guard generation == dataDeletionGeneration,
                      !isBootstrapped, allowsRepositoryLoadAttempt() else { return }
                snapshot = source
                selectedScale = TimeScale(timelineLevel: source.settings.startScale).scheduleEquivalent
                selectedCatCoat = CatCoat(catStyle: source.settings.catStyle)
                isStartupSnapshotPartial = true
                hasPreparedStartupSettings = true
                TaptionPlanDiagnosticsLogger.shared.record("startup_settings_ready")
            } catch {
                TaptionPlanDiagnosticsLogger.shared.record("startup_settings_deferred",
                    fields: ["error": String(describing: type(of: error))])
            }
        }
        startupSettingsTask = task
        await task.value
    }

    func bootstrapLocalSnapshot() async {
        guard allowsRepositoryLoadAttempt() else { return }
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }
        let isRecoveringFromLoadFailure = repositoryLoadFailed
        guard !isBootstrapped || isRecoveringFromLoadFailure else { return }

        let logger = TaptionPlanDiagnosticsLogger.shared
        let operation = logger.beginOperation("bootstrap_local_snapshot")
        logger.record("bootstrap_started")
        let task = Task { [weak self] in
            guard let self else { return }
            let generation = dataDeletionGeneration
            defer {
                if generation == dataDeletionGeneration { bootstrapTask = nil }
            }
            do {
                let source = try await repository.load()
                try Task.checkCancellation()
                guard generation == dataDeletionGeneration,
                      allowsRepositoryLoadAttempt() else { return }
                repositoryLoadFailed = false
                if isRecoveringFromLoadFailure,
                   AppModelMessage.isDataLoadFailure(userFacingError) {
                    userFacingError = nil
                }
                // Publish local data before normalization, sensors or cloud work.
                isStartupSnapshotPartial = false
                snapshot = source
                selectedScale = TimeScale(
                    timelineLevel: source.settings.startScale
                ).scheduleEquivalent
                selectedCatCoat = CatCoat(catStyle: source.settings.catStyle)
                needsBootstrapPreparation = true
                isBootstrapped = true
                if hasPreparedStartupSettings && isSceneActive {
                    updateForegroundLiveLocationTracking()
                    scheduleWatchHealthRefresh()
                }
                logger.record(
                    "bootstrap_local_snapshot_loaded",
                    fields: [
                        "plans": String(source.plans.count),
                        "actuals": String(source.actuals.count),
                        "places": String(source.places.count),
                    ]
                )
                logger.finishOperation(operation, outcome: "success")
                scheduleBootstrapPreparation()
            } catch is CancellationError {
                logger.finishOperation(operation, outcome: "cancelled")
                return
            } catch {
                guard allowsRepositoryLoadAttempt() else { return }
                isStartupSnapshotPartial = false
                hasPreparedStartupSettings = false
                if !isRecoveringFromLoadFailure {
                    var fallback = TaptionDataSnapshot.empty
                    fallback.categories = CategoryCatalog.builtIn
                    snapshot = fallback
                }
                repositoryLoadFailed = true
                needsBootstrapPreparation = false
                isBootstrapped = true
                userFacingError = AppModelMessage
                    .dataLoadFailed(error.localizedDescription).text()
                logger.finishOperation(operation, outcome: "failure", error: error)
                logger.record(
                    "bootstrap_failed",
                    level: .error,
                    fields: ["error": String(describing: type(of: error))]
                )
            }
        }
        bootstrapTask = task
        await task.value
    }

    func scheduleBootstrapPreparation() {
        guard needsBootstrapPreparation,
              acceptsDataMutation(), bootstrapPreparationTask == nil else {
            return
        }
        bootstrapPreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let generation = dataDeletionGeneration
            let logger = TaptionPlanDiagnosticsLogger.shared
            let operation = logger.beginOperation("bootstrap_preparation")
            var outcome = "cancelled"
            defer {
                if generation == dataDeletionGeneration {
                    bootstrapPreparationTask = nil
                }
                logger.finishOperation(operation, outcome: outcome)
            }
            // Let the initial scene continue before preparing the full record graph.
            await Task.yield()
            guard !Task.isCancelled, self.acceptsDataMutation() else {
                return
            }
            var source = snapshot
            let originalConfirmedSleepSpans = source.settings.confirmedSleepSpans
            let originalActuals = source.actuals
            let originalTravel = source.travel
            do {
                while true {
                    let revision = snapshotRevision
                    // 준비가 몇 번 돌았는지 남긴다. 도중에 개정이 올라오면 처음부터 다시 한다.
                    logger.record("bootstrap_preparation_pass", fields: ["revision": String(revision)])
                    source = try await Self.preparedLoadedSnapshotInBackground(
                        source,
                        lockingAutomaticClassifications: true
                    )
                    guard !Task.isCancelled,
                          generation == dataDeletionGeneration,
                          acceptsDataMutation() else { return }
                    if revision == snapshotRevision { break }
                    source = snapshot
                }
            } catch {
                return
            }
            snapshot = source
            needsLocalRecordNormalization = false
            if source.settings.confirmedSleepSpans != originalConfirmedSleepSpans
                || source.actuals != originalActuals
                || source.travel != originalTravel {
                // 화면이 이미 백그라운드로 내려간 뒤에는 새 쓰기를 시작하지 않는다. 서스펜드 중
                // SQLite 잠금을 쥐면 시스템이 앱을 종료한다(0xdead10cc). 다음 활성화에서 이어서 저장한다.
                guard !isSceneInBackground else { return }
                _ = await persist()
            }
            guard !Task.isCancelled,
                  generation == dataDeletionGeneration,
                  acceptsDataMutation() else { return }
            needsBootstrapPreparation = false
            if source.updatedAt == .distantPast, source.plans.isEmpty {
                openInitialSetup()
            }
            publishWatchPayload()
            await applyPendingWidgetCommands(repositoryAlreadyLoaded: true)
            outcome = "success"
        }
    }

    func waitForBootstrapPreparation() async {
        await bootstrapPreparationTask?.value
    }

    func reloadSnapshotAfterStoreChange() async throws {
        let loaded = try await repository.load()
        let prepared = try await Self.preparedLoadedSnapshotInBackground(loaded)
        snapshot = prepared
        selectedScale = TimeScale(timelineLevel: prepared.settings.startScale).scheduleEquivalent
        selectedCatCoat = CatCoat(catStyle: prepared.settings.catStyle)
        liveMergeCacheKey = nil
        liveMergeCacheValue = []
        sensorRefreshFingerprints.removeAll()
        await dayLoadCoordinator?.invalidateAll()
        MapHomeDayCacheEviction.removeAll()
        backupRestoreRevision &+= 1
        publishWidgetPayload()
        publishWatchPayload()
    }

    func resetSettingsToDefaults() async {
        await bootstrap()
        await waitForBootstrapPreparation()
        guard !repositoryLoadFailed else { return }

        await sensorService?.stopCollectionAndWait()
        sensorBackgroundCoordinator.cancel()
        syncSensorBackgroundState()
        isSensorCollecting = false
        await notificationScheduler.cancelAllPlanReminders()

        let defaults = AppFeatureSettings.defaults
        var reset = snapshot
        reset.settings = defaults
        snapshot = reset
        selectedScale = TimeScale(
            timelineLevel: defaults.startScale
        ).scheduleEquivalent
        selectedCatCoat = CatCoat(catStyle: defaults.catStyle)
        await persist()

        guard let persisted = try? await repository.load(),
              let reloaded = try? await Self
                .preparedLoadedSnapshotInBackground(persisted) else { return }
        snapshot = reloaded
        selectedScale = TimeScale(
            timelineLevel: reloaded.settings.startScale
        ).scheduleEquivalent
        selectedCatCoat = CatCoat(catStyle: reloaded.settings.catStyle)
        publishWatchPayload()
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
