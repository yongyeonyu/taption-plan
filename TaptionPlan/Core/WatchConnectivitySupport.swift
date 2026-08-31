import Foundation
import TaptionPlanCore
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

    func allSummaries() throws -> [TaptionWatchSensorSummary] {
        try load().sorted {
            if $0.startedAt == $1.startedAt { return $0.sequence < $1.sequence }
            return $0.startedAt < $1.startedAt
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
    case noRecentData
    case background
    case reachable

    var settingsLabel: String {
        switch self {
        case .unsupported: "이 iPhone에서 사용 불가"
        case .notPaired: "Apple Watch 미페어링"
        case .appNotInstalled: "워치 앱 설치 필요"
        case .noRecentData: "연결됨 · 최근 데이터 없음"
        case .background: "연결됨 · 백그라운드 동기화"
        case .reachable: "연결됨 · 실시간"
        }
    }
}

enum AppleWatchDataKind: String, CaseIterable, Hashable, Sendable {
    case motion
    case heartRate
    case route
    case activity
    case health
}

struct AppleWatchDataReceipt: Equatable, Sendable {
    let measuredAtByKind: [AppleWatchDataKind: Date]
    let receivedAtByKind: [AppleWatchDataKind: Date]

    var latestDataAt: Date? {
        receivedAtByKind.values.max()
    }

    func recentKinds(
        at now: Date = .now,
        window: TimeInterval = AppleWatchConnectionPolicy.recentContactWindow
    ) -> Set<AppleWatchDataKind> {
        Set(receivedAtByKind.compactMap { kind, date in
            let age = now.timeIntervalSince(date)
            return age >= 0 && age <= window ? kind : nil
        })
    }
}

struct AppleWatchDataReceiptStore {
    private static let measuredKeyPrefix =
        "TaptionPlan.watchDataMeasuredAt.v1."
    private static let receivedKeyPrefix =
        "TaptionPlan.watchDataReceivedAt.v1."
    private let defaults: UserDefaults

    init(
        defaults: UserDefaults = UserDefaults(
            suiteName: TaptionPlanSharedContainer.appGroupIdentifier
        ) ?? .standard
    ) {
        self.defaults = defaults
    }

    func load() -> AppleWatchDataReceipt {
        let measuredAtByKind: [AppleWatchDataKind: Date] = Dictionary(
            uniqueKeysWithValues: AppleWatchDataKind.allCases.compactMap { kind in
                guard let date = defaults.object(
                    forKey: Self.measuredKeyPrefix + kind.rawValue
                ) as? Date else { return nil }
                return (kind, date)
            }
        )
        // Older builds only stored the measurement time. Treat that value as
        // the first known receipt time so the menu remains useful after an
        // upgrade, while every new delivery records its real arrival time.
        return AppleWatchDataReceipt(
            measuredAtByKind: measuredAtByKind,
            receivedAtByKind: Dictionary(
                uniqueKeysWithValues: AppleWatchDataKind.allCases.compactMap { kind in
                    let receivedAt = defaults.object(
                        forKey: Self.receivedKeyPrefix + kind.rawValue
                    ) as? Date
                    guard let date = receivedAt ?? measuredAtByKind[kind]
                    else { return nil }
                    return (kind, date)
                }
            )
        )
    }

    @discardableResult
    func record(
        _ kinds: Set<AppleWatchDataKind>,
        measuredAt: Date,
        receivedAt: Date = .now
    ) -> AppleWatchDataReceipt {
        let safeMeasuredAt = min(measuredAt, receivedAt)
        for kind in kinds {
            let measuredKey = Self.measuredKeyPrefix + kind.rawValue
            if let previous = defaults.object(forKey: measuredKey) as? Date {
                if safeMeasuredAt > previous {
                    defaults.set(safeMeasuredAt, forKey: measuredKey)
                }
            } else {
                defaults.set(safeMeasuredAt, forKey: measuredKey)
            }
            let receivedKey = Self.receivedKeyPrefix + kind.rawValue
            if let previous = defaults.object(forKey: receivedKey) as? Date {
                if receivedAt > previous {
                    defaults.set(receivedAt, forKey: receivedKey)
                }
            } else {
                defaults.set(receivedAt, forKey: receivedKey)
            }
        }
        return load()
    }
}

enum AppleWatchConnectionPolicy {
    static let recentContactWindow: TimeInterval = 15 * 60

    static func state(
        isSupported: Bool,
        isPaired: Bool,
        isWatchAppInstalled: Bool,
        isReachable: Bool,
        lastContactAt: Date?,
        now: Date = .now
    ) -> AppleWatchConnectionState {
        guard isSupported else { return .unsupported }
        guard isPaired else { return .notPaired }
        let hasRecentContact = lastContactAt.map {
            now.timeIntervalSince($0) >= 0
                && now.timeIntervalSince($0) <= recentContactWindow
        } ?? false
        if hasRecentContact {
            return isReachable ? .reachable : .background
        }
        guard isWatchAppInstalled else { return .appNotInstalled }
        return .noRecentData
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
        case .noRecentData, .background, .reachable:
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
        case .noRecentData:
            AppleWatchCompanionRow(
                subtitle: "워치 앱은 설치됐지만 최근 데이터가 없습니다",
                value: "수신 대기",
                detail: "최근 15분 내 센서·건강 데이터 수신 시 연결됨으로 표시합니다."
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

enum AppleWatchDataSyncRequestStatus: Sendable, Equatable {
    case pending
    case backgroundQueued
    case noResponse
    case rejected
}

enum AppleWatchDataSyncReceiptPolicy {
    static func satisfiesPendingRequest(
        requestedAt: Date,
        expectedRequestID: String?,
        receivedRequestID: String?,
        measuredAt: Date,
        receivedAt: Date
    ) -> Bool {
        guard receivedAt >= requestedAt else { return false }
        if let receivedRequestID {
            return receivedRequestID == expectedRequestID
        }
        return measuredAt >= requestedAt
    }
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
    private let lastContactDefaultsKey = "TaptionPlan.lastWatchDataAt.v2"
    private let lock = NSLock()
    private var latestPayloadData: Data?
    private var commandHandler: (@Sendable (TaptionWatchCommand) -> Void)?
    private var sensorSummaryHandler:
        (@Sendable (TaptionWatchSensorSummary, Date, String?) -> Void)?
    private var healthSnapshotHandler:
        (@Sendable (TaptionWatchHealthSnapshot, Date, String?) -> Void)?
    /// 워치가 보낸 "맞아요 / 아니에요" 응답. AppModel이 별도로 연결한다.
    private var activityConfirmationHandler:
        (@Sendable (TaptionWatchActivityConfirmation) -> Void)?
    private var locationTrackingHandler: (@Sendable (Bool) -> Void)?
    private var locationTrackingGuidanceHandler: (@Sendable () -> Void)?
    private var statusHandler: (@Sendable (AppleWatchConnectionState) -> Void)?
    private var dataSyncLiveFailureHandler: (@Sendable (String) -> Void)?

    override init() {
        commandDefaults = UserDefaults(
            suiteName: TaptionPlanSharedContainer.appGroupIdentifier
        ) ?? .standard
        super.init()
    }

    func activate(
            onCommand: @escaping @Sendable (TaptionWatchCommand) -> Void,
            onSensorSummary: @escaping @Sendable (
                TaptionWatchSensorSummary,
                Date,
                String?
            ) -> Void,
            onHealthSnapshot: @escaping @Sendable (
                TaptionWatchHealthSnapshot,
                Date,
                String?
            ) -> Void = { _, _, _ in },
        onActivityConfirmation: @escaping @Sendable (
            TaptionWatchActivityConfirmation
        ) -> Void = { _ in },
        onLocationTracking: @escaping @Sendable (Bool) -> Void = { _ in },
        onLocationTrackingGuidance: @escaping @Sendable () -> Void = {},
        onStatusChange: @escaping @Sendable (AppleWatchConnectionState) -> Void,
        onDataSyncLiveFailure: @escaping @Sendable (String) -> Void
    ) {
        commandHandler = onCommand
        sensorSummaryHandler = onSensorSummary
        healthSnapshotHandler = onHealthSnapshot
        activityConfirmationHandler = onActivityConfirmation
        locationTrackingHandler = onLocationTracking
        locationTrackingGuidanceHandler = onLocationTrackingGuidance
        statusHandler = onStatusChange
        dataSyncLiveFailureHandler = onDataSyncLiveFailure
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
        let session = WCSession.default
        session.delegate = self
        session.activate()
        statusHandler?(connectionState(for: session))
    }

    func update(payload: TaptionWatchPayload) throws {
        let data = try encoder.encode(payload)
        storeLatestPayload(data)
        guard WCSession.isSupported() else { return }
        let message: [String: Any] = [TaptionWatchEnvelope.payloadKey: data]
        let session = WCSession.default
        let state = connectionState(for: session)
        guard session.activationState == .activated,
              state == .noRecentData
                || state == .background
                || state == .reachable else {
            return
        }
        try session.updateApplicationContext(message)
        TaptionPlanDiagnosticsLogger.shared.record(
            "watch_payload_delivered",
            fields: ["reachable": String(session.isReachable)]
        )
        if session.isReachable {
            session.sendMessage(
                message,
                replyHandler: nil,
                errorHandler: { error in
                    TaptionPlanDiagnosticsLogger.shared.record(
                        "watch_payload_message_failed",
                        level: .error,
                        fields: TaptionDiagnosticError.compactFields(
                            for: error
                        )
                    )
                }
            )
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

    @discardableResult
    func requestWatchDataSync(requestID requestedRequestID: String? = nil) -> Bool {
        let logger = TaptionPlanDiagnosticsLogger.shared
        let requestID = requestedRequestID ?? UUID().uuidString
        guard WCSession.isSupported() else {
            logger.record(
                "watch_data_sync_skipped",
                level: .notice,
                fields: [
                    "request_id": requestID,
                    "reason": "unsupported",
                ]
            )
            return false
        }
        let session = WCSession.default
        func statusFields(reason: String) -> [String: String] {
            [
                "request_id": requestID,
                "reason": reason,
                "activation_state": String(session.activationState.rawValue),
                "paired": String(session.isPaired),
                "watch_app_installed": String(session.isWatchAppInstalled),
                "reachable": String(session.isReachable),
                "connection_state": connectionState(for: session).rawValue,
            ]
        }
        guard session.activationState == .activated else {
            logger.record(
                "watch_data_sync_skipped",
                level: .notice,
                fields: statusFields(reason: "inactive")
            )
            return false
        }
        guard session.isPaired else {
            logger.record(
                "watch_data_sync_skipped",
                level: .notice,
                fields: statusFields(reason: "not_paired")
            )
            return false
        }
        guard session.isWatchAppInstalled else {
            logger.record(
                "watch_data_sync_skipped",
                level: .notice,
                fields: statusFields(reason: "watch_app_not_installed")
            )
            return false
        }
        let envelope: [String: Any] = [
            TaptionWatchEnvelope.dataSyncRequestKey: true,
            TaptionWatchEnvelope.dataSyncRequestIDKey: requestID,
        ]
        session.transferUserInfo(envelope)
        let reachable = session.isReachable
        logger.record(
            "watch_data_sync_requested",
            fields: [
                "request_id": requestID,
                "activation_state": String(session.activationState.rawValue),
                "paired": String(session.isPaired),
                "reliable_transport": "transferUserInfo",
                "reachable": String(reachable),
                "live_transport": reachable ? "sendMessage" : "none",
                "watch_app_installed": String(session.isWatchAppInstalled),
            ]
        )
        if reachable {
            session.sendMessage(
                envelope,
                replyHandler: nil,
                errorHandler: { error in
                    logger.record(
                        "watch_data_sync_message_failed",
                        level: .error,
                        fields: TaptionDiagnosticError.compactFields(
                            for: error
                        ).merging([
                            "request_id": requestID,
                        ]) { _, new in new }
                    )
                    self.dataSyncLiveFailureHandler?(requestID)
                }
            )
        }
        return true
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
        if activationState == .activated {
            publishLatestPayload()
            requestWatchDataSync()
        }
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
        if session.isReachable {
            publishLatestPayload()
            requestWatchDataSync()
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        statusHandler?(connectionState(for: session))
        publishLatestPayload()
        requestWatchDataSync()
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        receiveEnvelope(message, transport: "live_message")
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let accepted = receiveEnvelope(message, transport: "live_message_reply")
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
        receiveEnvelope(userInfo, transport: "user_info")
    }

    @discardableResult
    private func receiveEnvelope(
        _ envelope: [String: Any],
        transport: String
    ) -> Bool {
        let receivedAt = Date.now
        var latestWatchDataAt: Date?
        var accepted = receiveCommand(from: envelope)
        let requestID = envelope[
            TaptionWatchEnvelope.dataSyncRequestIDKey
        ] as? String
        var envelopeFields: [String: String] = [
            "transport": transport,
            "keys": envelope.keys.sorted().joined(separator: ","),
        ]
        if let requestID {
            envelopeFields["request_id"] = requestID
        }
        if let data = envelope[TaptionWatchEnvelope.sensorSummaryKey] as? Data {
            envelopeFields["sensor_bytes"] = String(data.count)
        }
        if let data = envelope[TaptionWatchEnvelope.healthSnapshotKey] as? Data {
            envelopeFields["health_bytes"] = String(data.count)
        }
        TaptionPlanDiagnosticsLogger.shared.record(
            "watch_envelope_received",
            fields: envelopeFields
        )
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
        ] as? Data {
            do {
                let summary = try decoder.decode(
                    TaptionWatchSensorSummary.self,
                    from: data
                )
                TaptionPlanDiagnosticsLogger.shared.record(
                    "watch_sensor_summary_received",
                    fields: [
                        "transport": transport,
                        "sequence": String(summary.sequence),
                        "samples": String(summary.accelerometerSampleCount),
                        "final": String(summary.isFinal),
                    ].merging(
                        requestID.map { ["request_id": $0] } ?? [:]
                    ) { _, new in new }
                )
                // Live and reliable delivery can contain the same summary.
                // Persistence is idempotent, so forwarding both avoids loss.
                sensorSummaryHandler?(summary, receivedAt, requestID)
                latestWatchDataAt = max(
                    latestWatchDataAt ?? summary.endedAt,
                    summary.endedAt
                )
                accepted = true
            } catch {
                TaptionPlanDiagnosticsLogger.shared.record(
                    "watch_sensor_summary_decode_failed",
                    level: .error,
                    fields: TaptionDiagnosticError.fields(for: error).merging([
                        "bytes": String(data.count),
                    ]) { _, new in new }
                )
            }
        }
        if let data = envelope[
            TaptionWatchEnvelope.healthSnapshotKey
        ] as? Data {
            do {
                let snapshot = try decoder.decode(
                    TaptionWatchHealthSnapshot.self,
                    from: data
                )
                var fields = [
                    "transport": transport,
                    "workout_count": String(snapshot.workoutCount),
                    "captured_at": String(snapshot.capturedAt.timeIntervalSince1970),
                ]
                if let requestID {
                    fields["request_id"] = requestID
                }
                TaptionPlanDiagnosticsLogger.shared.record(
                    "watch_health_snapshot_received",
                    fields: fields
                )
                healthSnapshotHandler?(snapshot, receivedAt, requestID)
                latestWatchDataAt = max(
                    latestWatchDataAt ?? snapshot.capturedAt,
                    snapshot.capturedAt
                )
                accepted = true
            } catch {
                var fields = TaptionDiagnosticError.fields(for: error)
                fields["transport"] = transport
                fields["bytes"] = String(data.count)
                if let requestID {
                    fields["request_id"] = requestID
                }
                TaptionPlanDiagnosticsLogger.shared.record(
                    "watch_health_snapshot_decode_failed",
                    level: .error,
                    fields: fields
                )
            }
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
        if let latestWatchDataAt {
            recordWatchContact(
                measuredAt: latestWatchDataAt,
                receivedAt: receivedAt,
                requestID: requestID
            )
        }
        return accepted
    }

    private func publishLatestPayload() {
        guard let data = loadLatestPayload(), WCSession.isSupported() else {
            return
        }
        let session = WCSession.default
        let state = connectionState(for: session)
        guard session.activationState == .activated,
              state == .noRecentData
                || state == .background
                || state == .reachable else {
            return
        }
        let message: [String: Any] = [TaptionWatchEnvelope.payloadKey: data]
        try? session.updateApplicationContext(message)
        TaptionPlanDiagnosticsLogger.shared.record(
            "watch_payload_republished",
            fields: ["reachable": String(session.isReachable)]
        )
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
        guard session.activationState == .activated else {
            // isWatchAppInstalled is not reliable until WCSession finishes
            // activation. Do not expose that transient false value as an
            // installation failure.
            return .noRecentData
        }
        return AppleWatchConnectionPolicy.state(
            isSupported: WCSession.isSupported(),
            isPaired: session.isPaired,
            isWatchAppInstalled: session.isWatchAppInstalled,
            isReachable: session.isReachable,
            lastContactAt: commandDefaults.object(
                forKey: lastContactDefaultsKey
            ) as? Date
        )
    }

    private func recordWatchContact(
        measuredAt: Date,
        receivedAt: Date,
        requestID: String? = nil
    ) {
        let receivedDataAt = receivedAt
        let dataAt = max(
            commandDefaults.object(forKey: lastContactDefaultsKey) as? Date
                ?? receivedDataAt,
            receivedDataAt
        )
        commandDefaults.set(dataAt, forKey: lastContactDefaultsKey)
        let session = WCSession.default
        let state = connectionState(for: session)
        statusHandler?(state)
        var fields = [
                "state": state.rawValue,
                "installed_flag": String(session.isWatchAppInstalled),
                "reachable": String(session.isReachable),
                "measured_at": String(measuredAt.timeIntervalSince1970),
                "received_at": String(dataAt.timeIntervalSince1970),
        ]
        if let requestID {
            fields["request_id"] = requestID
        }
        TaptionPlanDiagnosticsLogger.shared.record(
            "watch_contact_received",
            fields: fields
        )
    }

}
