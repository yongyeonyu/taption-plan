import Foundation

/// 여행 하나(TVA1111A01). 일정·핀·가계부 여행 장부가 같은 `id`(여행 번호)를 쓴다. 옛 저장본에는 없다.
public struct TravelTrip: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// 첫날·마지막 날. 여행지 달력의 연·월·일(`2026-11-19`)이라 기기 시간대가 바뀌어도 같은 날이다. 당일치기는 둘이 같다.
    public var startDay: String
    public var endDay: String
    /// ISO 3166-1 두 글자. 지구본 깃발과 나라 경계에 쓴다.
    public var countryCode: String?
    /// 도시·지역 이름(오사카, 대구).
    public var regionName: String?
    public var latitude: Double?
    public var longitude: Double?
    /// 여행지 통화(ISO 4217). 없으면 내 나라 통화만 쓴다(국내 여행).
    public var currencyCode: String?
    /// IANA 시간대 이름.
    public var timeZoneID: String?
    /// 지구본 깃발 색(`#RRGGBB`). 없으면 여행 순서대로 기본 색을 쓴다(TVE1112A01).
    public var flagColorHex: String?
    /// 언젠가 갈 여행(버킷리스트)의 날 수(TVW1112A01). 날짜를 아직 정하지 않아 `startDay`·`endDay`가 비어 있다. 날짜를 정하면 nil.
    public var wishDays: Int?

    /// 날짜를 아직 정하지 않은 여행.
    public var isWish: Bool { startDay.isEmpty && (wishDays ?? 0) >= 1 }

    public init(
        id: String, title: String, startDay: String, endDay: String, countryCode: String? = nil, regionName: String? = nil,
        latitude: Double? = nil, longitude: Double? = nil, currencyCode: String? = nil, timeZoneID: String? = nil,
        flagColorHex: String? = nil, wishDays: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.startDay = startDay
        self.endDay = endDay
        self.countryCode = countryCode
        self.regionName = regionName
        self.latitude = latitude
        self.longitude = longitude
        self.currencyCode = currencyCode
        self.wishDays = wishDays
        self.timeZoneID = timeZoneID
        self.flagColorHex = flagColorHex
    }
}

