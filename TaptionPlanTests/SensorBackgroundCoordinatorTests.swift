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
}
