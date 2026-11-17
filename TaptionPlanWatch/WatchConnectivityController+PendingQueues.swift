import Foundation
import WatchConnectivity
import WidgetKit

extension WatchConnectivityController {
    func transfer(
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

    func cachePending(_ summary: TaptionWatchSensorSummary) {
        TaptionWatchDurableSpoolPolicy.enqueue(
            summary,
            into: &pendingSensorSummaries
        )
        persistPendingSensorSummaries()
        WatchLaunchDiagnostics.mark(
            "sensor queue count=\(pendingSensorSummaries.count)"
        )
    }

    func flushPendingSensorSummaries(using session: WCSession) {
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
        guard !pending.isEmpty, !isFlushingSensorSummaries else { return }
        if let dayDatabase {
            let taskID = UUID()
            isFlushingSensorSummaries = true
            let task = Task { @MainActor [weak self, dayDatabase, pending] in
                guard let self else { return }
                defer { self.sensorWriteTasks[taskID] = nil; self.isFlushingSensorSummaries = false }
                let scheduled: [TaptionWatchSensorSummary]
                if (try? await dayDatabase.enqueueWorkoutBatch(pending, chunks: [])) != nil {
                    guard !Task.isCancelled, !self.isPurgingData else { return }
                    // outbox에 들어갔으니 ack까지는 outbox가 다시 보낸다(WSY1117A01).
                    self.flushPendingAmbientOutbox(using: session)
                    scheduled = pending
                } else {
                    do {
                        try await dayDatabase.appendBatch(pending)
                    } catch {
                        WatchLaunchDiagnostics.mark("sensor batch store failed before send")
                        return
                    }
                    guard !Task.isCancelled, !self.isPurgingData else { return }
                    scheduled = self.transferPendingSensorSummaries(
                        pending,
                        through: session
                    )
                }
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

    func cachePending(_ chunk: TaptionWatchAccelerationChunk) {
        TaptionWatchDurableSpoolPolicy.enqueue(
            chunk,
            into: &pendingAccelerationChunks
        )
        persistPendingAccelerationChunks()
        WatchLaunchDiagnostics.mark(
            "acceleration queue count=\(pendingAccelerationChunks.count)"
        )
    }

    func flushPendingAccelerationChunks(using session: WCSession) {
        guard !isPurgingData,
              session.activationState == .activated,
              !pendingAccelerationChunks.isEmpty else { return }
        if pendingAccelerationChunks.contains(where: \.isAmbient) {
            Task { @MainActor [weak self] in
                await self?.adoptLegacyAmbientQueue()
            }
        }
        let pending = pendingAccelerationChunks.filter { !$0.isAmbient }
        guard !pending.isEmpty, !isFlushingAccelerationChunks else { return }
        if let dayDatabase {
            let taskID = UUID()
            isFlushingAccelerationChunks = true
            let task = Task { @MainActor [weak self, dayDatabase, pending] in
                guard let self else { return }
                defer { self.sensorWriteTasks[taskID] = nil; self.isFlushingAccelerationChunks = false }
                for chunk in pending {
                    if (try? await dayDatabase.enqueueWorkoutBatch([], chunks: [chunk])) != nil {
                        guard !Task.isCancelled, !self.isPurgingData else { return }
                        self.flushPendingAmbientOutbox(using: session)
                    } else {
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

    func cachePending(_ snapshot: TaptionWatchHealthSnapshot) {
        TaptionWatchDurableSpoolPolicy.enqueue(
            snapshot,
            into: &pendingHealthSnapshots
        )
        persistPendingHealthSnapshots()
        WatchLaunchDiagnostics.mark(
            "health queue count=\(pendingHealthSnapshots.count)"
        )
    }

    func flushPendingHealthSnapshots(using session: WCSession) {
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

    func restorePendingHealthSnapshots() {
        let data = TaptionWatchDeviceLocalDefaults.data(
            forKey: pendingHealthSnapshotsKey
        )
        guard let values = TaptionWatchDurableSpoolCodec.decode(
            [TaptionWatchHealthSnapshot].self,
            from: data
        ) else { return }
        pendingHealthSnapshots = values
    }

    func restoreAmbientOutboxRetryAttempts() {
        let data = TaptionWatchDeviceLocalDefaults.data(
            forKey: ambientOutboxRetryAttemptsKey
        )
        ambientOutboxRetryAttempts =
            TaptionWatchAmbientAcknowledgementRetryPolicy
                .restoredAttempts(from: data)
    }

    func persistAmbientOutboxRetryAttempts() {
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

    private var pendingAccelerationChunksFile: String { "pending-acceleration-chunks.json" } // 묶음이 커서 파일에 둔다(WCH1110A01)
    func restorePendingAccelerationChunks() {
        let data = WatchPendingFile.read(pendingAccelerationChunksFile, legacyKey: pendingAccelerationChunksKey)
        guard let values = TaptionWatchDurableSpoolCodec.decode(
            [TaptionWatchAccelerationChunk].self,
            from: data
        ) else { return }
        pendingAccelerationChunks = values
        WatchLaunchDiagnostics.mark(
            "acceleration queue restored count=\(values.count)"
        )
    }

    func persistPendingAccelerationChunks() {
        guard !pendingAccelerationChunks.isEmpty else {
            return WatchPendingFile.remove(pendingAccelerationChunksFile, legacyKey: pendingAccelerationChunksKey)
        }
        guard let data = TaptionWatchDurableSpoolCodec.encode(pendingAccelerationChunks) else { return }
        WatchPendingFile.write(data, to: pendingAccelerationChunksFile)
    }

    func persistPendingHealthSnapshots() {
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

    func restorePendingSensorSummaries() {
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

    func persistPendingSensorSummaries() {
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
