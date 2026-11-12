import AppIntents
import Foundation

/// 단축어 동작 「결제 문자 넣기」(LED1110A01). 단축어 「메시지를 받을 때」 자동화가 카드사 문자를 넘기면
/// 앱을 열지 않고 가계부에 넣는다. 읽지 못한 글은 넣지 않고 그렇다고 답한다.
struct AddPaymentMessageIntent: AppIntent {
    static let title: LocalizedStringResource = "결제 문자 넣기"
    static let description = IntentDescription("카드 결제 문자를 BOKKI Plan 가계부에 넣어요.")
    static let openAppWhenRun = false

    /// 단축어 자동화 「메시지를 받을 때」의 받은 메시지가 바로 이어지게 한다(대표 신고: 넣을 내용이 비어 있음).
    @Parameter(title: "문자 내용", inputConnectionBehavior: .connectToPreviousIntentResult)
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // 묻지 않고 넣는 길이라 결제 시각까지 읽힌 문자만 넣는다.
        .result(dialog: IntentDialog(stringLiteral: await PaymentTextCapture.capture(text, requiresTime: true)))
    }
}

/// 단축어 동작 「결제 알림 넣기」(SHT1111A01). iOS 27 단축어 자동화 「알림 › 앱 푸시」에서 은행·카드 앱 알림을 넘기면
/// 가계부에 넣는다. 알림은 받은 때가 곧 결제 시각이라 시각이 없어도 지금으로 넣는다.
struct AddPaymentNotificationIntent: AppIntent {
    static let title: LocalizedStringResource = "결제 알림 넣기"
    static let description = IntentDescription("은행·카드 앱의 결제·출금 알림을 BOKKI Plan 가계부에 넣어요. 단축어 자동화 「알림 › 앱 푸시」에 걸어 쓰세요.")
    static let openAppWhenRun = false

    @Parameter(title: "알림 내용", inputConnectionBehavior: .connectToPreviousIntentResult)
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: await PaymentTextCapture.capture(text, requiresTime: false)))
    }
}

/// 결제 문자·알림 공통 처리(AIQ1111A01·SHT1111A01): 앱이 읽으면 바로 넣고 AI가 다듬으며, 못 읽으면 AI에게 맡긴다.
@MainActor
enum PaymentTextCapture {
    /// 넘어온 글을 처리하고 결과를 받은 문자함에 남긴다(PRL1112A01). 「AI」 탭이 이것을 보여 준다.
    static func capture(_ text: String, requiresTime: Bool, now: Date = .now) async -> String {
        // 「BOKKI 결제」는 낱말마다 트리거가 있어 한 문자가 여러 번 넘어온다. 같은 글은 한 번만 처리한다(NTF1112A01).
        if let earlier = repeated(text, now: now) { return earlier }
        inFlight[PaymentInbox.stored(text)] = now
        let (message, outcome) = await process(text, requiresTime: requiresTime, now: now)
        PaymentInbox.record(text, outcome: outcome, message: message, now: now)
        return message
    }

    static let repeatWindow: TimeInterval = 120
    private static var inFlight: [String: Date] = [:]

    /// 방금(2분 안) 같은 글을 받았으면 그때의 안내를 돌려준다. 처리 중인 글이면 빈 안내.
    static func repeated(_ text: String, now: Date, defaults: UserDefaults = .standard) -> String? {
        let key = PaymentInbox.stored(text)
        inFlight = inFlight.filter { abs(now.timeIntervalSince($0.value)) < repeatWindow }
        if let earlier = PaymentInbox.items(defaults, now: now).last(where: { $0.text == key && abs(now.timeIntervalSince($0.receivedAt)) < repeatWindow }) {
            return earlier.message
        }
        return inFlight[key] == nil ? nil : ""
    }

