import XCTest
@testable import TaptionPlan
import TaptionPlanCore

/// ARC1114A14: 일정 장소 도착 판정과 카드 내용. 좌표는 꾸민 값이다.
final class ArrivalDetectorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let stopID = UUID()
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func stop(_ id: UUID? = nil, latitude: Double = 0.5, longitude: Double = 0.5, itemID: String? = "a", planID: UUID? = nil) -> TravelPlanStop {
        TravelPlanStop(id: id ?? stopID, title: "핀", latitude: latitude, longitude: longitude, day: now, order: 0, planID: planID, tripID: itemID == nil ? nil : "t1", itemID: itemID)
    }

    private func item(_ id: String = "a", start: TimeInterval = -600, end: TimeInterval = 3_600, note: String? = nil, spend: Double? = nil, parent: String? = nil) -> TravelTripItem {
        TravelTripItem(tripID: "t1", itemID: id, kind: "sight", title: "곳 \(id)", start: now.addingTimeInterval(start), end: now.addingTimeInterval(end),
                       startOffsetSeconds: 0, endOffsetSeconds: 0, planID: nil, note: note, plannedSpendKRW: spend, parentItemID: parent)
    }

    /// 위도 0.001도는 약 111m.
    private func fix(latitude: Double = 0.5, longitude: Double = 0.5, accuracy: Double = 20, age: TimeInterval = 1) -> ArrivalFix {
        ArrivalFix(latitude: latitude, longitude: longitude, horizontalAccuracy: accuracy, timestamp: now.addingTimeInterval(-age))
    }

    private func candidates(_ stops: [TravelPlanStop]? = nil, items: [TravelTripItem]? = nil, plans: [PlanRecord] = []) -> [ArrivalCandidate] {
        ArrivalDetector.candidates(stops: stops ?? [stop()], items: items ?? [item()], plans: plans, calendar: calendar)
    }

    private func arrival(_ fix: ArrivalFix, _ candidates: [ArrivalCandidate], shown: Set<UUID> = []) -> ArrivalCandidate? {
        ArrivalDetector.arrival(fix: fix, now: now, candidates: candidates, shown: shown)
    }

    func testArrivesInsideRadiusAndNotOutside() {
        XCTAssertEqual(arrival(fix(latitude: 0.501), candidates())?.stopID, stopID, "약 111m는 반경 안")
        XCTAssertNil(arrival(fix(latitude: 0.502), candidates()), "약 222m는 반경 밖")
    }

    func testPoorOrInvalidAccuracyIsNotJudged() {
        XCTAssertNotNil(arrival(fix(accuracy: 180), candidates()))
        XCTAssertNil(arrival(fix(accuracy: 181), candidates()))
        XCTAssertNil(arrival(fix(accuracy: -1), candidates()))
        XCTAssertNil(arrival(fix(accuracy: .infinity), candidates()))
    }

    func testStaleFixIsNotJudged() {
        XCTAssertNotNil(arrival(fix(age: 120), candidates()))
        XCTAssertNil(arrival(fix(age: 121), candidates()), "오래된 위치로 추정하지 않는다")
        XCTAssertNil(arrival(fix(age: -60), candidates()))
    }

    func testTimeWindowIsTwoHoursBeforeStartUntilEnd() {
        XCTAssertNotNil(arrival(fix(), candidates(items: [item(start: 7_200, end: 9_000)])), "시작 2시간 전부터")
        XCTAssertNil(arrival(fix(), candidates(items: [item(start: 7_201, end: 9_000)])))
        XCTAssertNotNil(arrival(fix(), candidates(items: [item(start: -3_600, end: 0)])), "끝나는 때까지")
        XCTAssertNil(arrival(fix(), candidates(items: [item(start: -3_600, end: -1)])))
    }

    func testWindowFallsBackToLinkedPlanThenStopDay() {
        let plan = PlanRecord(title: "계획", span: TimeSpan(start: now.addingTimeInterval(3_600), end: now.addingTimeInterval(7_200)), categoryID: "etc")
        let linked = candidates([stop(itemID: nil, planID: plan.id)], items: [], plans: [plan])
        XCTAssertEqual(linked.first?.opensAt, now.addingTimeInterval(3_600 - ArrivalDetector.leadTime))
        XCTAssertEqual(linked.first?.closesAt, now.addingTimeInterval(7_200))

        let dayOnly = candidates([stop(itemID: nil)], items: [])
        XCTAssertEqual(dayOnly.first?.opensAt, calendar.startOfDay(for: now), "날짜만 있으면 그날 하루")
        XCTAssertEqual(dayOnly.first?.closesAt, calendar.startOfDay(for: now).addingTimeInterval(86_400))
        XCTAssertNotNil(arrival(fix(), dayOnly))
    }

    func testShownStopIsSkippedAndNearestWins() {
        let other = UUID()
        let both = candidates([stop(), stop(other, latitude: 0.5005, itemID: "b")], items: [item(), item("b")])
        XCTAssertEqual(arrival(fix(), both)?.stopID, stopID, "가까운 일정 먼저")
        XCTAssertEqual(arrival(fix(), both, shown: [stopID])?.stopID, other, "보인 일정은 다시 보이지 않는다")
        XCTAssertNil(arrival(fix(), both, shown: [stopID, other]))
    }

    func testInvalidStopCoordinateIsNotACandidate() {
        XCTAssertTrue(candidates([stop(latitude: 91)]).isEmpty)
    }

    func testShownRecordsArePrunedAfterRetention() {
        let kept = ArrivalDetector.pruned(
            ["new": now.addingTimeInterval(-86_400), "old": now.addingTimeInterval(-ArrivalDetector.shownRetention)],
            now: now
        )
        XCTAssertEqual(Array(kept.keys), ["new"])
    }

    func testCardCarriesNoteChecklistAndSpend() throws {
        let items = [
            item(note: "  예약 번호 A-1  ", spend: 10_000),
            item("d2", start: 1_800, note: "", spend: 5_000, parent: "a"),
            item("d1", start: 600, note: "줄 서기", parent: "a"),
            item("x", spend: 99_000)
        ]
        let candidate = try XCTUnwrap(candidates(items: items).first)
        let card = ArrivalCard.make(candidate: candidate, items: items, tripBudgetKRW: 300_000)
        XCTAssertEqual(card.title, "곳 a")
        XCTAssertEqual(card.note, "예약 번호 A-1")
        XCTAssertEqual(card.checklist.map(\.id), ["t1|d1", "t1|d2"], "세부 계획은 시각 순")
        XCTAssertEqual(card.checklist.map(\.note), ["줄 서기", nil])
        XCTAssertEqual(card.plannedSpendKRW, 15_000, "이곳과 세부 계획만 더한다")
        XCTAssertEqual(card.tripBudgetKRW, 300_000)
    }

    func testCardHidesLinesTheModelDoesNotHave() throws {
        let candidate = try XCTUnwrap(candidates([stop(itemID: nil)], items: []).first)
        let card = ArrivalCard.make(candidate: candidate, items: [], tripBudgetKRW: 0)
        XCTAssertEqual(card.title, "핀")
        XCTAssertNil(card.start)
        XCTAssertNil(card.note)
        XCTAssertTrue(card.checklist.isEmpty)
        XCTAssertNil(card.plannedSpendKRW)
        XCTAssertNil(card.tripBudgetKRW)
    }

    @MainActor
    func testChecklistToggleIsKeptOnDevice() throws {
        let name = "ArrivalDetectorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let manager = ArrivalCardManager(defaults: defaults)
        XCTAssertTrue(manager.isEnabled, "기본은 켬")
        manager.toggle("t1|d1")
        XCTAssertEqual(ArrivalCardManager(defaults: defaults).checked, ["t1|d1"])
        manager.toggle("t1|d1")
        XCTAssertTrue(ArrivalCardManager(defaults: defaults).checked.isEmpty)
    }
}
