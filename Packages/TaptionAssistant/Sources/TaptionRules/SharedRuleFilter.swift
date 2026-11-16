import Foundation

/// 공통 규칙 후보로 올리기 전에 기기에서 개인 정보를 거르는 규칙(SRL1116A01). 서버 `src/shared.js`의 `cleanCandidate`와 같은 표다.
/// 둘은 `server/trip-relay/test/fixtures/shared-rules.json` 하나로 맞춘다.
public enum SharedRuleFilter {
    /// 기기에서 올릴 수 있는 종류. 내 계좌·일정 제목·장소 쌍·넣지 않을 낱말·앱별 스위치는 사람마다 달라 올리지 않는다.
    public static let candidateTypes: [RuleType] = [.paymentText, .textIgnore, .receiptHint, .merchantCategory]
    /// 앱이 공통 규칙으로 받아 쓰는 종류.
    public static let sharedTypes: Set<RuleType> = [.paymentText, .textIgnore, .receiptHint, .merchantCategory, .sourceSwitch]

    private static let honorificOK = ["고객", "회원", "본인", "가입자", "이용자"]

    private static func replace(_ text: String, _ pattern: String, _ template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// 정규식에서 글자 그대로 맞추는 부분만 남긴다. 가린 글자(`\*`)는 ＊로 남겨 알아볼 수 있게 한다.
    public static func patternLiterals(_ pattern: String) -> String {
        var text = replace(pattern, #"\\\*"#, "＊")
        text = replace(text, #"\(\?<[A-Za-z]\w*>"#, " ")
        text = replace(text, #"\\[dDsSwWbBnrt]"#, " ")
        text = replace(text, #"\[(?:\\.|[^\]\\])*\]"#, " ")
        text = replace(text, #"\{\d+(?:,\d*)?\}"#, " ")
        text = replace(text, #"\\(.)"#, "$1")
        return replace(text, #"[()|?*+^$.]"#, " ")
    }

    private static func has(_ text: String, _ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }

    /// 개인을 알아볼 만한 글인가: 숫자 4자리 이상(카드 끝자리·계좌·금액), 가린 글자, 메일 주소, 「이름+님」.
    public static func isPersonal(_ text: String) -> Bool {
        if has(text, #"\d{4,}"#) || has(text, "[＊*]") || text.contains("@") { return true }
        guard let regex = try? NSRegularExpression(pattern: #"([가-힣]{2,4})\s*님"#) else { return true }
        let whole = NSRange(text.startIndex..., in: text)
        for found in regex.matches(in: text, range: whole) {
            guard let range = Range(found.range(at: 1), in: text) else { continue }
            let name = String(text[range])
            if !honorificOK.contains(where: { name.hasSuffix($0) }) { return true }
        }
        return false
    }

    /// 기기의 규칙에서 올릴 후보를 만든다. 알려진 칸만 남기고 견본 글·이름·제목·메모는 뺀다. 올릴 수 없거나 개인 정보로 보이면 nil.
    public static func candidate(from rule: Rule) -> Rule? {
        guard let type = RuleType(rawValue: rule.type), candidateTypes.contains(type), RuleShape.isValid(rule) else { return nil }
        var match: [String: RuleValue] = [:], result: [String: RuleValue] = [:]
        if type == .paymentText {
            guard let pattern = rule.match["pattern"]?.text, let kind = rule.result["kind"]?.text, !isPersonal(patternLiterals(pattern)) else { return nil }
            match["pattern"] = .text(pattern)
            result["kind"] = .text(kind)
        } else {
            for key in ["contains", "equals", "field", "source"] { if let value = rule.match[key] { match[key] = value } }
            for key in ["category", "isReceipt"] { if let value = rule.result[key] { result[key] = value } }
            if case .list(let words)? = match["contains"] { match["contains"] = .list(words.sorted()) }
            var texts = rule.match["contains"]?.list ?? []
            texts += ["equals", "source"].compactMap { rule.match[$0]?.text }
            if texts.contains(where: isPersonal) { return nil }
        }
        return Rule(id: "", type: rule.type, match: match, result: result)
    }

    /// 서버에 보내는 후보 한 개(`type`·`match`·`result`).
    public struct Upload: Encodable, Equatable {
        public let type: String
        public let match: [String: RuleValue]
        public let result: [String: RuleValue]
    }

    public static func upload(_ candidate: Rule) -> Upload { Upload(type: candidate.type, match: candidate.match, result: candidate.result) }
}