    static func process(_ text: String, requiresTime: Bool, now: Date = .now) async -> (String, PaymentInbox.Outcome) {
        let language = MapHomeLanguage.current
        // AI가 보탠 규칙이 먼저다. 앱 규칙이 못 읽거나 잘못 읽는 형식을 고치려고 넣은 것이기 때문이다.
        if let match = LedgerMessageRules.match(text, now: now) {
            guard case let .draft(draft, income) = match else {
                return (language.text("가계부에 넣지 않는 문자예요.", "This kind of text is not added to the ledger."), .skipped)
            }
            var entry = LedgerMessageParser.entry(draft, now: now)
            if income { entry.kind = .income }
            await LedgerBook.shared.load()
            guard LedgerMessageParser.duplicateVerdict(entry, in: LedgerBook.shared.entries) == .none else {
                return (language.text("이미 가계부에 넣은 결제예요.", "That payment is already in the ledger."), .duplicate)
            }
            let saved = await LedgerBook.shared.save(entry)
            let money = LedgerMoney.text(saved.amount, currency: saved.currency, language: language)
            return (language.text("\(saved.title) \(money)을 가계부에 넣었어요.", "Added \(saved.title) \(money) to the ledger."), .added)
        }
        // 급여 입금은 수입으로 넣는다(LIN1111A01). 그 밖의 입금은 넣지 않는다.
        if let salary = LedgerMessageParser.salaryDeposit(text, now: now) {
            await LedgerBook.shared.load()
            guard LedgerMessageParser.duplicateVerdict(salary, in: LedgerBook.shared.entries) == .none else {
                return (language.text("이미 가계부에 넣은 입금이에요.", "That deposit is already in the ledger."), .duplicate)
            }
            let saved = await LedgerBook.shared.save(salary)
            let money = LedgerMoney.text(saved.amount, currency: saved.currency, language: language)
            return (language.text("\(saved.title) \(money)을 수입으로 넣었어요.", "Added \(saved.title) \(money) as income."), .added)
        }
        // 자동화는 결제가 아닌 문자·알림도 넘긴다. 그런 글은 넣지도 AI에게 보내지도 않는다(SMA1111A01).
        guard LedgerMessageParser.isPaymentCandidate(text) else {
            return (language.text("가계부에 넣을 결제 문자가 아니에요.", "Not a payment message, so nothing was added."), .skipped)
        }
        // 등록한 내 계좌로 옮기는 돈은 지출이 아니다(LIN1111A01).
        if LedgerOwnAccounts.isOwnTransfer(text, names: LedgerOwnAccounts.names()) {
            return (language.text("내 계좌로 옮긴 돈이라 가계부에 넣지 않았어요.", "That was a transfer to your own account, so nothing was added."), .skipped)
        }
        guard var draft = LedgerMessageParser.parse(text, now: now), !requiresTime || draft.occurredAt != nil else {
            // 광고·안내가 아니면 연결된 AI에게 맡긴다. 번호는 가려서 보낸다.
            if !LedgerMessageParser.isNotice(text), AITaskQueue.enqueue(.paymentText, text: text, day: now) {
                await AITaskQueue.upload()
                return (language.text("결제 문자를 읽지 못해 AI에게 확인을 맡겼어요.", "Couldn't read the payment text, so it was sent to your AI to check."), .askedAI)
            }
            return (language.text("결제 문자를 읽지 못했어요. 가계부에서 직접 넣어 주세요.", "Couldn't read the payment text. Add it in the ledger yourself."), .unread)
        }
        if draft.occurredAt == nil { draft.occurredAt = now }
        let entry = LedgerMessageParser.entry(draft)
        await LedgerBook.shared.load()
        let money = LedgerMoney.text(entry.amount, currency: entry.currency, language: language)
        // 취소 문자는 원래 결제를 찾아 「취소됨」으로 표시한다. 못 찾으면 예전처럼 환불 수입으로 넣는다(LCN1111A01).
        if draft.isCancel, var original = LedgerMessageParser.canceledOriginal(for: entry, in: LedgerBook.shared.entries) {
            original.canceledAt = entry.occurredAt
            await LedgerBook.shared.save(original)
            return (language.text("\(original.title) \(money) 결제를 취소됨으로 표시했어요.", "Marked \(original.title) \(money) as canceled."), .added)
        }
        switch LedgerMessageParser.duplicateVerdict(entry, in: LedgerBook.shared.entries) {
        case .same:
            return (language.text("이미 가계부에 넣은 결제예요.", "That payment is already in the ledger."), .duplicate)
        case .suspect:
            // 10분 안 같은 금액의 다른 가게: 조용히 버리지 않고 확인 필요에 둔다(LRV1111A01).
            LedgerReviewStore.shared.add(entry, reason: .duplicate, now: now)
            return (language.text("방금 같은 금액의 결제가 있어 「확인 필요」에 두었어요.", "A payment of the same amount was just added, so this one is waiting in Needs review."), .review)
        case .none:
            break
        }
        if !draft.isCancel, draft.merchant == nil || LedgerMessageParser.looksLikeCardBill(text, merchant: draft.merchant) {
            // 가게 이름을 못 읽었으면 조용히 넣지 않는다. 이체 낱말이 있으면 이체 의심, 카드사로 나간 출금은 카드 대금으로 둔다.
            let reason: LedgerReviewStore.Reason = draft.merchant != nil ? .cardBill : LedgerMessageParser.looksLikeTransfer(text) ? .transfer : .noMerchant
            LedgerReviewStore.shared.add(entry, reason: reason, now: now)
            return (language.text("\(money) 결제를 「확인 필요」에 두었어요. 메모 › 지출에서 넣거나 버릴 수 있어요.", "\(money) is waiting in Needs review. Add or discard it in Memo › Spending."), .review)
        }
        let saved = await LedgerBook.shared.save(entry)
        // 앱이 먼저 넣고, 연결된 AI가 가게 이름·분류를 다듬는다(대표 결정).
        if AITaskQueue.enqueue(.paymentText, text: text, day: saved.occurredAt, context: ["entryId": saved.id.uuidString]) {
            await AITaskQueue.upload()
        }
        return (language.text("\(saved.title) \(money)을 가계부에 넣었어요.", "Added \(saved.title) \(money) to the ledger."), .added)
    }
}

