import XCTest
@testable import TaptionPlan

/// 위치가 끊긴 점심의 판정(ALG1102A01). 후보는 낮은 신뢰도이고 확인 전에는 업무를 자르지 않는다.
final class UnobservedStayEngineTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Seoul") ?? .current
        return value
    }

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: hour, minute: minute)) ?? .distantPast
    }

    private func fix(_ date: Date, meters: Double = 0) -> SensorReading {
        var value = SensorReading(
            timestamp: date,
            point: GeoPoint(latitude: 37.5 + meters / 111_320, longitude: 127, altitude: 10, horizontalAccuracy: 10, verticalAccuracy: 5),
            motion: .unknown
        )
        value.gpsAvailable = true
        return value
    }

    private var day: TimeSpan { TimeSpan(start: at(0), end: at(23, 59)) }

    private func candidates(_ readings: [SensorReading], foot: [TimeSpan], actuals: [ActualRecord] = []) -> [ActualRecord] {
        UnobservedStayEngine.mealCandidates(readings: readings, footSpans: foot, actuals: actuals, inside: day, calendar: calendar)
    }

    /// 걸어 나가 위치가 끊기고 걸어 돌아온 점심은 낮은 신뢰도 후보가 된다.
    func testMaskedLunchBecomesLowConfidenceCandidate() {
        let foot = [TimeSpan(start: at(11, 50), end: at(12, 0)), TimeSpan(start: at(13, 0), end: at(13, 5))]
        let found = candidates([fix(at(11, 50)), fix(at(13, 5), meters: 50)], foot: foot)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.startedAt, at(12))
        XCTAssertEqual(found.first?.endedAt, at(13))
        XCTAssertEqual(found.first?.confidence, .low)
        XCTAssertEqual(found.first?.categoryID, "eating")
        XCTAssertTrue(found.first?.evidence.contains { $0.hasPrefix("관측 안 된 체류") } == true)
    }

    /// 점심 뒤 자리로 돌아와 위치가 또 끊겨도 후보는 끼니마다 가장 긴 하나다(11-02 원본에서 나온 오탐).
    func testOnlyLongestGapPerMealIsACandidate() {
        let foot = [TimeSpan(start: at(11, 50), end: at(12, 0)), TimeSpan(start: at(13, 0), end: at(13, 2)), TimeSpan(start: at(13, 40), end: at(13, 42))]
        let found = candidates([fix(at(11, 50)), fix(at(13, 2)), fix(at(13, 42))], foot: foot)
        XCTAssertEqual(found.map(\.startedAt), [at(12)])
    }

    /// 자리에 두고 위치만 끊긴 시간, 식사 때가 아닌 시간, 멀리 옮겨 간 끊김은 후보가 아니다.
    func testGapsWithoutLeavingAreNotMeals() {
        XCTAssertTrue(candidates([fix(at(11, 50)), fix(at(13, 5))], foot: []).isEmpty, "걷지 않았다")
        let afternoon = [TimeSpan(start: at(15, 0), end: at(15, 5)), TimeSpan(start: at(16, 0), end: at(16, 5))]
        XCTAssertTrue(candidates([fix(at(15, 0)), fix(at(16, 5))], foot: afternoon).isEmpty, "식사 때가 아니다")
        let foot = [TimeSpan(start: at(11, 50), end: at(12, 0)), TimeSpan(start: at(13, 0), end: at(13, 5))]
        XCTAssertTrue(candidates([fix(at(11, 50)), fix(at(13, 5), meters: 5_000)], foot: foot).isEmpty, "이동이다")
    }

    /// 후보는 업무를 자르지 않고, 사용자가 확인한 뒤에만 자른다.
    func testCandidateCarvesWorkOnlyAfterConfirmation() throws {
        let foot = [TimeSpan(start: at(11, 50), end: at(12, 0)), TimeSpan(start: at(13, 0), end: at(13, 5))]
        var candidate = try XCTUnwrap(candidates([fix(at(11, 50)), fix(at(13, 5))], foot: foot).first)
        let work = ActualRecord(planID: nil, title: "근무", categoryID: "work", startedAt: at(9), endedAt: at(18), source: .location)
        let unconfirmed = RestaurantMealActualEngine.carvingMeals(from: [work, candidate], asOf: at(23))
        XCTAssertEqual(unconfirmed.filter { $0.categoryID == "work" }.count, 1)
        XCTAssertEqual(unconfirmed.first { $0.categoryID == "work" }?.endedAt, at(18))

        candidate.manuallyCorrected = true
        let confirmed = RestaurantMealActualEngine.carvingMeals(from: [work, candidate], asOf: at(23))
        XCTAssertEqual(confirmed.filter { $0.categoryID == "work" }.count, 2)
    }

    /// 회의와 겹치는 끊김은 식사 후보가 되지 않는다(MEA1105A01).
    func testMeetingBlocksMealCandidate() {
        let foot = [TimeSpan(start: at(11, 50), end: at(12, 0)), TimeSpan(start: at(13, 0), end: at(13, 5))]
        let readings = [fix(at(11, 50)), fix(at(13, 5))]
        let inside = TimeSpan(start: at(0), end: at(23))
        XCTAssertFalse(UnobservedStayEngine.mealCandidates(readings: readings, footSpans: foot, actuals: [], inside: inside).isEmpty)
        XCTAssertTrue(UnobservedStayEngine.mealCandidates(
            readings: readings, footSpans: foot, actuals: [],
            busySpans: [TimeSpan(start: at(11, 30), end: at(13, 30))], inside: inside
        ).isEmpty)
    }

    /// 식사 시간은 자동 걷기 세션에서 잘려 이동으로 덮이지 않고, 사용자 기록은 그대로다(MEA1105A01).
    func testMealCarvesAutomaticWalkSessionOnly() {
        let meal = ActualRecord(
            planID: nil, title: "식사 · 식당", categoryID: "eating", startedAt: at(17, 51), endedAt: at(18, 12),
            source: .location, confidence: .high, behavior: "meal", modelVersion: RestaurantMealActualEngine.modelVersion
        )
        let walk = ActualRecord(planID: nil, title: "걷기", categoryID: "activity", startedAt: at(17, 47), endedAt: at(18, 55), source: .location, confidence: .high)
        let carved = RestaurantMealActualEngine.carvingMeals(from: [walk, meal], asOf: at(23))
        let pieces = carved.filter { $0.title == "걷기" }.sorted { $0.startedAt < $1.startedAt }
        XCTAssertEqual(pieces.map(\.startedAt), [at(17, 47), at(18, 12)])
        XCTAssertEqual(pieces.map(\.endedAt), [at(17, 51), at(18, 55)])
        XCTAssertEqual(RestaurantMealActualEngine.carvingMeals(from: carved, asOf: at(23)), carved)
        var manual = walk
        manual.manuallyCorrected = true
        XCTAssertEqual(RestaurantMealActualEngine.carvingMeals(from: [manual, meal], asOf: at(23)).filter { $0.title == "걷기" }.count, 1)
        var watch = walk
        watch.source = .appleWatch
        XCTAssertEqual(RestaurantMealActualEngine.carvingMeals(from: [watch, meal], asOf: at(23)).filter { $0.title == "걷기" }.count, 1)
    }

    /// 겹친 회사보다 60m 이상 가까우면 높이로 식당을 빼지 않는다(MEA1105A01).
    func testClearlyClosestPlaceSkipsHeightCheck() {
        func point(_ meters: Double) -> GeoPoint {
            GeoPoint(latitude: 37.5 + meters / 111_320, longitude: 127, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10)
        }
        let restaurant = FrequentPlace(kind: .restaurant, name: "식당", point: point(0))
        let company = FrequentPlace(kind: .company, name: "회사", point: point(118))
        let near = SensorReading(timestamp: at(18), point: point(8))
        XCTAssertTrue(PlaceHeightMatch.isClearlyClosest(restaurant, among: [restaurant, company], readings: [near]))
        let between = SensorReading(timestamp: at(18), point: point(59))
        XCTAssertFalse(PlaceHeightMatch.isClearlyClosest(restaurant, among: [restaurant, company], readings: [between]))
    }

    /// 사용자가 넣은 기록이나 이미 있는 식사와 겹치면 새로 만들지 않는다.
    func testUserRecordsAndExistingMealsBlockCandidate() {
        let foot = [TimeSpan(start: at(11, 50), end: at(12, 0)), TimeSpan(start: at(13, 0), end: at(13, 5))]
        let readings = [fix(at(11, 50)), fix(at(13, 5))]
        let manual = ActualRecord(planID: nil, title: "회의", categoryID: "work", startedAt: at(12), endedAt: at(13), source: .manual)
        XCTAssertTrue(candidates(readings, foot: foot, actuals: [manual]).isEmpty)
        let meal = ActualRecord(planID: nil, title: "식사", categoryID: "eating", startedAt: at(12), endedAt: at(13), source: .location)
        XCTAssertTrue(candidates(readings, foot: foot, actuals: [meal]).isEmpty)
    }

    func testPauseRegionRadiusFollowsAccuracy() {
        XCTAssertEqual(LocationPauseRegionPolicy.radius(horizontalAccuracy: 10), 30)
        XCTAssertEqual(LocationPauseRegionPolicy.radius(horizontalAccuracy: 25), 50)
        XCTAssertTrue(LocationPauseRegionPolicy.needsNewRegion(distanceFromCenter: nil, radius: 0))
        XCTAssertFalse(LocationPauseRegionPolicy.needsNewRegion(distanceFromCenter: 20, radius: 30))
        XCTAssertTrue(LocationPauseRegionPolicy.needsNewRegion(distanceFromCenter: 40, radius: 30))
        XCTAssertEqual(LocationPauseRegionPolicy.radius(horizontalAccuracy: 100), 200)
        XCTAssertEqual(LocationPauseRegionPolicy.radius(horizontalAccuracy: 1_000), 300)
        XCTAssertEqual(LocationPauseRegionPolicy.radius(horizontalAccuracy: -1), 300)
        XCTAssertFalse(LocationPauseRegionPolicy.hasLeft(distanceMeters: 90, radius: 100))
        XCTAssertTrue(LocationPauseRegionPolicy.hasLeft(distanceMeters: 110, radius: 100))
    }
}
