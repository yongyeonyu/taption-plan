import CoreLocation
import XCTest
@testable import TaptionPlan

/// 선로 모양이 있는 지하철 탑승은 그리기·재생·거리를 모두 선로 위에서 정한다(SUB1108A01).
final class SubwayRideTrackTests: XCTestCase {
    // MARK: - 원본 재생(TAPTION_RAW_REPLAY가 있을 때만)

    /// 내보낸 원본 하루의 탑승마다 선 조각·회색 발자국·재생 위치가 선로에서 얼마나 떨어졌는지, 거리가 얼마인지 찍는다.
    /// 좌표는 찍지 않는다. `TAPTION_REPLAY_DAY`(MM-dd)로 날을 고른다.
    func testReplayRideGeometry() throws {
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
        for day in days where environment["TAPTION_REPLAY_DAY"].map({ $0 == formatter.string(from: day.day) }) ?? true {
            let readings = day.readings.sorted { $0.timestamp < $1.timestamp }
            let travel = day.travel
            let places = day.places ?? []
            let dayStart = calendar.startOfDay(for: day.day)
            let span = TimeSpan(start: dayStart, end: dayStart.addingTimeInterval(86_400))
            let overlays = MapHomeSubwayRouteOverlayEngine.overlays(travel: travel, readings: readings, day: span, through: span.end)
            let plan = MapHomeUnconfirmedPaws.plan(predicted: [], confirmed: [], decidedTravelIDs: [], travel: travel)
            let paws = MapHomeUnconfirmedPaws.subwayGapPoints(travel: plan.gapTravel, readings: readings, through: span.end, limit: 400)
            let gpsGaps = MapHomeGPSGapPredictionPolicy.predictedGaps(from: readings, calendar: calendar)
            let projection = MapHomeWBSPlaybackProjection.make(selectedDate: day.day, places: places, travel: travel,
                readings: readings, actuals: day.actuals ?? [], calendar: calendar)
            let lookup = MapHomePlaybackLookup(readings: readings, travel: travel, places: places)
            let counted = MapHomeCounterTimelinePolicy.travelMeters(segments: travel, cutoff: nil, day: span)
            print("RIDE day \(formatter.string(from: day.day)) travel=\(travel.count) overlays=\(overlays.count) grayPaws=\(paws.count) dayMeters=\(Int(counted))")
            for ride in travel.sorted(by: { $0.span.start < $1.span.start })
            where ride.mode == .subway || ride.mode == .train {
                guard let route = ride.subwayRoute, SubwayStationCatalog.isValid(route) else {
                    print("RIDE \(clock.string(from: ride.span.start))–\(clock.string(from: ride.span.end)) \(ride.mode.rawValue) 노선 없음 stored=\(Int(ride.distanceMeters))")
                    continue
                }
                let track = SubwayTrackCatalog.following(route.coordinates)
                let rideOverlays = overlays.filter { $0.travelID == ride.id }
                let overlayOff = rideOverlays.flatMap(\.coordinates).map { offTrack(geo($0), track) }.max() ?? 0
                let rideOverlayMeters = rideOverlays.map { length($0.coordinates.map(geo)) }.reduce(0, +)
                let ridePaws = paws.filter { $0.travelID == ride.id }
                let pawOff = ridePaws.map { offTrack(geo($0.coordinate), track) }.max() ?? 0
                let gapsInside = gpsGaps.filter { ride.span.intersection(with: TimeSpan(start: $0.start.timestamp, end: $0.end.timestamp)) != nil }
                var offsets: [Double] = []
                var date = ride.span.start
                while date < ride.span.end {
                    let frame = projection.frame(at: date)
                    if let location = MapHomePlaybackLocation.resolveOrGap(at: date, frame: frame,
                        normalizedReadings: readings, travel: travel, lookup: lookup) {
                        offsets.append(offTrack(location.coordinate, track))
                    }
                    date = date.addingTimeInterval(15)
                }
                let mean = offsets.isEmpty ? 0 : offsets.reduce(0, +) / Double(offsets.count)
                print("RIDE \(clock.string(from: ride.span.start))–\(clock.string(from: ride.span.end)) \(ride.mode.rawValue) "
                    + "stations=\(route.coordinates.count) chord=\(Int(length(route.coordinates))) track=\(Int(length(track))) "
                    + "stored=\(Int(ride.distanceMeters)) overlays=\(rideOverlays.count) overlayMeters=\(Int(rideOverlayMeters)) overlayOffMax=\(Int(overlayOff)) "
                    + "grayPaws=\(ridePaws.count) pawOffMax=\(Int(pawOff)) gpsGapRoutes=\(gapsInside.count) "
                    + "playback=\(offsets.count) offMean=\(Int(mean)) offMax=\(Int(offsets.max() ?? 0)) over50m=\(offsets.filter { $0 > 50 }.count)")
            }
            for entry in MapHomeDayTravelSummary.entries(from: travel) {
                print("RIDE summary \(entry.mode.rawValue)=\(Int(entry.meters))")
            }
        }
    }

