import CoreLocation
import Foundation

/// AI가 만든 여행 JSON(TRP1110A01). 형식은 docs/TRIP_IMPORT.md와 `TripImportPrompt`가 정한다.
struct TripImportDocument: Decodable, Equatable {
    struct Place: Decodable, Equatable {
        var name: String?
        var address: String?
        var lat: Double?
        var lng: Double?
        var mapsUrl: String?
    }

    struct Flight: Decodable, Equatable {
        var number: String?
        var fromAirport: String?
        var toAirport: String?
    }

    struct Travel: Decodable, Equatable {
        var mode: String?
        var minutes: Double?
    }

    struct Item: Decodable, Equatable {
        var id: String
        var type: String
        var title: String
        var start: String
        var end: String?
        var place: Place?
        var flight: Flight?
        var travelFromPrevious: Travel?
        var note: String?
    }

    var format: String
    var version: Int
    var tripId: String
    var title: String
    var startDate: String?
    var endDate: String?
    var returnsToOrigin: Bool?
    var items: [Item]
}

enum TripImportError: Error, Equatable {
    case noJSON
    case unreadable
    case notTripFormat
    case unsupportedVersion(Int)
    case empty
    case badTime(itemID: String)
}

/// 앱이 반영할 한 항목. 시각은 현지 시차를 붙인 절대 시각이다.
struct TripImportItem: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case flight, lodging, meal, cafe, sight, photo, shopping, activity, rest, sleep, transfer, other
    }

    let id: String
    let kind: Kind
    let title: String
    let start: Date
    let end: Date
    /// 그 일정이 일어나는 곳의 시간대. 미리보기와 날짜 묶음은 현지 시각으로 한다.
    var timeZone: TimeZone = .current
    /// 끝 시각의 시간대. 항공편 도착은 도착지 시각이다.
    var endTimeZone: TimeZone = .current
    var coordinate: CLLocationCoordinate2D?
    let placeName: String
    let address: String
    let mapsURL: URL?
    let travelMinutes: Double?
    let travelMode: String?
    let note: String

    /// 현지 날짜를 기기 달력의 같은 날짜로 옮긴다. 방콕 12월 1일 밤 일정은 한국 시간으로 넘어가도 12월 1일이다.
    func localDay(calendar: Calendar = .autoupdatingCurrent) -> Date {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        let parts = local.dateComponents([.year, .month, .day], from: start)
        return calendar.date(from: parts).map { calendar.startOfDay(for: $0) } ?? calendar.startOfDay(for: start)
    }

    /// 끝 시각이 없으면 1시간으로 둔다.
    static let defaultDuration: TimeInterval = 3_600

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.kind == rhs.kind && lhs.title == rhs.title && lhs.start == rhs.start && lhs.end == rhs.end
            && lhs.coordinate?.latitude == rhs.coordinate?.latitude && lhs.coordinate?.longitude == rhs.coordinate?.longitude
    }
}

struct TripImportPlan: Equatable {
    let tripID: String
    let title: String
    var items: [TripImportItem]

    /// 기기 달력 기준 날짜별 묶음.
    func days(calendar: Calendar = .autoupdatingCurrent) -> [(day: Date, items: [TripImportItem])] {
        Dictionary(grouping: items) { $0.localDay(calendar: calendar) }
            .map { ($0.key, $0.value.sorted { $0.start < $1.start }) }
            .sorted { $0.day < $1.day }
    }
}

enum TripImportParser {
    static let format = "bokki-trip"
    static let version = 1

