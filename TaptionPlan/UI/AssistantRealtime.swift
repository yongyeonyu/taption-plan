import Foundation
import Observation

/// 앱 전면 실시간 반영 소켓(RTA1120A02). 폴링(`AssistantLiveSync`) 위에 서버가 미는 알림(`cmd`·`patch`)을 하나 더 단다.
/// 알림에는 본문이 없다: 받으면 같은 갱신 입구(`refresh`)로 들어가 본문은 기존 HTTP로 가져간다.
/// 소켓이 한 번도 못 붙거나 끊겨도 앱은 폴링으로 그대로 돈다.

struct RealtimeEvent: Equatable, Sendable {
    var e: Int
    var type: String
    var entity: String?
    var id: String?
}

enum AssistantRealtimeMessage: Equatable, Sendable {
    case hello(latest: Int, oldest: Int)
    case event(RealtimeEvent)
    case events([RealtimeEvent], more: Bool)
    case ready(latest: Int)
    case resync
    case bye

    static let maximumBytes = 128 * 1024

    /// 모양이 다르거나 너무 긴 글자는 nil(조용히 무시한다).
    static func parse(_ text: String) -> AssistantRealtimeMessage? {
        guard text.utf8.count <= maximumBytes, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let type = object["type"] as? String else { return nil }
        func int(_ key: String, in dict: [String: Any]) -> Int? { (dict[key] as? NSNumber).map { Int(truncating: $0) } }
        func event(_ dict: [String: Any]) -> RealtimeEvent? {
            guard let kind = dict["type"] as? String, kind == "cmd" || kind == "patch", let e = int("e", in: dict) else { return nil }
            return RealtimeEvent(e: e, type: kind, entity: dict["entity"] as? String, id: dict["id"] as? String)
        }
        switch type {
        case "hello": return int("latest", in: object).map { .hello(latest: $0, oldest: int("oldest", in: object) ?? 1) }
        case "cmd", "patch": return event(object).map { .event($0) }
        case "events":
            let items = (object["items"] as? [[String: Any]] ?? []).compactMap(event)
            return .events(items, more: object["more"] as? Bool ?? false)
        case "ready": return int("latest", in: object).map { .ready(latest: $0) }
        case "resync": return .resync
        case "bye": return .bye
        default: return nil
        }
    }
}

/// 받은 알림이 앱에서 하는 일. 무거운 곁일(영수증 스캔·질문 올리기)은 부르지 않는다.
enum AssistantRealtimeAction: Equatable, Sendable {
    case refresh        // cmd, plan → `AssistantLiveSync.refresh`
    case tasks, rules
    case fullRefresh    // resync
}

/// 커서와 알림 해석(순수). `hello.latest`는 이벤트를 다 받기 전에는 커서로 쓰지 않는다(유실 방지).
struct AssistantRealtimeCursor: Equatable, Sendable {
    var value = 0
    private(set) var catchUpDone = false
    /// 이번 접속에서 서버가 알려 준 마지막 이벤트 번호. `resync`는 전체 확인으로 따라잡으므로 그 번호로 커서를 옮긴다.
    private var helloLatest = 0

    mutating func beginConnection() { catchUpDone = false }

    mutating func apply(_ message: AssistantRealtimeMessage) -> [AssistantRealtimeAction] {
        switch message {
        case let .hello(latest, _): helloLatest = latest; return []
        case .bye: return []
        case let .event(event): return take([event])
        case let .events(items, _): return take(items)
        case let .ready(latest): catchUpDone = true; value = max(value, latest); return []
        case .resync: value = helloLatest; return [.fullRefresh]
        }
    }

    private mutating func take(_ events: [RealtimeEvent]) -> [AssistantRealtimeAction] {
        var actions: [AssistantRealtimeAction] = []
        for event in events where event.e > value {
            value = event.e
            let action = Self.action(for: event)
            if let action, !actions.contains(action) { actions.append(action) }
        }
        return actions
    }

    static func action(for event: RealtimeEvent) -> AssistantRealtimeAction? {
        if event.type == "cmd" { return .refresh }
        switch event.entity {
        case "plan": return .refresh
        case "tasks": return .tasks
        case "rules": return .rules
        default: return nil // day·memo·app은 이 앱에 따로 다시 읽을 화면이 없다
        }
    }
}

/// 재연결 간격: 1초에서 시작해 두 배씩 60초까지, 25% 흔들림(`ShareBackoff`와 같은 값).
enum AssistantRealtimeBackoff {
    static func delay(attempt: Int, jitter: Double = Double.random(in: -0.25...0.25)) -> TimeInterval {
        let base = min(60, pow(2, Double(max(attempt - 1, 0))))
        return max(0.5, base * (1 + jitter))
    }
}

protocol AssistantSocket: Sendable {
    func receive() async throws -> String
    func send(_ text: String) async throws
    func cancel()
}

struct LiveAssistantSocket: AssistantSocket {
    let task: URLSessionWebSocketTask

