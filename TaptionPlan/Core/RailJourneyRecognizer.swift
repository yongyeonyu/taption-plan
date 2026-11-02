import Foundation

/// 지하철 탑승을 하루 원본 전체에서 찾는다(SUB1102A01).
///
/// 행동 구간은 모션이 바뀔 때마다 1~5분 조각으로 나뉘어, 조각마다 조건을 보면 역이 두 개 잡힐 수 없다.
/// 그래서 "역 → 역" 이동을 먼저 찾아 잇고, 이어진 탑승 전체를 `SubwayEvidenceGate`로 판정한다.
/// 아직 내리지 않은 탑승은 하차역 조건을 잴 수 없으니 막지 않는다.
enum RailJourneyRecognizer {
    struct Journey: Equatable, Sendable {
        var span: TimeSpan
        var route: SubwayRoutePath
        var stationNames: [String]
    }

    static let stationRadiusMeters = SubwayEvidenceGate.stationRadiusMeters
    private static let maximumAccuracyMeters = 100.0
    /// 역과 역 사이가 이보다 느리면 타고 간 것이 아니다(승강장 대기는 앞 역에 남아 있어 빠진다).
    private static let minimumRideSpeed = 3.0
    private static let maximumRideSpeed = 45.0
    /// 역 사이 표본이 노선에서 이만큼 벗어나면 다른 길로 간 것이다.
    private static let maximumOffRouteMeters = 700.0
    private static let maximumStepsPerMinute = 40.0
    /// 환승까지 한 번의 탑승으로 잇는 간격.
    private static let maximumLegGap: TimeInterval = 25 * 60
    private static let stoppedSpeed = 3.0
    private static let stopDetectionWindow: TimeInterval = 90
    /// 이만큼은 서 있어야 정차로 본다. 감속 중 한 표본만 느린 것은 빠진다.
    private static let minimumStopDuration: TimeInterval = 20
    private static let minimumGPSLossShare = 0.35
    private static let dwellExemptStations = 3

    private struct Visit {
        var name: String
        var first: Date
        var last: Date
    }

    static func journeys(readings: [SensorReading]) -> [Journey] {
        let ordered = readings
            .filter { RouteTimelineTimestamp.isValid($0.timestamp) }
            .sorted { $0.timestamp < $1.timestamp }
        var chains: [[Visit]] = []
        var chain: [Visit] = []
        let visits = stationVisits(ordered)
        for (from, to) in zip(visits, visits.dropFirst()) {
            if isRide(from: from, to: to, readings: ordered) {
                if chain.isEmpty { chain = [from] }
                chain.append(to)
            } else if chain.count >= 2, to.first.timeIntervalSince(from.last) <= maximumLegGap, from.name == to.name {
                // 같은 역을 잠깐 벗어났다 돌아온 환승은 끊지 않는다.
                chain[chain.count - 1].last = to.last
            } else {
                if chain.count >= 2 { chains.append(chain) }
                chain = []
            }
        }
        if chain.count >= 2 { chains.append(chain) }
        return chains.compactMap { journey(from: $0, readings: ordered) }
    }

    /// 인식한 탑승으로 겹치는 자동 차량 구간을 바꾼다. 걷기(환승)와 사용자가 고른 수단은 그대로 둔다.
    static func applying(
        _ journeys: [Journey],
        to segments: [TravelSegment],
        corrections: [TravelModeCorrection]
    ) -> [TravelSegment] {
        guard !journeys.isEmpty else { return segments }
        func isReplaceable(_ segment: TravelSegment) -> Bool {
            segment.mode != .walking && segment.mode != .running && segment.mode != .cycling
                && !segment.evidence.contains { $0.hasPrefix("사용자 확인") }
                && !corrections.contains { $0.span.overlapsMostly(segment.span) }
        }
        var result = segments.filter { segment in
            !(isReplaceable(segment) && journeys.contains { segment.span.overlapsMostly($0.span) || $0.span.contains(segment.span.start) })
        }
        for journey in journeys {
            let blockers = result.filter { $0.span.intersection(with: journey.span) != nil }.map(\.span)
            for span in remaining(journey.span, removing: blockers) where span.duration >= 60 {
                result.append(TravelSegment(
                    mode: .subway,
                    span: span,
                    distanceMeters: routeMeters(journey.route) * span.duration / max(1, journey.span.duration),
                    confidence: .high,
                    evidence: [
                        "지하철 노선 후보 확정",
                        "노선 " + journey.route.lineNames.joined(separator: " → "),
                        "역 감지 " + journey.stationNames.joined(separator: " · "),
                    ],
                    isConfirmed: false,
                    subwayRoute: journey.route
                ))
            }
        }
        return result.sorted { $0.span.start < $1.span.start }
    }

