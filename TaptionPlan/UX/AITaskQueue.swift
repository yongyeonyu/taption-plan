import Foundation
import UserNotifications

/// AI 확인 목록(AIQ1111A01). 앱이 처리하지 못했거나 불분명한 것을 서버 `/tasks`에 올리면
/// 연결된 AI가 가져가(처리중) 처리하고 완료·실패를 남긴다. AI 결과는 기존 명령(가계부·메모·기록)으로 바로 반영된다.
/// 원문의 카드·계좌·전화번호는 가리고 보낸다. 서버는 끝난 항목의 원문을 지우고, 길어도 7일 뒤 모두 지운다.
@MainActor
enum AITaskQueue {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case paymentText = "payment_text"
        case receiptText = "receipt_text"
        case memoPolish = "memo_polish"
        case routeCheck = "route_check"
        case fareCheck = "fare_check"
        case mergeReview = "merge_review"
        case stayPlace = "stay_place"
        /// 앱이 못 읽은 결제 문자: AI가 읽는 규칙(addPaymentRule)을 보내 달라는 부탁(PRL1112A01).
        case paymentRule = "payment_rule"
        /// 계획보다 밀렸거나 예산을 넘겨 남은 일정을 다시 짜 달라는 부탁(PVR1114A13).
        case replan
        case other

