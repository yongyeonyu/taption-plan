import Foundation

/// 공항 하나의 정본 정보. 좌표·IANA 시간대·이름·나라(ISO 3166-1 alpha-2, 영토는 그 코드).
public struct FlightAirport: Hashable, Sendable {
    public let code: String
    public let latitude: Double
    public let longitude: Double
    /// `TimeZone(identifier:)`로 풀리는 IANA 이름. 서머타임·날짜변경선은 `FlightTimeMath`가 이 이름으로 처리한다.
    public let timeZone: String
    public let nameKo: String
    public let nameEn: String
    public let country: String
}

/// 전 세계 공항 경량 번들(FLT1119A01). 한국 여행자가 실제로 쓰는 범위와 환승 허브만 담는다.
/// 공항 좌표·시간대의 정본이다. 앱의 `TravelAirports.coordinate`도 이 표를 본다(좌표는 지도 선 그리기용, 소수 둘째 자리).
public enum FlightAirportCatalog {
    public static func airport(_ code: String?) -> FlightAirport? {
        guard let code = code?.trimmingCharacters(in: .whitespaces).uppercased(), code.count == 3 else { return nil }
        return index[code]
    }

    public static var all: [FlightAirport] { airports }

    /// 한국 공항(국내선 판정·국내 조회 대상).
    public static var korea: [FlightAirport] { airports.filter { $0.country == "KR" } }

    /// 같은 나라 안 구간이면 국내선.
    public static func isDomestic(from origin: String, to destination: String) -> Bool? {
        guard let a = airport(origin), let b = airport(destination) else { return nil }
        return a.country == b.country
    }

    /// 알림글에 적힌 도시 이름(「인천」「방콕」「Bangkok」)으로 공항 하나. 이름이 정확히 같거나 「이름 + 공백」으로 시작하는 첫 공항
    /// (같은 도시의 공항이 여럿이면 표에서 먼저 나오는 큰 공항). 공항 이름의 일부만 같은 것(「서」)은 맞추지 않는다.
    public static func airport(city name: String) -> FlightAirport? {
        let text = name.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else { return nil }
        let lower = text.lowercased()
        return airports.first { $0.nameKo == text || $0.nameKo.hasPrefix(text + " ") || $0.nameEn.lowercased() == lower || $0.nameEn.lowercased().hasPrefix(lower + " ") }
    }

