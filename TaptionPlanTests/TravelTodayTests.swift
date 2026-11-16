import XCTest
@testable import TaptionPlan
import TaptionPlanCore
import TaptionPlanStore

/// TVZ1116C01: 여행 중 오늘 카드 — 지금·다음 고르기, 확정 대상, 자동 기록 맞춤, 상태 칸에 적는 값.
final class TravelTodayTests: XCTestCase {
    private let dayStart = Date(timeIntervalSince1970: 1_799_971_200)

    private func at(_ hour: Int, _ minute: Int = 0) -> Date { dayStart.addingTimeInterval(TimeInterval(hour * 3_600 + minute * 60)) }

    private func block(_ id: String, _ start: Int, _ end: Int, parent: String? = nil) -> TravelPlanTableModel.Block {
        TravelPlanTableModel.Block(id: id, column: 0, startMinute: start, endMinute: end, title: "곳 \(id)", status: .pending, parentID: parent)
    }

    private func item(_ id: String, _ from: Int, _ to: Int, status: String? = nil, planID: UUID? = nil) -> TravelTripItem {
        TravelTripItem(tripID: "t1", itemID: id, kind: "sight", title: "곳 \(id)", start: at(from), end: at(to),
                       startOffsetSeconds: 0, endOffsetSeconds: 0, planID: planID, status: status)
    }

    private func stay(_ from: Date, _ to: Date, latitude: Double) -> PlaceStay {
        PlaceStay(placeKey: "k", displayName: "머문 곳", span: TimeSpan(start: from, end: to), confidence: .high,
                  point: GeoPoint(latitude: latitude, longitude: 20, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10))
    }

    private let pin = TravelPlanStop(id: UUID(), title: "곳 a", latitude: 10, longitude: 20, day: .distantPast, order: 0, planID: nil, tripID: "t1", itemID: "a")

    // MARK: 지금·다음

    func testPicksCurrentAndNextWithTravelMinutes() {
        let blocks = [block("c", 15 * 60, 16 * 60), block("a", 9 * 60, 10 * 60), block("b", 11 * 60, 13 * 60)]
        let board = TravelTodayBoard.make(blocks: blocks, nowMinute: 12 * 60 + 25, travelMinutes: [TravelPlayhead.legKey("b", "c"): 12])
        XCTAssertFalse(board.isEmpty)
        XCTAssertEqual(board.current?.id, "b")
        XCTAssertEqual(board.remainingMinutes, 35)
        XCTAssertEqual(board.next?.id, "c")
        XCTAssertEqual(board.travelMinutes, 12)
    }

    func testBetweenPlansHasOnlyNextAndUsesNearestKnownLeg() {
        let blocks = [block("a", 9 * 60, 10 * 60), block("b", 10 * 60, 11 * 60), block("c", 15 * 60, 16 * 60)]
        // b에는 핀이 없어 a → c 구간만 받아 둔 경우.
        let board = TravelTodayBoard.make(blocks: blocks, nowMinute: 12 * 60, travelMinutes: [TravelPlayhead.legKey("a", "c"): 20])
        XCTAssertNil(board.current)
        XCTAssertEqual(board.next?.id, "c")
        XCTAssertEqual(board.travelMinutes, 20)
    }

    func testNoTravelMinutesWhenNoneLoadedAndAfterLastPlan() {
        let blocks = [block("a", 9 * 60, 10 * 60), block("b", 11 * 60, 12 * 60)]
        XCTAssertNil(TravelTodayBoard.make(blocks: blocks, nowMinute: 10 * 60 + 30).travelMinutes)
        let late = TravelTodayBoard.make(blocks: blocks, nowMinute: 20 * 60)
        XCTAssertNil(late.current)
        XCTAssertNil(late.next)
        XCTAssertFalse(late.isEmpty)
    }

    func testDayWithoutPlansIsEmpty() {
        let board = TravelTodayBoard.make(blocks: [], nowMinute: 12 * 60)
        XCTAssertTrue(board.isEmpty)
        XCTAssertNil(board.current)
        XCTAssertNil(board.next)
        XCTAssertTrue(board.reviews.isEmpty)
        // 길이가 없는 블록만 있어도 일정 없는 날이다.
        XCTAssertTrue(TravelTodayBoard.make(blocks: [block("z", 600, 600)], nowMinute: 700).isEmpty)
    }

