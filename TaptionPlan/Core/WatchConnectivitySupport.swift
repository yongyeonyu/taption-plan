import Foundation
import WatchConnectivity

actor AppleWatchSensorActivityArchive {
    private let fileURL: URL
    private let retentionInterval: TimeInterval
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        fileURL: URL,
        retentionInterval: TimeInterval = 31 * 86_400
    ) {
        self.fileURL = fileURL
        self.retentionInterval = max(86_400, retentionInterval)
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        decoder.dateDecodingStrategy = .secondsSince1970
    }

    static func applicationSupport(
        fileManager: FileManager = .default
    ) throws -> AppleWatchSensorActivityArchive {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = root.appendingPathComponent(
            "TaptionPlan/WatchSensors",
            isDirectory: true
        )
        return AppleWatchSensorActivityArchive(
            fileURL: directory.appendingPathComponent(
                "watch-sensor-summaries-v1.json"
            )
        )
    }

    func record(
        _ summary: TaptionWatchSensorSummary,
        now: Date = .now
    ) throws {
        var values = try load()
        values.removeAll {
            $0.sessionID == summary.sessionID
                && $0.sequence == summary.sequence
        }
        values.append(summary)
        let cutoff = now.addingTimeInterval(-retentionInterval)
        values.removeAll { $0.endedAt < cutoff }
        values.sort {
            if $0.startedAt == $1.startedAt {
                return $0.sequence < $1.sequence
            }
            return $0.startedAt < $1.startedAt
        }
        if values.count > 20_000 {
            values.removeFirst(values.count - 20_000)
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(values).write(
            to: fileURL,
            options: [
                .atomic,
                .completeFileProtectionUntilFirstUserAuthentication,
            ]
        )
    }

    func summaries(in span: TimeSpan) throws
        -> [TaptionWatchSensorSummary] {
        try load().filter {
            TimeSpan(
                start: $0.startedAt,
                end: $0.endedAt
            ).intersection(with: span) != nil
        }
    }

    private func load() throws -> [TaptionWatchSensorSummary] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        return try decoder.decode(
            [TaptionWatchSensorSummary].self,
            from: Data(contentsOf: fileURL)
        )
    }
}

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
    private var latestPayloadData: Data?
    private var commandHandler: (@Sendable (TaptionWatchCommand) -> Void)?
    private var sensorSummaryHandler:
        (@Sendable (TaptionWatchSensorSummary) -> Void)?
    private var statusHandler: (@Sendable (AppleWatchConnectionState) -> Void)?

    override init() {
        commandDefaults = UserDefaults(suiteName: "group.com.taption.plan") ?? .standard
        super.init()
    }

    func activate(
        onCommand: @escaping @Sendable (TaptionWatchCommand) -> Void,
        onSensorSummary: @escaping @Sendable (
            TaptionWatchSensorSummary
        ) -> Void,
        onStatusChange: @escaping @Sendable (AppleWatchConnectionState) -> Void
    ) {
        commandHandler = onCommand
        sensorSummaryHandler = onSensorSummary
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
        let data = try encoder.encode(payload)
        storeLatestPayload(data)
        guard WCSession.isSupported() else { return }
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

    func requestWorkout(_ request: TaptionWatchWorkoutRequest) throws {
        guard WCSession.isSupported() else { return }
        let data = try encoder.encode(request)
        let envelope: [String: Any] = [
            TaptionWatchEnvelope.workoutRequestKey: data,
        ]
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired else {
            return
        }
        session.transferUserInfo(envelope)
        if session.isReachable {
            session.sendMessage(
                envelope,
                replyHandler: nil,
                errorHandler: nil
            )
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
        receiveEnvelope(message)
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let accepted = receiveEnvelope(message)
        var reply: [String: Any] = [
            TaptionWatchEnvelope.acceptedKey: accepted,
        ]
        if message[TaptionWatchEnvelope.refreshRequestKey] as? Bool == true,
           let data = loadLatestPayload() {
            reply[TaptionWatchEnvelope.payloadKey] = data
        }
        replyHandler(reply)
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
        receiveEnvelope(userInfo)
    }

    @discardableResult
    private func receiveEnvelope(_ envelope: [String: Any]) -> Bool {
        var accepted = receiveCommand(from: envelope)
        if envelope[TaptionWatchEnvelope.refreshRequestKey] as? Bool == true {
            publishLatestPayload()
            accepted = true
        }
        if let data = envelope[
            TaptionWatchEnvelope.sensorSummaryKey
        ] as? Data,
        let summary = try? decoder.decode(
            TaptionWatchSensorSummary.self,
            from: data
        ) {
            // The Watch may deliver the same batch once as a live message and
            // again from its reliable background queue.  Forward both copies:
            // the archive and activity upsert are idempotent, while marking a
            // batch consumed before persistence could lose it on an app crash.
            sensorSummaryHandler?(summary)
            accepted = true
        }
        return accepted
    }

    private func publishLatestPayload() {
        guard let data = loadLatestPayload(), WCSession.isSupported() else {
            return
        }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired else {
            return
        }
        let message: [String: Any] = [TaptionWatchEnvelope.payloadKey: data]
        try? session.updateApplicationContext(message)
        if session.isReachable {
            session.sendMessage(
                message,
                replyHandler: nil,
                errorHandler: nil
            )
        }
    }

    private func storeLatestPayload(_ data: Data) {
        lock.lock()
        latestPayloadData = data
        lock.unlock()
    }

    private func loadLatestPayload() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return latestPayloadData
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
