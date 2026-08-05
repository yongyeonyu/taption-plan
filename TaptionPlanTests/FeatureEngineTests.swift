import XCTest
import UIKit
@testable import TaptionPlan

final class FeatureEngineTests: XCTestCase {
    private let hour: TimeInterval = 3_600

    func testPlayheadMapUsesOnlyMovementContainingExactPlayheadTime() {
        let playhead = makeDate(2026, 8, 1, 9, 0)
        let nearby = TravelSegment(
            mode: .car,
            span: TimeSpan(
                start: playhead.addingTimeInterval(-30 * 60),
                end: playhead.addingTimeInterval(-10 * 60)
            ),
            distanceMeters: 4_000,
            confidence: .high,
            evidence: ["GPS"]
        )
        let containing = TravelSegment(
            mode: .walking,
            span: TimeSpan(
                start: playhead.addingTimeInterval(-5 * 60),
                end: playhead.addingTimeInterval(5 * 60)
            ),
            distanceMeters: 600,
            confidence: .high,
            evidence: ["걸음 수"]
        )
        let focusSpan = TimeSpan(
            start: playhead.addingTimeInterval(-15 * 60),
            end: playhead.addingTimeInterval(15 * 60)
        )

        let exact = TimelineRouteDisplayPolicy.segments(
            from: [nearby, containing],
            intersecting: focusSpan,
            at: playhead
        )
        XCTAssertEqual(exact.map(\.id), [containing.id])
        XCTAssertTrue(
            TimelineRouteDisplayPolicy.allowsFallbackPath(
                at: playhead,
                routeSegments: exact
            )
        )

        let noMovement = TimelineRouteDisplayPolicy.segments(
            from: [nearby],
            intersecting: focusSpan,
            at: playhead
        )
        XCTAssertTrue(noMovement.isEmpty)
        XCTAssertFalse(
            TimelineRouteDisplayPolicy.allowsFallbackPath(
                at: playhead,
                routeSegments: noMovement
            )
        )

        let rangeSelection = TimelineRouteDisplayPolicy.segments(
            from: [nearby, containing],
            intersecting: focusSpan,
            at: nil
        )
        XCTAssertEqual(Set(rangeSelection.map(\.id)), Set([nearby.id, containing.id]))

        let tappedSegment = TimelineRouteDisplayPolicy.segments(
            from: [nearby, containing],
            intersecting: focusSpan,
            at: nil,
            selectedTravelID: nearby.id
        )
        XCTAssertEqual(tappedSegment.map(\.id), [nearby.id])
    }

    func testMovementDisplayHidesRawRecordWhenTravelCoversIt() {
        let start = makeDate(2026, 8, 1, 9)
        let end = start.addingTimeInterval(20 * 60)
        let raw = ActualRecord(
            planID: nil,
            title: "걷기",
            categoryID: "movement",
            startedAt: start,
            endedAt: end,
            source: .motion
        )
        let travel = TravelSegment(
            mode: .walking,
            span: TimeSpan(start: start, end: end),
            distanceMeters: 1_200,
            confidence: .high,
            evidence: ["GPS"]
        )

        XCTAssertTrue(
            MovementDisplayEngine.visibleActuals(
                [raw],
                travel: [travel],
                asOf: end
            ).isEmpty
        )
        XCTAssertEqual(
            MovementDisplayEngine.visibleActuals(
                [raw],
                travel: [],
                asOf: end
            ).map(\.id),
            [raw.id]
        )
    }

    // MARK: - 수면과 겹친 휴식

    private func restSpans(
        _ actuals: [ActualRecord],
        asOf: Date
    ) -> [TimeSpan] {
        RestSleepDisplayEngine.visibleActuals(actuals, asOf: asOf)
            .filter(RestSleepDisplayEngine.isRest)
            .map { $0.span(asOf: asOf) }
            .sorted { $0.start < $1.start }
    }

    /// 사용자 화면의 실제 값: 휴식 00:57 + 8시간 13분, 수면 02:43 + 4시간 50분.
    /// 수면이 휴식 한가운데 들어 있으므로 휴식은 앞뒤 두 조각만 남는다.
    func testSleepInsideRestLeavesTwoRestRemainders() {
        let day = makeDate(2026, 8, 5)
        let rest = makeActual(
            "집에서 휴식",
            "rest",
            start: makeDate(2026, 8, 5, 0, 57),
            minutes: 8 * 60 + 13,
            source: .location
        )
        let sleep = makeActual(
            "수면",
            "sleep",
            start: makeDate(2026, 8, 5, 2, 43),
            minutes: 4 * 60 + 50,
            source: .healthKit
        )
        let asOf = day.addingTimeInterval(24 * hour)

        let trimmed = RestSleepDisplayEngine.visibleActuals(
            [rest, sleep],
            asOf: asOf
        )
        let rests = trimmed.filter(RestSleepDisplayEngine.isRest)

        XCTAssertEqual(rests.count, 2)
        XCTAssertEqual(rests.map(\.startedAt), [
            makeDate(2026, 8, 5, 0, 57),
            makeDate(2026, 8, 5, 7, 33),
        ])
        XCTAssertEqual(rests.map(\.endedAt), [
            makeDate(2026, 8, 5, 2, 43),
            makeDate(2026, 8, 5, 9, 10),
        ])
        // 첫 조각이 원본 식별자를 지켜야 기록 상세가 열린다.
        XCTAssertEqual(rests.first?.id, rest.id)
        XCTAssertEqual(Set(rests.map(\.id)).count, 2)
        // 수면 기록 자체는 손대지 않는다.
        XCTAssertEqual(
            trimmed.filter { $0.categoryID == "sleep" }.map(\.id),
            [sleep.id]
        )
        // 다시 잘라도 같은 값이라야 화면 갱신마다 선택이 풀리지 않는다.
        XCTAssertEqual(
            RestSleepDisplayEngine.visibleActuals([rest, sleep], asOf: asOf),
            trimmed
        )
    }

    func testRestFullyInsideSleepDisappears() {
        let sleep = makeActual(
            "수면",
            "sleep",
            start: makeDate(2026, 8, 5, 1),
            minutes: 6 * 60,
            source: .healthKit
        )
        let rest = makeActual(
            "집에서 휴식",
            "rest",
            start: makeDate(2026, 8, 5, 2),
            minutes: 90,
            source: .location
        )
        let asOf = makeDate(2026, 8, 5, 12)

        XCTAssertTrue(restSpans([rest, sleep], asOf: asOf).isEmpty)
        XCTAssertEqual(
            RestSleepDisplayEngine.visibleActuals([rest, sleep], asOf: asOf)
                .map(\.id),
            [sleep.id]
        )
    }

    func testPartialSleepOverlapTrimsEachEdge() {
        let asOf = makeDate(2026, 8, 5, 23)
        let sleep = makeActual(
            "수면",
            "sleep",
            start: makeDate(2026, 8, 5, 1),
            minutes: 6 * 60,
            source: .healthKit
        )
        // 휴식이 수면보다 늦게 시작하고 늦게 끝난다: 뒤쪽만 남는다.
        let tail = makeActual(
            "집에서 휴식",
            "rest",
            start: makeDate(2026, 8, 5, 5),
            minutes: 4 * 60,
            source: .location
        )
        XCTAssertEqual(
            restSpans([tail, sleep], asOf: asOf),
            [TimeSpan(
                start: makeDate(2026, 8, 5, 7),
                end: makeDate(2026, 8, 5, 9)
            )]
        )

        // 휴식이 수면보다 먼저 시작하고 먼저 끝난다: 앞쪽만 남는다.
        let head = makeActual(
            "집에서 휴식",
            "rest",
            start: makeDate(2026, 8, 5, 0),
            minutes: 3 * 60,
            source: .location
        )
        let headRemainders = restSpans([head, sleep], asOf: asOf)
        XCTAssertEqual(
            headRemainders,
            [TimeSpan(
                start: makeDate(2026, 8, 5, 0),
                end: makeDate(2026, 8, 5, 1)
            )]
        )
        // 조각이 하나뿐이면 원본 식별자를 그대로 쓴다.
        XCTAssertEqual(
            RestSleepDisplayEngine.visibleActuals([head, sleep], asOf: asOf)
                .first?.id,
            head.id
        )
    }

    func testRestNotOverlappingSleepIsUntouched() {
        let asOf = makeDate(2026, 8, 5, 23)
        let sleep = makeActual(
            "수면",
            "sleep",
            start: makeDate(2026, 8, 5, 1),
            minutes: 6 * 60,
            source: .healthKit
        )
        let rest = makeActual(
            "카페",
            "rest",
            start: makeDate(2026, 8, 5, 14),
            minutes: 70,
            source: .location
        )
        let input = [rest, sleep]

        XCTAssertEqual(
            RestSleepDisplayEngine.visibleActuals(input, asOf: asOf),
            input
        )
        // 수면 기록이 없으면 휴식은 언제나 그대로다.
        XCTAssertEqual(
            RestSleepDisplayEngine.visibleActuals([rest], asOf: asOf),
            [rest]
        )
    }

    /// 근무·수업·통화·회의가 수면과 겹치면 감출 일이 아니라 따로 봐야 할
    /// 잘못이다. 수면 우선 규칙은 휴식 분류에만 닿는다.
    func testSleepDoesNotSwallowWorkOrMeetingRecords() {
        let asOf = makeDate(2026, 8, 5, 23)
        let sleep = makeActual(
            "수면",
            "sleep",
            start: makeDate(2026, 8, 5, 1),
            minutes: 6 * 60,
            source: .healthKit
        )
        let others = [
            makeActual(
                "근무",
                "work",
                start: makeDate(2026, 8, 5, 2),
                minutes: 60,
                source: .location
            ),
            makeActual(
                "수업·학습",
                "study",
                start: makeDate(2026, 8, 5, 3),
                minutes: 60,
                source: .location
            ),
            makeActual(
                "통화",
                "relationship",
                start: makeDate(2026, 8, 5, 4),
                minutes: 20,
                source: .call
            ),
            makeActual(
                "머무름",
                "activity",
                start: makeDate(2026, 8, 5, 5),
                minutes: 30,
                source: .location
            ),
        ]

        XCTAssertEqual(
            RestSleepDisplayEngine.visibleActuals(others + [sleep], asOf: asOf),
            others + [sleep]
        )
    }

    /// 화면에 보이는 목록·눈금판·합계가 모두 같은 값을 읽는지 본다. 세 값이
    /// 흐른 시간(00:57–09:10)을 넘으면 안 된다.
    func testRecordTotalsForOverlappingRestAndSleepMatchElapsedTime() {
        let day = makeDate(2026, 8, 5)
        let span = TimeSpan(start: day, end: day.addingTimeInterval(24 * hour))
        let asOf = day.addingTimeInterval(24 * hour)
        let raw = [
            makeActual(
                "집에서 휴식",
                "rest",
                start: makeDate(2026, 8, 5, 0, 57),
                minutes: 8 * 60 + 13,
                source: .location
            ),
            makeActual(
                "수면",
                "sleep",
                start: makeDate(2026, 8, 5, 2, 43),
                minutes: 4 * 60 + 50,
                source: .healthKit
            ),
        ]
        let elapsed = makeDate(2026, 8, 5, 9, 10)
            .timeIntervalSince(makeDate(2026, 8, 5, 0, 57))
        let expectedRest: TimeInterval = (1 * 60 + 46) * 60
            + (1 * 60 + 37) * 60
        let expectedSleep: TimeInterval = (4 * 60 + 50) * 60

        // 다듬기 전에는 두 값의 합이 흐른 시간을 넘는다.
        XCTAssertGreaterThan(
            ActualRecordGroupingEngine.groups(
                actuals: raw,
                in: span,
                categories: CategoryCatalog.builtIn,
                asOf: asOf
            ).reduce(0) { $0 + $1.duration },
            elapsed
        )

        let actuals = RestSleepDisplayEngine.visibleActuals(raw, asOf: asOf)
        let groups = ActualRecordGroupingEngine.groups(
            actuals: actuals,
            in: span,
            categories: CategoryCatalog.builtIn,
            asOf: asOf
        )
        let byCategory = Dictionary(
            groups.map { ($0.id, $0.duration) },
            uniquingKeysWith: { first, _ in first }
        )

        XCTAssertEqual(byCategory["sleep"], expectedSleep)
        XCTAssertEqual(byCategory["rest"], expectedRest)
        XCTAssertEqual(groups.reduce(0) { $0 + $1.duration }, elapsed)

        // 잘린 두 조각은 제목이 같으므로 목록에서는 한 줄로 합쳐 보인다.
        let restGroup = groups.first { $0.id == "rest" }
        XCTAssertEqual(restGroup?.children.map(\.title), ["집에서 휴식"])
        XCTAssertEqual(restGroup?.children.first?.occurrenceCount, 2)
        XCTAssertEqual(
            restGroup?.children.first?.start,
            makeDate(2026, 8, 5, 0, 57)
        )

        // 눈금판(원형 시간표)도 같은 값을 읽는다.
        let rings = RecordChartEngine.clockRings(
            actuals: actuals,
            in: span,
            asOf: asOf
        )
        XCTAssertEqual(
            rings.first { $0.categoryID == "rest" }?.duration,
            expectedRest
        )
        XCTAssertEqual(
            rings.first { $0.categoryID == "rest" }?.arcs.count,
            2
        )
        XCTAssertEqual(
            rings.reduce(0) { $0 + $1.duration },
            groups.reduce(0) { $0 + $1.duration }
        )
    }

    func testIntervalSubtractionKeepsOnlyUncoveredParts() {
        let base = makeDate(2026, 8, 5)
        func span(_ from: Double, _ to: Double) -> TimeSpan {
            TimeSpan(
                start: base.addingTimeInterval(from * hour),
                end: base.addingTimeInterval(to * hour)
            )
        }

        XCTAssertEqual(
            ActualIntervalMergeEngine.subtracting(
                [span(2, 3), span(5, 6)],
                from: span(1, 8)
            ),
            [span(1, 2), span(3, 5), span(6, 8)]
        )
        XCTAssertEqual(
            ActualIntervalMergeEngine.subtracting(
                [span(0, 9)],
                from: span(1, 8)
            ),
            []
        )
        XCTAssertEqual(
            ActualIntervalMergeEngine.subtracting(
                [span(9, 10)],
                from: span(1, 8)
            ),
            [span(1, 8)]
        )
        // 맞닿기만 한 구간은 아무것도 덜어 내지 않는다.
        XCTAssertEqual(
            ActualIntervalMergeEngine.subtracting(
                [span(0, 1), span(8, 9)],
                from: span(1, 8)
            ),
            [span(1, 8)]
        )
    }

    func testHierarchySupportsUnlimitedDescendantsAndRollup() throws {
        let base = makeDate(2026, 1, 1)
        let year = PlanRecord(
            title: "출시",
            span: TimeSpan(start: base, end: base.addingTimeInterval(365 * 24 * hour)),
            categoryID: "project"
        )
        let month = PlanRecord(
            title: "기획",
            span: TimeSpan(start: base, end: base.addingTimeInterval(30 * 24 * hour)),
            categoryID: "project",
            parentID: year.id
        )
        let week = PlanRecord(
            title: "초안",
            span: TimeSpan(start: base, end: base.addingTimeInterval(7 * 24 * hour)),
            categoryID: "study",
            parentID: month.id
        )
        let day = PlanRecord(
            title: "작성",
            span: TimeSpan(start: base, end: base.addingTimeInterval(2 * hour)),
            categoryID: "study",
            parentID: week.id
        )
        let actual = ActualRecord(
            planID: day.id,
            title: day.title,
            categoryID: day.categoryID,
            startedAt: base,
            endedAt: base.addingTimeInterval(hour),
            source: .manual
        )
        let plans = [year, month, week, day]

        XCTAssertEqual(try PlanHierarchy.descendants(of: year.id, in: plans).count, 3)
        let rollup = try TimelineAggregationEngine(
            calendar: utcCalendar
        ).rollup(
            goalID: year.id,
            plans: plans,
            actuals: [actual],
            asOf: base.addingTimeInterval(hour)
        )
        XCTAssertEqual(rollup.descendantCount, 3)
        XCTAssertEqual(rollup.actualDuration, hour)
        XCTAssertEqual(rollup.plannedDuration, month.span.duration)
    }

    func testHierarchyRejectsCycle() throws {
        let base = makeDate(2026, 1, 1)
        var first = PlanRecord(
            title: "A",
            span: TimeSpan(start: base, end: base.addingTimeInterval(hour)),
            categoryID: "project"
        )
        let second = PlanRecord(
            title: "B",
            span: first.span,
            categoryID: "project",
            parentID: first.id
        )
        first.parentID = second.id
        XCTAssertThrowsError(try PlanHierarchy.validate([first, second])) {
            XCTAssertEqual($0 as? PlanningError, .parentCycle)
        }
    }

    func testSummaryHierarchyProvidesExpectedLowerLevels() {
        let date = makeDate(2026, 7, 15)
        let engine = TimelineAggregationEngine(calendar: utcCalendar)

        let week = engine.hierarchySummaries(
            for: .week,
            containing: date,
            plans: [],
            actuals: [],
            photos: []
        )
        XCTAssertEqual(week[.day]?.count, 7)

        let year = engine.hierarchySummaries(
            for: .year,
            containing: date,
            plans: [],
            actuals: [],
            photos: []
        )
        XCTAssertEqual(year[.month]?.count, 12)
        XCTAssertNotNil(year[.week])
        XCTAssertNotNil(year[.day])
    }

    func testAutomaticActivityIncludesSleepWorkoutAndWatchWithOverlapLanes() {
        let day = makeDate(2026, 8, 1)
        let sleep = ActualRecord(
            planID: nil,
            title: "수면",
            categoryID: "sleep",
            startedAt: day,
            endedAt: day.addingTimeInterval(8 * hour),
            source: .healthKit
        )
        let workout = ActualRecord(
            planID: nil,
            title: "러닝",
            categoryID: "exercise",
            startedAt: day.addingTimeInterval(7 * hour),
            endedAt: day.addingTimeInterval(9 * hour),
            source: .healthKit
        )
        let watch = ActualRecord(
            planID: nil,
            title: "Apple Watch 활동",
            categoryID: "health",
            startedAt: day.addingTimeInterval(10 * hour),
            endedAt: day.addingTimeInterval(11 * hour),
            source: .appleWatch
        )
        let manual = ActualRecord(
            planID: nil,
            title: "직접 기록",
            categoryID: "routine",
            startedAt: day.addingTimeInterval(12 * hour),
            endedAt: day.addingTimeInterval(13 * hour),
            source: .manual
        )
        let span = TimeSpan(
            start: day,
            end: day.addingTimeInterval(24 * hour)
        )

        let activities = AutomaticRecordTimelineEngine.activities(
            from: [manual, watch, workout, sleep],
            inside: span,
            asOf: span.end
        )
        XCTAssertEqual(activities.map(\.id), [sleep.id, workout.id, watch.id])

        let allocation = TimelineLaneAllocator.allocate(
            activities,
            span: { $0.span(asOf: span.end) }
        )
        XCTAssertEqual(allocation.count, 2)
        XCTAssertNotEqual(
            allocation.lanes[sleep.id],
            allocation.lanes[workout.id]
        )
        XCTAssertEqual(allocation.lanes[sleep.id], allocation.lanes[watch.id])
    }

    func testAutomaticHealthAndSensorRecordsAreImmutable() {
        let start = makeDate(2026, 8, 1, 9)
        func record(_ source: ActualSource) -> ActualRecord {
            ActualRecord(
                planID: nil,
                title: "활동",
                categoryID: "activity",
                startedAt: start,
                endedAt: start.addingTimeInterval(hour),
                source: source
            )
        }

        XCTAssertTrue(
            AutomaticRecordTimelineEngine.isImmutable(record(.healthKit))
        )
        XCTAssertTrue(
            AutomaticRecordTimelineEngine.isImmutable(record(.appleWatch))
        )
        XCTAssertTrue(
            AutomaticRecordTimelineEngine.isImmutable(record(.location))
        )
        XCTAssertTrue(
            AutomaticRecordTimelineEngine.isImmutable(record(.motion))
        )
        XCTAssertTrue(
            AutomaticRecordTimelineEngine.isImmutable(record(.media))
        )
        XCTAssertTrue(
            AutomaticRecordTimelineEngine.isImmutable(record(.call))
        )
        XCTAssertFalse(
            AutomaticRecordTimelineEngine.isImmutable(record(.manual))
        )
        XCTAssertFalse(
            AutomaticRecordTimelineEngine.isImmutable(record(.timer))
        )
    }

    func testAutomaticTimelineDoesNotForecastPastNow() {
        let now = makeDate(2026, 8, 3, 12)
        let ongoing = ActualRecord(
            planID: nil,
            title: "정지·휴식",
            categoryID: "activity",
            startedAt: now.addingTimeInterval(-hour),
            endedAt: now.addingTimeInterval(hour),
            source: .motion
        )
        let future = ActualRecord(
            planID: nil,
            title: "걷기",
            categoryID: "activity",
            startedAt: now.addingTimeInterval(10 * 60),
            endedAt: now.addingTimeInterval(20 * 60),
            source: .appleWatch
        )

        let visible = AutomaticRecordTimelineEngine.activities(
            from: [ongoing, future],
            inside: TimeSpan(
                start: now.addingTimeInterval(-2 * hour),
                end: now.addingTimeInterval(2 * hour)
            ),
            asOf: now
        )

        XCTAssertEqual(visible.map(\.id), [ongoing.id])
        XCTAssertEqual(visible[0].endedAt, now)
    }

    func testGoalChildMustStayInsideParent() {
        let base = makeDate(2026, 1, 1)
        let parent = PlanRecord(
            title: "부모",
            span: TimeSpan(start: base, end: base.addingTimeInterval(10 * hour)),
            categoryID: "project"
        )
        XCTAssertThrowsError(
            try GoalDecompositionEngine.makeChild(
                parent: parent,
                title: "범위 밖",
                span: TimeSpan(
                    start: base.addingTimeInterval(9 * hour),
                    end: base.addingTimeInterval(11 * hour)
                )
            )
        )
    }

    func testTimeSliderUsesOneMinuteAndTenMinutePrecision() {
        let base = makeDate(2026, 7, 30, 9, 0)
        let span = TimeSpan(start: base, end: base.addingTimeInterval(hour))
        let slow = TimeSliderEngine.adjust(
            span,
            handle: .body,
            delta: 7 * 60,
            velocityPointsPerSecond: 100,
            isLongPressPrecision: false
        )
        let fast = TimeSliderEngine.adjust(
            span,
            handle: .body,
            delta: 7 * 60,
            velocityPointsPerSecond: 900,
            isLongPressPrecision: false
        )
        XCTAssertEqual(slow.start.timeIntervalSince(base), 7 * 60)
        XCTAssertEqual(fast.start.timeIntervalSince(base), 10 * 60)
        XCTAssertEqual(
            TimeSliderEngine.snapInterval(
                velocityPointsPerSecond: 900,
                isLongPressPrecision: true
            ),
            60
        )
    }

    func testGanttViewportPinchZoomAndPanStayInsideTimeline() {
        let zoomed = GanttViewport.full.magnifying(
            by: 2,
            anchor: 0.25
        )
        XCTAssertEqual(zoomed.start, 0.125, accuracy: 0.0001)
        XCTAssertEqual(zoomed.length, 0.5, accuracy: 0.0001)
        XCTAssertEqual(zoomed.zoomScale, 2, accuracy: 0.0001)

        let panned = zoomed.panning(
            translation: -100,
            viewportWidth: 400
        )
        XCTAssertEqual(panned.start, 0.25, accuracy: 0.0001)
        XCTAssertEqual(panned.end, 0.75, accuracy: 0.0001)

        let clampedRight = panned.panning(
            translation: -2_000,
            viewportWidth: 400
        )
        XCTAssertEqual(clampedRight.end, 1, accuracy: 0.0001)

        let restored = clampedRight.magnifying(
            by: 0.01,
            anchor: 0.5
        )
        XCTAssertEqual(restored, .full)
    }

    func testGanttViewportStopsAtOneMinuteForEveryTimelineDuration() {
        let durations: [TimeInterval] = [
            24 * 60 * 60,
            7 * 24 * 60 * 60,
            31 * 24 * 60 * 60,
            366 * 24 * 60 * 60,
        ]

        for duration in durations {
            let minimumLength = GanttViewport.oneMinuteMinimumLength(
                for: duration
            )
            let zoomed = GanttViewport.full.magnifying(
                by: 1_000_000,
                anchor: 0.5,
                minimumLength: minimumLength
            )

            XCTAssertEqual(
                duration * zoomed.length,
                60,
                accuracy: 0.001
            )
        }
    }

    func testGanttSemanticZoomStagesFollowProductHierarchy() {
        XCTAssertEqual(
            GanttZoomStage.allCases,
            [
                .year,
                .month,
                .week,
                .day,
                .hour,
                .fifteenMinutes,
                .fiveMinutes,
                .oneMinute,
            ]
        )
        XCTAssertEqual(GanttZoomStage.day.narrower, .hour)
        XCTAssertEqual(GanttZoomStage.oneMinute.narrower, nil)
        XCTAssertEqual(GanttZoomStage.oneMinute.broader, .fiveMinutes)
        XCTAssertEqual(GanttZoomStage.nearest(to: 15 * 60), .fifteenMinutes)
        XCTAssertEqual(GanttZoomStage.nearest(to: 60), .oneMinute)

        XCTAssertEqual(TimeScale.year.narrower, .month)
        XCTAssertEqual(TimeScale.month.narrower, .week)
        XCTAssertEqual(TimeScale.week.narrower, .day)
        XCTAssertEqual(TimeScale.day.broader, .week)
    }

    func testGanttViewportFocusAndSemanticFitStayInsideTimeline() {
        let focused = GanttViewport.full.focusing(
            start: 0.45,
            length: 0.10,
            minimumLength: 1 / 1_440
        )
        XCTAssertLessThan(focused.start, 0.45)
        XCTAssertGreaterThan(focused.end, 0.55)

        let oneHour = GanttViewport.full.fitting(
            visibleDuration: 60 * 60,
            within: 24 * 60 * 60,
            anchor: 0.75
        )
        XCTAssertEqual(
            oneHour.length * 24 * 60 * 60,
            60 * 60,
            accuracy: 0.001
        )
        XCTAssertEqual(
            oneHour.start + oneHour.length * 0.75,
            0.75,
            accuracy: 0.001
        )
    }

    func testOneMinuteGanttPrioritizesTimeActualAndSensorConfidence() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = makeDate(2026, 7, 31, 9, 4)
        let end = makeDate(2026, 7, 31, 9, 36)

