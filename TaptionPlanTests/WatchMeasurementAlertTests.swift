import XCTest
@testable import TaptionPlan

/// 워치 위젯은 워치 앱과 다른 프로세스라, 앱이 앱 그룹에 남긴 측정
/// 스냅숏만 보고 그린다. 위젯이 무엇을 말하고 언제 다시 그리는지는 전부
/// 이 순수 규칙에서 나오므로 시뮬레이터에서 그대로 검증한다.
/// 실제 `CMSensorRecorder` 가용성과 컴플리케이션 렌더링은 실기기 몫이다.
final class WatchMeasurementAlertTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(
        source: TaptionWatchMeasurementSource = .ambient,
        behavior: WatchBehaviorKind? = .walking,
        confidence: Double = 0.8,
        measuredAgo: TimeInterval? = 120,
        isRecordingRequested: Bool = true,
        isRecorderAvailable: Bool = true,
        isMotionAccessDenied: Bool = false,
        drainFailureCount: Int = 0,
        failureMessage: String? = nil
    ) -> TaptionWatchMeasurementSnapshot {
        TaptionWatchMeasurementSnapshot(
            updatedAt: now,
            source: source,
            behavior: behavior,
            confidenceScore: confidence,
            measuredAt: measuredAgo.map { now.addingTimeInterval(-$0) },
            isRecordingRequested: isRecordingRequested,
            isRecorderAvailable: isRecorderAvailable,
            isMotionAccessDenied: isMotionAccessDenied,
            drainFailureCount: drainFailureCount,
            failureMessage: failureMessage
        )
    }

    private func kinds(
        _ value: TaptionWatchMeasurementSnapshot?
    ) -> [TaptionWatchAlertKind] {
        TaptionWatchAlertPolicy.alerts(for: value, now: now).map(\.kind)
    }

    // MARK: - 알릴 것이 없는 상태

    func testHealthyRecordingRaisesNoAlert() {
        XCTAssertTrue(kinds(snapshot()).isEmpty)
        XCTAssertNil(TaptionWatchAlertPolicy.primary(for: snapshot(), now: now))
    }

    func testMissingSnapshotRaisesNoAlert() {
        // 워치 앱이 한 번도 실행되지 않았으면 상태를 단정할 근거가 없다.
        XCTAssertTrue(kinds(nil).isEmpty)
    }

    func testDisabledRecordingIsNotAnAlert() {
        // 사용자가 iPhone에서 끈 것이다. 경고로 되묻지 않는다.
        let value = snapshot(
            source: .idle,
            behavior: nil,
            measuredAgo: nil,
            isRecordingRequested: false,
            isRecorderAvailable: false
        )
        XCTAssertTrue(kinds(value).isEmpty)
    }

    func testFreshInstallWithoutMeasurementIsNotStalled() {
        // 측정이 한 번도 없었으면 "끊겼다"고 말할 근거가 없다.
        XCTAssertTrue(kinds(snapshot(behavior: nil, measuredAgo: nil)).isEmpty)
    }

    // MARK: - 알릴 것이 있는 상태

    func testFailureMessageBecomesTheFirstAlert() {
        let value = snapshot(
            drainFailureCount: 2,
            failureMessage: "운동 측정이 중단됐습니다."
        )
        XCTAssertEqual(kinds(value), [.recordingFailed, .recordingGap])
        let primary = TaptionWatchAlertPolicy.primary(for: value, now: now)
        XCTAssertEqual(primary?.detail, "운동 측정이 중단됐습니다.")
    }

    func testEmptyFailureMessageIsIgnored() {
        XCTAssertTrue(kinds(snapshot(failureMessage: "")).isEmpty)
    }

    func testDeniedMotionAccessReplacesUnavailableRecorder() {
        // 권한 거부가 원인이면 "이 워치에서 불가"라고 말하지 않는다.
        let value = snapshot(
            isRecorderAvailable: false,
            isMotionAccessDenied: true
        )
        XCTAssertEqual(kinds(value), [.motionAccessDenied])
    }

    func testUnavailableRecorderAlertsOnlyWhenRecordingIsRequested() {
        XCTAssertEqual(
            kinds(snapshot(isRecorderAvailable: false)),
            [.recorderUnavailable]
        )
        XCTAssertTrue(
            kinds(
                snapshot(
                    measuredAgo: nil,
                    isRecordingRequested: false,
                    isRecorderAvailable: false
                )
            ).isEmpty
        )
    }

    func testDrainFailuresReportTheirCount() {
        let alerts = TaptionWatchAlertPolicy.alerts(
            for: snapshot(drainFailureCount: 3),
            now: now
        )
        XCTAssertEqual(alerts.map(\.kind), [.recordingGap])
        XCTAssertEqual(alerts.first?.detail, "읽지 못한 구간 3회")
    }

    func testStalledMeasurementNeedsTheFullInterval() {
        let threshold = TaptionWatchAlertPolicy.stalledMeasurementInterval
        XCTAssertTrue(kinds(snapshot(measuredAgo: threshold - 1)).isEmpty)
        XCTAssertEqual(
            kinds(snapshot(measuredAgo: threshold)),
            [.measurementStalled]
        )
    }

    func testRunningWorkoutIsNeverStalled() {
        // 운동 중에는 30초마다 새 요약이 나온다. 시계를 되돌리거나 요약이
        // 늦어도 사용자를 부르지 않는다.
        let value = snapshot(
            source: .workout,
            measuredAgo: TaptionWatchAlertPolicy.stalledMeasurementInterval * 2
        )
        XCTAssertTrue(kinds(value).isEmpty)
    }

    func testFutureMeasurementIsNotStalled() {
        XCTAssertTrue(kinds(snapshot(measuredAgo: -3_600)).isEmpty)
    }

    // MARK: - 스냅숏 값

    func testSnapshotClampsConfidenceAndFailureCount() {
        let high = snapshot(confidence: 1.4, drainFailureCount: -2)
        XCTAssertEqual(high.confidenceScore, 1)
        XCTAssertEqual(high.drainFailureCount, 0)
        XCTAssertEqual(snapshot(confidence: -0.5).confidenceScore, 0)
    }

    func testSnapshotSurvivesJSONRoundTrip() throws {
        // 앱과 위젯은 앱 그룹에 넣은 JSON으로만 이어져 있다.
        let value = snapshot(drainFailureCount: 1, failureMessage: "실패")
        let decoded = try JSONDecoder().decode(
            TaptionWatchMeasurementSnapshot.self,
            from: JSONEncoder().encode(value)
        )
        XCTAssertEqual(decoded, value)
    }

    // MARK: - 위젯 새로고침

    func testFirstPublishAlwaysReloads() {
        XCTAssertTrue(
            TaptionWatchWidgetRefreshPolicy.shouldReload(
                previous: nil,
                next: snapshot(),
                lastReloadedAt: nil,
                now: now
            )
        )
    }

    func testUnchangedDisplayWaitsForTheMinimumInterval() {
        let interval = TaptionWatchWidgetRefreshPolicy.minimumInterval
        XCTAssertFalse(
            TaptionWatchWidgetRefreshPolicy.shouldReload(
                previous: snapshot(),
                next: snapshot(measuredAgo: 30),
                lastReloadedAt: now.addingTimeInterval(-interval + 1),
                now: now
            )
        )
        XCTAssertTrue(
            TaptionWatchWidgetRefreshPolicy.shouldReload(
                previous: snapshot(),
                next: snapshot(measuredAgo: 30),
                lastReloadedAt: now.addingTimeInterval(-interval),
                now: now
            )
        )
    }

    func testChangedActivityReloadsImmediately() {
        XCTAssertTrue(
            TaptionWatchWidgetRefreshPolicy.shouldReload(
                previous: snapshot(behavior: .walking),
                next: snapshot(behavior: .sitting),
                lastReloadedAt: now,
                now: now
            )
        )
    }

    func testConfidenceReloadsOnlyWhenItsBucketChanges() {
        XCTAssertFalse(
            TaptionWatchWidgetRefreshPolicy.shouldReload(
                previous: snapshot(confidence: 0.80),
                next: snapshot(confidence: 0.82),
                lastReloadedAt: now,
                now: now
            )
        )
        XCTAssertTrue(
            TaptionWatchWidgetRefreshPolicy.shouldReload(
                previous: snapshot(confidence: 0.80),
                next: snapshot(confidence: 0.91),
                lastReloadedAt: now,
                now: now
            )
        )
    }

    func testNewAlertReloadsImmediately() {
        XCTAssertTrue(
            TaptionWatchWidgetRefreshPolicy.shouldReload(
                previous: snapshot(),
                next: snapshot(failureMessage: "운동 저장을 완료하지 못했습니다."),
                lastReloadedAt: now,
                now: now
            )
        )
    }
}
