import Foundation

/// 결제 알림을 보낸 앱마다 무엇을 가계부에 넣을지(PAS1113A01). 단축어 「BOKKI 결제 알림」이 앱 이름을 함께 넘기면
/// 앱이 그 이름을 기억하고, 사용자는 앱마다 「지출」「수입」을 켜고 끈다. 충전·광고·잔액 안내는 이 설정과 상관없이 늘 넣지 않는다.
/// 앱 이름을 모르는 글(문자, 예전 단축어)은 늘 허용한다.
enum PaymentAlertSources {
    struct Source: Codable, Equatable, Identifiable, Sendable {
        var name: String
        var expense = true
        var income = true
        var lastSeen: Date
        var id: String { name }
    }

    static let key = "paymentAlertSources"
    static let limit = 40
    /// 문자 자동화(「BOKKI 결제」)로 넘어온 글의 출처 이름. 앱 이름이 없는 글은 문자로 본다(SMS1114A01).
    static let smsName = "문자"

    // MARK: 넣지 않을 낱말 (SMS1114A01)
    // 단축어 자동화는 앱이 고칠 수 없어(iOS 제한) 자동화는 넓게 받게 두고, 무엇을 넣을지는 앱의 이 설정으로 정한다.

    static let skipWordsKey = "paymentSkipWords"
    static let skipWordLimit = 30

    static func skipWords(_ defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: skipWordsKey) ?? []
    }

    /// 낱말을 다듬어 더한다(1~20자, 중복 없음). 더했으면 true.
    @discardableResult
    static func addSkipWord(_ raw: String, defaults: UserDefaults = .standard) -> Bool {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var words = skipWords(defaults)
        guard (1...20).contains(word.count), !words.contains(word), words.count < skipWordLimit else { return false }
        words.append(word)
        defaults.set(words, forKey: skipWordsKey)
        return true
    }

    static func removeSkipWord(_ word: String, defaults: UserDefaults = .standard) {
        defaults.set(skipWords(defaults).filter { $0 != word }, forKey: skipWordsKey)
    }

    /// 글에 든 「넣지 않을 낱말」(없으면 nil).
    static func skipWord(in text: String, defaults: UserDefaults = .standard) -> String? {
        skipWords(defaults).first { text.localizedCaseInsensitiveContains($0) }
    }

    static func all(_ defaults: UserDefaults = .standard) -> [Source] {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Source].self, from: $0) } ?? []
    }

    /// 단축어가 넘긴 앱 이름을 다듬는다: 앞뒤 공백을 떼고 1~40자. 그 밖이면 모르는 앱이다.
    static func name(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...40).contains(name.count) ? name : nil
    }

    /// 단축어 「BOKKI 결제 알림」이 붙인 첫 줄 「[앱: 이름]」을 떼어 낸다. 없으면 앱을 모르는 글이다.
    static func split(_ text: String) -> (source: String?, body: String) {
        let normalized = text.replacingOccurrences(of: "\r", with: "\n")
        guard let match = normalized.firstMatch(of: /^\s*\[앱:\s*([^\]\n]*)\]\s*\n?/) else { return (nil, text) }
        return (name(String(match.1)), String(normalized[match.range.upperBound...]))
    }

    /// 알림이 오면 그 앱을 목록에 남긴다. 처음 본 앱은 지출·수입 모두 켠 채로 들어온다.
    static func seen(_ raw: String?, now: Date = .now, defaults: UserDefaults = .standard) {
        guard let name = name(raw) else { return }
        var list = all(defaults)
        if let index = list.firstIndex(where: { $0.name == name }) {
            list[index].lastSeen = now
        } else {
            list.append(Source(name: name, lastSeen: now))
            if list.count > limit {
                list.sort { $0.lastSeen < $1.lastSeen }
                list.removeFirst(list.count - limit)
            }
        }
        save(list, defaults)
    }

    static func set(_ source: Source, defaults: UserDefaults = .standard) {
        var list = all(defaults)
        if let index = list.firstIndex(where: { $0.name == source.name }) { list[index] = source } else { list.append(source) }
        save(list, defaults)
    }

    static func remove(_ name: String, defaults: UserDefaults = .standard) {
        save(all(defaults).filter { $0.name != name }, defaults)
    }

    /// 그 앱의 이 종류 알림을 넣어도 되는가. 모르는 앱은 넣는다.
    static func allows(_ raw: String?, income: Bool, defaults: UserDefaults = .standard) -> Bool {
        guard let name = name(raw), let source = all(defaults).first(where: { $0.name == name }) else { return true }
        return income ? source.income : source.expense
    }

    /// 꺼 둔 종류라 넣지 않았다고 알리는 글.
    static func blockedMessage(_ raw: String?, income: Bool, language: MapHomeLanguage) -> String {
        let app = name(raw) ?? ""
        return income
            ? language.text("\(app) 알림의 수입은 넣지 않게 해 두었어요.", "Income from \(app) alerts is turned off.")
            : language.text("\(app) 알림의 지출은 넣지 않게 해 두었어요.", "Spending from \(app) alerts is turned off.")
    }

    private static func save(_ list: [Source], _ defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: key) }
    }
}