        XCTAssertEqual(
            GanttPrecisionPresentation.label(
                title: "자가용",
                startsAt: start,
                endsAt: end,
                detailText: "센서 추정 · 높은 신뢰",
                visibleDuration: 60,
                calendar: calendar
            ),
            "09:04–09:36 · 센서 추정 · 높은 신뢰"
        )
        XCTAssertEqual(
            GanttPrecisionPresentation.label(
                title: "러닝",
                startsAt: start,
                endsAt: end,
                detailText: "실제 · Apple 건강 · 높은 신뢰",
                visibleDuration: 15 * 60,
                calendar: calendar
            ),
            "러닝"
        )
    }

    @MainActor
    func testTwoFingerDoubleTapRecognizerIsInstalledAndInvokesReset() {
        var recognitionCount = 0
        let coordinator = TwoFingerDoubleTapAttachment.Coordinator {
            recognitionCount += 1
        }
        let hostView = UIView()
        let attachmentView = TwoFingerDoubleTapAttachment.AttachmentView()
        attachmentView.coordinator = coordinator

        hostView.addSubview(attachmentView)
        attachmentView.installRecognizerIfNeeded()

        let recognizer = hostView.gestureRecognizers?
            .compactMap { $0 as? UITapGestureRecognizer }
            .first
        XCTAssertEqual(recognizer?.numberOfTapsRequired, 2)
        XCTAssertEqual(recognizer?.numberOfTouchesRequired, 2)
        XCTAssertEqual(recognizer?.cancelsTouchesInView, false)

        coordinator.didRecognize()
        XCTAssertEqual(recognitionCount, 1)
    }

    @MainActor
    func testTwoFingerPinchRecognizerIsInstalledAndDeliversScale() {
        var changed: (CGFloat, CGFloat)?
        var ended: (CGFloat, CGFloat)?
        let coordinator = TwoFingerPinchAttachment.Coordinator(
            onChanged: { scale, anchor in
                changed = (scale, anchor)
            },
            onEnded: { scale, anchor in
                ended = (scale, anchor)
            }
        )
        let hostView = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let attachmentView = TwoFingerPinchAttachment.AttachmentView()
        attachmentView.coordinator = coordinator

        hostView.addSubview(attachmentView)
        attachmentView.installRecognizerIfNeeded()

        let recognizer = hostView.gestureRecognizers?
            .compactMap { $0 as? UIPinchGestureRecognizer }
            .first
        XCTAssertNotNil(recognizer)
        XCTAssertEqual(recognizer?.cancelsTouchesInView, false)

        coordinator.onChanged(1.5, 0.25)
        coordinator.onEnded(0.75, 0.75)
        XCTAssertEqual(changed?.0 ?? 0, 1.5, accuracy: 0.0001)
        XCTAssertEqual(changed?.1 ?? 0, 0.25, accuracy: 0.0001)
        XCTAssertEqual(ended?.0 ?? 0, 0.75, accuracy: 0.0001)
        XCTAssertEqual(ended?.1 ?? 0, 0.75, accuracy: 0.0001)
    }

    func testScheduleDragSnapsToFifteenMinutes() throws {
        let base = makeDate(2026, 7, 30, 9, 0)
        let plan = PlanRecord(
            title: "초안",
            span: TimeSpan(start: base, end: base.addingTimeInterval(hour)),
            categoryID: "project"
        )
        let moved = try ScheduleEditEngine.move(plan, by: 22 * 60)
        XCTAssertEqual(moved.span.start.timeIntervalSince(base), 15 * 60)
    }

    func testQuickActionsPreservePlanAndCreateSeparateActual() {
        let base = makeDate(2026, 7, 30, 9, 0)
        let plan = PlanRecord(
            title: "러닝",
            span: TimeSpan(start: base, end: base.addingTimeInterval(hour)),
            categoryID: "exercise"
        )
        let started = QuickActionEngine.start(plan: plan, actuals: [], at: base)
        XCTAssertEqual(started.plan.span, plan.span)
        XCTAssertEqual(started.plan.status, .running)
        XCTAssertEqual(started.actuals.count, 1)

        let completed = QuickActionEngine.complete(
            plan: started.plan,
            actuals: started.actuals,
            at: base.addingTimeInterval(40 * 60)
        )
        XCTAssertEqual(completed.plan.status, .completed)
        XCTAssertEqual(completed.actuals[0].span().duration, 40 * 60)
        XCTAssertEqual(completed.plan.span.duration, hour)
    }

    func testMoveToNextFreeTimeFindsGap() throws {
        let base = makeDate(2026, 7, 30, 9, 0)
        let plan = PlanRecord(
            title: "집중",
            span: TimeSpan(start: base, end: base.addingTimeInterval(hour)),
            categoryID: "project"
        )
        let occupied = [
            TimeSpan(start: base, end: base.addingTimeInterval(2 * hour)),
            TimeSpan(
                start: base.addingTimeInterval(3 * hour),
                end: base.addingTimeInterval(4 * hour)
            )
        ]
        let moved = try QuickActionEngine.moveToNextFreeTime(
            plan: plan,
            occupied: occupied,
            after: base
        )
        XCTAssertEqual(moved.span.start, base.addingTimeInterval(2 * hour))
    }

    func testPhotoMomentsClusterAndRespectHiddenFlag() {
        let base = makeDate(2026, 7, 30, 11, 42)
        let photos = [
            PhotoMoment(id: "1", capturedAt: base, pixelWidth: 100, pixelHeight: 100, isFavorite: false, isHiddenFromTimeline: false),
            PhotoMoment(id: "2", capturedAt: base.addingTimeInterval(5 * 60), pixelWidth: 100, pixelHeight: 100, isFavorite: true, isHiddenFromTimeline: false),
            PhotoMoment(id: "3", capturedAt: base.addingTimeInterval(40 * 60), pixelWidth: 100, pixelHeight: 100, isFavorite: false, isHiddenFromTimeline: true)
        ]
        let clusters = PhotoClusterer.cluster(photos)
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].representative.id, "2")
        XCTAssertEqual(clusters[0].additionalCount, 1)
        XCTAssertEqual(
            PhotoClusterer.nearestCluster(
                to: base.addingTimeInterval(8 * 60),
                in: photos,
                tolerance: 10 * 60
            )?.representative.id,
            "2"
        )
        XCTAssertNil(
            PhotoClusterer.nearestCluster(
                to: base.addingTimeInterval(2 * 60 * 60),
                in: photos,
                tolerance: 10 * 60
            )
        )
    }

    func testReviewDescribesDifferenceInsteadOfScoring() {
        let base = makeDate(2026, 7, 27)
        let plan = PlanRecord(
            title: "학습",
            span: TimeSpan(start: base, end: base.addingTimeInterval(2 * hour)),
            categoryID: "study"
        )
        let actual = ActualRecord(
            planID: plan.id,
            title: plan.title,
            categoryID: "study",
            startedAt: base,
            endedAt: base.addingTimeInterval(hour),
            source: .manual
        )
        let report = ReviewEngine(calendar: utcCalendar).report(
            for: .week,
            containing: base,
            plans: [plan],
            actuals: [actual],
            weather: [],
            photos: [],
            memos: [],
            asOf: base.addingTimeInterval(hour)
        )
        XCTAssertEqual(report.plannedDuration, 2 * hour)
        XCTAssertEqual(report.actualDuration, hour)
    }

    func testAllCustomCategoryRequirementsExist() throws {
        XCTAssertEqual(CategoryCatalog.builtIn.count, 32)
        XCTAssertGreaterThanOrEqual(CategoryIcon.allCases.count, 32)
        XCTAssertEqual(
            Set(CategoryCatalog.builtIn.map(\.icon)).count,
            CategoryCatalog.builtIn.count,
            "기본 대분류 아이콘은 서로 겹치지 않아야 합니다."
        )
        let custom = try CategoryCatalog.makeCustom(
            name: "봉사",
            icon: .family,
            lightHex: "AABBCC",
            existing: CategoryCatalog.builtIn
        )
        XCTAssertFalse(custom.isBuiltIn)
        XCTAssertEqual(custom.lightHex, "#AABBCC")
    }

    func testEveryBuiltInCategoryProvidesMiddleCategorySuggestions() {
        XCTAssertEqual(
            Set(CategoryHierarchyCatalog.middleSuggestionsByCategoryID.keys),
            Set(CategoryCatalog.builtIn.map(\.id))
        )

        for category in CategoryCatalog.builtIn {
            let suggestions = CategoryHierarchyCatalog.middleSuggestions(
                for: category.id
            )
            XCTAssertGreaterThanOrEqual(
                suggestions.count,
                4,
                "\(category.name) 중분류 추천이 부족합니다."
            )
            XCTAssertEqual(Set(suggestions).count, suggestions.count)
            XCTAssertTrue(suggestions.allSatisfy {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
        }

        XCTAssertEqual(
            CategoryHierarchyCatalog.middleSuggestions(
                for: "custom.volunteer"
            ),
            CategoryHierarchyCatalog.defaultMiddleSuggestions
        )
    }

    func testQuickPlanDraftUsesHalfHourDefaultsAndTitleFallback() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let input = calendar.date(
            from: DateComponents(
                year: 2026,
                month: 8,
                day: 1,
                hour: 12,
                minute: 57
            )
        )!
        let rounded = QuickPlanDraftEngine.roundedUpToHalfHour(input)

        XCTAssertEqual(calendar.component(.hour, from: rounded), 13)
        XCTAssertEqual(calendar.component(.minute, from: rounded), 0)
        XCTAssertEqual(QuickPlanDraftEngine.defaultDuration, 30 * 60)
        XCTAssertEqual(QuickPlanDraftEngine.adjustmentStep, 5 * 60)
        XCTAssertEqual(
            QuickPlanDraftEngine.resolvedTitle(
                subcategory: "청계천 산책",
                middleCategory: "산책"
            ),
            "청계천 산책"
        )
        XCTAssertEqual(
            QuickPlanDraftEngine.resolvedTitle(
                subcategory: "   ",
                middleCategory: "산책"
            ),
            "산책"
        )
        XCTAssertNil(
            QuickPlanDraftEngine.resolvedTitle(
                subcategory: "",
                middleCategory: ""
            )
        )
    }

    func testMiniGanttAdjustmentSnapsToFiveMinutes() {
        let base = makeDate(2026, 8, 1).addingTimeInterval(13 * hour)
        let span = TimeSpan(
            start: base,
            end: base.addingTimeInterval(30 * 60)
        )
        let resized = TimeSliderEngine.adjust(
            span,
            handle: .end,
            delta: 8 * 60,
            snapInterval: QuickPlanDraftEngine.adjustmentStep,
            minimumDuration: QuickPlanDraftEngine.adjustmentStep
        )
        let moved = TimeSliderEngine.adjust(
            span,
            handle: .body,
            delta: 12 * 60,
            snapInterval: QuickPlanDraftEngine.adjustmentStep,
            minimumDuration: QuickPlanDraftEngine.adjustmentStep
        )

        XCTAssertEqual(resized.duration, 40 * 60)
        XCTAssertEqual(moved.start, base.addingTimeInterval(10 * 60))
        XCTAssertEqual(moved.duration, span.duration)
    }

    func testDeletingCustomCategoryReassignsRecords() throws {
        let custom = try CategoryCatalog.makeCustom(
            name: "봉사",
            icon: .family,
            lightHex: "#AABBCC",
            existing: CategoryCatalog.builtIn
        )
        let base = makeDate(2026, 7, 30)
        let plan = PlanRecord(
            title: "봉사",
            span: TimeSpan(start: base, end: base.addingTimeInterval(hour)),
            categoryID: custom.id
        )
        let result = try CategoryCatalog.deleting(
            categoryID: custom.id,
            reassigningTo: "relationship",
            categories: CategoryCatalog.builtIn + [custom],
            plans: [plan],
            actuals: []
        )
        XCTAssertEqual(result.plans[0].categoryID, "relationship")
        XCTAssertFalse(result.categories.contains(where: { $0.id == custom.id }))
    }

    func testCategoryDragReorderingMovesInsteadOfSwapping() {
        let categories = Array(CategoryCatalog.builtIn.prefix(4))
        let reordered = CategoryCatalog.moving(
            categories,
            fromOffsets: IndexSet(integer: 0),
            toOffset: 3
        )

        XCTAssertEqual(
            reordered.map(\.id),
            [
                categories[1].id,
                categories[2].id,
                categories[0].id,
                categories[3].id,
            ]
        )
        XCTAssertEqual(
            reordered.map(\.sortOrder),
            Array(0..<categories.count)
        )
    }

    func testSubwayNeedsCombinedSignals() {
        let base = makeDate(2026, 7, 30, 8, 0)
        let readings = (0..<6).map { index in
            SensorReading(
                timestamp: base.addingTimeInterval(Double(index) * 60),
                speedMetersPerSecond: 12,
                motion: .automotive,
                motionConfidence: .high,
                relativeAltitudeMeters: Double(index) * -0.8,
                gpsAvailable: index < 2,
                nearbyStation: true,
                matchesRailRoute: true
            )
        }
        let result = TravelModeClassifier().classify(readings: readings)
        XCTAssertEqual(result.mode, .subway)
        XCTAssertEqual(result.confidence, .high)
        XCTAssertTrue(result.evidence.contains("지하철 복합 신호 충족"))
    }

    func testAppleWatchAccelerationAndUndergroundWindowIdentifySubway() {
        let base = makeDate(2026, 7, 30, 8, 0)
        let readings = (0..<6).map { index in
            SensorReading(
                timestamp: base.addingTimeInterval(Double(index) * 60),
                speedMetersPerSecond: index < 2 ? 14 : nil,
                motion: .automotive,
                motionConfidence: .high,
                relativeAltitudeMeters: Double(index) * -0.8,
                stepCount: 100,
                watchAccelerationStandardDeviationG: 0.04,
                watchAccelerationMeanJerkGPerSecond: 0.16,
                gpsAvailable: index < 2,
                frequentStops: true
            )
        }

        let result = TravelModeClassifier().classify(readings: readings)

        XCTAssertEqual(result.mode, .subway)
        XCTAssertTrue(
            result.evidence.contains("Apple Watch 3축 가속도 철도 진동")
        )
        XCTAssertTrue(result.evidence.contains("걸음 거의 없음 · 지하 구간"))
    }

    func testWatchVibrationWithoutUndergroundContextDoesNotBecomeSubway() {
        let base = makeDate(2026, 7, 30, 8, 0)
        let readings = (0..<4).map { index in
            SensorReading(
                timestamp: base.addingTimeInterval(Double(index) * 60),
                speedMetersPerSecond: 13,
                motion: .automotive,
                motionConfidence: .high,
                stepCount: 20,
                watchAccelerationStandardDeviationG: 0.04,
                watchAccelerationMeanJerkGPerSecond: 0.16,
                gpsAvailable: true
            )
        }

        XCTAssertNotEqual(
            TravelModeClassifier().classify(readings: readings).mode,
            .subway
        )
    }

    func testDirectMotionAndShipClassification() {
        let base = makeDate(2026, 7, 30)
        let running = SensorReading(
            timestamp: base,
            speedMetersPerSecond: 3,
            motion: .running,
            motionConfidence: .high
        )
        XCTAssertEqual(
            TravelModeClassifier().classify(readings: [running]).mode,
            .running
        )

        let ship = SensorReading(
            timestamp: base,
            speedMetersPerSecond: 8,
            motion: .unknown,
            motionConfidence: .medium,
            nearPort: true,
            onWater: true
        )
        XCTAssertEqual(
            TravelModeClassifier().classify(readings: [ship]).mode,
            .ship
        )
    }

    func testAutomotivePersistsWhenCoreMotionAlsoReportsStationary() {
        XCTAssertEqual(
            MotionKindResolver.resolve(
                stationary: true,
                walking: false,
                running: false,
                cycling: false,
                automotive: true
            ),
            .automotive
        )
        XCTAssertEqual(
            MotionKindResolver.resolve(
                stationary: false,
                walking: true,
                running: true,
                cycling: false,
                automotive: false
            ),
            .running
        )
        XCTAssertEqual(
            MotionKindResolver.resolve(
                stationary: false,
                walking: true,
                running: false,
                cycling: false,
                automotive: true
            ),
            .automotive
        )
    }

    func testMotionActivityActualsExposeEveryPassiveBehaviorWithoutDuplicates() {
        let base = makeDate(2026, 8, 1, 8)
        let span = TimeSpan(
            start: base,
            end: base.addingTimeInterval(30 * 60)
        )
        let activities = [
            MotionActivityRecord(
                span: TimeSpan(start: base, end: base.addingTimeInterval(5 * 60)),
                motion: .stationary,
                confidence: .high
            ),
            MotionActivityRecord(
                span: TimeSpan(
                    start: base.addingTimeInterval(5 * 60),
                    end: base.addingTimeInterval(10 * 60)
                ),
                motion: .walking,
                confidence: .high
            ),
            MotionActivityRecord(
                span: TimeSpan(
                    start: base.addingTimeInterval(10 * 60),
                    end: base.addingTimeInterval(15 * 60)
                ),
                motion: .running,
                confidence: .medium
            ),
            MotionActivityRecord(
                span: TimeSpan(
                    start: base.addingTimeInterval(15 * 60),
                    end: base.addingTimeInterval(20 * 60)
                ),
                motion: .cycling,
                confidence: .high
            ),
            MotionActivityRecord(
                span: TimeSpan(
                    start: base.addingTimeInterval(20 * 60),
                    end: base.addingTimeInterval(25 * 60)
                ),
                motion: .automotive,
                confidence: .medium
            ),
        ]

        let first = MotionActivityActualEngine.records(
            from: activities,
            existing: [],
            inside: span
        )
        let second = MotionActivityActualEngine.records(
            from: activities,
            existing: [],
            inside: span
        )

        XCTAssertEqual(
            first.map(\.title),
            ["정지·휴식", "걷기", "달리기", "자전거", "자동차"]
        )
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertTrue(first.allSatisfy { $0.source == .motion })

        let workout = ActualRecord(
            planID: nil,
            title: "걷기",
            categoryID: "exercise",
            startedAt: base.addingTimeInterval(5 * 60),
            endedAt: base.addingTimeInterval(10 * 60),
            source: .appleWatch
        )
        let withoutDuplicate = MotionActivityActualEngine.records(
            from: activities,
            existing: [workout],
            inside: span
        )
        XCTAssertFalse(withoutDuplicate.contains { $0.title == "걷기" })
    }

    func testIPhoneStepIncreaseSeparatesWalkingFromAutomotiveMotion() {
        let base = makeDate(2026, 7, 30, 9, 0)
        let span = TimeSpan(
            start: base,
            end: base.addingTimeInterval(3 * 60)
        )
        let walkingReadings = (0..<4).map { index in
            SensorReading(
                timestamp: base.addingTimeInterval(Double(index) * 60),
                speedMetersPerSecond: 1.4,
                motion: .automotive,
                motionConfidence: .medium,
                stepCount: index * 90
            )
        }
        let walking = TravelModeClassifier().classify(
            readings: walkingReadings,
            inside: span
        )

        XCTAssertEqual(walking.mode, .walking)
        XCTAssertTrue(
            walking.evidence.contains("iPhone 실시간 걸음 270보")
        )

        let automotiveReadings = (0..<4).map { index in
            SensorReading(
                timestamp: base.addingTimeInterval(Double(index) * 60),
                speedMetersPerSecond: 12,
                motion: .automotive,
                motionConfidence: .high,
                stepCount: 100 + min(index, 1)
            )
        }
        let automotive = TravelModeClassifier().classify(
            readings: automotiveReadings,
            inside: span
        )

        XCTAssertEqual(automotive.mode, .car)
        XCTAssertTrue(
            automotive.evidence.contains(
                "iPhone·Apple Watch 걸음 증가 거의 없음"
            )
        )
    }

    func testAutomotiveMotionWithVehicleSpeedBeatsIncidentalSteps() {
        let base = makeDate(2026, 7, 31, 19, 0)
        let span = TimeSpan(
            start: base,
            end: base.addingTimeInterval(10 * 60)
        )
        let readings = (0..<3).map { index in
            SensorReading(
                timestamp: base.addingTimeInterval(Double(index) * 5 * 60),
                point: GeoPoint(
                    latitude: 37.50 + Double(index) * 0.01,
                    longitude: 126.90 + Double(index) * 0.01,
                    altitude: 20,
                    horizontalAccuracy: 12,
                    verticalAccuracy: 30
                ),
                motion: .automotive,
                motionConfidence: .high,
                stepCount: 420 + index * 8
            )
        }

        let result = TravelModeClassifier().classify(
            readings: readings,
            inside: span
        )

        XCTAssertEqual(result.mode, .car)
        XCTAssertTrue(
            result.evidence.contains("차량 속도대와 자동차 모션 우선")
                || result.evidence.contains("차량 가능 속도")
                || result.evidence.contains("Core Motion 자동차 후보")
        )
    }

    func testVehicleSpeedAndLowStepsOverrideWalkingMotionHistory() {
        let base = makeDate(2026, 8, 2, 18, 0)
        let span = TimeSpan(
            start: base,
            end: base.addingTimeInterval(90 * 60)
        )
        let readings = (0..<7).map { index in
            SensorReading(
                timestamp: base.addingTimeInterval(Double(index) * 15 * 60),
                speedMetersPerSecond: 11,
                speedAccuracyMetersPerSecond: 0.8,
                motion: .walking,
                motionConfidence: .high,
                stepCount: 200 + index
            )
        }

        let result = TravelModeClassifier().classify(
            readings: readings,
            inside: span
        )

        XCTAssertEqual(result.mode, .car)
        XCTAssertTrue(
            result.evidence.contains("iPhone·Apple Watch 걸음 증가 거의 없음")
                || result.evidence.contains("보행 불가능 속도와 걸음 신호 불일치")
        )
    }

    func testCadenceAndMotionWindowIdentifyWalkingWithoutGPS() {
        let base = makeDate(2026, 8, 1, 8, 0)
        let readings = (0..<3).map { index in
            SensorReading(
                timestamp: base.addingTimeInterval(Double(index) * 60),
                speedMetersPerSecond: nil,
                motion: .unknown,
                motionConfidence: .low,
                currentPaceSecondsPerMeter: 0.72,
                currentCadenceStepsPerSecond: 1.75,
                deviceMotionSummary: DeviceMotionSummary(
                    sampleCount: 60,
                    meanUserAccelerationG: 0.12,
                    userAccelerationStandardDeviationG: 0.09,
                    peakUserAccelerationG: 0.42,
                    meanRotationRateRadiansPerSecond: 0.24,
                    rotationRateStandardDeviationRadiansPerSecond: 0.11,
                    peakRotationRateRadiansPerSecond: 0.72
                ),
                gpsAvailable: false
            )
        }

        let result = TravelModeClassifier().classify(
            readings: readings,
            inside: TimeSpan(
                start: base,
                end: base.addingTimeInterval(3 * 60)
            )
        )

        XCTAssertEqual(result.mode, .walking)
        XCTAssertTrue(
            result.evidence.contains {
                $0.contains("cadence 105보/분")
            }
        )
        XCTAssertTrue(
            result.evidence.contains("걸음 cadence와 3축 가속도 일치")
        )
    }

    func testPoorAccuracyGPSSpikeDoesNotBecomeAirplane() {
        let base = makeDate(2026, 8, 1, 8, 0)
        let speeds: [(Double, Double)] = [
            (1.2, 0.4),
            (1.4, 0.5),
            (95, 80),
            (1.3, 0.4),
            (1.5, 0.5),
        ]
        let readings = speeds.enumerated().map { index, item in
            SensorReading(
                timestamp: base.addingTimeInterval(Double(index) * 60),
                speedMetersPerSecond: item.0,
                speedAccuracyMetersPerSecond: item.1,
                motion: .walking,
                motionConfidence: .high,
                stepCount: index * 80,
                currentCadenceStepsPerSecond: 1.5
            )
        }

        let result = TravelModeClassifier().classify(readings: readings)

        XCTAssertEqual(result.mode, .walking)
        XCTAssertNotEqual(result.mode, .airplane)
    }

    func testLowStepAutomotiveMotionUsesVehicleVibrationWindow() {
        let base = makeDate(2026, 8, 1, 18, 0)
        let readings = (0..<4).map { index in
            SensorReading(
                timestamp: base.addingTimeInterval(Double(index) * 60),
                speedMetersPerSecond: 13,
                speedAccuracyMetersPerSecond: 0.8,
                motion: .automotive,
                motionConfidence: .high,
                stepCount: 20 + index,
                currentCadenceStepsPerSecond: 0,
                deviceMotionSummary: DeviceMotionSummary(
                    sampleCount: 30,
                    meanUserAccelerationG: 0.08,
                    userAccelerationStandardDeviationG: 0.04,
                    peakUserAccelerationG: 0.31,
                    meanRotationRateRadiansPerSecond: 0.09,
                    rotationRateStandardDeviationRadiansPerSecond: 0.03,
                    peakRotationRateRadiansPerSecond: 0.2
                )
            )
        }

        let result = TravelModeClassifier().classify(
            readings: readings,
            inside: TimeSpan(
                start: base,
                end: base.addingTimeInterval(4 * 60)
            )
        )

        XCTAssertEqual(result.mode, .car)
        XCTAssertTrue(result.evidence.contains("저걸음 차량 진동 패턴"))
    }

    func testAppleWatchWorkoutOverridesConflictingIPhoneMotion() {
        let base = makeDate(2026, 7, 30, 9, 0)
        let span = TimeSpan(
            start: base,
            end: base.addingTimeInterval(10 * 60)
        )
        let readings = (0..<6).map { index in
            SensorReading(
                timestamp: base.addingTimeInterval(Double(index) * 2 * 60),
                speedMetersPerSecond: 8,
                motion: .automotive,
                motionConfidence: .high,
                stepCount: index * 100
            )
        }
        let watchWorkout = AppleMovementEvidence(
            span: span,
            source: .appleWatch,
            kind: .workout,
            workoutMode: .walking,
            stepCount: 1_000,
            distanceMeters: 800,
            sourceName: "Apple Watch",
            deviceName: "Apple Watch"
        )

        let result = TravelModeClassifier().classify(
            readings: readings,
            inside: span,
            healthEvidence: [watchWorkout]
        )

        XCTAssertEqual(result.mode, .walking)
        XCTAssertEqual(result.confidence, .high)
        XCTAssertTrue(
            result.evidence.contains("Apple Watch 걷기 운동")
        )
    }

    func testMovementCorrectionSurvivesRefreshAndCanBeForgotten() throws {
        let base = makeDate(2026, 7, 30, 9, 0)
        let originalPlaces = [
            PlaceStay(
                placeKey: "home",
                displayName: "집",
                span: TimeSpan(
                    start: base.addingTimeInterval(-hour),
                    end: base
                ),
                confidence: .high
            ),
            PlaceStay(
                placeKey: "office",
                displayName: "회사",
                span: TimeSpan(
                    start: base.addingTimeInterval(hour),
                    end: base.addingTimeInterval(2 * hour)
                ),
                confidence: .high
            ),
        ]
        let original = TravelSegment(
            fromPlaceID: originalPlaces[0].id,
            toPlaceID: originalPlaces[1].id,
            mode: .car,
            span: TimeSpan(
                start: base,
                end: base.addingTimeInterval(hour)
            ),
            distanceMeters: 12_000,
            confidence: .medium,
            evidence: ["iPhone 자동차 활동"]
        )
        let corrections = MovementCorrectionEngine.recording(
            mode: .subway,
            for: original,
            places: originalPlaces,
            existing: [],
            at: base.addingTimeInterval(2 * hour)
        )

        let nextDay = base.addingTimeInterval(24 * hour)
        let refreshedPlaces = [
            PlaceStay(
                placeKey: "home",
                displayName: "집",
                span: TimeSpan(
                    start: nextDay.addingTimeInterval(-hour),
                    end: nextDay
                ),
                confidence: .high
            ),
            PlaceStay(
                placeKey: "office",
                displayName: "회사",
                span: TimeSpan(
                    start: nextDay.addingTimeInterval(hour),
                    end: nextDay.addingTimeInterval(2 * hour)
                ),
                confidence: .high
            ),
        ]
        let refreshed = TravelSegment(
            fromPlaceID: refreshedPlaces[0].id,
            toPlaceID: refreshedPlaces[1].id,
            mode: .bus,
            span: TimeSpan(
                start: nextDay,
                end: nextDay.addingTimeInterval(hour)
            ),
            distanceMeters: 12_100,
            confidence: .low,
            evidence: ["새 센서 판정"]
        )

        let applied = try XCTUnwrap(
            MovementCorrectionEngine.applying(
                corrections,
                to: [refreshed],
                places: refreshedPlaces
            ).first
        )

        XCTAssertEqual(applied.mode, .subway)
        XCTAssertEqual(applied.confidence, .high)
        XCTAssertTrue(applied.isConfirmed)
        XCTAssertTrue(applied.evidence.contains("사용자 확인 기억"))
        XCTAssertEqual(corrections.first?.inferredMode, .car)
        XCTAssertTrue(
            MovementCorrectionEngine.removingCorrection(
                for: applied,
                places: refreshedPlaces,
                from: corrections
            ).isEmpty
        )
    }

    func testAdjacentSimilarTravelSegmentsAreGrouped() throws {
        let base = makeDate(2026, 7, 31, 18, 21)
        let first = TravelSegment(
            mode: .car,
            span: TimeSpan(
                start: base,
                end: base.addingTimeInterval(4 * 60)
            ),
            distanceMeters: 1_100,
            confidence: .medium,
            evidence: ["Core Motion 자동차 후보"]
        )
        let second = TravelSegment(
            mode: .car,
            span: TimeSpan(
                start: base.addingTimeInterval(4 * 60),
                end: base.addingTimeInterval(7 * 60)
            ),
            distanceMeters: 900,
            confidence: .medium,
            evidence: ["iPhone Core Motion 기록"]
        )

        let group = try XCTUnwrap(
            TravelSegmentGroupingEngine.groups(from: [second, first]).first
        )

        XCTAssertEqual(group.segmentIDs, [first.id, second.id])
        XCTAssertEqual(group.mode, .car)
        XCTAssertEqual(group.span.start, first.span.start)
        XCTAssertEqual(group.span.end, second.span.end)
        XCTAssertEqual(group.distanceMeters, 2_000)
        XCTAssertEqual(group.evidence.count, 2)
    }

    func testTravelGroupingKeepsDifferentOrDistantSegmentsSeparate() {
        let base = makeDate(2026, 7, 31, 15, 42)
        let walking = TravelSegment(
            mode: .walking,
            span: TimeSpan(
                start: base,
                end: base.addingTimeInterval(21 * 60)
            ),
            distanceMeters: 1_000,
            confidence: .high,
            evidence: []
        )
        let laterWalking = TravelSegment(
            mode: .walking,
            span: TimeSpan(
                start: base.addingTimeInterval(38 * 60),
                end: base.addingTimeInterval(79 * 60)
            ),
            distanceMeters: 2_500,
            confidence: .medium,
            evidence: []
        )
        let car = TravelSegment(
            mode: .car,
            span: TimeSpan(
                start: base.addingTimeInterval(79 * 60),
                end: base.addingTimeInterval(83 * 60)
            ),
            distanceMeters: 900,
            confidence: .medium,
            evidence: []
        )

        XCTAssertEqual(
            TravelSegmentGroupingEngine.groups(
                from: [walking, laterWalking, car]
            ).map(\.segments.count),
            [1, 1, 1]
        )
    }

    func testMemoEditingPreservesIdentityAndAttachments() throws {
        let createdAt = makeDate(2026, 7, 30, 9, 0)
        let updatedAt = createdAt.addingTimeInterval(60)
        let attachment = MemoAttachment(
            kind: .photo,
            localIdentifier: "photo-id",
            createdAt: createdAt
        )
        let original = ActionMemo(
            planID: UUID(),
            targetID: "automatic.actual.item",
            kind: .idea,
            text: "초안",
            attachments: [attachment],
            createdAt: createdAt,
            updatedAt: createdAt
        )

        let updated = try XCTUnwrap(
            ActionMemoEditingEngine.updating(
                original,
                text: "  다음 행동  ",
                kind: .nextAction,
                at: updatedAt
            )
        )

        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.planID, original.planID)
        XCTAssertEqual(updated.targetID, original.targetID)
        XCTAssertEqual(updated.text, "다음 행동")
        XCTAssertEqual(updated.kind, .nextAction)
        XCTAssertEqual(updated.attachments, [attachment])
        XCTAssertEqual(updated.createdAt, createdAt)
        XCTAssertEqual(updated.updatedAt, updatedAt)
        XCTAssertNil(
            ActionMemoEditingEngine.updating(
                original,
                text: "  ",
                kind: .decision
            )
        )
    }

    func testFloorEstimatorUsesRelativeAltitudeAndBaseline() {
        let base = makeDate(2026, 7, 30)
        let readings = [
            SensorReading(timestamp: base, relativeAltitudeMeters: 0),
            SensorReading(
                timestamp: base.addingTimeInterval(60),
                relativeAltitudeMeters: 3.1,
                floorsAscended: 1
            )
        ]
        let result = FloorEstimator().estimate(
            readings: readings,
            placeKey: "office",
            baselineFloor: 9
        )
        XCTAssertEqual(result?.fromFloor, 9)
        XCTAssertEqual(result?.toFloor, 10)
    }

    func testTimelineFloorEstimatorNeedsPersistentSamples() {
        let base = makeDate(2026, 7, 30)
        let readings = [
            SensorReading(timestamp: base, relativeAltitudeMeters: 0),
            SensorReading(
                timestamp: base.addingTimeInterval(60),
                relativeAltitudeMeters: 3.1
            ),
        ]

        XCTAssertNil(
            FloorEstimator(minimumStableSampleCount: 3).estimate(
                readings: readings,
                placeKey: "home",
                baselineFloor: 20
            )
        )
    }

    func testHomeFloorCalibrationUsesRelativeAltitudeAndShowsSeaLevelAltitude() {
        let base = makeDate(2026, 7, 31, 18)
        let sessionID = UUID()
        let homePoint = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 82,
            horizontalAccuracy: 8,
            verticalAccuracy: 6
        )
        let initial = SensorReading(
            timestamp: base,
            point: homePoint,
            relativeAltitudeMeters: 0,
            pressureKilopascals: 100.2,
            altimeterSessionID: sessionID
        )
        let engine = FloorCalibrationEngine()
        let calibration = engine.capturing(
            .homeTwentiethFloor,
            from: initial
        )
        let estimate = engine.estimate(
            reading: SensorReading(
                timestamp: base.addingTimeInterval(60),
                point: homePoint,
                relativeAltitudeMeters: 3.1,
                pressureKilopascals: 100.16,
                altimeterSessionID: sessionID
            ),
            calibration: calibration
        )

        XCTAssertTrue(calibration.isCaptured)
        XCTAssertEqual(estimate?.floor, 21)
        XCTAssertEqual(
            estimate?.seaLevelAltitudeMeters ?? 0,
            85.1,
            accuracy: 0.01
        )
        XCTAssertEqual(estimate?.verticalAccuracyMeters, 6)
        XCTAssertEqual(estimate?.confidence, .high)
    }

    func testCoreMotionWalkingLabelLosesToImpossibleDisplacementSpeed() {
        let base = makeDate(2026, 8, 4, 9, 24)
        let span = TimeSpan(start: base, end: base.addingTimeInterval(46 * 60))
        // 부천 → 계양 약 8km. Core Motion은 보행으로 라벨링한 상태.
        let readings = [
            SensorReading(
                timestamp: base,
                point: GeoPoint(
                    latitude: 37.4870,
                    longitude: 126.7830,
                    altitude: 30,
                    horizontalAccuracy: 12,
                    verticalAccuracy: 8
                ),
                motion: .walking,
                motionConfidence: .medium
            ),
            SensorReading(
                timestamp: span.end,
                point: GeoPoint(
                    latitude: 37.5385,
                    longitude: 126.8580,
                    altitude: 25,
                    horizontalAccuracy: 12,
                    verticalAccuracy: 8
                ),
                motion: .walking,
                motionConfidence: .medium
            ),
        ]

        let inference = TravelModeClassifier().classify(
            readings: readings,
            inside: span
        )

        XCTAssertNotEqual(inference.mode, .walking)
        XCTAssertNotEqual(inference.mode, .running)
    }

    func testShortSlowSegmentStaysWalking() {
        let base = makeDate(2026, 8, 4, 9, 24)
        let span = TimeSpan(start: base, end: base.addingTimeInterval(10 * 60))
        let readings = [
            SensorReading(
                timestamp: base,
                point: GeoPoint(
                    latitude: 37.4870,
                    longitude: 126.7830,
                    altitude: 30,
                    horizontalAccuracy: 10,
                    verticalAccuracy: 8
                ),
                motion: .walking,
                motionConfidence: .high
            ),
            SensorReading(
                timestamp: span.end,
                point: GeoPoint(
                    latitude: 37.4900,
                    longitude: 126.7845,
                    altitude: 30,
                    horizontalAccuracy: 10,
                    verticalAccuracy: 8
                ),
                motion: .walking,
                motionConfidence: .high
            ),
        ]

        let inference = TravelModeClassifier().classify(
            readings: readings,
            inside: span
        )

        XCTAssertEqual(inference.mode, .walking)
    }

    func testRecalibrationKeepsOtherFloorsInSameBuilding() {
        let base = makeDate(2026, 8, 4, 9)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 40,
            horizontalAccuracy: 8,
            verticalAccuracy: 6
        )
        var place = FrequentPlace(kind: .home, name: "집")
        place.setLocation(
            from: SensorReading(timestamp: base, point: point),
            floor: 1
        )
        place.addFloorCalibration(
            from: SensorReading(
                timestamp: base.addingTimeInterval(60),
                point: point
            ),
            floor: 20
        )

        place.setLocation(
            from: SensorReading(
                timestamp: base.addingTimeInterval(120),
                point: point
            ),
            floor: 1
        )

        XCTAssertEqual(place.floorCalibration?.knownFloors, [1, 20])
    }

    func testRecalibrationInAnotherBuildingDropsStaleFloors() {
        let base = makeDate(2026, 8, 4, 9)
        let home = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 40,
            horizontalAccuracy: 8,
            verticalAccuracy: 6
        )
        let elsewhere = GeoPoint(
            latitude: 37.55,
            longitude: 127.05,
            altitude: 30,
            horizontalAccuracy: 8,
            verticalAccuracy: 6
        )
        var place = FrequentPlace(kind: .home, name: "집")
        place.setLocation(
            from: SensorReading(timestamp: base, point: home),
            floor: 1
        )
        place.addFloorCalibration(
            from: SensorReading(
                timestamp: base.addingTimeInterval(60),
                point: home
            ),
            floor: 20
        )

        place.setLocation(
            from: SensorReading(
                timestamp: base.addingTimeInterval(120),
                point: elsewhere
            ),
            floor: 3
        )

        XCTAssertEqual(place.floorCalibration?.knownFloors, [3])
    }

    func testAltitudeSpikeGateSkipsSingleSpikeAndAcceptsConfirmedChange() {
        var gate = AltitudeSpikeGate()
        XCTAssertTrue(gate.accept(80))
        XCTAssertTrue(gate.accept(83))
        XCTAssertFalse(gate.accept(140))
        XCTAssertTrue(gate.accept(84))
        XCTAssertFalse(gate.accept(120))
        XCTAssertTrue(gate.accept(121))
        XCTAssertTrue(gate.accept(122))
    }

    func testEnforcingMotionFamilyRewritesCyclingOverAutomotiveWindow() {
        let base = makeDate(2026, 8, 4, 9, 26)
        let span = TimeSpan(start: base, end: base.addingTimeInterval(42 * 60))
        let cycling = TravelSegment(
            mode: .cycling,
            span: span,
            distanceMeters: 8_000,
            confidence: .medium,
            evidence: ["자전거 속도대"]
        )
        let activity = MotionActivityRecord(
            span: span,
            motion: .automotive,
            confidence: .high
        )
        let readings = [
            SensorReading(timestamp: base, stepCount: 120),
            SensorReading(timestamp: span.end, stepCount: 128),
        ]

        let result = AppleDeviceGroundTruthEngine.enforcingMotionFamily(
            [cycling],
            activities: [activity],
            readings: readings
        )

        XCTAssertEqual(result.first?.mode, .car)
    }

    func testEnforcingMotionFamilyKeepsWalkingWhenStepsIncrease() {
        let base = makeDate(2026, 8, 4, 9, 26)
        let span = TimeSpan(start: base, end: base.addingTimeInterval(10 * 60))
        let walking = TravelSegment(
            mode: .walking,
            span: span,
            distanceMeters: 800,
            confidence: .high,
            evidence: ["Core Motion 보행"]
        )
        let activity = MotionActivityRecord(
            span: span,
            motion: .automotive,
            confidence: .medium
        )
        let readings = [
            SensorReading(timestamp: base, stepCount: 100),
            SensorReading(timestamp: span.end, stepCount: 1_000),
        ]

        let result = AppleDeviceGroundTruthEngine.enforcingMotionFamily(
            [walking],
            activities: [activity],
            readings: readings
        )

        XCTAssertEqual(result.first?.mode, .walking)
    }

    func testResolvingOverlapsKeepsOneSegmentPerMoment() {
        let base = makeDate(2026, 8, 4, 9, 24)
        let long = TravelSegment(
            mode: .car,
            span: TimeSpan(start: base, end: base.addingTimeInterval(40 * 60)),
            distanceMeters: 8_000,
            confidence: .high,
            evidence: ["GPS"]
        )
        let overlapping = TravelSegment(
            mode: .cycling,
            span: TimeSpan(
                start: base.addingTimeInterval(10 * 60),
                end: base.addingTimeInterval(20 * 60)
            ),
            distanceMeters: 900,
            confidence: .low,
            evidence: ["iPhone Core Motion 기록"]
        )

        let resolved = AppleDeviceGroundTruthEngine.resolvingOverlaps(
            [long, overlapping]
        )

        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.mode, .car)
        for pair in zip(resolved, resolved.dropFirst()) {
            XCTAssertNil(pair.0.span.intersection(with: pair.1.span))
        }
    }

    func testResolvingOverlapsTrimsTrailingRemainder() {
        let base = makeDate(2026, 8, 4, 9, 24)
        let first = TravelSegment(
            mode: .car,
            span: TimeSpan(start: base, end: base.addingTimeInterval(20 * 60)),
            distanceMeters: 6_000,
            confidence: .high,
            evidence: ["GPS"]
        )
        let second = TravelSegment(
            mode: .walking,
            span: TimeSpan(
                start: base.addingTimeInterval(18 * 60),
                end: base.addingTimeInterval(30 * 60)
            ),
            distanceMeters: 600,
            confidence: .medium,
            evidence: ["iPhone Core Motion 기록"]
        )

        let resolved = AppleDeviceGroundTruthEngine.resolvingOverlaps(
            [first, second]
        )

        XCTAssertEqual(resolved.count, 2)
        XCTAssertEqual(resolved[1].mode, .walking)
        XCTAssertEqual(resolved[1].span.start, first.span.end)
        XCTAssertNil(
            resolved[0].span.intersection(with: resolved[1].span)
        )
    }

    func testCoalescingTravelMergesSameModeFragmentsAcrossSamplingGaps() {
        let base = makeDate(2026, 8, 4, 11, 40)
        let first = TravelSegment(
            mode: .walking,
            span: TimeSpan(start: base, end: base.addingTimeInterval(120)),
            distanceMeters: 100,
            confidence: .medium,
            evidence: ["iPhone Core Motion 기록"]
        )
        let second = TravelSegment(
            mode: .walking,
            span: TimeSpan(
                start: base.addingTimeInterval(360),
                end: base.addingTimeInterval(480)
            ),
            distanceMeters: 150,
            confidence: .high,
            evidence: ["iPhone 걸음·거리 기록"]
        )
        let car = TravelSegment(
            mode: .car,
            span: TimeSpan(
                start: base.addingTimeInterval(600),
                end: base.addingTimeInterval(900)
            ),
            distanceMeters: 2_000,
            confidence: .high,
            evidence: ["GPS"]
        )

        let merged = AppleDeviceGroundTruthEngine.coalescingTravel(
            [first, second, car],
            stays: [],
            maximumGap: 6 * 60
        )

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].id, first.id)
        XCTAssertEqual(
            merged[0].span,
            TimeSpan(start: base, end: base.addingTimeInterval(480))
        )
        XCTAssertEqual(merged[0].distanceMeters, 250)
        XCTAssertEqual(merged[0].confidence, .high)
        XCTAssertEqual(merged[1].mode, .car)
    }

    func testCoalescingTravelKeepsFragmentsSeparatedByStay() {
        let base = makeDate(2026, 8, 4, 11, 40)
        let first = TravelSegment(
            mode: .walking,
            span: TimeSpan(start: base, end: base.addingTimeInterval(120)),
            distanceMeters: 100,
            confidence: .medium,
            evidence: ["iPhone Core Motion 기록"]
        )
        let second = TravelSegment(
            mode: .walking,
            span: TimeSpan(
                start: base.addingTimeInterval(360),
                end: base.addingTimeInterval(480)
            ),
            distanceMeters: 150,
            confidence: .high,
            evidence: ["iPhone 걸음·거리 기록"]
        )
        let stay = PlaceStay(
            placeKey: "cafe",
            displayName: "카페",
            span: TimeSpan(
                start: base.addingTimeInterval(130),
                end: base.addingTimeInterval(350)
            ),
            confidence: .high
        )

        let merged = AppleDeviceGroundTruthEngine.coalescingTravel(
            [first, second],
            stays: [stay],
            maximumGap: 6 * 60
        )

        XCTAssertEqual(merged.count, 2)
    }

    func testHomeFloorCalibrationRejectsFarAwayLocation() {
        let base = makeDate(2026, 7, 31, 18)
        let sessionID = UUID()
        let homePoint = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 82,
            horizontalAccuracy: 8,
            verticalAccuracy: 6
        )
        let engine = FloorCalibrationEngine()
        let calibration = engine.capturing(
            .homeTwentiethFloor,
            from: SensorReading(
                timestamp: base,
                point: homePoint,
                relativeAltitudeMeters: 0,
                altimeterSessionID: sessionID
            )
        )
        let estimate = engine.estimate(
            reading: SensorReading(
                timestamp: base.addingTimeInterval(60),
                point: GeoPoint(
                    latitude: 37.52,
                    longitude: 127.02,
                    altitude: 85,
                    horizontalAccuracy: 8,
                    verticalAccuracy: 6
                ),
                relativeAltitudeMeters: 3,
                altimeterSessionID: sessionID
            ),
            calibration: calibration
        )

        XCTAssertNil(estimate)
    }

    func testFloorEstimatorUsesPedometerCountersAsCumulativeValues() {
        let base = makeDate(2026, 7, 30)
        let readings = [
            SensorReading(
                timestamp: base,
                relativeAltitudeMeters: 0,
                floorsAscended: 4,
                floorsDescended: 1
            ),
            SensorReading(
                timestamp: base.addingTimeInterval(30),
                relativeAltitudeMeters: 3,
                floorsAscended: 5,
                floorsDescended: 1
            ),
            SensorReading(
                timestamp: base.addingTimeInterval(60),
                relativeAltitudeMeters: 3.1,
                floorsAscended: 5,
                floorsDescended: 1
            )
        ]
        let result = FloorEstimator().estimate(
            readings: readings,
            placeKey: "office",
            baselineFloor: 9
        )
        XCTAssertEqual(result?.toFloor, 10)
        XCTAssertTrue(result?.evidence.contains("층계 +1") == true)
    }

    func testFloorEstimatorDoesNotMixDifferentAltimeterSessions() {
        let base = makeDate(2026, 7, 30, 9)
        let firstSession = UUID()
        let secondSession = UUID()
        let readings = [
            SensorReading(
                timestamp: base,
                relativeAltitudeMeters: 0,
                altimeterSessionID: firstSession
            ),
            SensorReading(
                timestamp: base.addingTimeInterval(60),
                relativeAltitudeMeters: 0.1,
                altimeterSessionID: firstSession
            ),
            SensorReading(
                timestamp: base.addingTimeInterval(120),
                relativeAltitudeMeters: 3.1,
                altimeterSessionID: secondSession
            ),
            SensorReading(
                timestamp: base.addingTimeInterval(180),
                relativeAltitudeMeters: 3.2,
                altimeterSessionID: secondSession
            ),
        ]

        XCTAssertNil(
            FloorEstimator().estimate(
                readings: readings,
                placeKey: "office",
                baselineFloor: 9
            )
        )
    }

    func testFloorTimelineAppliesConfirmedBaselineAndSplitsPlace() {
        let base = makeDate(2026, 7, 30, 9)
        let sessionID = UUID()
        let placeSpan = TimeSpan(
            start: base,
            end: base.addingTimeInterval(30 * 60)
        )
        let detected = PlaceStay(
            placeKey: "office",
            displayName: "회사",
            span: placeSpan,
            confidence: .high
        )
        let known = PlaceStay(
            placeKey: "office",
            displayName: "회사",
            floor: 9,
            span: TimeSpan(
                start: base.addingTimeInterval(-8 * hour),
                end: base.addingTimeInterval(-7 * hour)
            ),
            confidence: .high,
            isConfirmed: true
        )
        let altitudes: [Double] = [0, 0.1, 3.0, 3.1, 3.1]
        let readings = altitudes.enumerated().map { index, altitude in
            SensorReading(
                timestamp: base.addingTimeInterval(
                    Double(index) * 5 * 60
                ),
                relativeAltitudeMeters: altitude,
                pressureKilopascals: 101.3 - altitude * 0.012,
                altimeterSessionID: sessionID
            )
        }

        let result = FloorTimelineEngine().apply(
            readings: readings,
            to: [detected],
            knownPlaces: [known]
        )

        XCTAssertEqual(result.places.map(\.floor), [9, 10])
        XCTAssertEqual(result.transitions.count, 1)
        XCTAssertEqual(result.transitions.first?.fromFloor, 9)
        XCTAssertEqual(result.transitions.first?.toFloor, 10)
        XCTAssertTrue(
            result.transitions.first?.evidence.contains(
                "기압 고도 센서"
            ) == true
        )
        XCTAssertTrue(
            MovementRouteBuilder().build(
                stays: result.places,
                readings: readings
            ).isEmpty
        )
    }

    func testFrequentPlaceFloorAnchorsSameBuildingAndDetectsFloorMove() {
        let base = makeDate(2026, 8, 1, 9)
        let sessionID = UUID()
        let anchor = GeoPoint(
            latitude: 37.5000,
            longitude: 127.0000,
            altitude: 60,
            horizontalAccuracy: 6,
            verticalAccuracy: 5
        )
        let frequent = FrequentPlace(
            kind: .company,
            name: "회사",
            point: anchor,
            floor: 9,
            referenceRelativeAltitudeMeters: 0,
            referencePressureKilopascals: 100.5,
            referenceAltimeterSessionID: sessionID,
            floorCapturedAt: base
        )
        let span = TimeSpan(
            start: base,
            end: base.addingTimeInterval(30 * 60)
        )
        let detected = PlaceStay(
            placeKey: "gps-cluster-1",
            displayName: "자동 감지 장소",
            span: span,
            confidence: .medium,
            point: GeoPoint(
                latitude: 37.5002,
                longitude: 127.0001,
                altitude: 60,
                horizontalAccuracy: 12,
                verticalAccuracy: 8
            )
        )
        let altitudes: [Double] = [0, 0.1, 3.0, 3.1, 3.1]
        let readings = altitudes.enumerated().map { index, altitude in
            SensorReading(
                timestamp: base.addingTimeInterval(
                    Double(index) * 5 * 60
                ),
                point: anchor,
                relativeAltitudeMeters: altitude,
                pressureKilopascals: 100.5 - altitude * 0.012,
                altimeterSessionID: sessionID
            )
        }

        let resolved = FrequentPlaceResolutionEngine().applying(
            [frequent],
            to: [detected],
            readings: readings
        )
        let result = FloorTimelineEngine().apply(
            readings: readings,
            to: resolved,
            knownPlaces: []
        )

        XCTAssertEqual(resolved.first?.placeKey, frequent.stablePlaceKey)
        XCTAssertEqual(resolved.first?.displayName, "회사")
        XCTAssertEqual(resolved.first?.floor, 9)
        XCTAssertEqual(result.places.map(\.floor), [9, 10])
        XCTAssertEqual(result.transitions.first?.fromFloor, 9)
        XCTAssertEqual(result.transitions.first?.toFloor, 10)
        XCTAssertTrue(
            MovementRouteBuilder().build(
                stays: result.places,
                readings: readings
            ).isEmpty
        )
    }

    func testFrequentPlaceLocationCanBeClearedWithoutDeletingPlace() {
        let base = makeDate(2026, 8, 1, 9)
        var place = FrequentPlace(kind: .home)
        place.setLocation(
            from: SensorReading(
                timestamp: base,
                point: GeoPoint(
                    latitude: 37.5,
                    longitude: 127,
                    altitude: 60,
                    horizontalAccuracy: 6,
                    verticalAccuracy: 5
                ),
                relativeAltitudeMeters: 1.2,
                pressureKilopascals: 100.4,
                altimeterSessionID: UUID()
            ),
            floor: 20
        )

        XCTAssertNotNil(place.floorCalibration)
        place.clearLocation()

        XCTAssertEqual(place.kind, .home)
        XCTAssertNil(place.point)
        XCTAssertNil(place.floor)
        XCTAssertNil(place.floorCalibration)
    }

    func testFrequentPlaceFloorHeightPersistsAndFeedsCalibration() throws {
        let base = makeDate(2026, 8, 1, 9)
        let place = FrequentPlace(
            kind: .company,
            name: "사무실",
            point: GeoPoint(
                latitude: 37.5,
                longitude: 127,
                altitude: 60,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            ),
            floor: 10,
            referenceRelativeAltitudeMeters: 0,
            floorCapturedAt: base,
            floorHeightMeters: 4.2
        )

        let data = try JSONEncoder().encode(place)
        let decoded = try JSONDecoder().decode(FrequentPlace.self, from: data)

        XCTAssertEqual(decoded.floorHeightMeters, 4.2, accuracy: 0.001)
        XCTAssertEqual(
            decoded.floorCalibration?.floorHeightMeters ?? 0,
            4.2,
            accuracy: 0.001
        )
    }

    func testFrequentPlaceAutomaticRecordingHonorsDwellAndToggle() {
        let base = makeDate(2026, 8, 1, 9)
        let anchor = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 60,
            horizontalAccuracy: 5,
            verticalAccuracy: 5
        )
        let shortStay = PlaceStay(
            placeKey: "gps-short",
            displayName: "자동 감지 장소",
            span: TimeSpan(
                start: base,
                end: base.addingTimeInterval(5 * 60)
            ),
            confidence: .medium,
            point: anchor
        )
        let longStay = PlaceStay(
            placeKey: "gps-long",
            displayName: "자동 감지 장소",
            span: TimeSpan(
                start: base,
                end: base.addingTimeInterval(15 * 60)
            ),
            confidence: .medium,
            point: anchor
        )
        let place = FrequentPlace(
            kind: .company,
            name: "회사",
            point: anchor,
            floor: 10,
            minimumDwellMinutes: 10
        )

        let shortResolved = FrequentPlaceResolutionEngine().applying(
            [place],
            to: [shortStay],
            readings: []
        )
        let longResolved = FrequentPlaceResolutionEngine().applying(
            [place],
            to: [longStay],
            readings: []
        )
        var disabled = place
        disabled.isAutomaticRecordingEnabled = false
        let disabledResolved = FrequentPlaceResolutionEngine().applying(
            [disabled],
            to: [longStay],
            readings: []
        )

        XCTAssertEqual(shortResolved.first?.displayName, "자동 감지 장소")
        XCTAssertEqual(longResolved.first?.displayName, "회사")
        XCTAssertEqual(disabledResolved.first?.displayName, "자동 감지 장소")
    }

    func testSleepAnalysisBuildsOneSessionWithoutDoubleCountingOverlaps() {
        let base = makeDate(2026, 7, 30, 22, 0)
        let segments = [
            SleepSegment(
                stage: .inBed,
                span: TimeSpan(start: base, end: base.addingTimeInterval(8.5 * hour)),
                sourceName: "iPhone"
            ),
            SleepSegment(
                stage: .core,
                span: TimeSpan(
                    start: base.addingTimeInterval(0.5 * hour),
                    end: base.addingTimeInterval(3 * hour)
                ),
                sourceName: "Apple Watch"
            ),
            SleepSegment(
                stage: .deep,
                span: TimeSpan(
                    start: base.addingTimeInterval(3 * hour),
                    end: base.addingTimeInterval(4 * hour)
                ),
                sourceName: "Apple Watch"
            ),
            SleepSegment(
                stage: .core,
                span: TimeSpan(
                    start: base.addingTimeInterval(4 * hour),
                    end: base.addingTimeInterval(6 * hour)
                ),
                sourceName: "Apple Watch"
            ),
            SleepSegment(
                stage: .rem,
                span: TimeSpan(
                    start: base.addingTimeInterval(6 * hour),
                    end: base.addingTimeInterval(7 * hour)
                ),
                sourceName: "Apple Watch"
            ),
            SleepSegment(
                stage: .awake,
                span: TimeSpan(
                    start: base.addingTimeInterval(7 * hour),
                    end: base.addingTimeInterval(7.25 * hour)
                ),
                sourceName: "Apple Watch"
            ),
            SleepSegment(
                stage: .rem,
                span: TimeSpan(
                    start: base.addingTimeInterval(7.25 * hour),
                    end: base.addingTimeInterval(8 * hour)
                ),
                sourceName: "Apple Watch"
            ),
            SleepSegment(
                stage: .asleepUnspecified,
                span: TimeSpan(
                    start: base.addingTimeInterval(0.5 * hour),
                    end: base.addingTimeInterval(8 * hour)
                ),
                sourceName: "iPhone"
            )
        ]

        let sessions = SleepAnalysisEngine().sessions(from: segments)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].asleepDuration, 7.25 * hour)
        XCTAssertEqual(sessions[0].awakeDuration, 0.25 * hour)
        XCTAssertEqual(sessions[0].inBedDuration, 8.5 * hour)
        XCTAssertEqual(sessions[0].stageDurations[.deep], hour)
        XCTAssertEqual(sessions[0].sourceNames, ["iPhone", "Apple Watch"])
        XCTAssertEqual(
            sessions[0].sleepEfficiency ?? 0,
            7.25 / 8.5,
            accuracy: 0.0001
        )
    }

    func testSleepAnalysisSeparatesNapFromNightSleep() {
        let base = makeDate(2026, 7, 30, 1, 0)
        let segments = [
            SleepSegment(
                stage: .core,
                span: TimeSpan(start: base, end: base.addingTimeInterval(6 * hour)),
                sourceName: "Apple Watch"
            ),
            SleepSegment(
                stage: .asleepUnspecified,
                span: TimeSpan(
                    start: base.addingTimeInterval(12 * hour),
                    end: base.addingTimeInterval(13 * hour)
                ),
                sourceName: "iPhone"
            )
        ]
        XCTAssertEqual(
            SleepAnalysisEngine().sessions(from: segments).count,
            2
        )
    }

    func testSensorArchivePersistsMotionAndPrunesOldReadings() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("taption-sensors-\(UUID().uuidString)")
        let fileURL = directory.appendingPathComponent("readings.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }

        let archive = SensorReadingArchive(
            fileURL: fileURL,
            retentionInterval: 86_400
        )
        let now = makeDate(2026, 7, 30, 12, 0)
        let motion = DeviceMotionSnapshot(
            gravity: SensorVector3(x: 0, y: 0, z: -1),
            userAcceleration: SensorVector3(x: 0.1, y: 0, z: 0),
            rotationRate: SensorVector3(x: 0, y: 0.2, z: 0),
            attitudeRadians: SensorVector3(x: 0, y: 0, z: 1)
        )
        try await archive.append(
            SensorReading(
                timestamp: now.addingTimeInterval(-2 * 86_400),
                motion: .walking,
                stepCount: 100
            ),
            now: now
        )
        try await archive.append(
            SensorReading(
                timestamp: now,
                motion: .running,
                stepCount: 220,
                deviceMotion: motion
            ),
            now: now
        )
        try await archive.compact(now: now)

        let restored = try await archive.readings(
            in: TimeSpan(
                start: now.addingTimeInterval(-3 * 86_400),
                end: now.addingTimeInterval(hour)
            )
        )
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].motion, .running)
        XCTAssertEqual(restored[0].stepCount, 220)
        XCTAssertEqual(restored[0].deviceMotion, motion)
    }

    func testRawDeviceDataArchiveStoresMonthlyCompressedPayloads() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("taption-raw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let archive = RawDeviceDataMonthlyArchive(rootDirectory: directory)
        let july = makeDate(2026, 7, 31, 5, 42)
        let august = makeDate(2026, 8, 1, 0, 5)
        let reading = SensorReading(
            timestamp: july,
            point: GeoPoint(
                latitude: 37.524,
                longitude: 126.673,
                altitude: 42,
                horizontalAccuracy: 9,
                verticalAccuracy: 12
            ),
            motion: .automotive,
            stepCount: 33
        )
        try archive.append(
            source: .gps,
            kind: "sensor-reading",
            payload: reading,
            capturedAt: july
        )
        let watchPayload = RawArchiveWatchFixture(sampleCount: 12, mode: "car")
        try archive.append(
            source: .appleWatch,
            kind: "watch-sensor-summary",
            payload: watchPayload,
            capturedAt: august
        )

        let julyValues = try archive.envelopes(inMonthContaining: july)
        let augustValues = try archive.envelopes(inMonthContaining: august)
        XCTAssertEqual(julyValues.count, 1)
        XCTAssertEqual(julyValues[0].source, .gps)
        XCTAssertEqual(julyValues[0].kind, "sensor-reading")
        XCTAssertTrue(julyValues[0].payloadJSON.contains("\"automotive\""))
        XCTAssertEqual(augustValues.count, 1)
        XCTAssertEqual(augustValues[0].source, .appleWatch)
        try archive.flushPendingWrites()
        let chunks = directory
            .appendingPathComponent("2026-08")
            .appendingPathComponent("chunks")
        let chunkFiles = try FileManager.default.contentsOfDirectory(
            at: chunks,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(chunkFiles.contains { $0.pathExtension == "zlib" })
    }

    func testRawDeviceDataArchiveDoesNotRewriteLegacyMonthlyFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("taption-raw-legacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let monthDirectory = directory.appendingPathComponent("2026-08")
        try FileManager.default.createDirectory(
            at: monthDirectory,
            withIntermediateDirectories: true
        )
        let date = makeDate(2026, 8, 1, 12)
        let legacyEnvelope = try RawDeviceDataEnvelope(
            capturedAt: date,
            source: .gps,
            kind: "legacy",
            payload: RawArchiveWatchFixture(sampleCount: 1, mode: "walk")
        )
        var legacyPayload = try RawDeviceDataMonthlyArchive
            .payloadEncoder()
            .encode(legacyEnvelope)
        legacyPayload.append(0x0A)
        let legacyData = try (legacyPayload as NSData).compressed(
            using: .zlib
        ) as Data
        let legacyURL = monthDirectory.appendingPathComponent(
            "taption-raw-2026-08.jsonl.zlib"
        )
        try legacyData.write(to: legacyURL)

        let archive = RawDeviceDataMonthlyArchive(
            rootDirectory: directory,
            flushDelay: 3_600
        )
        try archive.append(
            source: .healthKit,
            kind: "new",
            payload: RawArchiveWatchFixture(sampleCount: 2, mode: "run"),
            capturedAt: date.addingTimeInterval(60)
        )
        try archive.flushPendingWrites()

        XCTAssertEqual(try Data(contentsOf: legacyURL), legacyData)
        XCTAssertEqual(
            try archive.envelopes(inMonthContaining: date).map(\.kind),
            ["legacy", "new"]
        )
    }

    func testTrackingSessionArchiveWritesIndependentCompressedChunks() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("taption-session-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = TrackingSessionChunkArchive(rootDirectory: directory)
        let sessionID = UUID()
        let start = makeDate(2026, 8, 1, 9, 0)
        try archive.append(
            SensorReading(
                timestamp: start,
                motion: .walking,
                trackingSessionID: sessionID,
                trackingKind: .walking,
                sourceDevice: .iPhone,
                sequence: 1
            )
        )
        try archive.append(
            SensorReading(
                timestamp: start.addingTimeInterval(12),
                motion: .walking,
                trackingSessionID: sessionID,
                trackingKind: .walking,
                sourceDevice: .iPhone,
                sequence: 2,
                trackingSessionEnded: true
            )
        )
        let file = directory
            .appendingPathComponent("2026-08")
            .appendingPathComponent(sessionID.uuidString)
            .appendingPathComponent("000001.jsonl.zlib")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let compressed = try Data(contentsOf: file)
        let payload = try (compressed as NSData).decompressed(using: .zlib) as Data
        XCTAssertEqual(payload.split(separator: 0x0A).count, 2)
    }

    func testSensorCollectionProfilesUseRequestedIntervalsAndPowerPolicy() {
        XCTAssertEqual(
            SensorCollectionProfile.batterySaver.interval,
            15 * 60
        )
        XCTAssertEqual(
            SensorCollectionProfile.balanced.interval,
            5 * 60
        )
        XCTAssertEqual(
            SensorCollectionProfile.accuracy.interval,
            60
        )
        XCTAssertEqual(
            SensorCollectionProfile.batterySaver.samplingWindowDuration,
            8
        )
        XCTAssertEqual(
            SensorCollectionProfile.balanced.samplingWindowDuration,
            10
        )
        XCTAssertEqual(
            SensorCollectionProfile.accuracy.samplingWindowDuration,
            12
        )

        let batterySaver = SensorCollectionConfiguration.configured(
            for: .batterySaver,
            allowsBackgroundLocation: false
        )
        XCTAssertFalse(batterySaver.highAccuracyDuringMovement)
        XCTAssertFalse(batterySaver.collectsDeviceMotion)
        XCTAssertEqual(batterySaver.minimumEmissionInterval, 15 * 60)

        let accuracy = SensorCollectionConfiguration.configured(
            for: .accuracy,
            allowsBackgroundLocation: true
        )
        XCTAssertTrue(accuracy.highAccuracyDuringMovement)
        XCTAssertTrue(accuracy.collectsDeviceMotion)
        XCTAssertTrue(accuracy.allowsBackgroundLocation)
        XCTAssertEqual(accuracy.minimumEmissionInterval, 60)
        XCTAssertEqual(
            AppFeatureSettings.defaults.sensorCollectionProfile,
            .balanced
        )
        let balanced = SensorCollectionConfiguration.configured(
            for: .balanced,
            allowsBackgroundLocation: true
        )
        XCTAssertTrue(balanced.collectsDeviceMotion)
        XCTAssertEqual(balanced.minimumEmissionInterval, 5 * 60)
    }

    func testWatchCollectionAndDataSyncProfilesAreIndependent() throws {
        XCTAssertEqual(
            TaptionWatchAccelerationProfile.batterySaver.interval,
            15 * 60
        )
        XCTAssertEqual(
            TaptionWatchAccelerationProfile.accuracy.interval,
            60
        )
        XCTAssertEqual(
            TaptionWatchDataSyncProfile.balanced.interval,
            5 * 60
        )
        XCTAssertNil(TaptionWatchDataSyncProfile.off.intervalMinutes)

        let settings = TaptionWatchAccelerationSettings(
            profile: .accuracy,
            samplingWindowSeconds: 90
        )
        XCTAssertEqual(settings.samplingWindowSeconds, 60)
        XCTAssertTrue(settings.isEnabled)

        let data = try JSONEncoder().encode(
            TaptionWatchPayload(
                generatedAt: .now,
                viewportStart: .now,
                viewportEnd: .now,
                items: [],
                catStyle: "calico",
                reducesMotion: false,
                accelerationSettings: settings,
                dataSyncProfile: .batterySaver
            )
        )
        let decoded = try JSONDecoder().decode(
            TaptionWatchPayload.self,
            from: data
        )
        XCTAssertEqual(decoded.accelerationSettings, settings)
        XCTAssertEqual(decoded.dataSyncProfile, .batterySaver)
    }

    func testAutomaticTrackingPromotionAndStopPolicy() {
        XCTAssertFalse(
            TrackingSessionPolicy.shouldAutomaticallyStart(
                motion: .walking,
                confidence: .medium,
                sustainedFor: 9.9
            )
        )
        XCTAssertTrue(
            TrackingSessionPolicy.shouldAutomaticallyStart(
                motion: .walking,
                confidence: .medium,
                sustainedFor: 10
            )
        )
        XCTAssertTrue(
            TrackingSessionPolicy.shouldAutomaticallyStart(
                motion: .running,
                confidence: .high,
                sustainedFor: 15
            )
        )
        XCTAssertFalse(
            TrackingSessionPolicy.shouldAutomaticallyStart(
                motion: .automotive,
                confidence: .high,
                sustainedFor: 30
            )
        )
        XCTAssertFalse(
            TrackingSessionPolicy.shouldAutomaticallyStop(
                motion: .stationary,
                stationaryFor: 119
            )
        )
        XCTAssertTrue(
            TrackingSessionPolicy.shouldAutomaticallyStop(
                motion: .stationary,
                stationaryFor: 120
            )
        )
        XCTAssertEqual(TrackingSessionPolicy.activeDistanceFilterMeters, 5)
        XCTAssertEqual(TrackingSessionPolicy.activeHorizontalAccuracyLimit, 50)
    }

    func testHealthRefreshUsesFiveMinuteForegroundAndImmediateBackgroundPolicy() {
        XCTAssertEqual(
            HealthRefreshPolicy.foregroundInterval,
            5 * 60
        )
        XCTAssertEqual(
            HealthRefreshPolicy.periodicLookback,
            2 * 86_400
        )
        XCTAssertEqual(
            HealthRefreshPolicy.backgroundFrequency,
            .immediate
        )
    }

    func testAppleDeviceMotionHistoryOverridesAppSensorEstimate() {
        let base = makeDate(2026, 7, 30, 9, 0)
        let readings = [
            SensorReading(
                timestamp: base.addingTimeInterval(10 * 60),
                motion: .unknown,
                motionConfidence: .low
            ),
            SensorReading(
                timestamp: base.addingTimeInterval(70 * 60),
                motion: .walking,
                motionConfidence: .low
            ),
        ]
        let activities = [
            MotionActivityRecord(
                span: TimeSpan(
                    start: base,
                    end: base.addingTimeInterval(30 * 60)
                ),
                motion: .running,
                confidence: .high
            ),
        ]

        let result = AppleDeviceGroundTruthEngine.applyingMotionHistory(
            to: readings,
            activities: activities
        )

        XCTAssertEqual(result[0].motion, .running)
        XCTAssertEqual(result[0].motionConfidence, .high)
        XCTAssertEqual(result[1].motion, .walking)
    }

    func testAppleDeviceMotionFillsMovementMissingFromGPS() {
        let base = makeDate(2026, 7, 30, 9, 0)
        let walking = MotionActivityRecord(
            span: TimeSpan(
                start: base,
                end: base.addingTimeInterval(20 * 60)
            ),
            motion: .walking,
            confidence: .high
        )
        let running = MotionActivityRecord(
            span: TimeSpan(
                start: base.addingTimeInterval(30 * 60),
                end: base.addingTimeInterval(40 * 60)
            ),
            motion: .running,
            confidence: .medium
        )
        let pedometer = PedometerSummary(
            span: TimeSpan(
                start: base,
                end: base.addingTimeInterval(hour)
            ),
            stepCount: 3_000,
            distanceMeters: 3_000,
            floorsAscended: 1,
            floorsDescended: 0,
            averageActivePaceSecondsPerMeter: nil
        )

        let result = AppleDeviceGroundTruthEngine.mergingTravel(
            gpsSegments: [],
            motionActivities: [walking, running],
            pedometer: pedometer
        )

        XCTAssertEqual(result.map(\.mode), [.walking, .running])
        XCTAssertEqual(
            result.reduce(0) { $0 + $1.distanceMeters },
            3_000,
            accuracy: 0.001
        )
        XCTAssertTrue(
            result.allSatisfy {
                $0.evidence.contains("iPhone Core Motion 기록")
            }
        )
    }

    func testAppleDeviceGPSMovementWinsOverMotionFallback() {
        let base = makeDate(2026, 7, 30, 9, 0)
        let gps = TravelSegment(
            mode: .subway,
            span: TimeSpan(
                start: base,
                end: base.addingTimeInterval(30 * 60)
            ),
            distanceMeters: 8_000,
            confidence: .high,
            evidence: ["GPS"]
        )
        let automotive = MotionActivityRecord(
            span: TimeSpan(
                start: base.addingTimeInterval(10 * 60),
                end: base.addingTimeInterval(25 * 60)
            ),
            motion: .automotive,
            confidence: .high
        )

        let result = AppleDeviceGroundTruthEngine.mergingTravel(
            gpsSegments: [gps],
            motionActivities: [automotive],
            pedometer: nil
        )

        XCTAssertEqual(result, [gps])
    }

    func testHealthKitRefreshReplacesOnlyHealthKitGroundTruthWindow() {
        let base = makeDate(2026, 7, 30, 9, 0)
        let span = TimeSpan(
            start: base,
            end: base.addingTimeInterval(24 * hour)
        )
        let manual = ActualRecord(
            planID: nil,
            title: "직접 기록",
            categoryID: "exercise",
            startedAt: base,
            endedAt: base.addingTimeInterval(hour),
            source: .manual
        )
        let staleHealth = ActualRecord(
            planID: nil,
            title: "이전 Watch 기록",
            categoryID: "exercise",
            startedAt: base.addingTimeInterval(2 * hour),
            endedAt: base.addingTimeInterval(3 * hour),
            source: .healthKit
        )
        let freshHealth = ActualRecord(
            planID: nil,
            title: "새 Watch 기록",
            categoryID: "exercise",
            startedAt: base.addingTimeInterval(4 * hour),
            endedAt: base.addingTimeInterval(5 * hour),
            source: .healthKit
        )

        let result = AppleDeviceGroundTruthEngine
            .replacingHealthKitActuals(
                existing: [manual, staleHealth],
                with: [freshHealth, freshHealth],
                inside: span
            )

        XCTAssertTrue(result.contains(manual))
        XCTAssertFalse(result.contains(staleHealth))
        XCTAssertEqual(
            result.filter { $0.source == .healthKit },
            [freshHealth]
        )
    }

    func testLinkedWatchWorkoutSupersedesItsTimerActual() {
        let base = makeDate(2026, 7, 30, 9, 0)
        let planID = UUID()
        let timer = ActualRecord(
            planID: planID,
            title: "아침 달리기",
            categoryID: "exercise",
            startedAt: base,
            endedAt: base.addingTimeInterval(30 * 60),
            source: .timer
        )
        let otherTimer = ActualRecord(
            planID: UUID(),
            title: "다른 계획",
            categoryID: "project",
            startedAt: base,
            endedAt: base.addingTimeInterval(30 * 60),
            source: .timer
        )
        let watchWorkout = ActualRecord(
            planID: planID,
            title: "아침 달리기",
            categoryID: "exercise",
            startedAt: base.addingTimeInterval(20),
            endedAt: base.addingTimeInterval(31 * 60),
            source: .healthKit
        )

        let result = AppleDeviceGroundTruthEngine.replacingHealthKitActuals(
            existing: [timer, otherTimer],
            with: [watchWorkout],
            inside: TimeSpan(
                start: base.addingTimeInterval(-60),
                end: base.addingTimeInterval(60 * 60)
            )
        )

        XCTAssertFalse(result.contains(timer))
        XCTAssertTrue(result.contains(otherTimer))
        XCTAssertTrue(result.contains(watchWorkout))
    }

    func testWatchPayloadAndCommandRoundTrip() throws {
        let planID = UUID()
        let command = TaptionWatchCommand(
            planID: planID,
            kind: .postponeThirtyMinutes
        )
        let commandData = try JSONEncoder().encode(command)
        XCTAssertEqual(
            try JSONDecoder().decode(
                TaptionWatchCommand.self,
                from: commandData
            ),
            command
        )

        let base = makeDate(2026, 7, 30, 9, 0)
        let payload = TaptionWatchPayload(
            generatedAt: base,
            viewportStart: base,
            viewportEnd: base.addingTimeInterval(24 * hour),
            items: [
                TaptionWatchPlanItem(
                    id: planID,
                    title: "워치 연동",
                    categoryID: "project",
                    startsAt: base,
                    endsAt: base.addingTimeInterval(hour),
                    status: PlanStatus.planned.rawValue,
                    actualStartedAt: nil,
                    categoryName: "프로젝트",
                    categoryHex: "#5C81B1"
                )
            ],
            catStyle: CatStyle.calico.rawValue,
            reducesMotion: false,
            todaySummary: TaptionWatchDaySummary(
                date: base,
                scheduledCount: 3,
                completedCount: 1,
                recordedMinutes: 95,
                activeMinutes: 40
            )
        )
        let payloadData = try JSONEncoder().encode(payload)
        XCTAssertEqual(
            try JSONDecoder().decode(
                TaptionWatchPayload.self,
                from: payloadData
            ),
            payload
        )
    }

    func testWatchLiveItemPolicyDropsPastItemsAndKeepsParallelCurrentItems() {
        let now = makeDate(2026, 8, 1, 10, 0)
        let past = TaptionWatchPlanItem(
            id: UUID(),
            title: "지난 계획",
            categoryID: "project",
            startsAt: now.addingTimeInterval(-2 * hour),
            endsAt: now.addingTimeInterval(-hour),
            status: PlanStatus.planned.rawValue,
            actualStartedAt: nil,
            categoryName: "프로젝트",
            categoryHex: "#5C81B1"
        )
        let goal = TaptionWatchPlanItem(
            id: UUID(),
            title: "목표: 운동",
            categoryID: "exercise",
            startsAt: now.addingTimeInterval(-30 * 60),
            endsAt: now.addingTimeInterval(90 * 60),
            status: PlanStatus.planned.rawValue,
            actualStartedAt: nil,
            categoryName: "운동",
            categoryHex: "#4E8E63",
            isGoal: true
        )
        let plan = TaptionWatchPlanItem(
            id: UUID(),
            title: "달리기",
            categoryID: "exercise",
            startsAt: now,
            endsAt: now.addingTimeInterval(30 * 60),
            status: PlanStatus.running.rawValue,
            actualStartedAt: now,
            categoryName: "운동",
            categoryHex: "#4E8E63",
            parentID: goal.id
        )
        let completed = TaptionWatchPlanItem(
            id: UUID(),
            title: "완료된 계획",
            categoryID: "project",
            startsAt: now.addingTimeInterval(-15 * 60),
            endsAt: now.addingTimeInterval(15 * 60),
            status: PlanStatus.completed.rawValue,
            actualStartedAt: nil,
            categoryName: "프로젝트",
            categoryHex: "#5C81B1"
        )
        let upcoming = TaptionWatchPlanItem(
            id: UUID(),
            title: "다음 계획",
            categoryID: "project",
            startsAt: now.addingTimeInterval(2 * hour),
            endsAt: now.addingTimeInterval(3 * hour),
            status: PlanStatus.planned.rawValue,
            actualStartedAt: nil,
            categoryName: "프로젝트",
            categoryHex: "#5C81B1"
        )

        let items = [past, goal, plan, completed, upcoming]
        XCTAssertEqual(
            TaptionWatchLiveItemPolicy.current(items, at: now).map(\.id),
            [goal.id, plan.id]
        )
        XCTAssertEqual(
            TaptionWatchLiveItemPolicy.upcoming(items, at: now).map(\.id),
            [upcoming.id]
        )
        XCTAssertFalse(TaptionWatchLiveItemPolicy.isLive(past, at: now))
        XCTAssertFalse(
            TaptionWatchLiveItemPolicy.isLive(completed, at: now)
        )
    }

    func testWatchPlanItemDecodesPayloadWithoutNewGoalFields() throws {
        let id = UUID()
        let base = makeDate(2026, 8, 1, 10)
        let legacy: [String: Any] = [
            "id": id.uuidString,
            "title": "기존 워치 계획",
            "categoryID": "project",
            "startsAt": base.timeIntervalSince1970,
            "endsAt": base.addingTimeInterval(hour).timeIntervalSince1970,
            "status": PlanStatus.planned.rawValue,
            "categoryName": "프로젝트",
            "categoryHex": "#5C81B1"
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let item = try decoder.decode(TaptionWatchPlanItem.self, from: data)
        XCTAssertFalse(item.isGoal)
        XCTAssertNil(item.parentID)
        XCTAssertEqual(item.id, id)
    }

    func testWatchDaySummaryMergesOverlappingActuals() {
        let base = makeDate(2026, 7, 30, 9)
        let plans = [
            PlanRecord(
                title: "완료한 계획",
                span: TimeSpan(
                    start: base,
                    end: base.addingTimeInterval(hour)
                ),
                categoryID: "project",
                status: .completed
            ),
            PlanRecord(
                title: "다음 계획",
                span: TimeSpan(
                    start: base.addingTimeInterval(2 * hour),
                    end: base.addingTimeInterval(3 * hour)
                ),
                categoryID: "study"
            ),
            PlanRecord(
                title: "건너뛴 계획",
                span: TimeSpan(
                    start: base,
                    end: base.addingTimeInterval(hour)
                ),
                categoryID: "hobby",
                status: .skipped
            ),
        ]
        let actuals = [
            ActualRecord(
                planID: nil,
                title: "걷기",
                categoryID: "movement",
                startedAt: base,
                endedAt: base.addingTimeInterval(hour),
                source: .appleWatch
            ),
            ActualRecord(
                planID: nil,
                title: "운동",
                categoryID: "exercise",
                startedAt: base.addingTimeInterval(30 * 60),
                endedAt: base.addingTimeInterval(90 * 60),
                source: .healthKit
            ),
            ActualRecord(
                planID: nil,
                title: "업무",
                categoryID: "project",
                startedAt: base.addingTimeInterval(3 * hour),
                endedAt: base.addingTimeInterval(4 * hour),
                source: .timer
            ),
        ]

        let summary = TaptionWatchDaySummaryFactory.make(
            plans: plans,
            actuals: actuals,
            at: base.addingTimeInterval(6 * hour),
            calendar: utcCalendar
        )

        XCTAssertEqual(summary.scheduledCount, 2)
        XCTAssertEqual(summary.completedCount, 1)
        XCTAssertEqual(summary.recordedMinutes, 150)
        XCTAssertEqual(summary.activeMinutes, 90)
    }

    func testWatchSensorSummaryRoundTripCreatesOneActivityAndHealthReplacesIt()
        throws {
        let base = makeDate(2026, 7, 30, 9, 0)
        let plan = PlanRecord(
            title: "출근 달리기",
            span: TimeSpan(
                start: base,
                end: base.addingTimeInterval(30 * 60)
            ),
            categoryID: "exercise"
        )
        let summary = TaptionWatchSensorSummary(
            sessionID: UUID(),
            sequence: 2,
            workoutKind: .running,
            linkedPlanID: plan.id,
            linkedPlanTitle: plan.title,
            linkedCategoryID: plan.categoryID,
            startedAt: base,
            endedAt: base.addingTimeInterval(30 * 60),
            isFinal: true,
            accelerometerSampleCount: 18_000,
            accelerometerAverageG: TaptionWatchSensorVector3(
                x: 0.1,
                y: -0.2,
                z: 0.9
            ),
            peakAccelerationG: 2.4,
            gyroscopeSampleCount: 18_000,
            gyroscopeAverageRadiansPerSecond: TaptionWatchSensorVector3(
                x: 0.2,
                y: 0.1,
                z: -0.1
            ),
            peakRotationRateRadiansPerSecond: 3.1,
            gravity: TaptionWatchSensorVector3(x: 0, y: 0, z: -1),
            userAccelerationG: TaptionWatchSensorVector3(
                x: 0.1,
                y: 0.2,
                z: 0.3
            ),
            rotationRateRadiansPerSecond: TaptionWatchSensorVector3(
                x: 0.2,
                y: 0.3,
                z: 0.4
            ),
            attitudeRadians: TaptionWatchSensorVector3(
                x: 0.3,
                y: 0.4,
                z: 0.5
            ),
            relativeAltitudeMeters: 8.4,
            pressureKilopascals: 100.8,
            stepCount: 3_210,
            distanceMeters: 4_800,
            floorsAscended: 2,
            floorsDescended: 1,
            latestHeartRate: 154,
            averageHeartRate: 146,
            maximumHeartRate: 171,
            activeEnergyKilocalories: 280
        )

        let encoded = try JSONEncoder().encode(summary)
        XCTAssertEqual(
            try JSONDecoder().decode(
                TaptionWatchSensorSummary.self,
                from: encoded
            ),
            summary
        )

        let watchActuals = AppleWatchSensorActivityEngine.upserting(
            summary,
            into: [],
            linkedPlan: plan
        )
        let repeated = AppleWatchSensorActivityEngine.upserting(
            summary,
            into: watchActuals,
            linkedPlan: plan
        )
        XCTAssertEqual(repeated.count, 1)
        XCTAssertEqual(repeated[0].id, summary.sessionID)
        XCTAssertEqual(repeated[0].source, .appleWatch)
        XCTAssertEqual(repeated[0].planID, plan.id)

        let healthActual = ActualRecord(
            id: summary.sessionID,
            planID: plan.id,
            title: plan.title,
            categoryID: plan.categoryID,
            startedAt: summary.startedAt,
            endedAt: summary.endedAt,
            source: .healthKit
        )
        let reconciled = AppleDeviceGroundTruthEngine
            .replacingHealthKitActuals(
                existing: repeated,
                with: [healthActual],
                inside: TimeSpan(
                    start: base.addingTimeInterval(-60),
                    end: base.addingTimeInterval(hour)
                )
            )
        XCTAssertEqual(reconciled, [healthActual])
    }

    func testWatchBehaviorRulesPrioritizeWorkoutAndDetectStairs() {
        let workout = WatchBehaviorClassifier.classify(
            WatchBehaviorInput(
                workoutKind: .running,
                duration: 30,
                steps: 20
            )
        )
        XCTAssertEqual(workout.kind, .running)
        XCTAssertGreaterThan(workout.confidenceScore, 0.9)
        XCTAssertTrue(workout.evidence.contains("Apple Watch 운동 종류"))

        let stairs = WatchBehaviorClassifier.classify(
            WatchBehaviorInput(
                duration: 120,
                accelerometerSampleCount: 3_000,
                accelerometerStandardDeviationG: 0.12,
                accelerometerMeanJerkGPerSecond: 0.3,
                steps: 140,
                floorsAscended: 3,
                altitudeDeltaMeters: 9
            )
        )
        XCTAssertEqual(stairs.kind, .stairsUp)
        XCTAssertTrue(stairs.evidence.contains("걸음·층수 증가"))
    }

    func testWatchHARWindowExtractsPeriodicWalkingFeatures() throws {
        let start = makeDate(2026, 8, 2, 9)
        let samples = (0..<65).map { index in
            let elapsed = Double(index) / 25
            let wave = sin(2 * .pi * 1.8 * elapsed) * 0.14
            return WatchMotionSample(
                capturedAt: start.addingTimeInterval(elapsed),
                acceleration: TaptionWatchSensorVector3(
                    x: 0,
                    y: 0,
                    z: 1 + wave
                ),
                rotationRate: TaptionWatchSensorVector3(x: 0.2, y: 0, z: 0),
                gravity: TaptionWatchSensorVector3(x: 0, y: 0, z: 1)
            )
        }
        let features = try XCTUnwrap(
            WatchBehaviorWindowAnalyzer.features(from: samples)
        )
        XCTAssertGreaterThan(features.bodyAccelerationRMSG, 0.05)
        XCTAssertGreaterThan(features.dominantFrequencyHz ?? 0, 1.2)
        XCTAssertLessThan(features.dominantFrequencyHz ?? 0, 4.2)

        let inference = WatchBehaviorClassifier.classifyWindow(
            features,
            context: WatchBehaviorInput(
                duration: features.duration,
                accelerometerSampleCount: features.sampleCount,
                steps: 3,
                gpsAvailable: false
            )
        )
        XCTAssertEqual(inference.kind, .walking)
        XCTAssertTrue(inference.evidence.contains("IMU 보행 주기"))
        XCTAssertEqual(inference.modelVersion, WatchBehaviorClassifier.rulesVersion)
    }

    func testWatchHARWindowDistinguishesFineHandBehaviors() {
        let typing = WatchBehaviorClassifier.classify(
            WatchBehaviorInput(
                duration: 2.56,
                accelerometerSampleCount: 64,
                steps: 0,
                accelerationBodyRMSG: 0.06,
                accelerationZeroCrossingRateHz: 0.8,
                gyroscopeRMSG: 0.3
            )
        )
        XCTAssertEqual(typing.kind, .typing)

        let brushing = WatchBehaviorClassifier.classify(
            WatchBehaviorInput(
                duration: 2.56,
                accelerometerSampleCount: 64,
                steps: 0,
                accelerationBodyRMSG: 0.08,
                gyroscopeRMSG: 1.8
            )
        )
        XCTAssertEqual(brushing.kind, .brushingTeeth)
    }

    func testWatchHARWindowRefinesBroadWorkoutWithoutLosingFallback() throws {
        let start = makeDate(2026, 8, 2, 9)
        let samples = (0..<65).map { index in
            let elapsed = Double(index) / 25
            let wave = sin(2 * .pi * 1.8 * elapsed) * 0.14
            return WatchMotionSample(
                capturedAt: start.addingTimeInterval(elapsed),
                acceleration: TaptionWatchSensorVector3(
                    x: 0,
                    y: 0,
                    z: 1 + wave
                ),
                rotationRate: nil,
                gravity: TaptionWatchSensorVector3(x: 0, y: 0, z: 1)
            )
        }
        let features = try XCTUnwrap(
            WatchBehaviorWindowAnalyzer.features(from: samples)
        )
        let refined = WatchBehaviorClassifier.classifyWindow(
            features,
            context: WatchBehaviorInput(
                workoutKind: .walking,
                duration: features.duration,
                steps: 3
            )
        )
        XCTAssertEqual(refined.kind, .walking)

        let fallback = WatchBehaviorClassifier.classifyWindow(
            WatchBehaviorWindowFeatures(
                startedAt: start,
                endedAt: start.addingTimeInterval(2.56),
                sampleCount: 64,
                sampleRateHz: 25,
                accelerationMeanG: 1,
                accelerationStandardDeviationG: 0,
                bodyAccelerationRMSG: 0,
                jerkRMSGPerSecond: 0,
                zeroCrossingRateHz: 0,
                dominantFrequencyHz: nil,
                gyroscopeRMSGPerSecond: 0,
                posturePitchRadians: 0,
                postureRollRadians: 0
            ),
            context: WatchBehaviorInput(
                workoutKind: .cycling,
                duration: 2.56
            )
        )
        XCTAssertEqual(fallback.kind, .cycling)
    }

    func testWatchHARFeatureVectorAndTemporalAggregation() throws {
        let start = makeDate(2026, 8, 2, 9)
        let samples = (0..<65).map { index in
            let elapsed = Double(index) / 25
            let wave = sin(2 * .pi * 1.8 * elapsed) * 0.14
            return WatchMotionSample(
                capturedAt: start.addingTimeInterval(elapsed),
                acceleration: TaptionWatchSensorVector3(
                    x: 0,
                    y: 0,
                    z: 1 + wave
                ),
                rotationRate: nil,
                gravity: TaptionWatchSensorVector3(x: 0, y: 0, z: 1)
            )
        }
        let features = try XCTUnwrap(
            WatchBehaviorWindowAnalyzer.features(from: samples)
        )
        XCTAssertEqual(
            features.featureVector.count,
            12
        )
        XCTAssertEqual(
            WatchBehaviorWindowFeatures.featureSchemaVersion,
            "watch-har-window-v1"
        )
        XCTAssertEqual(
            WatchBehaviorKind.fromModelLabel("달리기"),
            .running
        )
        XCTAssertEqual(
            WatchBehaviorKind.fromModelLabel("stairsUp"),
            .stairsUp
        )

        let walking = WatchBehaviorSegment(
            startedAt: start,
            endedAt: start.addingTimeInterval(10),
            behavior: .walking,
            confidenceScore: 0.8,
            evidence: ["보행"],
            modelVersion: WatchBehaviorClassifier.rulesVersion
        )
        let stationary = WatchBehaviorSegment(
            startedAt: start.addingTimeInterval(10),
            endedAt: start.addingTimeInterval(18),
            behavior: .stationary,
            confidenceScore: 0.95,
            evidence: ["저진동"],
            modelVersion: WatchBehaviorClassifier.rulesVersion
        )
        let aggregate = WatchBehaviorClassifier.aggregate(
            [walking, stationary],
            fallback: WatchBehaviorInference(
                kind: .unknown,
                confidenceScore: 0.2,
                evidence: [],
                modelVersion: WatchBehaviorClassifier.rulesVersion
            )
        )
        XCTAssertEqual(aggregate.kind, .walking)
        XCTAssertTrue(aggregate.evidence.contains("시간 가중 집계"))
    }

    func testWatchSensorChunksUpdateTheSameImmutableActivity() {
        let base = makeDate(2026, 8, 2, 9)
        let sessionID = UUID()
        let first = TaptionWatchSensorSummary(
            sessionID: sessionID,
            sequence: 1,
            workoutKind: .walking,
            linkedPlanID: nil,
            linkedPlanTitle: nil,
            linkedCategoryID: nil,
            startedAt: base,
            endedAt: base.addingTimeInterval(30),
            isFinal: false,
            accelerometerSampleCount: 750,
            accelerometerAverageG: nil,
            peakAccelerationG: 0.9,
            gyroscopeSampleCount: 0,
            gyroscopeAverageRadiansPerSecond: nil,
            peakRotationRateRadiansPerSecond: nil,
            gravity: nil,
            userAccelerationG: nil,
            rotationRateRadiansPerSecond: nil,
            attitudeRadians: nil,
            relativeAltitudeMeters: nil,
            pressureKilopascals: nil,
            stepCount: 40,
            distanceMeters: 30,
            floorsAscended: nil,
            floorsDescended: nil,
            latestHeartRate: 90,
            averageHeartRate: 88,
            maximumHeartRate: 95,
            activeEnergyKilocalories: 4,
            behavior: .walking,
            behaviorConfidenceScore: 0.8,
            behaviorEvidence: ["걸음"],
            behaviorModelVersion: WatchBehaviorClassifier.rulesVersion
        )
        let second = TaptionWatchSensorSummary(
            sessionID: sessionID,
            sequence: 2,
            workoutKind: .walking,
            linkedPlanID: nil,
            linkedPlanTitle: nil,
            linkedCategoryID: nil,
            startedAt: base,
            endedAt: base.addingTimeInterval(90),
            isFinal: true,
            accelerometerSampleCount: 2_250,
            accelerometerAverageG: nil,
            peakAccelerationG: 1.1,
            gyroscopeSampleCount: 0,
            gyroscopeAverageRadiansPerSecond: nil,
            peakRotationRateRadiansPerSecond: nil,
            gravity: nil,
            userAccelerationG: nil,
            rotationRateRadiansPerSecond: nil,
            attitudeRadians: nil,
            relativeAltitudeMeters: nil,
            pressureKilopascals: nil,
            stepCount: 130,
            distanceMeters: 100,
            floorsAscended: nil,
            floorsDescended: nil,
            latestHeartRate: 98,
            averageHeartRate: 92,
            maximumHeartRate: 105,
            activeEnergyKilocalories: 14,
            behavior: .walking,
            behaviorConfidenceScore: 0.9,
            behaviorEvidence: ["걸음"],
            behaviorModelVersion: WatchBehaviorClassifier.rulesVersion
        )
        let firstActual = AppleWatchSensorActivityEngine.upserting(
            first,
            into: [],
            linkedPlan: nil
        )
        let finalActual = AppleWatchSensorActivityEngine.upserting(
            second,
            into: firstActual,
            linkedPlan: nil
        )
        XCTAssertEqual(finalActual.count, 1)
        XCTAssertEqual(finalActual[0].endedAt, second.endedAt)
        XCTAssertEqual(finalActual[0].behavior, WatchBehaviorKind.walking.rawValue)
        XCTAssertEqual(finalActual[0].modelVersion, WatchBehaviorClassifier.rulesVersion)
    }

    func testAmbientWatchMotionAtHomeCreatesHouseworkRecord() {
        let base = makeDate(2026, 8, 2, 14)
        let sessionID = UUID()
        let first = TaptionWatchSensorSummary(
            sessionID: sessionID,
            sequence: 1,
            workoutKind: .walking,
            linkedPlanID: nil,
            linkedPlanTitle: nil,
            linkedCategoryID: nil,
            startedAt: base,
            endedAt: base.addingTimeInterval(30),
            isFinal: false,
            accelerometerSampleCount: 150,
            accelerometerAverageG: nil,
            peakAccelerationG: 1.2,
            accelerometerStandardDeviationG: 0.08,
            accelerometerMeanJerkGPerSecond: 0.2,
            gyroscopeSampleCount: 0,
            gyroscopeAverageRadiansPerSecond: nil,
            peakRotationRateRadiansPerSecond: nil,
            gravity: nil,
            userAccelerationG: nil,
            rotationRateRadiansPerSecond: nil,
            attitudeRadians: nil,
            relativeAltitudeMeters: nil,
            pressureKilopascals: nil,
            stepCount: nil,
            distanceMeters: nil,
            floorsAscended: nil,
            floorsDescended: nil,
            latestHeartRate: nil,
            averageHeartRate: nil,
            maximumHeartRate: nil,
            activeEnergyKilocalories: nil,
            behavior: .stationary,
            behaviorConfidenceScore: 0.7,
            behaviorEvidence: ["지속 움직임"],
            behaviorModelVersion: WatchBehaviorClassifier.rulesVersion,
            isAmbient: true
        )
        var second = first
        second.sequence = 2
        second.endedAt = base.addingTimeInterval(60)

        let firstActuals = AppleWatchSensorActivityEngine.upserting(
            first,
            into: [],
            linkedPlan: nil,
            atHome: true
        )
        let finalActuals = AppleWatchSensorActivityEngine.upserting(
            second,
            into: firstActuals,
            linkedPlan: nil,
            atHome: true
        )

        XCTAssertEqual(finalActuals.count, 1)
        XCTAssertEqual(finalActuals[0].title, "집안일")
        XCTAssertEqual(finalActuals[0].behavior, WatchBehaviorKind.housework.rawValue)
        XCTAssertEqual(finalActuals[0].endedAt, second.endedAt)

        let outsideHome = AppleWatchSensorActivityEngine.upserting(
            second,
            into: [],
            linkedPlan: nil,
            atHome: false
        )
        XCTAssertTrue(outsideHome.isEmpty)
    }

    func testPlaceDetectionRequiresLongStay() {
        let base = makeDate(2026, 7, 30)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127.0,
            altitude: 30,
            horizontalAccuracy: 10,
            verticalAccuracy: 5
        )
        let readings = [
            SensorReading(timestamp: base, point: point, motion: .stationary),
            SensorReading(
                timestamp: base.addingTimeInterval(20 * 60),
                point: point,
                motion: .stationary
            )
        ]
        XCTAssertEqual(
            PlaceDetectionEngine().detectStays(readings: readings).count,
            1
        )
    }

    func testWalkingLocationEngineAddsConfirmedGPSLocations() {
        let base = makeDate(2026, 7, 30, 18)
        let sessionID = UUID()
        let readings = [
            SensorReading(
                timestamp: base,
                point: GeoPoint(
                    latitude: 37.5,
                    longitude: 127,
                    altitude: 30,
                    horizontalAccuracy: 8,
                    verticalAccuracy: 5
                ),
                motion: .walking,
                trackingSessionID: sessionID,
                trackingKind: .walking,
                sourceDevice: .iPhone
            ),
            SensorReading(
                timestamp: base.addingTimeInterval(45),
                point: GeoPoint(
                    latitude: 37.5002,
                    longitude: 127.0002,
                    altitude: 30,
                    horizontalAccuracy: 8,
                    verticalAccuracy: 5
                ),
                motion: .walking,
                trackingSessionID: sessionID,
                trackingKind: .walking,
                sourceDevice: .iPhone
            ),
            SensorReading(
                timestamp: base.addingTimeInterval(90),
                point: GeoPoint(
                    latitude: 37.5004,
                    longitude: 127.0004,
                    altitude: 30,
                    horizontalAccuracy: 8,
                    verticalAccuracy: 5
                ),
                motion: .walking,
                trackingSessionID: sessionID,
                trackingKind: .walking,
                sourceDevice: .iPhone
            )
        ]

        let locations = WalkingLocationEngine().build(readings: readings)

        XCTAssertEqual(locations.count, 1)
        XCTAssertEqual(locations.first?.displayName, "확인된 위치")
        XCTAssertTrue(locations.first?.isConfirmed == true)
        XCTAssertTrue(locations.first?.isWalkingLocation == true)
        XCTAssertEqual(locations.first?.span.duration ?? 0, 90, accuracy: 0.001)
    }

    func testWalkingLocationEngineIgnoresInaccurateAndNonWalkingGPS() {
        let base = makeDate(2026, 7, 30, 18)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 30,
            horizontalAccuracy: 80,
            verticalAccuracy: 5
        )
        let readings = [
            SensorReading(
                timestamp: base,
                point: point,
                motion: .walking,
                trackingKind: .walking
            ),
            SensorReading(
                timestamp: base.addingTimeInterval(60),
                point: point,
                motion: .stationary,
                trackingKind: .automatic
            )
        ]

        XCTAssertTrue(WalkingLocationEngine().build(readings: readings).isEmpty)
    }

    func testTimelineRouteUsesSameClockCoordinates() {
        let base = makeDate(2026, 7, 30)
        let viewport = TimelineViewport(
            dayStart: base,
            visibleSpan: 10 * hour,
            horizontalOffset: 6 * hour,
            currentTime: base.addingTimeInterval(8 * hour)
        )
        XCTAssertEqual(
            TimelineCoordinateMapper.fraction(
                for: base.addingTimeInterval(8 * hour),
                in: viewport
            ),
            0.2,
            accuracy: 0.0001
        )
    }

    func testWidgetSnapshotAndCatMotion() {
        let base = makeDate(2026, 7, 30, 12, 0)
        let plan = PlanRecord(
            title: "현재 계획",
            span: TimeSpan(
                start: base.addingTimeInterval(-hour),
                end: base.addingTimeInterval(hour)
            ),
            categoryID: "project"
        )
        let snapshot = WidgetSnapshotFactory.make(
            plans: [plan],
            now: base,
            catStyle: .calico,
            hideSensitiveContent: true
        )
        XCTAssertTrue(snapshot.catIsRunning)
        XCTAssertTrue(snapshot.availableActions.isEmpty)
        XCTAssertEqual(
            CatMotionPolicy.resolve(
                style: .white,
                hasCurrentActivity: true,
                reduceMotion: true
            ).animationDuration,
            0
        )
    }

    func testWidgetPlaybackAlwaysKeepsAutomaticLanes() {
        let base = makeDate(2026, 8, 1, 12, 0)

        XCTAssertEqual(
            TaptionWidgetPlaybackEngine.lanes(
                for: [],
                at: base
            ),
            [.schedule, .location, .movement, .sleep, .activity, .appUsage]
        )

        let action = TaptionWidgetItem(
            id: UUID(),
            title: "여행 준비",
            categoryID: "travel",
            startsAt: base.addingTimeInterval(-30 * 60),
            endsAt: base.addingTimeInterval(30 * 60),
            status: "planned",
            isFixed: false,
            lane: .action
        )
        XCTAssertEqual(
            TaptionWidgetPlaybackEngine.lanes(
                for: [action],
                at: base
            ),
            [.schedule, .location, .movement, .sleep, .activity, .appUsage, .action]
        )
        XCTAssertEqual(
            TaptionWidgetPlaybackEngine.activeItems(
                in: .action,
                from: [action],
                at: base
            ),
            [action]
        )
    }

    func testWidgetPayloadIsAlwaysCurrentCenteredAtSixHours() {
        let now = makeDate(2026, 8, 1, 18, 0)
        let payload = TaptionWidgetPayloadFactory.make(
            from: .empty,
            now: now
        )

        XCTAssertEqual(payload.displayCenterDate, now)
        XCTAssertEqual(
            payload.displayDuration,
            TaptionWidgetPlaybackEngine.defaultWindowDuration
        )
        XCTAssertEqual(
            payload.displayResolutionLabel,
            TaptionWidgetPlaybackEngine.defaultResolutionLabel
        )
        XCTAssertEqual(payload.displayDuration, 6 * hour)
        XCTAssertEqual(
            payload.sourceFingerprint,
            TaptionWidgetSyncFingerprint.make(items: payload.items)
        )

        let oldOffice = TaptionWidgetItem(
            id: UUID(),
            title: "회사",
            categoryID: "location",
            startsAt: now.addingTimeInterval(-6 * hour),
            endsAt: now.addingTimeInterval(-4 * hour),
            status: "recorded",
            isFixed: true,
            lane: .location
        )
        let currentHome = TaptionWidgetItem(
            id: UUID(),
            title: "집",
            categoryID: "location",
            startsAt: now.addingTimeInterval(-hour),
            endsAt: now.addingTimeInterval(hour),
            status: "recorded",
            isFixed: true,
            lane: .location
        )
        let oldMovement = TaptionWidgetItem(
            id: UUID(),
            title: "자가용",
            categoryID: "movement",
            startsAt: now.addingTimeInterval(-5 * hour),
            endsAt: now.addingTimeInterval(-4 * hour),
            status: "recorded",
            isFixed: true,
            lane: .movement
        )

        XCTAssertEqual(
            TaptionWidgetPlaybackEngine.visibleItems(
                in: .location,
                from: [oldOffice, currentHome, oldMovement],
                at: now
            ).map(\.title),
            ["집"]
        )
        XCTAssertTrue(
            TaptionWidgetPlaybackEngine.visibleItems(
                in: .movement,
                from: [oldOffice, currentHome, oldMovement],
                at: now
            ).isEmpty
        )
    }

    func testWidgetAutomotiveActualUsesMovementLaneAndAutomobileTitle() {
        let now = makeDate(2026, 8, 1, 18, 0)
        var snapshot = TaptionDataSnapshot.empty
        snapshot.actuals = [
            ActualRecord(
                planID: nil,
                title: "차량 탑승",
                categoryID: "movement",
                startedAt: now.addingTimeInterval(-10 * 60),
                endedAt: now,
                source: .motion,
                behavior: MotionKind.automotive.rawValue
            ),
        ]

        let payload = TaptionWidgetPayloadFactory.make(from: snapshot, now: now)

        XCTAssertEqual(
            payload.items.filter { $0.resolvedLane == .movement }.map(\.title),
            ["자동차"]
        )
        XCTAssertFalse(payload.items.contains { $0.resolvedLane == .activity })
    }

    func testWidgetFingerprintStaysStableWhileHealthActivityIsOpen() {
        let startedAt = makeDate(2026, 8, 1, 18, 0)
        var snapshot = TaptionDataSnapshot.empty
        snapshot.updatedAt = startedAt
        snapshot.actuals = [
            ActualRecord(
                planID: nil,
                title: "걷기",
                categoryID: "walking",
                startedAt: startedAt.addingTimeInterval(-10 * 60),
                source: .healthKit
            ),
        ]

        let first = TaptionWidgetPayloadFactory.make(
            from: snapshot,
            now: startedAt
        )
        let later = TaptionWidgetPayloadFactory.make(
            from: snapshot,
            now: startedAt.addingTimeInterval(5 * 60)
        )

        XCTAssertEqual(first.sourceFingerprint, later.sourceFingerprint)
        XCTAssertEqual(
            TaptionWidgetSyncStatus.compare(
                groundTruth: later,
                cached: first
            ),
            .synchronized(first.generatedAt)
        )

        var savedLater = later
        savedLater.sourceSnapshotUpdatedAt = startedAt.addingTimeInterval(1)
        XCTAssertEqual(
            TaptionWidgetSyncStatus.compare(
                groundTruth: savedLater,
                cached: first
            ),
            .pending
        )
    }

    func testWidgetRejectsNewerLegacyCacheWithoutGroundTruthFingerprint() {
        let now = makeDate(2026, 8, 1, 18, 0)
        var groundTruth = TaptionWidgetPayloadFactory.make(
            from: .empty,
            now: now
        )
        groundTruth.sourceFingerprint = "ground-truth"
        var legacyCache = groundTruth
        legacyCache.generatedAt = now.addingTimeInterval(60)
        legacyCache.sourceFingerprint = nil
        legacyCache.items = [
            TaptionWidgetItem(
                id: UUID(),
                title: "회사",
                categoryID: "location",
                startsAt: now.addingTimeInterval(-hour),
                endsAt: now.addingTimeInterval(hour),
                status: "recorded",
                isFixed: true,
                lane: .location
            )
        ]

        XCTAssertEqual(
            TaptionWidgetPayloadSyncPolicy.freshest(
                groundTruth: groundTruth,
                cached: legacyCache
            ),
            groundTruth
        )

        var staleCache = groundTruth
        staleCache.generatedAt = now.addingTimeInterval(120)
        staleCache.sourceSnapshotUpdatedAt = now.addingTimeInterval(-hour)
        groundTruth.sourceSnapshotUpdatedAt = now
        XCTAssertEqual(
            TaptionWidgetPayloadSyncPolicy.freshest(
                groundTruth: groundTruth,
                cached: staleCache
            ),
            groundTruth
        )
    }

    func testWidgetGroundTruthWinsWhenFingerprintsDifferAtSameSourceRevision() {
        let now = makeDate(2026, 8, 1, 18, 0)
        var groundTruth = TaptionWidgetPayload.empty
        groundTruth.generatedAt = now
        groundTruth.sourceSnapshotUpdatedAt = now
        groundTruth.sourceFingerprint = "app-ground-truth"
        groundTruth.items = [
            TaptionWidgetItem(
                id: UUID(),
                title: "집",
                categoryID: "location",
                startsAt: now.addingTimeInterval(-hour),
                endsAt: now.addingTimeInterval(hour),
                status: "recorded",
                isFixed: true,
                lane: .location
            ),
        ]
        var cached = groundTruth
        cached.generatedAt = now.addingTimeInterval(60)
        cached.sourceFingerprint = "stale-cache"
        cached.items = []

        XCTAssertEqual(
            TaptionWidgetPayloadSyncPolicy.selectionReason(
                groundTruth: groundTruth,
                cached: cached
            ),
            .groundTruth
        )
        XCTAssertEqual(
            TaptionWidgetPayloadSyncPolicy.freshest(
                groundTruth: groundTruth,
                cached: cached
            ).items.map(\.title),
            ["집"]
        )
    }

    func testWidgetPayloadDecodesLegacyCacheWithoutSyncMetadata() throws {
        let payload = TaptionWidgetPayloadFactory.make(
            from: .empty,
            now: makeDate(2026, 8, 1, 18, 0)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let encoded = try encoder.encode(payload)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "sourceSnapshotUpdatedAt")
        object.removeValue(forKey: "sourceFingerprint")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(
            TaptionWidgetPayload.self,
            from: legacyData
        )

        XCTAssertNil(decoded.sourceSnapshotUpdatedAt)
        XCTAssertNil(decoded.sourceFingerprint)
    }

    func testWidgetAutomaticallyScrollsOverflowingRowsAndReturns() {
        let reference = Date(timeIntervalSinceReferenceDate: 0)

        XCTAssertEqual(
            TaptionWidgetAutoScrollEngine.progress(
                at: reference,
                rowCount: 4
            ),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            TaptionWidgetAutoScrollEngine.progress(
                at: reference.addingTimeInterval(2.5),
                rowCount: 5
            ),
            0.5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            TaptionWidgetAutoScrollEngine.offset(
                at: reference.addingTimeInterval(3.5),
                contentHeight: 100,
                viewportHeight: 80,
                rowCount: 5
            ),
            20,
            accuracy: 0.001
        )
        XCTAssertEqual(
            TaptionWidgetAutoScrollEngine.offset(
                at: reference.addingTimeInterval(3.5),
                contentHeight: 80,
                viewportHeight: 100,
                rowCount: 5
            ),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            TaptionWidgetAutoScrollEngine.progress(
                at: reference.addingTimeInterval(5.5),
                rowCount: 5
            ),
            0.5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            TaptionWidgetAutoScrollEngine.progress(
                at: reference.addingTimeInterval(60),
                rowCount: 5,
                reducesMotion: true
            ),
            1,
            accuracy: 0.001
        )
    }

    func testWidgetPlaybackUsesMinuteTicksAndExactItemBoundaries() {
        let base = makeDate(2026, 8, 1, 12, 0)
        let startsAt = base.addingTimeInterval(95)
        let endsAt = base.addingTimeInterval(185)
        let movement = TaptionWidgetItem(
            id: UUID(),
            title: "자가용",
            categoryID: "movement",
            startsAt: startsAt,
            endsAt: endsAt,
            status: "recorded",
            isFixed: true,
            lane: .movement
        )
        let dates = TaptionWidgetPlaybackEngine.timelineDates(
            for: [movement],
            from: base,
            horizon: base.addingTimeInterval(5 * 60)
        )

        XCTAssertTrue(dates.contains(base.addingTimeInterval(60)))
        XCTAssertTrue(dates.contains(startsAt))
        XCTAssertTrue(dates.contains(endsAt))
        XCTAssertEqual(dates, dates.sorted())
    }

    func testWidgetLocationUsesResolvedIPhonePlaceName() {
        XCTAssertEqual(
            TaptionWidgetContentPolicy.locationTitle(
                displayName: "집",
                floor: nil
            ),
            "집"
        )
        XCTAssertEqual(
            TaptionWidgetContentPolicy.locationTitle(
                displayName: "회사",
                floor: 10
            ),
            "회사 · 10층"
        )
        XCTAssertEqual(
            TaptionWidgetContentPolicy.locationTitle(
                displayName: "   ",
                floor: nil
            ),
            "위치 기록"
        )
    }

    func testWidgetCatWalksAcrossAndTurnsAround() {
        let reference = Date(timeIntervalSinceReferenceDate: 0)
        let step = TaptionWidgetCatWalkEngine.defaultStepDuration
        let start = TaptionWidgetCatWalkEngine.pose(at: reference)
        let farEdge = TaptionWidgetCatWalkEngine.pose(
            at: reference.addingTimeInterval((step * 9) + 0.01)
        )
        let turnedAtFarEdge = TaptionWidgetCatWalkEngine.pose(
            at: reference.addingTimeInterval((step * 10) + 0.01)
        )
        let returning = TaptionWidgetCatWalkEngine.pose(
            at: reference.addingTimeInterval((step * 12) + 0.01)
        )
        let nearEdge = TaptionWidgetCatWalkEngine.pose(
            at: reference.addingTimeInterval((step * 19) + 0.01)
        )
        let sittingAtNearEdge = TaptionWidgetCatWalkEngine.pose(
            at: reference.addingTimeInterval((step * 20) + 0.01),
            preferredAction: .sitting
        )
        let movingAfterActionHold = TaptionWidgetCatWalkEngine.pose(
            at: reference.addingTimeInterval((step * 24) + 0.01),
            preferredAction: .sitting
        )
        let farActionHold = TaptionWidgetCatWalkEngine.pose(
            at: reference.addingTimeInterval((step * 30) + 0.01),
            preferredAction: .sleeping
        )
        let looped = TaptionWidgetCatWalkEngine.pose(
            at: reference.addingTimeInterval(
                TaptionWidgetCatWalkEngine.sequenceDuration + 0.01
            )
        )

        XCTAssertEqual(TaptionWidgetCatWalkEngine.roundTripDuration, 10)
        XCTAssertEqual(TaptionWidgetCatWalkEngine.sequenceDuration, 20)
        XCTAssertEqual(start.progress, 0, accuracy: 0.001)
        XCTAssertFalse(start.facesLeft)
        XCTAssertTrue(start.isAtEndpoint)
        XCTAssertEqual(start.action, .walking)
        XCTAssertEqual(farEdge.progress, 1, accuracy: 0.001)
        XCTAssertFalse(farEdge.facesLeft)
        XCTAssertTrue(farEdge.isAtEndpoint)
        XCTAssertEqual(farEdge.action, .walking)
        XCTAssertEqual(turnedAtFarEdge.progress, 1, accuracy: 0.001)
        XCTAssertTrue(turnedAtFarEdge.facesLeft)
        XCTAssertTrue(turnedAtFarEdge.isAtEndpoint)
        XCTAssertEqual(turnedAtFarEdge.action, .startled)
        XCTAssertLessThan(returning.progress, 1)
        XCTAssertTrue(returning.facesLeft)
        XCTAssertFalse(returning.isAtEndpoint)
        XCTAssertEqual(returning.action, .running)
        XCTAssertEqual(nearEdge.progress, 0, accuracy: 0.001)
        XCTAssertTrue(nearEdge.facesLeft)
        XCTAssertTrue(nearEdge.isAtEndpoint)
        XCTAssertEqual(nearEdge.action, .running)
        XCTAssertEqual(sittingAtNearEdge.progress, 0, accuracy: 0.001)
        XCTAssertFalse(sittingAtNearEdge.facesLeft)
        XCTAssertTrue(sittingAtNearEdge.isAtEndpoint)
        XCTAssertEqual(sittingAtNearEdge.action, .sitting)
        XCTAssertGreaterThan(movingAfterActionHold.progress, 0)
        XCTAssertEqual(movingAfterActionHold.action, .walking)
        XCTAssertEqual(farActionHold.progress, 1, accuracy: 0.001)
        XCTAssertTrue(farActionHold.facesLeft)
        XCTAssertEqual(farActionHold.action, .sleeping)
        XCTAssertEqual(looped.progress, 0, accuracy: 0.001)
        XCTAssertFalse(looped.facesLeft)
        XCTAssertTrue(looped.isAtEndpoint)
        XCTAssertEqual(looped.action, .walking)
    }

    func testCatPickerPreviewIncludesAndAnimatesEveryWidgetAction() {
        let reference = Date(timeIntervalSinceReferenceDate: 0)
        let actions = TaptionWidgetCatAction.allCases

        XCTAssertEqual(actions.count, 9)
        XCTAssertEqual(Set(actions.map(\.previewTitle)).count, actions.count)
        XCTAssertTrue(actions.allSatisfy { !$0.previewSystemImage.isEmpty })

        let runningStart = TaptionWidgetCatPreviewEngine.pose(
            at: reference,
            action: .running
        )
        let runningEnd = TaptionWidgetCatPreviewEngine.pose(
            at: reference.addingTimeInterval(2),
            action: .running
        )
        let grooming = TaptionWidgetCatPreviewEngine.pose(
            at: reference.addingTimeInterval(0.2),
            action: .grooming
        )
        let reduced = TaptionWidgetCatPreviewEngine.pose(
            at: reference.addingTimeInterval(1.8),
            action: .fishingPlay,
            reducesMotion: true
        )

        XCTAssertEqual(runningStart.progress, 0, accuracy: 0.001)
        XCTAssertEqual(runningEnd.progress, 1, accuracy: 0.001)
        XCTAssertEqual(grooming.progress, 0.5, accuracy: 0.001)
        XCTAssertEqual(grooming.action, .grooming)
        XCTAssertNotEqual(grooming.headTiltDegrees, 0)
        XCTAssertEqual(reduced.progress, 0.5, accuracy: 0.001)
        XCTAssertEqual(reduced.action, .fishingPlay)
        XCTAssertEqual(reduced.tailSwing, 0, accuracy: 0.001)
        XCTAssertEqual(reduced.headTiltDegrees, 0, accuracy: 0.001)
    }

    func testCatFrameClocksSupportWatchSizedIntOverflowDates() {
        let currentEra = Date(timeIntervalSinceReferenceDate: 800_000_000)

        XCTAssertTrue(
            (0...3).contains(
                TaptionCatAnimationEngine.pose(at: currentEra).phase
            )
        )
        XCTAssertTrue(
            (0...3).contains(
                TaptionWidgetCatWalkEngine.pose(at: currentEra).legPhase
            )
        )
        XCTAssertTrue(
            (0...3).contains(
                TaptionWidgetCatPreviewEngine.pose(
                    at: currentEra,
                    action: .walking
                ).legPhase
            )
        )
    }

    func testWidgetCatActionMatchesCurrentActionItemCategoryAndTitle() {
        XCTAssertEqual(
            TaptionWidgetCatActionSelector.preferredAction(
                categoryID: "exercise",
                title: "근력 운동"
            ),
            .ballPlay
        )
        XCTAssertEqual(
            TaptionWidgetCatActionSelector.preferredAction(
                categoryID: "hobby",
                title: "기타 연습"
            ),
            .fishingPlay
        )
        XCTAssertEqual(
            TaptionWidgetCatActionSelector.preferredAction(
                categoryID: "routine",
                title: "저녁 식사"
            ),
            .eating
        )
        XCTAssertEqual(
            TaptionWidgetCatActionSelector.preferredAction(
                categoryID: "sleep",
                title: "낮잠"
            ),
            .sleeping
        )
        XCTAssertEqual(
            TaptionWidgetCatActionSelector.preferredAction(
                categoryID: "movement",
                title: "아침 산책"
            ),
            .walking
        )
        XCTAssertEqual(
            TaptionWidgetCatActionSelector.preferredAction(
                categoryID: "exercise",
                title: "러닝"
            ),
            .running
        )
        XCTAssertNil(
            TaptionWidgetCatActionSelector.preferredAction(
                categoryID: "custom-unknown",
                title: "사용자 항목"
            )
        )
    }

    func testJSONCSVAndRepositoryRoundTrip() async throws {
        let base = makeDate(2026, 7, 30)
        let plan = PlanRecord(
            title: "저장",
            span: TimeSpan(start: base, end: base.addingTimeInterval(hour)),
            categoryID: "project"
        )
        var snapshot = TaptionDataSnapshot.empty
        snapshot.updatedAt = base
        snapshot.categories = CategoryCatalog.builtIn
        snapshot.plans = [plan]

        let encoded = try SnapshotExporter.jsonData(snapshot)
        let decoded = try SnapshotExporter.decodeJSON(encoded)
        XCTAssertEqual(decoded.plans.first?.id, plan.id)
        XCTAssertEqual(decoded.plans.first?.title, plan.title)
        XCTAssertEqual(decoded.plans.first?.span, plan.span)
        XCTAssertTrue(
            String(decoding: SnapshotExporter.plansCSV(snapshot), as: UTF8.self)
                .contains("\"저장\"")
        )

        let repository = InMemoryPlanRepository()
        try await repository.save(snapshot)
        let restored = try await repository.load()
        XCTAssertEqual(restored.plans, [plan])
    }

    func testEncryptedFileRepositoryRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("taption-test-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("snapshot.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        var snapshot = TaptionDataSnapshot.empty
        snapshot.categories = CategoryCatalog.builtIn
        let repository = FilePlanRepository(fileURL: fileURL)
        try await repository.save(snapshot)
        let restored = try await repository.load()

        XCTAssertEqual(restored.categories.count, CategoryCatalog.builtIn.count)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testSnapshotCompressionRoundTripAndLegacyJSON() {
        let json = Data(repeating: 0x41, count: 32 * 1024)
        let stored = TaptionSnapshotCompression.encode(json)

        XCTAssertLessThan(stored.count, json.count)
        XCTAssertEqual(TaptionSnapshotCompression.decode(stored), json)

        let legacy = Data("{\"schemaVersion\":1}".utf8)
        XCTAssertEqual(TaptionSnapshotCompression.decode(legacy), legacy)
    }

    func testAppGroupRepositoryMigratesExistingDeviceSnapshotOnce() async throws {
        var existing = TaptionDataSnapshot.empty
        existing.updatedAt = makeDate(2026, 7, 31, 18)
        existing.categories = CategoryCatalog.builtIn
        existing.plans = [
            PlanRecord(
                title: "기존 계획",
                span: TimeSpan(
                    start: existing.updatedAt,
                    end: existing.updatedAt.addingTimeInterval(hour)
                ),
                categoryID: "project"
            )
        ]
        let primary = InMemoryPlanRepository()
        let legacy = InMemoryPlanRepository(snapshot: existing)
        let repository = MigratingPlanRepository(
            primary: primary,
            legacy: legacy
        )

        let loaded = try await repository.load()
        let shared = try await primary.load()

        XCTAssertEqual(loaded.plans.first?.title, "기존 계획")
        XCTAssertEqual(shared.plans, loaded.plans)
    }

    func testWidgetCommandMutatesSharedSnapshotWithoutOpeningApp() throws {
        let base = makeDate(2026, 7, 30, 9)
        let plan = PlanRecord(
            title: "집중 작업",
            span: TimeSpan(
                start: base,
                end: base.addingTimeInterval(hour)
            ),
            categoryID: "project"
        )
        var source = TaptionDataSnapshot.empty
        source.plans = [plan]

        let postponed = try TaptionWidgetCommandEngine.apply(
            TaptionWidgetCommand(
                planID: plan.id,
                kind: .postponeThirtyMinutes,
                requestedAt: base
            ),
            to: source
        )
        XCTAssertEqual(
            postponed.plans[0].span.start,
            base.addingTimeInterval(30 * 60)
        )
        XCTAssertEqual(
            postponed.plans[0].span.end,
            base.addingTimeInterval(90 * 60)
        )

        let completed = try TaptionWidgetCommandEngine.apply(
            TaptionWidgetCommand(
                planID: plan.id,
                kind: .complete,
                requestedAt: base.addingTimeInterval(45 * 60)
            ),
            to: source
        )
        XCTAssertEqual(completed.plans[0].status, .completed)
        XCTAssertEqual(completed.actuals.count, 1)
        XCTAssertEqual(
            completed.actuals[0].endedAt,
            base.addingTimeInterval(hour)
        )
    }

    func testWidgetDeepLinkParsesExactPlan() throws {
        let planID = UUID()
        let link = TaptionDeepLink(
            url: URL(
                string: "taptionplan://plan/\(planID.uuidString)"
            )!
        )

        XCTAssertEqual(link, .plan(planID))
        XCTAssertEqual(
            TaptionDeepLink(url: URL(string: "taptionplan://today")!),
            .today
        )
        XCTAssertEqual(
            TaptionDeepLink(url: URL(string: "taptionplan://cats")!),
            .catPicker
        )
    }

    func testPlanNotificationPolicyKeepsOnlyUpcomingPlansInOrder() {
        let now = makeDate(2026, 7, 30, 9)
        let past = PlanRecord(
            title: "지난 계획",
            span: TimeSpan(
                start: now.addingTimeInterval(-hour),
                end: now
            ),
            categoryID: "project"
        )
        let later = PlanRecord(
            title: "두 번째",
            span: TimeSpan(
                start: now.addingTimeInterval(2 * hour),
                end: now.addingTimeInterval(3 * hour)
            ),
            categoryID: "project"
        )
        let first = PlanRecord(
            title: "첫 번째",
            span: TimeSpan(
                start: now.addingTimeInterval(hour),
                end: now.addingTimeInterval(2 * hour)
            ),
            categoryID: "study"
        )
        var completed = later
        completed.id = UUID()
        completed.status = .completed

        let reminders = PlanNotificationPolicy.reminderPlans(
            from: [past, later, completed, first],
            now: now
        )

        XCTAssertEqual(reminders.map(\.id), [first.id, later.id])
        XCTAssertEqual(
            PlanNotificationScheduler.identifier(for: first.id),
            "plan-start-\(first.id.uuidString)"
        )
    }

    func testCommercePolicyUsesLifetimeNonConsumableEntitlement() {
        XCTAssertTrue(TaptionCommercePolicy.isLifetimeNonConsumable)
        XCTAssertTrue(
            TaptionCommercePolicy.grantsProAccess(
                productID: TaptionCommercePolicy.proProductID,
                revocationDate: nil
            )
        )
        XCTAssertFalse(
            TaptionCommercePolicy.grantsProAccess(
                productID: TaptionCommercePolicy.proProductID,
                revocationDate: .now
            )
        )
        XCTAssertFalse(
            TaptionCommercePolicy.grantsProAccess(
                productID: "com.example.other",
                revocationDate: nil
            )
        )
    }

    func testSettingsMigrationDefaultsNotificationToggleToOff() throws {
        let encoded = try JSONEncoder().encode(AppFeatureSettings.defaults)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        )
        object.removeValue(forKey: "notificationsEnabled")
        object.removeValue(forKey: "movementCorrections")
        object.removeValue(forKey: "suppressedActualIDs")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let migrated = try JSONDecoder().decode(
            AppFeatureSettings.self,
            from: legacyData
        )

        XCTAssertFalse(migrated.notificationsEnabled)
        XCTAssertTrue(migrated.movementCorrections.isEmpty)
        XCTAssertTrue(migrated.suppressedActualIDs.isEmpty)
        XCTAssertEqual(migrated.startScale, .day)
        XCTAssertEqual(
            migrated.permissions.count,
            PermissionFeature.allCases.count
        )
        XCTAssertEqual(migrated.timelineRowOrder, TimelineRowOrder.defaults)
    }

    func testTimelineRowOrderMovesRowsAndKeepsUnknownRowsStable() {
        let rows = ["calendar", "location", "movement", "sleep", "photo"]
        let saved = TimelineRowOrder.defaults

        XCTAssertEqual(
            TimelineRowOrder.ordered(
                rows,
                id: { $0 },
                savedIDs: saved
            ),
            rows
        )
        XCTAssertEqual(
            TimelineRowOrder.moved(
                rows,
                sourceID: "photo",
                targetID: "location",
                savedIDs: saved
            ),
            ["calendar", "photo", "location", "movement", "sleep"]
        )
        XCTAssertEqual(
            TimelineRowOrder.moved(
                rows,
                sourceID: "calendar",
                targetID: "movement",
                savedIDs: saved
            ),
            ["location", "calendar", "movement", "sleep", "photo"]
        )
    }

    func testDeletedActualRecordStaysSuppressedOnAutomaticRefresh() throws {
        let base = makeDate(2026, 8, 1, 9, 0)
        let deleted = ActualRecord(
            planID: UUID(),
            title: "여행 준비",
            categoryID: "travel",
            startedAt: base,
            endedAt: base.addingTimeInterval(hour),
            source: .timer
        )
        let remaining = ActualRecord(
            planID: nil,
            title: "걷기",
            categoryID: "exercise",
            startedAt: base.addingTimeInterval(2 * hour),
            endedAt: base.addingTimeInterval(3 * hour),
            source: .healthKit
        )

        let visible = ActualRecordSuppressionEngine.visibleRecords(
            from: [deleted, remaining, deleted],
            suppressedIDs: [deleted.id]
        )

        XCTAssertEqual(visible, [remaining])

        var settings = AppFeatureSettings.defaults
        settings.suppressedActualIDs = [deleted.id]
        let decoded = try JSONDecoder().decode(
            AppFeatureSettings.self,
            from: JSONEncoder().encode(settings)
        )
        XCTAssertEqual(decoded.suppressedActualIDs, [deleted.id])
    }

    func testCloudKitRequiresExactContainerEntitlement() {
        XCTAssertFalse(
            CloudKitEntitlementPolicy.canInitialize(
                containerIdentifier: "iCloud.com.taption.plan",
                embeddedProfileData: nil
            )
        )
        XCTAssertFalse(
            CloudKitEntitlementPolicy.canInitialize(
                containerIdentifier: "iCloud.com.taption.plan",
                embeddedProfileData: Data(
                    "iCloud.com.example.other".utf8
                )
            )
        )
        XCTAssertTrue(
            CloudKitEntitlementPolicy.canInitialize(
                containerIdentifier: "iCloud.com.taption.plan",
                embeddedProfileData: Data(
                    """
                    <key>com.apple.developer.icloud-container-identifiers</key>
                    <array><string>iCloud.com.taption.plan</string></array>
                    """.utf8
                )
            )
        )
    }

    func testActualIntervalMergeDoesNotDoubleCountOverlaps() {
        let start = makeDate(2026, 8, 3, 9)
        let spans = [
            TimeSpan(start: start, end: start.addingTimeInterval(60 * 60)),
            TimeSpan(
                start: start.addingTimeInterval(30 * 60),
                end: start.addingTimeInterval(90 * 60)
            ),
            TimeSpan(
                start: start.addingTimeInterval(3 * 60 * 60),
                end: start.addingTimeInterval(4 * 60 * 60)
            ),
        ]

        XCTAssertEqual(
            ActualIntervalMergeEngine.duration(of: spans),
            2.5 * hour,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ActualIntervalMergeEngine.union(spans).count,
            2
        )
    }

    func testAutomaticActualSpanStopsAtObservationTime() {
        let observedAt = makeDate(2026, 8, 3, 18)
        let actual = ActualRecord(
            planID: nil,
            title: "걷기",
            categoryID: "movement",
            startedAt: observedAt.addingTimeInterval(-hour),
            endedAt: observedAt.addingTimeInterval(hour),
            source: .motion
        )

        XCTAssertEqual(
            actual.span(asOf: observedAt).end,
            observedAt
        )
        XCTAssertEqual(
            actual.span(asOf: observedAt).duration,
            hour,
            accuracy: 0.001
        )
    }

    func testCloudKitProductionSchemaErrorIsHandledAsUnavailable() {
        let error = NSError(
            domain: "CKErrorDomain",
            code: 15,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Cannot create new type TaptionSnapshot in production schema"
            ]
        )
        XCTAssertTrue(
            CloudKitErrorPolicy.isProductionSchemaUnavailable(error)
        )
        XCTAssertFalse(
            CloudKitErrorPolicy.isProductionSchemaUnavailable(
                NSError(domain: "CKErrorDomain", code: 3)
            )
        )
    }

    func testOpenMeteoWeatherCodesUseKoreanConditionsAndDayNightSymbols() {
        let clearDay = OpenMeteoWeatherCodePresentation(
            code: 0,
            isDay: true
        )
        XCTAssertEqual(clearDay.condition, "맑음")
        XCTAssertEqual(clearDay.symbolName, "sun.max.fill")

        let clearNight = OpenMeteoWeatherCodePresentation(
            code: 0,
            isDay: false
        )
        XCTAssertEqual(clearNight.condition, "맑음")
        XCTAssertEqual(clearNight.symbolName, "moon.stars.fill")

        let heavyRain = OpenMeteoWeatherCodePresentation(
            code: 65,
            isDay: true
        )
        XCTAssertEqual(heavyRain.condition, "강한 비")
        XCTAssertEqual(heavyRain.symbolName, "cloud.heavyrain.fill")
    }

    func testWeatherFreshnessMetadataSurvivesRoundTrip() throws {
        let fetchedAt = makeDate(2026, 8, 1, 18)
        let context = WeatherContext(
            observedAt: fetchedAt,
            fetchedAt: fetchedAt,
            isStale: true,
            condition: "맑음",
            symbolName: "sun.max.fill",
            temperatureCelsius: 28
        )
        let decoded = try JSONDecoder().decode(
            WeatherContext.self,
            from: JSONEncoder().encode(context)
        )
        XCTAssertEqual(decoded.fetchedAt, fetchedAt)
        XCTAssertEqual(decoded.isStale, true)
    }

    func testWeatherTimelineMergesEqualValuesAndSplitsOnChange() {
        let start = makeDate(2026, 8, 1, 10)
        let first = WeatherContext(
            observedAt: start,
            condition: "맑음",
            symbolName: "sun.max.fill",
            temperatureCelsius: 26.1
        )
        let repeated = WeatherContext(
            observedAt: start.addingTimeInterval(60 * 60),
            condition: "맑음",
            symbolName: "cloud.sun.fill",
            temperatureCelsius: 26.4
        )
        let changed = WeatherContext(
            observedAt: start.addingTimeInterval(2 * 60 * 60),
            condition: "흐림",
            symbolName: "cloud.fill",
            temperatureCelsius: 26.4
        )

        let merged = WeatherTimelineEngine.coalesced([
            first,
            repeated,
            changed,
        ])

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].observedAt, start)
        XCTAssertEqual(
            merged[0].validUntil,
            changed.observedAt
        )
        XCTAssertEqual(
            merged[1].validUntil,
            changed.observedAt.addingTimeInterval(15 * 60)
        )
    }

    func testWeatherTimelineKeepsSameDisplayedWeatherContinuous() {
        let start = makeDate(2026, 8, 1, 10)
        let first = WeatherContext(
            observedAt: start,
            condition: "맑음",
            symbolName: "sun.max.fill",
            temperatureCelsius: 28,
            airQuality: AirQualityContext(
                pm10MicrogramsPerCubicMeter: 41,
                pm25MicrogramsPerCubicMeter: 21,
                observedAt: start,
                providerName: "에어코리아",
                isFallback: false
            )
        )
        let repeated = WeatherContext(
            observedAt: start.addingTimeInterval(60 * 60),
            condition: "맑음",
            symbolName: "sun.max.fill",
            temperatureCelsius: 28.4,
            airQuality: AirQualityContext(
                pm10MicrogramsPerCubicMeter: 63,
                pm25MicrogramsPerCubicMeter: 30,
                observedAt: start.addingTimeInterval(60 * 60),
                providerName: "Open-Meteo",
                isFallback: true
            )
        )

        let merged = WeatherTimelineEngine.coalesced([first, repeated])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].validUntil, repeated.observedAt.addingTimeInterval(15 * 60))
        XCTAssertEqual(merged[0].airQuality?.pm10MicrogramsPerCubicMeter, 63)
    }

    func testWidgetSyncStatusUsesGroundTruthFingerprint() {
        var groundTruth = TaptionWidgetPayload.empty
        groundTruth.sourceFingerprint = "ground-truth"
        var cached = groundTruth
        cached.generatedAt = .now
        XCTAssertEqual(
            TaptionWidgetSyncStatus.compare(
                groundTruth: groundTruth,
                cached: cached
            ),
            .synchronized(cached.generatedAt)
        )

        cached.sourceFingerprint = "old"
        XCTAssertEqual(
            TaptionWidgetSyncStatus.compare(
                groundTruth: groundTruth,
                cached: cached
            ),
            .pending
        )
        groundTruth.sourceFingerprint = nil
        XCTAssertEqual(
            TaptionWidgetSyncStatus.compare(
                groundTruth: groundTruth,
                cached: cached
            ),
            .unavailable
        )
    }

    func testDomesticAirQualityGradeBoundaries() {
        XCTAssertEqual(AirQualityGrade.pm10(30), .good)
        XCTAssertEqual(AirQualityGrade.pm10(31), .moderate)
        XCTAssertEqual(AirQualityGrade.pm10(80), .moderate)
        XCTAssertEqual(AirQualityGrade.pm10(81), .bad)
        XCTAssertEqual(AirQualityGrade.pm10(151), .veryBad)
        XCTAssertEqual(AirQualityGrade.pm25(15), .good)
        XCTAssertEqual(AirQualityGrade.pm25(16), .moderate)
        XCTAssertEqual(AirQualityGrade.pm25(36), .bad)
        XCTAssertEqual(AirQualityGrade.pm25(76), .veryBad)

        let context = AirQualityContext(
            pm10MicrogramsPerCubicMeter: 45,
            pm25MicrogramsPerCubicMeter: 80,
            observedAt: .now,
            providerName: "test",
            isFallback: false
        )
        XCTAssertEqual(context.overallGrade, .veryBad)
    }

    func testAirKoreaUsesNearestStationAndCachesContext() async throws {
        AirQualityURLProtocolStub.requestCount = 0
        AirQualityURLProtocolStub.handler = { request in
            let path = try XCTUnwrap(request.url?.path)
            let json: String
            if path.contains("getMsrstnList") {
                json = """
                {"response":{"body":{"items":[
                  {"stationName":"가까운역","dmX":"37.5001","dmY":"127.0001"},
                  {"stationName":"먼역","dmX":"35.1000","dmY":"129.0000"}
                ]}}}
                """
            } else {
                XCTAssertTrue(
                    request.url?.absoluteString.contains(
                        "stationName=%EA%B0%80%EA%B9%8C%EC%9A%B4%EC%97%AD"
                    ) == true
                )
                json = """
                {"response":{"body":{"items":[
                  {"dataTime":"2026-08-01 18:00","pm10Value":"42","pm25Value":"18"}
                ]}}}
                """
            }
            return (200, Data(json.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AirQualityURLProtocolStub.self]
        let service = AirQualityContextService(
            session: URLSession(configuration: configuration),
            serviceKey: "local-test-key"
        )
        let first = try await service.context(
            latitude: 37.5,
            longitude: 127,
            at: makeDate(2026, 8, 1, 18)
        )
        let second = try await service.context(
            latitude: 37.5002,
            longitude: 127.0002,
            at: first.observedAt.addingTimeInterval(10 * 60)
        )
        XCTAssertEqual(first.stationName, "가까운역")
        XCTAssertEqual(first.providerName, "에어코리아")
        XCTAssertFalse(first.isFallback)
        XCTAssertEqual(first.pm10MicrogramsPerCubicMeter, 42)
        XCTAssertEqual(first.pm25MicrogramsPerCubicMeter, 18)
        XCTAssertEqual(second, first)
        XCTAssertEqual(AirQualityURLProtocolStub.requestCount, 2)
    }

    func testAirQualityFallsBackToOpenMeteoWithoutKey() async throws {
        AirQualityURLProtocolStub.requestCount = 0
        AirQualityURLProtocolStub.handler = { request in
            XCTAssertTrue(
                request.url?.host?.contains("open-meteo.com") == true
            )
            return (
                200,
                Data("{\"current\":{\"pm10\":21.5,\"pm2_5\":8.25}}".utf8)
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AirQualityURLProtocolStub.self]
        let service = AirQualityContextService(
            session: URLSession(configuration: configuration),
            serviceKey: nil
        )
        let context = try await service.context(
            latitude: 37.5,
            longitude: 127
        )
        XCTAssertTrue(context.isFallback)
        XCTAssertEqual(context.providerName, "Open-Meteo")
        XCTAssertEqual(context.pm10MicrogramsPerCubicMeter, 21.5)
        XCTAssertEqual(context.pm25MicrogramsPerCubicMeter, 8.25)
        XCTAssertEqual(AirQualityURLProtocolStub.requestCount, 1)
    }

    func testGoalDetailBranchesAndDeduplicatesOverlappingTime() {
        let start = makeDate(2026, 8, 1, 9)
        let repeatGoal = PlanRecord(
            title: "수면",
            span: TimeSpan(start: start, end: start.addingTimeInterval(30 * 86_400)),
            categoryID: "sleep",
            repeatRules: [
                GoalRepeatRule(
                    weekdays: [2, 3, 4, 5, 6],
                    startMinuteOfDay: 23 * 60,
                    endMinuteOfDay: 6 * 60 + 30
                ),
            ]
        )
        XCTAssertEqual(
            GoalDetailEngine.make(
                goal: repeatGoal,
                plans: [repeatGoal],
                actuals: [],
                referenceDate: start,
                calendar: utcCalendar
            ).mode,
            .habit
        )

        let projectGoal = PlanRecord(
            title: "자격증",
            span: TimeSpan(start: start, end: start.addingTimeInterval(10 * 86_400)),
            categoryID: "study"
        )
        let child = PlanRecord(
            title: "강의 듣기",
            span: TimeSpan(start: start, end: start.addingTimeInterval(hour)),
            categoryID: "study",
            parentID: projectGoal.id
        )
        XCTAssertEqual(
            GoalDetailEngine.make(
                goal: projectGoal,
                plans: [projectGoal, child],
                actuals: [],
                referenceDate: start,
                calendar: utcCalendar
            ).mode,
            .project
        )
        XCTAssertEqual(
            GoalDetailEngine.make(
                goal: projectGoal,
                plans: [projectGoal],
                actuals: [],
                referenceDate: start,
                calendar: utcCalendar
            ).mode,
            .empty
        )
        XCTAssertEqual(
            GoalDetailEngine.unionDuration([
                TimeSpan(start: start, end: start.addingTimeInterval(hour)),
                TimeSpan(
                    start: start.addingTimeInterval(30 * 60),
                    end: start.addingTimeInterval(2 * hour)
                ),
            ]),
            2 * hour
        )
    }

    func testSleepActualLinksToRoutineOnlyInRelationshipGraph() {
        let start = makeDate(2026, 8, 1, 22)
        let routine = PlanRecord(
            title: "루틴:수면",
            span: TimeSpan(start: start, end: start.addingTimeInterval(10 * hour)),
            categoryID: "sleep"
        )
        let action = PlanRecord(
            title: "취침 준비",
            span: TimeSpan(start: start, end: start.addingTimeInterval(hour)),
            categoryID: "sleep",
            parentID: routine.id
        )
        let sleep = ActualRecord(
            planID: action.id,
            routineID: routine.id,
            title: "수면",
            categoryID: "sleep",
            startedAt: start.addingTimeInterval(15 * 60),
            endedAt: start.addingTimeInterval(8 * hour),
            source: .appleWatch
        )

        let graph = RecordRelationshipEngine.make(
            inside: routine.span,
            plans: [routine, action],
            actuals: [sleep],
            calendarEvents: [],
            places: [],
            travel: []
        )

        XCTAssertTrue(
            graph.edges.contains {
                $0.from == "automatic.actual.\(sleep.id.uuidString)"
                    && $0.to == "routine.\(routine.id.uuidString)"
            }
        )
        XCTAssertFalse(
            graph.edges.contains {
                $0.from == "automatic.actual.\(sleep.id.uuidString)"
                    && $0.to == "action.\(action.id.uuidString)"
            }
        )
        XCTAssertTrue(
            graph.edges.contains {
                $0.from == "routine.\(routine.id.uuidString)"
                    && $0.to == "action.\(action.id.uuidString)"
            }
        )
    }

    func testRelationshipGraphResolvesNestedActionAndAutomaticEvidence() {
        let start = makeDate(2026, 8, 2, 9)
        let routine = PlanRecord(
            title: "루틴:운동",
            span: TimeSpan(start: start, end: start.addingTimeInterval(4 * hour)),
            categoryID: "activity"
        )
        let parentAction = PlanRecord(
            title: "준비 운동",
            span: TimeSpan(start: start, end: start.addingTimeInterval(hour)),
            categoryID: "exercise",
            parentID: routine.id
        )
        let nestedAction = PlanRecord(
            title: "달리기",
            span: TimeSpan(
                start: start.addingTimeInterval(hour),
                end: start.addingTimeInterval(3 * hour)
            ),
            categoryID: "exercise",
            parentID: parentAction.id
        )
        let running = ActualRecord(
            planID: nestedAction.id,
            routineID: nil,
            title: "달리기",
            categoryID: "exercise",
            startedAt: start.addingTimeInterval(75 * 60),
            endedAt: start.addingTimeInterval(2 * hour),
            source: .appleWatch
        )

        let graph = RecordRelationshipEngine.make(
            inside: running.span(),
            plans: [routine, parentAction, nestedAction],
            actuals: [running],
            calendarEvents: [],
            places: [],
            travel: [],
            focusNodeID: "automatic.actual.\(running.id.uuidString)"
        )

        XCTAssertTrue(graph.edges.contains {
            $0.from == "routine.\(routine.id.uuidString)"
                && $0.to == "action.\(nestedAction.id.uuidString)"
        })
        XCTAssertTrue(graph.edges.contains {
            $0.from == "automatic.actual.\(running.id.uuidString)"
                && $0.to == "action.\(nestedAction.id.uuidString)"
        })
        XCTAssertTrue(graph.nodes.contains { $0.id == "routine.\(routine.id.uuidString)" })
        XCTAssertTrue(graph.nodes.contains { $0.id == "action.\(nestedAction.id.uuidString)" })
    }

    func testRelationshipGraphOmitsRepeatSegmentsAndKeepsFocusedRoutineChain() {
        let start = makeDate(2026, 8, 2, 22)
        let routine = PlanRecord(
            title: "루틴:수면",
            span: TimeSpan(start: start, end: start.addingTimeInterval(10 * hour)),
            categoryID: "sleep"
        )
        let repeatSegment = PlanRecord(
            title: "수면 · 주중",
            span: TimeSpan(
                start: start.addingTimeInterval(hour),
                end: start.addingTimeInterval(8 * hour)
            ),
            categoryID: "sleep",
            parentID: routine.id,
            origin: .repeatRule
        )
        let action = PlanRecord(
            title: "취침 준비",
            span: TimeSpan(start: start, end: start.addingTimeInterval(hour)),
            categoryID: "sleep",
            parentID: routine.id
        )
        let sleep = ActualRecord(
            planID: action.id,
            routineID: routine.id,
            title: "수면",
            categoryID: "sleep",
            startedAt: start.addingTimeInterval(2 * hour),
            endedAt: start.addingTimeInterval(7 * hour),
            source: .healthKit
        )

        let graph = RecordRelationshipEngine.make(
            inside: sleep.span(),
            plans: [routine, repeatSegment, action],
            actuals: [sleep],
            calendarEvents: [],
            places: [],
            travel: [],
            focusNodeID: "automatic.actual.\(sleep.id.uuidString)"
        )

        XCTAssertFalse(graph.nodes.contains { $0.id == "routine.\(repeatSegment.id.uuidString)" })
        XCTAssertTrue(graph.edges.contains {
            $0.from == "automatic.actual.\(sleep.id.uuidString)"
                && $0.to == "routine.\(routine.id.uuidString)"
        })
        XCTAssertFalse(graph.edges.contains {
            $0.from == "automatic.actual.\(sleep.id.uuidString)"
                && $0.to == "action.\(action.id.uuidString)"
        })
        XCTAssertTrue(graph.edges.contains {
            $0.from == "routine.\(routine.id.uuidString)"
                && $0.to == "action.\(action.id.uuidString)"
        })
    }

    func testRelationshipGraphCanonicalizesLegacyRepeatLink() {
        let start = makeDate(2026, 8, 3, 8)
        let routine = PlanRecord(
            title: "루틴:출근",
            span: TimeSpan(start: start, end: start.addingTimeInterval(2 * hour)),
            categoryID: "work"
        )
        let repeatSegment = PlanRecord(
            title: "출근 · 월요일",
            span: TimeSpan(start: start, end: start.addingTimeInterval(hour)),
            categoryID: "work",
            parentID: routine.id,
            origin: .repeatRule
        )
        let place = PlaceStay(
            id: UUID(),
            placeKey: "company",
            displayName: "회사",
            floor: nil,
            span: TimeSpan(start: start, end: start.addingTimeInterval(30 * 60)),
            confidence: .high,
            point: nil
        )
        let graph = RecordRelationshipEngine.make(
            inside: place.span,
            plans: [routine, repeatSegment],
            actuals: [],
            calendarEvents: [],
            places: [place],
            travel: [],
            recordLinks: [
                RecordLink(
                    fromNodeID: "automatic.place.\(place.id.uuidString)",
                    toNodeID: "action.\(repeatSegment.id.uuidString)"
                )
            ]
        )

        XCTAssertTrue(graph.edges.contains {
            $0.from == "automatic.place.\(place.id.uuidString)"
                && $0.to == "routine.\(routine.id.uuidString)"
        })
        XCTAssertFalse(graph.edges.contains {
            $0.to == "action.\(repeatSegment.id.uuidString)"
        })
    }

    func testGoalActivityMatchingCountsExplicitlyLinkedSleepOnly() {
        let start = makeDate(2026, 8, 1, 22)
        let routine = PlanRecord(
            title: "루틴:수면",
            span: TimeSpan(start: start, end: start.addingTimeInterval(10 * hour)),
            categoryID: "sleep"
        )
        let linked = ActualRecord(
            planID: nil,
            routineID: routine.id,
            title: "수면",
            categoryID: "sleep",
            startedAt: start,
            endedAt: start.addingTimeInterval(7 * hour),
            source: .healthKit
        )
        let unlinked = ActualRecord(
            planID: nil,
            routineID: nil,
            title: "수면",
            categoryID: "sleep",
            startedAt: start,
            endedAt: start.addingTimeInterval(7 * hour),
            source: .healthKit
        )

        XCTAssertEqual(
            GoalActivityMatchingEngine.matches(
                goal: routine,
                plans: [routine],
                actuals: [linked, unlinked]
            ).map(\.actual.id),
            [linked.id]
        )
    }

    func testAutomaticSleepEvidenceUsesBestOverlappingRepeatSegment() {
        let routineStart = makeDate(2026, 8, 1, 22)
        let routine = PlanRecord(
            title: "루틴:수면",
            span: TimeSpan(
                start: routineStart,
                end: routineStart.addingTimeInterval(10 * hour)
            ),
            categoryID: "sleep"
        )
        let repeatSegment = PlanRecord(
            title: "수면 · 주중",
            span: TimeSpan(
                start: makeDate(2026, 8, 1, 23),
                end: makeDate(2026, 8, 2, 6, 30)
            ),
            categoryID: "sleep",
            parentID: routine.id,
            origin: .repeatRule
        )
        let sleep = ActualRecord(
            planID: nil,
            routineID: nil,
            title: "수면",
            categoryID: "sleep",
            startedAt: makeDate(2026, 8, 2, 2),
            endedAt: makeDate(2026, 8, 2, 6),
            source: .healthKit
        )

        let matches = GoalActivityMatchingEngine.matches(
            goal: routine,
            plans: [routine, repeatSegment],
            actuals: [sleep],
            asOf: makeDate(2026, 8, 2, 12)
        )

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.kind, .automatic)
        XCTAssertEqual(matches.first?.matchedPlanID, repeatSegment.id)
        XCTAssertEqual(
            GoalActivityMatchingEngine.progress(
                for: repeatSegment,
                matches: matches,
                asOf: makeDate(2026, 8, 2, 12)
            ),
            4 * hour / (7.5 * hour),
            accuracy: 0.001
        )
    }

    func testGoalRecordPolicyKeepsOrdinaryPlansOutOfGoalTab() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let goal = PlanRecord(
            title: "목표:달리기",
            span: TimeSpan(
                start: start,
                end: start.addingTimeInterval(86_400)
            ),
            categoryID: "exercise"
        )
        let ordinaryPlan = PlanRecord(
            title: "청계천 달리기",
            span: TimeSpan(
                start: start.addingTimeInterval(3_600),
                end: start.addingTimeInterval(5_400)
            ),
            categoryID: "exercise"
        )
        let childPlan = PlanRecord(
            title: "인터벌 훈련",
            span: TimeSpan(
                start: start.addingTimeInterval(7_200),
                end: start.addingTimeInterval(9_000)
            ),
            categoryID: "exercise",
            parentID: goal.id
        )
        let skippedGoal = PlanRecord(
            title: "목표:지난 목표",
            span: TimeSpan(
                start: start,
                end: start.addingTimeInterval(3_600)
            ),
            categoryID: "exercise",
            status: .skipped
        )

        let visible = GoalRecordPolicy.visibleGoals(
            in: [ordinaryPlan, childPlan, skippedGoal, goal]
        )

        XCTAssertEqual(visible.map(\.id), [goal.id])
        XCTAssertFalse(GoalRecordPolicy.isGoal(ordinaryPlan))
        XCTAssertFalse(GoalRecordPolicy.isGoal(childPlan))
    }

    func testScheduleHeaderUsesKoreanCalendarTitles() {
        let date = makeDate(2026, 7, 31)
        let formatter = ScheduleHeaderFormatter(calendar: utcCalendar)

        XCTAssertEqual(
            formatter.title(for: date, scale: .day),
            "7월 31일 (금)"
        )
        XCTAssertEqual(
            formatter.title(for: date, scale: .week),
            "7월 27일 – 8월 2일"
        )
        XCTAssertEqual(
            formatter.title(for: date, scale: .month),
            "2026년 7월"
        )
        XCTAssertEqual(
            formatter.title(for: date, scale: .year),
            "2026년"
        )
        XCTAssertEqual(
            formatter.playheadTitle(for: date, scale: .week),
            "7월 31일 (금)"
        )
        XCTAssertEqual(
            formatter.playheadTitle(for: date, scale: .month),
            "7월 31일 (금)"
        )
        XCTAssertEqual(
            formatter.playheadTitle(for: date, scale: .year),
            "7월 31일 (금)"
        )
    }

    func testPeriodNavigationAllowsEmptyAdjacentPeriodForEveryScale() throws {
        let date = makeDate(2026, 7, 31, 12)
        let engine = TimelinePeriodNavigationEngine(calendar: utcCalendar)

        // 기록이 없는 날짜도 고를 수 있어야 한다. 빈 구간이라는 사실
        // 자체를 확인하려면 일단 넘어갈 수 있어야 하기 때문이다.
        for level in TimelineLevel.allCases {
            for direction in [-1, 1] {
                XCTAssertTrue(
                    engine.canNavigate(
                        from: date,
                        level: level,
                        direction: direction,
                        snapshot: .empty
                    ),
                    "\(level.rawValue) should stay enabled without data"
                )
            }
        }
    }

    /// 기록이 있는 곳으로 끌려가지 않는다. 빈 구간으로 넘어가면 그 빈 구간이
    /// 그대로 나온다. 예전에는 손을 뗀 자리에 아무것도 없으면 가장 가까운
    /// 기록으로 화면이 되돌아가, 아직 비어 있는 앞날을 펼쳐 둘 수 없었다.
    func testPeriodNavigationLandsOnTheNeighborNotOnTheNearestRecord() throws {
        let date = makeDate(2026, 7, 31, 12)
        let engine = TimelinePeriodNavigationEngine(calendar: utcCalendar)
        // 기록은 한참 뒤에만 있다. 어느 배율에서 한 칸을 움직여도 여기에
        // 닿지 않는다.
        let distant = makeDate(2027, 3, 2, 9)
        let snapshot = makeSnapshot(
            plans: [
                PlanRecord(
                    title: "먼 계획",
                    span: TimeSpan(
                        start: distant,
                        end: distant.addingTimeInterval(hour)
                    ),
                    categoryID: "project"
                ),
            ]
        )

        for level in TimelineLevel.allCases {
            let component: Calendar.Component = switch level {
            case .day: .day
            case .week: .weekOfYear
            case .month: .month
            case .year: .year
            }
            for direction in [-1, 1] {
                XCTAssertTrue(
                    engine.canNavigate(
                        from: date,
                        level: level,
                        direction: direction,
                        snapshot: snapshot
                    )
                )
                XCTAssertEqual(
                    engine.adjacentDate(
                        from: date,
                        level: level,
                        direction: direction
                    ),
                    utcCalendar.date(
                        byAdding: component,
                        value: direction,
                        to: date
                    ),
                    "\(level.rawValue) \(direction) should not seek data"
                )
            }
        }
    }

    /// 배율마다 한 칸씩 넘긴 자리에 그대로 머문다. 되돌아오면 처음 자리다.
    @MainActor
    func testShiftingIntoAnEmptyPeriodStaysThereForEveryScale() {
        let calendar = Calendar.autoupdatingCurrent
        let anchor = makeDate(2026, 7, 31, 12)
        let model = AppModel(
            repository: InMemoryPlanRepository(),
            cloudSyncService: nil
        )

        for scale in TimeScale.allCases {
            let component: Calendar.Component = switch scale {
            case .day: .day
            case .week: .weekOfYear
            case .month: .month
            case .year: .year
            }
            model.selectedScale = scale
            model.selectedDate = anchor

            model.shiftSelectedDate(by: 1)
            XCTAssertEqual(
                model.selectedDate,
                calendar.date(byAdding: component, value: 1, to: anchor),
                "\(scale.rawValue) should stay on the empty next period"
            )

            model.shiftSelectedDate(by: -1)
            XCTAssertEqual(
                model.selectedDate,
                anchor,
                "\(scale.rawValue) should come back to where it started"
            )
        }
    }

    func testPeriodNavigationStillRejectsZeroDirection() {
        let date = makeDate(2026, 7, 31, 12)
        let engine = TimelinePeriodNavigationEngine(calendar: utcCalendar)

        for level in TimelineLevel.allCases {
            XCTAssertFalse(
                engine.canNavigate(
                    from: date,
                    level: level,
                    direction: 0,
                    snapshot: .empty
                )
            )
        }
    }

    func testScreenTimeUsageReplacesOnlyTheFetchedHours() {
        let start = makeDate(2026, 8, 3, 9)
        let span = TimeSpan(start: start, end: start.addingTimeInterval(hour))
        let fresh = ScreenTimeUsageRecordEngine.records(
            from: [
                ScreenTimeUsageSample(
                    key: "bundle:com.example.maps",
                    title: "어플 · 지도",
                    span: span,
                    duration: 20 * 60,
                    pickups: 1,
                    notifications: 2
                )
            ],
            suppressedIDs: []
        )
        let stale = ActualRecord(
            planID: nil,
            title: "어플 · 이전",
            categoryID: "appUsage",
            startedAt: start,
            endedAt: start.addingTimeInterval(5 * 60),
            source: .appUsage
        )
        let outside = ActualRecord(
            planID: nil,
            title: "어플 · 유지",
            categoryID: "appUsage",
            startedAt: start.addingTimeInterval(2 * hour),
            endedAt: start.addingTimeInterval(2 * hour + 5 * 60),
            source: .appUsage
        )

        let result = ScreenTimeUsageRecordEngine.replacing(
            existing: [stale, outside],
            with: fresh,
            inside: span
        )

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.map(\.title), ["어플 · 지도", "어플 · 유지"])
        XCTAssertEqual(result[0].source, .appUsage)
        XCTAssertEqual(result[0].span().duration, 20 * 60)
        XCTAssertEqual(result[0].evidence, [
            "Screen Time 시간대 합계",
            "사용 20분",
            "앱 열기 1회",
            "알림 2회",
        ])
    }

    func testScreenTimeUsageKeepsOneRecordPerApplication() {
        let start = makeDate(2026, 8, 3, 9)
        let span = TimeSpan(start: start, end: start.addingTimeInterval(hour))
        let records = ScreenTimeUsageRecordEngine.records(
            from: [
                ScreenTimeUsageSample(
                    key: "bundle:com.example.maps",
                    title: "어플 · 지도",
                    span: span,
                    duration: 12 * 60,
                    pickups: 3,
                    notifications: 0
                ),
                ScreenTimeUsageSample(
                    key: "bundle:com.example.chat",
                    title: "어플 · 메시지",
                    span: span,
                    duration: 25 * 60,
                    pickups: 8,
                    notifications: 4
                ),
                // 같은 시간대에 다시 나온 같은 앱은 한 줄로 합친다.
                ScreenTimeUsageSample(
                    key: "bundle:com.example.maps",
                    title: "어플 · 지도",
                    span: span,
                    duration: 12 * 60,
                    pickups: 3,
                    notifications: 0
                ),
            ],
            suppressedIDs: []
        )

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(
            Set(records.map(\.title)),
            ["어플 · 지도", "어플 · 메시지"]
        )
        XCTAssertEqual(Set(records.map(\.id)).count, 2)
        XCTAssertTrue(records.allSatisfy { $0.categoryID == "appUsage" })
        XCTAssertTrue(records.allSatisfy { $0.startedAt == start })
        XCTAssertEqual(
            records.first { $0.title == "어플 · 메시지" }?.span().duration,
            25 * 60
        )
        XCTAssertTrue(
            records.allSatisfy { !$0.evidence.contains(where: {
                $0.contains("카테고리")
            }) }
        )
    }

    func testScreenTimeUsageExplainsCategoryAndUnknownFallbacks() {
        let start = makeDate(2026, 8, 3, 14)
        let span = TimeSpan(start: start, end: start.addingTimeInterval(hour))
        let records = ScreenTimeUsageRecordEngine.records(
            from: [
                ScreenTimeUsageSample(
                    key: "category:소셜",
                    title: "어플 · 소셜",
                    span: span,
                    duration: 18 * 60,
                    pickups: 0,
                    notifications: 0,
                    nameSource: .category
                ),
                ScreenTimeUsageSample(
                    key: "total",
                    title: "어플",
                    span: span,
                    duration: 40 * 60,
                    pickups: 2,
                    notifications: 0,
                    nameSource: .unknown
                ),
            ],
            suppressedIDs: []
        )

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(
            records.first { $0.title == "어플 · 소셜" }?.evidence,
            [
                "Screen Time 시간대 합계",
                "사용 18분",
                "앱 이름을 읽을 수 없어 카테고리 단위로 묶었습니다",
            ]
        )
        XCTAssertEqual(
            records.first { $0.title == "어플" }?.evidence,
            [
                "Screen Time 시간대 합계",
                "사용 40분",
                "앱 열기 2회",
                "앱 이름과 카테고리를 모두 읽을 수 없어 시간대 합계만 남겼습니다",
            ]
        )
    }

    func testScreenTimeUsageDurationTextMatchesSettingsRow() {
        XCTAssertNil(ScreenTimeUsageRecordEngine.durationText(30))
        XCTAssertEqual(ScreenTimeUsageRecordEngine.durationText(14 * 60), "14분")
        XCTAssertEqual(
            ScreenTimeUsageRecordEngine.durationText(2 * hour),
            "2시간"
        )
        XCTAssertEqual(
            ScreenTimeUsageRecordEngine.durationText(2 * hour + 14 * 60),
            "2시간 14분"
        )
    }

    func testBundleIdentifierDisplayNameDropsReverseDNSPrefix() {
        let name = AppBundleDisplayName.displayName(forBundleIdentifier:)
        XCTAssertEqual(name("com.burbn.instagram"), "Instagram")
        XCTAssertEqual(name("com.google.ios.youtube"), "Youtube")
        XCTAssertEqual(name("net.whatsapp.WhatsApp"), "WhatsApp")
        // "com."만 떼면 "burbn.instagram"이 남는다. 마지막 조각만 써야 한다.
        XCTAssertNotEqual(name("com.burbn.instagram"), "burbn.instagram")
    }

    func testBundleIdentifierDisplayNameStripsPlatformNoise() {
        let name = AppBundleDisplayName.displayName(forBundleIdentifier:)
        XCTAssertEqual(name("com.apple.mobilesafari"), "Safari")
        XCTAssertEqual(name("com.apple.mobilemail"), "Mail")
        XCTAssertEqual(name("com.apple.MobileSMS"), "SMS")
        XCTAssertEqual(name("com.atebits.Tweetie2"), "Tweetie")
        XCTAssertEqual(name("com.example.player.ios"), "Player")
    }

    func testBundleIdentifierDisplayNameUsesCuratedKoreanNames() {
        let name = AppBundleDisplayName.displayName(forBundleIdentifier:)
        XCTAssertEqual(name("com.kakao.talk"), "카카오톡")
        XCTAssertEqual(name("viva.republica.toss"), "토스")
        XCTAssertEqual(name("COM.KAKAO.TALK"), "카카오톡")
    }

    func testBundleIdentifierDisplayNameRejectsEmptyInput() {
        let name = AppBundleDisplayName.displayName(forBundleIdentifier:)
        XCTAssertNil(name(""))
        XCTAssertNil(name("   "))
        XCTAssertNil(name("123"))
    }

    func testScreenTimeUsageNamesBundleFallbackAsEstimate() {
        let start = makeDate(2026, 8, 3, 14)
        let span = TimeSpan(start: start, end: start.addingTimeInterval(hour))
        let records = ScreenTimeUsageRecordEngine.records(
            from: [
                ScreenTimeUsageSample(
                    key: "bundle:com.burbn.instagram",
                    title: "Instagram",
                    span: span,
                    duration: 12 * 60,
                    pickups: 0,
                    notifications: 0,
                    nameSource: .bundleIdentifier
                ),
            ],
            suppressedIDs: []
        )

        XCTAssertEqual(records.first?.title, "Instagram")
        XCTAssertEqual(
            records.first?.evidence,
            [
                "Screen Time 시간대 합계",
                "사용 12분",
                "앱 이름 대신 번들 ID에서 유추한 이름입니다",
            ]
        )
    }

    // MARK: - 기록 계층·차트

    private func makeActual(
        _ title: String,
        _ categoryID: String,
        start: Date,
        minutes: Double,
        source: ActualSource = .motion,
        behavior: String? = nil
    ) -> ActualRecord {
        ActualRecord(
            planID: nil,
            title: title,
            categoryID: categoryID,
            startedAt: start,
            endedAt: start.addingTimeInterval(minutes * 60),
            source: source,
            behavior: behavior
        )
    }

    func testRecordGroupingSortsCategoriesByTotalAndChildrenByStart() {
        let day = makeDate(2026, 8, 4)
        let span = TimeSpan(start: day, end: day.addingTimeInterval(24 * hour))
        let actuals = [
            makeActual(
                "Safari",
                "appUsage",
                start: day.addingTimeInterval(10 * hour),
                minutes: 22,
                source: .appUsage
            ),
            makeActual(
                "카카오톡",
                "appUsage",
                start: day.addingTimeInterval(9 * hour),
                minutes: 38,
                source: .appUsage
            ),
            makeActual(
                "수면",
                "sleep",
                start: day,
                minutes: 7 * 60
            ),
        ]

        let groups = ActualRecordGroupingEngine.groups(
            actuals: actuals,
            in: span,
            categories: CategoryCatalog.builtIn,
            asOf: day.addingTimeInterval(24 * hour)
        )

        XCTAssertEqual(groups.map(\.id), ["sleep", "appUsage"])
        XCTAssertEqual(groups[0].name, "수면")
        // 사용자 카테고리에 없는 자동 줄도 한글 이름을 갖는다.
        XCTAssertEqual(groups[1].name, "어플")
        XCTAssertEqual(groups[0].duration, 7 * hour)
        XCTAssertEqual(groups[1].duration, 60 * 60)
        XCTAssertEqual(groups[1].children.map(\.title), ["카카오톡", "Safari"])
        XCTAssertEqual(groups[1].children.map(\.duration), [38 * 60, 22 * 60])
    }

    func testRecordGroupingMergesRepeatedTitlesAndClipsToSpan() {
        let day = makeDate(2026, 8, 4)
        let span = TimeSpan(
            start: day.addingTimeInterval(9 * hour),
            end: day.addingTimeInterval(12 * hour)
        )
        let actuals = [
            // 기간 앞으로 삐져나온 기록은 겹치는 만큼만 센다.
            makeActual(
                "회의",
                "work",
                start: day.addingTimeInterval(8.5 * hour),
                minutes: 60
            ),
            makeActual(
                "회의",
                "work",
                start: day.addingTimeInterval(10 * hour),
                minutes: 30
            ),
            // 같은 제목이 겹치면 한 번만 센다.
            makeActual(
                "회의",
                "work",
                start: day.addingTimeInterval(10 * hour + 15 * 60),
                minutes: 30
            ),
        ]

        let groups = ActualRecordGroupingEngine.groups(
            actuals: actuals,
            in: span,
            categories: CategoryCatalog.builtIn,
            asOf: day.addingTimeInterval(24 * hour)
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].name, "업무")
        XCTAssertEqual(groups[0].children.count, 1)
        XCTAssertEqual(groups[0].children[0].occurrenceCount, 3)
        XCTAssertEqual(groups[0].children[0].duration, 75 * 60)
        XCTAssertEqual(groups[0].duration, 75 * 60)
    }

    func testRecordGroupingRoutesActivityRecordsToSleepAndMovement() {
        let day = makeDate(2026, 8, 4)
        let span = TimeSpan(start: day, end: day.addingTimeInterval(24 * hour))
        let actuals = [
            makeActual("수면 추정", "activity", start: day, minutes: 60),
            makeActual(
                "걷기",
                "activity",
                start: day.addingTimeInterval(9 * hour),
                minutes: 30
            ),
            makeActual(
                "서 있기",
                "activity",
                start: day.addingTimeInterval(11 * hour),
                minutes: 10
            ),
        ]

        let groups = ActualRecordGroupingEngine.groups(
            actuals: actuals,
            in: span,
            categories: CategoryCatalog.builtIn,
            asOf: day.addingTimeInterval(24 * hour)
        )

        XCTAssertEqual(
            Set(groups.map(\.id)),
            ["sleep", "movement", "activity"]
        )
        XCTAssertEqual(groups.first { $0.id == "sleep" }?.duration, 60 * 60)
        XCTAssertEqual(groups.first { $0.id == "movement" }?.duration, 30 * 60)
        XCTAssertEqual(groups.first { $0.id == "activity" }?.duration, 10 * 60)
    }

    func testClockRingsPlaceArcsAtTheirTimeOfDay() {
        let day = makeDate(2026, 8, 4)
        let span = TimeSpan(start: day, end: day.addingTimeInterval(24 * hour))
        let actuals = [
            makeActual("수면", "sleep", start: day, minutes: 6 * 60),
            makeActual(
                "걷기",
                "movement",
                start: day.addingTimeInterval(12 * hour),
                minutes: 60
            ),
        ]

        let rings = RecordChartEngine.clockRings(
            actuals: actuals,
            in: span,
            asOf: day.addingTimeInterval(24 * hour)
        )

        XCTAssertEqual(rings.map(\.categoryID), ["sleep", "movement"])
        XCTAssertEqual(rings[0].arcs.count, 1)
        XCTAssertEqual(rings[0].arcs[0].startFraction, 0, accuracy: 0.0001)
        XCTAssertEqual(rings[0].arcs[0].endFraction, 0.25, accuracy: 0.0001)
        XCTAssertEqual(rings[1].arcs[0].startFraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(
            rings[1].arcs[0].endFraction,
            0.5 + 1.0 / 24,
            accuracy: 0.0001
        )
    }

    func testChartBucketsSplitDurationAcrossDayBoundaries() {
        let start = makeDate(2026, 8, 3)
        let span = TimeSpan(
            start: start,
            end: start.addingTimeInterval(7 * 24 * hour)
        )
        let actuals = [
            // 자정을 넘긴 수면은 두 칸으로 갈린다.
            makeActual(
                "수면",
                "sleep",
                start: start.addingTimeInterval(23 * hour),
                minutes: 4 * 60
            ),
            makeActual(
                "걷기",
                "movement",
                start: start.addingTimeInterval(10 * hour),
                minutes: 30
            ),
        ]

        let buckets = RecordChartEngine.buckets(
            actuals: actuals,
            in: span,
            unit: .day,
            calendar: utcCalendar,
            asOf: start.addingTimeInterval(7 * 24 * hour)
        )

        XCTAssertEqual(buckets.count, 7)
        XCTAssertEqual(buckets[0].total, 90 * 60)
        XCTAssertEqual(
            buckets[0].slices.map(\.categoryID),
            ["sleep", "movement"]
        )
        XCTAssertEqual(buckets[0].slices[0].duration, 60 * 60)
        XCTAssertEqual(buckets[1].total, 3 * hour)
        XCTAssertEqual(buckets[2].total, 0)
    }

    func testChartBucketsUseOneColumnPerMonthForTheYearScale() {
        let start = makeDate(2026, 1, 1)
        let span = TimeSpan(start: start, end: makeDate(2027, 1, 1))
        let actuals = [
            makeActual(
                "수면",
                "sleep",
                start: makeDate(2026, 3, 2, 22),
                minutes: 6 * 60
            )
        ]

        let buckets = RecordChartEngine.buckets(
            actuals: actuals,
            in: span,
            unit: .month,
            calendar: utcCalendar,
            asOf: makeDate(2027, 1, 1)
        )

        XCTAssertEqual(buckets.count, 12)
        XCTAssertEqual(buckets[2].total, 6 * hour)
        XCTAssertEqual(buckets.map(\.total).reduce(0, +), 6 * hour)
    }

    func testClockNowHandOnlyAppearsInsideTheShownDay() {
        let day = makeDate(2026, 8, 4)
        let span = TimeSpan(start: day, end: day.addingTimeInterval(24 * hour))

        XCTAssertEqual(
            RecordClockEngine.nowFraction(
                in: span,
                asOf: day.addingTimeInterval(6 * hour)
            ) ?? -1,
            0.25,
            accuracy: 0.0001
        )
        XCTAssertNil(
            RecordClockEngine.nowFraction(
                in: span,
                asOf: day.addingTimeInterval(-1)
            )
        )
        XCTAssertNil(
            RecordClockEngine.nowFraction(
                in: span,
                asOf: day.addingTimeInterval(24 * hour)
            )
        )
    }

    func testClockPlaybackProgressSpansTheWholeDayOnce() {
        let start = makeDate(2026, 8, 4, 9)

        XCTAssertNil(RecordClockEngine.progress(start: nil, now: start))
        XCTAssertEqual(
            RecordClockEngine.progress(start: start, now: start) ?? -1,
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            RecordClockEngine.progress(
                start: start,
                now: start.addingTimeInterval(
                    RecordClockEngine.sweepDuration / 2
                )
            ) ?? -1,
            0.5,
            accuracy: 0.0001
        )
        // 한 바퀴를 넘겨도 1을 넘지 않는다.
        XCTAssertEqual(
            RecordClockEngine.progress(
                start: start,
                now: start.addingTimeInterval(
                    RecordClockEngine.sweepDuration * 3
                )
            ) ?? -1,
            1,
            accuracy: 0.0001
        )
    }

    func testClockPlaybackRevealsArcsAsThePlayheadPassesThem() {
        let day = makeDate(2026, 8, 4)
        let span = TimeSpan(start: day, end: day.addingTimeInterval(24 * hour))
        let rings = RecordChartEngine.clockRings(
            actuals: [
                makeActual("수면", "sleep", start: day, minutes: 6 * 60),
                makeActual(
                    "걷기",
                    "movement",
                    start: day.addingTimeInterval(12 * hour),
                    minutes: 60
                ),
            ],
            in: span,
            asOf: day.addingTimeInterval(24 * hour)
        )

        // 재생 전에는 자르지 않는다.
        XCTAssertEqual(
            RecordClockEngine.rings(rings, revealedThrough: nil).count,
            2
        )

        // 재생머리가 수면 한가운데면 수면만, 그것도 절반만 보인다.
        let half = RecordClockEngine.rings(rings, revealedThrough: 0.125)
        XCTAssertEqual(half.map(\.categoryID), ["sleep"])
        XCTAssertEqual(half[0].arcs[0].endFraction, 0.125, accuracy: 0.0001)
        XCTAssertEqual(
            RecordClockEngine.categoryIDs(in: rings, at: 0.125),
            ["sleep"]
        )

        // 다 지나가면 원래 원호가 그대로 남는다.
        let whole = RecordClockEngine.rings(rings, revealedThrough: 1)
        XCTAssertEqual(whole.map(\.categoryID), ["sleep", "movement"])
        XCTAssertEqual(whole[0].arcs[0].endFraction, 0.25, accuracy: 0.0001)
        XCTAssertTrue(
            RecordClockEngine.categoryIDs(in: rings, at: 0.4).isEmpty
        )
    }

    func testClockLegendKeepsOnlyTheChosenCategory() {
        let day = makeDate(2026, 8, 4)
        let span = TimeSpan(start: day, end: day.addingTimeInterval(24 * hour))
        let rings = RecordChartEngine.clockRings(
            actuals: [
                makeActual("수면", "sleep", start: day, minutes: 6 * 60),
                makeActual(
                    "걷기",
                    "movement",
                    start: day.addingTimeInterval(12 * hour),
                    minutes: 60
                ),
            ],
            in: span,
            asOf: day.addingTimeInterval(24 * hour)
        )

        XCTAssertEqual(
            RecordClockEngine.rings(rings, isolating: nil).count,
            2
        )
        XCTAssertEqual(
            RecordClockEngine.rings(rings, isolating: "movement")
                .map(\.categoryID),
            ["movement"]
        )
        XCTAssertTrue(
            RecordClockEngine.rings(rings, isolating: "sleepless").isEmpty
        )
    }

    func testClockSwipeMovesADayOnlyOnADeliberateHorizontalDrag() {
        XCTAssertEqual(
            RecordClockEngine.swipeStep(width: -80, height: 10),
            1
        )
        XCTAssertEqual(
            RecordClockEngine.swipeStep(width: 80, height: -10),
            -1
        )
        // 짧게 흔든 손가락은 날짜를 넘기지 않는다.
        XCTAssertNil(RecordClockEngine.swipeStep(width: -20, height: 4))
        // 세로가 더 길면 목록을 굴리는 중이다.
        XCTAssertNil(RecordClockEngine.swipeStep(width: -60, height: 120))
    }

    func testAutomaticRowVocabularyIsSharedByEverySurface() {
        XCTAssertEqual(TimelineRowKind.appUsage.title, "어플")
        XCTAssertEqual(ScreenTimeUsageRecordEngine.laneTitle, "어플")
        XCTAssertEqual(TaptionWidgetLane.appUsage.title, "어플")
        XCTAssertEqual(
            TaptionWidgetLane.movement.systemImage,
            TimelineRowKind.movement.systemImage
        )
        XCTAssertEqual(TaptionWidgetLane.schedule.title, "일정")
        XCTAssertEqual(TaptionWidgetLane.action.title, "액션")
        XCTAssertEqual(
            TimelineRowOrder.defaults,
            [
                "calendar",
                "location",
                "movement",
                "sleep",
                "activity",
                "appUsage",
                "weather",
                "photo",
                "memo",
            ]
        )
        XCTAssertNil(TimelineRowKind(categoryID: "work"))
        XCTAssertEqual(TimelineRowKind(categoryID: "schedule"), .calendar)
        // 메모도 일정·위치·수면과 같은 자격의 줄이다.
        XCTAssertEqual(TimelineRowKind.memo.title, "메모")
        XCTAssertEqual(TimelineRowKind.memo.systemImage, "note.text")
        XCTAssertEqual(TimelineRowKind(categoryID: "memo"), .memo)
        XCTAssertEqual(
            MemoTimelineEngine.categoryID,
            TimelineRowKind.memo.rawValue
        )
    }

    func testDurationTextMatchesTheScreenTimeWording() {
        XCTAssertEqual(DurationText.korean(0), "0분")
        XCTAssertEqual(DurationText.korean(38 * 60), "38분")
        XCTAssertEqual(DurationText.korean(2 * hour), "2시간")
        XCTAssertEqual(DurationText.korean(2 * hour + 14 * 60), "2시간 14분")
        XCTAssertEqual(DurationText.signedKorean(-90 * 60), "－1시간 30분")
    }

    /// 같은 앱 사용 기록이 시간표 상세에서는 "1분 미만", 기록 목록에서는
    /// "0분"으로 읽히던 자리. 두 화면이 같은 문구를 쓴다.
    func testSubMinuteAppUsageReadsTheSameOnBothSurfaces() {
        // 시간표 상세는 durationText 가 nil 이면 "1분 미만"을 적는다.
        XCTAssertNil(ScreenTimeUsageRecordEngine.durationText(45))
        XCTAssertEqual(DurationText.koreanAtLeastAMinute(45), "1분 미만")
        XCTAssertEqual(DurationText.koreanAtLeastAMinute(59), "1분 미만")
        // 아무 일도 없던 0초까지 부풀리지는 않는다.
        XCTAssertEqual(DurationText.koreanAtLeastAMinute(0), "0분")
        XCTAssertEqual(DurationText.koreanAtLeastAMinute(60), "1분")
        XCTAssertEqual(DurationText.koreanAtLeastAMinute(2 * hour), "2시간")
        XCTAssertEqual(
            DurationText.koreanAtLeastAMinute(2 * hour + 14 * 60),
            "2시간 14분"
        )
    }

    // MARK: - Stationary context

    func testStationaryContextCallOutranksCalendarAndPlaceSignals() {
        // 2026-08-04는 화요일이다.
        let start = makeDate(2026, 8, 4, 10, 0)
        let end = start.addingTimeInterval(105 * 60)
        let stay = makeContextStay(start: start, end: end)
        let inference = StationaryContextClassifier().classify(
            StationaryContextInput(
                stay: stay,
                placeKind: .company,
                calendarEvents: [
                    makeContextEvent(title: "주간 회의", start: start, end: end)
                ],
                actuals: [
                    makeContextActual(
                        source: .call,
                        start: start,
                        end: end
                    )
                ],
                calendar: utcCalendar,
                now: end.addingTimeInterval(hour)
            )
        )

        XCTAssertEqual(inference.kind, .call)
        XCTAssertEqual(inference.kind.title, "통화")
        XCTAssertEqual(inference.confidence, .high)
        XCTAssertTrue(inference.evidence.contains("CallKit 통화 기록"))
    }

    func testStationaryContextMeetingNeverReachesHighConfidence() {
        let start = makeDate(2026, 8, 4, 10, 0)
        let end = start.addingTimeInterval(2 * hour)
        let inference = StationaryContextClassifier().classify(
            StationaryContextInput(
                stay: makeContextStay(start: start, end: end),
                placeKind: .company,
                readings: [
                    makeContextReading(at: start, flat: true),
                    makeContextReading(
                        at: start.addingTimeInterval(hour),
                        flat: true
                    ),
                    makeContextReading(
                        at: start.addingTimeInterval(90 * 60),
                        flat: true
                    ),
                ],
                calendarEvents: [
                    makeContextEvent(
                        title: "분기 리뷰",
                        start: start,
                        end: end,
                        attendeeCount: 5
                    )
                ],
                calendar: utcCalendar,
                now: end.addingTimeInterval(hour)
            )
        )

        XCTAssertEqual(inference.kind, .meeting)
        XCTAssertEqual(inference.kind.title, "회의")
        XCTAssertGreaterThan(inference.score, 0.75)
        XCTAssertEqual(inference.confidence, .medium)
    }

    func testStationaryContextCompanyPlaceOnWeekdayBecomesWork() {
        let start = makeDate(2026, 8, 4, 10, 0)
        let end = start.addingTimeInterval(2 * hour)
        let inference = StationaryContextClassifier().classify(
            StationaryContextInput(
                stay: makeContextStay(start: start, end: end),
                placeKind: .company,
                calendar: utcCalendar,
                now: end.addingTimeInterval(hour)
            )
        )

        XCTAssertEqual(inference.kind, .work)
        XCTAssertEqual(inference.kind.title, "근무")
        XCTAssertEqual(inference.kind.categoryID, "work")
        XCTAssertEqual(inference.confidence, .medium)
        XCTAssertTrue(inference.evidence.contains("평일 09–18시"))
    }

    func testStationaryContextShortStayBetweenTravelsBecomesWaiting() {
        let start = makeDate(2026, 8, 4, 10, 0)
        let end = start.addingTimeInterval(10 * 60)
        let inference = StationaryContextClassifier().classify(
            StationaryContextInput(
                stay: makeContextStay(start: start, end: end),
                placeKind: nil,
                travel: [
                    TravelSegment(
                        mode: .walking,
                        span: TimeSpan(
                            start: start.addingTimeInterval(-10 * 60),
                            end: start
                        ),
                        distanceMeters: 500,
                        confidence: .medium,
                        evidence: ["걸음 수"]
                    ),
                    TravelSegment(
                        mode: .subway,
                        span: TimeSpan(
                            start: end,
                            end: end.addingTimeInterval(20 * 60)
                        ),
                        distanceMeters: 6_000,
                        confidence: .medium,
                        evidence: ["역 근처"]
                    ),
                ],
                calendar: utcCalendar,
                now: end.addingTimeInterval(hour)
            )
        )

        XCTAssertEqual(inference.kind, .waiting)
        XCTAssertEqual(inference.kind.title, "대기")
        XCTAssertTrue(inference.evidence.contains("이동 사이 정지"))
    }

    func testStationaryContextWithoutEvidenceStaysUnknownAtLowConfidence() {
        // 2026-08-08은 토요일이라 평일 근무 가중치가 붙지 않는다.
        let start = makeDate(2026, 8, 8, 14, 0)
        let end = start.addingTimeInterval(30 * 60)
        let inference = StationaryContextClassifier().classify(
            StationaryContextInput(
                stay: makeContextStay(start: start, end: end),
                placeKind: nil,
                calendar: utcCalendar,
                now: end.addingTimeInterval(hour)
            )
        )

        XCTAssertEqual(inference.kind, .unknownStay)
        XCTAssertEqual(inference.kind.title, "머무름")
        XCTAssertEqual(inference.confidence, .low)
        XCTAssertEqual(inference.evidence, ["장소 문맥 근거 부족"])
    }

    func testStationaryContextModifiersAttachWithoutChangingTheKind() {
        let start = makeDate(2026, 8, 8, 13, 0)
        let end = start.addingTimeInterval(2 * hour)
        let inference = StationaryContextClassifier().classify(
            StationaryContextInput(
                stay: makeContextStay(start: start, end: end),
                placeKind: .home,
                readings: [
                    makeContextReading(at: start, flat: true),
                    makeContextReading(
                        at: start.addingTimeInterval(hour),
                        flat: true
                    ),
                    makeContextReading(
                        at: start.addingTimeInterval(90 * 60),
                        flat: true
                    ),
                ],
                actuals: [
                    makeContextActual(
                        source: .appUsage,
                        start: start,
                        end: start.addingTimeInterval(hour)
                    ),
                    makeContextActual(
                        source: .media,
                        start: start,
                        end: start.addingTimeInterval(90)
                    ),
                ],
                calendar: utcCalendar,
                now: end.addingTimeInterval(hour)
            )
        )

        XCTAssertEqual(inference.kind, .homeRest)
        XCTAssertEqual(inference.kind.title, "집에서 휴식")
        XCTAssertTrue(inference.modifiers.contains(.screenUse))
        XCTAssertTrue(inference.modifiers.contains(.mediaPlayback))
        XCTAssertTrue(inference.modifiers.contains(.onDesk))
        XCTAssertFalse(inference.modifiers.contains(.inPocket))
    }

    func testStationaryContextRecordsUseExistingCategoriesAndStableIDs() {
        let start = makeDate(2026, 8, 4, 10, 0)
        let end = start.addingTimeInterval(2 * hour)
        let span = TimeSpan(start: start, end: end.addingTimeInterval(hour))
        let stay = makeContextStay(
            start: start,
            end: end,
            placeKey: "frequent-office"
        )
        let makeRecords = {
            StationaryContextActualEngine.records(
                stays: [stay],
                placeKinds: ["frequent-office": .company],
                inside: span,
                calendar: self.utcCalendar,
                now: span.end
            )
        }
        let records = makeRecords()

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.title, "근무")
        XCTAssertEqual(records.first?.source, .location)
        XCTAssertEqual(records.first?.behavior, "work")
        XCTAssertEqual(records.first?.modelVersion, "stationary-context-v1")
        XCTAssertEqual(records.first?.id, makeRecords().first?.id)

        let catalogIDs = Set(CategoryCatalog.builtIn.map(\.id))
        for kind in StationaryContextKind.allCases {
            XCTAssertTrue(
                catalogIDs.contains(kind.categoryID),
                "\(kind.rawValue) → \(kind.categoryID) 가 카탈로그에 없다"
            )
        }
    }

    /// 실기기에서 종일 "정지·휴식"만 보이던 원인. 실내에서는 GPS가 끊겨
    /// 장소 체류가 하나도 만들어지지 않는데, 예전에는 체류가 있어야만
    /// 문맥 기록을 만들었다.
    func testStationaryContextReplacesMotionRestWithoutAnyPlaceStay() {
        let dayStart = makeDate(2026, 8, 4, 0, 0)
        let day = TimeSpan(
            start: dayStart,
            end: dayStart.addingTimeInterval(24 * hour)
        )
        let restStart = makeDate(2026, 8, 4, 19, 0)
        let restSpan = TimeSpan(
            start: restStart,
            end: restStart.addingTimeInterval(3 * hour)
        )
        let motionActuals = MotionActivityActualEngine.records(
            from: [
                MotionActivityRecord(
                    span: restSpan,
                    motion: .stationary,
                    confidence: .high
                )
            ],
            existing: [],
            inside: day
        )
        XCTAssertEqual(motionActuals.map(\.title), ["정지·휴식"])

        let contextRecords = StationaryContextActualEngine.records(
            stays: [],
            placeKinds: [:],
            stationarySpans: [restSpan],
            inside: day,
            calendar: utcCalendar,
            now: day.end
        )

        XCTAssertEqual(contextRecords.map(\.title), ["머무름"])
        XCTAssertEqual(contextRecords.first?.confidence, .low)
        XCTAssertEqual(contextRecords.first?.categoryID, "activity")
        XCTAssertEqual(contextRecords.first?.startedAt, restSpan.start)
        XCTAssertEqual(contextRecords.first?.endedAt, restSpan.end)

        let merged = StationaryContextActualEngine.suppressingStationaryMotion(
            motionActuals,
            coveredBy: contextRecords,
            asOf: day.end
        ) + contextRecords
        XCTAssertFalse(merged.contains { $0.title == "정지·휴식" })
    }

    func testStationaryContextFillsTheStationaryTimeAroundAPlaceStay() {
        let dayStart = makeDate(2026, 8, 4, 0, 0)
        let day = TimeSpan(
            start: dayStart,
            end: dayStart.addingTimeInterval(24 * hour)
        )
        let officeStart = makeDate(2026, 8, 4, 10, 0)
        let stay = makeContextStay(
            start: officeStart,
            end: officeStart.addingTimeInterval(2 * hour),
            placeKey: "frequent-office"
        )
        let records = StationaryContextActualEngine.records(
            stays: [stay],
            placeKinds: ["frequent-office": .company],
            stationarySpans: [
                TimeSpan(
                    start: officeStart.addingTimeInterval(-hour),
                    end: officeStart.addingTimeInterval(3 * hour)
                )
            ],
            inside: day,
            calendar: utcCalendar,
            now: day.end
        )

        XCTAssertEqual(records.map(\.title), ["머무름", "근무", "머무름"])
        XCTAssertEqual(records.first?.endedAt, stay.span.start)
        XCTAssertEqual(records.last?.startedAt, stay.span.end)
        XCTAssertEqual(
            Set(records.map(\.id)).count,
            records.count,
            "같은 갱신에서 만든 기록의 식별자가 겹친다"
        )
    }

    /// 시간대만으로는 근무를 만들지 않는다. 평일 낮의 집이 "근무"가 되면
    /// 안 된다.
    func testStationaryContextDoesNotInventWorkFromWeekdayHoursAlone() {
        let start = makeDate(2026, 8, 4, 14, 0)
        let inference = StationaryContextClassifier().classify(
            StationaryContextInput(
                stay: makeContextStay(
                    start: start,
                    end: start.addingTimeInterval(2 * hour)
                ),
                placeKind: nil,
                calendar: utcCalendar,
                now: start.addingTimeInterval(3 * hour)
            )
        )

        XCTAssertEqual(inference.kind, .unknownStay)
        XCTAssertEqual(inference.confidence, .low)
    }

    /// "대기"가 이동 종류였을 때는 앞뒤 이동과 겹친다고 보고 화면에서
    /// 지워졌다. 정지 문맥은 모두 활동 줄에 남아야 한다.
    func testWaitingRecordSurvivesMovementDisplayFiltering() {
        let start = makeDate(2026, 8, 4, 10, 0)
        let end = start.addingTimeInterval(10 * 60)
        let travel = [
            TravelSegment(
                mode: .walking,
                span: TimeSpan(
                    start: start.addingTimeInterval(-10 * 60),
                    end: start.addingTimeInterval(3 * 60)
                ),
                distanceMeters: 500,
                confidence: .medium,
                evidence: ["걸음 수"]
            ),
            TravelSegment(
                mode: .subway,
                span: TimeSpan(start: end, end: end.addingTimeInterval(20 * 60)),
                distanceMeters: 6_000,
                confidence: .medium,
                evidence: ["역 근처"]
            ),
        ]
        let records = StationaryContextActualEngine.records(
            stays: [makeContextStay(start: start, end: end)],
            placeKinds: [:],
            travel: travel,
            inside: TimeSpan(start: start, end: end.addingTimeInterval(hour)),
            calendar: utcCalendar,
            now: end.addingTimeInterval(hour)
        )

        XCTAssertEqual(records.map(\.title), ["대기"])
        XCTAssertEqual(records.first?.categoryID, "activity")
        XCTAssertEqual(
            MovementDisplayEngine.visibleActuals(
                records,
                travel: travel,
                asOf: end.addingTimeInterval(hour)
            ).map(\.title),
            ["대기"]
        )
    }

    /// 문맥 기록은 "정지·휴식"만 대신한다. 같은 시간에 잡힌 걷기는 남는다.
    func testStationaryContextDoesNotSwallowWalkingActivities() {
        let dayStart = makeDate(2026, 8, 4, 0, 0)
        let day = TimeSpan(
            start: dayStart,
            end: dayStart.addingTimeInterval(24 * hour)
        )
        let officeStart = makeDate(2026, 8, 4, 10, 0)
        let context = StationaryContextActualEngine.records(
            stays: [
                makeContextStay(
                    start: officeStart,
                    end: officeStart.addingTimeInterval(3 * hour),
                    placeKey: "frequent-office"
                )
            ],
            placeKinds: ["frequent-office": .company],
            inside: day,
            calendar: utcCalendar,
            now: day.end
        )
        XCTAssertEqual(context.map(\.title), ["근무"])

        let regenerated = MotionActivityActualEngine.records(
            from: [
                MotionActivityRecord(
                    span: TimeSpan(
                        start: officeStart.addingTimeInterval(30 * 60),
                        end: officeStart.addingTimeInterval(34 * 60)
                    ),
                    motion: .walking,
                    confidence: .high
                ),
                MotionActivityRecord(
                    span: TimeSpan(
                        start: officeStart.addingTimeInterval(40 * 60),
                        end: officeStart.addingTimeInterval(2 * hour)
                    ),
                    motion: .stationary,
                    confidence: .high
                ),
            ],
            existing: context,
            inside: day
        )

        XCTAssertEqual(regenerated.map(\.title), ["걷기"])
    }

    private func makeContextStay(
        start: Date,
        end: Date,
        placeKey: String = "frequent-context"
    ) -> PlaceStay {
        PlaceStay(
            placeKey: placeKey,
            displayName: "장소",
            span: TimeSpan(start: start, end: end),
            confidence: .medium
        )
    }

    private func makeContextEvent(
        title: String,
        start: Date,
        end: Date,
        attendeeCount: Int? = nil
    ) -> CalendarRecord {
        CalendarRecord(
            id: title,
            calendarID: "calendar",
            title: title,
            span: TimeSpan(start: start, end: end),
            isAllDay: false,
            calendarTitle: "업무",
            attendeeCount: attendeeCount,
            isCancelled: false
        )
    }

    private func makeContextActual(
        source: ActualSource,
        start: Date,
        end: Date
    ) -> ActualRecord {
        ActualRecord(
            planID: nil,
            title: "자동 기록",
            categoryID: "activity",
            startedAt: start,
            endedAt: end,
            source: source,
            confidence: .medium,
            createdAt: start
        )
    }

    private func makeContextReading(
        at timestamp: Date,
        flat: Bool
    ) -> SensorReading {
        SensorReading(
            timestamp: timestamp,
            motion: .stationary,
            motionConfidence: .high,
            deviceMotion: DeviceMotionSnapshot(
                gravity: SensorVector3(
                    x: 0,
                    y: flat ? 0 : -0.99,
                    z: flat ? -0.99 : 0.02
                ),
                userAcceleration: SensorVector3(x: 0, y: 0, z: 0),
                rotationRate: SensorVector3(x: 0, y: 0, z: 0),
                attitudeRadians: SensorVector3(x: 0, y: 0, z: 0)
            ),
            deviceMotionSummary: DeviceMotionSummary(
                sampleCount: 100,
                meanUserAccelerationG: 0.001,
                userAccelerationStandardDeviationG: 0.001,
                peakUserAccelerationG: 0.004,
                meanRotationRateRadiansPerSecond: 0.001,
                rotationRateStandardDeviationRadiansPerSecond: 0.001,
                peakRotationRateRadiansPerSecond: 0.003
            )
        )
    }

    func testSummaryBucketsSplitRecordsAcrossDayBoundaries() {
        let engine = TimelineAggregationEngine(calendar: utcCalendar)
        let outer = TimeSpan(
            start: makeDate(2026, 7, 1),
            end: makeDate(2026, 7, 8)
        )
        let crossing = PlanRecord(
            title: "밤샘",
            span: TimeSpan(
                start: makeDate(2026, 7, 2, 22, 0),
                end: makeDate(2026, 7, 3, 4, 0)
            ),
            categoryID: "project"
        )
        let morning = PlanRecord(
            title: "오전",
            span: TimeSpan(
                start: makeDate(2026, 7, 3, 9, 0),
                end: makeDate(2026, 7, 3, 11, 0)
            ),
            categoryID: "project"
        )
        let overlapping = PlanRecord(
            title: "겹침",
            span: TimeSpan(
                start: makeDate(2026, 7, 3, 10, 0),
                end: makeDate(2026, 7, 3, 12, 0)
            ),
            categoryID: "project"
        )
        let sleep = ActualRecord(
            planID: nil,
            title: "수면",
            categoryID: "sleep",
            startedAt: makeDate(2026, 7, 2, 23, 0),
            endedAt: makeDate(2026, 7, 3, 5, 0),
            source: .healthKit
        )
        let early = PhotoMoment(
            id: "early",
            capturedAt: makeDate(2026, 7, 3, 8, 0),
            pixelWidth: 100,
            pixelHeight: 100,
            isFavorite: false,
            isHiddenFromTimeline: false
        )
        let late = PhotoMoment(
            id: "late",
            capturedAt: makeDate(2026, 7, 3, 20, 0),
            pixelWidth: 100,
            pixelHeight: 100,
            isFavorite: false,
            isHiddenFromTimeline: false
        )
        let hidden = PhotoMoment(
            id: "hidden",
            capturedAt: makeDate(2026, 7, 3, 21, 0),
            pixelWidth: 100,
            pixelHeight: 100,
            isFavorite: false,
            isHiddenFromTimeline: true
        )

        let buckets = engine.buckets(
            of: .day,
            inside: outer,
            plans: [crossing, morning, overlapping],
            actuals: [sleep],
            photos: [late, early, hidden]
        )

        XCTAssertEqual(buckets.count, 7)

        func duration(
            _ bucket: SummaryBucket,
            _ categoryID: String
        ) -> (planned: TimeInterval, actual: TimeInterval) {
            guard let value = bucket.categories.first(where: {
                $0.categoryID == categoryID
            }) else {
                return (0, 0)
            }
            return (value.planned, value.actual)
        }

        XCTAssertEqual(duration(buckets[1], "project").planned, 2 * hour)
        XCTAssertEqual(duration(buckets[1], "sleep").actual, hour)
        // 겹치는 계획은 합쳐서 센다. 22시–4시 중 4시간에 9시–12시 3시간.
        XCTAssertEqual(duration(buckets[2], "project").planned, 7 * hour)
        XCTAssertEqual(duration(buckets[2], "sleep").actual, 5 * hour)
        XCTAssertEqual(buckets[2].photoCount, 2)
        XCTAssertEqual(buckets[2].representativePhotoID, "early")

        // 기록이 하나도 걸치지 않는 칸도 같은 분류 열쇠를 0으로 남긴다.
        XCTAssertEqual(duration(buckets[0], "project").planned, 0)
        XCTAssertEqual(duration(buckets[0], "sleep").actual, 0)
        XCTAssertEqual(buckets[0].photoCount, 0)
        XCTAssertNil(buckets[0].representativePhotoID)
    }

    // MARK: - 메모는 메모

    /// The placeholder factory always produced exactly this plan.
    private func makeMemoShellPlan(
        categoryID: String = "activity",
        categoryName: String = "활동",
        start: Date
    ) -> PlanRecord {
        PlanRecord(
            title: "메모 - \(categoryName)",
            span: TimeSpan(start: start, end: start.addingTimeInterval(60)),
            categoryID: categoryID,
            isImportant: false
        )
    }

    private func makeSnapshot(
        plans: [PlanRecord] = [],
        actuals: [ActualRecord] = [],
        recordLinks: [RecordLink] = [],
        memos: [ActionMemo] = []
    ) -> TaptionDataSnapshot {
        var snapshot = TaptionDataSnapshot.empty
        snapshot.plans = plans
        snapshot.actuals = actuals
        snapshot.recordLinks = recordLinks
        snapshot.memos = memos
        return snapshot
    }

    func testMemoShellMigrationLiftsMemoAndRemovesShellPlan() {
        let start = makeDate(2026, 8, 4, 9, 30)
        let shell = makeMemoShellPlan(start: start)
        var snapshot = makeSnapshot(
            plans: [shell],
            memos: [
                ActionMemo(planID: shell.id, kind: .idea, text: "회의 정리"),
            ]
        )

        MemoShellPlanMigration.apply(to: &snapshot)

        XCTAssertTrue(snapshot.plans.isEmpty)
        XCTAssertEqual(snapshot.memos.count, 1)
        let lifted = snapshot.memos[0]
        XCTAssertNil(lifted.planID)
        XCTAssertEqual(lifted.categoryID, "activity")
        XCTAssertEqual(lifted.occurredAt, start)
        XCTAssertEqual(lifted.text, "회의 정리")
    }

    func testMemoShellMigrationKeepsRealOneMinuteUserPlans() {
        let start = makeDate(2026, 8, 4, 9, 30)
        let sameShapeDifferentTitle = PlanRecord(
            title: "약 먹기",
            span: TimeSpan(start: start, end: start.addingTimeInterval(60)),
            categoryID: "health"
        )
        let importantShellLookalike = PlanRecord(
            title: "메모 - 활동",
            span: TimeSpan(start: start, end: start.addingTimeInterval(60)),
            categoryID: "activity",
            isImportant: true
        )
        let longerShellLookalike = PlanRecord(
            title: "메모 - 활동",
            span: TimeSpan(start: start, end: start.addingTimeInterval(120)),
            categoryID: "activity"
        )
        let trackedShellLookalike = PlanRecord(
            title: "메모 - 활동",
            span: TimeSpan(start: start, end: start.addingTimeInterval(60)),
            categoryID: "activity"
        )
        let linkedShellLookalike = PlanRecord(
            title: "메모 - 활동",
            span: TimeSpan(start: start, end: start.addingTimeInterval(60)),
            categoryID: "activity"
        )
        var snapshot = makeSnapshot(
            plans: [
                sameShapeDifferentTitle,
                importantShellLookalike,
                longerShellLookalike,
                trackedShellLookalike,
                linkedShellLookalike,
            ],
            actuals: [
                ActualRecord(
                    planID: trackedShellLookalike.id,
                    title: "메모 - 활동",
                    categoryID: "activity",
                    startedAt: start,
                    endedAt: start.addingTimeInterval(60),
                    source: .timer
                ),
            ],
            recordLinks: [
                RecordLink(
                    fromNodeID: "action.\(linkedShellLookalike.id.uuidString)",
                    toNodeID: "action.\(sameShapeDifferentTitle.id.uuidString)"
                ),
            ]
        )
        let before = snapshot.plans

        MemoShellPlanMigration.apply(to: &snapshot)

        XCTAssertEqual(snapshot.plans, before)
    }

    func testMemoShellMigrationIsIdempotent() {
        let start = makeDate(2026, 8, 4, 9, 30)
        let shell = makeMemoShellPlan(start: start)
        let keeper = PlanRecord(
            title: "논문 읽기",
            span: TimeSpan(start: start, end: start.addingTimeInterval(3_600)),
            categoryID: "study"
        )
        var snapshot = makeSnapshot(
            plans: [shell, keeper],
            memos: [
                ActionMemo(planID: shell.id, kind: .idea, text: "회의 정리"),
                ActionMemo(planID: keeper.id, kind: .idea, text: "3장까지"),
            ]
        )

        MemoShellPlanMigration.apply(to: &snapshot)
        let once = snapshot
        MemoShellPlanMigration.apply(to: &snapshot)

        XCTAssertEqual(snapshot, once)
        XCTAssertEqual(snapshot.plans.map(\.id), [keeper.id])
        XCTAssertEqual(
            snapshot.memos.first { $0.text == "3장까지" }?.planID,
            keeper.id
        )
    }

    @MainActor
    func testSavingCategoryMemoCreatesNoPlan() async {
        let repository = InMemoryPlanRepository()
        let model = AppModel(repository: repository, cloudSyncService: nil)
        let day = makeDate(2026, 8, 4, 9, 30)

        model.addMemo(
            text: "무릎 상태 확인",
            kind: .idea,
            categoryID: "activity",
            on: day
        )

        XCTAssertTrue(model.snapshot.plans.isEmpty)
        XCTAssertEqual(model.snapshot.memos.count, 1)
        let saved = model.memos(forCategoryID: "activity", on: day)
        XCTAssertEqual(saved.map(\.text), ["무릎 상태 확인"])
        XCTAssertNil(saved.first?.planID)
    }

    // MARK: - 메모 줄

    /// 메모 입력의 입구는 하나뿐이다. 계획도 기록도 카테고리도 고르지 않고
    /// 순간 하나만 받아 저장하며, 그 순간이 곧 메모 줄에서의 자리다.
    @MainActor
    func testGlobalMemoEntryHasNoHostAndLandsOnTheMemoRowAtOccurredAt() async throws {
        let model = AppModel(
            repository: InMemoryPlanRepository(),
            cloudSyncService: nil
        )
        let instant = makeDate(2026, 8, 4, 14, 12)
        let day = TimeSpan(
            start: makeDate(2026, 8, 4),
            end: makeDate(2026, 8, 5)
        )

        model.openMemoEntry(at: instant)
        XCTAssertEqual(model.detail, .memo)
        XCTAssertEqual(model.memoEntry?.occurredAt, instant)
        model.addMemoAtEntryInstant(text: "여기서 막혔다", kind: .blocker)

        XCTAssertTrue(model.snapshot.plans.isEmpty)
        let saved = try XCTUnwrap(model.snapshot.memos.first)
        XCTAssertEqual(model.snapshot.memos.count, 1)
        XCTAssertNil(saved.planID)
        XCTAssertNil(saved.targetID)
        XCTAssertEqual(saved.categoryID, MemoTimelineEngine.categoryID)
        XCTAssertEqual(saved.occurredAt, instant)

        let markers = MemoTimelineEngine.markers(
            from: model.timelineMemos(in: day),
            in: day,
            visibleDuration: day.duration
        )
        XCTAssertEqual(markers.map(\.span.start), [instant])
        XCTAssertEqual(markers.map(\.title), ["여기서 막혔다"])
        XCTAssertEqual(markers.map(\.memoIDs), [[saved.id]])

        // 표식을 다시 누르면 그 자리의 메모가 열린다.
        let marker = try XCTUnwrap(markers.first)
        model.openMemoEntry(
            at: marker.span.start,
            memoIDs: MemoTimelineEngine.memoIDs(
                in: marker.span,
                from: model.snapshot.memos
            )
        )
        XCTAssertEqual(model.memoEntryMemos.map(\.id), [saved.id])
        model.deleteMemo(saved.id)
        XCTAssertTrue(model.memoEntryMemos.isEmpty)
        XCTAssertEqual(model.memoEntry?.memoIDs, [])
    }

    /// 메모를 더해도 시간표가 다시 그려지지 않으면 새 메모가 줄에 나타나지
    /// 않는다. 배치 캐시를 깨우는 개정 번호가 메모까지 본다.
    @MainActor
    func testSavingAMemoInvalidatesTheTimelineLayout() async {
        let model = AppModel(
            repository: InMemoryPlanRepository(),
            cloudSyncService: nil
        )
        let before = model.timelineRevision
        model.openMemoEntry(at: makeDate(2026, 8, 4, 14, 12))
        model.addMemoAtEntryInstant(text: "여기서 막혔다", kind: .blocker)
        XCTAssertNotEqual(model.timelineRevision, before)
    }

    /// 순간을 그리는 표식이 화소보다 얇아지면 안 된다. 붙어 있는 메모는 낱개로
    /// 그리지 않고 하나로 합친다 — 눈금판 띠와 같은 기준을 쓴다.
    func testClusteredMemosMergeIntoOneMarkerInsteadOfSlivers() throws {
        let base = makeDate(2026, 8, 4, 9, 0)
        let day = TimeSpan(
            start: makeDate(2026, 8, 4),
            end: makeDate(2026, 8, 5)
        )
        let clustered = (0..<5).map { offset in
            memoFixture(at: base.addingTimeInterval(Double(offset) * 60))
        }

        let merged = MemoTimelineEngine.markers(
            from: clustered,
            in: day,
            visibleDuration: day.duration
        )
        let marker = try XCTUnwrap(merged.first)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(marker.count, 5)
        XCTAssertEqual(marker.title, "메모 5개")
        XCTAssertEqual(marker.span.start, base)
        // 합쳐도 표식 하나 길이 아래로는 내려가지 않는다.
        XCTAssertGreaterThanOrEqual(
            marker.span.duration,
            MemoTimelineEngine.markerDuration
        )
        XCTAssertEqual(
            MemoTimelineEngine.memoIDs(in: marker.span, from: clustered),
            clustered.map(\.id)
        )

        // 표식 하나 길이보다 멀리 떨어진 메모는 합쳐지지 않는다.
        let apart = clustered + [
            memoFixture(at: base.addingTimeInterval(3_600)),
        ]
        let separate = MemoTimelineEngine.markers(
            from: apart,
            in: day,
            visibleDuration: day.duration
        )
        XCTAssertEqual(separate.map(\.count), [5, 1])
        // 이웃 표식의 메모를 끌어오지 않는다.
        XCTAssertEqual(
            MemoTimelineEngine.memoIDs(
                in: try XCTUnwrap(separate.first).span,
                from: apart
            )
            .count,
            5
        )
    }

    /// 주·월·년으로 넓힐수록 표식은 더 크게 뭉친다. 하루에서 30분씩 떨어져
    /// 보이던 메모 셋은 주 배율에서 이미 한 표식이다.
    func testMemoRowCollapsesFurtherAsTheScaleWidens() throws {
        let base = makeDate(2026, 8, 4, 9, 0)
        let memos = (0..<3).map { offset in
            memoFixture(at: base.addingTimeInterval(Double(offset) * 30 * 60))
        }
        let day = TimeSpan(
            start: makeDate(2026, 8, 4),
            end: makeDate(2026, 8, 5)
        )
        let week = TimeSpan(
            start: makeDate(2026, 8, 3),
            end: makeDate(2026, 8, 10)
        )
        let month = TimeSpan(
            start: makeDate(2026, 8, 1),
            end: makeDate(2026, 9, 1)
        )
        let year = TimeSpan(
            start: makeDate(2026, 1, 1),
            end: makeDate(2027, 1, 1)
        )

        func markers(_ span: TimeSpan) -> [MemoTimelineEngine.Marker] {
            MemoTimelineEngine.markers(
                from: memos,
                in: span,
                visibleDuration: span.duration
            )
        }

        XCTAssertEqual(markers(day).map(\.count), [1, 1, 1])
        XCTAssertEqual(markers(week).map(\.count), [3])
        XCTAssertEqual(markers(month).map(\.count), [3])
        XCTAssertEqual(markers(year).map(\.count), [3])
        XCTAssertEqual(markers(year).map(\.title), ["메모 3개"])
        // 넓은 배율일수록 더 많이 합친다.
        let intervals = [day, week, month, year].map {
            MemoTimelineEngine.clusterInterval(visibleDuration: $0.duration)
        }
        XCTAssertEqual(intervals, intervals.sorted())
        XCTAssertEqual(intervals.first, MemoTimelineEngine.markerDuration)
        // 기간 밖의 메모는 그 줄에 오르지 않는다.
        XCTAssertTrue(
            MemoTimelineEngine.markers(
                from: memos,
                in: TimeSpan(
                    start: makeDate(2026, 8, 5),
                    end: makeDate(2026, 8, 6)
                ),
                visibleDuration: 86_400
            )
            .isEmpty
        )
    }

    /// 하단 메모 카드는 보고 있는 기간의 메모를 시각 순서대로 편다. 표식과
    /// 달리 합치지 않아야 하나씩 눌러 열 수 있다.
    func testMemoDetailCardListsEveryMemoInTheVisibleSpanInOrder() {
        let day = TimeSpan(
            start: makeDate(2026, 8, 4),
            end: makeDate(2026, 8, 5)
        )
        let morning = memoFixture(at: makeDate(2026, 8, 4, 9, 0))
        // 표식 하나로 합쳐질 만큼 붙어 있어도 카드에서는 따로 선다.
        let alongside = memoFixture(at: makeDate(2026, 8, 4, 9, 1))
        let evening = memoFixture(at: makeDate(2026, 8, 4, 21, 30))
        let nextDay = memoFixture(at: makeDate(2026, 8, 5, 8, 0))

        let listed = MemoTimelineEngine.detailList(
            in: day,
            from: [evening, nextDay, alongside, morning]
        )
        XCTAssertEqual(
            listed.map(\.id),
            [morning.id, alongside.id, evening.id]
        )
        XCTAssertEqual(
            MemoTimelineEngine.markers(
                from: listed,
                in: day,
                visibleDuration: day.duration
            )
            .count,
            2
        )
    }

    /// 메모가 없는 기간에서는 목록이 빈다. 하단의 메모 알약과 카드는 다른
    /// 줄과 같은 규칙으로 이 값을 보고 함께 나타나고 함께 빠진다.
    func testMemoDetailCardIsEmptyWhenTheVisibleSpanHasNoMemo() {
        let memo = memoFixture(at: makeDate(2026, 8, 4, 9, 0))
        let emptyDay = TimeSpan(
            start: makeDate(2026, 8, 5),
            end: makeDate(2026, 8, 6)
        )
        XCTAssertTrue(
            MemoTimelineEngine.detailList(in: emptyDay, from: [memo]).isEmpty
        )
        XCTAssertTrue(
            MemoTimelineEngine.detailList(in: emptyDay, from: []).isEmpty
        )
        // 같은 메모라도 그 메모가 놓인 기간에서는 카드에 오른다.
        XCTAssertEqual(
            MemoTimelineEngine.detailList(
                in: TimeSpan(
                    start: makeDate(2026, 8, 4),
                    end: makeDate(2026, 8, 5)
                ),
                from: [memo]
            )
            .map(\.id),
            [memo.id]
        )
    }

    /// 메모는 "지금" 남기는 것이 기본이지만, 지난 기간을 펼쳐 두었다면 그
    /// 기간에 남는다. 어제에 남긴 메모는 어제에 남는다.
    func testMemoEntryInstantFollowsTheTimelineNotTheWallClock() {
        let now = makeDate(2026, 8, 4, 14, 0)
        XCTAssertEqual(
            MemoTimelineEngine.entryDate(
                now: now,
                visibleSpan: TimeSpan(
                    start: makeDate(2026, 8, 4),
                    end: makeDate(2026, 8, 5)
                )
            ),
            now
        )
        XCTAssertEqual(
            MemoTimelineEngine.entryDate(
                now: now,
                visibleSpan: TimeSpan(
                    start: makeDate(2026, 8, 3),
                    end: makeDate(2026, 8, 4)
                )
            ),
            makeDate(2026, 8, 3, 12, 0)
        )
    }

    private func memoFixture(at instant: Date) -> ActionMemo {
        ActionMemo(
            categoryID: MemoTimelineEngine.categoryID,
            occurredAt: instant,
            kind: .idea,
            text: "메모 \(instant.timeIntervalSinceReferenceDate)",
            createdAt: instant,
            updatedAt: instant
        )
    }

    func testStandaloneMemoSurvivesRepositoryRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = FilePlanRepository(
            fileURL: directory.appendingPathComponent("taption-data-v1.json")
        )
        let occurredAt = makeDate(2026, 8, 4, 9, 30)
        let memo = ActionMemo(
            categoryID: "activity",
            occurredAt: occurredAt,
            kind: .idea,
            text: "무릎 상태 확인",
            createdAt: occurredAt,
            updatedAt: occurredAt
        )
        var snapshot = TaptionDataSnapshot.empty
        snapshot.memos = [memo]

        try await repository.save(snapshot)
        let loaded = try await repository.load()

        XCTAssertTrue(loaded.plans.isEmpty)
        XCTAssertEqual(loaded.memos, [memo])
    }

    /// Archives written before memos had their own identity carry a required
    /// `planID` and neither `categoryID` nor `occurredAt`.
    func testLegacyMemoDecodesWithPlanDerivedDefaults() throws {
        let planID = UUID()
        let createdAt = makeDate(2026, 8, 4, 9, 30)
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "planID": "\(planID.uuidString)",
          "kind": "idea",
          "text": "예전 메모",
          "attachments": [],
          "isHighlightedInReview": true,
          "createdAt": \(createdAt.timeIntervalSince1970),
          "updatedAt": \(createdAt.timeIntervalSince1970)
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let memo = try decoder.decode(
            ActionMemo.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(memo.planID, planID)
        XCTAssertNil(memo.categoryID)
        XCTAssertEqual(memo.occurredAt, createdAt)
    }

    // MARK: - 기록 화면에서 여러 칸 고르기

    /// 떨어져 있는 두 주를 고르면 그 사이의 주는 어디에도 들어가지 않는다.
    /// 합계와 목록이 같은 구간 묶음을 읽으므로 두 값이 어긋나지 않는다.
    func testNonContiguousBucketSelectionAddsOnlyChosenBuckets() {
        let engine = TimelineAggregationEngine(calendar: utcCalendar)
        let asOf = makeDate(2026, 9, 1)
        let period = engine.interval(
            for: .month,
            containing: makeDate(2026, 8, 15)
        )
        let buckets = ReviewSelectionEngine.buckets(
            for: .month,
            in: period,
            calendar: engine.calendar
        )
        XCTAssertEqual(buckets.map(\.label), ["1주", "2주", "3주", "4주", "5주", "6주"])
        XCTAssertEqual(buckets[1].span.start, makeDate(2026, 8, 3))
        XCTAssertEqual(buckets[3].span.start, makeDate(2026, 8, 17))

        let chosen = ActualRecord(
            planID: nil,
            title: "학습",
            categoryID: "study",
            startedAt: makeDate(2026, 8, 4, 9, 0),
            endedAt: makeDate(2026, 8, 4, 11, 0),
            source: .manual
        )
        let skipped = ActualRecord(
            planID: nil,
            title: "학습",
            categoryID: "study",
            startedAt: makeDate(2026, 8, 12, 9, 0),
            endedAt: makeDate(2026, 8, 12, 10, 0),
            source: .manual
        )
        let alsoChosen = ActualRecord(
            planID: nil,
            title: "달리기",
            categoryID: "exercise",
            startedAt: makeDate(2026, 8, 18, 9, 0),
            endedAt: makeDate(2026, 8, 18, 12, 0),
            source: .manual
        )
        let actuals = [chosen, skipped, alsoChosen]

        let spans = ReviewSelectionEngine.spans(
            period: period,
            buckets: buckets,
            selectedIDs: [buckets[1].id, buckets[3].id]
        )
        XCTAssertEqual(spans, [buckets[1].span, buckets[3].span])

        let report = ReviewEngine(calendar: utcCalendar).report(
            over: spans,
            plans: [],
            actuals: actuals,
            weather: [],
            photos: [],
            memos: [],
            asOf: asOf
        )
        XCTAssertEqual(report.actualDuration, 5 * hour)

        let groups = ActualRecordGroupingEngine.groups(
            actuals: actuals,
            in: spans,
            categories: [],
            asOf: asOf
        )
        XCTAssertEqual(
            groups.reduce(0) { $0 + $1.duration },
            report.actualDuration
        )
        XCTAssertEqual(Set(groups.map(\.id)), ["study", "exercise"])
        XCTAssertEqual(groups.first { $0.id == "study" }?.duration, 2 * hour)
        XCTAssertFalse(
            groups.contains { $0.children.contains { $0.recordID == skipped.id } }
        )

        // 붙어 있는 칸을 고르면 하나의 구간으로 이어진다.
        let adjacent = ReviewSelectionEngine.spans(
            period: period,
            buckets: buckets,
            selectedIDs: [buckets[1].id, buckets[2].id]
        )
        XCTAssertEqual(
            adjacent,
            [TimeSpan(start: buckets[1].span.start, end: buckets[2].span.end)]
        )
    }

    /// 고른 칸을 모두 끄면 지금까지의 화면(기간 하나)으로 돌아간다. 지난
    /// 기간의 칸만 남아 있을 때도 마찬가지라 빈 화면에 갇히지 않는다.
    func testClearingBucketSelectionRestoresWholePeriod() {
        let engine = TimelineAggregationEngine(calendar: utcCalendar)
        let asOf = makeDate(2026, 9, 1)
        let date = makeDate(2026, 8, 15)
        let period = engine.interval(for: .month, containing: date)
        let buckets = ReviewSelectionEngine.buckets(
            for: .month,
            in: period,
            calendar: engine.calendar
        )
        let actual = ActualRecord(
            planID: nil,
            title: "학습",
            categoryID: "study",
            startedAt: makeDate(2026, 8, 12, 9, 0),
            endedAt: makeDate(2026, 8, 12, 10, 0),
            source: .manual
        )

        XCTAssertEqual(
            ReviewSelectionEngine.spans(
                period: period,
                buckets: buckets,
                selectedIDs: []
            ),
            [period]
        )
        XCTAssertEqual(
            ReviewSelectionEngine.spans(
                period: period,
                buckets: buckets,
                selectedIDs: ["지난 달에 고른 칸"]
            ),
            [period]
        )

        let review = ReviewEngine(calendar: utcCalendar)
        let cleared = review.report(
            over: [period],
            plans: [],
            actuals: [actual],
            weather: [],
            photos: [],
            memos: [],
            asOf: asOf
        )
        let single = review.report(
            for: .month,
            containing: date,
            plans: [],
            actuals: [actual],
            weather: [],
            photos: [],
            memos: [],
            asOf: asOf
        )
        XCTAssertEqual(cleared.span, single.span)
        XCTAssertEqual(cleared.categories, single.categories)
        XCTAssertEqual(cleared.actualDuration, single.actualDuration)
        XCTAssertEqual(cleared.actualDuration, hour)
    }

    /// 하루는 나눠 고르지 않는다. 어떤 칸을 고른 척해도 하루 전체를 읽는다.
    func testDayScaleKeepsSinglePeriodBehaviour() {
        let engine = TimelineAggregationEngine(calendar: utcCalendar)
        let asOf = makeDate(2026, 8, 5)
        let day = engine.interval(
            for: .day,
            containing: makeDate(2026, 8, 4, 10, 0)
        )
        XCTAssertNil(ReviewSelectionEngine.bucketLevel(for: .day))
        XCTAssertTrue(
            ReviewSelectionEngine.buckets(
                for: .day,
                in: day,
                calendar: engine.calendar
            ).isEmpty
        )
        XCTAssertEqual(
            ReviewSelectionEngine.spans(
                period: day,
                buckets: [],
                selectedIDs: ["주에서 고른 칸"]
            ),
            [day]
        )

        let actual = ActualRecord(
            planID: nil,
            title: "학습",
            categoryID: "study",
            startedAt: makeDate(2026, 8, 4, 9, 0),
            endedAt: makeDate(2026, 8, 4, 11, 0),
            source: .manual
        )
        XCTAssertEqual(
            ActualRecordGroupingEngine.groups(
                actuals: [actual],
                in: [day],
                categories: [],
                asOf: asOf
            ),
            ActualRecordGroupingEngine.groups(
                actuals: [actual],
                in: day,
                categories: [],
                asOf: asOf
            )
        )
    }

    // MARK: - 하루 눈금판 안쪽 띠

    /// 겹쳐 들어온 수면 단계는 한 줄로 펴고, 화소보다 얇게 그려질 3분짜리
    /// 각성은 이웃에 합친다. 조각을 그대로 그리면 눈에 보이지도 않으면서
    /// 그리는 값만 늘어난다.
    func testSleepStageRingFlattensOverlapAndMergesTooShortStage() throws {
        let dayStart = makeDate(2026, 8, 4)
        let day = TimeSpan(
            start: dayStart,
            end: dayStart.addingTimeInterval(24 * hour)
        )
        func segment(
            _ stage: SleepStage,
            _ from: Double,
            _ to: Double
        ) -> SleepSegment {
            SleepSegment(
                stage: stage,
                span: TimeSpan(
                    start: dayStart.addingTimeInterval(from * hour),
                    end: dayStart.addingTimeInterval(to * hour)
                ),
                sourceName: "Apple Watch"
            )
        }
        let sessions = SleepAnalysisEngine().sessions(
            from: [
                segment(.inBed, 0, 7),
                segment(.core, 0, 1),
                segment(.deep, 1, 2),
                segment(.awake, 2, 2 + 3.0 / 60),
                segment(.core, 2 + 3.0 / 60, 4),
                segment(.rem, 4, 5),
            ]
        )
        XCTAssertEqual(sessions.count, 1)

        let ring = try XCTUnwrap(
            RecordClockDetailEngine.sleepRing(sessions: sessions, in: day)
        )
        XCTAssertEqual(ring.kind, .sleepStage)
        XCTAssertEqual(
            ring.arcs.map(\.token),
            ["core", "deep", "core", "rem", "inBed"]
        )
        // 3분짜리 각성은 앞 조각에 흡수돼 사라진다.
        XCTAssertEqual(
            ring.arcs[1].endFraction,
            (2 * hour + 180) / (24 * hour),
            accuracy: 1e-9
        )
        assertRingHasNoSlivers(ring)
    }

    /// 같은 이동 수단이 이어지면 하나로 붙이고, 너무 짧은 구간은 이웃에
    /// 합치되 이웃이 없으면 최소 길이로 넓혀 남긴다.
    func testTravelRingJoinsSameModeAndCondensesShortSegments() throws {
        let dayStart = makeDate(2026, 8, 4)
        let day = TimeSpan(
            start: dayStart,
            end: dayStart.addingTimeInterval(24 * hour)
        )
        func travel(
            _ mode: TravelMode,
            _ from: Double,
            _ to: Double
        ) -> TravelSegment {
            TravelSegment(
                mode: mode,
                span: TimeSpan(
                    start: dayStart.addingTimeInterval(from * hour),
                    end: dayStart.addingTimeInterval(to * hour)
                ),
                distanceMeters: 500,
                confidence: .high,
                evidence: ["GPS"]
            )
        }
        let ring = try XCTUnwrap(
            RecordClockDetailEngine.travelRing(
                segments: [
                    travel(.walking, 8, 8 + 20.0 / 60),
                    travel(.walking, 8 + 20.0 / 60, 8.5),
                    travel(.car, 9, 9 + 40.0 / 60),
                    travel(.subway, 9 + 40.0 / 60, 9 + 42.0 / 60),
                    travel(.running, 12, 12 + 2.0 / 60),
                ],
                in: day
            )
        )
        XCTAssertEqual(ring.kind, .travel)
        XCTAssertEqual(ring.arcs.map(\.token), ["walking", "car", "running"])
        XCTAssertEqual(
            ring.arcs[0].endFraction,
            8.5 / 24,
            accuracy: 1e-9
        )
        // 2분짜리 지하철은 앞선 자동차 구간에 합쳐진다.
        XCTAssertEqual(
            ring.arcs[1].endFraction,
            (9 * hour + 42 * 60) / (24 * hour),
            accuracy: 1e-9
        )
        assertRingHasNoSlivers(ring)

        XCTAssertNil(
            RecordClockDetailEngine.travelRing(segments: [], in: day)
        )
        XCTAssertNil(
            RecordClockDetailEngine.sleepRing(sessions: [], in: day)
        )
    }

    private func assertRingHasNoSlivers(
        _ ring: RecordClockDetailRing?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let ring else {
            XCTFail("띠가 없습니다.", file: file, line: line)
            return
        }
        var previousEnd = 0.0
        for arc in ring.arcs {
            XCTAssertGreaterThanOrEqual(
                arc.startFraction,
                previousEnd - 1e-9,
                "조각이 겹칩니다.",
                file: file,
                line: line
            )
            XCTAssertGreaterThanOrEqual(
                arc.endFraction - arc.startFraction,
                RecordClockDetailEngine.minimumArcFraction - 1e-9,
                "화소보다 얇은 조각이 남았습니다.",
                file: file,
                line: line
            )
            previousEnd = arc.endFraction
        }
        XCTAssertLessThanOrEqual(
            ring.arcs.count,
            RecordClockDetailEngine.maximumArcCount,
            file: file,
            line: line
        )
    }

    /// 오늘 적은 지난주 이야기는 지난주에 남는다. 메모가 놓이는 자리는
    /// 적은 시각이 아니라 그 메모가 말하는 시각이다.
    func testHighlightedMemoLandsOnTheWeekItIsAbout() {
        let occurredAt = makeDate(2026, 8, 4, 15, 0)
        let createdAt = makeDate(2026, 8, 20, 9, 0)
        let memo = ActionMemo(
            categoryID: "activity",
            occurredAt: occurredAt,
            kind: .decision,
            text: "무릎이 아팠던 날",
            createdAt: createdAt,
            updatedAt: createdAt
        )
        let engine = ReviewEngine(calendar: utcCalendar)

        let aboutWeek = engine.report(
            for: .week,
            containing: occurredAt,
            plans: [],
            actuals: [],
            weather: [],
            photos: [],
            memos: [memo],
            asOf: createdAt
        )
        XCTAssertEqual(aboutWeek.contexts.map(\.text), ["무릎이 아팠던 날"])
        XCTAssertEqual(aboutWeek.contexts.first?.date, occurredAt)

        let writtenWeek = engine.report(
            for: .week,
            containing: createdAt,
            plans: [],
            actuals: [],
            weather: [],
            photos: [],
            memos: [memo],
            asOf: createdAt
        )
        XCTAssertTrue(writtenWeek.contexts.isEmpty)
    }

    // MARK: - 현재 층수로 보정하기

    /// 주어진 고도 차이를 만드는 기압. 층 높이 계산이 쓰는 기압 공식의 역함수다.
    private func pressure(
        _ baseline: Double,
        risingBy meters: Double
    ) -> Double {
        baseline * pow(1 - meters / 44_330, 1 / 0.1903)
    }

    private func makeAltitudeReading(
        at date: Date,
        latitude: Double = 37.5,
        longitude: Double = 127,
        altitude: Double = 82,
        pressureKilopascals: Double
    ) -> SensorReading {
        SensorReading(
            timestamp: date,
            point: GeoPoint(
                latitude: latitude,
                longitude: longitude,
                altitude: altitude,
                horizontalAccuracy: 8,
                verticalAccuracy: 6
            ),
            pressureKilopascals: pressureKilopascals,
            // 앱을 다시 켠 뒤라 상대고도 세션이 끊겼다. 실제 기기에서 가장
            // 흔한 경우이므로 기압차 경로를 그대로 태운다.
            altimeterSessionID: UUID()
        )
    }

    /// 사용자는 "지금 몇 층인지"만 알려 준다. 층 높이는 서로 다른 두 층의
    /// 고도 차이에서 앱이 스스로 구한다.
    func testCurrentFloorCalibrationDerivesFloorHeightFromTwoFloors() throws {
        let base = makeDate(2026, 8, 5, 9, 0)
        let groundPressure = 101.0
        var place = FrequentPlace(kind: .company)
        XCTAssertEqual(place.floorHeightMeters, 3, accuracy: 0.001)

        place.calibrateCurrentFloor(
            to: 1,
            from: makeAltitudeReading(
                at: base,
                pressureKilopascals: groundPressure
            )
        )
        // 기준이 한 층뿐이면 잴 것이 없으므로 쓰던 값을 그대로 둔다.
        XCTAssertEqual(place.floorHeightMeters, 3, accuracy: 0.001)
        XCTAssertEqual(place.floor, 1)

        let upstairs = makeAltitudeReading(
            at: base.addingTimeInterval(600),
            latitude: 37.5002,
            pressureKilopascals: pressure(groundPressure, risingBy: 13.6)
        )
        place.calibrateCurrentFloor(to: 5, from: upstairs)

        XCTAssertEqual(place.floorHeightMeters, 3.4, accuracy: 0.05)
        XCTAssertEqual(place.floorReferencePoints.map(\.floor).sorted(), [1, 5])
        // 자리는 처음 잡은 기준점 그대로다. 층만 더한다.
        XCTAssertEqual(place.point?.latitude, 37.5)

        let estimate = FloorCalibrationEngine().estimate(
            reading: upstairs,
            calibration: try XCTUnwrap(place.floorCalibration)
        )
        XCTAssertEqual(estimate?.floor, 5)
    }

    /// 같은 층을 다시 알려 주면 그 층 기준만 갱신하고 다른 층은 남긴다.
    func testCurrentFloorCalibrationKeepsOtherFloors() {
        let base = makeDate(2026, 8, 5, 9, 0)
        let groundPressure = 101.0
        var place = FrequentPlace(kind: .home)
        place.calibrateCurrentFloor(
            to: 1,
            from: makeAltitudeReading(
                at: base,
                pressureKilopascals: groundPressure
            )
        )
        place.calibrateCurrentFloor(
            to: 5,
            from: makeAltitudeReading(
                at: base.addingTimeInterval(600),
                pressureKilopascals: pressure(groundPressure, risingBy: 13.6)
            )
        )
        place.calibrateCurrentFloor(
            to: 5,
            from: makeAltitudeReading(
                at: base.addingTimeInterval(1_200),
                pressureKilopascals: pressure(groundPressure, risingBy: 12.8)
            )
        )

        XCTAssertEqual(place.floorReferencePoints.map(\.floor).sorted(), [1, 5])
        XCTAssertEqual(place.floorHeightMeters, 3.2, accuracy: 0.05)
    }

    /// 잘못 잰 짝은 층 높이 계산에서 버린다. 억지로 끌어다 맞추면 멀쩡한
    /// 다른 기준까지 망가진다.
    func testFloorHeightEstimatorDropsImpossiblePairs() {
        let base = makeDate(2026, 8, 5, 9, 0)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 82,
            horizontalAccuracy: 8,
            verticalAccuracy: 6
        )
        let references = [
            FloorCalibrationPoint(
                floor: 1,
                point: point,
                relativeAltitudeMeters: nil,
                pressureKilopascals: 101.0,
                altimeterSessionID: UUID(),
                capturedAt: base
            ),
            FloorCalibrationPoint(
                floor: 5,
                point: point,
                relativeAltitudeMeters: nil,
                pressureKilopascals: pressure(101.0, risingBy: 60),
                altimeterSessionID: UUID(),
                capturedAt: base.addingTimeInterval(600)
            ),
        ]

        XCTAssertNil(FloorHeightEstimator.metersPerFloor(from: references))
        XCTAssertNil(
            FloorHeightEstimator.metersPerFloor(from: [references[0]])
        )
    }

    // MARK: - 어플 목록에서 iOS 내부 서비스 감추기

    private func makeUsageSample(
        key: String,
        title: String,
        nameSource: ScreenTimeUsageNameSource,
        start: Date,
        minutes: Double = 12
    ) -> ScreenTimeUsageSample {
        let span = TimeSpan(start: start, end: start.addingTimeInterval(3_600))
        return ScreenTimeUsageSample(
            key: key,
            title: title,
            span: span,
            duration: minutes * 60,
            pickups: 2,
            notifications: 1,
            nameSource: nameSource
        )
    }

    /// 스크린 타임은 화면에 뜨지 않는 iOS 서비스 프로세스까지 앱으로 올려
    /// 준다. 애플 번들 ID인데 시스템이 이름을 내주지 않은 줄만 감춘다.
    func testAppUsageRecordsHideAppleInternalServices() {
        let start = makeDate(2026, 8, 5, 9, 0)
        let samples = [
            makeUsageSample(
                key: "bundle:com.apple.ScreenshotServicesService",
                title: "ScreenshotServicesService",
                nameSource: .bundleIdentifier,
                start: start
            ),
            makeUsageSample(
                key: "bundle:com.apple.LocalAuthenticationUIService",
                title: "LocalAuthenticationUIService",
                nameSource: .bundleIdentifier,
                start: start
            ),
            makeUsageSample(
                key: "bundle:com.apple.mobilesafari",
                title: "Safari",
                nameSource: .application,
                start: start
            ),
            makeUsageSample(
                key: "bundle:com.apple.Maps",
                title: "지도",
                nameSource: .application,
                start: start
            ),
            makeUsageSample(
                key: "bundle:com.jumpdesktop.ios",
                title: "Jumpdesktop",
                nameSource: .bundleIdentifier,
                start: start
            ),
            makeUsageSample(
                key: "category:생산성",
                title: "생산성",
                nameSource: .category,
                start: start
            ),
            makeUsageSample(
                key: "total",
                title: "어플",
                nameSource: .unknown,
                start: start
            ),
        ]

        let records = ScreenTimeUsageRecordEngine.records(
            from: samples,
            suppressedIDs: []
        )

        // 이름이 온 애플 앱, 다른 회사 앱, 카테고리·합계 줄은 그대로 남는다.
        XCTAssertEqual(
            Set(records.map(\.title)),
            ["Safari", "지도", "Jumpdesktop", "생산성", "어플"]
        )
        XCTAssertTrue(
            samples
                .filter(ScreenTimeUsageRecordEngine.isHiddenSystemService)
                .map(\.title)
                .sorted()
                == ["LocalAuthenticationUIService", "ScreenshotServicesService"]
        )
    }

    /// 번들 ID가 없는 줄에는 이 규칙을 적용할 근거가 없다.
    func testHiddenSystemServiceRuleNeedsBothAppleBundleAndDerivedName() {
        let start = makeDate(2026, 8, 5, 9, 0)
        // 이름을 받은 애플 앱은 번들 ID가 애플이어도 남는다.
        XCTAssertFalse(
            ScreenTimeUsageRecordEngine.isHiddenSystemService(
                makeUsageSample(
                    key: "bundle:com.apple.MobileSMS",
                    title: "메시지",
                    nameSource: .application,
                    start: start
                )
            )
        )
        // 다른 회사 앱은 이름을 못 받아도 사용자가 직접 설치한 앱이다.
        XCTAssertFalse(
            ScreenTimeUsageRecordEngine.isHiddenSystemService(
                makeUsageSample(
                    key: "bundle:com.openai.chat",
                    title: "Chat",
                    nameSource: .bundleIdentifier,
                    start: start
                )
            )
        )
        // 토큰만 있는 줄은 번들 ID를 모르므로 판단하지 않는다.
        XCTAssertNil(
            ScreenTimeUsageRecordEngine.bundleIdentifier(
                of: makeUsageSample(
                    key: "token:abcd",
                    title: "Slideshow",
                    nameSource: .bundleIdentifier,
                    start: start
                )
            )
        )
    }

    // MARK: - 메모 이관이 메모를 잃지 않는지

    /// 실기기 모양 그대로: 카테고리 줄에 남긴 메모는 껍데기 계획에만 붙어
    /// 있었고 분류도 시각도 저장돼 있지 않았다. 이관 뒤에도 같은 분류·같은
    /// 날에서 찾을 수 있어야 하고, 기록 탭의 "이 기간을 설명한 기록"에도
    /// 그대로 떠야 한다.
    func testMemoShellMigrationKeepsLegacyMemoReachableAndRendered() throws {
        let start = makeDate(2026, 8, 4, 9, 30)
        let shell = makeMemoShellPlan(start: start)
        let legacyMemo = ActionMemo(
            planID: shell.id,
            categoryID: nil,
            occurredAt: nil,
            kind: .idea,
            text: "운동",
            createdAt: start,
            updatedAt: start
        )
        var snapshot = makeSnapshot(plans: [shell], memos: [legacyMemo])

        MemoShellPlanMigration.apply(to: &snapshot)

        XCTAssertTrue(snapshot.plans.isEmpty)
        let lifted = try XCTUnwrap(snapshot.memos.first)
        XCTAssertEqual(snapshot.memos.count, 1)
        XCTAssertEqual(lifted.id, legacyMemo.id)
        XCTAssertEqual(lifted.text, "운동")
        XCTAssertNil(lifted.planID)
        XCTAssertNil(lifted.targetID)
        XCTAssertEqual(lifted.categoryID, "activity")
        XCTAssertEqual(lifted.occurredAt, start)

        // 기록 탭의 맥락 줄을 만드는 바로 그 엔진.
        let report = ReviewEngine(calendar: utcCalendar).report(
            for: .day,
            containing: start,
            plans: snapshot.plans,
            actuals: [],
            weather: [],
            photos: [],
            memos: snapshot.memos,
            asOf: start.addingTimeInterval(hour)
        )
        XCTAssertEqual(report.contexts.map(\.text), ["운동"])
        XCTAssertEqual(report.contexts.map(\.symbolName), ["note.text"])
    }

    /// 자동 기록 줄에 남긴 메모는 껍데기 계획과 기록 키를 함께 들고 있었다.
    /// 이관은 계획 고리만 끊고 기록 키는 그대로 둬야 한다.
    func testMemoShellMigrationKeepsAutomaticRecordTargetKey() throws {
        let start = makeDate(2026, 8, 4, 9, 30)
        let shell = makeMemoShellPlan(start: start)
        let targetID = "automatic.actual.\(UUID().uuidString)"
        var snapshot = makeSnapshot(
            plans: [shell],
            memos: [
                ActionMemo(
                    planID: shell.id,
                    targetID: targetID,
                    kind: .idea,
                    text: "무릎 상태 확인",
                    createdAt: start,
                    updatedAt: start
                ),
            ]
        )

        MemoShellPlanMigration.apply(to: &snapshot)

        let lifted = try XCTUnwrap(snapshot.memos.first)
        XCTAssertNil(lifted.planID)
        XCTAssertEqual(lifted.targetID, targetID)
        XCTAssertEqual(lifted.categoryID, "activity")
        XCTAssertEqual(lifted.occurredAt, start)

        let report = ReviewEngine(calendar: utcCalendar).report(
            for: .day,
            containing: start,
            plans: snapshot.plans,
            actuals: [],
            weather: [],
            photos: [],
            memos: snapshot.memos,
            asOf: start.addingTimeInterval(hour)
        )
        XCTAssertEqual(report.contexts.map(\.text), ["무릎 상태 확인"])
    }

    /// 저장소에서 불러오는 실제 경로를 그대로 태운다. 껍데기 계획은 사라지고
    /// 메모는 분류 줄에서 다시 찾을 수 있어야 한다.
    @MainActor
    func testMemoShellMigrationSurvivesAppLoad() async {
        let start = makeDate(2026, 8, 4, 9, 30)
        let shell = makeMemoShellPlan(start: start)
        var stored = makeSnapshot(
            plans: [shell],
            memos: [
                ActionMemo(
                    planID: shell.id,
                    kind: .idea,
                    text: "운동",
                    createdAt: start,
                    updatedAt: start
                ),
            ]
        )
        stored.updatedAt = start
        stored.categories = CategoryCatalog.builtIn
        let model = AppModel(
            repository: InMemoryPlanRepository(snapshot: stored),
            cloudSyncService: nil
        )

        await model.bootstrap()
        // 이관은 첫 화면을 붙잡지 않도록 별도 작업에서 돈다.
        let deadline = Date.now.addingTimeInterval(10)
        while !model.snapshot.plans.isEmpty, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertTrue(model.snapshot.plans.isEmpty)
        XCTAssertEqual(model.snapshot.memos.count, 1)
        XCTAssertEqual(
            model.memos(forCategoryID: "activity", on: start).map(\.text),
            ["운동"]
        )
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        return calendar
    }

    private func makeDate(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 0,
        _ minute: Int = 0
    ) -> Date {
        utcCalendar.date(
            from: DateComponents(
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            )
        )!
    }
}

private struct RawArchiveWatchFixture: Codable, Hashable {
    var sampleCount: Int
    var mode: String
}

private final class AirQualityURLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler:
        ((URLRequest) throws -> (Int, Data))?
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requestCount += 1
        guard let handler = Self.handler else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
