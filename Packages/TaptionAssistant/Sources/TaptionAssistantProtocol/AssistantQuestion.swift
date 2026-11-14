import Foundation

extension JSONDecoder.DateDecodingStrategy {
    /// 서버는 `toISOString()`(밀리초 포함)으로 시각을 쓴다.
    public static let iso8601withFractionalOrPlain = custom { decoder in
        let text = try decoder.singleValueContainer().decode(String.self)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) { return date }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(text)"))
    }
}

/// AI가 앱에서 묻는 객관식 질문 하나(ASK1112A01). `id`는 그 `askUser` 명령의 id이고, AI는 이것으로 답을 찾는다.
public struct AssistantQuestion: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable { case waiting, answered, skipped }

    public static let questionLimit = 200
    public static let optionLimit = 60
    public static let textLimit = 200
    public static let optionRange = 2...4

    public var id: String
    public var question: String
    public var options: [String]
    public var multiSelect: Bool
    public var askedAt: Date
    public var status: Status = .waiting
    /// 고른 보기. 보기에 없는 글은 받지 않는다.
    public var choices: [String] = []
    /// 직접 입력한 답.
    public var text: String?
    public var answeredAt: Date?
    /// 승인 요청이면 무엇을 승인하는지(ACD1112A01). 보통 질문은 nil. 카드 문구는 앱이 쓴다.
    public var approval: AssistantApproval?

    public init(
        id: String, question: String, options: [String], multiSelect: Bool, askedAt: Date, status: Status = .waiting,
        choices: [String] = [], text: String? = nil, answeredAt: Date? = nil, approval: AssistantApproval? = nil
    ) {
        self.id = id
        self.question = question
        self.options = options
        self.multiSelect = multiSelect
        self.askedAt = askedAt
        self.status = status
        self.choices = choices
        self.text = text
        self.answeredAt = answeredAt
        self.approval = approval
    }

    /// 서버와 같은 규칙으로 다시 본다: 질문 1~200자, 서로 다른 보기 2~4개(1~60자).
    public static func make(id: String?, question: String?, options: [String]?, multiSelect: Bool?, now: Date) -> Self? {
        guard let id, !id.isEmpty, let question = trimmed(question, max: questionLimit), let options,
              optionRange.contains(options.count) else { return nil }
        let cleaned = options.compactMap { trimmed($0, max: optionLimit) }
        guard cleaned.count == options.count, Set(cleaned).count == cleaned.count else { return nil }
        return Self(id: id, question: question, options: cleaned, multiSelect: multiSelect ?? false, askedAt: now)
    }

    public static func trimmed(_ text: String?, max: Int) -> String? {
        guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty, value.count <= max else { return nil }
        return value
    }
}

/// AI가 혼자 할 수 없는 일의 승인 요청(ACD1112A01). 앱에서 사용자가 「승인」을 눌러야 실행된다.
/// 값을 바꾸는 것은 승인하면 바로 적용하고, 비밀번호·확인이 필요한 것은 그 화면을 열어 사용자가 직접 한다.
public struct AssistantApproval: Codable, Equatable, Sendable {
    public enum Request: String, Codable, CaseIterable, Sendable {
        case shareLevel, retentionDays, healthOff, eraseAllData, backup, restore, changePin
    }

    public static let approved = "approved"
    public static let declined = "declined"

    public var request: Request
    /// `shareLevel`은 off|summary|visits, `retentionDays`는 1|7|30. 나머지는 nil.
    public var value: String?

    public init(request: Request, value: String? = nil) {
        self.request = request
        self.value = value
    }

    /// 승인 카드로 쓸 질문. `question`은 AI가 `get_answers`에서 다시 읽는 영어 글이고, 화면 문구는 `title`이 만든다.
    public func question(id: String, now: Date) -> AssistantQuestion {
        AssistantQuestion(
            id: id, question: "Approval request: \(request.rawValue)" + (value.map { " = \($0)" } ?? ""),
            options: [Self.approved, Self.declined], multiSelect: false, askedAt: now, approval: self
        )
    }
}
