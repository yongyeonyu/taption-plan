import CoreLocation
import TaptionPlanEngine

/// 여행 일정 선(TAU1110A01). 300km 넘는 구간(비행기)은 직선 대신 대권으로 그린다. 경도 180도를 넘으면 선을 나눈다.
enum TravelGreatCircleAdapter {
    static let flightMeters = 300_000.0

    static func paths(_ stops: [CLLocationCoordinate2D]) -> [[CLLocationCoordinate2D]] {
        guard stops.count >= 2 else { return [] }
        var points: [RouteCoordinate] = []
        for (start, end) in zip(stops, stops.dropFirst()) {
            let a = RouteCoordinate(latitude: start.latitude, longitude: start.longitude)
            let b = RouteCoordinate(latitude: end.latitude, longitude: end.longitude)
            let leg = GreatCircle.distanceKm(from: a, to: b) * 1_000 >= flightMeters ? GreatCircle.points(from: a, to: b) : [a, b]
            points += points.isEmpty ? leg : Array(leg.dropFirst())
        }
        return GreatCircle.splitAtAntimeridian(points).map { part in
            part.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        }
    }
}
