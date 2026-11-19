import Foundation

// 항공 알림(알림톡·SMS·메일·공유·붙여넣기) 파서(FLT1119A01). 글을 읽어 유형을 가르고 필드를 뽑을 뿐, 카드를 만들거나 합치지는 않는다(`FlightAlertMerge`).
// 읽기만 한다: 결제·예약·취소 같은 동작은 하지 않는다. 읽지 못한 글은 `.unreadable`이다.
// 이름·예약번호·전화번호는 결과 구조체 안에만 있고, 오류 문구·로그에 쓰지 않는다(이 파일은 어떤 것도 출력하지 않는다).

public struct FlightAlertTime: Hashable, Sendable, Comparable {
    public var hour: Int
    public var minute: Int
    public init(hour: Int, minute: Int) { self.hour = hour; self.minute = minute }
    public var minutes: Int { hour * 60 + minute }
    public var text: String { String(format: "%02d:%02d", hour, minute) }
    public static func < (lhs: FlightAlertTime, rhs: FlightAlertTime) -> Bool { lhs.minutes < rhs.minutes }
}

/// 알림글의 날짜. 연도가 없는 글이 많아 `year`는 없을 수 있다.
public struct FlightAlertDate: Hashable, Sendable {
    public var year: Int?
    public var month: Int
    public var day: Int
    public init(year: Int? = nil, month: Int, day: Int) { self.year = year; self.month = month; self.day = day }

    /// 연도가 없으면 기준일(받은 날)에서 가장 가까운 앞날로 정한다: 기준일보다 60일 넘게 앞이면 다음 해.
    public func resolved(reference: Date, calendar: Calendar) -> (year: Int, month: Int, day: Int)? {
        if let year { return valid(year) ? (year, month, day) : nil }
        let base = calendar.component(.year, from: reference)
        for candidate in [base, base + 1] where valid(candidate) {
            guard let date = calendar.date(from: DateComponents(year: candidate, month: month, day: day)) else { continue }
            if date >= reference.addingTimeInterval(-60 * 86_400) { return (candidate, month, day) }
        }
        return nil
    }

    private func valid(_ year: Int) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let parts = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: parts) else { return false }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        return back.year == year && back.month == month && back.day == day
    }
}

public enum FlightAlertKind: String, Sendable {
    /// 항공사 분할 발송 ① 예약번호 안내: 항공사·출발 시각·도시·예약번호(편명 없음).
    case bookingNotice
    /// 항공사 분할 발송 ② 여정: 날짜·편명·노선(시각 없음).
    case itinerary
    /// 본문 항공사명형: 머리표 없이 이름·`ICN - DAD`·출발일·예약번호, 하단 수속·수하물 유의.
    case airlineNameBody
    /// 지연·시간 변경.
    case delayChange
    /// 온라인 체크인 안내(새 카드를 만들지 않는다).
    case checkIn
    /// 공항 현장·혼잡도(새 카드를 만들지 않는다).
    case airportOnsite
    /// `[Web발신]` SMS 사전 안내: 예약번호 자리에 전화번호 뒷자리가 온다.
    case smsAdvance
    /// 여행 부가 예약(eSIM·숙소·면세점).
    case travelExtra
}

public struct FlightAlertSegment: Hashable, Sendable {
    public var flight: String?
    public var origin: String?
    public var destination: String?
    public var date: FlightAlertDate?
    public var time: FlightAlertTime?
    public init(flight: String? = nil, origin: String? = nil, destination: String? = nil, date: FlightAlertDate? = nil, time: FlightAlertTime? = nil) {
        self.flight = flight; self.origin = origin; self.destination = destination; self.date = date; self.time = time
    }
}

public struct FlightAlertChange: Hashable, Sendable {
    public var flight: String?
    public var from: FlightAlertTime?
    public var to: FlightAlertTime?
    public var delayMinutes: Int?
    public var reason: String?
}

public struct FlightAlertCheckIn: Hashable, Sendable {
    public var isOpen: Bool
    /// 마감: 출발 몇 분 전.
    public var deadlineMinutesBeforeDeparture: Int?
}

