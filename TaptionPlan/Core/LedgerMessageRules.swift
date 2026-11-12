import Foundation

/// AI가 보태는 결제 문자 읽기 규칙(PRL1112A01). 앱이 못 읽는 형식을 AI가 정규식으로 알려 주면 저장해 두고,
/// 그 뒤 같은 형식의 문자는 앱이 스스로 읽는다. 규칙은 기기에만 있고, 견본 문자와 맞아야 저장한다.
enum LedgerMessageRules {
    enum Kind: String, Codable, Sendable { case expense, income, ignore }

    struct Rule: Codable, Equatable, Identifiable, Sendable {
        var id = UUID()
        var name: String
        /// ICU 정규식. 이름 붙은 묶음: amount(필수, ignore는 없어도 됨)·merchant·month·day·hour·minute·currency.
        var pattern: String
        var sample: String
        var kind: Kind
        var createdAt = Date()
    }

    enum Failure: Error, Equatable { case badPattern, noMatch, noAmount, tooLong }

    static let key = "ledgerMessageRules"
    static let limit = 20
    static let groups = ["amount", "merchant", "month", "day", "hour", "minute", "currency"]

    static func rules(_ defaults: UserDefaults = .standard) -> [Rule] {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Rule].self, from: $0) } ?? []
    }

    /// 견본과 맞고 금액을 읽어 내는 규칙만 받는다. 너무 넓은 규칙(견본 없이 아무 글이나)은 견본 검사로 걸러지지 않으므로 길이만 막는다.
    static func validated(name: String, pattern: String, sample: String, kind: Kind) -> Result<Rule, Failure> {
        guard (1...300).contains(pattern.count), (1...1_000).contains(sample.count), name.count <= 40 else { return .failure(.tooLong) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return .failure(.badPattern) }
        guard let found = fields(regex, in: sample) else { return .failure(.noMatch) }
        if kind != .ignore, found["amount"].flatMap(amount) == nil { return .failure(.noAmount) }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(Rule(name: title.isEmpty ? "AI" : title, pattern: pattern, sample: sample, kind: kind))
    }

    /// 같은 정규식이 있으면 바꾸고, 넘치면 오래된 것부터 버린다.
    static func add(_ rule: Rule, defaults: UserDefaults = .standard) {
        var list = rules(defaults).filter { $0.pattern != rule.pattern && $0.id != rule.id }
        list.append(rule)
        if list.count > limit { list.removeFirst(list.count - limit) }
        save(list, defaults)
    }

    static func remove(_ id: UUID, defaults: UserDefaults = .standard) {
        save(rules(defaults).filter { $0.id != id }, defaults)
    }

    enum Match: Equatable { case draft(LedgerMessageParser.Draft, income: Bool), ignore }

    /// 새 규칙이 먼저다(나중에 넣은 것이 앞선 실수를 고친다).
    static func match(_ text: String, now: Date = .now, calendar: Calendar = .autoupdatingCurrent,
                      defaults: UserDefaults = .standard) -> Match? {
        guard text.count <= 1_000 else { return nil }
        for rule in rules(defaults).reversed() {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: [.dotMatchesLineSeparators]),
                  let found = fields(regex, in: text) else { continue }
            if rule.kind == .ignore { return .ignore }
            guard let value = found["amount"].flatMap(amount) else { continue }
            let merchant = found["merchant"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let draft = LedgerMessageParser.Draft(
                amount: value, currency: found["currency"].map { $0.uppercased() }.flatMap { $0.count == 3 ? $0 : nil } ?? "KRW",
                merchant: merchant.flatMap { $0.isEmpty ? nil : String($0.prefix(40)) }, card: rule.name,
                occurredAt: date(found, now: now, calendar: calendar), isCancel: false
            )
            return .draft(draft, income: rule.kind == .income)
        }
        return nil
    }

    private static func fields(_ regex: NSRegularExpression, in text: String) -> [String: String]? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        var result: [String: String] = [:]
        for name in groups {
            let range = match.range(withName: name)
            if range.location != NSNotFound, let swift = Range(range, in: text) { result[name] = String(text[swift]) }
        }
        return result
    }

    private static func amount(_ text: String) -> Double? {
        LedgerMessageParser.number(text.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
    }

    /// 월·일·시·분이 다 있을 때만 시각으로 본다. 미래가 되면 작년이다.
    private static func date(_ found: [String: String], now: Date, calendar: Calendar) -> Date? {
        guard let month = found["month"].flatMap(Int.init), let day = found["day"].flatMap(Int.init),
              let hour = found["hour"].flatMap(Int.init), let minute = found["minute"].flatMap(Int.init),
              (1...12).contains(month), (1...31).contains(day), (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        var parts = DateComponents(year: calendar.component(.year, from: now), month: month, day: day, hour: hour, minute: minute)
        guard var value = calendar.date(from: parts) else { return nil }
        if value > now.addingTimeInterval(86_400) {
            parts.year = (parts.year ?? 0) - 1
            value = calendar.date(from: parts) ?? value
        }
        return value
    }

    private static func save(_ list: [Rule], _ defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: key) }
    }
}

