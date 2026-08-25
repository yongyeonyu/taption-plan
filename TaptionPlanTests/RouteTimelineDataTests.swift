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

    func testExpectedRoadRouteUsesSavedPlaceEndpointsWithoutMutatingTravel() throws {
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

        let request = try XCTUnwrap(
            ExpectedRouteRequestEngine.requests(
                travel: [travel],
                places: [from, to],
                readings: [],
                in: TimeSpan(start: date(0), end: date(1_440)),
                through: date(1_440)
            ).first
        )

        XCTAssertEqual(request.transport, .automobile)
        XCTAssertEqual(request.start, from.point)
        XCTAssertEqual(request.end, to.point)
        XCTAssertEqual(travel, original)
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
}
