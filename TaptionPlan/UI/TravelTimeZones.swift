import Foundation
import TaptionPlanStore

/// 여행 일정의 시간대(REV1117A01, 대표 지시 2026-11-17): 출국 비행 이전은 출발지(한국) 시각, 도착부터는 여행지 시각으로 저장하고 보여 준다.
/// 비행 구간은 출발 시각을 출발지 시차로, 도착 시각을 도착지 시차로 가진다(저장은 이미 시작·끝 시차가 따로 있다). 귀국편도 같다.
/// 시간대가 없는 옛 여행은 지금처럼 읽힌다: 새로 넣는 일정만 이 규칙을 쓴다.
enum TravelTimeZones {
    /// 나라 대표 시간대. 시간대가 여럿인 나라는 가장 많이 가는 곳(수도·대표 도시)을 쓰고, 표에 없으면 nil이다.
    static let countryZones: [String: String] = [
        "KR": "Asia/Seoul", "JP": "Asia/Tokyo", "CN": "Asia/Shanghai", "TW": "Asia/Taipei", "HK": "Asia/Hong_Kong", "MO": "Asia/Macau",
        "MN": "Asia/Ulaanbaatar", "KP": "Asia/Pyongyang", "TH": "Asia/Bangkok", "VN": "Asia/Ho_Chi_Minh", "LA": "Asia/Vientiane",
        "KH": "Asia/Phnom_Penh", "MM": "Asia/Yangon", "MY": "Asia/Kuala_Lumpur", "SG": "Asia/Singapore", "ID": "Asia/Jakarta",
        "PH": "Asia/Manila", "BN": "Asia/Brunei", "TL": "Asia/Dili", "IN": "Asia/Kolkata", "NP": "Asia/Kathmandu", "LK": "Asia/Colombo",
        "BD": "Asia/Dhaka", "BT": "Asia/Thimphu", "MV": "Indian/Maldives", "PK": "Asia/Karachi", "AF": "Asia/Kabul", "UZ": "Asia/Tashkent",
        "KZ": "Asia/Almaty", "KG": "Asia/Bishkek", "TJ": "Asia/Dushanbe", "TM": "Asia/Ashgabat", "AE": "Asia/Dubai", "QA": "Asia/Qatar",
        "SA": "Asia/Riyadh", "KW": "Asia/Kuwait", "BH": "Asia/Bahrain", "OM": "Asia/Muscat", "IL": "Asia/Jerusalem", "JO": "Asia/Amman",
        "LB": "Asia/Beirut", "TR": "Europe/Istanbul", "IR": "Asia/Tehran", "IQ": "Asia/Baghdad", "GE": "Asia/Tbilisi", "AM": "Asia/Yerevan",
        "AZ": "Asia/Baku", "GB": "Europe/London", "IE": "Europe/Dublin", "FR": "Europe/Paris", "DE": "Europe/Berlin", "IT": "Europe/Rome",
        "ES": "Europe/Madrid", "PT": "Europe/Lisbon", "NL": "Europe/Amsterdam", "BE": "Europe/Brussels", "LU": "Europe/Luxembourg",
        "CH": "Europe/Zurich", "AT": "Europe/Vienna", "CZ": "Europe/Prague", "SK": "Europe/Bratislava", "PL": "Europe/Warsaw",
        "HU": "Europe/Budapest", "SI": "Europe/Ljubljana", "HR": "Europe/Zagreb", "RS": "Europe/Belgrade", "BA": "Europe/Sarajevo",
        "ME": "Europe/Podgorica", "MK": "Europe/Skopje", "AL": "Europe/Tirane", "GR": "Europe/Athens", "BG": "Europe/Sofia",
        "RO": "Europe/Bucharest", "MD": "Europe/Chisinau", "UA": "Europe/Kyiv", "BY": "Europe/Minsk", "LT": "Europe/Vilnius",
        "LV": "Europe/Riga", "EE": "Europe/Tallinn", "FI": "Europe/Helsinki", "SE": "Europe/Stockholm", "NO": "Europe/Oslo",
        "DK": "Europe/Copenhagen", "IS": "Atlantic/Reykjavik", "MT": "Europe/Malta", "CY": "Asia/Nicosia", "MC": "Europe/Monaco",
        "RU": "Europe/Moscow", "US": "America/New_York", "CA": "America/Toronto", "MX": "America/Mexico_City", "CU": "America/Havana",
        "DO": "America/Santo_Domingo", "JM": "America/Jamaica", "BS": "America/Nassau", "PA": "America/Panama", "CR": "America/Costa_Rica",
        "GT": "America/Guatemala", "CO": "America/Bogota", "PE": "America/Lima", "EC": "America/Guayaquil", "VE": "America/Caracas",
        "BR": "America/Sao_Paulo", "AR": "America/Argentina/Buenos_Aires", "CL": "America/Santiago", "UY": "America/Montevideo",
        "BO": "America/La_Paz", "PY": "America/Asuncion", "AU": "Australia/Sydney", "NZ": "Pacific/Auckland", "FJ": "Pacific/Fiji",
        "PG": "Pacific/Port_Moresby", "GU": "Pacific/Guam", "EG": "Africa/Cairo", "MA": "Africa/Casablanca", "TN": "Africa/Tunis",
        "DZ": "Africa/Algiers", "NG": "Africa/Lagos", "GH": "Africa/Accra", "KE": "Africa/Nairobi", "TZ": "Africa/Dar_es_Salaam",
        "ET": "Africa/Addis_Ababa", "UG": "Africa/Kampala", "ZA": "Africa/Johannesburg", "NA": "Africa/Windhoek", "MU": "Indian/Mauritius",
        "MG": "Indian/Antananarivo", "SC": "Indian/Mahe", "SN": "Africa/Dakar",
    ]

