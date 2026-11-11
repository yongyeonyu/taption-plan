import Foundation
import Observation
import os
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
    /// 메모에서 금액을 알아봐 만든 기록이면 그 메모 id(LED1111A03). 메모를 고치거나 지우면 따라간다.
    var memoID: UUID?
    var note: String?
    var source: Source = .manual
    var createdAt = Date()
    /// 여행 지출의 몫을 나누는 사람(LED1111A05). nil이면 「다 같이 n분의 1」(= 공금), `[LedgerTrip.me]`면 나만.
    var shareNames: [String]?
    /// 일상↔여행 사이를 오가는 짝 기록(예산 이체·정산). 비용 계산에서 뺀다.
    var transfer: LedgerTransfer?
    /// 취소된 결제면 그 시각(LCN1111A01, 대표 결정). 기록은 남기고 합계에서만 뺀다. 예전 기록에는 없다.
    var canceledAt: Date?

    /// 합계에 더하는 원화 금액. 취소된 결제는 0이다.
    var countedKRW: Double { canceledAt == nil ? (amountKRW ?? 0) : 0 }
    var signedKRW: Double { countedKRW * (kind == .expense ? -1 : 1) }
}

struct LedgerBudget: Codable, Equatable, Identifiable, Sendable {
    /// `yyyy-MM` 또는 여행 id(`trip:<id>`).
    var period: String
    var category: LedgerCategory?
    var amountKRW: Double
    var id: String { "\(period)|\(category?.rawValue ?? "all")" }
}

/// 읽기 안전망(LDS1111A01). 꼭 있어야 하는 칸(id·시각·금액)만 필수로 읽고 나머지는 없으면 기본값으로 둔다.
/// 모르는 분류는 기타, 모르는 출처는 직접 넣음으로 읽는다. 돈 방향(지출/수입)과 이체 종류는 모르면 읽지 않는다:
/// 잘못 세는 것보다 빼고 알리는 게 낫다(`LedgerBook.unreadable`). 새 칸을 더하면 여기에도 더한다(왕복 시험이 잡는다).
extension LedgerEntry {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        occurredAt = try values.decode(Date.self, forKey: .occurredAt)
        amount = try values.decode(Double.self, forKey: .amount)
        currency = try values.decodeIfPresent(String.self, forKey: .currency) ?? "KRW"
        amountKRW = try values.decodeIfPresent(Double.self, forKey: .amountKRW)
        kind = try values.decodeIfPresent(Kind.self, forKey: .kind) ?? .expense
        category = try values.decodeIfPresent(String.self, forKey: .category).flatMap(LedgerCategory.init(rawValue:)) ?? .other
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        place = try values.decodeIfPresent(String.self, forKey: .place)
        payer = try values.decodeIfPresent(String.self, forKey: .payer)
        tripID = try values.decodeIfPresent(String.self, forKey: .tripID)
        memoID = try values.decodeIfPresent(UUID.self, forKey: .memoID)
        note = try values.decodeIfPresent(String.self, forKey: .note)
        source = try values.decodeIfPresent(String.self, forKey: .source).flatMap(Source.init(rawValue:)) ?? .manual
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? occurredAt
        shareNames = try values.decodeIfPresent([String].self, forKey: .shareNames)
        transfer = try values.decodeIfPresent(LedgerTransfer.self, forKey: .transfer)
        canceledAt = try values.decodeIfPresent(Date.self, forKey: .canceledAt)
    }
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

