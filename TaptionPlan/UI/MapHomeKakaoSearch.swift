import CoreLocation
import Foundation
import MapKit

/// 국내 장소 키워드 검색(KKO1110A01). 카카오 REST 키는 서버용이라 앱에 넣지 않고, 여행 계획 중계 서버
/// (`server/trip-relay`의 `/kakao/keyword`)가 키를 붙여 대신 부른다(REV1110A03). 중계가 없거나 실패하면 빈 결과라 Apple 검색만 남는다.
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

    static var endpoint: URL? { TripRelay.host.flatMap { URL(string: "https://\($0)/kakao/keyword") } }

    static func isAvailable(at center: CLLocationCoordinate2D) -> Bool {
        endpoint != nil && isInKorea(center)
    }

    /// 입력 중 추천. 호출을 아끼려고 정확도 순 한 번만 부른다.
    static func suggestions(query: String, center: CLLocationCoordinate2D) async -> [MapHomeSearchResult] {
        guard isAvailable(at: center) else { return [] }
        return Array(await fetch(query: query, center: center, nearby: false).prefix(8))
    }

    /// 남한 본토 대략 윤곽(위도, 경도 차례). 사각형으로 보면 후쿠오카·대마도·북한까지 국내로 쳐서
    /// 해외에서 카카오가 먼 한국 결과를 돌려주고 Apple 검색으로 넘어가지 않았다(REV1110A02).
    private static let mainland: [Double] = [
        37.80, 126.15, 37.80, 126.62, 37.95, 126.68, 38.10, 127.00, 38.25, 127.30, 38.30, 127.60,
        38.32, 128.00, 38.62, 128.33, 38.62, 128.42, 38.20, 128.68, 37.75, 129.10, 37.20, 129.45,
        36.60, 129.55, 36.00, 129.70, 35.60, 129.58, 35.30, 129.38, 35.05, 129.18, 34.70, 128.80,
        34.50, 128.30, 34.00, 127.40, 33.95, 126.40, 34.00, 124.95, 34.70, 125.20, 35.50, 125.90,
        36.30, 125.90, 37.00, 125.90, 37.60, 125.95,
    ]

    /// 본토 밖 섬: 제주, 울릉·독도, 백령·대청, 연평.
    private static let islands: [(latitude: ClosedRange<Double>, longitude: ClosedRange<Double>)] = [
        (33.10...33.60, 126.10...127.00),
        (37.20...37.60, 130.70...131.95),
        (37.75...38.00, 124.55...124.85),
        (37.60...37.72, 125.55...125.80),
    ]

    static func isInKorea(_ coordinate: CLLocationCoordinate2D) -> Bool {
        islands.contains { $0.latitude.contains(coordinate.latitude) && $0.longitude.contains(coordinate.longitude) }
            || MapHomeLandmarkSite.isInside(coordinate.latitude, coordinate.longitude, ring: mainland)
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
        guard isAvailable(at: center) else { return [] }
        async let nearby = fetch(query: query, center: center, nearby: true)
        async let accurate = fetch(query: query, center: center, nearby: false)
        return await Array(nearby.prefix(nearbyLimit)) + accurate
    }

    private static func fetch(query: String, center: CLLocationCoordinate2D, nearby: Bool) async -> [MapHomeSearchResult] {
        guard let endpoint else { return [] }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "x", value: String(center.longitude)),
            URLQueryItem(name: "y", value: String(center.latitude)),
            URLQueryItem(name: "size", value: "15"),
            URLQueryItem(name: "sort", value: nearby ? "distance" : "accuracy"),
        ] + (nearby ? [URLQueryItem(name: "radius", value: String(nearbyRadiusMeters))] : [])
        guard let url = components?.url else { return [] }
        let request = URLRequest(url: url, timeoutInterval: 5)
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
