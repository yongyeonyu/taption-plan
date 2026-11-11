import AppIntents
import Foundation
import HealthKit
import UIKit

// Siri·단축어로 앱에 바로 닿는 동작(SIR1111A01, 대표 지시: 되는 것 전부).
// 기록을 바꾸는 동작은 앱이 떠 있으면 바로 반영하고, 아니면 `SiriInbox`에 두었다가 앱이 열릴 때 반영한다.

// MARK: 기록·메모

struct AddMemoIntent: AppIntent {
    static let title: LocalizedStringResource = "메모 남기기"
    static let description = IntentDescription("지금 시각으로 BOKKI Plan에 메모를 남겨요. 금액이 있으면 가계부에도 들어가요.")
    static let openAppWhenRun = false

    @Parameter(title: "메모", inputConnectionBehavior: .connectToPreviousIntentResult)
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let language = MapHomeLanguage.current
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result(dialog: IntentDialog(stringLiteral: language.text("남길 메모가 비어 있어요.", "The memo is empty.")))
        }
        await SiriInbox.addMemo(String(trimmed.prefix(TaptionPlanMemoRecord.maximumTextLength)), at: .now)
        return .result(dialog: IntentDialog(stringLiteral: language.text("메모를 남겼어요.", "Memo saved.")))
    }
}

/// 출근·퇴근·기상 같은 순간을 메모로 남긴다. 단축어 자동화(장소 도착·알람 끔·집중 모드)에 걸어 쓴다.
enum SiriCheckIn: String, AppEnum {
    case arriveWork, leaveWork, wakeUp, goToBed, goOut, comeHome

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "순간"
    static let caseDisplayRepresentations: [SiriCheckIn: DisplayRepresentation] = [
        .arriveWork: "출근", .leaveWork: "퇴근", .wakeUp: "기상", .goToBed: "취침", .goOut: "외출", .comeHome: "귀가",
    ]

    func memoText(_ language: MapHomeLanguage) -> String {
        switch self {
        case .arriveWork: language.text("출근", "Arrived at work")
        case .leaveWork: language.text("퇴근", "Left work")
        case .wakeUp: language.text("기상", "Woke up")
        case .goToBed: language.text("취침", "Went to bed")
        case .goOut: language.text("외출", "Went out")
        case .comeHome: language.text("귀가", "Came home")
        }
    }
}

struct CheckInIntent: AppIntent {
    static let title: LocalizedStringResource = "지금 순간 기록"
    static let description = IntentDescription("출근·퇴근·기상·취침·외출·귀가를 지금 시각으로 남겨요. 단축어 자동화에 걸어 두면 저절로 남아요.")
    static let openAppWhenRun = false

    @Parameter(title: "순간")
    var moment: SiriCheckIn

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let language = MapHomeLanguage.current
        let text = moment.memoText(language)
        await SiriInbox.addMemo(text, at: .now)
        return .result(dialog: IntentDialog(stringLiteral: language.text("\(text)을(를) 남겼어요.", "Saved: \(text).")))
    }
}

struct AddExpenseIntent: AppIntent {
    static let title: LocalizedStringResource = "지출 기록"
    static let description = IntentDescription("방금 쓴 돈을 가계부에 넣어요. 예: 커피 4500원")
    static let openAppWhenRun = false

    @Parameter(title: "금액(원)")
    var amount: Double

    @Parameter(title: "내용")
    var title: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let language = MapHomeLanguage.current
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard amount > 0, amount <= 1e10, !name.isEmpty else {
            return .result(dialog: IntentDialog(stringLiteral: language.text("금액과 내용을 알려 주세요.", "Tell me the amount and what it was for.")))
        }
        let saved = await LedgerBook.shared.save(LedgerEntry(
            occurredAt: .now, amount: amount, category: LedgerCategory.guess(name), title: String(name.prefix(60)), source: .manual
        ))
        let money = LedgerMoney.text(saved.amount, currency: saved.currency, language: language)
        return .result(dialog: IntentDialog(stringLiteral: language.text("\(saved.title) \(money)을 가계부에 넣었어요.", "Added \(saved.title) \(money) to the ledger.")))
    }
}

/// 영수증 사진을 받아 읽는다. 읽히면 가계부에 넣고 AI가 다듬으며, 못 읽으면 AI에게 맡긴다(AIQ1111A01과 같은 길).
struct AddReceiptIntent: AppIntent {
    static let title: LocalizedStringResource = "영수증 넣기"
    static let description = IntentDescription("영수증 사진을 읽어 가계부에 넣어요. 공유 시트나 단축어에서 사진을 넘기면 돼요.")
    static let openAppWhenRun = false

