import Foundation
import OSLog
import TaptionPlanCore

private struct PlanDayDatabasePayload: Codable, Hashable, Sendable {
    let day: Date
    let sourceUpdatedAt: Date
    let sourceFingerprint: String?
    let actuals: [ActualRecord]
    let places: [PlaceStay]
    let travel: [TravelSegment]
    let readings: [SensorReading]
    let isComplete: Bool
}

struct PlanDayDatabaseMigrationReport: Equatable, Sendable {
    let dayCount: Int
    let iPhoneEventCount: Int
    let watchEventCount: Int
    let exactDigestDayCount: Int
}

private enum PlanDayDatabaseMigrationError: LocalizedError {
    case rawDigestMismatch(
        day: TaptionPlanDayKey,
        device: TaptionPlanStoreDevice,
        reason: String
    )

    var errorDescription: String? {
        switch self {
        case let .rawDigestMismatch(day, device, reason):
            return String(
                format: "Raw digest mismatch: %@ %04d-%02d-%02d %@",
                device.rawValue,
                day.year,
                day.month,
                day.day,
                reason
            )
        }
    }
}

enum PlanDayDatabaseRestoreError: Error {
    case rollbackFailed
}

/// App adapter for the package-owned v3 stores. Raw records are copied into
/// the stores before the derived day row is replaced; the old archives remain
/// untouched until an externally verified migration authorizes cleanup.
actor PlanDayDatabase {
    struct WatchAccelerationRestoreReceipt: Sendable {
        let watchEventIDs: [String]
        let iPhoneEventIDs: [String]
    }

    private static let legacyMigrationMarker = "legacy-v2-to-v3"
    private static let projectionDomains: Set<String> = [
        "plan-actual",
        "plan-place",
        "plan-travel",
    ]
    private static let watchSummaryProvenance = [
        "source-device:appleWatch",
        "transport:WatchConnectivity",
    ]
    private static let logger = Logger(
        subsystem: "com.taption.plan",
        category: "DayDatabase"
    )
    private static let signpostLog = OSLog(
        subsystem: "com.taption.plan",
        category: .pointsOfInterest
    )

    private let iPhoneStore: TaptionPlanV3Store
    private let watchStore: TaptionPlanV3Store
    private let writeLockURL: URL
    private var dataDeletionGeneration: UInt64

    init(directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        iPhoneStore = try TaptionPlanV3Store(
            url: directory.appendingPathComponent("taption-plan-iphone-v3.sqlite"),
            device: .iPhone
        )
        watchStore = try TaptionPlanV3Store(
            url: directory.appendingPathComponent("taption-plan-watch-v3.sqlite"),
            device: .appleWatch
        )
        writeLockURL = directory.appendingPathComponent(
            "taption-plan-day-write.lock"
        )
        dataDeletionGeneration = TaptionDataDeletionFence.currentGeneration()
    }

    static func applicationSupport(
        fileManager: FileManager = .default
    ) throws -> PlanDayDatabase {
        if let group = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: TaptionPlanSharedContainer.appGroupIdentifier
        ) {
            return try PlanDayDatabase(directory: group)
        }
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return try PlanDayDatabase(
            directory: root.appendingPathComponent("TaptionPlan", isDirectory: true)
        )
    }

    func deleteAll(generation: UInt64? = nil) async throws {
        let lock = try await TaptionDataFileLock.acquire(url: writeLockURL)
        defer { lock.unlock() }
        dataDeletionGeneration = generation
            ?? TaptionDataDeletionFence.currentGeneration()
        try await iPhoneStore.deleteAllData()
        try await watchStore.deleteAllData()
    }

    func load(
        day: Date,
        sourceRevision: UInt64,
        sourceFingerprint expectedSourceFingerprint: String? = nil,
        allowStaleSourceFingerprint: Bool = false
    ) async throws -> PlanDayDataSnapshot? {
        guard try await iPhoneStore.migrationCompleted(Self.legacyMigrationMarker) else {
            return nil
        }
        let dayKey = TaptionPlanDayKey(date: day)
        let signpostID = OSSignpostID(log: Self.signpostLog)
        os_signpost(
            .begin,
            log: Self.signpostLog,
            name: "day_query",
            signpostID: signpostID
        )
        defer {
            os_signpost(
                .end,
                log: Self.signpostLog,
                name: "day_query",
                signpostID: signpostID
            )
        }
        let row: TaptionPlanMaterializedDay?
        do {
            row = try await iPhoneStore.materializedDay(for: dayKey)
        } catch let error as TaptionPlanV3StoreError {
            guard case .databaseCorrupt = error else { throw error }
            // A malformed derived row must not brick the day forever. Raw
            // device events remain authoritative and can rebuild it.
            try await discardMaterializedDayIfCurrent(dayKey, expected: nil)
            return nil
        }
        guard let row,
              row.projectionVersion == TaptionPlanV3Store.projectionVersion else {
            return nil
        }
        if expectedSourceFingerprint == nil,
           row.sourceRevision != sourceRevision {
            return nil
        }
        let iPhoneDigest = try await iPhoneStore.rawDigest(for: dayKey)
        let watchDigest = try await watchStore.rawDigest(for: dayKey)
        guard materializationMatches(
            row,
            iPhoneDigest: iPhoneDigest,
            watchDigest: watchDigest
        ) else {
            let lock = try await TaptionDataFileLock.acquire(url: writeLockURL)
            defer { lock.unlock() }
            try checkDataGeneration()
            if let current = try await iPhoneStore.materializedDay(for: dayKey) {
                let currentIPhoneDigest = try await iPhoneStore.rawDigest(for: dayKey)
                let currentWatchDigest = try await watchStore.rawDigest(for: dayKey)
                if !materializationMatches(
                    current,
                    iPhoneDigest: currentIPhoneDigest,
                    watchDigest: currentWatchDigest
                ) {
                    try await iPhoneStore.removeMaterializedDay(for: dayKey)
                }
            }
            return nil
        }
        let decodeID = OSSignpostID(log: Self.signpostLog)
        os_signpost(
            .begin,
            log: Self.signpostLog,
            name: "day_decode",
            signpostID: decodeID
        )
        defer {
            os_signpost(
                .end,
                log: Self.signpostLog,
                name: "day_decode",
                signpostID: decodeID
            )
        }
        let payload: PlanDayDatabasePayload
        do {
            let encoded = try TaptionPlanCanonicalStorage.encodedPayload(
                from: row.payload
            )
            let decoded = try TaptionPlanCanonicalStorage.decode(
                PlanDayDatabasePayload.self,
                from: encoded
            )
            guard Calendar.autoupdatingCurrent.isDate(
                decoded.day,
                inSameDayAs: day
            ) else {
                throw PlanDayDatabaseError.invalidMaterializedDay
            }
            payload = decoded
        } catch {
            try await discardMaterializedDayIfCurrent(dayKey, expected: row)
            return nil
        }
        let snapshot = PlanDayDataSnapshot(
            day: payload.day,
            sourceRevision: expectedSourceFingerprint == nil
                ? row.sourceRevision
                : sourceRevision,
            sourceUpdatedAt: payload.sourceUpdatedAt,
            sourceFingerprint: payload.sourceFingerprint,
            projectionVersion: row.projectionVersion,
            actuals: payload.actuals,
            places: payload.places,
            travel: payload.travel,
            readings: payload.readings,
            isComplete: payload.isComplete
        )
        if let expectedSourceFingerprint,
           !allowStaleSourceFingerprint,
           snapshot.sourceFingerprint != expectedSourceFingerprint {
            return nil
        }
        return snapshot
    }

    func save(_ snapshot: PlanDayDataSnapshot) async throws {
        let lock = try await TaptionDataFileLock.acquire(url: writeLockURL)
        defer { lock.unlock() }
        try checkDataGeneration()
        try await save(
            snapshot,
            baseEvents: try rawEvents(for: snapshot),
            additionalIPhoneEvents: [],
            additionalWatchEvents: []
        )
    }

    func requiresLegacyMigration() async throws -> Bool {
        let completed = try await iPhoneStore.migrationCompleted(
            Self.legacyMigrationMarker
        )
        return !completed
    }

    func migrateLegacyIfNeeded(
        source: TaptionDataSnapshot,
        sourceRevision: UInt64,
        readings: [SensorReading],
        watchSummaries: [TaptionWatchSensorSummary],
        watchAccelerationChunks: [TaptionWatchAccelerationChunk] = [],
        rawEnvelopes: [RawDeviceDataEnvelope]
    ) async throws -> PlanDayDatabaseMigrationReport? {
        let lock = try await TaptionDataFileLock.acquire(url: writeLockURL)
        defer { lock.unlock() }
        try checkDataGeneration()
        guard try await requiresLegacyMigration() else { return nil }

        let calendar = Calendar.autoupdatingCurrent
        let days = migrationDays(
            source: source,
            readings: readings,
            watchSummaries: watchSummaries,
            watchAccelerationChunks: watchAccelerationChunks,
            rawEnvelopes: rawEnvelopes,
            calendar: calendar
        )
        let rawEnvelopesByDay = Dictionary(grouping: rawEnvelopes) {
            TaptionPlanDayKey(date: $0.capturedAt, calendar: calendar)
        }
        let watchSummariesByDay = Dictionary(grouping: watchSummaries) {
            TaptionPlanDayKey(date: $0.endedAt, calendar: calendar)
        }
        let watchChunksByDay = Dictionary(grouping: watchAccelerationChunks) {
            TaptionPlanDayKey(date: $0.endedAt, calendar: calendar)
        }
        func importAndValidate() async throws -> PlanDayDatabaseMigrationReport {
            var iPhoneEventCount = 0
            var watchEventCount = 0
            var exactDigestDayCount = 0
            for dayKey in days {
                guard !Task.isCancelled,
                      let day = calendar.date(
                        from: DateComponents(
                            year: dayKey.year,
                            month: dayKey.month,
                            day: dayKey.day
                        )
                      ) else { throw CancellationError() }
                let dayStart = calendar.startOfDay(for: day)
                let snapshot = PlanDayDataSnapshot.make(
                    date: dayStart,
                    sourceRevision: sourceRevision,
                    source: source,
                    sensorResult: SensorReadingsLoadResult(
                        readings: readings,
                        isComplete: true
                    ),
                    calendar: calendar
                )
                let baseEvents = try rawEvents(for: snapshot)
                let extras = try migrationEvents(
                    rawEnvelopes: rawEnvelopesByDay[dayKey] ?? [],
                    watchSummaries: watchSummariesByDay[dayKey] ?? [],
                    watchAccelerationChunks: watchChunksByDay[dayKey] ?? [],
                    day: dayKey
                )
                let expectedIPhone = baseEvents.iPhone + extras.iPhone
                let expectedWatch = baseEvents.watch + extras.watch
                try await save(
                    snapshot,
                    baseEvents: baseEvents,
                    additionalIPhoneEvents: extras.iPhone,
                    additionalWatchEvents: extras.watch
                )
                try checkDataGeneration()

                let actualIPhone = try await iPhoneStore.rawEvents(for: dayKey)
                let actualWatch = try await watchStore.rawEvents(for: dayKey)
                try validate(
                    expected: expectedIPhone,
                    actual: actualIPhone,
                    day: dayKey,
                    device: .iPhone,
                    exactDigestDayCount: &exactDigestDayCount
                )
                try validate(
                    expected: expectedWatch,
                    actual: actualWatch,
                    day: dayKey,
                    device: .appleWatch,
                    exactDigestDayCount: &exactDigestDayCount
                )
                iPhoneEventCount += actualIPhone.count
                watchEventCount += actualWatch.count
            }
            return PlanDayDatabaseMigrationReport(
                dayCount: days.count,
                iPhoneEventCount: iPhoneEventCount,
                watchEventCount: watchEventCount,
                exactDigestDayCount: exactDigestDayCount
            )
        }

        let report: PlanDayDatabaseMigrationReport
        do {
            report = try await importAndValidate()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try await iPhoneStore.resetForIncompleteMigration(
                Self.legacyMigrationMarker
            )
            try await watchStore.resetForIncompleteMigration(
                Self.legacyMigrationMarker
            )
            do {
                report = try await importAndValidate()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw error
            }
        }

        guard !Task.isCancelled else { throw CancellationError() }
        try checkDataGeneration()
        _ = try await iPhoneStore.markMigrationCompleted(
            Self.legacyMigrationMarker
        )
        return report
    }

    private func save(
        _ snapshot: PlanDayDataSnapshot,
        baseEvents: (
            iPhone: [TaptionPlanRawEvent],
            watch: [TaptionPlanRawEvent]
        ),
        additionalIPhoneEvents: [TaptionPlanRawEvent],
        additionalWatchEvents: [TaptionPlanRawEvent]
    ) async throws {
        let encodeID = OSSignpostID(log: Self.signpostLog)
        os_signpost(
            .begin,
            log: Self.signpostLog,
            name: "day_projection",
            signpostID: encodeID
        )
        defer {
            os_signpost(
                .end,
                log: Self.signpostLog,
                name: "day_projection",
                signpostID: encodeID
            )
        }
        let payload = PlanDayDatabasePayload(
            day: snapshot.day,
            sourceUpdatedAt: snapshot.sourceUpdatedAt,
            sourceFingerprint: snapshot.sourceFingerprint,
            actuals: snapshot.actuals,
            places: snapshot.places,
            travel: snapshot.travel,
            readings: snapshot.readings,
            isComplete: snapshot.isComplete
        )
        let encodedPayload = try TaptionPlanCanonicalStorage.encode(payload)
        let materializedPayload = TaptionPlanCanonicalStorage.envelope(for: encodedPayload)
        let events = baseEvents
        let dayKey = TaptionPlanDayKey(date: snapshot.day)
        let iPhoneEvents = events.iPhone + additionalIPhoneEvents
        let projectionEvents = iPhoneEvents.filter {
            Self.projectionDomains.contains($0.domain)
        }
        try await iPhoneStore.appendRawEvents(
            iPhoneEvents.filter { !Self.projectionDomains.contains($0.domain) }
        )
        try await iPhoneStore.replaceRawEvents(
            projectionEvents,
            for: dayKey,
            domains: Self.projectionDomains
        )
        try await watchStore.appendRawEvents(
            events.watch + additionalWatchEvents
        )
        let iPhoneDigest = try await iPhoneStore.rawDigest(
            for: dayKey
        )
        let watchDigest = try await watchStore.rawDigest(
            for: dayKey
        )
        let combinedDigest = Self.combinedDigest(
            iPhone: iPhoneDigest,
            watch: watchDigest
        )
        let firstTimestamp = [
            iPhoneDigest.firstTimestamp,
            watchDigest.firstTimestamp,
        ].compactMap { $0 }.min()
        let lastTimestamp = [
            iPhoneDigest.lastTimestamp,
            watchDigest.lastTimestamp,
        ].compactMap { $0 }.max()
        let row = TaptionPlanMaterializedDay(
            device: .iPhone,
            day: TaptionPlanDayKey(date: snapshot.day),
            sourceRevision: snapshot.sourceRevision,
            projectionVersion: TaptionPlanV3Store.projectionVersion,
            rawDigest: combinedDigest,
            rawEventCount: iPhoneDigest.eventCount + watchDigest.eventCount,
            firstTimestamp: firstTimestamp,
            lastTimestamp: lastTimestamp,
            payload: materializedPayload
        )
        try await iPhoneStore.replaceMaterializedDay(row)
        Self.logger.debug(
            "Materialized day saved: day=\(row.day.year)-\(row.day.month)-\(row.day.day, privacy: .public), events=\(row.rawEventCount, privacy: .public)"
        )
    }

    /// Persists the Watch raw summary in the Watch store and in the iPhone
    /// merge store. The source device and transport remain in provenance; the
    /// received record is never rewritten into the Watch's original shape.
    func recordWatchSummary(_ summary: TaptionWatchSensorSummary) async throws {
        let lock = try await TaptionDataFileLock.acquire(url: writeLockURL)
        defer { lock.unlock() }
        try checkDataGeneration()
        let payload = TaptionPlanCanonicalStorage.envelope(
            for: try TaptionPlanCanonicalStorage.encode(summary)
        )
        let day = TaptionPlanDayKey(date: summary.endedAt)
        let id = "\(summary.sessionID.uuidString):\(summary.sequence)"
        let watchEvent = TaptionPlanRawEvent(
            device: .appleWatch,
            day: day,
            timestamp: summary.endedAt,
            sequence: UInt64(max(0, summary.sequence)),
            id: id,
            domain: "watch-sensor-summary",
            provenance: Self.watchSummaryProvenance,
            payload: payload
        )
        let mergedEvent = TaptionPlanRawEvent(
            device: .iPhone,
            day: day,
            timestamp: summary.endedAt,
            sequence: UInt64(max(0, summary.sequence)),
            id: id,
            domain: "watch-sensor-summary",
            provenance: Self.watchSummaryProvenance + ["merge:iPhone"],
            payload: payload
        )
        let watchIDs = try await watchStore.appendRawEvents([watchEvent])
        try checkDataGeneration()
        let iPhoneIDs = try await iPhoneStore.appendRawEvents([mergedEvent])
        if !watchIDs.isEmpty || !iPhoneIDs.isEmpty {
            try await iPhoneStore.removeMaterializedDay(for: day)
        }
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
        let days = dayKeys(includingNeighborsOf: span)
        var values: [TaptionWatchSensorSummary] = []
        for day in days {
            var events = try await iPhoneStore.rawEvents(
                for: day,
                domain: "watch-sensor-summary"
            )
            events += try await watchStore.rawEvents(
                for: day,
                domain: "watch-sensor-summary"
            )
            values.append(contentsOf: try events.compactMap { event in
                let encoded = try TaptionPlanCanonicalStorage.encodedPayload(
                    from: event.payload
                )
                let summary = try TaptionPlanCanonicalStorage.decode(
                    TaptionWatchSensorSummary.self,
                    from: encoded
                )
                return TimeSpan(
                    start: summary.startedAt,
                    end: summary.endedAt
                ).intersection(with: span) == nil ? nil : summary
            })
        }
        var seen = Set<String>()
        return values
            .filter {
                seen.insert("\($0.sessionID.uuidString):\($0.sequence)").inserted
            }
            .sorted {
                if $0.startedAt != $1.startedAt {
                    return $0.startedAt < $1.startedAt
                }
                return $0.sequence < $1.sequence
            }
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
        let events = try chunks.map {
            try Self.watchAccelerationEvents(for: $0)
        }
        let receipt = try await appendWatchAccelerationEvents(events)
        let insertedIDs = Set(receipt.watchEventIDs + receipt.iPhoneEventIDs)
        for day in Set(events.compactMap {
            insertedIDs.contains($0.iPhone.id) ? $0.iPhone.day : nil
        }) {
            try await iPhoneStore.removeMaterializedDay(for: day)
        }
    }

    func recordWatchAccelerationChunksForRestore(
        _ chunks: [TaptionWatchAccelerationChunk]
    ) async throws -> WatchAccelerationRestoreReceipt {
        guard !chunks.isEmpty else {
            return WatchAccelerationRestoreReceipt(
                watchEventIDs: [],
                iPhoneEventIDs: []
            )
        }
        let lock = try await TaptionDataFileLock.acquire(url: writeLockURL)
        defer { lock.unlock() }
        try checkDataGeneration()
        return try await appendWatchAccelerationEvents(
            chunks.map { try Self.watchAccelerationEvents(for: $0) }
        )
    }

    func rollbackWatchAccelerationRestore(
        _ receipt: WatchAccelerationRestoreReceipt
    ) async throws {
        let lock = try await TaptionDataFileLock.acquire(url: writeLockURL)
        defer { lock.unlock() }
        try checkDataGeneration()
        var firstError: (any Error)?
        do {
            try await iPhoneStore.deleteRawEvents(
                ids: receipt.iPhoneEventIDs,
                domain: "watch-acceleration"
            )
        } catch {
            firstError = error
        }
        do {
            try await watchStore.deleteRawEvents(
                ids: receipt.watchEventIDs,
                domain: "watch-acceleration"
            )
        } catch {
            if firstError == nil { firstError = error }
        }
        if let firstError { throw firstError }
    }

    func validateWatchAccelerationChunks(
        _ chunks: [TaptionWatchAccelerationChunk]
    ) async throws {
        guard !chunks.isEmpty else { return }
        let lock = try await TaptionDataFileLock.acquire(url: writeLockURL)
        defer { lock.unlock() }
        try checkDataGeneration()
        let events = try chunks.map {
            try Self.watchAccelerationEvents(for: $0)
        }
        try await watchStore.validateRawEventsForAppend(events.map { $0.watch })
        try await iPhoneStore.validateRawEventsForAppend(events.map { $0.iPhone })
    }

    private func appendWatchAccelerationEvents(
        _ events: [(watch: TaptionPlanRawEvent, iPhone: TaptionPlanRawEvent)]
    ) async throws -> WatchAccelerationRestoreReceipt {
        let watchIDs = try await watchStore.appendRawEvents(
            events.map(\.watch)
        )
        do {
            try checkDataGeneration()
            let iPhoneIDs = try await iPhoneStore.appendRawEvents(
                events.map(\.iPhone)
            )
            return WatchAccelerationRestoreReceipt(
                watchEventIDs: watchIDs.map(\.id),
                iPhoneEventIDs: iPhoneIDs.map(\.id)
            )
        } catch {
            do {
                try await watchStore.deleteRawEvents(
                    ids: watchIDs.map(\.id),
                    domain: "watch-acceleration"
                )
            } catch {
                Self.logger.error(
                    "Watch acceleration rollback failed: \(error.localizedDescription, privacy: .public)"
                )
                throw PlanDayDatabaseRestoreError.rollbackFailed
            }
            throw error
        }
    }

    private static func watchAccelerationEvents(
        for chunk: TaptionWatchAccelerationChunk
    ) throws -> (watch: TaptionPlanRawEvent, iPhone: TaptionPlanRawEvent) {
        let payload = TaptionPlanCanonicalStorage.envelope(
            for: try TaptionPlanCanonicalStorage.encode(chunk)
        )
        let day = TaptionPlanDayKey(date: chunk.endedAt)
        let id = chunk.id.uuidString
        let sequence = UInt64(max(0, chunk.sequence))
        let provenance = [
            "source-device:appleWatch",
            "source:WatchAcceleration",
            "derived:downsampled-accelerometer-v1",
        ]
        let watchEvent = TaptionPlanRawEvent(
            device: .appleWatch,
            day: day,
            timestamp: chunk.endedAt,
            sequence: sequence,
            id: id,
            domain: "watch-acceleration",
            provenance: provenance,
            payload: payload
        )
        let mergedEvent = TaptionPlanRawEvent(
            device: .iPhone,
            day: day,
            timestamp: chunk.endedAt,
            sequence: sequence,
            id: id,
            domain: "watch-acceleration",
            provenance: provenance + ["merge:iPhone"],
            payload: payload
        )
        return (watchEvent, mergedEvent)
    }

    func watchAccelerationChunks(
        in span: TimeSpan
    ) async throws -> [TaptionWatchAccelerationChunk] {
        let days = dayKeys(includingNeighborsOf: span)
        var chunks: [TaptionWatchAccelerationChunk] = []
        for day in days {
            var events = try await iPhoneStore.rawEvents(
                for: day,
                domain: "watch-acceleration"
            )
            events += try await watchStore.rawEvents(
                for: day,
                domain: "watch-acceleration"
            )
            chunks.append(contentsOf: try events.compactMap { event in
                let encoded = try TaptionPlanCanonicalStorage.encodedPayload(
                    from: event.payload
                )
                let chunk = try TaptionPlanCanonicalStorage.decode(
                    TaptionWatchAccelerationChunk.self,
                    from: encoded
                )
                return chunk.samples.contains {
                    span.contains($0.capturedAt)
                } ? chunk : nil
            })
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

    private func dayKeys(intersecting span: TimeSpan) -> [TaptionPlanDayKey] {
        let calendar = Calendar.autoupdatingCurrent
        let first = calendar.startOfDay(for: span.start)
        let last = calendar.startOfDay(for: max(span.start, span.end))
        var result: [TaptionPlanDayKey] = []
        var day = first
        while day <= last {
            result.append(TaptionPlanDayKey(date: day))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day),
                  next > day else { break }
            day = next
        }
        return result
    }

    private func dayKeys(
        includingNeighborsOf span: TimeSpan
    ) -> [TaptionPlanDayKey] {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: span.start)
        let end = calendar.startOfDay(for: max(span.start, span.end))
        let first = calendar.date(byAdding: .day, value: -1, to: start)
            ?? start
        let last = calendar.date(byAdding: .day, value: 1, to: end) ?? end
        return dayKeys(intersecting: TimeSpan(start: first, end: last))
    }

    func invalidate(day: Date) async throws {
        let lock = try await TaptionDataFileLock.acquire(url: writeLockURL)
        defer { lock.unlock() }
        try checkDataGeneration()
        try await iPhoneStore.removeMaterializedDay(
            for: TaptionPlanDayKey(date: day)
        )
    }

    private func checkDataGeneration() throws {
        guard TaptionDataDeletionFence.allows(
            generation: dataDeletionGeneration
        ) else { throw CancellationError() }
    }

    private func discardMaterializedDayIfCurrent(
        _ day: TaptionPlanDayKey,
        expected: TaptionPlanMaterializedDay?
    ) async throws {
        let lock = try await TaptionDataFileLock.acquire(url: writeLockURL)
        defer { lock.unlock() }
        try checkDataGeneration()
        if let expected {
            guard let current = try await iPhoneStore.materializedDay(for: day),
                  current == expected else { return }
        }
        try await iPhoneStore.removeMaterializedDay(for: day)
    }

    private func materializationMatches(
        _ row: TaptionPlanMaterializedDay,
        iPhoneDigest: TaptionPlanDayDigest,
        watchDigest: TaptionPlanDayDigest
    ) -> Bool {
        let firstTimestamp = [
            iPhoneDigest.firstTimestamp,
            watchDigest.firstTimestamp,
        ].compactMap { $0 }.min()
        let lastTimestamp = [
            iPhoneDigest.lastTimestamp,
            watchDigest.lastTimestamp,
        ].compactMap { $0 }.max()
        return row.rawDigest == Self.combinedDigest(
            iPhone: iPhoneDigest,
            watch: watchDigest
        )
            && row.rawEventCount
                == iPhoneDigest.eventCount + watchDigest.eventCount
            && row.firstTimestamp == firstTimestamp
            && row.lastTimestamp == lastTimestamp
    }

    private static func combinedDigest(
        iPhone: TaptionPlanDayDigest,
        watch: TaptionPlanDayDigest
    ) -> String {
        TaptionPlanCanonicalStorage.checksum(
            Data("\(iPhone.sha256):\(watch.sha256)".utf8)
        )
    }

    private func migrationDays(
        source: TaptionDataSnapshot,
        readings: [SensorReading],
        watchSummaries: [TaptionWatchSensorSummary],
        watchAccelerationChunks: [TaptionWatchAccelerationChunk],
        rawEnvelopes: [RawDeviceDataEnvelope],
        calendar: Calendar
    ) -> [TaptionPlanDayKey] {
        var keys = Set<TaptionPlanDayKey>()

        func add(_ date: Date) {
            keys.insert(TaptionPlanDayKey(date: date, calendar: calendar))
        }

        func addRange(start: Date, end: Date) {
            let first = calendar.startOfDay(for: start)
            guard end > start else {
                add(first)
                return
            }
            var day = first
            while day < end {
                add(day)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day),
                      next > day else { break }
                day = next
            }
        }

        for actual in source.actuals {
            addRange(
                start: actual.startedAt,
                end: actual.endedAt ?? actual.startedAt.addingTimeInterval(1)
            )
        }
        for place in source.places {
            addRange(start: place.span.start, end: place.span.end)
        }
        for travel in source.travel {
            addRange(start: travel.span.start, end: travel.span.end)
        }
        readings.forEach { add($0.timestamp) }
        watchSummaries.forEach { add($0.endedAt) }
        watchAccelerationChunks.forEach { add($0.endedAt) }
        rawEnvelopes.forEach { add($0.capturedAt) }
        return keys.sorted()
    }

    private func migrationEvents(
        rawEnvelopes: [RawDeviceDataEnvelope],
        watchSummaries: [TaptionWatchSensorSummary],
        watchAccelerationChunks: [TaptionWatchAccelerationChunk],
        day: TaptionPlanDayKey
    ) throws -> (iPhone: [TaptionPlanRawEvent], watch: [TaptionPlanRawEvent]) {
        var iPhone: [TaptionPlanRawEvent] = []
        var watch: [TaptionPlanRawEvent] = []
        for envelope in rawEnvelopes {
            let device = envelope.source == .appleWatch
                ? TaptionPlanStoreDevice.appleWatch
                : TaptionPlanStoreDevice.iPhone
            let rawEvent = try event(
                value: envelope,
                device: device,
                day: day,
                timestamp: envelope.capturedAt,
                sequence: 0,
                id: envelope.id.uuidString,
                domain: "raw-device-data",
                provenance: [
                    "source-device:\(device.rawValue)",
                    "source:\(envelope.source.rawValue)",
                    "legacy:raw-device-data",
                ]
            )
            if device == .appleWatch {
                watch.append(rawEvent)
                iPhone.append(
                    try event(
                        value: envelope,
                        device: .iPhone,
                        day: day,
                        timestamp: envelope.capturedAt,
                        sequence: 0,
                        id: envelope.id.uuidString,
                        domain: "raw-device-data",
                        provenance: [
                            "source-device:appleWatch",
                            "source:\(envelope.source.rawValue)",
                            "legacy:raw-device-data",
                            "merge:iPhone",
                        ]
                    )
                )
            } else {
                iPhone.append(rawEvent)
            }
        }
        for summary in watchSummaries {
            let payload = TaptionPlanCanonicalStorage.envelope(
                for: try TaptionPlanCanonicalStorage.encode(summary)
            )
            let id = "\(summary.sessionID.uuidString):\(summary.sequence)"
            let sequence = UInt64(max(0, summary.sequence))
            let watchEvent = TaptionPlanRawEvent(
                device: .appleWatch,
                day: day,
                timestamp: summary.endedAt,
                sequence: sequence,
                id: id,
                domain: "watch-sensor-summary",
                provenance: Self.watchSummaryProvenance,
                payload: payload
            )
            let iPhoneEvent = TaptionPlanRawEvent(
                device: .iPhone,
                day: day,
                timestamp: summary.endedAt,
                sequence: sequence,
                id: id,
                domain: "watch-sensor-summary",
                provenance: Self.watchSummaryProvenance + ["merge:iPhone"],
                payload: payload
            )
            watch.append(watchEvent)
            iPhone.append(iPhoneEvent)
        }
        for chunk in watchAccelerationChunks {
            let payload = TaptionPlanCanonicalStorage.envelope(
                for: try TaptionPlanCanonicalStorage.encode(chunk)
            )
            let sequence = UInt64(max(0, chunk.sequence))
            let provenance = [
                "source-device:appleWatch",
                "source:WatchAcceleration",
                "derived:downsampled-accelerometer-v1",
            ]
            watch.append(TaptionPlanRawEvent(
                device: .appleWatch,
                day: day,
                timestamp: chunk.endedAt,
                sequence: sequence,
                id: chunk.id.uuidString,
                domain: "watch-acceleration",
                provenance: provenance,
                payload: payload
            ))
            iPhone.append(TaptionPlanRawEvent(
                device: .iPhone,
                day: day,
                timestamp: chunk.endedAt,
                sequence: sequence,
                id: chunk.id.uuidString,
                domain: "watch-acceleration",
                provenance: provenance + ["merge:iPhone"],
                payload: payload
            ))
        }
        return (iPhone, watch)
    }

    private func validate(
        expected: [TaptionPlanRawEvent],
        actual: [TaptionPlanRawEvent],
        day: TaptionPlanDayKey,
        device: TaptionPlanStoreDevice,
        exactDigestDayCount: inout Int
    ) throws {
        let storedExpected = expected.map { event in
            TaptionPlanRawEvent(
                device: event.device,
                day: event.day,
                timestamp: Date(
                    timeIntervalSince1970: event.timestamp.timeIntervalSince1970
                ),
                sequence: event.sequence,
                id: event.id,
                domain: event.domain,
                provenance: event.provenance,
                payload: event.payload
            )
        }
        let actualSet = Set(actual)
        if let missing = storedExpected.first(where: { !actualSet.contains($0) }) {
            let stored = actual.first {
                $0.domain == missing.domain && $0.id == missing.id
            }
            let difference = stored.map {
                "day=\($0.day == missing.day) timestamp=\($0.timestamp == missing.timestamp) sequence=\(missing.sequence)/\($0.sequence) provenance=\($0.provenance == missing.provenance) payload=\($0.payload == missing.payload)"
            } ?? "stored=false"
            throw PlanDayDatabaseMigrationError.rawDigestMismatch(
                day: day,
                device: device,
                reason: "missing=\(missing.domain)/\(missing.id) \(difference) expected=\(expected.count) actual=\(actual.count)"
            )
        }
        let expectedDigest = TaptionPlanV3Store.digest(
            events: expected,
            device: device,
            day: day
        )
        let actualDigest = TaptionPlanV3Store.digest(
            events: actual,
            device: device,
            day: day
        )
        if expectedDigest.eventCount == actualDigest.eventCount {
            guard expectedDigest.sha256 == actualDigest.sha256 else {
                throw PlanDayDatabaseMigrationError.rawDigestMismatch(
                    day: day,
                    device: device,
                    reason: "expected=\(expectedDigest.sha256.prefix(12)) actual=\(actualDigest.sha256.prefix(12)) count=\(actual.count)"
                )
            }
            exactDigestDayCount += 1
        }
    }

    private func rawEvents(
        for snapshot: PlanDayDataSnapshot
    ) throws -> (iPhone: [TaptionPlanRawEvent], watch: [TaptionPlanRawEvent]) {
        let day = TaptionPlanDayKey(date: snapshot.day)
        var iPhone: [TaptionPlanRawEvent] = []
        var watch: [TaptionPlanRawEvent] = []

        for (index, actual) in snapshot.actuals.enumerated() {
            iPhone.append(
                try projectionEvent(
                    value: actual,
                    sourceID: actual.id,
                    device: .iPhone,
                    day: day,
                    projectionDay: day,
                    timestamp: actual.startedAt,
                    sequence: index,
                    domain: "plan-actual",
                    provenance: ["source:\(actual.source.rawValue)", "projection:day"]
                        + TaptionActivityEngineAdapter.provenanceMarkers(for: actual)
                )
            )
        }
        for (index, place) in snapshot.places.enumerated() {
            iPhone.append(
                try projectionEvent(
                    value: place,
                    sourceID: place.id,
                    device: .iPhone,
                    day: day,
                    projectionDay: day,
                    timestamp: place.span.start,
                    sequence: index,
                    domain: "plan-place",
                    provenance: ["source:place-resolution", "projection:day"]
                        + TaptionActivityEngineAdapter.provenanceMarkers(for: place)
                )
            )
        }
        for (index, travel) in snapshot.travel.enumerated() {
            iPhone.append(
                try projectionEvent(
                    value: travel,
                    sourceID: travel.id,
                    device: .iPhone,
                    day: day,
                    projectionDay: day,
                    timestamp: travel.span.start,
                    sequence: index,
                    domain: "plan-travel",
                    provenance: ["source:\(travel.mode.rawValue)", "projection:day"]
                        + TaptionActivityEngineAdapter.provenanceMarkers(for: travel)
                )
            )
        }
        for (index, reading) in snapshot.readings.enumerated() {
            let sourceDevice = reading.sourceDevice == .appleWatch
                ? TaptionPlanStoreDevice.appleWatch
                : TaptionPlanStoreDevice.iPhone
            let provenance = [
                "source-device:\(reading.sourceDevice?.rawValue ?? "iPhone")",
                "projection:day",
            ] + TaptionActivityEngineAdapter.provenanceMarkers(for: reading)
            let readingEvent = try projectionEvent(
                value: reading,
                sourceID: reading.id,
                device: .iPhone,
                day: TaptionPlanDayKey(date: reading.timestamp),
                projectionDay: day,
                timestamp: reading.timestamp,
                sequence: reading.sequence ?? index,
                domain: "sensor-reading",
                provenance: provenance
            )
            iPhone.append(readingEvent)
            if sourceDevice == .appleWatch {
                watch.append(
                    TaptionPlanRawEvent(
                        device: .appleWatch,
                        day: readingEvent.day,
                        timestamp: readingEvent.timestamp,
                        sequence: readingEvent.sequence,
                        id: readingEvent.id,
                        domain: readingEvent.domain,
                        provenance: readingEvent.provenance,
                        payload: readingEvent.payload
                    )
                )
            }
        }
        return (iPhone, watch)
    }

    private func event<Value: Encodable>(
        value: Value,
        device: TaptionPlanStoreDevice,
        day: TaptionPlanDayKey,
        timestamp: Date,
        sequence: Int,
        id: String,
        domain: String,
        provenance: [String]
    ) throws -> TaptionPlanRawEvent {
        TaptionPlanRawEvent(
            device: device,
            day: day,
            timestamp: timestamp,
            sequence: UInt64(max(0, sequence)),
            id: id,
            domain: domain,
            provenance: provenance,
            payload: TaptionPlanCanonicalStorage.envelope(
                for: try TaptionPlanCanonicalStorage.encode(value)
            )
        )
    }

    private func projectionEvent<Value: Encodable>(
        value: Value,
        sourceID: UUID,
        device: TaptionPlanStoreDevice,
        day: TaptionPlanDayKey,
        projectionDay: TaptionPlanDayKey,
        timestamp: Date,
        sequence: Int,
        domain: String,
        provenance: [String]
    ) throws -> TaptionPlanRawEvent {
        let encoded = try TaptionPlanCanonicalStorage.encode(value)
        let dayKey = String(
            format: "%04d-%02d-%02d",
            projectionDay.year,
            projectionDay.month,
            projectionDay.day
        )
        // A new projection generation must not collide with an older immutable
        // projection event when the same source ID receives a new classification.
        return TaptionPlanRawEvent(
            device: device,
            day: day,
            timestamp: timestamp,
            sequence: UInt64(max(0, sequence)),
            id: "\(sourceID.uuidString):\(dayKey):\(encoded.checksum)",
            domain: domain,
            provenance: provenance,
            payload: TaptionPlanCanonicalStorage.envelope(for: encoded)
        )
    }
}

