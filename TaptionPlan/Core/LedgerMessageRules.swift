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
        /// 알림을 보낸 앱(PAS1113A01). 문자나 예전 단축어로 온 글은 없다.
        var source: String?
        /// 사용자가 이 글에 정해 준 종류(PAS1113A01).
        var choice: LedgerMessageRules.Kind?
        /// 「내부」로 정한 글(INT1114A01): 내 계좌 사이 이체·지역카드·교통카드 충전. 지출·수입이 아니다.
        var isInternal: Bool?
    }

    static let key = "paymentInbox"
    static let limit = 30
    static let lifetime: TimeInterval = 7 * 86_400

    static func items(_ defaults: UserDefaults = .standard, now: Date = .now) -> [Item] {
        let all = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Item].self, from: $0) } ?? []
        // 「넣지 않음」으로 정한 글은 보이지 않는다. 지우기 전 빌드에서 정해 남아 있는 것도 여기서 걸러진다(INY1114A01).
        return all.filter { now.timeIntervalSince($0.receivedAt) < lifetime && !isSkippedByChoice($0) }
    }

    static func isSkippedByChoice(_ item: Item) -> Bool { item.choice == .ignore && item.isInternal != true }

    /// 문자함에 남는 모양: 번호를 가리고 1,000자까지.
    @MainActor
    static func stored(_ text: String) -> String { String(AITaskQueue.mask(text).prefix(1_000)) }

    @MainActor
    static func record(_ text: String, outcome: Outcome, message: String, source: String? = nil, now: Date = .now, defaults: UserDefaults = .standard) {
        var list = items(defaults, now: now)
        list.append(Item(text: stored(text), receivedAt: now, outcome: outcome, message: message, source: source))
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
                ForEach(items.prefix(40)) { item in
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
                PaymentInboxChoiceSection(language: language, item: $item, notice: $notice)
                // 학습·삭제는 고르기 줄 바로 아래에 둔다(PIX1114A01, 대표 지시: 아래 메뉴를 위로).
                Section {
                    HStack(spacing: 8) {
                        actionButton(language.text("학습", "Teach"), "text.badge.plus", tint: Color.tpAccent) { Task { await askAI() } }
                            .disabled(item.ruleRequested)
                            .opacity(item.ruleRequested ? 0.45 : 1)
                            .accessibilityHint(language.text("AI에게 이 형식을 읽는 규칙을 부탁해요", "Asks your AI for a rule that reads this format"))
                        actionButton(language.text("삭제", "Delete"), "trash", tint: Color.red) {
                            PaymentInbox.remove(item.id)
                            dismiss()
                        }
                    }
                    .buttonStyle(.plain)
                } footer: {
                    Text(notice ?? language.text("「학습」을 누르면 AI가 이 형식을 읽는 규칙을 보내고, 그 뒤 같은 글은 앱이 스스로 넣어요.", "Teach asks your AI for a rule for this format; after that the app reads the same kind of text by itself."))
                }
                Section {
                    Button { mailDeveloper() } label: {
                        Label(language.text("개발자에게 반영 요청", "Ask the developer to add it"), systemImage: "envelope")
                    }
                } footer: {
                    Text(language.text("개발자에게 보내면 다음 버전에 모두에게 반영돼요.", "Mail the developer to get it built in for everyone."))
                }
            }
            .tpListStyle()
            .navigationTitle(language.text("받은 문자", "Received text"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(language.text("완료", "Done")) { dismiss() } } }
        }
    }

    private func actionButton(_ title: String, _ symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.taptionStyle(.subheadline, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 40)
                .foregroundStyle(tint)
                .background(Color.tpCard, in: RoundedRectangle(cornerRadius: TaptionCorner.small, style: .continuous))
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
    /// 여행 장부 전·후(TBG1112A01). `before`가 nil이면 이 명령이 장부를 만들었다.
    var ledgerTrip: TripChange?

    struct TripChange: Codable, Equatable, Sendable {
        var before: LedgerTrip?
        var after: LedgerTrip
    }

    /// 내 차 등록·빼기 전·후(HND1112A01). 그 뒤 목록이 바뀌었으면 되돌리지 않는다.
    var carAudio: CarAudio?
    /// 일정 제목 분류 전·후(HND1112A01). `had`가 false면 정하기 전이었다.
    var calendarTitle: CalendarTitle?

    struct CarAudio: Codable, Equatable, Sendable {
        struct Lists: Codable, Equatable, Sendable {
            var registered: [String]
            var recent: [String]
            var dismissed: [String]
        }

        var before: Lists
        var after: Lists
    }

    struct CalendarTitle: Codable, Equatable, Sendable {
        var title: String
        var hadBefore: Bool
        var before: String?
        var after: String?
    }

    /// ACT1114A07: UserDefaults에 둔 값의 전·후(환율·알림 앱 스위치·넣지 않을 낱말). 속성 목록으로 담는다.
    var stored: [Stored]?
    /// 지운 여행 장부. 되돌리면 다시 만든다.
    var deletedLedgerTrip: LedgerTrip?

    struct Stored: Codable, Equatable, Sendable {
        var key: String
        var before: Data?
        var after: Data?
    }

    /// 그 뒤 사용자가 같은 값을 바꿨으면 되돌리지 않는다.
    @MainActor
    func isCurrent(_ preferences: AssistantPreferenceStore) async -> Bool {
        if let budget {
            await preferences.ledger.load()
            if preferences.ledger.budget(for: budget.month)?.amountKRW != budget.after { return false }
        }
        if let ownAccounts, LedgerOwnAccounts.names(preferences.defaults) != ownAccounts.after { return false }
        if let ledgerTrip {
            await preferences.ledger.load()
            if preferences.ledger.trip(ledgerTrip.after.id) != ledgerTrip.after { return false }
        }
        if let stored, !stored.allSatisfy({ $0.isCurrent(preferences.defaults) }) { return false }
        if let deletedLedgerTrip {
            await preferences.ledger.load()
            if preferences.ledger.trip(deletedLedgerTrip.id) != nil { return false }
        }
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
        if let ledgerTrip {
            if let before = ledgerTrip.before { await preferences.ledger.saveTrip(before) } else { await preferences.ledger.deleteTrip(ledgerTrip.after.id) }
        }
        for value in stored ?? [] { value.undo(preferences.defaults) }
        if let deletedLedgerTrip { await preferences.ledger.saveTrip(deletedLedgerTrip) }
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
        case let .askUser(question), let .requestApproval(question):
            guard preferences.questions.add(question) else { return .rejected("duplicate") }
            // 앱이 앞에 있지 않으면 iOS 알림으로 알린다(ASN1112A01). 시험 저장소는 알리지 않는다.
            if preferences.isLive, !isSceneActive {
                AssistantQuestionNotice.post(question, language: language, enabled: settings.notificationsEnabled)
            }
            var result = AssistantEditResult(after: String((question.approval?.title(language) ?? question.question).prefix(80)))
            result.appChange = AssistantAppChange(questionID: question.id)
            return result
        case let .setTripBudget(tripID, budgetKRW):
            await preferences.ledger.load()
            let existing = preferences.ledger.trip(tripID)
            // 장부가 없으면 앱 여행(같은 번호)의 이름과 기간으로 만든다.
            let planned = LedgerBook.plannedTrips(
                stops: settings.travelPlanStops, items: settings.travelTripItems ?? [], trips: settings.travelTrips ?? []
            ).first { $0.id == tripID }
            guard var trip = existing ?? planned else { return .rejected("no_trip") }
            let budget: Double? = budgetKRW > 0 ? budgetKRW : nil
            guard existing == nil || existing?.budgetKRW != budget else { return .rejected("no_change") }
            trip.budgetKRW = budget
            await preferences.ledger.saveTrip(trip)
            var result = AssistantEditResult(before: "\(trip.name) \(money(existing?.budgetKRW))", after: "\(trip.name) \(money(budget))")
            result.appChange = AssistantAppChange(ledgerTrip: .init(before: existing, after: trip))
            return result
        case let .setSetting(setting, value):
            if setting.isSalary, !MapHomeSalaryPolicy.isAILinked(defaults) { return .rejected("salary_link_off") }
            let change = AssistantPreferenceChange(key: setting.key, before: preferences.value(setting.key, model: self), after: value)
            guard change.before != change.after else { return .rejected("no_change") }
            if setting.isModelBacked {
                await setting.apply(value, to: self)
                guard setting.read(model: self) == value else { return .rejected("edit_failed") }
            } else {
                preferences.set(setting.key, value: value, model: self)
            }
            let name = setting.title(language)
            return AssistantEditResult(
                before: "\(name): \(change.before ?? language.text("정하지 않음", "Not set"))", after: "\(name): \(value)", preferences: [change]
            )
        default:
            return await applyAssistantCatalogAction(action)
        }
    }
}

