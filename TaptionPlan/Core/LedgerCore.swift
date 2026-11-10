import Foundation
import Observation
import TaptionPlanStore

/// 가계부(LED1110A01, 추천안으로 만듦 2026-11-11 — 바꿀 수 있음).
/// 저장: 앱 SQLite(`TaptionStoreV2`)에 자기 종류(`ledger-entry`·`ledger-budget`)로 둔다. 말풍선·건강 기록과 같은 방식이라
/// 월별 백업(TAPTBK03)에 그대로 들어가고 옛 백업 형식은 바뀌지 않는다. 지운 것은 지움 표시로 남긴다.
enum LedgerCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case food, cafe, transport, shopping, living, health, culture, travel, lodging, education, gift, salary, other

    var id: String { rawValue }

    func title(_ language: MapHomeLanguage) -> String {
        switch self {
        case .food: language.text("식비", "Food")
        case .cafe: language.text("카페·간식", "Cafe")
        case .transport: language.text("교통", "Transport")
        case .shopping: language.text("쇼핑", "Shopping")
        case .living: language.text("생활", "Living")
        case .health: language.text("의료·건강", "Health")
        case .culture: language.text("문화·여가", "Leisure")
        case .travel: language.text("여행", "Travel")
        case .lodging: language.text("숙소", "Lodging")
        case .education: language.text("교육", "Education")
        case .gift: language.text("선물·경조사", "Gifts")
        case .salary: language.text("급여", "Salary")
        case .other: language.text("기타", "Other")
        }
    }

    var symbol: String {
        switch self {
        case .food: "fork.knife"
        case .cafe: "cup.and.saucer.fill"
        case .transport: "tram.fill"
        case .shopping: "bag.fill"
        case .living: "house.fill"
        case .health: "cross.case.fill"
        case .culture: "ticket.fill"
        case .travel: "airplane"
        case .lodging: "bed.double.fill"
        case .education: "book.fill"
        case .gift: "gift.fill"
        case .salary: "banknote.fill"
        case .other: "ellipsis.circle.fill"
        }
    }

    /// 글에서 분류를 짐작한다(결제 문자·영수증·AI). 모르면 기타.
    static func guess(_ text: String) -> LedgerCategory {
        let lower = text.lowercased() + " "
        let table: [(LedgerCategory, [String])] = [
            (.culture, ["cgv", "메가박스", "롯데시네마", "영화", "넷플릭스", "공연", "netflix"]),
            (.shopping, ["메가마트"]),
            (.food, ["전기구이"]),
            (.cafe, ["카페", "커피", "스타벅스", "투썸", "이디야", "메가커피", "메가mgc", "빽다방", "베이커리", "파리바게뜨", "cafe", "coffee", "starbucks"]),
            (.transport, ["택시", "카카오t", "버스", "지하철", "코레일", "ktx", "srt", "주유", "티머니", "교통", "taxi", "uber"]),
            (.food, ["식당", "치킨", "피자", "배달의민족", "배민", "요기요", "쿠팡이츠", "국밥", "김밥", "맥도날드", "버거", "restaurant"]),
            (.shopping, ["쿠팡", "11번가", "지마켓", "무신사", "올리브영", "다이소", "백화점", "마트", "이마트", "홈플러스", "amazon"]),
            (.living, ["편의점", "gs25", "cu ", "씨유", "세븐일레븐", "관리비", "통신", "전기", "가스", "수도"]),
            (.health, ["병원", "약국", "의원", "치과", "pharmacy", "hospital"]),
            (.lodging, ["호텔", "모텔", "에어비앤비", "숙소", "hotel", "airbnb"]),
            (.travel, ["항공", "공항", "면세", "airline"]),
        ]
        return table.first { _, words in words.contains { lower.contains($0) } }?.0 ?? .other
    }
}

