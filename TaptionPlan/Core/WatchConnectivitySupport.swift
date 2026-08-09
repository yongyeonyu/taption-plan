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

/// 첫 실행에서 한 번만 보여 주는 Apple Watch 안내.
enum AppleWatchOnboardingPrompt: String, Sendable, CaseIterable {
    /// 워치는 있는데 워치 앱이 없다. 설치를 권한다.
    case installInvitation
    /// 페어링된 워치가 없다. 워치가 있어야 되는 것만 알린다.
    case watchlessLimitations
}

/// 연결 상태를 안내 한 줄로 옮기는 규칙. `WCSession` 값은 세션이 활성화된
/// 뒤에야 뜻이 생기고 나중에 바뀌기도 해서, 판단을 값 계산으로 떼어내
/// 화면과 저장은 이 결과만 본다. 시뮬레이터에는 페어링된 워치가 없으므로
/// 테스트도 여기만 본다.
enum AppleWatchOnboarding {
    static func prompt(
        for state: AppleWatchConnectionState,
        dismissed: Set<AppleWatchOnboardingPrompt>,
        hasSeenWatchAppInstalled: Bool
    ) -> AppleWatchOnboardingPrompt? {
        let candidate: AppleWatchOnboardingPrompt?
        switch state {
        // iPad이거나 아직 세션이 활성화되기 전이다. 워치가 없다고 단정할 수
        // 없으므로 아무것도 말하지 않는다.
        case .unsupported:
            candidate = nil
        case .notPaired:
            candidate = .watchlessLimitations
        // 한 번이라도 설치를 확인했다면 사용자가 직접 지운 것이다. 다시
        // 권하지 않는다.
        case .appNotInstalled:
            candidate = hasSeenWatchAppInstalled ? nil : .installInvitation
        case .background, .reachable:
            candidate = nil
        }
        guard let candidate, !dismissed.contains(candidate) else { return nil }
        return candidate
    }

    /// 워치가 없을 때 실제로 줄어드는 것. 아이폰이 이미 하는 일을 없다고
    /// 적으면 거짓말이 되므로, 워치 신호에서만 나오는 것만 적는다.
    static let watchlessLimitations = [
        "계단·엘리베이터·양치·타이핑처럼 손목 움직임으로 나뉘는 세부 행동. iPhone만으로는 정지·걷기·달리기·자전거·자동차까지 구분합니다.",
        "‘집안일’ 구분. 집에 머문 시간을 집안일과 휴식으로 가르지 못합니다.",
        "심박수. 앱이 심박수를 읽을 수 있는 곳은 워치뿐입니다.",
        "이동수단을 확정해 주는 워치 운동 기록. 대신 GPS·기압·걸음으로 추정합니다.",
        "손목에서 바로 시작하는 기록과 되묻기.",
    ]

    /// 워치가 없어도 그대로인 것. 손해를 부풀리지 않기 위해 함께 보여 준다.
    static let iPhoneOnlyCoverage =
        "걸음·거리·층수, 걷기·달리기·자전거·자동차 구분, 장소와 이동 경로, 날씨, 앱 사용시간, 사진, 캘린더, 회의·통화·근무 같은 머문 자리 구분은 iPhone만으로 그대로 기록됩니다."

    /// Watch 앱을 여는 공개 URL 스킴은 없다. 눌러도 아무 일이 없을 수 있는
    /// 버튼 대신 찾아가는 길을 글로 적는다.
    static let installInstruction =
        "iPhone의 Watch 앱 → 나의 시계 → 사용 가능한 앱 → Taption Plan에서 ‘설치’"

    /// 설정에 늘 있는 줄. 안내를 닫았거나 못 본 사람도 워치 앱이 있다는 것을
    /// 여기서 알 수 있어야 해서 사라지지 않고, 상태에 따라 문구만 바뀐다.
    static func companionRow(
        for state: AppleWatchConnectionState
    ) -> AppleWatchCompanionRow {
        switch state {
        // 아직 워치를 못 찾았거나 확인할 수 없는 기기다. 있다는 사실과 무엇이
        // 더해지는지만 알린다.
        case .unsupported, .notPaired:
            AppleWatchCompanionRow(
                subtitle: "손목 센서로 하루를 함께 적는 워치 앱이 있습니다",
                value: "안내",
                detail: "Apple Watch를 연결하면 \(watchlessLimitations.count)가지가 더해집니다. \(iPhoneOnlyCoverage)"
            )
        case .appNotInstalled:
            AppleWatchCompanionRow(
                subtitle: "연결된 Apple Watch에 아직 설치되지 않았습니다",
                value: "설치 필요",
                detail: installInstruction
            )
        case .background, .reachable:
            AppleWatchCompanionRow(
                subtitle: "Apple Watch에 설치되어 손목 센서를 함께 기록합니다",
                value: "설치됨",
                detail: nil
            )
        }
    }
}

