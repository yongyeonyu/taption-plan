import Foundation

/// 도시 팩(ARCH1120A01 2단계)의 앱 쪽 모델. 팩은 공용 자료라 개인 일정·지출·위치가 섞이지 않는다.
/// 내려받기는 시즌 팩 다운로더(`SeasonPackDownloader`)를 그대로 쓴다(카탈로그 항목의 `archive`가 같은 모양이다).
/// 모르는 카테고리는 목록에서 제외한다(시즌 팩의 「모르는 열쇠는 무시」 규칙과 같다).

struct TripPackItem: Decodable, Equatable, Identifiable, Sendable {
    var id: String
    var category: String
    var name: String
    var nameKo: String
    var area: String
    var address: String?
    var lat: Double
    var lng: Double
    var phone: String?
    var hours: String?
    var priceHint: String?
    var tags: [String]?
    var note: String
    var source: String
    var sourceURL: String?
    var checkedAt: String
    var checkedBy: String
    var photo: String?
}

struct TripPack: Decodable, Equatable, Sendable {
    var format: String
    var schema: Int
    var city: String
    var version: Int
    var items: [TripPackItem]
}

/// 팩이 선언하는 카테고리. 이 앱이 아는 것만 쓰고 나머지는 걸러 낸다.
enum TripPackCategory: String, CaseIterable, Sendable {
    case stay, restaurant, cafe, sight, shop, hospital, pharmacy, themepark, rentcar
    case busStop = "bus_stop", railStation = "rail_station", airport, port

    /// 여행 일정 칸 종류(`TripImportItem.Kind`의 raw 값).
    var itemKind: String {
        switch self {
        case .stay: "lodging"
        case .restaurant: "meal"
        case .cafe: "cafe"
        case .sight: "sight"
        case .shop: "shopping"
        case .themepark: "activity"
        case .hospital, .pharmacy, .rentcar: "other"
        case .busStop, .railStation, .airport, .port: "transfer"
        }
    }

    /// 병원·약국은 안전 정보라 확인일을 같이 보이고, 오래되면 「확인 필요」로 표시한다.
    var isSafetyInfo: Bool { self == .hospital || self == .pharmacy }
}

enum TripPackReader {
    static let supportedSchema = 1
    static let staleDays = 90
    static let maximumBytes = 4_000_000

    /// 모양이 다르거나 크면 nil. 좌표가 범위 밖이거나 모르는 카테고리인 항목만 빼고 나머지는 쓴다.
    static func decode(_ data: Data) -> TripPack? {
        guard data.count <= maximumBytes, var pack = try? JSONDecoder().decode(TripPack.self, from: data),
              pack.format == "bokki-trip-pack", pack.schema == supportedSchema, !pack.city.isEmpty else { return nil }
        var seen = Set<String>()
        pack.items = pack.items.filter { item in
            TripPackCategory(rawValue: item.category) != nil && (-90...90).contains(item.lat) && (-180...180).contains(item.lng)
                && !item.id.isEmpty && seen.insert(item.id).inserted
        }
        return pack.items.isEmpty ? nil : pack
    }

    /// 확인일이 90일을 넘었는가(병원·약국은 화면에 「오래된 정보 · 확인 필요」로 보인다).
    static func isStale(_ item: TripPackItem, now: Date = .now, calendar: Calendar = Calendar(identifier: .gregorian)) -> Bool {
        var utc = calendar; utc.timeZone = .gmt
        let parts = item.checkedAt.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let checked = utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return true }
        return now.timeIntervalSince(checked) > Double(staleDays) * 86_400
    }

    /// 카테고리·문구로 거른다(순수 함수라 시험하기 쉽다).
    static func filter(_ items: [TripPackItem], category: TripPackCategory? = nil, query: String = "") -> [TripPackItem] {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        return items.filter { item in
            if let category, item.category != category.rawValue { return false }
            guard !text.isEmpty else { return true }
            return ([item.name, item.nameKo, item.area] + (item.tags ?? [])).contains { $0.lowercased().contains(text) }
        }
    }
}

/// 팩 항목 → 일정 칸에 넣을 값. 이름·좌표는 칸이 가져가므로 팩이 사라져도 칸은 남는다.
struct TripPackPlacement: Equatable {
    var kind: String
    var title: String
    var place: TravelItemPlace
    var note: String
    var source: String
    var packID: String
    var city: String
    var itemID: String
    var externalLink: String?

    static func make(_ item: TripPackItem, in pack: TripPack) -> TripPackPlacement? {
        guard let category = TripPackCategory(rawValue: item.category) else { return nil }
        return TripPackPlacement(
            kind: category.itemKind, title: item.nameKo, place: TravelItemPlace(name: item.nameKo, latitude: item.lat, longitude: item.lng),
            note: item.note, source: "pack", packID: "\(pack.city).v\(pack.version)", city: pack.city, itemID: item.id, externalLink: item.sourceURL)
    }
}
