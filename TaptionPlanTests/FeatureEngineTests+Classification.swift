import XCTest
import UIKit
import CoreLocation
import StoreKit
import StoreKitTest
import TaptionPlanCore
@testable import TaptionPlan

extension FeatureEngineTests {
    /// 다이나믹 아일랜드·잠금화면·워치가 같은 대분류 이름을 쓴다. 영어 설정이면 영어로 나온다.
    func testCurrentActivityTitlesFollowTheLanguage() {
        XCTAssertEqual(TaptionLiveActivityStickmanAction.computer.koreanTitle, "업무")
        XCTAssertEqual(TaptionLiveActivityStickmanAction.computer.englishTitle, "Work")
        XCTAssertEqual(TaptionLiveActivityStickmanAction.unconfirmed.koreanTitle, "확인 중")
        XCTAssertEqual(TaptionLiveActivityStickmanAction.unconfirmed.englishTitle, "Checking")
        XCTAssertEqual(TaptionLiveActivityStickmanAction.sleeping.englishTitle, "Sleep")

        // 대분류 id로 풀면 화면마다 같은 이름이 나온다.
        let resolved = TaptionLiveActivityStickmanAction.resolve(
            categoryID: "work",
            title: "업무"
        )
        XCTAssertEqual(resolved, .computer)
        XCTAssertEqual(resolved.englishTitle, "Work")

        let activity = TaptionWatchCurrentActivity(
            categoryID: "work",
            koreanTitle: resolved.koreanTitle,
            englishTitle: resolved.englishTitle,
            startedAt: Date(timeIntervalSince1970: 900)
        )
        XCTAssertEqual(activity.title(for: .korean), "업무")
        XCTAssertEqual(activity.title(for: .english), "Work")
    }

    func testActivityClassificationResultOrderingUsesStartThenExactID() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
        let first = ActualRecord(
            id: firstID,
            planID: nil,
            title: "first",
            categoryID: "activity",
            startedAt: start,
            source: .motion
        )
        let second = ActualRecord(
            id: secondID,
            planID: nil,
            title: "second",
            categoryID: "activity",
            startedAt: start,
            source: .motion
        )
        let later = ActualRecord(
            planID: nil,
            title: "later",
            categoryID: "activity",
            startedAt: start.addingTimeInterval(1),
            source: .motion
        )

        let ordered = try ActivityClassificationRecordOrdering.sorted(
            [later, second, first],
            cancellationCheck: {}
        )