    /// Core Motion은 지하철도 자동차라고 한다. 탑승 구간에 든 자동 차량 기록의 이름을 지하철로 바꾼다.
    static func retitling(
        _ actuals: [ActualRecord],
        subwaySpans: [TimeSpan],
        activityCorrections: [UUID: ActivityCorrection] = [:],
        asOf now: Date
    ) -> [ActualRecord] {
        guard !subwaySpans.isEmpty else { return actuals }
        return actuals.map { actual in
            guard !ActualRecord.userOwned(actual, activityCorrections: activityCorrections),
                  MovementPresentation.mode(for: actual) == .car,
                  subwaySpans.contains(where: { $0.overlapsMostly(actual.span(asOf: now)) }) else { return actual }
            var value = actual
            value.title = "지하철"
            value.behavior = WatchBehaviorKind.subway.rawValue
            value.evidence.append("지하철 노선 후보 확정")
            return value
        }
    }

    private static func stationVisits(_ ordered: [SensorReading]) -> [Visit] {
        var visits: [Visit] = []
        for reading in ordered {
            guard reading.gpsAvailable, let point = reading.point,
                  (0...maximumAccuracyMeters).contains(point.horizontalAccuracy),
                  let station = SubwayStationCatalog.nearest(to: point, maximumDistanceMeters: stationRadiusMeters)
            else { continue }
            if let last = visits.last, last.name == station.stationName {
                visits[visits.count - 1].last = reading.timestamp
            } else {
                visits.append(Visit(name: station.stationName, first: reading.timestamp, last: reading.timestamp))
            }
        }
        return visits
    }

    private static func isRide(from: Visit, to: Visit, readings: [SensorReading]) -> Bool {
        guard from.name != to.name,
              let route = SubwayStationCatalog.route(for: [from.name, to.name]),
              SubwayStationCatalog.isValid(route) else { return false }
        let duration = to.first.timeIntervalSince(from.last)
        guard duration > 0, duration <= maximumLegGap else { return false }
        let speed = routeMeters(route) / duration
        guard (minimumRideSpeed...maximumRideSpeed).contains(speed) else { return false }
        let between = readings.filter { $0.timestamp >= from.last && $0.timestamp <= to.first }
        // 차량 오디오에 연결돼 있었으면 등록 여부와 상관없이 차다.
        if between.contains(where: { $0.carAudioRouteName?.isEmpty == false }) { return false }
        if stepsPerMinute(between) > maximumStepsPerMinute { return false }
        return between.allSatisfy { reading in
            guard reading.gpsAvailable, let point = reading.point,
                  (0...maximumAccuracyMeters).contains(point.horizontalAccuracy) else { return true }
            return offRouteMeters(point, route: route) <= maximumOffRouteMeters
        }
    }

