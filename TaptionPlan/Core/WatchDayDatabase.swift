import Foundation
import TaptionPlanCore

/// The Watch keeps its own append-only v3 store.  WatchConnectivity is only a
/// transport; a summary is persisted here before it is sent to the iPhone.
actor WatchDayDatabase {
    private static let fileName = "taption-plan-watch-v3.sqlite"

    private let store: TaptionPlanV3Store

    init?() {
        guard let directory = Self.directory(),
              let store = try? TaptionPlanV3Store(
                url: directory.appendingPathComponent(Self.fileName),
                device: .appleWatch
              ) else { return nil }
        self.store = store
    }

    init?(directory: URL) {
        guard let store = try? TaptionPlanV3Store(
            url: directory.appendingPathComponent(Self.fileName),
            device: .appleWatch
        ) else { return nil }
        self.store = store
    }

    func append(_ summary: TaptionWatchSensorSummary) async throws {
        try await appendBatch([summary])
    }

    func append(_ chunk: TaptionWatchAccelerationChunk) async throws {
        try await appendBatch([], chunks: [chunk])
    }

    func appendBatch(_ summaries: [TaptionWatchSensorSummary]) async throws {
        try await appendBatch(summaries, chunks: [])
    }

    func appendBatch(
        _ summaries: [TaptionWatchSensorSummary],
        chunks: [TaptionWatchAccelerationChunk]
    ) async throws {
        guard !summaries.isEmpty || !chunks.isEmpty else { return }
        let chunkEvents = try chunks.map { chunk -> TaptionPlanRawEvent in
            let payload = try TaptionPlanCanonicalStorage.encode(chunk)
            return TaptionPlanRawEvent(
                device: .appleWatch,
                day: TaptionPlanDayKey(date: chunk.endedAt),
                timestamp: chunk.endedAt,
                sequence: UInt64(max(0, chunk.sequence)),
                id: chunk.id.uuidString,
                domain: "watch-acceleration",
                provenance: [
                    "source-device:appleWatch",
                    "source:WatchAcceleration",
                    "storage:watch-v3",
                    "derived:downsampled-accelerometer-v1",
                    "sample-count:\(chunk.samples.count)",
                ],
                payload: TaptionPlanCanonicalStorage.envelope(for: payload)
            )
        }
        let summaryEvents = try summaries.map { summary -> TaptionPlanRawEvent in
            let day = TaptionPlanDayKey(date: summary.endedAt)
            let id = "\(summary.sessionID.uuidString):\(summary.sequence)"
            let payload = try TaptionPlanCanonicalStorage.encode(summary)
            return TaptionPlanRawEvent(
                device: .appleWatch,
                day: day,
                timestamp: summary.endedAt,
                sequence: UInt64(max(0, summary.sequence)),
                id: id,
                domain: "watch-sensor-summary",
                provenance: [
                    "source-device:appleWatch",
                    "source:WatchSensorSummary",
                    "storage:watch-v3",
                ],
                payload: TaptionPlanCanonicalStorage.envelope(for: payload)
            )
        }
        try await store.appendRawEvents(chunkEvents + summaryEvents)
    }

    func enqueueAmbientBatch(
        _ summaries: [TaptionWatchSensorSummary],
        chunks: [TaptionWatchAccelerationChunk]
    ) async throws {
        guard !summaries.isEmpty || !chunks.isEmpty else { return }
        var days = Set<TaptionPlanDayKey>()
        for summary in summaries {
            days.insert(TaptionPlanDayKey(date: summary.ambientWindowStart ?? summary.endedAt))
            days.insert(TaptionPlanDayKey(date: summary.startedAt))
            days.insert(TaptionPlanDayKey(date: summary.endedAt))
        }
        for chunk in chunks {
            days.insert(TaptionPlanDayKey(date: chunk.ambientWindowStart ?? chunk.endedAt))
            days.insert(TaptionPlanDayKey(date: chunk.startedAt))
            days.insert(TaptionPlanDayKey(date: chunk.endedAt))
        }
        var storedEvents: [TaptionPlanRawEvent] = []
        for day in days {
            storedEvents += try await store.rawEvents(for: day)
        }
        var storedSummaries = try storedEvents
            .filter { $0.domain == "watch-sensor-summary" }
            .map { try Self.decode(TaptionWatchSensorSummary.self, from: $0) }
        var storedChunks = try storedEvents
            .filter { $0.domain == "watch-acceleration" }
            .map { try Self.decode(TaptionWatchAccelerationChunk.self, from: $0) }

        var rawEvents: [TaptionPlanRawEvent] = []
        var outboxItems: [TaptionPlanV3OutboxItem] = []
        let encoder = JSONEncoder()
        for value in summaries {
            guard let summary = try TaptionWatchAmbientRevisionPolicy
                .nextSummaryRevision(for: value, existing: storedSummaries)
            else { continue }
            let event = try Self.watchSummaryEvent(summary)
            if storedEvents.contains(where: { $0 == event }) { continue }
            let message = try encoder.encode(summary)
            rawEvents.append(event)
            outboxItems.append(
                TaptionPlanV3OutboxItem(
                    id: "summary:\(summary.rawEventID)",
                    kind: TaptionWatchEnvelope.sensorSummaryKey,
                    payload: message
                )
            )
            storedEvents.append(event)
            storedSummaries.append(summary)
        }
        for value in chunks {
            let windowStart = value.sessionID.flatMap { sessionID in
                summaries.first {
                    $0.sessionID == sessionID
                        && $0.sequence == value.sequence
                }.map { $0.ambientWindowStart ?? $0.startedAt }
            }
            guard let chunk = try TaptionWatchAmbientRevisionPolicy
                .nextChunkRevision(
                    for: value,
                    existing: storedChunks,
                    windowStart: windowStart
                )
            else { continue }
            let event = try Self.watchAccelerationEvent(chunk)
            if storedEvents.contains(where: { $0 == event }) { continue }
            let message = try encoder.encode(chunk)
            rawEvents.append(event)
            outboxItems.append(
                TaptionPlanV3OutboxItem(
                    id: "chunk:\(chunk.id.uuidString)",
                    kind: TaptionWatchEnvelope.accelerationChunkKey,
                    payload: message
                )
            )
            storedEvents.append(event)
            storedChunks.append(chunk)
        }
        try await store.appendRawEvents(rawEvents, outboxItems: outboxItems)
    }

    func pendingAmbientOutbox(
        limit: Int = 50
    ) async throws -> [TaptionPlanV3OutboxItem] {
        try await store.pendingOutboxItems(limit: limit)
    }

    func acknowledgeAmbientOutbox(ids: [String]) async throws {
        try await store.deleteOutboxItems(ids: ids)
    }

    func deleteAll() async throws {
        try await store.deleteAllData()
    }

    private static func directory() -> URL? {
        let fileManager = FileManager.default
        if let group = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: TaptionPlanSharedContainer.appGroupIdentifier
        ) {
            return group
        }
        guard let root = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return nil
        }
        return root.appendingPathComponent("TaptionPlan", isDirectory: true)
    }

    private static func watchSummaryEvent(
        _ summary: TaptionWatchSensorSummary
    ) throws -> TaptionPlanRawEvent {
        let dayDate = summary.ambientWindowStart ?? summary.endedAt
        let payload = try TaptionPlanCanonicalStorage.encode(summary)
        return TaptionPlanRawEvent(
            device: .appleWatch,
            day: TaptionPlanDayKey(date: dayDate),
            timestamp: dayDate,
            sequence: UInt64(max(0, summary.sequence)),
            id: summary.rawEventID,
            domain: "watch-sensor-summary",
            provenance: [
                "source-device:appleWatch",
                "source:WatchSensorSummary",
                "storage:watch-v3",
            ],
            payload: TaptionPlanCanonicalStorage.envelope(for: payload)
        )
    }

    private static func watchAccelerationEvent(
        _ chunk: TaptionWatchAccelerationChunk
    ) throws -> TaptionPlanRawEvent {
        let dayDate = chunk.ambientWindowStart ?? chunk.endedAt
        let payload = try TaptionPlanCanonicalStorage.encode(chunk)
        return TaptionPlanRawEvent(
            device: .appleWatch,
            day: TaptionPlanDayKey(date: dayDate),
            timestamp: dayDate,
            sequence: UInt64(max(0, chunk.sequence)),
            id: chunk.id.uuidString,
            domain: "watch-acceleration",
            provenance: [
                "source-device:appleWatch",
                "source:WatchAcceleration",
                "storage:watch-v3",
                "derived:downsampled-accelerometer-v1",
                "sample-count:\(chunk.samples.count)",
            ],
            payload: TaptionPlanCanonicalStorage.envelope(for: payload)
        )
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        from event: TaptionPlanRawEvent
    ) throws -> Value {
        try TaptionPlanCanonicalStorage.decode(
            type,
            from: TaptionPlanCanonicalStorage.encodedPayload(from: event.payload)
        )
    }

}
