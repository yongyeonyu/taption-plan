import Foundation

/// 노선 좌표가 있는 지하철·기차 탑승의 파생 모양과 거리(SUB1108A01).
///
/// 지도 선만 `SubwayTrackCatalog.following`으로 선로를 따르고, 끊긴 조각·회색 발자국·재생 위치·거리는
/// 역과 역을 직선으로 이은 좌표를 썼다. 그래서 선로 옆에 나란한 직선 미확인 발자국이 생기고, 화랑이는 그 직선을
/// 따라갔으며, 거리도 역 직선 길이였다. 이제 모두 이 선로 좌표 하나를 쓴다. 원본 센서와 저장 구간은 바꾸지 않는다.
enum SubwayRideTrack {
    /// 같은 노선을 가진 조각을 한 탑승으로 묶는 최대 간격(환승 걷기로 나뉜 조각).
    static let maximumJourneyGap: TimeInterval = 20 * 60
    /// 탑승 직전·직후 GPS를 양 끝 자리로 쓸 수 있는 시간과 선로에서 떨어진 거리.
    static let boundaryWindow: TimeInterval = 5 * 60
    static let boundaryOffTrackMeters = 300.0
    static let trustedAccuracyMeters = 150.0

    /// 탑승: 지하철·기차이고 유효한 노선이 있다.
    static func isRide(_ segment: TravelSegment) -> Bool {
        (segment.mode == .subway || segment.mode == .train)
            && segment.subwayRoute.map(SubwayStationCatalog.isValid) == true
    }

    /// 역 사이를 실제 선로 모양으로 채운 좌표. 선로 자료가 없는 역 쌍은 직선이다.
    static func coordinates(of route: SubwayRoutePath) -> [GeoPoint] {
        SubwayTrackCatalog.following(route.coordinates)
    }

    static func length(_ points: [GeoPoint]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + distanceMeters($1.0, $1.1) }
    }

    /// 이 시간이 탑승과 겹치면 true. 탑승 안의 GPS 공백은 따로 그리지 않는다.
    static func covers(_ span: TimeSpan, in travel: [TravelSegment]) -> Bool {
        travel.contains { isRide($0) && $0.span.intersection(with: span) != nil }
    }

    /// 탑승 거리 = 선로 길이 × 같은 탑승 안의 시간 몫. 다른 수단의 거리는 그대로 둔다.
    /// 환승 걷기로 나뉜 조각은 같은 노선을 함께 가지므로(`RailJourneyRecognizer.applying`) 시간 비율로 나눈다.
    static func applyingTrackDistance(_ travel: [TravelSegment]) -> [TravelSegment] {
        let rides = travel.indices.filter { isRide(travel[$0]) }.sorted { travel[$0].span.start < travel[$1].span.start }
        guard !rides.isEmpty else { return travel }
        var journeys: [[Int]] = []
        for index in rides {
            if let previous = journeys.last?.last,
               travel[previous].subwayRoute == travel[index].subwayRoute,
               travel[index].span.start.timeIntervalSince(travel[previous].span.end) <= maximumJourneyGap {
                journeys[journeys.count - 1].append(index)
            } else {
                journeys.append([index])
            }
        }
        var result = travel
        for journey in journeys {
            guard let route = travel[journey[0]].subwayRoute else { continue }
            let meters = length(coordinates(of: route))
            let seconds = journey.reduce(0.0) { $0 + travel[$1].span.duration }
            guard meters > 0, seconds > 0 else { continue }
            for index in journey {
                result[index].distanceMeters = meters * travel[index].span.duration / seconds
            }
        }
        return result
    }
}

/// 선로 한 줄 위의 거리(m) 계산.
struct SubwayTrackLine {
    let points: [GeoPoint]
    let lengths: [Double]
    let total: Double

    init?(route: SubwayRoutePath?) {
        guard let route else { return nil }
        self.init(points: SubwayRideTrack.coordinates(of: route))
    }