struct LedgerEntry: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable { case expense, income }
    enum Source: String, Codable, Sendable { case manual, assistant, message, receipt }

    var id = UUID()
    var occurredAt: Date
    /// 그 통화의 금액(양수).
    var amount: Double
    var currency = "KRW"
    /// 넣을 때의 원화 환산(원화면 같은 값). 환율을 몰랐으면 nil.
    var amountKRW: Double?
    var kind: Kind = .expense
    var category: LedgerCategory = .other
    var title: String
    var place: String?
    /// 단체 정산용. 비우면 나.
    var payer: String?
    var tripID: String?
    var note: String?
    var source: Source = .manual
    var createdAt = Date()

    var signedKRW: Double { (amountKRW ?? 0) * (kind == .expense ? -1 : 1) }
}

struct LedgerBudget: Codable, Equatable, Identifiable, Sendable {
    /// `yyyy-MM` 또는 여행 id(`trip:<id>`).
    var period: String
    var category: LedgerCategory?
    var amountKRW: Double
    var id: String { "\(period)|\(category?.rawValue ?? "all")" }
}

/// 환율(원화 환산). 중계 서버 `GET /fx`(하루 한 번 공개 환율)를 쓰고, 사용자가 넣은 값이 있으면 그것을 먼저 쓴다.
enum LedgerFX {
    struct Table: Codable, Equatable, Sendable {
        var base: String
        var rates: [String: Double]
        var day: String
    }

    /// 1 `currency` = 몇 원.
    static func krwPerUnit(_ currency: String, table: Table?, manual: [String: Double]) -> Double? {
        let code = currency.uppercased()
        if code == "KRW" { return 1 }
        if let value = manual[code], value > 0 { return value }
        guard let table, let krw = table.rates["KRW"], let unit = table.rates[code], unit > 0 else { return nil }
        return krw / unit
    }

    static func parse(_ data: Data) -> Table? {
        try? JSONDecoder().decode(Table.self, from: data)
    }

    @MainActor
    static func fetch(env: AssistantRegistration.Environment = .live) async -> Table? {
        guard let token = await AssistantRegistration.searchToken(),
              let reply = await TripRelay.send(TripRelay.relayRequest("/fx", method: "GET", token: token, host: env.host), session: env.session),
              reply.status == 200 else { return nil }
        return parse(reply.data)
    }
}

/// 단체 정산: 누가 냈는지와 나눌 사람으로 최소 송금 목록을 만든다(큰 빚부터 큰 받을 돈에 맞춘다).
enum LedgerSettlement {
    struct Transfer: Equatable, Sendable {
        var from: String
        var to: String
        var amountKRW: Double
    }

    /// `entries`의 지출을 `people`이 똑같이 나눈다. 낸 사람이 비었으면 `me`가 낸 것이다.
    static func transfers(_ entries: [LedgerEntry], people: [String], me: String) -> [Transfer] {
        // 낸 사람 칸에 적힌 이름은 목록에 없어도 함께한 사람으로 센다(다른 표기를 「나」로 돌리지 않는다).
        let payers = entries.compactMap { $0.payer?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let members = Array(Set(people + [me] + payers)).sorted()
        guard members.count >= 2 else { return [] }
        var balance = Dictionary(uniqueKeysWithValues: members.map { ($0, 0.0) })
        for entry in entries where entry.kind == .expense {
            let krw = entry.amountKRW ?? 0
            let payer = entry.payer.flatMap { members.contains($0) ? $0 : nil } ?? me
            balance[payer, default: 0] += krw
            for member in members { balance[member, default: 0] -= krw / Double(members.count) }
        }
        var debtors = balance.filter { $0.value < -0.5 }.map { ($0.key, -$0.value) }.sorted { $0.1 > $1.1 }
        var creditors = balance.filter { $0.value > 0.5 }.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
        var result: [Transfer] = []
        while let debtor = debtors.first, let creditor = creditors.first {
            let amount = min(debtor.1, creditor.1)
            result.append(Transfer(from: debtor.0, to: creditor.0, amountKRW: amount.rounded()))
            debtors[0].1 -= amount
            creditors[0].1 -= amount
            if debtors[0].1 < 0.5 { debtors.removeFirst() }
            if creditors[0].1 < 0.5 { creditors.removeFirst() }
        }
        return result
    }
}

/// 가계부 장부. 화면은 이것만 본다. 쓰기는 바로 메모리에 반영하고 SQLite에 이어서 쓴다.
@MainActor
@Observable
final class LedgerBook {
    static let shared = LedgerBook()
    static let entryKind = "ledger-entry"
    static let budgetKind = "ledger-budget"
    static let manualRatesKey = "ledgerManualRates"