    // MARK: 확정 대상

    func testReviewsArePastUnconfirmedTopLevelPlans() {
        let blocks = [
            block("a", 9 * 60, 10 * 60), block("a1", 9 * 60 + 10, 9 * 60 + 30, parent: "a"), block("b", 10 * 60, 11 * 60),
            block("c", 11 * 60, 13 * 60), block("d", 15 * 60, 16 * 60), block("orphan", 8 * 60, 8 * 60 + 30, parent: "gone"),
        ]
        let board = TravelTodayBoard.make(blocks: blocks, nowMinute: 12 * 60, marks: ["b": .skipped], suggested: ["a"])
        // 딸린 세부(a1)는 묻지 않고, 코스 곳이 그날에 없는 세부(orphan)는 굵은 곳으로 묻는다.
        XCTAssertEqual(board.reviews.map(\.id), ["orphan", "a"])
        XCTAssertEqual(board.reviews.map(\.suggestsVisited), [false, true])
        XCTAssertEqual(board.done.map(\.id), ["b"])
        XCTAssertEqual(board.done.first?.mark, .skipped)
        XCTAssertEqual(TravelTodayBoard.reviewIDs(blocks: blocks, nowMinute: 12 * 60, marks: ["b": .skipped]), ["orphan", "a"])
    }

    func testConfirmedPlanLeavesCurrentAndReviews() {
        let blocks = [block("a", 9 * 60, 10 * 60), block("b", 11 * 60, 13 * 60), block("c", 15 * 60, 16 * 60)]
        // 하던 일정을 일찍 「갔음」으로 끝내면 지금에서 빠지고, 끝 시각이 지나도 다시 묻지 않는다.
        let board = TravelTodayBoard.make(blocks: blocks, nowMinute: 12 * 60, marks: ["a": .visited, "b": .visited])
        XCTAssertNil(board.current)
        XCTAssertEqual(board.next?.id, "c")
        XCTAssertTrue(board.reviews.isEmpty)
        XCTAssertEqual(board.done.map(\.id), ["a", "b"])
        // 끝 시각이 딱 지금이면 지난 일정이다.
        XCTAssertEqual(TravelTodayBoard.make(blocks: blocks, nowMinute: 10 * 60).reviews.map(\.id), ["a"])
    }

    // MARK: 자동 기록 맞춤

    func testStayInsideRadiusAndTimeSuggestsVisited() {
        let plan = item("a", 10, 11)
        let now = at(12)
        XCTAssertTrue(TravelVisitMatch.isVisited(item: plan, stop: pin, stays: [stay(at(10, 20), at(10, 50), latitude: 10.0005)], now: now))
        // 반경 밖(약 1.1km).
        XCTAssertFalse(TravelVisitMatch.isVisited(item: plan, stop: pin, stays: [stay(at(10, 20), at(10, 50), latitude: 10.01)], now: now))
        // 같은 곳이어도 계획 시간과 30분 넘게 떨어진 머묾.
        XCTAssertFalse(TravelVisitMatch.isVisited(item: plan, stop: pin, stays: [stay(at(7), at(8), latitude: 10.0005)], now: now))
        // 조금 늦게 간 것(끝난 뒤 20분에 도착)은 같은 일정으로 본다.
        XCTAssertTrue(TravelVisitMatch.isVisited(item: plan, stop: pin, stays: [stay(at(11, 20), at(11, 40), latitude: 10.0005)], now: now))
        // 핀이 없으면 장소로는 알 수 없다.
        XCTAssertFalse(TravelVisitMatch.isVisited(item: plan, stop: nil, stays: [stay(at(10, 20), at(10, 50), latitude: 10.0005)], now: now))
        // 아직 오지 않은 시각의 기록은 세지 않는다.
        XCTAssertFalse(TravelVisitMatch.isVisited(item: plan, stop: pin, stays: [stay(at(10, 20), at(10, 50), latitude: 10.0005)], now: at(10, 10)))
    }

    func testLinkedRecordSuggestsVisitedWithoutPin() {
        let planID = UUID()
        let plan = item("a", 10, 11, planID: planID)
        let record = ActualRecord(planID: planID, title: "a", categoryID: "c", startedAt: at(10, 5), endedAt: at(10, 40), source: .manual)
        XCTAssertTrue(TravelVisitMatch.isVisited(item: plan, stop: nil, stays: [], actuals: [record], now: at(12)))
        XCTAssertFalse(TravelVisitMatch.isVisited(item: item("b", 10, 11, planID: UUID()), stop: nil, stays: [], actuals: [record], now: at(12)))
    }