extension LedgerMessageRules {
    /// `addPaymentRule` 명령을 규칙으로. kind가 없으면 지출이고, 칸이 없거나 검사에 걸리면 틀린 명령이다.
    static func rule(name: String?, pattern: String?, sample: String?, kind: String?) -> Rule? {
        guard let pattern, let sample, let kind = Kind(rawValue: kind ?? Kind.expense.rawValue) else { return nil }
        return try? validated(name: name ?? "", pattern: pattern, sample: sample, kind: kind).get()
    }

    /// 「AI가 한 일」에 적는 글.
    static func summary(_ rule: Rule, added: Int, language: MapHomeLanguage) -> String {
        added > 0 ? language.text("\(rule.name) · 받은 문자 \(added)건 넣음", "\(rule.name) · added \(added) received text(s)") : rule.name
    }
}

/// 자동화가 넘긴 글과 그 결과(PRL1112A01). 「AI」 탭에서 보고, 못 읽은 것은 AI에게 규칙을 부탁한다.
/// 기기에만 두고 번호는 가린다. 최근 30건, 7일까지.
enum PaymentInbox {
    enum Outcome: String, Codable, Sendable { case added, review, duplicate, skipped, unread, askedAI }

    struct Item: Codable, Equatable, Identifiable, Sendable {
        var id = UUID()
        var text: String
        var receivedAt: Date
        var outcome: Outcome
        var message: String
        var ruleRequested = false
    }

    static let key = "paymentInbox"
    static let limit = 30
    static let lifetime: TimeInterval = 7 * 86_400

    static func items(_ defaults: UserDefaults = .standard, now: Date = .now) -> [Item] {
        let all = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Item].self, from: $0) } ?? []
        return all.filter { now.timeIntervalSince($0.receivedAt) < lifetime }
    }

    @MainActor
    static func record(_ text: String, outcome: Outcome, message: String, now: Date = .now, defaults: UserDefaults = .standard) {
        var list = items(defaults, now: now)
        list.append(Item(text: String(AITaskQueue.mask(text).prefix(1_000)), receivedAt: now, outcome: outcome, message: message))
        if list.count > limit { list.removeFirst(list.count - limit) }
        save(list, defaults)
    }

    static func update(_ item: Item, defaults: UserDefaults = .standard) {
        var list = items(defaults)
        guard let index = list.firstIndex(where: { $0.id == item.id }) else { return }
        list[index] = item
        save(list, defaults)
    }

    static func remove(_ id: UUID, defaults: UserDefaults = .standard) {
        save(items(defaults).filter { $0.id != id }, defaults)
    }

    /// 규칙이 생기면 읽을 수 있게 된 글. 못 읽었거나 AI에게 맡긴 것만 다시 본다.
    static func readable(defaults: UserDefaults = .standard, now: Date = .now) -> [Item] {
        items(defaults, now: now).filter { item in
            (item.outcome == .unread || item.outcome == .askedAI || item.outcome == .skipped)
                && LedgerMessageRules.match(item.text, now: item.receivedAt, defaults: defaults) != nil
        }
    }

    private static func save(_ list: [Item], _ defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: key) }
    }
}

// MARK: 화면 (PRL1112A01) — 새 파일을 늘리지 않으려고 여기 둔다.

import SwiftUI

