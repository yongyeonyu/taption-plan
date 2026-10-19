import Foundation
import OSLog
import TaptionPlanCore

/// 애플워치 센서 요약·가속도 묶음의 저장소. 새 저장소(`TaptionStoreV2`)의 `raw_events` 표에 둔다.
///
/// 워치가 보낸 값은 원본 그대로 한 번만 저장하고(같은 id에 다른 내용이면 거부), 출처(기기·전송 경로)는
/// provenance 열에 남긴다. 하루 화면용 파생 값은 여기에 저장하지 않는다(`PlanDayLoadCoordinator`가 메모리에만 둔다).
actor PlanDayDatabase {
    private static let watchSummaryProvenance = [
        "source-device:appleWatch",
        "transport:WatchConnectivity",
    ]
    private static let watchAccelerationProvenance = [
        "source-device:appleWatch",
        "source:WatchAcceleration",
        "derived:downsampled-accelerometer-v1",
    ]
    private static let logger = Logger(
        subsystem: "com.taption.plan",
        category: "DayDatabase"
    )

    private let store: TaptionStoreV2
    private let writeLockURL: URL
    private var dataDeletionGeneration: UInt64

    init(store: TaptionStoreV2) {
        self.store = store
        writeLockURL = store.url.appendingPathExtension("lock")
        dataDeletionGeneration = TaptionDataDeletionFence.currentGeneration()
    }

    /// `directory` 안의 `taption-store.sqlite`를 연다(시험용).
    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.init(store: try TaptionStoreV2(
            url: directory.appendingPathComponent(TaptionStoreV2.fileName)
        ))
    }

    static func applicationSupport(
        fileManager: FileManager = .default
    ) throws -> PlanDayDatabase {
        PlanDayDatabase(store: try TaptionStoreV2.applicationSupport(fileManager: fileManager))
    }

    func deleteAll(generation: UInt64? = nil) async throws {
        let lock = try await TaptionDataFileLock.acquire(url: writeLockURL)
        defer { lock.unlock() }
        dataDeletionGeneration = generation
            ?? TaptionDataDeletionFence.currentGeneration()
        try await store.deleteRawEvents(kind: TaptionRawEvent.Kind.watchSummary)
        try await store.deleteRawEvents(kind: TaptionRawEvent.Kind.watchAcceleration)
    }

    /// 워치 요약 원본을 저장한다. 받은 값은 워치가 보낸 모양 그대로 두고, 출처와 전송 경로는 provenance에 남긴다.
    func recordWatchSummary(_ summary: TaptionWatchSensorSummary) async throws {
        let lock = try await TaptionDataFileLock.acquire(url: writeLockURL)
        defer { lock.unlock() }
        try checkDataGeneration()
        try await store.appendRawEvents([try Self.watchSummaryEvent(for: summary)])
    }

    func watchAccelerationSamples(
        for day: Date
    ) async throws -> [TaptionWatchAccelerationSample] {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(86_400)
        return try await watchAccelerationSamples(
            in: TimeSpan(start: start, end: end)
        )
    }

    func watchSummaries(
        in span: TimeSpan
    ) async throws -> [TaptionWatchSensorSummary] {
        let window = eventWindow(including: span)
        let events = try await store.rawEvents(
            kind: TaptionRawEvent.Kind.watchSummary, from: window.lowerBound, through: window.upperBound
        )
        let values = try events.map { try Self.decode(TaptionWatchSensorSummary.self, from: $0.payload) }
        var latestByWindow: [String: TaptionWatchSensorSummary] = [:]
        for value in values {
            let key = "\(value.sessionID.uuidString):\(value.sequence)"
            let currentRevision = latestByWindow[key]?.ambientRevision ?? 0
            let revision = value.ambientRevision ?? 0
            if latestByWindow[key] == nil || revision > currentRevision {
                latestByWindow[key] = value
            }
        }
        return latestByWindow.values
            .filter {
                TimeSpan(start: $0.startedAt, end: $0.endedAt)
                    .intersection(with: span) != nil
            }
            .sorted {
                if $0.startedAt != $1.startedAt {
                    return $0.startedAt < $1.startedAt
                }
                return $0.sequence < $1.sequence
            }
    }

    func latestWatchSummary(
        for sessionID: UUID
    ) async throws -> TaptionWatchSensorSummary? {
        let events = try await store.rawEvents(
            kind: TaptionRawEvent.Kind.watchSummary,
            idPrefix: "\(sessionID.uuidString):",
            limit: 32,
            newestFirst: true
        )
        var latest: TaptionWatchSensorSummary?
        for event in events {
            let summary = try Self.decode(TaptionWatchSensorSummary.self, from: event.payload)
            guard summary.sessionID == sessionID else { continue }
            if let latest {
                let isLater = summary.sequence > latest.sequence
                    || (summary.sequence == latest.sequence
                        && (summary.ambientRevision ?? 0)
                            > (latest.ambientRevision ?? 0))
                guard isLater else { continue }
            }
            latest = summary
        }
        return latest
    }

    func recordWatchAccelerationChunk(
        _ chunk: TaptionWatchAccelerationChunk
    ) async throws {
        try await recordWatchAccelerationChunks([chunk])
    }

    func recordWatchAccelerationChunks(
        _ chunks: [TaptionWatchAccelerationChunk]
    ) async throws {
        guard !chunks.isEmpty else { return }
        let lock = try await TaptionDataFileLock.acquire(url: writeLockURL)
        defer { lock.unlock() }
        try checkDataGeneration()
        try await store.appendRawEvents(try chunks.map(Self.watchAccelerationEvent))
    }

    func validateWatchAccelerationChunks(
        _ chunks: [TaptionWatchAccelerationChunk]
    ) async throws {
        guard !chunks.isEmpty else { return }
        let lock = try await TaptionDataFileLock.acquire(url: writeLockURL)
        defer { lock.unlock() }
        try checkDataGeneration()
        try await store.validateRawEvents(try chunks.map(Self.watchAccelerationEvent))
    }

    func watchAccelerationChunks(
        in span: TimeSpan
    ) async throws -> [TaptionWatchAccelerationChunk] {
        let window = eventWindow(including: span)
        let events = try await store.rawEvents(
            kind: TaptionRawEvent.Kind.watchAcceleration, from: window.lowerBound, through: window.upperBound
        )
        let chunks = try events.compactMap { event -> TaptionWatchAccelerationChunk? in
            let chunk = try Self.decode(TaptionWatchAccelerationChunk.self, from: event.payload)
            return chunk.samples.contains { span.contains($0.capturedAt) } ? chunk : nil
        }
        var seen = Set<UUID>()
        return chunks
            .filter { seen.insert($0.id).inserted }
            .sorted {
                if $0.startedAt != $1.startedAt {
                    return $0.startedAt < $1.startedAt
                }
                return $0.sequence < $1.sequence
            }
    }

    func watchAccelerationSamples(
        in span: TimeSpan
    ) async throws -> [TaptionWatchAccelerationSample] {
        let samples = try await watchAccelerationChunks(in: span)
            .flatMap(\.samples)
            .filter { span.contains($0.capturedAt) }
        return Dictionary(
            samples.map {
                ($0.id.uuidString, $0)
            }, uniquingKeysWith: { first, _ in first }
        ).values.sorted {
            if $0.capturedAt == $1.capturedAt {
                return $0.sequence < $1.sequence
            }
            return $0.capturedAt < $1.capturedAt
        }
    }

    /// 워치 원본이 있는 날짜(앞뒤 하루 포함). 저장 당시 시간대가 달랐을 수 있어 이웃 날짜도 넣는다.
    func backupDates(calendar: Calendar) async throws -> Set<Date> {
        var result = Set<Date>()
        for kind in [TaptionRawEvent.Kind.watchSummary, TaptionRawEvent.Kind.watchAcceleration] {
            for range in try await store.rawEventDayRanges(kind: kind) {
                var day = calendar.startOfDay(for: range.lowerBound)
                let last = calendar.startOfDay(for: range.upperBound)
                while day <= last {
                    for offset in -1...1 {
                        if let neighbor = calendar.date(byAdding: .day, value: offset, to: day) {
                            result.insert(neighbor)
                        }
                    }
                    guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
                    day = next
                }
            }
        }
        return result
    }

    // MARK: 보조

    /// 이벤트 시각(`ambientWindowStart ?? endedAt`)은 구간 시작과 다를 수 있어 앞뒤 하루를 더 읽는다.
    private func eventWindow(including span: TimeSpan) -> ClosedRange<Date> {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: span.start)
        let end = calendar.startOfDay(for: max(span.start, span.end))
        let lower = calendar.date(byAdding: .day, value: -1, to: start) ?? start
        let upper = calendar.date(byAdding: .day, value: 2, to: end) ?? end.addingTimeInterval(2 * 86_400)
        return lower...upper
    }

    private func checkDataGeneration() throws {
        guard TaptionDataDeletionFence.allows(
            generation: dataDeletionGeneration
        ) else { throw CancellationError() }
    }

    private static func watchSummaryEvent(
        for summary: TaptionWatchSensorSummary
    ) throws -> TaptionRawEvent {
        TaptionRawEvent(
            kind: TaptionRawEvent.Kind.watchSummary,
            id: summary.rawEventID,
            timestamp: summary.ambientWindowStart ?? summary.endedAt,
            sequence: Int64(max(0, summary.sequence)),
            provenance: watchSummaryProvenance,
            payload: try encode(summary)
        )
    }

    private static func watchAccelerationEvent(
        for chunk: TaptionWatchAccelerationChunk
    ) throws -> TaptionRawEvent {
        TaptionRawEvent(
            kind: TaptionRawEvent.Kind.watchAcceleration,
            id: chunk.id.uuidString,
            timestamp: chunk.ambientWindowStart ?? chunk.endedAt,
            sequence: Int64(max(0, chunk.sequence)),
            provenance: watchAccelerationProvenance,
            payload: try encode(chunk)
        )
    }

    private static func encode<Value: Encodable>(_ value: Value) throws -> String {
        try TaptionRawPayloadCoding.encode(value)
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from payload: String) throws -> Value {
        try TaptionRawPayloadCoding.decode(type, from: payload)
    }
}

