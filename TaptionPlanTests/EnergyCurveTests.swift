import SwiftUI
import XCTest
@testable import TaptionPlan
import TaptionPlanCore

/// 컨디션×일정 에너지 곡선 엔진(ENC1119A01). 정확한 값이 아니라 관계(범위·칸 수·단조성·인사이트 종류)를 본다.
final class EnergyCurveTests: XCTestCase {
    private func calendar(_ zone: String = "Asia/Seoul") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func day(_ zone: String = "Asia/Seoul", year: Int = 2026, month: Int = 11, _ dayOfMonth: Int = 18) -> TimeSpan {
        let calendar = calendar(zone)
        let start = calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth))!
        return TimeSpan(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
    }

    private func at(_ day: TimeSpan, _ hour: Double) -> Date { day.start.addingTimeInterval(hour * 3_600) }
    private func span(_ day: TimeSpan, _ from: Double, _ to: Double) -> TimeSpan { TimeSpan(start: at(day, from), end: at(day, to)) }

    private func sleep(_ day: TimeSpan, hours: Double = 7, wake: Double = 7, deep: Double = 1.2, efficiency: Double? = 0.92) -> EnergyCurveSleep {
        EnergyCurveSleep(asleep: hours * 3_600, deep: deep * 3_600, efficiency: efficiency, span: span(day, wake - hours - 0.3, wake))
    }

    private func input(_ day: TimeSpan, asOf: Double = 30, sleep: EnergyCurveSleep? = nil, segments: [EnergyCurveSegment] = [], blocks: [EnergyCurveBlock] = [], steps: [Int: Int]? = nil) -> EnergyCurveInput {
        EnergyCurveInput(day: day, asOf: at(day, asOf), sleep: sleep, segments: segments, blocks: blocks, stepsByBucket: steps)
    }

    private func value(_ result: EnergyCurveResult, hour: Double, in day: TimeSpan) -> Double? {
        result.buckets.first { $0.start == at(day, hour) }?.value
    }

    // 1. 보통 날
    func testOrdinaryDayHas96BucketsAllInRange() {
        let d = day()
        let result = EnergyCurveEngine.curve(input(d, sleep: sleep(d), segments: [EnergyCurveSegment(span: span(d, 9, 12), kind: .work)]))
        XCTAssertEqual(result.buckets.count, 96)
        XCTAssertEqual(result.buckets.first?.start, d.start)
        XCTAssertEqual(result.buckets.last?.start, at(d, 23.75))
        XCTAssertTrue(result.buckets.compactMap(\.value).allSatisfy { (0...1).contains($0) })
        XCTAssertTrue(result.hasSleepData); XCTAssertEqual(result.wakeMinute, 7 * 60)
        XCTAssertLessThanOrEqual(result.insights.count, 2)
    }

    // 2. 빈 데이터
    func testNoDataGivesEmptyResult() {
        let d = day()
        let result = EnergyCurveEngine.curve(input(d))
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(result.insights, [.noData])
        XCTAssertTrue(result.buckets.compactMap(\.value).isEmpty)
        XCTAssertFalse(result.hasSleepData)
    }

    // 3. 기상 뒤 단조 감소
    func testSleepOnlyDecreasesAfterWake() {
        let d = day()
        let result = EnergyCurveEngine.curve(input(d, sleep: sleep(d)))
        let values = result.buckets.compactMap(\.value)
        XCTAssertFalse(values.isEmpty)
        XCTAssertTrue((0.35...1.0).contains(values[0]), "시작값 범위")
        for (earlier, later) in zip(values, values.dropFirst()) { XCTAssertLessThanOrEqual(later, earlier + 1e-12) }
        XCTAssertNil(value(result, hour: 3, in: d), "기상 전 칸은 그리지 않는다")
        XCTAssertTrue(result.buckets.first { $0.start == at(d, 3) }?.isAsleep == true)
    }

    func testMissingSleepStartsFromDefaultAndSaysSo() {
        let d = day()
        let result = EnergyCurveEngine.curve(input(d, segments: [EnergyCurveSegment(span: span(d, 8, 9), kind: .rest)]))
        XCTAssertFalse(result.hasSleepData)
        XCTAssertTrue(result.insights.contains(.missingSleep))
        XCTAssertEqual(result.wakeMinute, 8 * 60, "수면이 없으면 첫 기록이 기상 기준점")
        XCTAssertEqual(EnergyCurveEngine.startValue(nil), 0.75)
        XCTAssertGreaterThan(EnergyCurveEngine.startValue(sleep(d, hours: 8)), EnergyCurveEngine.startValue(sleep(d, hours: 4)), "많이 잘수록 시작값이 높다")
    }

    // 4. 업무 vs 휴식
    func testWorkDrainsMoreThanRest() {
        let d = day()
        func evening(_ kind: EnergyCurveActivityKind) -> Double {
            let result = EnergyCurveEngine.curve(input(d, sleep: sleep(d), segments: [EnergyCurveSegment(span: span(d, 8, 12), kind: kind)]))
            return value(result, hour: 18, in: d) ?? -1
        }
        XCTAssertLessThan(evening(.work), evening(.rest))
    }

    // 5. 낮잠
    func testNapRaisesTheCurveAndNeverExceedsOne() {
        let d = day()
        let napped = EnergyCurveEngine.curve(input(d, sleep: sleep(d, hours: 9, deep: 2), segments: [EnergyCurveSegment(span: span(d, 13, 15), kind: .sleep)]))
        let plain = EnergyCurveEngine.curve(input(d, sleep: sleep(d, hours: 9, deep: 2)))
        XCTAssertGreaterThan(value(napped, hour: 16, in: d) ?? 0, value(plain, hour: 16, in: d) ?? 1)
        XCTAssertGreaterThan(value(napped, hour: 15, in: d) ?? 0, value(napped, hour: 13, in: d) ?? 1, "낮잠 뒤가 직전보다 높다")
        XCTAssertTrue(napped.buckets.compactMap(\.value).allSatisfy { $0 <= 1.0 })
        XCTAssertTrue(napped.buckets.first { $0.start == at(d, 14) }?.isAsleep == true)
    }

    // 6. 자정·DST
    func testMidnightCrossingCountsOnlyThisDaysShare() {
        let d = day()
        let overnight = EnergyCurveSegment(span: TimeSpan(start: at(d, -3), end: at(d, 2)), kind: .work)
        let tailOnly = EnergyCurveSegment(span: span(d, 0, 2), kind: .work)
        let a = EnergyCurveEngine.curve(input(d, sleep: sleep(d, wake: 1), segments: [overnight]))
        let b = EnergyCurveEngine.curve(input(d, sleep: sleep(d, wake: 1), segments: [tailOnly]))
        XCTAssertEqual(a, b, "자정을 넘긴 기록은 이 날 몫만 반영한다")
    }

    func testDaylightSavingDayBucketCountMatchesRealLength() {
        let fallBack = day("America/New_York", year: 2026, month: 11, 1)
        XCTAssertEqual(fallBack.duration, 25 * 3_600)
        XCTAssertEqual(EnergyCurveEngine.curve(input(fallBack, sleep: sleep(fallBack))).buckets.count, 100)
        let springForward = day("America/New_York", year: 2026, month: 3, 8)
        XCTAssertEqual(springForward.duration, 23 * 3_600)
        XCTAssertEqual(EnergyCurveEngine.curve(input(springForward, sleep: sleep(springForward))).buckets.count, 92)
    }

    // 7. 일정 인사이트
    func testScheduleStackNeedsTwoBlocksAroundTheLowestPoint() {
        let d = day()
        let hardDay = [EnergyCurveSegment(span: span(d, 8, 22), kind: .exercise)]
        func result(_ blocks: [EnergyCurveBlock]) -> EnergyCurveResult {
            EnergyCurveEngine.curve(input(d, sleep: sleep(d, hours: 4, deep: 0.2, efficiency: 0.7), segments: hardDay, blocks: blocks))
        }
        let two = result([EnergyCurveBlock(span: span(d, 9, 11), kind: .work), EnergyCurveBlock(span: span(d, 10, 12), kind: .work)])
        XCTAssertTrue(two.insights.contains { if case .scheduleStack = $0 { true } else { false } })
        let one = result([EnergyCurveBlock(span: span(d, 9, 11), kind: .work)])
        XCTAssertFalse(one.insights.contains { if case .scheduleStack = $0 { true } else { false } })
        XCTAssertTrue(one.insights.contains { if case .lowestPoint = $0 { true } else { false } })
    }

    func testShortSleepInsightUnderSixHours() {
        let d = day()
        XCTAssertTrue(EnergyCurveEngine.curve(input(d, sleep: sleep(d, hours: 5))).insights.contains(.shortSleep(minutes: 300)))
        XCTAssertFalse(EnergyCurveEngine.curve(input(d, sleep: sleep(d, hours: 7))).insights.contains { if case .shortSleep = $0 { true } else { false } })
    }

    // 8. 과한 입력
    func testExtremeInputsStayFiniteAndInRange() {
        let d = day()
        let extreme = EnergyCurveEngine.curve(input(
            d, sleep: EnergyCurveSleep(asleep: .infinity, deep: -5, efficiency: .nan, span: span(d, 0, 7)),
            segments: [EnergyCurveSegment(span: span(d, 6, 24), kind: .exercise), EnergyCurveSegment(span: span(d, 6, 24), kind: .exercise)],
            steps: Dictionary(uniqueKeysWithValues: (0..<96).map { ($0, 1_000_000) })
        ))
        XCTAssertTrue(extreme.buckets.compactMap(\.value).allSatisfy { $0.isFinite && (0...1).contains($0) })
        let zeroLength = EnergyCurveEngine.curve(EnergyCurveInput(day: TimeSpan(start: d.start, end: d.start), asOf: d.start, sleep: nil, segments: [], blocks: []))
        XCTAssertTrue(zeroLength.isEmpty)
    }

    // 오늘은 지금까지 실제 + 남은 일정 예측
    func testFutureBucketsAreProjectedFromBlocks() {
        let d = day()
        let result = EnergyCurveEngine.curve(input(d, asOf: 12, sleep: sleep(d), segments: [EnergyCurveSegment(span: span(d, 8, 12), kind: .rest)], blocks: [EnergyCurveBlock(span: span(d, 13, 18), kind: .work)]))
        XCTAssertTrue(result.buckets.filter { $0.start < at(d, 12) }.allSatisfy { !$0.isProjected })
        XCTAssertTrue(result.buckets.filter { $0.start >= at(d, 12) }.allSatisfy(\.isProjected))
        XCTAssertLessThan(value(result, hour: 18, in: d) ?? 1, value(result, hour: 13, in: d) ?? 0, "예측 구간의 업무가 곡선을 낮춘다")
    }

    func testStepsDrainSlightly() {
        let d = day()
        let plain = EnergyCurveEngine.curve(input(d, sleep: sleep(d)))
        let walked = EnergyCurveEngine.curve(input(d, sleep: sleep(d), steps: [30: 1_500]))
        XCTAssertLessThan(value(walked, hour: 9, in: d) ?? 1, value(plain, hour: 9, in: d) ?? 0)
    }

    func testCategoryMapping() {
        for (id, kind) in [("work", EnergyCurveActivityKind.work), ("study", .study), ("hobby", .hobby), ("exercise", .exercise), ("movement", .movement),
                           ("eating", .eating), ("housework", .housework), ("sleep", .sleep), ("unconfirmed", .unconfirmed), ("rest", .rest), ("activity", .rest), ("", .rest)] {
            XCTAssertEqual(EnergyCurveActivityKind.kind(forCategoryID: id), kind, id)
        }
    }

    // 9. 결정성
    func testSameInputGivesSameResult() {
        let d = day()
        let make = { self.input(d, sleep: self.sleep(d), segments: [EnergyCurveSegment(span: self.span(d, 9, 12), kind: .work)], blocks: [EnergyCurveBlock(span: self.span(d, 14, 16), kind: .study)]) }
        XCTAssertEqual(EnergyCurveEngine.curve(make()), EnergyCurveEngine.curve(make()))
    }

    /// 곡선·수면 띠·일정 띠 그림이 실제로 픽셀을 그린다(렌더링 연기 시험).
    @MainActor
    func testChartRendersSomething() throws {
        let d = day()
        let result = EnergyCurveEngine.curve(input(d, asOf: 15, sleep: sleep(d), segments: [EnergyCurveSegment(span: span(d, 9, 12), kind: .work)],
                                                   blocks: [EnergyCurveBlock(span: span(d, 13, 17), kind: .work), EnergyCurveBlock(span: span(d, 14, 15), kind: .study)]))
        let renderer = ImageRenderer(content: MapHomeEnergyCurveChart(result: result, language: .korean).frame(width: 320).background(Color.white))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.uiImage)
        XCTAssertGreaterThan(image.size.height, 120)
        let data = try XCTUnwrap(image.cgImage?.dataProvider?.data as Data?)
        let colored = stride(from: 0, to: data.count - 3, by: 4).filter { data[$0] != 255 || data[$0 + 1] != 255 || data[$0 + 2] != 255 }.count
        XCTAssertGreaterThan(colored, 500, "곡선·띠가 그려져야 한다")
    }
}