public struct FlightAlertOnsite: Hashable, Sendable {
    /// 공항에 도착을 권장하는 시간: 출발 몇 분 전.
    public var arriveMinutesBeforeDeparture: Int?
    /// 이 시각 이후 혼잡(시, 24시간제).
    public var congestedAfterHour: Int?
    /// 수속 마감: 출발 몇 분 전.
    public var counterCloseMinutesBeforeDeparture: Int?
}

public struct FlightAlertExtra: Hashable, Sendable {
    public enum Kind: String, Sendable { case esim, lodging, dutyFree }
    public enum Status: String, Sendable { case tentative, booked, received }
    public var kind: Kind
    public var product: String?
    public var country: String?
    public var days: Int?
    public var link: String?
    public var validityNote: String?
    public var status: Status?
    public var orderNumber: String?
    public var pickupPlace: String?
    public var isBusiness: Bool
    /// 연도 없는 기간(체크인·체크아웃 확인이 필요하다).
    public var ambiguousPeriod: (start: FlightAlertDate, end: FlightAlertDate)?
    public var departureDate: FlightAlertDate?
    public var departureTime: FlightAlertTime?

    public static func == (lhs: FlightAlertExtra, rhs: FlightAlertExtra) -> Bool {
        lhs.kind == rhs.kind && lhs.product == rhs.product && lhs.country == rhs.country && lhs.days == rhs.days && lhs.link == rhs.link
            && lhs.validityNote == rhs.validityNote && lhs.status == rhs.status && lhs.orderNumber == rhs.orderNumber && lhs.pickupPlace == rhs.pickupPlace
            && lhs.isBusiness == rhs.isBusiness && lhs.ambiguousPeriod?.start == rhs.ambiguousPeriod?.start && lhs.ambiguousPeriod?.end == rhs.ambiguousPeriod?.end
            && lhs.departureDate == rhs.departureDate && lhs.departureTime == rhs.departureTime
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(kind); hasher.combine(product); hasher.combine(orderNumber); hasher.combine(link)
    }
}

public struct FlightAlert: Hashable, Sendable {
    public var kind: FlightAlertKind
    /// 앞에서 뗀 발신 머리표(`Web발신`). 없으면 nil.
    public var marker: String?
    public var segments: [FlightAlertSegment]
    /// 예약번호(6자 영숫자). 전화번호 뒷자리·긴 숫자는 넣지 않는다. **기기 안에서만 쓴다.**
    public var pnr: String?
    /// `HONG/GILDONG`. 화면에는 「예약자」로만 보이고 서버·AI·로그로 보내지 않는다.
    public var passengerName: String?
    public var airlineName: String?
    public var change: FlightAlertChange?
    public var checkIn: FlightAlertCheckIn?
    public var onsite: FlightAlertOnsite?
    public var extra: FlightAlertExtra?
    /// 하단 유의사항·위약금 주의 같은 접이식 메모 문장.
    public var notes: [String]
    /// 예약번호 자리에 전화번호 뒷자리가 와서 버렸는가(SMS 사전 안내).
    public var droppedPhoneAsPNR: Bool
}

public enum FlightAlertResult: Hashable, Sendable {
    case alert(FlightAlert)
    case unreadable
}

