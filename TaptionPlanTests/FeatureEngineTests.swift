import XCTest
@testable import TaptionPlan

final class FeatureEngineTests: XCTestCase {
    private let hour: TimeInterval = 3_600

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
        XCTAssertEqual(rollup.plannedDuration, month.span.duration + week.span.duration + day.span.duration)
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

    func testRepresentativeTemplatesAndPrivacyDefaults() throws {
        XCTAssertEqual(TemplateCatalog.representativeSelections.count, 3)
        let employeeParent = try TemplateCatalog.apply(
            TemplateCatalog.representativeSelections[0]
        )
        XCTAssertTrue(employeeParent.visibleCategoryIDs.contains("routine"))
        XCTAssertTrue(employeeParent.quickAdds.contains("등하원"))

        let military = try TemplateCatalog.apply(
            ProfileSelection(roleID: "military")
        )
        XCTAssertEqual(military.suggestedPermissions[.location], false)
        XCTAssertEqual(military.suggestedPermissions[.calendar], false)

        XCTAssertThrowsError(
            try TemplateCatalog.apply(
                ProfileSelection(
                    roleID: "employee",
                    situationIDs: ["parenting", "leave", "side-job"]
                )
            )
        ) {
            XCTAssertEqual($0 as? TemplateError, .tooManySituations)
        }
    }

    func testAllCustomCategoryRequirementsExist() throws {
        XCTAssertEqual(CategoryCatalog.builtIn.count, 13)
        XCTAssertGreaterThanOrEqual(CategoryIcon.allCases.count, 24)
        let custom = try CategoryCatalog.makeCustom(
            name: "봉사",
            icon: .family,
            lightHex: "AABBCC",
            existing: CategoryCatalog.builtIn
        )
        XCTAssertFalse(custom.isBuiltIn)
        XCTAssertEqual(custom.lightHex, "#AABBCC")
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
            motion: .automotive,
            motionConfidence: .medium,
            nearPort: true,
            onWater: true
        )
        XCTAssertEqual(
            TravelModeClassifier().classify(readings: [ship]).mode,
            .ship
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
        XCTAssertEqual(snapshot.availableActions.count, 3)
        XCTAssertEqual(
            CatMotionPolicy.resolve(
                style: .white,
                hasCurrentActivity: true,
                reduceMotion: true
            ).animationDuration,
            0
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

        XCTAssertEqual(restored.categories.count, 13)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
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