    private static func journey(from visits: [Visit], readings: [SensorReading]) -> Journey? {
        guard let first = visits.first, let last = visits.last,
              let route = SubwayStationCatalog.route(for: visits.map(\.name)),
              SubwayStationCatalog.isValid(route) else { return nil }
        let inside = readings.filter { $0.timestamp >= first.first && $0.timestamp <= last.last }
        // 역 출입의 오르내림은 승차 전·하차 후에 일어난다.
        let altitudeContext = readings.filter {
            $0.timestamp >= first.first.addingTimeInterval(-TravelModeClassifier.subwayAltitudeWindow)
                && $0.timestamp <= last.last.addingTimeInterval(TravelModeClassifier.subwayAltitudeWindow)
        }
        let hasAltitudeData = altitudeContext.contains { $0.pressureKilopascals != nil || $0.relativeAltitudeMeters != nil }
        let after = readings.filter { $0.timestamp > last.last }
        let hasAlighted = hasLeftStation(after, from: last.name)
        let stops = visits.dropFirst().filter { hasStop(at: $0, readings: readings) }.count
        let offStationStops = stopsBetweenStations(first: first, last: last, readings: readings)
        let gpsLost = !inside.isEmpty && Double(inside.filter { !$0.gpsAvailable }.count) / Double(inside.count) >= minimumGPSLossShare
        // 역을 순서대로 세 곳 지나며 멈췄으면 타고 간 것이 분명하다. 빨리 나간 날에도 자동차로 돌아가지 않는다(대표 결정).
        // 차는 역이 아닌 곳에서도 신호에 멈추므로, 역 사이에서 멈췄으면 면제하지 않는다.
        let isDwellExempt = Set(visits.map(\.name)).count >= dwellExemptStations && stops >= 1 && offStationStops == 0
        let gate = SubwayEvidenceGate.Input(
            hasBoardingToAlightingRoute: true,
            sensedStationCount: Set(visits.map(\.name)).count,
            hasAltitudeChange: !hasAltitudeData
                || TravelModeClassifier.altitudeChangeMeters(altitudeContext) >= TravelModeClassifier.subwayAltitudeChangeMeters,
            // 지하철은 역 사이에 거의 서지 않는다. 역 밖 정차 하나가 역 정차 둘을 지운다.
            transitSpecificSignals: max(0, stops - offStationStops * 2) + (gpsLost ? 1 : 0),
            supportingSignals: stepsPerMinute(inside) <= maximumStepsPerMinute ? 1 : 0,
            boardingDwell: isDwellExempt ? nil : first.last.timeIntervalSince(first.first) + leftAfter(first, readings: readings),
            alightingDwell: isDwellExempt || !hasAlighted ? nil : last.last.timeIntervalSince(last.first)
        )
        guard SubwayEvidenceGate.missingConditions(gate).isEmpty else { return nil }
        let end = hasAlighted ? last.first : (readings.last?.timestamp ?? last.last)
        let start = first.last
        guard end > start else { return nil }
        return Journey(span: TimeSpan(start: start, end: end), route: route, stationNames: visits.map(\.name))
    }

    /// 마지막 역 이후 표본이 역을 벗어났으면 내린 것이다. 표본이 없으면 아직 타고 있는 것으로 본다.
    private static func hasLeftStation(_ after: [SensorReading], from name: String) -> Bool {
        after.contains { reading in
            guard reading.gpsAvailable, let point = reading.point else { return false }
            return SubwayStationCatalog.nearest(to: point, maximumDistanceMeters: stationRadiusMeters)?.stationName != name
        }
    }

    /// 탑승역에 닿고 마지막으로 잡힌 뒤 다음 표본까지. 지하에서 위치가 끊긴 시간은 아직 역에 있던 것으로 친다.
    private static func leftAfter(_ visit: Visit, readings: [SensorReading]) -> TimeInterval {
        guard let next = readings.first(where: { $0.timestamp > visit.last && $0.point != nil && $0.gpsAvailable }) else { return 0 }
        let silence = next.timestamp.timeIntervalSince(visit.last)
        let hasSilentReadings = readings.contains { $0.timestamp > visit.last && $0.timestamp < next.timestamp }
        return hasSilentReadings || silence >= 60 ? silence : 0
    }

    /// 역 근처에서 멈췄는가. 빠르게 다시 출발할 때까지 잰다.
    private static func hasStop(at visit: Visit, readings: [SensorReading]) -> Bool {
        let window = readings.filter {
            $0.timestamp >= visit.first.addingTimeInterval(-stopDetectionWindow)
                && $0.timestamp <= visit.last.addingTimeInterval(stopDetectionWindow)
        }
        return !stops(in: window).isEmpty
    }

