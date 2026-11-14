import Foundation

/// 규칙 한 칸의 값. 서버 JSON의 글·참거짓·수·글 목록을 그대로 담는다.
public enum RuleValue: Codable, Equatable, Sendable {
    case text(String)
    case flag(Bool)
    case number(Double)
    case list([String])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .flag(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .text(value) }
        else { self = .list(try container.decode([String].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let value): try container.encode(value)
        case .flag(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .list(let value): try container.encode(value)
        }
    }

    public var text: String? { if case .text(let value) = self { value } else { nil } }
    public var flag: Bool? { if case .flag(let value) = self { value } else { nil } }
    public var list: [String]? { if case .list(let value) = self { value } else { nil } }
}

/// AI나 사용자가 정해 서버에 둔 규칙 하나(AIX1114A01 P3). 앱은 이것으로 먼저 판단하고, 못 하면 AI에게 맡긴다.
public struct Rule: Codable, Equatable, Identifiable, Sendable {
    public struct Source: Codable, Equatable, Sendable {
        /// "ai" 또는 "user".
        public var by: String
        public var keyId: String?
        public var taskId: String?

        public init(by: String, keyId: String? = nil, taskId: String? = nil) {
            self.by = by
            self.keyId = keyId
            self.taskId = taskId
        }
    }

    public var id: String
    public var type: String
    /// 이 규칙을 읽으려면 필요한 평가기 버전. 앱의 `RuleEngine.version`보다 크면 건너뛴다.
    public var appliesTo: Int
    public var enabled: Bool
    public var match: [String: RuleValue]
    public var result: [String: RuleValue]
    public var source: Source?
    public var note: String?
    public var createdAt: String?
    public var updatedAt: String?

    public init(id: String, type: String, appliesTo: Int = 1, enabled: Bool = true, match: [String: RuleValue], result: [String: RuleValue] = [:],
                source: Source? = nil, note: String? = nil, createdAt: String? = nil, updatedAt: String? = nil) {
        self.id = id
        self.type = type
        self.appliesTo = appliesTo
        self.enabled = enabled
        self.match = match
        self.result = result
        self.source = source
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey { case id, type, appliesTo, enabled, match, result, source, note, createdAt, updatedAt }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? ""
        type = try values.decode(String.self, forKey: .type)
        appliesTo = try values.decodeIfPresent(Int.self, forKey: .appliesTo) ?? 1
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        // 모르는 모양의 칸이 있어도 목록 전체가 깨지지 않게, 못 읽는 본문은 비워 둔다(평가에서 건너뛴다).
        match = (try? values.decode([String: RuleValue].self, forKey: .match)) ?? [:]
        result = (try? values.decodeIfPresent([String: RuleValue].self, forKey: .result)) ?? [:]
        source = try? values.decodeIfPresent(Source.self, forKey: .source)
        note = try? values.decodeIfPresent(String.self, forKey: .note)
        createdAt = try? values.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try? values.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    public var isUserMade: Bool { source?.by == "user" }
}

/// 서버와 앱이 같은 버전으로 들고 있는 규칙 묶음.
public struct RuleSet: Codable, Equatable, Sendable {
    public var version: Int
    public var rules: [Rule]

    public init(version: Int = 0, rules: [Rule] = []) {
        self.version = version
        self.rules = rules
    }
}

public enum RuleType: String, CaseIterable, Sendable {
    case paymentText = "payment_text"
    case skipWord = "skip_word"
    case textIgnore = "text_ignore"
    case internalTransfer = "internal_transfer"
    case ownAccount = "own_account"
    case sourceSwitch = "source_switch"
    case merchantCategory = "merchant_category"
    case receiptHint = "receipt_hint"
    case calendarTitle = "calendar_title"
    case placePairMode = "place_pair_mode"
    case rideLine = "ride_line"
}
