import Foundation

// 항공 알림을 카드에 합치는 엔진(FLT1119A01). 순수 계산이다: 저장·화면·네트워크는 앱이 한다.
// 원칙: 같은 편명·같은 날짜의 카드는 항상 하나. 안내형(체크인·현장 안내)은 새 카드를 만들지 않는다. 후보가 둘 이상이면 자동으로 붙이지 않고 묻는다.
// 어느 값이 어디서 채워졌는지(알림·공공데이터·직접 입력)를 필드마다 기록하고, 손으로 적은 값은 자동 값이 덮지 않는다.

public enum FlightFieldSource: String, Hashable, Sendable, Codable {
    case message, share, paste, intent, publicData, manual
    /// 사람이 적었거나 고른 값. 자동 값이 덮지 않는다.
    var isManual: Bool { self == .manual }
}

/// 한 항공편 카드. 앱의 `TravelTripItem`(kind `flight`)과 오가는 값이다.
public struct FlightCard: Hashable, Sendable, Identifiable {
    public var id: String
    public var flight: String?
    public var airline: String?
    /// 알림 머리표의 항공사 이름(편명이 없는 안내문과 편명이 있는 여정문을 잇는 열쇠).
    public var airlineName: String?
    /// 예약번호. 기기 안에서만 쓴다.
    public var pnr: String?
    public var origin: String?
    public var destination: String?
    /// 출발 공항 현지 날짜 `YYYY-MM-DD`.
    public var date: String?
    /// 출발 현지 시각.
    public var time: FlightAlertTime?
    public var terminal: String?
    public var gate: String?
    public var checkIn: FlightAlertCheckIn?
    /// 공항 현장 안내가 준 권장 도착 시간(출발 몇 분 전). 있으면 도착 역산이 이 값을 쓴다.
    public var onsiteArriveMinutesBefore: Int?
    public var changes: [FlightChange]
    public var notes: [String]
    /// 필드 이름 → 출처.
    public var sources: [String: FlightFieldSource]
    public var confidence: Double
    public var receivedAt: Date

    public init(id: String, flight: String? = nil, airline: String? = nil, airlineName: String? = nil, pnr: String? = nil, origin: String? = nil, destination: String? = nil,
                date: String? = nil, time: FlightAlertTime? = nil, terminal: String? = nil, gate: String? = nil, checkIn: FlightAlertCheckIn? = nil,
                onsiteArriveMinutesBefore: Int? = nil, changes: [FlightChange] = [], notes: [String] = [], sources: [String: FlightFieldSource] = [:],
                confidence: Double = 1, receivedAt: Date = .distantPast) {
        self.id = id
        self.flight = flight
        self.airline = airline
        self.airlineName = airlineName
        self.pnr = pnr
        self.origin = origin
        self.destination = destination
        self.date = date
        self.time = time
        self.terminal = terminal
        self.gate = gate
        self.checkIn = checkIn
        self.onsiteArriveMinutesBefore = onsiteArriveMinutesBefore
        self.changes = changes
        self.notes = notes
        self.sources = sources
        self.confidence = confidence
        self.receivedAt = receivedAt
    }

    /// 지금까지 받은 지연(분). 마지막으로 받은 변경 기준.
    public var currentDelayMinutes: Int {
        changes.max(by: { $0.receivedAt < $1.receivedAt })?.delayMinutes ?? 0
    }
}

/// 공공데이터에서 받은 한 줄(시각·터미널 보충용).
public struct FlightPublicEntry: Hashable, Sendable {
    public var flight: String
    public var time: FlightAlertTime?
    public var terminal: String?
    public var gate: String?
    public init(flight: String, time: FlightAlertTime? = nil, terminal: String? = nil, gate: String? = nil) {
        self.flight = flight; self.time = time; self.terminal = terminal; self.gate = gate
    }
}

public enum FlightMergeOutcome: Hashable, Sendable {
    public enum Deferred: String, Sendable { case noMatchingCard, noMatchingTrip, unsupported }
    /// 새 카드를 만들었다.
    case created(cardID: String)
    /// 기존 카드에 합쳤다. `filled`는 채우거나 바꾼 필드 이름.
    case merged(cardID: String, filled: [String])
    /// 후보가 둘 이상(또는 확신할 수 없음)이라 자동으로 붙이지 않았다. 사용자가 어느 카드에 붙일지, 새로 만들지 고른다.
    case needsConfirmation(candidateIDs: [String])
    /// 카드가 없어 편명으로 공공데이터를 조회해 등록해야 한다(SMS 사전 안내).
    case lookupNeeded(flight: String, date: String)
    /// 붙일 카드가 없어 보류 목록에 둔다. 새 카드를 만들지 않는다.
    case deferred(Deferred)
    /// 이 엔진이 다루지 않는 유형(여행 부가 예약).
    case ignored
}

