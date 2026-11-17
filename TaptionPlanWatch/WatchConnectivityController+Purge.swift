import Foundation
import WatchConnectivity
import WidgetKit

extension WatchConnectivityController {
    nonisolated static func purgeGeneration(
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

    func performPurge(
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
        ambientLiveDeliveryGate.reset()
        ambientResendGate.reset()
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
            ] != nil
                || transfer.userInfo[TaptionWatchEnvelope.launchDiagnosticsKey] == nil {
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
        handledWorkoutRequestOrder.removeAll()
        TaptionWatchDeviceLocalDefaults.removeObject(forKey: cachedPayloadKey)
        TaptionWatchWidgetStore.clear()
        TaptionWatchMeasurementStore.clear()
        WidgetCenter.shared.reloadAllTimelines()
        WatchLaunchDiagnostics.mark(
            "local purge completed manager=true database=true"
        )
        return true
    }
}
