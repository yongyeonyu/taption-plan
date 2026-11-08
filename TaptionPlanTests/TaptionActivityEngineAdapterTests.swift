import Foundation
import Testing
import XCTest
import TaptionActivityEngine
import TaptionPlanCore
@testable import TaptionPlan

struct TaptionActivityEngineAdapterTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func reading(
        _ seconds: TimeInterval,
        motion: MotionKind = .walking,
        behavior: String? = nil,
        sourceDevice: TrackingDevice? = nil
    ) -> SensorReading {
        SensorReading(
            timestamp: base.addingTimeInterval(seconds),
            motion: motion,
            behavior: behavior,
            behaviorConfidenceScore: behavior == nil ? nil : 0.9,
            behaviorEvidence: behavior == nil ? nil : ["Watch"],
            sourceDevice: sourceDevice
        )
    }

    private func travelSegment(
        _ mode: TravelMode,
        _ start: TimeInterval,
        _ end: TimeInterval
    ) -> TravelSegment {
        travelSegment(
            mode,
            span: TimeSpan(
                start: base.addingTimeInterval(start),
                end: base.addingTimeInterval(end)
            )
        )
    }

    private func travelSegment(_ mode: TravelMode, span: TimeSpan) -> TravelSegment {
        TravelSegment(
            mode: mode,
            span: span,
            distanceMeters: 0,
            confidence: .high,
            evidence: []
        )
    }

    @Test func mapsDetailedAndMajorActivityTaxonomy() {
        let result = TaptionActivityEngineAdapter.classify(
            readings: [reading(0, motion: .walking)],
            travel: []
        )
        #expect(result.segments.first?.detailID == "movement.walking")
        #expect(result.segments.first?.majorCategoryID == "movement")
        #expect(result.majorCategoryIDs == ["movement"])
    }

    @Test func classifiedActivityUsesOnlyReadingsInsideRequestedSpan() {
        let span = TimeSpan(
            start: base,
            end: base.addingTimeInterval(10 * 60)
        )
        let outsideBefore = SensorReading(
            timestamp: base.addingTimeInterval(-0.5),
            motion: .walking,
            gpsAvailable: false,
            behavior: "walking",
            behaviorConfidenceScore: 0.1,
            behaviorEvidence: ["outside-before"]
        )
        let outsideAtEnd = SensorReading(
            timestamp: span.end,
            motion: .walking,
            gpsAvailable: false,
            behavior: "walking",
            behaviorConfidenceScore: 0.1,
            behaviorEvidence: ["outside-at-end"]
        )
        let readings = [outsideBefore]
            + (0...9).map { reading(Double($0 * 60), motion: .walking, behavior: "walking") }
            + [reading(599, motion: .walking, behavior: "walking")]
            + [outsideAtEnd]

        let actuals = TaptionActivityEngineAdapter.classifiedActivityActuals(
            readings: readings,
            travel: [],
            corrections: [:],
            actuals: [],
            inside: span,
            createdAt: base
        )

        #expect(actuals.count == 1)
        #expect(actuals.first?.startedAt == span.start)
        #expect(actuals.first?.confidence.rawValue == "high")
        #expect(actuals.first?.evidence.contains("outside-before") == false)
        #expect(actuals.first?.evidence.contains("outside-at-end") == false)
    }

    @Test func watchAndIPhoneEvidenceIsCombinedBeforeMajorProjection() {
        let result = TaptionActivityEngineAdapter.classify(
            readings: [
                reading(0, motion: .walking, behavior: "walking", sourceDevice: .iPhone),
                reading(1, motion: .stationary, behavior: "sleep", sourceDevice: .appleWatch)
            ]
        )

        #expect(result.state.evidence.count == 1)
        #expect(result.state.evidence.first?.source == .combined)
        #expect(result.segments.first?.majorCategoryID == "sleep")
    }

    @Test func movementMethodRequiresTravelAlgorithmResult() {
        let watchTransitHint = [
            reading(0, motion: .stationary, behavior: "subway", sourceDevice: .appleWatch)
        ]
        let withoutTravel = TaptionActivityEngineAdapter.classify(readings: watchTransitHint)
        #expect(withoutTravel.segments.first?.majorCategoryID == "activity")

        let travel = TravelSegment(
            mode: .subway,
            span: TimeSpan(start: base, end: base.addingTimeInterval(60)),
            distanceMeters: 1_000,
            confidence: .high,
            evidence: ["이동 알고리즘"]
        )
        let withTravel = TaptionActivityEngineAdapter.classify(
            readings: watchTransitHint,
            travel: [travel]
        )
        #expect(withTravel.segments.first?.detailID == "movement.subway")
    }

    @Test func evidenceTravelLookupPreservesFirstMatchAndInclusiveBoundaries() {
        let travel = [
            travelSegment(.subway, 0, 10),
            travelSegment(.bus, 5, 15),
            travelSegment(.walking, 10, 20),
            travelSegment(
                .running,
                span: TimeSpan(
                    start: Date(timeIntervalSinceReferenceDate: .nan),
                    end: base.addingTimeInterval(30)
                )
            ),
            travelSegment(
                .cycling,
                span: TimeSpan(
                    start: base.addingTimeInterval(30),
                    end: Date(timeIntervalSinceReferenceDate: .nan)
                )
            )
        ]
        let invalidTimestamp = SensorReading(
            timestamp: Date(timeIntervalSinceReferenceDate: .nan)
        )
        let readings = [
            reading(15),
            reading(0),
            reading(10),
            reading(-1),
            reading(20),
            reading(21),
            reading(31),
            invalidTimestamp
        ]

        let evidence = TaptionActivityEngineAdapter.evidence(
            from: readings,
            travel: travel
        )
        let indexedMatches = TaptionActivityEngineAdapter.matchingTravelIndices(
            for: readings,
            travel: travel
        )
        let referenceMatches = readings.map { reading in
            travel.firstIndex { $0.span.contains(reading.timestamp) }
        }

        #expect(evidence.map(\.id) == readings.map(\.id))
        #expect(indexedMatches.indices == referenceMatches)
        // NaN 시각과 NaN 경계 구간은 어떤 구간에도 매칭되지 않는다(기기·시뮬레이터 공통 규칙).
        #expect(referenceMatches == [1, 0, 0, nil, 2, nil, nil, nil])
        #expect(evidence.map(\.detailHint) == [
            "movement.bus",
            "movement.subway",
            "movement.subway",
            nil,
            "movement.walking",
            nil,
            nil,
            nil
        ])
        #expect(evidence.map(\.categoryHint) == [
            "movement", "movement", "movement", nil,
            "movement", nil, nil, nil
        ])
    }

    @Test func evidenceTravelLookupWorkIsBoundedForDenseDay() {
        let travel = (0..<4_000).reversed().map { index in
            travelSegment(.walking, TimeInterval(index), 10_000)
        }
        let readings = (0..<8_000).map { reading(TimeInterval($0) * 0.5) }
            + [reading(10_001)]

        let result = TaptionActivityEngineAdapter.matchingTravelIndices(
            for: readings,
            travel: travel
        )

        #expect(result.indices.count == readings.count)
        #expect(result.indices.first == 3_999)
        #expect(result.indices[readings.count - 2] == 0)
        #expect(result.indices[readings.count - 1] == nil)
        #expect(result.operationCount < (readings.count + travel.count) * 30)
    }

    @Test func evidenceGenerationPropagatesCancellationDuringReadingProjection() {
        let readings = (0..<1_024).map { reading(TimeInterval($0)) }
        var checks = 0
        var didCancel = false

        do {
            _ = try TaptionActivityEngineAdapter.evidence(
                from: readings,
                travel: [],
                cancellationCheck: {
                    checks += 1
                    if checks == 9 { throw CancellationError() }
                }
            )
        } catch is CancellationError {
            didCancel = true
        } catch {
            Issue.record("Unexpected evidence error: \(error)")
        }

        #expect(didCancel)
        #expect(checks == 9)
    }

    @Test func travelIndexSortPropagatesCancellationWithinBoundedWork() {
        let readings = [reading(0)]
        let travel = (0..<4_096).reversed().map { index in
            travelSegment(.walking, TimeInterval(index), 10_000)
        }
        var checks = 0
        var didCancel = false

        do {
            _ = try TaptionActivityEngineAdapter.matchingTravelIndices(
                for: readings,
                travel: travel,
                cancellationCheck: {
                    checks += 1
                    if checks == 36 { throw CancellationError() }
                }
            )
        } catch is CancellationError {
            didCancel = true
        } catch {
            Issue.record("Unexpected travel indexing error: \(error)")
        }

        #expect(didCancel)
        #expect(checks == 36)
    }

    @Test func missingLocationQualityIsNotAutomaticallyPrecise() {
        let value = SensorReading(
            timestamp: base,
            point: nil,
            locationFixQuality: nil,
            gpsAvailable: false
        )

        let evidence = TaptionActivityEngineAdapter.evidence(from: [value])

        #expect(evidence.first?.isPreciseLocation == false)
    }

    @Test func unavailableGPSDoesNotBecomePreciseFromQualityLabel() {
        let value = SensorReading(
            timestamp: base,
            point: GeoPoint(
                latitude: 37,
                longitude: 127,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            ),
            locationFixQuality: .precise,
            gpsAvailable: false
        )

        let evidence = TaptionActivityEngineAdapter.evidence(from: [value])

        #expect(evidence.first?.isPreciseLocation == false)
    }

    @Test func qualityProjectionRejectsScalarSpikeWithoutMutatingRawReadings() {
        let readings = (0..<7).map { index in
            SensorReading(
                timestamp: base.addingTimeInterval(TimeInterval(index)),
                point: GeoPoint(
                    latitude: 37 + Double(index) * 0.00001,
                    longitude: 126,
                    altitude: 0,
                    horizontalAccuracy: 5,
                    verticalAccuracy: 5
                ),
                locationFixQuality: .precise,
                speedMetersPerSecond: index == 3 ? 90 : 1,
                gpsAvailable: true
            )
        }
        let original = readings

        let projection = TaptionActivityEngineAdapter.qualityProjection(from: readings)

        #expect(readings == original)
        #expect(projection.readings[3].speedMetersPerSecond == nil)
        #expect(projection.rejectionCounts["speed.isolatedOutlier"] == 1)
        #expect(!projection.routeReadings.isEmpty)
    }

    @Test func qualityProjectionSeparatesLocationRejectionsFromScalarRejections() {
        let readings = [37.0, 34, 37.0001].enumerated().map { index, latitude in
            SensorReading(
                timestamp: base.addingTimeInterval(Double(index)),
                point: GeoPoint(latitude: latitude, longitude: 126, altitude: 0,
                                horizontalAccuracy: 5, verticalAccuracy: 5),
                locationFixQuality: .precise, motion: .walking, gpsAvailable: true
            )
        }

        let projection = TaptionActivityEngineAdapter.qualityProjection(from: readings)

        #expect(projection.readings == readings)
        #expect(projection.rejectionCounts.isEmpty)
        #expect(projection.impossibleLocationCount == 1)
        #expect(projection.innovationOutlierCount == 0)
        #expect(!projection.routeReadings.contains { $0.id == readings[1].id })
    }

    @Test func qualityProjectionRetainsStationaryEndForPlaceInference() {
        let readings = stride(from: 0.0, through: 1_800.0, by: 30).map { seconds in
            SensorReading(
                timestamp: base.addingTimeInterval(seconds),
                point: GeoPoint(latitude: 37, longitude: 126, altitude: 0,
                                horizontalAccuracy: 5, verticalAccuracy: 5),
                locationFixQuality: .precise, motion: .stationary, gpsAvailable: true
            )
        }
        let projection = TaptionActivityEngineAdapter.qualityProjection(from: readings)
        #expect(projection.readings == readings)
        #expect(projection.routeReadings.map(\.timestamp)
                == [0.0, 900, 1_800].map { base.addingTimeInterval($0) })
        #expect(projection.routeReadings.allSatisfy { $0.point?.latitude == 37 })
    }

    @Test func qualityProjectionDropsInvalidTimestampsBeforeOrdering() {
        let valid = (0..<7).map { index in
            SensorReading(
                timestamp: base.addingTimeInterval(TimeInterval(index)),
                speedMetersPerSecond: 1,
                gpsAvailable: false
            )
        }
        let invalid = SensorReading(
            timestamp: Date(timeIntervalSinceReferenceDate: .nan),
            speedMetersPerSecond: 90,
            gpsAvailable: false
        )

        let projection = TaptionActivityEngineAdapter.qualityProjection(
            from: [invalid] + valid
        )

        #expect(projection.readings.map(\.id) == valid.map(\.id))
    }

    @Test func qualityProjectionPropagatesCancellationDuringSort() {
        let readings = (0..<1_024).map { reading(TimeInterval($0)) }
        var checks = 0
        var didCancel = false

        do {
            _ = try TaptionActivityEngineAdapter.qualityProjection(
                from: readings,
                cancellationCheck: {
                    checks += 1
                    if checks == 9 { throw CancellationError() }
                }
            )
        } catch is CancellationError {
            didCancel = true
        } catch {
            Issue.record("Unexpected projection error: \(error)")
        }

        #expect(didCancel)
        #expect(checks == 9)
    }

    @Test func qualityDecisionScanChecksCancellationWithoutRejections() {
        let decisions = (0..<1_024).map {
            TaptionScalarQualityDecision(
                index: $0,
                acceptedValue: 1,
                reason: nil
            )
        }
        var checks = 0
        var didCancel = false

        do {
            try TaptionActivityEngineAdapter.forEachRejectedQualityDecision(
                decisions,
                cancellationCheck: {
                    checks += 1
                    if checks == 2 { throw CancellationError() }
                },
                apply: { _ in Issue.record("No decision should be rejected") }
            )
        } catch is CancellationError {
            didCancel = true
        } catch {
            Issue.record("Unexpected quality decision error: \(error)")
        }

        #expect(didCancel)
        #expect(checks == 2)
    }

    @Test func dataTrustSeparatesRawPreciseSupportingAndExpectedRecords() {
        let precise = SensorReading(
            timestamp: base,
            point: GeoPoint(
                latitude: 37,
                longitude: 127,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            ),
            locationFixQuality: .precise,
            gpsAvailable: true
        )
        let supporting = SensorReading(
            timestamp: base.addingTimeInterval(60),
            point: GeoPoint(
                latitude: 37.001,
                longitude: 127,
                altitude: 0,
                horizontalAccuracy: 250,
                verticalAccuracy: 100
            ),
            locationFixQuality: .approximate,
            gpsAvailable: false
        )
        let automatic = ActualRecord(
            planID: nil,
            title: "활동",
            categoryID: "activity",
            startedAt: base,
            endedAt: base.addingTimeInterval(60),
            source: .motion,
            confidence: .high
        )
        let manual = ActualRecord(
            planID: nil,
            title: "사용자 기록",
            categoryID: "activity",
            startedAt: base.addingTimeInterval(60),
            endedAt: base.addingTimeInterval(120),
            source: .manual,
            confidence: .high
        )

        let projection = TaptionActivityEngineAdapter.dataTrustProjection(
            readings: [precise, supporting],
            actuals: [automatic, manual],
            places: [],
            travel: []
        )

        #expect(projection.rawReadings.count == 2)
        #expect(projection.filteredGPSReadings.count == 1)
        #expect(projection.supportingReadings == [supporting])
        #expect(projection.actuals[automatic.id]?.tier == .expected)
        #expect(projection.actuals[automatic.id]?.status == .automaticallyConfirmed)
        #expect(projection.actuals[manual.id]?.tier == .groundTruth)
        #expect(projection.actuals[manual.id]?.status == .userCorrected)
        #expect(TaptionActivityEngineAdapter.trustLabel(for: supporting) == "보조 데이터")
    }

    @Test func registeredPlaceActivityUsesPlaceInferenceWithoutReplacingPlaceRecord() {
        let stay = PlaceStay(
            placeKey: "frequent-company",
            displayName: "회사",
            span: TimeSpan(start: base, end: base.addingTimeInterval(15 * 60)),
            confidence: .high,
            point: GeoPoint(
                latitude: 37,
                longitude: 127,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            )
        )

        let actual = TaptionActivityEngineAdapter.placeActivityActual(
            for: stay,
            registeredKind: .company,
            inside: stay.span
        )

        #expect(actual?.categoryID == "work")
        #expect(actual?.modelVersion == "classifier-v1/place")
        #expect(actual.map { TaptionActivityEngineAdapter.trustLabel(for: $0) } == "예상 데이터 · 자동확정")
    }

    @Test func inferredGapRecordsStayOutsideConfirmedSleep() {
        let sleep = ActualRecord(
            planID: nil,
            title: "수면",
            categoryID: "sleep",
            startedAt: base,
            endedAt: base.addingTimeInterval(60),
            source: .manual,
            behavior: "core",
            manuallyCorrected: true
        )
        let reading = SensorReading(
            timestamp: base.addingTimeInterval(120),
            motion: .walking,
            gpsAvailable: false
        )
        let span = TimeSpan(start: base, end: base.addingTimeInterval(10 * 60))

        let inferred = TaptionActivityEngineAdapter.inferredGapActuals(
            readings: [reading],
            travel: [],
            actuals: [sleep],
            inside: span,
            createdAt: base
        )

        #expect(!inferred.isEmpty)
        #expect(inferred.allSatisfy { $0.startedAt >= sleep.endedAt! })
        #expect(inferred.allSatisfy { $0.modelVersion == TaptionActivityEngineAdapter.inferredGapModelVersion })
    }

    @Test func lockedAutomaticMajorCategorySurvivesSensorRefresh() {
        let locked = ActualRecord(
            planID: nil,
            title: "업무",
            categoryID: "work",
            startedAt: base,
            endedAt: base.addingTimeInterval(60),
            source: .motion,
            behavior: "work",
            isClassificationLocked: true
        )
        let result = TaptionActivityEngineAdapter.classify(
            readings: [reading(0, motion: .walking)],
            actuals: [locked]
        )

        #expect(result.segments.first?.majorCategoryID == "work")
        #expect(result.state.overrides.first?.isLocked == true)
    }

    @Test func confirmedSleepSurvivesChangedActualUUIDAndSplitsAutomaticActivity() {
        let oldID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let newID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let correction = ActivityCorrection(
            title: "수면",
            behavior: "core",
            categoryID: "sleep",
            startedAt: base.addingTimeInterval(30),
            endedAt: base.addingTimeInterval(90)
        )
        let automatic = ActualRecord(
            id: newID,
            planID: nil,
            title: "걷기",
            categoryID: "movement",
            startedAt: base,
            endedAt: base.addingTimeInterval(120),
            source: .motion,
            confidence: .medium
        )
        let overrides = TaptionActivityEngineAdapter.confirmedSleepOverrides(
            corrections: [oldID: correction],
            actuals: [automatic]
        )
        #expect(overrides.count == 1)
        let corrected = TaptionActivityEngineAdapter.applyingConfirmedSleepOverrides(
            to: [automatic],
            corrections: [oldID: correction]
        )
        #expect(corrected.count == 3)
        #expect(corrected.contains { $0.categoryID == "sleep" && $0.startedAt == base.addingTimeInterval(30) })
        #expect(corrected.filter { $0.categoryID == "sleep" }.allSatisfy { $0.manuallyCorrected })
    }

    @Test func stableManualRecordIDIgnoresCreationDate() {
        let span = TimeSpan(start: base, end: base.addingTimeInterval(60))
        let option = ActivityCorrectionOption(
            id: "detail.movement.walking",
            title: "걷기",
            behavior: "walking",
            categoryID: "movement",
            systemImage: "figure.walk",
            isAutomatic: false,
            isCustom: false
        )
        let first = TaptionActivityEngineAdapter.makeStableManualActual(
            span: span,
            option: option,
            createdAt: base
        )
        let second = TaptionActivityEngineAdapter.makeStableManualActual(
            span: span,
            option: option,
            createdAt: base.addingTimeInterval(100)
        )
        #expect(first.id == second.id)
        #expect(first.source == .manual)
        #expect(first.manuallyCorrected)
    }

    @Test func confirmedSleepSpansNormalizeAndLeaveOneStableManualRecord() {
        let automaticID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let spans = [
            TimeSpan(start: base.addingTimeInterval(30), end: base.addingTimeInterval(90)),
            TimeSpan(start: base.addingTimeInterval(60), end: base.addingTimeInterval(120)),
            TimeSpan(start: base.addingTimeInterval(120), end: base.addingTimeInterval(150))
        ]
        let automatic = ActualRecord(
            id: automaticID,
            planID: nil,
            title: "활동",
            categoryID: "activity",
            startedAt: base,
            endedAt: base.addingTimeInterval(180),
            source: .motion,
            confidence: .medium
        )
        let first = TaptionActivityEngineAdapter.applyingConfirmedSleepSpans(
            spans,
            to: [automatic],
            createdAt: base
        )
        let sleeps = first.filter { $0.modelVersion == TaptionActivityEngineAdapter.confirmedSleepModelVersion }
        #expect(sleeps.count == 1)
        #expect(sleeps[0].startedAt == base.addingTimeInterval(30))
        #expect(sleeps[0].endedAt == base.addingTimeInterval(150))
        #expect(sleeps[0].source == .manual)
        #expect(sleeps[0].manuallyCorrected)
        #expect(TaptionActivityEngineAdapter.confirmedSleepOverrides(spans).count == 1)

        let second = TaptionActivityEngineAdapter.applyingConfirmedSleepSpans(
            spans.shuffled(),
            to: first,
            createdAt: base.addingTimeInterval(300)
        )
        let secondSleeps = second.filter { $0.modelVersion == TaptionActivityEngineAdapter.confirmedSleepModelVersion }
        #expect(secondSleeps.count == 1)
        #expect(secondSleeps[0].id == sleeps[0].id)
        #expect(secondSleeps[0].createdAt == sleeps[0].createdAt)
    }

    @Test func confirmedSleepEditSubtractsOldSpanAndAddsOnlyNewSleepSlice() {
        let original = TimeSpan(
            start: base.addingTimeInterval(30),
            end: base.addingTimeInterval(150)
        )
        let withoutEditedPart = ConfirmedSleepSpanEditor.replacing(
            [original],
            removing: [
                TimeSpan(
                    start: base.addingTimeInterval(60),
                    end: base.addingTimeInterval(90)
                )
            ]
        )
        #expect(withoutEditedPart == [
            TimeSpan(
                start: base.addingTimeInterval(30),
                end: base.addingTimeInterval(60)
            ),
            TimeSpan(
                start: base.addingTimeInterval(90),
                end: base.addingTimeInterval(150)
            )
        ])

        let replaced = ConfirmedSleepSpanEditor.replacing(
            [original],
            removing: [
                TimeSpan(
                    start: base.addingTimeInterval(60),
                    end: base.addingTimeInterval(90)
                )
            ],
            adding: [
                TimeSpan(
                    start: base.addingTimeInterval(60),
                    end: base.addingTimeInterval(75)
                )
            ]
        )
        #expect(replaced == [
            TimeSpan(
                start: base.addingTimeInterval(30),
                end: base.addingTimeInterval(75)
            ),
            TimeSpan(
                start: base.addingTimeInterval(90),
                end: base.addingTimeInterval(150)
            )
        ])
    }

    @Test func applyingEmptyConfirmedSleepSpansRemovesStaleCanonicalRecord() {
        let sleep = TaptionActivityEngineAdapter.confirmedSleepActuals([
            TimeSpan(start: base, end: base.addingTimeInterval(60))
        ])
        let result = TaptionActivityEngineAdapter.applyingConfirmedSleepSpans(
            [],
            to: sleep
        )
        #expect(result.isEmpty)
    }

    @Test func migratesLegacySleepCorrectionsBeforeActualUUIDChanges() {
        let span = TimeSpan(
            start: base.addingTimeInterval(30),
            end: base.addingTimeInterval(90)
        )
        let oldID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let correction = ActivityCorrection(
            title: "수면",
            behavior: "core",
            categoryID: "sleep",
            startedAt: span.start,
            endedAt: span.end
        )
        let migrated = TaptionActivityEngineAdapter.migratedConfirmedSleepSpans(
            existing: [],
            corrections: [oldID: correction],
            actuals: []
        )
        #expect(migrated == [span])

        let preserved = TaptionActivityEngineAdapter.migratedConfirmedSleepSpans(
            existing: [
                TimeSpan(
                    start: base.addingTimeInterval(30),
                    end: base.addingTimeInterval(60)
                )
            ],
            corrections: [oldID: correction],
            actuals: []
        )
        #expect(preserved == [
            TimeSpan(
                start: base.addingTimeInterval(30),
                end: base.addingTimeInterval(60)
            )
        ])

        let actual = ActualRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000100")!,
            planID: nil,
            title: "수면",
            categoryID: "sleep",
            startedAt: base.addingTimeInterval(120),
            endedAt: base.addingTimeInterval(180),
            source: .manual,
            manuallyCorrected: true
        )
        let fromActual = TaptionActivityEngineAdapter.migratedConfirmedSleepSpans(
            existing: [],
            corrections: [:],
            actuals: [actual]
        )
        #expect(fromActual == [
            TimeSpan(start: base.addingTimeInterval(120), end: base.addingTimeInterval(180))
        ])
    }

    // MARK: - Watch-less sleep gate (SLP0922S01)

    private func sleepReading(
        _ seconds: TimeInterval,
        screenIsOn: Bool? = false,
        screenBrightness: Double? = nil,
        charging: Bool = false,
        motion: MotionKind = .stationary,
        stepCount: Int? = 0,
        homeDistanceLat: Double = 37.5
    ) -> SensorReading {
        SensorReading(
            timestamp: base.addingTimeInterval(seconds),
            point: GeoPoint(
                latitude: homeDistanceLat,
                longitude: 127.0,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            ),
            motion: motion,
            stepCount: stepCount,
            powerState: charging ? .charging : .unplugged,
            screenBrightness: screenBrightness,
            screenIsOn: screenIsOn
        )
    }

    /// 화면 꺼짐(밝기 nil)·집에 있음·무충전이면 예전에는 보조조건 3개 요구로
    /// 워치리스 수면이 절대 성립하지 않았다. 화면 꺼짐을 어두움 근거로 인정하고
    /// 요구치를 2로 낮춘 뒤에는 수면(source .motion)이 생성돼야 한다.
    @Test func watchlessSleepFiresWhenScreenOffAtHomeWithoutCharger() {
        let home = GeoPoint(
            latitude: 37.5, longitude: 127.0,
            altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5
        )
        let readings = stride(from: 0.0, through: 40 * 60, by: 60).map {
            sleepReading($0)
        }
        let span = TimeSpan(
            start: base,
            end: base.addingTimeInterval(45 * 60)
        )
        let records = TaptionActivityEngineAdapter.strictSleepActuals(
            readings: readings,
            actuals: [],
            inside: span,
            homePoint: home,
            maximumSampleGap: 20 * 60,
            asOf: base.addingTimeInterval(60 * 60)
        )
        #expect(records.contains { $0.categoryID == "sleep" && $0.source == .motion })
    }

    /// 이동·화면 켜짐이 섞이면 여전히 수면으로 판정하지 않는다(과확정 방지).
    @Test func watchlessSleepStaysEmptyWhenPhoneIsUsedAndMoving() {
        let home = GeoPoint(
            latitude: 37.5, longitude: 127.0,
            altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5
        )
        let readings = stride(from: 0.0, through: 40 * 60, by: 60).map {
            sleepReading(
                $0,
                screenIsOn: true,
                screenBrightness: 0.8,
                motion: .walking,
                stepCount: 30
            )
        }
        let span = TimeSpan(
            start: base,
            end: base.addingTimeInterval(45 * 60)
        )
        let records = TaptionActivityEngineAdapter.strictSleepActuals(
            readings: readings,
            actuals: [],
            inside: span,
            homePoint: home,
            maximumSampleGap: 20 * 60,
            asOf: base.addingTimeInterval(60 * 60)
        )
        #expect(records.isEmpty)
    }
}

