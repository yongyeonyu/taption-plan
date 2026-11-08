import Foundation

/// 위경도·고도와 정확도. 정확도가 음수면 값이 없다는 뜻이다.
public struct GeoPoint: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double
    public var horizontalAccuracy: Double
    public var verticalAccuracy: Double

    @inlinable
    public init(
        latitude: Double,
        longitude: Double,
        altitude: Double,
        horizontalAccuracy: Double,
        verticalAccuracy: Double
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
    }
}

// 지도·장소·경로가 함께 쓰는 거리 계산. 반복문 안에서 불리므로 모듈 밖에서도 인라인되게 둔다.

/// 대원 거리(m). 경도는 짧은 쪽으로 잰다(날짜변경선을 넘어도 가깝게).
@inlinable
public func distanceMeters(_ lhs: GeoPoint, _ rhs: GeoPoint) -> Double {
    let earthRadius = 6_371_000.0
    let lat1 = lhs.latitude * .pi / 180
    let lat2 = rhs.latitude * .pi / 180
    let deltaLat = (rhs.latitude - lhs.latitude) * .pi / 180
    var longitudeDelta = (rhs.longitude - lhs.longitude).truncatingRemainder(dividingBy: 360)
    if longitudeDelta > 180 { longitudeDelta -= 360 } else if longitudeDelta < -180 { longitudeDelta += 360 }
    let deltaLon = longitudeDelta * .pi / 180
    let a = sin(deltaLat / 2) * sin(deltaLat / 2)
        + cos(lat1) * cos(lat2)
        * sin(deltaLon / 2) * sin(deltaLon / 2)
    return earthRadius * 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))
}

/// 수 km 안 판정용 평면 근사(m). 경도 폭은 첫 점의 위도로 줄인다. 판정 경계가 이 값에 맞춰져 있어 대원 거리로 바꾸지 않는다.
public enum PlanarDistance {
    @inlinable
    public static func meters(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let x = (a.longitude - b.longitude) * 111_320 * cos(a.latitude * .pi / 180)
        let y = (a.latitude - b.latitude) * 111_320
        return (x * x + y * y).squareRoot()
    }

    /// 점에서 선분까지 가장 가까운 거리(m). 점의 위도로 경도 폭을 줄인다.
    @inlinable
    public static func segmentMeters(_ point: GeoPoint, _ start: GeoPoint, _ end: GeoPoint) -> Double {
        let scale = cos(point.latitude * .pi / 180)
        let ax = (start.longitude - point.longitude) * 111_320 * scale, ay = (start.latitude - point.latitude) * 111_320
        let bx = (end.longitude - point.longitude) * 111_320 * scale, by = (end.latitude - point.latitude) * 111_320
        let dx = bx - ax, dy = by - ay
        let length = dx * dx + dy * dy
        let t = length > 0 ? min(1, max(0, -(ax * dx + ay * dy) / length)) : 0
        let x = ax + dx * t, y = ay + dy * t
        return (x * x + y * y).squareRoot()
    }
}
