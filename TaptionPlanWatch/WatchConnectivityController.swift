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
    private let completedPurgeGenerationKey =
        "TaptionPlan.completedWatchPurgeGeneration"
    private var pendingSensorSummaries: [TaptionWatchSensorSummary] = []
    private var pendingAccelerationChunks: [TaptionWatchAccelerationChunk] = []
    private var pendingHealthSnapshots: [TaptionWatchHealthSnapshot] = []
    private var widgetReloadFollowupTask: Task<Void, Never>?
    private var handledWorkoutRequestIDs = Set<UUID>()
    private var handledDataSyncRequestIDs = Set<String>()
    private var activeDataSyncRequestID: String?
    private var activePurge:
        (id: UUID, generation: UInt64, task: Task<Bool, Never>)?
    private var sensorWriteTasks: [UUID: Task<Void, Never>] = [:]
    private var isPurgingData = false
    private let dayDatabase: WatchDayDatabase?
    var onWorkoutRequest: ((TaptionWatchWorkoutRequest) -> Void)?
    var onPayloadChange: ((TaptionWatchPayload) -> Void)?
    var onDataSyncRequest: ((String) -> Void)?
    var onPurgeRequest: (() async -> Bool)?

    private var didPrepare = false
    private var didActivateConnectivity = false

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
        activateConnectivity()
        handleActivatedSessionIfReady()
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
        flushPendingSensorSummaries(using: .default)
        flushPendingAccelerationChunks(using: .default)
        flushPendingHealthSnapshots(using: .default)
        requestSync()
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
        beginDataSyncRequest(requestID: requestID, source: "watch_button")
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
        flushPendingSensorSummaries(using: session)
        flushPendingAccelerationChunks(using: session)
        flushPendingHealthSnapshots(using: session)
        let request: [String: Any] = [
            TaptionWatchEnvelope.refreshRequestKey: true,
            TaptionWatchEnvelope.dataSyncRequestIDKey: requestID,
        ]

        // Keep the reliable request independent from the live request.  A
        // WatchConnectivity reply/error callback may arrive on its private
        // operation queue; closures created from this @MainActor type then
        // trip Swift 6's actor-isolation precondition before their body runs.
        // The iPhone publishes its latest payload when it receives either
        // form of the refresh request, so no callback is needed here.
        session.transferUserInfo(request)
        WatchLaunchDiagnostics.mark(
            "refresh request scheduled id=\(requestID) reachable=\(session.isReachable)"
        )
        if session.isReachable {
            session.sendMessage(
                request,
                replyHandler: nil,
                errorHandler: { error in
                    WatchLaunchDiagnostics.mark(
                        "refresh request failed id=\(requestID) error=\(error.localizedDescription)"
                    )
                }
            )
        }
    }

    func finishDataSyncRequest(_ requestID: String) {
        guard activeDataSyncRequestID == requestID else { return }
        activeDataSyncRequestID = nil
        WatchLaunchDiagnostics.mark(
            "data sync finished id=\(requestID)"
        )
    }

    private func beginDataSyncRequest(
        requestID: String?,
        source: String
    ) {
        guard !isPurgingData else { return }
        let resolvedID = requestID ?? UUID().uuidString
        if handledDataSyncRequestIDs.count >= 100 {
            handledDataSyncRequestIDs.removeAll(keepingCapacity: true)
        }
        guard handledDataSyncRequestIDs.insert(resolvedID).inserted else {
            WatchLaunchDiagnostics.mark(
                "data sync duplicate ignored id=\(resolvedID) source=\(source)"
            )
            return
        }
        activeDataSyncRequestID = resolvedID
        let profile = payload?.dataSyncProfile?.rawValue.description ?? "none"
        WatchLaunchDiagnostics.mark(
            "data sync requested id=\(resolvedID) source=\(source) profile=\(profile) pending_sensor=\(pendingSensorSummaries.count) pending_acceleration=\(pendingAccelerationChunks.count) pending_health=\(pendingHealthSnapshots.count)"
        )
        onDataSyncRequest?(resolvedID)
    }

    func sendSensorSummary(_ summary: TaptionWatchSensorSummary) {
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
                guard !isPurgingData else { return }
                sendSensorSummaryTransport(summary)
            } catch {
                cachePending(summary)
                WatchLaunchDiagnostics.mark("sensor store failed before send")
            }
            return
        }
        sendSensorSummaryTransport(summary)
    }

    func sendAmbientDrainAndWait(
        summaries: [TaptionWatchSensorSummary],
        accelerationChunks: [TaptionWatchAccelerationChunk]
    ) async -> Bool {
        guard !isPurgingData else { return false }
        if let dayDatabase {
            do {
                try await dayDatabase.appendBatch(
                    summaries,
                    chunks: accelerationChunks
                )
            } catch {
                summaries.forEach(cachePending)
                accelerationChunks.forEach(cachePending)
                WatchLaunchDiagnostics.mark("ambient batch store failed")
                return false
            }
        }
        guard !isPurgingData else { return false }
        var scheduled = true
        for chunk in accelerationChunks where
            !sendAccelerationChunkTransport(chunk) {
            scheduled = false
        }
        for summary in summaries where !sendSensorSummaryTransport(summary) {
            scheduled = false
        }
        return scheduled
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
                guard !isPurgingData else { return }
                sendAccelerationChunkTransport(chunk)
            } catch {
                cachePending(chunk)
                WatchLaunchDiagnostics.mark(
                    "acceleration store failed before send chunk=\(chunk.id.uuidString)"
                )
            }
            return
        }
        sendAccelerationChunkTransport(chunk)
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
            session.sendMessage(
                envelope,
                replyHandler: nil,
                errorHandler: { error in
                    WatchLaunchDiagnostics.mark(
                        "acceleration live transfer failed chunk=\(chunk.id.uuidString) error=\(error.localizedDescription)"
                    )
                }
            )
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

    func sendHealthSnapshot(_ snapshot: TaptionWatchHealthSnapshot) {
        guard !isPurgingData else { return }
        let requestID = activeDataSyncRequestID ?? "none"
        guard WCSession.isSupported() else {
            cachePending(snapshot)
            WatchLaunchDiagnostics.mark(
                "health send queued unsupported id=\(requestID)"
            )
            return
        }
        guard let data = try? encoder.encode(snapshot) else {
            WatchLaunchDiagnostics.mark(
                "health encode failed id=\(requestID)"
            )
            return
        }
        var envelope: [String: Any] = [
            TaptionWatchEnvelope.healthSnapshotKey: data,
        ]
        if let activeDataSyncRequestID {
            envelope[TaptionWatchEnvelope.dataSyncRequestIDKey] =
                activeDataSyncRequestID
        }
        let session = WCSession.default
        guard session.activationState == .activated else {
            cachePending(snapshot)
            WatchLaunchDiagnostics.mark(
                "health send queued inactive id=\(requestID) state=\(session.activationState.rawValue)"
            )
            return
        }
        session.transferUserInfo(envelope)
        WatchLaunchDiagnostics.mark(
            "health reliable transfer scheduled id=\(requestID) reachable=\(session.isReachable)"
        )
        if session.isReachable {
            session.sendMessage(
                envelope,
                replyHandler: nil,
                errorHandler: { error in
                    WatchLaunchDiagnostics.mark(
                        "health live transfer failed id=\(requestID) error=\(error.localizedDescription)"
                    )
                }
            )
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
                self?.flushPendingSensorSummaries(using: .default)
                self?.flushPendingAccelerationChunks(using: .default)
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
        defer { isPurgingData = false }
        widgetReloadFollowupTask?.cancel()
        widgetReloadFollowupTask = nil
        let writeTasks = Array(sensorWriteTasks.values)
        writeTasks.forEach { $0.cancel() }
        for task in writeTasks { await task.value }
        sensorWriteTasks.removeAll(keepingCapacity: false)
        pendingSensorSummaries.removeAll(keepingCapacity: false)
        pendingAccelerationChunks.removeAll(keepingCapacity: false)
        pendingHealthSnapshots.removeAll(keepingCapacity: false)
        activeDataSyncRequestID = nil
        persistPendingSensorSummaries()
        persistPendingAccelerationChunks()
        persistPendingHealthSnapshots()

        let managerSucceeded = await onPurgeRequest?() ?? false
        let databaseSucceeded: Bool
        if let dayDatabase {
            do {
                try await dayDatabase.deleteAll()
                databaseSucceeded = true
            } catch {
                databaseSucceeded = false
                WatchLaunchDiagnostics.mark(
                    "day database purge failed error=\(error.localizedDescription)"
                )
            }
        } else {
            databaseSucceeded = false
        }

        payload = nil
        handledWorkoutRequestIDs.removeAll(keepingCapacity: false)
        handledDataSyncRequestIDs.removeAll(keepingCapacity: false)
        TaptionWatchDeviceLocalDefaults.removeObject(forKey: cachedPayloadKey)
        TaptionWatchWidgetStore.clear()
        TaptionWatchMeasurementStore.clear()
        WidgetCenter.shared.reloadAllTimelines()
        WatchLaunchDiagnostics.mark(
            "local purge completed manager=\(managerSucceeded) database=\(databaseSucceeded)"
        )
        return managerSucceeded && databaseSucceeded
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
            session.sendMessage(
                envelope,
                replyHandler: nil,
                errorHandler: { error in
                    WatchLaunchDiagnostics.mark(
                        "sensor live transfer failed sequence=\(summary.sequence) request_id=\(requestID) error=\(error.localizedDescription)"
                    )
                }
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
        guard !isPurgingData,
              session.activationState == .activated,
              !pendingSensorSummaries.isEmpty else {
            return
        }
        let pending = pendingSensorSummaries
        pendingSensorSummaries = []
        if let dayDatabase {
            let taskID = UUID()
            let task = Task { @MainActor [weak self, dayDatabase, pending] in
                guard let self else { return }
                defer { self.sensorWriteTasks[taskID] = nil }
                do {
                    try await dayDatabase.appendBatch(pending)
                } catch {
                    if !Task.isCancelled, !self.isPurgingData {
                        pending.forEach { self.cachePending($0) }
                    }
                    WatchLaunchDiagnostics.mark("sensor batch store failed before send")
                    return
                }
                guard !Task.isCancelled, !self.isPurgingData else { return }
                self.transferPendingSensorSummaries(pending, through: session)
                self.persistPendingSensorSummaries()
            }
            sensorWriteTasks[taskID] = task
            persistPendingSensorSummaries()
            return
        }
        transferPendingSensorSummaries(pending, through: session)
        persistPendingSensorSummaries()
        WatchLaunchDiagnostics.mark(
            "sensor queue drained sent=\(pending.count - pendingSensorSummaries.count) remaining=\(pendingSensorSummaries.count)"
        )
    }

    private func cachePending(_ chunk: TaptionWatchAccelerationChunk) {
        pendingAccelerationChunks.removeAll { $0.id == chunk.id }
        pendingAccelerationChunks.append(chunk)
        pendingAccelerationChunks.sort { $0.endedAt < $1.endedAt }
        if pendingAccelerationChunks.count > 120 {
            pendingAccelerationChunks.removeFirst(
                pendingAccelerationChunks.count - 120
            )
        }
        persistPendingAccelerationChunks()
        WatchLaunchDiagnostics.mark(
            "acceleration queue count=\(pendingAccelerationChunks.count)"
        )
    }

    private func flushPendingAccelerationChunks(using session: WCSession) {
        guard !isPurgingData,
              session.activationState == .activated,
              !pendingAccelerationChunks.isEmpty else { return }
        let pending = pendingAccelerationChunks
        pendingAccelerationChunks = []
        persistPendingAccelerationChunks()
        for chunk in pending {
            sendAccelerationChunkTransport(chunk)
        }
        persistPendingAccelerationChunks()
        WatchLaunchDiagnostics.mark(
            "acceleration queue drained sent=\(pending.count) remaining=\(pendingAccelerationChunks.count)"
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
        pendingHealthSnapshots = []
        persistPendingHealthSnapshots()
        for snapshot in pending {
            sendHealthSnapshot(snapshot)
        }
        WatchLaunchDiagnostics.mark(
            "health queue drained sent=\(pending.count) remaining=\(pendingHealthSnapshots.count)"
        )
    }

    private func restorePendingHealthSnapshots() {
        guard let data = TaptionWatchDeviceLocalDefaults.data(
            forKey: pendingHealthSnapshotsKey
        ),
        let values = try? decoder.decode(
            [TaptionWatchHealthSnapshot].self,
            from: data
        ) else { return }
        pendingHealthSnapshots = values
    }

    private func restorePendingAccelerationChunks() {
        guard let data = TaptionWatchDeviceLocalDefaults.data(
            forKey: pendingAccelerationChunksKey
        ), let values = try? decoder.decode(
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
        guard let data = try? encoder.encode(pendingAccelerationChunks) else {
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
        guard let data = try? encoder.encode(pendingHealthSnapshots) else {
            return
        }
        TaptionWatchDeviceLocalDefaults.set(
            data,
            forKey: pendingHealthSnapshotsKey
        )
    }

    private func restorePendingSensorSummaries() {
        guard let data = TaptionWatchDeviceLocalDefaults.data(
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
            TaptionWatchDeviceLocalDefaults.removeObject(
                forKey: pendingSensorSummariesKey
            )
            return
        }
        guard let data = try? encoder.encode(pendingSensorSummaries) else {
            return
        }
        TaptionWatchDeviceLocalDefaults.set(
            data,
            forKey: pendingSensorSummariesKey
        )
    }
}

extension WatchConnectivityController: WCSessionDelegate {}
