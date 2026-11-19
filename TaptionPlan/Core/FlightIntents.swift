import AppIntents
import Foundation

/// 단축어 동작 「항공 알림 넣기」(FLT1119A01). 항공사 문자·알림톡 내용을 읽어 여행의 항공편 카드에 붙인다.
/// 단축어 자동화 「메시지를 받을 때」(SMS)나 「알림 › 앱 푸시」에 걸어 쓴다. 카카오톡 알림톡이 「알림 › 앱 푸시」로 잡히는지는
/// 기기에서 확인하는 항목이고, 안 되면 복사 → 붙여넣기 배너나 공유로 넣는다. 읽기만 하고 예약·결제·취소는 하지 않는다.
struct AddFlightAlertIntent: AppIntent {
    static let title: LocalizedStringResource = "항공 알림 넣기"
    static let description = IntentDescription("항공사 문자·알림톡을 읽어 BOKKI Plan 여행의 항공편 카드에 붙여요. 읽기만 하고 예약·결제는 하지 않아요.")
    static let openAppWhenRun = false

    @Parameter(title: "알림 내용", inputConnectionBehavior: .connectToPreviousIntentResult)
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: await FlightIntentRunner.run(text)))
    }
}

@MainActor
enum FlightIntentRunner {
    /// 처리하고 답변 문구를 돌려준다. 앱 모델이 아직 준비되지 않았으면 읽을 수 있는 글만 보관함에 두었다가 앱이 열릴 때 붙인다.
    static func run(_ text: String, now: Date = .now) async -> String {
        let language = MapHomeLanguage.current
        guard let model = AppModel.live, model.isBootstrapped else {
            guard FlightIngest.looksLikeFlightAlert(text, now: now) else { return FlightIngest.message(for: .unreadable, language: language) }
            FlightInbox.stash(text, now: now)
            return language.text("받았어요. 앱을 열면 카드에 붙일게요.", "Got it. I'll attach it to the card when the app opens.")
        }
        let reply = await model.ingestFlightAlert(text, source: .intent, now: now)
        FlightAlertCenter.shared.show(reply)
        return FlightIngest.message(for: reply, language: language)
    }
}

/// 단축어 동작 「글을 일정으로 넣기」(FLT1119A01 확장). 단축어 자동화 「메시지를 받을 때」에서 받은 문자 가운데
/// 항공 알림이면 항공편 카드에 붙이고, 아니면 기기에서 일정으로 읽거나(날짜·시각이 모두 있을 때) 연결된 AI에게 맡기고, AI가 없으면 메모로 남긴다.
/// 앱이 아직 준비되지 않았으면 공유 확장과 같은 보관함에 두었다가 앱이 열릴 때 처리한다.
struct AddSharedTextIntent: AppIntent {
    static let title: LocalizedStringResource = "글을 일정으로 넣기"
    static let description = IntentDescription("받은 문자나 메시지 글을 읽어 BOKKI Plan 일정이나 항공편 카드로 넣어요. 못 읽으면 연결된 AI에게 맡기고, AI가 없으면 메모로 남겨요.")
    static let openAppWhenRun = false

    @Parameter(title: "글 내용", inputConnectionBehavior: .connectToPreviousIntentResult)
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: await SharedTextIntentRunner.run(text)))
    }
}

@MainActor
enum SharedTextIntentRunner {
    static func run(_ text: String, now: Date = .now, container: URL? = nil) async -> String {
        let language = MapHomeLanguage.current
        guard let model = AppModel.live, model.isBootstrapped else {
            guard FlightShareStore.enqueue(text: text, now: now, container: container) else { return FlightIngest.message(for: .unreadable, language: language) }
            return language.text("받았어요. 앱을 열면 일정으로 넣을게요.", "Got it. I'll add it to your schedule when the app opens.")
        }
        var reply = await model.ingestFlightAlert(text, source: .intent, now: now)
        if case .unreadable = reply { reply = await model.routeSharedText(text, now: now) }
        FlightAlertCenter.shared.show(reply)
        return FlightIngest.message(for: reply, language: language)
    }
}
