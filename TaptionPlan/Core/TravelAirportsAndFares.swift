import CoreLocation
import TaptionPlanEngine

/// 공항 좌표표(TAU1111A01). AI가 항공편 위치를 비워 보내도 도착 공항 코드(IATA)로 지도에 놓고 대권 선을 그린다.
/// 한국 여행자가 많이 쓰는 공항만 담는다. 좌표는 여객 터미널 부근(소수 둘째 자리, 지도 선 그리기용).
enum TravelAirports {
    static func coordinate(_ code: String?) -> CLLocationCoordinate2D? {
        guard let code = code?.trimmingCharacters(in: .whitespaces).uppercased(), let value = table[code] else { return nil }
        return CLLocationCoordinate2D(latitude: value.0, longitude: value.1)
    }

    static let table: [String: (Double, Double)] = [
        // 한국
        "ICN": (37.46, 126.44), "GMP": (37.56, 126.80), "PUS": (35.18, 128.94), "CJU": (33.51, 126.49),
        "TAE": (35.90, 128.64), "CJJ": (36.72, 127.50), "KWJ": (35.14, 126.81), "RSU": (34.84, 127.62),
        "USN": (35.59, 129.35), "MWX": (34.99, 126.38), "YNY": (38.06, 128.67), "KPO": (35.99, 129.42),
        // 일본
        "NRT": (35.77, 140.39), "HND": (35.55, 139.78), "KIX": (34.43, 135.24), "ITM": (34.79, 135.44),
        "NGO": (34.86, 136.81), "FUK": (33.59, 130.45), "CTS": (42.78, 141.69), "OKA": (26.20, 127.65),
        "KOJ": (31.80, 130.72), "KMJ": (32.84, 130.86), "OIT": (33.48, 131.74), "SDJ": (38.14, 140.92),
        // 중국·홍콩·마카오·대만
        "PEK": (40.08, 116.58), "PKX": (39.51, 116.41), "PVG": (31.14, 121.81), "SHA": (31.20, 121.34),
        "CAN": (23.39, 113.30), "SZX": (22.64, 113.81), "TAO": (36.36, 120.09), "SHE": (41.64, 123.48),
        "HKG": (22.31, 113.92), "MFM": (22.15, 113.59), "TPE": (25.08, 121.23), "TSA": (25.07, 121.55),
        "KHH": (22.58, 120.35),
        // 동남아시아
        "BKK": (13.69, 100.75), "DMK": (13.91, 100.61), "HKT": (8.11, 98.31), "CNX": (18.77, 98.96),
        "SGN": (10.82, 106.66), "HAN": (21.22, 105.81), "DAD": (16.05, 108.20), "CXR": (12.01, 109.22),
        "PQC": (10.17, 103.99), "MNL": (14.51, 121.02), "CEB": (10.31, 123.98), "SIN": (1.36, 103.99),
        "KUL": (2.75, 101.71), "BKI": (5.94, 116.05), "DPS": (-8.75, 115.17), "CGK": (-6.13, 106.66),
        // 괌·사이판·몽골
        "GUM": (13.49, 144.80), "SPN": (15.12, 145.73), "UBN": (47.65, 106.82),
        // 미주
        "LAX": (33.94, -118.41), "SFO": (37.62, -122.38), "SEA": (47.45, -122.31), "JFK": (40.64, -73.78),
        "EWR": (40.69, -74.17), "ORD": (41.98, -87.90), "ATL": (33.64, -84.43), "HNL": (21.32, -157.92),
        "LAS": (36.08, -115.15), "YVR": (49.19, -123.18), "YYZ": (43.68, -79.63),
        // 유럽·중동
        "LHR": (51.47, -0.45), "CDG": (49.01, 2.55), "FRA": (50.04, 8.56), "AMS": (52.31, 4.76),
        "FCO": (41.80, 12.25), "MXP": (45.63, 8.72), "MAD": (40.49, -3.57), "BCN": (41.30, 2.08),
        "MUC": (48.35, 11.79), "ZRH": (47.46, 8.55), "VIE": (48.11, 16.57), "PRG": (50.10, 14.26),
        "IST": (41.26, 28.74), "DXB": (25.25, 55.36), "DOH": (25.27, 51.61),
        // 오세아니아
        "SYD": (-33.94, 151.18), "MEL": (-37.67, 144.84), "BNE": (-27.38, 153.12), "AKL": (-37.01, 174.79),
    ]
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