        /// 서버가 새 종류를 더해도 목록이 깨지지 않게 모르는 값은 `other`로 읽는다(AIP1114A05).
        init(from decoder: Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
        }
    }

    /// `asked`는 AI가 사용자에게 묻고 답을 기다리는 중, `expired`는 아무도 맡지 않고 기한(7일)이 지난 것(AIP1114A05).
    enum Status: String, Codable, Sendable {
        case waiting, processing, asked, done, failed, expired
        /// 이 앱이 모르는 새 상태.
        case unknown

        init(from decoder: Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }

        var isFinished: Bool { self == .done || self == .failed || self == .expired }
    }

    /// AI가 일을 끝내며 남긴 것: 보낸 명령·가계부 기록·규칙의 id, 기다리는 질문, 사용자가 봐야 하는지.
    struct Outcome: Codable, Equatable, Sendable {
        var commandIds: [String]?
        var entryIds: [String]?
        var ruleIds: [String]?
        var askedQuestionId: String?
        var needsUser: Bool?
    }

    struct Task: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var kind: Kind
        var text: String?
        var date: String?
        var status: Status
        var result: String?
        var reason: String?
        var createdAt: Date?
        var updatedAt: Date?
        /// 맡은 연결 키 id, 맡은 횟수, 끝낸 결과(`GET /tasks?v=2`). 예전 캐시에는 없다.
        var claimedBy: String?
        var attempts: Int?
        var outcome: Outcome?
    }

    /// 아직 서버에 못 올린 항목.
    struct Upload: Codable, Equatable, Sendable {
        var id: String
        var kind: Kind
        var text: String
        var date: String?
        var context: [String: String]?
    }

    static let uploadsKey = "aiTaskUploads"
    static let cacheKey = "aiTaskCache"
    static let uploadLimit = 20

    /// 서버가 이미 받은 일의 id(AIU1114A01). 응답을 못 받아 큐에 남은 일을 다시 올려 끝난 일을 되살리지 않게 한다.
    static let ackedKey = "aiTaskAcked"
    static let ackedLimit = 300

    static func acknowledge(_ ids: [String], defaults: UserDefaults = .standard) {
        guard !ids.isEmpty else { return }
        var acked = defaults.stringArray(forKey: ackedKey) ?? []
        let known = Set(acked)
        let fresh = ids.filter { !known.contains($0) }
        if !fresh.isEmpty {
            acked.append(contentsOf: fresh)
            defaults.set(Array(acked.suffix(ackedLimit)), forKey: ackedKey)
        }
        let done = Set(ids)
        let pending = pendingUploads(defaults)
        if pending.contains(where: { done.contains($0.id) }) { save(pending.filter { !done.contains($0.id) }, defaults) }
    }

    /// 아직 서버가 받지 않은 일만.
    static func unsent(_ defaults: UserDefaults = .standard) -> [Upload] {
        let acked = Set(defaults.stringArray(forKey: ackedKey) ?? [])
        return pendingUploads(defaults).filter { !acked.contains($0.id) }
    }

    static func pendingUploads(_ defaults: UserDefaults = .standard) -> [Upload] {
        defaults.data(forKey: uploadsKey).flatMap { try? JSONDecoder().decode([Upload].self, from: $0) } ?? []
    }

    /// 마지막으로 받은 서버 목록. 화면은 이것과 아직 못 올린 항목을 함께 보인다.
    static func cached(_ defaults: UserDefaults = .standard) -> [Task] {
        defaults.data(forKey: cacheKey).flatMap { try? decoder.decode([Task].self, from: $0) } ?? []
    }

    /// 못 올린 항목을 `POST /tasks`로 올린다. 실패하면 다음에 다시.
    static func upload(env: AssistantRegistration.Environment) async {
        let list = unsent(env.defaults)
        guard !list.isEmpty, let master = env.secrets.read(.master) else { return }
        let tasks: [[String: Any]] = list.map { item in
            var task: [String: Any] = ["id": item.id, "kind": item.kind.rawValue, "text": item.text]
            if let date = item.date { task["date"] = date }
            if let context = item.context { task["context"] = context }
            return task
        }
        let body = try? JSONSerialization.data(withJSONObject: ["format": "bokki-tasks", "version": 1, "tasks": tasks] as [String: Any])
        let request = body.flatMap { TripRelay.relayRequest("/tasks", method: "POST", body: $0, token: master, host: env.host, client: env.client()) }
        guard let reply = await TripRelay.send(request, session: env.session), (200..<300).contains(reply.status) else { return }
        acknowledge(list.map(\.id), defaults: env.defaults)
    }

    /// 서버 목록을 읽는다. 읽지 못한 항목 하나 때문에 나머지를 버리지 않는다.
    static func decodeList(_ data: Data) -> [Task] {
        (try? decoder.decode(Envelope.self, from: data))?.tasks ?? []
    }

    // MARK: 끝난 일 알림 (AIP1114A05)

    struct FinishedNews: Equatable, Sendable {
        var done = 0
        var failed = 0
        var isEmpty: Bool { done + failed == 0 }
    }

    static let finishedSeenKey = "aiTaskFinishedSeen"
    static let finishedSeenLimit = 300

    /// 지난번 뒤로 완료·실패가 된 일을 세고, 끝난 일의 id를 적어 둔다.
    /// 처음 돌 때(적어 둔 것이 없을 때)는 이미 끝나 있던 일을 세지 않는다. 기한이 지난 것은 적기만 한다.
    static func noteFinished(_ tasks: [Task], defaults: UserDefaults) -> FinishedNews {
        let stored = defaults.stringArray(forKey: finishedSeenKey)
        let seen = Set(stored ?? [])
        let fresh = tasks.filter { $0.status.isFinished && !seen.contains($0.id) }
        if stored == nil || !fresh.isEmpty {
            defaults.set(Array(((stored ?? []) + fresh.map(\.id)).suffix(finishedSeenLimit)), forKey: finishedSeenKey)
        }
        guard stored != nil else { return FinishedNews() }
        return FinishedNews(done: fresh.filter { $0.status == .done }.count, failed: fresh.filter { $0.status == .failed }.count)
    }

    /// 끝난 항목(완료·실패)을 서버에서 지운다.
    static func deleteFinished(env: AssistantRegistration.Environment) async -> Bool {
        guard let master = env.secrets.read(.master),
              let reply = await TripRelay.send(TripRelay.relayRequest("/tasks", method: "DELETE", token: master, host: env.host, client: env.client()), session: env.session),
              (200..<300).contains(reply.status) else { return false }
        let open = cached(env.defaults).filter { !$0.status.isFinished }
        if let data = try? encoder.encode(open) { env.defaults.set(data, forKey: cacheKey) }
        return true
    }

    // MARK: 가리기

    static func mask(_ text: String) -> String { AssistantRedaction.mask(text) }

    // MARK: 저장

    private struct Envelope: Decodable {
        private enum Key: String, CodingKey { case tasks }
        private struct Item: Decodable {
            let task: Task?
            init(from decoder: Decoder) throws { task = try? Task(from: decoder) }
        }

        var tasks: [Task]

        init(from decoder: Decoder) throws {
            tasks = try decoder.container(keyedBy: Key.self).decode([Item].self, forKey: .tasks).compactMap(\.task)
        }
    }

    static let decoder: JSONDecoder = {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601withFractionalOrPlain
        return value
    }()

    static let encoder: JSONEncoder = {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .iso8601
        return value
    }()

    static func save(_ list: [Upload], _ defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: uploadsKey) }
    }

    static func dayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

