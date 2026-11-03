import XCTest
@testable import TaptionPlan

/// 임시 경로·체류·층·수면·걸음 판정(ALG1102A01).
final class AlgorithmUpgradeTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func geo(_ meters: Double = 0, accuracy: Double = 10) -> GeoPoint {
        GeoPoint(latitude: 37.5 + meters / 111_320, longitude: 127, altitude: 10, horizontalAccuracy: accuracy, verticalAccuracy: 5)
    }

    private func fix(_ minutes: Double, meters: Double = 0, accuracy: Double = 10, motion: MotionKind = .unknown) -> SensorReading {
        var value = SensorReading(timestamp: start.addingTimeInterval(minutes * 60), point: geo(meters, accuracy: accuracy), motion: motion)
        value.gpsAvailable = true
        return value
    }

    // MARK: 임시 경로

    private func routeRequests(gapMinutes: Double, gapMeters: Double, after: MotionKind) -> [ExpectedRouteRequest] {
        let end = gapMinutes + 1
        let segment = TravelSegment(
            mode: .car, span: TimeSpan(start: start, end: start.addingTimeInterval(end * 60)),
            distanceMeters: gapMeters, confidence: .high, evidence: [], isConfirmed: false
        )
        return ExpectedRouteRequestEngine.requests(
            travel: [segment], places: [],
            readings: [fix(0, motion: .automotive), fix(0.5, meters: 200, motion: .automotive),
                       fix(gapMinutes + 0.5, meters: gapMeters, motion: after)],
            in: TimeSpan(start: start.addingTimeInterval(-3_600), end: start.addingTimeInterval(86_400)),
            through: start.addingTimeInterval(86_400),
            gpsLoggingInterval: 10
        )
    }

    /// 차를 탄 채 표본만 2분 비면 임시 경로를 만들지 않고, 3분이 넘게 비면 만든다.
    func testSparseVehicleGapIsNotATemporaryRoute() {
        XCTAssertTrue(routeRequests(gapMinutes: 2, gapMeters: 1_500, after: .automotive).isEmpty)
        XCTAssertFalse(routeRequests(gapMinutes: 10, gapMeters: 5_000, after: .automotive).isEmpty)
    }

    /// 내린 뒤의 틈은 드문 표본이 아니라 빠진 이동이다.
    func testGapEndingOnFootStaysMissing() {
        XCTAssertFalse(routeRequests(gapMinutes: 2, gapMeters: 1_500, after: .walking).isEmpty)
    }

    // MARK: 체류·장소

    /// 셀룰러 위치 한 점이 체류를 끊거나 중심을 끌지 못한다.
    func testCoarseFixDoesNotBreakStayOrPullCenter() throws {
        var readings = (0...20).map { fix(Double($0), meters: 5, accuracy: 10) }
        readings.insert(fix(10.5, meters: 3_000, accuracy: 2_000), at: 11)
        let stays = PlaceDetectionEngine().detectStays(readings: readings)
        XCTAssertEqual(stays.count, 1)
        let point = try XCTUnwrap(stays.first?.point)
        XCTAssertEqual((point.latitude - 37.5) * 111_320, 5, accuracy: 1)
    }

    /// 정밀한 표본이 부정확한 표본보다 중심을 더 끈다.
    func testCenterIsWeightedByAccuracy() throws {
        let readings = (0...20).map { minute in
            minute.isMultiple(of: 2) ? fix(Double(minute), meters: 0, accuracy: 5) : fix(Double(minute), meters: 40, accuracy: 50)
        }
        let point = try XCTUnwrap(PlaceDetectionEngine().detectStays(readings: readings).first?.point)
        XCTAssertLessThan((point.latitude - 37.5) * 111_320, 5)
    }

    /// 하루에 같은 자리를 두 번 들르면 키가 하나로 묶이고, 아는 이름의 키는 그대로다.
    func testSameSpotVisitsShareKeyAndKnownKeyIsFixed() {
        let first = (0...20).map { fix(Double($0), meters: 0) }
        let away = [fix(21, meters: 5_000)]
        let second = (30...50).map { fix(Double($0), meters: 22) }
        let stays = PlaceDetectionEngine().detectStays(readings: first + away + second)
        XCTAssertEqual(stays.count, 2)
        XCTAssertEqual(stays[0].placeKey, stays[1].placeKey)

        let known = String(format: "%.4f,%.4f", 37.5002, 127.0)
        let named = PlaceDetectionEngine().detectStays(readings: first + away + second, knownNames: [known: "회사"])
        XCTAssertTrue(named.allSatisfy { $0.placeKey == known && $0.displayName == "회사" })
    }

    /// 회사 반경 안의 식당은 반경 끝이어도 식당이고, 크기가 비슷한 장소는 거리·정확도로 가른다.
    func testPlaceScoreBalancesDistanceAccuracyAndSize() {
        var company = FrequentPlace(kind: .company, name: "회사", point: geo(0), floor: nil)
        company.radiusMeters = 200
        var restaurant = FrequentPlace(kind: .restaurant, name: "식당", point: geo(40), floor: nil)
        restaurant.radiusMeters = 30
        let engine = FrequentPlaceResolutionEngine()
        XCTAssertEqual(engine.nearestMatch(to: geo(40), candidates: [company, restaurant])?.kind, .restaurant)
        XCTAssertEqual(engine.nearestMatch(to: geo(0), candidates: [company, restaurant])?.kind, .company)
        XCTAssertEqual(engine.nearestMatch(to: geo(12, accuracy: 60), candidates: [company, restaurant])?.kind, .restaurant)

        var cafe = FrequentPlace(kind: .restaurant, name: "카페", point: geo(0), floor: nil)
        cafe.radiusMeters = 40
        var other = FrequentPlace(kind: .company, name: "사무실", point: geo(40), floor: nil)
        other.radiusMeters = 40
        XCTAssertEqual(engine.nearestMatch(to: geo(10), candidates: [cafe, other])?.name, "카페")
        XCTAssertEqual(engine.nearestMatch(to: geo(30), candidates: [cafe, other])?.name, "사무실")
    }

    // MARK: 층·고도

    private func altitude(_ minutes: Double, _ meters: Double, session: UUID) -> SensorReading {
        SensorReading(timestamp: start.addingTimeInterval(minutes * 60), relativeAltitudeMeters: meters, altimeterSessionID: session)
    }

    /// 세 시간에 걸친 3m 변화는 날씨다. 처음과 끝만 보면 한 층을 오른 것으로 보였다.
    func testSlowBarometerDriftIsNotAFloorChange() {
        let session = UUID()
        let readings = stride(from: 0.0, through: 180, by: 5).map { altitude($0, 3.2 * $0 / 180, session: session) }
        XCTAssertNil(FloorEstimator(minimumStableSampleCount: 3).estimate(readings: readings, placeKey: "office", baselineFloor: 5))
    }

    /// 밤새 조용한 휴대폰의 빠른 흐름(11-01 원본: 약 0.02m/s로 7.6m)도 층 이동이 아니다.
    func testQuietPhoneOvernightDriftIsNotAFloorChange() {
        let session = UUID()
        let readings = [altitude(0, 0, session: session), altitude(6, -7.6, session: session), altitude(10, -7.7, session: session),
                        altitude(14, -7.6, session: session), altitude(18, -7.6, session: session)]
        XCTAssertNil(FloorEstimator(minimumStableSampleCount: 3).estimate(readings: readings, placeKey: "home", baselineFloor: 20))
    }

    /// 걸음이 늘면서 오른 것은 느려도 이동이다.
    func testClimbWithStepsCounts() throws {
        let session = UUID()
        let readings = (0...4).map { index -> SensorReading in
            var value = altitude(Double(index) * 2, Double(index) * 3, session: session)
            value.stepCount = index * 50
            return value
        } + [altitude(9, 12, session: session), altitude(10, 12, session: session), altitude(11, 12, session: session)]
        let result = try XCTUnwrap(FloorEstimator(minimumStableSampleCount: 3).estimate(readings: readings, placeKey: "station", baselineFloor: 1))
        XCTAssertEqual(result.toFloor, 5)
    }

    /// 오른 뒤 흐른 기압은 층 수에 들어가지 않는다.
    func testRealClimbIsCountedDespiteLaterDrift() throws {
        let session = UUID()
        var readings = [altitude(0, 0, session: session), altitude(5, 0, session: session), altitude(6, 3.1, session: session), altitude(7, 6.1, session: session)]
        readings += stride(from: 10.0, through: 180, by: 10).map { altitude($0, 6.1 + 4 * ($0 - 10) / 170, session: session) }
        let result = try XCTUnwrap(FloorEstimator(minimumStableSampleCount: 3).estimate(readings: readings, placeKey: "office", baselineFloor: 5))
        XCTAssertEqual(result.toFloor, 7)
        XCTAssertEqual(result.relativeAltitudeMeters ?? 0, 6.1, accuracy: 0.2)
    }

    /// 다른 방문에서 잰 기압 기준은 날씨 오차가 끼어 비교하지 않는다. 기압 오차를 넣어도 장소가 뒤집히지 않는다.
    func testFloorHeightDropsMinAndMaxBeforeAveraging() throws {
        XCTAssertNil(PlaceHeightCapture.trimmedMean([1, 2]))
        XCTAssertEqual(try XCTUnwrap(PlaceHeightCapture.trimmedMean([100, 1, 2, 3, -50])), 2, accuracy: 0.0001)
        let values = (0..<18).map { _ in 100.5 } + [90, 130]
        XCTAssertEqual(try XCTUnwrap(PlaceHeightCapture.trimmedMean(values)), 100.5, accuracy: 0.0001)

        let center = GeoPoint(latitude: 37.5, longitude: 127, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 5)
        var place = FrequentPlace(kind: .company, name: "회사")
        place.setMapLocation(center)
        var here = SensorReading(timestamp: .now, point: center, motion: .stationary)
        here.gpsAvailable = true
        here.relativeAltitudeMeters = 5
        XCTAssertTrue(PlaceHeightCapture.isInside(place, reading: here))
        var far = here
        far.point?.latitude = 37.6
        XCTAssertFalse(PlaceHeightCapture.isInside(place, reading: far), "멀리서 고치면 그 지점의 높이가 아니다")
        let reference = try XCTUnwrap(PlaceHeightCapture.reference(from: here, pressures: [101, 101, 101.3], altitudes: [40, 42, 60]))
        XCTAssertEqual(try XCTUnwrap(reference.pressureKilopascals), 101, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(reference.point?.altitude), 42, accuracy: 0.0001)
        XCTAssertNil(reference.relativeAltitudeMeters)
        XCTAssertNil(PlaceHeightCapture.reference(from: here, pressures: [], altitudes: []))
    }

    func testHomeChoresNeedSeveralSeparateBouts() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul") ?? .current
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 19)))
        let stay = TimeSpan(start: start, end: start.addingTimeInterval(3600))
        func reading(_ second: Int, _ motion: MotionKind, screen: Bool = false) -> SensorReading {
            var value = SensorReading(timestamp: start.addingTimeInterval(Double(second)), point: nil, motion: motion)
            value.screenIsOn = screen
            return value
        }
        func bouts(_ count: Int, seconds: Int, screen: Bool = false) -> [SensorReading] {
            (0..<count).flatMap { index -> [SensorReading] in
                let base = index * (3400 / count)
                return stride(from: 0, through: seconds, by: 30).map { reading(base + $0, .walking, screen: screen) }
                    + [reading(base + seconds + 200, .stationary)]
            }
        }
        XCTAssertNotNil(HomeChorePattern.assess(bouts(5, seconds: 180), in: stay, calendar: calendar), "여러 번 나눠 움직였다")
        XCTAssertNil(HomeChorePattern.assess(bouts(1, seconds: 900), in: stay, calendar: calendar), "한 번의 긴 걷기")
        XCTAssertNil(HomeChorePattern.assess(bouts(5, seconds: 180, screen: true), in: stay, calendar: calendar), "화면을 보며 움직였다")
        XCTAssertNil(HomeChorePattern.assess(bouts(5, seconds: 30), in: stay, calendar: calendar), "움직인 시간이 짧다")
        let night = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 2)))
        XCTAssertNil(HomeChorePattern.assess(bouts(5, seconds: 180), in: TimeSpan(start: night, end: night.addingTimeInterval(3600)), calendar: calendar), "심야")
    }

    func testPressureReferenceOnlyCountsInsideTheVisit() {
        func company(capturedAt: Date) -> FrequentPlace {
            var place = FrequentPlace(kind: .company, name: "회사", point: geo(0), floor: 8)
            place.radiusMeters = 200
            place.floorReferencePoints = [FloorCalibrationPoint(
                floor: 8, point: GeoPoint(latitude: 37.5, longitude: 127, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: -1),
                relativeAltitudeMeters: nil, pressureKilopascals: 101.3,
                altimeterSessionID: nil, capturedAt: capturedAt
            )]
            return place
        }
        var restaurant = FrequentPlace(kind: .restaurant, name: "식당", point: geo(0), floor: 1)
        restaurant.radiusMeters = 30
        var reading = SensorReading(timestamp: start, point: GeoPoint(latitude: 37.5, longitude: 127, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: -1), motion: .stationary)
        reading.pressureKilopascals = 100.9 // 다섯 시간 사이 날씨로 40hPa/100 ≈ 33m
        let stale = company(capturedAt: start.addingTimeInterval(-5 * 3_600))
        XCTAssertFalse(PlaceHeightMatch.isAtOtherHeight(stale, among: [stale, restaurant], readings: [reading]))
        let fresh = company(capturedAt: start.addingTimeInterval(-600))
        XCTAssertTrue(PlaceHeightMatch.isAtOtherHeight(fresh, among: [fresh, restaurant], readings: [reading]))
    }

    // MARK: 수면

    private func nightReading(_ minutes: Double, steps: Int?, charging: Bool = false) -> SensorReading {
        SensorReading(
            timestamp: start.addingTimeInterval(minutes * 60),
            motion: .stationary, motionConfidence: .high, stepCount: steps,
            powerState: charging ? .charging : .unplugged, screenBrightness: 0.1, screenIsOn: false
        )
    }

    /// 낮에 쌓인 걸음 수가 그대로 있어도 밤은 쪼개지지 않는다.
    func testAccumulatedStepsDoNotBreakSleep() {
        let readings = stride(from: 0.0, through: 480, by: 5).map { nightReading($0, steps: 8_000) }
        let span = TimeSpan(start: start, end: start.addingTimeInterval(481 * 60))
        let records = PhoneSleepWakeEngine.records(
            readings: readings, actuals: [], inside: span, watchAvailable: false, maximumSampleGap: 20 * 60, asOf: span.end
        )
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.startedAt, start.addingTimeInterval(5 * 60))

        let charging = stride(from: 0.0, through: 480, by: 5).map { nightReading($0, steps: 8_000, charging: true) }
        XCTAssertEqual(ChargingInactivitySleepEngine.records(
            readings: charging, actuals: [], inside: span, watchAvailable: false, maximumSampleGap: 20 * 60, asOf: span.end
        ).count, 1)
    }

    /// 실제로 걸음이 늘고 이어지면 깬 것이다.
    func testRealStepIncreaseWakesUp() throws {
        var readings = stride(from: 0.0, through: 240, by: 5).map { nightReading($0, steps: 8_000) }
        readings += stride(from: 245.0, through: 300, by: 5).map { minute in
            var value = nightReading(minute, steps: 8_000 + Int(minute - 240) * 10)
            value.motion = .stationary
            return value
        }
        let span = TimeSpan(start: start, end: start.addingTimeInterval(301 * 60))
        let records = PhoneSleepWakeEngine.records(
            readings: readings, actuals: [], inside: span, watchAvailable: false, maximumSampleGap: 20 * 60, asOf: span.end
        )
        let end = try XCTUnwrap(records.first?.endedAt)
        XCTAssertLessThan(end, start.addingTimeInterval(250 * 60))
    }

    // MARK: 걸음·거리

    private func stepReading(_ minutes: Double, steps: Int, device: TrackingDevice, meters: Double = 0) -> SensorReading {
        var value = fix(minutes, meters: meters, motion: .walking)
        value.stepCount = steps
        value.sourceDevice = device
        return value
    }

    /// 아이폰과 워치 누적값이 번갈아 와도 가짜 증가가 없다.
    func testInterleavedDeviceCountersAreSeparated() {
        let readings = [
            stepReading(0, steps: 5_000, device: .iPhone), stepReading(1, steps: 300, device: .appleWatch),
            stepReading(2, steps: 5_100, device: .iPhone), stepReading(3, steps: 400, device: .appleWatch),
            stepReading(4, steps: 5_200, device: .iPhone), stepReading(5, steps: 480, device: .appleWatch),
        ]
        XCTAssertEqual(DeviceStepCounter.increases(in: readings), [.iPhone: 200, .appleWatch: 180])
        XCTAssertEqual(DeviceStepCounter.increase(in: readings), 200)
    }

    /// 깨끗한 야외 걷기로 재서 실내 걸음을 옮기고, 재지 못하면 기본 보폭이라고 적는다.
    func testBreakdownSeparatesGPSAndStepEstimates() throws {
        func walk(_ from: Double, minutes: Double, steps: Int, meters: Double, accuracy: Double) -> (TravelSegment, [SensorReading]) {
            let span = TimeSpan(start: start.addingTimeInterval(from * 60), end: start.addingTimeInterval((from + minutes) * 60))
            let segment = TravelSegment(mode: .walking, span: span, distanceMeters: meters, confidence: .high, evidence: [], isConfirmed: false)
            let readings = (0...4).map { index -> SensorReading in
                var value = fix(from + minutes * Double(index) / 4, meters: meters * Double(index) / 4, accuracy: accuracy, motion: .walking)
                value.stepCount = steps * index / 4
                value.sourceDevice = .iPhone
                return value
            }
            return (segment, readings)
        }
        let outside = walk(0, minutes: 10, steps: 1_000, meters: 750, accuracy: 8)
        let outside2 = walk(20, minutes: 5, steps: 500, meters: 375, accuracy: 8)
        let inside = walk(40, minutes: 5, steps: 400, meters: 5, accuracy: 65)
        let travel = [outside.0, outside2.0, inside.0]
        let breakdown = WalkingDistanceBreakdown.make(travel: travel, readings: outside.1 + outside2.1 + inside.1)
        XCTAssertTrue(breakdown.isStrideCalibrated)
        XCTAssertEqual(breakdown.stride, 0.75, accuracy: 0.01)
        XCTAssertEqual(breakdown.parts[inside.0.id]?.gpsMeters, 0)
        XCTAssertEqual(breakdown.parts[inside.0.id]?.stepEstimatedMeters ?? 0, 300, accuracy: 5)
        XCTAssertEqual(breakdown.parts[outside.0.id]?.stepEstimatedMeters, 0)
        let notes = breakdown.annotating(travel)
        XCTAssertEqual(notes[0].distanceMeters, 750, "저장 거리는 바꾸지 않는다")
        XCTAssertTrue(notes[2].evidence.contains { $0.hasPrefix("걸음 추정") && $0.contains("재어 둔 보폭") })

        let uncalibrated = WalkingDistanceBreakdown.make(travel: [inside.0], readings: inside.1)
        XCTAssertFalse(uncalibrated.isStrideCalibrated)
        XCTAssertTrue(uncalibrated.annotating([inside.0])[0].evidence.contains { $0.contains("기본 보폭") })
    }
}