    private(set) var entries: [LedgerEntry] = []
    private(set) var budgets: [LedgerBudget] = []
    private(set) var fx: LedgerFX.Table?
    private(set) var isLoaded = false
    @ObservationIgnored private let storeFactory: () -> TaptionStoreV2?
    @ObservationIgnored private var loading: Task<Void, Never>?

    init(store: @escaping () -> TaptionStoreV2? = { try? TaptionStoreV2.applicationSupport() }) {
        storeFactory = store
    }

    /// 한 번만 읽는다. 동시에 부르면 같은 읽기를 기다린다(늦게 끝난 읽기가 그 사이 저장한 기록을 덮지 않게).
    func load() async {
        guard !isLoaded else { return }
        if let loading { return await loading.value }
        let task = Task { await read() }
        loading = task
        await task.value
        loading = nil
    }

    private func read() async {
        guard !isLoaded, let store = storeFactory() else { return }
        let decoder = JSONDecoder()
        let rows = (try? await store.records(kind: Self.entryKind)) ?? []
        let budgetRows = (try? await store.records(kind: Self.budgetKind)) ?? []
        let saved = entries
        entries = rows.compactMap { try? decoder.decode(LedgerEntry.self, from: Data($0.body.utf8)) }.sorted { $0.occurredAt > $1.occurredAt }
        budgets = budgetRows.compactMap { try? decoder.decode(LedgerBudget.self, from: Data($0.body.utf8)) }
        // 읽는 동안 메모리에만 들어온 기록(저장소가 없는 시험 포함)은 남긴다.
        for entry in saved where !entries.contains(where: { $0.id == entry.id }) { entries.append(entry) }
        entries.sort { $0.occurredAt > $1.occurredAt }
        isLoaded = true
    }

    /// 복원·전체 삭제 뒤 저장소에서 다시 읽게 한다.
    func reset() {
        entries = []
        budgets = []
        isLoaded = false
    }

    func refreshRates() async {
        if let table = await LedgerFX.fetch() { fx = table }
    }

    var manualRates: [String: Double] {
        get { (UserDefaults.standard.dictionary(forKey: Self.manualRatesKey) as? [String: Double]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.manualRatesKey) }
    }

    func krw(_ amount: Double, currency: String) -> Double? {
        LedgerFX.krwPerUnit(currency, table: fx, manual: manualRates).map { ($0 * amount).rounded() }
    }

    /// 넣거나 바꾼다. 원화 환산이 비었으면 지금 환율로 채운다.
    @discardableResult
    func save(_ entry: LedgerEntry) async -> LedgerEntry {
        await load()
        var value = entry
        // 단축어·AI처럼 가계부를 열기 전에 들어온 외화도 원화로 채운다. 환율을 못 받으면 비워 두고 다음에 채운다.
        if value.amountKRW == nil, value.currency != "KRW", fx == nil, manualRates[value.currency] == nil { await refreshRates() }
        if value.amountKRW == nil { value.amountKRW = krw(value.amount, currency: value.currency) }
        if let index = entries.firstIndex(where: { $0.id == value.id }) { entries[index] = value } else { entries.append(value) }
        entries.sort { $0.occurredAt > $1.occurredAt }
        await write(value, deleted: false)
        return value
    }

