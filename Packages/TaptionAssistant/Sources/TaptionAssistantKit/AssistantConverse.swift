import Foundation
import TaptionAssistantProtocol

/// 앱 안 AI 대화(AI1121A01). 무료 길을 먼저 쓴다: ① 규칙(모델 없음) → ② Apple 모델(PCC·기기) → ③ 중계 서버의 Bedrock(`POST /ai/converse`).
/// 어느 길이든 결과는 「제안」이다. 앱 화면에서 사용자가 고르고 눌러야 반영된다.
public enum AssistantConverse {
    public enum Role: String, Codable, Sendable { case user, assistant }

    public struct Message: Equatable, Codable, Sendable {
        public var role: Role
        public var text: String
        public init(role: Role, text: String) {
            self.role = role
            self.text = text
        }
    }

    /// 서버로 보내는 맥락. 좌표·원문 일기·카드번호를 담을 칸이 없다(AGENTS.md 4절). `region`은 시군구 이름만.
    public struct Context: Equatable, Sendable {
        public var today: String
        public var timeZone: String
        public var language: String
        public var region: String?
        public var tripID: String?
        public var tripTitle: String?
        public var categories: [(id: String, name: String)]

        public init(today: String, timeZone: String, language: String, region: String? = nil, tripID: String? = nil, tripTitle: String? = nil,
                    categories: [(id: String, name: String)] = []) {
            self.today = today
            self.timeZone = timeZone
            self.language = language
            self.region = region
            self.tripID = tripID
            self.tripTitle = tripTitle
            self.categories = categories
        }

        public static func == (a: Self, b: Self) -> Bool {
            a.today == b.today && a.timeZone == b.timeZone && a.language == b.language && a.region == b.region && a.tripID == b.tripID
                && a.tripTitle == b.tripTitle && a.categories.map(\.id) == b.categories.map(\.id) && a.categories.map(\.name) == b.categories.map(\.name)
        }

