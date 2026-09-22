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

    func testNonthrowingClassificationRemainsDeterministicInCancelledTask() async {
        let engine = ActivityClassificationEngine()
        let evidence = [
            ActivitySensorEvidence(id: UUID(), timestamp: base.addingTimeInterval(10), motion: .walking),
            ActivitySensorEvidence(id: UUID(), timestamp: base, motion: .walking),
        ]
        let appendedEvidence = ActivitySensorEvidence(
            id: UUID(),
            timestamp: base.addingTimeInterval(20),
            motion: .walking
        )
        let prefix = engine.classifyState(Array(evidence.prefix(1)))
        let expectedState = engine.classifyState(evidence)
        let expectedAppended = engine.append([appendedEvidence], to: prefix)
        let expectedProjection = ActivityClassificationProjection(evidence: evidence)
        let gate = ClassificationStartGate()
        let worker = Task.detached {
            gate.waitBeforeWork()
            return (
                state: engine.classifyState(evidence),
                segments: engine.classify(evidence),
                normalized: engine.normalize(evidence),
                appended: engine.append([appendedEvidence], to: prefix),
                projection: ActivityClassificationProjection(evidence: evidence)
            )
        }

        guard gate.waitUntilReady() else {
            worker.cancel()
            gate.resumeWork()
            XCTFail("classification worker did not reach the cancellation gate")
            return
        }
        worker.cancel()
        gate.resumeWork()

        let actual = await worker.value
        XCTAssertEqual(actual.state, expectedState)
        XCTAssertEqual(actual.segments, expectedState.segments)
        XCTAssertEqual(actual.normalized, engine.normalize(evidence))
        XCTAssertEqual(actual.appended, expectedAppended)
        XCTAssertEqual(actual.projection, expectedProjection)
    }

    func testLargeClassificationCancellationStopsDuringSortAndSegmentConstruction() async {
        let sampleCount = 40_000
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let evidence = (0..<sampleCount).reversed().map { index in
            ActivitySensorEvidence(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", index + 1))!,
                timestamp: start.addingTimeInterval(TimeInterval(index)),
                motion: .walking
            )
        }
        let engine = ActivityClassificationEngine()

        for phase in [
            ActivityClassificationWorkPhase.normalization,
            .sorting,
            .deduplication,
            .segmentConstruction,
        ] {
            let gate = ClassificationCancellationGate(phase: phase, checkpoint: 32)
            let worker = Task.detached(priority: .utility) {
                try engine.classifyState(
                    evidence,
                    overrides: [],
                    cancellationCheck: { currentPhase in
                        try gate.check(currentPhase)
                    }
                )
            }

            guard gate.waitUntilReached() else {
                worker.cancel()
                gate.resume()
                _ = try? await worker.value
                XCTFail("classification did not reach the \(phase) cancellation checkpoint")
                continue
            }

            worker.cancel()
            gate.resume()
            do {
                _ = try await worker.value
                XCTFail("classification continued after cancellation during \(phase)")
            } catch is CancellationError {
                XCTAssertEqual(gate.observedCheckpoints, 32)
            } catch {
                XCTFail("unexpected classification error: \(error)")
            }
        }
    }

    func testCoreMotionEvidenceDoesNotTriggerSleepClassification() throws {
        let fixtures: [(ActivityMotion, String, String)] = [
            (.walking, "Core Motion 보행", "movement.walking"),
            (.automotive, "iPhone Core Motion 자동차", "movement.car"),
        ]
        let engine = ActivityClassificationEngine()

        for (motion, evidence, expectedDetailID) in fixtures {
            let segment = try XCTUnwrap(engine.classify([
                ActivitySensorEvidence(
                    timestamp: base,
                    motion: motion,
                    categoryHint: "movement",
                    evidence: [evidence]
                )
            ]).first)

            XCTAssertEqual(segment.majorCategoryID, "movement")
            XCTAssertEqual(segment.detailID, expectedDetailID)
        }
    }

    func testExplicitCoreSleepStageStillClassifiesSleep() throws {
        let segment = try XCTUnwrap(ActivityClassificationEngine().classify([
            ActivitySensorEvidence(
                timestamp: base,
                behaviorHint: "core"
            )
        ]).first)

        XCTAssertEqual(segment.majorCategoryID, "sleep")
        XCTAssertEqual(segment.detailID, "sleep.core")
    }

    func testSleepOverrideWinsAndSplitsAutomaticActivity() {
        let override = ActivityClassificationOverride(id: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!, span: ActivityTimeSpan(start: base.addingTimeInterval(30), end: base.addingTimeInterval(90)), majorCategoryID: "sleep", detailID: "sleep.core")
        let evidence = stride(from: 0, through: 120, by: 30).map { offset in ActivitySensorEvidence(id: UUID(), timestamp: base.addingTimeInterval(TimeInterval(offset)), motion: .stationary) }
        let segments = ActivityClassificationEngine().classify(evidence, overrides: [override])
        XCTAssertTrue(segments.contains { $0.majorCategoryID == "sleep" && $0.isUserConfirmed })
        XCTAssertTrue(segments.contains { $0.majorCategoryID == "activity" })
    }

    func testOverlappingOverridesKeepSleepPriorityAcrossManySamples() {
        let broadActivity = ActivityClassificationOverride(
            span: ActivityTimeSpan(
                start: base,
                end: base.addingTimeInterval(100)
            ),
            majorCategoryID: "activity",
            updatedAt: base.addingTimeInterval(1_000)
        )
        let backgroundOverrides = (0..<256).map { _ in
            ActivityClassificationOverride(
                span: broadActivity.span,
                majorCategoryID: "activity",
                updatedAt: base
            )
        }
        let sleep = ActivityClassificationOverride(
            span: ActivityTimeSpan(
                start: base.addingTimeInterval(20),
                end: base.addingTimeInterval(60)
            ),
            majorCategoryID: "sleep",
            detailID: "sleep.core",
            updatedAt: base
        )
        let recentMovement = ActivityClassificationOverride(
            span: ActivityTimeSpan(
                start: base.addingTimeInterval(30),
                end: base.addingTimeInterval(80)
            ),
            majorCategoryID: "movement",
            detailID: "movement.walking",
            updatedAt: base.addingTimeInterval(10_000)
        )
        let evidence = (0..<10_000).map { index in
            ActivitySensorEvidence(
                timestamp: base.addingTimeInterval(Double(index) / 100),
                motion: .stationary
            )
        }

        let segments = ActivityClassificationEngine().classify(
            evidence,
            overrides: backgroundOverrides + [broadActivity, sleep, recentMovement]
        )

        XCTAssertEqual(
            segments.first {
                $0.span.start <= base.addingTimeInterval(45)
                    && base.addingTimeInterval(45) < $0.span.end
            }?.majorCategoryID,
            "sleep"
        )
        XCTAssertEqual(
            segments.first {
                $0.span.start <= base.addingTimeInterval(65)
                    && base.addingTimeInterval(65) < $0.span.end
            }?.majorCategoryID,
            "movement"
        )
        XCTAssertEqual(
            segments.first {
                $0.span.start <= base.addingTimeInterval(85)
                    && base.addingTimeInterval(85) < $0.span.end
            }?.majorCategoryID,
            "activity"
        )
    }

    func testOverridePriorityTieBreakMatchesUUIDStringOrder() {
        let earlierID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let laterID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let span = ActivityTimeSpan(
            start: base,
            end: base.addingTimeInterval(30)
        )
        let later = ActivityClassificationOverride(
            id: laterID,
            span: span,
            majorCategoryID: "movement",
            detailID: "movement.walking",
            updatedAt: base
        )
        let earlier = ActivityClassificationOverride(
            id: earlierID,
            span: span,
            majorCategoryID: "activity",
            detailID: "activity.rest",
            updatedAt: base
        )
        let evidence = [0, 10, 20].map {
            ActivitySensorEvidence(
                timestamp: base.addingTimeInterval(TimeInterval($0)),
                motion: .stationary
            )
        }

        let segments = ActivityClassificationEngine().classify(
            evidence,
            overrides: [later, earlier]
        )

        XCTAssertEqual(segments.first?.majorCategoryID, "activity")
    }

    func testOverrideSweepMatchesReferenceForNestedAndExpiredIntervals() {
        let overrides = (0..<512).map { index in
            let startOffset = (index * 37) % 280 - 20
            let duration = (index * 19) % 83
            let category = ["activity", "movement", "sleep"][(index * 7) % 3]
            let id = UUID(
                uuidString: String(
                    format: "00000000-0000-0000-0000-%012x",
                    index + 1
                )
            )!
            let span = ActivityTimeSpan(
                start: base.addingTimeInterval(TimeInterval(startOffset)),
                end: base.addingTimeInterval(
                    TimeInterval(startOffset + duration)
                )
            )
            let detailID: String
            switch category {
            case "sleep": detailID = "sleep.core"
            case "movement": detailID = "movement.walking"
            default: detailID = "activity.rest"
            }
            return ActivityClassificationOverride(
                id: id,
                span: span,
                majorCategoryID: category,
                detailID: detailID,
                updatedAt: base.addingTimeInterval(
                    TimeInterval((index * 11) % 23)
                )
            )
        }
        let evidence = (0...240).map { offset in
            ActivitySensorEvidence(
                timestamp: base.addingTimeInterval(TimeInterval(offset)),
                motion: .walking
            )
        }
        let segments = ActivityClassificationEngine().classify(
            evidence,
            overrides: Array(overrides.reversed())
        )

        for sample in evidence {
            let expected = overrides
                .filter {
                    $0.span.start <= sample.timestamp
                        && sample.timestamp < $0.span.end
                }
                .sorted { lhs, rhs in
                    if lhs.isSleep != rhs.isSleep { return lhs.isSleep }
                    if lhs.updatedAt != rhs.updatedAt {
                        return lhs.updatedAt > rhs.updatedAt
                    }
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                .first?.majorCategoryID ?? "movement"
            let actual = segments.first {
                $0.span.start <= sample.timestamp
                    && sample.timestamp < $0.span.end
            }?.majorCategoryID
            XCTAssertEqual(actual, expected, "timestamp=\(sample.timestamp)")
        }
    }

    func testOverrideSplitsPreserveSampleCountAndProvenanceSpans() {
        let evidence = [
            ActivitySensorEvidence(timestamp: base, motion: .walking),
            ActivitySensorEvidence(timestamp: base.addingTimeInterval(1), motion: .stationary),
            ActivitySensorEvidence(timestamp: base.addingTimeInterval(2), motion: .walking),
            ActivitySensorEvidence(timestamp: base.addingTimeInterval(3), motion: .stationary),
        ]
        let override = ActivityClassificationOverride(
            span: ActivityTimeSpan(
                start: base.addingTimeInterval(0.5),
                end: base.addingTimeInterval(1.5)
            ),
            majorCategoryID: "sleep",
            detailID: "sleep.core"
        )

        let segments = ActivityClassificationEngine().classify(
            evidence,
            overrides: [override]
        )

        XCTAssertEqual(segments.reduce(0) { $0 + $1.sampleCount }, evidence.count)
        for segment in segments {
            XCTAssertEqual(segment.provenance.span, segment.span)
        }
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

    func testIncrementalTailReclassifiesStateFromPreviousTaxonomy() {
        let previousTaxonomy = ActivityTaxonomy(majors: [
            .init(
                id: "legacy",
                title: "이전 이동",
                systemImage: "figure.walk",
                details: [
                    .init(
                        id: "legacy.walking",
                        title: "이전 걷기",
                        behavior: "walking",
                        systemImage: "figure.walk"
                    )
                ]
            )
        ])
        let evidence = [0, 10].map {
            ActivitySensorEvidence(
                timestamp: base.addingTimeInterval(TimeInterval($0)),
                behaviorHint: "walking"
            )
        }
        let previousState = ActivityClassificationEngine(taxonomy: previousTaxonomy)
            .classifyState([evidence[0]])
        let currentEngine = ActivityClassificationEngine()

        let incremental = currentEngine.append([evidence[1]], to: previousState)
        let full = currentEngine.classifyState(evidence)

        XCTAssertEqual(incremental, full)
    }

    func testLegacyClassificationStateWithoutEngineIdentityDecodesSafely() throws {
        let engine = ActivityClassificationEngine()
        let evidence = [0, 10].map {
            ActivitySensorEvidence(
                timestamp: base.addingTimeInterval(TimeInterval($0)),
                motion: .walking
            )
        }
        let legacyState = ActivityClassificationState(
            evidence: [evidence[0]],
            overrides: [],
            segments: engine.classify([evidence[0]])
        )
        let data = try JSONEncoder().encode(legacyState)
        let decoded = try JSONDecoder().decode(ActivityClassificationState.self, from: data)

        let incremental = engine.append([evidence[1]], to: decoded)
        let full = engine.classifyState(evidence)

        XCTAssertEqual(incremental, full)
    }

    func testIncrementalTailReclassifiesStaleSegmentFromPersistedState() throws {
        let engine = ActivityClassificationEngine()
        let evidence = [0, 10].map {
            ActivitySensorEvidence(
                timestamp: base.addingTimeInterval(TimeInterval($0)),
                motion: .walking
            )
        }
        let valid = engine.classifyState([evidence[0]])
        let original = try XCTUnwrap(valid.segments.first)
        let staleSegment = ActivitySegment(
            id: original.id,
            span: original.span,
            majorCategoryID: "sleep",
            detailID: "sleep.core",
            title: "수면",
            behavior: "sleep",
            confidence: original.confidence,
            evidence: ["stale-persisted-segment"],
            sampleCount: original.sampleCount,
            isUserConfirmed: false
        )
        let staleState = ActivityClassificationState(
            evidence: valid.evidence,
            overrides: valid.overrides,
            segments: [staleSegment],
            engineIdentity: try XCTUnwrap(valid.engineIdentity)
        )

        let incremental = engine.append([evidence[1]], to: staleState)
        let full = engine.classifyState(evidence)

        XCTAssertEqual(incremental, full)
    }

    func testIncrementalTailRebuildsWhenOverrideSplitsLastSample() {
        let evidence = [0, 10, 20].map {
            ActivitySensorEvidence(
                timestamp: base.addingTimeInterval(TimeInterval($0)),
                motion: .walking
            )
        }
        let override = ActivityClassificationOverride(
            span: ActivityTimeSpan(
                start: base.addingTimeInterval(10.5),
                end: base.addingTimeInterval(11)
            ),
            majorCategoryID: "sleep",
            detailID: "sleep.core"
        )
        let engine = ActivityClassificationEngine()
        let prefix = engine.classifyState(
            Array(evidence.prefix(2)),
            overrides: [override]
        )

        let incremental = engine.append(
            [evidence[2]],
            to: prefix,
            overrides: [override]
        )
        let full = engine.classifyState(evidence, overrides: [override])

        XCTAssertEqual(incremental, full)
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

    func testFusionChoosesNearestThenUUIDOrderAndKeepsStableIDs() {
        let phoneID = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
        let tiedWatchID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
        let otherTiedWatchID = UUID(uuidString: "00000000-0000-0000-0000-000000000013")!
        let fartherWatchID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let phone = ActivitySensorEvidence(
            id: phoneID,
            timestamp: base,
            motion: .walking,
            source: .iPhone
        )
        let tiedWatch = ActivitySensorEvidence(
            id: tiedWatchID,
            timestamp: base.addingTimeInterval(0.25),
            motion: .walking,
            source: .appleWatch
        )
        let otherTiedWatch = ActivitySensorEvidence(
            id: otherTiedWatchID,
            timestamp: base.addingTimeInterval(0.25),
            motion: .walking,
            source: .appleWatch
        )
        let fartherWatch = ActivitySensorEvidence(
            id: fartherWatchID,
            timestamp: base.addingTimeInterval(0.5),
            motion: .walking,
            source: .appleWatch
        )

        let fused = ActivitySensorEvidenceFusion.fuse([
            fartherWatch,
            otherTiedWatch,
            phone,
            tiedWatch,
        ])
        let combinedID = ActivityStableID.uuid(
            seed: "combined|\(phoneID.uuidString)|\(tiedWatchID.uuidString)"
        )

        XCTAssertEqual(fused.map(\.id), [combinedID, otherTiedWatchID, fartherWatchID])
    }

    func testFusionMergeSortCancelsWithinBoundedWork() {
        let sampleCount = 4_096
        let evidence = (0..<sampleCount).reversed().map { index in
            ActivitySensorEvidence(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", index + 1))!,
                timestamp: base.addingTimeInterval(TimeInterval(index)),
                motion: .walking,
                source: .iPhone
            )
        }
        var operationCount = 0
        var cancellationOperationCount = 0

        XCTAssertThrowsError(
            try ActivitySensorEvidenceFusion.fuse(
                evidence,
                matchingWindow: 0,
                sweepOperationCount: &operationCount,
                cancellationCheck: { currentOperation in
                    if currentOperation > evidence.count {
                        cancellationOperationCount = currentOperation
                        throw CancellationError()
                    }
                }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertGreaterThan(cancellationOperationCount, evidence.count)
        XCTAssertLessThanOrEqual(cancellationOperationCount, evidence.count + 256)
        XCTAssertEqual(operationCount, cancellationOperationCount)
    }

    func testDenseUnmatchedFusionWorkIsBoundedWithMergeSort() {
        let sampleCount = 4_000
        let phones = (0..<sampleCount).map { index in
            ActivitySensorEvidence(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", index + 1))!,
                timestamp: base.addingTimeInterval(0.1),
                motion: .walking,
                source: .iPhone
            )
        }
        let watches = (0..<sampleCount).map { index in
            ActivitySensorEvidence(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", index + sampleCount + 1))!,
                timestamp: base.addingTimeInterval(0.2),
                motion: .walking,
                source: .appleWatch
            )
        }
        let evidence = phones + watches
        var sweepOperationCount = 0

        let fused = ActivitySensorEvidenceFusion.fuse(
            evidence,
            matchingWindow: 0,
            sweepOperationCount: &sweepOperationCount
        )

        XCTAssertEqual(fused.count, evidence.count)
        XCTAssertFalse(fused.contains { $0.source == .combined })
        XCTAssertLessThanOrEqual(sweepOperationCount, evidence.count * 40)
    }

    func testStableUUIDGoldenSeedsRemainUnchanged() {
        let phoneID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let watchID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
        let phone = ActivitySensorEvidence(
            id: phoneID,
            timestamp: base,
            motion: .walking,
            source: .iPhone
        )
        let watch = ActivitySensorEvidence(
            id: watchID,
            timestamp: base.addingTimeInterval(1),
            motion: .walking,
            source: .appleWatch
        )

        let segment = ActivityClassificationEngine().classify([phone]).first
        let combined = ActivitySensorEvidenceFusion.fuse([phone, watch]).first

        XCTAssertEqual(
            segment?.id,
            UUID(uuidString: "9b5bf018-6247-557c-b129-c6aa7533e852")
        )
        XCTAssertEqual(
            combined?.id,
            UUID(uuidString: "777a2099-e109-568b-ada1-282c2bcb85c7")
        )
        XCTAssertEqual(
            ActivityStableID.uuid(seed: "stable-seed-v1"),
            UUID(uuidString: "46136afc-5fda-58eb-8c66-92cffa210fae")
        )
    }

    func testWatchAndPhoneFusionScalesToLongRecording() {
        let evidence = (0..<5_000).flatMap { index in
            let timestamp = base.addingTimeInterval(Double(index * 3))
            return [
                ActivitySensorEvidence(
                    timestamp: timestamp,
                    motion: .walking,
                    source: .iPhone
                ),
                ActivitySensorEvidence(
                    timestamp: timestamp.addingTimeInterval(1),
                    motion: .walking,
                    source: .appleWatch
                ),
            ]
        }
        let startedAt = Date()

        let fused = ActivitySensorEvidenceFusion.fuse(evidence)

        XCTAssertEqual(fused.count, 5_000)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    }

    func testFusionRejectsInvalidTimestampButProjectionPreservesInput() {
        let invalid = ActivitySensorEvidence(
            timestamp: Date(timeIntervalSinceReferenceDate: 1e100),
            motion: .stationary,
            source: .appleWatch
        )
        let phone = ActivitySensorEvidence(
            timestamp: base,
            motion: .walking,
            source: .iPhone
        )

        let fused = ActivitySensorEvidenceFusion.fuse(
            [invalid, phone],
            matchingWindow: .nan
        )

        XCTAssertEqual(fused.map(\.id), [phone.id])
        XCTAssertFalse(fused.contains { $0.source == .combined })
        XCTAssertEqual(
            ActivityClassificationProjection(
                evidence: [invalid, phone]
            ).inputEvidence.map(\.id),
            [invalid.id, phone.id]
        )
    }

    func testClassificationRejectsNonFiniteAndOutOfRangeTimestampsBeforeOrdering() {
        let invalidTimestamps: [TimeInterval] = [.nan, .infinity, -.infinity, 1e100]
        let invalidEvidence = invalidTimestamps.enumerated().map { item in
            let (index, timestamp) = item
            return ActivitySensorEvidence(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", index + 1))!,
                timestamp: Date(timeIntervalSinceReferenceDate: timestamp),
                motion: .walking
            )
        }
        let valid = ActivitySensorEvidence(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!,
            timestamp: base,
            motion: .walking
        )
        let engine = ActivityClassificationEngine()

        XCTAssertEqual(engine.normalize(invalidEvidence + [valid]).map(\.id), [valid.id])
        XCTAssertEqual(engine.classify(invalidEvidence + [valid]).map(\.sampleCount), [1])

        let invalidSpan = ActivityClassificationOverride(
            span: ActivityTimeSpan(
                start: base,
                end: Date(timeIntervalSinceReferenceDate: .infinity)
            ),
            majorCategoryID: "sleep"
        )
        let invalidUpdateTime = ActivityClassificationOverride(
            span: ActivityTimeSpan(start: base, end: base.addingTimeInterval(10)),
            majorCategoryID: "sleep",
            updatedAt: Date(timeIntervalSinceReferenceDate: .nan)
        )
        XCTAssertTrue(
            engine.classifyState(
                [valid],
                overrides: [invalidSpan, invalidUpdateTime]
            ).overrides.isEmpty
        )
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

    func testGapInferenceRejectsOutOfRangeSpanAndInvalidEvidenceTime() {
        let engine = ActivityGapInferenceEngine()
        let validSpan = ActivityTimeSpan(
            start: base,
            end: base.addingTimeInterval(10 * 60)
        )
        let walking = ActivitySensorEvidence(
            timestamp: base.addingTimeInterval(60),
            motion: .walking,
            speedMetersPerSecond: 1.4,
            isPreciseLocation: true
        )
        let invalidEvidence = ActivitySensorEvidence(
            timestamp: Date(timeIntervalSinceReferenceDate: .nan),
            motion: .automotive,
            speedMetersPerSecond: 20
        )

        XCTAssertEqual(
            engine.infer(.init(span: validSpan, evidence: [walking, invalidEvidence])),
            engine.infer(.init(span: validSpan, evidence: [walking]))
        )
        XCTAssertTrue(engine.infer(.init(
            span: ActivityTimeSpan(
                start: Date(timeIntervalSinceReferenceDate: .nan),
                end: base
            ),
            evidence: [walking]
        )).isEmpty)
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

    func testSleepInferenceIgnoresInvalidTimestampsBeforeSorting() {
        let valid = stride(from: 0, through: 5 * 60, by: 60).map { minute in
            SleepRuleSample(
                timestamp: base.addingTimeInterval(TimeInterval(minute)),
                screenIsOn: false,
                inactivityDuration: 30 * 60,
                distanceFromHomeMeters: 40,
                ambientIsDark: true,
                isCharging: true
            )
        }
        let invalidWake = SleepRuleSample(
            timestamp: Date(timeIntervalSinceReferenceDate: .nan),
            screenIsOn: true,
            phoneMoved: true,
            ambientIsDark: false,
            userWakeActivity: true
        )
        let engine = SleepInferenceEngine()

        XCTAssertEqual(engine.infer(valid + [invalidWake]).state, .asleep)
        XCTAssertEqual(
            engine.infer([invalidWake]).state,
            .insufficientEvidence
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

private final class ClassificationCancellationGate: @unchecked Sendable {
    private let phase: ActivityClassificationWorkPhase
    private let checkpoint: Int
    private let lock = NSLock()
    private let reached = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private var checkpoints = 0

    init(phase: ActivityClassificationWorkPhase, checkpoint: Int) {
        self.phase = phase
        self.checkpoint = checkpoint
    }

    var observedCheckpoints: Int {
        lock.lock()
        defer { lock.unlock() }
        return checkpoints
    }

    func waitUntilReached() -> Bool {
        reached.wait(timeout: .now() + .seconds(15)) == .success
    }

    func resume() {
        release.signal()
    }

    func check(_ currentPhase: ActivityClassificationWorkPhase) throws {
        guard currentPhase == phase else {
            try Task.checkCancellation()
            return
        }

        lock.lock()
        checkpoints += 1
        let shouldPause = checkpoints == checkpoint
        lock.unlock()

        if shouldPause {
            reached.signal()
            release.wait()
        }
        try Task.checkCancellation()
    }
}

private final class ClassificationStartGate: @unchecked Sendable {
    private let ready = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)

    func waitBeforeWork() {
        ready.signal()
        resume.wait()
    }

    func waitUntilReady() -> Bool {
        ready.wait(timeout: .now() + .seconds(15)) == .success
    }

    func resumeWork() {
        resume.signal()
    }
}