        XCTAssertEqual(ordered.map(\.id), [firstID, secondID, later.id])
    }

    @MainActor
    func testActivityClassificationRetryCancelsStaleFusionAndCommitsLatestRevision()
        async {
        let start = Date(timeIntervalSince1970: 1_800_100_000)
        let span = TimeSpan(start: start, end: start.addingTimeInterval(8_000))
        let readings = (0..<4_096).reversed().map { index in
            SensorReading(
                timestamp: start.addingTimeInterval(TimeInterval(index)),
                motion: .walking,
                behavior: "walking"
            )
        }
        let revisionFence = ActivityClassificationRevisionFence(1)
        let firstAttemptGate = ClassificationRevisionAdvanceGate(
            fence: revisionFence,
            advanceAtCheckpoint: 40
        )
        var attempts = 0
        var committedRevision: UInt64?

        let applied = await ActivityClassificationRetry.apply(
            capture: {
                ActivityClassificationSourceSnapshot(
                    revision: revisionFence.currentRevision,
                    snapshot: .empty
                )
            },
            currentRevision: { revisionFence.currentRevision },
            classify: { source -> [ActualRecord]? in
                attempts += 1
                let isFirstAttempt = attempts == 1
                do {
                    return try TaptionActivityEngineAdapter.classifiedActivityActuals(
                        readings: readings,
                        travel: source.travel,
                        corrections: source.corrections,
                        actuals: source.actuals,
                        inside: span,
                        createdAt: start,
                        cancellationCheck: {
                            try Task.checkCancellation()
                            if isFirstAttempt {
                                try firstAttemptGate.check(source.revision)
                            } else {
                                try revisionFence.check(source.revision)
                            }
                        }
                    )
                } catch is CancellationError {
                    return nil
                } catch {
                    return nil
                }
            },
            commit: { source, _ in
                committedRevision = source.revision
            }
        )

        XCTAssertTrue(applied)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(committedRevision, 2)
    }

    @MainActor
    func testAcceptedActivityEditSurvivesCallerCancellation() async throws {
        let day = makeDate(2026, 8, 13)
        let span = TimeSpan(
            start: day.addingTimeInterval(9 * hour),
            end: day.addingTimeInterval(10 * hour)
        )
        let travel = TravelSegment(
            mode: .walking,
            span: span,
            distanceMeters: 1_000,
            confidence: .high,
            evidence: ["테스트"],
            isConfirmed: true,
            isClassificationLocked: true
        )
        var stored = TaptionDataSnapshot.empty
        stored.categories = CategoryCatalog.builtIn
        stored.travel = [travel]
        stored.settings.locationEnabled = false
        stored.settings.weatherEnabled = false
        stored.settings.healthEnabled = false
        let repository = GatedSavePlanRepository(snapshot: stored)
        let model = AppModel(
            repository: repository,
            cloudSyncService: nil,
            registersHealthBackgroundHandler: false
        )
        await model.bootstrap()

        let request = ActivitySectionEditRequest(
            sourceIDs: [travel.id],
            originalSpan: span,
            originalOption: phaseOption("movement", title: "이동"),
            mode: .replace(
                editedSpan: span,
                option: phaseOption("work", title: "업무")
            )
        )
        let caller = Task { @MainActor in
            await model.saveActivitySectionEdit(request)
        }

        await repository.waitForFirstSave()
        caller.cancel()
        await repository.releaseFirstSave()
        _ = await caller.value

        let persisted = try await repository.load()
        XCTAssertTrue(
            persisted.actuals.contains {
                $0.categoryID == "work" && $0.title == "업무"
            }
        )
    }

    func testRecordAnalysisPolicyUsesOnlyCanonicalAutomaticCategories() {
        let phaseTitles = RecordAnalysisCategoryPolicy.options
            .filter(RecordAnalysisCategoryPolicy.isPhaseOption)
            .map(\.title)
        XCTAssertEqual(
            phaseTitles,
            ["활동", "업무", "수업", "취미", "수면", "이동", "식사", "운동", "건강관리", "샤워", "집안일", "미확인"]
        )

        let detailTitles = Set(
            RecordAnalysisCategoryPolicy.options
                .filter { !RecordAnalysisCategoryPolicy.isPhaseOption($0) }
                .map(\.title)
        )
        XCTAssertTrue(detailTitles.isSuperset(of: [
            "휴식", "미확인", "업무(집 - 회사)", "수업(집 - 학교·학원)",
            "취미(집 - 취미)", "코어 수면", "깊은 수면", "REM 수면",
            "걷기", "자동차", "지하철", "자가용", "버스", "배", "비행기",
            "자전거", "식사", "요리", "운동",
        ]))
    }

    func testHouseworkAlwaysBelongsToActivity() {
        let record = ActualRecord(
            planID: nil,
            title: "집안일",
            categoryID: "work",
            startedAt: makeDate(2026, 8, 13, 9, 0),
            endedAt: makeDate(2026, 8, 13, 10, 0),
            source: .location,
            behavior: WatchBehaviorKind.housework.rawValue
        )

        XCTAssertEqual(
            RecordAnalysisCategoryPolicy.categoryID(for: record),
            "activity"
        )
        XCTAssertEqual(
            RecordAnalysisCategoryPolicy.detailTitle(for: record),
            "집안일"
        )
        XCTAssertFalse(
            RecordAnalysisCategoryPolicy.options
                .filter { $0.categoryID == "work" }
                .contains { $0.title == "집안일" }
        )
    }

    func testActivityCorrectionChangesDisplayFieldsWithoutTouchingEvidence() {
        let source = ActualRecord(
            planID: nil,
            title: "머무름",
            categoryID: "activity",
            startedAt: makeDate(2026, 8, 10, 0, 0),
            endedAt: makeDate(2026, 8, 10, 1, 0),
            source: .location,
            behavior: StationaryContextKind.unknownStay.rawValue,
            evidence: ["GPS"]
        )
        let corrected = ActivityCorrectionEngine.applying(
            [source.id: ActivityCorrection(
                title: "샤워",
                behavior: WatchBehaviorKind.showering.rawValue,
                categoryID: "activity"
            )],
            to: [source]
        )[0]

        XCTAssertEqual(corrected.id, source.id)
        XCTAssertEqual(corrected.title, "샤워")
        XCTAssertEqual(corrected.behavior, WatchBehaviorKind.showering.rawValue)
        XCTAssertEqual(corrected.evidence, ["GPS"])
        XCTAssertEqual(corrected.source, .location)
        XCTAssertTrue(corrected.manuallyCorrected)
    }

    func testActivityCorrectionCanAdjustDisplaySpanWithoutChangingSource() {
        let source = ActualRecord(
            planID: nil,
            title: "머무름",
            categoryID: "activity",
            startedAt: makeDate(2026, 8, 10, 0, 0),
            endedAt: makeDate(2026, 8, 10, 1, 0),
            source: .location,
            behavior: StationaryContextKind.unknownStay.rawValue,
            evidence: ["GPS"]
        )
        let start = makeDate(2026, 8, 10, 0, 10)
        let end = makeDate(2026, 8, 10, 0, 40)
        let corrected = ActivityCorrectionEngine.applying(
            [source.id: ActivityCorrection(
                title: source.title,
                behavior: source.behavior,
                categoryID: source.categoryID,
                startedAt: start,
                endedAt: end
            )],
            to: [source]
        )[0]

        XCTAssertEqual(corrected.startedAt, start)
        XCTAssertEqual(corrected.endedAt, end)
        XCTAssertEqual(corrected.evidence, source.evidence)
        XCTAssertEqual(corrected.source, source.source)
        XCTAssertTrue(corrected.manuallyCorrected)
    }

    func testActivityCorrectionChoiceKeepsExistingDisplaySpan() {
        let start = makeDate(2026, 8, 10, 0, 10)
        let end = makeDate(2026, 8, 10, 0, 40)
        let updated = ActivityCorrectionEngine.replacingActivity(
            in: ActivityCorrection(
                title: "머무름",
                behavior: StationaryContextKind.unknownStay.rawValue,
                categoryID: "activity",
                startedAt: start,
                endedAt: end
            ),
            with: ActivityCorrectionOption.custom("독서")
        )

        XCTAssertEqual(updated.title, "독서")
        XCTAssertNil(updated.behavior)
        XCTAssertEqual(updated.startedAt, start)
        XCTAssertEqual(updated.endedAt, end)
    }

    func testBrushingTeethActivityUsesToothbrushIcon() {
        XCTAssertEqual(
            WatchBehaviorKind.brushingTeeth.systemImage,
            "toothbrush.fill"
        )
        XCTAssertEqual(
            ActivityCorrectionOption.custom("양치").systemImage,
            "toothbrush.fill"
        )
    }

    func testFragmentCorrectionReusesWholeFinishedRecord() {
        let source = ActualRecord(
            planID: nil,
            title: "활동",
            categoryID: "activity",
            startedAt: makeDate(2026, 8, 12, 7, 0),
            endedAt: makeDate(2026, 8, 12, 8, 0),
            source: .location
        )

        XCTAssertFalse(
            ActivityFragmentCorrectionEngine.needsSeparateRecord(
                source: source,
                displayedSpan: TimeSpan(
                    start: source.startedAt,
                    end: source.endedAt ?? source.startedAt
                )
            )
        )
    }

    func testActivitySectionReplaceMakesTrimmedSidesUnconfirmed() {
        let original = TimeSpan(
            start: makeDate(2026, 8, 12, 9, 0),
            end: makeDate(2026, 8, 12, 18, 0)
        )
        let edited = TimeSpan(
            start: makeDate(2026, 8, 12, 10, 0),
            end: makeDate(2026, 8, 12, 17, 0)
        )
        let request = ActivitySectionEditRequest(
            sourceIDs: [UUID()],
            originalSpan: original,
            originalOption: phaseOption("work", title: "업무"),
            mode: .replace(
                editedSpan: edited,
                option: phaseOption("study", title: "수업")
            )
        )

        let pieces = ActivitySectionOverrideEngine.pieces(for: request)

        XCTAssertEqual(pieces.map(\.span), [
            TimeSpan(start: original.start, end: edited.start),
            edited,
            TimeSpan(start: edited.end, end: original.end),
        ])
        XCTAssertEqual(
            pieces.map { $0.option.categoryID },
            ["unconfirmed", "study", "unconfirmed"]
        )
    }

    func testActivitySectionCutKeepsTopAndMarksBottomUnconfirmed() {
        let original = TimeSpan(
            start: makeDate(2026, 8, 12, 9, 0),
            end: makeDate(2026, 8, 12, 18, 0)
        )
        let cutAt = makeDate(2026, 8, 12, 13, 0)
        let request = ActivitySectionEditRequest(
            sourceIDs: [],
            originalSpan: original,
            originalOption: phaseOption("work", title: "업무"),
            mode: .cutLowerUnconfirmed(
                cutAt: cutAt,
                option: phaseOption("work", title: "업무")
            )
        )

        let records = ActivitySectionOverrideEngine.records(for: request)

        XCTAssertEqual(records.map(\.startedAt), [original.start, cutAt])
        XCTAssertEqual(records.map(\.endedAt), [cutAt, original.end])
        XCTAssertEqual(records.map(\.categoryID), ["work", "unconfirmed"])
        XCTAssertTrue(records.allSatisfy(\.manuallyCorrected))
    }

    func testActivitySectionDetailInsertPreservesBeforeAndAfter() {
        let original = TimeSpan(
            start: makeDate(2026, 8, 12, 9, 0),
            end: makeDate(2026, 8, 12, 18, 0)
        )
        let lunch = TimeSpan(
            start: makeDate(2026, 8, 12, 12, 0),
            end: makeDate(2026, 8, 12, 13, 0)
        )
        let request = ActivitySectionEditRequest(
            sourceIDs: [UUID()],
            originalSpan: original,
            originalOption: phaseOption("work", title: "업무"),
            mode: .insertDetail(
                detailSpan: lunch,
                option: phaseOption("eating", title: "점심")
            )
        )

        let records = ActivitySectionOverrideEngine.records(for: request)

        XCTAssertEqual(records.map(\.categoryID), ["work", "eating", "work"])
        XCTAssertEqual(records[0].span(asOf: original.end), TimeSpan(
            start: original.start,
            end: lunch.start
        ))
        XCTAssertEqual(records[1].span(asOf: original.end), lunch)
        XCTAssertEqual(records[2].span(asOf: original.end), TimeSpan(
            start: lunch.end,
            end: original.end
        ))
    }

    @MainActor
    func testActivityEditUndoRedoPreservesAutomaticRecordsAndClearsRedo()
        async throws {
        let day = makeDate(2026, 8, 12)
        let span = TimeSpan(
            start: day.addingTimeInterval(9 * hour),
            end: day.addingTimeInterval(10 * hour)
        )
        let automatic = ActualRecord(
            planID: nil,
            title: "걷기",
            categoryID: "movement",
            startedAt: day.addingTimeInterval(7 * hour),
            endedAt: day.addingTimeInterval(8 * hour),
            source: .healthKit,
            evidence: ["HealthKit"]
        )
        let travel = TravelSegment(
            mode: .subway,
            span: span,
            distanceMeters: 12_000,
            confidence: .high,
            evidence: ["GPS"],
            isConfirmed: true
        )
        var stored = TaptionDataSnapshot.empty
        stored.updatedAt = day
        stored.actuals = [automatic]
        stored.travel = [travel]
        stored.settings.locationEnabled = false
        stored.settings.weatherEnabled = false
        stored.settings.healthEnabled = false
        let repository = InMemoryPlanRepository(snapshot: stored)
        let model = AppModel(
            repository: repository,
            cloudSyncService: nil,
            registersHealthBackgroundHandler: false
        )
        await model.bootstrap()

        let result = await model.saveActivitySectionEdit(
            ActivitySectionEditRequest(
                sourceIDs: [travel.id],
                originalSpan: span,
                originalOption: phaseOption("movement", title: "지하철 탑승"),
                mode: .replace(
                    editedSpan: span,
                    option: phaseOption("eating", title: "식사")
                )
            )
        )
        XCTAssertNotNil(result)
        XCTAssertTrue(model.canUndo)
        XCTAssertFalse(model.canRedo)

        model.undoLastUserEdit()
        XCTAssertFalse(model.snapshot.actuals.contains {
            $0.source == .manual && $0.categoryID == "eating"
        })
        XCTAssertTrue(model.snapshot.actuals.contains { $0.id == automatic.id })
        XCTAssertTrue(model.canRedo)

        model.redoLastUserEdit()
        XCTAssertTrue(model.snapshot.actuals.contains {
            $0.source == .manual && $0.categoryID == "eating"
        })
        XCTAssertTrue(model.snapshot.actuals.contains { $0.id == automatic.id })
        XCTAssertTrue(model.canUndo)
        XCTAssertFalse(model.canRedo)

        let currentRail = MapHomeTimeRailSegmentEngine.segments(
            from: model.snapshot.actuals,
            travel: model.snapshot.travel,
            on: day,
            asOf: day.addingTimeInterval(24 * hour),
            calendar: utcCalendar
        )
        let currentSegment = try XCTUnwrap(
            MapHomeTimeRailSegmentEngine.segment(
                at: 9 * 60 + 30,
                in: currentRail
            )
        )
        let nextResult = await model.saveActivitySectionEdit(
            ActivitySectionEditRequest(
                sourceIDs: currentSegment.sourceIDs,
                originalSpan: span,
                originalOption: phaseOption("eating", title: "식사"),
                mode: .replace(
                    editedSpan: span,
                    option: phaseOption("exercise", title: "운동")
                )
            )
        )
        XCTAssertNotNil(nextResult)
        XCTAssertFalse(model.canRedo)
        XCTAssertTrue(model.snapshot.actuals.contains {
            $0.source == .manual && $0.categoryID == "exercise"
        })
        XCTAssertTrue(model.snapshot.actuals.contains { $0.id == automatic.id })
    }

    func testManualClassificationWinsOverLaterAutomaticEvidence() {
        let day = TimeSpan(
            start: makeDate(2026, 8, 10),
            end: makeDate(2026, 8, 11)
        )
        let automatic = ActualRecord(
            planID: nil,
            title: "걷기",
            categoryID: "movement",
            startedAt: day.start,
            endedAt: day.start.addingTimeInterval(3 * hour),
            source: .motion
        )
        let manual = ActualRecord(
            planID: nil,
            title: "샤워",
            categoryID: "activity",
            startedAt: day.start.addingTimeInterval(hour),
            endedAt: day.start.addingTimeInterval(2 * hour),
            source: .manual,
            manuallyCorrected: true
        )

        let records = ReviewCoverageEngine.records(
            actuals: [automatic, manual],
            in: [day],
            asOf: day.start.addingTimeInterval(3 * hour)
        )

        XCTAssertEqual(
            records.filter { $0.title == "샤워" }
                .reduce(0) { $0 + $1.span(asOf: day.end).duration },
            hour
        )
        XCTAssertEqual(
            records.filter { $0.title == "걷기" }
                .reduce(0) { $0 + $1.span(asOf: day.end).duration },
            2 * hour
        )
    }

    func testLockedClassificationMergePreservesFirstMaximumOverlap() {
        let start = makeDate(2026, 8, 12, 9, 0)
        let first = ActualRecord(
            planID: nil,
            title: "첫 분류",
            categoryID: "work",
            startedAt: start,
            endedAt: start.addingTimeInterval(20 * 60),
            source: .motion,
            isClassificationLocked: true
        )
        let second = ActualRecord(
            planID: nil,
            title: "두 번째 분류",
            categoryID: "hobby",
            startedAt: start,
            endedAt: start.addingTimeInterval(20 * 60),
            source: .motion,
            isClassificationLocked: true
        )
        let fresh = ActualRecord(
            planID: nil,
            title: "새 분류",
            categoryID: "activity",
            startedAt: start,
            endedAt: start.addingTimeInterval(20 * 60),
            source: .motion
        )

        let result = ActivityClassificationLockEngine.mergingLockedClassifications(
            existing: [first, second],
            fresh: [fresh],
            inside: TimeSpan(start: start, end: start.addingTimeInterval(hour))
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].categoryID, first.categoryID)
        XCTAssertEqual(result[0].title, first.title)
    }

    func testLockedClassificationMergeBoundsDisjointCandidateInspection() {
        let start = makeDate(2026, 8, 1, 0, 0)
        let count = 1_000
        let locked = (0..<count).map { index in
            let itemStart = start.addingTimeInterval(Double(index) * 60)
            return ActualRecord(
                planID: nil,
                title: "기존 \(index)",
                categoryID: "activity",
                startedAt: itemStart,
                endedAt: itemStart.addingTimeInterval(30),
                source: .motion,
                isClassificationLocked: true
            )
        }
        let fresh = (0..<count).map { index in
            let itemStart = start.addingTimeInterval(
                7 * 24 * hour + Double(index) * 60
            )
            return ActualRecord(
                planID: nil,
                title: "신규 \(index)",
                categoryID: "movement",
                startedAt: itemStart,
                endedAt: itemStart.addingTimeInterval(30),
                source: .motion
            )
        }
        var candidateInspectionCount = 0

        let result = ActivityClassificationLockEngine.mergingLockedClassifications(
            existing: locked,
            fresh: fresh,
            inside: TimeSpan(
                start: start,
                end: start.addingTimeInterval(8 * 24 * hour)
            ),
            candidateInspectionCount: &candidateInspectionCount
        )

        XCTAssertEqual(result.count, count * 2)
        XCTAssertLessThan(candidateInspectionCount, count * count / 20)
    }

    func testSensorEvidenceTimeIndexPreservesFilterSemantics() {
        let start = makeDate(2026, 8, 18, 9)
        let end = start.addingTimeInterval(60)
        let span = TimeSpan(start: start, end: end)
        let middle = SensorReading(
            timestamp: start.addingTimeInterval(30),
            motion: .walking
        )
        let atEnd = SensorReading(timestamp: end, motion: .automotive)
        let before = SensorReading(
            timestamp: start.addingTimeInterval(-1),
            motion: .stationary
        )
        let atStart = SensorReading(timestamp: start, motion: .cycling)
        let after = SensorReading(
            timestamp: end.addingTimeInterval(1),
            motion: .running
        )
        let invalid = SensorReading(
            timestamp: Date(timeIntervalSinceReferenceDate: .nan),
            motion: .unknown
        )
        func evidence(
            _ name: String,
            _ evidenceStart: Date,
            _ evidenceEnd: Date
        ) -> AppleMovementEvidence {
            AppleMovementEvidence(
                span: TimeSpan(start: evidenceStart, end: evidenceEnd),
                source: .iPhone,
                kind: .steps,
                stepCount: 1,
                sourceName: name
            )
        }
        let healthEvidence = [
            evidence(
                "late overlap",
                start.addingTimeInterval(45),
                end.addingTimeInterval(30)
            ),
            evidence(
                "touches start",
                start.addingTimeInterval(-30),
                start
            ),
            evidence(
                "early overlap",
                start.addingTimeInterval(-30),
                start.addingTimeInterval(15)
            ),
            evidence(
                "touches end",
                end,
                end.addingTimeInterval(30)
            ),
            evidence(
                "zero duration",
                start.addingTimeInterval(20),
                start.addingTimeInterval(20)
            ),
        ]
        let index = SensorEvidenceTimeIndex(
            readings: [middle, atEnd, before, atStart, after, invalid],
            healthEvidence: healthEvidence
        )

        XCTAssertEqual(
            index.readings(in: span).map(\.id),
            [middle.id, atEnd.id, atStart.id]
        )
        XCTAssertEqual(
            index.healthEvidence(overlapping: span).map(\.sourceName),
            ["late overlap", "early overlap"]
        )
    }

    func testSensorEvidenceTimeIndexBoundsDisjointInspection() {
        let start = makeDate(2026, 8, 1, 0, 0)
        let count = 1_000
        let readings = (0..<count).map { index in
            SensorReading(
                timestamp: start.addingTimeInterval(
                    30 * 24 * hour + Double(index) * 60
                )
            )
        }
        let healthEvidence = (0..<count).map { index in
            let evidenceStart = start.addingTimeInterval(
                60 * 24 * hour + Double(index) * 60
            )
            return AppleMovementEvidence(
                span: TimeSpan(
                    start: evidenceStart,
                    end: evidenceStart.addingTimeInterval(30)
                ),
                source: .iPhone,
                kind: .steps,
                stepCount: 1,
                sourceName: "Health"
            )
        }
        let index = SensorEvidenceTimeIndex(
            readings: readings,
            healthEvidence: healthEvidence
        )
        var inspectionCount = 0

        for offset in 0..<count {
            let queryStart = start.addingTimeInterval(Double(offset) * 60)
            let span = TimeSpan(
                start: queryStart,
                end: queryStart.addingTimeInterval(30)
            )
            XCTAssertTrue(
                index.readings(
                    in: span,
                    candidateInspectionCount: &inspectionCount
                ).isEmpty
            )
            XCTAssertTrue(
                index.healthEvidence(
                    overlapping: span,
                    candidateInspectionCount: &inspectionCount
                ).isEmpty
            )
        }

        XCTAssertLessThan(inspectionCount, count * count / 10)
    }

    func testSensorCollectionWaveformPhaseAdvancesRightToLeft() {
        XCTAssertEqual(
            SensorCollectionWaveformMath.rightToLeftPhase(
                position: 0.4,
                progress: 0
            ),
            0.4,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            SensorCollectionWaveformMath.rightToLeftPhase(
                position: 0.4,
                progress: 0.25
            ),
            0.15,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            SensorCollectionWaveformMath.rightToLeftPhase(
                position: 0.1,
                progress: 0.25
            ),
            0.85,
            accuracy: 0.000_001
        )
    }

    func testSensorCollectionCompactWaveformSegmentsShareAContinuousPhase() {
        let trailingEnd = SensorCollectionWaveformMath.segmentedPosition(
            localPosition: 1,
            offset: 0,
            scale: 0.5
        )
        let leadingStart = SensorCollectionWaveformMath.segmentedPosition(
            localPosition: 0,
            offset: 0.5,
            scale: 0.5
        )
        XCTAssertEqual(trailingEnd, leadingStart, accuracy: 0.000_001)
        XCTAssertEqual(
            SensorCollectionWaveformMath.rightToLeftPhase(
                position: trailingEnd,
                progress: 0.25
            ),
            SensorCollectionWaveformMath.rightToLeftPhase(
                position: leadingStart,
                progress: 0.25
            ),
            accuracy: 0.000_001
        )
    }

    func testAutomaticTrackingPromotionAndStopPolicy() {
        XCTAssertFalse(
            TrackingSessionPolicy.allowsAutomaticTracking(interval: 1)
        )
        XCTAssertTrue(
            TrackingSessionPolicy.allowsAutomaticTracking(interval: 30)
        )
        XCTAssertTrue(
            TrackingSessionPolicy.allowsAutomaticTracking(interval: 60)
        )
        XCTAssertTrue(
            TrackingSessionPolicy.allowsAutomaticTracking(interval: 300)
        )
        XCTAssertFalse(
            TrackingSessionPolicy.allowsAutomaticTracking(interval: 10)
        )
        XCTAssertFalse(
            TrackingSessionPolicy.allowsAutomaticTracking(interval: 900)
        )
        XCTAssertFalse(
            TrackingSessionPolicy.shouldAutomaticallyStart(
                motion: .walking,
                confidence: .medium,
                sustainedFor: 9.9
            )
        )
        XCTAssertTrue(
            TrackingSessionPolicy.shouldAutomaticallyStart(
                motion: .walking,
                confidence: .medium,
                sustainedFor: 10
            )
        )
        XCTAssertTrue(
            TrackingSessionPolicy.shouldAutomaticallyStart(
                motion: .running,
                confidence: .high,
                sustainedFor: 15
            )
        )
        XCTAssertFalse(
            TrackingSessionPolicy.shouldAutomaticallyStart(
                motion: .automotive,
                confidence: .high,
                sustainedFor: 30
            )
        )
        XCTAssertFalse(
            TrackingSessionPolicy.shouldAutomaticallyStop(
                motion: .stationary,
                stationaryFor: 119
            )
        )
        XCTAssertTrue(
            TrackingSessionPolicy.shouldAutomaticallyStop(
                motion: .stationary,
                stationaryFor: 120
            )
        )
        XCTAssertEqual(TrackingSessionPolicy.activeDistanceFilterMeters, 5)
        XCTAssertEqual(TrackingSessionPolicy.activeHorizontalAccuracyLimit, 50)
    }

    func testProTrialStartsOnlyWhenARecordExistsAndExpiresAtFourteenDays() {
        let start = makeDate(2026, 8, 23, 12)
        XCTAssertEqual(
            TaptionProTrialPolicy.state(record: nil, now: start),
            .trialNotStarted
        )

        let record = TaptionProTrialRecord(
            startedAt: start,
            lastObservedAt: start
        )
        XCTAssertEqual(
            TaptionProTrialPolicy.state(
                record: record,
                now: start.addingTimeInterval(13 * 86_400)
            ),
            .trial(
                expiresAt: start.addingTimeInterval(14 * 86_400),
                remainingDays: 1
            )
        )
        XCTAssertEqual(
            TaptionProTrialPolicy.state(
                record: record,
                now: start.addingTimeInterval(14 * 86_400)
            ),
            .expired(
                expiresAt: start.addingTimeInterval(14 * 86_400)
            )
        )
    }

    func testProTrialFromSevenDayExpiredRecordRemainsTrialWithinFourteenDays() {
        let start = makeDate(2026, 8, 23, 12)
        let record = TaptionProTrialRecord(
            startedAt: start,
            lastObservedAt: start.addingTimeInterval(7 * 86_400)
        )

        XCTAssertEqual(
            TaptionProTrialPolicy.state(
                record: record,
                now: start.addingTimeInterval(8 * 86_400)
            ),
            .trial(
                expiresAt: start.addingTimeInterval(14 * 86_400),
                remainingDays: 6
            )
        )
    }

    func testAutomaticActualSpanStopsAtObservationTime() {
        let observedAt = makeDate(2026, 8, 3, 18)
        let actual = ActualRecord(
            planID: nil,
            title: "걷기",
            categoryID: "movement",
            startedAt: observedAt.addingTimeInterval(-hour),
            endedAt: observedAt.addingTimeInterval(hour),
            source: .motion
        )

        XCTAssertEqual(
            actual.span(asOf: observedAt).end,
            observedAt
        )
        XCTAssertEqual(
            actual.span(asOf: observedAt).duration,
            hour,
            accuracy: 0.001
        )
    }

    func testRelationshipGraphResolvesNestedActionAndAutomaticEvidence() {
        let start = makeDate(2026, 8, 2, 9)
        let routine = PlanRecord(
            title: "루틴:운동",
            span: TimeSpan(start: start, end: start.addingTimeInterval(4 * hour)),
            categoryID: "activity"
        )
        let parentAction = PlanRecord(
            title: "준비 운동",
            span: TimeSpan(start: start, end: start.addingTimeInterval(hour)),
            categoryID: "exercise",
            parentID: routine.id
        )
        let nestedAction = PlanRecord(
            title: "달리기",
            span: TimeSpan(
                start: start.addingTimeInterval(hour),
                end: start.addingTimeInterval(3 * hour)
            ),
            categoryID: "exercise",
            parentID: parentAction.id
        )
        let running = ActualRecord(
            planID: nestedAction.id,
            routineID: nil,
            title: "달리기",
            categoryID: "exercise",
            startedAt: start.addingTimeInterval(75 * 60),
            endedAt: start.addingTimeInterval(2 * hour),
            source: .appleWatch
        )

        let graph = RecordRelationshipEngine.make(
            inside: running.span(),
            plans: [routine, parentAction, nestedAction],
            actuals: [running],
            calendarEvents: [],
            places: [],
            travel: [],
            focusNodeID: "automatic.actual.\(running.id.uuidString)"
        )

        XCTAssertTrue(graph.edges.contains {
            $0.from == "routine.\(routine.id.uuidString)"
                && $0.to == "action.\(nestedAction.id.uuidString)"
        })
        XCTAssertTrue(graph.edges.contains {
            $0.from == "automatic.actual.\(running.id.uuidString)"
                && $0.to == "action.\(nestedAction.id.uuidString)"
        })
        XCTAssertTrue(graph.nodes.contains { $0.id == "routine.\(routine.id.uuidString)" })
        XCTAssertTrue(graph.nodes.contains { $0.id == "action.\(nestedAction.id.uuidString)" })
    }

    /// 기록이 있는 곳으로 끌려가지 않는다. 빈 구간으로 넘어가면 그 빈 구간이
    /// 그대로 나온다. 예전에는 손을 뗀 자리에 아무것도 없으면 가장 가까운
    /// 기록으로 화면이 되돌아가, 아직 비어 있는 앞날을 펼쳐 둘 수 없었다.
    func testPeriodNavigationLandsOnTheNeighborNotOnTheNearestRecord() throws {
        let date = makeDate(2026, 7, 31, 12)
        let engine = TimelinePeriodNavigationEngine(calendar: utcCalendar)
        // 기록은 한참 뒤에만 있다. 어느 배율에서 한 칸을 움직여도 여기에
        // 닿지 않는다.
        let distant = makeDate(2027, 3, 2, 9)
        let snapshot = makeSnapshot(
            plans: [
                PlanRecord(
                    title: "먼 계획",
                    span: TimeSpan(
                        start: distant,
                        end: distant.addingTimeInterval(hour)
                    ),
                    categoryID: "project"
                ),
            ]
        )

        for level in TimelineLevel.allCases {
            let component: Calendar.Component = switch level {
            case .day: .day
            case .week: .weekOfYear
            case .month: .month
            case .year: .year
            }
            for direction in [-1, 1] {
                XCTAssertTrue(
                    engine.canNavigate(
                        from: date,
                        level: level,
                        direction: direction,
                        snapshot: snapshot
                    )
                )
                XCTAssertEqual(
                    engine.adjacentDate(
                        from: date,
                        level: level,
                        direction: direction
                    ),
                    utcCalendar.date(
                        byAdding: component,
                        value: direction,
                        to: date
                    ),
                    "\(level.rawValue) \(direction) should not seek data"
                )
            }
        }
    }

    func testScreenTimeUsageKeepsOneRecordPerApplication() {
        let start = makeDate(2026, 8, 3, 9)
        let span = TimeSpan(start: start, end: start.addingTimeInterval(hour))
        let records = ScreenTimeUsageRecordEngine.records(
            from: [
                ScreenTimeUsageSample(
                    key: "bundle:com.example.maps",
                    title: "어플 · 지도",
                    span: span,
                    duration: 12 * 60,
                    pickups: 3,
                    notifications: 0
                ),
                ScreenTimeUsageSample(
                    key: "bundle:com.example.chat",
                    title: "어플 · 메시지",
                    span: span,
                    duration: 25 * 60,
                    pickups: 8,
                    notifications: 4
                ),
                // 같은 시간대에 다시 나온 같은 앱은 한 줄로 합친다.
                ScreenTimeUsageSample(
                    key: "bundle:com.example.maps",
                    title: "어플 · 지도",
                    span: span,
                    duration: 12 * 60,
                    pickups: 3,
                    notifications: 0
                ),
            ],
            suppressedIDs: []
        )

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(
            Set(records.map(\.title)),
            ["어플 · 지도", "어플 · 메시지"]
        )
        XCTAssertEqual(Set(records.map(\.id)).count, 2)
        XCTAssertTrue(records.allSatisfy { $0.categoryID == "appUsage" })
        XCTAssertTrue(records.allSatisfy { $0.startedAt == start })
        XCTAssertEqual(
            records.first { $0.title == "어플 · 메시지" }?.span().duration,
            25 * 60
        )
        XCTAssertTrue(
            records.allSatisfy { !$0.evidence.contains(where: {
                $0.contains("카테고리")
            }) }
        )
    }

    func testRecordGroupingSortsCategoriesByTotalAndChildrenByStart() {
        let day = makeDate(2026, 8, 4)
        let span = TimeSpan(start: day, end: day.addingTimeInterval(24 * hour))
        let actuals = [
            makeActual(
                "Safari",
                "appUsage",
                start: day.addingTimeInterval(10 * hour),
                minutes: 22,
                source: .appUsage
            ),
            makeActual(
                "카카오톡",
                "appUsage",
                start: day.addingTimeInterval(9 * hour),
                minutes: 38,
                source: .appUsage
            ),
            makeActual(
                "수면",
                "sleep",
                start: day,
                minutes: 7 * 60
            ),
        ]

        let groups = ActualRecordGroupingEngine.groups(
            actuals: actuals,
            in: span,
            categories: CategoryCatalog.builtIn,
            asOf: day.addingTimeInterval(24 * hour)
        )

        XCTAssertEqual(groups.map(\.id), ["sleep", "appUsage"])
        XCTAssertEqual(groups[0].name, "수면")
        // 사용자 카테고리에 없는 자동 줄도 한글 이름을 갖는다.
        XCTAssertEqual(groups[1].name, "어플")
        XCTAssertEqual(groups[0].duration, 7 * hour)
        XCTAssertEqual(groups[1].duration, 60 * 60)
        XCTAssertEqual(groups[1].children.map(\.title), ["카카오톡", "Safari"])
        XCTAssertEqual(groups[1].children.map(\.duration), [38 * 60, 22 * 60])
    }

    func testDayPhaseBucketsCompleteEachPastDayTo24Hours() {
        let day = dayPhaseDay()
        let period = TimeSpan(
            start: day.start,
            end: day.end.addingTimeInterval(24 * hour)
        )
        let buckets = RecordChartEngine.phaseBuckets(
            actuals: [
                sleepActual(0, 7, on: day),
                stationaryContext(.work, 9, 17, on: day),
            ],
            travel: [],
            stays: [],
            placeKinds: [:],
            in: period,
            unit: .day,
            calendar: utcCalendar,
            asOf: period.end
        )

        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(buckets[0].total, 24 * hour)
        XCTAssertEqual(
            buckets[0].slices.first {
                $0.categoryID == DayPhase.unconfirmed.rawValue
            }?.duration,
            9 * hour
        )
        XCTAssertEqual(buckets[1].total, 24 * hour)
        XCTAssertEqual(
            buckets[1].slices.map(\.categoryID),
            [DayPhase.unconfirmed.rawValue]
        )
    }

    func testAutomaticRowVocabularyIsSharedByEverySurface() {
        XCTAssertEqual(TimelineRowKind.appUsage.title, "어플")
        XCTAssertEqual(ScreenTimeUsageRecordEngine.laneTitle, "어플")
        XCTAssertEqual(TaptionWidgetLane.appUsage.title, "어플")
        XCTAssertEqual(
            TaptionWidgetLane.movement.systemImage,
            TimelineRowKind.movement.systemImage
        )
        XCTAssertEqual(TaptionWidgetLane.schedule.title, "일정")
        XCTAssertEqual(TaptionWidgetLane.action.title, "액션")
        XCTAssertEqual(
            TimelineRowOrder.defaults,
            [
                "calendar",
                "location",
                "movement",
                "sleep",
                "activity",
                "appUsage",
                "weather",
                "photo",
                "memo",
            ]
        )
        XCTAssertNil(TimelineRowKind(categoryID: "work"))
        XCTAssertEqual(TimelineRowKind(categoryID: "schedule"), .calendar)
        // 메모도 일정·위치·수면과 같은 자격의 줄이다.
        XCTAssertEqual(TimelineRowKind.memo.title, "메모")
        XCTAssertEqual(TimelineRowKind.memo.systemImage, "note.text")
        XCTAssertEqual(TimelineRowKind(categoryID: "memo"), .memo)
        XCTAssertEqual(
            MemoTimelineEngine.categoryID,
            TimelineRowKind.memo.rawValue
        )
    }

    /// 일과 고리는 60초 안에서 맞닿은 근무만 붙인다. 기록이 이미 한 줄이면
    /// 고리도 한 조각이라, 둘이 서로 다른 그림을 그리지 않는다.
    func testJoinedWorkRecordGivesTheDayPhaseRingOneWorkArc() {
        let dayStart = makeDate(2026, 8, 4, 0, 0)
        let day = TimeSpan(
            start: dayStart,
            end: dayStart.addingTimeInterval(24 * hour)
        )
        let morning = makeDate(2026, 8, 4, 9, 0)
        let stays = [
            officeStay(
                start: morning,
                end: morning.addingTimeInterval(3 * hour),
                floor: 20
            ),
            officeStay(
                start: morning.addingTimeInterval(4 * hour),
                end: morning.addingTimeInterval(9 * hour),
                floor: 2
            ),
        ]
        let readings = officeReadings(
            from: morning,
            count: 55,
            metersFromAnchor: { _ in 0 }
        )
        let records = officeRecords(
            stays: stays,
            readings: readings,
            inside: day
        )
        let phases = DayPhaseEngine.phases(
            actuals: records,
            travel: [],
            stays: stays,
            placeKinds: [officeKey: .company],
            in: day,
            asOf: day.end
        )

        XCTAssertEqual(phases.filter { $0.phase == .work }.count, 1)
        XCTAssertEqual(
            phases.first { $0.phase == .work }?.span,
            TimeSpan(
                start: morning,
                end: morning.addingTimeInterval(9 * hour)
            )
        )
    }

    func testSummaryBucketsSplitRecordsAcrossDayBoundaries() {
        let engine = TimelineAggregationEngine(calendar: utcCalendar)
        let outer = TimeSpan(
            start: makeDate(2026, 7, 1),
            end: makeDate(2026, 7, 8)
        )
        let crossing = PlanRecord(
            title: "밤샘",
            span: TimeSpan(
                start: makeDate(2026, 7, 2, 22, 0),
                end: makeDate(2026, 7, 3, 4, 0)
            ),
            categoryID: "project"
        )
        let morning = PlanRecord(
            title: "오전",
            span: TimeSpan(
                start: makeDate(2026, 7, 3, 9, 0),
                end: makeDate(2026, 7, 3, 11, 0)
            ),
            categoryID: "project"
        )
        let overlapping = PlanRecord(
            title: "겹침",
            span: TimeSpan(
                start: makeDate(2026, 7, 3, 10, 0),
                end: makeDate(2026, 7, 3, 12, 0)
            ),
            categoryID: "project"
        )
        let sleep = ActualRecord(
            planID: nil,
            title: "수면",
            categoryID: "sleep",
            startedAt: makeDate(2026, 7, 2, 23, 0),
            endedAt: makeDate(2026, 7, 3, 5, 0),
            source: .healthKit
        )
        let early = PhotoMoment(
            id: "early",
            capturedAt: makeDate(2026, 7, 3, 8, 0),
            pixelWidth: 100,
            pixelHeight: 100,
            isFavorite: false,
            isHiddenFromTimeline: false
        )
        let late = PhotoMoment(
            id: "late",
            capturedAt: makeDate(2026, 7, 3, 20, 0),
            pixelWidth: 100,
            pixelHeight: 100,
            isFavorite: false,
            isHiddenFromTimeline: false
        )
        let hidden = PhotoMoment(
            id: "hidden",
            capturedAt: makeDate(2026, 7, 3, 21, 0),
            pixelWidth: 100,
            pixelHeight: 100,
            isFavorite: false,
            isHiddenFromTimeline: true
        )

        let buckets = engine.buckets(
            of: .day,
            inside: outer,
            plans: [crossing, morning, overlapping],
            actuals: [sleep],
            photos: [late, early, hidden]
        )

        XCTAssertEqual(buckets.count, 7)

        func duration(
            _ bucket: SummaryBucket,
            _ categoryID: String
        ) -> (planned: TimeInterval, actual: TimeInterval) {
            guard let value = bucket.categories.first(where: {
                $0.categoryID == categoryID
            }) else {
                return (0, 0)
            }
            return (value.planned, value.actual)
        }

        XCTAssertEqual(duration(buckets[1], "project").planned, 2 * hour)
        XCTAssertEqual(duration(buckets[1], "sleep").actual, hour)
        // 겹치는 계획은 합쳐서 센다. 22시–4시 중 4시간에 9시–12시 3시간.
        XCTAssertEqual(duration(buckets[2], "project").planned, 7 * hour)
        XCTAssertEqual(duration(buckets[2], "sleep").actual, 5 * hour)
        XCTAssertEqual(buckets[2].photoCount, 2)
        XCTAssertEqual(buckets[2].representativePhotoID, "early")

        // 기록이 하나도 걸치지 않는 칸도 같은 분류 열쇠를 0으로 남긴다.
        XCTAssertEqual(duration(buckets[0], "project").planned, 0)
        XCTAssertEqual(duration(buckets[0], "sleep").actual, 0)
        XCTAssertEqual(buckets[0].photoCount, 0)
        XCTAssertNil(buckets[0].representativePhotoID)
    }

    // MARK: - 메모는 메모

    func testActivityIsSplitAcrossItsDayPhaseRows() {
        let day = dayPhaseDay()
        let boundary = day.start.addingTimeInterval(7 * hour)
        let activity = TimeSpan(
            start: boundary.addingTimeInterval(-30 * 60),
            end: boundary.addingTimeInterval(30 * 60)
        )
        let assignments = DayPhaseEngine.assignments(
            of: activity,
            to: [
                DayPhaseSpan(
                    phase: .sleep,
                    span: TimeSpan(start: day.start, end: boundary)
                ),
                DayPhaseSpan(
                    phase: .commuteToWork,
                    span: TimeSpan(start: boundary, end: day.end)
                ),
            ]
        )

        XCTAssertEqual(assignments.map(\.phase), [.sleep, .commuteToWork])
        XCTAssertEqual(assignments.map(\.span.duration), [30 * 60, 30 * 60])
    }

    func testDayRecordGroupsShowPhasesWithNestedActivitiesAnd24Hours() {
        let day = dayPhaseDay()
        let sleepEnd = day.start.addingTimeInterval(8 * hour)
        let phases = [
            DayPhaseSpan(
                phase: .sleep,
                span: TimeSpan(start: day.start, end: sleepEnd)
            ),
            DayPhaseSpan(
                phase: .activity,
                span: TimeSpan(start: sleepEnd, end: day.end)
            ),
        ]
        let sleep = ActualRecord(
            planID: nil,
            title: "코어 수면",
            categoryID: "sleep",
            startedAt: day.start.addingTimeInterval(2 * hour),
            endedAt: day.start.addingTimeInterval(3 * hour),
            source: .healthKit
        )
        let walk = ActualRecord(
            planID: nil,
            title: "걷기",
            categoryID: "movement",
            startedAt: sleepEnd.addingTimeInterval(2 * hour),
            endedAt: sleepEnd.addingTimeInterval(3 * hour),
            source: .motion
        )

        let groups = ActualRecordGroupingEngine.phaseGroups(
            phases: phases,
            actuals: [sleep, walk],
            categories: CategoryCatalog.builtIn,
            asOf: day.end
        )

        XCTAssertEqual(groups.map(\.id), ["sleep", "activity"])
        XCTAssertEqual(groups.map(\.children.count), [1, 1])
        XCTAssertEqual(groups[0].children[0].title, "코어 수면")
        XCTAssertEqual(groups[1].children[0].title, "걷기")
        XCTAssertEqual(
            groups.reduce(0) { $0 + $1.duration },
            day.duration,
            accuracy: 0.001
        )
    }

    func testDayPhaseProjectionExcludesLargeUnrelatedHistory() {
        let day = dayPhaseDay()
        let current = [
            sleepActual(-2, 7, on: day),
            stationaryContext(.homeRest, 0, 7, on: day),
            stationaryContext(.work, 9, 18, on: day),
            stationaryContext(.homeRest, 20, 24, on: day),
        ]
        let history = (0..<120_000).map { index in
            let start = day.start.addingTimeInterval(-2 * 86_400 - Double(index) * 60)
            return ActualRecord(
                planID: nil,
                title: "집에서 휴식",
                categoryID: "activity",
                startedAt: start,
                endedAt: start.addingTimeInterval(30),
                source: .location,
                behavior: StationaryContextKind.homeRest.rawValue
            )
        }
        let actuals = history + current
        let expected = DayPhaseEngine.completePhases(
            actuals: current, travel: [], stays: [], placeKinds: [:],
            in: day, asOf: day.end
        )
        let expectedSleep = MapHomeSleepLocationPolicy.spans(actuals: current, in: day)
        let phaseStarted = ProcessInfo.processInfo.systemUptime
        let projected = DayPhaseEngine.completePhases(
            actuals: actuals, travel: [], stays: [], placeKinds: [:],
            in: day, asOf: day.end
        )
        let phaseMilliseconds = (ProcessInfo.processInfo.systemUptime - phaseStarted) * 1_000
        let sleepStarted = ProcessInfo.processInfo.systemUptime
        let sleep = MapHomeSleepLocationPolicy.spans(actuals: actuals, in: day)
        let sleepMilliseconds = (ProcessInfo.processInfo.systemUptime - sleepStarted) * 1_000

        XCTAssertEqual(projected, expected)
        XCTAssertEqual(sleep, expectedSleep)
        XCTAssertEqual(actuals.count, 120_004)
        XCTAssertEqual(actuals.last, current.last)
        print("CPU1006A01 fixture records=\(actuals.count) phases_ms=\(phaseMilliseconds) sleep_ms=\(sleepMilliseconds)")
    }

    /// 일과는 수면·활동·이동·업무처럼 배타적인 대분류 한 줄로 읽힌다.
    func testDayPhaseRingTellsACommuteDayInOrder() throws {
        let day = dayPhaseDay()
        let phases = DayPhaseEngine.phases(
            actuals: [
                sleepActual(0, 7, on: day),
                stationaryContext(.homeRest, 7, 8, on: day),
                stationaryContext(.work, 8.75, 18, on: day),
                stationaryContext(.homeRest, 18.75, 24, on: day),
            ],
            travel: [
                travelLeg(.walking, 8, 8.25, on: day),
                travelLeg(.subway, 8.25, 8.75, on: day),
                travelLeg(.subway, 18, 18.5, on: day),
                travelLeg(.walking, 18.5, 18.75, on: day),
            ],
            stays: [],
            placeKinds: [:],
            in: day,
            asOf: day.end
        )

        XCTAssertEqual(
            phases.map(\.phase.title),
            ["수면", "활동", "이동", "업무", "이동", "활동"]
        )
        // 걷고 타는 두 다리는 한 번의 이동이다.
        XCTAssertEqual(phases[2].span.start, day.start.addingTimeInterval(8 * hour))
        XCTAssertEqual(
            phases[2].span.end,
            day.start.addingTimeInterval(8.75 * hour)
        )
        assertPhasesPartitionTheDay(phases, in: day)
    }

    /// 출발지에서 이동해 도착한 목적지 안에 머무는 동안은 같은 목적지라면
    /// 업무/수업 문맥이 끊기지 않는다. 분류가 잠깐 비어도 등록된 장소가
    /// 근거가 되면 이어붙인다.
    func testDayPhaseRingKeepsWorkOrStudyContinuousWhenDestinationIsNotLeft() throws {
        let day = dayPhaseDay()
        let homeKey = "frequent-home"
        let workKey = "frequent-company"
        let schoolKey = "frequent-school"

        let workPhases = DayPhaseEngine.phases(
            actuals: [
                sleepActual(0, 7, on: day),
                stationaryContext(.work, 9, 10, on: day),
                stationaryContext(.unknownStay, 10, 11, on: day),
                stationaryContext(.work, 11, 18, on: day),
            ],
            travel: [
                travelLeg(.subway, 8, 8.75, on: day),
                travelLeg(.subway, 18, 18.5, on: day),
                travelLeg(.walking, 18.5, 18.75, on: day),
            ],
            stays: [
                homeStay(0, 8, key: homeKey, on: day),
                PlaceStay(
                    placeKey: workKey,
                    displayName: "회사",
                    span: TimeSpan(
                        start: day.start.addingTimeInterval(8.75 * hour),
                        end: day.start.addingTimeInterval(18 * hour)
                    ),
                    confidence: .high,
                    isConfirmed: true
                ),
                homeStay(18.75, 24, key: homeKey, on: day),
            ],
            placeKinds: [homeKey: .home, workKey: .company],
            in: day,
            asOf: day.end
        )

        XCTAssertEqual(
            workPhases.map(\.phase.title),
            ["수면", "이동", "업무", "이동"]
        )
        XCTAssertEqual(
            workPhases.first(where: { $0.phase == .work })?.span.start,
            day.start.addingTimeInterval(8.75 * hour)
        )
        XCTAssertEqual(
            workPhases.first(where: { $0.phase == .work })?.span.end,
            day.start.addingTimeInterval(18 * hour)
        )

        let studyPhases = DayPhaseEngine.phases(
            actuals: [
                sleepActual(0, 7, on: day),
                stationaryContext(.study, 9, 10, on: day),
                stationaryContext(.unknownStay, 10, 11, on: day),
                stationaryContext(.study, 11, 18, on: day),
            ],
            travel: [
                travelLeg(.bus, 8, 8.75, on: day),
                travelLeg(.bus, 18, 18.5, on: day),
                travelLeg(.walking, 18.5, 18.75, on: day),
            ],
            stays: [
                homeStay(0, 8, key: homeKey, on: day),
                PlaceStay(
                    placeKey: schoolKey,
                    displayName: "학교",
                    span: TimeSpan(
                        start: day.start.addingTimeInterval(8.75 * hour),
                        end: day.start.addingTimeInterval(18 * hour)
                    ),
                    confidence: .high,
                    isConfirmed: true
                ),
                homeStay(18.75, 24, key: homeKey, on: day),
            ],
            placeKinds: [homeKey: .home, schoolKey: .school],
            in: day,
            asOf: day.end
        )

        XCTAssertEqual(
            studyPhases.map(\.phase.title),
            ["수면", "이동", "수업", "이동"]
        )
        XCTAssertEqual(
            studyPhases.first(where: { $0.phase == .study })?.span.start,
            day.start.addingTimeInterval(8.75 * hour)
        )
        XCTAssertEqual(
            studyPhases.first(where: { $0.phase == .study })?.span.end,
            day.start.addingTimeInterval(18 * hour)
        )
        assertPhasesPartitionTheDay(workPhases, in: day)
        assertPhasesPartitionTheDay(studyPhases, in: day)
    }

    func testReturningToCompanyKeepsLunchActivityUnderWork() throws {
        let day = dayPhaseDay()
        let companyKey = "frequent-company"
        let lunch = TimeSpan(
            start: day.start.addingTimeInterval(12.1 * hour),
            end: day.start.addingTimeInterval(12.9 * hour)
        )
        let phases = DayPhaseEngine.phases(
            actuals: [
                stationaryContext(.mealPlace, 12.1, 12.9, on: day),
            ],
            travel: [],
            stays: [
                PlaceStay(
                    placeKey: companyKey,
                    displayName: "회사",
                    span: TimeSpan(
                        start: day.start.addingTimeInterval(9 * hour),
                        end: day.start.addingTimeInterval(12 * hour)
                    ),
                    confidence: .high,
                    isConfirmed: true
                ),
                PlaceStay(
                    placeKey: companyKey,
                    displayName: "회사",
                    span: TimeSpan(
                        start: day.start.addingTimeInterval(13 * hour),
                        end: day.start.addingTimeInterval(18 * hour)
                    ),
                    confidence: .high,
                    isConfirmed: true
                ),
            ],
            placeKinds: [companyKey: .company],
            in: day,
            asOf: day.end
        )

        let parent = try XCTUnwrap(
            phases.first { $0.span.contains(lunch.start) }
        )
        XCTAssertEqual(parent.phase, .work)
        XCTAssertEqual(
            DayPhaseEngine.assignments(of: lunch, to: phases).map(\.phase),
            [.work]
        )
    }

    /// 학교에 닿으면 이동의 목적은 활동 상세에 남고 일과는 수업으로 읽힌다.
    func testDayPhaseRingSaysSchoolWordsWhenArrivingAtStudy() throws {
        let day = dayPhaseDay()
        let homeKey = "frequent-home"
        let phases = DayPhaseEngine.phases(
            actuals: [
                sleepActual(0, 6.5, on: day),
                stationaryContext(.study, 8.2, 16, on: day),
            ],
            travel: [
                travelLeg(.walking, 7, 7.5, on: day),
                travelLeg(.bus, 7.5, 8, on: day),
                travelLeg(.bus, 16, 16.5, on: day),
            ],
            // 집이라는 사실은 자주가는 곳으로 확정된 체류에서도 온다.
            stays: [
                homeStay(0, 7, key: homeKey, on: day),
                homeStay(16.5, 24, key: homeKey, on: day),
            ],
            placeKinds: [homeKey: .home],
            in: day,
            asOf: day.end
        )

        XCTAssertEqual(
            phases.map(\.phase.title),
            ["수면", "이동", "수업", "이동"]
        )
        assertPhasesPartitionTheDay(phases, in: day)
    }

    /// 오감이 없는 날은 빈칸으로 남는다. 주말도 재택도 지어낸 이름을 갖지
    /// 않고, 그래도 화면이 망가진 것처럼 보이지 않는다.
    func testDayPhaseRingLeavesGapsWhenThereIsNoCommute() throws {
        let day = dayPhaseDay()
        let weekend = DayPhaseEngine.phases(
            actuals: [
                sleepActual(0, 8, on: day),
                stationaryContext(.homeRest, 8, 12, on: day),
                stationaryContext(.housework, 12, 13, on: day),
                stationaryContext(.homeRest, 13, 24, on: day),
            ],
            travel: [],
            stays: [],
            placeKinds: [:],
            in: day,
            asOf: day.end
        )
        XCTAssertEqual(weekend.map(\.phase), [.sleep, .activity])
        assertPhasesPartitionTheDay(weekend, in: day)

        let workedFromHome = DayPhaseEngine.phases(
            actuals: [
                sleepActual(0, 7, on: day),
                stationaryContext(.homeRest, 7, 9, on: day),
                stationaryContext(.work, 9, 18, on: day),
                stationaryContext(.homeRest, 18, 24, on: day),
            ],
            travel: [],
            stays: [],
            placeKinds: [:],
            in: day,
            asOf: day.end
        )
        XCTAssertEqual(
            workedFromHome.map(\.phase),
            [.sleep, .activity, .work, .activity]
        )
        assertPhasesPartitionTheDay(workedFromHome, in: day)
    }

    /// 조각이 화소보다 얇으면 그리지 않고 이웃에 합친다. 안쪽 띠와 같은
    /// 기준을 쓰므로 눈금판에 규칙이 두 벌 생기지 않는다.
    func testDayPhaseRingMergesShortPhasesInsteadOfDrawingSlivers() throws {
        let day = dayPhaseDay()
        let actuals = [
            sleepActual(0, 7, on: day),
            stationaryContext(.homeRest, 7, 8, on: day),
            stationaryContext(.work, 8.75, 12, on: day),
            // 근무 사이에 낀 3.6분짜리 수업. 그리면 보이지도 않는다.
            stationaryContext(.study, 12, 12.06, on: day),
            stationaryContext(.work, 12.06, 18, on: day),
            stationaryContext(.homeRest, 18.75, 24, on: day),
        ]
        let travel = [
            travelLeg(.subway, 8, 8.75, on: day),
            travelLeg(.subway, 18, 18.75, on: day),
        ]
        let phases = DayPhaseEngine.phases(
            actuals: actuals,
            travel: travel,
            stays: [],
            placeKinds: [:],
            in: day,
            asOf: day.end
        )
        // 나누기 단계에서는 짧은 수업도 제 자리를 지킨다.
        XCTAssertEqual(
            phases.map(\.phase),
            [.sleep, .activity, .movement, .work, .study, .work,
             .movement, .activity]
        )
        assertPhasesPartitionTheDay(phases, in: day)

        let ring = try XCTUnwrap(
            RecordClockDetailEngine.phaseRing(
                actuals: actuals,
                travel: travel,
                stays: [],
                placeKinds: [:],
                in: day,
                asOf: day.end
            )
        )
        XCTAssertEqual(ring.kind, .dayPhase)
        // 그릴 때는 앞선 업무가 그 자리를 이어받는다.
        XCTAssertEqual(
            ring.arcs.map(\.token),
            ["sleep", "activity", "movement", "work", "movement", "activity"]
        )
        XCTAssertEqual(ring.arcs[3].endFraction, 18.0 / 24, accuracy: 1e-9)
        assertRingHasNoSlivers(ring)
    }

    /// 등록해 두지 않은 곳에 다녀온 길은 이름을 지어내지 않는다. 도착해서
    /// 근무나 수업이 시작되면 예전처럼 출근·퇴근이라 부르고, 그마저 없으면
    /// 빈칸으로 남긴다.
    func testDayPhaseRingFallsBackWhenTheFarEndIsNotRegistered() {
        let known = roundTripPhases(
            to: .company,
            staying: .work,
            registeringDestination: false
        )
        XCTAssertEqual(
            known.map(\.phase.title),
            ["수면", "이동", "업무", "이동"]
        )

        let unknown = roundTripPhases(
            to: .hobby,
            staying: .cafe,
            registeringDestination: false
        )
        XCTAssertEqual(unknown.map(\.phase.title), ["수면", "이동", "활동", "이동"])

        // 등록은 했지만 종류에 이름이 없는 곳도 같은 자리로 떨어진다.
        let custom = roundTripPhases(to: .custom, staying: .cafe)
        XCTAssertEqual(custom.map(\.phase.title), ["수면", "이동", "활동", "이동"])
    }

    /// 읽음창은 짚은 조각의 진짜 시작·끝 시각을 적는다. 각도로 접었다 펴도
    /// 8시 12분이 8시 11분으로 새지 않아야 한다.
    func testPhaseReadoutReportsTheTrueStartAndEnd() throws {
        let day = dayPhaseDay()
        func at(_ hours: Int, _ minutes: Int) -> Date {
            day.start.addingTimeInterval(
                TimeInterval(hours * 3_600 + minutes * 60)
            )
        }
        let leaving = TimeSpan(start: at(8, 12), end: at(8, 47))
        let ring = try XCTUnwrap(
            RecordClockDetailEngine.phaseRing(
                actuals: [
                    sleepActual(0, 7, on: day),
                    ActualRecord(
                        planID: nil,
                        title: StationaryContextKind.work.title,
                        categoryID: StationaryContextKind.work.categoryID,
                        startedAt: leaving.end,
                        endedAt: at(18, 0),
                        source: .location,
                        confidence: .medium,
                        behavior: StationaryContextKind.work.rawValue,
                        modelVersion: StationaryContextClassifier.modelVersion
                    ),
                ],
                travel: [
                    TravelSegment(
                        mode: .subway,
                        span: leaving,
                        distanceMeters: 4_000,
                        confidence: .medium,
                        evidence: ["GPS"]
                    ),
                ],
                stays: [
                    PlaceStay(
                        placeKey: "frequent-home",
                        displayName: "집",
                        span: TimeSpan(start: day.start, end: leaving.start),
                        confidence: .high,
                        isConfirmed: true
                    ),
                ],
                placeKinds: ["frequent-home": .home],
                in: day,
                asOf: day.end
            )
        )

        let arc = try XCTUnwrap(
            ring.arcs.first { $0.token == DayPhase.movement.rawValue }
        )
        // 재생머리가 그 조각 위를 지날 때 읽는 조각도 같은 조각이다.
        XCTAssertEqual(
            RecordClockEngine.arc(
                in: ring,
                at: (arc.startFraction + arc.endFraction) / 2
            ),
            arc
        )
        let span = RecordClockEngine.span(of: arc, in: day)
        XCTAssertEqual(span.start, leaving.start)
        XCTAssertEqual(span.end, leaving.end)
        XCTAssertEqual(
            RecordClockEngine.timeRangeText(span),
            "\(leaving.start.formatted(date: .omitted, time: .shortened))"
                + "–"
                + "\(leaving.end.formatted(date: .omitted, time: .shortened))"
        )
    }

    /// 스크린 타임은 화면에 뜨지 않는 iOS 서비스 프로세스까지 앱으로 올려
    /// 준다. 애플 번들 ID인데 시스템이 이름을 내주지 않은 줄만 감춘다.
    func testAppUsageRecordsHideAppleInternalServices() {
        let start = makeDate(2026, 8, 5, 9, 0)
        let samples = [
            makeUsageSample(
                key: "bundle:com.apple.ScreenshotServicesService",
                title: "ScreenshotServicesService",
                nameSource: .bundleIdentifier,
                start: start
            ),
            makeUsageSample(
                key: "bundle:com.apple.LocalAuthenticationUIService",
                title: "LocalAuthenticationUIService",
                nameSource: .bundleIdentifier,
                start: start
            ),
            makeUsageSample(
                key: "bundle:com.apple.mobilesafari",
                title: "Safari",
                nameSource: .application,
                start: start
            ),
            makeUsageSample(
                key: "bundle:com.apple.Maps",
                title: "지도",
                nameSource: .application,
                start: start
            ),
            makeUsageSample(
                key: "bundle:com.jumpdesktop.ios",
                title: "Jumpdesktop",
                nameSource: .bundleIdentifier,
                start: start
            ),
            makeUsageSample(
                key: "category:생산성",
                title: "생산성",
                nameSource: .category,
                start: start
            ),
            makeUsageSample(
                key: "total",
                title: "어플",
                nameSource: .unknown,
                start: start
            ),
        ]

        let records = ScreenTimeUsageRecordEngine.records(
            from: samples,
            suppressedIDs: []
        )

        // 이름이 온 애플 앱, 다른 회사 앱, 카테고리·합계 줄은 그대로 남는다.
        XCTAssertEqual(
            Set(records.map(\.title)),
            ["Safari", "지도", "Jumpdesktop", "생산성", "어플"]
        )
        XCTAssertTrue(
            samples
                .filter(ScreenTimeUsageRecordEngine.isHiddenSystemService)
                .map(\.title)
                .sorted()
                == ["LocalAuthenticationUIService", "ScreenshotServicesService"]
        )
    }

}