/// 앱 설정·알림·진단을 쓰는 쪽과 지금 앱의 환경으로 부르는 길(PKG1114A19).
extension AITaskQueue {
    static func upload() async { await upload(env: .live) }

    static func deleteFinished() async -> Bool { await deleteFinished(env: .live) }

    /// 넣고 올린다. 연결된 AI가 없으면 넣지 않는다(맡길 곳이 없다).
    @discardableResult
    static func enqueue(_ kind: Kind, text: String, day: Date? = nil, context: [String: String]? = nil,
                        id: String = UUID().uuidString, defaults: UserDefaults = .standard) -> Bool {
        let masked = mask(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !masked.isEmpty, MemoPolishQueue.hasConnection(defaults) else { return false }
        var list = pendingUploads(defaults)
        list.append(Upload(id: id, kind: kind, text: String(masked.prefix(2_000)), date: day.map(dayText), context: context))
        if list.count > uploadLimit { list.removeFirst(list.count - uploadLimit) }
        save(list, defaults)
        TaptionPlanDiagnosticsLogger.shared.record("ai_task_enqueued", fields: ["kind": kind.rawValue])
        if defaults === UserDefaults.standard { _Concurrency.Task { await upload() } }
        return true
    }

    /// 서버 목록을 받아 둔다. 없으면 빈 목록.
    @discardableResult
    static func refresh(env: AssistantRegistration.Environment = .live) async -> [Task]? {
        await upload(env: env)
        guard let master = env.secrets.read(.master),
              let reply = await TripRelay.send(TripRelay.relayRequest("/tasks", method: "GET", query: [URLQueryItem(name: "v", value: "2")], token: master, host: env.host, client: env.client()), session: env.session)
        else { return nil }
        let tasks: [Task]
        switch reply.status {
        case 204: tasks = []
        case 200..<300: tasks = decodeList(reply.data)
        default: return nil
        }
        if let data = try? encoder.encode(tasks) { env.defaults.set(data, forKey: cacheKey) }
        // 서버 목록에 있는 일은 상태와 상관없이 이미 받은 것이다. 큐에 남아 있으면 지운다.
        acknowledge(tasks.map(\.id), defaults: env.defaults)
        ReceiptPhotoMarks.noteReviewed(tasks.filter { $0.status == .done }.map(\.id), defaults: env.defaults)
        // 지난번 뒤로 끝난 일을 한 번에 묶어 알린다. 시험 저장소는 알리지 않는다.
        let news = noteFinished(tasks, defaults: env.defaults)
        if env.defaults === UserDefaults.standard { AITaskNotice.announce(news) }
        return tasks
    }
}

/// 받은 질문과 답을 기기에 둔다(20개·7일). 답하거나 건너뛰면 `/answers`에 목록 전체를 올리고, AI가 `get_answers`로 읽는다.
@MainActor
@Observable
final class AssistantQuestionStore {
    static let shared = AssistantQuestionStore()
    static let key = "assistantQuestions"
    static let dirtyKey = "assistantQuestionsDirty"
    static let limit = 20
    static let lifetime: TimeInterval = 7 * 86_400

