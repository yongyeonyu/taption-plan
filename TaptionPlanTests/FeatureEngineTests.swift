import XCTest
import UIKit
import CoreLocation
import StoreKit
import StoreKitTest
import TaptionPlanCore
@testable import TaptionPlan

final class FeatureEngineTests: XCTestCase, UTCDateFixture {
    let hour: TimeInterval = 3_600

    /// 지나간 날은 확정하면 다시 계산하지 않는다. 오늘은 언제나 다시 계산한다.
    func testSettledDaysAreNotRecalculatedOnceSealed() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today

        XCTAssertFalse(PlanDayRecalculationPolicy.isSettled(today, now: now, calendar: calendar))
        XCTAssertTrue(PlanDayRecalculationPolicy.isSettled(yesterday, now: now, calendar: calendar))

        // 오늘은 확정 여부와 무관하게 다시 계산한다.
        XCTAssertTrue(PlanDayRecalculationPolicy.allowsRecalculation(
            day: today, now: now, isSealed: true, calendar: calendar
        ))
        // 지나간 날 + 확정 = 다시 계산하지 않는다.
        XCTAssertFalse(PlanDayRecalculationPolicy.allowsRecalculation(
            day: yesterday, now: now, isSealed: true, calendar: calendar
        ))
        // 사용자가 그 날 기록을 고치면(force) 다시 계산한다.
        XCTAssertTrue(PlanDayRecalculationPolicy.allowsRecalculation(
            day: yesterday, now: now, isSealed: true, force: true, calendar: calendar
        ))
        // 아직 확정하지 않은 지나간 날은 한 번 계산해 확정한다.
        XCTAssertTrue(PlanDayRecalculationPolicy.allowsRecalculation(
            day: yesterday, now: now, isSealed: false, calendar: calendar
        ))

