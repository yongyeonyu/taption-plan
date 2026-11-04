import XCTest
@testable import TaptionPlan

/// 3개 원 판정(대표 요청, ALG1102A01). 반경이 작은 장소가 시험의 중심이다.
final class PlaceZoneStayTrackerTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let center = GeoPoint(latitude: 37.5, longitude: 127, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5)

    private func sample(_ minutes: Double, meters: Double, accuracy: Double = 10) -> SensorReading {
        var value = SensorReading(
            timestamp: start.addingTimeInterval(minutes * 60),
            point: GeoPoint(latitude: 37.5 + meters / 111_320, longitude: 127, altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 5),
            motion: .unknown
        )
        value.gpsAvailable = true
        return value
    }

    private func stays(_ readings: [SensorReading], radius: Double = 30) -> [PlaceZoneStayTracker.Stay] {
        PlaceZoneStayTracker.stays(readings: readings, center: center, radius: radius)
    }

    /// 판정은 지도에 그리는 세 원과 같은 값을 쓴다.
    func testRadiiMatchTheCirclesDrawnOnTheMap() {
        XCTAssertEqual(PlaceZoneStayTracker.band, MapHomePlaceZone.band)
        XCTAssertEqual(PlaceZoneStayTracker.innerRadius(100), 100 * (1 - MapHomePlaceZone.band), accuracy: 0.001)
        XCTAssertEqual(PlaceZoneStayTracker.outerRadius(100), 100 * (1 + MapHomePlaceZone.band), accuracy: 0.001)
    }

    /// 30m 식당: 빨간 원 경계를 오가도 바깥 원을 넘지 않으면 쪼개지지 않는다.
    func testBoundaryFlutterDoesNotSplitSmallRadiusStay() throws {
        var readings = [sample(0, meters: 60), sample(1, meters: 20)]
        for minute in 2...30 { readings.append(sample(Double(minute), meters: minute.isMultiple(of: 2) ? 33 : 28)) }
        readings += [sample(31, meters: 20), sample(32, meters: 80)]
        let found = stays(readings)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.span.start, start.addingTimeInterval(60))
        XCTAssertEqual(found.first?.span.end, start.addingTimeInterval(32 * 60))
        XCTAssertEqual(found.first?.exitBasis, .outerCircle)
    }

    /// 지나가기만 하면 안쪽 원에 닿아도 잠깐이고, 안쪽 원에 안 닿고 스치면 체류가 없다.
    func testPassingByIsNotAStay() {
        let grazing = [sample(0, meters: 80), sample(1, meters: 28), sample(2, meters: 80)]
        XCTAssertTrue(stays(grazing).isEmpty)
        let through = [sample(0, meters: 80), sample(1, meters: 10), sample(2, meters: 80)]
        let found = stays(through)
        XCTAssertEqual(found.count, 1)
        XCTAssertLessThan(found[0].span.duration, RestaurantMealActualEngine.minimumDuration)
    }

    /// 안쪽 원에 닿지 않아도 빨간 원 안에 계속 있으면 이 영역에 있는 것이고, 첫 표본부터 머문 것이다.
    func testStayingInsideRadiusCountsWithoutReachingInnerCircle() throws {
        let readings = (0...20).map { sample(Double($0), meters: 28) } + [sample(21, meters: 80)]
        let found = stays(readings)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.span.start, start)
        XCTAssertEqual(found.first?.span.end, start.addingTimeInterval(21 * 60))
    }

    /// 나갈 때 빨간 원을 벗어난 표본이 있으면 그 시각이 이탈이다.
    func testExitUsesTheFirstSampleOutsideTheRadius() {
        let readings = [sample(0, meters: 10), sample(10, meters: 10), sample(11, meters: 33), sample(12, meters: 33), sample(13, meters: 90)]
        let found = stays(readings)
        XCTAssertEqual(found.first?.span.end, start.addingTimeInterval(11 * 60))
        XCTAssertEqual(found.first?.exitBasis, .radiusCircle)
    }

    /// 오차가 큰 표본 하나로는 상태가 바뀌지 않는다. 같은 쪽이 이어지면 바뀐다.
    func testInaccurateSampleAloneDoesNotChangeState() {
        let oneOff = [sample(0, meters: 10), sample(1, meters: 10), sample(2, meters: 120, accuracy: 65), sample(3, meters: 10), sample(4, meters: 10)]
        XCTAssertEqual(stays(oneOff).count, 1)
        XCTAssertEqual(stays(oneOff).first?.span.end, start.addingTimeInterval(4 * 60))

        let walkedPast = [sample(0, meters: 120), sample(1, meters: 10, accuracy: 65), sample(2, meters: 120)]
        XCTAssertTrue(stays(walkedPast).isEmpty, "부정확한 안쪽 표본 하나는 진입이 아니다")

        let twice = [sample(0, meters: 120), sample(1, meters: 10, accuracy: 65), sample(2, meters: 10, accuracy: 65), sample(9, meters: 10), sample(10, meters: 120)]
        XCTAssertEqual(stays(twice).first?.span.start, start.addingTimeInterval(60))

        let junk = [sample(0, meters: 10), sample(1, meters: 3_000, accuracy: 2_000), sample(2, meters: 10)]
        XCTAssertEqual(stays(junk).count, 1)
    }

    /// 표본이 없는 시간은 머문 것으로 단정하지 않고 관측 안 됨으로 둔다. 너무 길면 잇지도 않는다.
    func testGapsAreUnobserved() throws {
        let readings = [sample(0, meters: 10), sample(5, meters: 10), sample(45, meters: 10), sample(50, meters: 10)]
        let stay = try XCTUnwrap(stays(readings).first)
        XCTAssertEqual(stay.span.duration, 50 * 60)
        XCTAssertEqual(stay.unobserved.count, 1)
        XCTAssertEqual(stay.observedDuration, 10 * 60)

        let split = [sample(0, meters: 10), sample(5, meters: 10), sample(120, meters: 10), sample(130, meters: 10)]
        let found = stays(split)
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found.first?.exitBasis, .notObserved)
    }

    /// 사용자 기록은 건드리지 않고, 다른 층 식당은 빼며, 작은 반경 우선은 그대로다.
    func testRestaurantMealsUseZoneAndKeepHeightRule() {
        func geo(_ altitude: Double, vertical: Double = 5) -> GeoPoint {
            GeoPoint(latitude: 37.5, longitude: 127, altitude: altitude, horizontalAccuracy: 10, verticalAccuracy: vertical)
        }
        var restaurant = FrequentPlace(kind: .restaurant, name: "식당", point: geo(0, vertical: -1), floor: 1)
        restaurant.radiusMeters = 30
        var readings = (0...30).map { minute -> SensorReading in
            sample(Double(minute), meters: minute.isMultiple(of: 3) ? 33 : 25)
        }
        let span = TimeSpan(start: start.addingTimeInterval(-3_600), end: start.addingTimeInterval(7_200))
        let meals = RestaurantMealActualEngine.records(restaurants: [restaurant], readings: readings, inside: span, asOf: span.end)
        XCTAssertEqual(meals.count, 1, "경계를 오가도 식사 하나다")

        var company = FrequentPlace(kind: .company, name: "회사", point: geo(25), floor: 8)
        company.radiusMeters = 200
        company.floorReferencePoints = [FloorCalibrationPoint(
            floor: 8, point: geo(25), relativeAltitudeMeters: nil, pressureKilopascals: nil,
            altimeterSessionID: nil, capturedAt: start.addingTimeInterval(-86_400)
        )]
        readings = readings.map { reading in
            var value = reading
            value.point?.altitude = 25
            return value
        }
        XCTAssertTrue(RestaurantMealActualEngine.records(
            restaurants: [company, restaurant], readings: readings, inside: span, asOf: span.end
        ).isEmpty, "8층 사무실 높이면 1층 식당이 아니다")
    }

    /// 실내에서 위치가 40분 멈춰도 앞뒤가 식당 안이면 식사다. 업무는 그만큼 잘린다.
    func testRestaurantMealSurvivesIndoorLocationPause() {
        var restaurant = FrequentPlace(kind: .restaurant, name: "식당", point: GeoPoint(latitude: 37.5, longitude: 127, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: -1))
        restaurant.radiusMeters = 40
        let readings = [sample(0, meters: 5), sample(1, meters: 5), sample(41, meters: 5), sample(42, meters: 5)]
        let span = TimeSpan(start: start.addingTimeInterval(-3_600), end: start.addingTimeInterval(7_200))
        let meals = RestaurantMealActualEngine.records(restaurants: [restaurant], readings: readings, inside: span, asOf: span.end)
        XCTAssertEqual(meals.count, 1)
        XCTAssertEqual(meals.first?.categoryID, "eating")
        XCTAssertEqual(meals.first?.confidence, .medium, "관측이 짧으면 확정처럼 올리지 않는다")
        let work = ActualRecord(planID: nil, title: "업무", categoryID: "work", startedAt: start.addingTimeInterval(-3_000), endedAt: start.addingTimeInterval(6_000), source: .location)
        let carved = RestaurantMealActualEngine.carvingMeals(from: [work] + meals, asOf: span.end).filter { $0.categoryID == "work" }
        XCTAssertEqual(carved.count, 2)
    }

    /// 한 시간을 넘게 비면 근거가 없으므로 식사로 잇지 않는다.
    func testRestaurantMealDoesNotBridgeLongSilence() {
        var restaurant = FrequentPlace(kind: .restaurant, name: "식당", point: GeoPoint(latitude: 37.5, longitude: 127, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: -1))
        restaurant.radiusMeters = 40
        let span = TimeSpan(start: start.addingTimeInterval(-3_600), end: start.addingTimeInterval(14_400))
        XCTAssertTrue(RestaurantMealActualEngine.records(
            restaurants: [restaurant], readings: [sample(0, meters: 5), sample(100, meters: 5)], inside: span, asOf: span.end
        ).isEmpty)
    }
}