/// 분류 파이프라인 재계산 이행(ALG1101A01).
final class ClassifierMigrationTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private final class Markers: ClassificationRecomputeMarkerStore, @unchecked Sendable {
        var keys = Set<String>()
        func isCompleted(_ key: String) async -> Bool { keys.contains(key) }
        func markCompleted(_ key: String, outcome: String) async { keys.insert(key) }
    }

    private func automatic(_ title: String, minutes: Double, evidence: [String] = [], manuallyCorrected: Bool = false) -> ActualRecord {
        ActualRecord(
            planID: nil, title: title, categoryID: "activity",
            startedAt: start.addingTimeInterval(minutes * 60), endedAt: start.addingTimeInterval((minutes + 30) * 60),
            source: .motion, evidence: evidence, modelVersion: "motion-v1", manuallyCorrected: manuallyCorrected
        )
    }

    func testLegacyJSONWithoutNewFieldsDecodesAndReencodesByteIdentical() throws {
        let legacy = automatic("걷기", minutes: 0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(legacy)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("lockReason"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("classificationScore"))
        let decoded = try JSONDecoder().decode(ActualRecord.self, from: data)
        XCTAssertNil(decoded.lockReason)
        XCTAssertNil(decoded.classificationScore)
        XCTAssertTrue(decoded.isClassificationLocked)
        XCTAssertEqual(try encoder.encode(decoded), data)
        XCTAssertTrue(PlanActualStorage.exactlyEqual([decoded][...], [legacy][...]))
    }

    func testNewFieldsRoundTrip() throws {
        var record = automatic("버스", minutes: 0)
        record.classificationScore = 0.82
        record.lockReason = .user
        let decoded = try JSONDecoder().decode(ActualRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded.classificationScore, 0.82)
        XCTAssertEqual(decoded.lockReason, .user)
    }

    func testUserOwnedCoversManualCorrectionTableAndEvidenceFallback() {
        var manual = automatic("회의", minutes: 0)
        manual.source = .manual
        XCTAssertTrue(ActualRecord.userOwned(manual))
        XCTAssertTrue(ActualRecord.userOwned(automatic("걷기", minutes: 0, manuallyCorrected: true)))
        XCTAssertTrue(ActualRecord.userOwned(automatic("걷기", minutes: 0, evidence: ["사용자 교정"])))
        let corrected = automatic("걷기", minutes: 0)
        XCTAssertTrue(ActualRecord.userOwned(corrected, activityCorrections: [
            corrected.id: ActivityCorrection(title: "업무", categoryID: "work"),
        ]))
        XCTAssertFalse(ActualRecord.userOwned(automatic("걷기", minutes: 0)))
    }

    func testReleasingStabilityLocksKeepsUserRecordsByteIdentical() {
        let user = automatic("업무", minutes: 0, manuallyCorrected: true)
        let auto = automatic("걷기", minutes: 60)
        let outside = automatic("걷기", minutes: 3 * 24 * 60)
        let span = TimeSpan(start: start, end: start.addingTimeInterval(86_400))
        let result = ActivityClassificationLockEngine.releasingStabilityLocks(
            [user, auto, outside], inside: span, activityCorrections: [:]
        )
        XCTAssertEqual(result.released, 1)
        XCTAssertTrue(PlanActualStorage.exactlyEqual([result.records[0]][...], [user][...]))
        XCTAssertFalse(result.records[1].isClassificationLocked)
        XCTAssertTrue(PlanActualStorage.exactlyEqual([result.records[2]][...], [outside][...]))
    }

    func testFreshLockRecordsStabilityReasonAndKeepsUserReason() {
        let span = TimeSpan(start: start, end: start.addingTimeInterval(86_400))
        let previous = automatic("업무", minutes: 0, manuallyCorrected: true)
        let fresh = automatic("걷기", minutes: 0)
        let merged = ActivityClassificationLockEngine.mergingLockedClassifications(existing: [previous], fresh: [fresh], inside: span)
        XCTAssertEqual(merged.first?.title, "업무")
        XCTAssertEqual(merged.first?.lockReason, .user)
        let alone = ActivityClassificationLockEngine.mergingLockedClassifications(existing: [], fresh: [fresh], inside: span)
        XCTAssertEqual(alone.first?.lockReason, .stability)
    }

    func testCoordinatorRunsOncePerDaySkipsDaysWithoutRawAndResumesFailures() async {
        let markers = Markers()
        let coordinator = ClassificationRecomputeCoordinator(markers: markers)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let days = (0..<3).map { start.addingTimeInterval(Double($0) * 86_400) }
        var recomputed: [Date] = []
        let first = await coordinator.run(
            days: days, calendar: calendar,
            rawSampleCount: { day in day == calendar.startOfDay(for: days[0]) ? 0 : 500 },
            recompute: { day in
                recomputed.append(day)
                return day != calendar.startOfDay(for: days[1])
            }
        )
        XCTAssertEqual(first.map { $0.outcome }, [.recomputed, .failed, .skippedNoRaw], "최신 날부터")
        XCTAssertEqual(markers.keys.count, 2)
        XCTAssertTrue(markers.keys.allSatisfy { $0.hasPrefix(ClassificationRules.version + ":") })
        recomputed = []
        let second = await coordinator.run(days: days, calendar: calendar, rawSampleCount: { _ in 500 }, recompute: { day in
            recomputed.append(day)
            return true
        })
        XCTAssertEqual(second.map { $0.outcome }, [.alreadyDone, .recomputed, .alreadyDone])
        XCTAssertEqual(recomputed, [calendar.startOfDay(for: days[1])])
    }

    func testMarkerKeyIsDateScoped() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        XCTAssertEqual(ClassificationRecomputeCoordinator.markerKey(for: start, calendar: calendar), "classifier-v1r4:2026-09-21")
    }

    func testKeywordResolverNoLongerTurnsDeliveryOrBadmintonIntoMovement() {
        let delivery = automatic("배달 음식", minutes: 0)
        let badminton = automatic("배드민턴", minutes: 0)
        let ferry = automatic("배 타고 이동", minutes: 0)
        XCTAssertEqual(ActualRecordCategoryResolver.categoryID(for: delivery), "activity")
        XCTAssertEqual(RecordAnalysisCategoryPolicy.categoryID(for: badminton), "exercise")
        XCTAssertEqual(ActualRecordCategoryResolver.categoryID(for: ferry), "movement")
        XCTAssertNotEqual(RecordAnalysisCategoryPolicy.categoryID(for: automatic("remote 회의 준비", minutes: 0)), "sleep")
    }

    func testAppCatalogReadsTheSingleTaxonomyResource() {
        XCTAssertNotNil(ActivityTaxonomyResource.data, "분류표는 TaptionPlanCore 리소스 하나다(v4)")
        XCTAssertEqual(RecordClassificationCatalog.file.version, 5)
        XCTAssertTrue(RecordClassificationCatalog.options.contains { $0.id == "detail.study.academy" })
    }

    func testStepCountPrefersWatchAndAddsUncoveredPhoneSteps() {
        func r(_ minutes: Double, _ steps: Int, watch: Bool) -> SensorReading {
            var value = SensorReading(timestamp: start.addingTimeInterval(minutes * 60), stepCount: steps)
            value.sourceDevice = watch ? .appleWatch : .iPhone
            return value
        }
        let readings = [
            r(0, 100, watch: false), r(60, 2_000, watch: false), r(180, 2_500, watch: false),
            r(0, 50, watch: true), r(60, 2_300, watch: true),
        ]
        // 0~60분: 워치 2,250 + 시작점 50, 60~180분: 아이폰 500, 아이폰 시작점은 워치가 덮어 뺀다.
        XCTAssertEqual(ClassifierAdapter.stepCount(readings: readings, in: TimeSpan(start: start, end: start.addingTimeInterval(86_400))), 2_800)
    }

    func testStoreMarkersPersistInAppStoreMeta() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("alg-markers-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let markers = StoreClassificationRecomputeMarkers(store: try TaptionStoreV2(url: url))
        let key = ClassificationRecomputeCoordinator.markerKey(for: start)
        let before = await markers.isCompleted(key)
        XCTAssertFalse(before)
        await markers.markCompleted(key, outcome: "recomputed")
        let reopened = StoreClassificationRecomputeMarkers(store: try TaptionStoreV2(url: url))
        let after = await reopened.isCompleted(key)
        XCTAssertTrue(after, "표식은 앱 저장소 meta 표에 남는다")
    }

    func testLegacyModelVersionsMapToClassifierStages() {
        XCTAssertEqual(AutomaticModelVersion.normalized("stationary-context-v1"), "classifier-v1/context")
        XCTAssertEqual(AutomaticModelVersion.normalized("iphone-sleep-wake-v1"), AutomaticModelVersion.phoneSleep)
        XCTAssertEqual(AutomaticModelVersion.normalized("charging-inactivity-sleep-v1"), AutomaticModelVersion.phoneSleep)
        XCTAssertTrue(AutomaticModelVersion.matches("place-activity-v1", AutomaticModelVersion.placeActivity))
        XCTAssertEqual(AutomaticModelVersion.normalized("healthkit-sleep-v1"), "healthkit-sleep-v1", "원본 버전은 그대로")
        XCTAssertFalse(AutomaticModelVersion.isAutomaticClassification("manual-confirmed-sleep-v1"))
        XCTAssertEqual(StationaryContextClassifier.modelVersion, "classifier-v1/context")
    }

    func testTodayStepsPreferHealthTotalOverLiveIPhone() {
        XCTAssertEqual(ClassifierAdapter.todaySteps(health: 6_000, liveIPhone: 7_500), 6_000)
        XCTAssertEqual(ClassifierAdapter.todaySteps(health: nil, liveIPhone: 7_500), 7_500)
        XCTAssertEqual(ClassifierAdapter.todaySteps(health: 0, liveIPhone: 120), 120)
    }

    func testSalaryLiveSnapshotRoundTripsAndClears() throws {
        let suite = "alg-salary-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let value = SalaryLiveSnapshot(text: "12,000원", baseSeconds: 3_600, hourlyRate: 12_000, measuredAt: start, isWorking: true, tickSeconds: 10)
        SalaryLiveSnapshot.write(value, to: defaults)
        XCTAssertEqual(SalaryLiveSnapshot.read(defaults), value)
        SalaryLiveSnapshot.write(nil, to: defaults)
        XCTAssertEqual(SalaryLiveSnapshot.read(defaults), SalaryLiveSnapshot())
    }

    func testStayDetectionUsesCentroidAndKeepsKnownKeyAsAlias() {
        func reading(_ minute: Double, east: Double) -> SensorReading {
            var value = SensorReading(timestamp: start.addingTimeInterval(minute * 60), motion: .stationary, motionConfidence: .high)
            value.point = GeoPoint(latitude: 37.5, longitude: 127.0 + east / (111_320 * cos(37.5 * .pi / 180)), altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10)
            return value
        }
        // 첫 점이 동쪽 60m로 튀어 있다. 예전(첫 점 기준 70m)에는 서쪽 20m 표본에서 체류가 쪼개졌다.
        let readings = [reading(0, east: 60)] + (1...40).map { reading(Double($0), east: $0.isMultiple(of: 2) ? -20 : 0) }
        let stays = PlaceDetectionEngine().detectStays(readings: readings)
        XCTAssertEqual(stays.count, 1)
        // 이미 아는 키가 반경 절반(35m) 안이면 그 키·이름을 그대로 쓴다.
        let known = "37.5000,127.0002"
        let named = PlaceDetectionEngine().detectStays(readings: readings, knownNames: [known: "사무실"])
        XCTAssertEqual(named.first?.placeKey, known)
        XCTAssertEqual(named.first?.displayName, "사무실")
    }

    func testPhoneSleepFusionDropsCandidatesOverlappingWearableSleep() {
        let night = start
        let readings = (0...16).map { index in
            SensorReading(timestamp: night.addingTimeInterval(Double(index) * 5 * 60), motion: .stationary, motionConfidence: .high,
                          stepCount: 0, powerState: .charging, screenBrightness: 0.1, screenIsOn: false)
        }
        let span = TimeSpan(start: night, end: night.addingTimeInterval(3 * 3_600))
        XCTAssertFalse(PhoneSleepFusion.records(readings: readings, actuals: [], inside: span, nominalMaximumSampleGap: 20 * 60, asOf: span.end).isEmpty)
        XCTAssertTrue(PhoneSleepFusion.records(readings: readings, actuals: [], inside: span, nominalMaximumSampleGap: 20 * 60,
                                               authoritativeSleepSpans: [span], asOf: span.end).isEmpty)
    }

    func testClassificationScoreComesFromMatchingTimelineAndSkipsUserRecords() {
        let span = TimeSpan(start: start, end: start.addingTimeInterval(86_400))
        var bus = automatic("버스", minutes: 0)
        bus.behavior = "bus"
        let user = automatic("버스", minutes: 0, manuallyCorrected: true)
        let timeline = [
            ClassifierAdapter.TimelineSegment(span: TimeSpan(start: start, end: start.addingTimeInterval(20 * 60)), mode: .bus, meters: 8_000, score: 0.9),
            ClassifierAdapter.TimelineSegment(span: TimeSpan(start: start.addingTimeInterval(20 * 60), end: start.addingTimeInterval(30 * 60)), mode: .car, meters: 4_000, score: 0.7),
        ]
        let scored = ClassifierAdapter.scoring([bus, user], timeline: timeline, inside: span, activityCorrections: [:])
        XCTAssertEqual(scored[0].classificationScore, 0.6, "20분×0.9 / 30분")
        XCTAssertEqual(scored[0].categoryID, bus.categoryID)
        XCTAssertNil(scored[1].classificationScore)
    }

    private func hybrid(_ rule: TravelMode, hmm: TravelMode?, seconds: TimeInterval = 600, score: Double = 0.9,
                        evidence: [String] = [], confirmed: Bool = false, locked: Bool = false) -> TravelSegment {
        var segment = TravelSegment(mode: rule, span: TimeSpan(start: start, end: start.addingTimeInterval(600)),
                                    distanceMeters: 100, confidence: .low, evidence: evidence)
        segment.isConfirmed = confirmed
        segment.isClassificationLocked = locked
        let timeline = [ClassifierAdapter.TimelineSegment(span: TimeSpan(start: start, end: start.addingTimeInterval(seconds)),
                                                          mode: hmm, meters: 5_000, score: score)]
        return ClassifierAdapter.resolvingTravelModes([segment], timeline: timeline)[0]
    }

    func testHybridLetsHMMCorrectRuleModeAndKeepsEvidence() {
        let value = hybrid(.subway, hmm: .car, evidence: ["동력 이동"])
        XCTAssertEqual(value.mode, .car)
        XCTAssertNil(value.subwayRoute)
        XCTAssertEqual(value.confidence, .high)
        XCTAssertEqual(value.distanceMeters, 5_000)
        XCTAssertEqual(value.evidence.first, "동력 이동")
        XCTAssertEqual(value.evidence.count, 2)
        XCTAssertEqual(hybrid(.car, hmm: .airplane).mode, .airplane)
        XCTAssertEqual(hybrid(.walking, hmm: .car).mode, .car)
    }

    func testHybridKeepsRuleWhereHMMHasNoEvidence() {
        XCTAssertEqual(hybrid(.bus, hmm: .car).mode, .bus, "HMM은 정류장 근거가 없어 버스를 뒤집지 않는다")
        XCTAssertEqual(hybrid(.taxi, hmm: .car).mode, .taxi)
        XCTAssertEqual(hybrid(.train, hmm: .car).mode, .train)
        XCTAssertEqual(hybrid(.subway, hmm: .car, confirmed: true).mode, .subway)
        XCTAssertEqual(hybrid(.subway, hmm: .car, locked: true).mode, .subway)
        XCTAssertEqual(hybrid(.subway, hmm: .car, evidence: ["Apple Watch 3축 가속도 철도 진동"]).mode, .subway)
        XCTAssertEqual(hybrid(.subway, hmm: .car, evidence: ["사용자 지정 지하철역 일치"]).mode, .subway)
    }

    func testHybridDoesNotInventSubwayTrainOrDemoteVehicles() {
        XCTAssertEqual(hybrid(.car, hmm: .subway).mode, .car)
        XCTAssertEqual(hybrid(.car, hmm: .train).mode, .car)
        XCTAssertEqual(hybrid(.car, hmm: .walking).mode, .car)
        XCTAssertEqual(hybrid(.car, hmm: nil).mode, .car)
    }

    func testHybridNeedsCoverageAndConfidence() {
        XCTAssertEqual(hybrid(.subway, hmm: .car, seconds: 200).mode, .subway, "원본이 구간 절반을 덮지 못함")
        XCTAssertEqual(hybrid(.subway, hmm: .car, score: 0.3).mode, .subway, "사후 확률 부족")
    }

    func testAwaySecondsDoesNotCountRecordingGaps() {
        let home = PlaceStay(placeKey: "home", displayName: "집", span: TimeSpan(start: start, end: start.addingTimeInterval(8 * 3_600)), confidence: .high)
        let office = PlaceStay(placeKey: "office", displayName: "회사", span: TimeSpan(start: start.addingTimeInterval(9 * 3_600), end: start.addingTimeInterval(12 * 3_600)), confidence: .high)
        let away = MapHomeCalendarTimeTotalsPolicy.awaySeconds(
            stays: [home, office], homeKeys: ["home"], day: start, dayEnd: start.addingTimeInterval(24 * 3_600)
        )
        XCTAssertEqual(away, 3 * 3_600, "예전에는 24h - 8h = 16h")
    }
}