struct AppleWatchCompanionRow: Sendable, Equatable {
    let subtitle: String
    let value: String
    let detail: String?
}

/// 안내를 닫은 기록. 워치를 가진 기기가 어느 것인지는 계정이 아니라 기기의
/// 성질이라서 iCloud 스냅샷이 아니라 기기 저장소에 남긴다. 덕분에
/// `cloudPortableSnapshot` / `mergeDeviceLocalData`의 손으로 적은 목록에
/// 새 항목을 더할 일이 없다.
struct AppleWatchOnboardingStore {
    private let defaults: UserDefaults
    private let dismissedKey = "taption.apple-watch-onboarding.dismissed.v1"
    private let installedKey = "taption.apple-watch-onboarding.installed.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var dismissed: Set<AppleWatchOnboardingPrompt> {
        Set(
            (defaults.stringArray(forKey: dismissedKey) ?? [])
                .compactMap(AppleWatchOnboardingPrompt.init(rawValue:))
        )
    }

    var hasSeenWatchAppInstalled: Bool {
        defaults.bool(forKey: installedKey)
    }

    func dismiss(_ prompt: AppleWatchOnboardingPrompt) {
        var values = dismissed
        values.insert(prompt)
        defaults.set(
            values.map(\.rawValue).sorted(),
            forKey: dismissedKey
        )
    }

    func markWatchAppInstalled() {
        defaults.set(true, forKey: installedKey)
    }
}

final class AppleWatchConnectivityService: NSObject, WCSessionDelegate, @unchecked Sendable {
    private final class DiagnosticsReplyGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String?, Never>?

        init(_ continuation: CheckedContinuation<String?, Never>) {
            self.continuation = continuation
        }

