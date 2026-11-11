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