    func receive() async throws -> String {
        switch try await task.receive() {
        case let .string(text): return text
        case .data: return ""
        @unknown default: return ""
        }
    }

    func send(_ text: String) async throws { try await task.send(.string(text)) }
    func cancel() { task.cancel(with: .goingAway, reason: nil) }
}

@MainActor
@Observable
final class AssistantRealtime {
    static let shared = AssistantRealtime()

    nonisolated static let enabledKey = "assistantRealtimeEnabled"
    nonisolated static let cursorKey = "assistantRealtimeCursor"
    nonisolated static let pingSeconds: TimeInterval = 30
    nonisolated static let failuresBeforeDown = 3
    nonisolated static let retryAfterDown: TimeInterval = 30 * 60

    private(set) var isConnected = false
    private(set) var isDown = false
    @ObservationIgnored private(set) var failures = 0
    @ObservationIgnored var counters = (connects: 0, reconnects: 0, events: 0, downs: 0)

    nonisolated static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) == nil ? true : defaults.bool(forKey: enabledKey)
    }

    nonisolated static func setEnabled(_ value: Bool, defaults: UserDefaults = .standard) { defaults.set(value, forKey: enabledKey) }

    /// 반복을 돈다. 전면이 아니면(작업이 취소되면) 소켓을 닫고 끝난다. 켜짐 설정이 꺼져 있으면 소켓을 열지 않는다.
    func run(
        defaults: UserDefaults = .standard,
        makeSocket: @MainActor (Int) -> AssistantSocket?,
        wait: @escaping @MainActor (TimeInterval) async -> Void,
        apply: @MainActor (AssistantRealtimeAction) async -> Void
    ) async {
        var cursor = AssistantRealtimeCursor(value: defaults.integer(forKey: Self.cursorKey))
        var attempt = 0
        while !Task.isCancelled {
            guard Self.isEnabled(defaults: defaults), AssistantLiveSync.mode(defaults: defaults) != .off else {
                setConnected(false)
                await wait(10)
                continue
            }
            if isDown { await wait(Self.retryAfterDown); if Task.isCancelled { break }; isDown = false; failures = 0 }
            guard let socket = makeSocket(cursor.value) else { await wait(60); continue }
            cursor.beginConnection()
            counters.connects += 1
            if attempt > 0 { counters.reconnects += 1 }
            attempt += 1
            let outcome = await session(socket, cursor: &cursor, defaults: defaults, wait: wait, apply: apply)
            socket.cancel()
            setConnected(false)
            if Task.isCancelled { break }
            if outcome.gotHello { failures = 0; attempt = 1 } else { failures += 1 }
            if failures >= Self.failuresBeforeDown { isDown = true; counters.downs += 1; continue }
            await wait(AssistantRealtimeBackoff.delay(attempt: max(failures, 1)))
        }
        setConnected(false)
    }

    private func setConnected(_ value: Bool) { if isConnected != value { isConnected = value } }

    private struct Outcome { var gotHello = false }

    private func session(
        _ socket: AssistantSocket, cursor: inout AssistantRealtimeCursor, defaults: UserDefaults,
        wait: @escaping @MainActor (TimeInterval) async -> Void, apply: @MainActor (AssistantRealtimeAction) async -> Void
    ) async -> Outcome {
        var outcome = Outcome()
        // 핑은 글자 `ping` 하나. 서버가 DO를 깨우지 않고 `pong`으로 답한다.
        let pinger = Task { @MainActor in
            while !Task.isCancelled {
                await wait(Self.pingSeconds)
                if Task.isCancelled { return }
                try? await socket.send("ping")
            }
        }
        defer { pinger.cancel() }
        while !Task.isCancelled {
            guard let text = try? await socket.receive() else { return outcome }
            guard let message = AssistantRealtimeMessage.parse(text) else { continue } // pong·알 수 없는 글자는 무시
            if case .hello = message { outcome.gotHello = true; setConnected(true) }
            if case .bye = message { return outcome }
            let actions = cursor.apply(message)
            defaults.set(cursor.value, forKey: Self.cursorKey)
            for action in actions {
                counters.events += 1
                await apply(action)
            }
        }
        return outcome
    }

    /// 실제 소켓: `wss://<중계>/rt/ws?since=<커서>`, 헤더 인증(쿼리에 키를 넣지 않는다).
    static func liveSocket(since: Int, env: AssistantRegistration.Environment = .live) -> AssistantSocket? {
        guard env.host != nil,
              var request = TripRelay.relayRequest("/rt/ws", method: "GET", query: [URLQueryItem(name: "since", value: String(since))], host: env.host, client: env.client(), timeout: 20),
              var parts = request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else { return nil }
        parts.scheme = "wss"
        guard let url = parts.url else { return nil }
        request.url = url
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        let task = URLSession(configuration: configuration).webSocketTask(with: request)
        task.maximumMessageSize = AssistantRealtimeMessage.maximumBytes
        task.resume()
        return LiveAssistantSocket(task: task)
    }
}