/// 하루 화면용 파생 값(`PlanDayDataSnapshot`)의 메모리 캐시와 적재 조율.
/// 파생 값은 원본에서 다시 계산할 수 있으므로 디스크에 저장하지 않는다.
@MainActor
final class PlanDayLoadCoordinator {
    private struct CacheKey: Hashable {
        let day: TaptionPlanDayKey
        let sourceFingerprint: String
        let projectionVersion: UInt64
    }

    private let dataDeletionGeneration: UInt64
    private var cache: TaptionBoundedCache<CacheKey, PlanDayDataSnapshot>
    private var lastKnownCache: TaptionBoundedCache<TaptionPlanDayKey, PlanDayDataSnapshot>
    private struct InFlightRequest {
        let id: UUID
        let task: Task<PlanDayDataSnapshot, Never>
        let forceReload: Bool
    }

    private var inFlight: [CacheKey: InFlightRequest] = [:]
    private struct RawRequest {
        let id: UUID
        let task: Task<SensorReadingsLoadResult, Never>
    }
    private var rawRequests: [TaptionPlanDayKey: RawRequest] = [:]
    private var prefetchTask: Task<Void, Never>?
    private var forceReloadDays: Set<TaptionPlanDayKey> = []
    private var dayInvalidationGenerations: [TaptionPlanDayKey: UInt64] = [:]