// MARK: 등록부 동작 1묶음 — 가계부 (ACT1114A07). 새 파일을 늘리지 않으려고 여기 둔다.

extension AssistantAppChange.Stored {
    static func pack(_ value: Any?) -> Data? {
        value.flatMap { try? PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0) }
    }

    static func unpack(_ data: Data?) -> Any? {
        data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) }
    }

    /// JSON으로 담은 값(알림 앱 목록)은 풀어서 견준다. 같은 값도 담을 때마다 바이트가 다를 수 있다.
    private static func plain(_ value: Any?) -> Any? {
        (value as? Data).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? value
    }

    static func same(_ left: Any?, _ right: Any?) -> Bool {
        switch (plain(left), plain(right)) {
        case (nil, nil): true
        case let (left?, right?): (left as? NSObject)?.isEqual(right) ?? false
        default: false
        }
    }

    func isCurrent(_ defaults: UserDefaults) -> Bool { Self.same(defaults.object(forKey: key), Self.unpack(after)) }

    func undo(_ defaults: UserDefaults) {
        if let value = Self.unpack(before) { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

extension AssistantOperations {
    static let ledger: [any AssistantOperation.Type] = [
        ClassifyInboxItem.self, SetFxRate.self, SetPaymentSource.self, SetSkipWords.self,
        AddLedgerTrip.self, UpdateLedgerTrip.self, DeleteLedgerTrip.self,
    ]

    /// 받은 결제 문자 하나의 종류를 정한다. 화면의 「이 알림은」 칸과 같은 함수를 쓴다.
    struct ClassifyInboxItem: AssistantOperation {
        static let spec = AssistantOperationSpec(
            name: "classifyInboxItem", fields: ["inboxId", "choice"], counter: .ledger,
            title: { $0.text("받은 결제 문자 종류 정하기", "Classify received payment texts") },
            guide: #""inboxId":"<inbox[].id>","choice":"expense|income|ignore|internal"} (settles one received payment text like my own tap: expense or income adds it to the ledger when the amount can be read, ignore drops it from the inbox, internal is a transfer between my own accounts or a card top-up and removes the entry the app added for it)"#
        )

        let inboxID: UUID
        let choice: String

        init?(fields: AssistantFields) {
            guard let inboxID = fields.uuid("inboxId"), let choice = fields.raw("choice"),
                  choice == "internal" || LedgerMessageRules.Kind(rawValue: choice) != nil else { return nil }
            self.inboxID = inboxID
            self.choice = choice
        }

        func apply(host: AssistantOperationHost) async -> AssistantEditResult {
            guard let item = PaymentInbox.items(host.defaults).first(where: { $0.id == inboxID }) else { return .rejected("no_inbox_item") }
            await host.book.load()
            let entries = host.book.entries
            // 시험 저장소로는 AI에게 규칙을 부탁하지 않는다(실제 일 목록을 건드리지 않게).
            let asksAI = host.preferences.isLive
            let updated: PaymentInbox.Item, notice: String
            if let kind = LedgerMessageRules.Kind(rawValue: choice) {
                (updated, notice) = await PaymentInboxChoice.apply(kind, to: item, language: host.language, book: host.book, defaults: host.defaults, asksAI: asksAI)
            } else {
                (updated, notice) = await PaymentInboxChoice.applyInternal(to: item, language: host.language, book: host.book, defaults: host.defaults, asksAI: asksAI)
            }
            guard updated != item else { return .rejected("no_change") }
            var result = AssistantEditResult(before: String(item.text.replacingOccurrences(of: "\n", with: " ").prefix(40)), after: notice)
            result.appChange = AssistantAppChange(removedInbox: item)
            // 넣은 기록은 되돌리면 지우고, 「내부」로 지운 기록은 되돌리면 다시 넣는다.
            if let added = host.book.entries.first(where: { entry in !entries.contains { $0.id == entry.id } }) {
                result.ledgerEntryID = added.id
                result.ledgerEntry = added
            } else if let removed = entries.first(where: { entry in !host.book.entries.contains { $0.id == entry.id } }) {
                result.ledgerBefore = removed
            }
            return result
        }
    }

    /// 직접 넣는 환율(가계부 기록 편집의 「직접 넣는 환율」과 같은 값).
    struct SetFxRate: AssistantOperation {
        static let spec = AssistantOperationSpec(
            name: "setFxRate", fields: ["currency", "krwPerUnit"], counter: .ledger,
            title: { $0.text("환율 직접 정하기", "Set exchange rates") },
            guide: #""currency":"USD","krwPerUnit":1400} (my own exchange rate for one currency, KRW per unit; the ledger uses it for new entries instead of the fetched rate; current ones are in GET /app settings.fxRates)"#
        )

        let currency: String
        let rate: Double

        init?(fields: AssistantFields) {
            guard let currency = fields.raw("currency"), currency.count == 3, currency.allSatisfy({ $0.isASCII && $0.isUppercase }), currency != "KRW",
                  let rate = fields.number("krwPerUnit"), rate > 0, rate <= 1e7 else { return nil }
            self.currency = currency
            self.rate = rate
        }

        func apply(host: AssistantOperationHost) async -> AssistantEditResult {
            // `LedgerBook.manualRates`와 같은 키다. 시험은 따로 만든 저장소에 쓴다.
            let key = LedgerBook.manualRatesKey
            let rates = (host.defaults.dictionary(forKey: key) as? [String: Double]) ?? [:]
            guard let change = host.changing(key, { host.defaults.set(rates.merging([currency: rate]) { $1 }, forKey: key) }) else { return .rejected("no_change") }
            func describe(_ value: Double) -> String { "1 \(currency) = \(LedgerMoney.text(value, language: host.language))" }
            var result = AssistantEditResult(before: rates[currency].map(describe) ?? "", after: describe(rate))
            result.appChange = AssistantAppChange(stored: [change])
            return result
        }
    }

    /// 결제 알림을 보낸 앱마다의 지출·수입 스위치(「결제 알림 받기」 화면과 같은 함수).
    struct SetPaymentSource: AssistantOperation {
        static let spec = AssistantOperationSpec(
            name: "setPaymentSource", fields: ["name", "expense", "income", "remove"], counter: .settings,
            title: { $0.text("결제 알림 앱 스위치 바꾸기", "Change payment alert app switches") },
            guide: #""name":"<settings.paymentSources[].name>","expense":true,"income":false} (what the ledger keeps from one app's payment alerts; give expense, income or both, or "remove":true alone to take the app off the list; the name "문자" stands for text messages)"#
        )

        let name: String
        let expense: Bool?
        let income: Bool?
        let removes: Bool

        init?(fields: AssistantFields) {
            let expense = fields.flag("expense"), income = fields.flag("income"), remove = fields.flag("remove")
            guard let name = PaymentAlertSources.name(fields.raw("name")), fields.ok("expense", expense), fields.ok("income", income), fields.ok("remove", remove),
                  remove == true ? expense == nil && income == nil : expense != nil || income != nil else { return nil }
            self.name = name
            self.expense = expense
            self.income = income
            removes = remove == true
        }

        func apply(host: AssistantOperationHost) async -> AssistantEditResult {
            let language = host.language
            let isTexts = name == PaymentAlertSources.smsName
            let current = PaymentAlertSources.all(host.defaults).first { $0.name == name }
            func describe(_ source: PaymentAlertSources.Source?) -> String {
                guard let source else { return "" }
                func state(_ isOn: Bool) -> String { isOn ? language.text("켬", "On") : language.text("끔", "Off") }
                return "\(source.name) · \(language.text("지출", "Spending")) \(state(source.expense)) · \(language.text("수입", "Income")) \(state(source.income))"
            }
            var result = AssistantEditResult(before: describe(current))
            let change: AssistantAppChange.Stored?
            if removes {
                // 문자 줄은 화면에서도 지울 수 없다.
                guard current != nil, !isTexts else { return .rejected(isTexts ? "not_editable" : "no_source") }
                change = host.changing(PaymentAlertSources.key) { PaymentAlertSources.remove(name, defaults: host.defaults) }
                result.after = host.deleted
            } else {
                guard current != nil || PaymentAlertSources.all(host.defaults).count < PaymentAlertSources.limit else { return .rejected("source_limit") }
                var source = current ?? .init(name: name, lastSeen: isTexts ? .distantPast : .now)
                if let expense { source.expense = expense }
                if let income { source.income = income }
                change = host.changing(PaymentAlertSources.key) { PaymentAlertSources.set(source, defaults: host.defaults) }
                result.after = describe(source)
            }
            guard let change else { return .rejected("no_change") }
            result.appChange = AssistantAppChange(stored: [change])
            return result
        }
    }

    /// 넣지 않을 낱말(「결제 알림 받기」 화면 아래 칸과 같은 함수).
    struct SetSkipWords: AssistantOperation {
        static let spec = AssistantOperationSpec(
            name: "setSkipWords", fields: ["add", "remove"], counter: .settings,
            title: { $0.text("넣지 않을 낱말 고치기", "Edit words to skip") },
            guide: #""add":["광고"],"remove":["자동이체"]} (words in settings.skipWords: a payment text or alert containing one is not added to the ledger; add, remove or both, each word 1 to 20 characters)"#
        )

        let adds: [String]
        let removes: [String]

        init?(fields: AssistantFields) {
            let adds = fields.texts("add", max: 20, count: 1...10), removes = fields.texts("remove", max: 20, count: 1...10)
            guard fields.ok("add", adds), fields.ok("remove", removes), adds != nil || removes != nil else { return nil }
            self.adds = adds ?? []
            self.removes = removes ?? []
        }

        func apply(host: AssistantOperationHost) async -> AssistantEditResult {
            let before = PaymentAlertSources.skipWords(host.defaults)
            guard let change = host.changing(PaymentAlertSources.skipWordsKey, {
                for word in removes { PaymentAlertSources.removeSkipWord(word, defaults: host.defaults) }
                for word in adds { PaymentAlertSources.addSkipWord(word, defaults: host.defaults) }
            }) else { return .rejected("no_change") }
            var result = AssistantEditResult(before: before.joined(separator: ", "), after: PaymentAlertSources.skipWords(host.defaults).joined(separator: ", "))
            result.appChange = AssistantAppChange(stored: [change])
            return result
        }
    }

    /// 함께 간 사람 이름: 1~30자, 20명까지, 「나」를 가리키는 이름은 받지 않는다.
    static func members(_ fields: AssistantFields, count: ClosedRange<Int>) -> [String]? {
        fields.texts("members", max: 30, count: count).flatMap { $0.contains(LedgerTrip.me) ? nil : $0 }
    }

    /// 계획 없는 여행 장부를 만든다(가계부의 「여행 더하기」와 같은 `saveTrip`).
    struct AddLedgerTrip: AssistantOperation {
        static let spec = AssistantOperationSpec(
            name: "addLedgerTrip", fields: ["name", "start", "end", "members"], counter: .ledger, changes: 0,
            title: { $0.text("여행 가계부 만들기", "Create trip ledgers") },
            guide: #""name":"Jeju","start":"YYYY-MM-DD","end":"YYYY-MM-DD","members":["Mina"]} (creates a trip ledger that has no planned trip; end and members optional, members are my companions without me; for a planned trip use setTripBudget instead; the new id appears in GET /app ledger.trips)"#
        )

        let name: String
        let start: Date
        let end: Date
        let members: [String]

        init?(fields: AssistantFields) {
            let end = fields.day("end"), members = AssistantOperations.members(fields, count: 1...20)
            guard let name = fields.text("name", max: 40), let start = fields.day("start"), fields.ok("end", end), fields.ok("members", members),
                  (end ?? start) >= start else { return nil }
            self.name = name
            self.start = start
            self.end = end ?? start
            self.members = members ?? []
        }

        func apply(host: AssistantOperationHost) async -> AssistantEditResult {
            await host.book.load()
            guard host.book.trips.count < AssistantCatalogLimits.places else { return .rejected("trip_limit") }
            let trip = LedgerTrip(id: "ledger-" + UUID().uuidString, name: name, start: start, end: end, members: members)
            await host.book.saveTrip(trip)
            guard let saved = host.book.trip(trip.id) else { return .rejected("edit_failed") }
            var result = AssistantEditResult(after: AssistantOperations.describe(saved))
            result.appChange = AssistantAppChange(ledgerTrip: .init(before: nil, after: saved))
            return result
        }
    }

    static func describe(_ trip: LedgerTrip) -> String {
        let days = "\(AssistantDataText.day(trip.start))–\(AssistantDataText.day(trip.end))"
        return trip.members.isEmpty ? "\(trip.name) · \(days)" : "\(trip.name) · \(days) · \(trip.members.count + 1)"
    }

    /// 여행 장부의 이름·기간·동행·정산을 고친다(여행 장부 편집·정산 짝 기록 편집과 같은 `saveTrip`·`resetSettlement`).
    struct UpdateLedgerTrip: AssistantOperation {
        static let spec = AssistantOperationSpec(
            name: "updateLedgerTrip",
            fields: ["tripId", "name", "start", "end", "members", "settlementKRW", "autoSettlement", "fundingDate", "settlementDate"], counter: .ledger,
            title: { $0.text("여행 가계부 고치기", "Edit trip ledgers") },
            guide: #""tripId":"<ledger.trips[].id>","members":["Mina","Jun"],"settlementKRW":-30000,"settlementDate":"YYYY-MM-DD"} (give at least one of name, start, end, members (the whole companion list, [] for none), fundingDate (the day the budget moves), settlementKRW (fixes the settlement by hand: + returned to my daily ledger, - extra cost, 0 none), settlementDate, or "autoSettlement":true to go back to the automatic settlement)"#
        )

        let tripID: String
        let name: String?
        let start: Date?
        let end: Date?
        let members: [String]?
        let settlementKRW: Double?
        let autoSettlement: Bool
        let fundingDate: Date?
        let settlementDate: Date?

        init?(fields: AssistantFields) {
            let name = fields.text("name", max: 40), start = fields.day("start"), end = fields.day("end")
            let members = AssistantOperations.members(fields, count: 0...20), settlement = fields.number("settlementKRW"), auto = fields.flag("autoSettlement")
            let funding = fields.day("fundingDate"), settled = fields.day("settlementDate")
            guard let tripID = fields.text("tripId", max: 100), fields.ok("name", name), fields.ok("start", start), fields.ok("end", end),
                  fields.ok("members", members), fields.ok("settlementKRW", settlement), fields.ok("fundingDate", funding), fields.ok("settlementDate", settled),
                  !fields.has("autoSettlement") || (auto == true && settlement == nil), settlement.map({ abs($0) <= 1e12 }) ?? true,
                  fields.values.count > 1 else { return nil }
            if let start, let end, end < start { return nil }
            self.tripID = tripID
            self.name = name
            self.start = start
            self.end = end
            self.members = members
            settlementKRW = settlement?.rounded()
            autoSettlement = auto == true
            fundingDate = funding
            // 자동 정산과 같은 때(그날 아침 9시)에 둔다.
            settlementDate = settled.map { $0.addingTimeInterval(9 * 3_600) }
        }

        func apply(host: AssistantOperationHost) async -> AssistantEditResult {
            await host.book.load()
            guard let old = host.book.trip(tripID) else { return .rejected("no_trip") }
            var trip = old
            if let name { trip.name = name }
            if let start { trip.start = start }
            if let end { trip.end = end }
            guard trip.end >= trip.start else { return .rejected("end_before_start") }
            if let members { trip.members = members }
            if let fundingDate { trip.fundingDate = fundingDate }
            if let settlementKRW { trip.settlementKRW = settlementKRW }
            if let settlementDate { trip.settlementDate = settlementDate }
            if autoSettlement {
                trip.settlementKRW = nil
                trip.settlementDate = nil
            }
            guard trip != old else { return .rejected("no_change") }
            // 정산만 자동으로 돌릴 때는 화면의 「자동 정산으로 되돌리기」와 같은 함수를 쓴다.
            var automatic = old
            automatic.settlementKRW = nil
            automatic.settlementDate = nil
            if autoSettlement, trip == automatic { await host.book.resetSettlement(tripID) } else { await host.book.saveTrip(trip) }
            guard let saved = host.book.trip(tripID) else { return .rejected("edit_failed") }
            func describe(_ value: LedgerTrip) -> String {
                AssistantOperations.describe(value) + (value.settlementKRW.map { " · " + LedgerMoney.text($0, language: host.language) } ?? "")
            }
            var result = AssistantEditResult(before: describe(old), after: describe(saved))
            result.appChange = AssistantAppChange(ledgerTrip: .init(before: old, after: saved))
            return result
        }
    }

    /// 여행 장부를 지운다(여행 장부 화면의 지우기와 같은 `deleteTrip`). 안의 기록은 일상 장부로 돌아간다.
    struct DeleteLedgerTrip: AssistantOperation {
        static let spec = AssistantOperationSpec(
            name: "deleteLedgerTrip", fields: ["tripId"], counter: .ledger, deletes: true,
            title: { $0.text("여행 가계부 지우기", "Delete trip ledgers") },
            guide: #""tripId":"<ledger.trips[].id>"} (deletes a trip ledger: its budget and settlement transfers go, the entries inside stay and return to my daily ledger; only when I asked)"#
        )

        let tripID: String

        init?(fields: AssistantFields) {
            guard let tripID = fields.text("tripId", max: 100) else { return nil }
            self.tripID = tripID
        }

        func apply(host: AssistantOperationHost) async -> AssistantEditResult {
            await host.book.load()
            guard let old = host.book.trip(tripID) else { return .rejected("no_trip") }
            await host.book.deleteTrip(tripID)
            guard host.book.trip(tripID) == nil else { return .rejected("edit_failed") }
            var result = AssistantEditResult(before: AssistantOperations.describe(old), after: host.deleted)
            result.appChange = AssistantAppChange(deletedLedgerTrip: old)
            return result
        }
    }
}
