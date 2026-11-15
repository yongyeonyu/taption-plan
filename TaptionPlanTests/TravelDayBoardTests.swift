import XCTest
@testable import TaptionPlan
import TaptionPlanStore

/// TVY1116B01: 여행 모드 B안 「지도 + 날짜 보드」 — 동선 정리, 다른 날로 옮기기, 날짜 통째 옮기기.
@MainActor
final class TravelDayBoardTests: XCTestCase {
    private typealias Stop = TravelCourseSort.Stop

    /// 경도는 같고 위도만 다른 곳(0.01도 ≈ 1.1 km). `latitude`가 nil이면 핀 없는 곳.
    private func stop(_ id: String, _ start: Int, _ end: Int, _ latitude: Double?, fixed: Bool = false) -> Stop {
        Stop(id: id, startMinute: start, endMinute: end, latitude: latitude, longitude: latitude == nil ? nil : 129, isTimeFixed: fixed)
    }

    private func block(_ id: String, _ start: Int, _ end: Int, kind: String = "sight", booked: Bool = false, parent: String? = nil) -> TravelPlanTableModel.Block {
        .init(id: id, column: 0, startMinute: start, endMinute: end, title: id, tripStatus: booked ? .booked : nil, status: .pending, kind: kind, parentID: parent)
    }

    // MARK: 동선 정리

    func testSortPutsNearStopsFirstAndKeepsTheFirstStop() throws {
        // a(0) → b(멀다) → c(가깝다) → d(가운데): 가까운 순서는 a, c, d, b.
        let stops = [stop("a", 540, 600, 35.00), stop("b", 600, 660, 35.09), stop("c", 660, 720, 35.01), stop("d", 720, 780, 35.05)]
        let plan = try XCTUnwrap(TravelCourseSort.plan(stops))
        XCTAssertEqual(plan.order, ["a", "c", "d", "b"])
        XCTAssertEqual(plan.moves, ["c": -60, "d": -60, "b": 120], "첫 곳은 그대로, 나머지는 자리의 시각으로")
        XCTAssertEqual(plan.beforeMeters, 23_350, accuracy: 200)
        XCTAssertEqual(plan.afterMeters, 10_010, accuracy: 200)
        XCTAssertEqual(TravelCourseSort.kilometers(plan.afterMeters), "10.0")
    }

    func testSortKeepsBookedLodgingAndPinlessStopsInPlace() throws {
        // x는 예약(시각 고정), p는 핀 없음(자리 고정). b는 예약 앞 구간에 혼자라 그대로, 뒤 구간의 c·d·e만 바뀐다.
        let stops = [
            stop("a", 540, 600, 35.00), stop("b", 600, 660, 35.09), stop("x", 720, 780, 35.02, fixed: true),
            stop("c", 780, 840, 35.01), stop("p", 840, 900, nil), stop("d", 900, 960, 35.08), stop("e", 960, 1_020, 35.03),
        ]
        XCTAssertEqual(TravelCourseSort.movableGroups(stops), [[1], [3, 5, 6]])
        let plan = try XCTUnwrap(TravelCourseSort.plan(stops))
        XCTAssertEqual(plan.order, ["a", "b", "x", "c", "p", "e", "d"])
        XCTAssertEqual(plan.moves, ["e": -60, "d": 60], "예약·핀 없는 곳·예약 앞의 곳은 시각이 그대로")
    }

    func testSortNeverCrossesATimeFixedStop() {
        // 예약 뒤의 c가 a 바로 옆이어도 예약 앞으로 넘어가지 않는다. 구간마다 한 곳뿐이라 바꿀 것이 없다.
        let stops = [stop("a", 540, 600, 35.00), stop("b", 600, 660, 35.09), stop("x", 720, 780, 35.05, fixed: true), stop("c", 780, 840, 35.001)]
        XCTAssertNil(TravelCourseSort.plan(stops))
        XCTAssertEqual(TravelCourseSort.sorted(stops), stops)
    }

