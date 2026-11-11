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
        /// "booked" | "planned" | "tentative". 없거나 모르면 계획(TRP1110A09).
        var status: String?
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
    var status: TripItemStatus = .planned
    /// AI가 `status`를 알아볼 수 있게 적어 보냈는가. 아니면 다시 가져올 때 사용자가 정한 상태를 지킨다(REV1110A06).
    var hasExplicitStatus = false

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
        lhs.id == rhs.id && lhs.kind == rhs.kind && lhs.title == rhs.title && lhs.start == rhs.start && lhs.end == rhs.end && lhs.status == rhs.status
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

extension TripImportPlan {
    /// 들어온 일정에 `status`가 없으면 앱에 저장된 상태(사용자가 정한 값)를 이어 쓴다. 적어 보낸 값은 그대로 이긴다(REV1110A06).
    func keepingUserStatus(from existing: [TravelTripItem]) -> TripImportPlan {
        let stored = Dictionary(
            existing.filter { $0.tripID == tripID && $0.status != nil }.map { ($0.itemID, TripItemStatus(raw: $0.status)) },
            uniquingKeysWith: { first, _ in first }
        )
        guard !stored.isEmpty else { return self }
        var copy = self
        for index in copy.items.indices where !copy.items[index].hasExplicitStatus {
            if let status = stored[copy.items[index].id] { copy.items[index].status = status }
        }
        return copy
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
        // AI가 날마다 번호를 다시 매겨 id가 겹치면 뒤에 차례 번호를 붙인다. 같은 꼴로 다시 보내면 같은 id가 된다.
        var seenIDs: [String: Int] = [:]
        for raw in document.items {
            let count = seenIDs[raw.id, default: 0] + 1
            seenIDs[raw.id] = count
            let itemID = count == 1 ? raw.id : "\(raw.id)#\(count)"
            guard let startAt = date(raw.start) else { return .failure(.badTime(itemID: raw.id)) }
            let endAt = raw.end.flatMap(date).map { max($0, startAt.addingTimeInterval(60)) } ?? startAt.addingTimeInterval(TripImportItem.defaultDuration)
            let coordinate = raw.place.flatMap { place -> CLLocationCoordinate2D? in
                guard let lat = place.lat, let lng = place.lng else { return nil }
                let value = CLLocationCoordinate2D(latitude: lat, longitude: lng)
                return CLLocationCoordinate2DIsValid(value) && (lat != 0 || lng != 0) ? value : nil
            } ?? (raw.type.lowercased() == "flight" ? TravelAirports.coordinate(raw.flight?.toAirport) : nil)
            items.append(TripImportItem(
                id: itemID,
                kind: TripImportItem.Kind(rawValue: raw.type.lowercased()) ?? .other,
                title: raw.title.trimmingCharacters(in: .whitespacesAndNewlines),
                start: startAt,
                end: endAt,
                timeZone: timeZone(raw.start) ?? .current,
                endTimeZone: raw.end.flatMap(timeZone) ?? timeZone(raw.start) ?? .current,
                coordinate: coordinate,
                placeName: raw.place?.name ?? raw.title,
                address: raw.place?.address ?? "",
                mapsURL: raw.place?.mapsUrl.flatMap(mapsURL),
                travelMinutes: raw.travelFromPrevious?.minutes,
                travelMode: raw.travelFromPrevious?.mode,
                note: raw.note ?? "",
                status: TripItemStatus(raw: raw.status),
                hasExplicitStatus: TripItemStatus(explicit: raw.status) != nil
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

    /// 밖에서 온 계획의 링크는 구글 지도 https 주소만 연다. 피싱 주소나 다른 앱을 여는 주소는 버린다(REV1110A02).
    static func mapsURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return nil }
        let isGoogle = host.range(of: #"(^|\.)google\.[a-z]{2,3}(\.[a-z]{2})?$"#, options: .regularExpression) != nil
        return isGoogle || host == "goo.gl" || host.hasSuffix(".goo.gl") ? url : nil
    }

    private static func looksLikeTrip(_ json: String) -> Bool { json.contains("\"\(format)\"") }

    private static let timeRegex = try? NSRegularExpression(pattern: #"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?(Z|[+-]\d{2}:?\d{2})$"#)

    /// 「2026-12-01T09:05+09:00」, 초·소수 초가 있는 꼴, `+0900`, `Z`를 받는다.
    static func date(_ text: String) -> Date? {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard let match = timeRegex?.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let zone = timeZone(value) else { return nil }
        func number(_ index: Int) -> Int? {
            Range(match.range(at: index), in: value).flatMap { Int(value[$0]) }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = DateComponents(year: number(1), month: number(2), day: number(3), hour: number(4), minute: number(5), second: number(6) ?? 0)
        guard parts.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: parts)
    }
}

/// 같은 여행을 다시 붙였을 때 바뀐 것.
struct TripImportDiff: Equatable {
    var added = 0
    var changed = 0
    var removed = 0

    var isReplacing: Bool { added + changed + removed > 0 }

    /// 핀 유무와 상관없이 반영된 여행 일정 전체와 비교한다.
    static func make(plan: TripImportPlan, existing: [TravelTripItem]) -> Self? {
        let old = Dictionary(existing.filter { $0.tripID == plan.tripID }.map { ($0.itemID, $0) }, uniquingKeysWith: { first, _ in first })
        guard !old.isEmpty else { return nil }
        var diff = Self()
        // 상태를 안 적어 보낸 일정은 저장된 상태를 지키므로 바뀐 것으로 세지 않는다(REV1110A06).
        for item in plan.keepingUserStatus(from: existing).items {
            guard let previous = old[item.id] else { diff.added += 1; continue }
            if previous.title != item.title || previous.start != item.start || previous.end != item.end || previous.kind != item.kind.rawValue
                || TripItemStatus(raw: previous.status) != item.status {
                diff.changed += 1
            }
        }
        diff.removed = Set(old.keys).subtracting(plan.items.map(\.id)).count
        return diff
    }
}

/// 미리보기 이동 시간 경고(TAU1110A01). 앞 일정이 끝나고 다음이 시작할 때까지가 직선 거리로 어림한 이동 시간보다 짧으면 알린다.
/// 걷기 4.5km/h(1.5km 이하), 그 밖은 도시 이동 25km/h에 1.2배 여유. AI가 적은 이동 분이 더 길면 그것을 쓴다.
/// 항공편 도착 뒤에는 입국·짐 찾기로 60분을 먼저 둔다.
enum TripImportTimingCheck {
    enum Warning: Equatable {
        case tightMove(needMinutes: Int)
        case afterFlight(needMinutes: Int)
    }

    static let arrivalMinutes = 60.0

    static func warnings(_ items: [TripImportItem]) -> [String: Warning] {
        var result: [String: Warning] = [:]
        let sorted = items.sorted { $0.start < $1.start }
        for (previous, next) in zip(sorted, sorted.dropFirst()) where next.kind != .flight {
            // 숙소·잠처럼 다음 일정을 감싸는 항목이나 겹친 일정은 이동 사이가 아니다.
            guard previous.end <= next.start, previous.kind != .lodging, previous.kind != .sleep else { continue }
            let gapMinutes = next.start.timeIntervalSince(previous.end) / 60
            if previous.kind == .flight {
                if gapMinutes < arrivalMinutes, gapMinutes > -1 { result[next.id] = .afterFlight(needMinutes: Int(arrivalMinutes)) }
                continue
            }
            guard let need = needMinutes(from: previous, to: next), gapMinutes < need else { continue }
            result[next.id] = .tightMove(needMinutes: Int(need.rounded(.up)))
        }
        return result
    }

    static func needMinutes(from previous: TripImportItem, to next: TripImportItem) -> Double? {
        guard let a = previous.coordinate, let b = next.coordinate else { return next.travelMinutes }
        let meters = CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
        guard meters >= 200 else { return nil }
        let guess = (meters <= 1_500 ? meters / 75 : meters / 416.7) * 1.2
        return max(guess, next.travelMinutes ?? 0)
    }
}
