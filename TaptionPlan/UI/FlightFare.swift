import Foundation
import TaptionPlanStore

/// 항공권 결제 문자·알림 → 항공편 카드 가격(FLT1120A01 C). 이 파일은 순수 판정·매칭만 한다.
/// 판정은 규칙(무료·결정적)이 먼저이고, 확실하지 않으면 아무것도 붙이지 않는다. 문자 원문은 이 파일 밖으로 나가지 않는다.
enum FlightFare {
    enum Verdict: Equatable, Sendable {
        /// 항공권 결제로 본다(항공사 코드를 알면 담는다).
        case flight(airline: String?)
        /// 항공사·OTA 이름만 있고 편명·탑승 단서가 없다. 카드에 자동으로 붙이지 않는다.
        case ambiguous
        case notFlight
    }

    enum Status: Equatable, Sendable { case normal, canceled, partialCancel, installment }

    /// 이름 → IATA 두 글자(국내 항공사).
    static let airlines: [(name: String, code: String)] = [
        ("대한항공", "KE"), ("아시아나", "OZ"), ("제주항공", "7C"), ("티웨이", "TW"), ("진에어", "LJ"),
        ("에어부산", "BX"), ("에어서울", "RS"), ("에어프레미아", "YP"), ("이스타", "ZE"),
    ]
    /// 항공권과 숙박을 같이 파는 곳이 많아 이름만으로 항공권이라 정하지 않는다.
    static let agencies = ["마이리얼트립", "야놀자", "트립닷컴", "스카이스캐너", "하나투어", "모두투어", "노랑풍선", "Expedia", "Booking"]
    /// 숙박 단서(H-3이 정본). 있으면 항공권이 아니다.
    static let lodgingClues = ["체크인", "체크아웃", "투숙", "객실", "숙소", "호텔", "펜션", "리조트", "박 "]
    static let flightClues = ["탑승", "편명", "항공권", "항공편", "출발", "도착", "공항"]

    static func airlineCode(in text: String) -> String? {
        airlines.first { text.contains($0.name) }?.code
    }

    /// 문자에서 편명(`KE1201`)을 읽는다. 아는 항공사 코드로 시작할 때만(카드 번호 같은 숫자를 편명으로 보지 않는다).
    static func flightNumber(in text: String) -> String? {
        let known = Set(airlines.map(\.code))
        let upper = text.uppercased()
        let pattern = #"(?<![A-Z0-9])([A-Z0-9]{2})\s?(\d{2,4})(?![0-9])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = upper as NSString
        for match in regex.matches(in: upper, range: NSRange(location: 0, length: ns.length)) {
            let code = ns.substring(with: match.range(at: 1)), digits = ns.substring(with: match.range(at: 2))
            if known.contains(code) { return code + digits }
        }
        return nil
    }

    static func classify(_ text: String) -> Verdict {
        let named = airlines.contains { text.contains($0.name) } || agencies.contains { text.localizedCaseInsensitiveContains($0) }
        if lodgingClues.contains(where: { text.contains($0) }) { return .notFlight }
        let number = flightNumber(in: text)
        let clues = flightClues.contains { text.contains($0) }
        if number != nil || (named && clues && text.contains("항공")) { return .flight(airline: airlineCode(in: text) ?? number.map { String($0.prefix(2)) }) }
        return named ? .ambiguous : .notFlight
    }

    static func status(of text: String) -> Status {
        if text.contains("부분취소") { return .partialCancel }
        if text.contains("취소") { return .canceled }
        if text.contains("할부") { return .installment }
        return .normal
    }

    struct Expense: Equatable, Sendable {
        var id: String
        var amount: Int
        var currency: String
        var tripID: String?
        var flightNumber: String?
        var airlineCode: String?
        var isRoundTrip: Bool
    }

    enum Match: Equatable, Sendable {
        case attach(tripID: String, itemID: String, roundTrip: Bool)
        /// 1:1로 정해지지 않았다. 자동으로 붙이지 않고 사용자가 고른다.
        case candidates([String])
        case none
    }

    /// 카드 ↔ 지출. ① 편명 ③ 항공사(왕복 한 건은 한 카드에만). 한 지출은 한 카드, 이미 가격이 붙은 카드는 건너뛴다.
    static func match(_ expense: Expense, cards: [TravelTripItem]) -> Match {
        let free = cards.filter { $0.isFlight && ($0.fareExpenseID == nil || $0.fareExpenseID == expense.id) }
            .filter { expense.tripID == nil || $0.tripID == expense.tripID }
        func pick(_ list: [TravelTripItem], roundTrip: Bool) -> Match {
            let sorted = list.sorted { $0.start < $1.start }
            if let own = sorted.first(where: { $0.fareExpenseID == expense.id }) { return .attach(tripID: own.tripID, itemID: own.itemID, roundTrip: roundTrip) }
            if sorted.count == 1 { return .attach(tripID: sorted[0].tripID, itemID: sorted[0].itemID, roundTrip: roundTrip) }
            // 왕복 한 건은 같은 여행의 첫 카드에만 붙이고 「왕복 결제」로 표시한다.
            if roundTrip, sorted.count > 1, Set(sorted.map(\.tripID)).count == 1, let first = sorted.first {
                return .attach(tripID: first.tripID, itemID: first.itemID, roundTrip: true)
            }
            return sorted.isEmpty ? .none : .candidates(sorted.map { FlightCardMapping.cardID(tripID: $0.tripID, itemID: $0.itemID) })
        }
        if let number = expense.flightNumber {
            return pick(free.filter { $0.flightNumber?.uppercased() == number.uppercased() }, roundTrip: false)
        }
        if let code = expense.airlineCode {
            return pick(free.filter { ($0.flightNumber ?? "").uppercased().hasPrefix(code) }, roundTrip: expense.isRoundTrip)
        }
        return .none
    }

