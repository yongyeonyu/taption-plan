import Testing
@testable import TaptionPlanStore

/// 계획과 실제의 비교(TVC1112A01).
struct TravelPlanComparisonTests {
    typealias Span = TravelPlanComparison.Span

    let plan = [
        Span(id: "metro", start: 600, end: 630, isMove: true),      // 10:00 지하철
        Span(id: "lunch", start: 720, end: 780, isMove: false),     // 12:00 점심
        Span(id: "castle", start: 840, end: 960, isMove: false),    // 14:00 오사카성
        Span(id: "dinner", start: 1_080, end: 1_140, isMove: false), // 18:00 저녁
    ]

    @Test func matchedLateSkippedAndFutureItems() {
        let actual = [
            Span(id: "a-move", start: 605, end: 628, isMove: true),
            Span(id: "a-lunch", start: 745, end: 800, isMove: false),   // 25분 늦게 시작
            Span(id: "a-shop", start: 870, end: 900, isMove: true),     // 그 시간에 이동만 했다
        ]
        let result = TravelPlanComparison.compare(plan: plan, actual: actual, nowMinute: 1_000)
        #expect(result.statuses["metro"] == .done)
        #expect(result.statuses["lunch"] == .late)
        #expect(result.statuses["castle"] == .skipped, "종류가 다른 기록은 맞는 것으로 치지 않는다")
        #expect(result.statuses["dinner"] == .pending)
        #expect(result.unplanned.isEmpty)
    }

    @Test func itemInProgressIsNotSkippedUntilItsSlackPasses() {
        #expect(TravelPlanComparison.compare(plan: plan, actual: [], nowMinute: 850).statuses["castle"] == .underway)
        #expect(TravelPlanComparison.compare(plan: plan, actual: [], nowMinute: 989).statuses["castle"] == .underway)
        #expect(TravelPlanComparison.compare(plan: plan, actual: [], nowMinute: 990).statuses["castle"] == .skipped)
        #expect(TravelPlanComparison.compare(plan: plan, actual: [], nowMinute: 0).statuses.values.allSatisfy { $0 == .pending }, "오지 않은 날은 모두 대기")
        #expect(TravelPlanComparison.compare(plan: plan, actual: [], nowMinute: 1_440).statuses.values.allSatisfy { $0 == .skipped }, "지난 날 기록이 없으면 모두 건너뜀")
    }

    @Test func unplannedStaysNeedTwentyMinutesAwayFromAnyPlan() {
        let actual = [
            Span(id: "cafe", start: 1_000, end: 1_030, isMove: false),   // 계획 사이 30분
            Span(id: "short", start: 400, end: 410, isMove: false),      // 너무 짧다
            Span(id: "near", start: 790, end: 815, isMove: false),       // 점심 뒤 30분 안
            Span(id: "walk", start: 300, end: 360, isMove: true),        // 이동은 방문이 아니다
        ]
        #expect(TravelPlanComparison.compare(plan: plan, actual: actual, nowMinute: 1_440).unplanned == ["cafe"])
    }

    @Test func shortItemsNeedOnlyHalfTheirLength() {
        let short = [Span(id: "photo", start: 600, end: 606, isMove: false)]
        let result = TravelPlanComparison.compare(plan: short, actual: [Span(id: "x", start: 603, end: 607, isMove: false)], nowMinute: 1_440)
        #expect(result.statuses["photo"] == .done)
    }
}