    private(set) var items: [AssistantQuestion]
    /// 방금 도착해 알림으로 보일 질문.
    var announced: AssistantQuestion?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        items = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([AssistantQuestion].self, from: $0) } ?? []
    }

    var waiting: [AssistantQuestion] { items.filter { $0.status == .waiting } }
    var finished: [AssistantQuestion] { items.filter { $0.status != .waiting } }

    /// 새 질문을 넣는다. 같은 id가 이미 있으면 넣지 않는다. 넘치면 끝난 것부터, 그다음 오래된 것부터 뺀다.
    @discardableResult
    func add(_ question: AssistantQuestion, now: Date = .now) -> Bool {
        prune(now: now)
        guard !items.contains(where: { $0.id == question.id }) else { return false }
        items.append(question)
        while items.count > Self.limit {
            items.remove(at: items.firstIndex { $0.status != .waiting } ?? 0)
        }
        announced = question
        save()
        return true
    }

    /// 보기에 있는 것만 고른 답으로 남긴다. 고른 것도 쓴 글도 없으면 답으로 치지 않는다.
    @discardableResult
    func answer(_ id: String, choices: [String], text: String?, now: Date = .now) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id && $0.status == .waiting }) else { return false }
        let picked = items[index].options.filter(choices.contains)
        let typed = text.flatMap { AssistantQuestion.trimmed(String($0.prefix(AssistantQuestion.textLimit)), max: AssistantQuestion.textLimit) }
        guard !picked.isEmpty || typed != nil else { return false }
        items[index].choices = items[index].multiSelect ? picked : Array(picked.prefix(1))
        items[index].text = typed
        finish(index, .answered, now: now)
        return true
    }

    func skip(_ id: String, now: Date = .now) {
        guard let index = items.firstIndex(where: { $0.id == id && $0.status == .waiting }) else { return }
        finish(index, .skipped, now: now)
    }

    /// 「AI가 한 일」에서 되돌리기: 아직 답하지 않은 질문만 거둔다.
    func withdraw(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id && $0.status == .waiting }) else { return }
        items.remove(at: index)
        if announced?.id == id { announced = nil }
        save()
    }

    func clearFinished() {
        guard !finished.isEmpty else { return }
        items.removeAll { $0.status != .waiting }
        save()
    }

    /// 앱이 앞으로 올 때 부른다: 알리는 중인 것이 없고 답하지 않은 질문이 있으면 가장 오래된 것을 다시 알린다(ASN1112A01).
    func reannounce() {
        guard announced == nil, let first = waiting.first else { return }
        announced = first
    }

    func prune(now: Date = .now) {
        let kept = items.filter { now.timeIntervalSince($0.askedAt) < Self.lifetime }
        guard kept.count != items.count else { return }
        items = kept
        save()
    }

    var needsUpload: Bool { defaults.bool(forKey: Self.dirtyKey) }

    /// `POST /answers` 본문. 질문이 없으면 nil(그때는 서버 목록을 지운다).
    func uploadBody() -> Data? {
        guard !items.isEmpty else { return nil }
        let stamp = ISO8601DateFormatter()
        let answers: [[String: Any]] = items.map { item in
            var value: [String: Any] = ["id": item.id, "question": item.question, "status": item.status.rawValue, "askedAt": stamp.string(from: item.askedAt)]
            if item.status == .answered {
                if !item.choices.isEmpty { value["choices"] = item.choices }
                if let text = item.text { value["text"] = text }
            }
            if let answeredAt = item.answeredAt { value["answeredAt"] = stamp.string(from: answeredAt) }
            return value
        }
        return try? JSONSerialization.data(withJSONObject: ["format": "bokki-answers", "version": 1, "answers": answers] as [String: Any])
    }

    /// 바뀐 것이 있으면 올린다. 실패하면 다음에 다시 한다.
    func uploadIfNeeded(env: AssistantRegistration.Environment) async {
        guard needsUpload, let master = env.secrets.read(.master) else { return }
        let body = uploadBody()
        let request = TripRelay.relayRequest("/answers", method: body == nil ? "DELETE" : "POST", body: body, token: master, host: env.host, client: env.client())
        guard let reply = await TripRelay.send(request, session: env.session), (200..<300).contains(reply.status) else { return }
        // 올리는 사이 또 바뀌었으면 표시를 남겨 다음에 다시 올린다.
        if uploadBody() == body { defaults.set(false, forKey: Self.dirtyKey) }
    }

    private func finish(_ index: Int, _ status: AssistantQuestion.Status, now: Date) {
        items[index].status = status
        items[index].answeredAt = now
        if defaults === UserDefaults.standard { AssistantQuestionNotice.clear(items[index].id) }
        if announced?.id == items[index].id { announced = nil }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { defaults.set(data, forKey: Self.key) }
        defaults.set(true, forKey: Self.dirtyKey)
    }
}

extension AssistantQuestionStore {
    func uploadIfNeeded() async { await uploadIfNeeded(env: .live) }
}