public enum FlightAlertParser {
    /// 글을 읽는다. `receivedAt`은 연도가 없는 날짜를 정하는 기준일(받은 날).
    public static func parse(_ raw: String, receivedAt: Date = .now) -> FlightAlertResult {
        // 길이는 정규화 전에 막는다(긴 글에서 정규식이 느려지지 않게).
        guard raw.utf16.count <= FlightAlertText.maximumCharacters * 2 else { return .unreadable }
        let normalized = FlightAlertText.normalize(raw)
        guard !normalized.text.isEmpty, normalized.text.count <= FlightAlertText.maximumCharacters else { return .unreadable }
        let text = normalized.text
        let upper = normalized.upper
        let marker = normalized.marker

        let pnrInfo = pnr(in: upper)
        let name = passengerName(in: upper)
        let flights = flightNumbers(in: upper)
        let routes = routePairs(in: text, upper: upper)
        let times = clockTimes(in: text)
        let notes = notes(in: text)

        // 1) 여행 부가 예약
        if let extra = ExtraReader.read(text: text, upper: upper) {
            return .alert(FlightAlert(kind: .travelExtra, marker: marker, segments: [], pnr: extra.kind == .lodging ? pnrInfo.value : nil, passengerName: nil,
                                      airlineName: nil, change: nil, checkIn: nil, onsite: nil, extra: extra, notes: [], droppedPhoneAsPNR: false))
        }
        // 2) 지연·시간 변경
        if let change = changeInfo(text: text, flights: flights, times: times) {
            let flight = change.flight
            let segment = FlightAlertSegment(flight: flight, origin: routes.first?.0, destination: routes.first?.1, date: dates(in: text).first, time: change.from)
            return .alert(FlightAlert(kind: .delayChange, marker: marker, segments: [segment], pnr: pnrInfo.value, passengerName: name, airlineName: airlineName(in: text),
                                      change: change, checkIn: nil, onsite: nil, extra: nil, notes: [], droppedPhoneAsPNR: pnrInfo.droppedPhone))
        }
        // 3) 온라인 체크인
        if let checkIn = checkInInfo(text: text), pnrInfo.value != nil || !routes.isEmpty || !flights.isEmpty {
            let segment = FlightAlertSegment(flight: flights.first, origin: routes.first?.0, destination: routes.first?.1, date: dates(in: text).first)
            return .alert(FlightAlert(kind: .checkIn, marker: marker, segments: [segment], pnr: pnrInfo.value, passengerName: name, airlineName: airlineName(in: text),
                                      change: nil, checkIn: checkIn, onsite: nil, extra: nil, notes: [], droppedPhoneAsPNR: pnrInfo.droppedPhone))
        }
        // 4) SMS 사전 안내(예약번호 자리에 전화번호 뒷자리, 위약금 주의)
        if pnrInfo.droppedPhone || (marker != nil && !flights.isEmpty && mentionsPenalty(text)) {
            let segment = FlightAlertSegment(flight: flights.first, origin: routes.first?.0, destination: routes.first?.1, date: dates(in: text).first, time: times.first)
            var memo = notes
            if mentionsPenalty(text) { memo = [penaltyLine(in: text)] + notes }
            return .alert(FlightAlert(kind: .smsAdvance, marker: marker, segments: [segment], pnr: nil, passengerName: name, airlineName: airlineName(in: text),
                                      change: nil, checkIn: nil, onsite: nil, extra: nil, notes: Array(memo.prefix(6)), droppedPhoneAsPNR: pnrInfo.droppedPhone))
        }
        // 5) 공항 현장·혼잡도(예약번호 없이 노선과 권장 시간)
        if pnrInfo.value == nil, let onsite = onsiteInfo(text: text) {
            let segment = FlightAlertSegment(flight: flights.first, origin: routes.first?.0, destination: routes.first?.1, date: dates(in: text).first)
            return .alert(FlightAlert(kind: .airportOnsite, marker: marker, segments: [segment], pnr: nil, passengerName: nil, airlineName: airlineName(in: text),
                                      change: nil, checkIn: nil, onsite: onsite, extra: nil, notes: [], droppedPhoneAsPNR: false))
        }
        // 6) 여정(날짜·편명·노선, 시각 없음)
        let dateList = dates(in: text)
        if !flights.isEmpty, times.isEmpty || !hasDeparture(text) {
            let segments = clauseSegments(text: text, upper: upper)
            if !segments.isEmpty {
                return .alert(FlightAlert(kind: .itinerary, marker: marker, segments: segments, pnr: pnrInfo.value, passengerName: name, airlineName: airlineName(in: text),
                                          change: nil, checkIn: nil, onsite: nil, extra: nil, notes: notes, droppedPhoneAsPNR: false))
            }
        }
        // 7) 예약번호 안내(시각과 「출발」「도착」 도시)
        if pnrInfo.value != nil, let time = times.first, let (origin, destination) = cityPair(in: text) {
            let segment = FlightAlertSegment(flight: flights.first, origin: origin, destination: destination, date: dateList.first, time: time)
            return .alert(FlightAlert(kind: .bookingNotice, marker: marker, segments: [segment], pnr: pnrInfo.value, passengerName: name, airlineName: airlineName(in: text),
                                      change: nil, checkIn: nil, onsite: nil, extra: nil, notes: notes, droppedPhoneAsPNR: false))
        }
        // 8) 본문 항공사명형(`ICN-DAD`, 날짜, 예약번호, 시각·편명 없음)
        if let first = routes.first, pnrInfo.value != nil || name != nil, dateList.first != nil, flights.isEmpty {
            let segment = FlightAlertSegment(flight: nil, origin: first.0, destination: first.1, date: dateList.first, time: times.first)
            return .alert(FlightAlert(kind: .airlineNameBody, marker: marker, segments: [segment], pnr: pnrInfo.value, passengerName: name, airlineName: airlineName(in: text),
                                      change: nil, checkIn: nil, onsite: nil, extra: nil, notes: notes, droppedPhoneAsPNR: false))
        }
        return .unreadable
    }