/// 「AI」 탭 위쪽: 자동화가 넘긴 문자·알림과 앱이 한 일. 눌러서 원문을 보고 AI·개발자에게 부탁한다.
struct PaymentInboxList: View {
    let language: MapHomeLanguage
    let items: [PaymentInbox.Item]
    let open: (PaymentInbox.Item) -> Void

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(language.text("받은 결제 문자·알림", "Payment texts received"))
                    .font(.taptionStyle(.caption, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                ForEach(items.prefix(6)) { item in
                    Button { open(item) } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: PaymentInboxDetail.symbol(item.outcome))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(PaymentInboxDetail.needsHelp(item.outcome) ? Color.tpHoliday : Color.tpReferenceMint)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.text.replacingOccurrences(of: "\n", with: " "))
                                    .font(.taptionStyle(.caption))
                                    .foregroundStyle(Color.tpInk)
                                    .lineLimit(1)
                                Text(item.message)
                                    .font(.taptionStyle(.caption2))
                                    .foregroundStyle(Color.tpSecondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.tpSecondary)
                        }
                        .padding(8)
                        .background(Color.tpCard.opacity(0.9), in: RoundedRectangle(cornerRadius: TaptionCorner.small, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// 받은 글 하나: 원문·결과, 못 읽었으면 AI에게 규칙 요청·개발자에게 메일.
struct PaymentInboxDetail: View {
    let language: MapHomeLanguage
    @State var item: PaymentInbox.Item
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var notice: String?

    static func needsHelp(_ outcome: PaymentInbox.Outcome) -> Bool { outcome == .unread || outcome == .askedAI || outcome == .skipped }

    static func symbol(_ outcome: PaymentInbox.Outcome) -> String {
        switch outcome {
        case .added: "checkmark.circle.fill"
        case .review: "exclamationmark.circle"
        case .duplicate: "equal.circle"
        case .skipped: "minus.circle"
        case .unread, .askedAI: "questionmark.circle.fill"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(item.text).font(.taptionStyle(.body)).textSelection(.enabled)
                } header: {
                    Text(item.receivedAt.formatted(date: .abbreviated, time: .shortened))
                } footer: {
                    Text(language.text("번호는 가려서 이 기기에만 7일 동안 둬요.", "Numbers are masked. Kept on this device only, for 7 days."))
                }
                Section { Label(item.message, systemImage: Self.symbol(item.outcome)) }
                Section {
                    Button {
                        Task { await askAI() }
                    } label: { Label(language.text("AI에게 규칙 추가 요청", "Ask AI to add a rule"), systemImage: "text.badge.plus") }
                        .disabled(item.ruleRequested)
                    Button { mailDeveloper() } label: {
                        Label(language.text("개발자에게 추가 요청 메일", "Email the developer"), systemImage: "envelope")
                    }
                    Button(role: .destructive) {
                        PaymentInbox.remove(item.id)
                        dismiss()
                    } label: { Label(language.text("이 글 지우기", "Delete this text"), systemImage: "trash") }
                } footer: {
                    Text(notice ?? language.text("AI가 이 형식을 읽는 규칙을 보내면 앱이 저장하고, 그 뒤 같은 문자는 앱이 스스로 넣어요. 개발자에게 보내면 다음 버전에 모두에게 반영돼요.", "When your AI sends a rule for this format the app saves it and reads the same kind of text by itself. Mail the developer to get it built in for everyone."))
                }
            }
            .tpListStyle()
            .navigationTitle(language.text("받은 문자", "Received text"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(language.text("완료", "Done")) { dismiss() } } }
        }
    }

    @MainActor
    private func askAI() async {
        guard AITaskQueue.enqueue(.paymentRule, text: item.text, day: item.receivedAt) else {
            notice = language.text("연결된 AI가 없어요. 메뉴 › AI 연결에서 먼저 연결해 주세요.", "No AI is connected. Connect one in Menu › AI connection first.")
            return
        }
        item.ruleRequested = true
        PaymentInbox.update(item)
        await AITaskQueue.upload()
        notice = language.text("AI에게 맡겼어요. 규칙이 오면 이 문자도 다시 읽어 넣어요.", "Sent to your AI. When the rule arrives this text is read again.")
    }

    /// 메일 화면만 연다. 보내기는 사용자가 누른다. 본문은 번호를 가린 원문이다.
    private func mailDeveloper() {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = MapHomeDeveloperMail.recipient
        components.queryItems = [
            URLQueryItem(name: "subject", value: "BOKKI Plan payment text format"),
            URLQueryItem(name: "body", value: item.text + "\n\n— " + item.message),
        ]
        if let url = components.url { openURL(url) }
    }
}

// MARK: AI가 하는 가계부 설정·정리 (ACX1112A01) — 새 파일을 늘리지 않으려고 여기 둔다.

extension LedgerBudget {
    /// AI가 정할 수 있는 한 달 예산의 위쪽 끝(서버와 같다).
    static let assistantLimitKRW: Double = 1e12
}

extension LedgerOwnAccounts {
    static let limit = 20

