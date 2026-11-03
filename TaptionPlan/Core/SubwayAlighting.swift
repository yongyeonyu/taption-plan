import Foundation

/// 지하철 하차 시각을 정한다(PLY1103A01, 대표 규칙).
/// 탑승 구간은 다음 체류까지 이어지기 쉬워 회사 앞까지 열차가 따라온다. 마지막 차량 표본 뒤로 걷기가 3분 넘게 이어지면
/// 걷기를 시작한 시각이 하차다. 뒤에 차량 표본이 또 있는 걷기는 환승이라 자르지 않는다.
enum SubwayAlighting {
    static let minimumWalk: TimeInterval = 180
    private static let minimumVehicleSpeed = 5.0
    private static let alightingStationRadius = 500.0
    private static let trustedAccuracy = 150.0

    static func applying(
        _ segments: [TravelSegment],
        readings: [SensorReading],
        corrections: [TravelModeCorrection]
    ) -> [TravelSegment] {
        var result = segments
        for index in segments.indices where segments[index].mode == .subway {
            let segment = segments[index]
            guard !segment.isConfirmed,
                  !segment.evidence.contains(where: { $0.hasPrefix("사용자 확인") }),
                  !corrections.contains(where: { $0.span.overlapsMostly(segment.span) }),
                  let start = alightingStart(of: segment, readings: readings) else { continue }
            let walk = TimeSpan(start: start, end: segment.span.end)
            result.removeAll { $0.mode == .walking && !$0.isConfirmed && walk.contains($0.span.start) && $0.span.end <= walk.end }
            guard let position = result.firstIndex(where: { $0.id == segment.id }) else { continue }
            let share = walk.duration / max(1, segment.span.duration)
            result[position].span = TimeSpan(start: segment.span.start, end: start)
            result[position].distanceMeters = segment.distanceMeters * (1 - share)
            result[position].toPlaceID = nil
            if let route = extendedRoute(segment.subwayRoute, walk: walk, readings: readings) {
                result[position].subwayRoute = route
            }
            var walking = TravelSegment(
                mode: .walking, span: walk, distanceMeters: segment.distanceMeters * share,
                confidence: .high, evidence: ["지하철 하차 뒤 걷기"], isConfirmed: false
            )
            walking.toPlaceID = segment.toPlaceID
            result.append(walking)
        }
        return result.sorted { $0.span.start < $1.span.start }
    }

    static func alightingStart(of segment: TravelSegment, readings: [SensorReading]) -> Date? {
        let inside = readings.filter { segment.span.contains($0.timestamp) }.sorted { $0.timestamp < $1.timestamp }
        guard let lastVehicle = inside.lastIndex(where: isVehicle),
              let first = inside[(lastVehicle + 1)...].first(where: { $0.motion == .walking }),
              let last = inside.last(where: { $0.motion == .walking }),
              last.timestamp.timeIntervalSince(first.timestamp) >= minimumWalk else { return nil }
        return first.timestamp
    }

    private static func isVehicle(_ reading: SensorReading) -> Bool {
        if reading.motion == .automotive { return true }
        return reading.motion != .walking && reading.motion != .running
            && reading.gpsAvailable && (reading.speedMetersPerSecond ?? 0) >= minimumVehicleSpeed
    }

    /// 노선이 앞 역에서 끝났으면 걷기 시작점에 가까운 역까지 잇는다. 그래야 그 사이 열차가 멈춰 있지 않는다.
    private static func extendedRoute(_ route: SubwayRoutePath?, walk: TimeSpan, readings: [SensorReading]) -> SubwayRoutePath? {
        guard let route,
              let point = readings.first(where: {
                  walk.contains($0.timestamp) && ($0.point?.horizontalAccuracy ?? .infinity) <= trustedAccuracy
              })?.point,
              let station = SubwayStationCatalog.nearest(to: point, maximumDistanceMeters: alightingStationRadius),
              route.stops.last?.stationName != station.stationName else { return nil }
        var names = route.stops.map(\.stationName)
        names.removeAll { $0 == station.stationName }
        guard let extended = SubwayStationCatalog.route(for: names + [station.stationName]),
              SubwayStationCatalog.isValid(extended) else { return nil }
        return extended
    }
}
