import Foundation
import Testing
import TaptionActivityEngine
@testable import TaptionPlan

struct TaptionActivityEngineAdapterTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func reading(
        _ seconds: TimeInterval,
        motion: MotionKind = .walking,
        behavior: String? = nil
    ) -> SensorReading {
        SensorReading(
            timestamp: base.addingTimeInterval(seconds),
            motion: motion,
            behavior: behavior,
            behaviorConfidenceScore: behavior == nil ? nil : 0.9,
            behaviorEvidence: behavior == nil ? nil : ["Watch"]
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
