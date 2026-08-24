import XCTest
@testable import TaptionPlan

final class RouteTimelineDataTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func date(_ minute: Int) -> Date {
        calendar.date(
            byAdding: .minute,
            value: minute,
            to: calendar.startOfDay(for: Date(timeIntervalSince1970: 1_755_206_400))
        )!
    }

    private func reading(
        _ minute: Int,
        latitude: Double,
        id: UUID = UUID(),
        accuracy: Double = 5
    ) -> SensorReading {
        SensorReading(
            id: id,
            timestamp: date(minute),
            point: GeoPoint(
                latitude: latitude,
                longitude: 127,
                altitude: 0,
                horizontalAccuracy: accuracy,
                verticalAccuracy: 5
            )
        )
    }

    func testMapRouteRefreshDoesNotEraseCachedReadingsOnEmptyLoad() {
        XCTAssertFalse(
            MapHomeRouteReadingsPolicy.shouldReplace(
                existingCount: 12,
                loadedCount: 0
            )
        )
        XCTAssertFalse(
            MapHomeRouteReadingsPolicy.shouldReplace(
                existingCount: 12,
                loadedCount: 1
            )
        )
        XCTAssertFalse(
            MapHomeRouteReadingsPolicy.shouldReplace(
                existingCount: 12,
                loadedCount: 3
            )
        )
        XCTAssertTrue(
            MapHomeRouteReadingsPolicy.shouldReplace(
                existingCount: 0,
                loadedCount: 0
            )
        )
        XCTAssertTrue(
            MapHomeRouteReadingsPolicy.shouldReplace(
                existingCount: 12,
                loadedCount: 12
            )
        )
    }

    func testApproximateLocationDoesNotReplaceCachedRouteReadings() {
        let approximate = SensorReading(
            timestamp: date(1),
            point: GeoPoint(
                latitude: 37,
                longitude: 127,
                altitude: 0,
                horizontalAccuracy: 20,
                verticalAccuracy: 5
            ),
            locationFixQuality: .approximate,
            gpsAvailable: false
        )
        let cached = reading(0, latitude: 37)

        let loadedRouteCount = RouteTimelineDataEngine
            .normalizedDisplayReadings([approximate]).count
        let cachedRouteCount = RouteTimelineDataEngine
            .normalizedDisplayReadings([cached]).count

        XCTAssertFalse(
            MapHomeRouteReadingsPolicy.shouldReplace(
                existing: [cached],
                loaded: [approximate]
            )
        )
        XCTAssertEqual(loadedRouteCount, 1)
        XCTAssertEqual(cachedRouteCount, 1)
    }

    func testMapRouteTaskUsesCalendarDayKey() {
        let first = date(30)
        let second = date(1_200)

        XCTAssertEqual(
            MapHomeRouteReadingsPolicy.dayKey(for: first, calendar: calendar),
            MapHomeRouteReadingsPolicy.dayKey(for: second, calendar: calendar)
        )
    }

    func testPastDayFullCutoffKeepsRouteVisible() throws {
        let dayEnd = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: date(0))
        )!
        let projection = RouteTimelineDataEngine.project(
            selectedDate: date(0),
            through: dayEnd,
            actuals: [],
            readings: [
                reading(0, latitude: 37),
                reading(10, latitude: 38),
            ],
            calendar: calendar
        )

        XCTAssertEqual(projection.cutoff, dayEnd)
        XCTAssertFalse(projection.segments.isEmpty)
        XCTAssertEqual(projection.segments.first?.coordinates.count, 2)
    }

    func testProjectClipsAtTimelineAndDimsPastCategory() throws {
        let activity = ActualRecord(
            planID: nil,
            title: "활동",
            categoryID: "activity",
            startedAt: date(0),
            endedAt: date(10),
            source: .motion
        )
        let work = ActualRecord(
            planID: nil,
            title: "업무",
            categoryID: "work",
            startedAt: date(10),
            endedAt: date(20),
            source: .location
        )
        let originalActuals = [activity, work]
        let projection = RouteTimelineDataEngine.project(
            selectedDate: date(0),
            throughMinute: 15,
            actuals: originalActuals,
            readings: [
                reading(0, latitude: 37),
                reading(10, latitude: 38),
                reading(20, latitude: 39),
            ],
            calendar: calendar
        )

        XCTAssertEqual(projection.selectedCategory, .work)
        XCTAssertEqual(projection.cutoff, date(15))
        XCTAssertEqual(projection.segments.map(\.category), [.activity, .work])
        XCTAssertEqual(projection.segments.map(\.opacity), [0.5, 1.0])
        XCTAssertTrue(projection.segments.allSatisfy { $0.end <= date(15) })
        XCTAssertEqual(
            try XCTUnwrap(projection.coordinateAtCutoff).latitude,
            38.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(originalActuals, [activity, work])
    }

    func testNormalizedReadingsRemoveDuplicateTimestampAndPreferAccuratePoint() throws {
        let id = UUID()
        let duplicate = reading(5, latitude: 37, id: id, accuracy: 20)
        let accurate = reading(5, latitude: 37.1, id: UUID(), accuracy: 2)
        let values = RouteTimelineDataEngine.normalizedReadings([
            duplicate, accurate, duplicate,
        ])

        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(
            try XCTUnwrap(try XCTUnwrap(values.first).point).latitude,
            37.1,
            accuracy: 0.0001
        )
    }

    func testMapDisplayUsesBoundedApproximateLocationsWithoutChangingInferenceInput() {
        let approximate = SensorReading(
            timestamp: date(5),
            point: GeoPoint(
                latitude: 37.5,
                longitude: 127,
                altitude: 0,
                horizontalAccuracy: 250,
                verticalAccuracy: 100
            ),
            locationFixQuality: .approximate,
            gpsAvailable: false
        )

        XCTAssertTrue(
            RouteTimelineDataEngine.normalizedReadings([approximate]).isEmpty
        )
        XCTAssertEqual(
            RouteTimelineDataEngine.normalizedDisplayReadings([approximate]),
            [approximate]
        )
    }

    func testMapDisplayRejectsUnboundedApproximateLocation() {
        let approximate = SensorReading(
            timestamp: date(5),
            point: GeoPoint(
                latitude: 37.5,
                longitude: 127,
                altitude: 0,
                horizontalAccuracy:
                    RouteTimelineDataEngine.maximumApproximateDisplayAccuracy + 1,
                verticalAccuracy: 100
            ),
            locationFixQuality: .approximate,
            gpsAvailable: false
        )

        XCTAssertTrue(
            RouteTimelineDataEngine
                .normalizedDisplayReadings([approximate]).isEmpty
        )
    }

    func testMapProjectionDrawsBoundedApproximateRoute() {
        let readings = [
            SensorReading(
                timestamp: date(0),
                point: GeoPoint(
                    latitude: 37.5,
                    longitude: 127,
                    altitude: 0,
                    horizontalAccuracy: 250,
                    verticalAccuracy: 100
                ),
                locationFixQuality: .approximate,
                gpsAvailable: false
            ),
            SensorReading(
                timestamp: date(10),
                point: GeoPoint(
                    latitude: 37.51,
                    longitude: 127.01,
                    altitude: 0,
                    horizontalAccuracy: 300,
                    verticalAccuracy: 100
                ),
                locationFixQuality: .approximate,
                gpsAvailable: false
            ),
        ]
        let normalized = RouteTimelineDataEngine.normalizedDisplayReadings(
            readings
        )
        let projection = RouteTimelineDataEngine.project(
            selectedDate: date(0),
            throughMinute: 10,
            actuals: [],
            readings: normalized,
            readingsAreNormalized: true,
            calendar: calendar
        )

        XCTAssertEqual(projection.samples.count, 2)
        XCTAssertEqual(projection.segments.count, 1)
    }

    func testSelectedTimelineSpanDoesNotBrightenEarlierMatchingCategory() {
        let projection = RouteTimelineDataEngine.project(
            selectedDate: date(0),
            throughMinute: 25,
            selectedSpan: TimeSpan(start: date(20), end: date(30)),
            actuals: [
                ActualRecord(
                    planID: nil,
                    title: "첫 활동",
                    categoryID: "activity",
                    startedAt: date(0),
                    endedAt: date(10),
                    source: .motion
                ),
                ActualRecord(
                    planID: nil,
                    title: "업무",
                    categoryID: "work",
                    startedAt: date(10),
                    endedAt: date(20),
                    source: .location
                ),
                ActualRecord(
                    planID: nil,
                    title: "선택 활동",
                    categoryID: "activity",
                    startedAt: date(20),
                    endedAt: date(30),
                    source: .motion
                ),
            ],
            readings: [
                reading(0, latitude: 37),
                reading(10, latitude: 38),
                reading(20, latitude: 39),
                reading(30, latitude: 40),
            ],
            calendar: calendar
        )

        XCTAssertEqual(projection.segments.map(\.category), [.activity, .work, .activity])
        XCTAssertEqual(projection.segments.map(\.opacity), [0.5, 0.5, 1.0])
    }

    func testExactSampleAndLongGPSGapInterpolatePlaybackButKeepRouteGap() throws {
        let projection = RouteTimelineDataEngine.project(
            selectedDate: date(0),
            throughMinute: 10,
            actuals: [],
            readings: [
                reading(0, latitude: 37),
                reading(30, latitude: 40),
            ],
            calendar: calendar
        )

        XCTAssertEqual(
            try XCTUnwrap(projection.coordinateAtCutoff).latitude,
            38,
            accuracy: 0.0001
        )
        XCTAssertTrue(projection.segments.isEmpty)

        let exactSample = RouteTimelineDataEngine.project(
            selectedDate: date(0),
            throughMinute: 30,
            actuals: [],
            readings: [
                reading(0, latitude: 37),
                reading(30, latitude: 40),
            ],
            calendar: calendar
        )

        XCTAssertEqual(
            try XCTUnwrap(exactSample.coordinateAtCutoff).latitude,
            40,
            accuracy: 0.0001
        )
        XCTAssertTrue(exactSample.segments.isEmpty)
    }

    func testPlaybackBeforeFirstSampleIsNilAndAfterLastSampleHoldsLastPoint() throws {
        let beforeFirst = RouteTimelineDataEngine.project(
            selectedDate: date(0),
            throughMinute: 5,
            actuals: [],
            readings: [reading(10, latitude: 37)],
            calendar: calendar
        )
        XCTAssertNil(beforeFirst.coordinateAtCutoff)

        let afterLast = RouteTimelineDataEngine.project(
            selectedDate: date(0),
            throughMinute: 30,
            actuals: [],
            readings: [
                reading(0, latitude: 37),
                reading(10, latitude: 38),
            ],
            calendar: calendar
        )
        XCTAssertEqual(
            try XCTUnwrap(afterLast.coordinateAtCutoff).latitude,
            38,
            accuracy: 0.0001
        )
    }

    func testPlaybackDoesNotInterpolateAcrossMidnight() throws {
        let projection = RouteTimelineDataEngine.project(
            selectedDate: date(0),
            throughMinute: 1_440,
            actuals: [],
            readings: [
                reading(0, latitude: 37),
                reading(1_430, latitude: 38),
                reading(1_445, latitude: 50),
            ],
            calendar: calendar
        )

        XCTAssertEqual(
            try XCTUnwrap(projection.coordinateAtCutoff).latitude,
            38,
            accuracy: 0.0001
        )
    }

    func testRouteSegmentsRemainSplitAcrossGPSGapLongerThan15Minutes() {
        let projection = RouteTimelineDataEngine.project(
            selectedDate: date(0),
            throughMinute: 40,
            actuals: [],
            readings: [
                reading(0, latitude: 37),
                reading(10, latitude: 38),
                reading(30, latitude: 40),
                reading(40, latitude: 41),
            ],
            calendar: calendar
        )

        XCTAssertEqual(projection.segments.count, 2)
        XCTAssertEqual(projection.segments.map(\.start), [date(0), date(30)])
        XCTAssertEqual(projection.segments.map(\.end), [date(10), date(40)])
    }

    func testCategoryAtExactCutoffAndOngoingMidnightRecordAreIncluded() {
        let exactStart = ActualRecord(
            planID: nil,
            title: "업무",
            categoryID: "work",
            startedAt: date(10),
            endedAt: date(20),
            source: .location
        )
        let exactProjection = RouteTimelineDataEngine.project(
            selectedDate: date(0),
            throughMinute: 10,
            actuals: [exactStart],
            readings: [],
            calendar: calendar
        )
        XCTAssertEqual(exactProjection.selectedCategory, .work)

        let ongoing = ActualRecord(
            planID: nil,
            title: "수면",
            categoryID: "sleep",
            startedAt: date(-30),
            endedAt: nil,
            source: .healthKit
        )
        let midnightProjection = RouteTimelineDataEngine.project(
            selectedDate: date(0),
            throughMinute: 0,
            actuals: [ongoing],
            readings: [],
            calendar: calendar
        )
        XCTAssertEqual(midnightProjection.selectedCategory, .sleep)
    }

    func testFullDayCutoffUsesCalendarDayEndAcrossDSTFallback() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let selectedDate = try XCTUnwrap(
            newYork.date(from: DateComponents(year: 2026, month: 11, day: 1))
        )
        let dayStart = newYork.startOfDay(for: selectedDate)
        let dayEnd = try XCTUnwrap(
            newYork.date(byAdding: .day, value: 1, to: dayStart)
        )

        let cutoff = RouteTimelineDataEngine.timelineDate(
            selectedDate: selectedDate,
            minute: 1_440,
            calendar: newYork
        )

        XCTAssertEqual(cutoff, dayEnd)
        XCTAssertEqual(cutoff.timeIntervalSince(dayStart), 25 * 60 * 60)
    }

    func testInvalidAccuracyLosesDuplicatePreferenceAndInterpolationStaysFinite() throws {
        let invalid = reading(5, latitude: 40, accuracy: .nan)
        let accurate = reading(5, latitude: 37, accuracy: 4)
        let normalized = RouteTimelineDataEngine.normalizedReadings([
            invalid,
            accurate,
        ])

        XCTAssertEqual(
            try XCTUnwrap(try XCTUnwrap(normalized.first).point).latitude,
            37,
            accuracy: 0.0001
        )

        let nonFiniteMetadata = SensorReading(
            timestamp: date(0),
            point: GeoPoint(
                latitude: 37,
                longitude: 127,
                altitude: .nan,
                horizontalAccuracy: .nan,
                verticalAccuracy: .infinity
            )
        )
        let projection = RouteTimelineDataEngine.project(
            selectedDate: date(0),
            throughMinute: 5,
            actuals: [],
            readings: [
                nonFiniteMetadata,
                reading(10, latitude: 38, accuracy: 5),
            ],
            calendar: calendar
        )
        let point = try XCTUnwrap(projection.coordinateAtCutoff)
        XCTAssertTrue(point.altitude.isFinite)
        XCTAssertTrue(point.horizontalAccuracy.isFinite)
        XCTAssertTrue(point.verticalAccuracy.isFinite)
    }

    func testDenseRealtimeRouteProjectionStaysLinearAndMerged() {
        let start = date(0)
        let readings = (0..<10_000).map { index in
            SensorReading(
                timestamp: start.addingTimeInterval(TimeInterval(index)),
                point: GeoPoint(
                    latitude: 37 + Double(index) / 1_000_000,
                    longitude: 127,
                    altitude: 0,
                    horizontalAccuracy: 5,
                    verticalAccuracy: 5
                )
            )
        }
        let startedAt = ProcessInfo.processInfo.systemUptime
        let projection = RouteTimelineDataEngine.project(
            selectedDate: start,
            through: start.addingTimeInterval(9_999),
            actuals: [],
            readings: readings,
            readingsAreNormalized: true,
            calendar: calendar
        )
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt

        XCTAssertEqual(projection.segments.count, 1)
        XCTAssertEqual(projection.segments.first?.coordinates.count, 10_000)
        XCTAssertLessThan(elapsed, 3)

        let displayReadings = RouteTimelineDataEngine.displayReadings(
            from: readings
        )
        XCTAssertEqual(
            displayReadings.count,
            RouteTimelineDataEngine.maximumDisplayReadingCount
        )
        XCTAssertEqual(displayReadings.first?.timestamp, readings.first?.timestamp)
        XCTAssertEqual(displayReadings.last?.timestamp, readings.last?.timestamp)
        XCTAssertEqual(
            Set(displayReadings.map(\.timestamp)).count,
            displayReadings.count
        )

        let markerStartedAt = ProcessInfo.processInfo.systemUptime
        var marker: GeoPoint?
        for index in 0..<1_000 {
            marker = RouteTimelineDataEngine.playbackCoordinate(
                at: start.addingTimeInterval(TimeInterval(index * 9)),
                inNormalizedReadings: readings
            )
        }
        let markerElapsed = ProcessInfo.processInfo.systemUptime
            - markerStartedAt
        XCTAssertNotNil(marker)
        XCTAssertLessThan(markerElapsed, 0.2)
    }
}
