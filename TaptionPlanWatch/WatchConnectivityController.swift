import Foundation
import WatchConnectivity
import WidgetKit

@MainActor
final class WatchConnectivityController: NSObject, ObservableObject {
    @Published private(set) var payload: TaptionWatchPayload?
    @Published private(set) var statusText = AppLanguagePreference.text(
        korean: "iPhone 연결 중",
        english: "Connecting to iPhone"
    )

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let cachedPayloadKey = "TaptionPlan.cachedWatchPayload"
    private let pendingSensorSummariesKey =
        "TaptionPlan.pendingWatchSensorSummaries"
    private let pendingHealthSnapshotsKey =
        "TaptionPlan.pendingWatchHealthSnapshots"
    private var pendingSensorSummaries: [TaptionWatchSensorSummary] = []
    private var pendingHealthSnapshots: [TaptionWatchHealthSnapshot] = []
    private var widgetReloadFollowupTask: Task<Void, Never>?
    private var handledWorkoutRequestIDs = Set<UUID>()
    private let dayDatabase: WatchDayDatabase?
    var onWorkoutRequest: ((TaptionWatchWorkoutRequest) -> Void)?
    var onPayloadChange: ((TaptionWatchPayload) -> Void)?
    var onDataSyncRequest: (() -> Void)?

    private var didPrepare = false

    private var language: AppLanguagePreference.ResolvedLanguage {
        AppLanguagePreference.resolve(rawValue: payload?.languagePreference)
    }

    private func text(_ korean: String, _ english: String) -> String {
        language == .korean ? korean : english
    }

    override init() {
        dayDatabase = WatchDayDatabase()
        super.init()
    }

    /// 캐시 복원과 WatchConnectivity 활성화는 첫 화면이 그려진 뒤에 한다.
    /// App.init에서 수행하면 실기기에서 첫 프레임 전에 위젯·앱그룹·WC
    /// 데몬을 모두 건드리게 된다.
    func prepare() {
        guard !didPrepare else { return }
        didPrepare = true
        // 이전 실행이 어디서 멈췄는지 먼저 확보한 뒤 새 기록을 시작한다.
        pendingLaunchReport = WatchLaunchDiagnostics.pendingReport()
        WatchLaunchDiagnostics.clear()
        WatchLaunchDiagnostics.mark("prepare")
        restoreCachedPayload()
        restorePendingSensorSummaries()
        restorePendingHealthSnapshots()
        guard WCSession.isSupported() else {
            WatchLaunchDiagnostics.mark("connectivity unsupported")
            statusText = text("연결을 지원하지 않음", "Connectivity unavailable")
            return
        }
        // WCSession.delegate는 weak 참조다. SwiftUI가 소유권을 넘기기 전에
        // 해제되면 세션이 델리게이트 없는 상태로 남으므로 강한 참조를 둔다.
        Self.activeDelegate = self
        let session = WCSession.default
        session.delegate = self
        session.activate()
        WatchLaunchDiagnostics.mark("connectivity activating")
    }

    private static var activeDelegate: WatchConnectivityController?
    private var pendingLaunchReport: String?

    private func sendPendingLaunchReport() {
        guard let report = pendingLaunchReport, !report.isEmpty else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        pendingLaunchReport = nil
        session.transferUserInfo([
            TaptionWatchEnvelope.launchDiagnosticsKey: report,
        ])
    }

    private func sendDiagnosticsLog() {
        guard let report = WatchLaunchDiagnostics.currentReport(),
              !report.isEmpty else { return }
        WCSession.default.transferUserInfo([
            TaptionWatchEnvelope.diagnosticsLogKey: report,
        ])
    }

    var orderedItems: [TaptionWatchPlanItem] {
        (payload?.items ?? []).sorted { $0.startsAt < $1.startsAt }
    }

    func requestSync() {
        WatchLaunchDiagnostics.mark("manual data sync requested")
        // The button is a data-sync action, not only a payload refresh. Drain
        // the Watch's local recorder/HealthKit first; the iPhone request below
        // only refreshes the settings payload.
        onDataSyncRequest?()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        flushPendingSensorSummaries(using: session)
        flushPendingHealthSnapshots(using: session)
        let request: [String: Any] = [
            TaptionWatchEnvelope.refreshRequestKey: true,
        ]

        // Keep the reliable request independent from the live request.  A
        // WatchConnectivity reply/error callback may arrive on its private
        // operation queue; closures created from this @MainActor type then
        // trip Swift 6's actor-isolation precondition before their body runs.
        // The iPhone publishes its latest payload when it receives either
        // form of the refresh request, so no callback is needed here.
        session.transferUserInfo(request)
        if session.isReachable {
            session.sendMessage(
                request,
                replyHandler: nil,
                errorHandler: nil
            )
        }
    }