    /// 카드에 보이는 한 줄: `₩89,000 · 결제 문자`. 원화가 아니면 통화 코드를 그대로.
    static func fareText(_ item: TravelTripItem, language: MapHomeLanguage) -> String? {
        guard let amount = item.fareAmount, item.fareSource != "canceled" else {
            return item.fareSource == "canceled" ? language.text("취소됨", "Canceled") : nil
        }
        let currency = item.fareCurrency ?? "KRW"
        let number = amount.formatted()
        let money = currency == "KRW" ? "₩\(number)" : "\(currency) \(number)"
        let source = (item.fareSource ?? "").hasPrefix("paymentText") ? language.text("결제 문자", "payment text") : language.text("직접", "manual")
        let round = (item.fareSource ?? "").hasSuffix(":roundTrip") ? language.text(" · 왕복 결제", " · round trip") : ""
        return "\(money) · \(source)\(round)"
    }
}

/// 가계부에 결제를 넣은 직후 그 결제를 항공편 카드에 잇는다. 알 수 없거나 여럿이면 아무것도 붙이지 않는다.
@MainActor
enum FlightFareLinker {
    enum Outcome: Equatable { case attached, candidates, ignored }

    @discardableResult
    static func handle(_ entry: LedgerEntry, text: String, model: AppModel? = AssistantCommandRefresh.model) async -> Outcome {
        guard let model, entry.kind == .expense, entry.canceledAt == nil, case let .flight(airline) = FlightFare.classify(text) else { return .ignored }
        let status = FlightFare.status(of: text)
        // 취소·부분취소·할부는 금액을 카드에 옮기지 않는다(카드사 확인).
        guard status == .normal else { return .ignored }
        let expense = FlightFare.Expense(
            id: entry.id.uuidString, amount: Int(entry.amount.rounded()), currency: entry.currency, tripID: entry.tripID,
            flightNumber: FlightFare.flightNumber(in: text), airlineCode: airline, isRoundTrip: text.contains("왕복")
        )
        switch FlightFare.match(expense, cards: model.snapshot.settings.travelTripItems ?? []) {
        case let .attach(tripID, itemID, roundTrip):
            let source = "paymentText" + (roundTrip ? ":roundTrip" : "")
            return await model.attachFare(tripID: tripID, itemID: itemID, amount: expense.amount, currency: expense.currency, source: source, expenseID: expense.id) ? .attached : .ignored
        case .candidates: return .candidates
        case .none: return .ignored
        }
    }

    /// 지출을 지우면 연결을 푼다(카드는 남는다).
    static func released(_ expenseID: UUID, model: AppModel? = AssistantCommandRefresh.model) async {
        await model?.releaseFare(expenseID: expenseID.uuidString)
    }

    /// 지출이 취소되면 카드 금액도 「취소됨」으로.
    static func canceled(_ expenseID: UUID, model: AppModel? = AssistantCommandRefresh.model) async {
        await model?.markFareCanceled(expenseID: expenseID.uuidString)
    }
}

extension AppModel {
    func attachFare(tripID: String, itemID: String, amount: Int, currency: String, source: String, expenseID: String) async -> Bool {
        var items = snapshot.settings.travelTripItems ?? []
        guard acceptsDataMutation(), let index = items.firstIndex(where: { $0.tripID == tripID && $0.itemID == itemID }), items[index].isFlight else { return false }
        items[index].applyFare(amount: amount, currency: currency, source: source, expenseID: expenseID)
        snapshot.settings.travelTripItems = items
        return await persist()
    }

    func releaseFare(expenseID: String) async {
        var items = snapshot.settings.travelTripItems ?? []
        let hits = items.indices.filter { items[$0].fareExpenseID == expenseID }
        guard !hits.isEmpty, acceptsDataMutation() else { return }
        for index in hits { items[index].clearFare() }
        snapshot.settings.travelTripItems = items
        _ = await persist()
    }

    func markFareCanceled(expenseID: String) async {
        var items = snapshot.settings.travelTripItems ?? []
        let hits = items.indices.filter { items[$0].fareExpenseID == expenseID }
        guard !hits.isEmpty, acceptsDataMutation() else { return }
        for index in hits { items[index].fareSource = "canceled" }
        snapshot.settings.travelTripItems = items
        _ = await persist()
    }
}
