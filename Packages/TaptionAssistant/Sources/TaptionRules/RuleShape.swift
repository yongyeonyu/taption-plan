import Foundation

/// 규칙의 모양 검사. 서버 `server/trip-relay/src/rules.js`의 `RULE_TYPES`와 같은 표다.
/// 둘은 `server/trip-relay/test/fixtures/rules.json` 하나로 맞춘다.
public enum RuleShape {
    public static let categories = ["food", "cafe", "transport", "shopping", "living", "health", "culture", "travel", "lodging", "education", "gift", "salary", "other"]
    public static let modes = ["walk", "subway", "bus", "car", "train", "flight", "cycling"]

    enum Kind {
        case word(min: Int, max: Int)
        case label(max: Int)
        case words
        case oneOf([String])
        case flag
        case pattern
        case sample
        case detail
    }

    struct Field {
        let name: String
        let kind: Kind
        let required: Bool
    }

    struct Spec {
        let match: [Field]
        let result: [Field]
        /// 이 가운데 하나는 match에 있어야 한다.
        var any: [String] = []
    }

    private static func need(_ name: String, _ kind: Kind) -> Field { Field(name: name, kind: kind, required: true) }
    private static func maybe(_ name: String, _ kind: Kind) -> Field { Field(name: name, kind: kind, required: false) }

    static let specs: [RuleType: Spec] = [
        .paymentText: Spec(match: [need("pattern", .pattern), need("sample", .sample)],
                           result: [need("kind", .oneOf(["expense", "income", "ignore"])), maybe("name", .word(min: 1, max: 40))]),
        .skipWord: Spec(match: [need("word", .word(min: 1, max: 20))], result: []),
        .textIgnore: Spec(match: [need("contains", .words), maybe("source", .word(min: 1, max: 40))], result: [maybe("reason", .word(min: 1, max: 60))]),
        .internalTransfer: Spec(match: [need("contains", .words)], result: []),
        .ownAccount: Spec(match: [need("name", .word(min: 1, max: 30))], result: []),
        .sourceSwitch: Spec(match: [need("app", .word(min: 1, max: 40))], result: [need("expense", .flag), need("income", .flag)]),
        .merchantCategory: Spec(match: [maybe("contains", .words), maybe("equals", .word(min: 1, max: 60)), maybe("field", .oneOf(["merchant", "text"]))],
                                result: [need("category", .oneOf(categories)), maybe("title", .word(min: 1, max: 60))], any: ["contains", "equals"]),
        .receiptHint: Spec(match: [need("contains", .words)], result: [need("isReceipt", .flag), maybe("category", .oneOf(categories))]),
        .calendarTitle: Spec(match: [need("title", .word(min: 1, max: 80))], result: [maybe("detailId", .detail)]),
        .placePairMode: Spec(match: [need("from", .word(min: 1, max: 60)), need("to", .word(min: 1, max: 60))],
                             result: [need("mode", .oneOf(modes)), maybe("line", .label(max: 20))]),
        .rideLine: Spec(match: [need("board", .word(min: 1, max: 60)), need("alight", .word(min: 1, max: 60)), need("mode", .oneOf(["bus", "subway"]))],
                        result: [need("line", .label(max: 20))]),
    ]

    private static func matches(_ text: String, _ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }

    /// 낱말: 숫자·공백만은 안 되고, 숫자 9자리가 이어지면(계좌·카드·전화) 안 된다.
    static func isWord(_ text: String, min: Int, max: Int) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= min && text.count <= max && !matches(text, #"^[\d\s]+$"#) && !matches(text, #"\d{9,}"#)
    }

    static func isLabel(_ text: String, max: Int) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= max && !matches(text, #"\d{9,}"#)
    }

    /// 정규식: 300자, 묶음 12개까지. 되돌아보기·역참조·겹친 반복은 받지 않는다.
    public static func isSafePattern(_ pattern: String) -> Bool {
        guard !pattern.isEmpty, pattern.count <= 300 else { return false }
        let groups = (try? NSRegularExpression(pattern: #"\((?!\?[:=!])"#))?.numberOfMatches(in: pattern, range: NSRange(pattern.startIndex..., in: pattern)) ?? 0
        guard groups <= 12 else { return false }
        if matches(pattern, #"\(\?<[=!]"#) || matches(pattern, #"\\[1-9]"#) || matches(pattern, #"\\k<"#) { return false }
        return !matches(pattern, #"\([^()]*[+*][^()]*\)\s*[+*{]"#)
    }

    private static func fits(_ value: RuleValue, _ kind: Kind) -> Bool {
        switch (kind, value) {
        case let (.word(min, max), .text(text)): isWord(text, min: min, max: max)
        case let (.label(max), .text(text)): isLabel(text, max: max)
        case let (.words, .list(items)): (1...10).contains(items.count) && Set(items).count == items.count && items.allSatisfy { isWord($0, min: 2, max: 40) }
        case let (.oneOf(values), .text(text)): values.contains(text)
        case (.flag, .flag): true
        case let (.pattern, .text(text)): isSafePattern(text)
        case let (.sample, .text(text)): (1...1000).contains(text.count)
        case let (.detail, .text(text)): text == "none" || matches(text, #"^[\w.-]{1,60}$"#)
        default: false
        }
    }

    private static func part(_ fields: [Field], _ values: [String: RuleValue]) -> Bool {
        fields.allSatisfy { field in
            guard let value = values[field.name] else { return !field.required }
            return fits(value, field.kind)
        }
    }

    /// 종류를 알고, 꼭 있어야 하는 칸이 있고, 값이 모두 맞는가. 모르는 칸은 보지 않는다(서버가 버린다).
    public static func isValid(_ rule: Rule) -> Bool {
        guard let type = RuleType(rawValue: rule.type), let spec = specs[type], (1...99).contains(rule.appliesTo),
              part(spec.match, rule.match), part(spec.result, rule.result) else { return false }
        if !spec.any.isEmpty, !spec.any.contains(where: { rule.match[$0] != nil }) { return false }
        if let note = rule.note, note.count > 120 || matches(note, #"\d{9,}"#) { return false }
        return true
    }
}
