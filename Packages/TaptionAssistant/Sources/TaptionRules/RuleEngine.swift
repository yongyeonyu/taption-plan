import Foundation

/// 규칙 평가기. 앱이 AI에게 묻기 전에 먼저 규칙으로 판단한다(AIX1114A01 P3).
/// 모두 순수 함수다: 규칙 목록과 글을 받아, 맞은 규칙과 결과를 돌려준다.
public enum RuleEngine {
    /// 이 앱이 읽을 수 있는 규칙 버전. `Rule.appliesTo`가 이보다 크면 건너뛴다.
    public static let version = 1

    /// 켜져 있고 이 앱이 읽을 수 있는 규칙만, 쓸 순서로. 사용자가 만든 것이 먼저, 그다음 AI 것을 새것부터.
    /// `skipped`는 켜져 있지만 이 앱이 못 읽는 규칙의 id(서버에 알려 준다). 지우지 않는다.
    public static func usable(_ set: RuleSet) -> (rules: [Rule], skipped: [String]) {
        var rules: [Rule] = [], skipped: [String] = []
        for rule in set.rules where rule.enabled {
            if rule.appliesTo <= version, RuleShape.isValid(rule) { rules.append(rule) } else { skipped.append(rule.id) }
        }
        let ordered = rules.enumerated().sorted { a, b in
            if a.element.isUserMade != b.element.isUserMade { return a.element.isUserMade }
            let left = a.element.updatedAt ?? "", right = b.element.updatedAt ?? ""
            return left == right ? a.offset > b.offset : left > right
        }
        return (ordered.map(\.element), skipped)
    }

    private static func of(_ type: RuleType, _ rules: [Rule]) -> [Rule] { rules.filter { $0.type == type.rawValue } }
    private static func has(_ text: String, _ word: String) -> Bool { text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    private static func hasAny(_ text: String, _ words: [String]) -> Bool { words.contains { has(text, $0) } }
    private static func hasAll(_ text: String, _ words: [String]) -> Bool { !words.isEmpty && words.allSatisfy { has(text, $0) } }
    private static func same(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines).compare(b.trimmingCharacters(in: .whitespacesAndNewlines), options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    // MARK: 결제 글

    /// 넣지 않을 낱말이 든 글이면 그 규칙.
    public static func skipWord(in text: String, rules: [Rule]) -> Rule? {
        of(.skipWord, rules).first { $0.match["word"]?.text.map { has(text, $0) } ?? false }
    }

    /// 결제가 아닌 글(안내·광고)이면 그 규칙. `contains`의 낱말이 모두 들어 있어야 하고, `source`가 있으면 보낸 앱도 같아야 한다.
    public static func textIgnore(_ text: String, source: String? = nil, rules: [Rule]) -> Rule? {
        of(.textIgnore, rules).first { rule in
            guard hasAll(text, rule.match["contains"]?.list ?? []) else { return false }
            guard let wanted = rule.match["source"]?.text else { return true }
            return source.map { same($0, wanted) } ?? false
        }
    }

    /// 내 계좌 사이 이체·충전 글이면 그 규칙.
    public static func internalTransfer(_ text: String, rules: [Rule]) -> Rule? {
        of(.internalTransfer, rules).first { hasAll(text, $0.match["contains"]?.list ?? []) }
    }

    public static func ownAccountNames(rules: [Rule]) -> [String] {
        of(.ownAccount, rules).compactMap { $0.match["name"]?.text }
    }

    /// 알림을 보낸 앱의 지출·수입 받기 여부.
    public static func sourceSwitch(app: String, rules: [Rule]) -> (expense: Bool, income: Bool, rule: Rule)? {
        for rule in of(.sourceSwitch, rules) {
            guard let name = rule.match["app"]?.text, same(name, app), let expense = rule.result["expense"]?.flag, let income = rule.result["income"]?.flag else { continue }
            return (expense, income, rule)
        }
        return nil
    }

    /// 결제 글 읽기 규칙(정규식). 평가는 앱의 기존 정규식 읽기가 한다.
    public static func paymentTextRules(rules: [Rule]) -> [(rule: Rule, pattern: String, sample: String, kind: String, name: String?)] {
        of(.paymentText, rules).compactMap { rule in
            guard let pattern = rule.match["pattern"]?.text, let sample = rule.match["sample"]?.text, let kind = rule.result["kind"]?.text else { return nil }
            return (rule, pattern, sample, kind, rule.result["name"]?.text)
        }
    }

    // MARK: 가계부 분류

    /// 가게 이름(또는 글 전체)으로 정한 분류. `equals`는 이름이 같을 때, `contains`는 낱말 가운데 하나라도 들어 있을 때.
    public static func merchantCategory(merchant: String, text: String? = nil, rules: [Rule]) -> (category: String, title: String?, rule: Rule)? {
        for rule in of(.merchantCategory, rules) {
            guard let category = rule.result["category"]?.text else { continue }
            let subject = rule.match["field"]?.text == "text" ? (text ?? merchant) : merchant
            let hit: Bool
            if let exact = rule.match["equals"]?.text { hit = same(subject, exact) } else { hit = hasAny(subject, rule.match["contains"]?.list ?? []) }
            if hit { return (category, rule.result["title"]?.text, rule) }
        }
        return nil
    }

    // MARK: 영수증

    /// 사진에서 읽은 글이 영수증인지에 대한 힌트. 낱말이 모두 들어 있으면 그 규칙의 답.
    public static func receiptHint(_ text: String, rules: [Rule]) -> (isReceipt: Bool, category: String?, rule: Rule)? {
        for rule in of(.receiptHint, rules) {
            guard hasAll(text, rule.match["contains"]?.list ?? []), let isReceipt = rule.result["isReceipt"]?.flag else { continue }
            return (isReceipt, rule.result["category"]?.text, rule)
        }
        return nil
    }

    // MARK: 활동·이동

    /// 일정 제목의 상세 분류. `detailID`가 nil이면 「분류하지 않음」으로 정한 것이다.
    public static func calendarTitle(_ title: String, rules: [Rule]) -> (detailID: String?, rule: Rule)? {
        for rule in of(.calendarTitle, rules) {
            guard let wanted = rule.match["title"]?.text, same(wanted, title) else { continue }
            let detail = rule.result["detailId"]?.text
            return (detail == "none" ? nil : detail, rule)
        }
        return nil
    }

    /// 장소 쌍(어디서 → 어디로)의 이동 수단.
    public static func placePairMode(from: String, to: String, rules: [Rule]) -> (mode: String, line: String?, rule: Rule)? {
        for rule in of(.placePairMode, rules) {
            guard let a = rule.match["from"]?.text, let b = rule.match["to"]?.text, same(a, from), same(b, to), let mode = rule.result["mode"]?.text else { continue }
            return (mode, rule.result["line"]?.text, rule)
        }
        return nil
    }

    /// 승하차 정류소(역) 쌍의 버스 번호·지하철 노선.
    public static func rideLine(board: String, alight: String, mode: String, rules: [Rule]) -> (line: String, rule: Rule)? {
        for rule in of(.rideLine, rules) {
            guard rule.match["mode"]?.text == mode, let a = rule.match["board"]?.text, let b = rule.match["alight"]?.text, same(a, board), same(b, alight),
                  let line = rule.result["line"]?.text else { continue }
            return (line, rule)
        }
        return nil
    }
}