private enum PlanDayDatabaseError: Error {
    case invalidMaterializedDay
}

@MainActor
final class PlanDayLoadCoordinator {
    private struct CacheKey: Hashable {
        let day: TaptionPlanDayKey
        let sourceFingerprint: String
        let projectionVersion: UInt64
    }

    private let database: PlanDayDatabase
    private let cacheCapacity: Int
    private var cache: [CacheKey: PlanDayDataSnapshot] = [:]
    private var recency: [CacheKey] = []
    private struct InFlightRequest {
        let id: UUID
        let task: Task<PlanDayDataSnapshot, Never>
    }

    private var inFlight: [CacheKey: InFlightRequest] = [:]
    private var prefetchTask: Task<Void, Never>?
    private var forceReloadDays: Set<TaptionPlanDayKey> = []

    init(
        database: PlanDayDatabase,
        cacheCapacity: Int = 42
    ) {
        self.database = database
        self.cacheCapacity = max(1, cacheCapacity)
    }

    deinit {
        prefetchTask?.cancel()
        for request in inFlight.values {
            request.task.cancel()
        }
    }

    func load(
        day: Date,
        source: TaptionDataSnapshot,
        sourceRevision: UInt64,
        sensorLoader: @escaping (Date) async -> SensorReadingsLoadResult,
        forceReload requestedForceReload: Bool = false
    ) async -> PlanDayDataSnapshot {
        let loadStartedAt = ProcessInfo.processInfo.systemUptime
        let dayStart = Calendar.autoupdatingCurrent.startOfDay(for: day)
        let sourceFingerprint = PlanDayDataSnapshot.sourceFingerprint(
            date: dayStart,
            source: source
        )
        let key = CacheKey(
            day: TaptionPlanDayKey(date: dayStart),
            sourceFingerprint: sourceFingerprint
                ?? "revision:\(sourceRevision)",
            projectionVersion: TaptionPlanV3Store.projectionVersion
        )
        let pendingForceReload = forceReloadDays.remove(key.day) != nil
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
        if let cached = cache[key] {
            if !forceReload, cached.isComplete {
                touch(key)
                return finish(cached, source: "memory_cache")
            }
            cache.removeValue(forKey: key)
            recency.removeAll { $0 == key }
        }
        if !forceReload,
           let staleKey = recency.reversed().first(where: { $0.day == key.day }),
           let stale = cache[staleKey],
           stale.isComplete {
            let projectionStartedAt = ProcessInfo.processInfo.systemUptime
            let reprojected = PlanDayDataSnapshot.make(
                date: dayStart,
                sourceRevision: sourceRevision,
                source: source,
                sensorResult: SensorReadingsLoadResult(
                    readings: stale.readings,
                    isComplete: true
                )
            )
            return finish(
                reprojected,
                source: "reprojected_memory_raw",
                durations: [
                    "projection_ms": ProcessInfo.processInfo.systemUptime
                        - projectionStartedAt,
                ]
            )
        }
        cancelRequests(except: key)
        if let existing = inFlight[key] {
            if !forceReload {
                return await existing.task.value
            }
            existing.task.cancel()
            inFlight.removeValue(forKey: key)
        }

        let database = self.database
        let task = Task { @MainActor [source, database, forceReload] in
            let databaseStartedAt = ProcessInfo.processInfo.systemUptime
            if !forceReload,
               let cached = try? await database.load(
                day: dayStart,
                sourceRevision: sourceRevision,
                sourceFingerprint: sourceFingerprint
               ), cached.isComplete {
                return finish(
                    cached,
                    source: "database_cache",
                    durations: [
                        "database_ms": ProcessInfo.processInfo.systemUptime
                            - databaseStartedAt,
                    ]
                )
            }
            let databaseDuration = ProcessInfo.processInfo.systemUptime
                - databaseStartedAt
            var durations = ["database_ms": databaseDuration]
            if !forceReload,
               let stale = try? await database.load(
                day: dayStart,
                sourceRevision: sourceRevision,
                sourceFingerprint: sourceFingerprint,
                allowStaleSourceFingerprint: true
               ), stale.isComplete {
                let projectionStartedAt = ProcessInfo.processInfo.systemUptime
                let reprojected = PlanDayDataSnapshot.make(
                    date: dayStart,
                    sourceRevision: sourceRevision,
                    source: source,
                    sensorResult: SensorReadingsLoadResult(
                        readings: stale.readings,
                        isComplete: true
                    )
                )
                durations["projection_ms"] = ProcessInfo.processInfo
                    .systemUptime - projectionStartedAt
                guard !Task.isCancelled else {
                    return finish(
                        reprojected,
                        source: "reprojected_database_raw_cancelled",
                        durations: durations
                    )
                }
                let persistenceStartedAt = ProcessInfo.processInfo.systemUptime
                try? await database.save(reprojected)
                durations["persistence_ms"] = ProcessInfo.processInfo
                    .systemUptime - persistenceStartedAt
                return finish(
                    reprojected,
                    source: "reprojected_database_raw",
                    durations: durations
                )
            }
            let sensorStartedAt = ProcessInfo.processInfo.systemUptime
            let sensorResult = await sensorLoader(dayStart)
            durations["sensor_ms"] = ProcessInfo.processInfo.systemUptime
                - sensorStartedAt
            let projectionStartedAt = ProcessInfo.processInfo.systemUptime
            let projected = PlanDayDataSnapshot.make(
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
            let persistenceStartedAt = ProcessInfo.processInfo.systemUptime
            try? await database.save(projected)
            durations["persistence_ms"] = ProcessInfo.processInfo.systemUptime
                - persistenceStartedAt
            if let readBack = try? await database.load(
                day: dayStart,
                sourceRevision: sourceRevision,
                sourceFingerprint: sourceFingerprint
            ) {
                return finish(
                    readBack,
                    source: "rebuilt_readback",
                    durations: durations
                )
            }
            return finish(
                projected,
                source: "rebuilt_memory",
                durations: durations
            )
        }
        let request = InFlightRequest(id: UUID(), task: task)
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
            let sourceFingerprint = PlanDayDataSnapshot.sourceFingerprint(
                date: day,
                source: source
            )
            let key = CacheKey(
                day: TaptionPlanDayKey(date: day),
                sourceFingerprint: sourceFingerprint
                    ?? "revision:\(sourceRevision)",
                projectionVersion: TaptionPlanV3Store.projectionVersion
            )
            if cache[key] == nil {
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
        forceReloadDays.insert(dayKey)
        let keys = Set(cache.keys.filter { $0.day == dayKey })
            .union(inFlight.keys.filter { $0.day == dayKey })
        for key in keys {
            cache.removeValue(forKey: key)
            recency.removeAll { $0 == key }
            inFlight[key]?.task.cancel()
            inFlight.removeValue(forKey: key)
        }
        // The next load bypasses the materialized row and replaces it only
        // after the fresh projection is ready. Avoid an asynchronous delete
        // racing that save/readback pair.
    }

    func handleMemoryPressure() {
        cache.removeAll()
        recency.removeAll()
    }

    func invalidateAll() async {
        let prefetch = prefetchTask
        let requests = inFlight.values.map(\.task)
        prefetch?.cancel()
        prefetchTask = nil
        requests.forEach { $0.cancel() }
        inFlight.removeAll()
        forceReloadDays.removeAll()
        cache.removeAll()
        recency.removeAll()
        await prefetch?.value
        for request in requests { _ = await request.value }
    }

    var cachedDayCount: Int { cache.count }

    private func cancelRequests(except key: CacheKey) {
        let requests = inFlight.filter { $0.key != key }
        for (otherKey, request) in requests {
            request.task.cancel()
            inFlight.removeValue(forKey: otherKey)
        }
    }

    private func insert(_ value: PlanDayDataSnapshot, for key: CacheKey) {
        cache[key] = value
        touch(key)
        while recency.count > cacheCapacity, let oldest = recency.first {
            recency.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    private func touch(_ key: CacheKey) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}
