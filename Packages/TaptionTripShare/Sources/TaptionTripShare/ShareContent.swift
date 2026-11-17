import Foundation

// 암호화 전 평문(4절: UTF-8 JSON 객체, `v` 칸). 서버는 이 모양을 모른다.
// 좌표는 어느 종류에도 넣지 않는다(장소는 이름만). 금액은 통화의 가장 작은 단위 정수(원이면 1원).

public enum ShareContentVersion {
    public static let current = 1
}

/// 돈을 내거나 나누는 사람: 방의 참여자(번호) 또는 앱 없는 일행(주인이 `meta`에 이름만 더한 사람).
/// JSON에서는 `"m3"`·`"g2"` 글자.
public enum ShareParty: Hashable, Sendable, Codable, Comparable {
    case member(Int)
    case guest(Int)

    public var code: String {
        switch self {
        case .member(let no): "m\(no)"
        case .guest(let id): "g\(id)"
        }
    }

    public init?(code: String) {
        guard let number = Int(code.dropFirst()), number > 0 else { return nil }
        switch code.first {
        case "m": self = .member(number)
        case "g": self = .guest(number)
        default: return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let party = ShareParty(code: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "party"))
        }
        self = party
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(code)
    }

    /// 참여자(번호 순) 다음에 앱 없는 일행(id 순). 정산의 고정 순서.
    public static func < (lhs: ShareParty, rhs: ShareParty) -> Bool {
        switch (lhs, rhs) {
        case (.member(let a), .member(let b)), (.guest(let a), .guest(let b)): a < b
        case (.member, .guest): true
        case (.guest, .member): false
        }
    }
}

/// 일정 하나(`plan`).
public struct SharePlanContent: Codable, Sendable, Equatable {
    public var v = ShareContentVersion.current
    /// 달력 날짜 `yyyy-MM-dd`(여행지 기준).
    public var day: String
    /// 자정부터의 분. 시간이 없는 일정은 nil.
    public var start: Int?
    /// 자정을 넘는 일정(수면·야간 이동)은 1,440을 넘는다.
    public var end: Int?
    /// 시작·끝 시각의 UTC와의 차(분). 시간대를 넘는 이동이면 둘이 다르다.
    public var startOffset: Int?
    public var endOffset: Int?
    public var title: String
    /// 장소 이름만.
    public var place: String?
    public var memo: String?
    /// 예상 지출.
    public var cost: Int?
    public var currency: String?
    /// 같은 날 안의 순서.
    public var order: Int?
    /// 일정의 종류·상태(뜻은 앱이 정하는 글자).
    public var planKind: String?
    public var status: String?
    public var colorHex: String?
    /// 코스 세부일 때 부모 일정의 항목 id.
    public var parentItemID: String?
    /// 쓴 사람의 참여자 번호(서버가 붙이는 `by`와 견줄 수 있게 암호문 안에도 둔다).
    public var by: Int?

    public init(day: String, start: Int? = nil, end: Int? = nil, startOffset: Int? = nil, endOffset: Int? = nil, title: String,
                place: String? = nil, memo: String? = nil, cost: Int? = nil, currency: String? = nil, order: Int? = nil,
                planKind: String? = nil, status: String? = nil, colorHex: String? = nil, parentItemID: String? = nil, by: Int? = nil) {
        self.day = day
        self.start = start
        self.end = end
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.planKind = planKind
        self.status = status
        self.colorHex = colorHex
        self.parentItemID = parentItemID
        self.title = title
        self.place = place
        self.memo = memo
        self.cost = cost
        self.currency = currency
        self.order = order
        self.by = by
    }
}

/// 공유 지출(`expense-shared`). 정산에 들어간다.
public struct ShareExpenseContent: Codable, Sendable, Equatable {
    public var v = ShareContentVersion.current
    public var title: String?
    public var amount: Int
    public var currency: String
    /// 넣을 때의 원화 환산 금액(원). 있으면 정산은 이 값으로 한다(기기마다 환율이 달라도 결과가 같게).
    public var amountKRW: Int?
    /// 낸 사람.
    public var payer: ShareParty
    /// 나눌 사람들. **만들 때의 사람들을 그대로 적는다**(나중에 들어온 사람에게 몫이 생기지 않게).
    /// 비어 있으면 정산에서는 낸 사람 혼자 진 것으로 본다.
    public var split: [ShareParty]
    public var category: String?
    public var memo: String?
    /// 쓴 시각(1970년부터의 밀리초).
    public var at: Int
    public var by: Int?

