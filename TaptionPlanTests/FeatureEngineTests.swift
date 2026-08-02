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
            ["정지·휴식", "걷기", "달리기", "자전거", "차량 탑승"]
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

    func testWidgetPlaybackAlwaysKeepsFiveAutomaticLanes() {
        let base = makeDate(2026, 8, 1, 12, 0)

        XCTAssertEqual(
            TaptionWidgetPlaybackEngine.lanes(
                for: [],
                at: base
            ),
            [.schedule, .location, .movement, .sleep, .activity]
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
            [.schedule, .location, .movement, .sleep, .activity, .action]
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

    func testPeriodNavigationRequiresDataInAdjacentPeriodForEveryScale() throws {
        let date = makeDate(2026, 7, 31, 12)
        let engine = TimelinePeriodNavigationEngine(calendar: utcCalendar)
        let aggregation = TimelineAggregationEngine(calendar: utcCalendar)

        for level in TimelineLevel.allCases {
            XCTAssertFalse(
                engine.canNavigate(
                    from: date,
                    level: level,
                    direction: 1,
                    snapshot: .empty
                ),
                "\(level.rawValue) should be disabled without data"
            )

            let nextDate = try XCTUnwrap(
                engine.adjacentDate(
                    from: date,
                    level: level,
                    direction: 1
                )
            )
            let nextSpan = aggregation.interval(
                for: level,
                containing: nextDate
            )
            var snapshot = TaptionDataSnapshot.empty
            snapshot.plans = [
                PlanRecord(
                    title: "다음 기간 계획",
                    span: TimeSpan(
                        start: nextSpan.start.addingTimeInterval(60),
                        end: nextSpan.start.addingTimeInterval(hour)
                    ),
                    categoryID: "project"
                )
            ]

            XCTAssertTrue(
                engine.canNavigate(
                    from: date,
                    level: level,
                    direction: 1,
                    snapshot: snapshot
                ),
                "\(level.rawValue) should be enabled with adjacent data"
            )
            XCTAssertFalse(
                engine.canNavigate(
                    from: date,
                    level: level,
                    direction: -1,
                    snapshot: snapshot
                ),
                "\(level.rawValue) should not reuse next-period data"
            )
        }
    }

    func testPeriodNavigationUsesTimelineRecordsButNotWeatherContext() throws {
        let date = makeDate(2026, 7, 31, 12)
        let engine = TimelinePeriodNavigationEngine(calendar: utcCalendar)
        let nextDate = try XCTUnwrap(
            engine.adjacentDate(
                from: date,
                level: .day,
                direction: 1
            )
        )

        var snapshot = TaptionDataSnapshot.empty
        snapshot.weather = [
            WeatherContext(
                observedAt: nextDate,
                condition: "맑음",
                symbolName: "sun.max.fill",
                temperatureCelsius: 28
            )
        ]
        XCTAssertFalse(
            engine.canNavigate(
                from: date,
                level: .day,
                direction: 1,
                snapshot: snapshot
            )
        )

        snapshot.photos = [
            PhotoMoment(
                id: "hidden-photo",
                capturedAt: nextDate,
                pixelWidth: 1_000,
                pixelHeight: 1_000,
                isFavorite: false,
                isHiddenFromTimeline: true
            )
        ]
        XCTAssertFalse(
            engine.canNavigate(
                from: date,
                level: .day,
                direction: 1,
                snapshot: snapshot
            )
        )

        snapshot.photos[0].isHiddenFromTimeline = false
        XCTAssertTrue(
            engine.canNavigate(
                from: date,
                level: .day,
                direction: 1,
                snapshot: snapshot
            )
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