    func delete(_ id: UUID) async {
        await load()
        let entry = entries.first { $0.id == id } ?? LedgerEntry(id: id, occurredAt: .now, amount: 0, title: "")
        entries.removeAll { $0.id == id }
        // 메모리에 없어도 지움 표시를 남긴다(되돌리기가 저장소 행을 놓치지 않게).
        await write(entry, deleted: true)
    }

    /// 원화 환산이 빈 외화 기록을 지금 환율로 채운다(가계부를 열 때).
    func fillMissingKRW() async {
        for entry in entries where entry.amountKRW == nil {
            guard let value = krw(entry.amount, currency: entry.currency) else { continue }
            var filled = entry
            filled.amountKRW = value
            await save(filled)
        }
    }

    func setBudget(_ budget: LedgerBudget?, for id: String, period: String, category: LedgerCategory?) async {
        budgets.removeAll { $0.id == id }
        let value = budget ?? LedgerBudget(period: period, category: category, amountKRW: 0)
        if let budget { budgets.append(budget) }
        guard let store = storeFactory(), let body = try? JSONEncoder().encode(value), let text = String(data: body, encoding: .utf8) else { return }
        try? await store.upsertRecords([TaptionStoreRecord(id: value.id, kind: Self.budgetKind, updatedAt: .now, origin: .user, isDeleted: budget == nil, body: text)])
    }

    private func write(_ entry: LedgerEntry, deleted: Bool) async {
        guard let store = storeFactory(), let body = try? JSONEncoder().encode(entry), let text = String(data: body, encoding: .utf8) else { return }
        let record = TaptionStoreRecord(
            id: entry.id.uuidString, kind: Self.entryKind, start: entry.occurredAt, end: entry.occurredAt,
            updatedAt: .now, origin: entry.source == .manual ? .user : .imported, isDeleted: deleted, body: text
        )
        try? await store.upsertRecords([record])
    }

    // MARK: 모아 보기

    static func monthKey(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    func entries(inMonth month: String, calendar: Calendar = .autoupdatingCurrent) -> [LedgerEntry] {
        entries.filter { Self.monthKey($0.occurredAt, calendar: calendar) == month }
    }

    func entries(on day: Date, calendar: Calendar = .autoupdatingCurrent) -> [LedgerEntry] {
        entries.filter { calendar.isDate($0.occurredAt, inSameDayAs: day) }
    }

    static func total(_ list: [LedgerEntry], _ kind: LedgerEntry.Kind) -> Double {
        list.filter { $0.kind == kind }.reduce(0) { $0 + ($1.amountKRW ?? 0) }
    }

    func budget(for period: String, category: LedgerCategory? = nil) -> LedgerBudget? {
        budgets.first { $0.period == period && $0.category == category && $0.amountKRW > 0 }
    }

    /// 오늘 손익: 오늘 번 돈(세후 월급을 그 달 날수로 나눔) − 오늘 쓴 돈 + 오늘 들어온 돈.
    func todayNet(now: Date = .now, calendar: Calendar = .autoupdatingCurrent, monthlyNet: Double) -> Double {
        let days = Double(calendar.range(of: .day, in: .month, for: now)?.count ?? 30)
        let today = entries(on: now, calendar: calendar)
        // 월급 기록은 이미 하루 몫으로 나눠 넣었으니 수입에서 뺀다.
        return (monthlyNet / days).rounded() - Self.total(today, .expense) + Self.total(today.filter { $0.category != .salary }, .income)
    }
}

enum LedgerMoney {
    static func text(_ amount: Double, currency: String = "KRW", language: MapHomeLanguage) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = currency == "KRW" || currency == "JPY" ? 0 : 2
        let number = formatter.string(from: NSNumber(value: amount)) ?? "\(amount)"
        return currency == "KRW" ? language.text("\(number)원", "₩\(number)") : "\(currency) \(number)"
    }
}