    /// 코드·한글 이름·영문 이름 일부로 찾는다(대소문자 무시). 코드가 정확히 맞으면 맨 앞.
    public static func search(_ query: String, limit: Int = 20) -> [FlightAirport] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return [] }
        let exact = airports.filter { $0.code.lowercased() == text }
        let rest = airports.filter {
            $0.code.lowercased() != text
                && ($0.code.lowercased().hasPrefix(text) || $0.nameKo.lowercased().contains(text) || $0.nameEn.lowercased().contains(text))
        }
        return Array((exact + rest).prefix(limit))
    }

    private static let index: [String: FlightAirport] = Dictionary(uniqueKeysWithValues: airports.map { ($0.code, $0) })

    private static func a(_ code: String, _ lat: Double, _ lon: Double, _ zone: String, _ ko: String, _ en: String, _ country: String) -> FlightAirport {
        FlightAirport(code: code, latitude: lat, longitude: lon, timeZone: zone, nameKo: ko, nameEn: en, country: country)
    }

    private static let airports: [FlightAirport] = [
        a("ICN", 37.46, 126.44, "Asia/Seoul", "인천", "Incheon", "KR"),
        a("GMP", 37.56, 126.80, "Asia/Seoul", "김포", "Gimpo", "KR"),
        a("PUS", 35.18, 128.94, "Asia/Seoul", "부산 김해", "Busan Gimhae", "KR"),
        a("CJU", 33.51, 126.49, "Asia/Seoul", "제주", "Jeju", "KR"),
        a("TAE", 35.90, 128.64, "Asia/Seoul", "대구", "Daegu", "KR"),
        a("CJJ", 36.72, 127.50, "Asia/Seoul", "청주", "Cheongju", "KR"),
        a("KWJ", 35.14, 126.81, "Asia/Seoul", "광주", "Gwangju", "KR"),
        a("RSU", 34.84, 127.62, "Asia/Seoul", "여수", "Yeosu", "KR"),
        a("USN", 35.59, 129.35, "Asia/Seoul", "울산", "Ulsan", "KR"),
        a("MWX", 34.99, 126.38, "Asia/Seoul", "무안", "Muan", "KR"),
        a("YNY", 38.06, 128.67, "Asia/Seoul", "양양", "Yangyang", "KR"),
        a("KPO", 35.99, 129.42, "Asia/Seoul", "포항경주", "Pohang Gyeongju", "KR"),
        a("HIN", 35.09, 128.07, "Asia/Seoul", "사천", "Sacheon", "KR"),
        a("KUV", 35.90, 126.62, "Asia/Seoul", "군산", "Gunsan", "KR"),
        a("WJU", 37.44, 127.96, "Asia/Seoul", "원주", "Wonju", "KR"),
        a("NRT", 35.77, 140.39, "Asia/Tokyo", "도쿄 나리타", "Tokyo Narita", "JP"),
        a("HND", 35.55, 139.78, "Asia/Tokyo", "도쿄 하네다", "Tokyo Haneda", "JP"),
        a("KIX", 34.43, 135.24, "Asia/Tokyo", "오사카 간사이", "Osaka Kansai", "JP"),
        a("ITM", 34.79, 135.44, "Asia/Tokyo", "오사카 이타미", "Osaka Itami", "JP"),
        a("UKB", 34.63, 135.22, "Asia/Tokyo", "고베", "Kobe", "JP"),
        a("NGO", 34.86, 136.81, "Asia/Tokyo", "나고야 주부", "Nagoya Chubu", "JP"),
        a("FUK", 33.59, 130.45, "Asia/Tokyo", "후쿠오카", "Fukuoka", "JP"),
        a("CTS", 42.78, 141.69, "Asia/Tokyo", "삿포로 신치토세", "Sapporo New Chitose", "JP"),
        a("OKA", 26.20, 127.65, "Asia/Tokyo", "오키나와 나하", "Okinawa Naha", "JP"),
        a("ISG", 24.34, 124.19, "Asia/Tokyo", "이시가키", "Ishigaki", "JP"),
        a("KOJ", 31.80, 130.72, "Asia/Tokyo", "가고시마", "Kagoshima", "JP"),
        a("KMJ", 32.84, 130.86, "Asia/Tokyo", "구마모토", "Kumamoto", "JP"),
        a("OIT", 33.48, 131.74, "Asia/Tokyo", "오이타", "Oita", "JP"),
        a("NGS", 32.92, 129.91, "Asia/Tokyo", "나가사키", "Nagasaki", "JP"),
        a("SDJ", 38.14, 140.92, "Asia/Tokyo", "센다이", "Sendai", "JP"),
        a("HIJ", 34.44, 132.92, "Asia/Tokyo", "히로시마", "Hiroshima", "JP"),
        a("OKJ", 34.76, 133.86, "Asia/Tokyo", "오카야마", "Okayama", "JP"),
        a("TAK", 34.21, 134.02, "Asia/Tokyo", "다카마쓰", "Takamatsu", "JP"),
        a("MYJ", 33.83, 132.70, "Asia/Tokyo", "마쓰야마", "Matsuyama", "JP"),
        a("KMQ", 36.39, 136.41, "Asia/Tokyo", "고마쓰", "Komatsu", "JP"),
        a("TOY", 36.65, 137.19, "Asia/Tokyo", "도야마", "Toyama", "JP"),
        a("KIJ", 37.96, 139.12, "Asia/Tokyo", "니가타", "Niigata", "JP"),
        a("AOJ", 40.73, 140.69, "Asia/Tokyo", "아오모리", "Aomori", "JP"),
        a("HKD", 41.77, 140.82, "Asia/Tokyo", "하코다테", "Hakodate", "JP"),
        a("AKJ", 43.67, 142.45, "Asia/Tokyo", "아사히카와", "Asahikawa", "JP"),
        a("PEK", 40.08, 116.58, "Asia/Shanghai", "베이징 서우두", "Beijing Capital", "CN"),
        a("PKX", 39.51, 116.41, "Asia/Shanghai", "베이징 다싱", "Beijing Daxing", "CN"),
        a("PVG", 31.14, 121.81, "Asia/Shanghai", "상하이 푸둥", "Shanghai Pudong", "CN"),
        a("SHA", 31.20, 121.34, "Asia/Shanghai", "상하이 훙차오", "Shanghai Hongqiao", "CN"),
        a("CAN", 23.39, 113.30, "Asia/Shanghai", "광저우", "Guangzhou", "CN"),
        a("SZX", 22.64, 113.81, "Asia/Shanghai", "선전", "Shenzhen", "CN"),
        a("TAO", 36.36, 120.09, "Asia/Shanghai", "칭다오", "Qingdao", "CN"),
        a("SHE", 41.64, 123.48, "Asia/Shanghai", "선양", "Shenyang", "CN"),
        a("CTU", 30.58, 103.95, "Asia/Shanghai", "청두 솽류", "Chengdu Shuangliu", "CN"),
        a("TFU", 30.31, 104.44, "Asia/Shanghai", "청두 톈푸", "Chengdu Tianfu", "CN"),
        a("XIY", 34.45, 108.75, "Asia/Shanghai", "시안", "Xi'an", "CN"),
        a("CKG", 29.72, 106.64, "Asia/Shanghai", "충칭", "Chongqing", "CN"),
        a("HGH", 30.23, 120.43, "Asia/Shanghai", "항저우", "Hangzhou", "CN"),
        a("NKG", 31.74, 118.86, "Asia/Shanghai", "난징", "Nanjing", "CN"),
        a("WUH", 30.78, 114.21, "Asia/Shanghai", "우한", "Wuhan", "CN"),
        a("TSN", 39.12, 117.35, "Asia/Shanghai", "톈진", "Tianjin", "CN"),
        a("DLC", 38.97, 121.54, "Asia/Shanghai", "다롄", "Dalian", "CN"),
        a("HRB", 45.62, 126.25, "Asia/Shanghai", "하얼빈", "Harbin", "CN"),
        a("KMG", 25.10, 102.93, "Asia/Shanghai", "쿤밍", "Kunming", "CN"),
        a("XMN", 24.54, 118.13, "Asia/Shanghai", "샤먼", "Xiamen", "CN"),
        a("CSX", 28.19, 113.22, "Asia/Shanghai", "창사", "Changsha", "CN"),
        a("HAK", 19.93, 110.46, "Asia/Shanghai", "하이커우", "Haikou", "CN"),
        a("SYX", 18.30, 109.41, "Asia/Shanghai", "싼야", "Sanya", "CN"),
        a("YNJ", 42.88, 129.45, "Asia/Shanghai", "옌지", "Yanji", "CN"),
        a("TNA", 36.86, 117.22, "Asia/Shanghai", "지난", "Jinan", "CN"),
        a("CGO", 34.52, 113.84, "Asia/Shanghai", "정저우", "Zhengzhou", "CN"),
        a("URC", 43.91, 87.47, "Asia/Urumqi", "우루무치", "Urumqi", "CN"),
        a("HKG", 22.31, 113.92, "Asia/Hong_Kong", "홍콩", "Hong Kong", "HK"),
        a("MFM", 22.15, 113.59, "Asia/Macau", "마카오", "Macau", "MO"),
        a("TPE", 25.08, 121.23, "Asia/Taipei", "타이베이 타오위안", "Taipei Taoyuan", "TW"),
        a("TSA", 25.07, 121.55, "Asia/Taipei", "타이베이 쑹산", "Taipei Songshan", "TW"),
        a("KHH", 22.58, 120.35, "Asia/Taipei", "가오슝", "Kaohsiung", "TW"),
        a("RMQ", 24.26, 120.62, "Asia/Taipei", "타이중", "Taichung", "TW"),
        a("BKK", 13.69, 100.75, "Asia/Bangkok", "방콕 수완나품", "Bangkok Suvarnabhumi", "TH"),
        a("DMK", 13.91, 100.61, "Asia/Bangkok", "방콕 돈므앙", "Bangkok Don Mueang", "TH"),
        a("HKT", 8.11, 98.31, "Asia/Bangkok", "푸켓", "Phuket", "TH"),
        a("CNX", 18.77, 98.96, "Asia/Bangkok", "치앙마이", "Chiang Mai", "TH"),
        a("CEI", 19.95, 99.88, "Asia/Bangkok", "치앙라이", "Chiang Rai", "TH"),
        a("HDY", 6.93, 100.39, "Asia/Bangkok", "핫야이", "Hat Yai", "TH"),
        a("USM", 9.55, 100.06, "Asia/Bangkok", "코사무이", "Koh Samui", "TH"),
        a("KBV", 8.10, 98.99, "Asia/Bangkok", "끄라비", "Krabi", "TH"),
        a("UTP", 12.68, 101.01, "Asia/Bangkok", "파타야 우타파오", "Pattaya U-Tapao", "TH"),
        a("SGN", 10.82, 106.66, "Asia/Ho_Chi_Minh", "호찌민", "Ho Chi Minh City", "VN"),
        a("HAN", 21.22, 105.81, "Asia/Ho_Chi_Minh", "하노이", "Hanoi", "VN"),
        a("DAD", 16.05, 108.20, "Asia/Ho_Chi_Minh", "다낭", "Da Nang", "VN"),
        a("CXR", 12.01, 109.22, "Asia/Ho_Chi_Minh", "나트랑 캄란", "Nha Trang Cam Ranh", "VN"),
        a("PQC", 10.17, 103.99, "Asia/Ho_Chi_Minh", "푸꾸옥", "Phu Quoc", "VN"),
        a("HUI", 16.40, 107.70, "Asia/Ho_Chi_Minh", "후에", "Hue", "VN"),
        a("UIH", 13.95, 109.04, "Asia/Ho_Chi_Minh", "꾸이년", "Quy Nhon", "VN"),
        a("HPH", 20.82, 106.72, "Asia/Ho_Chi_Minh", "하이퐁", "Hai Phong", "VN"),
        a("REP", 13.41, 103.81, "Asia/Phnom_Penh", "씨엠립", "Siem Reap", "KH"),
        a("PNH", 11.55, 104.84, "Asia/Phnom_Penh", "프놈펜", "Phnom Penh", "KH"),
        a("VTE", 17.99, 102.56, "Asia/Vientiane", "비엔티안", "Vientiane", "LA"),
        a("LPQ", 19.90, 102.16, "Asia/Vientiane", "루앙프라방", "Luang Prabang", "LA"),
        a("RGN", 16.91, 96.13, "Asia/Yangon", "양곤", "Yangon", "MM"),
        a("MNL", 14.51, 121.02, "Asia/Manila", "마닐라", "Manila", "PH"),
        a("CRK", 15.19, 120.56, "Asia/Manila", "클락", "Clark", "PH"),
        a("CEB", 10.31, 123.98, "Asia/Manila", "세부", "Cebu", "PH"),
        a("KLO", 11.68, 122.38, "Asia/Manila", "칼리보(보라카이)", "Kalibo (Boracay)", "PH"),
        a("MPH", 11.92, 121.95, "Asia/Manila", "카티클란(보라카이)", "Caticlan (Boracay)", "PH"),
        a("USU", 12.12, 120.10, "Asia/Manila", "코론", "Coron", "PH"),
        a("SIN", 1.36, 103.99, "Asia/Singapore", "싱가포르 창이", "Singapore Changi", "SG"),
        a("KUL", 2.75, 101.71, "Asia/Kuala_Lumpur", "쿠알라룸푸르", "Kuala Lumpur", "MY"),
        a("BKI", 5.94, 116.05, "Asia/Kuching", "코타키나발루", "Kota Kinabalu", "MY"),
        a("PEN", 5.30, 100.28, "Asia/Kuala_Lumpur", "페낭", "Penang", "MY"),
        a("LGK", 6.33, 99.73, "Asia/Kuala_Lumpur", "랑카위", "Langkawi", "MY"),
        a("KCH", 1.49, 110.34, "Asia/Kuching", "쿠칭", "Kuching", "MY"),
        a("BWN", 4.94, 114.93, "Asia/Brunei", "브루나이", "Brunei", "BN"),
        a("DPS", -8.75, 115.17, "Asia/Makassar", "발리 덴파사르", "Bali Denpasar", "ID"),
        a("LOP", -8.76, 116.28, "Asia/Makassar", "롬복", "Lombok", "ID"),
        a("UPG", -5.06, 119.55, "Asia/Makassar", "마카사르", "Makassar", "ID"),
        a("CGK", -6.13, 106.66, "Asia/Jakarta", "자카르타", "Jakarta", "ID"),
        a("SUB", -7.38, 112.79, "Asia/Jakarta", "수라바야", "Surabaya", "ID"),
        a("JOG", -7.79, 110.43, "Asia/Jakarta", "족자카르타", "Yogyakarta", "ID"),
        a("GUM", 13.49, 144.80, "Pacific/Guam", "괌", "Guam", "GU"),
        a("SPN", 15.12, 145.73, "Pacific/Saipan", "사이판", "Saipan", "MP"),
        a("UBN", 47.65, 106.82, "Asia/Ulaanbaatar", "울란바토르", "Ulaanbaatar", "MN"),
        a("VVO", 43.40, 132.15, "Asia/Vladivostok", "블라디보스토크", "Vladivostok", "RU"),
        a("TAS", 41.26, 69.28, "Asia/Tashkent", "타슈켄트", "Tashkent", "UZ"),
        a("ALA", 43.35, 77.04, "Asia/Almaty", "알마티", "Almaty", "KZ"),
        a("DEL", 28.56, 77.10, "Asia/Kolkata", "델리", "Delhi", "IN"),
        a("BOM", 19.09, 72.87, "Asia/Kolkata", "뭄바이", "Mumbai", "IN"),
        a("BLR", 13.20, 77.71, "Asia/Kolkata", "방갈로르", "Bengaluru", "IN"),
        a("MAA", 12.99, 80.17, "Asia/Kolkata", "첸나이", "Chennai", "IN"),
        a("CCU", 22.65, 88.45, "Asia/Kolkata", "콜카타", "Kolkata", "IN"),
        a("HYD", 17.24, 78.43, "Asia/Kolkata", "하이데라바드", "Hyderabad", "IN"),
        a("GOI", 15.38, 73.83, "Asia/Kolkata", "고아", "Goa", "IN"),
        a("KTM", 27.70, 85.36, "Asia/Kathmandu", "카트만두", "Kathmandu", "NP"),
        a("CMB", 7.18, 79.88, "Asia/Colombo", "콜롬보", "Colombo", "LK"),
        a("MLE", 4.19, 73.53, "Indian/Maldives", "몰디브 말레", "Maldives Male", "MV"),
        a("DAC", 23.84, 90.40, "Asia/Dhaka", "다카", "Dhaka", "BD"),
        a("LAX", 33.94, -118.41, "America/Los_Angeles", "로스앤젤레스", "Los Angeles", "US"),
        a("SFO", 37.62, -122.38, "America/Los_Angeles", "샌프란시스코", "San Francisco", "US"),
        a("SAN", 32.73, -117.19, "America/Los_Angeles", "샌디에이고", "San Diego", "US"),
        a("SEA", 47.45, -122.31, "America/Los_Angeles", "시애틀", "Seattle", "US"),
        a("PDX", 45.59, -122.60, "America/Los_Angeles", "포틀랜드", "Portland", "US"),
        a("LAS", 36.08, -115.15, "America/Los_Angeles", "라스베이거스", "Las Vegas", "US"),
        a("PHX", 33.43, -112.01, "America/Phoenix", "피닉스", "Phoenix", "US"),
        a("DEN", 39.86, -104.67, "America/Denver", "덴버", "Denver", "US"),
        a("DFW", 32.90, -97.04, "America/Chicago", "댈러스", "Dallas Fort Worth", "US"),
        a("IAH", 29.98, -95.34, "America/Chicago", "휴스턴", "Houston", "US"),
        a("ORD", 41.98, -87.90, "America/Chicago", "시카고", "Chicago", "US"),
        a("MSP", 44.88, -93.22, "America/Chicago", "미니애폴리스", "Minneapolis", "US"),
        a("ATL", 33.64, -84.43, "America/New_York", "애틀랜타", "Atlanta", "US"),
        a("JFK", 40.64, -73.78, "America/New_York", "뉴욕 JFK", "New York JFK", "US"),
        a("EWR", 40.69, -74.17, "America/New_York", "뉴욕 뉴어크", "New York Newark", "US"),
        a("BOS", 42.36, -71.01, "America/New_York", "보스턴", "Boston", "US"),
        a("IAD", 38.95, -77.46, "America/New_York", "워싱턴 덜레스", "Washington Dulles", "US"),
        a("MIA", 25.79, -80.29, "America/New_York", "마이애미", "Miami", "US"),
        a("DTW", 42.21, -83.35, "America/Detroit", "디트로이트", "Detroit", "US"),
        a("ANC", 61.17, -150.00, "America/Anchorage", "앵커리지", "Anchorage", "US"),
        a("HNL", 21.32, -157.92, "Pacific/Honolulu", "호놀룰루", "Honolulu", "US"),
        a("OGG", 20.90, -156.43, "Pacific/Honolulu", "마우이", "Maui", "US"),
        a("KOA", 19.74, -156.05, "Pacific/Honolulu", "코나", "Kona", "US"),
        a("YVR", 49.19, -123.18, "America/Vancouver", "밴쿠버", "Vancouver", "CA"),
        a("YYC", 51.11, -114.02, "America/Edmonton", "캘거리", "Calgary", "CA"),
        a("YYZ", 43.68, -79.63, "America/Toronto", "토론토", "Toronto", "CA"),
        a("YUL", 45.47, -73.74, "America/Toronto", "몬트리올", "Montreal", "CA"),
        a("MEX", 19.44, -99.07, "America/Mexico_City", "멕시코시티", "Mexico City", "MX"),
        a("CUN", 21.04, -86.87, "America/Cancun", "칸쿤", "Cancun", "MX"),
        a("PTY", 9.07, -79.38, "America/Panama", "파나마시티", "Panama City", "PA"),
        a("BOG", 4.70, -74.15, "America/Bogota", "보고타", "Bogota", "CO"),
        a("LIM", -12.02, -77.11, "America/Lima", "리마", "Lima", "PE"),
        a("SCL", -33.39, -70.79, "America/Santiago", "산티아고", "Santiago", "CL"),
        a("EZE", -34.82, -58.54, "America/Argentina/Buenos_Aires", "부에노스아이레스", "Buenos Aires", "AR"),
        a("GRU", -23.43, -46.47, "America/Sao_Paulo", "상파울루", "Sao Paulo", "BR"),
        a("LHR", 51.47, -0.45, "Europe/London", "런던 히스로", "London Heathrow", "GB"),
        a("LGW", 51.15, -0.18, "Europe/London", "런던 개트윅", "London Gatwick", "GB"),
        a("MAN", 53.35, -2.27, "Europe/London", "맨체스터", "Manchester", "GB"),
        a("EDI", 55.95, -3.37, "Europe/London", "에든버러", "Edinburgh", "GB"),
        a("DUB", 53.42, -6.27, "Europe/Dublin", "더블린", "Dublin", "IE"),
        a("CDG", 49.01, 2.55, "Europe/Paris", "파리 샤를드골", "Paris Charles de Gaulle", "FR"),
        a("ORY", 48.72, 2.38, "Europe/Paris", "파리 오를리", "Paris Orly", "FR"),
        a("FRA", 50.04, 8.56, "Europe/Berlin", "프랑크푸르트", "Frankfurt", "DE"),
        a("MUC", 48.35, 11.79, "Europe/Berlin", "뮌헨", "Munich", "DE"),
        a("BER", 52.36, 13.50, "Europe/Berlin", "베를린", "Berlin", "DE"),
        a("DUS", 51.29, 6.77, "Europe/Berlin", "뒤셀도르프", "Dusseldorf", "DE"),
        a("HAM", 53.63, 9.99, "Europe/Berlin", "함부르크", "Hamburg", "DE"),
        a("AMS", 52.31, 4.76, "Europe/Amsterdam", "암스테르담", "Amsterdam", "NL"),
        a("BRU", 50.90, 4.48, "Europe/Brussels", "브뤼셀", "Brussels", "BE"),
        a("ZRH", 47.46, 8.55, "Europe/Zurich", "취리히", "Zurich", "CH"),
        a("GVA", 46.24, 6.11, "Europe/Zurich", "제네바", "Geneva", "CH"),
        a("VIE", 48.11, 16.57, "Europe/Vienna", "비엔나", "Vienna", "AT"),
        a("PRG", 50.10, 14.26, "Europe/Prague", "프라하", "Prague", "CZ"),
        a("BUD", 47.44, 19.26, "Europe/Budapest", "부다페스트", "Budapest", "HU"),
        a("WAW", 52.17, 20.97, "Europe/Warsaw", "바르샤바", "Warsaw", "PL"),
        a("FCO", 41.80, 12.25, "Europe/Rome", "로마", "Rome Fiumicino", "IT"),
        a("MXP", 45.63, 8.72, "Europe/Rome", "밀라노 말펜사", "Milan Malpensa", "IT"),
        a("VCE", 45.50, 12.35, "Europe/Rome", "베네치아", "Venice", "IT"),
        a("FLR", 43.81, 11.20, "Europe/Rome", "피렌체", "Florence", "IT"),
        a("MAD", 40.49, -3.57, "Europe/Madrid", "마드리드", "Madrid", "ES"),
        a("BCN", 41.30, 2.08, "Europe/Madrid", "바르셀로나", "Barcelona", "ES"),
        a("PMI", 39.55, 2.74, "Europe/Madrid", "마요르카", "Palma de Mallorca", "ES"),
        a("AGP", 36.67, -4.50, "Europe/Madrid", "말라가", "Malaga", "ES"),
        a("LIS", 38.77, -9.13, "Europe/Lisbon", "리스본", "Lisbon", "PT"),
        a("OPO", 41.24, -8.68, "Europe/Lisbon", "포르투", "Porto", "PT"),
        a("ATH", 37.94, 23.94, "Europe/Athens", "아테네", "Athens", "GR"),
        a("CPH", 55.62, 12.66, "Europe/Copenhagen", "코펜하겐", "Copenhagen", "DK"),
        a("ARN", 59.65, 17.92, "Europe/Stockholm", "스톡홀름", "Stockholm", "SE"),
        a("OSL", 60.19, 11.10, "Europe/Oslo", "오슬로", "Oslo", "NO"),
        a("HEL", 60.32, 24.96, "Europe/Helsinki", "헬싱키", "Helsinki", "FI"),
        a("SVO", 55.97, 37.41, "Europe/Moscow", "모스크바 셰레메티예보", "Moscow Sheremetyevo", "RU"),
        a("LED", 59.80, 30.26, "Europe/Moscow", "상트페테르부르크", "Saint Petersburg", "RU"),
        a("IST", 41.26, 28.74, "Europe/Istanbul", "이스탄불", "Istanbul", "TR"),
        a("SAW", 40.90, 29.31, "Europe/Istanbul", "이스탄불 사비하귄첸", "Istanbul Sabiha Gokcen", "TR"),
        a("AYT", 36.90, 30.80, "Europe/Istanbul", "안탈리아", "Antalya", "TR"),
        a("TLV", 32.01, 34.89, "Asia/Jerusalem", "텔아비브", "Tel Aviv", "IL"),
        a("DXB", 25.25, 55.36, "Asia/Dubai", "두바이", "Dubai", "AE"),
        a("AUH", 24.43, 54.65, "Asia/Dubai", "아부다비", "Abu Dhabi", "AE"),
        a("DOH", 25.27, 51.61, "Asia/Qatar", "도하", "Doha", "QA"),
        a("BAH", 26.27, 50.63, "Asia/Bahrain", "바레인", "Bahrain", "BH"),
        a("MCT", 23.59, 58.28, "Asia/Muscat", "무스카트", "Muscat", "OM"),
        a("RUH", 24.96, 46.70, "Asia/Riyadh", "리야드", "Riyadh", "SA"),
        a("JED", 21.68, 39.16, "Asia/Riyadh", "제다", "Jeddah", "SA"),
        a("AMM", 31.72, 35.99, "Asia/Amman", "암만", "Amman", "JO"),
        a("CAI", 30.12, 31.41, "Africa/Cairo", "카이로", "Cairo", "EG"),
        a("CMN", 33.37, -7.59, "Africa/Casablanca", "카사블랑카", "Casablanca", "MA"),
        a("ADD", 8.98, 38.80, "Africa/Addis_Ababa", "아디스아바바", "Addis Ababa", "ET"),
        a("NBO", -1.32, 36.93, "Africa/Nairobi", "나이로비", "Nairobi", "KE"),
        a("JNB", -26.14, 28.25, "Africa/Johannesburg", "요하네스버그", "Johannesburg", "ZA"),
        a("CPT", -33.97, 18.60, "Africa/Johannesburg", "케이프타운", "Cape Town", "ZA"),
        a("SYD", -33.94, 151.18, "Australia/Sydney", "시드니", "Sydney", "AU"),
        a("MEL", -37.67, 144.84, "Australia/Melbourne", "멜버른", "Melbourne", "AU"),
        a("CBR", -35.31, 149.19, "Australia/Sydney", "캔버라", "Canberra", "AU"),
        a("BNE", -27.38, 153.12, "Australia/Brisbane", "브리즈번", "Brisbane", "AU"),
        a("OOL", -28.16, 153.50, "Australia/Brisbane", "골드코스트", "Gold Coast", "AU"),
        a("CNS", -16.89, 145.76, "Australia/Brisbane", "케언즈", "Cairns", "AU"),
        a("ADL", -34.95, 138.53, "Australia/Adelaide", "애들레이드", "Adelaide", "AU"),
        a("PER", -31.94, 115.97, "Australia/Perth", "퍼스", "Perth", "AU"),
        a("DRW", -12.41, 130.88, "Australia/Darwin", "다윈", "Darwin", "AU"),
        a("AKL", -37.01, 174.79, "Pacific/Auckland", "오클랜드", "Auckland", "NZ"),
        a("CHC", -43.49, 172.53, "Pacific/Auckland", "크라이스트처치", "Christchurch", "NZ"),
        a("ZQN", -45.02, 168.74, "Pacific/Auckland", "퀸스타운", "Queenstown", "NZ"),
        a("NAN", -17.76, 177.44, "Pacific/Fiji", "피지 난디", "Fiji Nadi", "FJ"),
        a("PPT", -17.56, -149.61, "Pacific/Tahiti", "타히티", "Tahiti", "PF"),
        a("NOU", -22.02, 166.21, "Pacific/Noumea", "누메아", "Noumea", "NC"),
    ]
}
