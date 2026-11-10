import Foundation

/// 두 공항을 잇는 대권. 지도 폴리라인에 넣을 보간점을 만든다.
public enum GreatCircle {
    /// 지구 평균 반지름(km).
    public static let earthRadiusKm = 6_371.0088

    public static func distanceKm(from start: RouteCoordinate, to end: RouteCoordinate) -> Double {
        angle(vector(start), vector(end)) * earthRadiusKm
    }

    /// 양 끝을 포함해 `segments + 1`개 점. 좌표가 틀리면 빈 배열.
    public static func points(from start: RouteCoordinate, to end: RouteCoordinate, segments: Int = 64) -> [RouteCoordinate] {
        guard isValid(start), isValid(end), segments >= 1 else { return [] }
        let a = vector(start), b = vector(end)
        let angle = angle(a, b)
        // 같은 점이거나 정반대라 대권이 하나로 정해지지 않으면 양 끝만 준다.
        guard sin(angle) > 1e-9 else { return [start, end] }
        let middle = (1..<segments).map { index -> RouteCoordinate in
            let fraction = Double(index) / Double(segments)
            let first = sin((1 - fraction) * angle) / sin(angle)
            let second = sin(fraction * angle) / sin(angle)
            return coordinate((first * a.x + second * b.x, first * a.y + second * b.y, first * a.z + second * b.z))
        }
        return [start] + middle + [end]
    }

    /// 경도 180도를 넘는 곳에서 선을 둘로 나눈다. 나누지 않으면 지도를 가로지르는 선이 그려진다.
    public static func splitAtAntimeridian(_ points: [RouteCoordinate]) -> [[RouteCoordinate]] {
        var parts: [[RouteCoordinate]] = []
        var current: [RouteCoordinate] = []
        for point in points {
            if let previous = current.last, abs(point.longitude - previous.longitude) > 180 {
                let edge = previous.longitude > 0 ? 180.0 : -180.0
                let toEdge = edge - previous.longitude
                let span = toEdge + (point.longitude + edge)
                let latitude = span == 0 ? previous.latitude : previous.latitude + (point.latitude - previous.latitude) * toEdge / span
                current.append(RouteCoordinate(latitude: latitude, longitude: edge))
                parts.append(current)
                current = [RouteCoordinate(latitude: latitude, longitude: -edge)]
            }
            current.append(point)
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    private typealias Vector = (x: Double, y: Double, z: Double)

    private static func isValid(_ point: RouteCoordinate) -> Bool {
        point.latitude.isFinite && point.longitude.isFinite && abs(point.latitude) <= 90 && abs(point.longitude) <= 180
    }

    private static func vector(_ point: RouteCoordinate) -> Vector {
        let latitude = point.latitude * .pi / 180, longitude = point.longitude * .pi / 180
        return (cos(latitude) * cos(longitude), cos(latitude) * sin(longitude), sin(latitude))
    }

    private static func coordinate(_ vector: Vector) -> RouteCoordinate {
        RouteCoordinate(
            latitude: atan2(vector.z, (vector.x * vector.x + vector.y * vector.y).squareRoot()) * 180 / .pi,
            longitude: atan2(vector.y, vector.x) * 180 / .pi
        )
    }

    private static func angle(_ a: Vector, _ b: Vector) -> Double {
        let cross = (a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
        let dot = a.x * b.x + a.y * b.y + a.z * b.z
        return atan2((cross.0 * cross.0 + cross.1 * cross.1 + cross.2 * cross.2).squareRoot(), dot)
    }
}