    init(cacheCapacity: Int = 42) {
        self.cache = TaptionBoundedCache(capacity: max(1, cacheCapacity))
        self.lastKnownCache = TaptionBoundedCache(capacity: max(1, cacheCapacity))
        self.dataDeletionGeneration = TaptionDataDeletionFence.currentGeneration()
    }

    deinit {
        prefetchTask?.cancel()
        for request in inFlight.values {
            request.task.cancel()
        }
        for request in rawRequests.values { request.task.cancel() }
    }

    /// 메모리에 있는 마지막으로 확인된 완전한 하루를 즉시 돌려준다.
    /// 센서를 읽거나 다시 계산하지 않으며 일반 캐시를 채우지도 않는다.
    func cachedSnapshot(
        day: Date,
        source _: TaptionDataSnapshot,
        sourceRevision _: UInt64
    ) async -> PlanDayDataSnapshot? {
        guard TaptionDataDeletionFence.allows(
            generation: dataDeletionGeneration
        ) else { return nil }
        let dayStart = Calendar.autoupdatingCurrent.startOfDay(for: day)
        let dayKey = TaptionPlanDayKey(date: dayStart)
        if let cached = lastKnownCache.peek(dayKey), cached.isComplete {
            touchLastKnown(dayKey)
            return cached
        }
        return nil
    }

