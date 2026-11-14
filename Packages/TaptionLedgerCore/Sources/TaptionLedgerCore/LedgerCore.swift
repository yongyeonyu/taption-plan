import Foundation

/// 가계부(LED1110A01, 추천안으로 만듦 2026-11-11 — 바꿀 수 있음).
/// 저장: 앱 SQLite(`TaptionStoreV2`)에 자기 종류(`ledger-entry`·`ledger-budget`)로 둔다. 말풍선·건강 기록과 같은 방식이라
/// 월별 백업(TAPTBK03)에 그대로 들어가고 옛 백업 형식은 바뀌지 않는다. 지운 것은 지움 표시로 남긴다.
public enum LedgerCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case food, cafe, transport, shopping, living, health, culture, travel, lodging, education, gift, salary, other

    public var id: String { rawValue }

    public var symbol: String {
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
}

public struct LedgerEntry: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case expense, income }
    public enum Source: String, Codable, Sendable { case manual, assistant, message, receipt }

    public var id = UUID()
    public var occurredAt: Date
    /// 그 통화의 금액(양수).
    public var amount: Double
    public var currency = "KRW"
    /// 넣을 때의 원화 환산(원화면 같은 값). 환율을 몰랐으면 nil.
    public var amountKRW: Double?
    public var kind: Kind = .expense
    public var category: LedgerCategory = .other
    public var title: String
    public var place: String?
    /// 단체 정산용. 비우면 나.
    public var payer: String?
    public var tripID: String?
    /// 메모에서 금액을 알아봐 만든 기록이면 그 메모 id(LED1111A03). 메모를 고치거나 지우면 따라간다.
    public var memoID: UUID?
    public var note: String?
    public var source: Source = .manual
    public var createdAt = Date()
    /// 여행 지출의 몫을 나누는 사람(LED1111A05). nil이면 「다 같이 n분의 1」(= 공금), `[LedgerTrip.me]`면 나만.
    public var shareNames: [String]?
    /// 일상↔여행 사이를 오가는 짝 기록(예산 이체·정산). 비용 계산에서 뺀다.
    public var transfer: LedgerTransfer?
    /// 취소된 결제면 그 시각(LCN1111A01, 대표 결정). 기록은 남기고 합계에서만 뺀다. 예전 기록에는 없다.
    public var canceledAt: Date?

    public init(id: UUID = UUID(), occurredAt: Date, amount: Double, currency: String = "KRW", amountKRW: Double? = nil, kind: Kind = .expense, category: LedgerCategory = .other, title: String, place: String? = nil, payer: String? = nil, tripID: String? = nil, memoID: UUID? = nil, note: String? = nil, source: Source = .manual, createdAt: Date = Date(), shareNames: [String]? = nil, transfer: LedgerTransfer? = nil, canceledAt: Date? = nil) {
        self.id = id
        self.occurredAt = occurredAt
        self.amount = amount
        self.currency = currency
        self.amountKRW = amountKRW
        self.kind = kind
        self.category = category
        self.title = title
        self.place = place
        self.payer = payer
        self.tripID = tripID
        self.memoID = memoID
        self.note = note
        self.source = source
        self.createdAt = createdAt
        self.shareNames = shareNames
        self.transfer = transfer
        self.canceledAt = canceledAt
    }

    /// 합계에 더하는 원화 금액. 취소된 결제는 0이다.
    public var countedKRW: Double { canceledAt == nil ? (amountKRW ?? 0) : 0 }
    public var signedKRW: Double { countedKRW * (kind == .expense ? -1 : 1) }
}

public struct LedgerBudget: Codable, Equatable, Identifiable, Sendable {
    /// `yyyy-MM` 또는 여행 id(`trip:<id>`).
    public var period: String
    public var category: LedgerCategory?
    public var amountKRW: Double

    public init(period: String, category: LedgerCategory? = nil, amountKRW: Double) {
        self.period = period
        self.category = category
        self.amountKRW = amountKRW
    }

    public var id: String { "\(period)|\(category?.rawValue ?? "all")" }
}

/// 읽기 안전망(LDS1111A01). 꼭 있어야 하는 칸(id·시각·금액)만 필수로 읽고 나머지는 없으면 기본값으로 둔다.
/// 모르는 분류는 기타, 모르는 출처는 직접 넣음으로 읽는다. 돈 방향(지출/수입)과 이체 종류는 모르면 읽지 않는다:
/// 잘못 세는 것보다 빼고 알리는 게 낫다(`LedgerBook.unreadable`). 새 칸을 더하면 여기에도 더한다(왕복 시험이 잡는다).
extension LedgerEntry {
    public init(from decoder: Decoder) throws {
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
public enum LedgerFX {
    public struct Table: Codable, Equatable, Sendable {
        public var base: String
        public var rates: [String: Double]
        public var day: String

        public init(base: String, rates: [String: Double], day: String) {
            self.base = base
            self.rates = rates
            self.day = day
        }
    }

    /// 1 `currency` = 몇 원.
    public static func krwPerUnit(_ currency: String, table: Table?, manual: [String: Double]) -> Double? {
        let code = currency.uppercased()
        if code == "KRW" { return 1 }
        if let value = manual[code], value > 0 { return value }
        guard let table, let krw = table.rates["KRW"], let unit = table.rates[code], unit > 0 else { return nil }
        return krw / unit
    }

    public static func parse(_ data: Data) -> Table? {
        try? JSONDecoder().decode(Table.self, from: data)
    }
}

/// 단체 정산: 누가 냈는지와 나눌 사람으로 최소 송금 목록을 만든다(`LedgerSplit`, 원 단위).
public enum LedgerSettlement {
    public struct Transfer: Equatable, Sendable {
        public var from: String
        public var to: String
        public var amountKRW: Double

        public init(from: String, to: String, amountKRW: Double) {
            self.from = from
            self.to = to
            self.amountKRW = amountKRW
        }
    }

    /// `entries`의 지출을 `people`이 똑같이 나눈다. 낸 사람이 비었으면 `me`가 낸 것이다.
    public static func transfers(_ entries: [LedgerEntry], people: [String], me: String) -> [Transfer] {
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
