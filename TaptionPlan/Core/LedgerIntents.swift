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

struct BokkiShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddPaymentMessageIntent(),
            phrases: ["\(.applicationName) 결제 문자 넣기", "Add payment text to \(.applicationName)"],
            shortTitle: "결제 문자 넣기",
            systemImageName: "creditcard"
        )
    }
}
