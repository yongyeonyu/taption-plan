import CoreLocation
import TaptionPlanEngine

/// 공항 좌표(TAU1111A01). AI가 항공편 위치를 비워 보내도 도착 공항 코드(IATA)로 지도에 놓고 대권 선을 그린다.
/// 좌표의 정본은 `FlightAirportCatalog`(FLT1119A01, 좌표·시간대·이름)다. 이 표를 따로 두지 않는다.
enum TravelAirports {
    static func coordinate(_ code: String?) -> CLLocationCoordinate2D? {
        guard let airport = FlightAirportCatalog.airport(code) else { return nil }
        return CLLocationCoordinate2D(latitude: airport.latitude, longitude: airport.longitude)
    }
}

/// 대중교통 구간 예상 요금(TAU1111A01). 요금표가 있는 지역(수도권·대구) 안의 지하철·버스 이동만 계산한다.
/// 거리는 직선 거리 ×1.2(미리보기 이동 시간 어림과 같은 여유). 요금표 밖이면 nil.
enum TravelFareEstimate {
    static let routeFactor = 1.2

    /// 가져온 이동 수단 이름을 요금표 수단으로. 「transit」은 거리 비례 전철 요금으로 어림한다.
    static func tableMode(_ mode: String?, region: String) -> String? {
        switch mode?.lowercased() {
        case "transit", "subway", "metro", "train", "rail": "rail"
        case "bus": region == "수도권" ? "서울_간선지선" : "rail"
        default: nil
        }
    }

    static func region(_ coordinate: CLLocationCoordinate2D) -> String? {
        let (lat, lng) = (coordinate.latitude, coordinate.longitude)
        if (36.9...38.3).contains(lat), (126.3...127.9).contains(lng) { return "수도권" }
        if (35.6...36.2).contains(lat), (128.3...129.0).contains(lng) { return "대구" }
        return nil
    }

    static func won(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D, mode: String?,
                    calculator: FareCalculator? = .bundled) -> Int? {
        guard let region = region(a), region == self.region(b), let tableMode = tableMode(mode, region: region), let calculator else { return nil }
        let km = CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)) / 1_000 * routeFactor
        guard km >= 0.5 else { return nil }
        return calculator.fare(region: region, mode: tableMode, distanceKm: km)
    }
}

extension TravelFareEstimate {
    /// 가져온 여행 일정에서 앞 일정 → 다음 일정 대중교통 구간의 예상 요금(원). 다음 일정 id로 찾는다.
    static func fares(_ items: [TripImportItem], calculator: FareCalculator? = .bundled) -> [String: Int] {
        var result: [String: Int] = [:]
        let sorted = items.sorted { $0.start < $1.start }
        for (previous, next) in zip(sorted, sorted.dropFirst()) {
            guard let a = previous.coordinate, let b = next.coordinate,
                  let won = won(from: a, to: b, mode: next.travelMode, calculator: calculator) else { continue }
            result[next.id] = won
        }
        return result
    }
}
