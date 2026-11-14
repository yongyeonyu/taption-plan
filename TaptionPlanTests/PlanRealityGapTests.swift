import XCTest
@testable import TaptionPlan
import CoreLocation
import TaptionPlanCore
import TaptionPlanStore

/// PVR1114A13: 계획과 실제의 차이 계산, AI에게 보낼 요약, 지도 경로.
@MainActor
final class PlanRealityGapTests: XCTestCase {
    private let dayStart = Date(timeIntervalSince1970: 1_799_971_200)
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    private func at(_ hour: Int, _ minute: Int = 0) -> Date { dayStart.addingTimeInterval(Double(hour * 3_600 + minute * 60)) }
    private func span(_ from: (Int, Int), _ to: (Int, Int)) -> TimeSpan { TimeSpan(start: at(from.0, from.1), end: at(to.0, to.1)) }
    private var day: TimeSpan { TimeSpan(start: dayStart, end: dayStart.addingTimeInterval(86_400)) }
    private func plan(_ title: String, _ from: (Int, Int), _ to: (Int, Int), id: UUID = UUID()) -> PlanRecord {
        PlanRecord(id: id, title: title, span: span(from, to), categoryID: "c")
    }
    private func actual(_ planID: UUID?, _ from: (Int, Int), _ to: (Int, Int)?) -> ActualRecord {
        ActualRecord(planID: planID, title: "a", categoryID: "c", startedAt: at(from.0, from.1), endedAt: to.map { at($0.0, $0.1) }, source: .manual)
    }
    private func item(_ id: String, _ from: (Int, Int), _ to: (Int, Int), planned: Double? = nil, planID: UUID? = nil, parent: String? = nil) -> TravelTripItem {
        TravelTripItem(tripID: "t1", itemID: id, kind: "sight", title: "곳 \(id)", start: at(from.0, from.1), end: at(to.0, to.1),
                       startOffsetSeconds: 0, endOffsetSeconds: 0, planID: planID, plannedSpendKRW: planned, parentItemID: parent)
    }
    private func expense(_ amount: Double, _ time: (Int, Int)) -> LedgerEntry {
        LedgerEntry(occurredAt: at(time.0, time.1), amount: amount, amountKRW: amount, title: "지출", tripID: "t1")
    }

    func testLinkedRecordGivesStartEndAndDurationDeltas() {
        let museum = plan("박물관", (10, 0), (11, 0))
        let result = PlanRealityGap.day(.init(plans: [museum], actuals: [actual(museum.id, (10, 25), (11, 40))], day: day, now: at(20)))
        let row = result.items[0]
        XCTAssertEqual(row.match, .linked)
        XCTAssertEqual(row.startDelta, 25 * 60)
        XCTAssertEqual(row.endDelta, 40 * 60)
        XCTAssertEqual(row.durationDelta, 15 * 60)
        XCTAssertEqual(row.timeBadge(), 25 * 60, "시작이 어긋났으면 시작 차이를 보인다")
        XCTAssertEqual(PlanRealityText.time(25 * 60, .korean), "+25분")
        XCTAssertEqual(PlanRealityText.time(-65 * 60, .english), "-1 h 5 min")
    }

    func testSmallDifferencesGetNoBadgeAndUnlinkedPlanHasNoActual() {
        let a = plan("회의", (9, 0), (10, 0)), b = plan("산책", (12, 0), (13, 0))
        let result = PlanRealityGap.day(.init(plans: [b, a], actuals: [actual(a.id, (9, 3), (10, 2)), actual(nil, (12, 0), (13, 0))], day: day, now: at(20)))
        XCTAssertEqual(result.items.map(\.title), ["회의", "산책"], "계획 시각 순")
        XCTAssertNil(result.items[0].timeBadge(), "5분 안쪽은 뱃지가 없다")
        XCTAssertNil(result.items[1].actual, "이어지지 않은 기록은 짝짓지 않는다")
        XCTAssertFalse(result.isDelayed)
    }

    func testRoutinesSkippedAndContainerPlansAreLeftOut() {
        let parent = plan("오전", (9, 0), (12, 0))
        var child = plan("운동", (9, 0), (10, 0))
        child.parentID = parent.id
        var skipped = plan("건너뜀", (13, 0), (14, 0))
        skipped.status = .skipped
        let routine = plan("루틴: 독서", (15, 0), (16, 0))
        let other = PlanRecord(title: "다른 날", span: TimeSpan(start: at(30), end: at(31)), categoryID: "c")
        let result = PlanRealityGap.day(.init(plans: [parent, child, skipped, routine, other], day: day, now: at(8)))
        XCTAssertEqual(result.items.map(\.title), ["운동"])
    }

