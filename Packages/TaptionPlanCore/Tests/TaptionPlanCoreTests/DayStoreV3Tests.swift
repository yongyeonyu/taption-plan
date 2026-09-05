import Foundation
import XCTest
@testable import TaptionPlanCore

final class DayStoreV3Tests: XCTestCase {
    func testDeleteAllDataKeepsMigrationMarker() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanV3Store(url: url, device: .iPhone)
        let day = TaptionPlanDayKey(year: 2026, month: 9, day: 5)
        let raw = event(day: day, id: "gps-1", timestamp: 10)
        try await store.appendRawEvents([raw])
        let digest = try await store.rawDigest(for: day)
        try await store.replaceMaterializedDay(
            .init(
                device: .iPhone,
                day: day,
                sourceRevision: 1,
                projectionVersion: 1,
                rawDigest: digest.sha256,
                rawEventCount: digest.eventCount,
                firstTimestamp: digest.firstTimestamp,
                lastTimestamp: digest.lastTimestamp,
                payload: Data([3])
            )
        )
        _ = try await store.markMigrationCompleted("legacy-import")

        try await store.deleteAllData()

        let days = try await store.allDays()
        let events = try await store.rawEvents(for: day)
        let materialized = try await store.materializedDay(for: day)
        let migrationCompleted = try await store.migrationCompleted(
            "legacy-import"
        )
        XCTAssertTrue(days.isEmpty)
        XCTAssertTrue(events.isEmpty)
        XCTAssertNil(materialized)
        XCTAssertTrue(migrationCompleted)
    }

    func testDateQueryUsesDayLeadingIndex() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanV3Store(url: url, device: .iPhone)
        let day = TaptionPlanDayKey(year: 2026, month: 8, day: 30)
        try await store.appendRawEvents([
            event(day: day, id: "gps-1", timestamp: 10)
        ])

        let plan = try await store.explainRawDayQuery()

        XCTAssertTrue(
            plan.contains { $0.contains("raw_events_day_time_index") },
            "Expected date lookup to use the day-leading index: \(plan)"
        )
    }

    func testRawAppendIsIdempotentAndRejectsConflictingPayload() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanV3Store(url: url, device: .iPhone)
        let day = TaptionPlanDayKey(year: 2026, month: 8, day: 30)
        let original = event(day: day, id: "stable-1", timestamp: 20, payload: Data([1]))

        try await store.appendRawEvents([original, original])
        let initialEvents = try await store.rawEvents(for: day)
        XCTAssertEqual(initialEvents, [original])

        var conflicting = original
        conflicting = TaptionPlanRawEvent(
            device: conflicting.device,
            day: conflicting.day,
            timestamp: conflicting.timestamp,
            sequence: conflicting.sequence,
            id: conflicting.id,
            domain: conflicting.domain,
            provenance: conflicting.provenance,
            payload: Data([2])
        )
        do {
            try await store.appendRawEvents([conflicting])
            XCTFail("Expected append-only conflict")
        } catch let error as TaptionPlanV3StoreError {
            XCTAssertEqual(
                error,
                .payloadConflict(device: .iPhone, domain: "gps", id: "stable-1")
            )
        }
        let finalEvents = try await store.rawEvents(for: day)
        XCTAssertEqual(finalEvents, [original])
    }

    func testRawBatchReusesStatementsAndOptimizePreservesEvents() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanV3Store(url: url, device: .iPhone)
        let day = TaptionPlanDayKey(year: 2026, month: 8, day: 31)
        let events = (0..<1_000).map { index in
            event(
                day: day,
                id: "gps-\(index)",
                timestamp: TimeInterval(index)
            )
        }

        try await store.appendRawEvents(events + events)
        try await store.optimize()

        let loaded = try await store.rawEvents(for: day)
        XCTAssertEqual(loaded.count, events.count)
        XCTAssertEqual(loaded.first?.id, "gps-0")
        XCTAssertEqual(loaded.last?.id, "gps-999")
    }

    func testDigestIsStableBySortOrderAndIncludesProvenance() async throws {
        let firstURL = temporaryURL()
        let secondURL = temporaryURL()
        defer {
            removeDatabase(at: firstURL)
            removeDatabase(at: secondURL)
        }
        let day = TaptionPlanDayKey(year: 2026, month: 8, day: 30)
        let first = event(
            day: day,
            id: "gps-1",
            timestamp: 20,
            provenance: ["iPhone.location", "CoreMotion"]
        )
        let second = event(
            day: day,
            id: "gps-2",
            timestamp: 10,
            provenance: ["iPhone.location"]
        )
        let firstStore = try TaptionPlanV3Store(url: firstURL, device: .iPhone)
        let secondStore = try TaptionPlanV3Store(url: secondURL, device: .iPhone)
        try await firstStore.appendRawEvents([first, second])
        try await secondStore.appendRawEvents([second, first])

        let firstDigest = try await firstStore.rawDigest(for: day)
        let secondDigest = try await secondStore.rawDigest(for: day)
        XCTAssertEqual(firstDigest, secondDigest)

        let changedProvenance = TaptionPlanRawEvent(
            device: first.device,
            day: first.day,
            timestamp: first.timestamp,
            sequence: first.sequence,
            id: "gps-3",
            domain: first.domain,
            provenance: ["iPhone.location", "different-source"],
            payload: first.payload
        )
        try await firstStore.appendRawEvents([changedProvenance])
        let changedDigest = try await firstStore.rawDigest(for: day)
        XCTAssertNotEqual(firstDigest.sha256, changedDigest.sha256)
    }

    func testDigestUsesDomainAsTheFinalStableSortKey() async throws {
        let firstURL = temporaryURL()
        let secondURL = temporaryURL()
        defer {
            removeDatabase(at: firstURL)
            removeDatabase(at: secondURL)
        }
        let day = TaptionPlanDayKey(year: 2026, month: 9, day: 5)
        let gps = event(day: day, id: "shared", timestamp: 10)
        let motion = TaptionPlanRawEvent(
            device: gps.device,
            day: gps.day,
            timestamp: gps.timestamp,
            sequence: gps.sequence,
            id: gps.id,
            domain: "motion",
            provenance: gps.provenance,
            payload: Data([8])
        )
        let firstStore = try TaptionPlanV3Store(
            url: firstURL,
            device: .iPhone
        )
        let secondStore = try TaptionPlanV3Store(
            url: secondURL,
            device: .iPhone
        )
        try await firstStore.appendRawEvents([gps, motion])
        try await secondStore.appendRawEvents([motion, gps])

        let expected = TaptionPlanV3Store.digest(
            events: [motion, gps],
            device: .iPhone,
            day: day
        )
        let firstDigest = try await firstStore.rawDigest(for: day)
        let secondDigest = try await secondStore.rawDigest(for: day)
        XCTAssertEqual(firstDigest, expected)
        XCTAssertEqual(secondDigest, expected)
    }

    func testStreamingRawDigestMatchesCanonicalDigestForLargePayloads() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanV3Store(url: url, device: .iPhone)
        let day = TaptionPlanDayKey(year: 2026, month: 9, day: 4)
        let events = (0..<1_000).map { index in
            event(
                day: day,
                id: "gps-\(index)",
                timestamp: TimeInterval(index),
                payload: Data(repeating: UInt8(index % 255), count: 4_096)
            )
        }
        try await store.appendRawEvents(events)

        let digest = try await store.rawDigest(for: day)

        XCTAssertEqual(digest, TaptionPlanV3Store.digest(
            events: events,
            device: .iPhone,
            day: day
        ))
    }

    func testRawDigestCacheSeesAnotherConnectionCommit() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let day = TaptionPlanDayKey(year: 2026, month: 9, day: 5)
        let first = try TaptionPlanV3Store(url: url, device: .iPhone)
        let second = try TaptionPlanV3Store(url: url, device: .iPhone)
        try await first.appendRawEvents([
            event(day: day, id: "first", timestamp: 1),
        ])
        let cached = try await first.rawDigest(for: day)

        try await second.appendRawEvents([
            event(day: day, id: "second", timestamp: 2),
        ])

        let updated = try await first.rawDigest(for: day)
        XCTAssertNotEqual(updated, cached)
    }

    func testRawDigestCacheEvictsPastCapacity() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanV3Store(url: url, device: .iPhone)
        let calendar = Calendar(identifier: .gregorian)
        let start = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))
        )

        for offset in 0...TaptionPlanV3Store.rawDigestCacheCapacity {
            let date = try XCTUnwrap(
                calendar.date(byAdding: .day, value: offset, to: start)
            )
            let day = TaptionPlanDayKey(date: date, calendar: calendar)
            try await store.appendRawEvents([
                event(
                    day: day,
                    id: "event-\(offset)",
                    timestamp: TimeInterval(offset)
                ),
            ])
            _ = try await store.rawDigest(for: day)
        }

        let count = await store.rawDigestCacheCount
        XCTAssertEqual(count, TaptionPlanV3Store.rawDigestCacheCapacity)
    }

    func testMaterializedDayIsReplacedAsOneRowAndAllDaysIsIndexed() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanV3Store(url: url, device: .appleWatch)
        let day = TaptionPlanDayKey(year: 2026, month: 8, day: 30)
        let event = event(day: day, id: "watch-1", timestamp: 30, device: .appleWatch)
        try await store.appendRawEvents([event])
        let digest = try await store.rawDigest(for: day)
        let first = TaptionPlanMaterializedDay(
            device: .appleWatch,
            day: day,
            sourceRevision: 1,
            projectionVersion: 1,
            rawDigest: digest.sha256,
            rawEventCount: digest.eventCount,
            firstTimestamp: digest.firstTimestamp,
            lastTimestamp: digest.lastTimestamp,
            payload: Data([1])
        )
        try await store.replaceMaterializedDay(first)
        let second = TaptionPlanMaterializedDay(
            device: .appleWatch,
            day: day,
            sourceRevision: 2,
            projectionVersion: 1,
            rawDigest: digest.sha256,
            rawEventCount: digest.eventCount,
            firstTimestamp: digest.firstTimestamp,
            lastTimestamp: digest.lastTimestamp,
            payload: Data([2])
        )
        try await store.replaceMaterializedDay(second)

        let loadedValue = try await store.materializedDay(for: day)
        let loaded = try XCTUnwrap(loadedValue)
        XCTAssertEqual(loaded.sourceRevision, 2)
        XCTAssertEqual(loaded.payload, Data([2]))
        let days = try await store.allDays()
        XCTAssertEqual(days, [day])
    }

    func testThirtyDayColdAndWarmReadP95StaysInteractive() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let days = (1...30).map {
            TaptionPlanDayKey(year: 2026, month: 8, day: $0)
        }
        do {
            let store = try TaptionPlanV3Store(url: url, device: .iPhone)
            for (dayIndex, day) in days.enumerated() {
                let events = (0..<1_440).map { minute in
                    event(
                        day: day,
                        id: "gps-\(dayIndex)-\(minute)",
                        timestamp: TimeInterval(dayIndex * 86_400 + minute * 60),
                        provenance: ["iPhone.location", "CoreMotion"],
                        payload: Data(repeating: UInt8(minute % 255), count: 64)
                    )
                }
                try await store.appendRawEvents(events)
                let digest = try await store.rawDigest(for: day)
                try await store.replaceMaterializedDay(.init(
                    device: .iPhone,
                    day: day,
                    sourceRevision: 1,
                    projectionVersion: 1,
                    rawDigest: digest.sha256,
                    rawEventCount: digest.eventCount,
                    firstTimestamp: digest.firstTimestamp,
                    lastTimestamp: digest.lastTimestamp,
                    payload: Data(repeating: UInt8(dayIndex), count: 16_384)
                ))
            }
            try await store.checkpoint()
        }

        let store = try TaptionPlanV3Store(url: url, device: .iPhone)
        func readDurations() async throws -> [Double] {
            var milliseconds: [Double] = []
            for day in days {
                let started = DispatchTime.now().uptimeNanoseconds
                _ = try await store.rawDigest(for: day)
                _ = try await store.materializedDay(for: day)
                let elapsed = DispatchTime.now().uptimeNanoseconds - started
                milliseconds.append(Double(elapsed) / 1_000_000)
            }
            return milliseconds
        }
        func p95(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            let index = max(
                0,
                min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)
            )
            return sorted[index]
        }

        let coldP95 = p95(try await readDurations())
        let warmP95 = p95(try await readDurations())
        print("DAY_STORE_30D_COLD_P95_MS=\(coldP95)")
        print("DAY_STORE_30D_WARM_P95_MS=\(warmP95)")
        XCTAssertLessThan(coldP95, 100)
        XCTAssertLessThan(warmP95, 50)
    }

    func testExistingV2StoreIsRejectedWithoutMutatingIt() throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        do {
            _ = try TaptionPlanDayStore(url: url)
        }
        let before = try Data(contentsOf: url)

        XCTAssertThrowsError(
            try TaptionPlanV3Store(url: url, device: .iPhone)
        ) { error in
            XCTAssertEqual(error as? TaptionPlanV3StoreError, .unsupportedSchema(0))
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testExistingUnsupportedDatabaseIsInspectedReadOnly() throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        try Data("not a sqlite database".utf8).write(to: url)
        let before = try Data(contentsOf: url)

        XCTAssertThrowsError(
            try TaptionPlanV3Store(url: url, device: .iPhone)
        )
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-shm"))
    }

    private func event(
        day: TaptionPlanDayKey,
        id: String,
        timestamp: TimeInterval,
        device: TaptionPlanStoreDevice = .iPhone,
        provenance: [String] = ["test-source"],
        payload: Data = Data([7])
    ) -> TaptionPlanRawEvent {
        TaptionPlanRawEvent(
            device: device,
            day: day,
            timestamp: Date(timeIntervalSince1970: timestamp),
            sequence: UInt64(timestamp),
            id: id,
            domain: "gps",
            provenance: provenance,
            payload: payload
        )
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("taption-core-v3-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
    }

    private func removeDatabase(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }
}
