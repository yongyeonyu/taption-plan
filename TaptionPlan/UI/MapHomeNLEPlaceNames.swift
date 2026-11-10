import CoreLocation
import MapKit

/// 등록되지 않은 체류 자리의 가장 가까운 장소 이름을 지도에서 찾는다(NLE1104A02).
/// 이름만 메모리에 잠시 두며 기록에는 쓰지 않는다. 찾지 못하면 체류의 원래 이름을 쓴다.
@MainActor
enum NLENearbyPlaceNames {
    /// 한 번에 찾는 곳 수. MapKit 호출 제한을 넘지 않게 오래 머문 곳부터 찾는다.
    static let maximumLookups = 12
    private static let searchRadiusMeters: CLLocationDistance = 200
    private static let cacheLimit = 200
    private static var cache: [String: String] = [:]

    static func names(for points: [GeoPoint]) async -> [String: String] {
        var result: [String: String] = [:]
        var lookups = 0
        for point in points {
            let key = NLEPlaceLane.nameKey(for: point)
            if let cached = cache[key] {
                result[key] = cached
                continue
            }
            guard lookups < maximumLookups, !Task.isCancelled else { continue }
            lookups += 1
            guard let name = await nearestName(to: point) else { continue }
            if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
            cache[key] = name
            result[key] = name
        }
        return result
    }

    private static func nearestName(to point: GeoPoint) async -> String? {
        let center = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
        let location = CLLocation(latitude: point.latitude, longitude: point.longitude)
        // 국내는 카카오 식당·카페가 Apple 지도보다 촘촘하다(TAU1110A01). 이름은 화면에만 쓰고 기록에는 쓰지 않는다.
        if let name = await MapHomeKakaoSearch.nearestStayName(at: center) { return name }
        let request = MKLocalPointsOfInterestRequest(center: center, radius: searchRadiusMeters)
        if let response = try? await MKLocalSearch(request: request).start() {
            let nearest = response.mapItems
                .filter { !($0.name ?? "").isEmpty }
                .min {
                    location.distance(from: CLLocation(latitude: $0.placemark.coordinate.latitude, longitude: $0.placemark.coordinate.longitude))
                        < location.distance(from: CLLocation(latitude: $1.placemark.coordinate.latitude, longitude: $1.placemark.coordinate.longitude))
                }
            if let name = nearest?.name { return name }
        }
        let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first
        return placemark?.name ?? placemark?.subLocality ?? placemark?.locality
    }
}
