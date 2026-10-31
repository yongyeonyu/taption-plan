import Foundation
import Synchronization
import XCTest
import TaptionPlanStore

final class TaptionStoreRecordTests: XCTestCase {
    private func record(updated: Double, deleted: Bool = false, body: String = "{}") -> TaptionStoreRecord {
        TaptionStoreRecord(
            id: "a",
            kind: "plan",
            updatedAt: Date(timeIntervalSince1970: updated),
            origin: .user,
            isDeleted: deleted,
            body: body
        )
    }

    func testMergeOrderIsLaterUpdateThenDeletionThenBodyDigest() {
        let existing = TaptionRecordMerge.Existing(updated: 10, isDeleted: false, body: "{\"v\":1}")
        XCTAssertTrue(TaptionRecordMerge.incomingWins(existing: existing, incoming: record(updated: 11)))
        XCTAssertFalse(TaptionRecordMerge.incomingWins(existing: existing, incoming: record(updated: 9)))
        XCTAssertTrue(TaptionRecordMerge.incomingWins(existing: existing, incoming: record(updated: 10, deleted: true)))

        // 같은 시각·같은 삭제 상태면 본문 해시가 큰 쪽이 이긴다. 순서를 바꿔도 결과가 하나로 수렴한다.
        let left = "{\"v\":1}"
        let right = "{\"v\":2}"
        let leftWinsOverRight = TaptionRecordMerge.incomingWins(
            existing: .init(updated: 10, isDeleted: false, body: right),
            incoming: record(updated: 10, body: left)
        )
        let rightWinsOverLeft = TaptionRecordMerge.incomingWins(
            existing: .init(updated: 10, isDeleted: false, body: left),
            incoming: record(updated: 10, body: right)
        )
        XCTAssertNotEqual(leftWinsOverRight, rightWinsOverLeft)
        XCTAssertFalse(TaptionRecordMerge.incomingWins(
            existing: .init(updated: 10, isDeleted: false, body: left),
            incoming: record(updated: 10, body: left)
        ))
    }

    func testRawPayloadRoundTripsNonFiniteNumbersAndExactDates() throws {
        struct Payload: Codable, Equatable {
            var date: Date
            var values: [Double]
        }
        let payload = Payload(date: Date(timeIntervalSinceReferenceDate: 812_345_678.123_456_7), values: [1.5, .infinity, -.infinity])
        let text = try TaptionRawPayloadCoding.encode(payload)
        XCTAssertEqual(try TaptionRawPayloadCoding.decode(Payload.self, from: text), payload)
    }

    func testDiagnosticsSinkReceivesLedgerEventsOnceInstalled() {
        let events = Mutex<[String]>([])
        TaptionStoreDiagnostics.install { event, _, _ in events.withLock { $0.append(event) } }
        TaptionStoreQualityLedger.shared.reset()
        TaptionStoreQualityLedger.shared.recordDemotedColumn("speed_mps")
        TaptionStoreQualityLedger.shared.recordDayDrift(days: 2, rows: 5)
        XCTAssertEqual(events.withLock { $0 }, ["store_column_demoted", "store_day_drift"])
        XCTAssertEqual(TaptionStoreQualityLedger.shared.snapshot().demotedColumns, ["speed_mps": 1])
        TaptionStoreQualityLedger.shared.reset()
    }
}
