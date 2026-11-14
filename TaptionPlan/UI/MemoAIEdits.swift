import Foundation

/// AI가 글을 바꾼 메모 표시(MEM1110A02). 「AI가 수정함 · 피클」처럼 누가 고쳤는지 보인다.
/// 메모 저장 형식은 바꾸지 않고 이 기기 설정에만 둔다. 사용자가 직접 고친 것은 표시하지 않는다.
@MainActor
enum MemoAIEditMarks {
    struct Mark: Codable, Equatable, Sendable {
        var by: String
        var at: Date
        /// 표시를 붙인 때의 글. 사용자가 그 뒤 글을 바꾸면 표시를 지운다.
        var text: String
    }

    static let defaultsKey = "memoAIEditMarks"
    static let limit = 500
    static let appleName = "Apple Intelligence"

    static func all(_ defaults: UserDefaults = .standard) -> [String: Mark] {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode([String: Mark].self, from: $0) } ?? [:]
    }

    /// 지금 글이 AI가 고친 글과 같을 때만 표시를 돌려준다.
    static func mark(for memoID: UUID, text: String, defaults: UserDefaults = .standard) -> Mark? {
        guard let mark = all(defaults)[memoID.uuidString], mark.text == text else { return nil }
        return mark
    }

    static func set(_ memoID: UUID, by: String, text: String, at: Date = .now, defaults: UserDefaults = .standard) {
        var marks = all(defaults)
        marks[memoID.uuidString] = Mark(by: by, at: at, text: text)
        if marks.count > limit {
            for key in marks.sorted(by: { $0.value.at < $1.value.at }).prefix(marks.count - limit).map(\.key) { marks[key] = nil }
        }
        save(marks, defaults)
    }

    static func clear(_ memoID: UUID, defaults: UserDefaults = .standard) {
        var marks = all(defaults)
        guard marks.removeValue(forKey: memoID.uuidString) != nil else { return }
        save(marks, defaults)
    }

    private static func save(_ marks: [String: Mark], _ defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(marks) { defaults.set(data, forKey: defaultsKey) }
    }

    static func text(_ mark: Mark, language: MapHomeLanguage) -> String {
        language.text("AI가 수정함 · \(mark.by)", "Edited by AI · \(mark.by)")
    }
}

/// 연결된 AI에게 맡긴 메모 다듬기(MEM1110A02). 목록을 서버 `/polish`에 통째로 올리고,
/// AI가 `updateMemo`를 보내 반영되면 목록에서 뺀다. 서버는 7일 뒤 지운다.
@MainActor
enum MemoPolishQueue {
    struct Item: Codable, Equatable, Sendable {
        var memoID: UUID
        var text: String
        var date: String?
    }

    static let defaultsKey = "memoPolishQueue"
    static let limit = 20

    static func items(_ defaults: UserDefaults = .standard) -> [Item] {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode([Item].self, from: $0) } ?? []
    }

    static func contains(_ memoID: UUID, defaults: UserDefaults = .standard) -> Bool {
        items(defaults).contains { $0.memoID == memoID }
    }

    /// 연결이 하나라도 있어야 맡길 수 있다.
    static func hasConnection(_ defaults: UserDefaults = .standard) -> Bool {
        AssistantKeyLabels.connectionCount(defaults) > 0
    }

    /// 넣고 올린다. 같은 메모는 새 글로 바꾼다. 20개가 넘으면 오래된 것부터 뺀다.
    @discardableResult
    static func enqueue(_ memoID: UUID, text: String, day: Date?, defaults: UserDefaults = .standard) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, text.count <= TaptionPlanMemoRecord.maximumTextLength else { return false }
        var list = items(defaults).filter { $0.memoID != memoID }
        list.append(Item(memoID: memoID, text: text, date: day.map(Self.dayText)))
        if list.count > limit { list.removeFirst(list.count - limit) }
        save(list, defaults)
        return true
    }

    /// AI가 고쳐 보냈거나 사용자가 지웠다.
    static func resolve(_ memoID: UUID, defaults: UserDefaults = .standard) {
        let list = items(defaults)
        guard list.contains(where: { $0.memoID == memoID }) else { return }
        save(list.filter { $0.memoID != memoID }, defaults)
    }

    private static func save(_ list: [Item], _ defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: defaultsKey) }
        defaults.set(true, forKey: needsUploadKey)
        if defaults === UserDefaults.standard { Task { await upload() } }
    }

    static let needsUploadKey = "memoPolishQueueNeedsUpload"

    /// 목록이 있으면 `POST /polish`, 비었으면 `DELETE /polish`. 실패하면 다음에 다시 올린다.
    static func upload(env: AssistantRegistration.Environment = .live) async {
        guard env.defaults.bool(forKey: needsUploadKey), let master = env.secrets.read(.master) else { return }
        let list = items(env.defaults)
        let request: URLRequest?
        if list.isEmpty {
            request = TripRelay.relayRequest("/polish", method: "DELETE", token: master, host: env.host, client: env.client())
        } else {
            let memos: [[String: String]] = list.map { item in
                var memo = ["id": item.memoID.uuidString, "text": item.text]
                if let date = item.date { memo["date"] = date }
                return memo
            }
            let body = try? JSONSerialization.data(withJSONObject: ["format": "bokki-polish", "version": 1, "memos": memos] as [String: Any])
            request = body.flatMap { TripRelay.relayRequest("/polish", method: "POST", body: $0, token: master, host: env.host, client: env.client()) }
        }
        guard let reply = await TripRelay.send(request, session: env.session), (200..<300).contains(reply.status) else { return }
        // 올리는 사이 목록이 바뀌었으면 다음에 다시 올린다.
        if items(env.defaults) == list { env.defaults.set(false, forKey: needsUploadKey) }
    }

    private static func dayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

extension AppModel {
    /// AI 명령으로 메모 글이 바뀐 뒤 부른다. 표시를 붙이고 맡긴 목록에서 뺀다.
    func noteAssistantMemoEdit(_ memoID: UUID, by connection: String?) {
        guard let memo = snapshot.memos.first(where: { $0.id == memoID }) else { return }
        MemoAIEditMarks.set(memoID, by: connection ?? MapHomeLanguage.current.text("연결된 AI", "Connected AI"), text: memo.text)
        MemoPolishQueue.resolve(memoID)
    }
}
