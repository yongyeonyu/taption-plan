import CoreLocation
import XCTest
@testable import TaptionPlan

/// 지하철 탑승·환승·예상 경로 구간에서도 재생 중 화랑이가 늘 그려지고 환승에서 뒤로 튀지 않는다(PLY1108A01).
final class PlaybackRideVisibilityTests: XCTestCase {
    // MARK: - 원본 재생(TAPTION_RAW_REPLAY가 있을 때만)

    /// 초마다 구동기(카메라·화살표)와 화면(화랑이) 두 경로의 재생 위치를 구해, 화랑이가 빠지는 시각과 선로 위 뒤로 가기를 센다.
    /// 좌표는 찍지 않는다. `TAPTION_REPLAY_DAY`(MM-dd)로 날을, `TAPTION_REPLAY_FROM`·`TAPTION_REPLAY_TO`(HH:mm)로 시간을 고른다.
    func testReplayPlaybackVisibility() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["TAPTION_RAW_REPLAY"], !path.isEmpty else { throw XCTSkip("TAPTION_RAW_REPLAY 없음") }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let days = try (try? JSONDecoder().decode([TodaySensorRawExport].self, from: data))
            ?? [try JSONDecoder().decode(TodaySensorRawExport.self, from: data)]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul") ?? .current
        let formatter = DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MM-dd"
        let clock = DateFormatter()
        clock.timeZone = calendar.timeZone
        clock.dateFormat = "HH:mm:ss"
        func minute(_ text: String?) -> Double? {
            guard let parts = text?.split(separator: ":").compactMap({ Double($0) }), parts.count == 2 else { return nil }
            return parts[0] * 60 + parts[1]
        }
        let from = minute(environment["TAPTION_REPLAY_FROM"]) ?? 22 * 60 + 20
        let to = minute(environment["TAPTION_REPLAY_TO"]) ?? 23 * 60 + 10
        for day in days where environment["TAPTION_REPLAY_DAY"].map({ $0 == formatter.string(from: day.day) }) ?? true {
            let readings = day.readings.sorted { $0.timestamp < $1.timestamp }
            let travel = day.travel
            let places = day.places ?? []
            let dayStart = calendar.startOfDay(for: day.day)
            let projection = MapHomeWBSPlaybackProjection.make(selectedDate: day.day, places: places, travel: travel,
                readings: readings, actuals: day.actuals ?? [], calendar: calendar)
            let lookup = MapHomePlaybackLookup(readings: readings, travel: travel, places: places)
            let rides = travel.filter(SubwayRideTrack.isRide).sorted { $0.span.start < $1.span.start }
            let line = rides.first.flatMap { SubwayTrackLine(route: $0.subwayRoute) }
            var hidden: [String] = [], oldHidden: [String] = [], driverMissing = 0, backward: [String] = []
            var lastMeters: Double?, lastTrackDate: Date?
            var date = dayStart.addingTimeInterval(from * 60)
            let end = dayStart.addingTimeInterval(to * 60)
            while date <= end {
                let frame = projection.frame(at: date)
                let driver = MapHomePlaybackLocation.resolveOrGap(at: date, frame: frame, normalizedReadings: readings,
                    travel: travel, lookup: lookup)
                let screen = MapHomePlaybackLocation.resolveOrGap(at: date, frame: frame, normalizedReadings: readings,
                    travel: travel, places: places, calendar: calendar)
                let source = MapHomePlaybackLocation.subwayTransferCoordinate(at: date, travel: travel, readings: readings) != nil ? "transfer"
                    : MapHomePlaybackLocation.subwayCoordinate(at: date, travel: travel, readings: readings) != nil ? "track"
                    : frame != nil ? "frame"
                    : MapHomePlaybackLocation.sensorGapCoordinate(at: date, readings: readings) != nil ? "gap" : "place"
                if driver == nil { driverMissing += 1 }
                let drawn = screen.flatMap { MapHomePlaybackLocation.drawableCoordinate($0.coordinate) }
                if drawn == nil { hidden.append(clock.string(from: date)) }
                // 예전 화면 검사: 정확도가 0 이상이어야 했다.
                if screen.map({ $0.coordinate.horizontalAccuracy < 0 }) ?? true { oldHidden.append(clock.string(from: date)) }
                var trackText = "-"
                if let line, let point = driver?.coordinate {
                    let found = line.position(of: point)
                    trackText = "\(Int(found.meters))m off=\(Int(found.offset))"
                    let inJourney = rides.contains { $0.span.start <= date }
                        && date <= (rides.last?.span.end ?? .distantPast)
                    if inJourney, found.offset <= 50 {
                        if let lastMeters, let lastTrackDate, found.meters < lastMeters - 30 {
                            backward.append("\(clock.string(from: lastTrackDate))→\(clock.string(from: date)) \(Int(lastMeters - found.meters))m")
                        }
                        lastMeters = max(lastMeters ?? 0, found.meters)
                        lastTrackDate = date
                    }
                }
                if Int(date.timeIntervalSince(dayStart)) % 60 == 0 {
                    print("PLAY \(clock.string(from: date)) src=\(source) acc=\(screen.map { Int($0.coordinate.horizontalAccuracy) } ?? -999) "
                        + "screen=\(drawn == nil ? "HIDDEN" : "ok") old=\(screen.map { $0.coordinate.horizontalAccuracy < 0 } ?? true ? "HIDDEN" : "ok") driver=\(driver == nil ? "nil" : "ok") track=\(trackText)")
                }
                date = date.addingTimeInterval(1)
            }
            print("PLAY summary day=\(formatter.string(from: day.day)) oldHiddenSeconds=\(oldHidden.count) oldFirst=\(oldHidden.first ?? "-") oldLast=\(oldHidden.last ?? "-") hiddenSeconds=\(hidden.count) first=\(hidden.first ?? "-") last=\(hidden.last ?? "-") "
                + "driverNil=\(driverMissing) backward=\(backward.count) \(backward.prefix(5).joined(separator: ", "))")
        }
    }

    // MARK: - 합성: 걷기 → 탑승 → 환승 걷기 → 탑승(같은 노선, 지하라 GPS 없음) → 걷기

    private struct Fixture {
        let track: [GeoPoint]
        let first: TravelSegment
        let transfer: TravelSegment
        let second: TravelSegment
        let readings: [SensorReading]
        var travel: [TravelSegment] { [first, transfer, second] }
        var transferPoint: GeoPoint
    }

    /// 환승역에서만 GPS가 한 번 잡힌다. 두 조각은 노선 전체를 함께 가진다(`RailJourneyRecognizer.applying`과 같다).
    private func fixture() throws -> Fixture {
        let route = try XCTUnwrap(SubwayStationCatalog.route(for: ["가정역", "마곡나루역"]))
        XCTAssertGreaterThanOrEqual(route.coordinates.count, 3)
        let start = date(420)
        func ride(_ from: Double, _ to: Double) -> TravelSegment {
            TravelSegment(mode: .subway, span: TimeSpan(start: start.addingTimeInterval(from), end: start.addingTimeInterval(to)),
                distanceMeters: 1_000, confidence: .high, evidence: ["지하철 노선 후보 확정"], isConfirmed: false, subwayRoute: route)
        }
        let first = ride(0, 600), second = ride(840, 2400)
        let transfer = TravelSegment(mode: .walking, span: TimeSpan(start: first.span.end, end: second.span.start),
            distanceMeters: 200, confidence: .high, evidence: [], isConfirmed: false)
        let origin = try XCTUnwrap(route.coordinates.first), last = try XCTUnwrap(route.coordinates.last)
        let middle = route.coordinates[route.coordinates.count / 2]
        var readings = stride(from: -120.0, through: 0, by: 30).map { reading(start.addingTimeInterval($0), origin) }
        readings.append(reading(start.addingTimeInterval(780), middle))
        readings += stride(from: 2400.0, through: 2700, by: 30).map { reading(start.addingTimeInterval($0), last) }
        return Fixture(track: SubwayRideTrack.coordinates(of: route), first: first, transfer: transfer, second: second,
                       readings: readings.sorted { $0.timestamp < $1.timestamp }, transferPoint: middle)
    }

    /// 선로 위 재생 좌표는 정확도 -1(계산한 자리)이다. 화면은 이 좌표를 버리지 않아야 화랑이가 보인다.
    /// 예전 화면 검사(정확도 0 이상)는 11-05 원본에서 탑승 1,145초 내내 화랑이를 숨겼다.
    func testTrackPositionWithUnknownAccuracyIsDrawn() throws {
        let value = try fixture()
        let inside = value.second.span.start.addingTimeInterval(300)
        let location = try XCTUnwrap(MapHomePlaybackLocation.resolveOrGap(at: inside, frame: nil,
            normalizedReadings: value.readings, travel: value.travel, places: [], calendar: calendar))
        XCTAssertLessThan(location.coordinate.horizontalAccuracy, 0, "선로 좌표는 측정값이 아니다")
        XCTAssertNotNil(MapHomePlaybackLocation.drawableCoordinate(location.coordinate))
        // 예상 경로 좌표(`wbsGeoPoint`)도 정확도 -1이다.
        let expected = GeoPoint(latitude: 37.5, longitude: 126.8, altitude: 0, horizontalAccuracy: -1, verticalAccuracy: -1)
        let lonely = try XCTUnwrap(MapHomePlaybackLocation.resolveOrGap(at: date(1200), frame: nil,
            normalizedReadings: [], travel: [], places: [], expectedCoordinate: expected, calendar: calendar))
        XCTAssertNotNil(MapHomePlaybackLocation.drawableCoordinate(lonely.coordinate))
        // 위경도가 망가진 좌표만 버린다.
        for broken in [GeoPoint(latitude: .nan, longitude: 126.8, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5),
                       GeoPoint(latitude: 91, longitude: 126.8, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5)] {
            XCTAssertNil(MapHomePlaybackLocation.drawableCoordinate(broken))
        }
    }

    /// 탑승·환승 걷기·다음 탑승 내내 화랑이 자리가 있고, 선로 위에 있으며, 선로를 따라 뒤로 가지 않는다.
    /// 예전에는 환승 걷기에서 탑승 전 GPS와 환승역 GPS를 이은 직선을 따라가 내린 자리보다 노선 뒤쪽으로 튀었다.
    func testTransferWalkContinuesFromExitWithoutJumpingBack() throws {
        let value = try fixture()
        let line = try XCTUnwrap(SubwayTrackLine(points: value.track))
        let projection = MapHomeWBSPlaybackProjection.make(selectedDate: date(0), places: [], travel: value.travel,
            readings: value.readings, calendar: calendar)
        let lookup = MapHomePlaybackLookup(readings: value.readings, travel: value.travel, places: [])
        var last = -Double.infinity
        var date = value.first.span.start
        while date <= value.second.span.end {
            let frame = projection.frame(at: date)
            let driver = try XCTUnwrap(MapHomePlaybackLocation.resolveOrGap(at: date, frame: frame,
                normalizedReadings: value.readings, travel: value.travel, lookup: lookup), "\(date)")
            let screen = try XCTUnwrap(MapHomePlaybackLocation.resolveOrGap(at: date, frame: frame,
                normalizedReadings: value.readings, travel: value.travel, places: [], calendar: calendar), "\(date)")
            XCTAssertNotNil(MapHomePlaybackLocation.drawableCoordinate(screen.coordinate), "\(date)")
            XCTAssertLessThan(PlanarDistance.meters(driver.coordinate, screen.coordinate), 1, "구동기와 화면이 같은 자리")
            let found = line.position(of: driver.coordinate)
            XCTAssertLessThan(found.offset, 5, "선로 위 \(date)")
            XCTAssertGreaterThanOrEqual(found.meters, last - 1, "뒤로 가지 않음 \(date)")
            last = max(last, found.meters)
            date = date.addingTimeInterval(5)
        }
        // 환승 걷기 동안은 환승역에 머문다.
        let walking = value.transfer.span.start.addingTimeInterval(60)
        let held = try XCTUnwrap(MapHomePlaybackLocation.subwayTransferCoordinate(at: walking, travel: value.travel, readings: value.readings))
        XCTAssertLessThan(PlanarDistance.meters(held, value.transferPoint), 5)
        // 20분 넘게 떨어진 두 탑승 사이는 환승이 아니다.
        var later = value.second
        later.span = TimeSpan(start: value.first.span.end.addingTimeInterval(SubwayRideTrack.maximumJourneyGap + 60),
                              end: value.first.span.end.addingTimeInterval(SubwayRideTrack.maximumJourneyGap + 600))
        XCTAssertNil(MapHomePlaybackLocation.subwayTransferCoordinate(at: walking, travel: [value.first, later], readings: value.readings))
    }

    // MARK: - 도움 함수

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func date(_ minute: Int) -> Date {
        calendar.startOfDay(for: Date(timeIntervalSince1970: 1_755_206_400)).addingTimeInterval(Double(minute) * 60)
    }

    private func reading(_ timestamp: Date, _ point: GeoPoint) -> SensorReading {
        var value = SensorReading(timestamp: timestamp, point: GeoPoint(latitude: point.latitude, longitude: point.longitude,
            altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10), motion: .walking)
        value.gpsAvailable = true
        return value
    }
}
