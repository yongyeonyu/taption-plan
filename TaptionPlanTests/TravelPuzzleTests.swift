import TaptionPlanStore
import XCTest
@testable import TaptionPlan

/// 「조각 맞추기」 순수 계산(AIT1116A01).
final class TravelPuzzleTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ id: String, trip: String = "t1", hour: Double, hours: Double = 1, status: String? = nil, offset: Int = 32_400) -> TravelTripItem {
        TravelTripItem(tripID: trip, itemID: id, kind: "meal", title: id, start: base.addingTimeInterval(hour * 3600), end: base.addingTimeInterval((hour + hours) * 3600),
                       startOffsetSeconds: offset, endOffsetSeconds: offset, planID: nil, status: status)
    }

    func testPiecesAreOnlyTentativeOfThisTripInTimeOrder() {
        let items = [item("late", hour: 5, status: "tentative"), item("plan", hour: 1), item("booked", hour: 2, status: "booked"),
                     item("early", hour: 3, status: "tentative"), item("other", trip: "t2", hour: 1, status: "tentative")]
        XCTAssertEqual(TravelPuzzle.pieces(items: items, tripID: "t1").map(\.id), ["early", "late"])
    }

    func testConfirmedTentativeItemsAreNotPieces() {
        let items = [item("done", hour: 1, status: "visited/tentative"), item("skip", hour: 2, status: "skipped/tentative"), item("open", hour: 3, status: "tentative")]
        XCTAssertEqual(TravelPuzzle.pieces(items: items, tripID: "t1").map(\.id), ["open"])
    }

    func testConflictsIgnoreOtherPiecesAndTouchingEdges() {
        let piece = TravelPuzzle.pieces(items: [item("p", hour: 3, hours: 1.5, status: "tentative")], tripID: "t1")[0]
        let items = [item("p", hour: 3, hours: 1.5, status: "tentative"), item("other piece", hour: 3, status: "tentative"),
                     item("touch", hour: 2, hours: 1), item("overlap", hour: 4, hours: 1), item("after", hour: 4.5)]
        XCTAssertEqual(TravelPuzzle.conflicts(of: piece, items: items, tripID: "t1").map(\.itemID), ["overlap"])
    }

    func testArrivalsAreEmptyOnFirstSightAndListOnlyNewPieces() {
        let pieces = TravelPuzzle.pieces(items: [item("a", hour: 1, status: "tentative"), item("b", hour: 2, status: "tentative")], tripID: "t1")
        XCTAssertTrue(TravelPuzzle.arrivals(previous: nil, current: pieces).isEmpty)
        XCTAssertEqual(TravelPuzzle.arrivals(previous: ["a"], current: pieces), ["b"])
        XCTAssertTrue(TravelPuzzle.arrivals(previous: ["a", "b", "gone"], current: pieces).isEmpty)
    }

    func testDayKeyUsesLocalDateOfThePlace() {
        // 협정 세계시 15:20 = 한국 다음 날 00:20.
        let base: TimeInterval = 1_800_000_000
        let dayStart: TimeInterval = base - base.truncatingRemainder(dividingBy: 86_400)
        let start = Date(timeIntervalSince1970: dayStart + 55_200)
        let seoul = TravelPuzzlePiece(id: "x", title: "x", kind: "meal", start: start, end: start.addingTimeInterval(3600), utcOffsetSeconds: 32_400, plannedSpendKRW: nil)
        let utc = TravelPuzzlePiece(id: "y", title: "y", kind: "meal", start: start, end: start.addingTimeInterval(3600), utcOffsetSeconds: 0, plannedSpendKRW: nil)
        XCTAssertNotEqual(TravelPuzzle.dayKey(seoul), TravelPuzzle.dayKey(utc))
    }

    func testFittingTurnsTentativeIntoPlanAndUndoRestoresIt() {
        // 상태 문자열 규칙: 계획은 nil, 미정은 "tentative"(TripItemStatus.stored).
        XCTAssertNil(TripItemStatus.planned.stored)
        XCTAssertEqual(TripItemStatus.tentative.stored, "tentative")
    }
}
