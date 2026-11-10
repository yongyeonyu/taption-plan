import CoreLocation
import Foundation
import MapKit

/// 국내 장소 키워드 검색(KKO1110A01). 키가 없거나 실패하면 빈 결과라 Apple 검색만 남는다.
/// 좌표는 실시간 표시에만 쓴다. 저장할 때는 `MapHomeSearchRunner.appleCoordinate`로 다시 받는다.
enum MapHomeKakaoSearch {
    private struct Response: Decodable {
        struct Place: Decodable {
            let place_name: String
            let road_address_name: String?
            let address_name: String?
            let x: String
            let y: String
        }

        let documents: [Place]
    }

    private static let nearbyLimit = 5
    private static let nearbyRadiusMeters = 20_000

    static var apiKey: String {
        (Bundle.main.object(forInfoDictionaryKey: "KAKAO_REST_API_KEY") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func isAvailable(at center: CLLocationCoordinate2D) -> Bool {
        !apiKey.isEmpty && isInKorea(center)
    }

    /// 입력 중 추천. 호출을 아끼려고 정확도 순 한 번만 부른다.
    static func suggestions(query: String, center: CLLocationCoordinate2D) async -> [MapHomeSearchResult] {
        guard isAvailable(at: center) else { return [] }
        return Array(await fetch(query: query, center: center, nearby: false).prefix(8))
    }

    static func isInKorea(_ coordinate: CLLocationCoordinate2D) -> Bool {
        (33...39).contains(coordinate.latitude) && (124...132).contains(coordinate.longitude)
    }

    static func decode(_ data: Data) -> [MapHomeSearchResult] {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return response.documents.compactMap { place in
            guard let longitude = Double(place.x), let latitude = Double(place.y) else { return nil }
            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
            let address = [place.road_address_name, place.address_name].compactMap { $0 }.first { !$0.isEmpty }
            return MapHomeSearchResult(title: place.place_name, subtitle: address ?? "", coordinate: coordinate, isLiveOnly: true)
        }
    }

    /// 가까운 곳을 먼저 두고 정확도 순 결과를 잇는다. 이름만 맞는 먼 곳과 가까운 체인점을 함께 찾는다.
    static func search(query: String, center: CLLocationCoordinate2D) async -> [MapHomeSearchResult] {
        guard !apiKey.isEmpty, isInKorea(center) else { return [] }
        async let nearby = fetch(query: query, center: center, nearby: true)
        async let accurate = fetch(query: query, center: center, nearby: false)
        return await Array(nearby.prefix(nearbyLimit)) + accurate
    }

    private static func fetch(query: String, center: CLLocationCoordinate2D, nearby: Bool) async -> [MapHomeSearchResult] {
        var components = URLComponents(string: "https://dapi.kakao.com/v2/local/search/keyword.json")
        components?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "x", value: String(center.longitude)),
            URLQueryItem(name: "y", value: String(center.latitude)),
            URLQueryItem(name: "size", value: "15"),
            URLQueryItem(name: "sort", value: nearby ? "distance" : "accuracy"),
        ] + (nearby ? [URLQueryItem(name: "radius", value: String(nearbyRadiusMeters))] : [])
        guard let url = components?.url else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue("KakaoAK \(apiKey)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return decode(data)
    }
}

extension MapHomeSearchRunner {
    /// 이 안에 있는 Apple 결과만 같은 장소로 본다.
    static let samePlaceMeters: CLLocationDistance = 300

    /// 저장용 좌표. 같은 이름의 Apple 결과가 가까이 있을 때만 돌려준다.
    static func appleCoordinate(for result: MapHomeSearchResult) async -> CLLocationCoordinate2D? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = result.title
        request.region = MKCoordinateRegion(center: result.coordinate, latitudinalMeters: 2_000, longitudinalMeters: 2_000)
        guard let items = try? await MKLocalSearch(request: request).start().mapItems else { return nil }
        let origin = CLLocation(latitude: result.coordinate.latitude, longitude: result.coordinate.longitude)
        return items.map(\.placemark.coordinate).first {
            origin.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) <= samePlaceMeters
        }
    }
}
