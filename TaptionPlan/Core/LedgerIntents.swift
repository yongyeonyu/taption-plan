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
        let language = MapHomeLanguage.current
        guard let draft = LedgerMessageParser.parse(text), draft.occurredAt != nil else {
            // 광고·안내가 아니면 연결된 AI에게 맡긴다(AIQ1111A01). 번호는 가려서 보낸다.
            if !LedgerMessageParser.isNotice(text), AITaskQueue.enqueue(.paymentText, text: text, day: .now) {
                await AITaskQueue.upload()
                return .result(dialog: IntentDialog(stringLiteral: language.text(
                    "결제 문자를 읽지 못해 AI에게 확인을 맡겼어요.", "Couldn't read the payment text, so it was sent to your AI to check."
                )))
            }
            return .result(dialog: IntentDialog(stringLiteral: language.text(
                "결제 문자를 읽지 못했어요. 가계부에서 직접 넣어 주세요.", "Couldn't read the payment text. Add it in the ledger yourself."
            )))
        }
        let saved = await LedgerBook.shared.save(LedgerMessageParser.entry(draft))
        // 앱이 먼저 넣고, 연결된 AI가 가게 이름·분류·취소 연결을 다듬는다(AIQ1111A01, 대표 결정).
        if AITaskQueue.enqueue(.paymentText, text: text, day: saved.occurredAt, context: ["entryId": saved.id.uuidString]) {
            await AITaskQueue.upload()
        }
        let money = LedgerMoney.text(saved.amount, currency: saved.currency, language: language)
        return .result(dialog: IntentDialog(stringLiteral: language.text(
            "\(saved.title) \(money)을 가계부에 넣었어요.", "Added \(saved.title) \(money) to the ledger."
        )))
    }
}

/// Siri·단축어 앱에 바로 보이는 동작(SIR1111A01). 앱 하나당 10개까지다.
struct BokkiShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddPaymentMessageIntent(),
            phrases: ["\(.applicationName) 결제 문자 넣기", "Add payment text to \(.applicationName)"],
            shortTitle: "결제 문자 넣기",
            systemImageName: "creditcard"
        )
        AppShortcut(
            intent: AddMemoIntent(),
            phrases: ["\(.applicationName)에 메모 남겨", "\(.applicationName) 메모", "Add a memo in \(.applicationName)"],
            shortTitle: "메모 남기기",
            systemImageName: "note.text"
        )
        AppShortcut(
            intent: CheckInIntent(),
            phrases: ["\(.applicationName) \(\.$moment) 기록", "\(.applicationName)에 \(\.$moment) 남겨", "Log \(\.$moment) in \(.applicationName)"],
            shortTitle: "지금 순간 기록",
            systemImageName: "clock.badge.checkmark"
        )
        AppShortcut(
            intent: AddExpenseIntent(),
            phrases: ["\(.applicationName) 지출 기록", "\(.applicationName)에 지출 넣어", "Add an expense in \(.applicationName)"],
            shortTitle: "지출 기록",
            systemImageName: "wonsign.circle"
        )
        AppShortcut(
            intent: AddReceiptIntent(),
            phrases: ["\(.applicationName) 영수증 넣기", "Add a receipt to \(.applicationName)"],
            shortTitle: "영수증 넣기",
            systemImageName: "doc.text.viewfinder"
        )
        AppShortcut(
            intent: AskAIIntent(),
            phrases: ["\(.applicationName) AI에게 맡겨", "Ask \(.applicationName) AI"],
            shortTitle: "AI에게 맡기기",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: TodaySpendingIntent(),
            phrases: ["\(.applicationName) 오늘 얼마 썼어", "\(.applicationName) 오늘 지출", "How much did I spend today in \(.applicationName)"],
            shortTitle: "오늘 지출",
            systemImageName: "chart.bar"
        )
        AppShortcut(
            intent: TodayStepsIntent(),
            phrases: ["\(.applicationName) 오늘 몇 걸음", "\(.applicationName) 걸음 수", "Steps today in \(.applicationName)"],
            shortTitle: "오늘 걸음 수",
            systemImageName: "figure.walk"
        )
        AppShortcut(
            intent: CurrentActivityIntent(),
            phrases: ["\(.applicationName) 지금 뭐로 기록돼", "\(.applicationName) 지금 기록", "What is \(.applicationName) recording now"],
            shortTitle: "지금 기록",
            systemImageName: "waveform.path.ecg"
        )
        AppShortcut(
            intent: OpenScreenIntent(),
            phrases: ["\(.applicationName) \(\.$screen) 열어", "Open \(\.$screen) in \(.applicationName)"],
            shortTitle: "화면 열기",
            systemImageName: "rectangle.portrait.on.rectangle.portrait"
        )
    }
}
