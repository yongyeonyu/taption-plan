import CoreLocation
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

    func testMapRouteRefreshDoesNotEraseSameDayCachedReadingsOnEmptyLoad() {
        let cached = [reading(10, latitude: 37)]
        let day = TimeSpan(start: date(0), end: date(1_439))

        XCTAssertEqual(
            MapHomeRouteReadingsPolicy.merging(
                existing: cached,
                loaded: [],
                in: day
            ),
            cached
        )
    }

    func testMapRouteRefreshDropsReadingsFromAnotherDay() {
        let previousDay = reading(-10, latitude: 36)
        let currentDay = reading(10, latitude: 37)
        let day = TimeSpan(start: date(0), end: date(1_439))

        XCTAssertEqual(
            MapHomeRouteReadingsPolicy.merging(
                existing: [previousDay],
                loaded: [currentDay],
                in: day
            ),
            [currentDay]
        )
    }

    func testMapRouteTaskUsesCalendarDayKey() {
        let first = date(30)
        let second = date(1_200)

        XCTAssertEqual(
            MapHomeRouteReadingsPolicy.dayKey(for: first, calendar: calendar),
            MapHomeRouteReadingsPolicy.dayKey(for: second, calendar: calendar)
        )
    }

    func testTransitBoardingRefreshPolicyLimitsLiveUpdatesAndBucketsCutoff() {
        let start = date(60)

        XCTAssertTrue(
            MapHomeTransitBoardingRefreshPolicy.shouldRefresh(
                lastRefresh: nil,
                at: start
            )
        )
        XCTAssertFalse(
            MapHomeTransitBoardingRefreshPolicy.shouldRefresh(
                lastRefresh: start,
                at: start.addingTimeInterval(29)
            )
        )
        XCTAssertTrue(
            MapHomeTransitBoardingRefreshPolicy.shouldRefresh(
                lastRefresh: start,
                at: start.addingTimeInterval(30)
            )
        )
        XCTAssertTrue(
            MapHomeTransitBoardingRefreshPolicy.shouldRefresh(
                lastRefresh: start,
                at: start.addingTimeInterval(-1)
            )
        )
        XCTAssertEqual(
            MapHomeTransitBoardingRefreshPolicy.cutoffBucket(
                start.addingTimeInterval(29)
            ),
            MapHomeTransitBoardingRefreshPolicy.cutoffBucket(start)
        )
        XCTAssertNotEqual(
            MapHomeTransitBoardingRefreshPolicy.cutoffBucket(
                start.addingTimeInterval(30)
            ),
            MapHomeTransitBoardingRefreshPolicy.cutoffBucket(start)
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

    func testHistoricalDisplayKeepsLegacyLocationBackfillWithoutUsingItForRouteInference() {
        let locationBackfill = SensorReading(
            timestamp: date(5),
            point: GeoPoint(
                latitude: 37.5,
                longitude: 127,
                altitude: 0,
                horizontalAccuracy: 250,
                verticalAccuracy: 100
            ),
            gpsAvailable: false,
            watchWorkoutKind: "사진 위치"
        )

        XCTAssertTrue(
            RouteTimelineDataEngine.normalizedReadings([locationBackfill])
                .isEmpty
        )
        XCTAssertEqual(
            RouteTimelineDataEngine.normalizedDisplayReadings([locationBackfill]),
            [locationBackfill]
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

    func testPlaybackBeforeFirstSampleHoldsEarliestArchivePointAndAfterLastHoldsLastPoint() throws {
        let beforeFirst = RouteTimelineDataEngine.project(
            selectedDate: date(0),
            throughMinute: 5,
            actuals: [],
            readings: [reading(10, latitude: 37)],
            calendar: calendar
        )
        XCTAssertEqual(
            try XCTUnwrap(beforeFirst.coordinateAtCutoff).latitude,
            37,
            accuracy: 0.0001
        )

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

    func testHistoricalPlaybackKeepsMarkerWhenArchiveStartsAfterOldTimelineTime() throws {
        let archive = [reading(1_420, latitude: 37.4)]
        let live = [reading(1_435, latitude: 37.5)]
        let projection = RouteTimelineDataEngine.project(
            selectedDate: date(0),
            throughMinute: 900,
            actuals: [],
            readings: archive,
            liveReadings: live,
            calendar: calendar
        )

        XCTAssertEqual(
            try XCTUnwrap(projection.coordinateAtCutoff).latitude,
            37.4,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(
                RouteTimelineDataEngine.playbackCoordinate(
                    at: date(900),
                    inNormalizedReadings: RouteTimelineDataEngine.normalizedReadings(
                        archive + live
                    )
                )
            ).latitude,
            37.4,
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

    func testBackgroundWakePatternStillDrawsRecordedTravelCluster() {
        let readings = [
            reading(19 * 60 + 14, latitude: 37.56228),
            reading(19 * 60 + 20, latitude: 37.56434),
            reading(19 * 60 + 24, latitude: 37.56508),
            reading(19 * 60 + 36, latitude: 37.57165),
            reading(19 * 60 + 38, latitude: 37.57025),
            reading(19 * 60 + 40, latitude: 37.56919),
            reading(19 * 60 + 54, latitude: 37.55173),
            reading(20 * 60 + 38, latitude: 37.52400),
        ]
        let projection = RouteTimelineDataEngine.project(
            selectedDate: date(0),
            throughMinute: 20 * 60 + 40,
            actuals: [],
            readings: readings,
            calendar: calendar
        )

        XCTAssertEqual(projection.samples.count, readings.count)
        XCTAssertEqual(projection.segments.count, 1)
        XCTAssertGreaterThanOrEqual(
            projection.segments.flatMap(\.coordinates).count,
            7
        )
    }

    func testSparseGPSFilterKeepsPlaybackPointButDropsLongStraightLine() throws {
        let readings = [
            reading(0, latitude: 37),
            reading(10, latitude: 37.02),
        ]
        let projection = RouteTimelineDataEngine.project(
            selectedDate: date(0),
            throughMinute: 10,
            actuals: [],
            readings: readings,
            filtersSparseRouteConnections: true,
            calendar: calendar
        )

        XCTAssertTrue(projection.segments.isEmpty)
        XCTAssertEqual(
            try XCTUnwrap(projection.coordinateAtCutoff).latitude,
            37.02,
            accuracy: 0.0001
        )
    }

    func testConfirmedSubwayUsesStoredRouteForLineAndPlayback() throws {
        let route = SubwayRoutePath(
            stops: [
                SubwayRouteStop(
                    lineName: "공항철도",
                    order: 0,
                    stationName: "출발",
                    latitude: 37,
                    longitude: 127
                ),
                SubwayRouteStop(
                    lineName: "공항철도",
                    order: 1,
                    stationName: "중간",
                    latitude: 37.01,
                    longitude: 127
                ),
                SubwayRouteStop(
                    lineName: "공항철도",
                    order: 2,
                    stationName: "도착",
                    latitude: 37.02,
                    longitude: 127
                ),
            ],
            lineNames: ["공항철도"],
            transferStationNames: []
        )
        let travel = TravelSegment(
            mode: .subway,
            span: TimeSpan(start: date(0), end: date(30)),
            distanceMeters: 2_200,
            confidence: .high,
            evidence: ["사용자 확인"],
            isConfirmed: true,
            subwayRoute: route
        )
        let projection = RouteTimelineDataEngine.project(
            selectedDate: date(0),
            throughMinute: 15,
            actuals: [],
            travel: [travel],
            readings: [
                reading(0, latitude: 36.5),
                reading(10, latitude: 36.6),
                reading(20, latitude: 36.7),
            ],
            calendar: calendar
        )

        XCTAssertEqual(
            try XCTUnwrap(projection.coordinateAtCutoff).latitude,
            37.01,
            accuracy: 0.0001
        )
        XCTAssertTrue(
            projection.segments.allSatisfy {
                $0.confirmedSubwayTravelID == travel.id
            }
        )
        XCTAssertEqual(
            try XCTUnwrap(
                RouteTimelineDataEngine.confirmedSubwayCoordinates(
                    for: travel,
                    through: date(15)
                ).last
            ).latitude,
            37.01,
            accuracy: 0.0001
        )
    }

    func testUnconfirmedSubwayKeepsGPSRoute() {
        let route = SubwayRoutePath(
            stops: [
                SubwayRouteStop(
                    lineName: "1호선",
                    order: 0,
                    stationName: "출발",
                    latitude: 37,
                    longitude: 127
                ),
                SubwayRouteStop(
                    lineName: "1호선",
                    order: 1,
                    stationName: "도착",
                    latitude: 37.01,
                    longitude: 127
                ),
            ],
            lineNames: ["1호선"],
            transferStationNames: []
        )
        let travel = TravelSegment(
            mode: .subway,
            span: TimeSpan(start: date(0), end: date(10)),
            distanceMeters: 1_100,
            confidence: .medium,
            evidence: [],
            isConfirmed: false,
            subwayRoute: route
        )
        let projection = RouteTimelineDataEngine.project(
            selectedDate: date(0),
            throughMinute: 10,
            actuals: [],
            travel: [travel],
            readings: [
                reading(0, latitude: 36.5),
                reading(10, latitude: 36.6),
            ],
            calendar: calendar
        )

        XCTAssertFalse(projection.segments.isEmpty)
        XCTAssertTrue(
            projection.segments.allSatisfy {
                $0.confirmedSubwayTravelID == nil
            }
        )
        XCTAssertEqual(projection.coordinateAtCutoff?.latitude, 36.6)
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

    func testGPSLoggerRouteFilterRemovesDriftAndImpossibleJumpWithoutMutatingRawReadings() {
        let start = date(0)
        func sample(
            _ seconds: TimeInterval,
            latitude: Double,
            id: String,
            accuracy: Double = 5,
            motion: MotionKind = .unknown
        ) -> SensorReading {
            SensorReading(
                id: UUID(uuidString: id)!,
                timestamp: start.addingTimeInterval(seconds),
                point: GeoPoint(
                    latitude: latitude,
                    longitude: 127,
                    altitude: 0,
                    horizontalAccuracy: accuracy,
                    verticalAccuracy: 5
                ),
                motion: motion
            )
        }

        let readings = [
            sample(0, latitude: 37, id: "00000000-0000-0000-0000-000000000001"),
            sample(1, latitude: 37.000005, id: "00000000-0000-0000-0000-000000000002"),
            sample(5, latitude: 37.0001, id: "00000000-0000-0000-0000-000000000003"),
            sample(6, latitude: 37.005, id: "00000000-0000-0000-0000-000000000004"),
            sample(10, latitude: 37.0002, id: "00000000-0000-0000-0000-000000000005"),
        ]
        let original = readings

        let filtered = GPSLoggerRouteFilter.filter(readings)

        XCTAssertEqual(readings, original)
        XCTAssertEqual(
            filtered.map(\.id.uuidString),
            [
                "00000000-0000-0000-0000-000000000001",
                "00000000-0000-0000-0000-000000000003",
                "00000000-0000-0000-0000-000000000005",
            ]
        )
        XCTAssertEqual(filtered.count, 3)
        XCTAssertTrue(filtered[1].trackingSessionEnded == true)
    }

    func testGPSLoggerRouteFilterBoundsAccuracyAndIsDeterministic() {
        let start = date(0)
        func sample(
            _ seconds: TimeInterval,
            latitude: Double,
            id: String,
            accuracy: Double
        ) -> SensorReading {
            SensorReading(
                id: UUID(uuidString: id)!,
                timestamp: start.addingTimeInterval(seconds),
                point: GeoPoint(
                    latitude: latitude,
                    longitude: 127,
                    altitude: 0,
                    horizontalAccuracy: accuracy,
                    verticalAccuracy: 5
                ),
                locationFixQuality: .approximate,
                gpsAvailable: false
            )
        }

        let readings = [
            sample(
                0,
                latitude: 37,
                id: "00000000-0000-0000-0000-000000000011",
                accuracy: 500
            ),
            sample(
                10,
                latitude: 37.0001,
                id: "00000000-0000-0000-0000-000000000012",
                accuracy: 500
            ),
            sample(
                20,
                latitude: 37.0002,
                id: "00000000-0000-0000-0000-000000000013",
                accuracy: 1_001
            ),
        ]

        let first = GPSLoggerRouteFilter.filter(readings)
        let second = GPSLoggerRouteFilter.filter(readings)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map(\.id.uuidString), [
            "00000000-0000-0000-0000-000000000011",
            "00000000-0000-0000-0000-000000000012",
        ])
        XCTAssertTrue(first.allSatisfy { $0.point?.horizontalAccuracy ?? .infinity <= 1_000 })
    }

    func testGPSLoggerRouteFilterStartsNewSegmentAfterLongGap() {
        let start = date(0)
        let readings = [
            SensorReading(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!,
                timestamp: start,
                point: GeoPoint(
                    latitude: 37,
                    longitude: 127,
                    altitude: 0,
                    horizontalAccuracy: 5,
                    verticalAccuracy: 5
                )
            ),
            SensorReading(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000022")!,
                timestamp: start.addingTimeInterval(16 * 60),
                point: GeoPoint(
                    latitude: 38,
                    longitude: 127,
                    altitude: 0,
                    horizontalAccuracy: 5,
                    verticalAccuracy: 5
                )
            ),
        ]

        XCTAssertEqual(
            GPSLoggerRouteFilter.filter(readings).map(\.id),
            readings.map(\.id)
        )
    }

    func testGPSLoggerRouteFilterKeepsOnlyLowConfidenceRunBoundaries() {
        let start = date(0)
        func sample(
            _ seconds: TimeInterval,
            latitude: Double,
            id: String,
            accuracy: Double
        ) -> SensorReading {
            SensorReading(
                id: UUID(uuidString: id)!,
                timestamp: start.addingTimeInterval(seconds),
                point: GeoPoint(
                    latitude: latitude,
                    longitude: 127,
                    altitude: 0,
                    horizontalAccuracy: accuracy,
                    verticalAccuracy: 5
                ),
                gpsAvailable: accuracy <= 150
            )
        }

        let readings = [
            sample(
                0,
                latitude: 37,
                id: "00000000-0000-0000-0000-000000000031",
                accuracy: 5
            ),
            sample(
                1,
                latitude: 37.0002,
                id: "00000000-0000-0000-0000-000000000032",
                accuracy: 500
            ),
            sample(
                2,
                latitude: 37.0003,
                id: "00000000-0000-0000-0000-000000000033",
                accuracy: 500
            ),
            sample(
                3,
                latitude: 37.0004,
                id: "00000000-0000-0000-0000-000000000034",
                accuracy: 500
            ),
            sample(
                4,
                latitude: 37.0005,
                id: "00000000-0000-0000-0000-000000000035",
                accuracy: 5
            ),
        ]

        let filtered = GPSLoggerRouteFilter.filter(readings)

        XCTAssertTrue(filtered.contains { $0.id == readings[1].id })
        XCTAssertTrue(filtered.contains { $0.id == readings[3].id })
        XCTAssertFalse(filtered.contains { $0.id == readings[2].id })
    }

    func testDisplayReadingsKeepsCornersAndGapSegmentBoundaries() {
        let start = date(0)
        let readings = (0..<200).map { index in
            let timestampOffset = index >= 120
                ? Double(index) + 16 * 60
                : Double(index)
            let latitude = index <= 50
                ? 37 + Double(index) / 1_000_000
                : 37.00005
            let longitude = index <= 50
                ? 127
                : 127 + Double(index - 50) / 1_000_000
            return SensorReading(
                timestamp: start.addingTimeInterval(timestampOffset),
                point: GeoPoint(
                    latitude: latitude,
                    longitude: longitude,
                    altitude: 0,
                    horizontalAccuracy: 5,
                    verticalAccuracy: 5
                )
            )
        }

        let displayed = RouteTimelineDataEngine.displayReadings(
            from: readings,
            maximumCount: 20
        )
        let timestamps = Set(displayed.map(\.timestamp))

        XCTAssertEqual(displayed.count, 20)
        XCTAssertEqual(displayed.first?.timestamp, readings.first?.timestamp)
        XCTAssertEqual(displayed.last?.timestamp, readings.last?.timestamp)
        XCTAssertTrue(timestamps.contains(readings[50].timestamp))
        XCTAssertTrue(timestamps.contains(readings[119].timestamp))
        XCTAssertTrue(timestamps.contains(readings[120].timestamp))
    }

    func testConfirmedRoadRouteDoesNotCreateDottedOverlayOrMutateTravel() {
        let from = PlaceStay(
            placeKey: "home",
            displayName: "집",
            span: TimeSpan(start: date(0), end: date(10)),
            confidence: .high,
            point: GeoPoint(
                latitude: 37.50,
                longitude: 126.90,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            )
        )
        let to = PlaceStay(
            placeKey: "work",
            displayName: "회사",
            span: TimeSpan(start: date(60), end: date(120)),
            confidence: .high,
            point: GeoPoint(
                latitude: 37.60,
                longitude: 127.00,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            )
        )
        let travel = TravelSegment(
            fromPlaceID: from.id,
            toPlaceID: to.id,
            mode: .bus,
            span: TimeSpan(start: date(10), end: date(60)),
            distanceMeters: 10_000,
            confidence: .high,
            evidence: ["버스"],
            isConfirmed: true
        )
        let original = travel

        XCTAssertTrue(
            ExpectedRouteRequestEngine.requests(
                travel: [travel],
                places: [from, to],
                readings: [],
                in: TimeSpan(start: date(0), end: date(1_440)),
                through: date(1_440)
            ).isEmpty
        )
        XCTAssertEqual(travel, original)
    }

    func testExpectedSubwayRouteUsesRegisteredEndpointsAndCollapsesBridgedDuplicates()
        throws {
        let home = FrequentPlace(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            kind: .home,
            point: GeoPoint(
                latitude: 37.50,
                longitude: 126.90,
                altitude: 0,
                horizontalAccuracy: 10,
                verticalAccuracy: 10
            )
        )
        let company = FrequentPlace(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            kind: .company,
            point: GeoPoint(
                latitude: 37.60,
                longitude: 127.00,
                altitude: 0,
                horizontalAccuracy: 10,
                verticalAccuracy: 10
            )
        )
        let from = PlaceStay(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
            placeKey: home.stablePlaceKey,
            displayName: "집",
            span: TimeSpan(start: date(0), end: date(10)),
            confidence: .high,
            point: nil,
            isConfirmed: true
        )
        let to = PlaceStay(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000004")!,
            placeKey: company.stablePlaceKey,
            displayName: "회사",
            span: TimeSpan(start: date(100), end: date(140)),
            confidence: .high,
            point: nil,
            isConfirmed: true
        )
        let segmentIDs = [
            "50000000-0000-0000-0000-000000000005",
            "60000000-0000-0000-0000-000000000006",
            "70000000-0000-0000-0000-000000000007",
        ].map { UUID(uuidString: $0)! }
        let spans = [(10, 20), (30, 40), (19, 31)]
        let travel = segmentIDs.enumerated().map { index, id in
            TravelSegment(
                id: id,
                fromPlaceID: from.id,
                toPlaceID: to.id,
                mode: .subway,
                span: TimeSpan(
                    start: date(spans[index].0),
                    end: date(spans[index].1)
                ),
                distanceMeters: 19_000,
                confidence: index == 0 ? .medium : .low,
                evidence: index == 0 ? ["자동 추정"] : [],
                isConfirmed: false,
                subwayRoute: nil,
                isClassificationLocked: true
            )
        }
        let original = travel

        let requests = ExpectedRouteRequestEngine.requests(
            travel: travel,
            places: [from, to],
            readings: [],
            in: TimeSpan(start: date(0), end: date(1_440)),
            through: date(1_440),
            frequentPlaces: [home, company]
        )

        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.transport, .transit)
        XCTAssertEqual(request.start, home.point)
        XCTAssertEqual(request.end, company.point)
        XCTAssertEqual(request.departureDate, date(10))
        XCTAssertEqual(request.arrivalDate, date(40))
        XCTAssertEqual(travel, original)
    }

    func testExpectedRouteRejectsUnconfirmedSegmentWithoutBothRegisteredEndpoints() {
        let home = FrequentPlace(
            kind: .home,
            point: GeoPoint(
                latitude: 37.50,
                longitude: 126.90,
                altitude: 0,
                horizontalAccuracy: 10,
                verticalAccuracy: 10
            )
        )
        let from = PlaceStay(
            placeKey: home.stablePlaceKey,
            displayName: "집",
            span: TimeSpan(start: date(0), end: date(10)),
            confidence: .high,
            point: nil,
            isConfirmed: true
        )
        let to = PlaceStay(
            placeKey: "missing-company",
            displayName: "회사",
            span: TimeSpan(start: date(100), end: date(140)),
            confidence: .high,
            point: nil,
            isConfirmed: true
        )
        let travel = TravelSegment(
            fromPlaceID: from.id,
            toPlaceID: to.id,
            mode: .subway,
            span: TimeSpan(start: date(10), end: date(100)),
            distanceMeters: 19_000,
            confidence: .low,
            evidence: [],
            isConfirmed: false,
            isClassificationLocked: true
        )

        XCTAssertTrue(
            ExpectedRouteRequestEngine.requests(
                travel: [travel],
                places: [from, to],
                readings: [],
                in: TimeSpan(start: date(0), end: date(1_440)),
                through: date(1_440),
                frequentPlaces: [home]
            ).isEmpty
        )
    }

    func testRegisteredEndpointsAlwaysRequestBestExpectedRoadRoute() throws {
        let home = FrequentPlace(
            kind: .home,
            point: GeoPoint(
                latitude: 37.50,
                longitude: 126.90,
                altitude: 0,
                horizontalAccuracy: 10,
                verticalAccuracy: 10
            )
        )
        let company = FrequentPlace(
            kind: .company,
            point: GeoPoint(
                latitude: 37.60,
                longitude: 127.00,
                altitude: 0,
                horizontalAccuracy: 10,
                verticalAccuracy: 10
            )
        )
        let from = PlaceStay(
            placeKey: home.stablePlaceKey,
            displayName: "집",
            span: TimeSpan(start: date(0), end: date(10)),
            confidence: .high
        )
        let to = PlaceStay(
            placeKey: company.stablePlaceKey,
            displayName: "회사",
            span: TimeSpan(start: date(100), end: date(140)),
            confidence: .high
        )
        let travel = TravelSegment(
            fromPlaceID: from.id,
            toPlaceID: to.id,
            mode: .car,
            span: TimeSpan(start: date(10), end: date(100)),
            distanceMeters: 19_000,
            confidence: .low,
            evidence: [],
            isClassificationLocked: true
        )

        let request = try XCTUnwrap(
            ExpectedRouteRequestEngine.requests(
                travel: [travel],
                places: [from, to],
                readings: [],
                in: TimeSpan(start: date(0), end: date(1_440)),
                through: date(1_440),
                frequentPlaces: [home, company]
            ).first
        )
        XCTAssertEqual(request.transport, .automobile)
        XCTAssertEqual(request.provenance, "explicit-travel-mode")
        XCTAssertEqual(request.confidence, 1)
    }

    func testExpectedRouteSkipsStoredSubwayAndUsesTransitForTrain() throws {
        let subway = TravelSegment(
            mode: .subway,
            span: TimeSpan(start: date(10), end: date(30)),
            distanceMeters: 4_000,
            confidence: .high,
            evidence: ["지하철"],
            isConfirmed: true,
            subwayRoute: SubwayRoutePath(
                stops: [
                    SubwayRouteStop(
                        lineName: "1호선",
                        order: 0,
                        stationName: "A",
                        latitude: 37.5,
                        longitude: 126.9
                    ),
                    SubwayRouteStop(
                        lineName: "1호선",
                        order: 1,
                        stationName: "B",
                        latitude: 37.6,
                        longitude: 127.0
                    ),
                ],
                lineNames: ["1호선"],
                transferStationNames: []
            )
        )
        let train = TravelSegment(
            mode: .train,
            span: TimeSpan(start: date(40), end: date(80)),
            distanceMeters: 20_000,
            confidence: .high,
            evidence: ["기차"]
        )
        let requests = ExpectedRouteRequestEngine.requests(
            travel: [subway, train],
            places: [],
            readings: [
                reading(40, latitude: 37.1),
                reading(80, latitude: 37.3),
            ],
            in: TimeSpan(start: date(0), end: date(1_440)),
            through: date(1_440)
        )

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.segmentID, train.id)
        XCTAssertEqual(requests.first?.transport, .transit)
    }

    func testExpectedBusRouteUsesTransitAndKeepsInferenceProvenance() throws {
        let bus = TravelSegment(
            mode: .bus,
            span: TimeSpan(start: date(10), end: date(40)),
            distanceMeters: 8_000,
            confidence: .medium,
            evidence: ["버스"]
        )
        let requests = ExpectedRouteRequestEngine.requests(
            travel: [bus],
            places: [],
            readings: [
                reading(10, latitude: 37.10),
                reading(40, latitude: 37.16),
            ],
            in: TimeSpan(start: date(0), end: date(1_440)),
            through: date(1_440)
        )

        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.transport, .transit)
        XCTAssertEqual(request.provenance, "explicit-travel-mode")
        XCTAssertEqual(request.confidence, 1)
    }

    func testExpectedRouteSkipsCompletelyRecordedGPS() {
        let segment = TravelSegment(
            mode: .car,
            span: TimeSpan(start: date(10), end: date(40)),
            distanceMeters: 3_000,
            confidence: .medium,
            evidence: ["자동차"]
        )
        let readings = [10, 20, 30, 40].map {
            reading($0, latitude: 37 + Double($0) / 1_000)
        }

        XCTAssertTrue(
            ExpectedRouteRequestEngine.requests(
                travel: [segment],
                places: [],
                readings: readings,
                in: TimeSpan(start: date(0), end: date(1_440)),
                through: date(1_440)
            ).isEmpty
        )
    }

    func testExpectedRouteCoversOnlyTheMissingGPSGap() throws {
        let segment = TravelSegment(
            mode: .car,
            span: TimeSpan(start: date(10), end: date(100)),
            distanceMeters: 9_000,
            confidence: .medium,
            evidence: ["자동차"]
        )
        let startOfGap = reading(40, latitude: 37.04)
        let endOfGap = reading(100, latitude: 37.10)
        let request = try XCTUnwrap(
            ExpectedRouteRequestEngine.requests(
                travel: [segment],
                places: [],
                readings: [
                    reading(10, latitude: 37.01),
                    reading(20, latitude: 37.02),
                    reading(30, latitude: 37.03),
                    startOfGap,
                    endOfGap,
                ],
                in: TimeSpan(start: date(0), end: date(1_440)),
                through: date(1_440)
            ).first
        )

        XCTAssertEqual(request.departureDate, date(40))
        XCTAssertEqual(request.arrivalDate, date(100))
        XCTAssertEqual(request.start, startOfGap.point)
        XCTAssertEqual(request.end, endOfGap.point)
    }

    func testExpectedAirAndShipRoutesUseDirectExpectedPath() throws {
        let airplane = TravelSegment(
            mode: .airplane,
            span: TimeSpan(start: date(10), end: date(70)),
            distanceMeters: 50_000,
            confidence: .high,
            evidence: ["비행기"]
        )
        let ship = TravelSegment(
            mode: .ship,
            span: TimeSpan(start: date(80), end: date(140)),
            distanceMeters: 12_000,
            confidence: .high,
            evidence: ["배"]
        )
        let requests = ExpectedRouteRequestEngine.requests(
            travel: [airplane, ship],
            places: [],
            readings: [
                reading(10, latitude: 37.10),
                reading(70, latitude: 37.55),
                reading(80, latitude: 37.60),
                reading(140, latitude: 37.70),
            ],
            in: TimeSpan(start: date(0), end: date(1_440)),
            through: date(1_440)
        )

        XCTAssertEqual(requests.map(\.transport), [.direct, .direct])
        XCTAssertEqual(requests.map(\.provenance), ["explicit-travel-mode", "explicit-travel-mode"])
    }

    func testExpectedRouteAtPartialCutoffUsesLatestObservedEndpoint() throws {
        let destination = PlaceStay(
            placeKey: "destination",
            displayName: "도착지",
            span: TimeSpan(start: date(60), end: date(90)),
            confidence: .high,
            point: GeoPoint(
                latitude: 38,
                longitude: 127,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            )
        )
        let segment = TravelSegment(
            toPlaceID: destination.id,
            mode: .car,
            span: TimeSpan(start: date(10), end: date(60)),
            distanceMeters: 10_000,
            confidence: .medium,
            evidence: ["자동차"]
        )
        let observed = reading(30, latitude: 37.4)
        let request = try XCTUnwrap(
            ExpectedRouteRequestEngine.requests(
                travel: [segment],
                places: [destination],
                readings: [reading(10, latitude: 37.1), observed],
                in: TimeSpan(start: date(0), end: date(1_440)),
                through: date(30)
            ).first
        )

        XCTAssertEqual(request.end, observed.point)
        XCTAssertNotEqual(request.end, destination.point)
        XCTAssertEqual(request.arrivalDate, date(30))
    }

    func testObservedRouteSegmentsDeriveSpeedFromEndpointTimestamps() throws {
        let projection = RouteTimelineDataEngine.project(
            selectedDate: date(0),
            throughMinute: 20,
            actuals: [],
            readings: [
                reading(0, latitude: 37),
                reading(10, latitude: 37.01),
                reading(20, latitude: 37.03),
            ],
            calendar: calendar
        )

        let speeds = try XCTUnwrap(
            projection.segments.map(\.speedMetersPerSecond)
                .compactMap { $0 }
        )
        XCTAssertEqual(speeds.count, 2)
        XCTAssertGreaterThan(speeds[0], 0)
        XCTAssertGreaterThan(speeds[1], speeds[0])
    }

    func testRouteSpeedGradientUsesVisibleRouteRange() {
        let speeds = [1.0, 5.0, 10.0]

        XCTAssertEqual(
            RouteSpeedGradient.normalized(
                speedMetersPerSecond: 1,
                in: speeds
            ),
            0
        )
        XCTAssertEqual(
            RouteSpeedGradient.normalized(
                speedMetersPerSecond: 10,
                in: speeds
            ),
            1
        )
        XCTAssertNotEqual(
            RouteSpeedGradient.colorHex(
                speedMetersPerSecond: 1,
                in: speeds
            ),
            RouteSpeedGradient.colorHex(
                speedMetersPerSecond: 10,
                in: speeds
            )
        )
        XCTAssertNil(
            RouteSpeedGradient.colorHex(
                speedMetersPerSecond: nil,
                in: speeds
            )
        )
    }

    func testAppleRouteFallbackKeepsPreferredTransportFirst() {
        XCTAssertEqual(
            MapHomeAppleRouteFallbackPolicy.transports(for: .automobile),
            [.automobile, .walking]
        )
        XCTAssertEqual(
            MapHomeAppleRouteFallbackPolicy.transports(for: .transit),
            [.transit, .automobile, .walking]
        )
        XCTAssertEqual(
            MapHomeAppleRouteFallbackPolicy.transports(for: .walking),
            [.walking, .automobile]
        )
        XCTAssertEqual(
            MapHomeAppleRouteFallbackPolicy.transports(for: .direct),
            [.direct]
        )
    }

    func testApplePlaybackHeadingUsesLookAheadAtRouteBend() {
        let heading = MapHomeApplePlaybackMath.heading(
            at: date(5),
            departureDate: date(0),
            arrivalDate: date(10),
            coordinates: [
                CLLocationCoordinate2D(latitude: 37, longitude: 127),
                CLLocationCoordinate2D(latitude: 37, longitude: 127.01),
                CLLocationCoordinate2D(latitude: 37.008, longitude: 127.01),
            ]
        )

        XCTAssertEqual(heading, 0, accuracy: 0.5)
    }

    func testApplePlaybackHeadingIsQuantizedForStableAnnotationRotation() {
        XCTAssertEqual(MapHomeApplePlaybackMath.stableHeading(359), 0)
        XCTAssertEqual(MapHomeApplePlaybackMath.stableHeading(1), 0)
        XCTAssertEqual(MapHomeApplePlaybackMath.stableHeading(89), 90)
    }

    func testMapHomeTimelinePlaybackUsesRouteDistanceForRatio() {
        let segment = RouteTimelineSegment(
            id: "route",
            start: date(0),
            end: date(100),
            category: .movement,
            colorHex: RouteTimelineCategory.movement.colorHex,
            opacity: 1,
            coordinates: [
                GeoPoint(latitude: 37, longitude: 127, altitude: 0, horizontalAccuracy: 0, verticalAccuracy: 0),
                GeoPoint(latitude: 37, longitude: 127.0001, altitude: 0, horizontalAccuracy: 0, verticalAccuracy: 0),
                GeoPoint(latitude: 37, longitude: 127.001, altitude: 0, horizontalAccuracy: 0, verticalAccuracy: 0),
            ],
            speedMetersPerSecond: 1,
            confirmedSubwayTravelID: nil
        )

        let point = MapHomeRouteTimelinePlaybackMath.coordinate(
            at: date(50),
            in: [segment]
        )

        XCTAssertNotNil(point)
        XCTAssertEqual(point?.longitude ?? 0, 127.0005, accuracy: 0.00002)
    }

    func testWBSPlaybackUsesExplicitMovementAndResolvedRoadDistance() throws {
        let home = PlaceStay(
            placeKey: "home",
            displayName: "집",
            span: TimeSpan(start: date(0), end: date(10)),
            confidence: .high,
            point: GeoPoint(
                latitude: 37,
                longitude: 127,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            )
        )
        let office = PlaceStay(
            placeKey: "office",
            displayName: "회사",
            span: TimeSpan(start: date(100), end: date(180)),
            confidence: .high,
            point: GeoPoint(
                latitude: 37,
                longitude: 127.001,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            )
        )
        let travel = TravelSegment(
            fromPlaceID: home.id,
            toPlaceID: office.id,
            mode: .bus,
            span: TimeSpan(start: date(10), end: date(100)),
            distanceMeters: 100,
            confidence: .high,
            evidence: ["버스"]
        )
        let overlappingDuplicate = TravelSegment(
            fromPlaceID: home.id,
            toPlaceID: office.id,
            mode: .bus,
            span: TimeSpan(start: date(20), end: date(90)),
            distanceMeters: 100,
            confidence: .medium,
            evidence: []
        )
        let legID = "movement-\(travel.id.uuidString)"
        let roadCoordinates = [
            home.point!,
            GeoPoint(
                latitude: 37,
                longitude: 127.0001,
                altitude: 0,
                horizontalAccuracy: -1,
                verticalAccuracy: -1
            ),
            office.point!,
        ]
        let projection = MapHomeWBSPlaybackProjection.make(
            selectedDate: date(0),
            places: [home, office],
            travel: [travel, overlappingDuplicate],
            readings: [],
            resolvedRoutes: [
                MapHomeWBSResolvedRoute(
                    legID: legID,
                    coordinates: roadCoordinates
                )
            ],
            calendar: calendar
        )

        let movement = projection.legs.filter { $0.activity == .movement }
        XCTAssertEqual(movement.map(\.id), [legID])
        let frame = try XCTUnwrap(
            projection.frame(at: date(55), preferredForecastLegIDs: [legID])
        )
        XCTAssertEqual(frame.legID, legID)
        XCTAssertEqual(frame.mode, .bus)
        XCTAssertEqual(frame.coordinate.longitude, 127.0005, accuracy: 0.00002)
        XCTAssertEqual(frame.direction, .east)
        XCTAssertEqual(frame.stickmanFrameIndex, 12)
        let lineCoordinate = try XCTUnwrap(
            MapHomeExpectedRoutePlaybackMath.coordinate(
                at: date(55),
                departureDate: date(10),
                arrivalDate: date(100),
                coordinates: roadCoordinates.map {
                    CLLocationCoordinate2D(
                        latitude: $0.latitude,
                        longitude: $0.longitude
                    )
                }
            )
        )
        XCTAssertEqual(
            frame.coordinate.latitude,
            lineCoordinate.latitude,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            frame.coordinate.longitude,
            lineCoordinate.longitude,
            accuracy: 0.000_001
        )
    }

    func testWBSPlaybackCollapsesTransitivelyOverlappingForecastMovements()
        throws {
        let home = PlaceStay(
            placeKey: "home",
            displayName: "집",
            span: TimeSpan(start: date(0), end: date(10)),
            confidence: .high,
            point: GeoPoint(
                latitude: 37,
                longitude: 127,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            )
        )
        let office = PlaceStay(
            placeKey: "office",
            displayName: "회사",
            span: TimeSpan(start: date(40), end: date(60)),
            confidence: .high,
            point: GeoPoint(
                latitude: 37,
                longitude: 127.01,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            )
        )
        let first = TravelSegment(
            id: UUID(uuidString: "91000000-0000-0000-0000-000000000001")!,
            fromPlaceID: home.id,
            toPlaceID: office.id,
            mode: .car,
            span: TimeSpan(start: date(10), end: date(20)),
            distanceMeters: 1_000,
            confidence: .medium,
            evidence: ["자동 추정"]
        )
        let second = TravelSegment(
            id: UUID(uuidString: "92000000-0000-0000-0000-000000000002")!,
            fromPlaceID: home.id,
            toPlaceID: office.id,
            mode: .car,
            span: TimeSpan(start: date(30), end: date(40)),
            distanceMeters: 1_000,
            confidence: .low,
            evidence: []
        )
        let bridge = TravelSegment(
            id: UUID(uuidString: "93000000-0000-0000-0000-000000000003")!,
            fromPlaceID: home.id,
            toPlaceID: office.id,
            mode: .car,
            span: TimeSpan(start: date(19), end: date(31)),
            distanceMeters: 1_000,
            confidence: .low,
            evidence: []
        )
        let firstLegID = "movement-\(first.id.uuidString)"
        let projection = MapHomeWBSPlaybackProjection.make(
            selectedDate: date(0),
            places: [home, office],
            travel: [first, second, bridge],
            readings: [],
            resolvedRoutes: [
                MapHomeWBSResolvedRoute(
                    legID: firstLegID,
                    coordinates: [
                        home.point!,
                        GeoPoint(
                            latitude: 37.001,
                            longitude: 127.005,
                            altitude: 0,
                            horizontalAccuracy: -1,
                            verticalAccuracy: -1
                        ),
                        office.point!,
                    ]
                ),
            ],
            calendar: calendar
        )

        XCTAssertEqual(
            projection.legs.filter { $0.activity == .movement }.map(\.id),
            [firstLegID]
        )
        let movement = try XCTUnwrap(
            projection.legs.first { $0.activity == .movement }
        )
        XCTAssertEqual(movement.startDate, date(10))
        XCTAssertEqual(movement.endDate, date(40))
    }

    func testWBSPlaybackCreatesEvidenceBackedSubwayGapAndKeepsStayCameraAtCenter() throws {
        let firstPoint = GeoPoint(
            latitude: 37,
            longitude: 127,
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5
        )
        let secondPoint = GeoPoint(
            latitude: 37.001,
            longitude: 127.001,
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5
        )
        let first = PlaceStay(
            placeKey: "first",
            displayName: "첫 장소",
            span: TimeSpan(start: date(0), end: date(20)),
            confidence: .high,
            point: firstPoint
        )
        let second = PlaceStay(
            placeKey: "second",
            displayName: "둘째 장소",
            span: TimeSpan(start: date(80), end: date(120)),
            confidence: .high,
            point: secondPoint
        )
        let projection = MapHomeWBSPlaybackProjection.make(
            selectedDate: date(0),
            places: [first, second],
            travel: [],
            readings: [
                SensorReading(
                    timestamp: date(50),
                    point: GeoPoint(
                        latitude: 37.0005,
                        longitude: 127.0005,
                        altitude: 0,
                        horizontalAccuracy: 100,
                        verticalAccuracy: 20
                    ),
                    locationFixQuality: .approximate,
                    gpsAvailable: false,
                    nearbyStation: true,
                    nearbyStationName: "검암",
                    matchesRailRoute: true
                )
            ],
            calendar: calendar
        )

        XCTAssertEqual(
            projection.legs.filter { $0.activity == .movement }.count,
            1
        )
        let stay = try XCTUnwrap(projection.frame(at: date(10)))
        XCTAssertEqual(stay.activity, .stay)
        XCTAssertEqual(stay.cameraCoordinate, firstPoint)
        XCTAssertEqual(
            MapHomeWBSPlaybackProjection.distanceMeters(
                stay.coordinate,
                stay.cameraCoordinate
            ),
            30,
            accuracy: 0.5
        )
        let movementLegID = "movement-gap-\(first.id.uuidString)-\(second.id.uuidString)"
        let movement = try XCTUnwrap(
            projection.frame(at: date(50), preferredForecastLegIDs: [movementLegID])
        )
        XCTAssertEqual(movement.activity, .movement)
        XCTAssertEqual(movement.mode, .subway)
        XCTAssertTrue(movement.legID.hasPrefix("movement-gap-"))
    }

    func testSLP902A001ConfirmedSleepPinsPlaybackAndCameraWhilePreservingAdjacentMovementAndReadings() throws {
        let sleepAnchor = GeoPoint(
            latitude: 37.01,
            longitude: 127,
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5
        )
        let confirmedSleep = SleepSession(
            id: UUID(uuidString: "A902A001-0000-0000-0000-000000000001")!,
            span: TimeSpan(start: date(20), end: date(40)),
            asleepDuration: 20 * 60,
            awakeDuration: 0,
            inBedDuration: 20 * 60,
            stageDurations: [.asleepUnspecified: 20 * 60],
            sourceNames: ["Apple Watch"],
            segments: []
        )
        XCTAssertTrue(confirmedSleep.isAppleWatchConfirmed)
        let readings = [
            reading(0, latitude: 37),
            reading(10, latitude: 37.001),
            reading(20, latitude: sleepAnchor.latitude),
            reading(30, latitude: 37.02),
            reading(40, latitude: 37.03),
            reading(50, latitude: 37.04),
        ]
        let originalReadings = readings
        let projection = MapHomeWBSPlaybackProjection.make(
            selectedDate: date(0),
            places: [],
            travel: [],
            readings: readings,
            confirmedSleepSpans: [confirmedSleep.span],
            calendar: calendar
        )

        let beforeSleep = try XCTUnwrap(projection.frame(at: date(5)))
        XCTAssertEqual(beforeSleep.activity, .movement)
        XCTAssertEqual(beforeSleep.routePhase, .actual)
        XCTAssertEqual(beforeSleep.coordinate.latitude, 37.0005, accuracy: 0.0001)

        let duringSleep = try XCTUnwrap(projection.frame(at: date(25)))
        let laterDuringSleep = try XCTUnwrap(projection.frame(at: date(35)))
        for frame in [duringSleep, laterDuringSleep] {
            XCTAssertEqual(frame.activity, .stay)
            XCTAssertEqual(frame.coordinate.latitude, sleepAnchor.latitude, accuracy: 0.0001)
            XCTAssertEqual(frame.coordinate.longitude, sleepAnchor.longitude, accuracy: 0.0001)
            XCTAssertEqual(frame.cameraCoordinate, sleepAnchor)
        }

        let afterSleep = try XCTUnwrap(projection.frame(at: date(45)))
        XCTAssertEqual(afterSleep.activity, .movement)
        XCTAssertEqual(afterSleep.routePhase, .actual)
        XCTAssertEqual(afterSleep.coordinate.latitude, 37.035, accuracy: 0.0001)
        XCTAssertEqual(readings, originalReadings)
    }

    func testSLP902A001RouteTimelinePinsSleepCutoffAndOmitsSleepMovementWhilePreservingReadings() throws {
        let confirmedSleep = SleepSession(
            id: UUID(uuidString: "A902A001-0000-0000-0000-000000000002")!,
            span: TimeSpan(start: date(20), end: date(40)),
            asleepDuration: 20 * 60,
            awakeDuration: 0,
            inBedDuration: 20 * 60,
            stageDurations: [.asleepUnspecified: 20 * 60],
            sourceNames: ["Apple Watch"],
            segments: []
        )
        let readings = [
            reading(0, latitude: 37),
            reading(20, latitude: 37.01),
            reading(30, latitude: 37.02),
            reading(40, latitude: 37.03),
            reading(50, latitude: 37.04),
        ]
        let originalReadings = readings
        let sleepAnchor = try XCTUnwrap(readings[1].point)
        let projection = RouteTimelineDataEngine.project(
            selectedDate: date(0),
            throughMinute: 35,
            actuals: [],
            readings: readings,
            sleepSessions: [confirmedSleep],
            calendar: calendar
        )

        XCTAssertEqual(
            try XCTUnwrap(projection.coordinateAtCutoff),
            sleepAnchor
        )
        XCTAssertTrue(
            projection.segments.allSatisfy {
                $0.end <= confirmedSleep.span.start || $0.start >= date(35)
            }
        )
        XCTAssertEqual(readings, originalReadings)
    }

    func testWBSPlaybackDoesNotInventGapWithoutMovementEvidence() {
        let first = PlaceStay(
            placeKey: "first-no-evidence",
            displayName: "첫 장소",
            span: TimeSpan(start: date(0), end: date(20)),
            confidence: .high,
            point: GeoPoint(
                latitude: 37,
                longitude: 127,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            )
        )
        let second = PlaceStay(
            placeKey: "second-no-evidence",
            displayName: "둘째 장소",
            span: TimeSpan(start: date(80), end: date(120)),
            confidence: .high,
            point: GeoPoint(
                latitude: 37.001,
                longitude: 127.001,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            )
        )

        let projection = MapHomeWBSPlaybackProjection.make(
            selectedDate: date(0),
            places: [first, second],
            travel: [],
            readings: [],
            calendar: calendar
        )

        XCTAssertTrue(projection.legs.filter { $0.activity == .movement }.isEmpty)
    }

    func testWBSPlaybackDoesNotAddGapsCoveredByExplicitMovement() {
        let first = PlaceStay(
            placeKey: "first",
            displayName: "첫 장소",
            span: TimeSpan(start: date(0), end: date(10)),
            confidence: .high,
            point: GeoPoint(
                latitude: 37,
                longitude: 127,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            )
        )
        let middle = PlaceStay(
            placeKey: "middle",
            displayName: "중간 장소",
            span: TimeSpan(start: date(20), end: date(30)),
            confidence: .high,
            point: GeoPoint(
                latitude: 37.005,
                longitude: 127.005,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            )
        )
        let last = PlaceStay(
            placeKey: "last",
            displayName: "마지막 장소",
            span: TimeSpan(start: date(40), end: date(50)),
            confidence: .high,
            point: GeoPoint(
                latitude: 37.01,
                longitude: 127.01,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            )
        )
        let travel = TravelSegment(
            fromPlaceID: first.id,
            toPlaceID: last.id,
            mode: .car,
            span: TimeSpan(start: date(10), end: date(40)),
            distanceMeters: 1_500,
            confidence: .high,
            evidence: ["자동차"]
        )

        let projection = MapHomeWBSPlaybackProjection.make(
            selectedDate: date(0),
            places: [first, middle, last],
            travel: [travel],
            readings: [],
            calendar: calendar
        )

        XCTAssertEqual(
            projection.legs.filter { $0.routePhase == .forecast && $0.activity == .movement }
                .map(\.id),
            ["movement-\(travel.id.uuidString)"]
        )
    }

    func testWBSPlaybackActualTraceWinsAndBreaksAfterFifteenMinutes() throws {
        let place = PlaceStay(
            placeKey: "place",
            displayName: "장소",
            span: TimeSpan(start: date(0), end: date(120)),
            confidence: .high,
            point: GeoPoint(
                latitude: 37,
                longitude: 127,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            )
        )
        let projection = MapHomeWBSPlaybackProjection.make(
            selectedDate: date(0),
            places: [place],
            travel: [],
            readings: [
                reading(20, latitude: 37),
                reading(30, latitude: 37.001),
                reading(50, latitude: 37.002),
            ],
            calendar: calendar
        )

        let actual = projection.legs.filter { $0.routePhase == .actual }
        XCTAssertEqual(actual.count, 1)
        let frame = try XCTUnwrap(projection.frame(at: date(25)))
        XCTAssertEqual(frame.routePhase, .actual)
        XCTAssertEqual(frame.activity, .movement)
        XCTAssertTrue(frame.legID.hasPrefix("actual-"))
    }

    func testWBSPlaybackDoesNotAddForecastForContinuousRecordedCarRoute() {
        let home = PlaceStay(
            placeKey: "continuous-home",
            displayName: "집",
            span: TimeSpan(start: date(0), end: date(10)),
            confidence: .high,
            point: GeoPoint(
                latitude: 37,
                longitude: 127,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            )
        )
        let office = PlaceStay(
            placeKey: "continuous-office",
            displayName: "회사",
            span: TimeSpan(start: date(100), end: date(120)),
            confidence: .high,
            point: GeoPoint(
                latitude: 37,
                longitude: 127.01,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            )
        )
        let travel = TravelSegment(
            fromPlaceID: home.id,
            toPlaceID: office.id,
            mode: .car,
            span: TimeSpan(start: date(10), end: date(100)),
            distanceMeters: 1_000,
            confidence: .high,
            evidence: ["자동차"]
        )
        let readings = stride(from: 10, through: 100, by: 10).map { minute in
            var value = reading(minute, latitude: 37, id: UUID(), accuracy: 5)
            value.point = GeoPoint(
                latitude: 37,
                longitude: 127 + Double(minute - 10) / 9_000,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            )
            return value
        }

        let projection = MapHomeWBSPlaybackProjection.make(
            selectedDate: date(0),
            places: [home, office],
            travel: [travel],
            readings: readings,
            calendar: calendar
        )

        XCTAssertTrue(
            projection.legs.filter {
                $0.routePhase == .forecast && $0.activity == .movement
            }.isEmpty
        )
        XCTAssertTrue(
            projection.legs.contains {
                $0.routePhase == .actual && $0.activity == .movement
            }
        )
    }

    func testWBSPlaybackDoesNotUseHiddenForecastOrLastLegFallback() throws {
        let home = PlaceStay(
            placeKey: "hidden-forecast-home",
            displayName: "집",
            span: TimeSpan(start: date(0), end: date(60)),
            confidence: .high,
            point: GeoPoint(
                latitude: 37,
                longitude: 127,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            )
        )
        let office = PlaceStay(
            placeKey: "hidden-forecast-office",
            displayName: "회사",
            span: TimeSpan(start: date(100), end: date(120)),
            confidence: .high,
            point: GeoPoint(
                latitude: 37,
                longitude: 127.01,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            )
        )
        let travel = TravelSegment(
            fromPlaceID: home.id,
            toPlaceID: office.id,
            mode: .car,
            span: TimeSpan(start: date(10), end: date(55)),
            distanceMeters: 1_000,
            confidence: .high,
            evidence: ["자동차"]
        )
        let projection = MapHomeWBSPlaybackProjection.make(
            selectedDate: date(0),
            places: [home, office],
            travel: [travel],
            readings: [],
            calendar: calendar
        )

        let fallback = try XCTUnwrap(
            projection.frame(
                at: date(40),
                preferredForecastLegIDs: ["visible-other-forecast"]
            )
        )
        XCTAssertEqual(fallback.activity, .stay)
        XCTAssertNil(projection.frame(at: date(200)))
    }

    func testWBSPlaybackPrefersDottedForecastLegWhenItIsRendered() throws {
        let home = PlaceStay(
            placeKey: "forecast-home",
            displayName: "출발",
            span: TimeSpan(start: date(0), end: date(10)),
            confidence: .high,
            point: GeoPoint(
                latitude: 37,
                longitude: 127,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            )
        )
        let office = PlaceStay(
            placeKey: "forecast-office",
            displayName: "도착",
            span: TimeSpan(start: date(100), end: date(120)),
            confidence: .high,
            point: GeoPoint(
                latitude: 37,
                longitude: 127.001,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            )
        )
        let travel = TravelSegment(
            fromPlaceID: home.id,
            toPlaceID: office.id,
            mode: .car,
            span: TimeSpan(start: date(10), end: date(100)),
            distanceMeters: 100,
            confidence: .high,
            evidence: ["자동차"]
        )
        let legID = "movement-\(travel.id.uuidString)"
        let routeCoordinates = [home.point!, office.point!]
        let projection = MapHomeWBSPlaybackProjection.make(
            selectedDate: date(0),
            places: [home, office],
            travel: [travel],
            readings: [
                reading(20, latitude: 37),
                reading(30, latitude: 37.001),
            ],
            resolvedRoutes: [
                MapHomeWBSResolvedRoute(
                    legID: legID,
                    coordinates: routeCoordinates
                )
            ],
            calendar: calendar
        )

        let frame = try XCTUnwrap(
            projection.frame(
                at: date(25),
                preferredForecastLegIDs: [legID]
            )
        )
        XCTAssertEqual(frame.legID, legID)
        XCTAssertEqual(frame.routePhase, .forecast)
        XCTAssertEqual(frame.activity, .movement)
        XCTAssertGreaterThan(frame.coordinate.longitude, 127.0001)
        XCTAssertLessThan(frame.coordinate.latitude, 37.0001)

        let lineCoordinate = try XCTUnwrap(
            MapHomeExpectedRoutePlaybackMath.coordinate(
                at: date(25),
                departureDate: date(10),
                arrivalDate: date(100),
                coordinates: routeCoordinates.map {
                    CLLocationCoordinate2D(
                        latitude: $0.latitude,
                        longitude: $0.longitude
                    )
                }
            )
        )
        XCTAssertEqual(
            frame.coordinate.latitude,
            lineCoordinate.latitude,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            frame.coordinate.longitude,
            lineCoordinate.longitude,
            accuracy: 0.000_001
        )
    }

    func testThursdayWBSPlaybackMovesMonotonicallyWithoutViewRotation() throws {
        let thursday = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 27))
        )
        let dayStart = calendar.startOfDay(for: thursday)
        let start = GeoPoint(
            latitude: 37,
            longitude: 127,
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5
        )
        let end = GeoPoint(
            latitude: 37,
            longitude: 127.01,
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5
        )
        let from = PlaceStay(
            placeKey: "thu-from",
            displayName: "출발",
            span: TimeSpan(
                start: dayStart,
                end: dayStart.addingTimeInterval(10 * 60)
            ),
            confidence: .high,
            point: start
        )
        let to = PlaceStay(
            placeKey: "thu-to",
            displayName: "도착",
            span: TimeSpan(
                start: dayStart.addingTimeInterval(70 * 60),
                end: dayStart.addingTimeInterval(100 * 60)
            ),
            confidence: .high,
            point: end
        )
        let travel = TravelSegment(
            fromPlaceID: from.id,
            toPlaceID: to.id,
            mode: .walking,
            span: TimeSpan(
                start: dayStart.addingTimeInterval(10 * 60),
                end: dayStart.addingTimeInterval(70 * 60)
            ),
            distanceMeters: 900,
            confidence: .high,
            evidence: ["걷기"]
        )
        let travelLegID = "movement-\(travel.id.uuidString)"
        let projection = MapHomeWBSPlaybackProjection.make(
            selectedDate: thursday,
            places: [from, to],
            travel: [travel],
            readings: [],
            calendar: calendar
        )
        let first = try XCTUnwrap(
            projection.frame(
                at: dayStart.addingTimeInterval(10 * 60),
                preferredForecastLegIDs: [travelLegID]
            )
        )
        let middle = try XCTUnwrap(
            projection.frame(
                at: dayStart.addingTimeInterval(40 * 60),
                preferredForecastLegIDs: [travelLegID]
            )
        )
        let last = try XCTUnwrap(
            projection.frame(
                at: dayStart.addingTimeInterval(70 * 60 - 0.001),
                preferredForecastLegIDs: [travelLegID]
            )
        )

        XCTAssertLessThan(first.coordinate.longitude, middle.coordinate.longitude)
        XCTAssertLessThan(middle.coordinate.longitude, last.coordinate.longitude)
        XCTAssertEqual(first.direction, .east)
        XCTAssertEqual(middle.direction, .east)
        XCTAssertEqual(last.direction, .east)
    }

    func testMapHomeWBSTripStyleMatchesWBSRouteTokens() {
        XCTAssertEqual(MapHomeWBSTripStyle.paperHex, "#FCF9F4")
        XCTAssertEqual(MapHomeWBSTripStyle.actualRouteHex, "#458B88")
        XCTAssertEqual(MapHomeWBSTripStyle.forecastRouteHex, "#C65D4D")
        XCTAssertEqual(MapHomeWBSTripStyle.actualRouteLineWidth, 2.2)
        XCTAssertEqual(MapHomeWBSTripStyle.forecastRouteLineWidth, 1.8)
    }
}
