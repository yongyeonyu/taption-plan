import XCTest
@testable import TaptionActivityEngine

/// 짧은 정지로 쪼개진 이동 합치기 회귀 시험 (CLN1110A01). 합성 표본만 쓴다.
final class ActivityFragmentBridgeTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    /// 구간마다 (움직임, 초)를 10초 간격 표본으로 만든다.
    private func evidence(_ parts: [(ActivityMotion, Int)]) -> [ActivitySensorEvidence] {
        var second = 0
        var result: [ActivitySensorEvidence] = []
        for (motion, length) in parts {
            for offset in stride(from: 0, to: length, by: 10) {
                result.append(ActivitySensorEvidence(timestamp: base.addingTimeInterval(TimeInterval(second + offset)), motion: motion))
            }
            second += length
        }
        return result
    }

    func testWalkPauseWalkAtCrossingBecomesOneWalkKeepingFirstID() {
        let samples = evidence([(.walking, 180), (.stationary, 90), (.walking, 240)])
        let engine = ActivityClassificationEngine()
        let segments = engine.classify(samples)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.detailID, "movement.walking")
        XCTAssertEqual(segments.first?.id, ActivityStableID.uuid(seed: samples[0].id.uuidString), "첫 조각 식별자를 유지한다")
        XCTAssertTrue(segments.first?.provenance.evidence.contains(ActivityFragmentBridge.evidenceLabel) == true)
        XCTAssertTrue(segments.first?.provenance.evidence.contains("정지 센서 근거") == true, "흡수한 정지의 근거가 남는다")
        XCTAssertEqual(segments.first?.sampleCount, samples.count)
    }

    func testAppendMatchesFullClassificationAcrossBridgedPause() {
        let samples = evidence([(.walking, 180), (.stationary, 90), (.walking, 240)])
        let engine = ActivityClassificationEngine()
        let state = engine.classifyState(Array(samples.prefix(27)))
        let appended = engine.append(Array(samples.dropFirst(27)), to: state)
        XCTAssertEqual(appended.segments, engine.classify(samples))
    }

    func testRealStayIsNotBridged() {
        let segments = ActivityClassificationEngine().classify(evidence([(.walking, 180), (.stationary, 360), (.walking, 240)]))
        XCTAssertEqual(segments.map(\.detailID), ["movement.walking", "activity.rest", "movement.walking"])
    }

    func testWalkThenCarIsNotBridged() {
        let segments = ActivityClassificationEngine().classify(evidence([(.walking, 180), (.stationary, 60), (.automotive, 240)]))
        XCTAssertEqual(segments.map(\.detailID), ["movement.walking", "activity.rest", "movement.car"])
    }

    // MARK: - REV1110A06: 증분 경로

    private let crossing: [(ActivityMotion, Int)] = [(.walking, 180), (.stationary, 90), (.walking, 240), (.stationary, 60), (.walking, 120), (.stationary, 400), (.automotive, 200)]

    func testAppendAtEverySplitMatchesFullClassification() {
        let samples = evidence(crossing)
        let engine = ActivityClassificationEngine()
        let full = engine.classify(samples)
        for split in 1..<samples.count {
            let state = engine.classifyState(Array(samples.prefix(split)))
            XCTAssertEqual(engine.append(Array(samples.dropFirst(split)), to: state).segments, full, "split \(split)")
        }
    }

    func testOneSampleAtATimeMatchesFullClassificationAtEveryStep() {
        let samples = evidence(crossing)
        let engine = ActivityClassificationEngine()
        var state = engine.classifyState([samples[0]])
        for count in 2...samples.count {
            state = engine.append([samples[count - 1]], to: state)
            XCTAssertEqual(state.segments, engine.classify(Array(samples.prefix(count))), "count \(count)")
        }
    }

    func testAppendToAlreadyBridgedLastSegmentKeepsItBridged() {
        // 35번째 표본은 둘째 걷기 안이라 상태의 끝 구간이 이미 이어 붙인 걷기다.
        let samples = evidence([(.walking, 180), (.stationary, 90), (.walking, 240)])
        let engine = ActivityClassificationEngine()
        let state = engine.classifyState(Array(samples.prefix(35)))
        XCTAssertEqual(state.segments.count, 1)
        XCTAssertTrue(state.segments[0].evidence.contains(ActivityFragmentBridge.evidenceLabel))
        let appended = engine.append(Array(samples.dropFirst(35)), to: state)
        XCTAssertEqual(appended.segments, engine.classify(samples))
        XCTAssertEqual(appended.segments.first?.sampleCount, samples.count)
    }

    func testRestGrowingAfterMovementStaysOnTheIncrementalPath() {
        let walk = ActivitySegmentProbe.segment(detail: "movement.walking", major: "movement", start: 0, end: 180)
        let pause = ActivitySegmentProbe.segment(detail: "activity.rest", major: "activity", start: 180, end: 240)
        XCTAssertFalse(ActivityFragmentBridge.mayBridge(before: walk, pause: pause, tailCount: 1), "정지만 길어지면 전체를 다시 계산하지 않는다")
        XCTAssertTrue(ActivityFragmentBridge.mayBridge(before: walk, pause: pause, tailCount: 2))
        XCTAssertFalse(ActivityFragmentBridge.mayBridge(before: pause, pause: pause, tailCount: 2), "앞이 이동이 아니면 이어질 것이 없다")
        XCTAssertFalse(ActivityFragmentBridge.mayBridge(before: nil, pause: pause, tailCount: 2))
        let longRest = ActivitySegmentProbe.segment(detail: "activity.rest", major: "activity", start: 180, end: 400)
        XCTAssertFalse(ActivityFragmentBridge.mayBridge(before: walk, pause: longRest, tailCount: 2))
    }
}

private enum ActivitySegmentProbe {
    static func segment(detail: String, major: String, start: TimeInterval, end: TimeInterval) -> ActivitySegment {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let span = ActivityTimeSpan(start: base.addingTimeInterval(start), end: base.addingTimeInterval(end))
        return ActivitySegment(
            id: UUID(), span: span, majorCategoryID: major, detailID: detail, title: detail, behavior: detail,
            confidence: 0.6, evidence: [], sampleCount: 1, isUserConfirmed: false,
            provenance: .init(tier: .supporting, status: .observed, source: ActivityFragmentBridge.automaticSource, evidence: [], confidence: 0.6, span: span)
        )
    }
}
