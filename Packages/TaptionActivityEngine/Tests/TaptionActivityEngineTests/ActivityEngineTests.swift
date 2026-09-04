import XCTest
@testable import TaptionActivityEngine

final class ActivityEngineTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    func testTaxonomyMapsDetailsToMajor() {
        let taxonomy = ActivityTaxonomy.default
        XCTAssertEqual(taxonomy.detail(for: "movement.subway")?.behavior, "subway")
        XCTAssertEqual(taxonomy.major(for: "sleep")?.title, "수면")
    }

    func testDuplicateAndOutOfOrderNormalizationIsDeterministic() {
        let idA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let idB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let idC = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let t = base.addingTimeInterval(10)
        let low = ActivitySensorEvidence(id: idA, timestamp: t, motion: .stationary, horizontalAccuracyMeters: 50, sequence: 1)
        let precise = ActivitySensorEvidence(id: idB, timestamp: t, motion: .walking, horizontalAccuracyMeters: 5, sequence: 1)
        let earlier = ActivitySensorEvidence(id: idC, timestamp: base)
        let engine = ActivityClassificationEngine()
        XCTAssertEqual(engine.normalize([low, precise, earlier]).map(\.id), [idC, idB])
        let result = engine.normalize([low, precise])
        XCTAssertEqual(result, [precise])
    }

    func testSleepOverrideWinsAndSplitsAutomaticActivity() {
        let override = ActivityClassificationOverride(id: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!, span: ActivityTimeSpan(start: base.addingTimeInterval(30), end: base.addingTimeInterval(90)), majorCategoryID: "sleep", detailID: "sleep.core")
        let evidence = stride(from: 0, through: 120, by: 30).map { offset in ActivitySensorEvidence(id: UUID(), timestamp: base.addingTimeInterval(TimeInterval(offset)), motion: .stationary) }
        let segments = ActivityClassificationEngine().classify(evidence, overrides: [override])
        XCTAssertTrue(segments.contains { $0.majorCategoryID == "sleep" && $0.isUserConfirmed })
        XCTAssertTrue(segments.contains { $0.majorCategoryID == "activity" })
    }

    func testIncrementalTailEqualsFullClassification() {
        let evidence = stride(from: 0, through: 90, by: 10).map { offset in ActivitySensorEvidence(id: UUID(), timestamp: base.addingTimeInterval(TimeInterval(offset)), motion: offset < 50 ? .walking : .stationary) }
        let engine = ActivityClassificationEngine()
        let prefix = engine.classifyState(Array(evidence.prefix(5)))
        let incremental = engine.append(Array(evidence.dropFirst(5)), to: prefix)
        let full = engine.classifyState(evidence)
        XCTAssertEqual(incremental.segments, full.segments)
        XCTAssertEqual(incremental.evidence, full.evidence)
    }

    func testWatchAndPhoneEvidenceFuseWithWatchBehaviorPriority() {
        let phoneID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let watchID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
        let phone = ActivitySensorEvidence(
            id: phoneID,
            timestamp: base,
            motion: .walking,
            speedMetersPerSecond: 1.4,
            horizontalAccuracyMeters: 5,
            behaviorHint: "walking",
            confidence: 0.61,
            source: .iPhone
        )
        let watch = ActivitySensorEvidence(
            id: watchID,
            timestamp: base.addingTimeInterval(1),
            motion: .stationary,
            behaviorHint: "sleep",
            confidence: 0.92,
            source: .appleWatch
        )

        let fused = ActivitySensorEvidenceFusion.fuse([phone, watch])

        XCTAssertEqual(fused.count, 1)
        XCTAssertEqual(fused.first?.source, .combined)
        XCTAssertEqual(fused.first?.motion, .stationary)
        XCTAssertEqual(fused.first?.behaviorHint, "sleep")
        XCTAssertEqual(fused.first?.speedMetersPerSecond, 1.4)
        XCTAssertTrue(fused.first?.evidence.contains("Apple Watch + iPhone 조합") == true)
    }

    func testProjectionPreservesLockedOverrideAndCanonicalMajorIDs() {
        let evidence = ActivitySensorEvidence(timestamp: base, motion: .stationary)
        let override = ActivityClassificationOverride(
            span: ActivityTimeSpan(start: base, end: base.addingTimeInterval(10)),
            majorCategoryID: "legacy-category",
            title: "사용자 분류",
            isLocked: true
        )

        let projection = ActivityClassificationProjection(
            evidence: [evidence],
            overrides: [override]
        )
        let canonicalIDs = Set(ActivityTaxonomy.default.majors.map(\.id))

        XCTAssertEqual(projection.version, ActivityClassificationProjection.currentVersion)
        XCTAssertEqual(projection.state.overrides.first?.majorCategoryID, "activity")
        XCTAssertTrue(projection.state.overrides.first?.isLocked == true)
        XCTAssertTrue(projection.majorCategoryIDs.allSatisfy { canonicalIDs.contains($0) })
    }

    func testGapInferenceUsesEvidenceButDoesNotFillUnsupportedGap() {
        let engine = ActivityGapInferenceEngine()
        let gap = ActivityTimeSpan(start: base, end: base.addingTimeInterval(10 * 60))
        let walking = ActivitySensorEvidence(
            timestamp: base.addingTimeInterval(60),
            motion: .walking,
            speedMetersPerSecond: 1.4,
            isPreciseLocation: true
        )

        let inferred = engine.infer(.init(span: gap, evidence: [walking]))
        XCTAssertEqual(inferred.first?.majorCategoryID, "movement")
        XCTAssertEqual(inferred.first?.behavior, "walking")
        XCTAssertTrue(inferred.allSatisfy { $0.span.start >= gap.start && $0.span.end <= gap.end })

        let unsupported = engine.infer(.init(
            span: gap,
            evidence: [],
            precedingAnchor: .init(
                majorCategoryID: "sleep",
                detailID: "sleep.core",
                behavior: "core"
            ),
            followingAnchor: .init(
                majorCategoryID: "movement",
                detailID: "movement.walking",
                behavior: "walking"
            )
        ))
        XCTAssertTrue(unsupported.isEmpty)
    }

    func testGapInferenceBridgesMatchingShortGroundTruthAnchorsOnly() {
        let anchor = ActivityGapAnchor(
            majorCategoryID: "sleep",
            detailID: "sleep.core",
            behavior: "core"
        )
        let span = ActivityTimeSpan(start: base, end: base.addingTimeInterval(5 * 60))
        let result = ActivityGapInferenceEngine().infer(.init(
            span: span,
            evidence: [],
            precedingAnchor: anchor,
            followingAnchor: anchor
        ))

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.majorCategoryID, "sleep")
        XCTAssertEqual(result.first?.span, span)
    }

    func testSleepRequiresCoreAndAllSupportingConditionsForFiveMinutes() {
        let configuration = SleepInferenceConfiguration()
        let samples = stride(from: 0, through: 5 * 60, by: 60).map { minute in
            SleepRuleSample(
                timestamp: base.addingTimeInterval(TimeInterval(minute)),
                screenIsOn: false,
                inactivityDuration: 30 * 60,
                distanceFromHomeMeters: 40,
                ambientIsDark: true,
                isCharging: true
            )
        }

        let result = SleepInferenceEngine(configuration: configuration).infer(samples)

        XCTAssertEqual(result.state, .asleep)
        XCTAssertEqual(result.provenance?.tier, .expected)
        XCTAssertEqual(result.provenance?.status, .automaticallyConfirmed)
        XCTAssertEqual(
            result.provenance?.span,
            ActivityTimeSpan(start: base, end: base.addingTimeInterval(5 * 60))
        )
    }

    func testSleepDoesNotInferWithOnlyTwoSupportingConditions() {
        let samples = stride(from: 0, through: 5 * 60, by: 60).map { minute in
            SleepRuleSample(
                timestamp: base.addingTimeInterval(TimeInterval(minute)),
                screenIsOn: false,
                inactivityDuration: 30 * 60,
                distanceFromHomeMeters: 40,
                ambientIsDark: true,
                isCharging: false
            )
        }

        XCTAssertNotEqual(SleepInferenceEngine().infer(samples).state, .asleep)
    }

    func testSleepWakeRequiresScreenActivityAndReleasedSupportCondition() {
        let result = SleepInferenceEngine().infer([
            SleepRuleSample(
                timestamp: base,
                screenIsOn: true,
                inactivityDuration: 0,
                phoneMoved: true,
                distanceFromHomeMeters: 300,
                ambientIsDark: false,
                isCharging: false
            )
        ])

        XCTAssertEqual(result.state, .wakeCandidate)
    }

    func testRegisteredPlaceWinsOverPOIAndRequiresFifteenMinutes() {
        let span = ActivityTimeSpan(start: base, end: base.addingTimeInterval(15 * 60))
        let result = PlaceActivityInferenceEngine().infer(.init(
            span: span,
            registeredKind: .workplace,
            poiKind: .restaurant
        ))

        XCTAssertEqual(result?.categoryID, "work")
        XCTAssertEqual(result?.detailID, "work.rest")
        XCTAssertEqual(result?.provenance.source, "registered-place-v1")
    }
}
