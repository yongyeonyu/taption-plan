import XCTest
import Synchronization
@testable import TaptionWatchSync

private final class Flag: Sendable {
    private let value = Mutex(false)
    func set() { value.withLock { $0 = true } }
    var isSet: Bool { value.withLock { $0 } }
}

// WSY1117A01: 백그라운드 새로고침은 작업이 끝나기를 기다리지 않고 예산 안에 돌아와 완료를 보고한다.
final class WatchBackgroundBudgetTests: XCTestCase {
    func testOverBudgetWorkIsCancelledWithoutWaitingForIt() async {
        let cancelled = Flag()
        let began = ContinuousClock.now
        let finished = await TaptionWatchBackgroundBudget.run(within: .milliseconds(100)) {
            await withTaskCancellationHandler {
                // 취소를 무시하고 오래 걸리는 작업(예: 따로 띄운 Task를 기다리는 동기화).
                let end = ContinuousClock.now + .seconds(3)
                while ContinuousClock.now < end {
                    try? await Task.sleep(for: .milliseconds(20))
                }
            } onCancel: {
                cancelled.set()
            }
        }
        let elapsed = ContinuousClock.now - began
        XCTAssertFalse(finished)
        XCTAssertTrue(cancelled.isSet, "예산을 넘긴 작업에 취소를 알린다")
        XCTAssertLessThan(elapsed, .seconds(1), "작업이 끝날 때까지 기다리지 않는다")
    }

    func testWorkWithinBudgetReportsFinished() async {
        let ran = Flag()
        let finished = await TaptionWatchBackgroundBudget.run(within: .seconds(5)) {
            ran.set()
        }
        XCTAssertTrue(finished)
        XCTAssertTrue(ran.isSet)
    }

    func testBudgetsLeaveRoomInsideTheSystemLimit() {
        // watchOS 백그라운드 작업은 수 초~15초 안에 완료를 보고해야 한다.
        XCTAssertLessThanOrEqual(TaptionWatchBackgroundBudget.refresh, .seconds(10))
        XCTAssertLessThanOrEqual(TaptionWatchBackgroundBudget.connectivityWait, .seconds(10))
        XCTAssertEqual(TaptionWatchBackgroundBudget.ambientWindowsPerBackgroundRun, 1)
    }
}