    /// AI가 앞뒤에 설명이나 ```json 울타리를 붙여도 첫 `{`부터 마지막 `}`까지 읽는다.
    static func parse(_ text: String) -> Result<TripImportPlan, TripImportError> {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return .failure(.noJSON) }
        let json = String(text[start...end]).replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
        guard let document = try? JSONDecoder().decode(TripImportDocument.self, from: Data(json.utf8)) else {
            return .failure(looksLikeTrip(json) ? .unreadable : .notTripFormat)
        }
        guard document.format == format else { return .failure(.notTripFormat) }
        guard document.version == version else { return .failure(.unsupportedVersion(document.version)) }
        guard !document.items.isEmpty else { return .failure(.empty) }
        var items: [TripImportItem] = []
        for raw in document.items {
            guard let startAt = date(raw.start) else { return .failure(.badTime(itemID: raw.id)) }
            let endAt = raw.end.flatMap(date).map { max($0, startAt.addingTimeInterval(60)) } ?? startAt.addingTimeInterval(TripImportItem.defaultDuration)
            let coordinate = raw.place.flatMap { place -> CLLocationCoordinate2D? in
                guard let lat = place.lat, let lng = place.lng else { return nil }
                let value = CLLocationCoordinate2D(latitude: lat, longitude: lng)
                return CLLocationCoordinate2DIsValid(value) && (lat != 0 || lng != 0) ? value : nil
            }
            items.append(TripImportItem(
                id: raw.id,
                kind: TripImportItem.Kind(rawValue: raw.type.lowercased()) ?? .other,
                title: raw.title.trimmingCharacters(in: .whitespacesAndNewlines),
                start: startAt,
                end: endAt,
                timeZone: timeZone(raw.start) ?? .current,
                endTimeZone: raw.end.flatMap(timeZone) ?? timeZone(raw.start) ?? .current,
                coordinate: coordinate,
                placeName: raw.place?.name ?? raw.title,
                address: raw.place?.address ?? "",
                mapsURL: raw.place?.mapsUrl.flatMap(URL.init(string:)),
                travelMinutes: raw.travelFromPrevious?.minutes,
                travelMode: raw.travelFromPrevious?.mode,
                note: raw.note ?? ""
            ))
        }
        return .success(TripImportPlan(tripID: document.tripId, title: document.title, items: items.sorted { $0.start < $1.start }))
    }

    /// 「+07:00」「+0700」「Z」를 시간대로 읽는다.
    static func timeZone(_ text: String) -> TimeZone? {
        let value = text.trimmingCharacters(in: .whitespaces)
        if value.hasSuffix("Z") { return TimeZone(secondsFromGMT: 0) }
        guard let match = value.range(of: #"[+-]\d{2}:?\d{2}$"#, options: .regularExpression) else { return nil }
        let digits = value[match].filter(\.isNumber)
        guard digits.count == 4, let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)) else { return nil }
        let seconds = (hours * 3_600 + minutes * 60) * (value[match].hasPrefix("-") ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds)
    }

    private static func looksLikeTrip(_ json: String) -> Bool { json.contains("\"\(format)\"") }

    /// 「2026-12-01T09:05+09:00」, 초가 있는 꼴, `Z`를 받는다.
    static func date(_ text: String) -> Date? {
        let value = text.trimmingCharacters(in: .whitespaces)
        for pattern in ["yyyy-MM-dd'T'HH:mmXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mmXXX"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = pattern
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}

/// 같은 여행을 다시 붙였을 때 바뀐 것.
struct TripImportDiff: Equatable {
    var added = 0
    var changed = 0
    var removed = 0

    var isReplacing: Bool { added + changed + removed > 0 }

    static func make(plan: TripImportPlan, existing: [TravelPlanStop], plans: [String: (title: String, start: Date)]) -> Self? {
        let old = existing.filter { $0.tripID == plan.tripID }
        guard !old.isEmpty else { return nil }
        let oldByItem = Dictionary(old.compactMap { stop in stop.itemID.map { ($0, stop) } }, uniquingKeysWith: { first, _ in first })
        var diff = Self()
        for item in plan.items {
            guard let stop = oldByItem[item.id] else { diff.added += 1; continue }
            let previous = plans[stop.itemID ?? ""]
            if stop.title != item.title || previous?.start != item.start { diff.changed += 1 }
        }
        diff.removed = Set(oldByItem.keys).subtracting(plan.items.map(\.id)).count
        return diff
    }
}