    func load(
        day: Date,
        source: TaptionDataSnapshot,
        sourceRevision: UInt64,
        sourceFingerprint suppliedFingerprint: String? = nil,
        sensorLoader: @escaping (Date) async -> SensorReadingsLoadResult,
        forceReload requestedForceReload: Bool = false
    ) async -> PlanDayDataSnapshot {
        let loadStartedAt = ProcessInfo.processInfo.systemUptime
        let dayStart = Calendar.autoupdatingCurrent.startOfDay(for: day)
        let dayKey = TaptionPlanDayKey(date: dayStart)
        let invalidationGeneration = dayInvalidationGenerations[dayKey, default: 0]
        let sourceFingerprint: String?
        if let suppliedFingerprint {
            sourceFingerprint = suppliedFingerprint
        } else {
            sourceFingerprint = await Self.sourceFingerprint(date: dayStart, source: source)
        }
        guard !Task.isCancelled else {
            return PlanDayDataSnapshot.incomplete(
                date: dayStart,
                sourceRevision: sourceRevision,
                source: source
            )
        }
        let key = CacheKey(
            day: dayKey,
            sourceFingerprint: sourceFingerprint
                ?? "revision:\(sourceRevision)",
            projectionVersion: TaptionPlanV3Store.projectionVersion
        )
        let pendingForceReload = forceReloadDays.contains(key.day)
        let forceReload = requestedForceReload || pendingForceReload
        func finish(
            _ value: PlanDayDataSnapshot,
            source: String,
            durations: [String: TimeInterval] = [:]
        ) -> PlanDayDataSnapshot {
            var fields = durations.mapValues {
                String(Int(max(0, $0) * 1_000))
            }
            fields["source"] = source
            fields["duration_ms"] = String(Int(max(
                0,
                ProcessInfo.processInfo.systemUptime - loadStartedAt
            ) * 1_000))
            fields["readings"] = String(value.readings.count)
            TaptionPlanDiagnosticsLogger.shared.record(
                "day_snapshot_load_finished",
                fields: fields
            )
            return value
        }
        if let cached = cache.peek(key) {
            if !forceReload, cached.isComplete {
                touch(key)
                return finish(cached, source: "memory_cache")
            }
            cache.removeValue(for: key)
        }
        // 출처(계획·장소·이동)만 바뀌었으면 메모리에 있는 센서 원본을 다시 쓰고 파생 값만 다시 만든다.
        if !forceReload,
           let staleKey = cache.mostRecentKey(where: { $0.day == key.day }),
           let stale = cache.peek(staleKey),
           stale.isComplete {
            let projectionStartedAt = ProcessInfo.processInfo.systemUptime
            let reprojected = await Self.makeSnapshot(
                date: dayStart,
                sourceRevision: sourceRevision,
                source: source,
                sensorResult: SensorReadingsLoadResult(
                    readings: stale.readings,
                    isComplete: true
                )
            )
            let durations = [
                "projection_ms": ProcessInfo.processInfo.systemUptime
                    - projectionStartedAt,
            ]
            guard !Task.isCancelled else {
                return finish(
                    reprojected,
                    source: "reprojected_memory_raw_cancelled",
                    durations: durations
                )
            }
            guard dayInvalidationGenerations[key.day, default: 0]
                    == invalidationGeneration else {
                return await load(
                    day: day,
                    source: source,
                    sourceRevision: sourceRevision,
                    sensorLoader: sensorLoader,
                    forceReload: true
                )
            }
            if reprojected.isComplete {
                insert(reprojected, for: key)
            }
            return finish(
                reprojected,
                source: "reprojected_memory_raw",
                durations: durations
            )
        }
        cancelRequests(except: key)
        if let existing = inFlight[key] {
            if !forceReload || existing.forceReload {
                return await existing.task.value
            }
            existing.task.cancel()
            inFlight.removeValue(forKey: key)
        }

        let task = Task { @MainActor [self, source] in
            var durations: [String: TimeInterval] = [:]
            let sensorStartedAt = ProcessInfo.processInfo.systemUptime
            let sensorResult = await sharedSensorResult(day: dayStart, key: dayKey, loader: sensorLoader)
            durations["sensor_ms"] = ProcessInfo.processInfo.systemUptime
                - sensorStartedAt
            guard !Task.isCancelled else {
                return finish(PlanDayDataSnapshot.incomplete(date: dayStart,
                    sourceRevision: sourceRevision, source: source), source: "source_projection_cancelled",
                    durations: durations)
            }
            let projectionStartedAt = ProcessInfo.processInfo.systemUptime
            let projected = await Self.makeSnapshot(
                date: dayStart,
                sourceRevision: sourceRevision,
                source: source,
                sensorResult: sensorResult
            )
            durations["projection_ms"] = ProcessInfo.processInfo.systemUptime
                - projectionStartedAt
            guard !Task.isCancelled, projected.isComplete else {
                return finish(
                    projected,
                    source: "incomplete_projection",
                    durations: durations
                )
            }
            guard dayInvalidationGenerations[key.day, default: 0]
                    == invalidationGeneration else {
                return await self.load(
                    day: day,
                    source: source,
                    sourceRevision: sourceRevision,
                    sensorLoader: sensorLoader,
                    forceReload: true
                )
            }
            return finish(
                projected,
                source: "rebuilt_memory",
                durations: durations
            )
        }
        let request = InFlightRequest(id: UUID(), task: task, forceReload: forceReload)
        inFlight[key] = request
        let result = await withTaskCancellationHandler(operation: {
            await task.value
        }, onCancel: {
            task.cancel()
        })
        guard inFlight[key]?.id == request.id else { return result }
        inFlight[key] = nil
        guard !Task.isCancelled else { return result }
        if result.isComplete {
            insert(result, for: key)
            if pendingForceReload {
                forceReloadDays.remove(key.day)
            }
        }
        return result
    }