public struct FlightMergeResult: Sendable {
    public var cards: [FlightCard]
    public var outcomes: [FlightMergeOutcome]
}

/// 같은 여행으로 묶인 카드들(출국편 + 귀국편).
public struct FlightTripGroup: Hashable, Sendable {
    public var cardIDs: [String]
    public var startDate: String
    public var endDate: String
}

public enum FlightAlertMerge {
    /// 진행 중인 여행으로 보는 범위(받은 날 기준 앞뒤 일수). 현장 안내를 붙일 카드를 찾을 때 쓴다.
    public static let onsiteWindowDays = (before: 1, after: 2)
    /// 출국편과 귀국편을 한 여행으로 묶는 최대 간격(일).
    public static let pairingMaxDays = 45

    public static func apply(_ alert: FlightAlert, to cards: [FlightCard], receivedAt: Date = .now, calendar: Calendar = .autoupdatingCurrent,
                             source: FlightFieldSource = .message, makeID: () -> String = { "f-" + UUID().uuidString.prefix(8).lowercased() }) -> FlightMergeResult {
        var cards = cards
        var outcomes: [FlightMergeOutcome] = []
        switch alert.kind {
        case .travelExtra:
            outcomes.append(.ignored)
        case .bookingNotice, .itinerary, .airlineNameBody:
            for segment in alert.segments { outcomes.append(upsert(segment, alert: alert, into: &cards, receivedAt: receivedAt, calendar: calendar, source: source, makeID: makeID)) }
        case .delayChange:
            outcomes.append(applyDelay(alert, into: &cards, receivedAt: receivedAt, calendar: calendar, source: source))
        case .checkIn:
            outcomes.append(attach(alert, into: &cards, receivedAt: receivedAt, calendar: calendar, source: source) { card in
                card.checkIn = alert.checkIn
                card.sources["checkIn"] = source
                return ["checkIn"]
            })
        case .airportOnsite:
            outcomes.append(attachOnsite(alert, into: &cards, receivedAt: receivedAt, calendar: calendar, source: source))
        case .smsAdvance:
            outcomes.append(applySMS(alert, into: &cards, receivedAt: receivedAt, calendar: calendar, source: source))
        }
        return FlightMergeResult(cards: cards, outcomes: outcomes)
    }

    // MARK: 후보 찾기

    /// 병합 키 우선순위(위에서부터, 맞는 것이 하나면 병합): ① 날짜+편명 ② 예약번호 ③ 날짜+노선+항공사 ④ 날짜+노선(안내형만).
    static func candidates(flight: String?, date: String?, origin: String?, destination: String?, pnr: String?, airline: String?, airlineName: String? = nil,
                           in cards: [FlightCard], allowRouteOnly: Bool) -> [Int] {
        func indices(_ test: (FlightCard) -> Bool) -> [Int] { cards.indices.filter { test(cards[$0]) } }
        if let flight, let date {
            let hit = indices { $0.flight == flight && $0.date == date }
            if !hit.isEmpty { return hit }
        }
        if let pnr {
            // 예약번호는 같아도 편명이나 날짜가 서로 다르면 다른 구간이다(한 예약에 출국편과 귀국편이 함께 있다).
            var hit = indices { card in
                guard card.pnr == pnr else { return false }
                if let flight, let known = card.flight, known != flight { return false }
                if let date, let known = card.date, known != date { return false }
                return true
            }
            // 한 예약번호가 출국·귀국 두 카드를 가질 수 있다. 날짜나 노선을 알면 좁힌다.
            if hit.count > 1 {
                let narrowed = hit.filter { cards[$0].date == date || (origin != nil && cards[$0].origin == origin && cards[$0].destination == destination) }
                if !narrowed.isEmpty, date != nil || origin != nil { hit = narrowed }
            }
            if !hit.isEmpty { return hit }
        }
        if let date, let origin, let destination, airline != nil || airlineName != nil {
            let hit = indices { card in
                guard card.date == date, card.origin == origin, card.destination == destination else { return false }
                let code = card.airline ?? card.flight.map { String($0.prefix(2)) }
                if let airline, let code { return code == airline }
                if let airlineName, let name = card.airlineName { return name == airlineName }
                return false
            }
            if !hit.isEmpty { return hit }
        }
        if allowRouteOnly, let date, let origin, let destination {
            let hit = indices { $0.date == date && $0.origin == origin && $0.destination == destination }
            if !hit.isEmpty { return hit }
        }
        return []
    }