/// 승인 요청의 앱 쪽: 값 검사, 카드 문구, 실행. 값 타입은 `TaptionAssistantProtocol`에 있다.
extension AssistantApproval {
    /// 서버와 같은 규칙으로 다시 본다.
    static func make(request: String?, value: AssistantLooseValue?) -> Self? {
        guard let request = request.flatMap(Request.init(rawValue:)) else { return nil }
        switch (request, value) {
        case let (.shareLevel, .text(level)) where AssistantShareLevel(rawValue: level) != nil: return Self(request: request, value: level)
        case let (.retentionDays, .number(days)) where days == days.rounded() && AssistantRetention(rawValue: Int(days)) != nil:
            return Self(request: request, value: String(Int(days)))
        case (.healthOff, nil), (.eraseAllData, nil), (.backup, nil), (.restore, nil), (.changePin, nil): return Self(request: request, value: nil)
        default: return nil
        }
    }

    /// 승인하면 열 화면. 값을 바로 적용하는 요청은 nil.
    var screen: AssistantScreen? {
        switch request {
        case .eraseAllData: .settings
        case .backup, .restore: .dataProtection
        case .changePin: .aiConnection
        case .shareLevel, .retentionDays, .healthOff: nil
        }
    }

    func title(_ language: MapHomeLanguage) -> String {
        switch request {
        case .shareLevel:
            let level = value.flatMap(AssistantShareLevel.init(rawValue:)) ?? .summary
            return language.text("AI 공유 수준을 「\(level.title(language))」(으)로 바꿀까요?", "Change AI sharing to “\(level.title(language))”?")
        case .retentionDays:
            let days = value.flatMap(Int.init).flatMap(AssistantRetention.init(rawValue:)) ?? .week
            return language.text("서버 보관 기간을 \(days.title(language))로 바꿀까요?", "Change server retention to \(days.title(language))?")
        case .healthOff: return language.text("건강 연동을 끌까요?", "Turn off Health sync?")
        case .eraseAllData: return language.text("모든 데이터 삭제 화면을 열까요?", "Open the screen to erase all data?")
        case .backup: return language.text("백업 화면을 열까요?", "Open the backup screen?")
        case .restore: return language.text("복원 화면을 열까요?", "Open the restore screen?")
        case .changePin: return language.text("AI 연결 화면에서 PIN을 바꿀까요?", "Change the PIN in AI connections?")
        }
    }

    /// 승인하면 무슨 일이 생기는지.
    func detail(_ language: MapHomeLanguage) -> String {
        switch request {
        case .shareLevel, .retentionDays:
            language.text("승인하면 바로 바뀝니다. 덜 보내거나 기간을 줄이면 서버에 올린 기록을 지웁니다.",
                          "It changes as soon as you approve. Sharing less or keeping it shorter deletes what the server holds.")
        case .healthOff:
            language.text("승인하면 건강·Apple Watch에서 가져온 기록이 앱에서 지워집니다.",
                          "Approving removes the records brought from Health and Apple Watch from the app.")
        case .eraseAllData, .backup, .restore, .changePin:
            language.text("승인하면 그 화면만 엽니다. 실제 실행과 비밀번호 입력은 직접 하세요.",
                          "Approving only opens that screen. You do the action and enter any password yourself.")
        }
    }

    /// 승인된 요청을 실행한다. 값 설정은 여기서 적용하고, 화면이 필요한 것은 열어 달라고 맡긴다.
    @MainActor
    func perform(model: AppModel?, defaults: UserDefaults = .standard, screens: AssistantScreenRequest = .shared) async {
        switch request {
        case .shareLevel:
            guard let level = value.flatMap(AssistantShareLevel.init(rawValue:)) else { return }
            let old = AssistantShareLevel.current(defaults)
            defaults.set(level.rawValue, forKey: AssistantShareLevel.defaultsKey)
            if AssistantShareLevel.isDowngrade(from: old, to: level) { AssistantActivitySync.requestClear(defaults: defaults) }
        case .retentionDays:
            guard let days = value.flatMap(Int.init), AssistantRetention(rawValue: days) != nil else { return }
            let old = AssistantRetention.current(defaults).rawValue
            defaults.set(days, forKey: AssistantRetention.defaultsKey)
            if days < old { AssistantActivitySync.requestClear(defaults: defaults) }
        case .healthOff:
            await model?.setHealthEnabled(false)
        case .eraseAllData, .backup, .restore, .changePin:
            if let screen { screens.request(screen) }
        }
        if let model, defaults === UserDefaults.standard, request == .shareLevel || request == .retentionDays {
            await AssistantActivitySync.run(model: model)
        }
    }
}