/// 라벨을 붙인 합성 하루로 이전 분류(`TravelModeClassifier`, 정답 구간 경계를 받음)와
/// 새 분류(`ClassifierAdapter.classifyDay`, 경계 없이 하루 전체)를 분 단위로 비교한다.
/// 실기기 원본이 아니라 합성 자료다. `TEST_RUNNER_TAPTION_GOLDEN_DIFF_OUT`이 있으면 표를 쓴다.
final class ClassifierGoldenReplayTests: XCTestCase {
    private struct Leg {
        var label: TravelMode?
        var minutes: Int
        var speed: Double
        var motion: MotionKind
        var gps = true
        var nearStop = false
        var nearAirport = false
        var onWater = false
        var pressure: Double?
        var cadence: Double?
        var accel: Double?
    }

    private struct Day {
        var name: String
        var legs: [Leg]
    }

    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    private var days: [Day] {
        [
            Day(name: "commute-bus-subway-office", legs: [
                Leg(label: nil, minutes: 30, speed: 0, motion: .stationary),
                Leg(label: .walking, minutes: 8, speed: 1.3, motion: .walking, cadence: 1.8),
                Leg(label: .bus, minutes: 20, speed: 7, motion: .automotive, nearStop: true),
                Leg(label: .walking, minutes: 5, speed: 1.3, motion: .walking, cadence: 1.8),
                Leg(label: .subway, minutes: 25, speed: 10, motion: .automotive, gps: false, accel: 0.04),
                Leg(label: .walking, minutes: 5, speed: 1.3, motion: .walking, cadence: 1.8),
                Leg(label: nil, minutes: 60, speed: 0, motion: .stationary),
            ]),
            Day(name: "flight", legs: [
                Leg(label: nil, minutes: 30, speed: 0, motion: .stationary, nearAirport: true),
                Leg(label: .airplane, minutes: 90, speed: 230, motion: .unknown, pressure: 78),
                Leg(label: nil, minutes: 20, speed: 0, motion: .stationary, nearAirport: true),
            ]),
            Day(name: "ferry", legs: [
                Leg(label: .walking, minutes: 6, speed: 1.3, motion: .walking, cadence: 1.8),
                Leg(label: .ship, minutes: 40, speed: 9, motion: .unknown, onWater: true),
                Leg(label: .walking, minutes: 6, speed: 1.3, motion: .walking, cadence: 1.8),
            ]),
            Day(name: "car-and-run", legs: [
                Leg(label: .car, minutes: 30, speed: 14, motion: .automotive),
                Leg(label: nil, minutes: 20, speed: 0, motion: .stationary),
                Leg(label: .running, minutes: 20, speed: 3.2, motion: .running, cadence: 2.7),
            ]),
        ]
    }