    public init(title: String? = nil, amount: Int, currency: String, amountKRW: Int? = nil, payer: ShareParty, split: [ShareParty],
                category: String? = nil, memo: String? = nil, at: Int, by: Int? = nil) {
        self.title = title
        self.amount = amount
        self.currency = currency
        self.amountKRW = amountKRW
        self.payer = payer
        self.split = split
        self.category = category
        self.memo = memo
        self.at = at
        self.by = by
    }
}

/// 개인 지출 가운데 **공개**한 것(`expense-own`). 쓴 사람만 고친다. 정산에 들어가지 않는다.
public struct ShareOwnExpenseContent: Codable, Sendable, Equatable {
    public var v = ShareContentVersion.current
    public var amount: Int
    public var currency: String
    public var category: String?
    public var memo: String?
    public var at: Int
    public var by: Int?

    public init(amount: Int, currency: String, category: String? = nil, memo: String? = nil, at: Int, by: Int? = nil) {
        self.amount = amount
        self.currency = currency
        self.category = category
        self.memo = memo
        self.at = at
        self.by = by
    }
}

/// 개인 지출의 공개 여부. 비공개는 방에 올리지 않는다.
public enum ShareOwnExpenseVisibility: String, Sendable, Codable {
    case open
    case hidden
}

/// 공지(`notice`).
public struct ShareNoticeContent: Codable, Sendable, Equatable {
    public var v = ShareContentVersion.current
    public var text: String
    public var important: Bool
    public var createdAt: Int
    /// 「3시까지」 같은 시각(1970년부터의 밀리초).
    public var due: Int?
    /// 장소 이름만.
    public var place: String?
    public var by: Int?

    public init(text: String, important: Bool = false, createdAt: Int, due: Int? = nil, place: String? = nil, by: Int? = nil) {
        self.text = text
        self.important = important
        self.createdAt = createdAt
        self.due = due
        self.place = place
        self.by = by
    }
}

/// 참여자 카드(`member`, id는 `member-<번호>`).
public struct ShareMemberCard: Codable, Sendable, Equatable {
    public var v = ShareContentVersion.current
    public var name: String
    /// 색의 이름이나 `#rrggbb`. 뜻은 앱이 정한다.
    public var color: String
    /// 내가 보냈다고 표시한 송금들(`ShareTransfer.key`). 본인 카드라 마감 뒤에도 고칠 수 있다.
    public var sent: [String]?

    public init(name: String, color: String, sent: [String]? = nil) {
        self.name = name
        self.color = color
        self.sent = sent
    }
}

/// 앱 없는 일행. 주인이 이름만 더한다.
public struct ShareGuest: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}

/// 여행 정보(`meta`, 주인만 씀).
public struct ShareTripMeta: Codable, Sendable, Equatable {
    public var v = ShareContentVersion.current
    public var name: String
    public var startDay: String
    public var endDay: String
    public var currency: String
    /// 공유 예산 하나.
    public var budget: Int?
    public var guests: [ShareGuest]
    /// 「정산 안 함」 여행.
    public var settlementOff: Bool?
    public var country: String?
    public var region: String?
    /// 시간대 식별자(IANA 이름).
    public var timeZone: String?
    /// 계획표의 열 구성. 뜻은 앱이 정하는 글자들.
    public var columns: [String]?
    /// 「내 지출 전부 공유」의 여행 기본값.
    public var shareAllExpenses: Bool?

    public init(name: String, startDay: String, endDay: String, currency: String, budget: Int? = nil, guests: [ShareGuest] = [], settlementOff: Bool? = nil,
                country: String? = nil, region: String? = nil, timeZone: String? = nil, columns: [String]? = nil, shareAllExpenses: Bool? = nil) {
        self.country = country
        self.region = region
        self.timeZone = timeZone
        self.columns = columns
        self.shareAllExpenses = shareAllExpenses
        self.name = name
        self.startDay = startDay
        self.endDay = endDay
        self.currency = currency
        self.budget = budget
        self.guests = guests
        self.settlementOff = settlementOff
    }
}

/// 모이는 곳(`meet`, id `meet-point`). 좌표가 든 항목이라 위치 기간 창 안에서만 올린다. 지우지 않고 `on: false`로 덮어쓴다.
public struct ShareMeetContent: Codable, Sendable, Equatable {
    public var v = ShareContentVersion.current
    public var on: Bool
    public var name: String
    public var lat: Double
    public var lon: Double
    /// 모이는 시각(밀리초). 정하지 않았으면 nil.
    public var at: Int?
    /// 정한 사람의 참여자 번호.
    public var by: Int?