    @Parameter(title: "영수증 사진", supportedContentTypes: [.image], inputConnectionBehavior: .connectToPreviousIntentResult)
    var photo: IntentFile

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let language = MapHomeLanguage.current
        guard let image = UIImage(data: photo.data)?.cgImage else {
            return .result(dialog: IntentDialog(stringLiteral: language.text("사진을 열지 못했어요.", "Couldn't open the photo.")))
        }
        let lines = await LedgerReceiptReader.recognize(image)
        guard let draft = LedgerReceiptReader.draft(lines) else {
            if AITaskQueue.enqueue(.receiptText, text: lines.joined(separator: "\n"), day: .now) {
                await AITaskQueue.upload()
                return .result(dialog: IntentDialog(stringLiteral: language.text("영수증을 읽지 못해 AI에게 맡겼어요.", "Couldn't read the receipt, so it was sent to your AI.")))
            }
            return .result(dialog: IntentDialog(stringLiteral: language.text("영수증을 읽지 못했어요.", "Couldn't read the receipt.")))
        }
        let saved = await LedgerBook.shared.save(LedgerMessageParser.entry(draft, source: .receipt))
        if AITaskQueue.enqueue(.receiptText, text: lines.joined(separator: "\n"), day: saved.occurredAt, context: ["entryId": saved.id.uuidString]) {
            await AITaskQueue.upload()
        }
        let money = LedgerMoney.text(saved.amount, currency: saved.currency, language: language)
        return .result(dialog: IntentDialog(stringLiteral: language.text("\(saved.title) \(money)을 가계부에 넣었어요.", "Added \(saved.title) \(money) to the ledger.")))
    }
}

/// 연결된 AI에게 확인을 맡긴다. 결과는 메모 › AI에서 본다.
struct AskAIIntent: AppIntent {
    static let title: LocalizedStringResource = "AI에게 맡기기"
    static let description = IntentDescription("확인할 내용을 연결된 AI에게 맡겨요. 처리되면 메모 › AI에 결과가 보여요.")
    static let openAppWhenRun = false

    @Parameter(title: "맡길 내용", inputConnectionBehavior: .connectToPreviousIntentResult)
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let language = MapHomeLanguage.current
        guard AITaskQueue.enqueue(.other, text: text, day: .now) else {
            return .result(dialog: IntentDialog(stringLiteral: language.text("AI 연결이 없거나 내용이 비어 있어요.", "No AI is connected, or the text is empty.")))
        }
        await AITaskQueue.upload()
        return .result(dialog: IntentDialog(stringLiteral: language.text("AI에게 맡겼어요. 메모 › AI에서 볼 수 있어요.", "Sent to your AI. See Memo › AI.")))
    }
}

// MARK: 물어보기

struct TodaySpendingIntent: AppIntent {
    static let title: LocalizedStringResource = "오늘 지출"
    static let description = IntentDescription("오늘 가계부 지출 합계를 알려 줘요.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let language = MapHomeLanguage.current
        let book = LedgerBook.shared
        await book.load()
        let today = book.entries.filter { Calendar.autoupdatingCurrent.isDateInToday($0.occurredAt) }
        let spent = LedgerBook.total(today, .expense)
        let money = LedgerMoney.text(spent, currency: "KRW", language: language)
        let count = today.filter { $0.kind == .expense }.count
        return .result(dialog: IntentDialog(stringLiteral: language.text("오늘 \(count)건, \(money) 썼어요.", "Today: \(count) entries, \(money) spent.")))
    }
}

struct TodayStepsIntent: AppIntent {
    static let title: LocalizedStringResource = "오늘 걸음 수"
    static let description = IntentDescription("건강 앱의 오늘 걸음 수를 알려 줘요.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let language = MapHomeLanguage.current
        guard let steps = await SiriHealth.todaySteps() else {
            return .result(dialog: IntentDialog(stringLiteral: language.text("걸음 수를 읽지 못했어요. 건강 앱 권한을 확인해 주세요.", "Couldn't read steps. Check Health access.")))
        }
        return .result(dialog: IntentDialog(stringLiteral: language.text("오늘 \(steps.formatted())걸음 걸었어요.", "\(steps.formatted()) steps today.")))
    }
}

struct CurrentActivityIntent: AppIntent {
    static let title: LocalizedStringResource = "지금 기록"
    static let description = IntentDescription("지금 무엇으로 기록되고 있는지 알려 줘요.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let language = MapHomeLanguage.current
        guard let item = SiriNowRecord.current() else {
            return .result(dialog: IntentDialog(stringLiteral: language.text("지금 기록된 활동이 없어요.", "Nothing is being recorded right now.")))
        }
        let since = item.startsAt.formatted(date: .omitted, time: .shortened)
        return .result(dialog: IntentDialog(stringLiteral: language.text("지금은 ‘\(item.title)’(\(since)부터)로 기록되고 있어요.", "Now recorded as “\(item.title)” since \(since).")))
    }
}

