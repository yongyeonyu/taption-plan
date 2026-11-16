import CoreMotion
import CoreLocation
import HealthKit
import TaptionWatchBehaviorML
import WatchKit
import WidgetKit

extension WatchWorkoutManager {
    func deletePendingWorkoutForPurge() async throws {
        if let existingTask = purgeWorkoutDeletionTask {
            try await existingTask.value
            return
        }
        let identifiers = TaptionWatchWorkoutPurgeIntentStore.pendingIdentifiers()
        guard !identifiers.isEmpty else { return }
        let task = Task {
            try await TaptionWatchWorkoutPurgeReconciliation.run(
                identifiers: identifiers,
                deleteMatchingWorkout: { identifier in
                    if let workout = self.workoutAwaitingPurgeDeletion,
                       self.workoutAwaitingPurgeDeletionID == identifier {
                        try await self.deleteWorkoutFromHealthKit(workout)
                        return 1
                    }
                    return try await self.deleteWorkoutFromHealthKit(
                        identifier: identifier
                    )
                },
                matchingWorkoutExists: { identifier in
                    try await self.workoutExistsForPurge(
                        identifier: identifier
                    )
                },
                confirmDeletion: { identifier in
                    TaptionWatchWorkoutPurgeIntentStore.remove(identifier)
                    if self.workoutAwaitingPurgeDeletionID == identifier {
                        self.workoutAwaitingPurgeDeletion = nil
                        self.workoutAwaitingPurgeDeletionID = nil
                    }
                    if self.workoutPurgeIdentifier == identifier {
                        self.clearWorkoutPurgeTracking()
                    }
                }
            )
        }
        purgeWorkoutDeletionTask = task
        do {
            try await task.value
            purgeWorkoutDeletionTask = nil
        } catch {
            purgeWorkoutDeletionTask = nil
            throw error
        }
    }

    private func deleteWorkoutFromHealthKit(
        identifier: UUID
    ) async throws -> Int {
        let predicate = HKQuery.predicateForObjects(
            withMetadataKey: TaptionWatchHealthMetadata.workoutPurgeIdentifier,
            operatorType: .equalTo,
            value: identifier.uuidString
        )
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Int, Error>) in
            healthStore.deleteObjects(
                of: HKObjectType.workoutType(),
                predicate: predicate
            ) { success, deletedCount, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: deletedCount)
                } else {
                    continuation.resume(
                        throwing: WatchWorkoutDeletionError.unsuccessful
                    )
                }
            }
        }
    }

    private func workoutExistsForPurge(identifier: UUID) async throws -> Bool {
        let predicate = HKQuery.predicateForObjects(
            withMetadataKey: TaptionWatchHealthMetadata.workoutPurgeIdentifier,
            operatorType: .equalTo,
            value: identifier.uuidString
        )
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Bool, Error>) in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: 1,
                sortDescriptors: nil
            ) { @Sendable _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(
                        returning: !(samples ?? []).isEmpty
                    )
                }
            }
            healthStore.execute(query)
        }
    }

    private func deleteWorkoutFromHealthKit(_ workout: HKWorkout) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            healthStore.delete(workout) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: WatchWorkoutDeletionError.unsuccessful
                    )
                }
            }
        }
    }
}
