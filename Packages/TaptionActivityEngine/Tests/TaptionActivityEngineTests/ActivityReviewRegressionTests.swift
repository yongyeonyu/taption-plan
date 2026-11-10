import XCTest
@testable import TaptionActivityEngine

/// 리뷰 지적 회귀 시험 (REV1110A04).
final class ActivityReviewRegressionTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    func testVaryingConfidenceAndEvidenceDoNotShatterSegments() {
        let evidence = (0..<10).map { index in
            ActivitySensorEvidence(
                timestamp: base.addingTimeInterval(TimeInterval(index * 5)),
                motion: .walking,
                confidence: 0.6 + Double(index) * 0.03,
                evidence: ["fix-\(index)"]
            )
        }
        let segments = ActivityClassificationEngine().classify(evidence)

        // 5초 간격 표본은 1초 길이라 이웃 구간이 맞닿지 않는다. 정체성으로 이어 붙여야 한 구간이 된다.
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.span, ActivityTimeSpan(start: base, end: base.addingTimeInterval(46)))
        XCTAssertEqual(segments.first?.sampleCount, 10)
        XCTAssertEqual(segments.first?.confidence ?? 0, 0.6, accuracy: 1e-9)
        XCTAssertTrue(segments.first?.evidence.contains("fix-0") == true)
        XCTAssertTrue(segments.first?.evidence.contains("fix-9") == true)
    }

    func testSameTimestampKeepsSleepHintBesideSensorSample() {
        let sensor = ActivitySensorEvidence(timestamp: base, motion: .stationary)
        let sleepHint = ActivitySensorEvidence(timestamp: base, categoryHint: "sleep", source: .iPhone)
        let watch = ActivitySensorEvidence(timestamp: base, motion: .walking, source: .appleWatch)
        let duplicate = ActivitySensorEvidence(timestamp: base, motion: .walking, isPreciseLocation: false)
        let engine = ActivityClassificationEngine()

        let normalized = engine.normalize([sleepHint, duplicate, watch, sensor])
        XCTAssertEqual(Set(normalized.map(\.id)), [sensor.id, sleepHint.id, watch.id])
        XCTAssertEqual(normalized.last?.id, sleepHint.id)

        let segments = engine.classify([sleepHint, sensor])
        XCTAssertEqual(segments.map(\.majorCategoryID), ["sleep"])
    }

    func testLockedOverrideKeepsLockSourceAndIsNotMergedIntoAutomaticSegment() {
        let evidence = (0..<6).map { index in
            ActivitySensorEvidence(timestamp: base.addingTimeInterval(TimeInterval(index)), motion: .walking)
        }
        let lock = ActivityClassificationOverride(
            span: ActivityTimeSpan(start: base.addingTimeInterval(3), end: base.addingTimeInterval(10)),
            majorCategoryID: "movement",
            detailID: "movement.walking",
            updatedAt: base,
            isLocked: true,
            isUserConfirmed: false
        )
        let segments = ActivityClassificationEngine().classify(evidence, overrides: [lock])

        XCTAssertEqual(segments.map(\.provenance.source), ["activity-classifier-v1", "classification-lock"])
        for segment in segments where segment.evidence.contains("자동 분류 잠금") {
            XCTAssertEqual(segment.provenance.source, "classification-lock")
        }
    }

    func testGapHintsMatchWholeWordsOnly() {
        let span = ActivityTimeSpan(start: base, end: base.addingTimeInterval(10 * 60))
        func behavior(hint: String) -> String? {
            let evidence = stride(from: 0, to: 10 * 60, by: 60).map { second in
                ActivitySensorEvidence(
                    timestamp: base.addingTimeInterval(TimeInterval(second)),
                    motion: .walking,
                    behaviorHint: hint
                )
            }
            return ActivityGapInferenceEngine()
                .infer(.init(span: span, evidence: evidence))
                .first?.behavior
        }
        XCTAssertEqual(behavior(hint: "petCare"), "walking")
        XCTAssertEqual(behavior(hint: "restaurant"), "walking")
        XCTAssertEqual(behavior(hint: "movement.car"), "automotive")
    }

    func testSleepEvidenceFollowsConfiguration() {
        let configuration = SleepInferenceConfiguration(inactivityDuration: 20 * 60, minimumSupportingConditions: 2)
        let samples = stride(from: 0, through: 5 * 60, by: 60).map { second in
            SleepRuleSample(
                timestamp: base.addingTimeInterval(TimeInterval(second)),
                screenIsOn: false,
                inactivityDuration: 20 * 60,
                distanceFromHomeMeters: 40,
                ambientIsDark: true
            )
        }
        let evidence = SleepInferenceEngine(configuration: configuration).infer(samples).provenance?.evidence ?? []

        XCTAssertTrue(evidence.contains("20분 무사용"))
        XCTAssertTrue(evidence.contains("보조 조건 2개 이상 충족"))
        XCTAssertFalse(evidence.contains("30분 무사용"))
    }

    func testWakeSpanCoversOnlyWakeMoment() {
        let asleep = stride(from: 0, through: 60 * 60, by: 60).map { second in
            SleepRuleSample(
                timestamp: base.addingTimeInterval(TimeInterval(second)),
                screenIsOn: false,
                inactivityDuration: 30 * 60,
                distanceFromHomeMeters: 40,
                ambientIsDark: true,
                isCharging: true
            )
        }
        let wakeAt = base.addingTimeInterval(61 * 60)
        let wake = SleepRuleSample(timestamp: wakeAt, screenIsOn: true, phoneMoved: true, ambientIsDark: false)
        let result = SleepInferenceEngine().infer(asleep + [wake])

        XCTAssertEqual(result.state, .wakeCandidate)
        XCTAssertEqual(result.provenance?.span, ActivityTimeSpan(start: wakeAt, end: wakeAt))
    }
}
