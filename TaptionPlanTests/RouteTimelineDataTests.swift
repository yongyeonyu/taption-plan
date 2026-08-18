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

    func testLargeGPSGapHoldsLastConfirmedCoordinate() throws {
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
    }
}
