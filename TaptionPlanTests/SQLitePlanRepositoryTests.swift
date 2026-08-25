import Foundation
import XCTest
@testable import TaptionPlan
import TaptionPlanCore

final class SQLitePlanRepositoryTests: XCTestCase {
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