    func prefetchMonth(
        containing date: Date,
        source: TaptionDataSnapshot,
        sourceRevision: UInt64,
        sensorLoader: @escaping (Date) async -> SensorReadingsLoadResult,
        progress: ((Double) -> Void)? = nil
    ) {
        prefetchTask?.cancel()
        prefetchTask = Task { @MainActor [weak self, source] in
            guard let self else { return }
            await self.preloadMonth(
                containing: date,
                source: source,
                sourceRevision: sourceRevision,
                sensorLoader: sensorLoader,
                progress: progress
            )
        }
    }

    func preloadMonth(
        containing date: Date,
        source: TaptionDataSnapshot,
        sourceRevision: UInt64,
        sensorLoader: @escaping (Date) async -> SensorReadingsLoadResult,
        progress: ((Double) -> Void)? = nil
    ) async {
        let calendar = Calendar.autoupdatingCurrent
        let monthStart = calendar.date(
            from: calendar.dateComponents([.year, .month], from: date)
        ) ?? calendar.startOfDay(for: date)
        let count = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 0
        let days = (0..<count).compactMap {
            calendar.date(byAdding: .day, value: $0, to: monthStart)
        }
        progress?(0)
        for (index, day) in days.enumerated() {
            guard !Task.isCancelled else { return }
            let sourceFingerprint = await Self.sourceFingerprint(
                date: day,
                source: source
            )
            guard !Task.isCancelled else { return }
            let key = CacheKey(
                day: TaptionPlanDayKey(date: day),
                sourceFingerprint: sourceFingerprint
                    ?? "revision:\(sourceRevision)",
                projectionVersion: TaptionPlanV3Store.projectionVersion
            )
            if cache.peek(key) == nil {
                _ = await load(
                    day: day,
                    source: source,
                    sourceRevision: sourceRevision,
                    sensorLoader: sensorLoader
                )
            }
            progress?(Double(index + 1) / Double(max(1, days.count)))
            guard !Task.isCancelled else { return }
        }
    }


    func invalidate(day: Date) {
        let dayKey = TaptionPlanDayKey(date: day)
        rawRequests.removeValue(forKey: dayKey)?.task.cancel()
        TaptionPlanDiagnosticsLogger.shared.record("day_load_invalidated", fields: ["reason": "raw_data_changed"])
        dayInvalidationGenerations[dayKey, default: 0] &+= 1
        forceReloadDays.insert(dayKey)
        let keys = Set(cache.keys.filter { $0.day == dayKey })
            .union(inFlight.keys.filter { $0.day == dayKey })
        if let latestKey = cache.mostRecentKey(where: { keys.contains($0) }),
           let latest = cache.peek(latestKey),
           latest.isComplete {
            insertLastKnown(latest, for: dayKey)
        }
        for key in keys {
            cache.removeValue(for: key)
            inFlight[key]?.task.cancel()
            inFlight.removeValue(forKey: key)
        }
    }