    /// 명령으로 받은 이름: 다듬어 2~30자이고, 번호처럼 보이는 숫자 덩어리(9자 넘게 이어진 숫자·띄어쓰기·붙임표)가 없어야 한다.
    static func commandName(_ raw: String?) -> String? {
        guard let raw, raw.count <= 30 else { return nil }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count >= 2, name.range(of: #"\d[\d -]{7,}\d"#, options: .regularExpression) == nil else { return nil }
        return name
    }
}

extension LedgerMessageRules {
    /// 되돌리기: 지운 규칙을 만든 순서 자리에 다시 둔다(새 규칙이 먼저라는 차례를 지킨다).
    static func restore(_ rule: Rule, defaults: UserDefaults = .standard) {
        var list = rules(defaults).filter { $0.id != rule.id && $0.pattern != rule.pattern }
        list.append(rule)
        list.sort { $0.createdAt < $1.createdAt }
        if list.count > limit { list.removeFirst(list.count - limit) }
        save(list, defaults)
    }
}

extension PaymentInbox {
    /// 되돌리기: 지운 글을 받은 순서 자리에 다시 둔다. 7일이 지난 글은 `items`가 걸러 낸다.
    static func restore(_ item: Item, defaults: UserDefaults = .standard) {
        var list = items(defaults).filter { $0.id != item.id }
        list.append(item)
        list.sort { $0.receivedAt < $1.receivedAt }
        if list.count > limit { list.removeFirst(list.count - limit) }
        save(list, defaults)
    }
}

extension LedgerBook {
    /// 그 달 전체 예산을 정한다. nil이면 없앤다(가계부 화면과 같은 칸).
    func setMonthBudget(_ amountKRW: Double?, month: String) async {
        let budget = amountKRW.map { LedgerBudget(period: month, category: nil, amountKRW: $0) }
        await setBudget(budget, for: "\(month)|all", period: month, category: nil)
    }
}

/// AI 명령이 바꾼 가계부 설정·정리의 전·후(ACX1112A01). 「AI가 한 일」에서 되돌릴 때 쓴다. 한 명령은 한 칸만 채운다.
struct AssistantAppChange: Codable, Equatable, Sendable {
    struct Budget: Codable, Equatable, Sendable {
        var month: String
        var before: Double?
        var after: Double?
    }

    struct Names: Codable, Equatable, Sendable {
        var before: [String]
        var after: [String]
    }

    var budget: Budget?
    var ownAccounts: Names?
    var removedRule: LedgerMessageRules.Rule?
    var removedInbox: PaymentInbox.Item?
    /// 넣거나 버린 「확인 필요」. 넣은 가계부 기록은 `ledgerEntry`로 따로 되돌린다.
    var review: LedgerReviewStore.Item?
    /// 열어 달라고 한 화면. 아직 띄우지 않았을 때만 거둔다.
    var screen: AssistantScreen?
    /// 보낸 질문(ASK1112A01). 아직 답하지 않았을 때만 거둔다.
    var questionID: String?

    /// 그 뒤 사용자가 같은 값을 바꿨으면 되돌리지 않는다.
    @MainActor
    func isCurrent(_ preferences: AssistantPreferenceStore) async -> Bool {
        if let budget {
            await preferences.ledger.load()
            if preferences.ledger.budget(for: budget.month)?.amountKRW != budget.after { return false }
        }
        if let ownAccounts, LedgerOwnAccounts.names(preferences.defaults) != ownAccounts.after { return false }
        return true
    }

