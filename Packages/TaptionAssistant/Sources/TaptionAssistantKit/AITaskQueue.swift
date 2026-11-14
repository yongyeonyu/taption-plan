import Foundation
import Observation
import TaptionAssistantProtocol
import UserNotifications

/// AI 확인 목록(AIQ1111A01). 앱이 처리하지 못했거나 불분명한 것을 서버 `/tasks`에 올리면
/// 연결된 AI가 가져가(처리중) 처리하고 완료·실패를 남긴다. AI 결과는 기존 명령(가계부·메모·기록)으로 바로 반영된다.
/// 원문의 카드·계좌·전화번호는 가리고 보낸다. 서버는 끝난 항목의 원문을 지우고, 길어도 7일 뒤 모두 지운다.
@MainActor
public enum AITaskQueue {
    public enum Kind: String, Codable, CaseIterable, Sendable {
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
        public init(from decoder: Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
        }
    }

    /// `asked`는 AI가 사용자에게 묻고 답을 기다리는 중, `expired`는 아무도 맡지 않고 기한(7일)이 지난 것(AIP1114A05).
    public enum Status: String, Codable, Sendable {
        case waiting, processing, asked, done, failed, expired
        /// 이 앱이 모르는 새 상태.
        case unknown

        public init(from decoder: Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }

        public var isFinished: Bool { self == .done || self == .failed || self == .expired }
    }

    /// AI가 일을 끝내며 남긴 것: 보낸 명령·가계부 기록·규칙의 id, 기다리는 질문, 사용자가 봐야 하는지.
    public struct Outcome: Codable, Equatable, Sendable {
        public var commandIds: [String]?
        public var entryIds: [String]?
        public var ruleIds: [String]?
        public var askedQuestionId: String?
        public var needsUser: Bool?

        public init(commandIds: [String]? = nil, entryIds: [String]? = nil, ruleIds: [String]? = nil, askedQuestionId: String? = nil, needsUser: Bool? = nil) {
            self.commandIds = commandIds
            self.entryIds = entryIds
            self.ruleIds = ruleIds
            self.askedQuestionId = askedQuestionId
            self.needsUser = needsUser
        }
    }

    public struct Task: Codable, Equatable, Identifiable, Sendable {
        public var id: String
        public var kind: Kind
        public var text: String?
        public var date: String?
        public var status: Status
        public var result: String?
        public var reason: String?
        public var createdAt: Date?
        public var updatedAt: Date?
        /// 맡은 연결 키 id, 맡은 횟수, 끝낸 결과(`GET /tasks?v=2`). 예전 캐시에는 없다.
        public var claimedBy: String?
        public var attempts: Int?
        public var outcome: Outcome?

        public init(
            id: String, kind: Kind, text: String? = nil, date: String? = nil, status: Status, result: String? = nil, reason: String? = nil,
            createdAt: Date? = nil, updatedAt: Date? = nil, claimedBy: String? = nil, attempts: Int? = nil, outcome: Outcome? = nil
        ) {
            self.id = id
            self.kind = kind
            self.text = text
            self.date = date
            self.status = status
            self.result = result
            self.reason = reason
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.claimedBy = claimedBy
            self.attempts = attempts
            self.outcome = outcome
        }
    }

    /// 아직 서버에 못 올린 항목.
    public struct Upload: Codable, Equatable, Sendable {
        public var id: String
        public var kind: Kind
        public var text: String
        public var date: String?
        public var context: [String: String]?

        public init(id: String, kind: Kind, text: String, date: String? = nil, context: [String: String]? = nil) {
            self.id = id
            self.kind = kind
            self.text = text
            self.date = date
            self.context = context
        }
    }

    public static let uploadsKey = "aiTaskUploads"
    public static let cacheKey = "aiTaskCache"
    public static let uploadLimit = 20

    /// 서버가 이미 받은 일의 id(AIU1114A01). 응답을 못 받아 큐에 남은 일을 다시 올려 끝난 일을 되살리지 않게 한다.
    public static let ackedKey = "aiTaskAcked"
    public static let ackedLimit = 300

