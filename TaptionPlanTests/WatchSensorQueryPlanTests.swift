import XCTest
@testable import TaptionPlan
import TaptionPlanCore

private actor PurgeInterleavingDatabase {
    private enum Failure: Error { case injected }

    private var pausesAppends = true
    private var startedAppendCount = 0
    private var completedAppendCount = 0
    private var appendContinuations: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [
        (count: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []
    private var deleteAttemptCount = 0

    func append() async throws {
        if pausesAppends {
            await withCheckedContinuation { continuation in
                startedAppendCount += 1
                appendContinuations.append(continuation)
                let ready = startWaiters.filter {
                    startedAppendCount >= $0.count
                }
                startWaiters.removeAll {
                    startedAppendCount >= $0.count
                }
                ready.forEach { $0.continuation.resume() }
            }
        }
        completedAppendCount += 1
    }

    func waitForPausedAppends(_ count: Int) async {
        guard startedAppendCount < count else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((count, continuation))
        }
    }

    func releasePausedAppends() {
        pausesAppends = false
        let continuations = appendContinuations
        appendContinuations.removeAll(keepingCapacity: false)
        continuations.forEach { $0.resume() }
    }

    func deleteAll() throws {
        deleteAttemptCount += 1
        if deleteAttemptCount == 1 { throw Failure.injected }
    }

    func completedAppends() -> Int { completedAppendCount }
}

@MainActor
private final class PurgeState {
    var isPurging = false
}

/// `CMSensorRecorder.accelerometerData(from:to:)`는 잘못된 범위에 예외로
/// 답하고 Swift는 그 예외를 잡을 수 없다. 실기기 CoreMotion 없이 검증할 수
/// 있는 부분은 "애초에 잘못된 범위를 만들지 않는다"는 것뿐이므로, 범위
/// 계산과 워터마크 규칙을 순수 값 계산으로 떼어내 여기서 확인한다.
/// 예외 경로 자체(Objective-C 예외를 실제로 잡는지)는 실기기에서만
/// 확인할 수 있다.
final class WatchSensorQueryPlanTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testDataSyncRequestGateKeepsActiveRequestIDStable() {
        var gate = TaptionWatchDataSyncRequestGate()

        XCTAssertEqual(
            gate.begin(requestID: "request-a"),
            .accepted("request-a")
        )
        XCTAssertEqual(gate.activeRequestID, "request-a")
        XCTAssertEqual(
            gate.begin(requestID: "request-b"),
            .busy(
                activeRequestID: "request-a",
                rejectedRequestID: "request-b"
            )
        )
        XCTAssertEqual(gate.activeRequestID, "request-a")
        XCTAssertFalse(gate.finish("request-b"))
        XCTAssertTrue(gate.finish("request-a"))
        XCTAssertNil(gate.activeRequestID)
        XCTAssertEqual(
            gate.begin(requestID: "request-a"),
            .duplicate("request-a")
        )
        XCTAssertEqual(
            gate.begin(requestID: "request-b"),
            .accepted("request-b")
        )
    }

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
        XCTAssertEqual(
            result.first?.start,
            highWater.addingTimeInterval(-WatchSensorQueryPlan.availabilityLag)
        )
    }

    func testLegacyHighWaterWithoutPendingSessionSurvivesRecorderRearm() {
        let recordingDuration: TimeInterval = 12 * 3_600
        let legacyArmedAt = now.addingTimeInterval(-13 * 3_600)
        let legacyArmedUntil = legacyArmedAt.addingTimeInterval(
            recordingDuration
        )
        let highWater = now.addingTimeInterval(-7 * 3_600)
        let pendingSessionID: UUID? = nil
        XCTAssertNil(pendingSessionID)
        XCTAssertLessThanOrEqual(
            legacyArmedUntil.timeIntervalSince(now),
            30 * 60
        )

        let armedAt = WatchSensorQueryPlan.restoredArmedAt(
            stored: nil,
            armedUntil: legacyArmedUntil,
            recordingDuration: recordingDuration
        )
        XCTAssertEqual(armedAt, legacyArmedAt)
        let rearmedUntil = now.addingTimeInterval(recordingDuration)
        XCTAssertEqual(
            WatchSensorQueryPlan.restoredArmedAt(
                stored: armedAt,
                armedUntil: rearmedUntil,
                recordingDuration: recordingDuration
            ),
            legacyArmedAt
        )

        let result = WatchSensorQueryPlan.windows(
            now: now,
            armedAt: armedAt,
            highWater: highWater
        )
        XCTAssertEqual(
            result.first?.start,
            highWater.addingTimeInterval(-WatchSensorQueryPlan.availabilityLag)
        )
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

    func testAmbientArchiveSampleIDsAreStableAndUniqueWithinSession() {
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let first = TaptionWatchStableID.ambientAccelerationSample(
            sessionID: sessionID,
            sequence: 1
        )

        XCTAssertEqual(
            first,
            TaptionWatchStableID.ambientAccelerationSample(
                sessionID: sessionID,
                sequence: 1
            )
        )
        XCTAssertNotEqual(
            first,
            TaptionWatchStableID.ambientAccelerationSample(
                sessionID: sessionID,
                sequence: 2
            )
        )
        XCTAssertNotEqual(
            first,
            TaptionWatchStableID.ambientAccelerationSample(
                sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000100")!,
                sequence: 1
            )
        )
    }

    func testAmbientArchiveSequenceDoesNotShiftWhenLateSamplesArrive() {
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let anchor = Date(timeIntervalSince1970: 1_000_000)
        let originalDates = [1.0, 6.0, 11.0].map {
            anchor.addingTimeInterval($0)
        }
        let retryDates = [1.0, 5.5, 11.0].map {
            anchor.addingTimeInterval($0)
        }
        let originalSequences = originalDates.compactMap {
            TaptionWatchStableID.ambientAccelerationSequence(
                capturedAt: $0,
                anchor: anchor
            )
        }
        let retrySequences = retryDates.compactMap {
            TaptionWatchStableID.ambientAccelerationSequence(
                capturedAt: $0,
                anchor: anchor
            )
        }

        XCTAssertEqual(originalSequences.count, 3)
        XCTAssertEqual(retrySequences.count, 3)
        XCTAssertEqual(originalSequences[0], retrySequences[0])
        XCTAssertNotEqual(originalSequences[1], retrySequences[1])
        XCTAssertEqual(originalSequences[2], retrySequences[2])

        let archiveSample: (Int) -> TaptionWatchAccelerationSample = { sequence in
            TaptionWatchAccelerationSample(
                id: TaptionWatchStableID.ambientAccelerationSample(
                    sessionID: sessionID,
                    sequence: sequence
                ),
                capturedAt: anchor.addingTimeInterval(
                    Double(sequence - 1) / 1_000_000
                ),
                acceleration: .init(x: 0, y: 0, z: 0),
                sessionID: sessionID,
                sequence: sequence,
                isAmbient: true
            )
        }
        var index = TaptionWatchAccelerationArchiveAppendIndex()
        index.trackAmbientSessions([sessionID])
        originalSequences.forEach {
            XCTAssertTrue(index.insert(archiveSample($0)))
        }
        XCTAssertFalse(index.insert(archiveSample(retrySequences[0])))
        XCTAssertTrue(index.insert(archiveSample(retrySequences[1])))
        XCTAssertFalse(index.insert(archiveSample(retrySequences[2])))
    }

    func testAmbientSummarySequenceUsesStableTenMinuteWindows() {
        let anchor = Date(timeIntervalSince1970: 1_000_000)
        let first = anchor.addingTimeInterval(599)
        let late = anchor.addingTimeInterval(597)
        let next = anchor.addingTimeInterval(601)

        XCTAssertEqual(
            TaptionWatchStableID.ambientSummarySequence(
                capturedAt: first,
                anchor: anchor
            ),
            1
        )
        XCTAssertEqual(
            TaptionWatchStableID.ambientSummarySequence(
                capturedAt: late,
                anchor: anchor
            ),
            1
        )
        XCTAssertEqual(
            TaptionWatchStableID.ambientSummarySequence(
                capturedAt: next,
                anchor: anchor
            ),
            2
        )
        XCTAssertEqual(
            TaptionWatchStableID.ambientSummaryWindowStart(
                sequence: 2,
                anchor: anchor
            ),
            anchor.addingTimeInterval(600)
        )
    }

    func testAmbientAccelerationSampleAndSummaryWindowIDsSurviveDrainWatermarkMoves() {
        let sessionID = UUID()
        let armedAt = Date(timeIntervalSince1970: 1_000_000)
        let capturedAt = armedAt.addingTimeInterval(1_234)
        let sequence = TaptionWatchStableID.ambientAccelerationSequence(
            capturedAt: capturedAt,
            anchor: armedAt
        )!
        let firstSampleID = TaptionWatchStableID.ambientAccelerationSample(
            sessionID: sessionID,
            sequence: sequence
        )
        let retrySampleID = TaptionWatchStableID.ambientAccelerationSample(
            sessionID: sessionID,
            sequence: TaptionWatchStableID.ambientAccelerationSequence(
                capturedAt: capturedAt,
                anchor: armedAt
            )!
        )

        XCTAssertEqual(firstSampleID, retrySampleID)
        XCTAssertEqual(
            TaptionWatchStableID.ambientAccelerationSequence(
                capturedAt: capturedAt,
                anchor: armedAt
            ),
            sequence
        )
    }

    func testAmbientChunkRevisionChangesIDWithoutChangingLogicalWindow() {
        let sessionID = UUID()
        let original = TaptionWatchStableID.ambientAccelerationChunkID(
            sessionID: sessionID,
            sequence: 14,
            revision: 0
        )
        let retry = TaptionWatchStableID.ambientAccelerationChunkID(
            sessionID: sessionID,
            sequence: 14,
            revision: 0
        )
        let updated = TaptionWatchStableID.ambientAccelerationChunkID(
            sessionID: sessionID,
            sequence: 14,
            revision: 1
        )

        XCTAssertEqual(original, retry)
        XCTAssertNotEqual(original, updated)
        XCTAssertNotEqual(
            TaptionWatchStableID.ambientAccelerationChunkID(
                sessionID: sessionID,
                sequence: Int(UInt32.max) + 1,
                revision: 0
            ),
            TaptionWatchStableID.ambientAccelerationChunkID(
                sessionID: sessionID,
                sequence: 0,
                revision: 0
            )
        )
    }

    func testLegacyAmbientSummaryOverlapOnlySuppressesExactCrossSessionDuplicate() throws {
        let anchor = Date(timeIntervalSince1970: 1_000_000)
        let oldSessionID = UUID()
        let upgradedSessionID = UUID()
        let startedAt = anchor.addingTimeInterval(125)
        let existing = makeAmbientSummary(
            sessionID: oldSessionID,
            sequence: 125_000_001,
            startedAt: startedAt,
            windowStart: anchor
        )
        var duplicate = existing
        duplicate.sessionID = upgradedSessionID
        duplicate.sequence += 7
        duplicate.ambientWindowStart = nil

        XCTAssertNil(
            try TaptionWatchAmbientRevisionPolicy.nextSummaryRevision(
                for: duplicate,
                existing: [existing]
            )
        )

        var lateArrival = duplicate
        lateArrival.startedAt = startedAt.addingTimeInterval(5)
        lateArrival.endedAt = startedAt.addingTimeInterval(20)
        lateArrival.accelerometerSampleCount = 2
        let retained = try XCTUnwrap(
            TaptionWatchAmbientRevisionPolicy.nextSummaryRevision(
                for: lateArrival,
                existing: [existing]
            )
        )
        XCTAssertEqual(retained.sessionID, upgradedSessionID)
        XCTAssertEqual(retained.accelerometerSampleCount, 2)
    }

    func testLegacyAmbientChunkOverlapDropsOnlyPreviouslyStoredSamples() throws {
        let anchor = Date(timeIntervalSince1970: 1_000_000)
        let oldSessionID = UUID()
        let upgradedSessionID = UUID()
        let existingDates = [
            anchor.addingTimeInterval(10),
            anchor.addingTimeInterval(15),
        ]
        let lateDates = [
            anchor.addingTimeInterval(20),
            anchor.addingTimeInterval(25),
        ]
        func sample(_ date: Date, sequence: Int, sessionID: UUID) -> TaptionWatchAccelerationSample {
            TaptionWatchAccelerationSample(
                id: TaptionWatchStableID.ambientAccelerationSample(
                    capturedAt: date
                )!,
                capturedAt: date,
                acceleration: .init(x: Double(sequence), y: 0, z: 0),
                sessionID: sessionID,
                sequence: sequence,
                isAmbient: true
            )
        }
        let oldSamples = existingDates.enumerated().map { index, date in
            sample(date, sequence: index + 1, sessionID: oldSessionID)
        }
        let lateSampleValues = lateDates.enumerated().map { index, date in
            sample(date, sequence: index + 3, sessionID: upgradedSessionID)
        }
        let existing = TaptionWatchAccelerationChunk(
            sessionID: oldSessionID,
            sequence: 125_000_001,
            startedAt: existingDates[0],
            endedAt: existingDates[1],
            isAmbient: true,
            samples: oldSamples,
            ambientWindowStart: anchor
        )
        let overlapping = TaptionWatchAccelerationChunk(
            sessionID: upgradedSessionID,
            sequence: 125_000_008,
            startedAt: existingDates[0],
            endedAt: lateDates[1],
            isAmbient: true,
            samples: oldSamples + lateSampleValues,
            ambientWindowStart: anchor
        )

        let retained = try XCTUnwrap(
            TaptionWatchAmbientRevisionPolicy.nextChunkRevision(
                for: overlapping,
                existing: [existing]
            )
        )
        XCTAssertEqual(retained.samples.map(\.capturedAt), lateDates)
        XCTAssertEqual(retained.startedAt, lateDates[0])
        XCTAssertEqual(retained.endedAt, lateDates[1])
        XCTAssertEqual(retained.sessionID, upgradedSessionID)

        let fullyRepeated = TaptionWatchAccelerationChunk(
            sessionID: upgradedSessionID,
            sequence: 125_000_001,
            startedAt: existingDates[0],
            endedAt: existingDates[1],
            isAmbient: true,
            samples: oldSamples,
            ambientWindowStart: anchor
        )
        XCTAssertNil(
            try TaptionWatchAmbientRevisionPolicy.nextChunkRevision(
                for: fullyRepeated,
                existing: [existing]
            )
        )
    }

    func testAmbientGapSegmentsHaveStableDistinctSummaryIdentities() throws {
        let sessionID = UUID()
        let anchor = Date(timeIntervalSince1970: 1_000_000)
        let firstStart = anchor.addingTimeInterval(125)
        let secondStart = anchor.addingTimeInterval(250)
        let firstSequence = try XCTUnwrap(
            TaptionWatchStableID.ambientSummarySegmentSequence(
                startedAt: firstStart,
                anchor: anchor
            )
        )
        let secondSequence = try XCTUnwrap(
            TaptionWatchStableID.ambientSummarySegmentSequence(
                startedAt: secondStart,
                anchor: anchor
            )
        )
        let retrySequence = TaptionWatchStableID.ambientSummarySegmentSequence(
            startedAt: firstStart,
            anchor: anchor
        )

        XCTAssertEqual(firstSequence, retrySequence)
        XCTAssertNotEqual(firstSequence, secondSequence)
        XCTAssertEqual(
            TaptionWatchStableID.ambientSummarySequence(
                capturedAt: firstStart,
                anchor: anchor
            ),
            TaptionWatchStableID.ambientSummarySequence(
                capturedAt: secondStart,
                anchor: anchor
            )
        )

        let first = makeAmbientSummary(
            sessionID: sessionID,
            sequence: firstSequence,
            startedAt: firstStart,
            windowStart: anchor
        )
        let second = makeAmbientSummary(
            sessionID: sessionID,
            sequence: secondSequence,
            startedAt: secondStart,
            windowStart: anchor
        )
        let storedFirst = try XCTUnwrap(
            TaptionWatchAmbientRevisionPolicy.nextSummaryRevision(
                for: first,
                existing: []
            )
        )
        let storedSecond = try XCTUnwrap(
            TaptionWatchAmbientRevisionPolicy.nextSummaryRevision(
                for: second,
                existing: [storedFirst]
            )
        )

        XCTAssertNotEqual(storedFirst.rawEventID, storedSecond.rawEventID)
        XCTAssertNil(
            try TaptionWatchAmbientRevisionPolicy.nextSummaryRevision(
                for: first,
                existing: [storedFirst, storedSecond]
            )
        )
    }

    func testAmbientGapProducesSeparateProductionSummariesInSameWindow() throws {
        let sessionID = UUID()
        let anchor = Date(timeIntervalSince1970: 1_000_000)
        var accumulator = WatchAmbientSummaryAccumulator(
            sessionID: sessionID,
            sequenceAnchor: anchor
        )

        for index in 0...50 {
            let phase = 2 * Double.pi * Double(index) / 10
            accumulator.append(
                TaptionWatchSensorVector3(
                    x: 0.15 * sin(phase),
                    y: 0.04 * cos(phase),
                    z: 0.98
                ),
                capturedAt: anchor.addingTimeInterval(
                    120 + Double(index) * 0.08
                )
            )
        }
        for index in 0...37 {
            let phase = 2 * Double.pi * Double(index) / 8
            accumulator.append(
                TaptionWatchSensorVector3(
                    x: 0.22 * sin(phase),
                    y: 0.07 * cos(phase),
                    z: 0.95
                ),
                capturedAt: anchor.addingTimeInterval(
                    130 + Double(index) * 0.08
                )
            )
        }

        let summaries = accumulator.finish()
        XCTAssertEqual(summaries.count, 2)
        let first = try XCTUnwrap(summaries.first)
        let second = try XCTUnwrap(summaries.last)
        XCTAssertEqual(first.sessionID, sessionID)
        XCTAssertEqual(second.sessionID, sessionID)
        XCTAssertEqual(first.sequence, 120_000_001)
        XCTAssertEqual(second.sequence, 130_000_001)
        XCTAssertNotEqual(first.rawEventID, second.rawEventID)
        XCTAssertEqual(first.ambientWindowStart, anchor)
        XCTAssertEqual(second.ambientWindowStart, anchor)
        XCTAssertEqual(first.startedAt, anchor.addingTimeInterval(120))
        XCTAssertEqual(first.endedAt, anchor.addingTimeInterval(124))
        XCTAssertEqual(second.startedAt, anchor.addingTimeInterval(130))
        XCTAssertEqual(second.endedAt, anchor.addingTimeInterval(132.96))
        XCTAssertEqual(first.accelerometerSampleCount, 51)
        XCTAssertEqual(second.accelerometerSampleCount, 38)

        let firstSegments = try XCTUnwrap(first.behaviorSegments)
        let secondSegments = try XCTUnwrap(second.behaviorSegments)
        XCTAssertFalse(firstSegments.isEmpty)
        XCTAssertFalse(secondSegments.isEmpty)
        XCTAssertTrue(
            firstSegments.allSatisfy {
                $0.startedAt >= first.startedAt && $0.endedAt <= first.endedAt
            }
        )
        XCTAssertTrue(
            secondSegments.allSatisfy {
                $0.startedAt >= second.startedAt && $0.endedAt <= second.endedAt
            }
        )
        let firstPostGapWindowEnd = second.startedAt.addingTimeInterval(
            WatchBehaviorWindowAnalyzer.windowDuration
        )
        XCTAssertTrue(
            secondSegments.contains {
                abs($0.startedAt.timeIntervalSince(second.startedAt)) < 0.001
                    && abs($0.endedAt.timeIntervalSince(firstPostGapWindowEnd))
                        < 0.001
            }
        )
    }

    func testLegacyHighWaterOverlapIsRereadAndStableSampleIDsDeduplicateIt() throws {
        let armedAt = now.addingTimeInterval(-6 * 3_600)
        let highWater = now.addingTimeInterval(-3_600)
        let result = WatchSensorQueryPlan.windows(
            now: now,
            armedAt: armedAt,
            highWater: highWater
        )
        XCTAssertEqual(
            result.first?.start,
            highWater.addingTimeInterval(-WatchSensorQueryPlan.availabilityLag)
        )

        let overlapDate = highWater.addingTimeInterval(-60)
        let firstID = try XCTUnwrap(
            TaptionWatchStableID.ambientAccelerationSample(
                capturedAt: overlapDate
            )
        )
        let retryID = try XCTUnwrap(
            TaptionWatchStableID.ambientAccelerationSample(
                capturedAt: overlapDate
            )
        )
        XCTAssertEqual(firstID, retryID)

        var seen = Set<UUID>()
        XCTAssertFalse(
            TaptionWatchAmbientSampleDeduplicationPolicy.shouldProcess(
                retryID,
                committed: [firstID],
                seen: &seen
            )
        )
        let newID = try XCTUnwrap(
            TaptionWatchStableID.ambientAccelerationSample(
                capturedAt: highWater.addingTimeInterval(1)
            )
        )
        XCTAssertTrue(
            TaptionWatchAmbientSampleDeduplicationPolicy.shouldProcess(
                newID,
                committed: [firstID],
                seen: &seen
            )
        )
        XCTAssertFalse(
            TaptionWatchAmbientSampleDeduplicationPolicy.shouldProcess(
                newID,
                committed: [],
                seen: &seen
            )
        )
    }

    func testAmbientSampleDateLedgerRetainsOnlyTheRequeryOverlap() {
        let windowEnd = now
        let windowStart = windowEnd.addingTimeInterval(
            -WatchSensorQueryPlan.chunkSpan
        )
        let cutoff = windowEnd.addingTimeInterval(
            -(WatchSensorQueryPlan.availabilityLag + 60)
        )
        var sampleDates: [String: Date] = [:]
        for index in 0..<22_500 {
            sampleDates[String(index)] = windowStart.addingTimeInterval(
                Double(index) * 0.08
            )
        }
        sampleDates["overlap-boundary"] = cutoff

        let retained = TaptionWatchAmbientSampleDeduplicationPolicy
            .retainingSampleDates(sampleDates, from: cutoff)

        XCTAssertLessThanOrEqual(retained.count, 3_001)
        XCTAssertGreaterThan(retained.count, 2_500)
        XCTAssertTrue(retained.values.allSatisfy { $0 >= cutoff })
        XCTAssertEqual(retained["overlap-boundary"], cutoff)
    }

    func testAmbientSampleArchiveKeepsOneValuePerStableSampleID() throws {
        let capturedAt = Date(timeIntervalSince1970: 1_000_000)
        let stableID = try XCTUnwrap(
            TaptionWatchStableID.ambientAccelerationSample(capturedAt: capturedAt)
        )
        let priorSessionID = UUID()
        let currentSessionID = UUID()
        let first = TaptionWatchAccelerationSample(
            id: UUID(),
            capturedAt: capturedAt,
            acceleration: .init(x: 1, y: 2, z: 3),
            sessionID: priorSessionID,
            sequence: 1,
            isAmbient: true
        )
        let overlap = TaptionWatchAccelerationSample(
            id: UUID(),
            capturedAt: capturedAt,
            acceleration: .init(x: 9, y: 9, z: 9),
            sessionID: currentSessionID,
            sequence: 1,
            isAmbient: true
        )

        let unique = TaptionWatchAmbientSampleDeduplicationPolicy.uniqueSamples(
            [first, overlap]
        )
        XCTAssertEqual(unique.count, 1)
        XCTAssertEqual(unique.first?.id, stableID)
        XCTAssertEqual(unique.first?.acceleration, first.acceleration)

        var appendIndex = TaptionWatchAccelerationArchiveAppendIndex()
        appendIndex.trackAmbientSessions([currentSessionID])
        XCTAssertTrue(appendIndex.insert(first))
        XCTAssertFalse(appendIndex.insert(overlap))
    }

    func testAmbientAcknowledgementRetryPersistsAndBackoffCapsWithoutAttemptLimit() throws {
        let id = "summary:watch:segment"
        let readRetryID = TaptionWatchAmbientAcknowledgementRetryPolicy
            .outboxReadRetryID
        let encoded = try XCTUnwrap(
            TaptionWatchAmbientAcknowledgementRetryPolicy.encodedAttempts([
                id: 8,
                readRetryID: 2,
            ])
        )
        let restored = TaptionWatchAmbientAcknowledgementRetryPolicy
            .restoredAttempts(from: encoded)

        XCTAssertEqual(restored[id], 8)
        XCTAssertEqual(restored[readRetryID], 2)
        XCTAssertTrue(
            TaptionWatchAmbientAcknowledgementRetryPolicy.shouldRetry(
                retryCount: try XCTUnwrap(restored[id]),
                hasDeliveryID: true,
                sessionIsActivated: true,
                isPurging: false
            )
        )
        XCTAssertEqual(
            TaptionWatchAmbientAcknowledgementRetryPolicy.delay(retryCount: 3),
            40
        )
        XCTAssertEqual(
            TaptionWatchAmbientAcknowledgementRetryPolicy.delay(retryCount: 100),
            TaptionWatchAmbientAcknowledgementRetryPolicy.maximumDelay
        )
    }

    func testPendingAmbientOutboxItemsRemainRetryableUntilAcknowledged() {
        let summaryID = "summary:watch:segment"
        let chunkID = "chunk:watch:segment"
        let items = [
            TaptionPlanV3OutboxItem(
                id: summaryID,
                kind: TaptionWatchEnvelope.sensorSummaryKey,
                payload: Data()
            ),
            TaptionPlanV3OutboxItem(
                id: chunkID,
                kind: TaptionWatchEnvelope.accelerationChunkKey,
                payload: Data()
            ),
            TaptionPlanV3OutboxItem(
                id: "unrelated",
                kind: "other",
                payload: Data()
            ),
        ]

        XCTAssertEqual(
            TaptionWatchAmbientAcknowledgementRetryPolicy
                .pendingDeliveryIDs(from: items),
            [summaryID, chunkID]
        )
    }

    @MainActor
    func testAmbientAcknowledgementDeletionFailureSchedulesRetry() async {
        enum DatabaseFailure: Error { case delete }
        let deliveryID = "summary:watch:segment"
        var retryIDs: [String] = []

        let deleted = await TaptionWatchAmbientAcknowledgementRetryPolicy
            .deleteOutboxItem(
                id: deliveryID,
                delete: { throw DatabaseFailure.delete },
                onFailure: { id, _ in retryIDs.append(id) }
            )

        XCTAssertFalse(deleted)
        XCTAssertEqual(retryIDs, [deliveryID])
    }

    func testUnrelatedOutboxReadFailureRetainsTrackedAcknowledgementRetries() {
        let pending = Set(["summary:still-pending", "chunk:still-pending"])

        XCTAssertEqual(
            TaptionWatchAmbientOutboxReadFailurePolicy.retryIDs(
                requested: nil,
                alreadyTracked: pending
            ),
            pending
        )
        XCTAssertEqual(
            TaptionWatchAmbientOutboxReadFailurePolicy.retryIDs(
                requested: nil,
                alreadyTracked: []
            ),
            Set([
                TaptionWatchAmbientAcknowledgementRetryPolicy.outboxReadRetryID,
            ])
        )
    }

    func testAmbientOutboxFlushGenerationRejectsResultsAfterPurge() {
        XCTAssertTrue(
            TaptionWatchAmbientOutboxFlushPolicy.shouldContinue(
                startGeneration: 7,
                currentGeneration: 7,
                isPurging: false,
                isCancelled: false
            )
        )
        XCTAssertFalse(
            TaptionWatchAmbientOutboxFlushPolicy.shouldContinue(
                startGeneration: 7,
                currentGeneration: 8,
                isPurging: false,
                isCancelled: false
            )
        )
        XCTAssertFalse(
            TaptionWatchAmbientOutboxFlushPolicy.shouldContinue(
                startGeneration: 7,
                currentGeneration: 7,
                isPurging: true,
                isCancelled: false
            )
        )
        XCTAssertFalse(
            TaptionWatchAmbientOutboxFlushPolicy.shouldContinue(
                startGeneration: 7,
                currentGeneration: 7,
                isPurging: false,
                isCancelled: true
            )
        )
    }

    func testPurgeFailureThenOutboxReadFailureSchedulesGenericRetry() {
        let generation: UInt64 = 9
        XCTAssertFalse(
            TaptionWatchAmbientOutboxFlushPolicy.shouldContinue(
                startGeneration: generation,
                currentGeneration: generation,
                isPurging: true,
                isCancelled: false
            )
        )
        XCTAssertTrue(
            TaptionWatchAmbientOutboxFlushPolicy.shouldContinue(
                startGeneration: generation,
                currentGeneration: generation,
                isPurging: false,
                isCancelled: false
            )
        )

        let retryIDs = TaptionWatchAmbientOutboxReadFailurePolicy.retryIDs(
            requested: nil,
            alreadyTracked: []
        )
        let retryID = TaptionWatchAmbientAcknowledgementRetryPolicy
            .outboxReadRetryID
        XCTAssertEqual(retryIDs, [retryID])
        XCTAssertTrue(
            TaptionWatchAmbientAcknowledgementRetryPolicy.shouldRetry(
                retryCount: 0,
                hasDeliveryID: retryIDs.contains(retryID),
                sessionIsActivated: true,
                isPurging: false
            )
        )
    }

    func testFallbackSensorSpoolHasNoEvictionAndRemovesOnlyCommittedSnapshots() {
        var summaries: [TaptionWatchSensorSummary] = []
        for sequence in 1...41 {
            TaptionWatchDurableSpoolPolicy.enqueue(
                makeAmbientSummary(
                    sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                    sequence: sequence,
                    startedAt: now.addingTimeInterval(Double(sequence)),
                    windowStart: now
                ),
                into: &summaries
            )
        }
        XCTAssertEqual(summaries.count, 41)

        let failedAppendQueue = TaptionWatchDurableSpoolPolicy.removingCommitted(
            [],
            from: summaries
        )
        XCTAssertEqual(failedAppendQueue, summaries)
        let committedSummary = summaries[0]
        var newerSummary = committedSummary
        newerSummary.accelerometerSampleCount += 1
        XCTAssertEqual(
            TaptionWatchDurableSpoolPolicy.removingCommitted(
                [committedSummary],
                from: [newerSummary]
            ),
            [newerSummary]
        )
        summaries = TaptionWatchDurableSpoolPolicy.removingCommitted(
            [committedSummary],
            from: summaries
        )
        XCTAssertEqual(summaries.count, 40)

        var chunks: [TaptionWatchAccelerationChunk] = []
        for sequence in 1...121 {
            TaptionWatchDurableSpoolPolicy.enqueue(
                TaptionWatchAccelerationChunk(
                    sessionID: UUID(),
                    sequence: sequence,
                    startedAt: now.addingTimeInterval(Double(sequence)),
                    endedAt: now.addingTimeInterval(Double(sequence)),
                    samples: []
                ),
                into: &chunks
            )
        }
        XCTAssertEqual(chunks.count, 121)
        let committedChunk = chunks[0]
        chunks = TaptionWatchDurableSpoolPolicy.removingCommitted(
            [committedChunk],
            from: chunks
        )
        XCTAssertEqual(chunks.count, 120)
    }

    func testDurableSpoolCodecRestoresUnscheduledItemsAcrossRestart() throws {
        var summary = makeAmbientSummary(
            sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            sequence: 1,
            startedAt: now,
            windowStart: now
        )
        summary.isAmbient = false
        summary.ambientWindowStart = nil
        let chunk = TaptionWatchAccelerationChunk(
            sessionID: summary.sessionID,
            sequence: 1,
            startedAt: now,
            endedAt: now,
            samples: []
        )
        let health = TaptionWatchHealthSnapshot(
            capturedAt: now,
            dayStart: now,
            activeEnergyKilocalories: 20,
            exerciseMinutes: 12,
            standHours: 4,
            sleepMinutes: 360,
            sleepSegments: nil,
            workoutCount: 1,
            source: "watch"
        )

        let summaryData = try XCTUnwrap(
            TaptionWatchDurableSpoolCodec.encode([summary])
        )
        let chunkData = try XCTUnwrap(
            TaptionWatchDurableSpoolCodec.encode([chunk])
        )
        let healthData = try XCTUnwrap(
            TaptionWatchDurableSpoolCodec.encode([health])
        )
        var restoredSummaries = try XCTUnwrap(
            TaptionWatchDurableSpoolCodec.decode(
                [TaptionWatchSensorSummary].self,
                from: summaryData
            )
        )
        var restoredChunks = try XCTUnwrap(
            TaptionWatchDurableSpoolCodec.decode(
                [TaptionWatchAccelerationChunk].self,
                from: chunkData
            )
        )
        var restoredHealth = try XCTUnwrap(
            TaptionWatchDurableSpoolCodec.decode(
                [TaptionWatchHealthSnapshot].self,
                from: healthData
            )
        )

        XCTAssertTrue(TaptionWatchDurableSpoolPolicy.commitForTransfer(
            [summary],
            from: &restoredSummaries,
            isCancelled: false,
            isPurging: false
        ))
        XCTAssertTrue(TaptionWatchDurableSpoolPolicy.commitForTransfer(
            [],
            from: &restoredChunks,
            isCancelled: false,
            isPurging: false
        ))
        XCTAssertTrue(TaptionWatchDurableSpoolPolicy.commitForTransfer(
            [],
            from: &restoredHealth,
            isCancelled: false,
            isPurging: false
        ))
        XCTAssertTrue(restoredSummaries.isEmpty)
        XCTAssertEqual(restoredChunks, [chunk])
        XCTAssertEqual(restoredHealth, [health])

        XCTAssertEqual(
            TaptionWatchDurableSpoolCodec.decode(
                [TaptionWatchAccelerationChunk].self,
                from: TaptionWatchDurableSpoolCodec.encode(restoredChunks)
            ),
            [chunk]
        )
        XCTAssertEqual(
            TaptionWatchDurableSpoolCodec.decode(
                [TaptionWatchHealthSnapshot].self,
                from: TaptionWatchDurableSpoolCodec.encode(restoredHealth)
            ),
            [health]
        )
    }

    func testHealthSnapshotSpoolRemovesOnlyScheduledUnchangedSnapshots() {
        func snapshot(_ offset: TimeInterval) -> TaptionWatchHealthSnapshot {
            TaptionWatchHealthSnapshot(
                capturedAt: now.addingTimeInterval(offset),
                dayStart: now,
                activeEnergyKilocalories: 20,
                exerciseMinutes: 12,
                standHours: 4,
                sleepMinutes: 360,
                sleepSegments: nil,
                workoutCount: 1,
                source: "watch"
            )
        }

        let first = snapshot(0)
        let second = snapshot(60)
        var pending = [first, second]
        XCTAssertTrue(TaptionWatchDurableSpoolPolicy.commitForTransfer(
            [],
            from: &pending,
            isCancelled: false,
            isPurging: false
        ))
        XCTAssertEqual(pending, [first, second])

        var updated = first
        updated.activeEnergyKilocalories = 25
        TaptionWatchDurableSpoolPolicy.enqueue(updated, into: &pending)
        XCTAssertTrue(TaptionWatchDurableSpoolPolicy.commitForTransfer(
            [first, second],
            from: &pending,
            isCancelled: false,
            isPurging: false
        ))
        XCTAssertEqual(pending, [updated])

        XCTAssertFalse(TaptionWatchDurableSpoolPolicy.commitForTransfer(
            [updated],
            from: &pending,
            isCancelled: true,
            isPurging: false
        ))
        XCTAssertEqual(pending, [updated])
    }

    func testNoDatabaseDirectFlushDoesNotScheduleFallbackTwice() {
        var summary = makeAmbientSummary(
            sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            sequence: 1,
            startedAt: now,
            windowStart: now
        )
        summary.isAmbient = false
        summary.ambientWindowStart = nil
        let chunk = TaptionWatchAccelerationChunk(
            sessionID: summary.sessionID,
            sequence: 1,
            startedAt: now,
            endedAt: now,
            samples: []
        )
        var pendingSummaries = [summary]
        var pendingChunks = [chunk]
        var scheduledSummaryIDs: [String] = []
        var scheduledChunkIDs: [UUID] = []

        for _ in 0..<2 {
            let summariesToSchedule = pendingSummaries
            for item in summariesToSchedule {
                scheduledSummaryIDs.append(item.rawEventID)
                XCTAssertTrue(TaptionWatchDurableSpoolPolicy.commitForTransfer(
                    [item],
                    from: &pendingSummaries,
                    isCancelled: false,
                    isPurging: false
                ))
            }
            let chunksToSchedule = pendingChunks
            for item in chunksToSchedule {
                scheduledChunkIDs.append(item.id)
                XCTAssertTrue(TaptionWatchDurableSpoolPolicy.commitForTransfer(
                    [item],
                    from: &pendingChunks,
                    isCancelled: false,
                    isPurging: false
                ))
            }
        }

        XCTAssertEqual(scheduledSummaryIDs, [summary.rawEventID])
        XCTAssertEqual(scheduledChunkIDs, [chunk.id])
        XCTAssertTrue(pendingSummaries.isEmpty)
        XCTAssertTrue(pendingChunks.isEmpty)
    }

    @MainActor
    func testNonAmbientFlushRetriesAfterPurgeCancelsCommittedItemsAndDeleteFails() async {
        var summary = makeAmbientSummary(
            sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            sequence: 1,
            startedAt: now,
            windowStart: now
        )
        summary.isAmbient = false
        summary.ambientWindowStart = nil
        let chunk = TaptionWatchAccelerationChunk(
            sessionID: summary.sessionID,
            sequence: 1,
            startedAt: now,
            endedAt: now,
            samples: []
        )
        var pendingSummaries: [TaptionWatchSensorSummary] = []
        var pendingChunks: [TaptionWatchAccelerationChunk] = []
        TaptionWatchDurableSpoolPolicy.enqueue(summary, into: &pendingSummaries)
        TaptionWatchDurableSpoolPolicy.enqueue(chunk, into: &pendingChunks)
        let purgeState = PurgeState()
        var scheduledSummaryIDs: [String] = []
        var scheduledChunkIDs: [UUID] = []
        let database = PurgeInterleavingDatabase()

        let summaryFlush = Task { @MainActor in
            do { try await database.append() } catch { return }
            guard TaptionWatchDurableSpoolPolicy.commitForTransfer(
                [summary],
                from: &pendingSummaries,
                isCancelled: Task.isCancelled,
                isPurging: purgeState.isPurging
            ) else { return }
            scheduledSummaryIDs.append(summary.rawEventID)
        }
        let chunkFlush = Task { @MainActor in
            do { try await database.append() } catch { return }
            guard TaptionWatchDurableSpoolPolicy.commitForTransfer(
                [chunk],
                from: &pendingChunks,
                isCancelled: Task.isCancelled,
                isPurging: purgeState.isPurging
            ) else { return }
            scheduledChunkIDs.append(chunk.id)
        }

        await database.waitForPausedAppends(2)
        purgeState.isPurging = true
        summaryFlush.cancel()
        chunkFlush.cancel()
        await database.releasePausedAppends()
        await summaryFlush.value
        await chunkFlush.value
        let completedBeforeRetry = await database.completedAppends()
        XCTAssertEqual(completedBeforeRetry, 2)

        var purgeFailed = false
        do {
            try await database.deleteAll()
        } catch {
            purgeFailed = true
        }
        XCTAssertTrue(purgeFailed)
        purgeState.isPurging = false
        XCTAssertEqual(pendingSummaries, [summary])
        XCTAssertEqual(pendingChunks, [chunk])

        let summaryRetry = Task { @MainActor in
            do { try await database.append() } catch { return }
            guard TaptionWatchDurableSpoolPolicy.commitForTransfer(
                [summary],
                from: &pendingSummaries,
                isCancelled: Task.isCancelled,
                isPurging: purgeState.isPurging
            ) else { return }
            scheduledSummaryIDs.append(summary.rawEventID)
        }
        let chunkRetry = Task { @MainActor in
            do { try await database.append() } catch { return }
            guard TaptionWatchDurableSpoolPolicy.commitForTransfer(
                [chunk],
                from: &pendingChunks,
                isCancelled: Task.isCancelled,
                isPurging: purgeState.isPurging
            ) else { return }
            scheduledChunkIDs.append(chunk.id)
        }
        await summaryRetry.value
        await chunkRetry.value

        let completedAfterRetry = await database.completedAppends()
        XCTAssertEqual(completedAfterRetry, 4)
        XCTAssertEqual(pendingSummaries, [])
        XCTAssertEqual(pendingChunks, [])
        XCTAssertEqual(scheduledSummaryIDs, [summary.rawEventID])
        XCTAssertEqual(scheduledChunkIDs, [chunk.id])
    }

    private func makeAmbientSummary(
        sessionID: UUID,
        sequence: Int,
        startedAt: Date,
        windowStart: Date
    ) -> TaptionWatchSensorSummary {
        TaptionWatchSensorSummary(
            sessionID: sessionID,
            sequence: sequence,
            workoutKind: .walking,
            linkedPlanID: nil,
            linkedPlanTitle: nil,
            linkedCategoryID: nil,
            startedAt: startedAt,
            endedAt: startedAt,
            isFinal: false,
            accelerometerSampleCount: 1,
            accelerometerAverageG: nil,
            peakAccelerationG: nil,
            gyroscopeSampleCount: 0,
            gyroscopeAverageRadiansPerSecond: nil,
            peakRotationRateRadiansPerSecond: nil,
            gravity: nil,
            userAccelerationG: nil,
            rotationRateRadiansPerSecond: nil,
            attitudeRadians: nil,
            relativeAltitudeMeters: nil,
            pressureKilopascals: nil,
            stepCount: nil,
            distanceMeters: nil,
            floorsAscended: nil,
            floorsDescended: nil,
            latestHeartRate: nil,
            averageHeartRate: nil,
            maximumHeartRate: nil,
            activeEnergyKilocalories: nil,
            isAmbient: true,
            ambientWindowStart: windowStart
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

    func testLedgerRetriesAThrowingWindowWithoutLosingIt() {
        let start = now.addingTimeInterval(-3_600)
        let window = WatchSensorQueryWindow(
            start: start,
            end: start.addingTimeInterval(1_800)
        )
        var ledger = WatchSensorDrainLedger(highWater: start)
        ledger.failed(window)
        XCTAssertEqual(ledger.highWater, start)
        XCTAssertEqual(ledger.failureCount, 1)

        let next = WatchSensorQueryPlan.windows(
            now: now,
            armedAt: start,
            highWater: ledger.highWater
        )
        XCTAssertEqual(
            next.first?.start,
            start
        )
    }

    func testWindowsRecheckTheAvailabilityLagBeforeTheCommittedWatermark() {
        let armedAt = now.addingTimeInterval(-6 * 3_600)
        let highWater = now.addingTimeInterval(-60 * 60)
        let result = windows(armedAt: armedAt, highWater: highWater)

        XCTAssertEqual(
            result.first?.start,
            highWater.addingTimeInterval(-WatchSensorQueryPlan.availabilityLag)
        )
        XCTAssertEqual(
            result.last?.end,
            now.addingTimeInterval(-WatchSensorQueryPlan.availabilityLag)
        )
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

    func testLedgerStopsAfterTheFailureLimitWithoutAdvancing() {
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
        XCTAssertEqual(ledger.highWater, start)
    }

    func testExhaustedWindowStaysPendingForRetry() {
        let start = now.addingTimeInterval(-6 * 3_600)
        let window = WatchSensorQueryWindow(
            start: start,
            end: start.addingTimeInterval(1_800)
        )
        var ledger = WatchSensorDrainLedger(highWater: start)
        for _ in 0..<WatchSensorDrainLedger.defaultFailureLimit {
            ledger.failed(window)
        }

        XCTAssertTrue(ledger.isExhausted)
        XCTAssertEqual(ledger.highWater, start)
    }

    func testFailureKeepsWatermarkAtLastSuccessfulWindow() throws {
        let start = now.addingTimeInterval(-4 * 3_600)
        let plan = WatchSensorQueryPlan.windows(
            now: now,
            armedAt: start,
            highWater: nil
        )
        let first = try XCTUnwrap(plan.first)
        let second = try XCTUnwrap(plan.dropFirst().first)
        var ledger = WatchSensorDrainLedger(highWater: nil)
        ledger.succeeded(first)
        ledger.failed(second)

        XCTAssertEqual(ledger.highWater, first.end)
    }
}

final class WatchCommandCapabilityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let suiteName = "TaptionPlanTests.WatchCommandCapability.\(UUID().uuidString)"
    private lazy var defaults = UserDefaults(suiteName: suiteName)!

    override func setUp() {
        super.setUp()
        defaults.removePersistentDomain(
            forName: suiteName
        )
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func capability(
        commandID: UUID,
        planID: UUID,
        kind: TaptionWatchCommandKind = .start,
        expiresAt: Date? = nil
    ) -> TaptionWatchCommandCapability {
        TaptionWatchCommandCapability(
            commandID: commandID,
            token: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            planID: planID,
            kind: kind,
            expiresAt: expiresAt ?? now.addingTimeInterval(86_400)
        )
    }

    func testMissingOrMismatchedCommandCapabilityIsRejected() {
        let commandID = UUID()
        let planID = UUID()
        let capability = capability(commandID: commandID, planID: planID)
        XCTAssertFalse(
            capability.accepts(
                TaptionWatchCommand(
                    id: commandID,
                    planID: planID,
                    kind: .start,
                    requestedAt: now
                ),
                at: now
            )
        )
        XCTAssertFalse(
            capability.accepts(
                TaptionWatchCommand(
                    id: commandID,
                    planID: UUID(),
                    kind: .start,
                    requestedAt: now,
                    capabilityToken: capability.token
                ),
                at: now
            )
        )
        XCTAssertFalse(
            capability.accepts(
                TaptionWatchCommand(
                    id: commandID,
                    planID: planID,
                    kind: .complete,
                    requestedAt: now,
                    capabilityToken: capability.token
                ),
                at: now
            )
        )
    }

    func testCapabilityIsSingleUseByStore() {
        TaptionWatchCommandCapabilityStore.clear(defaults: defaults)
        let planID = UUID()
        let issued = TaptionWatchCommandCapabilityStore.reconcile(
            planIDs: [planID],
            now: now,
            defaults: defaults
        ).first { $0.planID == planID && $0.kind == .start }!
        let command = TaptionWatchCommand(
            id: issued.commandID,
            planID: planID,
            kind: .start,
            requestedAt: now,
            capabilityToken: issued.token
        )
        XCTAssertTrue(
            TaptionWatchCommandCapabilityStore.consume(
                command,
                at: now,
                defaults: defaults
            )
        )
        XCTAssertFalse(
            TaptionWatchCommandCapabilityStore.consume(
                command,
                at: now,
                defaults: defaults
            )
        )
        TaptionWatchCommandCapabilityStore.clear(defaults: defaults)
    }

    func testCapabilityIDsRemainStableAcrossPayloadRefresh() {
        let planID = UUID()
        let first = TaptionWatchCommandCapabilityStore.reconcile(
            planIDs: [planID], now: now, defaults: defaults
        )
        let second = TaptionWatchCommandCapabilityStore.reconcile(
            planIDs: [planID], now: now.addingTimeInterval(60), defaults: defaults
        )
        XCTAssertEqual(first, second)
    }

    func testGrantSurvivesMoreThanOneHundredOtherLiveGrants() {
        let firstPlan = UUID()
        let first = TaptionWatchCommandCapabilityStore.reconcile(
            planIDs: [firstPlan], now: now, defaults: defaults
        ).first { $0.planID == firstPlan && $0.kind == .start }!
        let otherPlans = Set((0..<21).map { _ in UUID() })
        _ = TaptionWatchCommandCapabilityStore.reconcile(
            planIDs: otherPlans.union([firstPlan]), now: now, defaults: defaults
        )
        let command = TaptionWatchCommand(
            id: first.commandID,
            planID: firstPlan,
            kind: .start,
            requestedAt: now,
            capabilityToken: first.token
        )
        XCTAssertTrue(
            TaptionWatchCommandCapabilityStore.consume(
                command, at: now, defaults: defaults
            )
        )
        let reloaded = UserDefaults(suiteName: suiteName)!
        _ = TaptionWatchCommandCapabilityStore.reconcile(
            planIDs: otherPlans.union([firstPlan]), now: now, defaults: reloaded
        )
        XCTAssertFalse(TaptionWatchCommandCapabilityStore.consume(
            command, at: now, defaults: reloaded
        ))
        let replacement = TaptionWatchCommandCapabilityStore.reconcile(
            planIDs: [firstPlan], now: now, defaults: reloaded
        ).first!
        _ = TaptionWatchCommandCapabilityStore.reconcile(
            planIDs: [], now: now, defaults: reloaded
        )
        XCTAssertFalse(TaptionWatchCommandCapabilityStore.consume(
            TaptionWatchCommand(id: replacement.commandID, planID: firstPlan,
                kind: replacement.kind, requestedAt: now,
                capabilityToken: replacement.token),
            at: now, defaults: reloaded
        ))
    }

    func testCapabilityRejectsWrongCommandIDAndToken() {
        let planID = UUID()
        let issued = TaptionWatchCommandCapabilityStore.reconcile(
            planIDs: [planID], now: now, defaults: defaults
        ).first { $0.planID == planID && $0.kind == .start }!
        XCTAssertFalse(
            issued.accepts(
                TaptionWatchCommand(
                    id: UUID(), planID: planID, kind: .start,
                    requestedAt: now, capabilityToken: issued.token
                ),
                at: now
            )
        )
        XCTAssertFalse(
            issued.accepts(
                TaptionWatchCommand(
                    id: issued.commandID, planID: planID, kind: .start,
                    requestedAt: now, capabilityToken: UUID()
                ),
                at: now
            )
        )
    }

    func testExpiredCapabilityIsRejected() {
        let commandID = UUID()
        let planID = UUID()
        let capability = capability(
            commandID: commandID,
            planID: planID,
            expiresAt: now.addingTimeInterval(-1)
        )
        let command = TaptionWatchCommand(
            id: commandID,
            planID: planID,
            kind: .start,
            requestedAt: now,
            capabilityToken: capability.token
        )
        XCTAssertFalse(capability.accepts(command, at: now))
    }
}

final class WatchDeletionPayloadTests: XCTestCase {
    private let cutoff = Date(timeIntervalSince1970: 1_800_000_000)

    func testCommandRejectsFutureClockButAllowsDelayedDelivery() {
        let planID = UUID()
        let future = TaptionWatchCommand(
            planID: planID,
            kind: .start,
            requestedAt: cutoff.addingTimeInterval(301)
        )
        let delayed = TaptionWatchCommand(
            planID: planID,
            kind: .complete,
            requestedAt: cutoff.addingTimeInterval(-86_400)
        )

        XCTAssertNil(future.retainingData(receivedAt: cutoff))
        XCTAssertEqual(delayed.retainingData(receivedAt: cutoff), delayed)
    }

    func testAccelerationChunkKeepsOnlyPostDeletionSamples() throws {
        let samples = [-1.0, 1.0, 2.0].enumerated().map { index, offset in
            TaptionWatchAccelerationSample(
                capturedAt: cutoff.addingTimeInterval(offset),
                acceleration: TaptionWatchSensorVector3(x: 0, y: 0, z: 1),
                sequence: index,
                isAmbient: true
            )
        }
        let chunk = TaptionWatchAccelerationChunk(
            sessionID: nil,
            sequence: 1,
            startedAt: cutoff.addingTimeInterval(-10),
            endedAt: cutoff.addingTimeInterval(3),
            samples: samples
        )

        let retained = try XCTUnwrap(chunk.retainingData(after: cutoff))

        XCTAssertEqual(retained.samples.count, 2)
        XCTAssertTrue(retained.samples.allSatisfy { $0.capturedAt > cutoff })
        XCTAssertEqual(retained.startedAt, cutoff)
    }

    func testSummaryRejectsCrossingDeletionAndFiltersOldRoutePoints() throws {
        var crossing = makeSummary(
            startedAt: cutoff.addingTimeInterval(-1),
            endedAt: cutoff.addingTimeInterval(30)
        )
        XCTAssertNil(crossing.retainingData(after: cutoff))

        crossing.startedAt = cutoff.addingTimeInterval(1)
        crossing.routePoints = [
            makeLocation(at: cutoff),
            makeLocation(at: cutoff.addingTimeInterval(2)),
        ]
        let retained = try XCTUnwrap(crossing.retainingData(after: cutoff))
        XCTAssertEqual(retained.routePoints?.map(\.capturedAt), [
            cutoff.addingTimeInterval(2),
        ])
    }

    func testConfirmationRejectsAnObservedSpanFromBeforeDeletion() {
        let crossing = TaptionWatchActivityConfirmation(
            respondedAt: cutoff.addingTimeInterval(30),
            observedStartedAt: cutoff.addingTimeInterval(-30),
            observedEndedAt: cutoff.addingTimeInterval(20),
            isCorrect: true,
            observedBehavior: .walking
        )
        let fresh = TaptionWatchActivityConfirmation(
            respondedAt: cutoff.addingTimeInterval(30),
            observedStartedAt: cutoff.addingTimeInterval(1),
            observedEndedAt: cutoff.addingTimeInterval(20),
            isCorrect: true,
            observedBehavior: .walking
        )

        XCTAssertNil(crossing.retainingData(after: cutoff))
        XCTAssertNotNil(fresh.retainingData(after: cutoff))
    }

    func testHealthSnapshotDropsPreDeletionDailyTotalsAndClipsSleep() throws {
        let snapshot = TaptionWatchHealthSnapshot(
            capturedAt: cutoff.addingTimeInterval(120),
            dayStart: cutoff.addingTimeInterval(-3_600),
            activeEnergyKilocalories: 500,
            exerciseMinutes: 30,
            standHours: 5,
            sleepMinutes: 60,
            sleepSegments: [
                TaptionWatchSleepSegment(
                    id: UUID(),
                    stage: "core",
                    startDate: cutoff.addingTimeInterval(-60),
                    endDate: cutoff.addingTimeInterval(60),
                    sourceName: "Watch",
                    sourceBundleIdentifier: "test",
                    deviceName: nil,
                    timeZoneIdentifier: nil,
                    isUserEntered: false
                ),
            ],
            workoutCount: 2,
            source: "Watch"
        )

        let retained = try XCTUnwrap(snapshot.retainingData(after: cutoff))

        XCTAssertEqual(retained.dayStart, cutoff)
        XCTAssertNil(retained.activeEnergyKilocalories)
        XCTAssertNil(retained.exerciseMinutes)
        XCTAssertNil(retained.standHours)
        XCTAssertEqual(retained.workoutCount, 0)
        XCTAssertEqual(retained.sleepSegments?.first?.startDate, cutoff)
        XCTAssertEqual(retained.sleepMinutes, 1)
    }

    func testHealthSnapshotUnionsOverlappingSleepSources() throws {
        let start = cutoff.addingTimeInterval(-2_100)
        let segments = [
            TaptionWatchSleepSegment(
                id: UUID(),
                stage: "asleepUnspecified",
                startDate: start,
                endDate: start.addingTimeInterval(1_800),
                sourceName: "iPhone",
                sourceBundleIdentifier: "phone",
                deviceName: nil,
                timeZoneIdentifier: nil,
                isUserEntered: false
            ),
            TaptionWatchSleepSegment(
                id: UUID(),
                stage: "deep",
                startDate: start.addingTimeInterval(600),
                endDate: start.addingTimeInterval(1_200),
                sourceName: "Watch",
                sourceBundleIdentifier: "watch",
                deviceName: nil,
                timeZoneIdentifier: nil,
                isUserEntered: false
            ),
            TaptionWatchSleepSegment(
                id: UUID(),
                stage: "core",
                startDate: start.addingTimeInterval(1_500),
                endDate: start.addingTimeInterval(2_100),
                sourceName: "Watch",
                sourceBundleIdentifier: "watch",
                deviceName: nil,
                timeZoneIdentifier: nil,
                isUserEntered: false
            ),
        ]
        var snapshot = TaptionWatchHealthSnapshot(
            capturedAt: cutoff,
            dayStart: cutoff.addingTimeInterval(-86_400),
            activeEnergyKilocalories: nil,
            exerciseMinutes: nil,
            standHours: nil,
            sleepMinutes: 65,
            sleepSegments: segments,
            workoutCount: 0,
            source: "Watch"
        )

        XCTAssertEqual(
            TaptionWatchSleepDuration.minutes(for: segments) ?? 0,
            35,
            accuracy: 0.001
        )
        snapshot.capturedAt = cutoff
        let retained = try XCTUnwrap(
            snapshot.retainingData(after: nil, receivedAt: cutoff)
        )
        XCTAssertEqual(
            try XCTUnwrap(retained.sleepMinutes),
            35,
            accuracy: 0.001
        )
    }

    func testHealthSnapshotSleepTotalUsesSegmentsBeyondPayloadLimit() throws {
        let maximum = TaptionWatchPayloadLimits.maximumSleepSegments
        let interval = 61.0
        let start = cutoff.addingTimeInterval(
            -Double(maximum + 1) * interval
        )
        let segments = (0...maximum).map { index in
            let segmentStart = start.addingTimeInterval(
                Double(index) * interval
            )
            return TaptionWatchSleepSegment(
                id: UUID(),
                stage: "core",
                startDate: segmentStart,
                endDate: segmentStart.addingTimeInterval(60),
                sourceName: "Watch",
                sourceBundleIdentifier: "test",
                deviceName: nil,
                timeZoneIdentifier: nil,
                isUserEntered: false
            )
        }
        let snapshot = TaptionWatchHealthSnapshot(
            capturedAt: cutoff,
            dayStart: start,
            activeEnergyKilocalories: nil,
            exerciseMinutes: nil,
            standHours: nil,
            sleepMinutes: nil,
            sleepSegments: segments,
            workoutCount: 0,
            source: "Watch"
        )
        var atLimit = snapshot
        atLimit.sleepSegments = Array(segments.prefix(maximum))

        let retainedAtLimit = try XCTUnwrap(
            atLimit.retainingData(after: nil, receivedAt: cutoff)
        )
        let retained = try XCTUnwrap(
            snapshot.retainingData(after: nil, receivedAt: cutoff)
        )

        XCTAssertEqual(retainedAtLimit.sleepSegments?.count, maximum)
        XCTAssertEqual(
            try XCTUnwrap(retainedAtLimit.sleepMinutes),
            Double(maximum),
            accuracy: 0.001
        )
        XCTAssertEqual(retained.sleepSegments?.count, maximum)
        XCTAssertEqual(
            try XCTUnwrap(retained.sleepMinutes),
            Double(maximum + 1),
            accuracy: 0.001
        )
    }

    func testHealthSnapshotDropsLegacyPreDeletionSleepTotal() throws {
        let snapshot = TaptionWatchHealthSnapshot(
            capturedAt: cutoff.addingTimeInterval(120),
            dayStart: cutoff.addingTimeInterval(60),
            activeEnergyKilocalories: nil,
            exerciseMinutes: nil,
            standHours: nil,
            sleepMinutes: 60,
            sleepSegments: nil,
            workoutCount: 0,
            source: "Watch"
        )

        let retained = try XCTUnwrap(snapshot.retainingData(after: cutoff))

        XCTAssertNil(retained.sleepMinutes)
    }

    func testMotionPayloadsRejectFutureClocksAndFilterNestedTimestamps() throws {
        var chunk = TaptionWatchAccelerationChunk(
            sessionID: nil,
            sequence: 1,
            startedAt: cutoff,
            endedAt: cutoff.addingTimeInterval(10),
            samples: [
                TaptionWatchAccelerationSample(
                    capturedAt: cutoff.addingTimeInterval(1),
                    acceleration: TaptionWatchSensorVector3(x: 0, y: 0, z: 1),
                    sequence: 1,
                    isAmbient: true
                ),
                TaptionWatchAccelerationSample(
                    capturedAt: cutoff.addingTimeInterval(301),
                    acceleration: TaptionWatchSensorVector3(x: 0, y: 0, z: 1),
                    sequence: 2,
                    isAmbient: true
                ),
            ]
        )
        let retainedChunk = try XCTUnwrap(
            chunk.retainingData(after: nil, receivedAt: cutoff)
        )
        XCTAssertEqual(retainedChunk.samples.map(\.sequence), [1])

        chunk.endedAt = cutoff.addingTimeInterval(301)
        XCTAssertNil(chunk.retainingData(after: nil, receivedAt: cutoff))

        var summary = makeSummary(
            startedAt: cutoff,
            endedAt: cutoff.addingTimeInterval(10)
        )
        summary.routePoints = [
            makeLocation(at: cutoff.addingTimeInterval(1)),
            makeLocation(at: cutoff.addingTimeInterval(301)),
        ]
        summary.behaviorSegments = [
            WatchBehaviorSegment(
                startedAt: cutoff,
                endedAt: cutoff.addingTimeInterval(1),
                behavior: .walking,
                confidenceScore: 1,
                evidence: [],
                modelVersion: "test"
            ),
            WatchBehaviorSegment(
                startedAt: cutoff.addingTimeInterval(301),
                endedAt: cutoff.addingTimeInterval(302),
                behavior: .walking,
                confidenceScore: 1,
                evidence: [],
                modelVersion: "test"
            ),
        ]
        let retainedSummary = try XCTUnwrap(
            summary.retainingData(after: nil, receivedAt: cutoff)
        )
        XCTAssertEqual(retainedSummary.routePoints?.count, 1)
        XCTAssertEqual(retainedSummary.behaviorSegments?.count, 1)

        summary.endedAt = cutoff.addingTimeInterval(301)
        XCTAssertNil(summary.retainingData(after: nil, receivedAt: cutoff))
    }

    func testConfirmationRejectsFutureClock() {
        let confirmation = TaptionWatchActivityConfirmation(
            respondedAt: cutoff.addingTimeInterval(301),
            observedStartedAt: cutoff,
            observedEndedAt: cutoff.addingTimeInterval(1),
            isCorrect: true,
            observedBehavior: .walking
        )

        XCTAssertNil(
            confirmation.retainingData(after: nil, receivedAt: cutoff)
        )
    }

    func testHealthSnapshotRejectsFutureCaptureAndDropsFutureSleep() throws {
        let futureSegment = TaptionWatchSleepSegment(
            id: UUID(),
            stage: "core",
            startDate: cutoff.addingTimeInterval(600),
            endDate: cutoff.addingTimeInterval(900),
            sourceName: "Watch",
            sourceBundleIdentifier: "test",
            deviceName: nil,
            timeZoneIdentifier: nil,
            isUserEntered: false
        )
        let crossingSegment = TaptionWatchSleepSegment(
            id: UUID(),
            stage: "core",
            startDate: cutoff.addingTimeInterval(290),
            endDate: cutoff.addingTimeInterval(310),
            sourceName: "Watch",
            sourceBundleIdentifier: "test",
            deviceName: nil,
            timeZoneIdentifier: nil,
            isUserEntered: false
        )
        var snapshot = TaptionWatchHealthSnapshot(
            capturedAt: cutoff.addingTimeInterval(301),
            dayStart: cutoff.addingTimeInterval(-3_600),
            activeEnergyKilocalories: nil,
            exerciseMinutes: nil,
            standHours: nil,
            sleepMinutes: 5,
            sleepSegments: [futureSegment, crossingSegment],
            workoutCount: 0,
            source: "Watch"
        )

        XCTAssertNil(snapshot.retainingData(after: nil, receivedAt: cutoff))

        snapshot.capturedAt = cutoff
        let retained = try XCTUnwrap(
            snapshot.retainingData(after: nil, receivedAt: cutoff)
        )
        XCTAssertEqual(retained.sleepSegments?.count, 1)
        XCTAssertEqual(
            retained.sleepSegments?.first?.endDate,
            cutoff.addingTimeInterval(300)
        )
        XCTAssertEqual(
            try XCTUnwrap(retained.sleepMinutes),
            10.0 / 60.0,
            accuracy: 0.001
        )
    }

    func testCompletedPurgeGenerationRejectsReplay() {
        XCTAssertTrue(
            TaptionWatchPurgeGenerationPolicy.shouldExecute(
                requested: 11,
                completed: 10
            )
        )
        XCTAssertFalse(
            TaptionWatchPurgeGenerationPolicy.shouldExecute(
                requested: 10,
                completed: 10
            )
        )
        XCTAssertFalse(
            TaptionWatchPurgeGenerationPolicy.shouldExecute(
                requested: 9,
                completed: 10
            )
        )
    }

    func testDatabasePurgeFailurePreservesManagerStores() async {
        enum Failure: Error { case purge }
        var managerStoresDeleted = false

        do {
            try await TaptionWatchPurgeSequence.run(
                deleteDatabase: { throw Failure.purge },
                deleteManagerStores: { managerStoresDeleted = true }
            )
            XCTFail("Manager stores must remain when database purge fails")
        } catch {
            XCTAssertFalse(managerStoresDeleted)
        }
    }

    func testWatchSummaryFallbackReadingIDIsStablePerSequence() {
        var summary = makeSummary(startedAt: .now, endedAt: .now)
        let first = summary.fallbackReadingID

        XCTAssertEqual(first, summary.fallbackReadingID)
        summary.sequence += 1
        XCTAssertNotEqual(first, summary.fallbackReadingID)
    }

    private func makeSummary(
        startedAt: Date,
        endedAt: Date
    ) -> TaptionWatchSensorSummary {
        TaptionWatchSensorSummary(
            sessionID: UUID(),
            sequence: 1,
            workoutKind: .walking,
            linkedPlanID: nil,
            linkedPlanTitle: nil,
            linkedCategoryID: nil,
            startedAt: startedAt,
            endedAt: endedAt,
            isFinal: false,
            accelerometerSampleCount: 1,
            accelerometerAverageG: nil,
            peakAccelerationG: nil,
            gyroscopeSampleCount: 0,
            gyroscopeAverageRadiansPerSecond: nil,
            peakRotationRateRadiansPerSecond: nil,
            gravity: nil,
            userAccelerationG: nil,
            rotationRateRadiansPerSecond: nil,
            attitudeRadians: nil,
            relativeAltitudeMeters: nil,
            pressureKilopascals: nil,
            stepCount: nil,
            distanceMeters: nil,
            floorsAscended: nil,
            floorsDescended: nil,
            latestHeartRate: nil,
            averageHeartRate: nil,
            maximumHeartRate: nil,
            activeEnergyKilocalories: nil
        )
    }

    private func makeLocation(at date: Date) -> TaptionWatchLocationPoint {
        TaptionWatchLocationPoint(
            id: UUID(),
            capturedAt: date,
            latitude: 37.5,
            longitude: 127,
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            speedMetersPerSecond: nil,
            courseDegrees: nil
        )
    }
}

final class WatchWorkoutStartGateTests: XCTestCase {
    @MainActor
    func testLockedFinishWithoutSampleKeepsPurgeIntentUntilDeletionIsConfirmed() async throws {
        let suite = "WatchWorkoutPurgeIntentTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let identifier = UUID()
        let outcome = TaptionWatchWorkoutFinishState.successfulFinish(
            sampleAvailable: false
        )
        XCTAssertEqual(outcome, .savedWithoutSample)
        XCTAssertTrue(outcome.mayHavePersistedWorkout)
        XCTAssertTrue(TaptionWatchWorkoutFinishState.finishing.mayHavePersistedWorkout)
        XCTAssertTrue(
            TaptionWatchWorkoutFinishState.failedMayHavePersisted
                .mayHavePersistedWorkout
        )

        TaptionWatchWorkoutPurgeIntentStore.enqueue(identifier, defaults: defaults)
        XCTAssertEqual(
            TaptionWatchWorkoutPurgeIntentStore.pendingIdentifiers(
                defaults: try XCTUnwrap(UserDefaults(suiteName: suite))
            ),
            [identifier]
        )

        do {
            try await TaptionWatchWorkoutPurgeReconciliation.run(
                identifiers: TaptionWatchWorkoutPurgeIntentStore.pendingIdentifiers(
                    defaults: defaults
                ),
                deleteMatchingWorkout: { _ in 0 },
                matchingWorkoutExists: { _ in true },
                confirmDeletion: {
                    TaptionWatchWorkoutPurgeIntentStore.remove(
                        $0,
                        defaults: defaults
                    )
                }
            )
            XCTFail("A locked workout without deletion confirmation must stay pending")
        } catch {
            XCTAssertEqual(
                TaptionWatchWorkoutPurgeIntentStore.pendingIdentifiers(
                    defaults: defaults
                ),
                [identifier]
            )
        }

        try await TaptionWatchWorkoutPurgeReconciliation.run(
            identifiers: TaptionWatchWorkoutPurgeIntentStore.pendingIdentifiers(
                defaults: defaults
            ),
            deleteMatchingWorkout: { _ in 0 },
            matchingWorkoutExists: { _ in false },
            confirmDeletion: {
                TaptionWatchWorkoutPurgeIntentStore.remove(
                    $0,
                    defaults: defaults
                )
            }
        )
        XCTAssertTrue(
            TaptionWatchWorkoutPurgeIntentStore.pendingIdentifiers(
                defaults: defaults
            ).isEmpty
        )

        let deletedIdentifier = UUID()
        TaptionWatchWorkoutPurgeIntentStore.enqueue(
            deletedIdentifier,
            defaults: defaults
        )
        try await TaptionWatchWorkoutPurgeReconciliation.run(
            identifiers: [deletedIdentifier],
            deleteMatchingWorkout: { _ in 1 },
            matchingWorkoutExists: { _ in
                XCTFail("A positive delete count already confirms removal")
                return true
            },
            confirmDeletion: {
                TaptionWatchWorkoutPurgeIntentStore.remove(
                    $0,
                    defaults: defaults
                )
            }
        )
        XCTAssertTrue(
            TaptionWatchWorkoutPurgeIntentStore.pendingIdentifiers(
                defaults: defaults
            ).isEmpty
        )
    }

    func testResetInvalidatesPendingStartAndBlocksStartsUntilComplete() throws {
        var gate = TaptionWatchWorkoutStartGate()
        let pendingStart = try XCTUnwrap(gate.beginStart())
        let reset = try XCTUnwrap(gate.beginReset())

        XCTAssertFalse(gate.accepts(pendingStart))
        XCTAssertNil(gate.beginStart())
        XCTAssertTrue(gate.accepts(reset))

        XCTAssertTrue(gate.finishReset(reset))
        XCTAssertNotNil(try XCTUnwrap(gate.beginStart()))
    }

    func testPurgeDuringResetPreventsStaleResetFromResumingAmbientRecording() throws {
        var gate = TaptionWatchWorkoutStartGate()
        let reset = try XCTUnwrap(gate.beginReset())
        let purgeID = gate.beginPurge()

        XCTAssertFalse(gate.accepts(reset))
        XCTAssertFalse(gate.allowsAmbientRecording)
        gate.endPurge(purgeID)

        XCTAssertFalse(gate.finishReset(reset))
        XCTAssertTrue(gate.allowsAmbientRecording)
    }

    func testConcurrentResetIsRejectedUntilCurrentResetFinishes() throws {
        var gate = TaptionWatchWorkoutStartGate()
        let reset = try XCTUnwrap(gate.beginReset())

        XCTAssertNil(gate.beginReset())
        XCTAssertNil(gate.beginStart())

        XCTAssertTrue(gate.finishReset(reset))
        XCTAssertNotNil(try XCTUnwrap(gate.beginStart()))
    }

    func testPurgeInvalidatesPendingStartAndBlocksNewStartUntilComplete() throws {
        var gate = TaptionWatchWorkoutStartGate()
        let pendingStart = try XCTUnwrap(gate.beginStart())
        let purgeID = gate.beginPurge()

        XCTAssertTrue(gate.isPurging)
        XCTAssertFalse(gate.accepts(pendingStart))
        XCTAssertNil(gate.beginStart())

        gate.endPurge(purgeID)
        XCTAssertFalse(gate.isPurging)
        let nextStart = try XCTUnwrap(gate.beginStart())
        XCTAssertGreaterThan(nextStart, pendingStart)
        XCTAssertFalse(gate.accepts(pendingStart))
        XCTAssertTrue(gate.accepts(nextStart))
    }

    func testPurgeInvalidatesManualSyncWaitingForAmbientDrain() throws {
        var gate = TaptionWatchWorkoutStartGate()
        let syncGeneration = try XCTUnwrap(gate.beginHealthSync())
        let purgeID = gate.beginPurge()

        XCTAssertFalse(gate.accepts(syncGeneration))
        XCTAssertNil(gate.beginHealthSync())
        gate.endPurge(purgeID)
        XCTAssertFalse(gate.accepts(syncGeneration))
        XCTAssertNotNil(gate.beginHealthSync())
    }

    func testConcurrentPurgesKeepStartsBlockedUntilBothFinish() throws {
        var gate = TaptionWatchWorkoutStartGate()
        let firstPurge = gate.beginPurge()
        let secondPurge = gate.beginPurge()

        gate.endPurge(secondPurge)
        XCTAssertNil(gate.beginStart())

        gate.endPurge(firstPurge)
        XCTAssertNotNil(try XCTUnwrap(gate.beginStart()))
    }

    func testCommerceLockDuringAuthorizationWaitRejectsPendingStart() throws {
        var gate = TaptionWatchWorkoutStartGate()
        let pendingStart = try XCTUnwrap(gate.beginStart())

        gate.setCommerceLocked(true)
        XCTAssertFalse(gate.accepts(pendingStart))
        XCTAssertNil(gate.beginStart())

        gate.setCommerceLocked(false)
        let unlockedStart = try XCTUnwrap(gate.beginStart())
        XCTAssertGreaterThan(unlockedStart, pendingStart)
        XCTAssertFalse(gate.accepts(pendingStart))
        XCTAssertTrue(gate.accepts(unlockedStart))
    }

    func testCommerceLockDuringResetDoesNotCancelWorkoutTeardown() throws {
        var gate = TaptionWatchWorkoutStartGate()
        let reset = try XCTUnwrap(gate.beginReset())

        gate.setCommerceLocked(true)
        XCTAssertTrue(gate.accepts(reset))
        gate.setCommerceLocked(false)
        XCTAssertTrue(gate.accepts(reset))
        XCTAssertTrue(gate.finishReset(reset))
        XCTAssertNotNil(gate.beginStart())
    }

    @MainActor
    func testLifecycleBarrierWaitsForAllActiveOperations() async {
        let barrier = TaptionWatchWorkoutLifecycleBarrier()
        barrier.beginOperation()
        barrier.beginOperation()
        var resumed = false
        let waiter = Task {
            await barrier.waitUntilIdle()
            resumed = true
        }
        await Task.yield()

        XCTAssertFalse(resumed)
        barrier.finishOperation()
        await Task.yield()
        XCTAssertFalse(resumed)

        barrier.finishOperation()
        await waiter.value
        XCTAssertTrue(resumed)
    }
}

final class WatchWorkoutDataIsolationTests: XCTestCase {
    func testDelayedLocationFromPreviousWorkoutIsExcluded() {
        let workoutBStartedAt = Date(timeIntervalSince1970: 100)
        let pointFromA = locationPoint(at: workoutBStartedAt.addingTimeInterval(-1))
        let pointFromB = locationPoint(at: workoutBStartedAt)

        XCTAssertFalse(pointFromA.belongs(toWorkoutStartingAt: workoutBStartedAt))
        XCTAssertTrue(pointFromB.belongs(toWorkoutStartingAt: workoutBStartedAt))
    }

    func testAmbientArchiveAppendIndexRejectsRepeatedDrainSequences() {
        let firstSession = UUID()
        let secondSession = UUID()
        var index = TaptionWatchAccelerationArchiveAppendIndex()

        let first = archiveSample(sessionID: firstSession, sequence: 1)
        index.trackAmbientSessions([firstSession])
        XCTAssertTrue(index.insert(first))
        XCTAssertFalse(index.insert(first))
        XCTAssertTrue(index.insert(archiveSample(sessionID: firstSession, sequence: 2)))
        XCTAssertFalse(index.insert(first))
        XCTAssertTrue(index.insert(archiveSample(sessionID: secondSession, sequence: 1)))
        XCTAssertTrue(index.insert(archiveSample(sessionID: firstSession, sequence: 4)))
        XCTAssertTrue(index.insert(archiveSample(sessionID: firstSession, sequence: 3)))
        XCTAssertFalse(index.insert(archiveSample(sessionID: firstSession, sequence: 3)))
        XCTAssertTrue(index.insert(archiveSample(
            sessionID: secondSession,
            sequence: 10,
            isAmbient: false
        )))
        XCTAssertFalse(index.insert(archiveSample(
            sessionID: secondSession,
            sequence: 9,
            isAmbient: false
        )))

        let unscopedID = UUID()
        let unscoped = TaptionWatchAccelerationSample(
            id: unscopedID,
            capturedAt: Date(timeIntervalSince1970: 1),
            acceleration: .init(x: 0, y: 0, z: 0),
            sequence: 1,
            isAmbient: true
        )
        XCTAssertTrue(index.insert(unscoped))
        XCTAssertFalse(index.insert(unscoped))
    }

    private func locationPoint(at date: Date) -> TaptionWatchLocationPoint {
        TaptionWatchLocationPoint(
            id: UUID(),
            capturedAt: date,
            latitude: 37.5,
            longitude: 127,
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            speedMetersPerSecond: nil,
            courseDegrees: nil
        )
    }

    private func archiveSample(
        sessionID: UUID,
        sequence: Int,
        isAmbient: Bool = true
    ) -> TaptionWatchAccelerationSample {
        TaptionWatchAccelerationSample(
            id: TaptionWatchStableID.ambientAccelerationSample(
                sessionID: sessionID,
                sequence: sequence
            ),
            capturedAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
            acceleration: .init(x: 0, y: 0, z: 0),
            sessionID: sessionID,
            sequence: sequence,
            isAmbient: isAmbient
        )
    }
}

/// 시뮬레이터에는 페어링된 워치가 없어 `WCSession`으로는 세 상태를 만들 수
/// 없다. 상태 판단을 값 계산으로 떼어 두었으므로 여기서 그대로 확인한다.
final class AppleWatchOnboardingTests: XCTestCase {
    private func prompt(
        _ state: AppleWatchConnectionState,
        dismissed: Set<AppleWatchOnboardingPrompt> = [],
        hasSeenWatchAppInstalled: Bool = false
    ) -> AppleWatchOnboardingPrompt? {
        AppleWatchOnboarding.prompt(
            for: state,
            dismissed: dismissed,
            hasSeenWatchAppInstalled: hasSeenWatchAppInstalled
        )
    }

    private func store() -> (AppleWatchOnboardingStore, UserDefaults) {
        let name = "AppleWatchOnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (AppleWatchOnboardingStore(defaults: defaults), defaults)
    }

    func testPairedWatchWithoutAppInvitesInstall() {
        XCTAssertEqual(prompt(.appNotInstalled), .installInvitation)
    }

    func testNoPairedWatchExplainsLimitations() {
        XCTAssertEqual(prompt(.notPaired), .watchlessLimitations)
    }

    func testInstalledWatchAppShowsNeither() {
        XCTAssertNil(prompt(.background))
        XCTAssertNil(prompt(.reachable))
    }

    /// iPad이거나 세션이 아직 활성화되기 전이다. 워치가 없다고 단정하면
    /// 거짓말이 되므로 아무것도 보여 주지 않는다.
    func testUnsupportedSessionSaysNothing() {
        XCTAssertNil(prompt(.unsupported))
    }

    func testDismissalSuppressesTheSamePromptForever() {
        XCTAssertNil(
            prompt(.notPaired, dismissed: [.watchlessLimitations])
        )
        XCTAssertNil(
            prompt(.appNotInstalled, dismissed: [.installInvitation])
        )
    }

    /// 워치가 없다는 안내를 닫은 뒤 다음 주에 워치를 사면, 설치 권유는
    /// 새 이야기이므로 한 번 뜬다.
    func testPairingAfterDismissingWatchlessNoticeInvitesInstall() {
        XCTAssertEqual(
            prompt(.appNotInstalled, dismissed: [.watchlessLimitations]),
            .installInvitation
        )
    }

    /// 설치를 확인한 뒤 사용자가 워치 앱을 지운 경우다. 스스로 지운 것을
    /// 다시 권하면 잔소리가 된다.
    func testInstallIsNeverInvitedAgainOnceSeenInstalled() {
        XCTAssertNil(
            prompt(.appNotInstalled, hasSeenWatchAppInstalled: true)
        )
    }

    func testDismissalPersistsAcrossStoreInstances() {
        let (store, defaults) = store()
        XCTAssertTrue(store.dismissed.isEmpty)
        store.dismiss(.watchlessLimitations)

        let reopened = AppleWatchOnboardingStore(defaults: defaults)
        XCTAssertEqual(reopened.dismissed, [.watchlessLimitations])
        XCTAssertFalse(reopened.hasSeenWatchAppInstalled)
        XCTAssertNil(
            prompt(.notPaired, dismissed: reopened.dismissed)
        )
    }

    func testInstalledMarkPersistsAcrossStoreInstances() {
        let (store, defaults) = store()
        store.markWatchAppInstalled()

        let reopened = AppleWatchOnboardingStore(defaults: defaults)
        XCTAssertTrue(reopened.hasSeenWatchAppInstalled)
    }

    func testPairedWatchNeedsDataWithinFifteenMinutes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recent = now.addingTimeInterval(-14 * 60)
        let stale = now.addingTimeInterval(-16 * 60)

        XCTAssertEqual(
            AppleWatchConnectionPolicy.state(
                isSupported: true,
                isPaired: true,
                isWatchAppInstalled: true,
                isReachable: false,
                lastContactAt: recent,
                now: now
            ),
            .background
        )
        XCTAssertEqual(
            AppleWatchConnectionPolicy.state(
                isSupported: true,
                isPaired: true,
                isWatchAppInstalled: true,
                isReachable: false,
                lastContactAt: stale,
                now: now
            ),
            .noRecentData
        )
        XCTAssertEqual(
            AppleWatchConnectionPolicy.recentContactWindow,
            15 * 60
        )
    }

    /// 설정 줄은 사라지지 않고 문구만 바뀐다. 설치되지 않았을 때만 찾아가는
    /// 길을 덧붙이고, 이미 설치된 사람에게 설치를 권하지 않는다.
    func testCompanionRowHasOneWordingPerState() {
        let watchless = AppleWatchOnboarding.companionRow(for: .notPaired)
        let notInstalled = AppleWatchOnboarding.companionRow(for: .appNotInstalled)
        let installed = AppleWatchOnboarding.companionRow(for: .reachable)

        XCTAssertEqual(watchless.value, "안내")
        XCTAssertEqual(notInstalled.value, "설치 필요")
        XCTAssertEqual(installed.value, "설치됨")

        XCTAssertEqual(
            notInstalled.detail,
            AppleWatchOnboarding.installInstruction
        )
        XCTAssertNil(installed.detail)
        XCTAssertEqual(
            watchless.detail?.contains(AppleWatchOnboarding.iPhoneOnlyCoverage),
            true
        )

        // iPad처럼 확인할 수 없는 기기에서도 워치 앱이 있다는 사실은 알린다.
        XCTAssertEqual(
            AppleWatchOnboarding.companionRow(for: .unsupported),
            watchless
        )

        XCTAssertEqual(
            Set([watchless.subtitle, notInstalled.subtitle, installed.subtitle])
                .count,
            3
        )
    }

    /// 아이폰이 이미 하는 일을 없다고 적으면 거짓말이 된다. 목록에 아이폰
    /// 단독으로도 남는 기록이 섞이지 않았는지 지킨다.
    func testWatchlessLimitationsDoNotClaimIPhoneOnlyFeaturesAreLost() {
        let text = AppleWatchOnboarding.watchlessLimitations.joined(
            separator: "\n"
        )
        for covered in ["장소", "날씨", "앱 사용시간", "사진", "캘린더", "층수"] {
            XCTAssertFalse(
                text.contains(covered),
                "iPhone만으로 되는 \(covered)을(를) 제한으로 적었다"
            )
        }
        XCTAssertFalse(AppleWatchOnboarding.watchlessLimitations.isEmpty)
    }
}

final class AppleWatchDataReceiptStoreTests: XCTestCase {
    private func store() -> (AppleWatchDataReceiptStore, UserDefaults) {
        let name = "AppleWatchDataReceiptStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (AppleWatchDataReceiptStore(defaults: defaults), defaults)
    }

    func testRecentKindsUseEachPayloadReceiptDateAndSurviveReload() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let (store, defaults) = store()
        store.record(
            [.motion, .heartRate],
            measuredAt: now.addingTimeInterval(-14 * 60),
            receivedAt: now.addingTimeInterval(-2 * 60)
        )
        store.record(
            [.route],
            measuredAt: now.addingTimeInterval(-16 * 60),
            receivedAt: now.addingTimeInterval(-20 * 60)
        )

        let reloaded = AppleWatchDataReceiptStore(defaults: defaults).load()
        XCTAssertEqual(reloaded.recentKinds(at: now), [.motion, .heartRate])
        XCTAssertEqual(
            reloaded.latestDataAt,
            now.addingTimeInterval(-2 * 60)
        )
    }

    func testDelayedPayloadIsRecentWhenItWasJustReceived() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let (store, _) = store()
        let receipt = store.record(
            [.health],
            measuredAt: now.addingTimeInterval(-3_600),
            receivedAt: now
        )

        XCTAssertEqual(receipt.recentKinds(at: now), [.health])
        XCTAssertEqual(receipt.latestDataAt, now)
    }

    func testEmptyHealthResponseStillRecordsItsReceiptTime() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let (store, _) = store()
        let receipt = store.record(
            [.health],
            measuredAt: now,
            receivedAt: now
        )

        XCTAssertEqual(receipt.recentKinds(at: now), [.health])
        XCTAssertEqual(receipt.latestDataAt, now)
    }

    func testFutureAndOutOfOrderPayloadsCannotMoveDataTimeForwardOrBackward() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let (store, _) = store()
        store.record(
            [.activity],
            measuredAt: now.addingTimeInterval(3_600),
            receivedAt: now
        )
        let receipt = store.record(
            [.activity],
            measuredAt: now.addingTimeInterval(-3_600),
            receivedAt: now
        )

        XCTAssertEqual(receipt.latestDataAt, now)
        XCTAssertEqual(receipt.recentKinds(at: now), [.activity])
    }

    func testSyncReceiptRequiresMatchingRequestOrFreshLegacyMeasurement() {
        let requestedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let receivedAt = requestedAt.addingTimeInterval(5)

        XCTAssertFalse(
            AppleWatchDataSyncReceiptPolicy.satisfiesPendingRequest(
                requestedAt: requestedAt,
                expectedRequestID: "current",
                receivedRequestID: "older",
                measuredAt: requestedAt.addingTimeInterval(-60),
                receivedAt: receivedAt
            )
        )
        XCTAssertFalse(
            AppleWatchDataSyncReceiptPolicy.satisfiesPendingRequest(
                requestedAt: requestedAt,
                expectedRequestID: "current",
                receivedRequestID: nil,
                measuredAt: requestedAt.addingTimeInterval(-1),
                receivedAt: receivedAt
            )
        )
        XCTAssertTrue(
            AppleWatchDataSyncReceiptPolicy.satisfiesPendingRequest(
                requestedAt: requestedAt,
                expectedRequestID: "current",
                receivedRequestID: "current",
                measuredAt: requestedAt.addingTimeInterval(-60),
                receivedAt: receivedAt
            )
        )
        XCTAssertTrue(
            AppleWatchDataSyncReceiptPolicy.satisfiesPendingRequest(
                requestedAt: requestedAt,
                expectedRequestID: "current",
                receivedRequestID: nil,
                measuredAt: requestedAt,
                receivedAt: receivedAt
            )
        )
    }

    func testAutomaticWatchSyncCoalescesConnectionCallbackBursts() {
        XCTAssertTrue(
            AppleWatchAutomaticSyncPolicy.shouldRequest(
                lastRequestUptime: nil,
                nowUptime: 100
            )
        )
        XCTAssertFalse(
            AppleWatchAutomaticSyncPolicy.shouldRequest(
                lastRequestUptime: 100,
                nowUptime: 109.9
            )
        )
        XCTAssertTrue(
            AppleWatchAutomaticSyncPolicy.shouldRequest(
                lastRequestUptime: 100,
                nowUptime: 110
            )
        )
    }
}
