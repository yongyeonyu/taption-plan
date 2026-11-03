import XCTest
@testable import TaptionPlan

/// 탑승 전체 판정의 음성·양성 합성 시험(ALG1102A01). 좌표는 공개 역 카탈로그 값만 쓴다.
final class RailRideLikelihoodTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func stops() throws -> [SubwayRouteStop] {
        let route = try XCTUnwrap(SubwayStationCatalog.route(for: ["마곡나루", "검암"]))
        let stops = route.stops
        XCTAssertGreaterThanOrEqual(stops.count, 3)
        return stops
    }

    private func reading(
        _ latitude: Double, _ longitude: Double, minute: Double, speed: Double?,
        motion: MotionKind = .automotive, kPa: Double? = nil, fix: Bool = true, car: String? = nil
    ) -> SensorReading {
        var value = SensorReading(
            timestamp: start.addingTimeInterval(minute * 60),
            point: GeoPoint(latitude: latitude, longitude: longitude, altitude: 10, horizontalAccuracy: fix ? 10 : 500, verticalAccuracy: 5),
            motion: motion
        )
        value.speedMetersPerSecond = speed
        value.gpsAvailable = fix
        value.pressureKilopascals = kPa
        value.carAudioRouteName = car
        return value
    }

    /// 역과 역 사이를 15초 간격으로 달리는 표본. `redLights`는 (구간 안 비율, 멈춘 초)다.
    private func drive(
        stops: [SubwayRouteStop], minutesPerLeg: Double, startMinute: Double,
        stopAtStations: Bool, redLights: [Int: (fraction: Double, seconds: Double)] = [:], car: String? = nil
    ) -> [SensorReading] {
        var result: [SensorReading] = []
        var minute = startMinute
        for (index, pair) in zip(stops, stops.dropFirst()).enumerated() {
            let (a, b) = (pair.0, pair.1)
            guard let la = a.latitude, let loa = a.longitude, let lb = b.latitude, let lob = b.longitude else { continue }
            let count = Int(minutesPerLeg * 4)
            for step in 0..<count {
                let fraction = Double(step) / Double(count)
                let lat = la + (lb - la) * fraction, lng = loa + (lob - loa) * fraction
                if let light = redLights[index], abs(fraction - light.fraction) < 0.5 / Double(count) {
                    let pauses = Int(light.seconds / 15)
                    for pause in 0...pauses {
                        result.append(reading(lat, lng, minute: minute + Double(pause) * 0.25, speed: 0.3, car: car))
                    }
                    minute += Double(pauses + 1) * 0.25
                }
                result.append(reading(lat, lng, minute: minute, speed: 14, car: car))
                minute += 0.25
            }
            if stopAtStations, index < stops.count - 2 {
                for pause in 0...3 {
                    result.append(reading(lb, lob, minute: minute + Double(pause) * 0.25, speed: 0.5, car: car))
                }
                minute += 1
            }
        }
        if let last = stops.last, let la = last.latitude, let lo = last.longitude {
            result.append(reading(la, lo, minute: minute, speed: 1, car: car))
            result.append(reading(la, lo, minute: minute + 6, speed: 0.5, car: car))
        }
        return result
    }

    private func dwellAtBoarding(_ stop: SubwayRouteStop, minutes: Double) -> [SensorReading] {
        guard let lat = stop.latitude, let lng = stop.longitude else { return [] }
        return [
            reading(lat, lng, minute: -minutes, speed: 0.5),
            reading(lat, lng, minute: -minutes / 2, speed: 0.5),
            reading(lat, lng, minute: -0.25, speed: 0.5),
        ]
    }

    /// 빨간불마다 역 사이에 멈추는 차는 역에도 멈추고 탑승역에 오래 있어도 지하철이 아니다.
    func testCarWithRedLightsBesideTheLineIsNotRail() throws {
        let stops = try stops()
        let readings = dwellAtBoarding(stops[0], minutes: 6)
            + drive(stops: stops, minutesPerLeg: 4, startMinute: 0, stopAtStations: true,
                    redLights: [0: (0.5, 60), 1: (0.5, 45)])
        XCTAssertTrue(RailJourneyRecognizer.journeys(readings: readings).isEmpty)
    }

    /// 역을 멈추지 않고 지나며 GPS도 끊기지 않는 차는 지하철이 아니다.
    func testContinuousCarPassingStationsIsNotRail() throws {
        let stops = try stops()
        let readings = dwellAtBoarding(stops[0], minutes: 6)
            + drive(stops: stops, minutesPerLeg: 4, startMinute: 0, stopAtStations: false)
        XCTAssertTrue(RailJourneyRecognizer.journeys(readings: readings).isEmpty)
    }

    /// 차량 오디오는 1순위다. 나머지가 모두 철도로 보여도, 일부 구간만 연결돼도 막는다.
    func testCarAudioBeforeTheRideVetoesRail() throws {
        let stops = try stops()
        // 걸어서 탑승역에 와 기다린 뒤 역마다 선다.
        let platform = reading(stops[0].latitude!, stops[0].longitude!, minute: -7, speed: 1.2, motion: .walking)
        var rail = [platform] + dwellAtBoarding(stops[0], minutes: 6)
            + drive(stops: stops, minutesPerLeg: 4, startMinute: 0, stopAtStations: true)
        XCTAssertFalse(RailJourneyRecognizer.journeys(readings: rail).isEmpty, "오디오 없는 같은 경로는 철도여야 한다: \(RailJourneyRecognizer.rejections(readings: rail))")
        rail[2].carAudioRouteName = "내 차"
        XCTAssertTrue(RailJourneyRecognizer.journeys(readings: rail).isEmpty)
    }

    /// 역마다 서고 탑승역까지 걸어온 탑승은 차량 근거가 없으면 철도다.
    func testAlignedStationStopsScoreAsRail() throws {
        let stops = try stops()
        let ride = drive(stops: stops, minutesPerLeg: 4, startMinute: 0, stopAtStations: true)
        let walk = [reading(stops[0].latitude!, stops[0].longitude!, minute: -3, speed: 1.2, motion: .walking, kPa: 102.40),
                    reading(stops[0].latitude!, stops[0].longitude!, minute: -1, speed: 1.0, motion: .walking, kPa: 102.20)]
        let result = RailRideLikelihood.assess(
            route: try XCTUnwrap(SubwayStationCatalog.route(for: ["마곡나루", "검암"])),
            boarding: start, alighting: ride.last!.timestamp, boardingDwell: 0, readings: walk + ride
        )
        XCTAssertEqual(result.stopsAtStations, stops.count - 2)
        XCTAssertEqual(result.stopsBetweenStations, 0)
        XCTAssertGreaterThan(result.logLikelihoodRatio, RailRideLikelihood.minimumLogLikelihoodRatio)
        XCTAssertTrue(result.evidence.contains("탑승역 수직 이동"))
    }

    /// 지하 구간처럼 GPS가 끊긴 시간은 역 사이 정차로 세지 않는다.
    func testSilentUndergroundLegHasNoBetweenStationStops() throws {
        let stops = try stops()
        let a = stops[0], b = stops[1]
        let ride = [
            reading(a.latitude!, a.longitude!, minute: 0, speed: 1),
            reading(a.latitude!, a.longitude!, minute: 1, speed: nil, fix: false),
            reading(a.latitude!, a.longitude!, minute: 3, speed: nil, fix: false),
            reading(b.latitude!, b.longitude!, minute: 5, speed: 1),
        ]
        let result = RailRideLikelihood.assess(
            route: try XCTUnwrap(SubwayStationCatalog.route(for: [a.stationName, b.stationName])),
            boarding: start, alighting: ride.last!.timestamp, boardingDwell: 0, readings: ride
        )
        XCTAssertEqual(result.stopsBetweenStations, 0)
        XCTAssertGreaterThan(result.gpsLossShare, 0.5)
    }
}