// MARK: 화면 (PAS1113A01)

import SwiftUI

/// 「결제 알림 받기」: 알림을 보낸 앱마다 지출·수입 스위치와 앱 더하기 안내.
struct PaymentAlertSourcesView: View {
    let language: MapHomeLanguage
    @Environment(\.openURL) private var openURL
    /// 문자는 늘 맨 위에 둔다(아직 받은 문자가 없어도 스위치를 미리 정할 수 있게).
    @State private var sources: [PaymentAlertSources.Source] = {
        let all = PaymentAlertSources.all().sorted { $0.lastSeen > $1.lastSeen }
        let sms = all.first { $0.name == PaymentAlertSources.smsName } ?? .init(name: PaymentAlertSources.smsName, lastSeen: .distantPast)
        return [sms] + all.filter { $0.name != PaymentAlertSources.smsName }
    }()
    @State private var skipWords = PaymentAlertSources.skipWords()
    @State private var newWord = ""

    var body: some View {
        List {
            if sources.count <= 1 {
                Section {
                    Text(language.text("아직 받은 앱 알림이 없어요. 결제 알림이 한 번 오면 그 앱이 여기에 생겨요.", "No app alerts yet. An app appears here after its first payment alert."))
                        .font(.taptionStyle(.subheadline))
                        .foregroundStyle(Color.tpSecondary)
                } header: {
                    Text(language.text("앱마다 넣을 알림", "What to keep from each app"))
                }
            }
            ForEach($sources) { $source in
                Section {
                    Toggle(language.text("지출", "Spending"), isOn: $source.expense)
                    Toggle(language.text("수입", "Income"), isOn: $source.income)
                    if source.name != PaymentAlertSources.smsName {
                        Button(role: .destructive) {
                            PaymentAlertSources.remove(source.name)
                            sources.removeAll { $0.name == source.name }
                        } label: { Text(language.text("목록에서 지우기", "Remove from list")) }
                    }
                } header: {
                    Text(source.name == PaymentAlertSources.smsName ? language.text("문자 (「BOKKI 결제」 자동화)", "Texts (BOKKI Payment automation)") : source.name)
                } footer: {
                    if source.id == sources.last?.id {
                        Text(language.text("충전·광고·잔액 안내는 스위치와 상관없이 넣지 않아요. 넣지 않은 알림도 「AI」 탭의 받은 문자에 7일 동안 남아요.", "Top-ups, ads and balance notices are never added. Skipped alerts stay in the AI tab's received texts for 7 days."))
                    }
                }
                .font(.taptionStyle(.subheadline))
                .onChange(of: source) { _, value in PaymentAlertSources.set(value) }
            }
            Section {
                ForEach(skipWords, id: \.self) { word in
                    HStack {
                        Text(word)
                        Spacer()
                        Button {
                            PaymentAlertSources.removeSkipWord(word)
                            skipWords = PaymentAlertSources.skipWords()
                        } label: { Image(systemName: "minus.circle.fill").foregroundStyle(Color.red) }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(language.text("\(word) 지우기", "Remove \(word)"))
                    }
                }
                HStack {
                    TextField(language.text("낱말 (예: 광고, 자동이체)", "Word (e.g. ad, autopay)"), text: $newWord)
                        .submitLabel(.done)
                        .onSubmit(addWord)
                    Button(language.text("더하기", "Add"), action: addWord)
                        .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text(language.text("넣지 않을 낱말", "Words to skip"))
            } footer: {
                Text(language.text("이 낱말이 든 문자·알림은 가계부에 넣지 않아요. 단축어 자동화는 고치지 않아도 돼요 — 자동화는 그대로 받고, 무엇을 넣을지는 여기서 정해요.", "Texts and alerts containing these words are not added. You don't need to edit the Shortcuts automation: it keeps receiving, and this decides what gets added."))
            }
            .font(.taptionStyle(.subheadline))
            Section {
                ForEach(Array(Self.addSteps(language).enumerated()), id: \.offset) { index, step in
                    Label(step, systemImage: "\(index + 1).circle")
                }
                Button {
                    if let url = URL(string: "shortcuts://") { openURL(url) }
                } label: { Label(language.text("단축어 앱 열기", "Open Shortcuts"), systemImage: "square.2.layers.3d") }
            } header: {
                Text(language.text("앱 더하기", "Add an app"))
            } footer: {
                Text(language.text("어느 앱의 알림을 넘길지는 iOS가 단축어 앱에서만 고르게 해요. 넣은 앱은 첫 결제 알림이 오면 위 목록에 생겨요.", "iOS only lets you pick the apps in Shortcuts. A new app shows up above after its first payment alert."))
            }
        }
        .tpListStyle()
        .navigationTitle(language.text("결제 알림 받기", "Payment alerts"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func addWord() {
        if PaymentAlertSources.addSkipWord(newWord) { skipWords = PaymentAlertSources.skipWords() }
        newWord = ""
    }

    static func addSteps(_ language: MapHomeLanguage) -> [String] {
        [
            language.text("단축어 앱 › 아래 「자동화」", "Shortcuts › Automation at the bottom"),
            language.text("「BOKKI 결제 알림」 줄을 눌러요", "Tap the BOKKI Payment Alerts row"),
            language.text("앱 이름들 옆 「+」를 눌러 앱을 골라요", "Tap + next to the app names and pick the app"),
            language.text("스위치가 켜져 있는지 봐요", "Check that its switch is on"),
        ]
    }
}

/// 받은 알림 하나에 종류를 정해 준다(PAS1113A01): 이 글은 바로 그렇게 처리하고, 연결된 AI에게 같은 모양의 규칙을 부탁한다.
enum PaymentInboxChoice {
    @MainActor
    static func apply(_ kind: LedgerMessageRules.Kind, to item: PaymentInbox.Item, language: MapHomeLanguage) async -> (PaymentInbox.Item, String) {
        var item = item
        item.choice = kind
        item.isInternal = nil
        var notice: String
        if kind == .ignore {
            notice = item.outcome == .added
                ? language.text("앞으로 이런 알림은 넣지 않게 할게요. 이미 넣은 기록은 가계부에서 지워 주세요.", "Alerts like this won't be added from now on. Delete the entry already added from the ledger.")
                : language.text("앞으로 이런 알림은 넣지 않게 할게요.", "Alerts like this won't be added from now on.")
        } else if item.outcome == .added {
            notice = language.text("이미 가계부에 들어간 글이에요. 앞으로 같은 모양을 이 종류로 읽게 할게요.", "This one is already in the ledger. Alerts like it will be read this way from now on.")
        } else if let entry = entry(for: item, income: kind == .income) {
            await LedgerBook.shared.load()
            let saved = await LedgerBook.shared.save(entry)
            item.outcome = .added
            item.message = language.text("직접 정해 가계부에 넣었어요.", "Added to the ledger as you chose.")
            notice = language.text("\(saved.title) \(LedgerMoney.text(saved.amount, currency: saved.currency, language: language))을 넣었어요.", "Added \(saved.title) \(LedgerMoney.text(saved.amount, currency: saved.currency, language: language)).")
        } else {
            notice = language.text("금액을 읽지 못해 아직 넣지 않았어요. AI가 규칙을 보내면 다시 읽어 넣어요.", "Couldn't read the amount yet. It is read again when your AI sends a rule.")
        }
        var context = ["choice": kind.rawValue]
        if let source = item.source { context["app"] = source }
        if !item.ruleRequested, AITaskQueue.enqueue(.paymentRule, text: item.text, day: item.receivedAt, context: context) {
            item.ruleRequested = true
            await AITaskQueue.upload()
            notice += " " + language.text("AI에게 같은 모양의 규칙을 부탁했어요.", "Asked your AI for a rule for this layout.")
        }
        PaymentInbox.update(item)
        return (item, notice)
    }

    /// 「내부」(INT1114A01, 대표 지시): 내 계좌 사이 거래·지역카드 충전·교통카드 충전 같은 내부 이체. 지출도 수입도 아니므로
    /// 가계부에 넣지 않고, 이 글로 이미 들어간 기록이 있으면 지운다. AI에게는 같은 모양을 넣지 않는 규칙을 부탁한다.
    @MainActor
    static func applyInternal(to item: PaymentInbox.Item, language: MapHomeLanguage) async -> (PaymentInbox.Item, String) {
        var item = item
        item.choice = .ignore
        item.isInternal = true
        var notice = language.text("내부 이체로 정했어요. 지출·수입에 넣지 않아요.", "Marked as an internal transfer. It isn't counted as spending or income.")
        if item.outcome == .added {
            await LedgerBook.shared.load()
            if let entry = addedEntry(for: item, in: LedgerBook.shared.entries) {
                await LedgerBook.shared.remove(entry)
                notice += " " + language.text("가계부에 들어갔던 기록은 지웠어요.", "The entry already added was removed.")
            } else {
                notice += " " + language.text("이미 들어간 기록은 가계부에서 지워 주세요.", "Delete the entry already added from the ledger.")
            }
        }
        item.outcome = .skipped
        item.message = language.text("내부 이체라 가계부에 넣지 않았어요.", "Internal transfer: not added to the ledger.")
        var context = ["choice": LedgerMessageRules.Kind.ignore.rawValue, "reason": "internal transfer between the user's own accounts or a prepaid/local-currency/transit card top-up"]
        if let source = item.source { context["app"] = source }
        if !item.ruleRequested, AITaskQueue.enqueue(.paymentRule, text: item.text, day: item.receivedAt, context: context) {
            item.ruleRequested = true
            await AITaskQueue.upload()
            notice += " " + language.text("AI에게 같은 모양의 규칙을 부탁했어요.", "Asked your AI for a rule for this layout.")
        }
        PaymentInbox.update(item)
        return (item, notice)
    }

    /// 이 글로 들어간 가계부 기록: 결제 문자·AI로 들어온 같은 금액의 기록 가운데 받은 때 앞뒤 10분 안에 만들어진 것.
    static func addedEntry(for item: PaymentInbox.Item, in entries: [LedgerEntry]) -> LedgerEntry? {
        guard let amount = LedgerMessageParser.amount(item.text)?.value else { return nil }
        return entries
            .filter { $0.source != .manual && $0.amount == amount && abs($0.createdAt.timeIntervalSince(item.receivedAt)) <= 600 }
            .min { abs($0.createdAt.timeIntervalSince(item.receivedAt)) < abs($1.createdAt.timeIntervalSince(item.receivedAt)) }
    }

    /// 앱 규칙으로 읽은 금액·가게로 기록을 만든다. 시각은 받은 때다.
    static func entry(for item: PaymentInbox.Item, income: Bool) -> LedgerEntry? {
        let draft: LedgerMessageParser.Draft?
        if case let .draft(found, _) = LedgerMessageRules.match(item.text, now: item.receivedAt) {
            draft = found
        } else {
            draft = LedgerMessageParser.parse(item.text, now: item.receivedAt)
                ?? LedgerMessageParser.amount(item.text).map { .init(amount: $0.value, currency: $0.currency, merchant: nil, card: nil, occurredAt: nil, isCancel: false) }
        }
        guard var value = draft else { return nil }
        if value.occurredAt == nil { value.occurredAt = item.receivedAt }
        value.isCancel = false
        var entry = LedgerMessageParser.entry(value, now: item.receivedAt)
        entry.kind = income ? .income : .expense
        if value.merchant == nil, let source = item.source { entry.title = source }
        return entry
    }
}

/// 단축어 안내의 「결제 알림 받기」 줄. 시트를 이 줄에 단다.
struct PaymentAlertSourcesRow: View {
    let language: MapHomeLanguage
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            Label(language.text("앱마다 넣을 알림 고르기", "Choose alerts per app"), systemImage: "slider.horizontal.3")
        }
        .sheet(isPresented: $isPresented) {
            NavigationStack {
                PaymentAlertSourcesView(language: language)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(language.text("완료", "Done")) { isPresented = false } } }
            }
        }
    }
}

