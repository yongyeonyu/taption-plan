import Foundation
import TaptionPlanCore

private struct WatchMaterializedDayPayload: Codable, Sendable {
    let day: TaptionPlanDayKey
    let summaries: [TaptionWatchSensorSummary]
}

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
              ) else {
            return nil
        }
        self.store = store
    }

    func append(_ summary: TaptionWatchSensorSummary) async throws {
        try await appendBatch([summary])
    }

    func append(_ chunk: TaptionWatchAccelerationChunk) async throws {
        let payload = try TaptionPlanCanonicalStorage.encode(chunk)
        let event = TaptionPlanRawEvent(
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
                "raw:accelerometer-v1",
                "sample-count:\(chunk.samples.count)",
            ],
            payload: TaptionPlanCanonicalStorage.envelope(for: payload)
        )
        try await store.appendRawEvents([event])
        try await materialize(day: event.day)
    }

    func appendBatch(_ summaries: [TaptionWatchSensorSummary]) async throws {
        guard !summaries.isEmpty else { return }
        let events = try summaries.map { summary -> TaptionPlanRawEvent in
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
        try await store.appendRawEvents(events)
        let days = Set(events.map(\.day))
        for day in days {
            try await materialize(day: day)
        }
    }

    private func materialize(day: TaptionPlanDayKey) async throws {
        let summaries = try await store.rawEvents(
            for: day,
            domain: "watch-sensor-summary"
        ).map { event -> TaptionWatchSensorSummary in
            let encoded = try TaptionPlanCanonicalStorage.encodedPayload(
                from: event.payload
            )
            return try TaptionPlanCanonicalStorage.decode(
                TaptionWatchSensorSummary.self,
                from: encoded
            )
        }
        let digest = try await store.rawDigest(for: day)
        let materialized = WatchMaterializedDayPayload(
            day: day,
            summaries: summaries
        )
        let materializedPayload = try TaptionPlanCanonicalStorage.encode(
            materialized
        )
        let row = TaptionPlanMaterializedDay(
            device: .appleWatch,
            day: day,
            sourceRevision: UInt64(max(0, digest.eventCount)),
            projectionVersion: TaptionPlanV3Store.projectionVersion,
            rawDigest: digest.sha256,
            rawEventCount: digest.eventCount,
            firstTimestamp: digest.firstTimestamp,
            lastTimestamp: digest.lastTimestamp,
            payload: TaptionPlanCanonicalStorage.envelope(for: materializedPayload)
        )
        try await store.replaceMaterializedDay(row)
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
}