    /// 첫 역과 마지막 역 사이, 어느 역에서도 먼 곳에서 멈춘 횟수.
    private static func stopsBetweenStations(first: Visit, last: Visit, readings: [SensorReading]) -> Int {
        let window = readings.filter { $0.timestamp >= first.last && $0.timestamp <= last.first }
        return stops(in: window).filter { reading in
            guard reading.gpsAvailable, let point = reading.point,
                  (0...maximumAccuracyMeters).contains(point.horizontalAccuracy) else { return false }
            return SubwayStationCatalog.nearest(to: point, maximumDistanceMeters: stationRadiusMeters * 2) == nil
        }.count
    }

    /// 속도가 낮아진 표본에서 다시 빨라질 때까지 정차 시간 이상 걸린 곳의 첫 표본들.
    private static func stops(in readings: [SensorReading]) -> [SensorReading] {
        var result: [SensorReading] = []
        var slowStart: SensorReading?
        for reading in readings {
            guard let speed = reading.speedMetersPerSecond, speed >= 0 else { continue }
            if speed <= stoppedSpeed {
                if slowStart == nil { slowStart = reading }
            } else if let start = slowStart {
                if reading.timestamp.timeIntervalSince(start.timestamp) >= minimumStopDuration { result.append(start) }
                slowStart = nil
            }
        }
        if let start = slowStart, let last = readings.last,
           last.timestamp.timeIntervalSince(start.timestamp) >= minimumStopDuration {
            result.append(start)
        }
        return result
    }

    private static func stepsPerMinute(_ readings: [SensorReading]) -> Double {
        let counts = readings.compactMap(\.stepCount)
        guard let first = counts.first, let last = counts.last, last >= first,
              let start = readings.first?.timestamp, let end = readings.last?.timestamp,
              end > start else { return 0 }
        return Double(last - first) / max(1, end.timeIntervalSince(start) / 60)
    }

    private static func remaining(_ span: TimeSpan, removing blockers: [TimeSpan]) -> [TimeSpan] {
        var pieces = [span]
        for blocker in blockers {
            pieces = pieces.flatMap { piece -> [TimeSpan] in
                guard piece.intersection(with: blocker) != nil else { return [piece] }
                var kept: [TimeSpan] = []
                if blocker.start > piece.start { kept.append(TimeSpan(start: piece.start, end: blocker.start)) }
                if blocker.end < piece.end { kept.append(TimeSpan(start: blocker.end, end: piece.end)) }
                return kept
            }
        }
        return pieces
    }

    private static func routeMeters(_ route: SubwayRoutePath) -> Double {
        let points = route.coordinates
        return zip(points, points.dropFirst()).reduce(0) { $0 + meters($1.0, $1.1) }
    }

    private static func offRouteMeters(_ point: GeoPoint, route: SubwayRoutePath) -> Double {
        let points = route.coordinates
        return zip(points, points.dropFirst()).map { segmentMeters(point, $0.0, $0.1) }.min() ?? .infinity
    }

    private static func segmentMeters(_ point: GeoPoint, _ start: GeoPoint, _ end: GeoPoint) -> Double {
        let scale = cos(point.latitude * .pi / 180)
        let ax = (start.longitude - point.longitude) * 111_320 * scale, ay = (start.latitude - point.latitude) * 111_320
        let bx = (end.longitude - point.longitude) * 111_320 * scale, by = (end.latitude - point.latitude) * 111_320
        let dx = bx - ax, dy = by - ay
        let length = dx * dx + dy * dy
        let t = length > 0 ? min(1, max(0, -(ax * dx + ay * dy) / length)) : 0
        let x = ax + dx * t, y = ay + dy * t
        return (x * x + y * y).squareRoot()
    }

    private static func meters(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let x = (a.longitude - b.longitude) * 111_320 * cos(a.latitude * .pi / 180)
        let y = (a.latitude - b.latitude) * 111_320
        return (x * x + y * y).squareRoot()
    }
}
