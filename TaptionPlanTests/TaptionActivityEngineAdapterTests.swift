import Foundation
import Testing
import TaptionActivityEngine
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

    @Test func mapsDetailedAndMajorActivityTaxonomy() {
        let result = TaptionActivityEngineAdapter.classify(
            readings: [reading(0, motion: .walking)],
            travel: []
        )
        #expect(result.segments.first?.detailID == "movement.walking")
        #expect(result.segments.first?.majorCategoryID == "movement")
        #expect(result.majorCategoryIDs == ["movement"])
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
}
