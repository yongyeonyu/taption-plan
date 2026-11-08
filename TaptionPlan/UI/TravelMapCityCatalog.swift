import CoreLocation
import Foundation

/// Natural Earth 도시 목록(ne_10m_populated_places, 공개 도메인)의 한 줄.
struct TravelMapCity: Hashable, Sendable {
    let englishName: String
    let koreanName: String
    let latitude: Double
    let longitude: Double
    let population: Int
    let countryCode: String

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    var key: String { "\(englishName)|\(Int((latitude * 100).rounded()))|\(Int((longitude * 100).rounded()))" }

    func name(_ language: MapHomeLanguage) -> String { language == .korean ? koreanName : englishName }
}

/// 기록 좌표를 도시로 묶는 데 쓰는 앱 안 도시 목록(TRV1108A01).
///
/// 저장된 기록에는 역지오코딩한 시·군 이름이 없다. 그래서 좌표를 이 목록의 가장 가까운 도시로 묶고,
/// 큰 도시를 조금 더 끌어당겨(인구 가중) 서울 강남이 성남이 아니라 서울로 묶이게 한다.
/// 위치 서비스를 부르지 않아 오프라인에서도 같은 결과가 나온다.
struct TravelMapCityCatalog: Sendable {
    /// 이 거리(m)보다 먼 도시는 고르지 않는다.
    static let matchRadiusMeters = 35_000.0

    static let bundled: TravelMapCityCatalog = {
        guard let url = Bundle.main.url(forResource: "ne-cities", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return TravelMapCityCatalog(cities: []) }
        return TravelMapCityCatalog(tsv: text)
    }()

    /// 인구가 큰 순서다.
    let cities: [TravelMapCity]
    private let grid: [Cell: [Int]]

    private struct Cell: Hashable { let latitude: Int; let longitude: Int }

    init(cities: [TravelMapCity]) {
        self.cities = cities
        var grid: [Cell: [Int]] = [:]
        for (index, city) in cities.enumerated() {
            grid[Self.cell(latitude: city.latitude, longitude: city.longitude), default: []].append(index)
        }
        self.grid = grid
    }

    /// `en ko lat lon pop iso` 탭 구분. `#`으로 시작하는 줄은 출처 설명이다.
    init(tsv: String) {
        var cities: [TravelMapCity] = []
        for line in tsv.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 5, let latitude = Double(fields[2]), let longitude = Double(fields[3]) else { continue }
            cities.append(TravelMapCity(
                englishName: String(fields[0]),
                koreanName: String(fields[1]),
                latitude: latitude,
                longitude: longitude,
                population: Int(fields[4]) ?? 0,
                countryCode: fields.count > 5 ? String(fields[5]) : ""
            ))
        }
        self.init(cities: cities)
    }

    private static func cell(latitude: Double, longitude: Double) -> Cell {
        Cell(latitude: Int(floor(latitude)), longitude: Int(floor(longitude)))
    }

    /// 반경 안에서 거리 ÷ 인구 가중이 가장 작은 도시.
    func nearest(latitude: Double, longitude: Double, within radius: Double = matchRadiusMeters) -> TravelMapCity? {
        let center = Self.cell(latitude: latitude, longitude: longitude)
        let point = MapHomeRangeTripPlan.Point(latitude: latitude, longitude: longitude)
        var best: (score: Double, city: TravelMapCity)?
        for dLat in -1...1 {
            for dLon in -1...1 {
                for index in grid[Cell(latitude: center.latitude + dLat, longitude: center.longitude + dLon)] ?? [] {
                    let city = cities[index]
                    let meters = MapHomeRangeTripPlan.meters(point, MapHomeRangeTripPlan.Point(latitude: city.latitude, longitude: city.longitude))
                    guard meters <= radius else { continue }
                    let score = meters / Self.pull(population: city.population)
                    if best.map({ score < $0.score }) ?? true { best = (score, city) }
                }
            }
        }
        return best?.city
    }

    /// 5만 명은 1, 1천만 명은 약 1.6. 큰 도시 언저리를 그 도시로 묶는다.
    static func pull(population: Int) -> Double {
        1 + 0.25 * max(0, log10(Double(max(population, 1)) / 50_000))
    }

    /// 한국어·영어 이름에 검색어가 든 도시. 인구가 큰 순서이고 앞에서 시작하는 이름이 먼저다.
    func search(_ query: String, limit: Int = 6) -> [TravelMapCity] {
        let key = query.lowercased().replacingOccurrences(of: " ", with: "")
        guard !key.isEmpty else { return [] }
        var prefix: [TravelMapCity] = [], contains: [TravelMapCity] = []
        for city in cities {
            let names = [city.koreanName, city.englishName].map { $0.lowercased().replacingOccurrences(of: " ", with: "") }
            if names.contains(where: { $0.hasPrefix(key) }) {
                prefix.append(city)
                if prefix.count >= limit { break }
            } else if contains.count < limit, names.contains(where: { $0.contains(key) }) {
                contains.append(city)
            }
        }
        return Array((prefix + contains).prefix(limit))
    }
}