    func testSortReturnsNilWhenAlreadyNearestOrTooFewPins() {
        XCTAssertNil(TravelCourseSort.plan([stop("a", 540, 600, 35.00), stop("b", 600, 660, 35.01), stop("c", 660, 720, 35.02)]), "이미 가까운 순서")
        XCTAssertNil(TravelCourseSort.plan([stop("a", 540, 600, 35.00), stop("b", 600, 660, nil), stop("c", 660, 720, nil)]), "핀이 없으면 바꾸지 않는다")
        XCTAssertNil(TravelCourseSort.plan([stop("a", 540, 600, 35.00), stop("b", 600, 660, 35.0004), stop("c", 660, 720, 35.0002)]), "100 m도 줄지 않으면 그대로")
        XCTAssertNil(TravelCourseSort.plan([]))
    }

    func testSortRetimesWithLengthsFollowingStopsAndGapsStayingPut() throws {
        // a 09:00–10:00, b 10:00–12:00(멀다), 틈 30, c 12:30–13:00(가깝다) → a, c, b. 구간의 끝 13:00은 그대로다.
        let stops = [stop("a", 540, 600, 35.00), stop("b", 600, 720, 35.09), stop("c", 750, 780, 35.01)]
        let plan = try XCTUnwrap(TravelCourseSort.plan(stops))
        XCTAssertEqual(plan.order, ["a", "c", "b"])
        XCTAssertEqual(plan.moves, ["c": -150, "b": 60])
    }

