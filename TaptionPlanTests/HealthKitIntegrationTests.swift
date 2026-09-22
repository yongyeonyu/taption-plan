import Foundation
import HealthKit
import XCTest
import TaptionPlanCore
@testable import TaptionPlan

private actor HealthKitHistoryPageSequence {
    enum Failure: Error {
        case laterPage
    }

    private let records: [HealthKitSampleRecord]
    private let importStore: HealthKitImportStore
    private let typeIdentifier: String
    private var page = 0
    private var checkpointBeforeFailure: HealthKitTypeSyncState?
    private var checkpointReadError: String?

    init(
        records: [HealthKitSampleRecord],
        importStore: HealthKitImportStore,
        typeIdentifier: String
    ) {
        self.records = records
        self.importStore = importStore
        self.typeIdentifier = typeIdentifier
    }

    func next() async throws -> [HealthKitSampleRecord] {
        page += 1
        guard page == 1 else {
            do {
                checkpointBeforeFailure = try await importStore.syncState(
                    for: typeIdentifier
                )
            } catch {
                checkpointReadError = error.localizedDescription
            }
            throw Failure.laterPage
        }
        return records
    }

    func requestCount() -> Int {
        page
    }

    func checkpoint() -> HealthKitTypeSyncState? {
        checkpointBeforeFailure
    }

    func checkpointReadFailure() -> String? {
        checkpointReadError
    }
}

private actor HealthKitSynchronizationTestLatch {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    func isReleased() -> Bool {
        released
    }
}

private actor HealthKitSynchronizationTestProbe {
    private var activeCount = 0
    private var maximumActiveCount = 0
    private var entryCount = 0
    private var firstEntryContinuation: CheckedContinuation<Void, Never>?

    func enter() {
        activeCount += 1
        entryCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        firstEntryContinuation?.resume()
        firstEntryContinuation = nil
    }

    func leave() {
        activeCount -= 1
    }

    func waitForFirstEntry() async {
        guard entryCount == 0 else { return }
        await withCheckedContinuation { continuation in
            firstEntryContinuation = continuation
        }
    }

    func maximumConcurrentOperations() -> Int {
        maximumActiveCount
    }

    func totalOperationCount() -> Int {
        entryCount
    }
}

final class HealthKitIntegrationTests: XCTestCase {
    private enum QueryError: Error {
        case failed
    }

    func testObservedHealthChangeQueueRequeuesFailedScopeWithoutDroppingNewEvents() {
        var queue = HealthKitObservedChangeQueue()
        queue.mark("HKQuantityTypeIdentifierStepCount")

        let firstScope = queue.take()
        queue.mark("HKCategoryTypeIdentifierSleepAnalysis")
        queue.requeue(firstScope ?? [])

        XCTAssertEqual(
            queue.take(),
            Set([
                "HKQuantityTypeIdentifierStepCount",
                "HKCategoryTypeIdentifierSleepAnalysis",
            ])
        )
        XCTAssertTrue(queue.isEmpty)
    }

    func testWorkoutSourceAllowsAppleAndTaptionButRejectsExternalOrSpoofedBundles() {
        for bundle in ["com.apple.Health", "com.apple.health", "com.taption.plan",
                       "com.taption.plan.watchkitapp"] {
            XCTAssertTrue(AppleHealthService.isTrustedWorkoutSource(bundle))
        }
        for bundle in ["", "com.example.workout", "com.apple.health.fake",
                       "com.taption.plan.watchkitapp.fake", "Apple Watch"] {
            XCTAssertFalse(AppleHealthService.isTrustedWorkoutSource(bundle))
        }
    }

    func testWatchHealthSnapshotRetriesOnlyMissingRawArchive() {
        let capturedAt = Date(timeIntervalSince1970: 1_788_000_000)
        let receivedAt = capturedAt.addingTimeInterval(120)

        XCTAssertTrue(
            WatchHealthSnapshotRetryPolicy.accepts(
                capturedAt: capturedAt,
                fingerprint: "same",
                receivedAt: receivedAt,
                lastAppliedAt: nil,
                rawRetryAt: nil,
                rawRetryFingerprint: nil,
                lastRawRetryAttemptAt: nil
            )
        )
        XCTAssertTrue(
            WatchHealthSnapshotRetryPolicy.accepts(
                capturedAt: capturedAt,
                fingerprint: "same",
                receivedAt: receivedAt,
                lastAppliedAt: capturedAt,
                rawRetryAt: capturedAt,
                rawRetryFingerprint: "same",
                lastRawRetryAttemptAt: receivedAt.addingTimeInterval(-61)
            )
        )
        XCTAssertFalse(
            WatchHealthSnapshotRetryPolicy.accepts(
                capturedAt: capturedAt,
                fingerprint: "same",
                receivedAt: receivedAt,
                lastAppliedAt: capturedAt,
                rawRetryAt: nil,
                rawRetryFingerprint: nil,
                lastRawRetryAttemptAt: nil
            )
        )
        XCTAssertFalse(
            WatchHealthSnapshotRetryPolicy.accepts(
                capturedAt: capturedAt,
                fingerprint: "changed",
                receivedAt: receivedAt,
                lastAppliedAt: capturedAt,
                rawRetryAt: capturedAt,
                rawRetryFingerprint: "same",
                lastRawRetryAttemptAt: nil
            )
        )
        XCTAssertFalse(
            WatchHealthSnapshotRetryPolicy.accepts(
                capturedAt: capturedAt,
                fingerprint: "same",
                receivedAt: receivedAt,
                lastAppliedAt: capturedAt,
                rawRetryAt: capturedAt,
                rawRetryFingerprint: "same",
                lastRawRetryAttemptAt: receivedAt.addingTimeInterval(-30)
            )
        )
        XCTAssertFalse(
            WatchHealthSnapshotRetryPolicy.accepts(
                capturedAt: capturedAt.addingTimeInterval(-1),
                fingerprint: "same",
                receivedAt: receivedAt,
                lastAppliedAt: capturedAt,
                rawRetryAt: capturedAt.addingTimeInterval(-1),
                rawRetryFingerprint: "same",
                lastRawRetryAttemptAt: nil
            )
        )
    }

