import Foundation

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
        case other
    }

    enum Status: String, Codable, Sendable {
        case waiting, processing, done, failed
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

    static func pendingUploads(_ defaults: UserDefaults = .standard) -> [Upload] {
        defaults.data(forKey: uploadsKey).flatMap { try? JSONDecoder().decode([Upload].self, from: $0) } ?? []
    }

    /// 마지막으로 받은 서버 목록. 화면은 이것과 아직 못 올린 항목을 함께 보인다.
    static func cached(_ defaults: UserDefaults = .standard) -> [Task] {
        defaults.data(forKey: cacheKey).flatMap { try? decoder.decode([Task].self, from: $0) } ?? []
    }

    /// 넣고 올린다. 연결된 AI가 없으면 넣지 않는다(맡길 곳이 없다).
    @discardableResult
    static func enqueue(_ kind: Kind, text: String, day: Date? = nil, context: [String: String]? = nil,
                        defaults: UserDefaults = .standard) -> Bool {
        let masked = mask(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !masked.isEmpty, MemoPolishQueue.hasConnection(defaults) else { return false }
        var list = pendingUploads(defaults)
        list.append(Upload(id: UUID().uuidString, kind: kind, text: String(masked.prefix(2_000)), date: day.map(dayText), context: context))
        if list.count > uploadLimit { list.removeFirst(list.count - uploadLimit) }
        save(list, defaults)
        TaptionPlanDiagnosticsLogger.shared.record("ai_task_enqueued", fields: ["kind": kind.rawValue])
        if defaults === UserDefaults.standard { _Concurrency.Task { await upload() } }
        return true
    }

    /// 못 올린 항목을 `POST /tasks`로 올린다. 실패하면 다음에 다시.
    static func upload(env: AssistantRegistration.Environment = .live) async {
        let list = pendingUploads(env.defaults)
        guard !list.isEmpty, let master = env.secrets.read(.master) else { return }
        let tasks: [[String: Any]] = list.map { item in
            var task: [String: Any] = ["id": item.id, "kind": item.kind.rawValue, "text": item.text]
            if let date = item.date { task["date"] = date }
            if let context = item.context { task["context"] = context }
            return task
        }
        let body = try? JSONSerialization.data(withJSONObject: ["format": "bokki-tasks", "version": 1, "tasks": tasks] as [String: Any])
        let request = body.flatMap { TripRelay.relayRequest("/tasks", method: "POST", body: $0, token: master, host: env.host) }
        guard let reply = await TripRelay.send(request, session: env.session), (200..<300).contains(reply.status) else { return }
        let sent = Set(list.map(\.id))
        save(pendingUploads(env.defaults).filter { !sent.contains($0.id) }, env.defaults)
    }

    /// 서버 목록을 받아 둔다. 없으면 빈 목록.
    @discardableResult
    static func refresh(env: AssistantRegistration.Environment = .live) async -> [Task]? {
        await upload(env: env)
        guard let master = env.secrets.read(.master),
              let reply = await TripRelay.send(TripRelay.relayRequest("/tasks", method: "GET", token: master, host: env.host), session: env.session)
        else { return nil }
        let tasks: [Task]
        switch reply.status {
        case 204: tasks = []
        case 200..<300: tasks = (try? decoder.decode(Envelope.self, from: reply.data))?.tasks ?? []
        default: return nil
        }
        if let data = try? encoder.encode(tasks) { env.defaults.set(data, forKey: cacheKey) }
        return tasks
    }

    /// 끝난 항목(완료·실패)을 서버에서 지운다.
    static func deleteFinished(env: AssistantRegistration.Environment = .live) async -> Bool {
        guard let master = env.secrets.read(.master),
              let reply = await TripRelay.send(TripRelay.relayRequest("/tasks", method: "DELETE", token: master, host: env.host), session: env.session),
              (200..<300).contains(reply.status) else { return false }
        let open = cached(env.defaults).filter { $0.status == .waiting || $0.status == .processing }
        if let data = try? encoder.encode(open) { env.defaults.set(data, forKey: cacheKey) }
        return true
    }

    // MARK: 가리기

    /// 숫자가 9개 넘게 이어진 덩어리(카드·계좌·전화번호)는 끝 4자리만 남기고 가린다. 금액·날짜·시각은 그대로다.
    static func mask(_ text: String) -> String {
        // 띄어 쓴 카드번호(4자리 묶음)와, 붙임표로 이은 번호. 아무 띄어쓰기나 받으면 번호 뒤 날짜까지 한 덩어리가 된다.
        let pattern = #"\d{4}(?: \d{4}){2,3}|\d[\d-]{7,}\d"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let run = String(result[range])
            let digits = run.filter(\.isNumber).count
            guard digits >= 9 else { continue }
            var remaining = digits
            let masked = String(run.map { character -> Character in
                guard character.isNumber else { return character }
                remaining -= 1
                return remaining < 4 ? character : "*"
            })
            result.replaceSubrange(range, with: masked)
        }
        return result
    }

    // MARK: 저장

    private struct Envelope: Decodable { var tasks: [Task] }

    private static let decoder: JSONDecoder = {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601withFractionalOrPlain
        return value
    }()

    private static let encoder: JSONEncoder = {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .iso8601
        return value
    }()

    private static func save(_ list: [Upload], _ defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: uploadsKey) }
    }

    private static func dayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

