import Foundation

/// 이미 처리한 명령 id. 서버에서 지운 뒤에도 캐시가 잠깐 예전 목록을 줄 수 있어 두 번 반영하지 않는다.
public enum AssistantCommandLedger {
    public static let defaultsKey = "assistantCommandHandledIDs"
    public static let limit = 200

    public static func handled(_ defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: defaultsKey) ?? []
    }

    public static func remember(_ ids: [String], defaults: UserDefaults = .standard) {
        let old = handled(defaults).filter { !ids.contains($0) }
        defaults.set(Array((old + ids).suffix(limit)), forKey: defaultsKey)
    }

    public static func forget(_ ids: [String], defaults: UserDefaults = .standard) {
        defaults.set(handled(defaults).filter { !ids.contains($0) }, forKey: defaultsKey)
    }
}

/// 명령 하나를 반영했는지와 못 했으면 그 사유. 서버에 그대로 알린다.
public struct AssistantCommandResult: Equatable, Sendable {
    public var id: String
    public var applied: Bool
    public var reason: String?

    public init(id: String, applied: Bool, reason: String? = nil) {
        self.id = id
        self.applied = applied
        self.reason = reason
    }
}

/// 명령 큐를 부르는 요청과 결과 알리기·지우기.
extension TripRelay {
    @MainActor
    public static func commandRequest(
        _ path: String, method: String, query: [URLQueryItem] = [], body: Data? = nil, env: AssistantRegistration.Environment,
        timeout: TimeInterval = 10
    ) -> URLRequest? {
        env.secrets.read(.master).flatMap { relayRequest(path, method: method, query: query, body: body, token: $0, host: env.host, client: env.client(), timeout: timeout) }
    }

    public static let commandFetchTimeout: TimeInterval = 5
}

/// 명령 결과를 서버에 남기고, 끝난 명령을 큐에서 지운다.
extension TripRelay {
    /// 결과를 AI가 볼 수 있게 남긴다. 서버가 받았을 때만 true.
    @MainActor
    public static func postResults(_ results: [AssistantCommandResult], env: AssistantRegistration.Environment) async -> Bool {
        let body = try? JSONSerialization.data(withJSONObject: ["results": results.map { result -> [String: String] in
            var value = ["id": result.id, "status": result.applied ? "applied" : "rejected"]
            if let reason = result.reason { value["reason"] = reason }
            return value
        }])
        let reply = await send(commandRequest("/command/result", method: "POST", body: body, env: env), session: env.session)
        return reply.map { (200..<300).contains($0.status) } ?? false
    }

    @MainActor
    public static func deleteCommands(_ ids: [String], env: AssistantRegistration.Environment) async {
        guard !ids.isEmpty else { return }
        let query = [URLQueryItem(name: "ids", value: ids.joined(separator: ","))]
        _ = await send(commandRequest("/command", method: "DELETE", query: query, env: env), session: env.session)
    }
}

/// 앱이 켜져 있는 동안 명령을 확인하는 간격(SYN1111A03, 대표 결정).
/// AI와 대화 중이면 빠르게(10초, 저전력 20초, 과열 60초), 그 밖에는 5분마다 본다(대표 결정).
/// 대화 중: AI가 5분 안에 왔고 「대화 끝」을 보내지 않았거나, 앱에서 직접 새로고침한 뒤 2분.
@MainActor
public enum AssistantCommandPolling {
    /// 서버가 `GET /command` 응답 머리에 준 값.
    public struct Signal: Equatable, Sendable {
        /// AI가 마지막으로 온 지 몇 초. 온 적 없으면 nil.
        public var seenAgo: TimeInterval?
        public var ended: Bool
        public var receivedAt: Date

        public init(seenAgo: TimeInterval? = nil, ended: Bool, receivedAt: Date) {
            self.seenAgo = seenAgo
            self.ended = ended
            self.receivedAt = receivedAt
        }
    }

    public nonisolated static let idleInterval: TimeInterval = 300
    public nonisolated static let aiIdleTimeout: TimeInterval = 300
    public nonisolated static let manualWindow: TimeInterval = 120

    public static var signal: Signal?
    public static var manualAt: Date?

    public nonisolated static func signal(from response: HTTPURLResponse, now: Date = .now) -> Signal? {
        guard let text = response.value(forHTTPHeaderField: "x-ai-seen-ago"), let ago = TimeInterval(text) else { return nil }
        return Signal(seenAgo: ago < 0 ? nil : ago, ended: response.value(forHTTPHeaderField: "x-ai-ended") == "1", receivedAt: now)
    }

    public nonisolated static func isConversation(signal: Signal?, manualAt: Date?, now: Date = .now) -> Bool {
        if let manualAt, now.timeIntervalSince(manualAt) < manualWindow { return true }
        guard let signal, !signal.ended, let ago = signal.seenAgo else { return false }
        return ago + now.timeIntervalSince(signal.receivedAt) < aiIdleTimeout
    }

    public nonisolated static func interval(conversation: Bool, lowPower: Bool, thermal: ProcessInfo.ThermalState) -> TimeInterval {
        guard conversation else { return idleInterval }
        if thermal == .serious || thermal == .critical { return 60 }
        return lowPower ? 20 : 10
    }

    public static func nextInterval(now: Date = .now, info: ProcessInfo = .processInfo) -> TimeInterval {
        interval(conversation: isConversation(signal: signal, manualAt: manualAt, now: now), lowPower: info.isLowPowerModeEnabled, thermal: info.thermalState)
    }
}
