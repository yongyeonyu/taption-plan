import MapKit
import SwiftUI
import TaptionPlanStore

/// 여행 계획의 곳 사이 길(TVP1112A01). Apple 길찾기로 받아 메모리에만 둔다(지도 타일이 아니라 경로 점들).
/// Trip 앱처럼 처음에는 곧은 선을 쓰고, 길이 오면 그 길로 바꾼다.
@MainActor @Observable
final class TravelRouteStore {
    /// 구간(`TravelPlayhead.legKey`)별 길. 경도, 위도.
    private(set) var paths: [String: [SIMD2<Double>]] = [:]
    private var asked: Set<String> = []

    /// 이보다 먼 구간(비행기·배)은 곧은 선 그대로 둔다.
    static let farthestMeters = 300_000.0
    /// 이보다 가까우면 걷는 길부터 찾는다.
    static let walkMeters = 1_500.0

    /// 구간 자리까지 넣은 이름표: 일정이 다른 곳으로 옮겨지면 다시 찾는다.
    static func cacheKey(_ from: TravelPlayhead.Stop, _ to: TravelPlayhead.Stop) -> String {
        String(format: "%.4f,%.4f>%.4f,%.4f", from.longitude, from.latitude, to.longitude, to.latitude)
    }

    /// 어떤 길찾기를 차례로 해 볼지. 너무 멀거나 같은 자리면 비어 있다.
    static func transports(meters: Double) -> [MKDirectionsTransportType] {
        guard meters > 30, meters <= farthestMeters else { return [] }
        return meters <= walkMeters ? [.walking, .automobile] : [.automobile, .transit, .walking]
    }

    /// 그날 일정 순서대로 아직 없는 구간의 길을 하나씩 받아 온다(길찾기 한도를 넘지 않게 차례로).
    func load(_ stops: [TravelPlayhead.Stop]) async {
        let ordered = stops.sorted { ($0.startMinute, $0.endMinute) < ($1.startMinute, $1.endMinute) }
        for (from, to) in zip(ordered, ordered.dropFirst()) {
            if Task.isCancelled { return }
            let cache = Self.cacheKey(from, to), leg = TravelPlayhead.legKey(from.id, to.id)
            if let known = cached[cache] {
                if paths[leg] != known { paths[leg] = known }
                continue
            }
            guard asked.insert(cache).inserted else { continue }
            let start = CLLocationCoordinate2D(latitude: from.latitude, longitude: from.longitude)
            let end = CLLocationCoordinate2D(latitude: to.latitude, longitude: to.longitude)
            let meters = CLLocation(latitude: start.latitude, longitude: start.longitude)
                .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
            guard let path = await Self.route(start: start, end: end, transports: Self.transports(meters: meters)) else { continue }
            cached[cache] = path
            paths[leg] = path
        }
    }

    private var cached: [String: [SIMD2<Double>]] = [:]

    private static func route(start: CLLocationCoordinate2D, end: CLLocationCoordinate2D, transports: [MKDirectionsTransportType]) async -> [SIMD2<Double>]? {
        for transport in transports {
            if Task.isCancelled { return nil }
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
            request.transportType = transport
            request.requestsAlternateRoutes = false
            guard let route = try? await MKDirections(request: request).calculate().routes.first, route.polyline.pointCount > 1 else { continue }
            let points = route.polyline.points()
            return (0..<route.polyline.pointCount).map { SIMD2(points[$0].coordinate.longitude, points[$0].coordinate.latitude) }
        }
        return nil
    }
}
