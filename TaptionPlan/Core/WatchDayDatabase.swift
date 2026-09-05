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
              ) else {
            return nil
        }
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
}