    func sendSensorSummary(_ summary: TaptionWatchSensorSummary) {
        WatchLaunchDiagnostics.mark(
            "sensor send requested sequence=\(summary.sequence) samples=\(summary.accelerometerSampleCount)"
        )
        if let dayDatabase {
            Task { @MainActor [weak self, dayDatabase] in
                do {
                    try await dayDatabase.append(summary)
                    self?.sendSensorSummaryTransport(summary)
                } catch {
                    self?.cachePending(summary)
                    WatchLaunchDiagnostics.mark("sensor store failed before send")
                }
            }
            return
        }
        sendSensorSummaryTransport(summary)
    }

    private func sendSensorSummaryTransport(
        _ summary: TaptionWatchSensorSummary
    ) {
        guard WCSession.isSupported() else {
            cachePending(summary)
            WatchLaunchDiagnostics.mark("sensor send queued unsupported")
            return
        }
        let session = WCSession.default
        guard session.activationState == .activated else {
            cachePending(summary)
            WatchLaunchDiagnostics.mark("sensor send queued inactive")
            return
        }
        if !transfer(summary, through: session) {
            cachePending(summary)
        }
    }

    func sendActivityConfirmation(
        _ confirmation: TaptionWatchActivityConfirmation
    ) {
        guard WCSession.isSupported(),
              let data = try? encoder.encode(confirmation) else {
            return
        }
        let envelope: [String: Any] = [
            TaptionWatchEnvelope.activityConfirmationKey: data,
        ]
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        session.transferUserInfo(envelope)
        if session.isReachable {
            session.sendMessage(envelope, replyHandler: nil, errorHandler: nil)
        }
    }

