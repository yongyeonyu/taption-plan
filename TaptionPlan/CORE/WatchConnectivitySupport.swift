import Foundation
import WatchConnectivity

enum AppleWatchConnectionState: String, Sendable {
    case unsupported
    case notPaired
    case appNotInstalled
    case background
    case reachable

    var settingsLabel: String {
        switch self {
        case .unsupported: "이 iPhone에서 사용 불가"
        case .notPaired: "Apple Watch 미페어링"
        case .appNotInstalled: "워치 앱 설치 필요"
        case .background: "연결됨 · 백그라운드 동기화"
        case .reachable: "연결됨 · 실시간"
        }
    }
}

final class AppleWatchConnectivityService: NSObject, WCSessionDelegate, @unchecked Sendable {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let commandDefaults: UserDefaults
    private let commandDefaultsKey = "TaptionPlan.appliedWatchCommandIDs"
    private let lock = NSLock()
    private var commandHandler: (@Sendable (TaptionWatchCommand) -> Void)?
    private var statusHandler: (@Sendable (AppleWatchConnectionState) -> Void)?

    override init() {
        commandDefaults = UserDefaults(suiteName: "group.com.taption.plan") ?? .standard
        super.init()
    }

    func activate(
        onCommand: @escaping @Sendable (TaptionWatchCommand) -> Void,
        onStatusChange: @escaping @Sendable (AppleWatchConnectionState) -> Void
    ) {
        commandHandler = onCommand
        statusHandler = onStatusChange
        guard WCSession.isSupported() else {
            onStatusChange(.unsupported)
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        onStatusChange(connectionState(for: session))
    }

    func refreshConnectionState() {
        guard WCSession.isSupported() else {
            statusHandler?(.unsupported)
            return
        }
        statusHandler?(connectionState(for: .default))
    }

    func update(payload: TaptionWatchPayload) throws {
        guard WCSession.isSupported() else { return }
        let data = try encoder.encode(payload)
        let message: [String: Any] = [TaptionWatchEnvelope.payloadKey: data]
        let session = WCSession.default
        guard session.activationState == .activated,
              session.isPaired else {
            return
        }
        try session.updateApplicationContext(message)
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil, errorHandler: nil)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        statusHandler?(connectionState(for: session))
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        statusHandler?(connectionState(for: session))
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
        statusHandler?(connectionState(for: session))
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        statusHandler?(connectionState(for: session))
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        statusHandler?(connectionState(for: session))
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        receiveCommand(from: message)
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let accepted = receiveCommand(from: message)
        replyHandler([TaptionWatchEnvelope.acceptedKey: accepted])
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
        receiveCommand(from: userInfo)
    }

    @discardableResult
    private func receiveCommand(from envelope: [String: Any]) -> Bool {
        guard let data = envelope[TaptionWatchEnvelope.commandKey] as? Data,
              let command = try? decoder.decode(
                TaptionWatchCommand.self,
                from: data
              ),
              markCommandAsNew(command.id) else {
            return false
        }
        commandHandler?(command)
        return true
    }

    private func markCommandAsNew(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var values = commandDefaults.stringArray(forKey: commandDefaultsKey) ?? []
        let key = id.uuidString
        guard !values.contains(key) else { return false }
        values.append(key)
        if values.count > 100 {
            values.removeFirst(values.count - 100)
        }
        commandDefaults.set(values, forKey: commandDefaultsKey)
        return true
    }

    private func connectionState(
        for session: WCSession
    ) -> AppleWatchConnectionState {
        guard WCSession.isSupported() else { return .unsupported }
        guard session.isPaired else { return .notPaired }
        guard session.isWatchAppInstalled else { return .appNotInstalled }
        return session.isReachable ? .reachable : .background
    }
}