    func testDelayComesFromTheLatestRecordedItemOnlyToday() {
        let a = plan("가", (9, 0), (10, 0)), b = plan("나", (10, 0), (11, 0)), c = plan("다", (13, 0), (14, 0))
        let actuals = [actual(a.id, (9, 0), (10, 0)), actual(b.id, (10, 20), (11, 30))]
        let today = PlanRealityGap.day(.init(plans: [a, b, c], actuals: actuals, day: day, now: at(11, 35)))
        XCTAssertEqual(today.delay, 30 * 60)
        XCTAssertTrue(today.isDelayed)
        XCTAssertEqual(today.remaining, 1)
        XCTAssertTrue(today.needsReplan)
        let later = PlanRealityGap.day(.init(plans: [a, b, c], actuals: actuals, day: day, now: at(30)))
        XCTAssertEqual(later.delay, 0, "지난 날은 지연을 따지지 않는다")
        XCTAssertFalse(later.needsReplan)
        XCTAssertEqual(later.items[1].timeBadge(), 20 * 60, "지난 날에도 뱃지는 남는다")
        let small = PlanRealityGap.day(.init(plans: [a, b, c], actuals: [actual(b.id, (10, 0), (11, 10))], day: day, now: at(11, 35)))
        XCTAssertFalse(small.isDelayed, "15분보다 덜 밀렸으면 지연이 아니다")
    }

    func testOngoingRecordPastThePlannedEndCountsTheOverrun() {
        let a = plan("가", (9, 0), (10, 0)), b = plan("나", (10, 0), (11, 0))
        let result = PlanRealityGap.day(.init(plans: [a, b], actuals: [actual(a.id, (9, 5), nil)], day: day, now: at(10, 40)))
        XCTAssertTrue(result.items[0].isOngoing)
        XCTAssertNil(result.items[0].endDelta, "끝나지 않은 기록은 끝 차이가 없다")
        XCTAssertEqual(result.delay, 40 * 60)
        XCTAssertEqual(result.remaining, 1, "계획 끝을 넘긴 진행 중 일정은 남은 일정으로 세지 않는다")
    }

    func testTripItemMatchesAStayNearItsStopAndSumsSpending() {
        let stop = TravelPlanStop(id: UUID(), title: "곳 a", latitude: 10, longitude: 20, day: dayStart, order: 0, planID: nil, tripID: "t1", itemID: "a")
        let near = PlaceStay(placeKey: "k1", displayName: "머문 곳", span: span((10, 30), (11, 50)), confidence: .high,
                             point: GeoPoint(latitude: 10.0005, longitude: 20, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10))
        let far = PlaceStay(placeKey: "k2", displayName: "다른 곳", span: span((10, 0), (10, 20)), confidence: .high,
                            point: GeoPoint(latitude: 10.1, longitude: 20, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10))
        let items = [item("a", (10, 0), (11, 0), planned: 20_000), item("a1", (10, 30), (10, 50), planned: 5_000, parent: "a"), item("b", (15, 0), (16, 0), planned: 30_000)]
        let entries = [expense(18_000, (10, 10)), expense(12_000, (10, 40)), expense(9_000, (12, 0))]
        let result = PlanRealityGap.day(.init(places: [far, near], stops: [stop], tripItems: items, entries: entries, day: day, now: at(12, 30)))
        XCTAssertEqual(result.items.map(\.id), ["item:t1/a", "item:t1/b"], "세부 일정은 굵은 곳에 묶는다")
        let a = result.items[0]
        XCTAssertEqual(a.match, .place)
        XCTAssertEqual(a.startDelta, 30 * 60)
        XCTAssertEqual(a.plannedKRW, 25_000)
        XCTAssertEqual(a.spentKRW, 30_000, "일정 시간 밖의 지출은 세지 않는다")
        XCTAssertEqual(a.costBadge(), 5_000)
        XCTAssertEqual(PlanRealityText.money(-5_000, .korean), "-5,000원")
        XCTAssertNil(result.items[1].spentKRW, "아직 오지 않은 일정은 비용 차이를 내지 않는다")
        XCTAssertEqual(result.plannedKRW, 55_000)
        XCTAssertEqual(result.plannedSoFarKRW, 25_000)
        XCTAssertEqual(result.overKRW, 5_000)
        XCTAssertTrue(result.isOverBudget)
        XCTAssertTrue(result.needsReplan)
        XCTAssertGreaterThan(PlanRealityGap.meters(10, 20, 10.1, 20), 10_000)
    }

    func testSmallOverspendIsNotOverBudget() {
        let items = [item("a", (10, 0), (11, 0), planned: 20_000), item("b", (15, 0), (16, 0))]
        let result = PlanRealityGap.day(.init(tripItems: items, entries: [expense(23_000, (10, 10))], day: day, now: at(12)))
        XCTAssertEqual(result.overKRW, 3_000)
        XCTAssertFalse(result.isOverBudget)
        XCTAssertEqual(result.items[0].costBadge(), 3_000)
    }