    // MARK: - 합성: 걷기 → GPS 끊긴 지하철 탑승(선로 좌표) → 걷기

    private struct Fixture {
        let route: SubwayRoutePath
        let track: [GeoPoint]
        let ride: TravelSegment
        let walkBefore: TravelSegment
        let walkAfter: TravelSegment
        let readings: [SensorReading]
        var travel: [TravelSegment] { [walkBefore, ride, walkAfter] }
    }

    /// 탑승 안에는 출발역 바로 뒤와 다음 역 앞에만 GPS가 있다(지하). 둘 사이는 2분이라 예전에는 직선 재생 프레임이 생겼다.
    private func fixture() throws -> Fixture {
        let route = try XCTUnwrap(SubwayStationCatalog.route(for: ["가정역", "마곡나루역"]))
        let track = SubwayRideTrack.coordinates(of: route)
        let start = date(420)
        let ride = TravelSegment(mode: .subway, span: TimeSpan(start: start, end: start.addingTimeInterval(30 * 60)),
            distanceMeters: 99_999, confidence: .high, evidence: ["지하철 노선 후보 확정"], isConfirmed: false, subwayRoute: route)
        let first = try XCTUnwrap(route.coordinates.first), last = try XCTUnwrap(route.coordinates.last)
        func shifted(_ point: GeoPoint, _ meters: Double) -> GeoPoint {
            GeoPoint(latitude: point.latitude + meters / 111_320, longitude: point.longitude, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10)
        }
        let walkBefore = TravelSegment(mode: .walking, span: TimeSpan(start: start.addingTimeInterval(-300), end: start),
            distanceMeters: 300, confidence: .high, evidence: [], isConfirmed: false)
        let walkAfter = TravelSegment(mode: .walking, span: TimeSpan(start: ride.span.end, end: ride.span.end.addingTimeInterval(300)),
            distanceMeters: 300, confidence: .high, evidence: [], isConfirmed: false)
        var readings = stride(from: -300.0, through: 0, by: 30).map { reading(start.addingTimeInterval($0), shifted(first, -$0)) }
        // 두 번째 역 근처 표본: 선로 위 첫 역 다음 역.
        let second = route.coordinates[1]
        readings.append(reading(start.addingTimeInterval(60), first))
        readings.append(reading(start.addingTimeInterval(180), second))
        readings += stride(from: 1800.0, through: 2100, by: 30).map { reading(start.addingTimeInterval($0), shifted(last, 3 * ($0 - 1800))) }
        return Fixture(route: route, track: track, ride: ride, walkBefore: walkBefore, walkAfter: walkAfter,
                       readings: readings.sorted { $0.timestamp < $1.timestamp })
    }

    func testFixtureTrackBendsAwayFromStationChords() throws {
        let value = try fixture()
        XCTAssertGreaterThan(value.track.count, value.route.coordinates.count, "선로 자료가 있어야 시험이 뜻이 있다")
        let chordOff = value.track.map { offTrack($0, value.route.coordinates) }.max() ?? 0
        XCTAssertGreaterThan(chordOff, 50, "역 직선과 선로가 50m 넘게 벌어지는 노선")
    }

