import Foundation
import XCTest
@testable import TaptionPlanCore

final class DayStoreTests: XCTestCase {
    func testDeleteAllContentKeepsMigrationMarker() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanDayStore(url: url)
        let day = TaptionPlanDayKey(year: 2026, month: 9, day: 5)
        try await store.saveSnapshot(
            .init(
                domain: "plan",
                day: day,
                revision: 1,
                updatedAt: .now,
                payload: Data([1])
            )
        )
        try await store.appendEvents([
            .init(
                day: day,
                timestamp: .now,
                sequence: 1,
                id: "raw-1",
                domain: "sensor",
                payload: Data([2])
            )
        ])
        try await store.setMetadata("value", forKey: "user-value")
        _ = try await store.markMigrationCompleted("legacy-import")

        try await store.deleteAllContent()

        let snapshot = try await store.snapshot(domain: "plan", day: day)
        let events = try await store.events(from: day, through: day)
        let metadata = try await store.metadata(forKey: "user-value")
        let migrationCompleted = try await store.migrationCompleted(
            "legacy-import"
        )
        XCTAssertNil(snapshot)
        XCTAssertTrue(events.isEmpty)
        XCTAssertNil(metadata)
        XCTAssertTrue(migrationCompleted)
    }

    func testCanonicalSnapshotAndOneTimeConversion() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanDayStore(url: url)
        let day = TaptionPlanDayKey(year: 2026, month: 8, day: 26)
        let value = try TaptionPlanStorageEnvelopeV2()
        try await store.saveCodableSnapshot(value, domain: "canonical", day: day, revision: 1)
        let decoded = try await store.codableSnapshot(TaptionPlanStorageEnvelopeV2.self, domain: "canonical", day: day)
        XCTAssertEqual(decoded, value)
        let first = try await store.convertCodableSnapshotOnce(TaptionPlanStorageEnvelopeV2.self, from: "canonical", day: day, marker: "v2")
        let second = try await store.convertCodableSnapshotOnce(TaptionPlanStorageEnvelopeV2.self, from: "canonical", day: day, marker: "v2")
        XCTAssertTrue(first)
        XCTAssertFalse(second)
    }
    func testSQLiteWALSnapshotUpsertAndReopen() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let day = TaptionPlanDayKey(year: 2026, month: 8, day: 25)
        let payload = Data("raw-sensor-v2".utf8)

        try await writeSnapshot(url: url, day: day, payload: payload)
        let reopened = try TaptionPlanDayStore(url: url)
        let snapshot = try await reopened.snapshot(domain: "sensor", day: day)

        XCTAssertEqual(snapshot?.payload, payload)
        XCTAssertEqual(snapshot?.revision, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + "-wal"))
        XCTAssertFalse(payload.starts(with: [0x78, 0x9c]))
    }

    func testEventsAreOrderedByDayTimestampSequenceAndID() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let day = TaptionPlanDayKey(year: 2026, month: 8, day: 25)
        let events = [
            TaptionPlanDayStore.Event(day: day, timestamp: .init(timeIntervalSince1970: 30), sequence: 2, id: "c", domain: "gps", payload: Data([3])),
            TaptionPlanDayStore.Event(day: day, timestamp: .init(timeIntervalSince1970: 10), sequence: 2, id: "b", domain: "gps", payload: Data([2])),
            TaptionPlanDayStore.Event(day: day, timestamp: .init(timeIntervalSince1970: 10), sequence: 1, id: "a", domain: "gps", payload: Data([1]))
        ]
        let store = try TaptionPlanDayStore(url: url)

        try await store.appendEvents(events)
        let result = try await store.events(from: day, through: day)

        XCTAssertEqual(result.map(\.id), ["a", "b", "c"])
    }

    func testExistingEventIDsRemainDomainScoped() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanDayStore(url: url)
        let day = TaptionPlanDayKey(year: 2026, month: 9, day: 6)
        try await store.appendEvents([
            .init(
                day: day,
                timestamp: .now,
                sequence: 0,
                id: "healthkit:known",
                domain: "healthkit-sample",
                payload: Data([1])
            ),
        ])

        let healthIDs = try await store.existingEventIDs(
            ["healthkit:known", "healthkit:missing"],
            domain: "healthkit-sample"
        )
        let sensorIDs = try await store.existingEventIDs(
            ["healthkit:known"],
            domain: "sensor-reading"
        )

        XCTAssertEqual(healthIDs, ["healthkit:known"])
        XCTAssertTrue(sensorIDs.isEmpty)
    }

    func testBatchRollsBackOnConstraintFailure() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let day = TaptionPlanDayKey(year: 2026, month: 8, day: 25)
        let existing = TaptionPlanDayStore.Event(day: day, timestamp: .now, sequence: 1, id: "existing", domain: "gps", payload: Data([1]))
        let store = try TaptionPlanDayStore(url: url)
        try await store.appendEvents([existing])

        let batch = [
            TaptionPlanDayStore.Event(day: day, timestamp: .now, sequence: 2, id: "new", domain: "gps", payload: Data([2])),
            existing
        ]
        var rolledBack = false
        do {
            try await store.appendEvents(batch)
        } catch {
            rolledBack = true
        }
        XCTAssertTrue(rolledBack)
        let result = try await store.events(from: day, through: day)

        XCTAssertEqual(result.map(\.id), ["existing"])
    }

    func testUniqueAppendRejectsConflictsAndDomainDeleteIsScoped() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let day = TaptionPlanDayKey(year: 2026, month: 9, day: 4)
        let store = try TaptionPlanDayStore(url: url)
        let first = TaptionPlanDayStore.Event(
            day: day,
            timestamp: .init(timeIntervalSince1970: 10),
            sequence: 1,
            id: "sensor-1",
            domain: "sensor-reading",
            payload: Data([1])
        )
        try await store.appendUniqueEvents([first])
        try await store.appendUniqueEvents([first])
        do {
            try await store.appendUniqueEvents([
                .init(
                    day: day,
                    timestamp: .init(timeIntervalSince1970: 20),
                    sequence: 2,
                    id: first.id,
                    domain: first.domain,
                    payload: Data([2])
                )
            ])
            XCTFail("Expected immutable event conflict")
        } catch let error as TaptionPlanDayStoreError {
            XCTAssertEqual(error, .eventConflict(id: first.id))
        }
        try await store.appendUniqueEvents([
            .init(
                day: day,
                timestamp: .init(timeIntervalSince1970: 30),
                sequence: 3,
                id: "raw-1",
                domain: "raw-device-data",
                payload: Data([3])
            )
        ])

        let sensor = try await store.allEvents(domain: first.domain)
        XCTAssertEqual(sensor.map(\.payload), [Data([1])])
        try await store.deleteEvents(domain: first.domain)
        let deleted = try await store.allEvents(domain: first.domain)
        let retained = try await store.allEvents(domain: "raw-device-data")
        XCTAssertTrue(deleted.isEmpty)
        XCTAssertEqual(retained.map(\.id), ["raw-1"])
    }

    func testEventsCanBeUpsertedAndDeletedWithinTheirDomain() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let firstDay = TaptionPlanDayKey(year: 2026, month: 8, day: 25)
        let secondDay = TaptionPlanDayKey(year: 2026, month: 8, day: 26)
        let store = try TaptionPlanDayStore(url: url)
        try await store.appendEvents([
            .init(
                day: firstDay,
                timestamp: .init(timeIntervalSince1970: 10),
                sequence: 0,
                id: "healthkit:sample",
                domain: "healthkit-sample",
                payload: Data([1])
            )
        ])

        try await store.upsertEvents([
            .init(
                day: secondDay,
                timestamp: .init(timeIntervalSince1970: 20),
                sequence: 1,
                id: "healthkit:sample",
                domain: "healthkit-sample",
                payload: Data([2])
            )
        ])
        let firstDayEvents = try await store.events(
            from: firstDay,
            through: firstDay,
            domain: "healthkit-sample"
        )
        let secondDayEvents = try await store.events(
            from: secondDay,
            through: secondDay,
            domain: "healthkit-sample"
        )
        XCTAssertTrue(firstDayEvents.isEmpty)
        XCTAssertEqual(secondDayEvents.first?.payload, Data([2]))

        try await store.deleteEvents(
            ids: ["healthkit:sample"],
            domain: "healthkit-sample"
        )
        let remaining = try await store.events(
            from: secondDay,
            through: secondDay,
            domain: "healthkit-sample"
        )
        XCTAssertTrue(remaining.isEmpty)
    }

    func testEventDeltaAndCursorSnapshotCommitTogether() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let day = TaptionPlanDayKey(year: 2026, month: 8, day: 27)
        let store = try TaptionPlanDayStore(url: url)
        let cursor = TaptionPlanDayStore.Snapshot(
            domain: "healthkit-sync-state",
            day: day,
            revision: 1,
            updatedAt: .now,
            payload: Data("anchor-1".utf8)
        )

        try await store.applyEventDelta(
            upserting: [
                .init(
                    day: day,
                    timestamp: .now,
                    sequence: 0,
                    id: "healthkit:atomic",
                    domain: "healthkit-sample",
                    payload: Data([7])
                )
            ],
            deletingIDs: [],
            domain: "healthkit-sample",
            snapshots: [cursor]
        )

        let events = try await store.events(
            from: day,
            through: day,
            domain: "healthkit-sample"
        )
        let savedCursor = try await store.snapshot(
            domain: "healthkit-sync-state",
            day: day
        )
        XCTAssertEqual(events.map(\.id), ["healthkit:atomic"])
        XCTAssertEqual(savedCursor?.payload, Data("anchor-1".utf8))
    }

    func testMetadataAndOneTimeMigrationMarker() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanDayStore(url: url)

        try await store.setMetadata("v2", forKey: "schema")
        let metadata = try await store.metadata(forKey: "schema")
        let firstMarker = try await store.markMigrationCompleted("legacy-import")
        let secondMarker = try await store.markMigrationCompleted("legacy-import")
        let completed = try await store.migrationCompleted("legacy-import")
        XCTAssertEqual(metadata, "v2")
        XCTAssertTrue(firstMarker)
        XCTAssertFalse(secondMarker)
        XCTAssertTrue(completed)
    }

    func testMalformedDatabaseSurfacesCorruption() throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        try Data("not a sqlite database".utf8).write(to: url)

        do {
            _ = try TaptionPlanDayStore(url: url)
            XCTFail("Expected malformed database to be rejected")
        } catch let error as TaptionPlanDayStoreError {
            guard case .databaseCorrupt = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testMapDayDocumentPersistsByDayAlgorithmAndStyle() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanDayStore(url: url)
        let day = TaptionPlanDayKey(year: 2026, month: 8, day: 25)
        let payload = Data("map-document-v1".utf8)

        let first = try await store.saveMapDayDocument(
            day: day,
            algorithmKey: "route-v1",
            styleKey: "simplified",
            payload: payload
        )
        let second = try await store.saveMapDayDocument(
            day: day,
            algorithmKey: "route-v1",
            styleKey: "simplified",
            payload: Data("map-document-v2".utf8)
        )
        let loaded = try await store.mapDayDocument(
            day: day,
            algorithmKey: "route-v1",
            styleKey: "simplified"
        )

        XCTAssertEqual(first.revision, 1)
        XCTAssertEqual(second.revision, 2)
        XCTAssertEqual(loaded?.payload, Data("map-document-v2".utf8))
        let differentStyle = try await store.mapDayDocument(
            day: day,
            algorithmKey: "route-v1",
            styleKey: "standard"
        )
        XCTAssertNil(differentStyle)
    }

    func testCodableMapDayDocumentUsesCanonicalEnvelope() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanDayStore(url: url)
        let day = TaptionPlanDayKey(year: 2026, month: 8, day: 26)
        let value = try TaptionPlanStorageEnvelopeV2()

        _ = try await store.saveCodableMapDayDocument(
            value,
            day: day,
            algorithmKey: "route-v2",
            styleKey: "simplified"
        )
        let raw = try await store.mapDayDocument(
            day: day,
            algorithmKey: "route-v2",
            styleKey: "simplified"
        )?.payload
        XCTAssertEqual(String(decoding: raw?.prefix(8) ?? Data(), as: UTF8.self), "TP-CANON")
        let decoded = try await store.codableMapDayDocument(
            TaptionPlanStorageEnvelopeV2.self,
            day: day,
            algorithmKey: "route-v2",
            styleKey: "simplified"
        )
        XCTAssertEqual(decoded, value)
    }

    func testTimestampIndexQueriesAFullDayOfSamples() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let timestamps = (0..<86_400).map {
            start.addingTimeInterval(TimeInterval($0))
        }
        let index = TaptionPlanTimestampIndex(timestamps: timestamps)
        let noon = start.addingTimeInterval(12 * 60 * 60)

        XCTAssertEqual(index.count, 86_400)
        XCTAssertEqual(index.prefixCount(through: noon), 43_201)
        XCTAssertEqual(
            index.range(
                from: start.addingTimeInterval(23 * 60 * 60),
                through: start.addingTimeInterval(24 * 60 * 60 - 1)
            ).count,
            3_600
        )
    }

    func testTimestampIndexFullDayQueryBenchmark() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let index = TaptionPlanTimestampIndex(
            timestamps: (0..<86_400).map {
                start.addingTimeInterval(TimeInterval($0))
            }
        )

        measure {
            var total = 0
            for offset in stride(from: 0, to: 86_400, by: 7) {
                total += index.prefixCount(
                    through: start.addingTimeInterval(TimeInterval(offset))
                )
            }
            XCTAssertGreaterThan(total, 0)
        }
    }

    func testDayStoreReadsAFullDayOfOrderedEvents() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanDayStore(url: url)
        let day = TaptionPlanDayKey(year: 2026, month: 8, day: 25)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let events = (0..<17_280).map { index in
            TaptionPlanDayStore.Event(
                day: day,
                timestamp: start.addingTimeInterval(TimeInterval(index * 5)),
                sequence: UInt64(index),
                id: "sample-\(index)",
                domain: "gps",
                payload: Data([UInt8(index & 0xFF)])
            )
        }

        try await store.appendEvents(events)
        let result = try await store.events(from: day, through: day, domain: "gps")

        XCTAssertEqual(result.count, events.count)
        XCTAssertEqual(result.first?.sequence, 0)
        XCTAssertEqual(result.last?.sequence, UInt64(events.count - 1))
    }

    private func writeSnapshot(
        url: URL,
        day: TaptionPlanDayKey,
        payload: Data
    ) async throws {
        let store = try TaptionPlanDayStore(url: url)
        try await store.saveSnapshot(
            .init(
                domain: "sensor",
                day: day,
                revision: 2,
                updatedAt: .now,
                payload: payload
            )
        )
        try await store.saveSnapshot(
            .init(
                domain: "sensor",
                day: day,
                revision: 1,
                updatedAt: .now,
                payload: Data("stale".utf8)
            )
        )
    }

    func testEqualSnapshotRevisionCannotReplaceExistingPayload() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanDayStore(url: url)
        let day = TaptionPlanDayKey(year: 2026, month: 9, day: 5)
        try await store.saveSnapshot(.init(
            domain: "sensor",
            day: day,
            revision: 7,
            updatedAt: .now,
            payload: Data("first".utf8)
        ))
        try await store.saveSnapshot(.init(
            domain: "sensor",
            day: day,
            revision: 7,
            updatedAt: .now,
            payload: Data("second".utf8)
        ))

        let restored = try await store.snapshot(domain: "sensor", day: day)
        XCTAssertEqual(restored?.payload, Data("first".utf8))
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("taption-core-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
    }

    private func removeDatabase(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }
}