    private static func dateKey(_ date: FlightAlertDate?, receivedAt: Date, calendar: Calendar) -> String? {
        guard let resolved = date?.resolved(reference: receivedAt, calendar: calendar) else { return nil }
        return String(format: "%04d-%02d-%02d", resolved.year, resolved.month, resolved.day)
    }

    private static func airlineCode(_ flight: String?) -> String? { flight.map { String($0.prefix(2)) } }

    // MARK: 만들기·합치기(① ② 2번 유형)

    private static func upsert(_ segment: FlightAlertSegment, alert: FlightAlert, into cards: inout [FlightCard], receivedAt: Date, calendar: Calendar,
                               source: FlightFieldSource, makeID: () -> String) -> FlightMergeOutcome {
        let date = dateKey(segment.date, receivedAt: receivedAt, calendar: calendar)
        let found = candidates(flight: segment.flight, date: date, origin: segment.origin, destination: segment.destination, pnr: alert.pnr,
                               airline: airlineCode(segment.flight), airlineName: alert.airlineName, in: cards, allowRouteOnly: false)
        if found.count > 1 { return .needsConfirmation(candidateIDs: found.map { cards[$0].id }) }
        if let index = found.first {
            let filled = fill(&cards[index], segment: segment, alert: alert, date: date, receivedAt: receivedAt, source: source)
            return .merged(cardID: cards[index].id, filled: filled)
        }
        // 노선·날짜도 편명도 없으면 만들 수 없다.
        guard date != nil, segment.flight != nil || (segment.origin != nil && segment.destination != nil) else { return .deferred(.noMatchingCard) }
        var card = FlightCard(id: makeID(), receivedAt: receivedAt)
        _ = fill(&card, segment: segment, alert: alert, date: date, receivedAt: receivedAt, source: source)
        card.confidence = confidence(of: card, alert: alert)
        cards.append(card)
        return .created(cardID: card.id)
    }

    private static func confidence(of card: FlightCard, alert: FlightAlert) -> Double {
        var score = 0.5
        if card.flight != nil { score += 0.2 }
        if card.time != nil { score += 0.15 }
        if card.origin != nil, card.destination != nil { score += 0.1 }
        if card.pnr != nil { score += 0.05 }
        return min(1, score)
    }

    /// 값을 채운다. 빈 칸은 채우고, 이미 있는 값은 손으로 적은 것이 아니고 이번 글이 더 새로우면 바꾼다. 채우거나 바꾼 필드 이름을 돌려준다.
    @discardableResult
    private static func fill(_ card: inout FlightCard, segment: FlightAlertSegment, alert: FlightAlert, date: String?, receivedAt: Date, source: FlightFieldSource) -> [String] {
        var changed: [String] = []
        func set<T: Equatable>(_ name: String, _ keyPath: WritableKeyPath<FlightCard, T?>, _ value: T?) {
            guard let value else { return }
            if let current = card[keyPath: keyPath] {
                guard current != value, card.sources[name]?.isManual != true, receivedAt >= card.receivedAt else { return }
            }
            card[keyPath: keyPath] = value
            card.sources[name] = source
            changed.append(name)
        }
        set("flight", \.flight, segment.flight)
        set("airline", \.airline, airlineCode(segment.flight))
        set("pnr", \.pnr, alert.pnr)
        if card.airlineName == nil { card.airlineName = alert.airlineName }
        set("origin", \.origin, segment.origin)
        set("destination", \.destination, segment.destination)
        set("date", \.date, date)
        set("time", \.time, segment.time)
        for note in alert.notes where !card.notes.contains(note) { card.notes.append(note); if !changed.contains("notes") { changed.append("notes") } }
        card.notes = Array(card.notes.prefix(12))
        if !changed.isEmpty { card.receivedAt = max(card.receivedAt, receivedAt) }
        return changed
    }

    /// 공공데이터로 빈 시각·터미널·탑승구를 채운다(알림 ②의 시각 없는 카드). 손으로 적은 값·알림 값은 덮지 않는다.
    public static func fill(_ card: FlightCard, publicData entry: FlightPublicEntry) -> (card: FlightCard, filled: [String]) {
        var card = card
        var filled: [String] = []
        if card.time == nil, let time = entry.time { card.time = time; card.sources["time"] = .publicData; filled.append("time") }
        if card.terminal == nil, let terminal = entry.terminal { card.terminal = terminal; card.sources["terminal"] = .publicData; filled.append("terminal") }
        if card.gate == nil, let gate = entry.gate { card.gate = gate; card.sources["gate"] = .publicData; filled.append("gate") }
        return (card, filled)
    }