        XCTAssertFalse(PlanDayRecalculationPolicy.canSeal(
            day: today, now: now, isComplete: true, calendar: calendar
        ))
        XCTAssertFalse(PlanDayRecalculationPolicy.canSeal(
            day: yesterday, now: now, isComplete: false, calendar: calendar
        ))
        XCTAssertTrue(PlanDayRecalculationPolicy.canSeal(
            day: yesterday, now: now, isComplete: true, calendar: calendar
        ))
    }

    @MainActor
    func testInitialSceneDoesNotWaitForFullHistoryAndRejectsPartialWrites() async throws {
        let date = Date(timeIntervalSince1970: 1_791_250_000)
        var source = TaptionDataSnapshot.empty
        source.updatedAt = date
        source.settings.locationEnabled = false
        source.settings.healthEnabled = false
        source.settings.weatherEnabled = false
        source.actuals = [ActualRecord(planID: nil, title: "합성 활동", categoryID: "eating",
            startedAt: date, endedAt: date.addingTimeInterval(60), source: .motion,
            isClassificationLocked: true)]
        let repository = GatedStartupPlanRepository(snapshot: source)
        let model = AppModel(repository: repository, cloudSyncService: nil,
            registersHealthBackgroundHandler: false)
        let start = ProcessInfo.processInfo.systemUptime
        await model.sceneBecameActive()
        XCTAssertTrue(model.hasPreparedStartupSettings)
        XCTAssertFalse(model.isBootstrapped)
        XCTAssertTrue(model.snapshot.actuals.isEmpty)
        let plan = model.addPlan(title: "준비 중 편집", categoryID: "work", startAt: date, duration: 60)
        XCTAssertNil(plan)
        let savesBeforeHydration = await repository.saves
        XCTAssertEqual(savesBeforeHydration, 0)
        print("MAP1006G01 startup_settings_ms=\((ProcessInfo.processInfo.systemUptime - start) * 1000) history_pending=true")
        await repository.releaseHistory()
        await model.prepareLocalDataForDisplay()
        XCTAssertTrue(model.isBootstrapped)
        XCTAssertEqual(model.snapshot.actuals, source.actuals)
        await model.bootstrap()
        await model.sceneEnteredBackground()
    }

    func testInitialLaunchProgressAdvancesMonotonicallyToTarget() {
        var progress = 0.0
        let targets = [0.36, 0.78, 0.98, 1.0]

        for target in targets {
            var iterations = 0
            while progress < target {
                let next = AppShellInitialLaunchProgressMath.next(
                    current: progress,
                    target: target
                )
                XCTAssertGreaterThan(next, progress)
                XCTAssertLessThanOrEqual(next, target)
                progress = next
                iterations += 1
                XCTAssertLessThan(iterations, 500)
            }
            XCTAssertEqual(progress, target, accuracy: 0.000_001)
        }
        XCTAssertEqual(
            AppShellInitialLaunchProgressMath.next(
                current: 0.9,
                target: 0.4
            ),
            0.9,
            accuracy: 0.000_001
        )
    }

    func testInitialLaunchProgressClampsInvalidValues() {
        XCTAssertEqual(
            AppShellInitialLaunchProgressMath.next(
                current: -1,
                target: 0
            ),
            0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            AppShellInitialLaunchProgressMath.next(
                current: 1,
                target: 2
            ),
            1,
            accuracy: 0.000_001
        )
    }

    func testDaySourceFingerprintIgnoresTimestampAndOtherDays() {
        let day = makeDate(2026, 8, 25)
        var first = TaptionDataSnapshot.empty
        first.updatedAt = day
        first.actuals = [
            ActualRecord(
                planID: nil,
                title: "업무",
                categoryID: "work",
                startedAt: day.addingTimeInterval(9 * 3_600),
                endedAt: day.addingTimeInterval(10 * 3_600),
                source: .manual
            ),
        ]
        var changedElsewhere = first
        changedElsewhere.updatedAt = day.addingTimeInterval(60)
        changedElsewhere.actuals.append(
            ActualRecord(
                planID: nil,
                title: "다른 날 업무",
                categoryID: "work",
                startedAt: day.addingTimeInterval(2 * 86_400),
                endedAt: day.addingTimeInterval(2 * 86_400 + 3_600),
                source: .manual
            )
        )

        XCTAssertEqual(
            PlanDayDataSnapshot.sourceFingerprint(
                date: day,
                source: first,
                calendar: utcCalendar
            ),
            PlanDayDataSnapshot.sourceFingerprint(
                date: day,
                source: changedElsewhere,
                calendar: utcCalendar
            )
        )

        changedElsewhere.actuals[0].title = "변경된 업무"
        XCTAssertNotEqual(
            PlanDayDataSnapshot.sourceFingerprint(
                date: day,
                source: first,
                calendar: utcCalendar
            ),
            PlanDayDataSnapshot.sourceFingerprint(
                date: day,
                source: changedElsewhere,
                calendar: utcCalendar
            )
        )
    }

    func testFragmentCorrectionChangesOnlyTheSelectedSplitPiece() throws {
        let start = makeDate(2026, 8, 12, 0, 0)
        let source = ActualRecord(
            planID: nil,
            title: "활동",
            categoryID: "activity",
            startedAt: start,
            endedAt: start.addingTimeInterval(8 * hour),
            source: .location
        )
        let sleep = ActualRecord(
            planID: nil,
            title: "수면",
            categoryID: "sleep",
            startedAt: start.addingTimeInterval(2 * hour),
            endedAt: start.addingTimeInterval(7 * hour),
            source: .healthKit
        )
        let period = TimeSpan(
            start: start,
            end: start.addingTimeInterval(8 * hour)
        )
        let pieces = ReviewCoverageEngine.records(
            actuals: [source, sleep],
            in: [period],
            asOf: period.end
        ).filter { $0.title == source.title }
        let selected = try XCTUnwrap(
            pieces.max { $0.startedAt < $1.startedAt }
        ).span(asOf: period.end)

        XCTAssertTrue(
            ActivityFragmentCorrectionEngine.needsSeparateRecord(
                source: source,
                displayedSpan: selected
            )
        )
        let corrected = ActivityFragmentCorrectionEngine.record(
            source: source,
            displayedSpan: selected,
            correctedSpan: selected,
            option: .custom("출근준비")
        )
        let result = ReviewCoverageEngine.records(
            actuals: [source, sleep, corrected],
            in: [period],
            asOf: period.end
        )

        XCTAssertEqual(source.title, "활동")
        XCTAssertEqual(corrected.source, .manual)
        XCTAssertNotEqual(corrected.id, source.id)
        XCTAssertEqual(
            result.first(where: { $0.startedAt == start })?.title,
            "활동"
        )
        XCTAssertEqual(
            result.first(where: {
                $0.startedAt == start.addingTimeInterval(7 * hour)
            })?.title,
            "출근준비"
        )
    }

    @MainActor
    func testSelectedDateDirectAssignmentRefreshesSelectedDayWhileActive()
        async {
        let model = await makeActiveIntegrationModel()
        let selectedDate = makeDate(2026, 8, 13, 12)
        defer { TaptionPlanDiagnosticsLogger.shared.clear() }

        model.selectedDate = selectedDate

        let starts = await waitForSelectedDateRefresh(
            model: model,
            selectedDate: selectedDate
        )
        XCTAssertEqual(starts.count, 1)
        XCTAssertTrue(
            starts.contains {
                $0.contains(
                    "\"day_start\":\"\(selectedDayStart(selectedDate))\""
                )
            }
        )

        await model.sceneEnteredBackground()
    }

    @MainActor
    func testSelectedDateRapidAssignmentsCoalesceToFinalSelectedDay()
        async {
        let model = await makeActiveIntegrationModel()
        let dates = [
            makeDate(2026, 8, 14, 12),
            makeDate(2026, 8, 15, 12),
            makeDate(2026, 8, 16, 12),
        ]
        defer { TaptionPlanDiagnosticsLogger.shared.clear() }

        for date in dates {
            model.selectedDate = date
        }

        let starts = await waitForSelectedDateRefresh(
            model: model,
            selectedDate: dates[2]
        )
        XCTAssertEqual(starts.count, 1)
        XCTAssertTrue(
            starts.contains {
                $0.contains(
                    "\"day_start\":\"\(selectedDayStart(dates[2]))\""
                )
            }
        )

        await model.sceneEnteredBackground()
    }

    @MainActor
    func testCommerceLockStopsAndResumesModelMutations() async {
        let model = AppModel(
            repository: InMemoryPlanRepository(),
            cloudSyncService: nil,
            registersHealthBackgroundHandler: false,
            startsCommerceLocked: true
        )

        XCTAssertTrue(model.isCommerceLocked)
        await model.suspendForCommerceLock()

        XCTAssertTrue(model.isCommerceLocked)

        await model.sceneBecameActive()
        XCTAssertFalse(model.isCommerceLocked)
    }

    @MainActor
    func testPartialUnconfirmedEditPreservesSourceOutsideSelectedSpan() async throws {
        let day = makeDate(2026, 8, 12)
        let source = ActualRecord(
            planID: nil,
            title: "미확인",
            categoryID: "unconfirmed",
            startedAt: day.addingTimeInterval(9 * hour),
            endedAt: day.addingTimeInterval(12 * hour),
            source: .manual,
            behavior: "unconfirmed-gap",
            manuallyCorrected: true
        )
        var stored = TaptionDataSnapshot.empty
        stored.actuals = [source]
        stored.settings.locationEnabled = false
        stored.settings.weatherEnabled = false
        stored.settings.healthEnabled = false
        let repository = InMemoryPlanRepository(snapshot: stored)
        let model = AppModel(
            repository: repository,
            cloudSyncService: nil,
            registersHealthBackgroundHandler: false
        )
        await model.bootstrap()

        let selected = TimeSpan(
            start: day.addingTimeInterval(9 * hour),
            end: day.addingTimeInterval(10 * hour)
        )
        let result = await model.saveActivitySectionEdit(
            ActivitySectionEditRequest(
                sourceIDs: [source.id],
                originalSpan: selected,
                originalOption: phaseOption("unconfirmed", title: "미확인"),
                mode: .replace(
                    editedSpan: selected,
                    option: phaseOption("work", title: "업무")
                )
            )
        )
        XCTAssertNotNil(result)
        let saved = try await repository.load()
        XCTAssertTrue(saved.actuals.contains {
            $0.categoryID == "work" && $0.startedAt == selected.start
                && $0.endedAt == selected.end
        })
        XCTAssertTrue(saved.actuals.contains {
            $0.categoryID == "unconfirmed" && $0.startedAt == selected.end
                && $0.endedAt == source.endedAt
        })
    }

    /// 굽은 길을 1m 간격으로 찍은 뒤 GPS 흔들림을 얹은 경로.
    func makeWalkPolyline(pointCount: Int) -> [CLLocationCoordinate2D] {
        (0..<pointCount).map { index in
            let progress = Double(index) / Double(max(1, pointCount - 1))
            let jitter = sin(Double(index) * 1.7) * 0.000004
            return CLLocationCoordinate2D(
                latitude: 37.5 + progress * 0.004 + jitter,
                longitude: 127.0
                    + sin(progress * .pi * 2) * 0.002
                    + cos(Double(index) * 2.3) * 0.000004
            )
        }
    }

    func restSpans(
        _ actuals: [ActualRecord],
        asOf: Date
    ) -> [TimeSpan] {
        RestSleepDisplayEngine.visibleActuals(actuals, asOf: asOf)
            .filter(RestSleepDisplayEngine.isRest)
            .map { $0.span(asOf: asOf) }
            .sorted { $0.start < $1.start }
    }

    func routineSpans(
        _ actuals: [ActualRecord],
        asOf: Date
    ) -> [TimeSpan] {
        RestSleepDisplayEngine.visibleActuals(actuals, asOf: asOf)
            .filter {
                ActualRecordCategoryResolver.categoryID(for: $0) == "routine"
            }
            .map { $0.span(asOf: asOf) }
            .sorted { $0.start < $1.start }
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
        let window = UIWindow(
            frame: CGRect(x: 0, y: 0, width: 400, height: 300)
        )
        let controller = UIViewController()
        window.rootViewController = controller
        let scrollView = UIScrollView(frame: window.bounds)
        let hostView = UIView(frame: scrollView.bounds)
        let attachmentView = TwoFingerPinchAttachment.AttachmentView()
        attachmentView.frame = hostView.bounds
        attachmentView.coordinator = coordinator
        coordinator.targetView = attachmentView

        // SwiftUI creates background representables before their final window
        // hierarchy exists. The recognizer must not stay on that temporary host.
        hostView.addSubview(attachmentView)
        attachmentView.installRecognizerIfNeeded()
        XCTAssertFalse(
            hostView.gestureRecognizers?.contains {
                $0 is UIPinchGestureRecognizer
            } ?? false
        )

        controller.view.addSubview(scrollView)
        scrollView.addSubview(hostView)
        window.isHidden = false
        attachmentView.installRecognizerIfNeeded()

        let recognizer = window.gestureRecognizers?
            .compactMap { $0 as? UIPinchGestureRecognizer }
            .first
        XCTAssertNotNil(recognizer)
        XCTAssertEqual(recognizer?.cancelsTouchesInView, false)
        XCTAssertEqual(
            scrollView.panGestureRecognizer.maximumNumberOfTouches,
            1
        )
        XCTAssertFalse(
            hostView.gestureRecognizers?.contains {
                $0 is UIPinchGestureRecognizer
            } ?? false
        )

        coordinator.onChanged(1.5, 0.25)
        coordinator.onEnded(0.75, 0.75)
        XCTAssertEqual(changed?.0 ?? 0, 1.5, accuracy: 0.0001)
        XCTAssertEqual(changed?.1 ?? 0, 0.25, accuracy: 0.0001)
        XCTAssertEqual(ended?.0 ?? 0, 0.75, accuracy: 0.0001)
        XCTAssertEqual(ended?.1 ?? 0, 0.75, accuracy: 0.0001)
        coordinator.restoreScrollTouchLimits()
    }

    @MainActor
    func testTwoFingerPinchKeepsSharedScrollLimitUntilLastAttachmentLeaves() {
        let scrollView = UIScrollView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 300)
        )
        let firstView = UIView(frame: scrollView.bounds)
        let secondView = UIView(frame: scrollView.bounds)
        scrollView.addSubview(firstView)
        scrollView.addSubview(secondView)
        let first = TwoFingerPinchAttachment.Coordinator(
            onChanged: { _, _ in },
            onEnded: { _, _ in }
        )
        let second = TwoFingerPinchAttachment.Coordinator(
            onChanged: { _, _ in },
            onEnded: { _, _ in }
        )

        let original = scrollView.panGestureRecognizer.maximumNumberOfTouches
        first.limitAncestorScrollPans(from: firstView)
        second.limitAncestorScrollPans(from: secondView)
        XCTAssertEqual(
            scrollView.panGestureRecognizer.maximumNumberOfTouches,
            1
        )

        first.restoreScrollTouchLimits()
        XCTAssertEqual(
            scrollView.panGestureRecognizer.maximumNumberOfTouches,
            1
        )
        second.restoreScrollTouchLimits()
        XCTAssertEqual(
            scrollView.panGestureRecognizer.maximumNumberOfTouches,
            original
        )
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

    func testChangingDailyDataRebuildsMonthAndYear() throws {
        let start = makeDate(2026, 2, 3, 9)
        let asOf = makeDate(2026, 2, 4)
        let id = UUID()
        var snapshot = TaptionDataSnapshot.empty
        snapshot.actuals = [
            ActualRecord(
                id: id,
                planID: nil,
                title: "업무",
                categoryID: "work",
                startedAt: start,
                endedAt: start.addingTimeInterval(hour),
                source: .manual
            )
        ]
        let original = try ReviewReportArchiveEngine.refreshed(
            snapshot: snapshot,
            asOf: asOf,
            calendar: utcCalendar
        )
        snapshot.yearlyReports = original
        snapshot.actuals[0].endedAt = start.addingTimeInterval(3 * hour)

        let updated = try ReviewReportArchiveEngine.refreshed(
            snapshot: snapshot,
            asOf: asOf,
            calendar: utcCalendar
        )
        let day = updated[0].days.first { $0.span.contains(start) }
        let month = updated[0].months[0].report.categories.first {
            $0.categoryID == "work"
        }
        let year = updated[0].report.categories.first {
            $0.categoryID == "work"
        }

        XCTAssertNotEqual(
            day?.sourceFingerprint,
            original[0].days.first { $0.span.contains(start) }?.sourceFingerprint
        )
        XCTAssertEqual(day?.groups.first { $0.id == "work" }?.duration, 3 * hour)
        XCTAssertEqual(month?.actual, 3 * hour)
        XCTAssertEqual(year?.actual, 3 * hour)
        XCTAssertEqual(day?.dayPhases?.reduce(0) { $0 + $1.actual }, 24 * hour)
        XCTAssertEqual(
            updated[0].months[0].dayPhases?.reduce(0) { $0 + $1.actual },
            24 * hour
        )
        XCTAssertEqual(
            updated[0].dayPhases?.reduce(0) { $0 + $1.actual },
            24 * hour
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

    // SUB1029A01: 역 좌표를 스치는 도로 주행은 고도 변화가 없으면 지하철이 아니다.
    func seoulDrive(pressure: (Int) -> Double?) -> [SensorReading] {
        let day = makeDate(2026, 8, 1, 9, 0)
        return stride(from: 0, through: 56, by: 2).map { minute in
            SensorReading(
                timestamp: day.addingTimeInterval(Double(minute) * 60),
                point: GeoPoint(latitude: 37.50 + Double(minute) / 600, longitude: 127, altitude: 0,
                                horizontalAccuracy: 10, verticalAccuracy: 10),
                speedMetersPerSecond: 15, motion: .automotive, motionConfidence: .high,
                pressureKilopascals: pressure(minute)
            )
        }
    }

    func testDepartureSpanKeepsUndergroundGapWithoutStillnessAtOrigin() {
        let day = makeDate(2026, 8, 1, 8, 0)
        let gap = TimeSpan(start: day, end: day.addingTimeInterval(80 * 60))
        // 지하에서 GPS만 끊긴 이동: 출발지에 머문 근거가 없으므로 처음부터 이동이다.
        let readings = [SensorReading(timestamp: day.addingTimeInterval(75 * 60), motion: .walking,
                                      motionConfidence: .high)]

        XCTAssertEqual(MovementRouteBuilder.departureSpan(gap, readings: readings, origin: nil), gap)
    }

    @MainActor
    func testAppleTransportEnrichmentDoesNotPromoteTwoRoadEndpoints() async {
        let base = makeDate(2026, 8, 18, 20, 22)
        let readings = [
            SensorReading(
                timestamp: base,
                point: GeoPoint(
                    latitude: 37.5667,
                    longitude: 126.8273,
                    altitude: 20,
                    horizontalAccuracy: 12,
                    verticalAccuracy: 8
                ),
                speedMetersPerSecond: 12,
                motion: .automotive,
                motionConfidence: .high
            ),
            SensorReading(
                timestamp: base.addingTimeInterval(25 * 60),
                point: GeoPoint(
                    latitude: 37.5248,
                    longitude: 126.6744,
                    altitude: 20,
                    horizontalAccuracy: 12,
                    verticalAccuracy: 8
                ),
                speedMetersPerSecond: 12,
                motion: .automotive,
                motionConfidence: .high
            ),
        ]

        let service = AppleTransportContextService()
        let enriched = await service.enriching(readings)

        XCTAssertFalse(enriched.contains(where: \.matchesRailRoute))
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

    func testResolvingOverlapsRechecksAfterTrimmingChangesOrder() {
        let base = makeDate(2026, 8, 4, 10, 0)
        let first = TravelSegment(
            mode: .car,
            span: TimeSpan(
                start: base,
                end: base.addingTimeInterval(200)
            ),
            distanceMeters: 1_000,
            confidence: .high,
            evidence: ["GPS"]
        )
        let trimmed = TravelSegment(
            mode: .walking,
            span: TimeSpan(
                start: base.addingTimeInterval(20),
                end: base.addingTimeInterval(300)
            ),
            distanceMeters: 1_800,
            confidence: .low,
            evidence: ["Core Motion"]
        )
        let later = TravelSegment(
            mode: .cycling,
            span: TimeSpan(
                start: base.addingTimeInterval(100),
                end: base.addingTimeInterval(400)
            ),
            distanceMeters: 2_500,
            confidence: .high,
            evidence: ["GPS"]
        )

        let resolved = AppleDeviceGroundTruthEngine.resolvingOverlaps(
            [first, trimmed, later]
        )

        XCTAssertEqual(resolved.map(\.id), [first.id, later.id])
        XCTAssertEqual(
            resolved[0].span,
            TimeSpan(start: base, end: base.addingTimeInterval(100))
        )
        XCTAssertEqual(resolved[1].span, later.span)
        for pair in zip(resolved, resolved.dropFirst()) {
            XCTAssertNil(pair.0.span.intersection(with: pair.1.span))
        }
    }

    func testIPhoneOnlyNightIsMarkedProvisional() {
        let base = makeDate(2026, 9, 1, 23)
        let sessions = SleepAnalysisEngine().sessions(from: [
            SleepSegment(
                stage: .asleepUnspecified,
                span: TimeSpan(start: base, end: base.addingTimeInterval(7 * hour)),
                sourceName: "iPhone",
                sourceBundleIdentifier: "com.apple.Health"
            )
        ])

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].sourceTier, .iPhone)
        XCTAssertTrue(sessions[0].isProvisional)
        XCTAssertFalse(sessions[0].isWatchAuthoritative)
    }

    func testTimeSpanValueIndexPreservesInputOrderAndStrictBoundaries() {
        let base = makeDate(2026, 8, 1, 9, 0)
        let first = TravelSegment(
            mode: .walking,
            span: TimeSpan(
                start: base.addingTimeInterval(10),
                end: base.addingTimeInterval(20)
            ),
            distanceMeters: 10,
            confidence: .high,
            evidence: ["first"]
        )
        let second = TravelSegment(
            mode: .walking,
            span: TimeSpan(
                start: base,
                end: base.addingTimeInterval(15)
            ),
            distanceMeters: 15,
            confidence: .high,
            evidence: ["second"]
        )
        let ending = TravelSegment(
            mode: .walking,
            span: TimeSpan(
                start: base,
                end: base.addingTimeInterval(12)
            ),
            distanceMeters: 12,
            confidence: .high,
            evidence: ["ending"]
        )
        let touching = TravelSegment(
            mode: .walking,
            span: TimeSpan(
                start: base.addingTimeInterval(20),
                end: base.addingTimeInterval(30)
            ),
            distanceMeters: 10,
            confidence: .high,
            evidence: ["touching"]
        )
        let index = TimeSpanValueIndex(
            [first, second, ending, touching]
        ) { $0.span }
        var inspectionCount: Int? = 0

        let values = index.values(
            overlapping: TimeSpan(
                start: base.addingTimeInterval(12),
                end: base.addingTimeInterval(20)
            ),
            inspectionCount: &inspectionCount
        )

        XCTAssertEqual(values, [first, second])
        XCTAssertFalse(values.contains(ending))
        XCTAssertFalse(values.contains(touching))
    }

    func testCommercePolicyTemporarilyDisablesPaidPurchaseWithoutAds() {
        XCTAssertFalse(TaptionCommercePolicy.isAdSupportedFreeMode)
        XCTAssertFalse(TaptionCommercePolicy.supportsPaidPurchase)
        XCTAssertEqual(
            TaptionCommercePolicy.proProductID,
            "com.taption.plan.pro"
        )
        XCTAssertEqual(
            TaptionCommercePolicy.trialDuration,
            14 * 24 * 60 * 60
        )
    }

#if DEBUG
    @MainActor
    func testDeveloperTrialResetStartsFreshFourteenDays() throws {
        let suiteName = "TaptionPlanTests.proTrialReset.\(UUID().uuidString)"
        let localStore = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        localStore.removePersistentDomain(forName: suiteName)
        defer { localStore.removePersistentDomain(forName: suiteName) }

        let persistence = TaptionProTrialPersistence(
            cloudStore: nil,
            localStore: localStore,
            keychainService: nil
        )
        let expiredStart = makeDate(2026, 8, 1, 12)
        _ = persistence.startTrial(at: expiredStart)

        let resetAt = makeDate(2026, 9, 7, 12)
        let reset = try persistence.resetTrial(at: resetAt)

        XCTAssertEqual(reset.startedAt, resetAt)
        XCTAssertEqual(
            TaptionProTrialPolicy.state(record: reset, now: resetAt),
            .trial(
                expiresAt: resetAt.addingTimeInterval(14 * 86_400),
                remainingDays: 14
            )
        )
    }
#endif

    func testProTrialMergeKeepsEarliestStartAndLatestObservedDate() {
        let start = makeDate(2026, 8, 23, 12)
        let merged = TaptionProTrialPolicy.merged([
            TaptionProTrialRecord(
                startedAt: start.addingTimeInterval(86_400),
                lastObservedAt: start.addingTimeInterval(2 * 86_400)
            ),
            TaptionProTrialRecord(
                startedAt: start,
                lastObservedAt: start.addingTimeInterval(4 * 86_400)
            ),
        ])

        XCTAssertEqual(merged?.startedAt, start)
        XCTAssertEqual(
            merged?.lastObservedAt,
            start.addingTimeInterval(4 * 86_400)
        )
    }

    func testProTrialLastObservedDateBlocksClockRollback() {
        let start = makeDate(2026, 8, 23, 12)
        let record = TaptionProTrialRecord(
            startedAt: start,
            lastObservedAt: start.addingTimeInterval(15 * 86_400)
        )

        XCTAssertEqual(
            TaptionProTrialPolicy.state(
                record: record,
                now: start.addingTimeInterval(86_400)
            ),
            .expired(
                expiresAt: start.addingTimeInterval(14 * 86_400)
            )
        )
    }

    func testProEntitlementRejectsOtherOrRevokedProducts() {
        XCTAssertTrue(
            TaptionCommercePolicy.grantsProAccess(
                productID: TaptionCommercePolicy.proProductID,
                revocationDate: nil
            )
        )
        XCTAssertFalse(
            TaptionCommercePolicy.grantsProAccess(
                productID: "com.taption.plan.other",
                revocationDate: nil
            )
        )
        XCTAssertFalse(
            TaptionCommercePolicy.grantsProAccess(
                productID: TaptionCommercePolicy.proProductID,
                revocationDate: .now
            )
        )
    }

    func testProEntitlementRequiresNonConsumableProductType() {
        XCTAssertTrue(
            TaptionCommercePolicy.grantsProAccess(
                productID: TaptionCommercePolicy.proProductID,
                productType: .nonConsumable,
                revocationDate: nil
            )
        )
        for unsupportedType in [
            Product.ProductType.consumable,
            .autoRenewable,
            .nonRenewable,
        ] {
            XCTAssertFalse(
                TaptionCommercePolicy.grantsProAccess(
                    productID: TaptionCommercePolicy.proProductID,
                    productType: unsupportedType,
                    revocationDate: nil
                )
            )
        }
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

    func testDiagnosticErrorFieldsRetainDomainCodeAndDescription() {
        let error = NSError(
            domain: "TaptionPlanTests",
            code: 47,
            userInfo: [NSLocalizedDescriptionKey: "diagnostic detail"]
        )
        let fields = TaptionDiagnosticError.fields(for: error)

        XCTAssertEqual(fields["error_domain"], "TaptionPlanTests")
        XCTAssertEqual(fields["error_code"], "47")
        XCTAssertEqual(fields["error_description"], "diagnostic detail")
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

    func makeActual(
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

    func testChartSelectionReturnsOnlyTheTappedBucketSpan() {
        let day = makeDate(2026, 8, 3)
        let buckets = RecordChartEngine.buckets(
            actuals: [
                makeActual(
                    "걷기",
                    "movement",
                    start: day.addingTimeInterval(hour),
                    minutes: 30
                ),
                makeActual(
                    "수면",
                    "sleep",
                    start: day.addingTimeInterval(24 * hour),
                    minutes: 6 * 60
                ),
            ],
            in: TimeSpan(
                start: day,
                end: day.addingTimeInterval(7 * 24 * hour)
            ),
            unit: .day,
            calendar: Calendar(identifier: .gregorian),
            asOf: day.addingTimeInterval(7 * 24 * hour)
        )
        let selected = buckets[1]

        XCTAssertEqual(
            ReviewSelectionEngine.chartSpan(selected.id, buckets: buckets),
            selected.span
        )
        XCTAssertNil(
            ReviewSelectionEngine.chartSpan("missing", buckets: buckets)
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

    func testClockPlaybackStopsAtNowForToday() {
        let day = makeDate(2026, 8, 4)
        let span = TimeSpan(
            start: day,
            end: day.addingTimeInterval(24 * hour)
        )
        let now = day.addingTimeInterval(6 * hour)
        let playbackStartedAt = makeDate(2026, 8, 5)
        let end = RecordClockEngine.playbackEndFraction(in: span, asOf: now)

        XCTAssertEqual(end, 0.25, accuracy: 0.0001)
        XCTAssertEqual(
            RecordClockEngine.progress(
                start: playbackStartedAt,
                now: playbackStartedAt.addingTimeInterval(24),
                endFraction: end
            ) ?? -1,
            0.25,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            RecordClockEngine.playbackEndFraction(
                in: span,
                asOf: span.end.addingTimeInterval(1)
            ),
            1
        )
        XCTAssertEqual(
            RecordClockEngine.playbackEndFraction(
                in: span,
                asOf: span.start.addingTimeInterval(-1)
            ),
            0
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

    var officeKey: String { "frequent-office" }

    func officePoint(_ metersNorth: Double) -> GeoPoint {
        GeoPoint(
            latitude: 37.5 + metersNorth / 111_320,
            longitude: 127,
            altitude: 40,
            horizontalAccuracy: 12,
            verticalAccuracy: 8
        )
    }

    func officeStay(
        start: Date,
        end: Date,
        floor: Int
    ) -> PlaceStay {
        PlaceStay(
            placeKey: officeKey,
            displayName: "회사",
            floor: floor,
            span: TimeSpan(start: start, end: end),
            confidence: .high,
            point: officePoint(0),
            isConfirmed: true,
            floorEvidence: FloorEvidence(
                measuredAt: start,
                relativeAltitudeMeters: Double(floor) * 3
            )
        )
    }

    func officeReadings(
        from start: Date,
        count: Int,
        metersFromAnchor: (Int) -> Double
    ) -> [SensorReading] {
        (0..<count).map { step in
            SensorReading(
                timestamp: start.addingTimeInterval(Double(step) * 600),
                point: officePoint(metersFromAnchor(step)),
                motion: .stationary,
                motionConfidence: .high,
                relativeAltitudeMeters: 0
            )
        }
    }

    func floorChanging(
        _ readings: [SensorReading],
        after index: Int
    ) -> [SensorReading] {
        readings.enumerated().map { offset, reading in
            var value = reading
            value.systemFloor = offset < index ? 20 : 2
            return value
        }
    }

    /// 사용자가 설정에서 맞춘 반경 120m·최소 체류 10분을 그대로 쓴다.
    func officeRecords(
        stays: [PlaceStay],
        readings: [SensorReading],
        inside: TimeSpan? = nil,
        stationarySpans: [TimeSpan] = []
    ) -> [ActualRecord] {
        let span = inside ?? TimeSpan(
            start: makeDate(2026, 8, 4, 0, 0),
            end: makeDate(2026, 8, 5, 0, 0)
        )
        return StationaryContextActualEngine.records(
            stays: stays,
            placeKinds: [officeKey: .company],
            placeAnchors: [
                officeKey: FrequentPlaceAnchor(
                    point: officePoint(0),
                    radiusMeters: 120
                )
            ],
            stationarySpans: stationarySpans,
            readings: readings,
            inside: span,
            calendar: utcCalendar,
            now: span.end
        )
    }

    func makeContextStay(
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

    func makeContextEvent(
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

    func makeContextActual(
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

    func makeContextReading(
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

    func makeWatchRawSamples(
        start: Date,
        values: [Double]
    ) -> [TaptionWatchAccelerationSample] {
        values.enumerated().map { index, value in
            TaptionWatchAccelerationSample(
                capturedAt: start.addingTimeInterval(Double(index) * 10),
                acceleration: TaptionWatchSensorVector3(
                    x: value,
                    y: 0,
                    z: 0
                ),
                sequence: index + 1,
                isAmbient: true
            )
        }
    }

    func makeWatchSummary(
        start: Date,
        duration: TimeInterval,
        sessionID: UUID,
        behavior: WatchBehaviorKind
    ) -> TaptionWatchSensorSummary {
        var summary = TaptionWatchSensorSummary(
            sessionID: sessionID,
            sequence: 1,
            workoutKind: .walking,
            linkedPlanID: nil,
            linkedPlanTitle: nil,
            linkedCategoryID: nil,
            startedAt: start,
            endedAt: start.addingTimeInterval(duration),
            isFinal: false,
            accelerometerSampleCount: 64,
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
            stepCount: 0,
            distanceMeters: 0,
            floorsAscended: nil,
            floorsDescended: nil,
            latestHeartRate: nil,
            averageHeartRate: nil,
            maximumHeartRate: nil,
            activeEnergyKilocalories: nil
        )
        summary.behavior = behavior
        summary.behaviorConfidenceScore = 0.8
        summary.behaviorEvidence = ["기존 Watch 판정"]
        summary.behaviorModelVersion = WatchBehaviorClassifier.rulesVersion
        summary.isAmbient = true
        return summary
    }

    func makeWatchRawSamples(
        start: Date,
        sessionID: UUID,
        count: Int
    ) -> [TaptionWatchAccelerationSample] {
        (0..<count).map { index in
            let sign = index.isMultiple(of: 2) ? 1.0 : -1.0
            return TaptionWatchAccelerationSample(
                capturedAt: start.addingTimeInterval(Double(index) * 0.25),
                acceleration: TaptionWatchSensorVector3(
                    x: 0,
                    y: 0,
                    z: 1 + sign * 0.08
                ),
                sessionID: sessionID,
                sequence: index + 1,
                isAmbient: true
            )
        }
    }

    /// The placeholder factory always produced exactly this plan.
    func makeMemoShellPlan(
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

    func makeSnapshot(
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

    @MainActor
    func makeActiveIntegrationModel(
        selectedDate: Date = .now
    ) async -> AppModel {
        TaptionPlanDiagnosticsLogger.shared.clear()
        var stored = TaptionDataSnapshot.empty
        stored.settings.locationEnabled = false
        stored.settings.healthEnabled = false
        stored.settings.weatherEnabled = false
        // 센서 보관소를 지정하지 않으면 AppModel이 앱의 실제 센서 저장소를 연다. 실기기에서는 그 안의 실제 기록을 분석하느라
        // 5초 안에 통합 새로고침이 끝나지 않았다. 시험은 늘 비어 있는 임시 보관소를 쓴다(대표 지시, ARC1030A04).
        let sensorDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("integration-model-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: sensorDirectory) }
        let sensorService = (try? SensorReadingArchive(
            fileURL: sensorDirectory.appendingPathComponent("readings.jsonl")
        )).map { AppleSensorDataService(archive: $0) }
        let model = AppModel(
            repository: InMemoryPlanRepository(snapshot: stored),
            sensorService: sensorService,
            cloudSyncService: nil,
            registersHealthBackgroundHandler: false
        )
        model.selectedDate = selectedDate
        await model.sceneBecameActive()
        await waitForInitialForegroundWorkToSettle(model)
        TaptionPlanDiagnosticsLogger.shared.clear()
        return model
    }

    @MainActor
    func waitForInitialForegroundWorkToSettle(
        _ model: AppModel
    ) async {
        let deadline = Date.now.addingTimeInterval(5)
        while Date.now < deadline {
            let log = TaptionPlanDiagnosticsLogger.shared.combinedLog()
            if log.contains("integration_refresh_finished"),
               !model.isRefreshingIntegrations {
                try? await Task.sleep(for: .milliseconds(50))
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("initial foreground integration refresh did not settle")
    }

    @MainActor
    private func waitForSelectedDateRefresh(
        model: AppModel,
        selectedDate: Date
    ) async -> [String] {
        let expectedDayStart = selectedDayStart(selectedDate)
        let deadline = Date.now.addingTimeInterval(5)
        while Date.now < deadline {
            let log = TaptionPlanDiagnosticsLogger.shared.combinedLog()
            let starts = integrationRefreshStartLines(in: log)
            if starts.contains(where: {
                $0.contains("\"day_start\":\"\(expectedDayStart)\"")
            }),
                log.contains("integration_refresh_finished"),
                !model.isRefreshingIntegrations {
                try? await Task.sleep(for: .milliseconds(100))
                return integrationRefreshStartLines()
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return integrationRefreshStartLines()
    }

    func integrationRefreshStartLines(
        in log: String = TaptionPlanDiagnosticsLogger.shared.combinedLog()
    ) -> [String] {
        log.split(whereSeparator: \.isNewline).compactMap { line in
            let value = String(line)
            return value.contains(
                "\"event\":\"integration_refresh_started\""
            ) ? value : nil
        }
    }

    func sensorTimelineRefreshStartLines(
        in log: String = TaptionPlanDiagnosticsLogger.shared.combinedLog()
    ) -> [String] {
        log.split(whereSeparator: \.isNewline).compactMap { line in
            let value = String(line)
            return value.contains(
                "\"event\":\"sensor_timeline_refresh_started\""
            ) ? value : nil
        }
    }

    @MainActor
    func waitForSensorAnalysisBatch() async -> [String] {
        let deadline = Date.now.addingTimeInterval(5)
        while Date.now < deadline {
            let starts = sensorAnalysisBatchStartLines()
            if !starts.isEmpty {
                try? await Task.sleep(for: .milliseconds(100))
                return sensorAnalysisBatchStartLines()
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return sensorAnalysisBatchStartLines()
    }

    func sensorAnalysisBatchStartLines(
        in log: String = TaptionPlanDiagnosticsLogger.shared.combinedLog()
    ) -> [String] {
        log.split(whereSeparator: \.isNewline).compactMap { line in
            let value = String(line)
            return value.contains(
                "\"event\":\"sensor_analysis_batch_started\""
            ) ? value : nil
        }
    }

    private func selectedDayStart(_ date: Date) -> String {
        String(
            Calendar.autoupdatingCurrent
                .startOfDay(for: date)
                .timeIntervalSince1970
        )
    }

    func memoFixture(at instant: Date) -> ActionMemo {
        ActionMemo(
            categoryID: MemoTimelineEngine.categoryID,
            occurredAt: instant,
            kind: .idea,
            text: "메모 \(instant.timeIntervalSinceReferenceDate)",
            createdAt: instant,
            updatedAt: instant
        )
    }

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

    func assertRingHasNoSlivers(
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

    // MARK: - 하루 눈금판 바깥의 일과 고리

    /// 집을 나서 한 곳에 머물다 집으로 돌아오는 하루. 걷고 타는 두 다리가
    /// 한 번의 오감이 되는 것은 여느 날과 같다.
    func roundTripPhases(
        to kind: FrequentPlaceKind,
        staying context: StationaryContextKind?,
        registeringDestination: Bool = true
    ) -> [DayPhaseSpan] {
        let day = dayPhaseDay()
        let homeKey = "frequent-home"
        let awayKey = "frequent-away"
        return DayPhaseEngine.phases(
            actuals: [sleepActual(0, 7, on: day)]
                + (context.map { [stationaryContext($0, 8.75, 18, on: day)] }
                    ?? []),
            travel: [
                travelLeg(.walking, 8, 8.25, on: day),
                travelLeg(.subway, 8.25, 8.75, on: day),
                travelLeg(.subway, 18, 18.5, on: day),
                travelLeg(.walking, 18.5, 18.75, on: day),
            ],
            stays: [
                homeStay(0, 8, key: homeKey, on: day),
                PlaceStay(
                    placeKey: awayKey,
                    displayName: kind.defaultName,
                    span: TimeSpan(
                        start: day.start.addingTimeInterval(8.75 * hour),
                        end: day.start.addingTimeInterval(18 * hour)
                    ),
                    confidence: .high,
                    isConfirmed: true
                ),
                homeStay(18.75, 24, key: homeKey, on: day),
            ],
            placeKinds: registeringDestination
                ? [homeKey: .home, awayKey: kind]
                : [homeKey: .home],
            in: day,
            asOf: day.end
        )
    }

    func dayPhaseDay() -> TimeSpan {
        let start = makeDate(2026, 8, 4)
        return TimeSpan(start: start, end: start.addingTimeInterval(24 * hour))
    }

    func stationaryContext(
        _ kind: StationaryContextKind,
        _ from: Double,
        _ to: Double,
        on day: TimeSpan
    ) -> ActualRecord {
        ActualRecord(
            planID: nil,
            title: kind.title,
            categoryID: kind.categoryID,
            startedAt: day.start.addingTimeInterval(from * hour),
            endedAt: day.start.addingTimeInterval(to * hour),
            source: .location,
            confidence: .medium,
            behavior: kind.rawValue,
            modelVersion: StationaryContextClassifier.modelVersion
        )
    }

    func sleepActual(
        _ from: Double,
        _ to: Double,
        on day: TimeSpan
    ) -> ActualRecord {
        ActualRecord(
            planID: nil,
            title: "수면",
            categoryID: "sleep",
            startedAt: day.start.addingTimeInterval(from * hour),
            endedAt: day.start.addingTimeInterval(to * hour),
            source: .healthKit
        )
    }

    func travelLeg(
        _ mode: TravelMode,
        _ from: Double,
        _ to: Double,
        on day: TimeSpan
    ) -> TravelSegment {
        TravelSegment(
            mode: mode,
            span: TimeSpan(
                start: day.start.addingTimeInterval(from * hour),
                end: day.start.addingTimeInterval(to * hour)
            ),
            distanceMeters: 4_000,
            confidence: .medium,
            evidence: ["GPS"]
        )
    }

    func homeStay(
        _ from: Double,
        _ to: Double,
        key: String,
        on day: TimeSpan
    ) -> PlaceStay {
        PlaceStay(
            placeKey: key,
            displayName: "집",
            span: TimeSpan(
                start: day.start.addingTimeInterval(from * hour),
                end: day.start.addingTimeInterval(to * hour)
            ),
            confidence: .high,
            isConfirmed: true
        )
    }

    /// 이 고리는 겹칠 수 없는 한 줄이다. 조각은 시간 순서대로 놓이고, 서로
    /// 겹치지 않으며, 하루 밖으로 나가지 않는다.
    func assertPhasesPartitionTheDay(
        _ phases: [DayPhaseSpan],
        in day: TimeSpan,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var previousEnd = day.start
        for piece in phases {
            XCTAssertGreaterThanOrEqual(
                piece.span.start,
                previousEnd,
                "줄거리가 겹칩니다.",
                file: file,
                line: line
            )
            XCTAssertGreaterThan(piece.span.duration, 0, file: file, line: line)
            previousEnd = piece.span.end
        }
        XCTAssertGreaterThanOrEqual(
            phases.first?.span.start ?? day.start,
            day.start,
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            previousEnd,
            day.end,
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            phases.reduce(0) { $0 + $1.span.duration },
            day.duration,
            file: file,
            line: line
        )
    }

    /// 주어진 고도 차이를 만드는 기압. 층 높이 계산이 쓰는 기압 공식의 역함수다.
    func pressure(
        _ baseline: Double,
        risingBy meters: Double
    ) -> Double {
        baseline * pow(1 - meters / 44_330, 1 / 0.1903)
    }

    func makeAltitudeReading(
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

    /// 새 기준점은 그 자리에서 바로 기준이 된다. 다음 센서 주기를 기다리면
    /// 사용자는 방금 고친 값이 반영되지 않았다고 본다.
    func testNewReferenceTakesEffectImmediately() throws {
        let base = makeDate(2026, 8, 5, 9, 0)
        let groundPressure = 101.0
        var place = FrequentPlace(kind: .company)
        place.calibrateCurrentFloor(
            to: 19,
            from: makeAltitudeReading(
                at: base,
                pressureKilopascals: groundPressure
            )
        )
        let here = makeAltitudeReading(
            at: base.addingTimeInterval(60),
            pressureKilopascals: pressure(groundPressure, risingBy: 0.2)
        )
        XCTAssertEqual(
            FloorCalibrationEngine().estimate(
                reading: here,
                calibration: try XCTUnwrap(place.floorCalibration)
            )?.floor,
            19
        )

        place.calibrateCurrentFloor(to: 2, from: here)

        XCTAssertEqual(
            FloorCalibrationEngine().estimate(
                reading: here,
                calibration: try XCTUnwrap(place.floorCalibration)
            )?.floor,
            2
        )
    }

    func legacyData(
        from value: some Encodable,
        without key: String
    ) throws -> Data {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
                as? [String: Any]
        )
        XCTAssertNotNil(object.removeValue(forKey: key))
        return try JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - 고도 표본 묶음

    func burstSamples(
        _ values: [Double],
        session: UUID,
        from start: Date
    ) -> [AltitudeBurstSample] {
        values.enumerated().map { index, meters in
            AltitudeBurstSample(
                relativeAltitudeMeters: meters,
                pressureKilopascals: pressure(101.0, risingBy: meters),
                altimeterSessionID: session,
                timestamp: start.addingTimeInterval(Double(index))
            )
        }
    }

    func makeUsageSample(
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

    // MARK: - 등록하지 않은 자주 가는 곳

    func makeVisitStay(
        latitude: Double,
        longitude: Double,
        start: Date,
        minutes: Double = 60,
        displayName: String = "자동 감지 장소"
    ) -> PlaceStay {
        PlaceStay(
            // `PlaceDetectionEngine` 과 같은 방식의 좌표 키. 방문마다 GPS
            // 평균이 달라지므로 같은 자리라도 키가 갈린다.
            placeKey: String(format: "%.4f,%.4f", latitude, longitude),
            displayName: displayName,
            span: TimeSpan(
                start: start,
                end: start.addingTimeInterval(minutes * 60)
            ),
            confidence: .medium,
            point: GeoPoint(
                latitude: latitude,
                longitude: longitude,
                altitude: 30,
                horizontalAccuracy: 10,
                verticalAccuracy: 8
            )
        )
    }

    func makeCafeVisits(
        from base: Date,
        dayOffsets: [Double]
    ) -> [PlaceStay] {
        // 좌표를 조금씩 흔들어 방문마다 `placeKey` 가 달라지게 한다. 같은
        // 장소를 알아보는 것은 키가 아니라 거리여야 한다.
        dayOffsets.enumerated().map { index, offset in
            makeVisitStay(
                latitude: 37.5000 + Double(index % 3) * 0.0002,
                longitude: 127.0000 + Double(index % 2) * 0.0002,
                start: base.addingTimeInterval(offset * 86_400)
            )
        }
    }

    func transitReadings(
        at start: Date,
        point: GeoPoint,
        duration: TimeInterval,
        locationFixQuality: LocationFixQuality? = nil,
        sourceDevice: TrackingDevice? = nil
    ) -> [SensorReading] {
        [
            transitReading(
                at: start,
                point: point,
                locationFixQuality: locationFixQuality,
                sourceDevice: sourceDevice
            ),
            transitReading(
                at: start.addingTimeInterval(duration),
                point: point,
                locationFixQuality: locationFixQuality,
                sourceDevice: sourceDevice
            ),
        ]
    }

    func uncertainTransitTravel(at start: Date) -> TravelSegment {
        TravelSegment(
            mode: .car,
            span: TimeSpan(
                start: start.addingTimeInterval(3 * 60),
                end: start.addingTimeInterval(20 * 60)
            ),
            distanceMeters: 1_000,
            confidence: .low,
            evidence: ["자동 추정"]
        )
    }

    func transitReading(
        at date: Date,
        point: GeoPoint,
        locationFixQuality: LocationFixQuality? = nil,
        sourceDevice: TrackingDevice? = nil
    ) -> SensorReading {
        let observedPoint = GeoPoint(
            latitude: point.latitude,
            longitude: point.longitude,
            altitude: point.altitude,
            horizontalAccuracy: point.horizontalAccuracy < 0
                ? 10
                : point.horizontalAccuracy,
            verticalAccuracy: point.verticalAccuracy < 0
                ? 10
                : point.verticalAccuracy
        )
        return SensorReading(
            timestamp: date,
            point: observedPoint,
            locationFixQuality: locationFixQuality,
            gpsAvailable: true,
            sourceDevice: sourceDevice
        )
    }

    func phaseOption(
        _ categoryID: String,
        title: String
    ) -> ActivityCorrectionOption {
        ActivityCorrectionOption(
            id: "phase.\(categoryID)",
            title: title,
            behavior: categoryID == "unconfirmed" ? "unconfirmed-gap" : nil,
            categoryID: categoryID,
            systemImage: "circle.fill",
            isAutomatic: false,
            isCustom: false
        )
    }

}