    private func readings(_ day: Day) -> (readings: [SensorReading], labels: [(TimeSpan, TravelMode?)]) {
        var result: [SensorReading] = []
        var labels: [(TimeSpan, TravelMode?)] = []
        var t = base
        var east = 0.0
        for leg in day.legs {
            let span = TimeSpan(start: t, end: t.addingTimeInterval(Double(leg.minutes) * 60))
            labels.append((span, leg.label))
            for second in stride(from: 0, to: leg.minutes * 60, by: 10) {
                var reading = SensorReading(timestamp: t.addingTimeInterval(Double(second)), motion: leg.motion, motionConfidence: .high)
                east += leg.speed * 10
                if leg.gps {
                    reading.point = GeoPoint(latitude: 34.0, longitude: 129.0 + east / (111_320 * cos(34.0 * .pi / 180)), altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10)
                    reading.speedMetersPerSecond = leg.speed
                    reading.courseDegrees = leg.speed > 0 ? 90 : nil
                }
                reading.gpsAvailable = leg.gps
                reading.frequentStops = leg.nearStop
                reading.nearAirport = leg.nearAirport
                reading.onWater = leg.onWater
                reading.pressureKilopascals = leg.pressure
                reading.currentCadenceStepsPerSecond = leg.cadence
                if let accel = leg.accel {
                    reading.deviceMotionSummary = DeviceMotionSummary(
                        sampleCount: 50, meanUserAccelerationG: accel, userAccelerationStandardDeviationG: accel,
                        peakUserAccelerationG: accel * 3, meanRotationRateRadiansPerSecond: 0.1,
                        rotationRateStandardDeviationRadiansPerSecond: 0.05, peakRotationRateRadiansPerSecond: 0.3
                    )
                }
                result.append(reading)
            }
            t = span.end
        }
        return (result, labels)
    }