    public static func acknowledge(_ ids: [String], defaults: UserDefaults = .standard) {
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
    public static func unsent(_ defaults: UserDefaults = .standard) -> [Upload] {
        let acked = Set(defaults.stringArray(forKey: ackedKey) ?? [])
        return pendingUploads(defaults).filter { !acked.contains($0.id) }
    }

    public static func pendingUploads(_ defaults: UserDefaults = .standard) -> [Upload] {
        defaults.data(forKey: uploadsKey).flatMap { try? JSONDecoder().decode([Upload].self, from: $0) } ?? []
    }

    /// 마지막으로 받은 서버 목록. 화면은 이것과 아직 못 올린 항목을 함께 보인다.
    public static func cached(_ defaults: UserDefaults = .standard) -> [Task] {
        defaults.data(forKey: cacheKey).flatMap { try? decoder.decode([Task].self, from: $0) } ?? []
    }

    /// 못 올린 항목을 `POST /tasks`로 올린다. 실패하면 다음에 다시.
    public static func upload(env: AssistantRegistration.Environment) async {
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
    public static func decodeList(_ data: Data) -> [Task] {
        (try? decoder.decode(Envelope.self, from: data))?.tasks ?? []
    }

    // MARK: 끝난 일 알림 (AIP1114A05)

    public struct FinishedNews: Equatable, Sendable {
        public var done = 0
        public var failed = 0

        public init(done: Int = 0, failed: Int = 0) {
            self.done = done
            self.failed = failed
        }
        public var isEmpty: Bool { done + failed == 0 }
    }

    public static let finishedSeenKey = "aiTaskFinishedSeen"
    public static let finishedSeenLimit = 300

    /// 지난번 뒤로 완료·실패가 된 일을 세고, 끝난 일의 id를 적어 둔다.
    /// 처음 돌 때(적어 둔 것이 없을 때)는 이미 끝나 있던 일을 세지 않는다. 기한이 지난 것은 적기만 한다.
    public static func noteFinished(_ tasks: [Task], defaults: UserDefaults) -> FinishedNews {
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
    public static func deleteFinished(env: AssistantRegistration.Environment) async -> Bool {
        guard let master = env.secrets.read(.master),
              let reply = await TripRelay.send(TripRelay.relayRequest("/tasks", method: "DELETE", token: master, host: env.host, client: env.client()), session: env.session),
              (200..<300).contains(reply.status) else { return false }
        let open = cached(env.defaults).filter { !$0.status.isFinished }
        if let data = try? encoder.encode(open) { env.defaults.set(data, forKey: cacheKey) }
        return true
    }

    // MARK: 가리기

    public static func mask(_ text: String) -> String { AssistantRedaction.mask(text) }

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

    public static let decoder: JSONDecoder = {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601withFractionalOrPlain
        return value
    }()

    public static let encoder: JSONEncoder = {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .iso8601
        return value
    }()

    public static func save(_ list: [Upload], _ defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: uploadsKey) }
    }

    public static func dayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

/// 받은 질문과 답을 기기에 둔다(20개·7일). 답하거나 건너뛰면 `/answers`에 목록 전체를 올리고, AI가 `get_answers`로 읽는다.
@MainActor
@Observable
public final class AssistantQuestionStore {
    public static let shared = AssistantQuestionStore()
    public static let key = "assistantQuestions"
    public static let dirtyKey = "assistantQuestionsDirty"
    public static let limit = 20
    public static let lifetime: TimeInterval = 7 * 86_400

    public private(set) var items: [AssistantQuestion]
    /// 방금 도착해 알림으로 보일 질문.
    public var announced: AssistantQuestion?
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        items = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([AssistantQuestion].self, from: $0) } ?? []
    }

    public var waiting: [AssistantQuestion] { items.filter { $0.status == .waiting } }
    public var finished: [AssistantQuestion] { items.filter { $0.status != .waiting } }

    /// 새 질문을 넣는다. 같은 id가 이미 있으면 넣지 않는다. 넘치면 끝난 것부터, 그다음 오래된 것부터 뺀다.
    @discardableResult
    public func add(_ question: AssistantQuestion, now: Date = .now) -> Bool {
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
    public func answer(_ id: String, choices: [String], text: String?, now: Date = .now) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id && $0.status == .waiting }) else { return false }
        let picked = items[index].options.filter(choices.contains)
        let typed = text.flatMap { AssistantQuestion.trimmed(String($0.prefix(AssistantQuestion.textLimit)), max: AssistantQuestion.textLimit) }
        guard !picked.isEmpty || typed != nil else { return false }
        items[index].choices = items[index].multiSelect ? picked : Array(picked.prefix(1))
        items[index].text = typed
        finish(index, .answered, now: now)
        return true
    }

    public func skip(_ id: String, now: Date = .now) {
        guard let index = items.firstIndex(where: { $0.id == id && $0.status == .waiting }) else { return }
        finish(index, .skipped, now: now)
    }

    /// 「AI가 한 일」에서 되돌리기: 아직 답하지 않은 질문만 거둔다.
    public func withdraw(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id && $0.status == .waiting }) else { return }
        items.remove(at: index)
        if announced?.id == id { announced = nil }
        save()
    }

    public func clearFinished() {
        guard !finished.isEmpty else { return }
        items.removeAll { $0.status != .waiting }
        save()
    }

    /// 앱이 앞으로 올 때 부른다: 알리는 중인 것이 없고 답하지 않은 질문이 있으면 가장 오래된 것을 다시 알린다(ASN1112A01).
    public func reannounce() {
        guard announced == nil, let first = waiting.first else { return }
        announced = first
    }

    public func prune(now: Date = .now) {
        let kept = items.filter { now.timeIntervalSince($0.askedAt) < Self.lifetime }
        guard kept.count != items.count else { return }
        items = kept
        save()
    }

    public var needsUpload: Bool { defaults.bool(forKey: Self.dirtyKey) }

    /// `POST /answers` 본문. 질문이 없으면 nil(그때는 서버 목록을 지운다).
    public func uploadBody() -> Data? {
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
    public func uploadIfNeeded(env: AssistantRegistration.Environment) async {
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

/// 앱이 앞에 있지 않을 때 온 AI 질문·승인 요청을 iOS 알림으로 알린다(ASN1112A01).
/// 알림 권한이 있고 앱의 알림 설정이 켜져 있을 때만 보낸다. 사생활 잠금 중에는 질문 글을 싣지 않는다.
public enum AssistantQuestionNotice {
    public static func identifier(_ id: String) -> String { "assistant-question-\(id)" }

    public static func clear(_ id: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier(id)])
    }
}
