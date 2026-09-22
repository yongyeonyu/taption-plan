import Foundation
import WatchConnectivity
import WidgetKit

@MainActor
final class WatchConnectivityController: NSObject, ObservableObject {
    private final class PurgeReplyHandler: @unchecked Sendable {
        private let handler: ([String: Any]) -> Void

        init(_ handler: @escaping ([String: Any]) -> Void) {
            self.handler = handler
        }

        func finish(requestID: String, succeeded: Bool) {
            handler([
                TaptionWatchEnvelope.purgeRequestIDKey: requestID,
                TaptionWatchEnvelope.purgeAcknowledgedKey: succeeded,
            ])
        }
    }

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
    private let pendingAccelerationChunksKey =
        "TaptionPlan.pendingWatchAccelerationChunks"
    private let pendingHealthSnapshotsKey =
        "TaptionPlan.pendingWatchHealthSnapshots"
    private let ambientOutboxRetryAttemptsKey =
        "TaptionPlan.ambientOutboxRetryAttempts"
    private let completedPurgeGenerationKey =
        "TaptionPlan.completedWatchPurgeGeneration"
    private var pendingSensorSummaries: [TaptionWatchSensorSummary] = []
    private var pendingAccelerationChunks: [TaptionWatchAccelerationChunk] = []
    private var pendingHealthSnapshots: [TaptionWatchHealthSnapshot] = []
    private var widgetReloadFollowupTask: Task<Void, Never>?
    private var handledWorkoutRequestIDs = Set<UUID>()
    private var dataSyncRequestGate = TaptionWatchDataSyncRequestGate()
    private var activeDataSyncRequestID: String? {
        dataSyncRequestGate.activeRequestID
    }
    private var activePurge:
        (id: UUID, generation: UInt64, task: Task<Bool, Never>)?
    private var sensorWriteTasks: [UUID: Task<Void, Never>] = [:]
    private var isPurgingData = false
    private let dayDatabase: WatchDayDatabase?
    var onWorkoutRequest: ((TaptionWatchWorkoutRequest) -> Void)?
    var onPayloadChange: ((TaptionWatchPayload) -> Void)?
    var onDataSyncRequest: ((String) -> Void)?
    var onPurgeRequest:
        ((@MainActor () async throws -> Void) async -> Bool)?