    func testGoldenReplayNewClassifierIsNotWorseThanOld() throws {
        var rows: [[String: Any]] = []
        var totalLabeled = 0, oldCorrect = 0, newCorrect = 0
        for day in days {
            let (dayReadings, labels) = readings(day)
            let span = TimeSpan(start: base, end: base.addingTimeInterval(86_400))
            let timeline = try ClassifierAdapter.travelTimeline(readings: dayReadings, in: span)
            var perLabel: [String: (minutes: Int, old: Int, new: Int)] = [:]
            var oldFlightMeters = 0.0, newFlightMeters = 0.0
            for (legSpan, label) in labels {
                let inside = dayReadings.filter { legSpan.contains($0.timestamp) }
                let old: TravelMode? = label == nil ? nil : TravelModeClassifier().classify(readings: inside, inside: legSpan).mode
                if label == .airplane {
                    oldFlightMeters = TravelDistanceMath.pathMeters(readings: inside)
                    newFlightMeters = timeline.filter { $0.mode == .airplane }.map(\.meters).reduce(0, +)
                }
                for minute in 0..<Int(legSpan.duration / 60) {
                    let moment = legSpan.start.addingTimeInterval(Double(minute) * 60 + 30)
                    let fresh = timeline.first { $0.span.start <= moment && moment < $0.span.end }?.mode
                    let key = label?.rawValue ?? "stationary"
                    var entry = perLabel[key] ?? (0, 0, 0)
                    entry.minutes += 1
                    if old == label { entry.old += 1 }
                    if fresh == label { entry.new += 1 }
                    perLabel[key] = entry
                }
            }
            for (label, entry) in perLabel.sorted(by: { $0.key < $1.key }) {
                totalLabeled += entry.minutes
                oldCorrect += entry.old
                newCorrect += entry.new
                rows.append(["day": day.name, "label": label, "minutes": entry.minutes, "oldCorrectMinutes": entry.old, "newCorrectMinutes": entry.new])
            }
            if oldFlightMeters > 0 || newFlightMeters > 0 || day.name == "flight" {
                rows.append(["day": day.name, "label": "airplane-distance-m", "old": oldFlightMeters.rounded(), "new": newFlightMeters.rounded()])
            }
        }
        // 사용자 기록 분 회귀: 재계산 전 잠금 해제가 사용자 기록을 건드리지 않는다.
        let user = ActualRecord(planID: nil, title: "업무", categoryID: "work", startedAt: base, endedAt: base.addingTimeInterval(3_600),
                                source: .location, manuallyCorrected: true)
        let released = ActivityClassificationLockEngine.releasingStabilityLocks(
            [user], inside: TimeSpan(start: base, end: base.addingTimeInterval(86_400)), activityCorrections: [:]
        ).records
        let userRegressionMinutes = PlanActualStorage.exactlyEqual(released[...], [user][...]) ? 0 : 60
        let report: [String: Any] = [
            "requestID": "ALG1101A01",
            "source": "synthetic labeled days (not device raw); old classifier receives oracle segment boundaries, new classifier sees the whole day",
            "pipelineVersion": "classifier-v1",
            "labeledMinutes": totalLabeled,
            "oldCorrectMinutes": oldCorrect,
            "newCorrectMinutes": newCorrect,
            "userOwnedRegressionMinutes": userRegressionMinutes,
            "rows": rows,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print("GOLDEN-DIFF " + String(decoding: data, as: UTF8.self))
        if let path = ProcessInfo.processInfo.environment["TAPTION_GOLDEN_DIFF_OUT"], !path.isEmpty {
            try data.write(to: URL(fileURLWithPath: path))
        }
        XCTAssertGreaterThanOrEqual(newCorrect, oldCorrect, "라벨 분에서 새 분류가 이전보다 나빠지면 안 된다")
        XCTAssertEqual(userRegressionMinutes, 0)
    }
}
