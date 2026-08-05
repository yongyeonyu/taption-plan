import XCTest
@testable import TaptionPlan

/// `CMSensorRecorder.accelerometerData(from:to:)`는 잘못된 범위에 예외로
/// 답하고 Swift는 그 예외를 잡을 수 없다. 실기기 CoreMotion 없이 검증할 수
/// 있는 부분은 "애초에 잘못된 범위를 만들지 않는다"는 것뿐이므로, 범위
/// 계산과 워터마크 규칙을 순수 값 계산으로 떼어내 여기서 확인한다.
/// 예외 경로 자체(Objective-C 예외를 실제로 잡는지)는 실기기에서만
/// 확인할 수 있다.
final class WatchSensorQueryPlanTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func windows(
        armedAt: Date?,
        highWater: Date?,
        chunk: TimeInterval = WatchSensorQueryPlan.chunkSpan
    ) -> [WatchSensorQueryWindow] {
        WatchSensorQueryPlan.windows(
            now: now,
            armedAt: armedAt,
            highWater: highWater,
            chunk: chunk
        )
    }

    // MARK: - 기록을 건 적 없는 상태

    func testNeverArmedRecorderIssuesNoQuery() {
        XCTAssertTrue(windows(armedAt: nil, highWater: nil).isEmpty)
        XCTAssertTrue(
            windows(armedAt: nil, highWater: now.addingTimeInterval(-3_600))
                .isEmpty
        )
    }

    func testArmingAndDrainingInTheSameRunIssuesNoQuery() {
        // 실행 경로가 arm() 직후 drain()을 부른다. 첫 실행에서는 무장
        // 시각이 곧 현재라 조회 가능한 구간이 존재하지 않는다.
        XCTAssertTrue(windows(armedAt: now, highWater: nil).isEmpty)
    }

    // MARK: - 무장 이전 구간

    func testQueryNeverStartsBeforeRecordingWasArmed() {
        let armedAt = now.addingTimeInterval(-2 * 3_600)
        let stale = now.addingTimeInterval(-2 * 86_400)
        let result = windows(armedAt: armedAt, highWater: stale)
        XCTAssertFalse(result.isEmpty)
        XCTAssertEqual(result.first?.start, armedAt)
        XCTAssertTrue(result.allSatisfy { $0.start >= armedAt })
    }

    func testWatermarkAfterArmTimeIsRespected() {
        let armedAt = now.addingTimeInterval(-6 * 3_600)
        let highWater = now.addingTimeInterval(-3_600)
        let result = windows(armedAt: armedAt, highWater: highWater)
        XCTAssertEqual(result.first?.start, highWater)
    }

    // MARK: - 보관 한계

    func testQueryNeverReachesBelowTheRetentionFloor() {
        let armedAt = now.addingTimeInterval(-10 * 86_400)
        let result = windows(armedAt: armedAt, highWater: nil)
        let floor = now.addingTimeInterval(
            -WatchSensorQueryPlan.retentionSpan
                + WatchSensorQueryPlan.retentionMargin
        )
        XCTAssertEqual(result.first?.start, floor)
        XCTAssertTrue(result.allSatisfy { $0.start >= floor })
    }

    func testRetentionFloorKeepsAMarginAboveTheHardLimit() {
        let armedAt = now.addingTimeInterval(-10 * 86_400)
        let oldest = windows(armedAt: armedAt, highWater: nil).first
        let hardLimit = now.addingTimeInterval(
            -WatchSensorQueryPlan.retentionSpan
        )
        XCTAssertGreaterThan(
            oldest?.start.timeIntervalSince(hardLimit) ?? 0,
            0
        )
    }

    // MARK: - 뒤집힌 범위와 빈 범위

    func testInvertedRangeIsNeverIssued() {
        let armedAt = now.addingTimeInterval(-6 * 3_600)
        // 워터마크가 조회 가능한 끝을 넘어섰다.
        let ahead = now.addingTimeInterval(-30)
        XCTAssertTrue(windows(armedAt: armedAt, highWater: ahead).isEmpty)
    }

    func testFutureWatermarkIsDiscardedInsteadOfStallingForever() {
        let armedAt = now.addingTimeInterval(-6 * 3_600)
        let future = now.addingTimeInterval(86_400)
        XCTAssertNil(
            WatchSensorQueryPlan.sanitizedHighWater(future, now: now)
        )
        let result = windows(armedAt: armedAt, highWater: future)
        XCTAssertEqual(result.first?.start, armedAt)
    }

    func testRangeShorterThanOneAnalysisWindowIsNeverIssued() {
        let armedAt = now.addingTimeInterval(-6 * 3_600)
        let edge = now.addingTimeInterval(
            -WatchSensorQueryPlan.availabilityLag - 1
        )
        XCTAssertTrue(windows(armedAt: armedAt, highWater: edge).isEmpty)
    }

    func testEqualStartAndEndIsNeverIssued() {
        let edge = now.addingTimeInterval(-WatchSensorQueryPlan.availabilityLag)
        XCTAssertTrue(windows(armedAt: edge, highWater: edge).isEmpty)
    }

    // MARK: - 길이 한계

    func testNoWindowExceedsTheDocumentedTwelveHourMaximum() {
        let armedAt = now.addingTimeInterval(-2 * 86_400)
        for window in windows(armedAt: armedAt, highWater: nil) {
            XCTAssertLessThanOrEqual(
                window.duration,
                WatchSensorQueryPlan.maximumQuerySpan
            )
        }
    }

    func testOverLongChunkRequestIsClampedToTwelveHours() {
        let armedAt = now.addingTimeInterval(-2 * 86_400)
        let result = windows(
            armedAt: armedAt,
            highWater: nil,
            chunk: 48 * 3_600
        )
        XCTAssertFalse(result.isEmpty)
        for window in result {
            XCTAssertLessThanOrEqual(
                window.duration,
                WatchSensorQueryPlan.maximumQuerySpan
            )
        }
    }

    func testDefaultChunkStaysWithinTheDocumentedMaximum() {
        XCTAssertLessThanOrEqual(
            WatchSensorQueryPlan.chunkSpan,
            WatchSensorQueryPlan.maximumQuerySpan
        )
    }

    // MARK: - 조회 목록의 모양

    func testWindowsAreContiguousForwardAndNonEmpty() {
        let armedAt = now.addingTimeInterval(-5 * 3_600)
        let result = windows(armedAt: armedAt, highWater: nil)
        XCTAssertFalse(result.isEmpty)
        for window in result {
            XCTAssertLessThan(window.start, window.end)
        }
        for (previous, next) in zip(result, result.dropFirst()) {
            XCTAssertEqual(previous.end, next.start)
        }
    }

    func testLastWindowStopsBeforeTheThreeMinuteAvailabilityLag() {
        let armedAt = now.addingTimeInterval(-5 * 3_600)
        let result = windows(armedAt: armedAt, highWater: nil)
        XCTAssertEqual(
            result.last?.end,
            now.addingTimeInterval(-WatchSensorQueryPlan.availabilityLag)
        )
    }

    func testWindowCountIsBoundedEvenAcrossTheWholeRetentionSpan() {
        let armedAt = now.addingTimeInterval(-30 * 86_400)
        let result = windows(armedAt: armedAt, highWater: nil)
        XCTAssertLessThanOrEqual(
            result.count,
            WatchSensorQueryPlan.maximumWindowsPerDrain
        )
    }

    // MARK: - 워터마크

    func testLedgerAdvancesPastASuccessfulWindow() {
        var ledger = WatchSensorDrainLedger(highWater: nil)
        let window = WatchSensorQueryWindow(
            start: now.addingTimeInterval(-3_600),
            end: now.addingTimeInterval(-1_800)
        )
        ledger.succeeded(window)
        XCTAssertEqual(ledger.highWater, window.end)
        XCTAssertEqual(ledger.failureCount, 0)
        XCTAssertFalse(ledger.isExhausted)
    }

    func testLedgerAdvancesPastAThrowingWindowSoItIsNeverRetriedForever() {
        let start = now.addingTimeInterval(-3_600)
        let window = WatchSensorQueryWindow(
            start: start,
            end: start.addingTimeInterval(1_800)
        )
        var ledger = WatchSensorDrainLedger(highWater: start)
        ledger.failed(window)
        XCTAssertEqual(ledger.highWater, window.end)
        XCTAssertEqual(ledger.failureCount, 1)

        // 다음 실행은 같은 범위를 다시 만들지 않는다.
        let next = WatchSensorQueryPlan.windows(
            now: now,
            armedAt: start,
            highWater: ledger.highWater
        )
        XCTAssertTrue(next.allSatisfy { $0.start >= window.end })
    }

    func testLedgerNeverMovesTheWatermarkBackwards() {
        let ahead = now.addingTimeInterval(-600)
        var ledger = WatchSensorDrainLedger(highWater: ahead)
        let older = WatchSensorQueryWindow(
            start: now.addingTimeInterval(-7_200),
            end: now.addingTimeInterval(-5_400)
        )
        ledger.succeeded(older)
        XCTAssertEqual(ledger.highWater, ahead)
        ledger.failed(older)
        XCTAssertEqual(ledger.highWater, ahead)
    }

    func testLedgerStopsAfterTheFailureLimitWithoutLosingProgress() {
        let start = now.addingTimeInterval(-6 * 3_600)
        var ledger = WatchSensorDrainLedger(highWater: start, failureLimit: 2)
        var cursor = start
        while !ledger.isExhausted {
            let window = WatchSensorQueryWindow(
                start: cursor,
                end: cursor.addingTimeInterval(1_800)
            )
            ledger.failed(window)
            cursor = window.end
        }
        XCTAssertEqual(ledger.failureCount, 2)
        XCTAssertEqual(ledger.highWater, cursor)
    }

    func testMixedSuccessAndFailureLeavesNoUnreadGapBehindTheWatermark() {
        let start = now.addingTimeInterval(-4 * 3_600)
        let plan = WatchSensorQueryPlan.windows(
            now: now,
            armedAt: start,
            highWater: nil
        )
        var ledger = WatchSensorDrainLedger(
            highWater: nil,
            failureLimit: plan.count + 1
        )
        for (index, window) in plan.enumerated() {
            if index % 3 == 0 {
                ledger.failed(window)
            } else {
                ledger.succeeded(window)
            }
        }
        // 워터마크는 계획한 마지막 지점과 정확히 같다. 뒤에 남은 구간도,
        // 이미 읽은 구간을 다시 읽는 일도 없다.
        XCTAssertEqual(ledger.highWater, plan.last?.end)
    }
}
