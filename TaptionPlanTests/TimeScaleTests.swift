import XCTest
@testable import TaptionPlan

final class TimeScaleTests: XCTestCase {
    func testEveryScaleHasAxisLabels() {
        for scale in TimeScale.allCases {
            XCTAssertFalse(scale.axisLabels.isEmpty)
        }
    }

    func testCircularActivityLabelsUseTheirClockQuadrant() {
        XCTAssertEqual(
            CircularActivityLabelQuadrant(clockFraction: 0),
            .topRight
        )
        XCTAssertEqual(
            CircularActivityLabelQuadrant(clockFraction: 0.249_999),
            .topRight
        )
        XCTAssertEqual(
            CircularActivityLabelQuadrant(clockFraction: 0.25),
            .bottomRight
        )
        XCTAssertEqual(
            CircularActivityLabelQuadrant(clockFraction: 0.5),
            .bottomLeft
        )
        XCTAssertEqual(
            CircularActivityLabelQuadrant(clockFraction: 0.75),
            .topLeft
        )
        XCTAssertEqual(
            CircularActivityLabelQuadrant(clockFraction: 0.999_999),
            .topLeft
        )
        XCTAssertEqual(
            CircularActivityLabelQuadrant(clockFraction: 1),
            .topRight
        )
    }

    func testCircularActivityLabelPagingMovesInOrderAndStopsAtEnds() {
        XCTAssertEqual(
            CircularActivityLabelPaging.index(
                movingBy: -1,
                from: 0,
                count: 3
            ),
            0
        )
        XCTAssertEqual(
            CircularActivityLabelPaging.index(
                movingBy: 1,
                from: 0,
                count: 3
            ),
            1
        )
        XCTAssertEqual(
            CircularActivityLabelPaging.index(
                movingBy: 1,
                from: 1,
                count: 3
            ),
            2
        )
        XCTAssertEqual(
            CircularActivityLabelPaging.index(
                movingBy: 1,
                from: 2,
                count: 3
            ),
            2
        )
    }

    func testQuickActivitySelectionOpensForUnclassifiedActivityOnly() {
        let stay = ActualRecord(
            planID: nil,
            title: "머무름",
            categoryID: "activity",
            startedAt: .now,
            endedAt: .now.addingTimeInterval(60),
            source: .location,
            behavior: StationaryContextKind.unknownStay.rawValue
        )
        let walking = ActualRecord(
            planID: nil,
            title: "걷기",
            categoryID: "activity",
            startedAt: .now,
            endedAt: .now.addingTimeInterval(60),
            source: .motion,
            behavior: WatchBehaviorKind.walking.rawValue
        )
        let namedActivity = ActualRecord(
            planID: nil,
            title: "출근준비",
            categoryID: "activity",
            startedAt: .now,
            endedAt: .now.addingTimeInterval(60),
            source: .manual
        )

        XCTAssertTrue(ActivityQuickSelectionPolicy.needsSelection(stay))
        XCTAssertFalse(ActivityQuickSelectionPolicy.needsSelection(walking))
        XCTAssertFalse(
            ActivityQuickSelectionPolicy.needsSelection(namedActivity)
        )
    }

    func testQuickActivitySelectionExcludesPlaceholderOptions() {
        let placeholder = ActivityCorrectionOption(
            id: "placeholder",
            title: "활동",
            behavior: WatchBehaviorKind.unknown.rawValue,
            categoryID: "activity",
            systemImage: "sparkles",
            isAutomatic: true,
            isCustom: false
        )
        let detailed = ActivityCorrectionOption.custom("독서")

        XCTAssertFalse(
            ActivityQuickSelectionPolicy.isDetailedOption(placeholder)
        )
        XCTAssertTrue(
            ActivityQuickSelectionPolicy.isDetailedOption(detailed)
        )
    }

    func testCircularClockTapChoosesNearestVisibleBand() {
        let outer = 138.0
        let phaseWidth = 12.0
        let gap = 3.5
        let activityWidth = 20.0
        let phaseCenter = outer - phaseWidth / 2
        let activityCenter = outer - phaseWidth - gap - activityWidth / 2

        XCTAssertEqual(
            CircularClockTapBand.resolve(
                distance: phaseCenter,
                outerRadius: outer,
                phaseBandWidth: phaseWidth,
                bandGap: gap,
                activityBandWidth: activityWidth
            ),
            .phase
        )
        XCTAssertEqual(
            CircularClockTapBand.resolve(
                distance: activityCenter,
                outerRadius: outer,
                phaseBandWidth: phaseWidth,
                bandGap: gap,
                activityBandWidth: activityWidth
            ),
            .activity
        )
        XCTAssertNil(
            CircularClockTapBand.resolve(
                distance: 20,
                outerRadius: outer,
                phaseBandWidth: phaseWidth,
                bandGap: gap,
                activityBandWidth: activityWidth
            )
        )
    }

