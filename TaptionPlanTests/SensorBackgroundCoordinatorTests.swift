import XCTest
@testable import TaptionPlan

@MainActor
final class SensorBackgroundCoordinatorTests: XCTestCase {
    func testWakeReasonsAreDeduplicatedIndependently() {
        let coordinator = SensorBackgroundCoordinator(
            wakeDeduplicationWindow: 5
        )
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(coordinator.receiveWake(.appLaunch, at: start))
        XCTAssertFalse(
            coordinator.receiveWake(
                .appLaunch,
                at: start.addingTimeInterval(4)
            )
        )
        XCTAssertTrue(
            coordinator.receiveWake(
                .locationRelaunch,
                at: start.addingTimeInterval(4)
            )
        )
        XCTAssertEqual(coordinator.sessionState, .waiting)
        XCTAssertEqual(coordinator.lastWakeReason, .locationRelaunch)
    }

    func testSaveTokenIsMonotonicAndTracksLatestWrite() {
        let coordinator = SensorBackgroundCoordinator()
        let date = Date(timeIntervalSince1970: 2_000)

        XCTAssertEqual(coordinator.markSaved(at: date), 1)
        XCTAssertEqual(
            coordinator.markSaved(
                at: date.addingTimeInterval(1),
                persistedToken: 8
            ),
            8
        )
        XCTAssertEqual(
            coordinator.markSaved(
                at: date.addingTimeInterval(2),
                persistedToken: 3
            ),
            9
        )
        XCTAssertEqual(coordinator.lastSavedAt, date.addingTimeInterval(2))
    }

    func testAutomaticSessionCanBeCancelledAndExpires() {
        let coordinator = SensorBackgroundCoordinator(
            defaultSessionLifetime: 10
        )
        let start = Date(timeIntervalSince1970: 3_000)

        XCTAssertTrue(coordinator.beginAutomaticSession(at: start))
        XCTAssertEqual(coordinator.sessionState, .collecting)
        XCTAssertFalse(
            coordinator.expireIfNeeded(at: start.addingTimeInterval(9))
        )
        XCTAssertTrue(
            coordinator.expireIfNeeded(at: start.addingTimeInterval(10))
        )
        XCTAssertEqual(coordinator.sessionState, .stopped)
        XCTAssertNil(coordinator.sessionStartedAt)

        _ = coordinator.receiveWake(.foregroundResume, at: start)
        XCTAssertTrue(coordinator.beginAutomaticSession(at: start))
        coordinator.cancel()
        XCTAssertEqual(coordinator.sessionState, .stopped)
        XCTAssertNil(coordinator.lastWakeReason)
    }

    func testEverySystemWakeReasonCanRecoverAndClockRollbackIsAccepted() {
        let coordinator = SensorBackgroundCoordinator(
            wakeDeduplicationWindow: 5
        )
        let start = Date(timeIntervalSince1970: 5_000)

        for (offset, reason) in SensorWakeReason.allCases.enumerated() {
            XCTAssertTrue(
                coordinator.receiveWake(
                    reason,
                    at: start.addingTimeInterval(Double(offset))
                )
            )
        }
        XCTAssertTrue(
            coordinator.receiveWake(
                .bgAppRefresh,
                at: start.addingTimeInterval(-60)
            )
        )
        _ = coordinator.markSaved(at: start)
        _ = coordinator.markSaved(at: start.addingTimeInterval(-60))
        XCTAssertEqual(coordinator.lastSavedAt, start)
    }

    func testBackgroundCollectionSessionPersistsAcrossProcessRecreation() {
        let suite = "SensorBackgroundCoordinatorTests.persistence"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let key = "session"
        let startedAt = Date(timeIntervalSince1970: 8_000)

        let first = SensorBackgroundCoordinator(
            defaults: defaults,
            storageKey: key
        )
        XCTAssertTrue(first.beginCollectionSession(at: startedAt))
        let sessionID = first.sessionID
        _ = first.markSaved(at: startedAt.addingTimeInterval(30))

        let restored = SensorBackgroundCoordinator(
            defaults: defaults,
            storageKey: key
        )
        XCTAssertEqual(restored.sessionState, .collecting)
        XCTAssertEqual(restored.sessionID, sessionID)
        XCTAssertEqual(restored.sessionStartedAt, startedAt)
        XCTAssertEqual(
            restored.lastSavedAt,
            startedAt.addingTimeInterval(30)
        )
        XCTAssertFalse(
            restored.expireIfNeeded(
                at: startedAt.addingTimeInterval(24 * 60 * 60)
            )
        )

        restored.cancel()
        defaults.removePersistentDomain(forName: suite)
    }

    func testBackgroundRefreshUsesSystemSafeMinimumAndSavedInterval() {
        XCTAssertEqual(
            SensorBackgroundRefreshPolicy.delay(for: 1),
            15 * 60
        )
        XCTAssertEqual(
            SensorBackgroundRefreshPolicy.delay(for: 30 * 60),
            30 * 60
        )

        let suite = "SensorBackgroundCoordinatorTests.refresh-policy"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        SensorBackgroundRefreshPolicy.save(
            intervalSeconds: 1_800,
            defaults: defaults
        )
        XCTAssertEqual(
            SensorBackgroundRefreshPolicy.savedDelay(defaults: defaults),
            1_800
        )
        defaults.removePersistentDomain(forName: suite)
    }
}