/// `YYYY-MM-DD` 날짜 글. 글자 순서가 곧 날짜 순서다.
public enum TravelTripDay {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    public static func string(year: Int, month: Int, day: Int) -> String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// 그 순간을 UTC 차(초)만큼 옮긴 벽시계의 날짜.
    public static func string(for date: Date, offsetSeconds: Int) -> String {
        let parts = utc.dateComponents([.year, .month, .day], from: date.addingTimeInterval(TimeInterval(offsetSeconds)))
        return string(year: parts.year ?? 0, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// 달력의 그날. 모양이 다르거나 없는 날짜면 nil.
    public static func components(_ day: String) -> DateComponents? {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let dayOfMonth = Int(parts[2]) else { return nil }
        let wanted = DateComponents(year: year, month: month, day: dayOfMonth)
        guard let date = utc.date(from: wanted), utc.dateComponents([.year, .month, .day], from: date) == wanted else { return nil }
        return wanted
    }

    /// `from`에서 `to`까지 날 수(같은 날이면 0). 못 읽으면 nil.
    public static func days(from: String, to: String) -> Int? {
        guard let start = components(from).flatMap(utc.date(from:)), let end = components(to).flatMap(utc.date(from:)) else { return nil }
        return utc.dateComponents([.day], from: start, to: end).day
    }
}

/// 여행 목록. 저장한 여행과, 일정·핀에만 번호가 남은 옛 여행을 한 목록으로 만든다.
public enum TravelTripDirectory {
    public enum State: String, Sendable {
        case active, upcoming, past
        /// 날짜를 정하지 않은 여행(버킷리스트).
        case someday
    }

    public struct Entry: Hashable, Sendable, Identifiable {
        public var trip: TravelTrip
        /// 저장한 여행이면 true, 일정·핀에서 알아낸 옛 여행이면 false.
        public var isStored: Bool
        public var state: State
        /// 여행 날 수. 당일치기는 1.
        public var dayCount: Int
        /// 다가오는 여행이 시작하기까지 남은 날(1 이상).
        public var daysUntilStart: Int?
        /// 여행 중이면 오늘이 몇 일차인지(1부터).
        public var dayNumber: Int?

        public var id: String { trip.id }
        public var nights: Int { max(0, dayCount - 1) }
        public var isDayTrip: Bool { dayCount == 1 }
    }

    /// `today`는 기기 달력의 오늘(`YYYY-MM-DD`). `names`는 여행 번호별 이름(가계부 여행 장부)으로, 옛 여행의 이름에 먼저 쓴다.
    /// 순서: 여행 중 → 다가오는 여행(가까운 것부터) → 지난 여행(최근 것부터).
    public static func entries(
        stored: [TravelTrip], stops: [TravelPlanStop], items: [TravelTripItem], names: [String: String] = [:], today: String
    ) -> [Entry] {
        var trips: [String: (trip: TravelTrip, isStored: Bool)] = [:]
        for trip in stored where trips[trip.id] == nil { trips[trip.id] = (trip, true) }
        for trip in legacyTrips(stops: stops, items: items, names: names) where trips[trip.id] == nil { trips[trip.id] = (trip, false) }
        // 언젠가 갈 여행은 다가오는 여행 뒤, 지난 여행 앞.
        let rank: [State: Int] = [.active: 0, .upcoming: 1, .someday: 2, .past: 3]
        return trips.values.map { entry($0.trip, isStored: $0.isStored, today: today) }.sorted { left, right in
            if left.state != right.state { return (rank[left.state] ?? 0) < (rank[right.state] ?? 0) }
            if left.state == .past, left.trip.endDay != right.trip.endDay { return left.trip.endDay > right.trip.endDay }
            if left.state == .someday, left.trip.title != right.trip.title { return left.trip.title < right.trip.title }
            if left.state != .past, left.trip.startDay != right.trip.startDay { return left.trip.startDay < right.trip.startDay }
            return left.id < right.id
        }
    }

    public static func entry(_ trip: TravelTrip, isStored: Bool, today: String) -> Entry {
        if trip.isWish {
            return Entry(trip: trip, isStored: isStored, state: .someday, dayCount: max(1, trip.wishDays ?? 1), daysUntilStart: nil, dayNumber: nil)
        }
        let state: State = today < trip.startDay ? .upcoming : (today > trip.endDay ? .past : .active)
        return Entry(
            trip: trip, isStored: isStored, state: state,
            dayCount: max(1, (TravelTripDay.days(from: trip.startDay, to: trip.endDay) ?? 0) + 1),
            daysUntilStart: state == .upcoming ? TravelTripDay.days(from: today, to: trip.startDay) : nil,
            dayNumber: state == .active ? TravelTripDay.days(from: trip.startDay, to: today).map { $0 + 1 } : nil
        )
    }

    /// 일정 하나의 첫날·마지막 날(그곳 벽시계). 자정에 끝나는 일정이 다음 날로 넘어가지 않게 끝 바로 앞을 본다.
    static func days(of item: TravelTripItem) -> (start: String, end: String) {
        let first = TravelTripDay.string(for: item.start, offsetSeconds: item.startOffsetSeconds)
        let lastMoment = item.end > item.start ? item.end.addingTimeInterval(-1) : item.start
        return (first, max(first, TravelTripDay.string(for: lastMoment, offsetSeconds: item.endOffsetSeconds)))
    }

    /// 그 여행 일정들의 첫날·마지막 날. 일정이 없으면 nil.
    public static func days(of items: [TravelTripItem], tripID: String) -> (start: String, end: String)? {
        let all = items.filter { $0.tripID == tripID }.map { days(of: $0) }
        guard let start = all.map(\.start).min(), let end = all.map(\.end).max() else { return nil }
        return (start, end)
    }

    /// AI가 보낸 여행을 반영한다. 이름과 기간은 새 것으로 바꾸고, 사용자가 정한 여행지·통화·시간대는 그대로 둔다.
    /// 처음 보는 여행인데 일정이 없으면 만들지 않는다.
    public static func upserting(_ trips: [TravelTrip], id: String, title: String, items: [TravelTripItem]) -> [TravelTrip] {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let span = days(of: items, tripID: id)
        var copy = trips
        if let index = copy.firstIndex(where: { $0.id == id }) {
            if !name.isEmpty { copy[index].title = name }
            if let span {
                copy[index].startDay = span.start
                copy[index].endDay = span.end
            }
        } else if let span {
            copy.append(TravelTrip(id: id, title: name, startDay: span.start, endDay: span.end))
        }
        return copy
    }

    /// 언젠가 갈 여행에 첫날을 정한다: 정해 둔 날 수만큼 이어진 기간이 된다. 첫날을 읽지 못하면 그대로.
    public static func scheduled(_ trip: TravelTrip, startDay: String, calendar: Calendar = Calendar(identifier: .gregorian)) -> TravelTrip {
        guard trip.isWish, let parts = TravelTripDay.components(startDay) else { return trip }
        var utc = calendar
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        guard let first = utc.date(from: parts), let last = utc.date(byAdding: .day, value: max(1, trip.wishDays ?? 1) - 1, to: first) else { return trip }
        var copy = trip
        copy.startDay = startDay
        copy.endDay = TravelTripDay.string(for: last, offsetSeconds: 0)
        copy.wishDays = nil
        return copy
    }

    /// 일정이 여행 기간 밖에 놓이면 그 여행의 기간을 늘린다(줄이지는 않는다).
    public static func extended(_ trips: [TravelTrip], toCover items: [TravelTripItem]) -> [TravelTrip] {
        trips.map { trip in
            guard let span = days(of: items, tripID: trip.id) else { return trip }
            var copy = trip
            // 날짜 없던 여행에 일정이 생기면 그 날짜로 정해진다.
            if trip.isWish {
                copy.startDay = span.start
                copy.endDay = span.end
                copy.wishDays = nil
                return copy
            }
            copy.startDay = min(trip.startDay, span.start)
            copy.endDay = max(trip.endDay, span.end)
            return copy
        }
    }

    /// 일정·핀에 남은 여행 번호로 기간과 이름을 알아낸다. 날짜는 일정이 일어나는 곳의 벽시계 날짜다.
    static func legacyTrips(stops: [TravelPlanStop], items: [TravelTripItem], names: [String: String]) -> [TravelTrip] {
        var found: [String: (start: String, end: String, title: String?, firstStart: Date?)] = [:]
        for item in items {
            let (first, last) = days(of: item)
            var value = found[item.tripID] ?? (first, last, nil, nil)
            value.start = min(value.start, first)
            value.end = max(value.end, last)
            if value.firstStart.map({ item.start < $0 }) ?? true {
                value.firstStart = item.start
                value.title = item.title
            }
            found[item.tripID] = value
        }
        for stop in stops {
            guard let id = stop.tripID else { continue }
            // 핀의 날짜는 만든 기기의 자정이다. 12시간을 더해 UTC로 읽으면 어느 시간대에서 만들었든 그날이다.
            let day = TravelTripDay.string(for: stop.day, offsetSeconds: 12 * 3_600)
            var value = found[id] ?? (day, day, nil, nil)
            value.start = min(value.start, day)
            value.end = max(value.end, day)
            if value.title == nil { value.title = stop.title }
            found[id] = value
        }
        return found.map { id, value in
            TravelTrip(id: id, title: names[id] ?? value.title ?? "", startDay: value.start, endDay: value.end)
        }
    }
}

/// 여행 일정의 시각 고치기. 시각만 바꾸고 그곳의 UTC 차는 그대로 둔다.
public enum TravelTripItemEditor {
    /// 일정이 이보다 짧아지게 늘이거나 줄일 수 없다.
    public static let minimumDuration: TimeInterval = 300

    /// 일정 하나를 `delta`초 옮긴다. 그 일정이 없으면 nil.
    public static func moved(_ items: [TravelTripItem], tripID: String, itemID: String, by delta: TimeInterval) -> [TravelTripItem]? {
        guard delta.isFinite, let index = items.firstIndex(where: { $0.tripID == tripID && $0.itemID == itemID }) else { return nil }
        var copy = items
        copy[index].start = items[index].start.addingTimeInterval(delta)
        copy[index].end = items[index].end.addingTimeInterval(delta)
        return copy
    }

    /// 시작과 끝을 따로 옮긴다. 그 일정이 없거나 길이가 `minimumDuration`보다 짧아지면 nil.
    public static func resized(
        _ items: [TravelTripItem], tripID: String, itemID: String, startDelta: TimeInterval? = nil, endDelta: TimeInterval? = nil
    ) -> [TravelTripItem]? {
        guard (startDelta ?? 0).isFinite, (endDelta ?? 0).isFinite,
              let index = items.firstIndex(where: { $0.tripID == tripID && $0.itemID == itemID }) else { return nil }
        let start = items[index].start.addingTimeInterval(startDelta ?? 0)
        let end = items[index].end.addingTimeInterval(endDelta ?? 0)
        guard end.timeIntervalSince(start) >= minimumDuration else { return nil }
        var copy = items
        copy[index].start = start
        copy[index].end = end
        return copy
    }
}
