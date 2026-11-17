import XCTest
@testable import TaptionWatchSync

// WSY1117A01: 한 번 보낸 outbox 항목은 ack를 기다리고, 재시도 시각 전에는 다시 보내지 않는다.
final class WatchOutboxResendGateTests: XCTestCase {
    func testFinishedTransferWaitsForAcknowledgementBeforeResending() {
        var gate = TaptionWatchOutboxResendGate()
        XCTAssertTrue(gate.shouldTransfer(id: "summary:a", retryCount: 0, isOutstanding: false, isRetryDue: false, now: 100))
        // 전송이 끝나 outstanding에서 빠졌어도, 다른 항목의 ack·새 기록으로 flush가 돌면 기다린다.
        XCTAssertFalse(gate.shouldTransfer(id: "summary:a", retryCount: 0, isOutstanding: false, isRetryDue: false, now: 101))
        XCTAssertFalse(gate.shouldTransfer(id: "summary:a", retryCount: 0, isOutstanding: false, isRetryDue: false, now: 104.9))
        // 새 항목은 바로 보낸다.
        XCTAssertTrue(gate.shouldTransfer(id: "chunk:b", retryCount: 0, isOutstanding: false, isRetryDue: false, now: 101))
    }

    func testRetryTimerOrElapsedAcknowledgementWaitAllowsResend() {
        var gate = TaptionWatchOutboxResendGate()
        XCTAssertTrue(gate.shouldTransfer(id: "summary:a", retryCount: 0, isOutstanding: false, isRetryDue: false, now: 100))
        XCTAssertTrue(gate.shouldTransfer(id: "summary:a", retryCount: 0, isOutstanding: false, isRetryDue: true, now: 103), "재시도 시각이 온 항목")
        XCTAssertFalse(gate.shouldTransfer(id: "summary:a", retryCount: 1, isOutstanding: false, isRetryDue: false, now: 112))
        XCTAssertTrue(gate.shouldTransfer(id: "summary:a", retryCount: 1, isOutstanding: false, isRetryDue: false, now: 113))
    }

    func testOutstandingTransferIsNeverDuplicated() {
        var gate = TaptionWatchOutboxResendGate()
        XCTAssertFalse(gate.shouldTransfer(id: "summary:a", retryCount: 0, isOutstanding: true, isRetryDue: true, now: 100))
        XCTAssertTrue(gate.shouldTransfer(id: "summary:a", retryCount: 0, isOutstanding: false, isRetryDue: false, now: 100))
    }

    func testAcknowledgementAndResetForgetSentItems() {
        var gate = TaptionWatchOutboxResendGate()
        XCTAssertTrue(gate.shouldTransfer(id: "summary:a", retryCount: 0, isOutstanding: false, isRetryDue: false, now: 100))
        XCTAssertTrue(gate.shouldTransfer(id: "chunk:b", retryCount: 0, isOutstanding: false, isRetryDue: false, now: 100))
        gate.acknowledge("summary:a")
        XCTAssertTrue(gate.shouldTransfer(id: "summary:a", retryCount: 0, isOutstanding: false, isRetryDue: false, now: 101), "ack 뒤 같은 ID가 다시 들어오면 새 항목")
        gate.reset()
        XCTAssertTrue(gate.shouldTransfer(id: "chunk:b", retryCount: 0, isOutstanding: false, isRetryDue: false, now: 101))
    }

    func testClockGoingBackwardsDoesNotBlockForever() {
        var gate = TaptionWatchOutboxResendGate()
        XCTAssertTrue(gate.shouldTransfer(id: "summary:a", retryCount: 0, isOutstanding: false, isRetryDue: false, now: 500))
        XCTAssertTrue(gate.shouldTransfer(id: "summary:a", retryCount: 0, isOutstanding: false, isRetryDue: false, now: 10))
    }
}
