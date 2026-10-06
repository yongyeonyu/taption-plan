import Foundation
import CSQLite
import XCTest
@testable import TaptionPlanCore

final class ActualRecordStoreTests: XCTestCase {
    private func row(_ key: String, position: Int, start: Double, end: Double?) -> TaptionPlanDayStore.ActualRow {
        .init(key: key, position: position, id: "duplicate", planID: nil, routineID: "routine",
              title: "Cafe\u{0301}\0title", categoryID: "activity",
              startedAt: Date(timeIntervalSinceReferenceDate: start),
              endedAt: end.map { Date(timeIntervalSinceReferenceDate: $0) },
              source: "location", confidence: "high", createdAt: Date(timeIntervalSinceReferenceDate: start - 0.25),
              behavior: "walk", evidence: Data([1, 0, 2]), routeID: "route", sensorChunkID: "chunk",
              modelVersion: "v1", manuallyCorrected: true, classificationLocked: true)
    }

    private func location() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-records-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("records.sqlite")
    }

    func testIntervalIndexPreservesExactBoundariesOpenEndsAndOriginalOrder() async throws {
        let store = try TaptionPlanDayStore(url: location())
        let t = 800_000_000.0
        let rows = [
            row("later", position: 0, start: t + 0.25, end: t + 0.5),
            row("overnight", position: 1, start: t - 86_400, end: t + 0.125),
            row("open", position: 2, start: t - 100, end: nil),
            row("too-late", position: 3, start: t + 0.375, end: t + 1),
            row("too-early", position: 4, start: t - 100, end: t),
            row("instant", position: 5, start: t + 0.125, end: t + 0.125),
            row("reversed", position: 6, start: t + 0.125, end: t - 1),
        ]
        try await store.applyActualRecordDelta(upserting: rows, deletingKeys: [])
        let query = try await store.actualRecords(in: Date(timeIntervalSinceReferenceDate: t + 0.125)...Date(timeIntervalSinceReferenceDate: t + 0.25))
        XCTAssertEqual(query, [rows[0], rows[1], rows[2], rows[5], rows[6]])
        XCTAssertEqual(Array(query[0].title.utf8), Array(rows[0].title.utf8))
        let all = try await store.actualRecords()
        XCTAssertEqual(all, rows)
    }

    func testDeltaUpdatesRangeAndDeletesWithoutChangingOtherRows() async throws {
        let store = try TaptionPlanDayStore(url: location())
        let a = row("a", position: 0, start: 100, end: 200)
        var b = row("b", position: 1, start: 100, end: 200)
        try await store.applyActualRecordDelta(upserting: [a, b], deletingKeys: [])
        let before = try await store.actualRecordRevision()
        b.startedAt = Date(timeIntervalSinceReferenceDate: 300)
        b.endedAt = Date(timeIntervalSinceReferenceDate: 400)
        try await store.applyActualRecordDelta(upserting: [b], deletingKeys: ["a"])
        let after = try await store.actualRecordRevision()
        let early = try await store.actualRecords(in: Date(timeIntervalSinceReferenceDate: 100)...Date(timeIntervalSinceReferenceDate: 200))
        let later = try await store.actualRecords(in: Date(timeIntervalSinceReferenceDate: 300)...Date(timeIntervalSinceReferenceDate: 400))
        XCTAssertEqual(after - before, 2)
        XCTAssertTrue(early.isEmpty)
        XCTAssertEqual(later, [b])
        try await store.deleteAllContent()
        let deleted = try await store.actualRecords(in: .distantPast ... .distantFuture)
        XCTAssertTrue(deleted.isEmpty)
    }

    func testRecordAndRootRollbackTogetherOnErrorAndCancellation() async throws {
        let store = try TaptionPlanDayStore(url: location())
        let original = row("a", position: 0, start: 100, end: 200)
        try await store.applyActualRecordDelta(upserting: [original], deletingKeys: [])
        let before = try await store.actualRecordRevision()
        do {
            try await store.withSnapshotWriteTransaction { store in
                try store.applyActualRecordDelta(upserting: [], deletingKeys: [], replaceAll: true)
                try store.saveSnapshot(.init(domain: "fixture", day: .init(year: 2026, month: 10, day: 6),
                    revision: 1, updatedAt: .now, payload: Data([1])))
                throw CancellationError()
            }
            XCTFail("Cancelled transaction must fail")
        } catch is CancellationError {}
        let after = try await store.actualRecordRevision()
        let restored = try await store.actualRecords()
        let roots = try await store.snapshots(day: .init(year: 2026, month: 10, day: 6))
        XCTAssertEqual(after, before)
        XCTAssertEqual(restored, [original])
        XCTAssertTrue(roots.isEmpty)
        var invalid = original
        invalid.position = -1
        do {
            try await store.applyActualRecordDelta(upserting: [invalid], deletingKeys: [], replaceAll: true)
            XCTFail("Invalid replacement must roll back deletion")
        } catch {}
        let preserved = try await store.actualRecords()
        XCTAssertEqual(preserved, [original])
    }

    func testBulkReplacementRestoresIndexAndTriggersAfterRollbackAndCommit() async throws {
        let store = try TaptionPlanDayStore(url: location())
        let original = row("a", position: 0, start: 100, end: 200)
        let replacement = row("b", position: 0, start: 300, end: 400)
        try await store.applyActualRecordDelta(upserting: [original], deletingKeys: [])
        let before = try await store.actualRecordRevision()
        do {
            try await store.replaceActualRecords { store in
                try store.applyActualRecordDelta(upserting: [replacement], deletingKeys: [])
                throw CancellationError()
            }
            XCTFail("Cancelled bulk replacement must roll back schema and rows")
        } catch is CancellationError {}
        let restored = try await store.actualRecords(in: Date(timeIntervalSinceReferenceDate: 100)...Date(timeIntervalSinceReferenceDate: 200))
        let rolledBackRevision = try await store.actualRecordRevision()
        XCTAssertEqual(restored, [original])
        XCTAssertEqual(rolledBackRevision, before)
        try await store.replaceActualRecords { store in
            try store.applyActualRecordDelta(upserting: [replacement], deletingKeys: [])
        }
        let replaced = try await store.actualRecords(in: Date(timeIntervalSinceReferenceDate: 300)...Date(timeIntervalSinceReferenceDate: 400))
        let committedRevision = try await store.actualRecordRevision()
        XCTAssertEqual(replaced, [replacement])
        XCTAssertEqual(committedRevision, before + 1)
        try await store.applyActualRecordDelta(upserting: [], deletingKeys: [replacement.key])
        let deleted = try await store.actualRecords(in: .distantPast ... .distantFuture)
        let finalRevision = try await store.actualRecordRevision()
        XCTAssertTrue(deleted.isEmpty)
        XCTAssertEqual(finalRevision, committedRevision + 1)
    }

    func testReadTransactionKeepsRevisionAndRowsOnSameWALSnapshot() async throws {
        let url = try location()
        let store = try TaptionPlanDayStore(url: url)
        try await store.applyActualRecordDelta(upserting: [row("a", position: 0, start: 100, end: 200)], deletingKeys: [])
        let during = try await store.withSnapshotReadTransaction { store in
            let revision = try store.actualRecordRevision()
            var external: OpaquePointer?
            XCTAssertEqual(sqlite3_open_v2(url.path, &external, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
            defer { sqlite3_close(external) }
            XCTAssertEqual(sqlite3_exec(external, "UPDATE actual_records SET title='external';", nil, nil, nil), SQLITE_OK)
            return (revision, try store.actualRecordRevision(), try store.actualRecords())
        }
        XCTAssertEqual(during.0, during.1)
        XCTAssertNotEqual(during.2[0].title, "external")
        let after = try await store.actualRecords()
        let revision = try await store.actualRecordRevision()
        XCTAssertEqual(after[0].title, "external")
        XCTAssertEqual(revision, during.0 + 1)
    }

    func testRangeQueryPlanUsesRTreeBeforePrimaryKeyLookup() async throws {
        let url = try location()
        let store = try TaptionPlanDayStore(url: url)
        try await store.applyActualRecordDelta(upserting: [row("a", position: 0, start: 100, end: 200)], deletingKeys: [])
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "EXPLAIN QUERY PLAN SELECT a.id FROM actual_record_ranges r CROSS JOIN actual_records a ON a.row_id=r.row_id WHERE r.starts<=200 AND r.ends>=100 AND a.started_at<=200 AND (a.ended_at IS NULL OR MAX(a.started_at,a.ended_at)>=100) ORDER BY a.position;", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var plan: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { plan.append(String(cString: sqlite3_column_text(statement, 3))) }
        XCTAssertTrue(plan.contains { $0.contains("VIRTUAL TABLE INDEX") })
        XCTAssertTrue(plan.contains { $0.contains("SEARCH a USING INTEGER PRIMARY KEY") })
        XCTAssertFalse(plan.contains { $0.hasPrefix("SCAN a") })
    }
}
