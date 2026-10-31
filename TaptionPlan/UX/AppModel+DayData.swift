import Foundation
import TaptionPlanCore

extension AppModel {
    func watchSensorTimelineData(
        in span: TimeSpan
    ) async -> WatchSensorTimelineData {
        var summaries = [String: TaptionWatchSensorSummary]()
        var chunks = [UUID: TaptionWatchAccelerationChunk]()

        if let dayDatabase {
            async let databaseSummaries = try? dayDatabase.watchSummaries(
                in: span
            )
            async let databaseChunks = try? dayDatabase.watchAccelerationChunks(
                in: span
            )
            for summary in (await databaseSummaries) ?? [] {
                summaries["\(summary.sessionID.uuidString):\(summary.sequence)"] =
                    summary
            }
            for chunk in (await databaseChunks) ?? [] {
                chunks[chunk.id] = chunk
            }
        }

        let sourceSummaries = Array(summaries.values)
        let sourceChunks = Array(chunks.values)
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let orderedSummaries = try RouteTimelineCancellableSort.sorted(sourceSummaries,
                by: { $0.startedAt != $1.startedAt ? $0.startedAt < $1.startedAt : $0.sequence < $1.sequence },
                cancellationCheck: { try Task.checkCancellation() })
            let orderedChunks = try RouteTimelineCancellableSort.sorted(sourceChunks,
                by: { $0.startedAt != $1.startedAt ? $0.startedAt < $1.startedAt : $0.sequence < $1.sequence },
                cancellationCheck: { try Task.checkCancellation() })
            let replayed = WatchActivityRawReplayEngine.replaying(summaries: orderedSummaries, chunks: orderedChunks)
            try Task.checkCancellation()
            return WatchSensorTimelineData(summaries: replayed, accelerationChunks: orderedChunks)
        }
        guard let prepared = try? await withTaskCancellationHandler(operation: { try await worker.value },
            onCancel: { worker.cancel() }) else {
            return WatchSensorTimelineData(summaries: [], accelerationChunks: [])
        }
        let replayed = prepared.summaries
        let orderedChunks = prepared.accelerationChunks
        let replayedCount = replayed.filter {
            $0.behaviorModelVersion
                == WatchActivityRawReplayEngine.modelVersion
        }.count
        TaptionPlanDiagnosticsLogger.shared.record(
            "watch_day_raw_loaded",
            fields: [
                "span_start": String(span.start.timeIntervalSince1970),
                "span_end": String(span.end.timeIntervalSince1970),
                "summaries": String(replayed.count),
                "chunks": String(orderedChunks.count),
                "samples": String(orderedChunks.reduce(0) { $0 + $1.samples.count }),
                "replayed": String(replayedCount),
            ]
        )
        return WatchSensorTimelineData(
            summaries: replayed,
            accelerationChunks: orderedChunks
        )
    }

    func sensorReadingsLoadResult(
        in span: TimeSpan
    ) async -> SensorReadingsLoadResult {
        async let watchDataTask = watchSensorTimelineData(in: span)
        let archived: [SensorReading]
        let isComplete: Bool
        if let sensorService {
            do {
                let result = try await sensorService
                    .archivedRouteReadingsLoadResult(
                    in: span
                )
                archived = result.readings
                isComplete = result.isComplete
            } catch {
                let cancellationReason = Task.isCancelled ? "caller_task_cancelled"
                    : !hasCurrentDataGeneration ? "data_generation_changed" : "archive_read_failed"
                TaptionPlanDiagnosticsLogger.shared.record(
                    "route_readings_load_failed",
                    level: .error,
                    fields: [
                        "error": String(describing: type(of: error)),
                        "reason": cancellationReason,
                        "start": String(span.start.timeIntervalSince1970),
                        "end": String(span.end.timeIntervalSince1970),
                    ]
                )
                archived = []
                isComplete = false
            }
        } else {
            archived = []
            isComplete = false
        }
        let watchData = await watchDataTask
        let photoReadings = photoBackfillReadings(in: span, existingReadings: archived)
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let readings = try RouteTimelineCancellableSort.sorted(
                (archived + photoReadings).filter { RouteTimelineTimestamp.isValid($0.timestamp) },
                by: { $0.timestamp < $1.timestamp }, cancellationCheck: { try Task.checkCancellation() })
            return SensorReadingsLoadResult(readings: readings, isComplete: isComplete,
                watchSummaries: watchData.summaries, watchAccelerationChunks: watchData.accelerationChunks)
        }
        return (try? await withTaskCancellationHandler(operation: { try await worker.value },
            onCancel: { worker.cancel() })) ?? SensorReadingsLoadResult(readings: [], isComplete: false)
    }

    /// Loads the WBS-style day snapshot: one source snapshot plus one bounded
    /// sensor read. Every consumer receives derived arrays from that captured
    /// value, so an async load cannot mix two revisions or rewrite raw data.
    func planDayDataSnapshot(
        for date: Date,
        forceReload: Bool = true,
        refreshRawReadings: Bool = false
    ) async -> PlanDayDataSnapshot {
        let empty = {
            PlanDayDataSnapshot.make(
                date: date,
                sourceRevision: 0,
                source: .empty,
                sensorResult: SensorReadingsLoadResult(
                    readings: [],
                    isComplete: false
                )
            )
        }
        guard acceptsDataMutation() else { return empty() }
        activeDataMutationCount += 1
        defer { activeDataMutationCount -= 1 }
        if forceReload {
            await refreshSensorTimeline(containing: date)
            guard acceptsDataMutation() else { return empty() }
        }
        let sourceRevision = dayProjectionRevision
        let source = await indexedDaySource(snapshot, for: date)
        if let dayLoadCoordinator {
            let fingerprint = await cachedDayFingerprint(for: date, source: source, revision: sourceRevision)
            let loaded = await dayLoadCoordinator.load(
                day: date,
                source: source,
                sourceRevision: sourceRevision,
                sourceFingerprint: fingerprint,
                sensorLoader: { [weak self] day in
                    guard let self else {
                        return SensorReadingsLoadResult(
                            readings: [],
                            isComplete: false
                        )
                    }
                    return await self.sensorReadingsLoadResult(
                        in: self.daySpan(containing: day)
                    )
                },
                forceReload: forceReload || refreshRawReadings
            )
            return acceptsDataMutation() && PlanDayDataSnapshot.keepsLoadedSnapshot(
                loaded, currentRevision: dayProjectionRevision) ? loaded : empty()
        }
        let result = await sensorReadingsLoadResult(
            in: daySpan(containing: date)
        )
        guard acceptsDataMutation() else { return empty() }
        let made = PlanDayDataSnapshot.make(date: date, sourceRevision: sourceRevision,
            source: source, sensorResult: result)
        return PlanDayDataSnapshot.keepsLoadedSnapshot(made, currentRevision: dayProjectionRevision)
            ? made : empty()
    }

    func rebasePlanDayDataSnapshot(
        from previous: PlanDayDataSnapshot,
        for date: Date
    ) async -> PlanDayDataSnapshot? {
        guard acceptsDataMutation() else { return nil }
        let deletionGeneration = dataDeletionGeneration
        let sourceRevision = dayProjectionRevision
        let source = await indexedDaySource(snapshot, for: date)
        let worker = Task.detached(priority: .utility) {
            try PlanDayDataSnapshot.rebase(
                from: previous,
                date: date,
                sourceRevision: sourceRevision,
                source: source,
                cancellationCheck: { try Task.checkCancellation() }
            )
        }
        do {
            let rebased = try await withTaskCancellationHandler(
                operation: { try await worker.value },
                onCancel: { worker.cancel() }
            )
            guard !Task.isCancelled,
                  deletionGeneration == dataDeletionGeneration,
                  sourceRevision == dayProjectionRevision, acceptsDataMutation() else { return nil }
            return rebased
        } catch {
            worker.cancel()
            return nil
        }
    }

    func planDaySourceSnapshot(for date: Date, reusing previous: PlanDayDataSnapshot?) async -> PlanDayDataSnapshot? {
        guard acceptsDataMutation() else { return nil }
        let generation = dataDeletionGeneration
        let revision = dayProjectionRevision
        let source = await indexedDaySource(snapshot, for: date)
        let worker = Task.detached(priority: .utility) {
            if let previous, Calendar.autoupdatingCurrent.isDate(previous.day, inSameDayAs: date) {
                return try PlanDayDataSnapshot.rebase(from: previous, date: date,
                    sourceRevision: revision, source: source,
                    cancellationCheck: { try Task.checkCancellation() })
            }
            return try PlanDayDataSnapshot.make(date: date, sourceRevision: revision,
                source: source, sensorResult: SensorReadingsLoadResult(readings: [], isComplete: false),
                cancellationCheck: { try Task.checkCancellation() })
        }
        let value = try? await withTaskCancellationHandler(operation: { try await worker.value },
            onCancel: { worker.cancel() })
        guard !Task.isCancelled, generation == dataDeletionGeneration,
              revision == dayProjectionRevision, acceptsDataMutation() else { return nil }
        return value
    }

    func startupDayDataPreview(for date: Date) async -> PlanDayDataSnapshot? {
        guard hasPreparedStartupSettings, !isBootstrapped, !isAppLocked,
              allowsRepositoryLoadAttempt(), let dayLoadCoordinator else { return nil }
        let generation = dataDeletionGeneration
        let value = await dayLoadCoordinator.cachedSnapshot(day: date, source: snapshot,
            sourceRevision: dayProjectionRevision)
        guard generation == dataDeletionGeneration, !isAppLocked,
              allowsRepositoryLoadAttempt() else { return nil }
        return value
    }

    // MARK: 확정한 하루(지나간 날은 다시 계산하지 않는다)

    /// 확정한 하루 요약. 없으면 nil이고, 그때는 지금처럼 원본에서 계산한다.
    func sealedDay(for day: Date) -> TaptionSealedDay? {
        sealedDays[Calendar.autoupdatingCurrent.startOfDay(for: day)]
    }

    /// 이 날을 다시 계산해도 되는지. 확정한 지나간 날은 원본이 바뀌지 않는 한 다시 계산하지 않는다.
    func allowsRecalculation(of day: Date, force: Bool = false) -> Bool {
        PlanDayRecalculationPolicy.allowsRecalculation(
            day: day,
            now: .now,
            isSealed: sealedDay(for: day) != nil,
            force: force
        )
    }

    /// 확정 요약을 저장소에서 읽어 온다. 1분에 한 번만 읽는다(장면이 자주 활성화된다).
    func reloadSealedDaysIfNeeded(force: Bool = false) async {
        guard let daySealStore else { return }
        if !force, let loadedAt = sealedDaysLoadedAt,
           Date().timeIntervalSince(loadedAt) < 60 { return }
        do {
            let days = try await daySealStore.sealedDays()
            let calendar = Calendar.autoupdatingCurrent
            var map: [Date: TaptionSealedDay] = [:]
            map.reserveCapacity(days.count)
            for day in days {
                map[calendar.startOfDay(for: day.dayStart)] = day
            }
            sealedDays = map
            sealedDaysLoadedAt = .now
            TaptionPlanDiagnosticsLogger.shared.record(
                "sealed_days_loaded",
                fields: ["days": String(map.count)]
            )
        } catch {
            TaptionPlanDiagnosticsLogger.shared.record(
                "sealed_days_load_failed",
                level: .error,
                fields: ["error": String(describing: type(of: error))]
            )
        }
    }

    /// 지나간 날 중 아직 확정하지 않은 날을 확정한다. 최근 `limit`일만 본다(오래된 날은 열 때 확정한다).
    func sealSettledDays(limit: Int = 5) async {
        guard daySealStore != nil, !isSealingSettledDays, acceptsDataMutation() else { return }
        isSealingSettledDays = true
        defer { isSealingSettledDays = false }
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: .now)
        for offset in 1...max(1, limit) {
            guard !Task.isCancelled, acceptsDataMutation() else { return }
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            if sealedDays[day] != nil { continue }
            // 캐시에 없는 날은 건너뛴다. 확정은 하루치 원본을 읽으므로, 앱을 열 때마다 여러 날을
            // 읽으면 시작이 느려진다. 어제는 늘 확정하고, 그 이전은 지도가 미리 읽어 둔 날만 확정한다.
            if offset > 1, await cachedPlanDayDataSnapshot(for: day) == nil { continue }
            await sealDay(day)
        }
    }

    /// 하루를 확정한다. 이미 같은 원본으로 확정돼 있으면 아무것도 하지 않는다.
    func sealDay(_ day: Date, now: Date = .now) async {
        guard let daySealStore, acceptsDataMutation() else { return }
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: day)
        guard PlanDayRecalculationPolicy.isSettled(start, now: now, calendar: calendar) else { return }
        // 확정에는 하루치 원본이 필요하다. 캐시에 있으면 그대로 쓰고, 없으면 한 번만 읽는다.
        let snapshot = await planDayDataSnapshot(for: start, forceReload: false)
        guard PlanDayRecalculationPolicy.canSeal(
            day: start, now: now, isComplete: snapshot.isComplete, calendar: calendar
        ) else { return }
        guard let digest = sealedDigest(from: snapshot, now: now) else { return }
        if let existing = sealedDays[start],
           existing.version == digest.version,
           existing.sourceFingerprint == digest.sourceFingerprint {
            return
        }
        do {
            try await daySealStore.upsertSealedDays([digest])
            sealedDays[start] = digest
            TaptionPlanDiagnosticsLogger.shared.record(
                "day_sealed",
                fields: [
                    "day": String(Int(start.timeIntervalSince1970)),
                    "readings": String(digest.readingCount),
                    "polyline": String(digest.polyline.count / 2),
                    "categories": String(digest.categorySeconds.count),
                ]
            )
        } catch {
            TaptionPlanDiagnosticsLogger.shared.record(
                "day_seal_failed",
                level: .error,
                fields: ["error": String(describing: type(of: error))]
            )
        }
    }

    /// 확정하지 않은 날을 다시 계산하도록 확정을 지운다(사용자가 그 날 기록을 고쳤을 때).
    func removeSeal(for day: Date) async {
        guard let daySealStore else { return }
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: day)
        let number = TaptionReadingRowCodec.dayNumber(for: start, calendar: calendar)
        do {
            try await daySealStore.deleteSealedDays(numbers: [number])
            sealedDays[start] = nil
            TaptionPlanDiagnosticsLogger.shared.record("day_seal_removed", fields: ["day": String(number)])
        } catch {
            TaptionPlanDiagnosticsLogger.shared.record(
                "day_seal_remove_failed",
                level: .error,
                fields: ["error": String(describing: type(of: error))]
            )
        }
    }

    private func sealedDigest(from snapshot: PlanDayDataSnapshot, now: Date) -> TaptionSealedDay? {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: snapshot.day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let window = TimeSpan(start: start, end: end)
        let placeKinds = FrequentPlaceResolutionEngine()
            .kindsByPlaceKey(self.snapshot.settings.frequentPlaces)
        let categories = TaptionSealedDayBuilder.categoryDurations(
            actuals: snapshot.actuals,
            travel: snapshot.travel,
            stays: snapshot.places,
            placeKinds: placeKinds,
            day: window,
            asOf: now
        )
        // 달력 지표(거리·장소·이동 횟수·외출)는 대분류가 아닌 값만 따로 담는다.
        var metrics = MapHomeCalendarTimeTotalsPolicy.dayTotals(
            actuals: snapshot.actuals,
            travel: snapshot.travel,
            stays: snapshot.places,
            placeKinds: placeKinds,
            day: start,
            dayEnd: end,
            asOf: now
        )
        for key in categories.keys { metrics[key] = nil }
        metrics["unconfirmed"] = nil
        let steps = snapshot.readings.compactMap(\.stepCount).filter { $0 > 0 }.max() ?? 0
        let distance = snapshot.travel.reduce(0.0) { $0 + max(0, $1.distanceMeters) }
        let weather = self.snapshot.weather
            .filter { context in
                context.isForecast != true && context.observedAt >= start && context.observedAt < end
            }
            .max { $0.observedAt < $1.observedAt }
        let memos = self.snapshot.memos.filter { $0.occurredAt >= start && $0.occurredAt < end }.count
        return TaptionSealedDayBuilder.make(
            day: start,
            sealedAt: now,
            sourceFingerprint: snapshot.sourceFingerprint,
            categories: categories,
            metrics: metrics,
            steps: steps,
            distanceMeters: distance,
            readings: snapshot.readings,
            weather: weather,
            memoCount: memos,
            actualCount: snapshot.actuals.count,
            travelCount: snapshot.travel.count,
            placeCount: snapshot.places.count
        )
    }

    func cachedPlanDayDataSnapshot(for date: Date) async -> PlanDayDataSnapshot? {
        let generation = dataDeletionGeneration
        guard acceptsDataMutation(), let dayLoadCoordinator else { return nil }
        let revision = dayProjectionRevision
        let result = await dayLoadCoordinator.cachedSnapshot(
            day: date,
            source: snapshot,
            sourceRevision: revision
        )
        guard generation == dataDeletionGeneration, revision == dayProjectionRevision, acceptsDataMutation() else {
            return nil
        }
        return result
    }

    private func indexedDaySource(_ source: TaptionDataSnapshot, for date: Date) async -> TaptionDataSnapshot {
        do {
            guard let actuals = try await repository.actuals(in: daySpan(containing: date), matching: source.actuals) else {
                return source
            }
            var value = source
            value.actuals = actuals
            return value
        } catch {
            // A failed/obsolete SQL projection must never replace in-memory edits or canonical data.
            return source
        }
    }

    func daySpan(containing date: Date) -> TimeSpan {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(24 * 60 * 60)
        return TimeSpan(start: start, end: end)
    }

    func rawDataRevision(for date: Date) -> UInt64 {
        _ = rawDayRevisionSignal
        return rawDayRevisions[
            Calendar.autoupdatingCurrent.startOfDay(for: date)
        ] ?? 0
    }

    func daySourceFingerprint(for date: Date) -> String? {
        let day = Calendar.autoupdatingCurrent.startOfDay(for: date)
        if let cached = daySourceFingerprintCache.value(for: day),
           cached.revision == dayProjectionRevision {
            return cached.value
        }
        let value = PlanDayDataSnapshot.sourceFingerprint(
            date: day,
            source: snapshot
        )
        daySourceFingerprintCache.insert((dayProjectionRevision, value), for: day)
        return value
    }

    private func cachedDayFingerprint(
        for date: Date, source: TaptionDataSnapshot, revision: UInt64
    ) async -> String? {
        let day = Calendar.autoupdatingCurrent.startOfDay(for: date)
        if let cached = daySourceFingerprintCache.value(for: day), cached.revision == revision {
            return cached.value
        }
        let worker = Task.detached(priority: .userInitiated) {
            try PlanDayDataSnapshot.sourceFingerprint(date: day, source: source,
                cancellationCheck: { try Task.checkCancellation() })
        }
        let value = await withTaskCancellationHandler(operation: {
            try? await worker.value
        }, onCancel: { worker.cancel() })
        if !Task.isCancelled, revision == dayProjectionRevision {
            daySourceFingerprintCache.insert((revision, value), for: day)
        }
        return value
    }

    func invalidateRawDays(_ dates: [Date]) {
        let calendar = Calendar.autoupdatingCurrent
        let days = Set(dates.map { calendar.startOfDay(for: $0) })
        guard !days.isEmpty else { return }
        for day in days {
            rawDayRevisions[day, default: 0] &+= 1
            dayLoadCoordinator?.invalidate(day: day)
        }
        rawDayRevisionSignal &+= 1
    }

    func sensorReadings(in span: TimeSpan) async -> [SensorReading] {
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: span.start)
        if dayLoadCoordinator != nil,
           let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart),
           span.start == dayStart,
           span.end == dayEnd {
            return await planDayDataSnapshot(
                for: dayStart,
                forceReload: false
            ).readings
        }
        return await sensorReadingsLoadResult(in: span).readings
    }

    func photoBackfillReadings(
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

    func hasPhotoLocations(in span: TimeSpan) -> Bool {
        snapshot.photos.contains {
            span.contains($0.capturedAt)
                && $0.location != nil
                && !$0.isHiddenFromTimeline
        }
    }
}