    func testSortNeverGetsLongerOnScatteredStops() {
        // 여러 모양에서 정리한 길이가 지금보다 길어지지 않고, 곳의 집합과 고정 자리가 그대로다.
        var seed: UInt64 = 20_261_116
        func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 33) / Double(1 << 31)
        }
        for _ in 0..<40 {
            let stops = (0..<9).map { index in
                Stop(id: "s\(index)", startMinute: 480 + index * 60, endMinute: 530 + index * 60,
                     latitude: index == 4 ? nil : 35 + next() * 0.2, longitude: index == 4 ? nil : 129 + next() * 0.2, isTimeFixed: index == 6)
            }
            let sorted = TravelCourseSort.sorted(stops)
            XCTAssertLessThanOrEqual(TravelCourseSort.length(sorted), TravelCourseSort.length(stops) + 0.001)
            XCTAssertEqual(Set(sorted.map(\.id)), Set(stops.map(\.id)))
            XCTAssertEqual([sorted[0].id, sorted[4].id, sorted[6].id], ["s0", "s4", "s6"])
            XCTAssertEqual(Set(sorted[1...5].map(\.id)), Set(stops[1...5].map(\.id)), "고정된 곳을 넘어가지 않는다")
            let moves = TravelCourseSort.moves(from: stops, to: sorted)
            XCTAssertNil(moves["s6"])
            // 옮긴 뒤에도 시간 순서가 새 순서와 같다.
            let starts = sorted.map { $0.startMinute + (moves[$0.id] ?? 0) }
            XCTAssertEqual(starts, starts.sorted())
        }
    }

    func testSortStopsMarkBookedLodgingSleepAndCalendarFixedAsTimeFixed() {
        let blocks = [
            block("a", 540, 600), block("b", 600, 660, booked: true), block("c", 660, 720, kind: "lodging"), block("d", 720, 780, kind: "sleep"),
            block("e", 780, 840), block("f", 840, 900), block("g", 900, 930, kind: "transfer"), block("h", 930, 1_050, kind: "flight"),
            block("a1", 550, 560, parent: "a"),
        ]
        let stops = TravelDayBoard.sortStops(blocks, pins: ["a": (35, 129), "f": (35.1, 129.1)], fixedIDs: ["e"])
        XCTAssertEqual(stops.map(\.id), ["a", "b", "c", "d", "e", "f", "g", "h"], "세부 계획은 굵은 곳에 딸려 가므로 뺀다")
        XCTAssertEqual(stops.map(\.isTimeFixed), [false, true, true, true, true, false, true, true], "예약·숙소·잠·캘린더 고정·이동·항공")
        XCTAssertEqual(stops.map(\.hasPin), [true, false, false, false, false, true, false, false])
    }

    // MARK: 다른 날로 옮기기

    private func item(_ id: String, day: String, minute: Int, length: Int = 60, kind: String = "sight", status: String? = nil, parent: String? = nil) -> TravelTripItem {
        let start = TravelQuickEntrySheet.date(dayKey: day, minute: minute, offsetSeconds: 32_400)
        return TravelTripItem(
            tripID: "t1", itemID: id, kind: kind, title: id, start: start, end: start.addingTimeInterval(TimeInterval(length * 60)),
            startOffsetSeconds: 32_400, endOffsetSeconds: 32_400, planID: nil, status: status, parentItemID: parent
        )
    }

    func testMovingToAnotherDayAppendsAfterThatDaysLastPlan() {
        let moving = item("a", day: "2026-12-02", minute: 600)
        let target = [block("x", 540, 660), block("y", 780, 900), block("z", 1_320, 1_440, kind: "sleep")]
        // 이틀 뒤, 그날 마지막 일정(잠은 건너뜀) 끝 15:00에 붙는다.
        XCTAssertEqual(TravelDayBoard.minutes(item: moving, toDay: "2026-12-04", blocks: target, nowMinute: nil), 2 * 1_440 + 300)
        XCTAssertEqual(TravelDayBoard.minutes(item: moving, toDay: "2026-12-01", blocks: [], nowMinute: nil), -1_440 - 60, "빈 날은 09:00")
        XCTAssertNil(TravelDayBoard.minutes(item: moving, toDay: "2026-12-02", blocks: target, nowMinute: nil), "같은 날이면 옮기지 않는다")
        XCTAssertNil(TravelDayBoard.minutes(item: moving, toDay: "어느 날", blocks: target, nowMinute: nil))
    }

    func testBookedAndSleepKeepTheirClockWhenMovedToAnotherDay() {
        let target = [block("x", 540, 900)]
        XCTAssertEqual(TravelDayBoard.minutes(item: item("b", day: "2026-12-02", minute: 720, status: "booked"), toDay: "2026-12-05", blocks: target, nowMinute: nil), 3 * 1_440)
        XCTAssertEqual(TravelDayBoard.minutes(item: item("s", day: "2026-12-02", minute: 1_380, kind: "sleep"), toDay: "2026-12-01", blocks: target, nowMinute: nil), -1_440)
    }

    func testMoveStepIsOneUndoStepAndDragTextRoundTrips() throws {
        let step = try XCTUnwrap(TravelDayBoard.step(item: item("a", day: "2026-12-02", minute: 600), toDay: "2026-12-03", dayLabel: "2일차 12/3", blocks: [], nowMinute: nil))
        XCTAssertEqual(step.move, 1_440 - 60)
        XCTAssertEqual(step.summary, "→ 2일차 12/3 a")
        var history = TravelPlanHistory()
        history.record(step)
        XCTAssertEqual(history.undo()?.move, -(1_440 - 60))
        XCTAssertFalse(history.canUndo, "한 걸음으로 쌓인다")

        XCTAssertEqual(TravelDayBoard.itemID(fromDrag: TravelDayBoard.dragText("m-12ab")), "m-12ab")
        XCTAssertNil(TravelDayBoard.itemID(fromDrag: "m-12ab"))
        XCTAssertNil(TravelDayBoard.itemID(fromDrag: TravelDayBoard.dragPrefix))
    }

    func testDayLabelsMatchTheChips() {
        let days = TravelDayBoard.days(of: TravelTrip(id: "t1", title: "t", startDay: "2026-12-02", endDay: "2026-12-04"), language: .korean)
        XCTAssertEqual(days.map(\.key), ["2026-12-02", "2026-12-03", "2026-12-04"])
        XCTAssertEqual(days.map(\.label), ["1일차 12/2", "2일차 12/3", "3일차 12/4"])
    }

    // MARK: 저장소까지(세부 동반·되돌리기)

    /// 기기 시간대의 그날 `minute`분.
    private func local(_ day: String, _ minute: Int) throws -> Date {
        let midnight = try XCTUnwrap(TravelTripDay.components(day).flatMap(Calendar.autoupdatingCurrent.date(from:)))
        return midnight.addingTimeInterval(TimeInterval(minute * 60))
    }

    private func wall(_ item: TravelTripItem?) -> String {
        guard let item else { return "없음" }
        let focus = TravelMapSpot.focus(item)
        return focus.dayKey + " " + TravelQuickEntrySheet.clock(focus.minute)
    }

    private func add(_ model: AppModel, _ title: String, day: String, minute: Int, length: Int = 60, place: TravelItemPlace? = nil, parent: String? = nil) async throws -> String {
        let start = try local(day, minute)
        let id = await model.addTripItem(
            tripID: "t1", kind: .sight, title: title, start: start, end: start.addingTimeInterval(TimeInterval(length * 60)),
            offsetSeconds: TimeZone.autoupdatingCurrent.secondsFromGMT(for: start), place: place, parentItemID: parent
        )
        return try XCTUnwrap(id)
    }

    private func tripModel() async -> AppModel {
        let model = AppModel(repository: InMemoryPlanRepository(), cloudSyncService: nil)
        await model.bootstrapLocalSnapshot()
        let saved = await model.saveTravelTrip(TravelTrip(id: "t1", title: "부산", startDay: "2026-12-02", endDay: "2026-12-04"))
        XCTAssertTrue(saved)
        return model
    }

    private func found(_ model: AppModel, _ id: String) -> TravelTripItem? {
        model.settings.travelTripItems?.first { $0.tripID == "t1" && $0.itemID == id }
    }

    func testMovingAStopToAnotherDayTakesItsDetailsAndUndoesInOneStep() async throws {
        let model = await tripModel()
        let parent = try await add(model, "시장", day: "2026-12-02", minute: 600, length: 120, place: TravelItemPlace(name: "시장", latitude: 35.1, longitude: 129.03))
        let detail = try await add(model, "어묵", day: "2026-12-02", minute: 630, length: 30, parent: parent)
        let other = try await add(model, "전망대", day: "2026-12-04", minute: 540, length: 90)

        let moved = await TravelDayBoard.move(model: model, tripID: "t1", itemID: parent, toDay: "2026-12-04", dayLabel: "3일차 12/4")
        let step = try XCTUnwrap(moved)
        XCTAssertEqual(wall(found(model, parent)), "2026-12-04 10:30", "그 날 마지막 일정 끝에 붙는다")
        XCTAssertEqual(wall(found(model, detail)), "2026-12-04 11:00", "세부 계획은 부모와 같은 만큼")
        XCTAssertEqual(found(model, parent).map { $0.end.timeIntervalSince($0.start) }, 7_200, "길이는 그대로")
        XCTAssertEqual(wall(found(model, other)), "2026-12-04 09:00")
        let pin = try XCTUnwrap(model.settings.travelPlanStops.first { $0.itemID == parent })
        XCTAssertEqual(TravelModeView.dayKey(pin.day), "2026-12-04", "지도 핀 날짜도 함께")

        var history = TravelPlanHistory()
        history.record(step)
        await model.applyTravelHistory(try XCTUnwrap(history.undo()))
        XCTAssertEqual(wall(found(model, parent)), "2026-12-02 10:00")
        XCTAssertEqual(wall(found(model, detail)), "2026-12-02 10:30")
        XCTAssertFalse(history.canUndo)

        let same = await TravelDayBoard.move(model: model, tripID: "t1", itemID: parent, toDay: "2026-12-02", dayLabel: "")
        XCTAssertNil(same, "같은 날로는 옮기지 않는다")
        let missing = await TravelDayBoard.move(model: model, tripID: "t1", itemID: "없음", toDay: "2026-12-03", dayLabel: "")
        XCTAssertNil(missing)
    }

    func testSortingADayAppliesAndUndoesInOneStep() async throws {
        let model = await tripModel()
        func place(_ latitude: Double) -> TravelItemPlace { TravelItemPlace(name: "곳", latitude: latitude, longitude: 129) }
        let a = try await add(model, "a", day: "2026-12-03", minute: 540, place: place(35.00))
        let b = try await add(model, "b", day: "2026-12-03", minute: 600, place: place(35.09))
        let c = try await add(model, "c", day: "2026-12-03", minute: 660, place: place(35.01))
        let c1 = try await add(model, "c1", day: "2026-12-03", minute: 670, length: 20, parent: c)

        let stops = TravelDayBoard.sortStops(model: model, tripID: "t1", dayKey: "2026-12-03")
        XCTAssertEqual(stops.map(\.id), [a, b, c])
        let plan = try XCTUnwrap(TravelCourseSort.plan(stops))
        XCTAssertEqual(plan.order, [a, c, b])
        let step = try XCTUnwrap(TravelPlanHistory.Step.reorder(tripID: "t1", moves: plan.moves, title: "동선 정리"))
        let applied = await TripSharePlanEditor.applyStep(model: model, step)
        XCTAssertTrue(applied)
        XCTAssertEqual([a, b, c, c1].map { wall(found(model, $0)) }, ["2026-12-03 09:00", "2026-12-03 11:00", "2026-12-03 10:00", "2026-12-03 10:10"])
        XCTAssertNil(TravelCourseSort.plan(TravelDayBoard.sortStops(model: model, tripID: "t1", dayKey: "2026-12-03")), "정리한 뒤에는 이미 가까운 순서")

        var history = TravelPlanHistory()
        history.record(step)
        await model.applyTravelHistory(try XCTUnwrap(history.undo()))
        XCTAssertEqual([a, b, c, c1].map { wall(found(model, $0)) }, ["2026-12-03 09:00", "2026-12-03 10:00", "2026-12-03 11:00", "2026-12-03 11:10"])
    }

    /// 여행 시작일을 옮기면 세부 계획까지 같은 날 수만큼 옮겨진다(이미 있던 동작, TVX1112A01).
    func testShiftingATripMovesStopsAndTheirDetailsBySameDays() async throws {
        let model = await tripModel()
        let parent = try await add(model, "시장", day: "2026-12-02", minute: 600, length: 120, place: TravelItemPlace(name: "시장", latitude: 35.1, longitude: 129.03))
        let detail = try await add(model, "어묵", day: "2026-12-02", minute: 630, length: 30, parent: parent)
        let last = try await add(model, "전망대", day: "2026-12-04", minute: 540)
        let old = try XCTUnwrap(model.settings.travelTrips?.first)
        var trip = old
        (trip.startDay, trip.endDay) = ("2026-12-12", "2026-12-14")
        let saved = await model.saveTravelTrip(trip)
        XCTAssertTrue(saved)
        // 여행 고치기(`TravelNewTripSheet.create`)가 하는 일: 첫날이 옮겨진 날 수만큼 통째로.
        let days = try XCTUnwrap(TravelTripDay.days(from: old.planStartDay, to: trip.planStartDay))
        XCTAssertEqual(days, 10)
        let shifted = await model.shiftTravelTrip("t1", byDays: days)
        XCTAssertTrue(shifted)
        XCTAssertEqual([parent, detail, last].map { wall(found(model, $0)) }, ["2026-12-12 10:00", "2026-12-12 10:30", "2026-12-14 09:00"])
        XCTAssertEqual(found(model, detail)?.parentItemID, parent)
        let pin = try XCTUnwrap(model.settings.travelPlanStops.first { $0.itemID == parent })
        XCTAssertEqual(TravelModeView.dayKey(pin.day), "2026-12-12")
        XCTAssertEqual(model.settings.travelTrips?.first.map { [$0.startDay, $0.endDay] }, ["2026-12-12", "2026-12-14"])
    }
}
