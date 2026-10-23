import Foundation
import CoreLocation
import TaptionPlanEngine

/// 그리기 직전에 경로 점을 줄인다. GPS 한 점은 보통 5m 안팎의 오차를 안고
/// 있어 그보다 작은 굴곡은 지도에서 화소 아래로 사라진다. 하루에 수백 점,
/// 한 주면 수천 점이라 줄이지 않으면 지도가 그대로 굳는다.
enum RoutePolylineDecimator {
    /// 지도를 가장 가깝게 당겨도 1pt가 약 2.5m다. 5m는 GPS 오차보다 작아
    /// 모양이 눈에 띄게 달라지지 않는다.
    static let defaultToleranceMeters: Double = 5
    /// 한 구간을 아무리 길게 걸어도 이만큼만 그린다.
    static let defaultLimit = 400
    /// 서 있는 동안 흔들리는 좌표를 먼저 걷어 낸다.
    static let minimumSpacingMeters: Double = 3

    private typealias PlanarPoint = (x: Double, y: Double)

    /// 핵심 경로 엔진의 bounded simplifier를 사용해 양 끝점과 큰 굴곡을
    /// 보존하면서 렌더링 점 수를 제한한다.
    static func decimate(
        _ coordinates: [CLLocationCoordinate2D],
        toleranceMeters: Double = defaultToleranceMeters,
        limit: Int = defaultLimit
    ) -> [CLLocationCoordinate2D] {
        guard coordinates.count > 2 else { return coordinates }
        let routePoints = coordinates.map {
            RouteCoordinate(latitude: $0.latitude, longitude: $0.longitude)
        }
        return RoutePathSimplifier.simplify(
            routePoints,
            toleranceMeters: toleranceMeters,
            maximumCount: max(2, limit)
        ).map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
    }

    /// 최소 간격보다 촘촘한 점을 걷어 낸다. 마지막 점은 도착 지점이라
    /// 간격과 무관하게 남긴다.
    static func spaced(
        _ coordinates: [CLLocationCoordinate2D],
        minimumMeters: Double = minimumSpacingMeters
    ) -> [CLLocationCoordinate2D] {
        guard coordinates.count > 2, minimumMeters > 0 else { return coordinates }
        let scale = planarScale(at: coordinates[0].latitude)
        let squaredMinimum = minimumMeters * minimumMeters
        var result: [CLLocationCoordinate2D] = [coordinates[0]]
        result.reserveCapacity(coordinates.count)
        for coordinate in coordinates.dropFirst() {
            let previous = result[result.count - 1]
            let dx = RouteTimelineLongitude.shortestDelta(
                from: previous.longitude,
                to: coordinate.longitude
            ) * scale.longitude
            let dy = (coordinate.latitude - previous.latitude) * scale.latitude
            if dx * dx + dy * dy >= squaredMinimum {
                result.append(coordinate)
            }
        }
        if let last = coordinates.last,
           result.count == 1
            || result[result.count - 1].latitude != last.latitude
            || result[result.count - 1].longitude != last.longitude {
            result.append(last)
        }
        return result
    }

    /// 탭한 좌표에서 경로까지의 거리. 지도 위 선을 골라내는 데 쓴다.
    static func distanceMeters(
        from coordinate: CLLocationCoordinate2D,
        to polyline: [CLLocationCoordinate2D]
    ) -> Double? {
        guard let first = polyline.first else { return nil }
        let scale = planarScale(at: first.latitude)
        let origin = first
        func project(_ value: CLLocationCoordinate2D) -> PlanarPoint {
            (
                x: RouteTimelineLongitude.shortestDelta(
                    from: origin.longitude,
                    to: value.longitude
                ) * scale.longitude,
                y: (value.latitude - origin.latitude) * scale.latitude
            )
        }
        let target = project(coordinate)
        guard polyline.count > 1 else {
            let start = project(first)
            let dx = target.x - start.x
            let dy = target.y - start.y
            return (dx * dx + dy * dy).squareRoot()
        }
        var best = Double.infinity
        var previous = project(first)
        for value in polyline.dropFirst() {
            let current = project(value)
            best = min(
                best,
                squaredDistance(target, from: previous, to: current)
            )
            previous = current
        }
        return best.squareRoot()
    }

    private static func planarScale(
        at latitude: Double
    ) -> (latitude: Double, longitude: Double) {
        // 경로 한 구간은 지구 곡률을 무시할 만큼 짧다. 삼각 함수를 점마다
        // 부르는 대신 위도 하나로 미터 평면을 만들어 둔다.
        let metersPerDegree = 111_320.0
        return (
            latitude: metersPerDegree,
            longitude: metersPerDegree * cos(latitude * .pi / 180)
        )
    }

    private static func squaredDistance(
        _ point: PlanarPoint,
        from start: PlanarPoint,
        to end: PlanarPoint
    ) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else {
            let ex = point.x - start.x
            let ey = point.y - start.y
            return ex * ex + ey * ey
        }
        var ratio = ((point.x - start.x) * dx + (point.y - start.y) * dy)
            / lengthSquared
        ratio = min(1, max(0, ratio))
        let ex = point.x - (start.x + ratio * dx)
        let ey = point.y - (start.y + ratio * dy)
        return ex * ex + ey * ey
    }

}