    func sendHealthSnapshot(_ snapshot: TaptionWatchHealthSnapshot) {
        guard WCSession.isSupported(),
              let data = try? encoder.encode(snapshot) else {
            return
        }
        let envelope: [String: Any] = [
            TaptionWatchEnvelope.healthSnapshotKey: data,
        ]
        let session = WCSession.default
        guard session.activationState == .activated else {
            cachePending(snapshot)
            return
        }
        session.transferUserInfo(envelope)
        if session.isReachable {
            session.sendMessage(envelope, replyHandler: nil, errorHandler: nil)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        let activationRawValue = session.activationState.rawValue
        let isReachable = session.isReachable
        let data = session.receivedApplicationContext[
            TaptionWatchEnvelope.payloadKey
        ] as? Data
        Task { @MainActor [weak self] in
            WatchLaunchDiagnostics.mark(
                "connectivity activated=\(activationState.rawValue) reachable=\(isReachable) error=\(error == nil ? "none" : "present")"
            )
            self?.updateStatus(
                activationRawValue: activationRawValue,
                isReachable: isReachable
            )
            if let data {
                self?.apply(data: data)
            }
            if activationState == .activated {
                self?.sendPendingLaunchReport()
                self?.sendDiagnosticsLog()
                self?.flushPendingSensorSummaries(using: .default)
                self?.flushPendingHealthSnapshots(using: .default)
                self?.requestSync()
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let activationRawValue = session.activationState.rawValue
        let isReachable = session.isReachable
        Task { @MainActor [weak self] in
            WatchLaunchDiagnostics.mark(
                "connectivity reachable=\(isReachable)"
            )
            self?.updateStatus(
                activationRawValue: activationRawValue,
                isReachable: isReachable
            )
            if isReachable {
                self?.sendDiagnosticsLog()
                self?.flushPendingSensorSummaries(using: .default)
                self?.flushPendingHealthSnapshots(using: .default)
                self?.requestSync()
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        let data = applicationContext[TaptionWatchEnvelope.payloadKey] as? Data
        Task { @MainActor [weak self] in
            if let data { self?.apply(data: data) }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        let data = message[TaptionWatchEnvelope.payloadKey] as? Data
        let workoutData = message[
            TaptionWatchEnvelope.workoutRequestKey
        ] as? Data
        let dataSyncRequested = message[
            TaptionWatchEnvelope.dataSyncRequestKey
        ] as? Bool == true
        let diagnosticsRequested = message[
            TaptionWatchEnvelope.diagnosticsRequestKey
        ] as? Bool == true
        Task { @MainActor [weak self] in
            if let data { self?.apply(data: data) }
            if let workoutData { self?.applyWorkoutRequest(data: workoutData) }
            if dataSyncRequested {
                WatchLaunchDiagnostics.mark("data sync requested")
                self?.onDataSyncRequest?()
            }
            if diagnosticsRequested {
                WatchLaunchDiagnostics.mark("diagnostics requested")
                self?.sendDiagnosticsLog()
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        if message[
            TaptionWatchEnvelope.diagnosticsRequestKey
        ] as? Bool == true {
            WatchLaunchDiagnostics.mark("diagnostics requested live")
            replyHandler([
                TaptionWatchEnvelope.diagnosticsLogKey:
                    WatchLaunchDiagnostics.currentReport() ?? "",
            ])
            return
        }
        self.session(session, didReceiveMessage: message)
        replyHandler([TaptionWatchEnvelope.acceptedKey: true])
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
        let data = userInfo[TaptionWatchEnvelope.payloadKey] as? Data
        let workoutData = userInfo[
            TaptionWatchEnvelope.workoutRequestKey
        ] as? Data
        let dataSyncRequested = userInfo[
            TaptionWatchEnvelope.dataSyncRequestKey
        ] as? Bool == true
        let diagnosticsRequested = userInfo[
            TaptionWatchEnvelope.diagnosticsRequestKey
        ] as? Bool == true
        Task { @MainActor [weak self] in
            if let data { self?.apply(data: data) }
            if let workoutData { self?.applyWorkoutRequest(data: workoutData) }
            if dataSyncRequested {
                WatchLaunchDiagnostics.mark("data sync requested background")
                self?.onDataSyncRequest?()
            }
            if diagnosticsRequested {
                WatchLaunchDiagnostics.mark("diagnostics requested background")
                self?.sendDiagnosticsLog()
            }
        }
    }

    private func applyWorkoutRequest(data: Data) {
        guard let request = try? decoder.decode(
            TaptionWatchWorkoutRequest.self,
            from: data
        ), handledWorkoutRequestIDs.insert(request.id).inserted else {
            return
        }
        if handledWorkoutRequestIDs.count > 100 {
            handledWorkoutRequestIDs = [request.id]
        }
        onWorkoutRequest?(request)
    }

    private func apply(data: Data) {
        guard let value = try? decoder.decode(
                TaptionWatchPayload.self,
                from: data
              ) else {
            return
        }
        payload = value
        updateStatus(
            activationRawValue: WCSession.default.activationState.rawValue,
            isReachable: WCSession.default.isReachable
        )
        WatchLaunchDiagnostics.mark(
            "payload applied acceleration=\(value.accelerationSettings?.profile.rawValue.description ?? "none") sync=\(value.dataSyncProfile?.rawValue.description ?? "none")"
        )
        onPayloadChange?(value)
        UserDefaults.standard.set(data, forKey: cachedPayloadKey)
        publishToWidget(value)
    }

    private func restoreCachedPayload() {
        guard let data = UserDefaults.standard.data(forKey: cachedPayloadKey),
              let value = try? decoder.decode(
                TaptionWatchPayload.self,
                from: data
              ) else {
            return
        }
        payload = value
        updateStatus(
            activationRawValue: WCSession.default.activationState.rawValue,
            isReachable: WCSession.default.isReachable
        )
        onPayloadChange?(value)
        publishToWidget(value)
    }

    private func publishToWidget(_ payload: TaptionWatchPayload) {
        guard (try? TaptionWatchWidgetStore.write(payload)) != nil else {
            return
        }
        WidgetCenter.shared.reloadTimelines(ofKind: TaptionWatchWidgetKind.status)
        widgetReloadFollowupTask?.cancel()
        widgetReloadFollowupTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            WidgetCenter.shared.reloadTimelines(
                ofKind: TaptionWatchWidgetKind.status
            )
        }
    }

    private func updateStatus(
        activationRawValue: Int,
        isReachable: Bool
    ) {
        switch activationRawValue {
        case WCSessionActivationState.notActivated.rawValue:
            statusText = text("iPhone 연결 중", "Connecting to iPhone")
        case WCSessionActivationState.inactive.rawValue:
            statusText = text("연결 대기", "Waiting for connection")
        case WCSessionActivationState.activated.rawValue:
            statusText = isReachable
                ? text("iPhone 실시간 연결", "iPhone connected")
                : text("백그라운드 동기화", "Background sync")
        default:
            statusText = text("연결 상태 확인 중", "Checking connection")
        }
    }

    private func transfer(
        _ summary: TaptionWatchSensorSummary,
        through session: WCSession
    ) -> Bool {
        guard let data = try? encoder.encode(summary) else {
            WatchLaunchDiagnostics.mark(
                "sensor encode failed sequence=\(summary.sequence)"
            )
            return false
        }
        WatchLaunchDiagnostics.mark(
            "sensor summary sequence=\(summary.sequence) samples=\(summary.accelerometerSampleCount) final=\(summary.isFinal)"
        )
        let envelope: [String: Any] = [
            TaptionWatchEnvelope.sensorSummaryKey: data,
        ]
        session.transferUserInfo(envelope)
        WatchLaunchDiagnostics.mark(
            "sensor reliable transfer scheduled sequence=\(summary.sequence)"
        )
        if session.isReachable {
            session.sendMessage(
                envelope,
                replyHandler: nil,
                errorHandler: nil
            )
        }
        return true
    }

    private func cachePending(_ summary: TaptionWatchSensorSummary) {
        pendingSensorSummaries.removeAll {
            $0.sessionID == summary.sessionID
                && $0.sequence == summary.sequence
        }
        pendingSensorSummaries.append(summary)
        pendingSensorSummaries.sort {
            if $0.startedAt == $1.startedAt {
                return $0.sequence < $1.sequence
            }
            return $0.startedAt < $1.startedAt
        }
        if pendingSensorSummaries.count > 40 {
            pendingSensorSummaries.removeFirst(
                pendingSensorSummaries.count - 40
            )
        }
        persistPendingSensorSummaries()
        WatchLaunchDiagnostics.mark(
            "sensor queue count=\(pendingSensorSummaries.count)"
        )
    }

    private func flushPendingSensorSummaries(using session: WCSession) {
        guard session.activationState == .activated,
              !pendingSensorSummaries.isEmpty else {
            return
        }
        let pending = pendingSensorSummaries
        pendingSensorSummaries = []
        if let dayDatabase {
            Task { @MainActor [weak self, dayDatabase, pending] in
                guard let self else { return }
                do {
                    try await dayDatabase.appendBatch(pending)
                } catch {
                    pending.forEach { self.cachePending($0) }
                    WatchLaunchDiagnostics.mark("sensor batch store failed before send")
                    return
                }
                self.transferPendingSensorSummaries(pending, through: session)
                self.persistPendingSensorSummaries()
            }
            persistPendingSensorSummaries()
            return
        }
        transferPendingSensorSummaries(pending, through: session)
        persistPendingSensorSummaries()
        WatchLaunchDiagnostics.mark(
            "sensor queue drained sent=\(pending.count - pendingSensorSummaries.count) remaining=\(pendingSensorSummaries.count)"
        )
    }

    private func transferPendingSensorSummaries(
        _ pending: [TaptionWatchSensorSummary],
        through session: WCSession
    ) {
        for summary in pending {
            if !transfer(summary, through: session) {
                pendingSensorSummaries.append(summary)
            }
        }
    }

    private func cachePending(_ snapshot: TaptionWatchHealthSnapshot) {
        pendingHealthSnapshots.removeAll { $0.capturedAt == snapshot.capturedAt }
        pendingHealthSnapshots.append(snapshot)
        pendingHealthSnapshots.sort { $0.capturedAt < $1.capturedAt }
        if pendingHealthSnapshots.count > 20 {
            pendingHealthSnapshots.removeFirst(pendingHealthSnapshots.count - 20)
        }
        persistPendingHealthSnapshots()
    }

    private func flushPendingHealthSnapshots(using session: WCSession) {
        guard session.activationState == .activated,
              !pendingHealthSnapshots.isEmpty else { return }
        let pending = pendingHealthSnapshots
        pendingHealthSnapshots = []
        persistPendingHealthSnapshots()
        for snapshot in pending {
            sendHealthSnapshot(snapshot)
        }
    }

    private func restorePendingHealthSnapshots() {
        guard let data = UserDefaults.standard.data(
            forKey: pendingHealthSnapshotsKey
        ),
        let values = try? decoder.decode(
            [TaptionWatchHealthSnapshot].self,
            from: data
        ) else { return }
        pendingHealthSnapshots = values
    }

    private func persistPendingHealthSnapshots() {
        if pendingHealthSnapshots.isEmpty {
            UserDefaults.standard.removeObject(forKey: pendingHealthSnapshotsKey)
            return
        }
        guard let data = try? encoder.encode(pendingHealthSnapshots) else {
            return
        }
        UserDefaults.standard.set(data, forKey: pendingHealthSnapshotsKey)
    }

    private func restorePendingSensorSummaries() {
        guard let data = UserDefaults.standard.data(
            forKey: pendingSensorSummariesKey
        ),
        let values = try? decoder.decode(
            [TaptionWatchSensorSummary].self,
            from: data
        ) else {
            return
        }
        pendingSensorSummaries = values
        WatchLaunchDiagnostics.mark(
            "sensor queue restored count=\(values.count)"
        )
    }

    private func persistPendingSensorSummaries() {
        if pendingSensorSummaries.isEmpty {
            UserDefaults.standard.removeObject(
                forKey: pendingSensorSummariesKey
            )
            return
        }
        guard let data = try? encoder.encode(pendingSensorSummaries) else {
            return
        }
        UserDefaults.standard.set(
            data,
            forKey: pendingSensorSummariesKey
        )
    }
}

extension WatchConnectivityController: WCSessionDelegate {}