/// 받은 글 화면의 「이 알림은」 칸(PAS1113A01).
struct PaymentInboxChoiceSection: View {
    let language: MapHomeLanguage
    @Binding var item: PaymentInbox.Item
    @Binding var notice: String?

    var body: some View {
        Section {
            HStack(spacing: 6) {
                choice(.expense, language.text("지출", "Spending"), "arrow.up.right")
                choice(.income, language.text("수입", "Income"), "arrow.down.left")
                internalChoice
                choice(.ignore, language.text("넣지 않음", "Skip"), "nosign")
            }
            .buttonStyle(.plain)
        } header: {
            Text(item.source.map { language.text("이 알림은 · \($0)", "This alert · \($0)") } ?? language.text("이 글은", "This text is"))
        } footer: {
            Text(language.text("고르면 이 글은 바로 그렇게 처리하고, 연결된 AI가 같은 모양의 글을 앞으로 그렇게 읽는 규칙을 만들어요.", "Your choice applies to this text now, and your AI makes a rule so texts like it are read the same way."))
        }
    }

    /// 「내부」: 내 계좌 사이 이체·지역카드·교통카드 충전(INT1114A01).
    private var internalChoice: some View {
        let isOn = item.isInternal == true
        return Button {
            Task {
                let (updated, message) = await PaymentInboxChoice.applyInternal(to: item, language: language)
                item = updated
                notice = message
            }
        } label: {
            Label(language.text("내부", "Internal"), systemImage: "arrow.left.arrow.right")
                .font(.taptionStyle(.subheadline, weight: .medium))
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 40)
                .foregroundStyle(isOn ? Color.white : Color.tpInk)
                .background(isOn ? Color.tpAccent : Color.tpCard, in: RoundedRectangle(cornerRadius: TaptionCorner.small, style: .continuous))
        }
        .accessibilityIdentifier("paymentInboxChoice-internal")
        .accessibilityHint(language.text("내 계좌 사이 이체나 카드 충전", "A transfer between your own accounts or a card top-up"))
    }

    private func choice(_ kind: LedgerMessageRules.Kind, _ title: String, _ symbol: String) -> some View {
        let isOn = item.choice == kind && (kind != .ignore || item.isInternal != true)
        return Button {
            Task {
                let (updated, message) = await PaymentInboxChoice.apply(kind, to: item, language: language)
                item = updated
                notice = message
            }
        } label: {
            Label(title, systemImage: symbol)
                .font(.taptionStyle(.subheadline, weight: .medium))
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 40)
                .foregroundStyle(isOn ? Color.white : Color.tpInk)
                .background(isOn ? Color.tpAccent : Color.tpCard, in: RoundedRectangle(cornerRadius: TaptionCorner.small, style: .continuous))
        }
        .accessibilityIdentifier("paymentInboxChoice-\(kind.rawValue)")
    }
}

#if DEBUG
/// 화면 확인용(PAS1113A01, Debug 전용): `-paymentAlertPreview`는 앱별 스위치 화면, 뒤에 `inbox`를 붙이면 받은 알림 화면.
/// 시뮬레이터에서만 쓴다. 보기 앱 두 개를 목록에 넣는다.
struct PaymentAlertPreviewHost: View {
    let showsInbox: Bool
    private let language = MapHomeLanguage.current

    init(showsInbox: Bool) {
        self.showsInbox = showsInbox
        PaymentAlertSources.seen("인천e음")
        PaymentAlertSources.seen("토스")
    }

    var body: some View {
        if showsInbox {
            PaymentInboxDetail(language: language, item: .init(
                text: "결제 완료 5,000원 씨유(CU) 예시점 서로e음 카드(교통) 총 보유 잔액 12,345원",
                receivedAt: .now, outcome: .skipped, message: "인천e음 알림의 지출은 넣지 않게 해 두었어요.", source: "인천e음"
            ))
        } else {
            NavigationStack { PaymentAlertSourcesView(language: language) }
        }
    }
}
#endif