    // MARK: 신호

    private struct PNR { var value: String?; var droppedPhone: Bool }

    /// 예약번호는 「예약번호」「PNR」「Booking」 라벨 뒤에서만 읽는다. 6자 영숫자(글자와 숫자가 섞이거나 글자만)이고,
    /// `0000-0000` 같은 전화번호 뒷자리·8자리 이상 숫자는 예약번호가 아니다.
    private static func pnr(in upper: String) -> PNR {
        guard let regex = try? NSRegularExpression(pattern: #"(?:예약\s*번호|예약\s*코드|PNR|BOOKING(?:\s*(?:NO|NUMBER|REF))?|CONFIRMATION)\s*[:：]?\s*\(?\s*([A-Z0-9]{4}-[A-Z0-9]{4}|[A-Z0-9]{6,12})"#) else { return PNR(value: nil, droppedPhone: false) }
        var dropped = false
        for match in regex.matches(in: upper, range: NSRange(upper.startIndex..., in: upper)) {
            guard let range = Range(match.range(at: 1), in: upper) else { continue }
            let token = String(upper[range])
            if token.range(of: #"^\d{4}-\d{4}$"#, options: .regularExpression) != nil { dropped = true; continue }
            if token.contains("-") { continue }
            // 6자 영숫자만 예약번호다. 숫자뿐인 긴 값(주문번호·전화번호)은 아니다.
            if token.count == 6 { return PNR(value: token, droppedPhone: dropped) }
        }
        return PNR(value: nil, droppedPhone: dropped)
    }

    private static func passengerName(in upper: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\b([A-Z]{2,}/[A-Z]{2,}(?:\s+(?:MR|MS|MRS|MSTR|MISS))?)\b"#),
              let match = regex.firstMatch(in: upper, range: NSRange(upper.startIndex..., in: upper)), let range = Range(match.range(at: 1), in: upper) else { return nil }
        return String(upper[range])
    }

    /// 편명: 항공사 두 글자(영문 또는 영문·숫자) + 숫자 2~4자리(+ 선택 영문 한 글자). 공항 코드·예약번호·시각은 걸러낸다.
    static func flightNumbers(in upper: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?<![A-Z0-9])([A-Z][A-Z0-9]|[0-9][A-Z])\s?(\d{2,4})[A-Z]?(?![A-Z0-9])"#) else { return [] }
        var out: [String] = []
        for match in regex.matches(in: upper, range: NSRange(upper.startIndex..., in: upper)) {
            guard let airline = Range(match.range(at: 1), in: upper), let number = Range(match.range(at: 2), in: upper) else { continue }
            let code = String(upper[airline]) + String(upper[number])
            // 예약번호 라벨 바로 뒤의 6자는 위 정규식이 이미 6자 연속이라 걸리지 않는다. 날짜(03/07)·시각은 글자가 없어 걸리지 않는다.
            if !out.contains(code) { out.append(code) }
        }
        return out
    }

    /// 공항 코드 쌍(`ICN→BKK`)과 한글 도시 쌍(`다낭→인천`)을 나타난 순서대로.
    static func routePairs(in text: String, upper: String) -> [(String, String)] {
        var found: [(Int, String, String)] = []
        if let regex = try? NSRegularExpression(pattern: #"\b([A-Z]{3})\s*→\s*([A-Z]{3})\b"#) {
            for match in regex.matches(in: upper, range: NSRange(upper.startIndex..., in: upper)) {
                guard let a = Range(match.range(at: 1), in: upper), let b = Range(match.range(at: 2), in: upper) else { continue }
                let from = String(upper[a]), to = String(upper[b])
                if FlightAirportCatalog.airport(from) != nil, FlightAirportCatalog.airport(to) != nil { found.append((match.range.location, from, to)) }
            }
        }
        if let regex = try? NSRegularExpression(pattern: #"([가-힣]{2,12})\s{0,3}→\s{0,3}([가-힣]{2,12})"#) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let a = Range(match.range(at: 1), in: text), let b = Range(match.range(at: 2), in: text),
                      let from = FlightAirportCatalog.airport(city: String(text[a]))?.code, let to = FlightAirportCatalog.airport(city: String(text[b]))?.code else { continue }
                found.append((match.range.location, from, to))
            }
        }
        return found.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
    }

