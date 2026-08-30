import Foundation
import XCTest
@testable import TaptionPlanCore

final class DayStoreV3Tests: XCTestCase {
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
