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

    /// TVM1117A02: 어젯밤부터 이어진 숙소·잠은 오늘 0시부터 걸친 칸이라도 「지금」이 아니다. 오늘 밤에 시작한 잠과 밤샘 비행은 그대로 「지금」.
    func testLodgingAndSleepCarriedFromYesterdayAreNotNow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        func overnight(_ id: String, _ kind: String, from: Int, to: Int) -> TravelTripItem {
            TravelTripItem(tripID: "t1", itemID: id, kind: kind, title: id, start: at(0).addingTimeInterval(TimeInterval(from * 60)),
                           end: at(0).addingTimeInterval(TimeInterval(to * 60)), startOffsetSeconds: 0, endOffsetSeconds: 0, planID: nil)
        }
        let items = [
            overnight("hotel", "lodging", from: -9 * 60, to: 11 * 60), overnight("night", "sleep", from: -60, to: 7 * 60),
            overnight("red-eye", "flight", from: -2 * 60, to: 6 * 60), overnight("tonight", "sleep", from: 23 * 60, to: 31 * 60),
        ]
        let table = TravelPlanTableModel.make(items: items, tripID: "t1", day: at(0), actual: [], now: at(5), calendar: calendar)
        XCTAssertEqual(Set(table.blocks.filter(\.carriesOver).map(\.id)), ["hotel", "night", "red-eye"], "0시 전에 시작한 칸")
        XCTAssertEqual(TravelTodayBoard.make(blocks: table.blocks, nowMinute: 5 * 60).current?.id, "red-eye", "이어진 비행은 지금")
        let morning = TravelTodayBoard.make(blocks: table.blocks, nowMinute: 9 * 60)
        XCTAssertNil(morning.current, "어제 들어간 숙소는 지금이 아니다")
        XCTAssertEqual(TravelTodayBoard.make(blocks: table.blocks, nowMinute: 23 * 60 + 30).current?.id, "tonight", "오늘 밤의 잠은 지금")
    }

    /// TVM1117A02: 여행 화면 본문 한 번(계획표를 올린 상태)에 계획표 모델을 20번 묻는다(지구본 그림 6·지도 9·돈 줄 1·계획표 3·날짜 보드 1).
    /// 내용 번호·날·지금 분이 같으면 한 번만 만들고, 하나라도 바뀌면 다시 만든다. 전후 시간은 로그 `TVM1117A02 perf`로 남긴다.
    @MainActor
    func testPlanTableCacheBuildsOncePerBodyAndRebuildsOnChange() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let day = at(0), now = at(12)
        // 그날 일정 40개, 실제 기록 30일치 1,500건, 지출 600건.
        let items = (0..<40).map { index in
            TravelTripItem(tripID: "t1", itemID: "i\(index)", kind: index % 4 == 0 ? "transfer" : "sight", title: "곳 \(index)",
                           start: day.addingTimeInterval(TimeInterval(index * 1_800)), end: day.addingTimeInterval(TimeInterval(index * 1_800 + 1_500)),
                           startOffsetSeconds: 0, endOffsetSeconds: 0, planID: nil)
        }
        let actuals = (0..<1_500).map { index in
            ActualRecord(planID: nil, title: "기록", categoryID: index % 3 == 0 ? "movement" : "hobby",
                         startedAt: day.addingTimeInterval(TimeInterval(-29 * 86_400 + index * 1_700)),
                         endedAt: day.addingTimeInterval(TimeInterval(-29 * 86_400 + index * 1_700 + 1_500)), source: .motion)
        }
        let entries = (0..<600).map { LedgerEntry(occurredAt: day.addingTimeInterval(TimeInterval($0 * 130)), amount: 1_000, title: "지출", tripID: "t1") }
        func build() -> TravelPlanTableModel {
            TravelPlanTableModel.make(
                items: items, tripID: "t1", day: day, actual: MapHomeTimeRailSegmentEngine.segments(from: actuals, on: day, asOf: now, calendar: calendar),
                now: now, spent: TravelPlanSpend.byItem(items: items, tripID: "t1", entries: entries), calendar: calendar
            )
        }
        let lookupsPerBody = 20
        let cache = TravelPlanTableCache()
        let key = TravelPlanTableCache.Key(tripID: "t1", dayKey: "2027-01-15", contentRevision: 7, ledgerRevision: 3, columns: nil, nowMinute: 100, timeZone: "GMT")
        _ = build() // 처음 한 번은 재지 않는다.
        let clock = ContinuousClock()
        let before = clock.measure { for _ in 0..<lookupsPerBody { _ = build() } }
        var first: TravelPlanTableModel?
        let after = clock.measure { for _ in 0..<lookupsPerBody { first = cache.table(key, make: build) } }
        XCTAssertEqual(cache.builds, 1, "본문 한 번에 한 번만 만든다")
        XCTAssertEqual(cache.lookups, lookupsPerBody)
        XCTAssertEqual(first, build())
        print("TVM1117A02 perf: 본문 한 번(묻기 \(lookupsPerBody)) 전 \(before) · 후 \(after) · 만들기 \(lookupsPerBody) → \(cache.builds)")

        var changed = key
        changed.contentRevision += 1
        _ = cache.table(changed, make: build)
        changed.ledgerRevision += 1
        _ = cache.table(changed, make: build)
        changed.nowMinute += 1
        _ = cache.table(changed, make: build)
        changed.dayKey = "2027-01-16"
        _ = cache.table(changed, make: build)
        changed.columns = TravelPlanColumns.defaults
        _ = cache.table(changed, make: build)
        XCTAssertEqual(cache.builds, 6, "일정·지출·지금 분·날·열이 바뀌면 다시 만든다")
        _ = cache.table(changed, make: build)
        XCTAssertEqual(cache.builds, 6)
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