    /// 「인천 출발, 방콕 도착」 꼴의 도시 쌍.
    private static func cityPair(in text: String) -> (String, String)? {
        func code(after pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            return FlightAirportCatalog.airport(city: String(text[range]))?.code
        }
        guard let origin = code(after: #"([가-힣A-Za-z]{2,12})\s{0,3}출발"#), let destination = code(after: #"([가-힣A-Za-z]{2,12})\s{0,3}도착"#) else { return nil }
        return (origin, destination)
    }

    private static func hasDeparture(_ text: String) -> Bool { text.contains("출발") && text.contains("도착") }

    // MARK: 날짜·시각

    /// 날짜 4형식: `2027-03-07`·`2027.03.07`, `3월 7일`, `03/07`, `03.07`. 연도가 없으면 year는 nil.
    static func dates(in text: String) -> [FlightAlertDate] {
        var found: [(Int, FlightAlertDate)] = []
        func scan(_ pattern: String, _ build: ([String]) -> FlightAlertDate?) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let groups = (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
                if let date = build(groups) { found.append((match.range.location, date)) }
            }
        }
        scan(#"(?<!\d)(20\d{2})[-./]\s?(\d{1,2})[-./]\s?(\d{1,2})(?!\d)"#) { g in
            g.count == 3 ? FlightAlertDate(year: Int(g[0]), month: Int(g[1]) ?? 0, day: Int(g[2]) ?? 0) : nil
        }
        scan(#"(?<!\d)(\d{1,2})\s?월\s?(\d{1,2})\s?일"#) { g in g.count == 2 ? FlightAlertDate(month: Int(g[0]) ?? 0, day: Int(g[1]) ?? 0) : nil }
        scan(#"(?<![\d/.])(\d{1,2})/(\d{1,2})(?![\d/])"#) { g in g.count == 2 ? FlightAlertDate(month: Int(g[0]) ?? 0, day: Int(g[1]) ?? 0) : nil }
        scan(#"(?<![\d.])(\d{1,2})\.(\d{1,2})(?![\d.])"#) { g in g.count == 2 ? FlightAlertDate(month: Int(g[0]) ?? 0, day: Int(g[1]) ?? 0) : nil }
        var seen = Set<Int>()
        return found.sorted { $0.0 < $1.0 }.compactMap { location, date in
            guard (1...12).contains(date.month), (1...31).contains(date.day), seen.insert(location).inserted else { return nil }
            return date
        }
    }

    /// `HH:mm` 시각(24시간제)을 나타난 순서대로.
    static func clockTimes(in text: String) -> [FlightAlertTime] {
        guard let regex = try? NSRegularExpression(pattern: #"(?<![\d:])([01]?\d|2[0-3]):([0-5]\d)(?![\d:])"#) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let h = Range(match.range(at: 1), in: text), let m = Range(match.range(at: 2), in: text),
                  let hour = Int(text[h]), let minute = Int(text[m]) else { return nil }
            return FlightAlertTime(hour: hour, minute: minute)
        }
    }

    /// 「2시간 30분」「90분」「1시간」→ 분.
    static func durationMinutes(_ phrase: String) -> Int? {
        if let regex = try? NSRegularExpression(pattern: #"(\d+)\s*시간(?:\s*(\d+)\s*분)?"#),
           let match = regex.firstMatch(in: phrase, range: NSRange(phrase.startIndex..., in: phrase)), let h = Range(match.range(at: 1), in: phrase), let hours = Int(phrase[h]) {
            let minutes = Range(match.range(at: 2), in: phrase).flatMap { Int(phrase[$0]) } ?? 0
            return hours * 60 + minutes
        }
        if let regex = try? NSRegularExpression(pattern: #"(\d+)\s*분"#),
           let match = regex.firstMatch(in: phrase, range: NSRange(phrase.startIndex..., in: phrase)), let m = Range(match.range(at: 1), in: phrase) { return Int(phrase[m]) }
        return nil
    }

    // MARK: 항공사·문장

    private static func airlineName(in text: String) -> String? {
        guard let first = text.split(separator: "\n").first else { return nil }
        if first.hasPrefix("["), let end = first.firstIndex(of: "]") { return String(first[first.index(after: first.startIndex)..<end]) }
        return nil
    }

    /// 하단 유의사항: 번호·불릿·「※」로 시작하거나 수속·수하물·보조배터리 같은 말이 든 문장(최대 6줄, 각 200자).
    private static func notes(in text: String) -> [String] {
        let keys = ["수속", "수하물", "보조배터리", "출국장", "마감", "유의", "주의", "※", "반입", "액체"]
        return text.split(separator: "\n").map(String.init).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.count >= 6 && (trimmed.hasPrefix("※") || trimmed.hasPrefix("*") || trimmed.hasPrefix("-") || trimmed.hasPrefix("•") || keys.contains(where: trimmed.contains))
        }.prefix(6).map { String($0.prefix(200)) }
    }

    private static func mentionsPenalty(_ text: String) -> Bool {
        ["노쇼", "예약부도", "위약금", "부도"].contains(where: text.contains)
    }

    private static func penaltyLine(in text: String) -> String {
        let line = text.split(separator: "\n").first { ["노쇼", "예약부도", "위약금", "부도"].contains(where: $0.contains) }
        return String((line.map(String.init) ?? "노쇼·예약부도 위약금 주의").prefix(200))
    }

    // MARK: 유형별 신호

    private static func changeInfo(text: String, flights: [String], times: [FlightAlertTime]) -> FlightAlertChange? {
        let hasChangeWord = text.contains("변경") || text.contains("지연") || text.uppercased().contains("DELAY")
        guard hasChangeWord else { return nil }
        func time(after label: String) -> FlightAlertTime? {
            guard let range = text.range(of: label) else { return nil }
            return clockTimes(in: String(text[range.upperBound...].prefix(24))).first
        }
        let from = time(after: "기존"), to = time(after: "변경")
        var delay: Int?
        if let regex = try? NSRegularExpression(pattern: #"\+\s*(\d+)\s*분|(\d+)\s*분\s*지연"#),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            for group in 1...2 { if let r = Range(match.range(at: group), in: text) { delay = Int(text[r]) } }
        }
        if delay == nil, let from, let to {
            let diff = to.minutes - from.minutes
            delay = diff < -720 ? diff + 1_440 : diff
        }
        // 기존·변경 시각도 지연 분도 없으면 지연 알림이 아니다(「변경 가능」 같은 안내).
        guard from != nil || to != nil || delay != nil else { return nil }
        var reason: String?
        if let regex = try? NSRegularExpression(pattern: #"(?:지연\s*사유|사유)\s*[:：]?\s*([^\n+]{2,40})"#),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let r = Range(match.range(at: 1), in: text) {
            reason = String(text[r]).trimmingCharacters(in: .whitespaces)
        }
        // 편명: 「편명」 라벨 뒤를 먼저, 없으면 첫 편명.
        var flight = flights.first
        if let regex = try? NSRegularExpression(pattern: #"편명\s*[:：]?\s*([A-Za-z0-9]{2}\s?\d{2,4})"#),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let r = Range(match.range(at: 1), in: text) {
            flight = String(text[r]).replacingOccurrences(of: " ", with: "").uppercased()
        }
        return FlightAlertChange(flight: flight, from: from, to: to, delayMinutes: delay, reason: reason)
    }

    private static func checkInInfo(text: String) -> FlightAlertCheckIn? {
        guard text.contains("체크인") || text.uppercased().contains("CHECK-IN") || text.uppercased().contains("CHECKIN"),
              !["숙소", "호텔", "객실", "체크아웃", "리조트"].contains(where: text.contains) else { return nil }
        let isOpen = ["가능", "오픈", "시작", "열렸", "할 수 있"].contains(where: text.contains)
        var deadline: Int?
        if let regex = try? NSRegularExpression(pattern: #"마감[^\n]{0,12}?출발\s*([^\n]{0,14}?)\s*전|출발\s*([^\n]{0,14}?)\s*전[^\n]{0,8}마감"#),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            for group in 1...2 { if let r = Range(match.range(at: group), in: text), deadline == nil { deadline = durationMinutes(String(text[r])) } }
        }
        return FlightAlertCheckIn(isOpen: isOpen, deadlineMinutesBeforeDeparture: deadline)
    }

    private static func onsiteInfo(text: String) -> FlightAlertOnsite? {
        guard text.contains("권장") || text.contains("혼잡") || text.contains("수속 마감") else { return nil }
        var arrive: Int?, congested: Int?, close: Int?
        if let regex = try? NSRegularExpression(pattern: #"출발\s*([^\n,·]{0,14}?)\s*전[^\n,·]{0,6}?(?:도착|공항)[^\n,·]{0,6}권장"#),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let r = Range(match.range(at: 1), in: text) { arrive = durationMinutes(String(text[r])) }
        if arrive == nil, let regex = try? NSRegularExpression(pattern: #"([^\n,·]{0,14}?)\s*전\s*(?:도착|공항)[^\n,·]{0,6}권장"#),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let r = Range(match.range(at: 1), in: text) { arrive = durationMinutes(String(text[r])) }
        if let regex = try? NSRegularExpression(pattern: #"(\d{1,2})\s*시\s*이후\s*혼잡"#),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let r = Range(match.range(at: 1), in: text) { congested = Int(text[r]) }
        if let regex = try? NSRegularExpression(pattern: #"수속\s*마감\s*([^\n,·]{0,14}?)\s*전"#),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let r = Range(match.range(at: 1), in: text) { close = durationMinutes(String(text[r])) }
        guard arrive != nil || congested != nil || close != nil else { return nil }
        return FlightAlertOnsite(arriveMinutesBeforeDeparture: arrive, congestedAfterHour: congested, counterCloseMinutesBeforeDeparture: close)
    }

    /// 절(쉼표·줄바꿈으로 나눈 조각)마다 날짜·편명·노선을 묶는다. 앞 절의 날짜는 편명만 있는 다음 절에 넘기지 않는다.
    private static func clauseSegments(text: String, upper: String) -> [FlightAlertSegment] {
        let clauses = upper.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" || $0 == "·" }).map(String.init)
        var out: [FlightAlertSegment] = []
        for clause in clauses {
            guard let flight = flightNumbers(in: clause).first else { continue }
            let route = routePairs(in: clause, upper: clause).first
            let date = dates(in: clause).first
            out.append(FlightAlertSegment(flight: flight, origin: route?.0, destination: route?.1, date: date, time: clockTimes(in: clause).first))
        }
        return out
    }
}

// MARK: 여행 부가 예약

enum ExtraReader {
    static func read(text: String, upper: String) -> FlightAlertExtra? {
        let lower = text.lowercased()
        if lower.contains("esim") || text.contains("유심") || upper.contains("USIM") || text.contains("로밍") { return esim(text) }
        if text.contains("면세") || text.contains("인도장") || text.contains("주문완료") || (text.contains("주문번호") && text.contains("수령")) { return dutyFree(text) }
        let lodgingWords = ["숙소", "호텔", "객실", "리조트", "예약 접수", "예약접수", "체크아웃"]
        if lodgingWords.contains(where: text.contains), !text.contains("온라인 체크인") { return lodging(text) }
        return nil
    }

    private static func firstMatch(_ pattern: String, in text: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespaces)
    }

    private static func link(_ text: String) -> String? {
        firstMatch(#"(https://[^\s<>"']{4,300})"#, in: text)
    }

    private static func esim(_ text: String) -> FlightAlertExtra {
        // 상품명 「베트남 · 4일」: 나라와 이용일수
        var country: String?, days: Int?
        if let regex = try? NSRegularExpression(pattern: #"([가-힣A-Za-z]{2,12})\s*[·,/]\s*(\d{1,3})\s*일"#),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let c = Range(match.range(at: 1), in: text), let d = Range(match.range(at: 2), in: text) {
            country = String(text[c]); days = Int(text[d])
        }
        let validity = text.split(separator: "\n").map(String.init).first { $0.contains("QR") || $0.contains("유효") || $0.contains("발급 후") || $0.contains("이내") || $0.contains("내 사용") }
        return FlightAlertExtra(kind: .esim, product: firstMatch(#"(?:상품명|상품)\s*[:：]?\s*([^\n]{2,40})"#, in: text), country: country, days: days,
                                link: link(text), validityNote: validity.map { String($0.prefix(120)) }, status: nil, orderNumber: nil, pickupPlace: nil,
                                isBusiness: false, ambiguousPeriod: nil, departureDate: nil, departureTime: nil)
    }

    private static func lodging(_ text: String) -> FlightAlertExtra {
        let status: FlightAlertExtra.Status? = text.contains("예약 접수") || text.contains("예약접수") ? .tentative : (text.contains("확정") ? .booked : nil)
        // 연도 없는 기간 「05/03 ~ 09/15」
        var period: (FlightAlertDate, FlightAlertDate)?
        if let regex = try? NSRegularExpression(pattern: #"(?<![\d/])(\d{1,2})/(\d{1,2})\s*~\s*(\d{1,2})/(\d{1,2})(?![\d/])"#),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            let nums = (1...4).compactMap { Range(match.range(at: $0), in: text).flatMap { Int(text[$0]) } }
            if nums.count == 4 { period = (FlightAlertDate(month: nums[0], day: nums[1]), FlightAlertDate(month: nums[2], day: nums[3])) }
        }
        return FlightAlertExtra(kind: .lodging, product: nil, country: nil, days: nil, link: link(text), validityNote: nil, status: status, orderNumber: nil, pickupPlace: nil,
                                isBusiness: text.contains("출장"), ambiguousPeriod: period, departureDate: nil, departureTime: nil)
    }

    private static func dutyFree(_ text: String) -> FlightAlertExtra {
        let received = text.contains("정상 수령") || text.contains("수령 완료") || text.contains("수령완료")
        let dates = FlightAlertParser.dates(in: text), times = FlightAlertParser.clockTimes(in: text)
        return FlightAlertExtra(kind: .dutyFree, product: firstMatch(#"주문\s*상품\s*(?:정보)?\s*[:：]?\s*([^\n]{2,60})"#, in: text), country: nil, days: nil, link: nil, validityNote: nil,
                                status: received ? .received : .booked, orderNumber: firstMatch(#"주문\s*번호\s*[:：]?\s*([0-9A-Za-z-]{6,24})"#, in: text),
                                pickupPlace: firstMatch(#"인도장\s*(?:위치)?\s*[:：]?\s*([^\n]{2,40})"#, in: text), isBusiness: false, ambiguousPeriod: nil,
                                departureDate: dates.first, departureTime: times.first)
    }
}
