import Foundation
import TaptionPlanCore
import WatchConnectivity

enum AppleWatchConnectionState: String, Sendable {
    case unsupported
    case notPaired
    case appNotInstalled
    case noRecentData
    case background
    case reachable

    var settingsLabel: String {
        settingsLabel(preference: .current)
    }

    func settingsLabel(preference: AppLanguagePreference) -> String {
        switch self {
        case .unsupported:
            AppLanguagePreference.text(
                korean: "이 iPhone에서 사용 불가",
                english: "Unavailable on this iPhone",
                preference: preference
            )
        case .notPaired:
            AppLanguagePreference.text(
                korean: "Apple Watch 미페어링",
                english: "Apple Watch not paired",
                preference: preference
            )
        case .appNotInstalled:
            AppLanguagePreference.text(
                korean: "워치 앱 설치 필요",
                english: "Watch app installation needed",
                preference: preference
            )
        case .noRecentData:
            AppLanguagePreference.text(
                korean: "연결됨 · 최근 데이터 없음",
                english: "Connected · No recent data",
                preference: preference
            )
        case .background:
            AppLanguagePreference.text(
                korean: "연결됨 · 백그라운드 동기화",
                english: "Connected · Background sync",
                preference: preference
            )
        case .reachable:
            AppLanguagePreference.text(
                korean: "연결됨 · 실시간",
                english: "Connected · Live",
                preference: preference
            )
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

    func clear() {
        for kind in AppleWatchDataKind.allCases {
            defaults.removeObject(
                forKey: Self.measuredKeyPrefix + kind.rawValue
            )
            defaults.removeObject(
                forKey: Self.receivedKeyPrefix + kind.rawValue
            )
        }
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

enum AppleWatchAutomaticSyncPolicy {
    static let minimumInterval: TimeInterval = 10

    static func shouldRequest(
        lastRequestUptime: TimeInterval?,
        nowUptime: TimeInterval
    ) -> Bool {
        guard let lastRequestUptime else { return true }
        return nowUptime < lastRequestUptime
            || nowUptime - lastRequestUptime >= minimumInterval
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
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let commandDefaults: UserDefaults
    private let commandDefaultsKey = "TaptionPlan.appliedWatchCommandIDs"
    private let confirmationDefaultsKey =
        "TaptionPlan.appliedWatchConfirmationIDs"
    private let lastContactDefaultsKey = "TaptionPlan.lastWatchDataAt.v2"
    private let watchAppVersionDefaultsKey = "TaptionPlan.watchAppVersion"
    private let lock = NSLock()
    private var lastAutomaticSyncUptime: TimeInterval?
    private var latestPayloadData: Data?
    private var commandHandler: (@Sendable (TaptionWatchCommand) -> Void)?
    private var sensorSummaryHandler:
        (@Sendable (TaptionWatchSensorSummary, Date, String?, String?) -> Void)?
    private var accelerationChunkHandler:
        (@Sendable (TaptionWatchAccelerationChunk, Date, String?, String?) -> Void)?
    var onAmbientAcknowledgementRequested: (@Sendable (String) -> Void)?
    private var healthSnapshotHandler:
        (@Sendable (TaptionWatchHealthSnapshot, Date, String?) -> Void)?
    /// 워치가 보낸 "맞아요 / 아니에요" 응답. AppModel이 별도로 연결한다.
    private var activityConfirmationHandler:
        (@Sendable (TaptionWatchActivityConfirmation, Date) -> Void)?
    private var locationTrackingHandler: (@Sendable (Bool) -> Void)?
    private var locationTrackingGuidanceHandler: (@Sendable () -> Void)?
    private var statusHandler: (@Sendable (AppleWatchConnectionState) -> Void)?
    private var dataSyncLiveFailureHandler: (@Sendable (String) -> Void)?

    var isWatchPaired: Bool {
        guard WCSession.isSupported() else { return false }
        let session = WCSession.default
        return session.activationState == .activated && session.isPaired
    }

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
                String?,
                String?
            ) -> Void,
            onAccelerationChunk: @escaping @Sendable (
                TaptionWatchAccelerationChunk,
                Date,
                String?,
                String?
            ) -> Void = { _, _, _, _ in },
            onHealthSnapshot: @escaping @Sendable (
                TaptionWatchHealthSnapshot,
                Date,
                String?
            ) -> Void = { _, _, _ in },
        onActivityConfirmation: @escaping @Sendable (
            TaptionWatchActivityConfirmation,
            Date
        ) -> Void = { _, _ in },
        onLocationTracking: @escaping @Sendable (Bool) -> Void = { _ in },
        onLocationTrackingGuidance: @escaping @Sendable () -> Void = {},
        onStatusChange: @escaping @Sendable (AppleWatchConnectionState) -> Void,
        onDataSyncLiveFailure: @escaping @Sendable (String) -> Void
    ) {
        commandHandler = onCommand
        sensorSummaryHandler = onSensorSummary
        accelerationChunkHandler = onAccelerationChunk
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

    func acknowledgeAmbientDelivery(_ id: String) {
        guard id.hasPrefix("summary:") || id.hasPrefix("chunk:") else {
            return
        }
        onAmbientAcknowledgementRequested?(id)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let envelope: [String: Any] = [
            TaptionWatchEnvelope.ambientAcknowledgementKey: id,
        ]
        session.transferUserInfo(envelope)
        if session.isReachable {
            session.sendMessage(envelope, replyHandler: nil, errorHandler: { error in
                TaptionPlanDiagnosticsLogger.shared.record(
                    "watch_ambient_live_ack_failed",
                    level: .notice,
                    fields: ["code": String((error as NSError).code)]
                )
            })
        }
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

    func requestWatchDataDeletion(
        generation: UInt64,
        requestID: String = UUID().uuidString
    ) async -> Bool {
        let logger = TaptionPlanDiagnosticsLogger.shared
        guard WCSession.isSupported() else { return false }
        let session = WCSession.default
        guard session.activationState == .activated,
              session.isPaired,
              session.isWatchAppInstalled else {
            logger.record(
                "watch_purge_request_rejected",
                level: .notice,
                fields: ["request_id": requestID]
            )
            return false
        }
        let envelope: [String: Any] = [
            TaptionWatchEnvelope.purgeRequestKey: true,
            TaptionWatchEnvelope.purgeRequestIDKey: requestID,
            TaptionWatchEnvelope.purgeGenerationKey: String(generation),
        ]
        session.transferUserInfo(envelope)
        guard session.isReachable else {
            logger.record(
                "watch_purge_queued_without_ack",
                level: .notice,
                fields: ["request_id": requestID]
            )
            return false
        }
        return await withCheckedContinuation { continuation in
            let gate = OneShotReply(continuation)
            session.sendMessage(
                envelope,
                replyHandler: { reply in
                    let acknowledged = reply[
                        TaptionWatchEnvelope.purgeAcknowledgedKey
                    ] as? Bool == true
                    let replyID = reply[
                        TaptionWatchEnvelope.purgeRequestIDKey
                    ] as? String
                    logger.record(
                        "watch_purge_reply_received",
                        fields: [
                            "request_id": requestID,
                            "acknowledged": String(
                                acknowledged && replyID == requestID
                            ),
                        ]
                    )
                    gate.finish(acknowledged && replyID == requestID)
                },
                errorHandler: { error in
                    logger.record(
                        "watch_purge_message_failed",
                        level: .error,
                        fields: TaptionDiagnosticError.fields(for: error)
                            .merging(["request_id": requestID]) {
                                _, new in new
                            }
                    )
                    gate.finish(false)
                }
            )
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + 5
            ) {
                gate.finish(false)
            }
        }
    }

    func watchDataDeletionRequired() -> Bool {
        guard WCSession.isSupported() else { return false }
        let session = WCSession.default
        return session.activationState == .activated
            && session.isPaired
            && session.isWatchAppInstalled
    }

    func clearLocalState() {
        lock.lock()
        latestPayloadData = nil
        lastAutomaticSyncUptime = nil
        lock.unlock()
        commandDefaults.removeObject(forKey: commandDefaultsKey)
        commandDefaults.removeObject(forKey: confirmationDefaultsKey)
        commandDefaults.removeObject(forKey: lastContactDefaultsKey)
        commandDefaults.removeObject(forKey: watchAppVersionDefaultsKey)
        TaptionWatchCommandCapabilityStore.clear()
    }

    func requestWatchDataSyncIfDue() {
        guard AppleWatchLink.isEnabled() else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let shouldRequest = AppleWatchAutomaticSyncPolicy.shouldRequest(
            lastRequestUptime: lastAutomaticSyncUptime,
            nowUptime: now
        )
        if shouldRequest {
            lastAutomaticSyncUptime = now
        }
        lock.unlock()
        guard shouldRequest else { return }
        guard !requestWatchDataSync() else { return }
        lock.lock()
        if lastAutomaticSyncUptime == now {
            lastAutomaticSyncUptime = nil
        }
        lock.unlock()
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
            let gate = OneShotReply(continuation)
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

    var watchAppVersion: TaptionWatchAppVersion? {
        commandDefaults.data(forKey: watchAppVersionDefaultsKey)
            .flatMap { try? JSONDecoder().decode(TaptionWatchAppVersion.self, from: $0) }
    }

    private func storeWatchAppVersion(from context: [String: Any]) {
        guard let version = TaptionWatchAppVersion(context: context),
              let data = try? JSONEncoder().encode(version) else { return }
        commandDefaults.set(data, forKey: watchAppVersionDefaultsKey)
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        storeWatchAppVersion(from: applicationContext)
        statusHandler?(connectionState(for: session))
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        storeWatchAppVersion(from: session.receivedApplicationContext)
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
            requestWatchDataSyncIfDue()
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
            requestWatchDataSyncIfDue()
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        statusHandler?(connectionState(for: session))
        publishLatestPayload()
        requestWatchDataSyncIfDue()
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
        var accepted = receiveCommand(from: envelope, receivedAt: receivedAt)
        let requestID = envelope[
            TaptionWatchEnvelope.dataSyncRequestIDKey
        ] as? String
        let ambientDeliveryID = envelope[
            TaptionWatchEnvelope.ambientDeliveryIDKey
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
        if let data = envelope[TaptionWatchEnvelope.accelerationChunkKey]
            as? Data {
            envelopeFields["acceleration_bytes"] = String(data.count)
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
            if report.utf8.count <= TaptionWatchEnvelope.diagnosticsMaximumBytes {
                WatchLaunchReportStore.save(report)
                accepted = true
            }
        }
        if let report = envelope[
            TaptionWatchEnvelope.diagnosticsLogKey
        ] as? String, !report.isEmpty {
            if report.utf8.count <= TaptionWatchEnvelope.diagnosticsMaximumBytes {
                WatchDiagnosticsLogStore.save(report)
                TaptionPlanDiagnosticsLogger.shared.record(
                    "watch_diagnostics_received",
                    fields: ["bytes": String(report.utf8.count)]
                )
                accepted = true
            }
        }
        if let acknowledged = envelope[
            TaptionWatchEnvelope.purgeAcknowledgedKey
        ] as? Bool,
           let purgeRequestID = envelope[
               TaptionWatchEnvelope.purgeRequestIDKey
           ] as? String {
            TaptionPlanDiagnosticsLogger.shared.record(
                "watch_purge_background_ack_received",
                fields: [
                    "request_id": purgeRequestID,
                    "acknowledged": String(acknowledged),
                ]
            )
            accepted = true
        }
        if let data = envelope[
            TaptionWatchEnvelope.sensorSummaryKey
        ] as? Data {
            if data.count > TaptionWatchEnvelope.sensorSummaryMaximumBytes {
                TaptionPlanDiagnosticsLogger.shared.record(
                    "watch_sensor_summary_decode_failed",
                    level: .error,
                    fields: ["reason": "payload_too_large", "bytes": String(data.count)]
                )
            } else {
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
                sensorSummaryHandler?(
                    summary,
                    receivedAt,
                    requestID,
                    ambientDeliveryID
                )
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
        }
        if let data = envelope[
            TaptionWatchEnvelope.accelerationChunkKey
        ] as? Data {
            if data.count > TaptionWatchEnvelope.accelerationChunkMaximumBytes {
                TaptionPlanDiagnosticsLogger.shared.record(
                    "watch_acceleration_chunk_decode_failed",
                    level: .error,
                    fields: ["reason": "payload_too_large", "bytes": String(data.count)]
                )
            } else {
            do {
                let chunk = try decoder.decode(
                    TaptionWatchAccelerationChunk.self,
                    from: data
                )
                TaptionPlanDiagnosticsLogger.shared.record(
                    "watch_acceleration_chunk_received",
                    fields: [
                        "transport": transport,
                        "chunk": chunk.id.uuidString,
                        "samples": String(chunk.samples.count),
                        "sequence": String(chunk.sequence),
                        "final": String(chunk.isFinal),
                    ].merging(
                        requestID.map { ["request_id": $0] } ?? [:]
                    ) { _, new in new }
                )
                accelerationChunkHandler?(
                    chunk,
                    receivedAt,
                    requestID,
                    ambientDeliveryID
                )
                latestWatchDataAt = max(
                    latestWatchDataAt ?? chunk.endedAt,
                    chunk.endedAt
                )
                accepted = true
            } catch {
                TaptionPlanDiagnosticsLogger.shared.record(
                    "watch_acceleration_chunk_decode_failed",
                    level: .error,
                    fields: TaptionDiagnosticError.fields(for: error).merging([
                        "bytes": String(data.count),
                    ]) { _, new in new }
                )
            }
            }
        }
        if let data = envelope[
            TaptionWatchEnvelope.healthSnapshotKey
        ] as? Data {
            if data.count > TaptionWatchEnvelope.healthSnapshotMaximumBytes {
                TaptionPlanDiagnosticsLogger.shared.record(
                    "watch_health_snapshot_decode_failed",
                    level: .error,
                    fields: ["reason": "payload_too_large", "bytes": String(data.count)]
                )
            } else {
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
        }
        if let data = envelope[
            TaptionWatchEnvelope.activityConfirmationKey
        ] as? Data,
        data.count <= TaptionWatchEnvelope.confirmationMaximumBytes,
        let confirmation = try? decoder.decode(
            TaptionWatchActivityConfirmation.self,
            from: data
        ),
        // 확인 응답은 실시간 메시지와 백그라운드 큐로 두 번 도착할 수 있다.
        markAsNew(confirmation.id, key: confirmationDefaultsKey) {
            activityConfirmationHandler?(confirmation, receivedAt)
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
    private func receiveCommand(
        from envelope: [String: Any],
        receivedAt: Date
    ) -> Bool {
        guard !TaptionExternalPrivacyStore.isLocked,
              let data = envelope[TaptionWatchEnvelope.commandKey] as? Data,
              data.count <= TaptionWatchEnvelope.commandMaximumBytes,
              let command = try? decoder.decode(
                TaptionWatchCommand.self,
                from: data
              ),
              let command = command.retainingData(receivedAt: receivedAt),
              TaptionWatchCommandCapabilityStore.consume(
                  command,
                  at: receivedAt
              ) else {
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