/// 단체 정산: 누가 냈는지와 나눌 사람으로 최소 송금 목록을 만든다(`LedgerSplit`, 원 단위).
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
        var balance = Dictionary(uniqueKeysWithValues: members.map { ($0, 0) })
        for entry in entries where entry.kind == .expense {
            let won = LedgerSplit.won(entry.countedKRW)
            let payer = entry.payer.flatMap { members.contains($0) ? $0 : nil } ?? me
            balance[payer, default: 0] += won
            for (member, share) in zip(members, LedgerSplit.even(won, among: members, payer: payer)) { balance[member, default: 0] -= share }
        }
        return LedgerSplit.transfers(balance, order: members).map { Transfer(from: $0.from, to: $0.to, amountKRW: Double($0.amount)) }
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
    /// 여행 장부(LED1111A05). 일상 장부 아래 칸이다.
    var trips: [LedgerTrip] = []
    private(set) var fx: LedgerFX.Table?
    private(set) var isLoaded = false
    /// 읽지 못한 행 수(저장 종류별, LDS1111A01). 행은 저장소에 그대로 남아 백업에 들어가고 다음 빌드가 다시 읽는다.
    private(set) var unreadable: [String: Int] = [:]
    /// 기록이 바뀔 때마다 1씩 는다. 카운터가 다시 셀지 정한다.
    private(set) var revision = 0
    @ObservationIgnored let storeFactory: () -> TaptionStoreV2?
    @ObservationIgnored private var loading: Task<Void, Never>?
    /// 메모마다 이어진 기록 맞추기를 차례로 한다(리뷰: 빨리 두 번 고치면 기록이 둘 생기던 것).
    @ObservationIgnored var memoQueues: [UUID: Task<Void, Never>] = [:]
    /// `reset()`마다 늘린다. 그 전에 시작한 읽기는 결과를 버린다.
    @ObservationIgnored private var generation = 0
    /// 환율을 마지막으로 받으려 한 때. 실패해도 10분 안에는 다시 기다리지 않는다.
    @ObservationIgnored private var lastRateAttempt = Date.distantPast

    init(store: @escaping () -> TaptionStoreV2? = { try? TaptionStoreV2.applicationSupport() }) {
        storeFactory = store
    }

    /// 한 번만 읽는다. 동시에 부르면 같은 읽기를 기다린다(늦게 끝난 읽기가 그 사이 저장한 기록을 덮지 않게).
    func load() async {
        guard !isLoaded else { return }
        if let loading { return await loading.value }
        let started = generation
        let task = Task { await read(generation: started) }
        loading = task
        await task.value
        if generation == started { loading = nil }
        // 읽는 사이 reset됐으면 새로 읽는다.
        if !isLoaded, generation != started { await load() }
    }

    private func read(generation started: Int) async {
        guard !isLoaded, let store = storeFactory() else { return }
        let rows = (try? await store.records(kind: Self.entryKind)) ?? []
        let budgetRows = (try? await store.records(kind: Self.budgetKind)) ?? []
        let tripRows = (try? await store.records(kind: LedgerTrip.kind)) ?? []
        guard generation == started else { return }
        let readTrips = Self.decodeRows(tripRows.map(\.body), as: LedgerTrip.self)
        let readEntries = Self.decodeRows(rows.map(\.body), as: LedgerEntry.self)
        let readBudgets = Self.decodeRows(budgetRows.map(\.body), as: LedgerBudget.self)
        let failed = [LedgerTrip.kind: readTrips.failed, Self.entryKind: readEntries.failed, Self.budgetKind: readBudgets.failed].filter { $0.value > 0 }
        if unreadable != failed { unreadable = failed }
        if !failed.isEmpty { Self.log.error("ledger rows left unread: \(failed.description, privacy: .public)") }
        trips = readTrips.values.sorted { $0.start > $1.start }
        let saved = entries
        entries = readEntries.values.sorted { $0.occurredAt > $1.occurredAt }
        budgets = readBudgets.values
        // 읽는 동안 메모리에만 들어온 기록(저장소가 없는 시험 포함)은 남긴다.
        for entry in saved where !entries.contains(where: { $0.id == entry.id }) { entries.append(entry) }
        entries.sort { $0.occurredAt > $1.occurredAt }
        isLoaded = true
        revision += 1
    }

    private static let log = Logger(subsystem: "TaptionPlan", category: "ledger")

    /// 저장된 글을 하나씩 읽는다. 못 읽은 것은 건너뛰고 개수만 돌려준다(한 행 때문에 나머지를 잃지 않게).
    nonisolated static func decodeRows<Value: Decodable>(_ bodies: [String], as type: Value.Type) -> (values: [Value], failed: Int) {
        let decoder = JSONDecoder()
        var values: [Value] = []
        for body in bodies {
            if let value = try? decoder.decode(type, from: Data(body.utf8)) { values.append(value) }
        }
        return (values, bodies.count - values.count)
    }

    /// 복원·전체 삭제 뒤 저장소에서 다시 읽게 한다.
    func reset() {
        generation += 1
        loading = nil
        entries = []
        budgets = []
        trips = []
        unreadable = [:]
        isLoaded = false
        revision += 1
    }

    func refreshRates(now: Date = .now) async {
        lastRateAttempt = now
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
        if value.amountKRW == nil, value.currency != "KRW", fx == nil, manualRates[value.currency] == nil,
           Date.now.timeIntervalSince(lastRateAttempt) > 600 { await refreshRates() }
        if value.amountKRW == nil { value.amountKRW = krw(value.amount, currency: value.currency) }
        if let index = entries.firstIndex(where: { $0.id == value.id }) { entries[index] = value } else { entries.append(value) }
        entries.sort { $0.occurredAt > $1.occurredAt }
        revision += 1
        await write(value, deleted: false)
        return value
    }

    func delete(_ id: UUID) async {
        await load()
        let entry = entries.first { $0.id == id } ?? LedgerEntry(id: id, occurredAt: .now, amount: 0, title: "")
        entries.removeAll { $0.id == id }
        revision += 1
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

    nonisolated static func monthKey(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
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
        list.filter { $0.kind == kind }.reduce(0) { $0 + $1.countedKRW }
    }

    func budget(for period: String, category: LedgerCategory? = nil) -> LedgerBudget? {
        budgets.first { $0.period == period && $0.category == category && $0.amountKRW > 0 }
    }

    /// 오늘 손익: 오늘 번 돈(세후 월급을 그 달 날수로 나눔) − 오늘 쓴 돈 + 오늘 들어온 돈.
    func todayNet(now: Date = .now, calendar: Calendar = .autoupdatingCurrent, monthlyNet: Double) -> Double {
        let days = Double(calendar.range(of: .day, in: .month, for: now)?.count ?? 30)
        // 일상 장부만: 여행 안 기록까지 더하면 여행 경비 이체와 겹쳐 두 번 빠진다(리뷰).
        let today = entries(on: now, calendar: calendar).filter(isDaily)
        // 월급 기록은 이미 하루 몫으로 나눠 넣었으니 수입에서 뺀다.
        return (monthlyNet / days).rounded() - Self.total(today, .expense) + Self.total(today.filter { $0.category != .salary }, .income)
    }
}

@MainActor
enum LedgerMoney {
    private static let whole = formatter(digits: 0)
    private static let cents = formatter(digits: 2)

    private static func formatter(digits: Int) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = digits
        return formatter
    }

    static func text(_ amount: Double, currency: String = "KRW", language: MapHomeLanguage) -> String {
        let formatter = currency == "KRW" || currency == "JPY" ? whole : cents
        let number = formatter.string(from: NSNumber(value: amount)) ?? "\(amount)"
        return currency == "KRW" ? language.text("\(number)원", "₩\(number)") : "\(currency) \(number)"
    }
}
