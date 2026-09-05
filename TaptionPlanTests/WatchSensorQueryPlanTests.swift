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
        XCTAssertEqual(next.first?.start, window.start)
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