    func testPlanLinkedToATripItemIsOneRowWithItsBudget() {
        let id = UUID()
        let result = PlanRealityGap.day(.init(plans: [plan("저녁", (18, 0), (19, 0), id: id)], tripItems: [item("d", (18, 0), (19, 0), planned: 40_000, planID: id)],
                                              entries: [expense(52_000, (18, 30))], day: day, now: at(20)))
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].id, "plan:\(id.uuidString)")
        XCTAssertEqual(result.items[0].costDelta, 12_000)
    }

    func testSummaryFollowsTheShareLevelAndCarriesNoCoordinates() throws {
        let a = plan("비밀 약속", (10, 0), (11, 0)), b = plan("다음 일정", (13, 0), (14, 0))
        let gap = PlanRealityGap.day(.init(plans: [a, b], actuals: [actual(a.id, (10, 25), (11, 40))], day: day, now: at(11, 45)))
        XCTAssertNil(PlanRealityText.summary(gap, level: .off, language: .korean, now: at(11, 45), calendar: utc))
        let brief = try XCTUnwrap(PlanRealityText.summary(gap, level: .summary, language: .korean, now: at(11, 45), calendar: utc))
        XCTAssertFalse(brief.contains("비밀 약속"), brief)
        XCTAssertTrue(brief.contains("10:00–11:00 #1 → 10:25–11:40 (+25분)"), brief)
        XCTAssertTrue(brief.hasPrefix("지연 +40분 · 남은 일정 1개"), brief)
        let full = try XCTUnwrap(PlanRealityText.summary(gap, level: .visits, language: .korean, now: at(11, 45), calendar: utc))
        XCTAssertTrue(full.contains("10:00–11:00 비밀 약속"), full)
        XCTAssertTrue(full.contains("13:00–14:00 다음 일정 · 남음"), full)
        let context = PlanRealityText.context(gap, level: .summary, now: at(11, 45), calendar: utc)
        XCTAssertEqual(context, ["remaining": "1", "from": "11:45", "level": "summary", "delayMinutes": "40"])
        XCTAssertNotEqual(PlanRealityText.signature(gap, dayStart: dayStart), PlanRealityText.signature(PlanRealityGap.Day(), dayStart: dayStart))
        let calm = PlanRealityGap.day(.init(plans: [a, b], actuals: [actual(a.id, (10, 0), (11, 0))], day: day, now: at(11, 45)))
        XCTAssertNil(PlanRealityText.summary(calm, level: .visits, language: .korean, now: at(11, 45), calendar: utc), "차이가 없으면 보내지 않는다")
    }

    func testReplanTaskIsQueuedWithItsKindAndOldAppsReadNewKindsAsOther() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PlanRealityGapTests-\(UUID())"))
        defaults.set(["key": "피클"], forKey: AssistantKeyLabels.labelsKey)
        XCTAssertTrue(AITaskQueue.enqueue(.replan, text: "지연 +40분 · 남은 일정 1개", context: ["delayMinutes": "40"], defaults: defaults))
        let upload = try XCTUnwrap(AITaskQueue.pendingUploads(defaults).first)
        XCTAssertEqual(upload.kind.rawValue, "replan")
        XCTAssertEqual(upload.context, ["delayMinutes": "40"])
        let list = AITaskQueue.decodeList(Data(#"{"tasks":[{"id":"a","kind":"replan","status":"waiting"},{"id":"b","kind":"later_kind","status":"waiting"}]}"#.utf8))
        XCTAssertEqual(list.map(\.kind), [.replan, .other])
    }

    func testActualRouteDropsCoarseAndOutOfDayPoints() {
        func reading(_ offset: TimeInterval, _ latitude: Double, accuracy: Double = 10, quality: LocationFixQuality? = .precise) -> SensorReading {
            var value = SensorReading(timestamp: dayStart.addingTimeInterval(offset))
            value.point = GeoPoint(latitude: latitude, longitude: 20, altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 10)
            value.locationFixQuality = quality
            return value
        }
        let route = PlanRealityRoute.actual([
            reading(7_200, 10.02), reading(3_600, 10.01), reading(5_000, 10.5, accuracy: 900), reading(6_000, 10.6, quality: .approximate), reading(-60, 9),
        ], in: day)
        XCTAssertEqual(route.map(\.latitude), [10.01, 10.02], "시각 순, 부정확한 점과 다른 날의 점은 뺀다")
        let stop = TravelPlanStop(id: UUID(), title: "곳", latitude: 10, longitude: 20, day: dayStart, order: 0, planID: nil)
        XCTAssertTrue(PlanRealityRoute.planned([stop]).isEmpty, "한 곳뿐이면 계획 경로가 없다")
    }
}