    func testHealthKitAnchoredDeltaCountsNewUpdatedAndDeletedUUIDs() {
        let existing = UUID()
        let removed = UUID()
        let unknownDeletion = UUID()
        let added = UUID()

        XCTAssertEqual(
            HealthKitImportDeltaCounts.classify(
                incoming: [existing, added],
                deleted: [removed, unknownDeletion],
                existing: [existing, removed],
                countsExistingAsUpdated: true
            ),
            HealthKitImportDeltaCounts(added: 1, updated: 1, deleted: 1)
        )
        XCTAssertEqual(
            HealthKitImportDeltaCounts.classify(
                incoming: [existing, added],
                deleted: [],
                existing: [existing],
                countsExistingAsUpdated: false
            ),
            HealthKitImportDeltaCounts(added: 1, updated: 0, deleted: 0)
        )
    }

    func testHealthKitSnapshotReconciliationTracksDeletionAndRejectsBadCursor()
        throws
    {
        let retained = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        )
        let deleted = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")
        )
        let added = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-0000-0000-000000000003")
        )
        let previousCursor = try PropertyListEncoder().encode([
            deleted, retained, retained,
        ])

        let result = try HealthKitSnapshotReconciliation.make(
            previousCursor: previousCursor,
            currentIDs: [added, retained, added]
        )

        XCTAssertEqual(result.currentIDs, [retained, added])
        XCTAssertEqual(result.deletedIDs, [deleted])
        XCTAssertEqual(
            result.counts,
            HealthKitImportDeltaCounts(added: 1, updated: 1, deleted: 1)
        )
        XCTAssertEqual(
            try PropertyListDecoder().decode([UUID].self, from: result.cursor),
            [retained, added]
        )
        XCTAssertThrowsError(
            try HealthKitSnapshotReconciliation.make(
                previousCursor: Data("broken".utf8),
                currentIDs: []
            )
        )
    }

    func testHealthKitStoreReturnsRecordSpanningMoreThanSevenDays() async throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let store = try HealthKitImportStore(databaseURL: url)
        let queryStart = Date(timeIntervalSince1970: 1_800_000_000)
        let record = HealthKitSampleRecord(
            uuid: UUID(),
            typeIdentifier: "HKWorkoutTypeIdentifier",
            startDate: queryStart.addingTimeInterval(-30 * 86_400),
            endDate: queryStart.addingTimeInterval(3_600),
            sourceName: "Apple Watch",
            sourceBundleIdentifier: "com.apple.health"
        )
        try await store.upsert([record])

        let records = try await store.records(
            from: queryStart,
            through: queryStart.addingTimeInterval(86_400)
        )

        XCTAssertEqual(records, [record])
    }

    func testHealthKitStoreBackfillsMaximumDurationForLegacyDatabase() async throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let queryStart = Date(timeIntervalSince1970: 1_800_000_000)
        let record = HealthKitSampleRecord(
            uuid: UUID(),
            typeIdentifier: "HKWorkoutTypeIdentifier",
            startDate: queryStart.addingTimeInterval(-30 * 86_400),
            endDate: queryStart.addingTimeInterval(3_600),
            sourceName: "Apple Watch",
            sourceBundleIdentifier: "com.apple.health"
        )
        let encoded = try TaptionPlanCanonicalStorage.encode(record)
        let legacyStore = try TaptionPlanDayStore(url: url)
        try await legacyStore.upsertEvents([
            TaptionPlanDayStore.Event(
                day: TaptionPlanDayKey(date: record.startDate),
                timestamp: record.startDate,
                sequence: 0,
                id: record.eventID,
                domain: HealthKitImportStore.eventDomain,
                payload: TaptionPlanCanonicalStorage.envelope(for: encoded)
            ),
        ])
        let store = try HealthKitImportStore(databaseURL: url)

        let first = try await store.records(
            from: queryStart,
            through: queryStart.addingTimeInterval(86_400)
        )
        let second = try await store.records(
            from: queryStart,
            through: queryStart.addingTimeInterval(86_400)
        )

        XCTAssertEqual(first, [record])
        XCTAssertEqual(second, [record])
    }

    @available(iOS 18.0, *)
    func testMalformedHealthKitHistoryCursorPreservesCheckpointWithoutReimport()
        async throws
    {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let store = try HealthKitImportStore(databaseURL: url)
        let type = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        let malformedCursor = Data("broken-history-cursor".utf8)
        let state = HealthKitTypeSyncState(
            typeIdentifier: type.identifier,
            historyCursor: malformedCursor,
            historyComplete: false,
            sampleCount: 7,
            addedCount: 7
        )
        try await store.saveSyncState(state)
        let pages = HealthKitHistoryPageSequence(
            records: [],
            importStore: store,
            typeIdentifier: type.identifier
        )
        let coordinator = HealthKitImportCoordinator(
            healthStore: HKHealthStore(),
            importStore: store,
            firstSampleDateLoader: { _ in .distantPast },
            earliestPermittedDateLoader: { .distantPast },
            historyRecordLoader: { _, _, _ in try await pages.next() }
        )

        _ = try await coordinator.synchronizeSampleChanges(
            typeIdentifiers: [type.identifier]
        )

        let savedState = try await store.syncState(for: type.identifier)
        let saved = try XCTUnwrap(savedState)
        let pageRequestCount = await pages.requestCount()
        XCTAssertEqual(pageRequestCount, 0)
        XCTAssertEqual(saved.historyCursor, malformedCursor)
        XCTAssertFalse(saved.historyComplete)
        XCTAssertEqual(saved.sampleCount, 7)
        XCTAssertEqual(saved.addedCount, 7)
        XCTAssertEqual(
            saved.lastError,
            HealthKitImportCoordinatorError.invalidHistoryCursor.errorDescription
        )
    }

    @available(iOS 18.0, *)
    func testMalformedHealthKitAnchorPreservesCheckpointWithoutReset() async throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let store = try HealthKitImportStore(databaseURL: url)
        let type = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        let malformedAnchor = Data("broken-anchor".utf8)
        let state = HealthKitTypeSyncState(
            typeIdentifier: type.identifier,
            anchor: malformedAnchor,
            historyComplete: true,
            sampleCount: 5,
            addedCount: 8,
            deletedCount: 3
        )
        try await store.saveSyncState(state)
        let coordinator = HealthKitImportCoordinator(
            healthStore: HKHealthStore(),
            importStore: store
        )

        _ = try await coordinator.synchronizeSampleChanges(
            typeIdentifiers: [type.identifier]
        )

        let savedState = try await store.syncState(for: type.identifier)
        let saved = try XCTUnwrap(savedState)
        XCTAssertEqual(saved.anchor, malformedAnchor)
        XCTAssertTrue(saved.historyComplete)
        XCTAssertEqual(saved.sampleCount, 5)
        XCTAssertEqual(saved.addedCount, 8)
        XCTAssertEqual(saved.deletedCount, 3)
        XCTAssertEqual(
            saved.lastError,
            HealthKitImportCoordinatorError.invalidAnchorCursor.errorDescription
        )
        XCTAssertThrowsError(
            try HealthKitImportCoordinator.decodeAnchor(malformedAnchor)
        ) { error in
            XCTAssertEqual(
                error as? HealthKitImportCoordinatorError,
                .invalidAnchorCursor
            )
        }
    }

    func testHealthSyncOverviewReportsPartialFailures() {
        let overview = HealthKitSyncOverview(states: [
            HealthKitTypeSyncState(
                typeIdentifier: "success",
                historyComplete: true
            ),
            HealthKitTypeSyncState(
                typeIdentifier: "failed",
                lastError: "denied"
            ),
        ])

        XCTAssertEqual(overview.completedTypeCount, 1)
        XCTAssertEqual(overview.failedTypeCount, 1)
        XCTAssertEqual(overview.lastError, "denied")
    }

    @available(iOS 18.0, *)
    func testHistoryPageFailurePreservesCommittedCheckpointAndRecords() async throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let store = try HealthKitImportStore(databaseURL: url)
        let type = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let firstPageStart = calendar.date(
            byAdding: .month,
            value: -2,
            to: .now
        )!
        let committedCursor = calendar.date(
            byAdding: .month,
            value: 1,
            to: firstPageStart
        )!
        let record = biometricRecord(
            identifier: type.identifier,
            at: firstPageStart.addingTimeInterval(60),
            value: 72,
            unit: "count/min"
        )
        let pages = HealthKitHistoryPageSequence(
            records: [record],
            importStore: store,
            typeIdentifier: type.identifier
        )
        let coordinator = HealthKitImportCoordinator(
            healthStore: HKHealthStore(),
            importStore: store,
            firstSampleDateLoader: { _ in firstPageStart },
            earliestPermittedDateLoader: { .distantPast },
            historyRecordLoader: { _, _, _ in try await pages.next() }
        )

        var synchronizationError: String?
        do {
            _ = try await coordinator.synchronizeSampleChanges(
                typeIdentifiers: [type.identifier]
            )
        } catch {
            synchronizationError = error.localizedDescription
        }

        let state: HealthKitTypeSyncState?
        do {
            state = try await store.syncState(for: type.identifier)
        } catch {
            XCTFail(
                "Sync-state read after synchronization failed: "
                    + error.localizedDescription
            )
            return
        }
        let pageCount = await pages.requestCount()
        let checkpointBeforeFailure = await pages.checkpoint()
        let checkpointReadFailure = await pages.checkpointReadFailure()
        XCTAssertNil(synchronizationError, synchronizationError ?? "")
        XCTAssertNil(checkpointReadFailure, checkpointReadFailure ?? "")
        guard let state else {
            XCTFail("No sync state was saved after \(pageCount) history-page requests")
            return
        }
        XCTAssertNotNil(state.lastError)
        guard let cursorData = state.historyCursor else {
            XCTFail(
                "Committed history checkpoint missing after \(pageCount) page requests "
                    + "(before failure: \(checkpointBeforeFailure?.historyCursor != nil), "
                    + "count: \(state.sampleCount), complete: \(state.historyComplete), "
                    + "error: \(state.lastError ?? "none"))"
            )
            return
        }
        let cursor = try XCTUnwrap(
            HealthKitImportCoordinator.decodeDate(cursorData)
        )
        XCTAssertNotNil(checkpointBeforeFailure?.historyCursor)
        let records = try await store.records(
            from: record.startDate.addingTimeInterval(-1),
            through: record.endDate.addingTimeInterval(1)
        )
        XCTAssertEqual(cursor, committedCursor)
        XCTAssertFalse(state.historyComplete)
        XCTAssertEqual(state.sampleCount, 1)
        XCTAssertEqual(records, [record])
    }

    func testHealthKitSynchronizationGateSerializesConcurrentOperations() async throws {
        let gate = HealthKitSynchronizationGate()
        let latch = HealthKitSynchronizationTestLatch()
        let probe = HealthKitSynchronizationTestProbe()
        let first = Task {
            try await gate.withPermit {
                await probe.enter()
                await latch.wait()
                await probe.leave()
            }
        }
        await probe.waitForFirstEntry()
        let second = Task {
            try await gate.withPermit {
                await probe.enter()
                await probe.leave()
            }
        }

        try await Task.sleep(for: .milliseconds(50))
        let maximumBeforeRelease = await probe.maximumConcurrentOperations()
        XCTAssertEqual(maximumBeforeRelease, 1)

        await latch.release()
        try await first.value
        try await second.value
        let maximum = await probe.maximumConcurrentOperations()
        XCTAssertEqual(maximum, 1)
    }

    @available(iOS 18.0, *)
    func testConcurrentSampleSynchronizationsDoNotOverlapCoordinatorWork() async throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let store = try HealthKitImportStore(databaseURL: url)
        let type = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        let firstSampleDate = Date.now.addingTimeInterval(-60 * 86_400)
        let latch = HealthKitSynchronizationTestLatch()
        let probe = HealthKitSynchronizationTestProbe()
        let coordinator = HealthKitImportCoordinator(
            healthStore: HKHealthStore(),
            importStore: store,
            firstSampleDateLoader: { _ in firstSampleDate },
            earliestPermittedDateLoader: { .distantPast },
            historyRecordLoader: { _, _, _ in
                await probe.enter()
                await latch.wait()
                await probe.leave()
                throw QueryError.failed
            }
        )

        let first = Task {
            try await coordinator.synchronizeSampleChanges(
                typeIdentifiers: [type.identifier]
            )
        }
        await probe.waitForFirstEntry()
        let second = Task {
            try await coordinator.synchronizeSampleChanges(
                typeIdentifiers: [type.identifier]
            )
        }

        try await Task.sleep(for: .milliseconds(50))
        let overlappingOperations = await probe.maximumConcurrentOperations()
        let operationsBeforeRelease = await probe.totalOperationCount()
        await latch.release()
        _ = try await first.value
        _ = try await second.value
        let maximumAfterCompletion = await probe.maximumConcurrentOperations()
        let operationsAfterCompletion = await probe.totalOperationCount()

        XCTAssertEqual(overlappingOperations, 1)
        XCTAssertEqual(operationsBeforeRelease, 1)
        XCTAssertEqual(maximumAfterCompletion, 1)
        XCTAssertEqual(operationsAfterCompletion, 2)
    }

    @available(iOS 18.0, *)
    func testHealthKitDeleteWaitsForInFlightHistoryPage() async throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let store = try HealthKitImportStore(databaseURL: url)
        let type = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        let sampleDate = Date.now.addingTimeInterval(-2 * 86_400)
        let record = HealthKitSampleRecord(
            uuid: UUID(),
            typeIdentifier: type.identifier,
            startDate: sampleDate,
            endDate: sampleDate.addingTimeInterval(60),
            numericValue: 72,
            unit: "count/min",
            sourceName: "Apple Watch",
            sourceBundleIdentifier: "com.apple.health",
            sourceProductType: "Watch",
            deviceName: "Apple Watch",
            userEntered: false,
            timeZoneIdentifier: "UTC"
        )
        let queryLatch = HealthKitSynchronizationTestLatch()
        let queryProbe = HealthKitSynchronizationTestProbe()
        let deleteStarted = HealthKitSynchronizationTestLatch()
        let deleteCompleted = HealthKitSynchronizationTestLatch()
        let coordinator = HealthKitImportCoordinator(
            healthStore: HKHealthStore(),
            importStore: store,
            firstSampleDateLoader: { _ in sampleDate },
            earliestPermittedDateLoader: { .distantPast },
            historyRecordLoader: { _, _, _ in
                await queryProbe.enter()
                await queryLatch.wait()
                await queryProbe.leave()
                return [record]
            }
        )

        let synchronization = Task {
            try await coordinator.synchronizeSampleChanges(
                typeIdentifiers: [type.identifier]
            )
        }
        await queryProbe.waitForFirstEntry()
        let deletion = Task {
            await deleteStarted.release()
            try await coordinator.deleteAll()
            await deleteCompleted.release()
        }
        await deleteStarted.wait()
        try await Task.sleep(for: .milliseconds(50))
        let completedWhileQueryWasBlocked = await deleteCompleted.isReleased()
        XCTAssertFalse(completedWhileQueryWasBlocked)

        await queryLatch.release()
        _ = try await synchronization.value
        try await deletion.value

        let completedAfterHistory = await deleteCompleted.isReleased()
        let records = try await store.records(
            from: sampleDate.addingTimeInterval(-1),
            through: sampleDate.addingTimeInterval(61)
        )
        XCTAssertTrue(completedAfterHistory)
        XCTAssertTrue(records.isEmpty)
    }

    @available(iOS 18.0, *)
    func testActivitySummaryPredicateHasCalendarOnDateBounds() {
        let calendar = Calendar(identifier: .gregorian)
        _ = HealthKitImportCoordinator.activitySummaryPredicate(
            from: Date(timeIntervalSince1970: 1_788_000_000),
            through: Date(timeIntervalSince1970: 1_788_086_400),
            calendar: calendar
        )
    }

    @available(iOS 18.0, *)
    func testSpecializedQueryFailureIsNotConvertedToSampleWithoutPayload() async {
        let start = Date(timeIntervalSince1970: 1_788_000_000)
        let type = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        let sample = HKQuantitySample(
            type: type,
            quantity: HKQuantity(
                unit: .count().unitDivided(by: .minute()),
                doubleValue: 72
            ),
            start: start,
            end: start
        )
        let descriptor = HealthKitTypeCatalog.descriptor(
            for: type.identifier
        )!
        let coordinator = HealthKitImportCoordinator(
            healthStore: HKHealthStore(),
            importStore: nil,
            payloadLoader: { _ in throw QueryError.failed }
        )

        do {
            _ = try await coordinator.records(
                from: [sample],
                descriptor: descriptor
            )
            XCTFail("A failed detail query must not import the sample")
        } catch QueryError.failed {
        } catch {
            XCTFail("Unexpected query error: \(error)")
        }
    }

    @available(iOS 18.0, *)
    func testCharacteristicQueryFailureIsNotSavedAsSuccessfulEmptyValue() async throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let store = try HealthKitImportStore(databaseURL: url)
        let failedIdentifier = "HKCharacteristicTypeIdentifierDateOfBirth"
        let successfulEmptyIdentifier = "HKCharacteristicTypeIdentifierBiologicalSex"
        let coordinator = HealthKitImportCoordinator(
            healthStore: HKHealthStore(),
            importStore: store,
            characteristicValueLoader: { identifier in
                if identifier == failedIdentifier { throw QueryError.failed }
                return nil
            }
        )

        try await coordinator.importCharacteristics()

        let failedState = try await store.syncState(for: failedIdentifier)
        XCTAssertNotNil(failedState?.lastError)
        XCTAssertFalse(failedState?.historyComplete ?? true)
        XCTAssertEqual(failedState?.sampleCount, 0)

        let emptyState = try await store.syncState(for: successfulEmptyIdentifier)
        XCTAssertNil(emptyState?.lastError)
        XCTAssertTrue(emptyState?.historyComplete ?? false)
        XCTAssertEqual(emptyState?.sampleCount, 0)
    }

    @available(iOS 18.0, *)
    func testDeleteAllReportsUnavailableRawStore() async {
        let coordinator = HealthKitImportCoordinator(
            healthStore: HKHealthStore(),
            importStore: nil
        )

        do {
            try await coordinator.deleteAll()
            XCTFail("Missing raw store must not be reported as deleted")
        } catch {
            guard case .some(.localStoreUnavailable) =
                error as? HealthKitImportCoordinatorError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testHealthAuthorizationEnablesImplicitWatchSync() {
        XCTAssertEqual(
            TaptionWatchDataSyncProfile.profileAfterHealthAuthorization(
                current: .off,
                userDidSetProfile: false
            ),
            .balanced
        )
        XCTAssertEqual(
            TaptionWatchDataSyncProfile.profileAfterHealthAuthorization(
                current: .off,
                userDidSetProfile: true
            ),
            .off
        )
        XCTAssertEqual(
            TaptionWatchDataSyncProfile.profileAfterHealthAuthorization(
                current: .accuracy,
                userDidSetProfile: false
            ),
            .accuracy
        )
    }

    func testHealthBackgroundObserversOnlyWakeForTimelineInputs() {
        XCTAssertEqual(
            HealthRefreshPolicy.backgroundObservedTypeIdentifiers,
            [
                HKObjectType.workoutType().identifier,
                HKCategoryTypeIdentifier.sleepAnalysis.rawValue,
                HKCategoryTypeIdentifier.mindfulSession.rawValue,
                HKQuantityTypeIdentifier.stepCount.rawValue,
            ]
        )
    }

    func testCatalogCoversEveryPublicHealthKitFamily() {
        let identifiers = HealthKitTypeCatalog.all.map(\.identifier)

        XCTAssertGreaterThanOrEqual(identifiers.count, 215)
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        XCTAssertEqual(HealthKitTypeCatalog.quantities.count, 120)
        XCTAssertEqual(HealthKitTypeCatalog.categories.count, 69)
        XCTAssertEqual(HealthKitTypeCatalog.characteristics.count, 6)
        XCTAssertEqual(HealthKitTypeCatalog.clinicalRecords.count, 9)
        XCTAssertTrue(identifiers.contains("HKDataTypeIdentifierStateOfMind"))
        XCTAssertTrue(identifiers.contains("HKScoredAssessmentTypeIdentifierPHQ9"))
        XCTAssertTrue(identifiers.contains("HKMedicationDoseEventTypeIdentifierMedicationDoseEvent"))
        XCTAssertTrue(identifiers.contains("HKCategoryTypeIdentifierAudioExposureEvent"))
    }

    func testEveryAvailableCatalogDescriptorResolvesToAHealthKitObjectType() {
        let descriptors = HealthKitTypeCatalog.availableDescriptors()
        let resolved = descriptors.compactMap(
            HealthKitTypeCatalog.readObjectType(for:)
        )

        XCTAssertEqual(resolved.count, descriptors.count)
        XCTAssertFalse(
            HealthKitTypeCatalog.descriptor(
                for: "HKVisionPrescriptionTypeIdentifier"
            )?.backgroundEligible ?? true
        )
    }

    func testStandardAuthorizationExcludesTypesThatNeedAnotherAuthorizationPath() {
        let identifiers = Set(
            HealthKitTypeCatalog.standardAuthorizationObjectTypes().map(\.identifier)
        )

        XCTAssertFalse(identifiers.contains("HKVisionPrescriptionTypeIdentifier"))
        XCTAssertFalse(identifiers.contains("HKCorrelationTypeIdentifierBloodPressure"))
        XCTAssertFalse(identifiers.contains("HKCorrelationTypeIdentifierFood"))
        XCTAssertTrue(identifiers.contains("HKQuantityTypeIdentifierBloodPressureSystolic"))
        XCTAssertTrue(identifiers.contains("HKQuantityTypeIdentifierDietaryEnergyConsumed"))
    }

    func testEveryQuantityHasACanonicalUnitConversion() {
        for descriptor in HealthKitTypeCatalog.quantities where
            descriptor.isAvailableOnCurrentOS {
            guard HealthKitImportCoordinator.unit(
                named: descriptor.canonicalUnit
            ) != nil else {
                return XCTFail("Missing unit: \(descriptor.canonicalUnit)")
            }
        }
        XCTAssertEqual(
            HealthKitTypeCatalog.descriptor(
                for: "HKQuantityTypeIdentifierHeartRate"
            )?.canonicalUnit,
            "count/min"
        )
        XCTAssertEqual(
            HealthKitTypeCatalog.descriptor(
                for: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"
            )?.canonicalUnit,
            "ms"
        )
        XCTAssertEqual(
            HealthKitTypeCatalog.descriptor(
                for: "HKQuantityTypeIdentifierRespiratoryRate"
            )?.canonicalUnit,
            "count/min"
        )
    }

    func testHealthKitRawDeltaAndAnchorRoundTripAtomically() async throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let store = try HealthKitImportStore(databaseURL: url)
        let start = Date(timeIntervalSince1970: 1_788_000_000)
        let sample = HealthKitSampleRecord(
            uuid: UUID(),
            typeIdentifier: "HKQuantityTypeIdentifierHeartRate",
            startDate: start,
            endDate: start.addingTimeInterval(60),
            numericValue: 72,
            unit: "count/min",
            sourceName: "Apple Watch",
            sourceBundleIdentifier: "com.apple.health",
            sourceProductType: "Watch",
            deviceName: "Apple Watch",
            userEntered: false,
            timeZoneIdentifier: "Asia/Seoul"
        )
        let historyCursorDate = start.addingTimeInterval(120)
        let historyCursor = try HealthKitImportCoordinator.encodeDate(
            historyCursorDate
        )
        XCTAssertEqual(
            HealthKitImportCoordinator.decodeDate(historyCursor),
            historyCursorDate
        )
        let legacyHistoryCursor = try PropertyListSerialization.data(
            fromPropertyList: historyCursorDate,
            format: .binary,
            options: 0
        )
        XCTAssertEqual(
            HealthKitImportCoordinator.decodeDate(legacyHistoryCursor),
            historyCursorDate
        )
        let firstState = HealthKitTypeSyncState(
            typeIdentifier: sample.typeIdentifier,
            anchor: Data("anchor-1".utf8),
            historyCursor: historyCursor,
            historyComplete: true,
            sampleCount: 1,
            addedCount: 1,
            lastSampleDate: sample.endDate,
            lastSyncedAt: start
        )

        try await store.apply(
            records: [sample],
            deletedIDs: [],
            state: firstState
        )
        let records = try await store.records(
            from: start.addingTimeInterval(-1),
            through: start.addingTimeInterval(61)
        )
        let savedState = try await store.syncState(
            for: sample.typeIdentifier
        )
        XCTAssertEqual(records, [sample])
        XCTAssertEqual(savedState, firstState)

        let deletedState = HealthKitTypeSyncState(
            typeIdentifier: sample.typeIdentifier,
            anchor: Data("anchor-2".utf8),
            historyComplete: true,
            sampleCount: 0,
            addedCount: 1,
            deletedCount: 1,
            lastSampleDate: sample.endDate,
            lastDeletionDate: start.addingTimeInterval(120),
            lastSyncedAt: start.addingTimeInterval(120)
        )
        try await store.apply(
            records: [],
            deletedIDs: [sample.uuid],
            state: deletedState
        )
        let remaining = try await store.records(
            from: start.addingTimeInterval(-1),
            through: start.addingTimeInterval(121)
        )
        let finalState = try await store.syncState(
            for: sample.typeIdentifier
        )
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(finalState, deletedState)
    }

    func testHealthKitDeleteAllClearsSamplesAndSyncAnchors() async throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let store = try HealthKitImportStore(databaseURL: url)
        let date = Date(timeIntervalSince1970: 1_788_100_000)
        let sample = HealthKitSampleRecord(
            uuid: UUID(),
            typeIdentifier: "HKQuantityTypeIdentifierHeartRate",
            startDate: date,
            endDate: date,
            numericValue: 72,
            unit: "count/min"
        )
        try await store.apply(
            records: [sample],
            deletedIDs: [],
            state: HealthKitTypeSyncState(
                typeIdentifier: sample.typeIdentifier,
                anchor: Data("anchor".utf8),
                sampleCount: 1,
                addedCount: 1,
                lastSyncedAt: date
            )
        )

        try await store.deleteAll()

        let records = try await store.records(
            from: date.addingTimeInterval(-1),
            through: date.addingTimeInterval(1)
        )
        let state = try await store.syncState(for: sample.typeIdentifier)
        XCTAssertTrue(records.isEmpty)
        XCTAssertNil(state)
    }

    func testHealthCategoryIsAvailableForNonDiagnosticProjection() {
        let health = RecordClassificationCatalog.categories.first {
            $0.id == "health"
        }
        XCTAssertEqual(health?.title, "건강관리")
        XCTAssertEqual(
            Set(health?.details.map(\.id) ?? []),
            [
                "health.wellness",
                "health.vitals",
                "health.recovery",
                "health.medication",
            ]
        )
    }

    func testExplicitMedicationAndClinicalRecordsUseNonDiagnosticHealthTitles() {
        let start = Date(timeIntervalSince1970: 1_788_000_000)
        let span = TimeSpan(
            start: start.addingTimeInterval(-60),
            end: start.addingTimeInterval(3_600)
        )
        let records = [
            HealthKitSampleRecord(
                uuid: UUID(),
                typeIdentifier:
                    "HKMedicationDoseEventTypeIdentifierMedicationDoseEvent",
                startDate: start,
                endDate: start,
                categoryValue: 4,
                sourceName: "Health",
                userEntered: true
            ),
            HealthKitSampleRecord(
                uuid: UUID(),
                typeIdentifier: "HKClinicalTypeIdentifierConditionRecord",
                startDate: start.addingTimeInterval(1_200),
                endDate: start.addingTimeInterval(1_200),
                textValue: "private diagnosis text",
                sourceName: "Health",
                sourceBundleIdentifier: "com.apple.Health"
            ),
        ]

        let actuals = HealthKitBehaviorProjectionEngine.actuals(
            from: records,
            in: span
        )

        XCTAssertEqual(actuals.map(\.categoryID), ["health", "health"])
        XCTAssertEqual(actuals.map(\.title), ["투약", "건강 기록"])
        XCTAssertFalse(actuals.map(\.title).contains("private diagnosis text"))
        XCTAssertTrue(actuals.allSatisfy {
            $0.evidence.contains { $0.contains("sampleUUIDs=") }
        })
    }

    func testSustainedHeartRateDeviationCreatesActivityEstimateWithWarmBaseline() {
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.startOfDay(
            for: Date(timeIntervalSince1970: 1_788_000_000)
        )
        var records: [HealthKitSampleRecord] = []
        for dayOffset in -8 ... -1 {
            for sampleOffset in 0..<4 {
                let date = calendar.date(
                    byAdding: .day,
                    value: dayOffset,
                    to: day
                )!.addingTimeInterval(TimeInterval(sampleOffset * 15 * 60))
                records.append(heartRateRecord(at: date, value: 60))
            }
        }
        let elevatedStart = day.addingTimeInterval(9 * 3_600)
        for minute in [0, 3, 6, 9, 12] {
            records.append(
                heartRateRecord(
                    at: elevatedStart.addingTimeInterval(
                        TimeInterval(minute * 60)
                    ),
                    value: 105
                )
            )
        }
        let span = TimeSpan(
            start: day,
            end: day.addingTimeInterval(86_400)
        )

        let actuals = HealthKitBehaviorProjectionEngine.actuals(
            from: records,
            in: span
        )

        let estimate = actuals.first { $0.title == "활동 추정" }
        XCTAssertEqual(estimate?.categoryID, "activity")
        XCTAssertEqual(estimate?.behavior, "activity-estimate")
        XCTAssertEqual(estimate?.confidence, .medium)
        XCTAssertTrue(estimate?.evidence.contains {
            $0.contains("baseline median=")
        } == true)
        let watchRecords = records.map {
            biometricRecord(
                identifier: $0.typeIdentifier,
                at: $0.startDate,
                value: $0.numericValue!,
                unit: "count/min",
                sourceBundleIdentifier: "com.taption.plan.watchkitapp"
            )
        }
        let watchActuals = HealthKitBehaviorProjectionEngine.actuals(
            from: watchRecords, in: span
        )
        XCTAssertEqual(watchActuals.map(\.categoryID), actuals.map(\.categoryID))
        XCTAssertEqual(watchActuals.map(\.behavior), actuals.map(\.behavior))
    }

    func testContinuousBiometricDoesNotProjectWithoutSevenDayBaseline() {
        let start = Date(timeIntervalSince1970: 1_788_000_000)
        let records = [0, 4, 8, 12].map {
            heartRateRecord(
                at: start.addingTimeInterval(TimeInterval($0 * 60)),
                value: 120
            )
        }
        let actuals = HealthKitBehaviorProjectionEngine.actuals(
            from: records,
            in: TimeSpan(
                start: start,
                end: start.addingTimeInterval(3_600)
            )
        )
        XCTAssertTrue(actuals.isEmpty)
    }

    func testUntrustedContinuousSourceDoesNotCreateAutomaticEstimate() {
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.startOfDay(
            for: Date(timeIntervalSince1970: 1_788_000_000)
        )
        var records: [HealthKitSampleRecord] = []
        for dayOffset in -8 ... -1 {
            for sampleOffset in 0..<4 {
                let date = calendar.date(
                    byAdding: .day,
                    value: dayOffset,
                    to: day
                )!.addingTimeInterval(TimeInterval(sampleOffset * 15 * 60))
                records.append(biometricRecord(
                    identifier: "HKQuantityTypeIdentifierHeartRate",
                    at: date,
                    value: 60,
                    unit: "count/min",
                    sourceBundleIdentifier: "com.example.other-health"
                ))
            }
        }
        let elevatedStart = day.addingTimeInterval(9 * 3_600)
        for minute in [0, 3, 6, 9, 12] {
            records.append(biometricRecord(
                identifier: "HKQuantityTypeIdentifierHeartRate",
                at: elevatedStart.addingTimeInterval(TimeInterval(minute * 60)),
                value: 105,
                unit: "count/min",
                sourceBundleIdentifier: "com.example.other-health"
            ))
        }

        let actuals = HealthKitBehaviorProjectionEngine.actuals(
            from: records,
            in: TimeSpan(
                start: day,
                end: day.addingTimeInterval(86_400)
            )
        )

        XCTAssertTrue(actuals.isEmpty)
    }

    func testTargetDayDoesNotCompleteSevenDayBaseline() {
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.startOfDay(
            for: Date(timeIntervalSince1970: 1_788_000_000)
        )
        var records: [HealthKitSampleRecord] = []
        for dayOffset in -6 ... -1 {
            for sampleOffset in 0..<4 {
                let date = calendar.date(
                    byAdding: .day,
                    value: dayOffset,
                    to: day
                )!.addingTimeInterval(TimeInterval(sampleOffset * 15 * 60))
                records.append(heartRateRecord(at: date, value: 60))
            }
        }
        let elevatedStart = day.addingTimeInterval(9 * 3_600)
        for minute in [0, 3, 6, 9, 12] {
            records.append(heartRateRecord(
                at: elevatedStart.addingTimeInterval(TimeInterval(minute * 60)),
                value: 105
            ))
        }

        let actuals = HealthKitBehaviorProjectionEngine.actuals(
            from: records,
            in: TimeSpan(
                start: day,
                end: day.addingTimeInterval(86_400)
            )
        )

        XCTAssertFalse(actuals.contains { $0.title == "활동 추정" })
    }

    func testHeartRateVariabilityProjectsAsVitalsInsteadOfActivity() {
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.startOfDay(
            for: Date(timeIntervalSince1970: 1_788_000_000)
        )
        var records: [HealthKitSampleRecord] = []
        for dayOffset in -8 ... -1 {
            for sampleOffset in 0..<4 {
                records.append(biometricRecord(
                    identifier:
                        "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
                    at: calendar.date(
                        byAdding: .day,
                        value: dayOffset,
                        to: day
                    )!.addingTimeInterval(TimeInterval(sampleOffset * 15 * 60)),
                    value: 50,
                    unit: "ms"
                ))
            }
        }
        let changedStart = day.addingTimeInterval(9 * 3_600)
        for minute in [0, 3, 6, 9, 12] {
            records.append(biometricRecord(
                identifier: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
                at: changedStart.addingTimeInterval(TimeInterval(minute * 60)),
                value: 80,
                unit: "ms"
            ))
        }

        let actuals = HealthKitBehaviorProjectionEngine.actuals(
            from: records,
            in: TimeSpan(
                start: day,
                end: day.addingTimeInterval(86_400)
            )
        )

        XCTAssertTrue(actuals.contains {
            $0.title == "생체 변화" && $0.categoryID == "health"
        })
        XCTAssertFalse(actuals.contains { $0.title == "활동 추정" })
    }

    func testMedicationInventoryDoesNotCreateAFakeDoseEvent() {
        let start = Date(timeIntervalSince1970: 1_788_000_000)
        let record = HealthKitSampleRecord(
            uuid: UUID(),
            typeIdentifier:
                "HKDataTypeIdentifierUserAnnotatedMedicationConcept",
            startDate: start,
            endDate: start,
            textValue: "Medication inventory",
            sourceName: "Apple Health",
            userEntered: true
        )

        XCTAssertTrue(
            HealthKitBehaviorProjectionEngine.actuals(
                from: [record],
                in: TimeSpan(
                    start: start.addingTimeInterval(-60),
                    end: start.addingTimeInterval(600)
                )
            ).isEmpty
        )
    }

    func testNutrientSamplesAtOneMealMergeIntoOneTimelineCandidate() {
        let start = Date(timeIntervalSince1970: 1_788_000_000)
        let identifiers = [
            "HKQuantityTypeIdentifierDietaryCarbohydrates",
            "HKQuantityTypeIdentifierDietaryProtein",
            "HKQuantityTypeIdentifierDietaryFatTotal",
        ]
        let records = identifiers.enumerated().map { index, identifier in
            HealthKitSampleRecord(
                uuid: UUID(),
                typeIdentifier: identifier,
                startDate: start.addingTimeInterval(TimeInterval(index * 60)),
                endDate: start.addingTimeInterval(TimeInterval(index * 60)),
                numericValue: 10,
                unit: "g",
                sourceName: "Nutrition App",
                userEntered: true
            )
        }

        let actuals = HealthKitBehaviorProjectionEngine.actuals(
            from: records,
            in: TimeSpan(
                start: start.addingTimeInterval(-60),
                end: start.addingTimeInterval(30 * 60)
            )
        )

        XCTAssertEqual(actuals.count, 1)
        XCTAssertEqual(actuals.first?.categoryID, "eating")
        XCTAssertEqual(
            actuals.first?.evidence.filter { $0.contains("sampleUUIDs=") }.count,
            3
        )
    }

    private func heartRateRecord(
        at date: Date,
        value: Double
    ) -> HealthKitSampleRecord {
        biometricRecord(
            identifier: "HKQuantityTypeIdentifierHeartRate",
            at: date,
            value: value,
            unit: "count/min"
        )
    }

    private func biometricRecord(
        identifier: String,
        at date: Date,
        value: Double,
        unit: String,
        sourceBundleIdentifier: String? = "com.apple.Health"
    ) -> HealthKitSampleRecord {
        HealthKitSampleRecord(
            uuid: UUID(),
            typeIdentifier: identifier,
            startDate: date,
            endDate: date,
            numericValue: value,
            unit: unit,
            sourceName: "Apple Watch",
            sourceBundleIdentifier: sourceBundleIdentifier,
            sourceProductType: "Watch"
        )
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("healthkit-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
    }

    private func removeDatabase(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }
}
