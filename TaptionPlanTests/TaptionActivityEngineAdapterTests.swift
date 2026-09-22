import Foundation
import Testing
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
        #expect(evidence.map(\.detailHint) == [
            "movement.bus",
            "movement.subway",
            "movement.subway",
            "movement.running",
            "movement.walking",
            "movement.running",
            "movement.cycling",
            "movement.subway"
        ])
        #expect(evidence.map(\.categoryHint) == [
            "movement", "movement", "movement", "movement",
            "movement", "movement", "movement", "movement"
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
        #expect(actual?.modelVersion == "place-activity-v1")
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
