import Foundation
import XCTest
@testable import TaptionPlan
import TaptionPlanCore

final class SQLitePlanRepositoryTests: XCTestCase {
    func testFileRepositoryDecodesSecondsSince1970LZFSESnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("taption-plan-legacy-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("snapshot.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        var value = TaptionDataSnapshot.empty
        value.updatedAt = Date(timeIntervalSince1970: 1_725_000_123.25)
        value.plans = [
            PlanRecord(
                title: "Unix 시간 기록",
                span: TimeSpan(
                    start: Date(timeIntervalSince1970: 1_725_000_000.5),
                    end: Date(timeIntervalSince1970: 1_725_000_060.75)
                ),
                categoryID: "activity"
            )
        ]
        let json = try SnapshotExporter.jsonData(value, prettyPrinted: false)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try TaptionSnapshotCompression.encode(json).write(
            to: fileURL,
            options: [.atomic]
        )

        let restored = try await FilePlanRepository(fileURL: fileURL).load()
        XCTAssertEqual(restored.updatedAt, value.updatedAt)
        let restoredPlan = try XCTUnwrap(restored.plans.first)
        let originalPlan = try XCTUnwrap(value.plans.first)
        XCTAssertEqual(restoredPlan.id, originalPlan.id)
        XCTAssertEqual(restoredPlan.title, originalPlan.title)
        XCTAssertEqual(restoredPlan.categoryID, originalPlan.categoryID)
        XCTAssertEqual(
            restoredPlan.span.start.timeIntervalSince1970,
            originalPlan.span.start.timeIntervalSince1970,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            restoredPlan.span.end.timeIntervalSince1970,
            originalPlan.span.end.timeIntervalSince1970,
            accuracy: 0.000_001
        )
    }

    func testLegacyMigrationReturnsBeforePrimaryWriteFinishes() async throws {
        var existing = TaptionDataSnapshot.empty
        existing.updatedAt = Date(timeIntervalSince1970: 1_725_000_000)
        existing.plans = [
            PlanRecord(
                title: "기존 기록",
                span: TimeSpan(
                    start: existing.updatedAt,
                    end: existing.updatedAt.addingTimeInterval(60)
                ),
                categoryID: "activity"
            )
        ]
        let primary = BlockingPlanRepository()
        let repository = MigratingPlanRepository(
            primary: primary,
            legacy: InMemoryPlanRepository(snapshot: existing)
        )

        let loaded = try await repository.load()
        XCTAssertEqual(loaded.plans, existing.plans)
        await primary.waitUntilSaveStarted()
        let primaryBeforeRelease = try await primary.load()
        XCTAssertTrue(primaryBeforeRelease.plans.isEmpty)

        await primary.releaseSave()
        for _ in 0..<100 {
            if (try await primary.load()).plans == existing.plans { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("background legacy migration did not finish")
    }

    func testRoundTripReopenAndUncompressedJSONPayload() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        var value = TaptionDataSnapshot.empty
        value.updatedAt = Date(timeIntervalSince1970: 123)
        value.plans = [
            PlanRecord(
                title: "분할 저장",
                span: TimeSpan(
                    start: Date(timeIntervalSince1970: 100),
                    end: Date(timeIntervalSince1970: 200)
                ),
                categoryID: "work",
                createdAt: Date(timeIntervalSince1970: 50),
                updatedAt: Date(timeIntervalSince1970: 60)
            )
        ]

        let repository = try SQLitePlanRepository(databaseURL: url)
        try await repository.save(value)
        let first = try await repository.load()
        XCTAssertEqual(first.plans, value.plans)
        XCTAssertEqual(first.actuals, value.actuals)
        XCTAssertGreaterThan(first.updatedAt, value.updatedAt)

        let reopened = try SQLitePlanRepository(databaseURL: url)
        let second = try await reopened.load()
        XCTAssertEqual(second.plans, first.plans)
        XCTAssertEqual(second.actuals, first.actuals)
        XCTAssertEqual(second.updatedAt, first.updatedAt)

        let store = try TaptionPlanDayStore(url: url)
        let rows = try await store.snapshots(
            day: .init(year: 0, month: 0, day: 0)
        )
        XCTAssertTrue(rows.contains { $0.domain == "plan.plans" })
        XCTAssertFalse(rows.contains { $0.domain == "plan.snapshot" })
        let payload = try XCTUnwrap(
            rows.first(where: { $0.domain == "plan.plans" })?.payload
        )
        XCTAssertEqual(payload.first, 0x5B)
        XCTAssertFalse(payload.starts(with: [0x54, 0x50, 0x5A, 0x31]))
        XCTAssertTrue(String(decoding: payload, as: UTF8.self).contains("분할 저장"))
    }

    func testSaveOverwritesWithMonotonicRevision() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let repository = try SQLitePlanRepository(databaseURL: url)
        try await repository.save(.empty)
        try await repository.save(.empty)

        let store = try TaptionPlanDayStore(url: url)
        let snapshot = try await store.snapshot(
            domain: "plan.metadata",
            day: .init(year: 0, month: 0, day: 0)
        )
        XCTAssertEqual(snapshot?.revision, 2)
    }

    func testUnchangedDomainsAreNotRewritten() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        var value = TaptionDataSnapshot.empty
        value.plans = [
            PlanRecord(
                title: "고정 계획",
                span: TimeSpan(start: .now, end: .now.addingTimeInterval(60)),
                categoryID: "work"
            )
        ]
        let repository = try SQLitePlanRepository(databaseURL: url)
        try await repository.save(value)
        let store = try TaptionPlanDayStore(url: url)
        let day = TaptionPlanDayKey(year: 0, month: 0, day: 0)
        let firstPlan = try await store.snapshot(domain: "plan.plans", day: day)
        let firstPlanRevision = try XCTUnwrap(firstPlan?.revision)

        try await repository.save(value)
        let secondPlan = try await store.snapshot(domain: "plan.plans", day: day)
        let metadata = try await store.snapshot(domain: "plan.metadata", day: day)
        let secondPlanRevision = try XCTUnwrap(secondPlan?.revision)
        let metadataRevision = try XCTUnwrap(metadata?.revision)

        XCTAssertEqual(firstPlanRevision, secondPlanRevision)
        XCTAssertEqual(metadataRevision, 2)
    }

    func testMissingDatabaseLoadsEmpty() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let repository = try SQLitePlanRepository(databaseURL: url)

        let value = try await repository.load()

        XCTAssertEqual(value, .empty)
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("taption-plan-repository-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
    }

    private func removeDatabase(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }
}

private actor BlockingPlanRepository: PlanDataRepository {
    private var value = TaptionDataSnapshot.empty
    private var saveStarted = false
    private var pendingSave: CheckedContinuation<Void, Never>?

    func load() async throws -> TaptionDataSnapshot {
        value
    }

    func save(_ snapshot: TaptionDataSnapshot) async throws {
        saveStarted = true
        await withCheckedContinuation { continuation in
            pendingSave = continuation
        }
        value = snapshot
    }

    func waitUntilSaveStarted() async {
        for _ in 0..<100 {
            if saveStarted { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func releaseSave() {
        pendingSave?.resume()
        pendingSave = nil
    }
}