    init?(points: [GeoPoint]) {
        guard points.count >= 2 else { return nil }
        let lengths = zip(points, points.dropFirst()).map { PlanarDistance.meters($0.0, $0.1) }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return nil }
        self.points = points
        self.lengths = lengths
        self.total = total
    }

    /// 점을 선로에 투영한 위치(처음부터 m)와 선로까지 거리.
    func position(of point: GeoPoint) -> (meters: Double, offset: Double) {
        var best = (distance: Double.infinity, meters: 0.0)
        var traversed = 0.0
        let scale = cos(point.latitude * .pi / 180) * 111_320
        for index in lengths.indices {
            let ax = (points[index].longitude - point.longitude) * scale, ay = (points[index].latitude - point.latitude) * 111_320
            let bx = (points[index + 1].longitude - point.longitude) * scale, by = (points[index + 1].latitude - point.latitude) * 111_320
            let dx = bx - ax, dy = by - ay, square = dx * dx + dy * dy
            let t = square > 0 ? min(1, max(0, -(ax * dx + ay * dy) / square)) : 0
            let x = ax + dx * t, y = ay + dy * t, distance = x * x + y * y
            if distance < best.distance { best = (distance, traversed + lengths[index] * t) }
            traversed += lengths[index]
        }
        return (best.meters, best.distance.squareRoot())
    }

    func point(atMeters target: Double) -> GeoPoint {
        var traversed = 0.0
        for index in lengths.indices {
            let next = traversed + lengths[index]
            if target <= next, lengths[index] > 0 {
                let t = max(0, (target - traversed) / lengths[index])
                let a = points[index], b = points[index + 1]
                return GeoPoint(
                    latitude: a.latitude + (b.latitude - a.latitude) * t,
                    longitude: a.longitude + (b.longitude - a.longitude) * t,
                    altitude: a.altitude, horizontalAccuracy: a.horizontalAccuracy, verticalAccuracy: a.verticalAccuracy
                )
            }
            traversed = next
        }
        return points[points.count - 1]
    }

    /// 두 위치 사이의 선로 조각. 선로 꼭짓점을 그대로 담는다.
    func slice(from start: Double, to end: Double) -> [GeoPoint] {
        var result = [point(atMeters: start)]
        var traversed = 0.0
        for index in lengths.indices {
            traversed += lengths[index]
            if traversed > start, traversed < end { result.append(points[index + 1]) }
        }
        result.append(point(atMeters: end))
        return result
    }

    /// 탑승 시각별 선로 위치. 안쪽은 믿을 만한 GPS 투영(뒤로 가지 않음), 양 끝은 탑승 직전·직후 GPS가 선로 가까이 있으면
    /// 그 자리, 없으면 노선 처음·끝이다. 환승으로 나뉜 조각이 노선 전체를 함께 가져도 그 조각이 탄 몫만 지난다.
    /// `readings`는 시각순이어야 한다.
    func anchors(segment: TravelSegment, readings: [SensorReading], through cutoff: Date = .distantFuture) -> [(date: Date, meters: Double)] {
        let span = segment.span
        let window = SubwayRideTrack.boundaryWindow
        func trusted(_ reading: SensorReading) -> GeoPoint? {
            guard reading.gpsAvailable, let point = reading.point,
                  point.horizontalAccuracy <= SubwayRideTrack.trustedAccuracyMeters else { return nil }
            return point
        }
        var lower = 0, upper = readings.count
        let from = span.start.addingTimeInterval(-window)
        while lower < upper {
            let middle = (lower + upper) / 2
            if readings[middle].timestamp < from { lower = middle + 1 } else { upper = middle }
        }
        var startMeters = 0.0
        var endMeters = total
        var inside: [(date: Date, meters: Double)] = []
        var index = lower
        while index < readings.count, readings[index].timestamp <= span.end.addingTimeInterval(window) {
            let reading = readings[index]
            index += 1
            guard let point = trusted(reading) else { continue }
            if reading.timestamp <= span.start {
                let found = position(of: point)
                if found.offset <= SubwayRideTrack.boundaryOffTrackMeters { startMeters = found.meters }
            } else if reading.timestamp < span.end {
                inside.append((reading.timestamp, position(of: point).meters))
            } else {
                let found = position(of: point)
                if found.offset <= SubwayRideTrack.boundaryOffTrackMeters { endMeters = found.meters }
                break
            }
        }
        // 투영이 잠깐 뒤로 잡혀도 열차는 뒤로 가지 않는다.
        var result: [(date: Date, meters: Double)] = [(span.start, startMeters)]
        for anchor in inside { result.append((anchor.date, max(result[result.count - 1].meters, anchor.meters))) }
        result.append((span.end, max(result[result.count - 1].meters, endMeters)))
        guard cutoff < span.end else { return result }
        // 지금 시각까지만: 마지막 기준점 뒤는 시간 비율로 잇는다.
        var visible = result.filter { $0.date < cutoff }
        guard let last = visible.last, let next = result.first(where: { $0.date >= cutoff }) else { return visible }
        let ratio = next.date > last.date ? cutoff.timeIntervalSince(last.date) / next.date.timeIntervalSince(last.date) : 1
        visible.append((cutoff, last.meters + (next.meters - last.meters) * min(1, max(0, ratio))))
        return visible
    }

    /// 기준점 사이를 시간 비율로 이은 위치.
    static func meters(at date: Date, anchors: [(date: Date, meters: Double)]) -> Double? {
        guard let first = anchors.first else { return nil }
        if date <= first.date { return first.meters }
        for (a, b) in zip(anchors, anchors.dropFirst()) where date <= b.date {
            let duration = b.date.timeIntervalSince(a.date)
            guard duration > 0 else { return b.meters }
            return a.meters + (b.meters - a.meters) * date.timeIntervalSince(a.date) / duration
        }
        return anchors.last?.meters
    }
}
