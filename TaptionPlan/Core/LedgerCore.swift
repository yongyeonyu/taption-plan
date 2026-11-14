import Foundation
import Observation
import os
@_exported import TaptionLedgerCore
import TaptionPlanStore

/// 분류의 화면 이름과 글에서 짐작하기. 값 타입은 `TaptionLedgerCore`에 있다.
extension LedgerCategory {
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

    /// 글에서 분류를 짐작한다(결제 문자·영수증·AI). 모르면 기타.
    static func guess(_ text: String) -> LedgerCategory {
        // 서버 규칙이 먼저다(AIX1114A01 P3): 사용자가 정한 것, 그다음 AI가 배운 것, 그다음 아래 표.
        if let learned = RuleEngine.merchantCategory(merchant: text, text: text, rules: AssistantRuleSnapshot.rules),
           let category = LedgerCategory(rawValue: learned.category) { return category }
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
            // 「○○통증의학과」처럼 병원·의원이 안 붙은 진료과 이름도 의료·건강이다(HLT1114A01, 대표 신고).
            (.health, ["병원", "약국", "의원", "치과", "의학과", "외과", "내과", "피부과", "이비인후과", "소아과", "산부인과", "비뇨기과", "한의", "클리닉", "메디컬", "검진", "pharmacy", "hospital", "clinic"]),
            (.lodging, ["호텔", "모텔", "에어비앤비", "숙소", "hotel", "airbnb"]),
            (.travel, ["항공", "공항", "면세", "airline"]),
        ]
        return table.first { _, words in words.contains { lower.contains($0) } }?.0 ?? .other
    }
}

extension LedgerFX {
    @MainActor
    static func fetch(env: AssistantRegistration.Environment = .live) async -> Table? {
        guard let token = await AssistantRegistration.searchToken(),
              let reply = await TripRelay.send(TripRelay.relayRequest("/fx", method: "GET", token: token, host: env.host), session: env.session),
              reply.status == 200 else { return nil }
        return parse(reply.data)
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