    private var didPrepare = false
    private var didActivateConnectivity = false
    private var isFlushingAmbientOutbox = false
    private var ambientOutboxFlushRequested = false
    private var ambientOutboxFlushTask: Task<Void, Never>?
    private var ambientOutboxFlushGeneration: UInt64 = 0
    private var ambientOutboxRetryTask: Task<Void, Never>?
    private var ambientOutboxRetryID: UUID?
    private var ambientOutboxRetryAttempts: [String: Int] = [:]
    private var legacyAmbientAdoptionID: UUID?
    private var legacyAmbientAdoptionTask: Task<Void, Never>?

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
        restorePendingAccelerationChunks()
        restorePendingHealthSnapshots()
        restoreAmbientOutboxRetryAttempts()
        activateConnectivity()
        Task { @MainActor [weak self] in
            await self?.adoptLegacyAmbientQueue()
            self?.handleActivatedSessionIfReady()
        }
    }

    private static var activeDelegate: WatchConnectivityController?
    private var pendingLaunchReport: String?

    private func handleActivatedSessionIfReady() {
        guard didPrepare,
              WCSession.default.activationState == .activated else {
            return
        }
        sendPendingLaunchReport()
        sendDiagnosticsLog()
        flushPendingAmbientOutbox(using: .default)
        flushPendingSensorSummaries(using: .default)
        flushPendingAccelerationChunks(using: .default)
        flushPendingHealthSnapshots(using: .default)
        requestSync()
    }

    private func adoptLegacyAmbientQueue() async {
        guard !isPurgingData, let dayDatabase else { return }
        if let legacyAmbientAdoptionTask {
            await legacyAmbientAdoptionTask.value
            return
        }
        let summaries = pendingSensorSummaries.filter { $0.isAmbient == true }
        let chunks = pendingAccelerationChunks.filter(\.isAmbient)
        guard !summaries.isEmpty || !chunks.isEmpty else { return }
        let adoptedSummaries = Set(summaries)
        let adoptedChunks = Set(chunks)
        let adoptionID = UUID()
        let task = Task { @MainActor [weak self, dayDatabase] in
            do {
                try await dayDatabase.enqueueAmbientBatch(
                    summaries,
                    chunks: chunks
                )
                guard let self, !Task.isCancelled, !self.isPurgingData else {
                    return
                }
                TaptionWatchAmbientQueueAdoption.removePersistedSummaries(
                    from: &self.pendingSensorSummaries,
                    snapshot: adoptedSummaries
                )
                TaptionWatchAmbientQueueAdoption.removePersistedChunks(
                    from: &self.pendingAccelerationChunks,
                    snapshot: adoptedChunks
                )
                self.persistPendingSensorSummaries()
                self.persistPendingAccelerationChunks()
            } catch {
                WatchLaunchDiagnostics.mark(
                    "legacy ambient queue adoption failed error=\(error.localizedDescription)"
                )
            }
        }
        legacyAmbientAdoptionID = adoptionID
        legacyAmbientAdoptionTask = task
        await task.value
        if legacyAmbientAdoptionID == adoptionID {
            legacyAmbientAdoptionID = nil
            legacyAmbientAdoptionTask = nil
        }
    }

    /// `transferUserInfo`는 화면이 그려진 뒤가 아니라 Watch 앱이 백그라운드로
    /// 깨는 순간에도 delegate가 등록되어 있어야 전달된다. 센서 하드웨어는
    /// 건드리지 않고 WCSession만 먼저 활성화한다.
    func activateConnectivity() {
        guard !didActivateConnectivity else { return }
        didActivateConnectivity = true
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
        guard !isPurgingData else { return }
        let requestID = UUID().uuidString
        // The button must drain the Watch's local recorder before asking the
        // iPhone to refresh. Previously it only sent refreshRequest, so an
        // already-recorded Watch window never reached the iPhone.
        guard WCSession.isSupported() else {
            WatchLaunchDiagnostics.mark(
                "data sync transport skipped id=\(requestID) reason=unsupported"
            )
            return
        }
        let session = WCSession.default
        guard session.activationState == .activated else {
            WatchLaunchDiagnostics.mark(
                "data sync transport skipped id=\(requestID) reason=inactive state=\(session.activationState.rawValue)"
            )
            return
        }
        guard beginDataSyncRequest(
            requestID: requestID,
            source: "watch_button"
        ) else {
            return
        }
        flushPendingSensorSummaries(using: session)
        flushPendingAccelerationChunks(using: session)
        flushPendingHealthSnapshots(using: session)
        let request: [String: Any] = [
            TaptionWatchEnvelope.refreshRequestKey: true,
            TaptionWatchEnvelope.dataSyncRequestIDKey: requestID,
        ]

        // Keep the reliable request independent from the live request. The
        // WatchConnectivity callbacks may run on a private operation queue,
        // while this controller is main-actor isolated. The queued request
        // carries the refresh if the live message cannot be delivered.
        session.transferUserInfo(request)
        WatchLaunchDiagnostics.mark(
            "refresh request scheduled id=\(requestID) reachable=\(session.isReachable)"
        )
        if session.isReachable {
            session.sendMessage(request, replyHandler: nil, errorHandler: nil)
        }
    }

    func finishDataSyncRequest(_ requestID: String) {
        guard dataSyncRequestGate.finish(requestID) else { return }
        WatchLaunchDiagnostics.mark(
            "data sync finished id=\(requestID)"
        )
    }

    @discardableResult
    private func beginDataSyncRequest(
        requestID: String?,
        source: String
    ) -> Bool {
        guard !isPurgingData else { return false }
        let resolvedID = requestID ?? UUID().uuidString
        switch dataSyncRequestGate.begin(requestID: resolvedID) {
        case let .busy(activeRequestID, rejectedRequestID):
            WatchLaunchDiagnostics.mark(
                "data sync request rejected while busy id=\(rejectedRequestID) active=\(activeRequestID) source=\(source)"
            )
            return false
        case let .duplicate(duplicateID):
            WatchLaunchDiagnostics.mark(
                "data sync duplicate ignored id=\(duplicateID) source=\(source)"
            )
            return false
        case let .accepted(acceptedID):
            let profile = payload?.dataSyncProfile?.rawValue.description ?? "none"
            WatchLaunchDiagnostics.mark(
                "data sync requested id=\(acceptedID) source=\(source) profile=\(profile) pending_sensor=\(pendingSensorSummaries.count) pending_acceleration=\(pendingAccelerationChunks.count) pending_health=\(pendingHealthSnapshots.count)"
            )
            onDataSyncRequest?(acceptedID)
            return true
        }
    }

    func sendSensorSummary(_ summary: TaptionWatchSensorSummary) {
        guard !isPurgingData else { return }
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.sensorWriteTasks[taskID] = nil }
            await self.sendSensorSummaryAndWait(summary)
        }
        sensorWriteTasks[taskID] = task
    }

    func sendSensorSummaryAndWait(_ summary: TaptionWatchSensorSummary) async {
        guard !isPurgingData else { return }
        WatchLaunchDiagnostics.mark(
            "sensor send requested sequence=\(summary.sequence) samples=\(summary.accelerometerSampleCount)"
        )
        if let dayDatabase {
            do {
                try await dayDatabase.append(summary)
            } catch {
                cachePending(summary)
                WatchLaunchDiagnostics.mark("sensor store failed before send")
                return
            }
            guard !isPurgingData else { return }
        } else {
            cachePending(summary)
        }
        guard sendSensorSummaryTransport(summary),
              TaptionWatchDurableSpoolPolicy.commitForTransfer(
                  [summary],
                  from: &pendingSensorSummaries,
                  isCancelled: Task.isCancelled,
                  isPurging: isPurgingData
              ) else { return }
        persistPendingSensorSummaries()
    }

    func sendAmbientDrainAndWait(
        summaries: [TaptionWatchSensorSummary],
        accelerationChunks: [TaptionWatchAccelerationChunk]
    ) async -> Bool {
        guard !isPurgingData else { return false }
        guard let dayDatabase else {
            return false
        }
        do {
            try await dayDatabase.enqueueAmbientBatch(
                summaries,
                chunks: accelerationChunks
            )
        } catch {
            WatchLaunchDiagnostics.mark("ambient batch store failed")
            return false
        }
        guard !isPurgingData else { return false }
        flushPendingAmbientOutbox(using: .default)
        return true
    }

    func sendAccelerationChunkAndWait(
        _ chunk: TaptionWatchAccelerationChunk
    ) async {
        guard !isPurgingData else { return }
        WatchLaunchDiagnostics.mark(
            "acceleration send requested chunk=\(chunk.id.uuidString) samples=\(chunk.samples.count)"
        )
        if let dayDatabase {
            do {
                try await dayDatabase.append(chunk)
            } catch {
                cachePending(chunk)
                WatchLaunchDiagnostics.mark(
                    "acceleration store failed before send chunk=\(chunk.id.uuidString)"
                )
                return
            }
            guard !isPurgingData else { return }
        } else {
            cachePending(chunk)
        }
        guard sendAccelerationChunkTransport(chunk),
              TaptionWatchDurableSpoolPolicy.commitForTransfer(
                  [chunk],
                  from: &pendingAccelerationChunks,
                  isCancelled: Task.isCancelled,
                  isPurging: isPurgingData
              ) else { return }
        persistPendingAccelerationChunks()
    }

    @discardableResult
    private func sendSensorSummaryTransport(
        _ summary: TaptionWatchSensorSummary
    ) -> Bool {
        guard WCSession.isSupported() else {
            cachePending(summary)
            WatchLaunchDiagnostics.mark(
                "sensor send queued unsupported sequence=\(summary.sequence)"
            )
            return false
        }
        let session = WCSession.default
        guard session.activationState == .activated else {
            cachePending(summary)
            WatchLaunchDiagnostics.mark(
                "sensor send queued inactive sequence=\(summary.sequence) state=\(session.activationState.rawValue)"
            )
            return false
        }
        let scheduled = transfer(summary, through: session)
        if !scheduled {
            cachePending(summary)
        }
        return scheduled
    }

    @discardableResult
    private func sendAccelerationChunkTransport(
        _ chunk: TaptionWatchAccelerationChunk
    ) -> Bool {
        guard WCSession.isSupported() else {
            cachePending(chunk)
            WatchLaunchDiagnostics.mark(
                "acceleration send queued unsupported chunk=\(chunk.id.uuidString)"
            )
            return false
        }
        let session = WCSession.default
        guard session.activationState == .activated else {
            cachePending(chunk)
            WatchLaunchDiagnostics.mark(
                "acceleration send queued inactive chunk=\(chunk.id.uuidString) state=\(session.activationState.rawValue)"
            )
            return false
        }
        guard let data = try? encoder.encode(chunk) else {
            cachePending(chunk)
            WatchLaunchDiagnostics.mark(
                "acceleration encode failed chunk=\(chunk.id.uuidString)"
            )
            return false
        }
        var envelope: [String: Any] = [
            TaptionWatchEnvelope.accelerationChunkKey: data,
        ]
        if let activeDataSyncRequestID {
            envelope[TaptionWatchEnvelope.dataSyncRequestIDKey] =
                activeDataSyncRequestID
        }
        session.transferUserInfo(envelope)
        WatchLaunchDiagnostics.mark(
            "acceleration reliable transfer scheduled chunk=\(chunk.id.uuidString) samples=\(chunk.samples.count) reachable=\(session.isReachable)"
        )
        if session.isReachable {
            session.sendMessage(envelope, replyHandler: nil, errorHandler: nil)
        }
        return true
    }

    func sendActivityConfirmation(
        _ confirmation: TaptionWatchActivityConfirmation
    ) {
        guard !isPurgingData,
              WCSession.isSupported(),
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

    func sendCommand(
        planID: UUID,
        kind: TaptionWatchCommandKind,
        at date: Date = .now
    ) {
        guard let capability = payload?.commandCapabilities?.first(where: {
            $0.planID == planID && $0.kind == kind && $0.expiresAt >= date
        }) else { return }
        sendCommand(
            TaptionWatchCommand(
                id: capability.commandID,
                planID: planID,
                kind: kind,
                requestedAt: date,
                capabilityToken: capability.token
            )
        )
    }

    private func sendCommand(_ command: TaptionWatchCommand) {
        guard !isPurgingData,
              WCSession.isSupported(),
              let data = try? encoder.encode(command) else {
            return
        }
        let envelope: [String: Any] = [
            TaptionWatchEnvelope.commandKey: data,
        ]
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        session.transferUserInfo(envelope)
        if session.isReachable {
            session.sendMessage(envelope, replyHandler: nil, errorHandler: nil)
        }
    }

    @discardableResult
    func sendHealthSnapshot(
        _ snapshot: TaptionWatchHealthSnapshot,
        through session: WCSession = .default
    ) -> Bool {
        guard !isPurgingData else { return false }
        let requestID = activeDataSyncRequestID ?? "none"
        guard WCSession.isSupported() else {
            cachePending(snapshot)
            WatchLaunchDiagnostics.mark(
                "health send queued unsupported id=\(requestID)"
            )
            return false
        }
        guard let data = try? encoder.encode(snapshot) else {
            cachePending(snapshot)
            WatchLaunchDiagnostics.mark(
                "health encode failed id=\(requestID)"
            )
            return false
        }
        var envelope: [String: Any] = [
            TaptionWatchEnvelope.healthSnapshotKey: data,
        ]
        if let activeDataSyncRequestID {
            envelope[TaptionWatchEnvelope.dataSyncRequestIDKey] =
                activeDataSyncRequestID
        }
        guard session.activationState == .activated else {
            cachePending(snapshot)
            WatchLaunchDiagnostics.mark(
                "health send queued inactive id=\(requestID) state=\(session.activationState.rawValue)"
            )
            return false
        }
        session.transferUserInfo(envelope)
        WatchLaunchDiagnostics.mark(
            "health reliable transfer scheduled id=\(requestID) reachable=\(session.isReachable)"
        )
        if session.isReachable {
            session.sendMessage(envelope, replyHandler: nil, errorHandler: nil)
        }
        return true
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
                self?.handleActivatedSessionIfReady()
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
            if isReachable, self?.didPrepare == true {
                self?.sendDiagnosticsLog()
                self?.flushPendingAmbientOutbox(using: .default)
                self?.flushPendingSensorSummaries(using: .default)
                self?.flushPendingAccelerationChunks(using: .default)
                self?.flushPendingHealthSnapshots(using: .default)
                self?.requestSync()
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didFinish userInfoTransfer: WCSessionUserInfoTransfer,
        error: (any Error)?
    ) {
        guard let deliveryID = userInfoTransfer.userInfo[
                TaptionWatchEnvelope.ambientDeliveryIDKey
              ] as? String else { return }
        let transferFailed = error != nil
        let activationRawValue = session.activationState.rawValue
        let errorDescription = error?.localizedDescription
        Task { @MainActor [weak self] in
            guard let self else { return }
            let sessionIsActivated =
                activationRawValue == WCSessionActivationState.activated.rawValue
            if transferFailed, sessionIsActivated {
                guard TaptionWatchAmbientOutboxRetryPolicy.shouldRetry(
                    transferFailed: true,
                    hasDeliveryID: !deliveryID.isEmpty,
                    sessionIsActivated: sessionIsActivated,
                    isPurging: self.isPurgingData
                ) else { return }
                WatchLaunchDiagnostics.mark(
                    "ambient outbox transfer failed id=\(deliveryID) error=\(errorDescription ?? "unknown")"
                )
            }
            self.scheduleAmbientOutboxRetry(for: deliveryID)
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
        let dataSyncRequestID = message[
            TaptionWatchEnvelope.dataSyncRequestIDKey
        ] as? String
        let diagnosticsRequested = message[
            TaptionWatchEnvelope.diagnosticsRequestKey
        ] as? Bool == true
        let purgeRequestID = message[
            TaptionWatchEnvelope.purgeRequestIDKey
        ] as? String
        let purgeRequested = message[
            TaptionWatchEnvelope.purgeRequestKey
        ] as? Bool == true
        let purgeGeneration = Self.purgeGeneration(in: message)
        WatchLaunchDiagnostics.mark(
            "envelope received transport=live_message keys=\(message.keys.sorted().joined(separator: ",")) request_id=\(dataSyncRequestID ?? "none") data_sync=\(dataSyncRequested)"
        )
        Task { @MainActor [weak self] in
            if let data { self?.apply(data: data) }
            if let workoutData { self?.applyWorkoutRequest(data: workoutData) }
            if dataSyncRequested {
                self?.beginDataSyncRequest(
                    requestID: dataSyncRequestID,
                    source: "live_message"
                )
            }
            if diagnosticsRequested {
                WatchLaunchDiagnostics.mark("diagnostics requested")
                self?.sendDiagnosticsLog()
            }
            if purgeRequested,
               let purgeRequestID,
               let purgeGeneration {
                _ = await self?.performPurge(
                    requestID: purgeRequestID,
                    generation: purgeGeneration
                )
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        if message[TaptionWatchEnvelope.purgeRequestKey] as? Bool == true {
            guard let requestID = message[
                TaptionWatchEnvelope.purgeRequestIDKey
            ] as? String,
            let generation = Self.purgeGeneration(in: message) else {
                replyHandler([
                    TaptionWatchEnvelope.purgeAcknowledgedKey: false,
                ])
                return
            }
            let reply = PurgeReplyHandler(replyHandler)
            Task { @MainActor [weak self] in
                let succeeded = await self?.performPurge(
                    requestID: requestID,
                    generation: generation
                ) ?? false
                reply.finish(requestID: requestID, succeeded: succeeded)
            }
            return
        }
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
        let ambientAcknowledgement = userInfo[
            TaptionWatchEnvelope.ambientAcknowledgementKey
        ] as? String
        let data = userInfo[TaptionWatchEnvelope.payloadKey] as? Data
        let workoutData = userInfo[
            TaptionWatchEnvelope.workoutRequestKey
        ] as? Data
        let dataSyncRequested = userInfo[
            TaptionWatchEnvelope.dataSyncRequestKey
        ] as? Bool == true
        let dataSyncRequestID = userInfo[
            TaptionWatchEnvelope.dataSyncRequestIDKey
        ] as? String
        let diagnosticsRequested = userInfo[
            TaptionWatchEnvelope.diagnosticsRequestKey
        ] as? Bool == true
        let purgeRequestID = userInfo[
            TaptionWatchEnvelope.purgeRequestIDKey
        ] as? String
        let purgeRequested = userInfo[
            TaptionWatchEnvelope.purgeRequestKey
        ] as? Bool == true
        let purgeGeneration = Self.purgeGeneration(in: userInfo)
        WatchLaunchDiagnostics.mark(
            "envelope received transport=user_info keys=\(userInfo.keys.sorted().joined(separator: ",")) request_id=\(dataSyncRequestID ?? "none") data_sync=\(dataSyncRequested)"
        )
        Task { @MainActor [weak self] in
            if let ambientAcknowledgement {
                await self?.acknowledgeAmbientDelivery(ambientAcknowledgement)
            }
            if let data { self?.apply(data: data) }
            if let workoutData { self?.applyWorkoutRequest(data: workoutData) }
            if dataSyncRequested {
                self?.beginDataSyncRequest(
                    requestID: dataSyncRequestID,
                    source: "user_info"
                )
            }
            if diagnosticsRequested {
                WatchLaunchDiagnostics.mark("diagnostics requested background")
                self?.sendDiagnosticsLog()
            }
            if purgeRequested,
               let purgeRequestID,
               let purgeGeneration {
                _ = await self?.performPurge(
                    requestID: purgeRequestID,
                    generation: purgeGeneration
                )
            }
        }
    }

    private nonisolated static func purgeGeneration(
        in envelope: [String: Any]
    ) -> UInt64? {
        guard let value = envelope[
            TaptionWatchEnvelope.purgeGenerationKey
        ] as? String else { return nil }
        return UInt64(value)
    }

    private func completedPurgeGeneration() -> UInt64 {
        guard let data = TaptionWatchDeviceLocalDefaults.data(
            forKey: completedPurgeGenerationKey
        ), let value = String(data: data, encoding: .utf8) else { return 0 }
        return UInt64(value) ?? 0
    }

    private func finishPurge(
        id: UUID,
        generation: UInt64,
        succeeded: Bool
    ) {
        guard activePurge?.id == id else { return }
        activePurge = nil
        guard succeeded else { return }
        let completed = max(completedPurgeGeneration(), generation)
        TaptionWatchDeviceLocalDefaults.set(
            Data(String(completed).utf8),
            forKey: completedPurgeGenerationKey
        )
    }

    private func performPurge(
        requestID: String,
        generation: UInt64
    ) async -> Bool {
        guard generation > 0 else {
            sendPurgeAcknowledgement(
                requestID: requestID,
                succeeded: false
            )
            return false
        }
        while let activePurge {
            let succeeded = await activePurge.task.value
            finishPurge(
                id: activePurge.id,
                generation: activePurge.generation,
                succeeded: succeeded
            )
            if !TaptionWatchPurgeGenerationPolicy.shouldExecute(
                requested: generation,
                completed: completedPurgeGeneration()
            ) {
                sendPurgeAcknowledgement(
                    requestID: requestID,
                    succeeded: true
                )
                return true
            }
            if !succeeded {
                sendPurgeAcknowledgement(
                    requestID: requestID,
                    succeeded: false
                )
                return false
            }
        }
        if !TaptionWatchPurgeGenerationPolicy.shouldExecute(
            requested: generation,
            completed: completedPurgeGeneration()
        ) {
            sendPurgeAcknowledgement(requestID: requestID, succeeded: true)
            return true
        }
        let purgeID = UUID()
        let task = Task { @MainActor [weak self] in
            await self?.executePurge() ?? false
        }
        activePurge = (purgeID, generation, task)
        let succeeded = await task.value
        finishPurge(
            id: purgeID,
            generation: generation,
            succeeded: succeeded
        )
        sendPurgeAcknowledgement(
            requestID: requestID,
            succeeded: succeeded
        )
        return succeeded
    }

    private func executePurge() async -> Bool {
        isPurgingData = true
        defer {
            isPurgingData = false
        }
        await cancelAmbientOutboxFlush()
        cancelAmbientOutboxRetry()
        ambientOutboxFlushRequested = false
        widgetReloadFollowupTask?.cancel()
        widgetReloadFollowupTask = nil
        let writeTasks = Array(sensorWriteTasks.values)
        writeTasks.forEach { $0.cancel() }
        for task in writeTasks { await task.value }

        if let legacyAmbientAdoptionTask {
            legacyAmbientAdoptionTask.cancel()
            await legacyAmbientAdoptionTask.value
            self.legacyAmbientAdoptionTask = nil
            legacyAmbientAdoptionID = nil
        }

        for transfer in WCSession.default.outstandingUserInfoTransfers
            where transfer.userInfo[
                TaptionWatchEnvelope.ambientDeliveryIDKey
            ] != nil {
            transfer.cancel()
        }
        guard let dayDatabase else { return false }
        let managerSucceeded = await onPurgeRequest? {
            try await dayDatabase.deleteAll()
        } ?? false
        guard managerSucceeded else {
            WatchLaunchDiagnostics.mark("local purge stopped manager=false")
            isPurgingData = false
            Array(ambientOutboxRetryAttempts.keys).forEach {
                scheduleAmbientOutboxRetry(for: $0)
            }
            flushPendingSensorSummaries(using: .default)
            flushPendingAccelerationChunks(using: .default)
            flushPendingAmbientOutbox(using: .default)
            return false
        }

        ambientOutboxRetryAttempts.removeAll(keepingCapacity: false)
        persistAmbientOutboxRetryAttempts()
        sensorWriteTasks.removeAll(keepingCapacity: false)
        pendingSensorSummaries.removeAll(keepingCapacity: false)
        pendingAccelerationChunks.removeAll(keepingCapacity: false)
        pendingHealthSnapshots.removeAll(keepingCapacity: false)
        dataSyncRequestGate.reset()
        persistPendingSensorSummaries()
        persistPendingAccelerationChunks()
        persistPendingHealthSnapshots()
        payload = nil
        handledWorkoutRequestIDs.removeAll(keepingCapacity: false)
        TaptionWatchDeviceLocalDefaults.removeObject(forKey: cachedPayloadKey)
        TaptionWatchWidgetStore.clear()
        TaptionWatchMeasurementStore.clear()
        WidgetCenter.shared.reloadAllTimelines()
        WatchLaunchDiagnostics.mark(
            "local purge completed manager=true database=true"
        )
        return true
    }

    private func flushPendingAmbientOutbox(
        using session: WCSession,
        deliveryIDs: Set<String>? = nil
    ) {
        guard !isPurgingData,
              session.activationState == .activated,
              let dayDatabase else { return }
        guard !isFlushingAmbientOutbox else {
            ambientOutboxFlushRequested = true
            return
        }
        let generation = ambientOutboxFlushGeneration
        isFlushingAmbientOutbox = true
        let task = Task { @MainActor [weak self, dayDatabase, session, generation] in
            defer {
                if let self {
                    self.isFlushingAmbientOutbox = false
                    let shouldRetry = self.ambientOutboxFlushRequested
                    self.ambientOutboxFlushRequested = false
                    self.ambientOutboxFlushTask = nil
                    if shouldRetry {
                        self.flushPendingAmbientOutbox(using: session)
                    }
                }
            }
            guard let self,
                  self.canContinueAmbientOutboxFlush(generation),
                  !Task.isCancelled else { return }
            do {
                let items = try await dayDatabase.pendingAmbientOutbox(limit: 256)
                guard self.canContinueAmbientOutboxFlush(generation) else {
                    return
                }
                let pendingIDs = Set(items.map(\.id))
                let staleRetryIDs = self.ambientOutboxRetryAttempts.keys.filter {
                    $0 == TaptionWatchAmbientAcknowledgementRetryPolicy
                        .outboxReadRetryID
                        || (items.count < 256 && !pendingIDs.contains($0))
                }
                staleRetryIDs.forEach { self.ambientOutboxRetryAttempts[$0] = nil }
                if !staleRetryIDs.isEmpty {
                    self.persistAmbientOutboxRetryAttempts()
                }
                if self.ambientOutboxRetryAttempts.isEmpty {
                    self.cancelAmbientOutboxRetry()
                }
                guard self.canContinueAmbientOutboxFlush(generation),
                      session.activationState == .activated else { return }
                for id in TaptionWatchAmbientAcknowledgementRetryPolicy
                    .pendingDeliveryIDs(from: items) {
                    self.scheduleAmbientOutboxRetry(for: id)
                }
                for id in self.ambientOutboxRetryAttempts.keys {
                    self.scheduleAmbientOutboxRetry(for: id)
                }
                let outstandingIDs = Set(
                    session.outstandingUserInfoTransfers.compactMap {
                        $0.userInfo[
                            TaptionWatchEnvelope.ambientDeliveryIDKey
                        ] as? String
                    }
                )
                for item in items where !outstandingIDs.contains(item.id) {
                    guard self.canContinueAmbientOutboxFlush(generation),
                          session.activationState == .activated else {
                        return
                    }
                    guard item.kind == TaptionWatchEnvelope.sensorSummaryKey
                            || item.kind == TaptionWatchEnvelope.accelerationChunkKey
                    else { continue }
                    var envelope: [String: Any] = [
                        item.kind: item.payload,
                        TaptionWatchEnvelope.ambientDeliveryIDKey: item.id,
                    ]
                    if let requestID = self.activeDataSyncRequestID {
                        envelope[TaptionWatchEnvelope.dataSyncRequestIDKey] =
                            requestID
                    }
                    session.transferUserInfo(envelope)
                    WatchLaunchDiagnostics.mark(
                        "ambient outbox transfer scheduled id=\(item.id) kind=\(item.kind)"
                    )
                }
            } catch {
                guard self.canContinueAmbientOutboxFlush(generation) else {
                    return
                }
                WatchLaunchDiagnostics.mark(
                    "ambient outbox read failed error=\(error.localizedDescription)"
                )
                let retryIDs = TaptionWatchAmbientOutboxReadFailurePolicy.retryIDs(
                    requested: deliveryIDs,
                    alreadyTracked: Set(self.ambientOutboxRetryAttempts.keys)
                )
                retryIDs.forEach {
                    self.scheduleAmbientOutboxRetry(for: $0)
                }
            }
        }
        ambientOutboxFlushTask = task
    }

    private func canContinueAmbientOutboxFlush(
        _ generation: UInt64
    ) -> Bool {
        TaptionWatchAmbientOutboxFlushPolicy.shouldContinue(
            startGeneration: generation,
            currentGeneration: ambientOutboxFlushGeneration,
            isPurging: isPurgingData,
            isCancelled: Task.isCancelled
        )
    }

    private func cancelAmbientOutboxFlush() async {
        ambientOutboxFlushGeneration &+= 1
        ambientOutboxFlushTask?.cancel()
        await ambientOutboxFlushTask?.value
        ambientOutboxFlushTask = nil
        isFlushingAmbientOutbox = false
        ambientOutboxFlushRequested = false
    }

    private func cancelAmbientOutboxRetry() {
        ambientOutboxRetryTask?.cancel()
        ambientOutboxRetryTask = nil
        ambientOutboxRetryID = nil
    }

    private func scheduleAmbientOutboxRetry(for deliveryID: String) {
        guard deliveryID.hasPrefix("summary:")
                || deliveryID.hasPrefix("chunk:")
                || deliveryID == TaptionWatchAmbientAcknowledgementRetryPolicy
                    .outboxReadRetryID else { return }
        let retryCount = ambientOutboxRetryAttempts[deliveryID] ?? 0
        guard TaptionWatchAmbientAcknowledgementRetryPolicy.shouldRetry(
            retryCount: retryCount,
            hasDeliveryID: !deliveryID.isEmpty,
            sessionIsActivated: WCSession.default.activationState == .activated,
            isPurging: isPurgingData
        ) else { return }
        if ambientOutboxRetryAttempts[deliveryID] == nil {
            ambientOutboxRetryAttempts[deliveryID] = retryCount
            persistAmbientOutboxRetryAttempts()
        }
        guard WCSession.default.activationState == .activated,
              ambientOutboxRetryID == nil else { return }
        let retryID = UUID()
        ambientOutboxRetryID = retryID
        let delay = TaptionWatchAmbientAcknowledgementRetryPolicy.delay(
            retryCount: retryCount
        )
        ambientOutboxRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(delay * 1_000_000_000)
                )
            } catch {
                return
            }
            guard let self,
                  self.ambientOutboxRetryID == retryID else { return }
            self.ambientOutboxRetryID = nil
            self.ambientOutboxRetryTask = nil
            guard !Task.isCancelled,
                  !self.isPurgingData,
                  WCSession.default.activationState == .activated else { return }
            let deliveryIDs = Set(self.ambientOutboxRetryAttempts.keys)
            guard !deliveryIDs.isEmpty else { return }
            for id in deliveryIDs {
                self.ambientOutboxRetryAttempts[id] =
                    TaptionWatchAmbientAcknowledgementRetryPolicy
                        .nextRetryCount(after: self.ambientOutboxRetryAttempts[id] ?? 0)
            }
            self.persistAmbientOutboxRetryAttempts()
            self.flushPendingAmbientOutbox(
                using: .default,
                deliveryIDs: deliveryIDs
            )
        }
    }

    private func acknowledgeAmbientDelivery(_ id: String) async {
        guard id.hasPrefix("summary:") || id.hasPrefix("chunk:"),
              let dayDatabase else { return }
        let deleted = await TaptionWatchAmbientAcknowledgementRetryPolicy
            .deleteOutboxItem(
                id: id,
                delete: {
                    try await dayDatabase.acknowledgeAmbientOutbox(ids: [id])
                },
                onFailure: { [weak self] id, error in
                    WatchLaunchDiagnostics.mark(
                        "ambient outbox acknowledgement failed error=\(error.localizedDescription)"
                    )
                    self?.scheduleAmbientOutboxRetry(for: id)
                }
            )
        guard deleted else { return }
        ambientOutboxRetryAttempts[id] = nil
        persistAmbientOutboxRetryAttempts()
        if ambientOutboxRetryAttempts.isEmpty {
            cancelAmbientOutboxRetry()
        }
        WatchLaunchDiagnostics.mark("ambient outbox acknowledged id=\(id)")
        guard !isPurgingData else { return }
        await adoptLegacyAmbientQueue()
        flushPendingAmbientOutbox(using: .default)
    }

    private func sendPurgeAcknowledgement(
        requestID: String,
        succeeded: Bool
    ) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        session.transferUserInfo([
            TaptionWatchEnvelope.purgeRequestIDKey: requestID,
            TaptionWatchEnvelope.purgeAcknowledgedKey: succeeded,
        ])
    }

    private func applyWorkoutRequest(data: Data) {
        guard !isPurgingData,
              let request = try? decoder.decode(
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
        guard !isPurgingData,
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
        WatchLaunchDiagnostics.mark(
            "payload applied acceleration=\(value.accelerationSettings?.profile.rawValue.description ?? "none") sync=\(value.dataSyncProfile?.rawValue.description ?? "none")"
        )
        onPayloadChange?(value)
        TaptionWatchDeviceLocalDefaults.set(data, forKey: cachedPayloadKey)
        publishToWidget(value)
    }

    private func restoreCachedPayload() {
        guard let data = TaptionWatchDeviceLocalDefaults.data(
            forKey: cachedPayloadKey
        ),
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
        let requestID = activeDataSyncRequestID ?? "none"
        WatchLaunchDiagnostics.mark(
            "sensor summary sequence=\(summary.sequence) samples=\(summary.accelerometerSampleCount) final=\(summary.isFinal) request_id=\(requestID)"
        )
        var envelope: [String: Any] = [
            TaptionWatchEnvelope.sensorSummaryKey: data,
        ]
        if let activeDataSyncRequestID {
            envelope[TaptionWatchEnvelope.dataSyncRequestIDKey] =
                activeDataSyncRequestID
        }
        session.transferUserInfo(envelope)
        WatchLaunchDiagnostics.mark(
            "sensor reliable transfer scheduled sequence=\(summary.sequence) request_id=\(requestID) reachable=\(session.isReachable)"
        )
        if session.isReachable {
            session.sendMessage(envelope, replyHandler: nil, errorHandler: nil)
        }
        return true
    }

    private func cachePending(_ summary: TaptionWatchSensorSummary) {
        TaptionWatchDurableSpoolPolicy.enqueue(
            summary,
            into: &pendingSensorSummaries
        )
        persistPendingSensorSummaries()
        WatchLaunchDiagnostics.mark(
            "sensor queue count=\(pendingSensorSummaries.count)"
        )
    }

    private func flushPendingSensorSummaries(using session: WCSession) {
        guard !isPurgingData,
              session.activationState == .activated,
              !pendingSensorSummaries.isEmpty else {
            return
        }
        if pendingSensorSummaries.contains(where: { $0.isAmbient == true }) {
            Task { @MainActor [weak self] in
                await self?.adoptLegacyAmbientQueue()
            }
        }
        let pending = pendingSensorSummaries.filter { $0.isAmbient != true }
        guard !pending.isEmpty else { return }
        if let dayDatabase {
            let taskID = UUID()
            let task = Task { @MainActor [weak self, dayDatabase, pending] in
                guard let self else { return }
                defer { self.sensorWriteTasks[taskID] = nil }
                do {
                    try await dayDatabase.appendBatch(pending)
                } catch {
                    WatchLaunchDiagnostics.mark("sensor batch store failed before send")
                    return
                }
                guard !Task.isCancelled, !self.isPurgingData else { return }
                let scheduled = self.transferPendingSensorSummaries(
                    pending,
                    through: session
                )
                guard TaptionWatchDurableSpoolPolicy.commitForTransfer(
                    scheduled,
                    from: &self.pendingSensorSummaries,
                    isCancelled: Task.isCancelled,
                    isPurging: self.isPurgingData
                ) else { return }
                self.persistPendingSensorSummaries()
            }
            sensorWriteTasks[taskID] = task
            return
        }
        let scheduled = transferPendingSensorSummaries(pending, through: session)
        guard TaptionWatchDurableSpoolPolicy.commitForTransfer(
            scheduled,
            from: &pendingSensorSummaries,
            isCancelled: Task.isCancelled,
            isPurging: isPurgingData
        ) else { return }
        persistPendingSensorSummaries()
    }

    private func cachePending(_ chunk: TaptionWatchAccelerationChunk) {
        TaptionWatchDurableSpoolPolicy.enqueue(
            chunk,
            into: &pendingAccelerationChunks
        )
        persistPendingAccelerationChunks()
        WatchLaunchDiagnostics.mark(
            "acceleration queue count=\(pendingAccelerationChunks.count)"
        )
    }

    private func flushPendingAccelerationChunks(using session: WCSession) {
        guard !isPurgingData,
              session.activationState == .activated,
              !pendingAccelerationChunks.isEmpty else { return }
        if pendingAccelerationChunks.contains(where: \.isAmbient) {
            Task { @MainActor [weak self] in
                await self?.adoptLegacyAmbientQueue()
            }
        }
        let pending = pendingAccelerationChunks.filter { !$0.isAmbient }
        guard !pending.isEmpty else { return }
        if let dayDatabase {
            let taskID = UUID()
            let task = Task { @MainActor [weak self, dayDatabase, pending] in
                guard let self else { return }
                defer { self.sensorWriteTasks[taskID] = nil }
                for chunk in pending {
                    do {
                        try await dayDatabase.append(chunk)
                    } catch {
                        WatchLaunchDiagnostics.mark(
                            "acceleration batch store failed before send chunk=\(chunk.id.uuidString)"
                        )
                        continue
                    }
                    guard !Task.isCancelled, !self.isPurgingData else { return }
                    guard self.sendAccelerationChunkTransport(chunk) else {
                        continue
                    }
                    guard TaptionWatchDurableSpoolPolicy.commitForTransfer(
                        [chunk],
                        from: &self.pendingAccelerationChunks,
                        isCancelled: Task.isCancelled,
                        isPurging: self.isPurgingData
                    ) else { return }
                    self.persistPendingAccelerationChunks()
                }
            }
            sensorWriteTasks[taskID] = task
            return
        }
        var scheduled: [TaptionWatchAccelerationChunk] = []
        for chunk in pending where sendAccelerationChunkTransport(chunk) {
            scheduled.append(chunk)
        }
        guard TaptionWatchDurableSpoolPolicy.commitForTransfer(
            scheduled,
            from: &pendingAccelerationChunks,
            isCancelled: Task.isCancelled,
            isPurging: isPurgingData
        ) else { return }
        persistPendingAccelerationChunks()
    }

    private func transferPendingSensorSummaries(
        _ pending: [TaptionWatchSensorSummary],
        through session: WCSession
    ) -> [TaptionWatchSensorSummary] {
        var scheduled: [TaptionWatchSensorSummary] = []
        scheduled.reserveCapacity(pending.count)
        for summary in pending {
            if transfer(summary, through: session) {
                scheduled.append(summary)
            } else {
                cachePending(summary)
            }
        }
        return scheduled
    }

    private func cachePending(_ snapshot: TaptionWatchHealthSnapshot) {
        TaptionWatchDurableSpoolPolicy.enqueue(
            snapshot,
            into: &pendingHealthSnapshots
        )
        persistPendingHealthSnapshots()
        WatchLaunchDiagnostics.mark(
            "health queue count=\(pendingHealthSnapshots.count)"
        )
    }

    private func flushPendingHealthSnapshots(using session: WCSession) {
        guard !isPurgingData,
              session.activationState == .activated else {
            if !pendingHealthSnapshots.isEmpty {
                WatchLaunchDiagnostics.mark(
                    "health queue flush skipped reason=inactive state=\(session.activationState.rawValue)"
                )
            }
            return
        }
        guard !pendingHealthSnapshots.isEmpty else { return }
        let pending = pendingHealthSnapshots
        var scheduled: [TaptionWatchHealthSnapshot] = []
        for snapshot in pending {
            guard !Task.isCancelled, !isPurgingData else { break }
            if sendHealthSnapshot(snapshot, through: session) {
                scheduled.append(snapshot)
            }
        }
        guard TaptionWatchDurableSpoolPolicy.commitForTransfer(
            scheduled,
            from: &pendingHealthSnapshots,
            isCancelled: Task.isCancelled,
            isPurging: isPurgingData
        ) else { return }
        persistPendingHealthSnapshots()
        WatchLaunchDiagnostics.mark(
            "health queue drained scheduled=\(scheduled.count) remaining=\(pendingHealthSnapshots.count)"
        )
    }

    private func restorePendingHealthSnapshots() {
        let data = TaptionWatchDeviceLocalDefaults.data(
            forKey: pendingHealthSnapshotsKey
        )
        guard let values = TaptionWatchDurableSpoolCodec.decode(
            [TaptionWatchHealthSnapshot].self,
            from: data
        ) else { return }
        pendingHealthSnapshots = values
    }

    private func restoreAmbientOutboxRetryAttempts() {
        let data = TaptionWatchDeviceLocalDefaults.data(
            forKey: ambientOutboxRetryAttemptsKey
        )
        ambientOutboxRetryAttempts =
            TaptionWatchAmbientAcknowledgementRetryPolicy
                .restoredAttempts(from: data)
    }

    private func persistAmbientOutboxRetryAttempts() {
        guard !ambientOutboxRetryAttempts.isEmpty else {
            TaptionWatchDeviceLocalDefaults.removeObject(
                forKey: ambientOutboxRetryAttemptsKey
            )
            return
        }
        guard let data = TaptionWatchAmbientAcknowledgementRetryPolicy
            .encodedAttempts(ambientOutboxRetryAttempts) else {
            return
        }
        TaptionWatchDeviceLocalDefaults.set(
            data,
            forKey: ambientOutboxRetryAttemptsKey
        )
    }

    private func restorePendingAccelerationChunks() {
        let data = TaptionWatchDeviceLocalDefaults.data(
            forKey: pendingAccelerationChunksKey
        )
        guard let values = TaptionWatchDurableSpoolCodec.decode(
            [TaptionWatchAccelerationChunk].self,
            from: data
        ) else { return }
        pendingAccelerationChunks = values
        WatchLaunchDiagnostics.mark(
            "acceleration queue restored count=\(values.count)"
        )
    }

    private func persistPendingAccelerationChunks() {
        if pendingAccelerationChunks.isEmpty {
            TaptionWatchDeviceLocalDefaults.removeObject(
                forKey: pendingAccelerationChunksKey
            )
            return
        }
        guard let data = TaptionWatchDurableSpoolCodec.encode(
            pendingAccelerationChunks
        ) else {
            return
        }
        TaptionWatchDeviceLocalDefaults.set(
            data,
            forKey: pendingAccelerationChunksKey
        )
    }

    private func persistPendingHealthSnapshots() {
        if pendingHealthSnapshots.isEmpty {
            TaptionWatchDeviceLocalDefaults.removeObject(
                forKey: pendingHealthSnapshotsKey
            )
            return
        }
        guard let data = TaptionWatchDurableSpoolCodec.encode(
            pendingHealthSnapshots
        ) else {
            return
        }
        TaptionWatchDeviceLocalDefaults.set(
            data,
            forKey: pendingHealthSnapshotsKey
        )
    }

    private func restorePendingSensorSummaries() {
        let data = TaptionWatchDeviceLocalDefaults.data(
            forKey: pendingSensorSummariesKey
        )
        guard let values = TaptionWatchDurableSpoolCodec.decode(
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
            TaptionWatchDeviceLocalDefaults.removeObject(
                forKey: pendingSensorSummariesKey
            )
            return
        }
        guard let data = TaptionWatchDurableSpoolCodec.encode(
            pendingSensorSummaries
        ) else {
            return
        }
        TaptionWatchDeviceLocalDefaults.set(
            data,
            forKey: pendingSensorSummariesKey
        )
    }
}

extension WatchConnectivityController: WCSessionDelegate {}