    /// 탑승 안 GPS 공백의 회색 발자국·선 조각은 선로 위에만 놓이고, 공백 직선(gps-gap)은 찍지 않는다.
    func testGapUnderRideIsDrawnOnlyOnTrack() throws {
        let value = try fixture()
        let day = TimeSpan(start: date(0), end: date(1440))
        let overlays = MapHomeSubwayRouteOverlayEngine.overlays(travel: value.travel, readings: value.readings, day: day, through: day.end)
        XCTAssertFalse(overlays.isEmpty)
        for overlay in overlays {
            XCTAssertLessThan(overlay.coordinates.map { offTrack(geo($0), value.track) }.max() ?? .infinity, 5)
        }
        let paws = MapHomeUnconfirmedPaws.subwayGapPoints(travel: [value.ride], readings: value.readings, through: day.end, limit: 200)
        XCTAssertFalse(paws.isEmpty)
        XCTAssertLessThan(paws.map { offTrack(geo($0.coordinate), value.track) }.max() ?? .infinity, 5,
                          "회색 발자국이 역 직선이 아니라 선로 위에 있다")
        let inside = MapPredictedRoute(source: "gps-gap", travelID: nil, mode: .walking,
            span: TimeSpan(start: value.ride.span.start.addingTimeInterval(60), end: value.ride.span.start.addingTimeInterval(180)),
            coordinates: [value.route.coordinates[0], value.route.coordinates[1]])
        let plan = MapHomeUnconfirmedPaws.plan(predicted: [inside], confirmed: [], decidedTravelIDs: [], travel: value.travel)
        XCTAssertTrue(plan.predicted.isEmpty, "탑승 안의 공백 직선은 미확인 경로로 그리지 않는다")
    }

    /// 탑승 밖의 진짜 GPS 공백은 전처럼 그리고, 걷기 거리도 그대로 센다.
    func testRealGapOutsideRideIsStillDrawnAndCounted() throws {
        let value = try fixture()
        let outside = MapPredictedRoute(source: "gps-gap", travelID: nil, mode: .walking,
            span: TimeSpan(start: value.walkAfter.span.start.addingTimeInterval(60), end: value.walkAfter.span.start.addingTimeInterval(180)),
            coordinates: [value.route.coordinates[0], value.route.coordinates[1]])
        let plan = MapHomeUnconfirmedPaws.plan(predicted: [outside], confirmed: [], decidedTravelIDs: [], travel: value.travel)
        XCTAssertEqual(plan.predicted, [outside])
        let walk = TravelSegment(mode: .walking, span: TimeSpan(start: date(600), end: date(610)),
            distanceMeters: 640, confidence: .high, evidence: [], isConfirmed: false)
        XCTAssertEqual(SubwayRideTrack.applyingTrackDistance([walk]), [walk])
        XCTAssertEqual(MapHomeDayTravelSummary.entries(from: [walk]).first?.meters, 640)
        // 탑승 밖 공백 재생은 앞뒤 표본 사이 직선 그대로다.
        let a = GeoPoint(latitude: 37.5, longitude: 127, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10)
        let b = GeoPoint(latitude: 37.51, longitude: 127, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10)
        let gap = [reading(date(600), a), reading(date(610), b)]
        let middle = try XCTUnwrap(MapHomePlaybackLocation.resolveOrGap(at: date(605), frame: nil,
            normalizedReadings: gap, travel: [walk], places: [], calendar: calendar))
        XCTAssertEqual(middle.coordinate.latitude, 37.505, accuracy: 0.0001)
    }

