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

    func testMapRouteReadingsPreparationPreservesSourceCountsAndDayFilter() throws {
        let inDay = reading(10, latitude: 37)
        var outsideDay = reading(1_450, latitude: 37.1)
        outsideDay.sourceDevice = .appleWatch

        let prepared = try MapHomeRouteReadingsPreparation.prepare(
            routeReadings: [inDay],
            liveReadings: [outsideDay],
            latestReading: nil,
            dayStart: date(0),
            dayEnd: date(1_440),
            cancellationCheck: {}
        )

        XCTAssertEqual(prepared.sourceCount, 2)
        XCTAssertEqual(prepared.watchSourceCount, 1)
        XCTAssertEqual(prepared.filteredCount, prepared.normalized.count)
    }

    func testRouteReadingsPreparationSignatureChangesWhenLatestCoordinateChanges() {
        let id = UUID()
        let first = reading(10, latitude: 37, id: id)
        let moved = reading(10, latitude: 37.1, id: id)

        XCTAssertEqual(first.id, moved.id)
        XCTAssertEqual(first.timestamp, moved.timestamp)
        XCTAssertNotEqual(
            MapHomeRouteReadingsPreparation.latestRouteInputSignature(first),
            MapHomeRouteReadingsPreparation.latestRouteInputSignature(moved)
        )
    }

    func testRouteReadingsPreparationSignatureTracksSessionEnd() {
        let id = UUID()
        var active = reading(10, latitude: 37, id: id)
        var ended = active
        ended.trackingSessionEnded = true

        XCTAssertNotEqual(
            MapHomeRouteReadingsPreparation.latestRouteInputSignature(active),
            MapHomeRouteReadingsPreparation.latestRouteInputSignature(ended)
        )
        active.trackingSessionEnded = false
        XCTAssertEqual(
            MapHomeRouteReadingsPreparation.latestRouteInputSignature(active),
            MapHomeRouteReadingsPreparation.latestRouteInputSignature(
                reading(10, latitude: 37, id: id)
            )
        )
    }

    func testRouteReadingsPreparationSignatureTracksApproximateAccuracyBoundary()
        throws {
        let id = UUID()
        let timestamp = date(10)
        let accepted = SensorReading(
            id: id,
            timestamp: timestamp,
            point: GeoPoint(
                latitude: 37,
                longitude: 127,
                altitude: 0,
                horizontalAccuracy: 999,
                verticalAccuracy: 5
            ),
            locationFixQuality: .approximate,
            gpsAvailable: false
        )
        let rejected = SensorReading(
            id: id,
            timestamp: timestamp,
            point: GeoPoint(
                latitude: 37,
                longitude: 127,
                altitude: 0,
                horizontalAccuracy: 1_001,
                verticalAccuracy: 5
            ),
            locationFixQuality: .approximate,
            gpsAvailable: false
        )
        XCTAssertNotEqual(
            MapHomeRouteReadingsPreparation.latestRouteInputSignature(accepted),
            MapHomeRouteReadingsPreparation.latestRouteInputSignature(rejected)
        )
        var precise = accepted
        precise.gpsAvailable = true
        precise.locationFixQuality = .precise
        XCTAssertNotEqual(
            MapHomeRouteReadingsPreparation.latestRouteInputSignature(accepted),
            MapHomeRouteReadingsPreparation.latestRouteInputSignature(precise)
        )

        let acceptedPreparation = try MapHomeRouteReadingsPreparation.prepare(
            routeReadings: [],
            liveReadings: [],
            latestReading: accepted,
            dayStart: date(0),
            dayEnd: date(1_440),
            cancellationCheck: {}
        )
        let rejectedPreparation = try MapHomeRouteReadingsPreparation.prepare(
            routeReadings: [],
            liveReadings: [],
            latestReading: rejected,
            dayStart: date(0),
            dayEnd: date(1_440),
            cancellationCheck: {}
        )
        XCTAssertEqual(acceptedPreparation.normalized.map(\.id), [id])
        XCTAssertTrue(rejectedPreparation.normalized.isEmpty)
    }

    func testMapRouteReadingsPreparationPropagatesCancellation() {
        let readings = (0..<1_024).map {
            reading($0, latitude: 37 + Double($0) * 0.00001)
        }
        var checks = 0

        XCTAssertThrowsError(
            try MapHomeRouteReadingsPreparation.prepare(
                routeReadings: readings,
                liveReadings: [],
                latestReading: nil,
                dayStart: date(0),
                dayEnd: date(1_440),
                cancellationCheck: {
                    checks += 1
                    if checks == 5 { throw CancellationError() }
                }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(checks, 5)
    }

    func testRouteTimelineCancellableSortChecksCancellationDuringMerge() {
        var checks = 0

        XCTAssertThrowsError(
            try RouteTimelineCancellableSort.sorted(
                Array((0..<4_096).reversed()),
                by: { $0 < $1 },
                cancellationCheck: {
                    checks += 1
                    if checks == 4 { throw CancellationError() }
                }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(checks, 4)
    }

    func testRouteTimelineCancellableSortKeepsStableOrder() {
        let values = [
            (key: 2, order: 0),
            (key: 1, order: 1),
            (key: 2, order: 2),
            (key: 1, order: 3),
        ]
        let sorted = RouteTimelineCancellableSort.sorted(
            values,
            by: { $0.key < $1.key },
            cancellationCheck: {}
        )

        XCTAssertEqual(sorted.map { $0.order }, [1, 3, 0, 2])
    }

    func testDateResetRejectsPreparedReadingsFromPreviousGeneration() async throws {
        var generation = MapHomeRouteReadingsPreparationGeneration()
        let previousGeneration = generation.advance()
        let activeGeneration = generation.advance()
        let latest = reading(10, latitude: 37)
        let dayStart = date(0)
        let dayEnd = date(1_440)
        let worker = Task.detached(priority: .utility) {
            try await Task.sleep(nanoseconds: 20_000_000)
            return try MapHomeRouteReadingsPreparation.prepare(
                routeReadings: [latest],
                liveReadings: [],
                latestReading: nil,
                dayStart: dayStart,
                dayEnd: dayEnd,
                cancellationCheck: { try Task.checkCancellation() }
            )
        }

        let prepared = try await worker.value

        XCTAssertEqual(prepared.normalized.map(\.id), [latest.id])
        XCTAssertFalse(generation.accepts(previousGeneration))
        XCTAssertTrue(generation.accepts(activeGeneration))
    }

    func testRouteNormalizationRejectsNonFiniteTimestampsBeforeGrouping() {
        let valid = reading(5, latitude: 37)
        let invalid = SensorReading(
            timestamp: Date(timeIntervalSince1970: .nan),
            point: valid.point
        )

        let normalized = RouteTimelineDataEngine.normalizedDisplayReadings([
            invalid,
            valid,
        ])

        XCTAssertEqual(normalized.map(\.id), [valid.id])
    }

    func testRoutePlaybackInterpolationUsesShortestLongitudeAcrossDateline() throws {
        let start = date(0)
        let first = SensorReading(
            timestamp: start,
            point: GeoPoint(
                latitude: 10,
                longitude: 179.9,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            )
        )
        let last = SensorReading(
            timestamp: start.addingTimeInterval(10 * 60),
            point: GeoPoint(
                latitude: 10,
                longitude: -179.9,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            )
        )
        let readings = RouteTimelineDataEngine.normalizedReadings([first, last])

        let marker = try XCTUnwrap(
            RouteTimelineDataEngine.playbackCoordinate(
                at: start.addingTimeInterval(5 * 60),
                inNormalizedReadings: readings
            )
        )
        let segment = RouteTimelineSegment(
            id: "dateline",
            start: start,
            end: last.timestamp,
            category: .movement,
            colorHex: RouteTimelineCategory.movement.colorHex,
            opacity: 1,
            coordinates: [first.point!, last.point!],
            speedMetersPerSecond: nil,
            confirmedSubwayTravelID: nil
        )
        let routeMarker = try XCTUnwrap(
            MapHomeRouteTimelinePlaybackMath.coordinate(
                at: start.addingTimeInterval(5 * 60),
                in: [segment]
            )
        )

        XCTAssertLessThan(abs(abs(marker.longitude) - 180), 0.001)
        XCTAssertLessThan(abs(abs(routeMarker.longitude) - 180), 0.001)
    }

    func testDisplayReadingsKeepsSharpDeviationUnderMaximumCount() {
        let deviationIndex = 1_234
        let start = date(0)
        let readings = (0..<10_000).map { index in
            SensorReading(
                timestamp: start.addingTimeInterval(TimeInterval(index)),
                point: GeoPoint(
                    latitude: index == deviationIndex ? 0.02 : 0,
                    longitude: 127 + Double(index) * 0.00001,
                    altitude: 0,
                    horizontalAccuracy: 5,
                    verticalAccuracy: 5
                )
            )
        }

        let displayed = RouteTimelineDataEngine.displayReadings(
            from: readings,
            maximumCount: 8
        )

        XCTAssertLessThanOrEqual(displayed.count, 8)
        XCTAssertTrue(displayed.contains { $0.id == readings[deviationIndex].id })
    }

    func testDisplayReadingsPropagatesCancellationDuringRDP() {
        let start = date(0)
        let readings = (0..<10_000).map { index in
            SensorReading(
                timestamp: start.addingTimeInterval(TimeInterval(index)),
                point: GeoPoint(
                    latitude: Double(index % 2) * 0.0001,
                    longitude: 127 + Double(index) * 0.00001,
                    altitude: 0,
                    horizontalAccuracy: 5,
                    verticalAccuracy: 5
                )
            )
        }
        var checks = 0

        XCTAssertThrowsError(
            try RouteTimelineDataEngine.displayReadings(
                from: readings,
                maximumCount: 8,
                cancellationCheck: {
                    checks += 1
                    if checks == 123 { throw CancellationError() }
                }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(checks, 123)
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

    func testProjectScopesCategoryIndexToSelectedDay() {
        let previousDay = (0..<1_000).map { offset in
            let start = -1_440 + offset
            return ActualRecord(
                planID: nil,
                title: "이전 기록",
                categoryID: "sleep",
                startedAt: date(start),
                endedAt: date(start + 1),
                source: .motion
            )
        }
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

        let projection = RouteTimelineDataEngine.project(
            selectedDate: date(0),
            throughMinute: 20,
            actuals: previousDay + [work, activity],
            readings: [
                reading(0, latitude: 37),
                reading(10, latitude: 38),
                reading(20, latitude: 39),
            ],
            calendar: calendar
        )

        XCTAssertEqual(projection.segments.map(\.category), [.activity, .work])
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

    func testExactSampleAndLongGPSGapHoldsLastObservedPoint() throws {
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
            37,
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

    func testConfirmedSubwayIntervalIndexPreservesPrecedenceWithBoundedLookups() {
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
                    stationName: "도착",
                    latitude: 37.01,
                    longitude: 127
                ),
            ],
            lineNames: ["공항철도"],
            transferStationNames: []
        )
        var travel = (0..<512).map { index in
            TravelSegment(
                mode: .subway,
                span: TimeSpan(start: date(index), end: date(index + 600)),
                distanceMeters: 1_000,
                confidence: .high,
                evidence: [],
                isConfirmed: true,
                subwayRoute: route
            )
        }
        let firstTie = TravelSegment(
            mode: .subway,
            span: TimeSpan(start: date(1_000), end: date(1_800)),
            distanceMeters: 1_000,
            confidence: .high,
            evidence: [],
            isConfirmed: true,
            subwayRoute: route
        )
        let secondTie = TravelSegment(
            mode: .subway,
            span: firstTie.span,
            distanceMeters: 1_000,
            confidence: .high,
            evidence: [],
            isConfirmed: true,
            subwayRoute: route
        )
        travel.append(contentsOf: [firstTie, secondTie])
        let index = RouteConfirmedSubwayIntervalIndex(travel: travel)

        for minute in [0, 200, 500, 700, 1_000, 1_200, 1_500, 1_800, 2_000] {
            let instant = date(minute)
            let expected = travel
                .filter { RouteConfirmedSubwayIntervalIndex.isConfirmedSubway($0) }
                .filter { $0.span.contains(instant) }
                .max { $0.span.start < $1.span.start }
            XCTAssertEqual(
                index.segment(at: instant)?.id,
                expected?.id,
                "minute \(minute)"
            )
        }
        XCTAssertEqual(index.segment(at: date(1_200))?.id, firstTie.id)

        var operationCount = 0
        for minute in 0..<1_800 {
            _ = index.segment(
                at: date(minute),
                operationCount: &operationCount
            )
        }
        XCTAssertLessThan(operationCount, 1_800 * 30)
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

    func testRouteTimelineDoesNotPromoteApproximateQualityToPreciseGPS() {
        let approximate = SensorReading(
            timestamp: date(0),
            point: GeoPoint(
                latitude: 37,
                longitude: 127,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            ),
            locationFixQuality: .approximate,
            gpsAvailable: true
        )
        let precise = SensorReading(
            timestamp: date(0),
            point: GeoPoint(
                latitude: 38,
                longitude: 128,
                altitude: 0,
                horizontalAccuracy: 20,
                verticalAccuracy: 5
            ),
            locationFixQuality: .precise,
            gpsAvailable: true
        )

        XCTAssertTrue(
            RouteTimelineDataEngine.normalizedReadings([approximate]).isEmpty
        )
        XCTAssertEqual(
            RouteTimelineDataEngine.normalizedDisplayReadings([approximate]).count,
            1
        )
        XCTAssertEqual(
            RouteTimelineDataEngine.normalizedDisplayReadings([
                approximate,
                precise,
            ]).first?.id,
            precise.id
        )
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

    func testMPR0921C01PlaybackActualIndexP95StaysWithinRefreshBudget() {
        let start = date(0)
        let actuals = (0..<10_000).map { index in
            let minute = index % 1_440
            let offset = Double(index / 1_440) / 100
            let startedAt = start.addingTimeInterval(
                Double(minute * 60) + offset
            )
            return ActualRecord(
                planID: nil,
                title: "자동 기록",
                categoryID: index.isMultiple(of: 2) ? "work" : "activity",
                startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(15 * 60),
                source: .motion,
                confidence: .high
            )
        }
        let actualIndex = RouteTimelineDataEngine.actualIndex(
            selectedDate: start,
            actuals: actuals,
            calendar: calendar
        )
        var durations: [Double] = []
        durations.reserveCapacity(40)
        var resolved = 0

        for iteration in 0..<41 {
            let cutoff = start.addingTimeInterval(
                Double((720 + iteration) * 60)
            )
            let startedAt = ProcessInfo.processInfo.systemUptime
            let projection = RouteTimelineDataEngine.project(
                selectedDate: start,
                through: cutoff,
                actuals: actuals,
                actualIndex: actualIndex,
                readings: [],
                readingsAreNormalized: true,
                calendar: calendar
            )
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            if iteration > 0 { durations.append(elapsed) }
            if projection.selectedCategory != nil { resolved += 1 }
        }

        let sorted = durations.sorted()
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        print(
            "MPR0921C01 actual-index p95 ms: "
                + String(format: "%.3f", p95 * 1_000)
        )
        XCTAssertEqual(resolved, 41)
        XCTAssertLessThan(
            p95,
            MapHomeDayPlaybackMath.routeProjectionInterval
        )

        let options = XCTMeasureOptions()
        options.iterationCount = 5
        var measuredResolved = 0
        measure(metrics: [XCTCPUMetric()], options: options) {
            measuredResolved = 0
            for iteration in 0..<4 {
                let projection = RouteTimelineDataEngine.project(
                    selectedDate: start,
                    through: start.addingTimeInterval(
                        Double((780 + iteration) * 60)
                    ),
                    actuals: actuals,
                    actualIndex: actualIndex,
                    readings: [],
                    readingsAreNormalized: true,
                    calendar: calendar
                )
                if projection.selectedCategory != nil {
                    measuredResolved += 1
                }
            }
        }
        XCTAssertEqual(measuredResolved, 4)
    }

    func testMPR0921C01CachedActualIndexMatchesDirectProjection() {
        let start = date(0)
        let actuals = [
            ActualRecord(
                planID: nil,
                title: "활동",
                categoryID: "activity",
                startedAt: date(-10),
                endedAt: date(15),
                source: .motion
            ),
            ActualRecord(
                planID: nil,
                title: "업무",
                categoryID: "work",
                startedAt: date(15),
                endedAt: date(45),
                source: .location
            ),
            ActualRecord(
                planID: nil,
                title: "운동",
                categoryID: "exercise",
                startedAt: date(45),
                endedAt: nil,
                source: .healthKit
            ),
        ]
        let readings = [
            reading(0, latitude: 37),
            reading(20, latitude: 37.01),
            reading(50, latitude: 37.02),
        ]
        let actualIndex = RouteTimelineDataEngine.actualIndex(
            selectedDate: start,
            actuals: actuals,
            calendar: calendar
        )

        for minute in [0, 10, 15, 30, 45, 60, 1_440] {
            let direct = RouteTimelineDataEngine.project(
                selectedDate: start,
                throughMinute: minute,
                actuals: actuals,
                readings: readings,
                calendar: calendar
            )
            let cached = RouteTimelineDataEngine.project(
                selectedDate: start,
                throughMinute: minute,
                actuals: actuals,
                actualIndex: actualIndex,
                readings: readings,
                calendar: calendar
            )
            XCTAssertEqual(cached, direct, "minute \(minute)")
        }
    }

    func testFilteredRouteReadingsRemoveDriftAndImpossibleJumpWithoutMutatingRawReadings() {
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

        let filtered = TaptionRouteEngineAdapter.filteredReadings(from: readings)

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

    func testNormalizedReadingsPreserveSessionEndAcrossEqualTimestampOrders() {
        let timestamp = date(10)
        let open = reading(
            10,
            latitude: 37,
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        var ended = reading(
            10,
            latitude: 37.1,
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )
        ended.trackingSessionEnded = true
        XCTAssertEqual(open.timestamp, timestamp)
        XCTAssertEqual(ended.timestamp, timestamp)

        let firstOrder = RouteTimelineDataEngine.normalizedDisplayReadings(
            [open, ended],
            cancellationCheck: {}
        )
        let reversedOrder = RouteTimelineDataEngine.normalizedDisplayReadings(
            [ended, open],
            cancellationCheck: {}
        )

        XCTAssertEqual(firstOrder.count, 1)
        XCTAssertEqual(reversedOrder.count, 1)
        XCTAssertTrue(firstOrder[0].trackingSessionEnded == true)
        XCTAssertTrue(reversedOrder[0].trackingSessionEnded == true)
        XCTAssertEqual(firstOrder[0].id, reversedOrder[0].id)
        XCTAssertEqual(firstOrder[0].point, reversedOrder[0].point)
    }

    func testEqualTimestampSessionEndPreventsProjectionSegmentAcrossNextGPS() {
        var ended = reading(10, latitude: 37)
        ended.trackingSessionEnded = true
        let next = reading(20, latitude: 37.1)

        for readings in [[ended, next], [next, ended]] {
            let projection = RouteTimelineDataEngine.project(
                selectedDate: date(0),
                through: date(30),
                actuals: [],
                readings: readings,
                calendar: calendar
            )

            XCTAssertTrue(
                projection.segments.isEmpty,
                "ended route reading must prevent interpolation to the next GPS"
            )
        }
    }

    func testFilteredRouteReadingsBoundAccuracyAndAreDeterministic() {
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

        let first = TaptionRouteEngineAdapter.filteredReadings(from: readings)
        let second = TaptionRouteEngineAdapter.filteredReadings(from: readings)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map(\.id.uuidString), [
            "00000000-0000-0000-0000-000000000011",
            "00000000-0000-0000-0000-000000000012",
        ])
        XCTAssertTrue(first.allSatisfy { $0.point?.horizontalAccuracy ?? .infinity <= 1_000 })
    }

    func testFilteredRouteReadingsStartNewSegmentAfterLongGap() {
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
            TaptionRouteEngineAdapter.filteredReadings(from: readings).map(\.id),
            readings.map(\.id)
        )
    }

    func testFilteredRouteReadingsKeepOnlyLowConfidenceRunBoundaries() {
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

        let filtered = TaptionRouteEngineAdapter.filteredReadings(from: readings)

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
        let projection = MapHomeWBSPlaybackProjection.make(
            selectedDate: date(0),
            places: [from, to],
            travel: [travel],
            readings: [],
            calendar: calendar
        )
        XCTAssertTrue(
            projection.legs.filter {
                $0.routePhase == .forecast && $0.activity == .movement
            }.isEmpty
        )
        XCTAssertEqual(travel, original)
    }

    func testConfirmedSubwayRouteDoesNotCreateDottedOverlay() {
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
            mode: .subway,
            span: TimeSpan(start: date(10), end: date(60)),
            distanceMeters: 10_000,
            confidence: .high,
            evidence: ["지하철"],
            isConfirmed: true,
            subwayRoute: SubwayRoutePath(
                stops: [
                    SubwayRouteStop(
                        lineName: "1호선",
                        order: 0,
                        stationName: "A",
                        latitude: 37.50,
                        longitude: 126.90
                    ),
                    SubwayRouteStop(
                        lineName: "1호선",
                        order: 1,
                        stationName: "B",
                        latitude: 37.60,
                        longitude: 127.00
                    ),
                ],
                lineNames: ["1호선"],
                transferStationNames: []
            )
        )

        let projection = MapHomeWBSPlaybackProjection.make(
            selectedDate: date(0),
            places: [from, to],
            travel: [travel],
            readings: [],
            resolvedRoutes: [
                MapHomeWBSResolvedRoute(
                    legID: "movement-\(travel.id.uuidString)",
                    coordinates: travel.subwayRoute!.coordinates
                )
            ],
            calendar: calendar
        )

        XCTAssertTrue(
            projection.legs.filter {
                $0.routePhase == .forecast && $0.activity == .movement
            }.isEmpty
        )
    }

    func testExpectedSubwayRouteRequiresBoundedGPSGap() {
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
        let requests = ExpectedRouteRequestEngine.requests(
            travel: travel,
            places: [from, to],
            readings: [],
            in: TimeSpan(start: date(0), end: date(1_440)),
            through: date(1_440),
            frequentPlaces: [home, company]
        )

        XCTAssertTrue(requests.isEmpty)
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

    func testExpectedRouteDoesNotUseRegisteredEndpointsWithoutGPS() {
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

        XCTAssertTrue(
            ExpectedRouteRequestEngine.requests(
                travel: [travel],
                places: [from, to],
                readings: [],
                in: TimeSpan(start: date(0), end: date(1_440)),
                through: date(1_440),
                frequentPlaces: [home, company]
            ).isEmpty
        )
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

    func testExpectedRouteSkipsNormalGPSContinuity() {
        let segment = TravelSegment(
            mode: .car,
            span: TimeSpan(start: date(10), end: date(40)),
            distanceMeters: 3_000,
            confidence: .medium,
            evidence: ["자동차"]
        )
        let readings = [10, 15, 20, 25, 30, 35, 40].map {
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

    func testExpectedRouteUsesLateGPSToBoundOnlyTheMissingGap() throws {
        let segment = TravelSegment(
            mode: .car,
            span: TimeSpan(start: date(10), end: date(100)),
            distanceMeters: 9_000,
            confidence: .medium,
            evidence: ["자동차"]
        )
        let startOfGap = reading(40, latitude: 37.04)
        let endOfGap = reading(100, latitude: 37.10)
        let continuous = (10..<40).map {
            reading($0, latitude: 37 + Double($0) / 1_000)
        }
        let request = try XCTUnwrap(
            ExpectedRouteRequestEngine.requests(
                travel: [segment],
                places: [],
                readings: continuous + [startOfGap, endOfGap],
                in: TimeSpan(start: date(0), end: date(1_440)),
                through: date(1_440)
            ).first
        )

        XCTAssertEqual(request.departureDate, date(40))
        XCTAssertEqual(request.arrivalDate, date(100))
        XCTAssertEqual(request.start, startOfGap.point)
        XCTAssertEqual(request.end, endOfGap.point)
        let filled = (40...100).map {
            reading($0, latitude: 37 + Double($0) / 1_000)
        }
        XCTAssertTrue(ExpectedRouteRequestEngine.requests(
            travel: [segment], places: [], readings: continuous + filled,
            in: TimeSpan(start: date(0), end: date(1_440)),
            through: date(1_440)
        ).isEmpty)
    }

    func testExpectedRouteSkipsStationaryGPSGap() {
        let segment = TravelSegment(
            mode: .car,
            span: TimeSpan(start: date(10), end: date(100)),
            distanceMeters: 1_000,
            confidence: .medium,
            evidence: ["자동차"]
        )
        let stationary = [
            reading(10, latitude: 37),
            reading(100, latitude: 37),
        ]

        XCTAssertTrue(
            ExpectedRouteRequestEngine.requests(
                travel: [segment],
                places: [],
                readings: stationary,
                in: TimeSpan(start: date(0), end: date(1_440)),
                through: date(1_440)
            ).isEmpty
        )
    }

    func testExpectedRouteRequestsEveryBoundedGPSGapWithStableDistinctIDs() {
        let segment = TravelSegment(
            mode: .car,
            span: TimeSpan(start: date(10), end: date(100)),
            distanceMeters: 30_000,
            confidence: .medium,
            evidence: ["자동차"]
        )
        let readings = [
            reading(10, latitude: 37.00),
            reading(40, latitude: 37.05),
            reading(70, latitude: 37.10),
            reading(100, latitude: 37.15),
        ]
        let requests = ExpectedRouteRequestEngine.requests(
            travel: [segment],
            places: [],
            readings: readings,
            in: TimeSpan(start: date(0), end: date(1_440)),
            through: date(1_440)
        ).sorted { $0.departureDate < $1.departureDate }
        let repeated = ExpectedRouteRequestEngine.requests(
            travel: [segment],
            places: [],
            readings: readings,
            in: TimeSpan(start: date(0), end: date(1_440)),
            through: date(1_440)
        ).sorted { $0.departureDate < $1.departureDate }

        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests.map(\.departureDate), [date(10), date(40), date(70)])
        XCTAssertEqual(requests.map(\.arrivalDate), [date(40), date(70), date(100)])
        XCTAssertEqual(requests.map(\.id), repeated.map(\.id))
        XCTAssertEqual(Set(requests.map(\.id)).count, requests.count)
        XCTAssertTrue(requests.allSatisfy { $0.id != segment.id })
    }

    func testExpectedRouteRequestWorkDoesNotRescanAllReadingsPerTravelSegment() {
        var travel: [TravelSegment] = []
        var readings: [SensorReading] = (0..<8_000).map { _ in
            SensorReading(timestamp: date(25))
        }
        for index in 0..<40 {
            let startMinute = index * 30
            let latitude = 37 + Double(index) * 0.01
            travel.append(TravelSegment(
                mode: .car,
                span: TimeSpan(
                    start: date(startMinute),
                    end: date(startMinute + 20)
                ),
                distanceMeters: 1_000,
                confidence: .medium,
                evidence: []
            ))
            readings.append(reading(startMinute, latitude: latitude))
            readings.append(reading(startMinute + 20, latitude: latitude + 0.005))
        }
        for index in 0..<400 {
            let startMinute = (index / 10) * 30 + 20
            let start = date(startMinute).addingTimeInterval(
                TimeInterval(1 + (index % 10) * 2)
            )
            travel.append(TravelSegment(
                mode: .train,
                span: TimeSpan(start: start, end: start.addingTimeInterval(1)),
                distanceMeters: 500,
                confidence: .high,
                evidence: [],
                isConfirmed: true
            ))
        }

        var operationCount = 0
        let requests = ExpectedRouteRequestEngine.requests(
            travel: travel,
            places: [],
            readings: readings,
            in: TimeSpan(start: date(0), end: date(1_440)),
            through: date(1_440),
            frequentPlaces: [],
            operationCount: &operationCount
        )

        XCTAssertEqual(requests.count, 40)
        XCTAssertLessThan(
            operationCount,
            readings.count * 3 + travel.count * 3
        )
    }

    func testExpectedRouteRequestCancellationStopsReadingSortBeforeIndexBuild() {
        let dayStart = date(0)
        let readings = (0..<8_192).reversed().map { index in
            SensorReading(
                timestamp: dayStart.addingTimeInterval(Double(index) / 10)
            )
        }
        var cancellationChecks = 0
        var operationCount = 0

        XCTAssertThrowsError(
            try ExpectedRouteRequestEngine.requests(
                travel: [],
                places: [],
                readings: readings,
                in: TimeSpan(start: dayStart, end: date(1_440)),
                through: date(1_440),
                frequentPlaces: [],
                operationCount: &operationCount,
                cancellationCheck: {
                    cancellationChecks += 1
                    if cancellationChecks == 110 { throw CancellationError() }
                }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertEqual(cancellationChecks, 110)
        XCTAssertEqual(operationCount, readings.count)
    }

    func testWBSProjectionUsesProvidedExpectedRouteRequests() throws {
        let segment = TravelSegment(
            mode: .car,
            span: TimeSpan(start: date(10), end: date(100)),
            distanceMeters: 10_000,
            confidence: .medium,
            evidence: []
        )
        let readings = [
            reading(10, latitude: 37),
            reading(100, latitude: 37.1),
        ]
        let generatedRequests = ExpectedRouteRequestEngine.requests(
            travel: [segment],
            places: [],
            readings: readings,
            in: TimeSpan(start: date(0), end: date(1_440)),
            through: date(1_440)
        )
        let generatedRequest = try XCTUnwrap(generatedRequests.first)
        let withoutRequests = MapHomeWBSPlaybackProjection.make(
            selectedDate: date(0),
            places: [],
            travel: [segment],
            readings: readings,
            expectedRouteRequests: [],
            calendar: calendar
        )
        let computedProjection = MapHomeWBSPlaybackProjection.make(
            selectedDate: date(0),
            places: [],
            travel: [segment],
            readings: readings,
            calendar: calendar
        )
        let withRequests = MapHomeWBSPlaybackProjection.make(
            selectedDate: date(0),
            places: [],
            travel: [segment],
            readings: readings,
            expectedRouteRequests: generatedRequests,
            calendar: calendar
        )

        XCTAssertFalse(withoutRequests.legs.contains {
            $0.routePhase == .forecast && $0.activity == .movement
        })
        XCTAssertTrue(withRequests.legs.contains {
            $0.id == "movement-\(generatedRequest.id.uuidString)"
        })
        XCTAssertEqual(withRequests, computedProjection)
    }

    func testExpectedRouteGapIDSurvivesPersistedDateRoundTrip() throws {
        let dates = [
            Date(timeIntervalSinceReferenceDate: 811012345.000002),
            Date(timeIntervalSinceReferenceDate: 811014145.000002),
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let restored = try decoder.decode([Date].self, from: encoder.encode(dates))
        XCTAssertNotEqual(dates[0], restored[0])
        let segmentID = UUID()
        let point = try XCTUnwrap(reading(10, latitude: 37).point)
        let original = ExpectedRouteRequest(
            segmentID: segmentID, mode: .car, transport: .automobile,
            start: point, end: point,
            departureDate: dates[0], arrivalDate: dates[1]
        )
        let decoded = ExpectedRouteRequest(
            segmentID: segmentID, mode: .car, transport: .automobile,
            start: point, end: point,
            departureDate: restored[0], arrivalDate: restored[1]
        )
        XCTAssertEqual(original.id, decoded.id)
    }

    func testExpectedRouteDoesNotUseLeadingOrTrailingPlaceFallback() {
        let from = PlaceStay(
            placeKey: "bounded-from",
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
        let to = PlaceStay(
            placeKey: "bounded-to",
            displayName: "도착",
            span: TimeSpan(start: date(100), end: date(120)),
            confidence: .high,
            point: GeoPoint(
                latitude: 37.2,
                longitude: 127.2,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            )
        )
        let segment = TravelSegment(
            fromPlaceID: from.id,
            toPlaceID: to.id,
            mode: .car,
            span: TimeSpan(start: date(10), end: date(100)),
            distanceMeters: 30_000,
            confidence: .medium,
            evidence: ["자동차"]
        )

        XCTAssertTrue(
            ExpectedRouteRequestEngine.requests(
                travel: [segment],
                places: [from, to],
                readings: [reading(40, latitude: 37.1)],
                in: TimeSpan(start: date(0), end: date(1_440)),
                through: date(1_440)
            ).isEmpty
        )
    }

    func testExpectedRouteDoesNotTreatEndedTrackingSessionAsGPSFailure() {
        let segment = TravelSegment(
            mode: .car,
            span: TimeSpan(start: date(10), end: date(100)),
            distanceMeters: 12_000,
            confidence: .medium,
            evidence: ["자동차"]
        )
        var endedSession = reading(10, latitude: 37)
        endedSession.trackingSessionEnded = true

        XCTAssertTrue(
            ExpectedRouteRequestEngine.requests(
                travel: [segment],
                places: [],
                readings: [endedSession, reading(100, latitude: 37.1)],
                in: TimeSpan(start: date(0), end: date(1_440)),
                through: date(1_440)
            ).isEmpty
        )
    }

    func testExpectedRouteRejectsStopMarkerWithoutGPS() {
        let segment = TravelSegment(
            mode: .car,
            span: TimeSpan(start: date(10), end: date(100)),
            distanceMeters: 12_000,
            confidence: .medium,
            evidence: []
        )
        var stopped = SensorReading(timestamp: date(40))
        stopped.trackingSessionEnded = true
        XCTAssertTrue(ExpectedRouteRequestEngine.requests(
            travel: [segment],
            places: [],
            readings: [reading(10, latitude: 37), stopped, reading(100, latitude: 37.1)],
            in: TimeSpan(start: date(0), end: date(1_440)),
            through: date(1_440)
        ).isEmpty)
    }

    func testExpectedRouteDoesNotOverlapConfirmedTravel() {
        let span = TimeSpan(start: date(10), end: date(100))
        let candidate = TravelSegment(
            mode: .car, span: span, distanceMeters: 12_000,
            confidence: .medium, evidence: []
        )
        let confirmed = TravelSegment(
            mode: .train, span: span, distanceMeters: 12_000,
            confidence: .high, evidence: [], isConfirmed: true
        )
        XCTAssertTrue(ExpectedRouteRequestEngine.requests(
            travel: [candidate, confirmed], places: [],
            readings: [reading(10, latitude: 37), reading(100, latitude: 37.1)],
            in: TimeSpan(start: date(0), end: date(1_440)),
            through: date(1_440)
        ).isEmpty)
    }

    func testExpectedRouteCoversSparseLongDistanceGPSGap() throws {
        let segment = TravelSegment(
            mode: .car,
            span: TimeSpan(start: date(10), end: date(30)),
            distanceMeters: 2_500,
            confidence: .medium,
            evidence: ["자동차"]
        )
        let startOfGap = reading(10, latitude: 37.00)
        let endOfGap = reading(20, latitude: 37.02)
        let request = try XCTUnwrap(
            ExpectedRouteRequestEngine.requests(
                travel: [segment],
                places: [],
                readings: [
                    startOfGap,
                    endOfGap,
                    reading(30, latitude: 37.021),
                ],
                in: TimeSpan(start: date(0), end: date(1_440)),
                through: date(1_440)
            ).first
        )

        XCTAssertEqual(request.departureDate, date(10))
        XCTAssertEqual(request.arrivalDate, date(20))
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

    func testWBSPlaybackDoesNotUseResolvedRoadDistanceWithoutGPSBoundedGap() {
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

        XCTAssertTrue(
            projection.legs.filter {
                $0.routePhase == .forecast && $0.activity == .movement
            }.isEmpty
        )
    }

    func testWBSPlaybackDoesNotForecastOverlappingTravelWithoutGPS() {
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

        XCTAssertTrue(
            projection.legs.filter {
                $0.routePhase == .forecast && $0.activity == .movement
            }.isEmpty
        )
    }

    func testWBSPlaybackDoesNotForecastSubwayGapWithoutReliableGPS() throws {
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

        XCTAssertTrue(
            projection.legs.filter {
                $0.routePhase == .forecast && $0.activity == .movement
            }.isEmpty
        )
        let stay = try XCTUnwrap(projection.frame(at: date(10)))
        XCTAssertEqual(stay.activity, .stay)
        XCTAssertEqual(stay.cameraCoordinate, firstPoint)
        XCTAssertEqual(
            MapHomeWBSPlaybackProjection.distanceMeters(
                stay.coordinate,
                stay.cameraCoordinate
            ),
            0,
            accuracy: 0.5
        )
    }

    func testWBSPlaybackCreatesOnlyGPSBoundedSubwayForecastGap() throws {
        let first = PlaceStay(
            placeKey: "gps-subway-first",
            displayName: "출발",
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
            placeKey: "gps-subway-second",
            displayName: "도착",
            span: TimeSpan(start: date(80), end: date(120)),
            confidence: .high,
            point: GeoPoint(
                latitude: 37.2,
                longitude: 127.2,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            )
        )
        let travel = TravelSegment(
            fromPlaceID: first.id,
            toPlaceID: second.id,
            mode: .subway,
            span: TimeSpan(start: date(20), end: date(80)),
            distanceMeters: 30_000,
            confidence: .medium,
            evidence: ["지하철"],
            isConfirmed: false,
            isClassificationLocked: true
        )
        let startGPS = reading(20, latitude: 37.05)
        let endGPS = reading(80, latitude: 37.15)
        let projection = MapHomeWBSPlaybackProjection.make(
            selectedDate: date(0),
            places: [first, second],
            travel: [travel],
            readings: [startGPS, endGPS],
            calendar: calendar
        )

        let forecast = projection.legs.filter {
            $0.routePhase == .forecast && $0.activity == .movement
        }
        XCTAssertEqual(forecast.count, 1)
        let movement = try XCTUnwrap(forecast.first)
        XCTAssertEqual(movement.startDate, date(20))
        XCTAssertEqual(movement.endDate, date(80))
        XCTAssertEqual(movement.mode, .subway)
        XCTAssertEqual(movement.coordinates.first, startGPS.point)
        XCTAssertEqual(movement.coordinates.last, endGPS.point)
    }

    func testMPR905H001RecordedRouteRemovesGeneratedForecastGap() {
        let first = PlaceStay(
            placeKey: "first-recorded",
            displayName: "첫 장소",
            span: TimeSpan(start: date(0), end: date(20)),
            confidence: .high,
            point: reading(20, latitude: 37).point
        )
        let second = PlaceStay(
            placeKey: "second-recorded",
            displayName: "둘째 장소",
            span: TimeSpan(start: date(80), end: date(120)),
            confidence: .high,
            point: reading(80, latitude: 37.01).point
        )
        let readings = stride(from: 20, through: 80, by: 10).map {
            reading($0, latitude: 37 + Double($0 - 20) / 6_000)
        }

        let projection = MapHomeWBSPlaybackProjection.make(
            selectedDate: date(0),
            places: [first, second],
            travel: [],
            readings: readings,
            calendar: calendar
        )

        XCTAssertFalse(projection.legs.contains {
            $0.id.hasPrefix("movement-gap-")
        })
        XCTAssertTrue(projection.legs.contains {
            $0.routePhase == .actual && $0.activity == .movement
        })
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
            reading(50, latitude: 37.038),
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
        XCTAssertEqual(afterSleep.coordinate.latitude, 37.034, accuracy: 0.0001)
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

    func testWBSPlaybackDoesNotForecastExplicitMovementWithoutGPS() {
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

        XCTAssertTrue(
            projection.legs.filter {
                $0.routePhase == .forecast && $0.activity == .movement
            }.isEmpty
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

    func testWBSPlaybackBreaksSparseActualRouteGap() {
        let projection = MapHomeWBSPlaybackProjection.make(
            selectedDate: date(0),
            places: [],
            travel: [],
            readings: [
                reading(0, latitude: 37),
                SensorReading(
                    timestamp: date(6),
                    point: GeoPoint(
                        latitude: 37,
                        longitude: 127.03,
                        altitude: 0,
                        horizontalAccuracy: 5,
                        verticalAccuracy: 5
                    )
                ),
            ],
            calendar: calendar
        )

        XCTAssertTrue(
            projection.legs.filter {
                $0.routePhase == .actual && $0.activity == .movement
            }.isEmpty
        )
        XCTAssertNil(projection.frame(at: date(3)))
    }

    func testWBSPlaybackDoesNotTreatApproximateGPSAsActualTrace() {
        let readings = [
            SensorReading(
                timestamp: date(20),
                point: GeoPoint(
                    latitude: 37,
                    longitude: 127,
                    altitude: 0,
                    horizontalAccuracy: 5,
                    verticalAccuracy: 5
                ),
                locationFixQuality: .approximate,
                gpsAvailable: false
            ),
            SensorReading(
                timestamp: date(30),
                point: GeoPoint(
                    latitude: 37.001,
                    longitude: 127.001,
                    altitude: 0,
                    horizontalAccuracy: 5,
                    verticalAccuracy: 5
                ),
                locationFixQuality: .approximate,
                gpsAvailable: false
            ),
        ]

        let projection = MapHomeWBSPlaybackProjection.make(
            selectedDate: date(0),
            places: [],
            travel: [],
            readings: readings,
            calendar: calendar
        )

        XCTAssertTrue(
            projection.legs.filter {
                $0.routePhase == .actual && $0.activity == .movement
            }.isEmpty
        )
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

    func testWBSPlaybackDoesNotUseResolvedRouteWithoutGPSBoundedGap() {
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

        XCTAssertTrue(
            projection.legs.filter {
                $0.routePhase == .forecast && $0.activity == .movement
            }.isEmpty
        )
    }

    func testThursdayWBSPlaybackDoesNotForecastWithoutGPS() throws {
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
        let projection = MapHomeWBSPlaybackProjection.make(
            selectedDate: thursday,
            places: [from, to],
            travel: [travel],
            readings: [],
            calendar: calendar
        )
        XCTAssertTrue(
            projection.legs.filter {
                $0.routePhase == .forecast && $0.activity == .movement
            }.isEmpty
        )
    }

    func testMPR905H001DensePlaybackFrameLookup() {
        let start = date(0)
        let readings = (0...10_000).map { second in
            SensorReading(
                timestamp: start.addingTimeInterval(Double(second)),
                point: GeoPoint(
                    latitude: 37 + Double(second) * 0.000_002,
                    longitude: 127,
                    altitude: 0,
                    horizontalAccuracy: 5,
                    verticalAccuracy: 5
                )
            )
        }
        let projection = MapHomeWBSPlaybackProjection.make(
            selectedDate: start,
            places: [],
            travel: [],
            readings: readings,
            calendar: calendar
        )
        XCTAssertEqual(
            projection.legs.filter { $0.activity == .movement }.count,
            10_000
        )

        measure {
            var resolved = 0
            for second in stride(from: 0, to: 10_000, by: 5) {
                if projection.frame(
                    at: start.addingTimeInterval(Double(second) + 0.5)
                ) != nil {
                    resolved += 1
                }
            }
            XCTAssertEqual(resolved, 2_000)
        }
    }

    func testMPR905H001FrameIndexHonorsExactMinuteBoundary() throws {
        let start = date(0)
        let readings = (0...2).map { minute in
            SensorReading(
                timestamp: start.addingTimeInterval(Double(minute) * 60),
                point: GeoPoint(
                    latitude: 37 + Double(minute) * 0.001,
                    longitude: 127,
                    altitude: 0,
                    horizontalAccuracy: 5,
                    verticalAccuracy: 5
                )
            )
        }
        let projection = MapHomeWBSPlaybackProjection.make(
            selectedDate: start,
            places: [],
            travel: [],
            readings: readings,
            calendar: calendar
        )
        let legs = projection.legs.filter { $0.activity == .movement }
        XCTAssertEqual(legs.count, 2)

        XCTAssertEqual(
            try XCTUnwrap(projection.frame(at: start.addingTimeInterval(60))).legID,
            legs[1].id
        )
        XCTAssertNil(projection.frame(at: start.addingTimeInterval(120)))
    }

    func testMPR905H001FrameIndexHonorsDSTDayLength() throws {
        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.timeZone = try XCTUnwrap(
            TimeZone(identifier: "America/Los_Angeles")
        )
        for components in [
            DateComponents(year: 2026, month: 3, day: 8),
            DateComponents(year: 2026, month: 11, day: 1),
        ] {
            let dayStart = try XCTUnwrap(localCalendar.date(from: components))
            let dayEnd = try XCTUnwrap(
                localCalendar.date(byAdding: .day, value: 1, to: dayStart)
            )
            let stay = PlaceStay(
                placeKey: "dst",
                displayName: "DST",
                span: TimeSpan(start: dayStart, end: dayEnd),
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
                selectedDate: dayStart,
                places: [stay],
                travel: [],
                readings: [],
                calendar: localCalendar
            )

            XCTAssertNotNil(
                projection.frame(at: dayEnd.addingTimeInterval(-0.001))
            )
            XCTAssertNil(projection.frame(at: dayEnd))
        }
    }

    func testMapHomeWBSTripStyleMatchesWBSRouteTokens() {
        XCTAssertEqual(MapHomeWBSTripStyle.paperHex, "#FCF9F4")
        XCTAssertEqual(MapHomeWBSTripStyle.actualRouteHex, "#458B88")
        XCTAssertEqual(MapHomeWBSTripStyle.transitRouteHex, "#9A6A2D")
        XCTAssertEqual(MapHomeWBSTripStyle.forecastRouteHex, "#C65D4D")
        XCTAssertEqual(MapHomeWBSTripStyle.actualRouteLineWidth, 2.2)
        XCTAssertEqual(MapHomeWBSTripStyle.forecastRouteLineWidth, 1.8)
    }
}