        /// 오늘 날짜와 시간대 오프셋(+09:00).
        public static func now(_ date: Date = .now, timeZone: TimeZone = .current, language: String) -> Context {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            let seconds = timeZone.secondsFromGMT(for: date)
            let offset = String(format: "%@%02d:%02d", seconds < 0 ? "-" : "+", abs(seconds) / 3600, abs(seconds) % 3600 / 60)
            return Context(today: String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0), timeZone: offset, language: language)
        }
    }

    public struct Reply: Equatable, Sendable {
        public var text: String
        /// `{"commands":[...]}` 모양. 앱의 명령 읽기(`AssistantCommandParser.parse`)에 그대로 넘긴다.
        public var commandsJSON: Data
        public var commandCount: Int
        /// 여러 날 여행 초안(bokki-trip). 여행 가져오기 미리보기로 넘긴다.
        public var tripJSON: String?
        /// 서버가 받기 전에 지운 것의 종류(coordinates·cardNumber·idNumber).
        public var redacted: [String]
        public var truncated: Bool

        public init(text: String, commandsJSON: Data = Data(#"{"commands":[]}"#.utf8), commandCount: Int = 0, tripJSON: String? = nil,
                    redacted: [String] = [], truncated: Bool = false) {
            self.text = text
            self.commandsJSON = commandsJSON
            self.commandCount = commandCount
            self.tripJSON = tripJSON
            self.redacted = redacted
            self.truncated = truncated
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        case notConnected
        /// 서버에 AWS 비밀값이 없다(503).
        case unavailable
        /// 하루 한도(429). daily면 내일까지.
        case limited(retryAfter: Double, daily: Bool)
        case rejected
        case network
        case server
    }

    public static let maxMessages = 12
    public static let maxMessageLength = 2_000
    public static let path = "/ai/converse"

    // MARK: 보내기 전 지우기

    /// 기기에서 먼저 지운다(서버도 다시 지운다). 좌표는 표시로 바꾸고 긴 번호는 끝 4자리만 남긴다.
    public static func scrubbed(_ text: String) -> String {
        var out = AssistantRedaction.mask(text)
        for pattern in coordinatePatterns {
            out = out.replacingOccurrences(of: pattern, with: "[위치 생략]", options: [.regularExpression, .caseInsensitive])
        }
        return out
    }

    private static let coordinatePatterns = [
        #"-?\d{1,3}\.\d{3,}\s*[,/ ]\s*-?\d{1,3}\.\d{3,}"#,
        #"\d{1,3}\s*°\s*\d{1,2}\s*['′]"#,
        #"(?:[?&](?:q|ll|sll|center|query|daddr|saddr|destination|origin)=|@)-?\d{1,3}\.\d+\s*(?:,|%2C)\s*-?\d{1,3}\.\d+"#,
    ]

    /// 대화 끝부분만, 한 말당 길이를 잘라 보낸다. 첫 말이 사용자 말이 되게 맞춘다.
    public static func body(_ messages: [Message], context: Context, maxTokens: Int? = nil) -> Data? {
        var recent = Array(messages.suffix(maxMessages))
        while recent.first?.role == .assistant { recent.removeFirst() }
        let lines: [[String: String]] = recent.compactMap { message in
            let text = scrubbed(String(message.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxMessageLength)))
            return text.isEmpty ? nil : ["role": message.role.rawValue, "text": text]
        }
        guard lines.last?["role"] == Role.user.rawValue else { return nil }
        var body: [String: Any] = ["messages": lines, "context": contextObject(context)]
        if let maxTokens { body["maxTokens"] = maxTokens }
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    private static func contextObject(_ context: Context) -> [String: Any] {
        var out: [String: Any] = ["today": context.today, "timeZone": context.timeZone, "language": context.language]
        if let region = context.region.map(scrubbed), !region.isEmpty { out["region"] = String(region.prefix(40)) }
        if context.tripID != nil || context.tripTitle != nil {
            var trip: [String: String] = [:]
            trip["id"] = context.tripID
            trip["title"] = context.tripTitle.map(scrubbed)
            out["trip"] = trip
        }
        if !context.categories.isEmpty {
            out["categories"] = context.categories.prefix(30).map { ["id": $0.id, "name": String($0.name.prefix(20))] }
        }
        return out
    }

    // MARK: 답 읽기

    public static func decode(status: Int, data: Data) -> Result<Reply, Failure> {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        switch status {
        case 200:
            guard let object, let text = object["reply"] as? String else { return .failure(.server) }
            let commands = object["commands"] as? [Any] ?? []
            let envelope = (try? JSONSerialization.data(withJSONObject: ["commands": commands])) ?? Data(#"{"commands":[]}"#.utf8)
            let trip = (object["trip"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
                .flatMap { String(data: $0, encoding: .utf8) }
            return .success(Reply(
                text: text, commandsJSON: envelope, commandCount: commands.count, tripJSON: trip,
                redacted: object["redacted"] as? [String] ?? [], truncated: object["truncated"] as? Bool ?? false
            ))
        case 429:
            let error = object?["error"] as? String ?? ""
            return .failure(.limited(retryAfter: object?["retryAfter"] as? Double ?? 60, daily: error.hasPrefix("daily_")))
        case 503: return .failure(.unavailable)
        case 400, 413: return .failure(.rejected)
        case 401, 403: return .failure(.notConnected)
        default: return .failure(.server)
        }
    }

    /// 서버로 보낸다. 주인 키가 없으면 `.notConnected`.
    @MainActor
    public static func send(
        _ messages: [Message], context: Context, env: AssistantRegistration.Environment
    ) async -> Result<Reply, Failure> {
        guard env.host != nil, AssistantRegistration.isReady(env) else { return .failure(.notConnected) }
        guard let body = body(messages, context: context),
              let request = TripRelay.commandRequest(path, method: "POST", body: body, env: env, timeout: 35) else { return .failure(.notConnected) }
        guard let reply = await TripRelay.send(request, session: env.session) else { return .failure(.network) }
        return decode(status: reply.status, data: reply.data)
    }
}

// MARK: 길 고르기

/// 한 말을 어느 길로 처리할지(AI1121A01). 판단만 하고 모델을 부르지 않는다.
public enum AssistantConverseIntent: Equatable, Sendable {
    /// 「메모: …」처럼 그대로 적어 두기. 모델이 필요 없다.
    case quickMemo(String)
    /// 메모 다듬기. Apple 모델 우선.
    case polish(String)
    /// 그 밖의 대화·여행 짜기·여러 명령. 서버(Bedrock).
    case conversation
}

public enum AssistantConverseRoute: Equatable, Sendable {
    case local
    case apple
    case server
    /// 연결이 없거나 좌표가 든 다듬기라 어느 길도 쓰지 않는다.
    case unavailable
}

public enum AssistantConverseRouter {
    static let memoPrefixes = ["메모:", "메모 :", "메모해줘:", "memo:", "note:"]
    static let polishWords = ["다듬어", "매끄럽게", "정리해 줘", "정리해줘", "polish", "rewrite"]

    /// 대화의 첫 말에서만 단순한 일을 알아본다. 이어지는 말은 대화로 본다.
    public static func intent(_ text: String, isFirstTurn: Bool) -> AssistantConverseIntent {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isFirstTurn, !trimmed.isEmpty, trimmed.count <= AppleModelTask.memoPolish.onDeviceInputLimit else { return .conversation }
        let lower = trimmed.lowercased()
        if let prefix = memoPrefixes.first(where: { lower.hasPrefix($0) }) {
            let body = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? .conversation : .quickMemo(body)
        }
        if polishWords.contains(where: { lower.contains($0) }), let body = quoted(trimmed) ?? afterColon(trimmed), body.count >= 2 {
            return .polish(body)
        }
        return .conversation
    }

    /// 다듬기는 Apple 길(PCC·기기)이 되면 Apple로, 아니면 서버로. 좌표가 든 글은 기기에서만 다룬다.
    public static func route(_ intent: AssistantConverseIntent, apple: AppleModelDecision?, serverReady: Bool) -> AssistantConverseRoute {
        switch intent {
        case .quickMemo: return .local
        case .polish:
            if let apple, apple.route == .privateCloud || apple.route == .onDevice { return .apple }
            if apple?.route == .notAvailable { return .unavailable }
            return serverReady ? .server : .unavailable
        case .conversation: return serverReady ? .server : .unavailable
        }
    }

    private static func quoted(_ text: String) -> String? {
        for (open, close) in [("\"", "\""), ("“", "”"), ("「", "」"), ("'", "'")] {
            guard let start = text.range(of: open), let end = text.range(of: close, options: .backwards), start.upperBound < end.lowerBound else { continue }
            return String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func afterColon(_ text: String) -> String? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let rest = text[text.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? nil : rest
    }
}