// MARK: 화면 열기

enum SiriScreen: String, AppEnum {
    case ledger, aiTasks, memos, dayCard, calendar

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "화면"
    static let caseDisplayRepresentations: [SiriScreen: DisplayRepresentation] = [
        .ledger: "가계부", .aiTasks: "AI 목록", .memos: "메모", .dayCard: "하루 카드", .calendar: "달력",
    ]
}

struct OpenScreenIntent: AppIntent {
    static let title: LocalizedStringResource = "화면 열기"
    static let description = IntentDescription("가계부·AI 목록·메모·하루 카드·달력을 바로 열어요.")
    static let openAppWhenRun = true

    @Parameter(title: "화면")
    var screen: SiriScreen

    @MainActor
    func perform() async throws -> some IntentResult {
        SiriNavigation.request(screen)
        return .result()
    }
}

// MARK: 도우미

/// 앱이 떠 있지 않을 때 받은 메모. 앱이 열리면 반영한다.
@MainActor
enum SiriInbox {
    struct Memo: Codable, Equatable, Sendable {
        var text: String
        var at: Date
    }

    static let key = "siriInboxMemos"

    static func pending(_ defaults: UserDefaults = .standard) -> [Memo] {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Memo].self, from: $0) } ?? []
    }

    /// 떠 있는 앱이 있으면 AI 메모와 같은 길(가계부 잇기 포함)로 바로, 없으면 쌓아 둔다.
    static func addMemo(_ text: String, at: Date, defaults: UserDefaults = .standard) async {
        if let model = AppModel.live, model.isBootstrapped {
            _ = await model.applyAssistantAction(.addMemo(text: text, at: at))
            return
        }
        var list = pending(defaults)
        list.append(Memo(text: text, at: at))
        if let data = try? JSONEncoder().encode(Array(list.suffix(50))) { defaults.set(data, forKey: key) }
    }

    /// 앱이 준비되면 부른다.
    static func drain(into model: AppModel, defaults: UserDefaults = .standard) async {
        let list = pending(defaults)
        guard !list.isEmpty, model.isBootstrapped else { return }
        defaults.removeObject(forKey: key)
        for memo in list { _ = await model.applyAssistantAction(.addMemo(text: memo.text, at: memo.at)) }
    }
}

/// 화면 열기 요청. 홈 화면이 받으면 그 화면을 연다.
@MainActor
enum SiriNavigation {
    static let notification = Notification.Name("bokki.siri.openScreen")
    /// 홈 화면이 아직 없을 때 받은 요청. 홈 화면이 나타나면 꺼내 쓴다.
    private(set) static var pending: SiriScreen?

    static func request(_ screen: SiriScreen) {
        pending = screen
        NotificationCenter.default.post(name: notification, object: nil)
    }

    static func take() -> SiriScreen? {
        defer { pending = nil }
        return pending
    }
}

/// 위젯과 같은 공유 자료에서 지금 시각의 기록을 찾는다(앱을 열지 않고 읽는다).
enum SiriNowRecord {
    static func current(now: Date = .now) -> TaptionWidgetItem? {
        let order: [TaptionWidgetLane: Int] = [.movement: 0, .activity: 1, .location: 2, .sleep: 3]
        return TaptionWidgetSharedStore.readWidgetPayload(now: now).items
            .filter { $0.startsAt <= now && now < $0.endsAt && order[$0.lane ?? .schedule] != nil }
            .min { (order[$0.lane ?? .schedule] ?? 9) < (order[$1.lane ?? .schedule] ?? 9) }
    }
}

enum SiriHealth {
    static func todaySteps(now: Date = .now) async -> Int? {
        guard HKHealthStore.isHealthDataAvailable(), let type = HKObjectType.quantityType(forIdentifier: .stepCount) else { return nil }
        let start = Calendar.autoupdatingCurrent.startOfDay(for: now)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: .strictStartDate)
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, statistics, _ in
                continuation.resume(returning: statistics?.sumQuantity().map { Int($0.doubleValue(for: .count())) })
            }
            HKHealthStore().execute(query)
        }
    }
}

extension AppModel {
    /// 떠 있는 앱 모델. Siri 동작이 앱을 열지 않고 바로 반영할 때 쓴다(SIR1111A01).
    @MainActor static weak var live: AppModel?
}
