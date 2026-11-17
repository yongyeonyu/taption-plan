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

    @Published var payload: TaptionWatchPayload?
    @Published private(set) var statusText = AppLanguagePreference.text(
        korean: "iPhone 연결 중",
        english: "Connecting to iPhone"
    )

    let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    let cachedPayloadKey = "TaptionPlan.cachedWatchPayload"
    let pendingSensorSummariesKey =
        "TaptionPlan.pendingWatchSensorSummaries"
    let pendingAccelerationChunksKey =
        "TaptionPlan.pendingWatchAccelerationChunks"
    let pendingHealthSnapshotsKey =
        "TaptionPlan.pendingWatchHealthSnapshots"
    let ambientOutboxRetryAttemptsKey =
        "TaptionPlan.ambientOutboxRetryAttempts"
    let completedPurgeGenerationKey =
        "TaptionPlan.completedWatchPurgeGeneration"
    var pendingSensorSummaries: [TaptionWatchSensorSummary] = []
    var pendingAccelerationChunks: [TaptionWatchAccelerationChunk] = []
    var pendingHealthSnapshots: [TaptionWatchHealthSnapshot] = []
    var widgetReloadFollowupTask: Task<Void, Never>?
    var handledWorkoutRequestIDs = Set<UUID>()
    var handledWorkoutRequestOrder: [UUID] = []
    var dataSyncRequestGate = TaptionWatchDataSyncRequestGate()
    var activeDataSyncRequestID: String? {
        dataSyncRequestGate.activeRequestID
    }
    var activePurge:
        (id: UUID, generation: UInt64, task: Task<Bool, Never>)?
    var sensorWriteTasks: [UUID: Task<Void, Never>] = [:]
    var isFlushingSensorSummaries = false // 연결·버튼이 겹쳐도 두 번 보내지 않는다(WCH1110A01)
    var isFlushingAccelerationChunks = false
    var isPurgingData = false
    let dayDatabase: WatchDayDatabase?
    var onWorkoutRequest: ((TaptionWatchWorkoutRequest) -> Void)?
    var onPayloadChange: ((TaptionWatchPayload) -> Void)?
    var onDataSyncRequest: ((String) -> Void)?
    var onPurgeRequest:
        ((@MainActor () async throws -> Void) async -> Bool)?

    private var didPrepare = false
    private var didActivateConnectivity = false
    var isFlushingAmbientOutbox = false
    var ambientOutboxFlushRequested = false
    var ambientOutboxFlushTask: Task<Void, Never>?
    var ambientOutboxFlushGeneration: UInt64 = 0
    var ambientLiveDeliveryGate = TaptionWatchAmbientLiveDeliveryGate()
    var ambientOutboxRetryTask: Task<Void, Never>?
    var ambientOutboxRetryID: UUID?
    var ambientOutboxRetryAttempts: [String: Int] = [:]
    var legacyAmbientAdoptionID: UUID?
    var legacyAmbientAdoptionTask: Task<Void, Never>?

    private var language: AppLanguagePreference.ResolvedLanguage { AppLanguagePreference.resolve(rawValue: payload?.languagePreference) }

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

    func adoptLegacyAmbientQueue() async {
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
            statusText = language.text("연결을 지원하지 않음", "Connectivity unavailable")
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
            // 원본과 outbox에 함께 넣고, iPhone ack가 올 때까지 outbox가 다시 보낸다(WSY1117A01).
            if (try? await dayDatabase.enqueueWorkoutBatch([summary], chunks: [])) != nil {
                guard !isPurgingData else { return }
                flushPendingAmbientOutbox(using: .default)
                return
            }
            // outbox가 가득 차는 등으로 못 넣으면 예전처럼 원본만 남기고 한 번 보낸다.
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
            if (try? await dayDatabase.enqueueWorkoutBatch([], chunks: [chunk])) != nil {
                guard !isPurgingData else { return }
                flushPendingAmbientOutbox(using: .default)
                return
            }
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
    func sendAccelerationChunkTransport(
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
        let ambientAcknowledgement = message[
            TaptionWatchEnvelope.ambientAcknowledgementKey
        ] as? String
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
            if let ambientAcknowledgement {
                await self?.acknowledgeAmbientDelivery(ambientAcknowledgement)
            }
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

    private func applyWorkoutRequest(data: Data) {
        guard !isPurgingData,
              let request = try? decoder.decode(
            TaptionWatchWorkoutRequest.self,
            from: data
        ), handledWorkoutRequestIDs.insert(request.id).inserted else {
            return
        }
        handledWorkoutRequestOrder.append(request.id)
        if handledWorkoutRequestOrder.count > 100 {
            handledWorkoutRequestIDs.remove(handledWorkoutRequestOrder.removeFirst())
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
        // 늦게 온 예전 값은 버리고, 같은 값이면 화면·캐시·위젯은 두고 설정만 다시 본다(WCH1110A01).
        if let current = payload, value.generatedAt < current.generatedAt || value == current {
            if value == current { onPayloadChange?(value) }
            return
        }
        AppLanguagePreference.adoptPhoneSelection(value.languagePreference) // 워치 위젯도 iPhone 언어를 따른다.
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
        AppLanguagePreference.adoptPhoneSelection(value.languagePreference) // 워치 위젯도 iPhone 언어를 따른다.
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
        TaptionWatchWidgetKind.reloadForPayload()
        widgetReloadFollowupTask?.cancel()
        widgetReloadFollowupTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            TaptionWatchWidgetKind.reloadForPayload()
        }
    }

    private func updateStatus(
        activationRawValue: Int,
        isReachable: Bool
    ) {
        switch activationRawValue {
        case WCSessionActivationState.notActivated.rawValue:
            statusText = language.text("iPhone 연결 중", "Connecting to iPhone")
        case WCSessionActivationState.inactive.rawValue:
            statusText = language.text("연결 대기", "Waiting for connection")
        case WCSessionActivationState.activated.rawValue:
            statusText = isReachable
                ? language.text("iPhone 실시간 연결", "iPhone connected")
                : language.text("백그라운드 동기화", "Background sync")
        default:
            statusText = language.text("연결 상태 확인 중", "Checking connection")
        }
    }
}

extension WatchConnectivityController: WCSessionDelegate {}