    // MARK: 지연(3번)

    private static func applyDelay(_ alert: FlightAlert, into cards: inout [FlightCard], receivedAt: Date, calendar: Calendar, source: FlightFieldSource) -> FlightMergeOutcome {
        guard let change = alert.change else { return .deferred(.noMatchingCard) }
        let segment = alert.segments.first
        let date = dateKey(segment?.date, receivedAt: receivedAt, calendar: calendar)
        // 예약번호가 먼저(가장 믿을 만한 열쇠), 그다음 날짜+편명. 날짜 없는 지연 글은 편명만으로 가장 가까운 앞날 카드.
        var found = candidates(flight: change.flight, date: date, origin: segment?.origin, destination: segment?.destination, pnr: alert.pnr,
                               airline: airlineCode(change.flight), in: cards, allowRouteOnly: false)
        if found.isEmpty, let flight = change.flight, date == nil {
            let flights = cards.indices.filter { cards[$0].flight == flight }
            let upcoming = flights.filter { (cards[$0].date ?? "") >= dayString(receivedAt, calendar: calendar, backDays: 1) }
            found = upcoming.count == 1 ? upcoming : (flights.count == 1 ? flights : upcoming)
        }
        // 예약번호만 맞고 편명이 서로 다른 카드가 둘 이상이면 편명으로 좁힌다.
        if found.count > 1, let flight = change.flight {
            let narrowed = found.filter { cards[$0].flight == flight }
            if narrowed.count == 1 { found = narrowed }
        }
        if found.count > 1 { return .needsConfirmation(candidateIDs: found.map { cards[$0].id }) }
        guard let index = found.first else { return .deferred(.noMatchingCard) }
        var filled: [String] = []
        if let flight = change.flight, cards[index].flight == nil { cards[index].flight = flight; cards[index].sources["flight"] = source; filled.append("flight") }
        if let to = change.to, cards[index].sources["time"]?.isManual != true { cards[index].time = to; cards[index].sources["time"] = source; filled.append("time") }
        let delay = change.delayMinutes ?? 0
        let wall = localTime(date: cards[index].date ?? date)
        cards[index].changes.append(FlightChange(flight: cards[index].flight ?? change.flight ?? "", before: change.from.flatMap(wall), after: change.to.flatMap(wall),
                                                 delayMinutes: delay, reason: change.reason, receivedAt: receivedAt))
        cards[index].changes = Array(cards[index].changes.suffix(20))
        cards[index].receivedAt = max(cards[index].receivedAt, receivedAt)
        filled.append("change")
        return .merged(cardID: cards[index].id, filled: filled)
    }

    private static func localTime(date: String?) -> (FlightAlertTime) -> FlightLocalTime? {
        { time in
            guard let date else { return nil }
            let parts = date.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            return FlightLocalTime(year: parts[0], month: parts[1], day: parts[2], hour: time.hour, minute: time.minute)
        }
    }