/// 앱이 앞에 있지 않을 때 온 AI 질문·승인 요청을 iOS 알림으로 알린다(ASN1112A01).
/// 알림 권한이 있고 앱의 알림 설정이 켜져 있을 때만 보낸다. 사생활 잠금 중에는 질문 글을 싣지 않는다.
enum AssistantQuestionNotice {
    static func identifier(_ id: String) -> String { "assistant-question-\(id)" }

    static func clear(_ id: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier(id)])
    }
}

extension AssistantQuestionNotice {
    /// 알림에 실을 제목과 본문. 잠금 중이면 본문은 앱에서 보라는 말뿐이다.
    static func content(_ question: AssistantQuestion, language: MapHomeLanguage, locked: Bool) -> (title: String, body: String) {
        let title = question.approval == nil ? language.text("AI 질문", "AI question") : language.text("AI 승인 요청", "AI approval request")
        let body = locked ? language.text("앱에서 확인해 주세요.", "Open the app to see it.") : (question.approval?.title(language) ?? question.question)
        return (title, body)
    }

    @MainActor
    static func post(_ question: AssistantQuestion, language: MapHomeLanguage, enabled: Bool) {
        guard enabled else { return }
        let text = content(question, language: language, locked: TaptionExternalPrivacyStore.isLocked)
        Task {
            let center = UNUserNotificationCenter.current()
            let status = await center.notificationSettings().authorizationStatus
            guard status == .authorized || status == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = text.title
            content.body = text.body
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: identifier(question.id), content: content, trigger: nil))
        }
    }
}

/// 맡긴 일이 끝나면 한 번에 묶어 알린다(AIP1114A05). 앱이 앞에 있으면 화면 띠로, 아니면 iOS 알림 하나로.
/// 알림에는 건수만 싣고 일의 내용은 싣지 않는다.
@MainActor
enum AITaskNotice {
    static let identifier = "ai-task-finished"
    /// 화면 띠에 띄운 글. 같은 확인에서 명령 반영 알림이 덮지 않게 `AssistantCommandRefresh`가 가져가 함께 보인다.
    private static var banner: String?

    static func takeBanner() -> String? {
        defer { banner = nil }
        return banner
    }

    /// 완료가 있으면 그 수를 제목에, 실패는 본문에 따로 센다. 실패뿐이면 제목이 실패 수다.
    static func content(_ news: AITaskQueue.FinishedNews, language: MapHomeLanguage) -> (title: String, body: String)? {
        guard !news.isEmpty else { return nil }
        let done = news.done, failed = news.failed
        let open = language.text("앱에서 확인해 주세요.", "Open the app to see it.")
        guard done > 0 else { return (language.text("AI가 끝내지 못한 일이 \(failed)건 있어요", "Your AI couldn't finish \(failed) task(s)"), open) }
        return (language.text("AI가 \(done)건을 처리했어요", "Your AI handled \(done) task(s)"), failed > 0 ? language.text("실패 \(failed)건", "\(failed) failed") : open)
    }

    static func announce(_ news: AITaskQueue.FinishedNews, language: MapHomeLanguage = .current) {
        guard let text = content(news, language: language), let model = AssistantCommandRefresh.model else { return }
        if model.isSceneActive {
            let line = news.done > 0 && news.failed > 0 ? text.title + " · " + text.body : text.title
            banner = line
            AssistantInbox.current.show(line)
        } else if model.settings.notificationsEnabled {
            post(text)
        }
    }

    /// 같은 식별자로 보내 알림이 쌓이지 않고 하나만 남는다.
    private static func post(_ text: (title: String, body: String)) {
        Task {
            let center = UNUserNotificationCenter.current()
            let status = await center.notificationSettings().authorizationStatus
            guard status == .authorized || status == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = text.title
            content.body = text.body
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
    }
}