extension JSONDecoder.DateDecodingStrategy {
    /// 서버는 `toISOString()`(밀리초 포함)으로 시각을 쓴다.
    static let iso8601withFractionalOrPlain = custom { decoder in
        let text = try decoder.singleValueContainer().decode(String.self)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) { return date }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(text)"))
    }
}

/// AI가 앱에서 묻는 객관식 질문 하나(ASK1112A01). `id`는 그 `askUser` 명령의 id이고, AI는 이것으로 답을 찾는다.
struct AssistantQuestion: Codable, Equatable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable { case waiting, answered, skipped }

    static let questionLimit = 200
    static let optionLimit = 60
    static let textLimit = 200
    static let optionRange = 2...4

    var id: String
    var question: String
    var options: [String]
    var multiSelect: Bool
    var askedAt: Date
    var status: Status = .waiting
    /// 고른 보기. 보기에 없는 글은 받지 않는다.
    var choices: [String] = []
    /// 직접 입력한 답.
    var text: String?
    var answeredAt: Date?

    /// 서버와 같은 규칙으로 다시 본다: 질문 1~200자, 서로 다른 보기 2~4개(1~60자).
    static func make(id: String?, question: String?, options: [String]?, multiSelect: Bool?, now: Date) -> Self? {
        guard let id, !id.isEmpty, let question = trimmed(question, max: questionLimit), let options,
              optionRange.contains(options.count) else { return nil }
        let cleaned = options.compactMap { trimmed($0, max: optionLimit) }
        guard cleaned.count == options.count, Set(cleaned).count == cleaned.count else { return nil }
        return Self(id: id, question: question, options: cleaned, multiSelect: multiSelect ?? false, askedAt: now)
    }

    static func trimmed(_ text: String?, max: Int) -> String? {
        guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty, value.count <= max else { return nil }
        return value
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
    func uploadIfNeeded(env: AssistantRegistration.Environment = .live) async {
        guard needsUpload, let master = env.secrets.read(.master) else { return }
        let body = uploadBody()
        let request = TripRelay.relayRequest("/answers", method: body == nil ? "DELETE" : "POST", body: body, token: master, host: env.host)
        guard let reply = await TripRelay.send(request, session: env.session), (200..<300).contains(reply.status) else { return }
        // 올리는 사이 또 바뀌었으면 표시를 남겨 다음에 다시 올린다.
        if uploadBody() == body { defaults.set(false, forKey: Self.dirtyKey) }
    }

    private func finish(_ index: Int, _ status: AssistantQuestion.Status, now: Date) {
        items[index].status = status
        items[index].answeredAt = now
        if announced?.id == items[index].id { announced = nil }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { defaults.set(data, forKey: Self.key) }
        defaults.set(true, forKey: Self.dirtyKey)
    }
}
