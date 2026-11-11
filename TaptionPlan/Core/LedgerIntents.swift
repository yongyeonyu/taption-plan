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
    static func capture(_ text: String, requiresTime: Bool, now: Date = .now) async -> String {
        let language = MapHomeLanguage.current
        guard var draft = LedgerMessageParser.parse(text, now: now), !requiresTime || draft.occurredAt != nil else {
            // 광고·안내가 아니면 연결된 AI에게 맡긴다. 번호는 가려서 보낸다.
            if !LedgerMessageParser.isNotice(text), AITaskQueue.enqueue(.paymentText, text: text, day: now) {
                await AITaskQueue.upload()
                return language.text("결제 문자를 읽지 못해 AI에게 확인을 맡겼어요.", "Couldn't read the payment text, so it was sent to your AI to check.")
            }
            return language.text("결제 문자를 읽지 못했어요. 가계부에서 직접 넣어 주세요.", "Couldn't read the payment text. Add it in the ledger yourself.")
        }
        if draft.occurredAt == nil { draft.occurredAt = now }
        let saved = await LedgerBook.shared.save(LedgerMessageParser.entry(draft))
        // 앱이 먼저 넣고, 연결된 AI가 가게 이름·분류·취소 연결을 다듬는다(대표 결정).
        if AITaskQueue.enqueue(.paymentText, text: text, day: saved.occurredAt, context: ["entryId": saved.id.uuidString]) {
            await AITaskQueue.upload()
        }
        let money = LedgerMoney.text(saved.amount, currency: saved.currency, language: language)
        return language.text("\(saved.title) \(money)을 가계부에 넣었어요.", "Added \(saved.title) \(money) to the ledger.")
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