    func testSuggestedOnlyLooksAtAskedPlans() {
        let items = [item("a", 10, 11), item("b", 13, 14)]
        let stays = [stay(at(10, 10), at(10, 50), latitude: 10.0005)]
        let stops = [pin, TravelPlanStop(id: UUID(), title: "곳 b", latitude: 10, longitude: 20, day: .distantPast, order: 1, planID: nil, tripID: "t1", itemID: "b")]
        XCTAssertEqual(TravelVisitMatch.suggested(ids: ["a", "b"], items: items, tripID: "t1", stops: stops, stays: stays, actuals: [], now: at(15)), ["a"])
        XCTAssertTrue(TravelVisitMatch.suggested(ids: [], items: items, tripID: "t1", stops: stops, stays: stays, actuals: [], now: at(15)).isEmpty)
        XCTAssertTrue(TravelVisitMatch.suggested(ids: ["a"], items: items, tripID: "other", stops: stops, stays: stays, actuals: [], now: at(15)).isEmpty)
    }

    // MARK: 상태 칸에 적는 값

    func testMarkKeepsBookedAndRestoresItOnUndo() {
        XCTAssertEqual(TravelVisitMark.stored(.visited, over: nil), "visited")
        XCTAssertEqual(TravelVisitMark.stored(.skipped, over: "booked"), "skipped/booked")
        XCTAssertEqual(TravelVisitMark.stored(.visited, over: "skipped/tentative"), "visited/tentative")
        XCTAssertEqual(TravelVisitMark.stored(nil, over: "visited/booked"), "booked")
        XCTAssertNil(TravelVisitMark.stored(nil, over: "visited"))
        XCTAssertNil(TravelVisitMark.stored(nil, over: nil))
        XCTAssertEqual(TravelVisitMark(stored: "visited/booked"), .visited)
        XCTAssertEqual(TravelVisitMark(stored: "skipped"), .skipped)
        XCTAssertNil(TravelVisitMark(stored: "booked"))
        XCTAssertNil(TravelVisitMark(stored: nil))
    }

    func testExistingStatusReadersStillSeeBookedAndPlanned() {
        // 예약 표시(시간 막대·핀)는 확정한 뒤에도 그대로 읽힌다.
        XCTAssertEqual(TripItemStatus(raw: "visited/booked"), .booked)
        XCTAssertEqual(TripItemStatus(raw: "skipped/tentative"), .tentative)
        XCTAssertEqual(TripItemStatus(raw: "visited"), .planned)
        XCTAssertEqual(TripItemStatus(raw: "booked"), .booked)
        XCTAssertEqual(TripItemStatus(raw: nil), .planned)
        // 밖에서 받은 글로는 확정 값을 상태로 받지 않는다.
        XCTAssertNil(TripItemStatus(explicit: "visited"))
    }

    func testStorableValuesFromSharedRoom() {
        for text in ["booked", "tentative", "visited", "skipped", "visited/booked", "skipped/tentative"] { XCTAssertTrue(TravelVisitMark.isStorable(text), text) }
        for text in ["", "planned", "done", "booked/visited", "visited/planned", "visited/booked/x", "visited/"] { XCTAssertFalse(TravelVisitMark.isStorable(text), text) }
    }

    func testMarksReadOnlyThatTrip() {
        var other = item("a", 9, 10, status: "skipped")
        other.tripID = "t2"
        let marks = TravelTodayBoard.marks([item("a", 9, 10, status: "visited/booked"), item("b", 10, 11, status: "booked"), other], tripID: "t1")
        XCTAssertEqual(marks, ["a": .visited])
    }

    @MainActor
    func testTexts() {
        XCTAssertEqual(TravelTodayText.clock(14 * 60 + 5), "14:05")
        XCTAssertEqual(TravelTodayText.clock(1_440), "00:00")
        XCTAssertEqual(TravelTodayText.left(35, .korean), "35분 남음")
        XCTAssertEqual(TravelTodayText.left(120, .korean), "2시간 남음")
        XCTAssertEqual(TravelTodayText.left(65, .english), "1 h 5 min left")
    }
}
