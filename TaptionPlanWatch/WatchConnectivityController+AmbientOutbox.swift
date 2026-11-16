import Foundation
import WatchConnectivity
import WidgetKit

extension WatchConnectivityController {
    func flushPendingAmbientOutbox(
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
                for item in items {
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
                    if !outstandingIDs.contains(item.id) {
                        session.transferUserInfo(envelope)
                        WatchLaunchDiagnostics.mark(
                            "ambient outbox transfer scheduled id=\(item.id) kind=\(item.kind)"
                        )
                    }
                    if self.ambientLiveDeliveryGate.reserve(
                        id: item.id,
                        payloadBytes: item.payload.count,
                        isReachable: session.isReachable,
                        now: ProcessInfo.processInfo.systemUptime
                    ) {
                        session.sendMessage(
                            envelope,
                            replyHandler: nil,
                            errorHandler: { error in
                                WatchLaunchDiagnostics.mark(
                                    "ambient live transfer failed code=\((error as NSError).code)"
                                )
                            }
                        )
                        WatchLaunchDiagnostics.mark(
                            "ambient live transfer scheduled bytes=\(item.payload.count)"
                        )
                    }
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

    func cancelAmbientOutboxFlush() async {
        ambientOutboxFlushGeneration &+= 1
        ambientOutboxFlushTask?.cancel()
        await ambientOutboxFlushTask?.value
        ambientOutboxFlushTask = nil
        isFlushingAmbientOutbox = false
        ambientOutboxFlushRequested = false
    }

    func cancelAmbientOutboxRetry() {
        ambientOutboxRetryTask?.cancel()
        ambientOutboxRetryTask = nil
        ambientOutboxRetryID = nil
    }

    func scheduleAmbientOutboxRetry(for deliveryID: String) {
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

    func acknowledgeAmbientDelivery(_ id: String) async {
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
        ambientLiveDeliveryGate.acknowledge(id)
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

    func sendPurgeAcknowledgement(
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
}
