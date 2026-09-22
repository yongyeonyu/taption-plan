import Foundation
import CSQLite
import XCTest
@testable import TaptionPlanCore

final class DayStoreTests: XCTestCase {
    func testCancellationDuringSnapshotTransactionRollsBackAndAllowsRetry() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanDayStore(url: url)
        let day = TaptionPlanDayKey(year: 2026, month: 9, day: 8)
        let batch = (0..<20_000).map { index in
            TaptionPlanDayStore.Snapshot(
                domain: "plan.\(index)", day: day, revision: 1,
                updatedAt: .now, payload: Data(repeating: 1, count: 1024)
            )
        }
        var observer: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &observer, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(observer) }
        let write = Task { try await store.saveSnapshots(batch) }
        var transactionStarted = false
        for _ in 0..<1_000 {
            let result = sqlite3_exec(observer, "BEGIN IMMEDIATE;", nil, nil, nil)
            if result == SQLITE_BUSY {
                transactionStarted = true
                break
            }
            XCTAssertEqual(result, SQLITE_OK)
            _ = sqlite3_exec(observer, "ROLLBACK;", nil, nil, nil)
            try await Task.sleep(for: .milliseconds(1))
        }
        write.cancel()
        XCTAssertTrue(transactionStarted, "Cancel only after SQLite holds its write lock")
        do {
            try await write.value
            XCTFail("An interrupted transaction must not commit")
        } catch TaptionPlanDayStoreError.database(let code, _) {
            XCTAssertEqual(code, SQLITE_INTERRUPT)
        }
        let rolledBack = try await store.snapshots(day: day)
        XCTAssertTrue(rolledBack.isEmpty)
        try await store.saveSnapshot(batch[0])
        let retried = try await store.snapshot(domain: batch[0].domain, day: day)
        XCTAssertEqual(retried?.payload, batch[0].payload)
    }

    func testCancelledSnapshotWritePreservesStoredValueAndAllowsRetry() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanDayStore(url: url)
        let day = TaptionPlanDayKey(year: 2026, month: 9, day: 8)
        let original = TaptionPlanDayStore.Snapshot(
            domain: "plan", day: day, revision: 1,
            updatedAt: .now, payload: Data([1])
        )
        let replacement = TaptionPlanDayStore.Snapshot(
            domain: "plan", day: day, revision: 2,
            updatedAt: .now, payload: Data([2])
        )
        try await store.saveSnapshot(original)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await store.saveSnapshot(replacement)
        }
        do {
            try await cancelled.value
            XCTFail("Cancelled writes must not commit")
        } catch is CancellationError {}
        let preserved = try await store.snapshot(domain: "plan", day: day)
        XCTAssertEqual(preserved?.payload, original.payload)
        try await store.saveSnapshot(replacement)
        let retried = try await store.snapshot(domain: "plan", day: day)
        XCTAssertEqual(retried?.payload, replacement.payload)
    }

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

        XCTAssertEqual(
            healthIDs,
            Set(["healthkit:known"])
        )
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
        try await store.validateUniqueEvents([first])
        let eventsBeforeAppend = try await store.allEvents(
            domain: first.domain
        )
        XCTAssertTrue(eventsBeforeAppend.isEmpty)
        let inserted = try await store.appendUniqueEvents([first])
        let duplicate = try await store.appendUniqueEvents([first])
        XCTAssertEqual(inserted, Set([first.id]))
        XCTAssertTrue(duplicate.isEmpty)
        do {
            try await store.validateUniqueEvents([
                .init(
                    day: day,
                    timestamp: .init(timeIntervalSince1970: 20),
                    sequence: 2,
                    id: first.id,
                    domain: first.domain,
                    payload: Data([2])
                )
            ])
            XCTFail("Expected validation conflict")
        } catch let error as TaptionPlanDayStoreError {
            XCTAssertEqual(error, .eventConflict(id: first.id))
        }
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

    func testConditionalRepairDoesNotOverwriteConcurrentEventUpdate() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanDayStore(url: url)
        let day = TaptionPlanDayKey(year: 2026, month: 8, day: 25)
        let timestamp = Date(timeIntervalSince1970: 10)
        let original = TaptionPlanDayStore.Event(
            day: day,
            timestamp: timestamp,
            sequence: 1,
            id: "sensor-1",
            domain: "sensor-reading",
            payload: Data([1])
        )
        try await store.appendEvents([original])

        let concurrentUpdate = TaptionPlanDayStore.Event(
            day: day,
            timestamp: timestamp,
            sequence: 1,
            id: "sensor-1",
            domain: "sensor-reading",
            payload: Data([2])
        )
        try await store.upsertEvents([concurrentUpdate])
        let repaired = TaptionPlanDayStore.Event(
            day: day,
            timestamp: timestamp,
            sequence: 1,
            id: "sensor-1",
            domain: "sensor-reading",
            payload: Data([3])
        )

        let updatedIDs = try await store.upsertEvents(
            [repaired],
            onlyIfUnchangedFrom: [original]
        )
        let persisted = try await store.allEvents(domain: "sensor-reading")

        XCTAssertTrue(updatedIDs.isEmpty)
        XCTAssertEqual(persisted, [concurrentUpdate])
    }

    func testSQLiteEventIdentityPreservesCanonicalStringVariants() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanDayStore(url: url)
        let day = TaptionPlanDayKey(year: 2026, month: 9, day: 20)
        let timestamp = Date(timeIntervalSince1970: 10)
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        func event(id: String, domain: String = "sensor-reading", payload: UInt8 = 1)
            -> TaptionPlanDayStore.Event {
            .init(
                day: day,
                timestamp: timestamp,
                sequence: 1,
                id: id,
                domain: domain,
                payload: Data([payload])
            )
        }
        let originals = [event(id: composed), event(id: decomposed)]

        try await store.validateUniqueEvents(originals)
        let inserted = try await store.appendUniqueEventIdentifiers(originals)
        let existing = try await store.existingEventIdentifiers(
            [composed, decomposed],
            domain: "sensor-reading"
        )
        do {
            _ = try await store.appendUniqueEvents(originals)
            XCTFail("String Set compatibility API must reject ambiguous IDs")
        } catch let error as TaptionPlanDayStoreError {
            XCTAssertEqual(error, .invalidIdentifier)
        }
        do {
            _ = try await store.existingEventIDs(
                [composed, decomposed],
                domain: "sensor-reading"
            )
            XCTFail("String Set compatibility API must reject ambiguous IDs")
        } catch let error as TaptionPlanDayStoreError {
            XCTAssertEqual(error, .invalidIdentifier)
        }
        let repairs = originals.map {
            event(id: $0.id, payload: 2)
        }
        let updated = try await store.upsertEvents(
            repairs,
            onlyIfUnchangedFrom: originals
        )

        XCTAssertNotEqual(Data(composed.utf8), Data(decomposed.utf8))
        XCTAssertEqual(Set(originals).count, 2)
        XCTAssertEqual(inserted, Set(originals.map { .init($0.id) }))
        XCTAssertEqual(existing, Set(originals.map { .init($0.id) }))
        XCTAssertEqual(updated, Set(originals.map { .init($0.id) }))
        let repairedEvents = try await store.allEvents(domain: "sensor-reading")
        XCTAssertEqual(Set(repairedEvents), Set(repairs))

        let composedDomain = event(id: "same-id", domain: composed)
        try await store.appendEvents([composedDomain])
        do {
            try await store.validateUniqueEvents([
                event(id: "same-id", domain: decomposed),
            ])
            XCTFail("Canonical variants of a SQLite domain must conflict")
        } catch let error as TaptionPlanDayStoreError {
            XCTAssertEqual(error, .eventConflict(id: "same-id"))
        }

        try await store.deleteEvents(
            ids: [composed, decomposed],
            domain: "sensor-reading"
        )
        let remainingIDs = try await store.existingEventIdentifiers(
            [composed, decomposed],
            domain: "sensor-reading"
        )
        XCTAssertTrue(remainingIDs.isEmpty)
    }

    func testStringSetReturnAPIsRemainSourceCompatible() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanDayStore(url: url)
        let day = TaptionPlanDayKey(year: 2026, month: 9, day: 20)
        let event = TaptionPlanDayStore.Event(
            day: day,
            timestamp: Date(timeIntervalSince1970: 10),
            sequence: 1,
            id: "sensor-1",
            domain: "sensor-reading",
            payload: Data([1])
        )

        let inserted: Set<String> = try await store.appendUniqueEvents([event])
        let existing: Set<String> = try await store.existingEventIDs(
            [event.id],
            domain: event.domain
        )
        let exact: Set<TaptionPlanDayStore.EventIdentifier> =
            try await store.existingEventIdentifiers([event.id], domain: event.domain)

        XCTAssertEqual(inserted, Set([event.id]))
        XCTAssertEqual(existing, Set([event.id]))
        XCTAssertEqual(
            exact,
            Set([TaptionPlanDayStore.EventIdentifier(event.id)])
        )
    }

    func testSnapshotIdentityMatchesSQLiteByteExactDomainKeys() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanDayStore(url: url)
        let day = TaptionPlanDayKey(year: 2026, month: 9, day: 20)
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        let snapshots = [composed, decomposed].map {
            TaptionPlanDayStore.Snapshot(
                domain: $0,
                day: day,
                revision: 1,
                updatedAt: Date(timeIntervalSince1970: 10),
                payload: Data([1])
            )
        }

        try await store.saveSnapshots(snapshots)
        let loaded = try await store.snapshots(day: day)

        XCTAssertEqual(Set(snapshots).count, 2)
        XCTAssertEqual(Set(loaded), Set(snapshots))
    }

    func testLegacyStoreRejectsEmbeddedNULAtTextIdentityBoundaries() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanDayStore(url: url)
        let day = TaptionPlanDayKey(year: 2026, month: 9, day: 20)
        let valid = TaptionPlanDayStore.Event(
            day: day,
            timestamp: Date(timeIntervalSince1970: 10),
            sequence: 1,
            id: "gps-1",
            domain: "sensor-reading",
            payload: Data([1])
        )

        do {
            try await store.appendEvents([.init(
                day: day,
                timestamp: valid.timestamp,
                sequence: valid.sequence,
                id: "gps-1\u{0000}alias",
                domain: valid.domain,
                payload: valid.payload
            )])
            XCTFail("Embedded NUL identifiers must be rejected")
        } catch let error as TaptionPlanDayStoreError {
            XCTAssertEqual(error, .invalidIdentifier)
        }
        do {
            try await store.appendEvents([.init(
                day: day,
                timestamp: valid.timestamp,
                sequence: valid.sequence,
                id: valid.id,
                domain: "sensor\u{0000}alias",
                payload: valid.payload
            )])
            XCTFail("Embedded NUL domains must be rejected")
        } catch let error as TaptionPlanDayStoreError {
            XCTAssertEqual(error, .invalidDomain)
        }
        try await store.appendEvents([valid])

        do {
            _ = try await store.existingEventIDs(["gps-1\u{0000}alias"], domain: valid.domain)
            XCTFail("Embedded NUL lookup identifiers must be rejected")
        } catch let error as TaptionPlanDayStoreError {
            XCTAssertEqual(error, .invalidIdentifier)
        }
        do {
            try await store.deleteEvents(ids: ["gps-1\u{0000}alias"], domain: valid.domain)
            XCTFail("Embedded NUL delete identifiers must be rejected")
        } catch let error as TaptionPlanDayStoreError {
            XCTAssertEqual(error, .invalidIdentifier)
        }
        do {
            try await store.saveSnapshots([.init(
                domain: "snapshot\u{0000}alias",
                day: day,
                revision: 1,
                updatedAt: valid.timestamp,
                payload: Data([1])
            )])
            XCTFail("Embedded NUL snapshot domains must be rejected")
        } catch let error as TaptionPlanDayStoreError {
            XCTAssertEqual(error, .invalidDomain)
        }
        do {
            _ = try await store.saveMapDayDocument(
                day: day,
                algorithmKey: "algorithm\u{0000}alias",
                styleKey: "style",
                payload: Data([1])
            )
            XCTFail("Embedded NUL map keys must be rejected")
        } catch let error as TaptionPlanDayStoreError {
            XCTAssertEqual(error, .invalidDomain)
        }
        let validMigrationMarker = try await store.markMigrationCompleted("migration")
        XCTAssertTrue(validMigrationMarker)
        do {
            _ = try await store.markMigrationCompleted("migration\u{0000}alias")
            XCTFail("Embedded NUL migration keys must be rejected")
        } catch let error as TaptionPlanDayStoreError {
            XCTAssertEqual(error, .invalidMigrationKey)
        }
        do {
            _ = try await store.migrationCompleted("migration\u{0000}alias")
            XCTFail("Embedded NUL migration lookups must be rejected")
        } catch let error as TaptionPlanDayStoreError {
            XCTAssertEqual(error, .invalidMigrationKey)
        }
        let migrationRemainsCompleted = try await store.migrationCompleted("migration")
        XCTAssertTrue(migrationRemainsCompleted)

        let persisted = try await store.allEvents(domain: valid.domain)
        XCTAssertEqual(persisted, [valid])
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

    func testMapDayCacheIdentityDoesNotCollideOnSeparators() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanDayStore(url: url)
        let day = TaptionPlanDayKey(year: 2026, month: 8, day: 25)
        let firstPayload = Data("algorithm-with-separator".utf8)
        let secondPayload = Data("style-with-separator".utf8)

        let first = try await store.saveMapDayDocument(
            day: day,
            algorithmKey: "route:v1",
            styleKey: "simple",
            payload: firstPayload
        )
        let second = try await store.saveMapDayDocument(
            day: day,
            algorithmKey: "route",
            styleKey: "v1:simple",
            payload: secondPayload
        )

        XCTAssertEqual(first.revision, 1)
        XCTAssertEqual(second.revision, 1)
        let loadedFirst = try await store.mapDayDocument(
            day: day,
            algorithmKey: "route:v1",
            styleKey: "simple"
        )
        let loadedSecond = try await store.mapDayDocument(
            day: day,
            algorithmKey: "route",
            styleKey: "v1:simple"
        )
        XCTAssertEqual(loadedFirst?.payload, firstPayload)
        XCTAssertEqual(loadedSecond?.payload, secondPayload)
    }

    func testMapDayCacheIdentityPreservesCanonicalStringVariants() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanDayStore(url: url)
        let day = TaptionPlanDayKey(year: 2026, month: 8, day: 25)
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        let firstKey = TaptionPlanMapDayCacheKey(
            day: day,
            algorithmKey: composed,
            styleKey: "simple"
        )
        let secondKey = TaptionPlanMapDayCacheKey(
            day: day,
            algorithmKey: decomposed,
            styleKey: "simple"
        )

        XCTAssertNotEqual(firstKey, secondKey)
        XCTAssertEqual(Set([firstKey, secondKey]).count, 2)
        try await store.saveMapDayDocument(
            day: day,
            algorithmKey: composed,
            styleKey: "simple",
            payload: Data("composed".utf8)
        )
        try await store.saveMapDayDocument(
            day: day,
            algorithmKey: decomposed,
            styleKey: "simple",
            payload: Data("decomposed".utf8)
        )

        let first = try await store.mapDayDocument(
            day: day,
            algorithmKey: composed,
            styleKey: "simple"
        )
        let second = try await store.mapDayDocument(
            day: day,
            algorithmKey: decomposed,
            styleKey: "simple"
        )
        XCTAssertEqual(first?.payload, Data("composed".utf8))
        XCTAssertEqual(second?.payload, Data("decomposed".utf8))
    }

    func testMapDayRevisionsAreAtomicAcrossStoreConnections() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let firstStore = try TaptionPlanDayStore(url: url)
        let secondStore = try TaptionPlanDayStore(url: url)
        var observer: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                url.path,
                &observer,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                nil
            ),
            SQLITE_OK
        )
        guard let observer else {
            return XCTFail("Unable to open SQLite write-lock fixture")
        }
        defer { sqlite3_close(observer) }
        XCTAssertEqual(
            sqlite3_exec(observer, "BEGIN IMMEDIATE;", nil, nil, nil),
            SQLITE_OK
        )

        let day = TaptionPlanDayKey(year: 2026, month: 8, day: 25)
        let firstWrite = Task {
            try await firstStore.saveMapDayDocument(
                day: day,
                algorithmKey: "route-v1",
                styleKey: "simple",
                payload: Data("first".utf8)
            )
        }
        let secondWrite = Task {
            try await secondStore.saveMapDayDocument(
                day: day,
                algorithmKey: "route-v1",
                styleKey: "simple",
                payload: Data("second".utf8)
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(
            sqlite3_exec(observer, "COMMIT;", nil, nil, nil),
            SQLITE_OK
        )

        let firstDocument = try await firstWrite.value
        let secondDocument = try await secondWrite.value
        XCTAssertEqual(
            Set([firstDocument.revision, secondDocument.revision]),
            Set([UInt64(1), 2])
        )
        let stored = try await firstStore.mapDayDocument(
            day: day,
            algorithmKey: "route-v1",
            styleKey: "simple"
        )
        XCTAssertEqual(stored?.revision, 2)
        let newestDocument = firstDocument.revision > secondDocument.revision
            ? firstDocument
            : secondDocument
        XCTAssertEqual(stored?.payload, newestDocument.payload)
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

    func testStorageRejectsInvalidDayKeyBeforeWriting() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanDayStore(url: url)
        let invalidDay = TaptionPlanDayKey(year: 0, month: 0, day: 0)

        do {
            try await store.saveSnapshot(.init(
                domain: "plan",
                day: invalidDay,
                revision: 1,
                updatedAt: .now,
                payload: Data([1])
            ))
            XCTFail("Invalid storage day keys must be rejected")
        } catch let error as TaptionPlanDayStoreError {
            XCTAssertEqual(error, .invalidDay)
        }
    }

    func testUndatedSnapshotOptInPreservesLegacyStateAndAtomicEventDeltaAfterReopen() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanDayStore(url: url, allowsUndatedSnapshots: true)
        let undated = TaptionPlanDayKey(year: 0, month: 0, day: 0)
        let day = TaptionPlanDayKey(year: 2026, month: 9, day: 23)
        var legacy: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &legacy, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(legacy) }
        XCTAssertEqual(sqlite3_exec(legacy, """
            INSERT INTO snapshots(domain, day_key, revision, updated_at, payload)
            VALUES ('sync', '0000-00-00', 7, 0, X'01');
            """, nil, nil, nil), SQLITE_OK)

        let previous = try await store.snapshot(domain: "sync", day: undated)
        XCTAssertEqual(previous?.revision, 7)
        XCTAssertEqual(previous?.payload, Data([1]))
        let timestamp = Date(timeIntervalSince1970: 1_790_000_000)
        let event = TaptionPlanDayStore.Event(
            day: day, timestamp: timestamp, sequence: 0, id: "sample", domain: "samples", payload: Data([3])
        )
        let next = TaptionPlanDayStore.Snapshot(
            domain: "sync", day: undated, revision: 8, updatedAt: timestamp, payload: Data([2])
        )
        try await store.applyEventDelta(
            upserting: [event], deletingIDs: [], domain: "samples", snapshots: [next]
        )
        let reopened = try TaptionPlanDayStore(url: url, allowsUndatedSnapshots: true)
        let snapshots = try await reopened.snapshots(day: undated)
        let events = try await reopened.events(from: day, through: day, domain: "samples")
        XCTAssertEqual(snapshots, [next])
        XCTAssertEqual(events, [event])

        let strictStore = try TaptionPlanDayStore(url: url)
        do {
            _ = try await strictStore.snapshot(domain: "sync", day: undated)
            XCTFail("Undated state requires explicit opt-in")
        } catch let error as TaptionPlanDayStoreError {
            XCTAssertEqual(error, .invalidDay)
        }
    }

    func testUndatedSnapshotOptInStillRejectsInvalidDaysForEventsAndMaps() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let store = try TaptionPlanDayStore(url: url, allowsUndatedSnapshots: true)
        let undated = TaptionPlanDayKey(year: 0, month: 0, day: 0)
        do {
            try await store.appendEvents([.init(
                day: undated, timestamp: .now, sequence: 0, id: "sample", domain: "samples", payload: Data([1])
            )])
            XCTFail("An undated checkpoint must not make invalid events valid")
        } catch let error as TaptionPlanDayStoreError {
            XCTAssertEqual(error, .invalidDay)
        }
        do {
            _ = try await store.saveMapDayDocument(
                day: undated, algorithmKey: "test", styleKey: "test", payload: Data([1])
            )
            XCTFail("Map projections require real dates")
        } catch let error as TaptionPlanDayStoreError {
            XCTAssertEqual(error, .invalidDay)
        }
        do {
            try await store.saveSnapshot(.init(
                domain: "sync", day: .init(year: 0, month: 1, day: 1),
                revision: 1, updatedAt: .now, payload: Data([1])
            ))
            XCTFail("Only the exact legacy state sentinel is allowed")
        } catch let error as TaptionPlanDayStoreError {
            XCTAssertEqual(error, .invalidDay)
        }
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