    func handleMemoryPressure() {
        cache.removeAll()
        lastKnownCache.removeAll()
        rawRequests.values.forEach { $0.task.cancel() }
        rawRequests.removeAll()
    }

    func prepareForBackground() {
        prefetchTask?.cancel()
        prefetchTask = nil
        for (key, request) in inFlight {
            dayInvalidationGenerations[key.day, default: 0] &+= 1
            request.task.cancel()
        }
        inFlight.removeAll()
        handleMemoryPressure()
    }

    func invalidateAll() async {
        let prefetch = prefetchTask
        let requests = inFlight.values.map(\.task)
        let raw = rawRequests.values.map(\.task)
        rawRequests.removeAll()
        raw.forEach { $0.cancel() }
        for day in Set(cache.keys.map(\.day) + inFlight.keys.map(\.day)) {
            dayInvalidationGenerations[day, default: 0] &+= 1
        }
        prefetch?.cancel()
        prefetchTask = nil
        requests.forEach { $0.cancel() }
        inFlight.removeAll()
        forceReloadDays.removeAll()
        cache.removeAll()
        lastKnownCache.removeAll()
        await prefetch?.value
        for request in requests { _ = await request.value }
        for request in raw { _ = await request.value }
    }

    var cachedDayCount: Int { cache.count }

    private func cancelRequests(except key: CacheKey) {
        let requests = inFlight.filter { $0.key.day == key.day && $0.key != key }
        for (otherKey, request) in requests {
            TaptionPlanDiagnosticsLogger.shared.record("day_projection_cancelled",
                fields: ["reason": "source_revision_changed", "raw_read_kept": "true"])
            request.task.cancel()
            inFlight.removeValue(forKey: otherKey)
        }
    }

    private func sharedSensorResult(day: Date, key: TaptionPlanDayKey,
                                    loader: @escaping (Date) async -> SensorReadingsLoadResult) async -> SensorReadingsLoadResult {
        if let existing = rawRequests[key] { return await existing.task.value }
        let id = UUID()
        let task = Task { @MainActor in
            let result = await loader(day)
            return Task.isCancelled ? SensorReadingsLoadResult(readings: [], isComplete: false) : result
        }
        rawRequests[key] = RawRequest(id: id, task: task)
        let value = await task.value
        if rawRequests[key]?.id == id { rawRequests.removeValue(forKey: key) }
        return value
    }

    private func insert(_ value: PlanDayDataSnapshot, for key: CacheKey) {
        cache.insert(value, for: key)
        insertLastKnown(value, for: key.day)
    }

    private func touch(_ key: CacheKey) { _ = cache.value(for: key) }

    private func insertLastKnown(_ value: PlanDayDataSnapshot, for day: TaptionPlanDayKey) {
        guard value.isComplete else { return }
        lastKnownCache.insert(value, for: day)
    }

    private func touchLastKnown(_ day: TaptionPlanDayKey) { _ = lastKnownCache.value(for: day) }

    private nonisolated static func sourceFingerprint(
        date: Date,
        source: TaptionDataSnapshot
    ) async -> String? {
        let worker = Task.detached(priority: nil) {
            try PlanDayDataSnapshot.sourceFingerprint(
                date: date,
                source: source,
                cancellationCheck: { try Task.checkCancellation() }
            )
        }
        return await withTaskCancellationHandler(operation: {
            try? await worker.value
        }, onCancel: {
            worker.cancel()
        })
    }

    private nonisolated static func makeSnapshot(
        date: Date,
        sourceRevision: UInt64,
        source: TaptionDataSnapshot,
        sensorResult: SensorReadingsLoadResult
    ) async -> PlanDayDataSnapshot {
        let worker = Task.detached(priority: nil) {
            try PlanDayDataSnapshot.make(
                date: date,
                sourceRevision: sourceRevision,
                source: source,
                sensorResult: sensorResult,
                cancellationCheck: { try Task.checkCancellation() }
            )
        }
        return await withTaskCancellationHandler(operation: {
            do {
                return try await worker.value
            } catch {
                return PlanDayDataSnapshot.incomplete(
                    date: date,
                    sourceRevision: sourceRevision,
                    source: source
                )
            }
        }, onCancel: {
            worker.cancel()
        })
    }
}
