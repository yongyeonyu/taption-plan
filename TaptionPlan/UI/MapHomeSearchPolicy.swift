import CoreLocation
import MapKit

/// 지도 검색의 범위와 앱 안 자료(등록 장소·지하철역) 찾기(SRC1107A01).
enum MapHomeSearchPolicy {
    /// 크게 확대해 있어도 이만큼은 찾는다. 좁은 화면 범위만 주면 Apple 검색이 결과를 거의 내지 않는다.
    static let minimumSpanDegrees = 0.25
    static let localLimit = 5

    /// 보고 있는 지도 가운데를 기준으로 찾는다. 지도를 아직 모르면 현재 위치를 쓴다.
    static func region(visibleCenter: CLLocationCoordinate2D, visibleSpan: MKCoordinateSpan, current: CLLocationCoordinate2D?) -> MKCoordinateRegion {
        let hasVisible = visibleCenter.latitude != 0 || visibleCenter.longitude != 0
        let center = hasVisible ? visibleCenter : (current ?? visibleCenter)
        let span = MKCoordinateSpan(
            latitudeDelta: max(visibleSpan.latitudeDelta, minimumSpanDegrees),
            longitudeDelta: max(visibleSpan.longitudeDelta, minimumSpanDegrees)
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    /// 이름에 검색어가 든 등록 장소와 지하철역. 등록 장소가 먼저다.
    static func localMatches(_ query: String, places: [FrequentPlace], language: MapHomeLanguage) -> [MapHomeSearchResult] {
        let key = normalized(query)
        guard key.count >= 1 else { return [] }
        var seen = Set<String>()
        var result: [MapHomeSearchResult] = []
        for place in places {
            guard let point = place.point, normalized(place.displayName).contains(key),
                  seen.insert(normalized(place.displayName)).inserted else { continue }
            result.append(MapHomeSearchResult(
                title: place.displayName,
                subtitle: language.text("등록한 장소", "Saved place"),
                coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
            ))
        }
        for station in SubwayStationCatalog.stations {
            guard result.count < localLimit, let point = station.coordinate,
                  normalized(station.stationName).contains(key),
                  seen.insert(normalized(station.stationName)).inserted else { continue }
            result.append(MapHomeSearchResult(
                title: station.stationName,
                subtitle: language.text("지하철역 · \(station.lineName)", "Subway station · \(station.lineName)"),
                coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
            ))
        }
        return Array(result.prefix(localLimit))
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: " ", with: "")
    }
}