    private static func dayString(_ date: Date, calendar: Calendar, backDays: Int = 0) -> String {
        let shifted = calendar.date(byAdding: .day, value: -backDays, to: date) ?? date
        let parts = calendar.dateComponents([.year, .month, .day], from: shifted)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: 안내형(4·5번): 새 카드를 만들지 않는다

    private static func attach(_ alert: FlightAlert, into cards: inout [FlightCard], receivedAt: Date, calendar: Calendar, source: FlightFieldSource,
                               update: (inout FlightCard) -> [String]) -> FlightMergeOutcome {
        let segment = alert.segments.first
        let date = dateKey(segment?.date, receivedAt: receivedAt, calendar: calendar)
        let found = candidates(flight: segment?.flight, date: date, origin: segment?.origin, destination: segment?.destination, pnr: alert.pnr,
                               airline: airlineCode(segment?.flight), in: cards, allowRouteOnly: true)
        if found.count > 1 { return .needsConfirmation(candidateIDs: found.map { cards[$0].id }) }
        guard let index = found.first else { return .deferred(.noMatchingCard) }
        let filled = update(&cards[index])
        cards[index].receivedAt = max(cards[index].receivedAt, receivedAt)
        return .merged(cardID: cards[index].id, filled: filled)
    }

    private static func attachOnsite(_ alert: FlightAlert, into cards: inout [FlightCard], receivedAt: Date, calendar: Calendar, source: FlightFieldSource) -> FlightMergeOutcome {
        guard let onsite = alert.onsite, let segment = alert.segments.first, let origin = segment.origin, let destination = segment.destination else { return .deferred(.noMatchingTrip) }
        let from = dayString(receivedAt, calendar: calendar, backDays: onsiteWindowDays.before)
        let to = dayString(calendar.date(byAdding: .day, value: onsiteWindowDays.after, to: receivedAt) ?? receivedAt, calendar: calendar)
        let found = cards.indices.filter { index in
            let card = cards[index]
            guard card.origin == origin, card.destination == destination, let date = card.date else { return false }
            return date >= from && date <= to
        }
        if found.count > 1 { return .needsConfirmation(candidateIDs: found.map { cards[$0].id }) }
        guard let index = found.first else { return .deferred(.noMatchingTrip) }
        var filled: [String] = []
        if let lead = onsite.arriveMinutesBeforeDeparture { cards[index].onsiteArriveMinutesBefore = lead; cards[index].sources["onsiteArrive"] = source; filled.append("onsiteArrive") }
        let tips = [onsite.congestedAfterHour.map { "\($0)시 이후 혼잡" }, onsite.counterCloseMinutesBeforeDeparture.map { "수속 마감 출발 \($0)분 전" }].compactMap { $0 }
        for tip in tips where !cards[index].notes.contains(tip) { cards[index].notes.append(tip); if !filled.contains("notes") { filled.append("notes") } }
        cards[index].receivedAt = max(cards[index].receivedAt, receivedAt)
        return .merged(cardID: cards[index].id, filled: filled)
    }

    // MARK: SMS 사전 안내(6번)

    private static func applySMS(_ alert: FlightAlert, into cards: inout [FlightCard], receivedAt: Date, calendar: Calendar, source: FlightFieldSource) -> FlightMergeOutcome {
        guard let segment = alert.segments.first, let flight = segment.flight, let date = dateKey(segment.date, receivedAt: receivedAt, calendar: calendar) else { return .deferred(.noMatchingCard) }
        // 키는 「날짜 + 편명」이다(예약번호 자리의 전화번호 뒷자리는 쓰지 않는다).
        let found = cards.indices.filter { cards[$0].flight == flight && cards[$0].date == date }
        if found.count > 1 { return .needsConfirmation(candidateIDs: found.map { cards[$0].id }) }
        guard let index = found.first else { return .lookupNeeded(flight: flight, date: date) }
        var filled: [String] = []
        for note in alert.notes where !cards[index].notes.contains(note) { cards[index].notes.append(note); if !filled.contains("notes") { filled.append("notes") } }
        cards[index].receivedAt = max(cards[index].receivedAt, receivedAt)
        return .merged(cardID: cards[index].id, filled: filled)
    }

    // MARK: 여행 묶기

    /// 같은 예약번호의 카드, 또는 `A→B`와 `B→A`가 `pairingMaxDays`일 안에 오면 한 여행(출국~귀국 기간)으로 묶는다. 짝이 없는 카드도 하나짜리 여행이다.
    public static func groups(_ cards: [FlightCard]) -> [FlightTripGroup] {
        let dated = cards.filter { $0.date != nil }.sorted { ($0.date ?? "") < ($1.date ?? "") }
        var used = Set<String>()
        var out: [FlightTripGroup] = []
        for card in dated where !used.contains(card.id) {
            var members = [card]
            used.insert(card.id)
            for other in dated where !used.contains(other.id) {
                let samePNR = card.pnr != nil && other.pnr == card.pnr
                let reverse = card.origin != nil && other.origin == card.destination && other.destination == card.origin && (days(from: card.date, to: other.date) ?? -1) >= 0
                    && (days(from: card.date, to: other.date) ?? Int.max) <= pairingMaxDays
                if samePNR || reverse { members.append(other); used.insert(other.id) }
            }
            let dates = members.compactMap(\.date).sorted()
            out.append(FlightTripGroup(cardIDs: members.map(\.id), startDate: dates.first ?? "", endDate: dates.last ?? ""))
        }
        return out
    }

    private static func days(from: String?, to: String?) -> Int? {
        guard let from, let to else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        func parse(_ text: String) -> Date? {
            let parts = text.split(separator: "-").compactMap { Int($0) }
            return parts.count == 3 ? calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) : nil
        }
        guard let a = parse(from), let b = parse(to) else { return nil }
        return calendar.dateComponents([.day], from: a, to: b).day
    }
}