    /// 재생 위치는 탑승 내내 선로 위다. GPS 두 점을 잇는 직선 프레임이 있어도 선로가 먼저다.
    func testPlaybackFollowsTrackDuringRide() throws {
        let value = try fixture()
        let projection = MapHomeWBSPlaybackProjection.make(selectedDate: date(0), places: [], travel: value.travel,
            readings: value.readings, calendar: calendar)
        XCTAssertNotNil(projection.frame(at: value.ride.span.start.addingTimeInterval(120)), "예전 직선 프레임이 있는 시각")
        let lookup = MapHomePlaybackLookup(readings: value.readings, travel: value.travel, places: [])
        var date = value.ride.span.start.addingTimeInterval(1)
        var checked = 0
        while date < value.ride.span.end {
            let location = try XCTUnwrap(MapHomePlaybackLocation.resolveOrGap(at: date, frame: projection.frame(at: date),
                normalizedReadings: value.readings, travel: value.travel, lookup: lookup))
            XCTAssertLessThan(offTrack(location.coordinate, value.track), 5, "\(date)")
            checked += 1
            date = date.addingTimeInterval(20)
        }
        XCTAssertGreaterThan(checked, 80)
        // 내린 뒤 걷기는 GPS 그대로다.
        let after = value.ride.span.end.addingTimeInterval(150)
        let walk = try XCTUnwrap(MapHomePlaybackLocation.resolveOrGap(at: after, frame: projection.frame(at: after),
            normalizedReadings: value.readings, travel: value.travel, lookup: lookup))
        XCTAssertGreaterThan(offTrack(walk.coordinate, value.track), 100)
    }

    /// 탑승 거리는 선로 길이다. 환승으로 나뉜 조각은 합이 선로 길이고, 걷기는 그대로다.
    func testRideDistanceEqualsTrackLength() throws {
        let value = try fixture()
        let trackMeters = SubwayRideTrack.length(value.track)
        XCTAssertGreaterThan(trackMeters, SubwayRideTrack.length(value.route.coordinates))
        let fixed = SubwayRideTrack.applyingTrackDistance(value.travel)
        XCTAssertEqual(fixed.first { $0.id == value.ride.id }?.distanceMeters ?? 0, trackMeters, accuracy: 0.5)
        XCTAssertEqual(fixed.filter { $0.mode == .walking }.map(\.distanceMeters), [300, 300])
        let summary = Dictionary(uniqueKeysWithValues: MapHomeDayTravelSummary.entries(from: value.travel).map { ($0.mode, $0.meters) })
        XCTAssertEqual(summary[.subway] ?? 0, trackMeters, accuracy: 0.5)
        let day = TimeSpan(start: date(0), end: date(1440))
        XCTAssertEqual(MapHomeCounterTimelinePolicy.travelMeters(segments: value.travel, cutoff: nil, day: day),
                       trackMeters + 600, accuracy: 1)
        // 지나는 중에는 지난 시간만큼만 센다.
        let half = value.ride.span.start.addingTimeInterval(15 * 60)
        XCTAssertEqual(MapHomeCounterTimelinePolicy.travelMeters(segments: [value.ride], cutoff: half, day: day),
                       trackMeters / 2, accuracy: 1)
        // 환승 걷기로 나뉜 두 조각(같은 노선)은 합이 선로 길이다.
        var first = value.ride
        first.span = TimeSpan(start: value.ride.span.start, end: value.ride.span.start.addingTimeInterval(600))
        var second = value.ride
        second.id = UUID()
        second.span = TimeSpan(start: first.span.end.addingTimeInterval(240), end: first.span.end.addingTimeInterval(240 + 1800))
        let split = SubwayRideTrack.applyingTrackDistance([first, second])
        XCTAssertEqual(split.reduce(0) { $0 + $1.distanceMeters }, trackMeters, accuracy: 0.5)
        // 사용자가 확인한 탑승도 같다.
        var boarded = value.ride
        boarded.isConfirmed = true
        XCTAssertEqual(SubwayRideTrack.applyingTrackDistance([boarded])[0].distanceMeters, trackMeters, accuracy: 0.5)
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
            altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10), motion: .automotive)
        value.gpsAvailable = true
        return value
    }

    private func geo(_ coordinate: CLLocationCoordinate2D) -> GeoPoint {
        GeoPoint(latitude: coordinate.latitude, longitude: coordinate.longitude, altitude: 0, horizontalAccuracy: -1, verticalAccuracy: -1)
    }

    private func length(_ points: [GeoPoint]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + PlanarDistance.meters($1.0, $1.1) }
    }

    private func offTrack(_ point: GeoPoint, _ track: [GeoPoint]) -> Double {
        zip(track, track.dropFirst()).map { PlanarDistance.segmentMeters(point, $0.0, $0.1) }.min() ?? .infinity
    }
}
