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
