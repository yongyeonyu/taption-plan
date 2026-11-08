import XCTest
@testable import TaptionPlan

/// 등록 지점 반경으로 걷기를 가른다(대표 결정 2026-11-08, CLP1105A01).
final class PlaceWalkRadiusSplitTests: XCTestCase {
    private let calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return value
    }()
    private var dayStart: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 5))! }
    private let center = GeoPoint(latitude: 37.5, longitude: 127, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5)
    private lazy var company = FrequentPlace(kind: .company, point: center, radiusMeters: 100)

    private func date(_ minute: Double) -> Date { dayStart.addingTimeInterval(minute * 60) }

    private func sample(_ minute: Double, meters: Double, accuracy: Double = 10) -> SensorReading {
        var value = SensorReading(
            timestamp: date(minute),
            point: GeoPoint(latitude: 37.5 + meters / 111_320, longitude: 127, altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 5),
            motion: .walking
        )
        value.gpsAvailable = true
        return value
    }

    private func stay(_ start: Double, _ end: Double) -> PlaceStay {
        PlaceStay(placeKey: company.stablePlaceKey, displayName: "회사", span: TimeSpan(start: date(start), end: date(end)), confidence: .high)
    }

    private func walk(_ start: Int, _ end: Int, id: UUID = UUID()) -> MapHomeTimeRailSegment {
        MapHomeTimeRailSegment(startMinute: start, endMinute: end, categoryID: "movement", title: "걷기", behavior: "walking", sourceID: id)
    }

    private func apply(
        _ segments: [MapHomeTimeRailSegment],
        stays: [PlaceStay],
        readings: [SensorReading],
        userOwned: Set<UUID> = []
    ) -> [MapHomeTimeRailSegment] {
        MapHomePlaceFirstPolicy.apply(
            to: segments, stays: stays, frequentPlaces: [company], readings: readings,
            userOwnedIDs: userOwned, on: dayStart, calendar: calendar
        )
    }

    /// 반경 안에서만 걸었으면 업무 안의 상세 걷기다. 줄 이름은 "업무"다.
    func testWalkInsideRadiusIsAbsorbedWithCategoryTitle() {
        let segments = [
            MapHomeTimeRailSegment(startMinute: 540, endMinute: 600, categoryID: "work", title: "근무"),
            walk(600, 610),
            MapHomeTimeRailSegment(startMinute: 610, endMinute: 700, categoryID: "work", title: "근무"),
        ]
        let readings = stride(from: 600.0, through: 610, by: 1).map { sample($0, meters: $0.truncatingRemainder(dividingBy: 2) == 0 ? 30 : 80) }
        let result = apply(segments, stays: [stay(540, 700)], readings: readings)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].categoryID, "work")
        XCTAssertEqual(result[0].title, "업무")
        XCTAssertEqual(result[0].walkSpans, [600..<610])
    }

    /// 반경 밖까지 나가면 반경의 절반(50m)을 지난 때부터 걷기다. 그 앞은 업무다.
    func testWalkLeavingRadiusStartsAtHalfRadiusCrossing() {
        let readings = [sample(600, meters: 10), sample(602, meters: 30), sample(604, meters: 70), sample(606, meters: 150), sample(610, meters: 400)]
        let result = apply([walk(600, 615)], stays: [stay(540, 605)], readings: readings)
        XCTAssertEqual(result.map(\.categoryID), ["work", "movement"])
        // 30m(602분)와 70m(604분) 사이에서 50m를 지난 때는 603분이다.
        XCTAssertEqual(result[0].startMinute, 600)
        XCTAssertEqual(result[0].endMinute, 603)
        XCTAssertEqual(result[0].title, "업무")
        XCTAssertEqual(result[0].walkSpans, [600..<603])
        XCTAssertEqual(result[1].startMinute, 603)
        XCTAssertEqual(result[1].endMinute, 615)
        XCTAssertEqual(result[1].title, "걷기")
        XCTAssertEqual(result[1].behavior, "walking")
        XCTAssertTrue(result[1].walkSpans.isEmpty)
    }

    /// 돌아올 때는 반경의 절반 안으로 들어온 때 걷기가 끝난다.
    func testReturnTripEndsWalkInsideHalfRadius() {
        let readings = [sample(700, meters: 400), sample(706, meters: 150), sample(708, meters: 90), sample(710, meters: 10), sample(712, meters: 5)]
        let result = apply([walk(700, 712)], stays: [stay(711, 800)], readings: readings)
        XCTAssertEqual(result.map(\.categoryID), ["movement", "work"])
        // 90m(708분)와 10m(710분) 사이에서 50m가 되는 때는 709분이다.
        XCTAssertEqual(result[0].endMinute, 709)
        XCTAssertEqual(result[1].startMinute, 709)
        XCTAssertEqual(result[1].walkSpans, [709..<712])
    }

    /// 나갔다 돌아온 걷기는 나간 동안만 걷기다.
    func testRoundTripSplitsIntoPlaceWalkPlace() {
        let readings = [sample(600, meters: 10), sample(602, meters: 30), sample(604, meters: 70), sample(610, meters: 300),
                        sample(616, meters: 70), sample(618, meters: 30), sample(620, meters: 10)]
        let result = apply([walk(600, 620)], stays: [stay(540, 600), stay(620, 700)], readings: readings)
        XCTAssertEqual(result.map(\.categoryID), ["work", "movement", "work"])
        XCTAssertEqual(result.map(\.startMinute), [600, 603, 617])
        XCTAssertEqual(result.map(\.endMinute), [603, 617, 620])
    }

    /// 반경 밖 표본이 부정확하면 나간 것으로 보지 않는다.
    func testInaccurateOutsideSampleDoesNotSplit() {
        company = FrequentPlace(kind: .company, point: center, radiusMeters: 40)
        let readings = [sample(600, meters: 5), sample(604, meters: 60, accuracy: 50), sample(608, meters: 5)]
        let result = apply([walk(600, 610)], stays: [stay(540, 700)], readings: readings)
        XCTAssertEqual(result.map(\.categoryID), ["work"])
    }

    /// 사용자가 만든·고친 걷기는 위치로 가르지 않고 예전처럼 머문 시간 겹침으로만 본다.
    func testUserOwnedWalkIsNotSplit() {
        let id = UUID()
        let readings = [sample(600, meters: 10), sample(604, meters: 70), sample(606, meters: 300)]
        let away = apply([walk(600, 615, id: id)], stays: [stay(540, 605)], readings: readings, userOwned: [id])
        XCTAssertEqual(away.map(\.categoryID), ["movement"])
        XCTAssertEqual(away.first?.sourceIDs, [id])
        let inside = apply([walk(600, 610, id: id)], stays: [stay(540, 700)], readings: readings, userOwned: [id])
        XCTAssertEqual(inside.map(\.categoryID), ["work"])
        XCTAssertEqual(inside.first?.title, "업무")
    }

    /// 걷는 동안 위치가 없으면 예전처럼 머문 시간 겹침(70%)으로 본다.
    func testWithoutReadingsFallsBackToStayOverlap() {
        XCTAssertEqual(apply([walk(600, 610)], stays: [stay(540, 700)], readings: []).map(\.categoryID), ["work"])
        XCTAssertEqual(apply([walk(600, 615)], stays: [stay(540, 605)], readings: []).map(\.categoryID), ["movement"])
    }

    /// 중심이 없는 등록 지점은 반경으로 가르지 않는다.
    func testPlaceWithoutCenterKeepsStayOverlapRule() {
        company = FrequentPlace(kind: .company, point: nil, radiusMeters: 100)
        let readings = [sample(600, meters: 10), sample(604, meters: 300)]
        XCTAssertEqual(apply([walk(600, 610)], stays: [stay(540, 700)], readings: readings).map(\.categoryID), ["work"])
    }

    /// 식사 대분류도 이름이 걷기로 남지 않는다.
    func testAbsorbedRestaurantWalkShowsEatingTitle() {
        company = FrequentPlace(kind: .restaurant, point: center, radiusMeters: 40)
        let result = apply([walk(720, 725)], stays: [stay(700, 760)], readings: [sample(722, meters: 5)])
        XCTAssertEqual(result.first?.categoryID, "eating")
        XCTAssertEqual(result.first?.title, "식사")
    }
}