/// Siri·단축어 앱에 바로 보이는 동작(SIR1111A01). 앱 하나당 10개까지라 묶어서 두고, 말하는 방식은 문구를 여러 개로 받는다(SHT1111A01).
/// 「결제 알림 넣기」는 자동화용이라 여기 없이 단축어 동작 목록에만 있다.
struct BokkiShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddPaymentMessageIntent(),
            phrases: [
                "\(.applicationName) 결제 문자 넣기",
                "\(.applicationName) 결제 문자 저장",
                "Add payment text to \(.applicationName)",
            ],
            shortTitle: "결제 문자 넣기",
            systemImageName: "creditcard"
        )
        AppShortcut(
            intent: AddMemoIntent(),
            phrases: [
                "\(.applicationName)에 저장",
                "\(.applicationName)에 저장해 줘",
                "\(.applicationName)에 기록해",
                "\(.applicationName)에 적어 줘",
                "\(.applicationName)에 메모 남겨",
                "\(.applicationName)에 메모해 줘",
                "\(.applicationName) 메모",
                "Save to \(.applicationName)",
                "Add a memo in \(.applicationName)",
                "Note in \(.applicationName)",
            ],
            shortTitle: "BOKKI Plan에 저장",
            systemImageName: "note.text"
        )
        AppShortcut(
            intent: CheckInIntent(),
            phrases: [
                "\(.applicationName) \(\.$moment) 기록",
                "\(.applicationName)에 \(\.$moment) 남겨",
                "\(.applicationName) \(\.$moment)",
                "\(.applicationName)에 \(\.$moment) 적어 줘",
                "Log \(\.$moment) in \(.applicationName)",
                "\(.applicationName) \(\.$moment) now",
            ],
            shortTitle: "지금 순간 기록",
            systemImageName: "clock.badge.checkmark"
        )
        AppShortcut(
            intent: AddExpenseIntent(),
            phrases: [
                "\(.applicationName) 지출 기록",
                "\(.applicationName)에 지출 넣어",
                "\(.applicationName) 가계부에 적어",
                "\(.applicationName)에 쓴 돈 기록해",
                "\(.applicationName) 결제 기록",
                "Add an expense in \(.applicationName)",
                "Log spending in \(.applicationName)",
            ],
            shortTitle: "지출 기록",
            systemImageName: "wonsign.circle"
        )
        AppShortcut(
            intent: AddReceiptIntent(),
            phrases: [
                "\(.applicationName) 영수증 넣기",
                "\(.applicationName) 영수증 저장",
                "\(.applicationName)에 영수증 올려",
                "Add a receipt to \(.applicationName)",
            ],
            shortTitle: "영수증 넣기",
            systemImageName: "doc.text.viewfinder"
        )
        AppShortcut(
            intent: AskAIIntent(),
            phrases: [
                "\(.applicationName) AI에게 맡겨",
                "\(.applicationName) AI한테 물어봐",
                "\(.applicationName) AI에게 확인 부탁해",
                "Ask \(.applicationName) AI",
            ],
            shortTitle: "AI에게 맡기기",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: TodaySpendingIntent(),
            phrases: [
                "\(.applicationName) 오늘 얼마 썼어",
                "\(.applicationName) 오늘 지출",
                "\(.applicationName) 오늘 지출 얼마야",
                "\(.applicationName) 오늘 쓴 돈",
                "How much did I spend today in \(.applicationName)",
            ],
            shortTitle: "오늘 지출",
            systemImageName: "chart.bar"
        )
        AppShortcut(
            intent: TodayStepsIntent(),
            phrases: [
                "\(.applicationName) 오늘 몇 걸음",
                "\(.applicationName) 걸음 수",
                "\(.applicationName) 오늘 얼마나 걸었어",
                "Steps today in \(.applicationName)",
            ],
            shortTitle: "오늘 걸음 수",
            systemImageName: "figure.walk"
        )
        AppShortcut(
            intent: CurrentActivityIntent(),
            phrases: [
                "\(.applicationName) 지금 뭐로 기록돼",
                "\(.applicationName) 지금 기록",
                "\(.applicationName) 지금 뭐 하는 중이야",
                "\(.applicationName) 지금 상태",
                "What is \(.applicationName) recording now",
            ],
            shortTitle: "지금 기록",
            systemImageName: "waveform.path.ecg"
        )
        AppShortcut(
            intent: OpenScreenIntent(),
            phrases: [
                "\(.applicationName) \(\.$screen) 열어",
                "\(.applicationName) \(\.$screen) 보여 줘",
                "\(.applicationName)에서 \(\.$screen) 열어",
                "Open \(\.$screen) in \(.applicationName)",
                "Show \(\.$screen) in \(.applicationName)",
            ],
            shortTitle: "화면 열기",
            systemImageName: "rectangle.portrait.on.rectangle.portrait"
        )
    }
}

extension PaymentInbox {
    /// 규칙이 생긴 뒤 못 읽었던 글을 다시 읽는다(PRL1112A01). 가계부에 들어간 건수를 돌려준다.
    @MainActor
    static func reprocess(now: Date = .now) async -> Int {
        var added = 0
        for var item in readable(now: now) {
            let (message, outcome) = await PaymentTextCapture.process(item.text, requiresTime: false, now: item.receivedAt)
            item.outcome = outcome
            item.message = message
            update(item)
            if outcome == .added { added += 1 }
        }
        return added
    }
}