    public init(on: Bool = true, name: String, latitude: Double, longitude: Double, at: Int? = nil, by: Int? = nil) {
        self.on = on
        self.name = String(name.prefix(60))
        lat = latitude
        lon = longitude
        self.at = at
        self.by = by
    }

    public var isValid: Bool { (-90...90).contains(lat) && (-180...180).contains(lon) }
    public static let itemID = "meet-point"

    /// 해제한 모양: 지우지 못하는 항목이라 덮어쓰되, 좌표·이름·시각은 남기지 않는다.
    public var cleared: ShareMeetContent { ShareMeetContent(on: false, name: "", latitude: 0, longitude: 0, by: by) }
}

/// 항목 하나의 평문.
public enum ShareContent: Sendable, Equatable {
    case plan(SharePlanContent)
    case sharedExpense(ShareExpenseContent)
    case ownExpense(ShareOwnExpenseContent)
    case notice(ShareNoticeContent)
    case member(ShareMemberCard)
    case meta(ShareTripMeta)
    case meet(ShareMeetContent)
    /// 더 새 판이 써서 이 판의 모양으로 읽지 못한 것. 보여 주지 못하지만 지우지 않는다.
    case unsupported(kind: String, version: Int)

    /// 개인 지출은 공개한 것만 내용이 된다. 비공개는 nil(올릴 것이 없다).
    public static func ownExpense(_ expense: ShareOwnExpenseContent, visibility: ShareOwnExpenseVisibility) -> ShareContent? {
        visibility == .open ? .ownExpense(expense) : nil
    }

    public var kind: String {
        switch self {
        case .plan: ShareKind.plan.rawValue
        case .sharedExpense: ShareKind.expenseShared.rawValue
        case .ownExpense: ShareKind.expenseOwn.rawValue
        case .notice: ShareKind.notice.rawValue
        case .member: ShareKind.member.rawValue
        case .meta: ShareKind.meta.rawValue
        case .meet: ShareKind.meet.rawValue
        case .unsupported(let kind, _): kind
        }
    }

    public var version: Int {
        switch self {
        case .plan(let value): value.v
        case .sharedExpense(let value): value.v
        case .ownExpense(let value): value.v
        case .notice(let value): value.v
        case .member(let value): value.v
        case .meta(let value): value.v
        case .meet(let value): value.v
        case .unsupported(_, let version): version
        }
    }

    /// 더 높은 판이 쓴 내용은 읽기만 한다(이 판이 다시 쓰면 모르는 칸을 잃는다).
    public var isReadOnly: Bool { version > ShareContentVersion.current }

    /// 패딩 전의 JSON. 칸은 이름 순으로 적는다(같은 내용이면 같은 글자).
    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            switch self {
            case .plan(let value): return try encoder.encode(value)
            case .sharedExpense(let value): return try encoder.encode(value)
            case .ownExpense(let value): return try encoder.encode(value)
            case .notice(let value): return try encoder.encode(value)
            case .member(let value): return try encoder.encode(value)
            case .meta(let value): return try encoder.encode(value)
            case .meet(let value): return try encoder.encode(value)
            case .unsupported: throw ShareError.readOnly(.newerVersion)
            }
        } catch let error as ShareError {
            throw error
        } catch {
            throw ShareError.invalidResponse
        }
    }

    private struct Head: Decodable { var v: Int }

    /// 풀린 평문을 종류에 맞게 읽는다. `v`가 없거나 이 판의 모양이 아니면 던진다(그 항목은 버린다).
    public static func decode(kind: String, json: Data) throws -> ShareContent {
        let decoder = JSONDecoder()
        guard let head = try? decoder.decode(Head.self, from: json), head.v >= 1 else { throw ShareError.invalidResponse }
        guard let known = ShareKind(rawValue: kind) else { return .unsupported(kind: kind, version: head.v) }
        do {
            switch known {
            case .plan: return .plan(try decoder.decode(SharePlanContent.self, from: json))
            case .expenseShared: return .sharedExpense(try decoder.decode(ShareExpenseContent.self, from: json))
            case .expenseOwn: return .ownExpense(try decoder.decode(ShareOwnExpenseContent.self, from: json))
            case .notice: return .notice(try decoder.decode(ShareNoticeContent.self, from: json))
            case .member: return .member(try decoder.decode(ShareMemberCard.self, from: json))
            case .meta: return .meta(try decoder.decode(ShareTripMeta.self, from: json))
            case .meet: return .meet(try decoder.decode(ShareMeetContent.self, from: json))
            }
        } catch {
            if head.v > ShareContentVersion.current { return .unsupported(kind: kind, version: head.v) }
            throw ShareError.invalidResponse
        }
    }
}