    func testContinuousDayZoomPresetsCoverOneMinuteToOneWeek() {
        XCTAssertEqual(TimelineZoomPreset.oneMinute.duration, 60)
        XCTAssertEqual(TimelineZoomPreset.oneWeek.duration, 7 * 24 * 60 * 60)
        XCTAssertEqual(
            TimelineZoomPreset.nearest(to: 60),
            .oneMinute
        )
        XCTAssertEqual(
            TimelineZoomPreset.nearest(to: 24 * 60 * 60),
            .oneDay
        )
    }

    func testTimelineInteractionFrameGateReduces240HzInputToDisplayCadence() {
        var lastUptime: TimeInterval = 0
        var renderedSamples = 0

        for sample in 0...240 {
            let uptime = Double(sample) / 240
            if TimelineInteractionFrameGate.shouldRender(
                lastUptime: &lastUptime,
                nowUptime: uptime
            ) {
                renderedSamples += 1
            }
        }

        XCTAssertGreaterThan(renderedSamples, 50)
        XCTAssertLessThanOrEqual(renderedSamples, 62)
    }

    func testTimelineInteractionFrameGateAlwaysAcceptsFinalSample() {
        var lastUptime = 10.0

        XCTAssertFalse(
            TimelineInteractionFrameGate.shouldRender(
                lastUptime: &lastUptime,
                nowUptime: 10.001
            )
        )
        XCTAssertTrue(
            TimelineInteractionFrameGate.shouldRender(
                lastUptime: &lastUptime,
                nowUptime: 10.001,
                force: true
            )
        )
        XCTAssertEqual(lastUptime, 10.001)
    }

    func testPinchZoomRulerLabelsActualNonPresetSpans() {
        XCTAssertEqual(
            TimelineZoomPreset.displayLabel(for: 90 * 60),
            "1시간 30분"
        )
        XCTAssertEqual(
            TimelineZoomPreset.displayLabel(for: 10 * 24 * 60 * 60),
            "10일"
        )
        XCTAssertEqual(
            TimelineZoomPreset.displayLabel(for: 2 * 366 * 24 * 60 * 60),
            "2년"
        )
    }

    func testDefaultPlanDurationIsNeverNegative() {
        let start = Date(timeIntervalSince1970: 100)
        let plan = PlanItem(
            title: "테스트",
            startAt: start,
            endAt: start.addingTimeInterval(-60),
            category: .project
        )

        XCTAssertEqual(plan.duration, 0)
    }

    func testAxisGridUsesRequestedSlotCounts() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let leapFebruary = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2028, month: 2, day: 15))
        )
        let regularFebruary = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2027, month: 2, day: 15))
        )

        XCTAssertEqual(
            TimelineAxisGrid.buckets(
                for: .day,
                containing: leapFebruary,
                calendar: calendar
            ).count,
            2
        )
        XCTAssertEqual(
            TimelineAxisGrid.buckets(
                for: .week,
                containing: leapFebruary,
                calendar: calendar
            ).count,
            7
        )
        XCTAssertEqual(
            TimelineAxisGrid.buckets(
                for: .month,
                containing: leapFebruary,
                calendar: calendar
            ).count,
            29
        )
        XCTAssertEqual(
            TimelineAxisGrid.buckets(
                for: .month,
                containing: regularFebruary,
                calendar: calendar
            ).count,
            28
        )
        XCTAssertEqual(
            TimelineAxisGrid.buckets(
                for: .year,
                containing: leapFebruary,
                calendar: calendar
            ).count,
            12
        )
    }

    func testAxisGridStartsWeeksOnMondayAndDisplaysKoreanHolidays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2027, month: 2, day: 7))
        )
        let week = TimelineAxisGrid.buckets(
            for: .week,
            containing: date,
            calendar: calendar
        )
        let weekday = calendar.component(.weekday, from: week[0].date)
        XCTAssertEqual(weekday, 2) // Monday in Gregorian Calendar
        XCTAssertEqual(week[6].holidayName, "설날")
        XCTAssertEqual(
            TimelineAxisGrid.koreanHolidayName(
                on: date,
                calendar: calendar
            ),
            "설날"
        )
    }

    func testNonDayFractionsKeepCalendarBucketsEqual() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2029, month: 1, day: 1))
        )
        let span = TimelineAxisGrid.span(
            for: .year,
            containing: date,
            calendar: calendar
        )
        let february = try XCTUnwrap(
            calendar.date(byAdding: .month, value: 1, to: span.start)
        )
        let july = try XCTUnwrap(
            calendar.date(byAdding: .month, value: 6, to: span.start)
        )
        XCTAssertEqual(
            TimelineAxisGrid.fraction(
                of: february,
                in: span,
                scale: .year,
                calendar: calendar
            ),
            1.0 / 12.0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            TimelineAxisGrid.fraction(
                of: july,
                in: span,
                scale: .year,
                calendar: calendar
            ),
            0.5,
            accuracy: 0.000_001
        )
    }
}
