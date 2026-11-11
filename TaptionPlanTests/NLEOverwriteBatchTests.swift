import XCTest
import TaptionPlanCore
@testable import TaptionPlan

/// 전체 덮기의 대표 결정 여섯 가지(OVW1108A01): 상세활동 지움, 직접 입력 건너뛰기,
/// 수면 변화 안내, 한 번에 저장·실패 시 모두 되돌림, 원본 구간끼리만 합치기, 되돌리기 한 칸.
@MainActor
final class NLEOverwriteBatchTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }()

    private var dayStart: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 23))!
    }

    private func at(_ minute: Int) -> Date {
        dayStart.addingTimeInterval(TimeInterval(minute * 60))
    }

    private func option(_ categoryID: String) -> ActivityCorrectionOption {
        MapHomeNLEClipEditor.option(forCategoryID: categoryID, title: categoryID, behavior: nil)
    }

    private func segment(_ start: Int, _ end: Int, _ categoryID: String, _ source: UUID) -> MapHomeTimeRailSegment {
        MapHomeTimeRailSegment(
            startMinute: start, endMinute: end, categoryID: categoryID, title: categoryID, sourceIDs: [source]
        )
    }

    private func record(
        _ id: UUID, _ start: Int, _ end: Int, _ categoryID: String,
        source: ActualSource = .healthKit, manual: Bool = false
    ) -> ActualRecord {
        ActualRecord(
            id: id, planID: nil, title: categoryID, categoryID: categoryID,
            startedAt: at(start), endedAt: at(end), source: source,
            evidence: [manual ? "사용자 입력" : "HealthKit"],
            modelVersion: manual ? "manual-entry-test" : nil,
            manuallyCorrected: manual
        )
    }

    // MARK: - 1. 상세활동도 지움

    func testDetailsStayByDefaultAndClearOnlyInsideTheOverwrittenRange() throws {
        let work = UUID(), meal = UUID()
        let segments = [segment(0, 600, "work", work), segment(600, 1_440, "eating", meal)]
        let track = MapHomeNLEClipEditor.makeMainTrack(segments: segments)
        let insideID = UUID(), outsideID = UUID()
        let details = [
            MapHomeSectionDetail(id: insideID, title: "회의", categoryID: "work", behavior: "meeting",
                                 startMinute: 120, endMinute: 180),
            MapHomeSectionDetail(id: outsideID, title: "간식", categoryID: "eating", behavior: "snack",
                                 startMinute: 700, endMinute: 730),
        ]
        let sub = MapHomeNLEClipEditor.makeSubTrack(details: details, segments: segments)
        let study = option("study")

        let kept = NLEOverwritePolicy.apply(
            track, subTrack: sub, option: study, scope: .sameCategory,
            selectedCategoryID: "work", mergesAfter: false
        )
        XCTAssertEqual(kept.removedDetails, 0)
        XCTAssertEqual(kept.subTrack, sub, "기본은 상세활동을 그대로 둔다")

        let cleared = NLEOverwritePolicy.apply(
            track, subTrack: sub, option: study, scope: .sameCategory,
            selectedCategoryID: "work", mergesAfter: false, clearsDetails: true
        )
        XCTAssertEqual(cleared.removedDetails, 1)
        let clearedSub = try XCTUnwrap(cleared.subTrack)
        XCTAssertEqual(clearedSub.clip(atMinute: 150)?.option, study, "범위 안 상세활동은 새 분류로 채운다")
        XCTAssertEqual(clearedSub.clip(atMinute: 710)?.option.behavior, "snack", "범위 밖 상세활동은 남는다")
        XCTAssertEqual(
            NLEOverwritePolicy.detailCount(
                sub, inside: NLEOverwritePolicy.targets(track, option: study, scope: .sameCategory, selectedCategoryID: "work"),
                fill: study
            ),
            1,
            "창이 보여 주는 수와 지우는 수가 같다"
        )
    }

    func testDetailCrossingTheRangeIsClearedOnlyInside() throws {
        var sub = NLETrack(
            clips: [
                NLEClip(
                    id: "sub|a", option: option("walking"), startMinute: 500, endMinute: 700,
                    parent: NLEClipParent(startMinute: 0, endMinute: 1_440, sourceIDs: [UUID()],
                                          option: option("walking"), fillOption: option("work")),
                    origin: NLEClipOrigin(startMinute: 500, endMinute: 700, option: option("walking"))
                ),
            ],
            fillsGaps: false
        )
        let removed = NLEOverwritePolicy.clearDetails(&sub, inside: [600..<1_440], fill: option("study"))
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(sub.clip(atMinute: 550)?.option.categoryID, "walking")
        XCTAssertEqual(sub.clip(atMinute: 650)?.option.categoryID, "study")
    }

    // MARK: - 2. 직접 입력 기록

    /// 대표 신고(2026-11-11): 미확인도 덮이고, 여러 개 골라 한 번에 덮는다. 미확인을 덮은 것도 저장 요청이 된다.
    func testUnconfirmedAndPickedClipsAreOverwritten() throws {
        let work = UUID(), meal = UUID()
        // 시간 띠의 미확인 구간은 원본 기록이 없다. 원본 없이 채운 다른 분류(활동)는 덮지 않는다.
        let unconfirmed = MapHomeTimeRailSegment(startMinute: 600, endMinute: 900, categoryID: "unconfirmed", title: "미확인", sourceIDs: [])
        let invented = MapHomeTimeRailSegment(startMinute: 1_300, endMinute: 1_440, categoryID: "activity", title: "activity", sourceIDs: [])
        let track = MapHomeNLEClipEditor.makeMainTrack(segments: [
            segment(0, 600, "work", work), unconfirmed, segment(900, 1_300, "eating", meal), invented,
        ])
        let gap = try XCTUnwrap(track.clip(atMinute: 700))
        XCTAssertTrue(gap.isGap)
        XCTAssertEqual(NLEOverwritePolicy.affectedCount(track, scope: .wholeDay, selectedCategoryID: nil), 3)

        let whole = NLEOverwritePolicy.apply(track, option: option("study"), scope: .wholeDay, selectedCategoryID: nil, mergesAfter: false)
        XCTAssertEqual(whole.track.clip(atMinute: 700)?.option.categoryID, "study", "unconfirmed is overwritten too")
        XCTAssertEqual(whole.track.clip(atMinute: 1_350)?.option.categoryID, "activity", "time filled without a record stays")
        let requests = whole.track.editRequests(dayStart: dayStart, calendar: calendar)
        let covered = requests.flatMap { ActivitySectionOverrideEngine.pieces(for: $0) }
            .filter { $0.span.start <= at(700) && $0.span.end > at(700) }
        XCTAssertEqual(covered.map(\.option.categoryID), ["study"], "the unconfirmed span is saved as a user cover")

        let picked: Set<String> = [gap.id, try XCTUnwrap(track.clip(atMinute: 1_000)).id]
        let some = NLEOverwritePolicy.apply(
            track, option: option("rest"), scope: .picked, selectedCategoryID: nil, mergesAfter: true, pickedClipIDs: picked
        )
        XCTAssertEqual(some.changed, 2)
        XCTAssertEqual(some.track.clip(atMinute: 700)?.option.categoryID, "rest")
        XCTAssertEqual(some.track.clip(atMinute: 1_000)?.option.categoryID, "rest")
        XCTAssertEqual(some.track.clip(atMinute: 100)?.option.categoryID, "work", "unpicked clips stay")
        XCTAssertEqual(NLEOverwritePolicy.affectedCount(track, scope: .picked, selectedCategoryID: nil, pickedClipIDs: picked), 2)
    }

    /// RNG1111A01: 조각난 클립을 끌어 한 번에 고르고 업무로 덮으면, 원본 구간이 달라도 한 덩어리가 되고
    /// 각 원본 기록에는 그 시간만큼 업무 조각이 저장된다.
    func testRangePickedFragmentsMergeIntoOneClip() throws {
        let work = UUID(), home1 = UUID(), home2 = UUID(), rest = UUID(), move = UUID()
        let track = MapHomeNLEClipEditor.makeMainTrack(segments: [
            segment(732, 996, "work", work),
            MapHomeTimeRailSegment(startMinute: 996, endMinute: 1_020, categoryID: "unconfirmed", title: "미확인", sourceIDs: []),
            segment(1_020, 1_060, "household", home1),
            segment(1_060, 1_150, "rest", rest),
            segment(1_150, 1_197, "household", home2),
            segment(1_197, 1_250, "eating", move),
        ])
        let first = try XCTUnwrap(track.clip(atMinute: 800))
        // 업무 끝에서 이동 바로 앞까지 끈다. 이동은 고르지 않는다.
        let picked = Set([first.id]).union(track.clipIDs(from: 990, to: 1_196))
        XCTAssertEqual(picked.count, 5)
        XCTAssertNil(picked.first { track.clip($0)?.option.categoryID == "eating" })

        let result = NLEOverwritePolicy.apply(
            track, option: option("work"), scope: .picked, selectedCategoryID: nil, mergesAfter: true, pickedClipIDs: picked
        )
        let merged = try XCTUnwrap(result.track.clip(atMinute: 1_100))
        XCTAssertEqual(merged.option.categoryID, "work")
        XCTAssertEqual(merged.startMinute, 732)
        XCTAssertEqual(merged.endMinute, 1_197)
        XCTAssertEqual(merged.id, first.id, "the longest recorded clip survives")
        XCTAssertEqual(result.track.clip(atMinute: 1_200)?.option.categoryID, "eating")

        let requests = result.track.editRequests(dayStart: dayStart, calendar: calendar)
        for source in [home1, rest, home2] {
            let request = try XCTUnwrap(requests.first { $0.sourceIDs == [source] })
            XCTAssertEqual(ActivitySectionOverrideEngine.pieces(for: request).map(\.option.categoryID), ["work"])
        }
    }

    /// UNC1111A01: 사이드바에서 고른 미확인 구간 여러 개가 한 번의 일괄 저장 요청으로 바뀐다. 미확인이 아닌 구간은 빠진다.
    func testUnconfirmedBatchBuildsOneRequestPerPickedSpan() throws {
        let category = try XCTUnwrap(MapHomeSidebarMajorCategory.all.first { $0.id == "work" })
        let spans = [
            MapHomeTimeRailSegment(startMinute: 1_011, endMinute: 1_020, categoryID: "unconfirmed", title: "미확인", sourceIDs: []),
            MapHomeTimeRailSegment(startMinute: 1_022, endMinute: 1_045, categoryID: "unconfirmed", title: "미확인", sourceIDs: []),
            MapHomeTimeRailSegment(startMinute: 1_050, endMinute: 1_060, categoryID: "eating", title: "eating", sourceIDs: []),
        ]
        let requests = spans.compactMap { MapHomeUnconfirmedBatch.request(for: $0, category: category, day: dayStart, calendar: calendar) }
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map(\.originalSpan.start), [at(1_011), at(1_022)])
        let pieces = requests.flatMap { ActivitySectionOverrideEngine.pieces(for: $0) }
        XCTAssertEqual(Set(pieces.map(\.option.categoryID)), ["work"])
    }

    func testUserOwnedClipsAreSkippedWhenAskedAndCounted() {
        let automatic = UUID(), entered = UUID()
        let track = MapHomeNLEClipEditor.makeMainTrack(segments: [
            segment(0, 600, "work", automatic), segment(600, 1_440, "eating", entered),
        ])
        let userOwned = MapHomeNLEClipEditor.userOwnedSourceIDs(
            in: track,
            actuals: [record(automatic, 0, 600, "work"), record(entered, 600, 1_440, "eating", source: .manual, manual: true)],
            corrections: [:]
        )
        XCTAssertEqual(userOwned, [entered], "자동 기록은 직접 입력이 아니다")

        let skipped = NLEOverwritePolicy.apply(
            track, option: option("study"), scope: .wholeDay, selectedCategoryID: nil,
            mergesAfter: true, userOwnedSourceIDs: userOwned, includesUserOwned: false
        )
        XCTAssertEqual(skipped.changed, 1)
        XCTAssertEqual(skipped.skipped, 1)
        XCTAssertEqual(skipped.track.clip(atMinute: 700)?.option.categoryID, "eating")
        let requests = skipped.track.editRequests(dayStart: dayStart, calendar: calendar)
        XCTAssertFalse(requests.contains { $0.sourceIDs.contains(entered) }, "건너뛴 기록에는 저장 요청이 없다")

        let included = NLEOverwritePolicy.apply(
            track, option: option("study"), scope: .wholeDay, selectedCategoryID: nil,
            mergesAfter: true, userOwnedSourceIDs: userOwned, includesUserOwned: true
        )
        XCTAssertEqual(included.changed, 2)
        XCTAssertEqual(included.skipped, 0)
    }

    func testCorrectedAutomaticRecordCountsAsUserOwned() {
        let corrected = UUID()
        let track = MapHomeNLEClipEditor.makeMainTrack(segments: [segment(0, 1_440, "work", corrected)])
        let ids = MapHomeNLEClipEditor.userOwnedSourceIDs(
            in: track,
            actuals: [record(corrected, 0, 1_440, "work")],
            corrections: [corrected: ActivityCorrection(title: "업무", behavior: nil, categoryID: "work")]
        )
        XCTAssertEqual(ids, [corrected])
    }

    // MARK: - 3. 수면 변화

    func testSleepChangeIsMeasuredInHoursBeforeApplying() {
        let track = MapHomeNLEClipEditor.makeMainTrack(segments: [
            segment(0, 420, "sleep", UUID()), segment(420, 510, "work", UUID()), segment(510, 1_440, "eating", UUID()),
        ])
        let toStudy = NLEOverwritePolicy.targets(track, option: option("study"), scope: .wholeDay, selectedCategoryID: nil)
        XCTAssertEqual(NLEOverwritePolicy.sleepMinutesChanged(toStudy, to: option("study")), 420)
        XCTAssertEqual(NLEOverwritePolicy.sleepChangeText(minutes: 420, language: .korean), "수면 7.0시간이 바뀝니다")

        let toSleep = NLEOverwritePolicy.targets(track, option: option("sleep"), scope: .sameCategory, selectedCategoryID: "work")
        XCTAssertEqual(NLEOverwritePolicy.sleepMinutesChanged(toSleep, to: option("sleep")), 90)
        XCTAssertEqual(NLEOverwritePolicy.sleepChangeText(minutes: 90, language: .korean), "수면 1.5시간이 바뀝니다")
        XCTAssertNil(NLEOverwritePolicy.sleepChangeText(minutes: 0, language: .korean), "수면이 그대로면 알리지 않는다")
    }

    // MARK: - 5. 원본 구간끼리만 합치기

    func testMergeNeverJoinsDifferentSourceSegments() {
        let track = MapHomeNLEClipEditor.makeMainTrack(segments: [
            segment(0, 600, "work", UUID()), segment(600, 1_440, "eating", UUID()),
        ])
        let result = NLEOverwritePolicy.apply(
            track, option: option("study"), scope: .wholeDay, selectedCategoryID: nil, mergesAfter: true
        )
        XCTAssertEqual(result.changed, 2)
        XCTAssertEqual(result.merged, 0, "같은 분류가 되어도 원본 구간이 다르면 합치지 않는다")
        XCTAssertEqual(result.track.clips.filter { !$0.isGap }.count, 2)
        XCTAssertEqual(result.track.editRequests(dayStart: dayStart, calendar: calendar).count, 2)
    }

    // MARK: - 4·6. 한 번에 저장, 실패 시 모두 되돌림, 되돌리기 한 칸

    private struct Fixture {
        let model: AppModel
        let repository: OverwriteSaveRepository
        let main: [ActivitySectionEditRequest]
        let detail: [ActivitySectionEditRequest]
    }

    /// 수면·업무·직접 입력 식사 세 구간과 업무 안 상세활동 하나. 하루 전체를 수면으로 덮고 상세도 지운다.
    /// 확정 수면이 자동 기록을 자르므로 되돌리기가 자동 기록의 표시 사본까지 돌려놓는지 함께 본다.
    private func makeFixture() async throws -> Fixture {
        let sleep = UUID(), work = UUID(), meal = UUID(), meeting = UUID()
        var stored = TaptionDataSnapshot.empty
        stored.categories = CategoryCatalog.builtIn
        stored.actuals = [
            record(sleep, 0, 420, "sleep"),
            record(work, 420, 900, "work"),
            record(meeting, 480, 540, "work"),
            record(meal, 900, 1_440, "eating", source: .manual, manual: true),
        ]
        stored.settings.locationEnabled = false
        stored.settings.weatherEnabled = false
        stored.settings.healthEnabled = false
        let repository = OverwriteSaveRepository(snapshot: stored)
        let model = AppModel(repository: repository, cloudSyncService: nil, registersHealthBackgroundHandler: false)
        await model.bootstrap()

        let segments = [segment(0, 420, "sleep", sleep), segment(420, 900, "work", work), segment(900, 1_440, "eating", meal)]
        let track = MapHomeNLEClipEditor.makeMainTrack(segments: segments)
        let sub = MapHomeNLEClipEditor.makeSubTrack(
            details: [MapHomeSectionDetail(id: meeting, title: "회의", categoryID: "work", behavior: "meeting",
                                           startMinute: 480, endMinute: 540)],
            segments: segments
        )
        let result = NLEOverwritePolicy.apply(
            track, subTrack: sub, option: option("sleep"), scope: .wholeDay,
            selectedCategoryID: nil, mergesAfter: true, clearsDetails: true
        )
        XCTAssertEqual(result.changed, 2, "이미 수면인 클립은 세지 않는다")
        XCTAssertEqual(result.removedDetails, 1)
        let main = result.track.editRequests(dayStart: dayStart, calendar: calendar)
        let detail = try XCTUnwrap(result.subTrack).editRequests(dayStart: dayStart, calendar: calendar)
        XCTAssertGreaterThan(main.count, 1, "여러 구간을 한 번에 저장하는 경우다")
        XCTAssertFalse(detail.isEmpty)
        return Fixture(model: model, repository: repository, main: main, detail: detail)
    }

    func testBatchSaveWritesOnceAndFailureRollsBackEverything() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        let before = model.snapshot
        let storedBefore = try await fixture.repository.load()
        let undoCount = model.userEditUndoHistory.count
        await fixture.repository.setFailing(true)
        let savesBefore = await fixture.repository.saveCount

        let saved = await model.saveClipEditBatch(main: fixture.main, detail: fixture.detail)

        XCTAssertFalse(saved)
        let attempts = await fixture.repository.saveCount - savesBefore
        XCTAssertEqual(attempts, 1, "여러 구간이어도 저장은 한 번이다")
        XCTAssertEqual(model.snapshot.actuals, before.actuals, "실패하면 메모리도 편집 전으로 돌아간다")
        XCTAssertEqual(model.snapshot.settings.confirmedSleepSpans, before.settings.confirmedSleepSpans)
        let storedAfter = try await fixture.repository.load()
        XCTAssertEqual(storedAfter.actuals, storedBefore.actuals, "저장소에도 반쯤 남지 않는다")
        XCTAssertEqual(model.userEditUndoHistory.count, undoCount, "저장하지 못한 편집은 되돌리기에 쌓지 않는다")
    }

    func testBatchSaveIsOneUndoEntryThatRestoresEveryRecord() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        let before = model.snapshot
        let undoCount = model.userEditUndoHistory.count
        let savesBefore = await fixture.repository.saveCount

        let saved = await model.saveClipEditBatch(main: fixture.main, detail: fixture.detail)

        XCTAssertTrue(saved)
        let writes = await fixture.repository.saveCount - savesBefore
        XCTAssertEqual(writes, 1, "구간마다 저장하지 않고 한 번에 쓴다")
        XCTAssertEqual(model.userEditUndoHistory.count, undoCount + 1, "덮기 한 번은 되돌리기 한 칸이다")
        XCTAssertNotEqual(model.snapshot.settings.confirmedSleepSpans, before.settings.confirmedSleepSpans,
                          "하루를 수면으로 덮었으니 확정 수면이 바뀐다")
        XCTAssertNotEqual(model.snapshot.actuals, before.actuals)

        model.undoLastUserEdit()

        XCTAssertEqual(
            model.snapshot.actuals.sorted { $0.id.uuidString < $1.id.uuidString },
            before.actuals.sorted { $0.id.uuidString < $1.id.uuidString },
            "직접 입력·상세활동·수면을 포함해 모든 기록이 돌아온다"
        )
        XCTAssertEqual(model.snapshot.settings.confirmedSleepSpans, before.settings.confirmedSleepSpans)
        XCTAssertEqual(model.userEditUndoHistory.count, undoCount)
    }
}

/// 저장 횟수를 세고, 켜 두면 저장을 거절하는 저장소.
actor OverwriteSaveRepository: PlanDataRepository {
    private var snapshot: TaptionDataSnapshot
    private var failing = false
    private(set) var saveCount = 0

    init(snapshot: TaptionDataSnapshot) {
        self.snapshot = snapshot
    }

    func setFailing(_ value: Bool) {
        failing = value
    }

    func load() async throws -> TaptionDataSnapshot {
        snapshot
    }

    func save(_ snapshot: TaptionDataSnapshot) async throws {
        saveCount += 1
        if failing { throw CocoaError(.fileWriteUnknown) }
        self.snapshot = snapshot
    }

    func deleteAll() async throws {
        snapshot = .empty
    }
}