    static func zoneID(countryCode: String?) -> String? { countryCode.flatMap { countryZones[$0.uppercased()] } }

    /// 여행지 시간대: 저장된 값, 없으면 나라 대표 시간대, 그것도 없으면 기기 시간대(옛 여행의 지금 동작).
    static func destination(_ trip: TravelTrip) -> TimeZone {
        trip.timeZoneID.flatMap(TimeZone.init(identifier:)) ?? zoneID(countryCode: trip.countryCode).flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
    }

    /// 그 벽시계 시각(날 `yyyy-MM-dd`의 `minute`분)을 시차 없이 초로 센 값. 두 벽시계를 견줄 때만 쓴다.
    private static func wallSeconds(dayKey: String, minute: Int) -> Int? {
        guard let parts = TravelTripDay.components(dayKey) else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        return utc.date(from: parts).map { Int($0.timeIntervalSince1970) + minute * 60 }
    }

    private static func flights(_ items: [TravelTripItem], tripID: String) -> [TravelTripItem] {
        items.filter { $0.tripID == tripID && $0.kind == "flight" && $0.parentItemID == nil }.sorted { $0.start < $1.start }
    }

    private static func destinationOffset(_ trip: TravelTrip, dayKey: String) -> Int {
        let zone = destination(trip)
        let noon = wallSeconds(dayKey: dayKey, minute: 720).map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? .now
        return zone.secondsFromGMT(for: noon)
    }

    /// 손으로 넣는 일정(날 `dayKey`의 `minute`분)의 시차(초). 출국 비행이 있으면 첫 비행의 출발지 시차에서 시작해,
    /// 그 일정이 도착 벽시계 시각 이후인 비행마다 그 도착지 시차로 바뀐다. 비행 도중(도착 전)은 출발지 쪽으로 본다. 비행이 없으면 여행지 시차.
    static func offset(trip: TravelTrip, items: [TravelTripItem], dayKey: String, minute: Int) -> Int {
        let list = flights(items, tripID: trip.id)
        guard let first = list.first, let wall = wallSeconds(dayKey: dayKey, minute: minute) else { return destinationOffset(trip, dayKey: dayKey) }
        var current = first.startOffsetSeconds
        for flight in list {
            guard wall >= Int(flight.end.timeIntervalSince1970) + flight.endOffsetSeconds else { break }
            current = flight.endOffsetSeconds
        }
        return current
    }

    /// 손으로 넣는 비행의 출발지·도착지 시차. 다른 비행이 없으면 출발은 집(`home`), 도착은 여행지.
    /// 있으면 출발은 그 시각의 시차(`offset`)이고, 여행지에서 떠나는 비행이면 도착은 집(첫 비행의 출발지), 아니면 여행지다.
    static func flightOffsets(
        trip: TravelTrip, items: [TravelTripItem], dayKey: String, minute: Int, home: TimeZone = .autoupdatingCurrent
    ) -> (start: Int, end: Int) {
        let destination = destinationOffset(trip, dayKey: dayKey)
        let list = flights(items, tripID: trip.id)
        guard let first = list.first else {
            let noon = wallSeconds(dayKey: dayKey, minute: 720).map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? .now
            return (home.secondsFromGMT(for: noon), destination)
        }
        let start = offset(trip: trip, items: items, dayKey: dayKey, minute: minute)
        return (start, start == destination ? first.startOffsetSeconds : destination)
    }
}
