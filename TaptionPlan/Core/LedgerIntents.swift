import AppIntents
import Foundation

/// 단축어 동작 「결제 문자 넣기」(LED1110A01). 단축어 「메시지를 받을 때」 자동화가 카드사 문자를 넘기면
/// 앱을 열지 않고 가계부에 넣는다. 읽지 못한 글은 넣지 않고 그렇다고 답한다.
struct AddPaymentMessageIntent: AppIntent {
    static let title: LocalizedStringResource = "결제 문자 넣기"
    static let description = IntentDescription("카드 결제 문자를 BOKKI Plan 가계부에 넣어요.")
    static let openAppWhenRun = false

    @Parameter(title: "문자 내용")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let draft = LedgerMessageParser.parse(text) else {
            return .result(dialog: "결제 문자를 읽지 못했어요. 가계부에서 직접 넣어 주세요.")
        }
        let saved = await LedgerBook.shared.save(LedgerMessageParser.entry(draft))
        let money = LedgerMoney.text(saved.amount, currency: saved.currency, language: .current)
        return .result(dialog: "\(saved.title) \(money)을 가계부에 넣었어요.")
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
