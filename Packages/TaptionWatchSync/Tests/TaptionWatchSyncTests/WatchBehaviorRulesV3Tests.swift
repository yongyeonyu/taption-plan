import XCTest
@testable import TaptionWatchSync

/// WSN1112A01: 가속도만 있는 평상시 창에서 걷기·달리기를 잘못 읽지 않고, 판정이 한 행동에 붙들리지 않는다.
final class WatchBehaviorRulesV3Tests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    /// 평상시 경로와 같은 12.5Hz, 2.56초.
    private let rate = 12.5
    private let count = 33

    private struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    private func window(_ magnitude: (Int, Double) -> Double) -> [WatchMotionSample] {
        (0..<count).map { index in
            let elapsed = Double(index) / rate
            return WatchMotionSample(
                capturedAt: start.addingTimeInterval(elapsed),
                acceleration: TaptionWatchSensorVector3(
                    x: 0, y: 0, z: magnitude(index, elapsed)
                )
            )
        }
    }

    private func classify(_ samples: [WatchMotionSample]) throws -> (
        WatchBehaviorWindowFeatures, WatchBehaviorInference
    ) {
        let features = try XCTUnwrap(WatchBehaviorWindowAnalyzer.features(from: samples))
        let inference = WatchBehaviorClassifier.classifyWindow(
            features,
            context: WatchBehaviorInput(duration: features.duration, gpsLossRatio: 1)
        )
        return (features, inference)
    }

    func testPeriodicArmSwingIsWalkingWithStrongPeriodicity() throws {
        let (features, inference) = try classify(window { _, t in
            1 + 0.2 * abs(sin(2 * .pi * 0.9 * t))
        })
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(features.periodicityStrength),
            WatchBehaviorClassifier.minimumGaitPeriodicity
        )
        XCTAssertEqual(inference.kind, .walking)
        XCTAssertEqual(inference.modelVersion, "watch-har-v3")
    }

    func testIrregularHandMotionIsNotWalkingOrRunning() throws {
        var generator = Generator(state: 7)
        var kinds: [WatchBehaviorKind: Int] = [:]
        var irregular = 0
        for _ in 0..<200 {
            let noise = (0..<count).map { _ in Double.random(in: -0.18...0.18, using: &generator) }
            let (_, inference) = try classify(window { index, _ in 1 + noise[index] })
            kinds[inference.kind, default: 0] += 1
            if inference.evidence.contains(WatchBehaviorClassifier.irregularMotionEvidence) {
                irregular += 1
            }
        }
        let gait = (kinds[.walking] ?? 0) + (kinds[.running] ?? 0)
        // v2는 이런 창 대부분을 걷기·달리기로 읽었다. 잡음이 우연히 주기를 띠는 몫만 남긴다.
        XCTAssertLessThanOrEqual(gait, 20, "\(kinds)")
        XCTAssertGreaterThanOrEqual(irregular, 150, "\(kinds)")
    }

    func testFaintVibrationAtRunningFrequencyIsNotRunning() {
        // 실제 기록에서 가속도 변동 0.00g인 묶음에 「달리기 범위」 근거가 붙어 있었다.
        let inference = WatchBehaviorClassifier.classify(
            WatchBehaviorInput(
                duration: 2.56,
                accelerometerSampleCount: 32,
                accelerationBodyRMSG: 0.004,
                dominantMotionFrequencyHz: 2.5,
                motionPeriodicity: 0.9
            )
        )
        XCTAssertEqual(inference.kind, .stationary)
    }

    func testStrongPeriodicImpactIsRunning() {
        let inference = WatchBehaviorClassifier.classify(
            WatchBehaviorInput(
                duration: 2.56,
                accelerometerSampleCount: 32,
                accelerationBodyRMSG: 0.6,
                dominantMotionFrequencyHz: 2.6,
                motionPeriodicity: 0.7
            )
        )
        XCTAssertEqual(inference.kind, .running)
    }

    func testLegacyInputWithoutPeriodicityKeepsWalkingRule() {
        let inference = WatchBehaviorClassifier.classify(
            WatchBehaviorInput(
                duration: 2.56,
                accelerometerSampleCount: 64,
                accelerationBodyRMSG: 0.1,
                dominantMotionFrequencyHz: 1.8
            )
        )
        XCTAssertEqual(inference.kind, .walking)
    }

    func testStillWindowIsStationary() throws {
        let (_, inference) = try classify(window { _, _ in 1.001 })
        XCTAssertEqual(inference.kind, .stationary)
    }

    // MARK: - 구간 안정화

    private func inference(_ kind: WatchBehaviorKind, _ score: Double) -> WatchBehaviorInference {
        WatchBehaviorInference(
            kind: kind, confidenceScore: score,
            evidence: ["\(kind.rawValue) 근거"],
            modelVersion: WatchBehaviorClassifier.rulesVersion
        )
    }

    func testStabilizerLeavesWalkingAfterTwoStationaryWindows() {
        var stabilizer = WatchBehaviorStabilizer()
        XCTAssertEqual(stabilizer.stabilize(inference(.walking, 0.79)).kind, .walking)
        let held = stabilizer.stabilize(inference(.stationary, 0.55))
        XCTAssertEqual(held.kind, .walking)
        XCTAssertEqual(held.evidence, [WatchBehaviorStabilizer.heldEvidence])
        XCTAssertEqual(stabilizer.stabilize(inference(.stationary, 0.55)).kind, .stationary)
        XCTAssertEqual(stabilizer.stabilize(inference(.stationary, 0.55)).kind, .stationary)
    }

    func testStabilizerIgnoresSingleOutlierAndAlternatingNoise() {
        var stabilizer = WatchBehaviorStabilizer()
        _ = stabilizer.stabilize(inference(.stationary, 0.55))
        XCTAssertEqual(stabilizer.stabilize(inference(.unknown, 0.4)).kind, .stationary)
        XCTAssertEqual(stabilizer.stabilize(inference(.eating, 0.45)).kind, .stationary)
        XCTAssertEqual(stabilizer.stabilize(inference(.unknown, 0.4)).kind, .stationary)
        XCTAssertEqual(stabilizer.stabilize(inference(.stationary, 0.55)).kind, .stationary)
    }

    func testStabilizerSwitchesAtOnceOnClearlyStrongerEvidence() {
        var stabilizer = WatchBehaviorStabilizer()
        _ = stabilizer.stabilize(inference(.stationary, 0.55))
        XCTAssertEqual(stabilizer.stabilize(inference(.walking, 0.79)).kind, .walking)
    }

    // MARK: - 평상시 묶음 해석

    private func segment(
        _ kind: WatchBehaviorKind, from: TimeInterval, to: TimeInterval,
        evidence: [String] = []
    ) -> WatchBehaviorSegment {
        WatchBehaviorSegment(
            startedAt: start.addingTimeInterval(from),
            endedAt: start.addingTimeInterval(to),
            behavior: kind, confidenceScore: 0.6, evidence: evidence,
            modelVersion: WatchBehaviorClassifier.rulesVersion
        )
    }

    func testChunkWithMixedGaitAndHandMotionIsMixedActivityWithValues() {
        let verdict = WatchAmbientChunkInterpreter.interpret(
            duration: 600, sampleCount: 7_500, standardDeviationG: 0.072,
            segments: [
                segment(.walking, from: 0, to: 120),
                segment(.unknown, from: 120, to: 360,
                        evidence: [WatchBehaviorClassifier.irregularMotionEvidence]),
                segment(.stationary, from: 360, to: 600),
            ]
        )
        XCTAssertEqual(verdict.outcome, .mixedActivity)
        XCTAssertEqual(verdict.gaitShare, 0.2, accuracy: 0.001)
        XCTAssertEqual(verdict.handShare, 0.4, accuracy: 0.001)
        XCTAssertTrue(verdict.evidence.contains("가속도 변동 0.072g"))
        XCTAssertTrue(verdict.evidence.contains("걸음 창 20%"))
        XCTAssertTrue(verdict.evidence.contains("손동작 창 40%"))
    }

    func testQuietChunkIsStillEvenWithSmallJitter() {
        // 예전 기준(0.018g)으로는 움직임이었다.
        let verdict = WatchAmbientChunkInterpreter.interpret(
            duration: 600, sampleCount: 7_500, standardDeviationG: 0.021,
            segments: [segment(.stationary, from: 0, to: 600)]
        )
        XCTAssertEqual(verdict.outcome, .still)
    }

    func testWalkingChunkIsLeftToPhone() {
        let verdict = WatchAmbientChunkInterpreter.interpret(
            duration: 600, sampleCount: 7_500, standardDeviationG: 0.15,
            segments: [
                segment(.walking, from: 0, to: 500),
                segment(.stationary, from: 500, to: 600),
            ]
        )
        XCTAssertEqual(verdict.outcome, .mostlyGait)
    }

    func testShortChunkIsInsufficient() {
        let verdict = WatchAmbientChunkInterpreter.interpret(
            duration: 12, sampleCount: 150, standardDeviationG: 0.2, segments: []
        )
        XCTAssertEqual(verdict.outcome, .insufficient)
    }

    func testFeaturesDecodeWithoutPeriodicity() throws {
        let features = WatchBehaviorWindowFeatures(
            startedAt: start, endedAt: start.addingTimeInterval(2.56),
            sampleCount: 32, sampleRateHz: 12.5, accelerationMeanG: 1,
            accelerationStandardDeviationG: 0, bodyAccelerationRMSG: 0,
            jerkRMSGPerSecond: 0, zeroCrossingRateHz: 0, gyroscopeRMSGPerSecond: 0,
            periodicityStrength: 0.5
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(features)) as? [String: Any]
        )
        object.removeValue(forKey: "periodicityStrength")
        let legacy = try JSONDecoder().decode(
            WatchBehaviorWindowFeatures.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(legacy.periodicityStrength)
        XCTAssertEqual(legacy.featureVector.count, 12)
    }
}
