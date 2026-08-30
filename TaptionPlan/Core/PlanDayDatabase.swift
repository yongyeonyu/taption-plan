import Foundation
import OSLog
import TaptionPlanCore

private struct PlanDayDatabasePayload: Codable, Hashable, Sendable {
    let day: Date
    let sourceUpdatedAt: Date
    let actuals: [ActualRecord]
    let places: [PlaceStay]
    let travel: [TravelSegment]
    let readings: [SensorReading]
    let isComplete: Bool
}

private struct PlanDayWatchMaterializedPayload: Codable, Hashable, Sendable {
    let day: TaptionPlanDayKey
    let summaries: [TaptionWatchSensorSummary]
}

struct PlanDayDatabaseMigrationReport: Equatable, Sendable {
    let dayCount: Int
    let iPhoneEventCount: Int
    let watchEventCount: Int
    let exactDigestDayCount: Int
}

private enum PlanDayDatabaseMigrationError: Error {
    case rawDigestMismatch(day: TaptionPlanDayKey, device: TaptionPlanStoreDevice)
}

/// App adapter for the package-owned v3 stores. Raw records are copied into
/// the stores before the derived day row is replaced; the old archives remain
/// untouched until an externally verified migration authorizes cleanup.
actor PlanDayDatabase {
    private static let legacyMigrationMarker = "legacy-v2-to-v3"
    private static let legacyMigrationFailedMarker = "legacy-v2-to-v3-failed"
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
    }

    static func applicationSupport(
        fileManager: FileManager = .default
    ) throws -> PlanDayDatabase {
        if let group = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: TaptionWidgetSharedStore.appGroupIdentifier
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

    func load(
        day: Date,
        sourceRevision: UInt64
    ) async throws -> PlanDayDataSnapshot? {
        guard try await iPhoneStore.migrationCompleted(Self.legacyMigrationMarker),
              !(try await iPhoneStore.migrationCompleted(Self.legacyMigrationFailedMarker)) else {
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
        let row = try await iPhoneStore.materializedDay(for: dayKey)
        guard let row,
              row.sourceRevision == sourceRevision,
              row.projectionVersion == TaptionPlanV3Store.projectionVersion else {
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
        let encoded = try TaptionPlanCanonicalStorage.encodedPayload(from: row.payload)
        let payload = try TaptionPlanCanonicalStorage.decode(
            PlanDayDatabasePayload.self,
            from: encoded
        )
        guard Calendar.autoupdatingCurrent.isDate(payload.day, inSameDayAs: day) else {
            throw PlanDayDatabaseError.invalidMaterializedDay
        }
        return PlanDayDataSnapshot(
            day: payload.day,
            sourceRevision: row.sourceRevision,
            sourceUpdatedAt: payload.sourceUpdatedAt,
            projectionVersion: row.projectionVersion,
            actuals: payload.actuals,
            places: payload.places,
            travel: payload.travel,
            readings: payload.readings,
            isComplete: payload.isComplete
        )
    }

    func save(_ snapshot: PlanDayDataSnapshot) async throws {
        try await save(snapshot, additionalIPhoneEvents: [], additionalWatchEvents: [])
    }

    func migrateLegacyIfNeeded(
        source: TaptionDataSnapshot,
        sourceRevision: UInt64,
        readings: [SensorReading],
        watchSummaries: [TaptionWatchSensorSummary],
        rawEnvelopes: [RawDeviceDataEnvelope]
    ) async throws -> PlanDayDatabaseMigrationReport? {
        let migrationCompleted = try await iPhoneStore.migrationCompleted(
            Self.legacyMigrationMarker
        )
        let migrationFailed = try await iPhoneStore.migrationCompleted(
            Self.legacyMigrationFailedMarker
        )
        guard !migrationCompleted && !migrationFailed else { return nil }

        let calendar = Calendar.autoupdatingCurrent
        let days = migrationDays(
            source: source,
            readings: readings,
            watchSummaries: watchSummaries,
            rawEnvelopes: rawEnvelopes,
            calendar: calendar
        )
        func importAndValidate(regenerate: Bool) async throws -> PlanDayDatabaseMigrationReport {
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
                let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
                    ?? dayStart.addingTimeInterval(86_400)
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
                    rawEnvelopes: rawEnvelopes.filter {
                        $0.capturedAt >= dayStart && $0.capturedAt < dayEnd
                    },
                    watchSummaries: watchSummaries.filter {
                        $0.endedAt >= dayStart && $0.endedAt < dayEnd
                    },
                    day: dayKey
                )
                let expectedIPhone = baseEvents.iPhone + extras.iPhone
                let expectedWatch = baseEvents.watch + extras.watch
                if regenerate {
                    try await iPhoneStore.removeMaterializedDay(for: dayKey)
                    try await watchStore.removeMaterializedDay(for: dayKey)
                }
                try await save(
                    snapshot,
                    additionalIPhoneEvents: extras.iPhone,
                    additionalWatchEvents: extras.watch
                )

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
            report = try await importAndValidate(regenerate: false)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            do {
                report = try await importAndValidate(regenerate: true)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                _ = try? await iPhoneStore.markMigrationCompleted(
                    Self.legacyMigrationFailedMarker
                )
                throw error
            }
        }

        guard !Task.isCancelled else { throw CancellationError() }
        _ = try await iPhoneStore.markMigrationCompleted(
            Self.legacyMigrationMarker
        )
        return report
    }

    private func save(
        _ snapshot: PlanDayDataSnapshot,
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
            actuals: snapshot.actuals,
            places: snapshot.places,
            travel: snapshot.travel,
            readings: snapshot.readings,
            isComplete: snapshot.isComplete
        )
        let encodedPayload = try TaptionPlanCanonicalStorage.encode(payload)
        let materializedPayload = TaptionPlanCanonicalStorage.envelope(for: encodedPayload)
        let events = try rawEvents(for: snapshot)
        try await iPhoneStore.appendRawEvents(
            events.iPhone + additionalIPhoneEvents
        )
        try await watchStore.appendRawEvents(
            events.watch + additionalWatchEvents
        )
        let dayKey = TaptionPlanDayKey(date: snapshot.day)
        let iPhoneDigest = try await iPhoneStore.rawDigest(
            for: dayKey
        )
        let watchDigest = try await watchStore.rawDigest(
            for: dayKey
        )
        let combinedDigest = TaptionPlanCanonicalStorage.checksum(
            Data("\(iPhoneDigest.sha256):\(watchDigest.sha256)".utf8)
        )
        let iPhoneEvents = try await iPhoneStore.rawEvents(for: dayKey)
        let watchEvents = try await watchStore.rawEvents(for: dayKey)
        let allEvents = iPhoneEvents + watchEvents
        let firstTimestamp = allEvents.map(\.timestamp).min()
        let lastTimestamp = allEvents.map(\.timestamp).max()
        let row = TaptionPlanMaterializedDay(
            device: .iPhone,
            day: TaptionPlanDayKey(date: snapshot.day),
            sourceRevision: snapshot.sourceRevision,
            projectionVersion: TaptionPlanV3Store.projectionVersion,
            rawDigest: combinedDigest,
            rawEventCount: allEvents.count,
            firstTimestamp: firstTimestamp,
            lastTimestamp: lastTimestamp,
            payload: materializedPayload
        )
        try await iPhoneStore.replaceMaterializedDay(row)
        if watchDigest.eventCount > 0 {
            try await materializeWatchDay(for: dayKey)
        }
        Self.logger.debug(
            "Materialized day saved: day=\(row.day.year)-\(row.day.month)-\(row.day.day, privacy: .public), events=\(row.rawEventCount, privacy: .public)"
        )
    }

    /// Persists the Watch raw summary in the Watch store and in the iPhone
    /// merge store. The source device and transport remain in provenance; the
    /// received record is never rewritten into the Watch's original shape.
    func recordWatchSummary(_ summary: TaptionWatchSensorSummary) async throws {
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
        try await watchStore.appendRawEvents([watchEvent])
        try await iPhoneStore.appendRawEvents([mergedEvent])
        try await materializeWatchDay(for: day)
        try await iPhoneStore.removeMaterializedDay(for: day)
    }

    func invalidate(day: Date) async throws {
        try await iPhoneStore.removeMaterializedDay(
            for: TaptionPlanDayKey(date: day)
        )
    }

    private func materializeWatchDay(for day: TaptionPlanDayKey) async throws {
        let events = try await watchStore.rawEvents(
            for: day,
            domain: "watch-sensor-summary"
        )
        let summaries = try events.map { event -> TaptionWatchSensorSummary in
            let encoded = try TaptionPlanCanonicalStorage.encodedPayload(
                from: event.payload
            )
            return try TaptionPlanCanonicalStorage.decode(
                TaptionWatchSensorSummary.self,
                from: encoded
            )
        }
        let digest = try await watchStore.rawDigest(for: day)
        let payload = try TaptionPlanCanonicalStorage.encode(
            PlanDayWatchMaterializedPayload(day: day, summaries: summaries)
        )
        try await watchStore.replaceMaterializedDay(
            TaptionPlanMaterializedDay(
                device: .appleWatch,
                day: day,
                sourceRevision: UInt64(digest.eventCount),
                projectionVersion: TaptionPlanV3Store.projectionVersion,
                rawDigest: digest.sha256,
                rawEventCount: digest.eventCount,
                firstTimestamp: digest.firstTimestamp,
                lastTimestamp: digest.lastTimestamp,
                payload: TaptionPlanCanonicalStorage.envelope(for: payload)
            )
        )
    }

    private func migrationDays(
        source: TaptionDataSnapshot,
        readings: [SensorReading],
        watchSummaries: [TaptionWatchSensorSummary],
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
        rawEnvelopes.forEach { add($0.capturedAt) }
        return keys.sorted()
    }

    private func migrationEvents(
        rawEnvelopes: [RawDeviceDataEnvelope],
        watchSummaries: [TaptionWatchSensorSummary],
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
        return (iPhone, watch)
    }

    private func validate(
        expected: [TaptionPlanRawEvent],
        actual: [TaptionPlanRawEvent],
        day: TaptionPlanDayKey,
        device: TaptionPlanStoreDevice,
        exactDigestDayCount: inout Int
    ) throws {
        guard Set(expected).isSubset(of: Set(actual)) else {
            throw PlanDayDatabaseMigrationError.rawDigestMismatch(
                day: day,
                device: device
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
            guard expectedDigest == actualDigest else {
                throw PlanDayDatabaseMigrationError.rawDigestMismatch(
                    day: day,
                    device: device
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
                try event(
                    value: actual,
                    device: .iPhone,
                    day: day,
                    timestamp: actual.startedAt,
                    sequence: index,
                    id: projectionID(actual.id, day: day),
                    domain: "plan-actual",
                    provenance: ["source:\(actual.source.rawValue)", "projection:day"]
                )
            )
        }
        for (index, place) in snapshot.places.enumerated() {
            iPhone.append(
                try event(
                    value: place,
                    device: .iPhone,
                    day: day,
                    timestamp: place.span.start,
                    sequence: index,
                    id: projectionID(place.id, day: day),
                    domain: "plan-place",
                    provenance: ["source:place-resolution", "projection:day"]
                )
            )
        }
        for (index, travel) in snapshot.travel.enumerated() {
            iPhone.append(
                try event(
                    value: travel,
                    device: .iPhone,
                    day: day,
                    timestamp: travel.span.start,
                    sequence: index,
                    id: projectionID(travel.id, day: day),
                    domain: "plan-travel",
                    provenance: ["source:\(travel.mode.rawValue)", "projection:day"]
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
            ]
            let readingEvent = try event(
                value: reading,
                device: .iPhone,
                day: TaptionPlanDayKey(date: reading.timestamp),
                timestamp: reading.timestamp,
                sequence: reading.sequence ?? index,
                id: reading.id.uuidString,
                domain: "sensor-reading",
                provenance: provenance
            )
            iPhone.append(readingEvent)
            if sourceDevice == .appleWatch {
                watch.append(
                    try event(
                        value: reading,
                        device: .appleWatch,
                        day: TaptionPlanDayKey(date: reading.timestamp),
                        timestamp: reading.timestamp,
                        sequence: reading.sequence ?? index,
                        id: reading.id.uuidString,
                        domain: "sensor-reading",
                        provenance: provenance
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

    private func projectionID(_ id: UUID, day: TaptionPlanDayKey) -> String {
        "\(id.uuidString):\(String(format: "%04d-%02d-%02d", day.year, day.month, day.day))"
    }
}

private enum PlanDayDatabaseError: Error {
    case invalidMaterializedDay
}

@MainActor
final class PlanDayLoadCoordinator {
    private struct CacheKey: Hashable {
        let day: TaptionPlanDayKey
        let sourceRevision: UInt64
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
        sensorLoader: @escaping (Date) async -> SensorReadingsLoadResult
    ) async -> PlanDayDataSnapshot {
        let dayStart = Calendar.autoupdatingCurrent.startOfDay(for: day)
        let key = CacheKey(
            day: TaptionPlanDayKey(date: dayStart),
            sourceRevision: sourceRevision,
            projectionVersion: TaptionPlanV3Store.projectionVersion
        )
        if let cached = cache[key] {
            touch(key)
            return cached
        }
        cancelRequests(except: key)
        if let existing = inFlight[key] {
            return await existing.task.value
        }

        let database = self.database
        let task = Task { @MainActor [source, database] in
            if let cached = try? await database.load(
                day: dayStart,
                sourceRevision: sourceRevision
            ) {
                return cached
            }
            let sensorResult = await sensorLoader(dayStart)
            let projected = PlanDayDataSnapshot.make(
                date: dayStart,
                sourceRevision: sourceRevision,
                source: source,
                sensorResult: sensorResult
            )
            guard !Task.isCancelled else { return projected }
            try? await database.save(projected)
            return projected
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
        insert(result, for: key)
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
            let key = CacheKey(
                day: TaptionPlanDayKey(date: day),
                sourceRevision: sourceRevision,
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
        let keys = Set(cache.keys.filter { $0.day == dayKey })
            .union(inFlight.keys.filter { $0.day == dayKey })
        for key in keys {
            cache.removeValue(forKey: key)
            recency.removeAll { $0 == key }
            inFlight[key]?.task.cancel()
            inFlight.removeValue(forKey: key)
        }
        Task {
            try? await database.invalidate(day: day)
        }
    }

    func handleMemoryPressure() {
        cache.removeAll()
        recency.removeAll()
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
