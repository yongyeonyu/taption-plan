import Foundation

/// 여행 계획표의 재생 헤드(TVP1112A01): 하루의 어느 시각에 지도의 어디에 있는지.
public enum TravelPlayhead {
    /// 좌표가 있는 일정 하나(그날 0시부터의 분).
    public struct Stop: Hashable, Sendable {
        public var id: String
        public var startMinute: Int
        public var endMinute: Int
        public var longitude: Double
        public var latitude: Double

        public init(id: String, startMinute: Int, endMinute: Int, longitude: Double, latitude: Double) {
            self.id = id
            self.startMinute = startMinute
            self.endMinute = endMinute
            self.longitude = longitude
            self.latitude = latitude
        }
    }

    public struct Position: Hashable, Sendable {
        public var longitude: Double
        public var latitude: Double
        /// 머무는 중인 일정. 이동 중이면 nil.
        public var stopID: String?
        /// 이동 중일 때 향하는 쪽(오른쪽이면 참). 머무는 중이면 마지막 방향을 그대로 쓴다.
        public var facesEast: Bool
    }

    /// 그 시각의 자리. 일정 안이면 그 곳, 일정 사이면 앞 일정의 끝에서 다음 일정의 시작까지 시간에 비례해 곧게 간다.
    /// 첫 일정 전에는 첫 곳, 마지막 일정 뒤에는 마지막 곳. 좌표 있는 일정이 없으면 nil.
    /// 두 일정 사이 길의 이름표(`paths`의 키).
    public static func legKey(_ from: String, _ to: String) -> String { from + ">" + to }

    /// 길(경도, 위도 점들)의 `t`(0~1) 지점. 거리에 비례해 간다. 점이 둘보다 적으면 nil.
    public static func along(_ path: [SIMD2<Double>], t: Double) -> (point: SIMD2<Double>, facesEast: Bool)? {
        guard path.count > 1 else { return nil }
        // 좁은 범위라 위도에 맞춘 평면 거리로 충분하다.
        let scale = cos(path[0].y * .pi / 180)
        func length(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
            let dx = (b.x - a.x) * scale, dy = b.y - a.y
            return (dx * dx + dy * dy).squareRoot()
        }
        let lengths = zip(path, path.dropFirst()).map(length)
        let total = lengths.reduce(0, +)
        guard total > 0 else { return (path[0], true) }
        var left = min(1, max(0, t)) * total
        for (index, piece) in lengths.enumerated() {
            if left <= piece || index == lengths.count - 1 {
                let f = piece > 0 ? min(1, left / piece) : 0
                let a = path[index], b = path[index + 1]
                return (a + (b - a) * f, b.x >= a.x)
            }
            left -= piece
        }
        return (path[path.count - 1], true)
    }

    /// `paths`에 그 구간의 길이 있으면(키는 `legKey`) 곧은 선 대신 그 길을 따라간다.
    public static func position(at minute: Int, stops: [Stop], paths: [String: [SIMD2<Double>]] = [:]) -> Position? {
        let ordered = stops.sorted { ($0.startMinute, $0.endMinute) < ($1.startMinute, $1.endMinute) }
        guard let first = ordered.first, let last = ordered.last else { return nil }
        if minute <= first.startMinute { return Position(longitude: first.longitude, latitude: first.latitude, stopID: first.id, facesEast: true) }
        var previous = first
        for stop in ordered {
            if minute >= stop.startMinute, minute <= stop.endMinute {
                return Position(longitude: stop.longitude, latitude: stop.latitude, stopID: stop.id, facesEast: stop.longitude >= previous.longitude)
            }
            if minute < stop.startMinute {
                // 앞 일정이 뒤 일정과 겹쳐 끝이 더 늦으면 바로 다음 곳에 둔다.
                let span = stop.startMinute - previous.endMinute
                let t = span > 0 ? min(1, max(0, Double(minute - previous.endMinute) / Double(span))) : 1
                if let spot = paths[legKey(previous.id, stop.id)].flatMap({ along($0, t: t) }) {
                    return Position(longitude: spot.point.x, latitude: spot.point.y, stopID: nil, facesEast: spot.facesEast)
                }
                return Position(
                    longitude: previous.longitude + (stop.longitude - previous.longitude) * t,
                    latitude: previous.latitude + (stop.latitude - previous.latitude) * t,
                    stopID: nil, facesEast: stop.longitude >= previous.longitude
                )
            }
            if stop.endMinute >= previous.endMinute { previous = stop }
        }
        return Position(longitude: last.longitude, latitude: last.latitude, stopID: last.id, facesEast: true)
    }

    /// 재생 헤드를 처음 둘 시각: 오늘이면 지금, 아니면 첫 일정의 시작(없으면 09:00).
    public static func startMinute(nowMinute: Int?, firstStartMinute: Int?) -> Int {
        min(max(nowMinute ?? firstStartMinute ?? 540, 0), 1_439)
    }
}