    @MainActor
    func undo(_ preferences: AssistantPreferenceStore) async {
        if let budget { await preferences.ledger.setMonthBudget(budget.before, month: budget.month) }
        if let ownAccounts { LedgerOwnAccounts.set(ownAccounts.before, defaults: preferences.defaults) }
        if let removedRule { LedgerMessageRules.restore(removedRule, defaults: preferences.defaults) }
        if let removedInbox { PaymentInbox.restore(removedInbox, defaults: preferences.defaults) }
        if let review { preferences.review.restore(review) }
        if let screen { preferences.screens.cancel(screen) }
        if let questionID { preferences.questions.withdraw(questionID) }
    }
}

extension AppModel {
    /// 가계부 설정·정리와 화면 열기(ACX1112A01). 숫자·이름은 읽을 때 이미 검사했다.
    func applyAssistantAppAction(_ action: AssistantCommand.Action, preferences: AssistantPreferenceStore) async -> AssistantEditResult {
        let language = MapHomeLanguage.current
        let defaults = preferences.defaults
        func money(_ amount: Double?) -> String {
            amount.map { LedgerMoney.text($0, language: language) } ?? language.text("예산 없음", "No budget")
        }
        switch action {
        case let .setBudget(month, amountKRW):
            await preferences.ledger.load()
            let before = preferences.ledger.budget(for: month)?.amountKRW
            let after: Double? = amountKRW > 0 ? amountKRW : nil
            guard before != after else { return .rejected("no_change") }
            await preferences.ledger.setMonthBudget(after, month: month)
            var result = AssistantEditResult(before: "\(month) \(money(before))", after: "\(month) \(money(after))")
            result.appChange = AssistantAppChange(budget: .init(month: month, before: before, after: after))
            return result
        case let .addOwnAccount(name):
            let before = LedgerOwnAccounts.names(defaults)
            guard !before.contains(name) else { return .rejected("no_change") }
            guard before.count < LedgerOwnAccounts.limit else { return .rejected("account_limit") }
            LedgerOwnAccounts.set(before + [name], defaults: defaults)
            var result = AssistantEditResult(after: name)
            result.appChange = AssistantAppChange(ownAccounts: .init(before: before, after: LedgerOwnAccounts.names(defaults)))
            return result
        case let .removeOwnAccount(name):
            let before = LedgerOwnAccounts.names(defaults)
            guard before.contains(name) else { return .rejected("no_account") }
            LedgerOwnAccounts.set(before.filter { $0 != name }, defaults: defaults)
            var result = AssistantEditResult(before: name, after: language.text("지움", "Deleted"))
            result.appChange = AssistantAppChange(ownAccounts: .init(before: before, after: LedgerOwnAccounts.names(defaults)))
            return result
        case let .deletePaymentRule(id):
            guard let rule = LedgerMessageRules.rules(defaults).first(where: { $0.id == id }) else { return .rejected("no_rule") }
            LedgerMessageRules.remove(id, defaults: defaults)
            var result = AssistantEditResult(before: rule.name, after: language.text("지움", "Deleted"))
            result.appChange = AssistantAppChange(removedRule: rule)
            return result
        case let .resolveReview(id, add):
            guard let item = preferences.review.items.first(where: { $0.id == id }) else { return .rejected("no_review") }
            let entry = item.entry
            var result = AssistantEditResult(before: "\(entry.title) \(LedgerMoney.text(entry.amount, currency: entry.currency, language: language))")
            result.appChange = AssistantAppChange(review: item)
            guard add else {
                preferences.review.remove(id)
                result.after = language.text("버림", "Discarded")
                return result
            }
            await preferences.review.accept(id, into: preferences.ledger)
            let saved = preferences.ledger.entries.first { $0.id == entry.id } ?? entry
            result.ledgerEntryID = saved.id
            result.ledgerEntry = saved
            result.after = language.text("가계부에 넣음", "Added to the ledger")
            return result
        case let .deleteInboxItem(id):
            guard let item = PaymentInbox.items(defaults).first(where: { $0.id == id }) else { return .rejected("no_inbox_item") }
            PaymentInbox.remove(id, defaults: defaults)
            var result = AssistantEditResult(before: String(item.text.replacingOccurrences(of: "\n", with: " ").prefix(40)), after: language.text("지움", "Deleted"))
            result.appChange = AssistantAppChange(removedInbox: item)
            return result
        case let .openScreen(screen):
            preferences.screens.request(screen)
            var result = AssistantEditResult(after: screen.title(language))
            result.appChange = AssistantAppChange(screen: screen)
            return result
        case let .askUser(question):
            guard preferences.questions.add(question) else { return .rejected("duplicate") }
            var result = AssistantEditResult(after: String(question.question.prefix(80)))
            result.appChange = AssistantAppChange(questionID: question.id)
            return result
        case let .setSetting(setting, value):
            let change = AssistantPreferenceChange(key: setting.key, before: preferences.value(setting.key), after: value)
            guard change.before != change.after else { return .rejected("no_change") }
            preferences.set(setting.key, value: value, model: self)
            let name = setting.title(language)
            return AssistantEditResult(
                before: "\(name): \(change.before ?? language.text("정하지 않음", "Not set"))", after: "\(name): \(value)", preferences: [change]
            )
        default:
            return await applyAssistantCatalogAction(action)
        }
    }
}