        func finish(_ value: String?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let commandDefaults: UserDefaults
    private let commandDefaultsKey = "TaptionPlan.appliedWatchCommandIDs"
    private let confirmationDefaultsKey =
        "TaptionPlan.appliedWatchConfirmationIDs"
    private let lock = NSLock()
    private var latestPayloadData: Data?
    private var commandHandler: (@Sendable (TaptionWatchCommand) -> Void)?
    private var sensorSummaryHandler:
        (@Sendable (TaptionWatchSensorSummary) -> Void)?
    private var healthSnapshotHandler:
        (@Sendable (TaptionWatchHealthSnapshot) -> Void)?
    /// 워치가 보낸 "맞아요 / 아니에요" 응답. AppModel이 별도로 연결한다.
    private var activityConfirmationHandler:
        (@Sendable (TaptionWatchActivityConfirmation) -> Void)?
    private var locationTrackingHandler: (@Sendable (Bool) -> Void)?
    private var locationTrackingGuidanceHandler: (@Sendable () -> Void)?
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
        onHealthSnapshot: @escaping @Sendable (
            TaptionWatchHealthSnapshot
        ) -> Void = { _ in },
        onActivityConfirmation: @escaping @Sendable (
            TaptionWatchActivityConfirmation
        ) -> Void = { _ in },
        onLocationTracking: @escaping @Sendable (Bool) -> Void = { _ in },
        onLocationTrackingGuidance: @escaping @Sendable () -> Void = {},
        onStatusChange: @escaping @Sendable (AppleWatchConnectionState) -> Void
    ) {
        commandHandler = onCommand
        sensorSummaryHandler = onSensorSummary
        healthSnapshotHandler = onHealthSnapshot
        activityConfirmationHandler = onActivityConfirmation
        locationTrackingHandler = onLocationTracking
        locationTrackingGuidanceHandler = onLocationTrackingGuidance
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

    func requestWatchDataSync() {
        guard WCSession.isSupported() else { return }
        let envelope: [String: Any] = [
            TaptionWatchEnvelope.dataSyncRequestKey: true,
        ]
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired else {
            return
        }
        session.transferUserInfo(envelope)
        if session.isReachable {
            session.sendMessage(envelope, replyHandler: nil, errorHandler: nil)
        }
    }

    func requestDiagnosticsLog() async -> String? {
        let cached = WatchDiagnosticsLogStore.read()
        guard WCSession.isSupported() else { return cached }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired else {
            return cached
        }
        let request: [String: Any] = [
            TaptionWatchEnvelope.diagnosticsRequestKey: true,
        ]
        session.transferUserInfo(request)
        guard session.isReachable else { return cached }
        return await withCheckedContinuation { continuation in
            let gate = DiagnosticsReplyGate(continuation)
            session.sendMessage(
                request,
                replyHandler: { reply in
                    let report = reply[
                        TaptionWatchEnvelope.diagnosticsLogKey
                    ] as? String
                    if let report, !report.isEmpty {
                        WatchDiagnosticsLogStore.save(report)
                    }
                    gate.finish(report?.isEmpty == false ? report : cached)
                },
                errorHandler: { _ in
                    gate.finish(cached)
                }
            )
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + 2
            ) {
                gate.finish(WatchDiagnosticsLogStore.read() ?? cached)
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        TaptionPlanDiagnosticsLogger.shared.record(
            "watch_connectivity_activation",
            fields: [
                "state": String(activationState.rawValue),
                "error": error == nil ? "false" : "true",
            ]
        )
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
        if let report = envelope[
            TaptionWatchEnvelope.launchDiagnosticsKey
        ] as? String {
            WatchLaunchReportStore.save(report)
            accepted = true
        }
        if let report = envelope[
            TaptionWatchEnvelope.diagnosticsLogKey
        ] as? String, !report.isEmpty {
            WatchDiagnosticsLogStore.save(report)
            TaptionPlanDiagnosticsLogger.shared.record(
                "watch_diagnostics_received",
                fields: ["bytes": String(report.utf8.count)]
            )
            accepted = true
        }
        if let data = envelope[
            TaptionWatchEnvelope.sensorSummaryKey
        ] as? Data,
        let summary = try? decoder.decode(
            TaptionWatchSensorSummary.self,
            from: data
        ) {
            TaptionPlanDiagnosticsLogger.shared.record(
                "watch_sensor_summary_received",
                fields: [
                    "sequence": String(summary.sequence),
                    "samples": String(summary.accelerometerSampleCount),
                    "final": String(summary.isFinal),
                ]
            )
            // The Watch may deliver the same batch once as a live message and
            // again from its reliable background queue.  Forward both copies:
            // the archive and activity upsert are idempotent, while marking a
            // batch consumed before persistence could lose it on an app crash.
            sensorSummaryHandler?(summary)
            accepted = true
        }
        if let data = envelope[
            TaptionWatchEnvelope.healthSnapshotKey
        ] as? Data,
        let snapshot = try? decoder.decode(
            TaptionWatchHealthSnapshot.self,
            from: data
        ) {
            TaptionPlanDiagnosticsLogger.shared.record(
                "watch_health_snapshot_received"
            )
            healthSnapshotHandler?(snapshot)
            accepted = true
        }
        if let data = envelope[
            TaptionWatchEnvelope.activityConfirmationKey
        ] as? Data,
        let confirmation = try? decoder.decode(
            TaptionWatchActivityConfirmation.self,
            from: data
        ),
        // 확인 응답은 실시간 메시지와 백그라운드 큐로 두 번 도착할 수 있다.
        markAsNew(confirmation.id, key: confirmationDefaultsKey) {
            activityConfirmationHandler?(confirmation)
            accepted = true
        }
        if let enabled = envelope[
            TaptionWatchEnvelope.locationTrackingKey
        ] as? Bool {
            locationTrackingHandler?(enabled)
            accepted = true
        }
        if envelope[
            TaptionWatchEnvelope.locationTrackingGuidanceKey
        ] as? Bool == true {
            locationTrackingGuidanceHandler?()
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
              markAsNew(command.id, key: commandDefaultsKey) else {
            return false
        }
        commandHandler?(command)
        return true
    }

    private func markAsNew(_ id: UUID, key storeKey: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var values = commandDefaults.stringArray(forKey: storeKey) ?? []
        let key = id.uuidString
        guard !values.contains(key) else { return false }
        values.append(key)
        if values.count > 100 {
            values.removeFirst(values.count - 100)
        }
        commandDefaults.set(values, forKey: storeKey)
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
