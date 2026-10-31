import XCTest
import UIKit
import CoreLocation
import StoreKit
import StoreKitTest
import TaptionPlanCore
@testable import TaptionPlan

/// NLE 클립 편집: 대분류 24시간 트랙, 서브클립, 자르기·가르기·옮기기·스냅.
/// NLE 트랙 편집은 `MapHomeNLEClipEditor`의 메인 액터 정적 메서드를 부른다.
/// XCTest는 테스트를 메인 스레드에서 돌리므로 클래스 전체를 메인 액터로 둔다.
@MainActor
final class NLETrackTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }()

    private func dayStart() -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 23))!
    }

    private func segment(
        _ start: Int,
        _ end: Int,
        _ categoryID: String,
        sources: [UUID] = []
    ) -> MapHomeTimeRailSegment {
        MapHomeTimeRailSegment(
            startMinute: start,
            endMinute: end,
            categoryID: categoryID,
            title: categoryID,
            sourceIDs: sources
        )
    }

    /// 가운데 구간이 앞뒤 시간을 품지 않는 하루. 경계 시험용이다.
    private func threeSegmentDay(sources: [UUID]) -> [MapHomeTimeRailSegment] {
        [
            segment(0, 300, "sleep"),
            segment(300, 540, "work", sources: sources),
            segment(540, 1_440, "activity"),
        ]
    }

    /// 끝을 여러 번 당겨도 비운 자리는 미확인 하나로 합쳐진다(대표 지적, UXP1024D20 ④).
    func testRepeatedTrimsKeepSingleUnconfirmedGap() {
        var track = MapHomeNLEClipEditor.makeMainTrack(
            segments: threeSegmentDay(sources: [UUID()])
        )
        guard let work = track.clip(atMinute: 400) else {
            return XCTFail("업무 클립이 없다")
        }
        track.trim(work.id, edge: .end, toMinute: 520)
        XCTAssertEqual(track.clips.filter(\.isGap).count, 1)
        track.trim(work.id, edge: .end, toMinute: 480)
        let gaps = track.clips.filter(\.isGap)
        XCTAssertEqual(gaps.count, 1, "끝을 다시 당겨도 미확인은 하나여야 한다")
        XCTAssertEqual(gaps.first?.startMinute, 480)
        XCTAssertEqual(gaps.first?.endMinute, 540)
    }

    /// 하루 트랙은 기록이 없어도 24시간을 빈틈없이 채운다.
    func testMainTrackAlwaysCoversTwentyFourHours() {
        let track = MapHomeNLEClipEditor.makeMainTrack(segments: [
            segment(0, 360, "sleep"),
            segment(360, 600, "work"),
        ])

        XCTAssertEqual(track.totalLengthMinutes, NLETrack.dayMinutes)
        XCTAssertEqual(track.clips.first?.startMinute, 0)
        XCTAssertEqual(track.clips.last?.endMinute, NLETrack.dayMinutes)
        XCTAssertEqual(
            track.clips.filter(\.isGap).reduce(0) { $0 + $1.lengthMinutes },
            840
        )
        // 클립은 겹치지 않고 앞 클립의 끝이 다음 클립의 시작과 맞닿는다.
        for (lhs, rhs) in zip(track.clips, track.clips.dropFirst()) {
            XCTAssertEqual(lhs.endMinute, rhs.startMinute)
        }
    }

    /// 끝을 자르면 비워진 자리는 미확인으로 남고, 하루는 여전히 24시간이다.
    func testTrimmingLeavesUnconfirmedAndKeepsTheDayFull() {
        var track = MapHomeNLEClipEditor.makeMainTrack(segments: threeSegmentDay(sources: [UUID()]))
        let clip = try! XCTUnwrap(track.clip(atMinute: 400))

        XCTAssertTrue(track.trim(clip.id, edge: .end, toMinute: 480))

        XCTAssertEqual(track.totalLengthMinutes, NLETrack.dayMinutes)
        let vacated = track.clips.first { $0.startMinute == 480 && $0.endMinute == 540 }
        XCTAssertEqual(vacated?.isGap, true)

        // 이웃 구간의 시간을 가져오지는 않는다(구간 경계 540에서 멈춘다).
        track.trim(clip.id, edge: .end, toMinute: 900)
        XCTAssertEqual(track.clip(clip.id)?.endMinute, 540)
        XCTAssertEqual(track.totalLengthMinutes, NLETrack.dayMinutes)
    }

    /// 옮기기는 원본 구간 안에서만 움직이고 길이를 유지한다.
    func testMoveStaysInsideItsOriginalSegmentAndKeepsLength() {
        var track = MapHomeNLEClipEditor.makeMainTrack(segments: threeSegmentDay(sources: [UUID()]))
        let clip = try! XCTUnwrap(track.clip(atMinute: 400))
        // 끝을 잘라 옮길 자리를 만든다.
        XCTAssertTrue(track.trim(clip.id, edge: .end, toMinute: 480))
        let length = try! XCTUnwrap(track.clip(clip.id)).lengthMinutes

        XCTAssertTrue(track.move(clip.id, toStartMinute: 360))
        XCTAssertEqual(track.clip(clip.id)?.startMinute, 360)
        XCTAssertEqual(track.clip(clip.id)?.lengthMinutes, length)

        track.move(clip.id, toStartMinute: 900)
        XCTAssertEqual(track.clip(clip.id)?.endMinute, 540)
        XCTAssertEqual(track.clip(clip.id)?.lengthMinutes, length)
        XCTAssertEqual(track.totalLengthMinutes, NLETrack.dayMinutes)
    }

    /// 가르기는 같은 원본을 물려받은 조각 둘을 만든다.
    func testSplitCreatesTwoClipsSharingOneOriginalSegment() {
        let source = UUID()
        var track = MapHomeNLEClipEditor.makeMainTrack(segments: threeSegmentDay(sources: [source]))
        let clip = try! XCTUnwrap(track.clip(atMinute: 400))
        let tailID = try! XCTUnwrap(track.split(clip.id, atMinute: 420))

        let pieces = track.clips.filter { $0.parent.sourceIDs == [source] }
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(track.clip(tailID)?.startMinute, 420)

        // 분류가 같으면 저장할 것이 없다(가르기는 편집점만 만든다).
        XCTAssertTrue(track.editRequests(dayStart: dayStart()).isEmpty)

        // 뒤 조각의 분류를 바꾸면 원본 구간 하나에 요청 하나가 나온다.
        let study = MapHomeNLEClipEditor.option(
            forCategoryID: "study",
            title: "공부",
            behavior: nil
        )
        track.setOption(tailID, to: study)
        let requests = track.editRequests(dayStart: dayStart())
        XCTAssertEqual(requests.count, 1)
        let request = try! XCTUnwrap(requests.first)
        XCTAssertEqual(request.sourceIDs, [source])
        XCTAssertEqual(request.originalSpan.duration, 240 * 60, accuracy: 0.5)
        guard case let .cover(pieces, fill: fill) = request.mode else {
            return XCTFail("cover 요청이어야 한다")
        }
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces.map(\.option.categoryID), ["work", "study"])
        XCTAssertEqual(fill.categoryID, "unconfirmed")
    }

    /// cover는 원본 구간을 빈틈없이 덮는다. 남는 곳은 넘겨준 분류로 채운다.
    func testCoverModeFillsTheOriginalSpanWithoutGaps() {
        let start = dayStart()
        let original = TimeSpan(start: start, end: start.addingTimeInterval(3_600))
        let work = MapHomeNLEClipEditor.option(
            forCategoryID: "work",
            title: "업무",
            behavior: nil
        )
        let pieces = ActivitySectionOverrideEngine.coveringPieces(
            [ActivitySectionOverridePiece(
                span: TimeSpan(
                    start: start.addingTimeInterval(600),
                    end: start.addingTimeInterval(1_200)
                ),
                option: work
            )],
            original: original
        )

        XCTAssertEqual(pieces.count, 3)
        XCTAssertEqual(pieces.map(\.span.duration), [600, 600, 2_400])
        XCTAssertEqual(pieces[0].option.categoryID, "unconfirmed")
        XCTAssertEqual(pieces[1].option.categoryID, "work")
        XCTAssertEqual(pieces.first?.span.start, original.start)
        XCTAssertEqual(pieces.last?.span.end, original.end)

        // 같은 방식으로 만든 기록도 원본을 빈틈없이 덮는다.
        let request = ActivitySectionEditRequest(
            sourceIDs: [UUID()],
            originalSpan: original,
            originalOption: work,
            mode: .cover(pieces: pieces, fill: ActivitySectionOverrideEngine.unconfirmedOption)
        )
        let records = ActivitySectionOverrideEngine.records(for: request)
        XCTAssertEqual(records.first?.startedAt, original.start)
        XCTAssertEqual(records.last?.endedAt, original.end)
        for (lhs, rhs) in zip(records, records.dropFirst()) {
            XCTAssertEqual(lhs.endedAt, rhs.startedAt)
        }
    }

    /// 상세활동 줄은 하루 전체를 담고, 각 기록은 자기 원본 구간을 울타리로 삼는다.
    func testDetailTrackSpansTheDayAndClampsToItsOriginalSegment() {
        let segments = [
            segment(540, 660, "hobby", sources: [UUID()]),
            segment(660, 780, "eating", sources: [UUID()]),
        ]
        let details = [
            MapHomeSectionDetail(
                id: UUID(),
                title: "카페에서 공부",
                categoryID: "study",
                behavior: nil,
                startMinute: 560,
                endMinute: 600
            ),
            MapHomeSectionDetail(
                id: UUID(),
                title: "점심",
                categoryID: "eating",
                behavior: nil,
                startMinute: 700,
                endMinute: 740
            ),
        ]
        let sub = MapHomeNLEClipEditor.makeSubTrack(details: details, segments: segments)

        XCTAssertEqual(sub.clips.count, 2)
        XCTAssertFalse(sub.clips.contains(where: \.isGap))

        let study = sub.clips.first { $0.option.title == "카페에서 공부" }
        XCTAssertEqual(study?.startMinute, 560)
        XCTAssertEqual(study?.endMinute, 600)
        // 울타리는 자기가 속한 원본 구간이다.
        XCTAssertEqual(study?.parent.startMinute, 540)
        XCTAssertEqual(study?.parent.endMinute, 660)
        XCTAssertEqual(study?.parent.fillOption.categoryID, "hobby")

        // 원본 구간 밖으로는 나가지 못한다.
        guard let studyID = study?.id else { return XCTFail("상세활동이 없다") }
        var moved = sub
        moved.move(studyID, toStartMinute: 200)
        XCTAssertEqual(moved.clip(studyID)?.startMinute, 540)

        // 기록을 지우면 그 자리는 그 구간의 대분류가 이어받는다.
        var cleared = sub
        cleared.delete(studyID, fallback: study?.parent.fillOption)
        XCTAssertEqual(cleared.clip(atMinute: 570)?.option.categoryID, "hobby")
    }

    /// 센서 결과로 되돌리면 그 구간은 다시 한 덩어리가 되고, 저장할 것도 없어진다.
    func testReplaceWithTheSensorResultLeavesNothingToSave() {
        let segments = threeSegmentDay(sources: [UUID()])
        var edited = MapHomeNLEClipEditor.makeMainTrack(segments: segments)

        // 업무 300–540을 가운데에서 가르고 뒤쪽을 공부로 바꿔 둔다.
        guard let workID = edited.clip(atMinute: 400)?.id else { return XCTFail("업무가 없다") }
        edited.split(workID, atMinute: 420)
        guard let tailID = edited.clip(atMinute: 480)?.id else { return XCTFail("뒤 조각이 없다") }
        edited.setOption(
            tailID,
            to: MapHomeNLEClipEditor.option(forCategoryID: "study", title: "공부", behavior: nil)
        )
        XCTAssertTrue(edited.clips.contains(where: \.isDirty))

        // 센서가 기록한 그대로(업무 300–540) 되돌린다.
        guard let anchor = edited.clip(atMinute: 300) else { return XCTFail("기준 클립이 없다") }
        edited.replace(300..<540, with: anchor.parent.option, parent: anchor.parent)

        let restored = edited.clip(atMinute: 400)
        XCTAssertEqual(restored?.option.categoryID, "work")
        XCTAssertEqual(restored?.startMinute, 300)
        XCTAssertEqual(restored?.endMinute, 540)
        XCTAssertFalse(edited.clips.contains(where: \.isDirty))
        XCTAssertEqual(edited.totalLengthMinutes, NLETrack.dayMinutes)
    }

    /// 상세활동을 대분류로 올리면 그 구간만 바뀐 것으로 남는다.
    func testReplacePromotesADetailAndKeepsTheRest() {
        var edited = MapHomeNLEClipEditor.makeMainTrack(
            segments: threeSegmentDay(sources: [UUID()])
        )
        guard let anchor = edited.clip(atMinute: 400) else { return XCTFail("기준 클립이 없다") }
        let study = MapHomeNLEClipEditor.option(
            forCategoryID: "study",
            title: "공부",
            behavior: nil
        )
        edited.replace(420..<480, with: study, parent: anchor.parent)

        let promoted = edited.clip(atMinute: 450)
        XCTAssertEqual(promoted?.option.categoryID, "study")
        XCTAssertEqual(promoted?.startMinute, 420)
        XCTAssertEqual(promoted?.endMinute, 480)
        XCTAssertEqual(promoted?.isDirty, true)
        // 앞뒤는 그대로 남고, 하루도 여전히 빈틈없다.
        XCTAssertEqual(edited.clip(atMinute: 400)?.option.categoryID, "work")
        XCTAssertEqual(edited.clip(atMinute: 500)?.option.categoryID, "work")
        XCTAssertEqual(edited.totalLengthMinutes, NLETrack.dayMinutes)
    }

    /// 센서 결과로 되돌린 구간은 저장 요청을 만들지 않는다(이미 그렇게 저장돼 있다).
    func testRestoredSegmentProducesNoEditRequest() {
        var edited = MapHomeNLEClipEditor.makeMainTrack(
            segments: threeSegmentDay(sources: [UUID()])
        )
        guard let workID = edited.clip(atMinute: 400)?.id else { return XCTFail("업무가 없다") }
        edited.split(workID, atMinute: 420)
        guard let tailID = edited.clip(atMinute: 480)?.id,
              let anchor = edited.clip(atMinute: 300) else { return XCTFail("조각이 없다") }
        edited.setOption(
            tailID,
            to: MapHomeNLEClipEditor.option(forCategoryID: "study", title: "공부", behavior: nil)
        )
        XCTAssertEqual(edited.editRequests(dayStart: Date()).count, 1)

        edited.replace(300..<540, with: anchor.parent.option, parent: anchor.parent)
        XCTAssertTrue(edited.editRequests(dayStart: Date()).isEmpty)
    }

    /// 상세활동을 대분류로 올리면 그 원본 구간만 덮는 요청 하나가 나간다.
    func testPromotedDetailProducesOneCoverRequest() {
        var edited = MapHomeNLEClipEditor.makeMainTrack(
            segments: threeSegmentDay(sources: [UUID()])
        )
        guard let anchor = edited.clip(atMinute: 400) else { return XCTFail("기준 클립이 없다") }
        edited.replace(
            420..<480,
            with: MapHomeNLEClipEditor.option(forCategoryID: "study", title: "공부", behavior: nil),
            parent: anchor.parent
        )

        let dayStart = Calendar.autoupdatingCurrent.startOfDay(for: Date())
        let requests = edited.editRequests(dayStart: dayStart)
        XCTAssertEqual(requests.count, 1)
        guard case let .cover(pieces, fill: _) = requests[0].mode else {
            return XCTFail("덮어쓰기 요청이 아니다")
        }
        // 업무 300–420 · 공부 420–480 · 업무 480–540. 빈 자리 없이 이어진다.
        XCTAssertEqual(pieces.map(\.option.categoryID), ["work", "study", "work"])
        XCTAssertEqual(
            pieces.first?.span.start,
            dayStart.addingTimeInterval(300 * 60)
        )
        XCTAssertEqual(
            pieces.last?.span.end,
            dayStart.addingTimeInterval(540 * 60)
        )
    }

    /// 눈금 좌표와 분이 서로 어긋나지 않는다(끌기·자르기의 기준).
    func testTimelineGeometryRoundTripsMinutesAndPoints() {
        let geometry = NLETimelineGeometry(
            minuteWidth: 3,
            visibleStartMinute: 420,
            visibleMinutes: 300
        )
        XCTAssertEqual(geometry.x(forMinute: 420), 0, accuracy: 0.001)
        XCTAssertEqual(geometry.x(forMinute: 570), 450, accuracy: 0.001)
        XCTAssertEqual(geometry.width(minutes: 90), 270, accuracy: 0.001)
        XCTAssertEqual(geometry.minute(forX: 450), 570, accuracy: 0.001)
        XCTAssertEqual(geometry.visibleEndMinute, 720, accuracy: 0.001)

        // 0으로 나누지 않는다. 확대 폭이 0이어도 값이 무너지지 않으면 된다.
        let flat = NLETimelineGeometry(
            minuteWidth: 0,
            visibleStartMinute: 0,
            visibleMinutes: 1_440
        )
        XCTAssertTrue(flat.minute(forX: 100).isFinite)
        XCTAssertEqual(flat.x(forMinute: 100), 0, accuracy: 0.001)
    }

    /// 스냅은 이웃 클립의 끝, 재생 헤드, 하루의 양 끝에 붙는다.
    func testVerticalGeometryUsesTheSameMathAsHorizontal() {
        let geometry = NLETimelineGeometry(
            minuteWidth: 1.5,
            visibleStartMinute: 120,
            visibleMinutes: 300
        )
        XCTAssertEqual(geometry.y(forMinute: 180), 90, accuracy: 0.001)
        XCTAssertEqual(geometry.height(minutes: 60), 90, accuracy: 0.001)
        XCTAssertEqual(geometry.minute(forY: 90), 180, accuracy: 0.001)
    }

    func testSnapPullsToNeighborEdgesAndPlayhead() {
        let targets = [0, 360, 480, 1_440]
        XCTAssertEqual(NLESnapPolicy.snapped(478, to: targets), 480)
        XCTAssertEqual(NLESnapPolicy.snapped(363, to: targets), 360)
        XCTAssertEqual(NLESnapPolicy.snapped(400, to: targets), 400)
        XCTAssertEqual(NLESnapPolicy.snapped(2, to: targets), 0)

        let track = MapHomeNLEClipEditor.makeMainTrack(segments: [
            segment(0, 360, "sleep"),
            segment(360, 600, "work"),
        ])
        let edges = NLESnapPolicy.targets(for: track, excluding: nil, playheadMinute: 300)
        XCTAssertTrue(edges.contains(360))
        XCTAssertTrue(edges.contains(300))
        XCTAssertTrue(edges.contains(1_440))
    }

    /// 몸통은 0.4초를 누르고 있어야 집어 들고, 18pt 넘게 움직이면 집어 들지 않는다.
    func testLiftNeedsFourTenthsOfASecondAndSmallMovement() {
        XCTAssertFalse(NLEReorderHoldPolicy.shouldLift(after: 0.39, distance: 0))
        XCTAssertTrue(NLEReorderHoldPolicy.shouldLift(after: 0.4, distance: 0))
        XCTAssertTrue(NLEReorderHoldPolicy.shouldLift(after: 1.2, distance: 18))
        XCTAssertFalse(NLEReorderHoldPolicy.shouldLift(after: 1.2, distance: 18.5))
    }

    /// 가장자리 자동 스크롤은 경과 시간에 비례해 360pt/s로 흐르고, 한 번에 반영하는 양에는 상한이 있다.
    func testEdgeScrollKeepsThreeHundredSixtyPointsPerSecond() {
        XCTAssertEqual(NLEReorderHoldPolicy.scrollPoints(elapsed: 1.0 / 60), 6, accuracy: 0.01)
        XCTAssertEqual(NLEReorderHoldPolicy.scrollPoints(elapsed: 0.05), 18, accuracy: 0.01)
        XCTAssertEqual(NLEReorderHoldPolicy.scrollPoints(elapsed: -1), 0, accuracy: 0.01)
        // 0.5초를 한 번에 반영하지 않는다. 멈췄다 돌아와도 화면이 튀지 않는다.
        XCTAssertEqual(
            NLEReorderHoldPolicy.scrollPoints(elapsed: 0.5),
            NLEReorderHoldPolicy.scrollPoints(elapsed: NLEReorderHoldPolicy.maximumStep),
            accuracy: 0.01
        )
        XCTAssertEqual(NLEReorderHoldPolicy.scrollPoints(elapsed: 0.5), 36, accuracy: 0.01)
    }

    /// 확대 단추는 '전체 → 4배 → 12배 → 1분 → 전체'로 돈다.
    /// 하루 전체에서는 1시간짜리 클립이 몇 pt라 경계를 잡을 수 없어서, 한 단추로 편집 가능한 배율까지 간다.
    func testZoomButtonCyclesWholeDayFourTimesAndTwelveTimes() {
        let fit = NLEZoomPolicy.fitMinuteHeight(height: 400)
        XCTAssertEqual(fit, 400 / 1_440, accuracy: 0.0001)
        XCTAssertEqual(NLEZoomPolicy.nextLevel(currentMinuteHeight: fit, fitMinuteHeight: fit), 4)
        XCTAssertEqual(NLEZoomPolicy.nextLevel(currentMinuteHeight: fit * 4, fitMinuteHeight: fit), 12)
        // 12배 다음은 1분을 잡을 수 있는 배율, 그다음은 하루 전체로 돌아온다.
        XCTAssertEqual(
            NLEZoomPolicy.nextLevel(currentMinuteHeight: fit * 12, fitMinuteHeight: fit) * fit,
            NLEZoomPolicy.minuteEditHeight, accuracy: 0.001
        )
        XCTAssertEqual(NLEZoomPolicy.nextLevel(currentMinuteHeight: NLEZoomPolicy.minuteEditHeight, fitMinuteHeight: fit), 1)
        // 손가락으로 어중간하게 벌려 둔 상태에서도 다음 칸으로 넘어간다.
        XCTAssertEqual(NLEZoomPolicy.nextLevel(currentMinuteHeight: fit * 2, fitMinuteHeight: fit), 4)
    }

    /// 단추에 적히는 이름은 '누르면 될 일'이다. 지금 상태가 아니라 다음 상태를 적는다.
    func testZoomButtonNamesTheNextStep() {
        let fit = NLEZoomPolicy.fitMinuteHeight(height: 400)
        XCTAssertEqual(
            NLEZoomPolicy.nextTitle(currentMinuteHeight: fit, fitMinuteHeight: fit, language: .korean),
            "확대"
        )
        XCTAssertEqual(
            NLEZoomPolicy.nextTitle(currentMinuteHeight: fit * 4, fitMinuteHeight: fit, language: .korean),
            "더 확대"
        )
        XCTAssertEqual(
            NLEZoomPolicy.nextTitle(currentMinuteHeight: fit * 12, fitMinuteHeight: fit, language: .korean),
            "1분"
        )
        XCTAssertEqual(
            NLEZoomPolicy.nextTitle(currentMinuteHeight: NLEZoomPolicy.minuteEditHeight, fitMinuteHeight: fit, language: .korean),
            "전체"
        )
    }

    /// 줄 높이가 0에 가까워도 배율이 0이 되지 않는다. 0으로 나누면 화면이 사라진다.
    func testZoomFitKeepsAFloorWhenTheRailHasNoHeight() {
        XCTAssertEqual(NLEZoomPolicy.fitMinuteHeight(height: 0), 0.22, accuracy: 0.0001)
        XCTAssertEqual(NLEZoomPolicy.fitMinuteHeight(height: 1_440), 1, accuracy: 0.0001)
        XCTAssertEqual(NLEZoomPolicy.nextLevel(currentMinuteHeight: 1, fitMinuteHeight: 0), 4)
    }

    /// '하루 전체를 보고 있다'는 판단은 20% 여유까지만 인정한다. 조금 벌린 상태에서 안내 문구가 남으면 안 된다.
    func testZoomReportsWholeDayOnlyNearTheFitScale() {
        let fit = NLEZoomPolicy.fitMinuteHeight(height: 400)
        XCTAssertTrue(NLEZoomPolicy.isFitted(currentMinuteHeight: fit, fitMinuteHeight: fit))
        XCTAssertTrue(NLEZoomPolicy.isFitted(currentMinuteHeight: fit * 1.2, fitMinuteHeight: fit))
        XCTAssertFalse(NLEZoomPolicy.isFitted(currentMinuteHeight: fit * 1.3, fitMinuteHeight: fit))
    }

    /// 경계를 밀면 양쪽 클립이 함께 움직이고 빈 시간은 생기지 않는다(롤 편집).
    /// 뒤쪽 클립의 시작을 위로 밀면 앞 클립이 줄고, 아래로 밀면 앞 클립이 늘어난다.
    func testRollMovesBothClipsAtTheSharedBoundary() {
        var track = MapHomeNLEClipEditor.makeMainTrack(segments: [
            segment(0, 300, "sleep"),
            segment(300, 1_440, "work"),
        ])
        guard let sleep = track.clip(atMinute: 100), let work = track.clip(atMinute: 400) else {
            return XCTFail("클립이 없다")
        }
        XCTAssertTrue(track.roll(work.id, edge: .start, toMinute: 280))
        XCTAssertEqual(track.clip(sleep.id)?.endMinute, 280)
        XCTAssertEqual(track.clip(work.id)?.startMinute, 280)
        XCTAssertTrue(track.clips.filter(\.isGap).isEmpty, "롤은 빈 시간을 만들지 않는다")

        // 앞 클립의 원본 구간(0~300)을 넘어서도 늘어난다.
        XCTAssertTrue(track.roll(work.id, edge: .start, toMinute: 320))
        XCTAssertEqual(track.clip(sleep.id)?.endMinute, 320)
        XCTAssertEqual(track.clip(work.id)?.startMinute, 320)
        XCTAssertTrue(track.clips.filter(\.isGap).isEmpty)
        XCTAssertEqual(track.totalLengthMinutes, NLETrack.dayMinutes)
    }

    /// 원본 구간을 넘어선 시간은 그 시간을 소유한 이웃 구간의 요청에 조각으로 실린다.
    func testRollAcrossOriginalSegmentsKeepsThePieceInTheOwningRequest() {
        let sleepSource = UUID()
        let workSource = UUID()
        var track = MapHomeNLEClipEditor.makeMainTrack(segments: [
            segment(0, 300, "sleep", sources: [sleepSource]),
            segment(300, 1_440, "work", sources: [workSource]),
        ])
        guard let work = track.clip(atMinute: 400) else { return XCTFail("업무 클립이 없다") }
        XCTAssertTrue(track.roll(work.id, edge: .start, toMinute: 320))

        let start = dayStart()
        let requests = track.editRequests(dayStart: start, calendar: calendar)
        XCTAssertEqual(requests.count, 2, "넘어선 시간을 소유한 이웃 구간에도 요청이 나가야 한다")
        guard let owner = requests.first(where: { $0.sourceIDs == [workSource] }) else {
            return XCTFail("업무 원본 구간 요청이 없다")
        }
        let pieces = ActivitySectionOverrideEngine.pieces(for: owner)
        XCTAssertEqual(pieces.first?.option.categoryID, "sleep")
        XCTAssertEqual(pieces.first?.span.start, calendar.date(byAdding: .minute, value: 300, to: start))
        XCTAssertEqual(pieces.first?.span.end, calendar.date(byAdding: .minute, value: 320, to: start))
    }

    /// 경계를 끌어 이웃이 최소 길이까지 눌리면 합치기를 묻고, 합치면 끌어온 클립이 이웃 자리까지 한 덩어리가 된다(ARC1030A05, UIX1031A18).
    func testHandleReachingNeighborFarEndOffersMergeAndAdoptsDraggedCategory() throws {
        let sleepSource = UUID()
        let workSource = UUID()
        var track = MapHomeNLEClipEditor.makeMainTrack(segments: [
            segment(0, 300, "sleep", sources: [sleepSource]),
            segment(300, 1_440, "work", sources: [workSource]),
        ])
        let work = try XCTUnwrap(track.clip(atMinute: 400))
        let sleep = try XCTUnwrap(track.clip(atMinute: 100))

        // 중간까지만 간 손은 묻지 않는다(이웃이 아직 최소 길이보다 길다).
        var midway = track
        XCTAssertTrue(midway.roll(work.id, edge: .start, toMinute: 120))
        XCTAssertNil(midway.squeezedMergePair(of: work.id, edge: .start, clipLengthAtStart: 1_140, neighborLengthAtStart: 300))
        // 이웃의 먼 쪽 끝까지 간 손은 합치기를 묻는다.
        XCTAssertTrue(track.roll(work.id, edge: .start, toMinute: 0))
        let pair = try XCTUnwrap(track.squeezedMergePair(of: work.id, edge: .start, clipLengthAtStart: 1_140, neighborLengthAtStart: 300))
        XCTAssertEqual(pair.survivor.id, work.id)
        XCTAssertEqual(pair.absorbed.id, sleep.id)
        // 끌기 전부터 최소 길이였던 이웃은 묻지 않는다.
        XCTAssertNil(track.squeezedMergePair(of: work.id, edge: .start, clipLengthAtStart: 1_140, neighborLengthAtStart: NLETrack.minimumClipMinutes))

        XCTAssertTrue(track.mergeIntoDragged(work.id, neighborID: sleep.id))
        XCTAssertNil(track.clip(sleep.id), "합친 이웃은 따로 남지 않는다")
        XCTAssertEqual(track.clip(work.id)?.startMinute, 0)
        XCTAssertEqual(track.clips.filter { !$0.isGap }.count, 1)
        // 이웃의 원본 구간 요청이 빠지지 않고 끌어온 분류로 나간다.
        let requests = track.editRequests(dayStart: dayStart(), calendar: calendar)
        let owner = try XCTUnwrap(requests.first(where: { $0.sourceIDs == [sleepSource] }))
        XCTAssertEqual(ActivitySectionOverrideEngine.pieces(for: owner).first?.option.categoryID, "work")
    }

    /// 이웃이 기록 없는 빈 시간이면 묻지 않고, 같은 분류로 나뉜 두 덩어리는 묻고 하나로 합친다(UIX1031A21).
    func testMergeIsNotOfferedForGapOrSameCategoryNeighbors() throws {
        var gapTrack = MapHomeNLEClipEditor.makeMainTrack(segments: threeSegmentDay(sources: [UUID()]))
        let work = try XCTUnwrap(gapTrack.clip(atMinute: 400))
        gapTrack.trim(work.id, edge: .end, toMinute: 480)
        XCTAssertTrue(gapTrack.roll(work.id, edge: .end, toMinute: NLETrack.dayMinutes))
        XCTAssertNil(gapTrack.squeezedMergePair(of: work.id, edge: .end, clipLengthAtStart: 120, neighborLengthAtStart: 960))

        var sameTrack = MapHomeNLEClipEditor.makeMainTrack(segments: [
            segment(0, 300, "work", sources: [UUID()]),
            segment(300, 1_440, "work", sources: [UUID()]),
        ])
        let second = try XCTUnwrap(sameTrack.clip(atMinute: 400))
        _ = sameTrack.roll(second.id, edge: .start, toMinute: 0)
        let pair = try XCTUnwrap(sameTrack.squeezedMergePair(of: second.id, edge: .start, clipLengthAtStart: 1_140, neighborLengthAtStart: 300))
        XCTAssertTrue(sameTrack.mergeIntoDragged(pair.survivor.id, neighborID: pair.absorbed.id))
        XCTAssertEqual(sameTrack.clips.filter { !$0.isGap }.count, 1)
    }

    /// 분류가 같아도 이름이 다른 이웃(「머무름」과 「집에서 휴식」)은 끝까지 끌면 합치기를 묻는다(UIX1031A16).
    /// 경계 바로 위를 잡아 위 클립의 끝 손잡이가 잡혀도, 끌어 올려 위 클립이 눌리면 묻는다(UIX1031A18: 대표 영상).
    func testMergeIsOfferedForSameCategoryNeighborWithDifferentTitle() throws {
        func clipSegment(_ start: Int, _ end: Int, title: String) -> MapHomeTimeRailSegment {
            MapHomeTimeRailSegment(
                startMinute: start, endMinute: end, categoryID: "rest", title: title, sourceIDs: [UUID()]
            )
        }
        let base = MapHomeNLEClipEditor.makeMainTrack(segments: [
            clipSegment(20, 59, title: "머무름"),
            clipSegment(59, 115, title: "집에서 휴식"),
        ])
        let stay = try XCTUnwrap(base.clip(atMinute: 30))
        let rest = try XCTUnwrap(base.clip(atMinute: 80))
        XCTAssertEqual(stay.option.categoryID, rest.option.categoryID)

        // 아래 클립의 시작 손잡이를 잡고 올린 경우.
        var fromBelow = base
        XCTAssertTrue(fromBelow.roll(rest.id, edge: .start, toMinute: 0))
        let below = try XCTUnwrap(fromBelow.squeezedMergePair(of: rest.id, edge: .start, clipLengthAtStart: 56, neighborLengthAtStart: 39))
        XCTAssertEqual(below.survivor.id, rest.id)
        XCTAssertEqual(below.absorbed.id, stay.id)

        // 위 클립의 끝 손잡이를 잡고 올린 경우: 잡은 클립이 스스로 눌렸으니 그 클립을 아래로 합친다.
        var fromAbove = base
        XCTAssertTrue(fromAbove.roll(stay.id, edge: .end, toMinute: 0))
        let above = try XCTUnwrap(fromAbove.squeezedMergePair(of: stay.id, edge: .end, clipLengthAtStart: 39, neighborLengthAtStart: 56))
        XCTAssertEqual(above.survivor.id, rest.id)
        XCTAssertEqual(above.absorbed.id, stay.id)

        XCTAssertTrue(fromAbove.mergeIntoDragged(above.survivor.id, neighborID: above.absorbed.id))
        XCTAssertNil(fromAbove.clip(stay.id))
        XCTAssertEqual(fromAbove.clip(rest.id)?.startMinute, 20)
        XCTAssertEqual(fromAbove.clip(rest.id)?.option.title, "집에서 휴식")
    }

    /// 아래로 끌어 아래 클립을 누를 때도 묻고, 화면에서 거의 사라질 만큼만 눌러도 묻는다.
    /// 원본 ID가 아직 없는 진행 중 구간도 합칠 수 있다(UIX1031A19).
    func testMergeDownwardWithSqueezeThresholdAndLiveNeighbor() throws {
        var track = MapHomeNLEClipEditor.makeMainTrack(segments: [
            MapHomeTimeRailSegment(startMinute: 0, endMinute: 300, categoryID: "rest", title: "집에서 휴식", sourceIDs: [UUID()]),
            MapHomeTimeRailSegment(startMinute: 300, endMinute: 400, categoryID: "work", title: "일", sourceIDs: []),
        ])
        let rest = try XCTUnwrap(track.clip(atMinute: 100))
        let work = try XCTUnwrap(track.clip(atMinute: 350))

        // 위 클립의 끝을 아래로 끌어 아래 클립을 6분만 남겼다.
        XCTAssertTrue(track.roll(rest.id, edge: .end, toMinute: 394))
        XCTAssertNil(track.squeezedMergePair(of: rest.id, edge: .end, clipLengthAtStart: 300, neighborLengthAtStart: 100))
        let pair = try XCTUnwrap(track.squeezedMergePair(
            of: rest.id, edge: .end, clipLengthAtStart: 300, neighborLengthAtStart: 100, squeezeMinutes: 8
        ))
        XCTAssertEqual(pair.survivor.id, rest.id)
        XCTAssertEqual(pair.absorbed.id, work.id)
        XCTAssertTrue(track.mergeIntoDragged(pair.survivor.id, neighborID: pair.absorbed.id))
        XCTAssertEqual(track.clip(rest.id)?.endMinute, 400)
        XCTAssertNil(track.clip(work.id))
    }

    /// 하루 전체 배율처럼 화면 두께 기준이 이웃보다 길어도, 이웃을 끝까지 밀면 묻고 조금만 밀면 묻지 않는다(UIX1031A20).
    func testMergeThresholdLargerThanNeighborStillWorks() throws {
        func clipSegment(_ start: Int, _ end: Int, title: String) -> MapHomeTimeRailSegment {
            MapHomeTimeRailSegment(startMinute: start, endMinute: end, categoryID: "rest", title: title, sourceIDs: [UUID()])
        }
        let base = MapHomeNLEClipEditor.makeMainTrack(segments: [
            clipSegment(20, 59, title: "머무름"),
            clipSegment(59, 115, title: "집에서 휴식"),
        ])
        let stay = try XCTUnwrap(base.clip(atMinute: 30))
        let rest = try XCTUnwrap(base.clip(atMinute: 80))

        var slight = base
        XCTAssertTrue(slight.roll(rest.id, edge: .start, toMinute: 50))
        XCTAssertNil(slight.squeezedMergePair(of: rest.id, edge: .start, clipLengthAtStart: 56, neighborLengthAtStart: 39, squeezeMinutes: 60))

        var full = base
        XCTAssertTrue(full.roll(rest.id, edge: .start, toMinute: 0))
        XCTAssertEqual(full.squeezedMergePair(of: rest.id, edge: .start, clipLengthAtStart: 56, neighborLengthAtStart: 39, squeezeMinutes: 60)?.absorbed.id, stay.id)

        var near = base
        XCTAssertTrue(near.roll(rest.id, edge: .start, toMinute: 27))
        XCTAssertEqual(near.squeezedMergePair(of: rest.id, edge: .start, clipLengthAtStart: 56, neighborLengthAtStart: 39, squeezeMinutes: 60)?.absorbed.id, stay.id, "7분 남기면(처음의 4분의 1 이하) 묻는다")

        var down = base
        XCTAssertTrue(down.roll(stay.id, edge: .end, toMinute: 200))
        XCTAssertEqual(down.squeezedMergePair(of: stay.id, edge: .end, clipLengthAtStart: 39, neighborLengthAtStart: 56, squeezeMinutes: 60)?.absorbed.id, rest.id)
    }

    /// 처음부터 1분인 이웃은 더 줄지 않으므로, 손가락이 그 클립을 지나쳐 밀면 묻는다(UIX1031A22: 기기 로그 「걷기」 1분).
    func testOneMinuteNeighborMergesWhenFingerPushesThrough() throws {
        func clipSegment(_ start: Int, _ end: Int, category: String, title: String) -> MapHomeTimeRailSegment {
            MapHomeTimeRailSegment(startMinute: start, endMinute: end, categoryID: category, title: title, sourceIDs: [UUID()])
        }
        let track = MapHomeNLEClipEditor.makeMainTrack(segments: [
            clipSegment(0, 88, category: "rest", title: "집에서 휴식"),
            clipSegment(88, 89, category: "move", title: "걷기"),
            clipSegment(89, 203, category: "rest", title: "집에서 휴식"),
        ])
        let walk = try XCTUnwrap(track.clip(atMinute: 88))
        let rest = try XCTUnwrap(track.clip(atMinute: 100))
        XCTAssertEqual(walk.lengthMinutes, 1)

        // 경계에 손가락만 대고 있으면 묻지 않는다.
        XCTAssertNil(track.squeezedMergePair(of: rest.id, edge: .start, clipLengthAtStart: 114, neighborLengthAtStart: 1, squeezeMinutes: 17, fingerMinute: 89))
        // 1분 클립을 지나쳐 밀면 묻는다.
        let pair = try XCTUnwrap(track.squeezedMergePair(of: rest.id, edge: .start, clipLengthAtStart: 114, neighborLengthAtStart: 1, squeezeMinutes: 17, fingerMinute: 80))
        XCTAssertEqual(pair.survivor.id, rest.id)
        XCTAssertEqual(pair.absorbed.id, walk.id)
        // 1분 클립의 끝 손잡이를 잡고 아래로 밀어도(잡은 클립이 1분) 묻는다.
        let fromWalk = try XCTUnwrap(track.squeezedMergePair(of: walk.id, edge: .end, clipLengthAtStart: 1, neighborLengthAtStart: 114, squeezeMinutes: 17, fingerMinute: 87))
        XCTAssertEqual(fromWalk.absorbed.id, walk.id)
    }

    /// 가만히 있어도 GPS가 흔들리면 이동 거리가 쌓이지 않는다. 실제로 움직이면 거의 그대로 센다(ARC1030A08).
    func testTravelDistanceIgnoresStationaryGPSJitterButCountsRealMovement() {
        let base = Date(timeIntervalSinceReferenceDate: 815_000_000)
        func reading(_ second: Int, lat: Double, lon: Double, accuracy: Double = 10) -> SensorReading {
            SensorReading(
                timestamp: base.addingTimeInterval(Double(second)),
                point: GeoPoint(latitude: lat, longitude: lon, altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 10)
            )
        }
        // 한 자리에서 ±15m쯤 흔들리는 1시간(1초 간격) 기록.
        var generator = SystemRandomNumberGenerator()
        let jitter = (0..<3_600).map { second -> SensorReading in
            let dLat = Double.random(in: -0.00013...0.00013, using: &generator)
            let dLon = Double.random(in: -0.00016...0.00016, using: &generator)
            return reading(second, lat: 37.5 + dLat, lon: 127 + dLon)
        }
        let jitterMeters = TravelDistanceMath.pathMeters(readings: jitter)
        let naive = zip(jitter.compactMap(\.point), jitter.compactMap(\.point).dropFirst())
            .reduce(0.0) { $0 + distanceMeters($1.0, $1.1) }
        XCTAssertGreaterThan(naive, 20_000, "예전 방식이면 가만히 있어도 수십 km가 쌓인다")
        XCTAssertLessThan(jitterMeters, 3_000, "흔들림은 거리로 세지 않는다(\(Int(jitterMeters))m)")

        // 북쪽으로 1km를 15초마다 ~100m씩 가는 실제 이동은 거의 그대로 센다.
        let walk = (0...10).map { reading($0 * 15, lat: 37.5 + Double($0) * 0.0009, lon: 127) }
        let walkMeters = TravelDistanceMath.pathMeters(readings: walk)
        XCTAssertEqual(walkMeters, 1_000, accuracy: 60)

        // 튄 점(1초에 수 km)은 세지 않는다.
        let jump = [reading(0, lat: 37.5, lon: 127), reading(1, lat: 37.6, lon: 127), reading(60, lat: 37.5009, lon: 127)]
        XCTAssertLessThan(TravelDistanceMath.pathMeters(readings: jump), 300)
    }

    /// 발자국은 GPS가 기록된 순간의 값으로 고정된다. 뒤에 기록이 붙어도 앞 발자국의 위치·방향·속도는 바뀌지 않는다(ARC1030A07).
    func testPawprintLedgerKeepsEarlierEntriesWhenReadingsAreAppended() {
        let base = Date(timeIntervalSinceReferenceDate: 815_000_000)
        func reading(_ second: Int, lat: Double, speed: Double?) -> SensorReading {
            SensorReading(
                timestamp: base.addingTimeInterval(Double(second)),
                point: GeoPoint(latitude: lat, longitude: 127, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10),
                speedMetersPerSecond: speed
            )
        }
        // 0.001도(약 111m)씩 북쪽으로 움직이는 기록.
        let first = (0..<6).map { reading($0 * 10, lat: 37 + Double($0) * 0.001, speed: 5 + Double($0)) }
        let before = MapHomePawprintLedger.entries(readings: first, excluding: [])
        XCTAssertEqual(before.count, 6)
        XCTAssertEqual(before[2].speed, 7, "기록 당시 GPS 속도를 그대로 쓴다")

        let more = first + (6..<10).map { reading($0 * 10, lat: 37 + Double($0) * 0.001, speed: 20) }
        let after = MapHomePawprintLedger.entries(readings: more, excluding: [])
        XCTAssertEqual(Array(after.prefix(before.count)), before, "새 기록이 붙어도 앞 발자국은 그대로다")
        XCTAssertEqual(after.count, 10)
        // 같은 입력은 늘 같은 결과(순서를 섞어 넣어도 시간순으로 판단한다).
        XCTAssertEqual(MapHomePawprintLedger.entries(readings: Array(more.reversed()), excluding: []), after)
    }

    /// 간격 안의 기록은 발자국이 되지 않고, GPS 속도가 없으면 직전 기록에서 구한 평균 속도를 쓰며, 지하철 구간은 건너뛴다.
    func testPawprintLedgerSpacingDerivedSpeedAndExclusion() throws {
        let base = Date(timeIntervalSinceReferenceDate: 815_000_000)
        func reading(_ second: Int, lat: Double) -> SensorReading {
            SensorReading(
                timestamp: base.addingTimeInterval(Double(second)),
                point: GeoPoint(latitude: lat, longitude: 127, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10)
            )
        }
        let readings = [
            reading(0, lat: 37.0000),
            reading(10, lat: 37.0002),   // 간격 안: 발자국 없음
            reading(20, lat: 37.0010),   // 약 111m: 발자국, 속도는 직전 기록(0.0002도)에서 20초 → 구한 값
            reading(30, lat: 37.0020),
        ]
        let entries = MapHomePawprintLedger.entries(readings: readings, excluding: [])
        XCTAssertEqual(entries.count, 3)
        let derived = try XCTUnwrap(entries[1].speed)
        XCTAssertEqual(derived, CLLocation(latitude: 37.0002, longitude: 127)
            .distance(from: CLLocation(latitude: 37.0010, longitude: 127)) / 10, accuracy: 0.01)

        let skipped = MapHomePawprintLedger.entries(
            readings: readings,
            excluding: [TimeSpan(start: base.addingTimeInterval(15), end: base.addingTimeInterval(35))]
        )
        XCTAssertEqual(skipped.count, 1)
    }

    /// 이웃이 1분보다 짧아지는 자리에서는 경계가 더 밀리지 않는다.
    func testRollStopsWhenTheNeighborReachesOneMinute() {
        var track = MapHomeNLEClipEditor.makeMainTrack(segments: [
            segment(0, 300, "sleep"),
            segment(300, 1_440, "work"),
        ])
        guard let work = track.clip(atMinute: 400) else { return XCTFail("업무 클립이 없다") }
        XCTAssertTrue(track.roll(work.id, edge: .start, toMinute: 0))
        XCTAssertEqual(track.clip(atMinute: 0)?.lengthMinutes, NLETrack.minimumClipMinutes)
    }

    /// 미확인 자리를 밀어도 미확인은 하나로 남는다.
    func testRollIntoUnconfirmedGapKeepsOneGap() {
        var track = MapHomeNLEClipEditor.makeMainTrack(segments: threeSegmentDay(sources: [UUID()]))
        guard let work = track.clip(atMinute: 400) else { return XCTFail("업무 클립이 없다") }
        track.trim(work.id, edge: .end, toMinute: 480)
        XCTAssertEqual(track.clips.filter(\.isGap).count, 1)

        XCTAssertTrue(track.roll(work.id, edge: .end, toMinute: 500))
        let gaps = track.clips.filter(\.isGap)
        XCTAssertEqual(gaps.count, 1, "밀어도 미확인은 하나여야 한다")
        XCTAssertEqual(gaps.first?.startMinute, 500)
        XCTAssertEqual(gaps.first?.endMinute, 540)
    }

    // MARK: - 전체 덮기·합치기 (OVW1026A01)

    private func studyOption() -> ActivityCorrectionOption {
        MapHomeNLEClipEditor.option(forCategoryID: "study", title: "공부", behavior: nil)
    }

    /// 하루 전체를 덮어도 원본 기록이 없는 시간은 건드리지 않는다.
    /// 센서에 없는 시간을 지어내지 않는다는 이 트랙의 규칙 그대로다.
    func testOverwriteLeavesInventedTimeAlone() {
        // 가운데 업무 구간만 센서 기록이 있다. 앞뒤는 기록 없이 채운 시간이다.
        var track = MapHomeNLEClipEditor.makeMainTrack(
            segments: threeSegmentDay(sources: [UUID()])
        )
        XCTAssertEqual(track.clips.count, 3)

        let changed = track.overwrite(with: studyOption())

        XCTAssertEqual(changed, 1, "기록이 있는 클립만 바뀐다")
        XCTAssertEqual(track.clip(atMinute: 400)?.option.categoryID, "study")
        XCTAssertEqual(track.clip(atMinute: 100)?.option.categoryID, "sleep", "기록 없는 시간은 그대로")
        XCTAssertEqual(track.clip(atMinute: 900)?.option.categoryID, "activity")
        XCTAssertEqual(track.totalLengthMinutes, NLETrack.dayMinutes)
    }

    /// 기록이 있는 하루는 클립 수만큼 바뀌고, 두 번째 덮기는 바뀐 것이 없다.
    func testOverwriteCountsEveryRecordedClipOnce() {
        var track = MapHomeNLEClipEditor.makeMainTrack(segments: [
            segment(0, 300, "sleep", sources: [UUID()]),
            segment(300, 540, "work", sources: [UUID()]),
            segment(540, 1_440, "activity", sources: [UUID()]),
        ])

        XCTAssertEqual(track.overwrite(with: studyOption()), 3)
        XCTAssertTrue(track.clips.allSatisfy { $0.option.categoryID == "study" })
        XCTAssertEqual(track.overwrite(with: studyOption()), 0, "이미 같은 분류면 다시 세지 않는다")
    }

    /// '같은 분류만'은 고른 분류의 클립만 바꾼다. 나머지 분류는 손대지 않는다.
    func testOverwriteCanLimitItselfToTheSelectedCategory() {
        var track = MapHomeNLEClipEditor.makeMainTrack(segments: [
            segment(0, 300, "work", sources: [UUID()]),
            segment(300, 540, "work", sources: [UUID()]),
            segment(540, 1_440, "activity", sources: [UUID()]),
        ])

        let changed = track.overwrite(with: studyOption(), matchingCategoryID: "work")

        XCTAssertEqual(changed, 2)
        XCTAssertEqual(track.clips.filter { $0.option.categoryID == "study" }.count, 2)
        XCTAssertEqual(track.clip(atMinute: 900)?.option.categoryID, "activity")
    }

    /// 손으로 가른 클립을 합치면 하나로 돌아오고, 저장할 것도 남지 않는다.
    func testMergingHandSplitClipsSavesNothing() {
        let source = UUID()
        var track = MapHomeNLEClipEditor.makeMainTrack(segments: threeSegmentDay(sources: [source]))
        let work = try! XCTUnwrap(track.clip(atMinute: 400))
        _ = track.split(work.id, atMinute: 420)
        XCTAssertEqual(track.clips.count, 4)

        XCTAssertEqual(track.mergeAdjacent(), 1)
        XCTAssertEqual(track.clips.count, 3)

        let fused = try! XCTUnwrap(track.clip(atMinute: 400))
        XCTAssertEqual(fused.startMinute, 300)
        XCTAssertEqual(fused.endMinute, 540)
        XCTAssertFalse(fused.isDirty, "가르기→합치기는 왕복이라 바뀐 것이 없다")
        XCTAssertTrue(track.editRequests(dayStart: dayStart()).isEmpty)
    }

    /// 한쪽 조각만 분류를 바꾼 뒤 덮고 합치면, 합쳐진 구간 전체가 바뀐 것으로 남는다.
    func testOverwriteThenMergeDirtiesTheWholeFusedSpan() {
        let source = UUID()
        var track = MapHomeNLEClipEditor.makeMainTrack(segments: threeSegmentDay(sources: [source]))
        let work = try! XCTUnwrap(track.clip(atMinute: 400))
        let tailID = try! XCTUnwrap(track.split(work.id, atMinute: 420))
        XCTAssertTrue(track.setOption(tailID, to: studyOption()))

        XCTAssertEqual(track.overwrite(with: studyOption()), 1, "앞 조각만 바뀐다")
        XCTAssertEqual(track.mergeAdjacent(), 1)

        let fused = try! XCTUnwrap(track.clip(atMinute: 400))
        XCTAssertEqual(fused.startMinute, 300)
        XCTAssertEqual(fused.endMinute, 540)
        XCTAssertTrue(fused.isDirty)

        // 요청은 여전히 원본 구간 하나에 하나다.
        let requests = track.editRequests(dayStart: dayStart())
        XCTAssertEqual(requests.count, 1)
        let request = try! XCTUnwrap(requests.first)
        XCTAssertEqual(request.sourceIDs, [source])
        XCTAssertEqual(request.originalSpan.duration, 240 * 60, accuracy: 0.5)
        let pieces = ActivitySectionOverrideEngine.pieces(for: request)
        XCTAssertEqual(pieces.count, 1, "합친 구간은 조각 하나로 덮는다")
        XCTAssertEqual(pieces.first?.option.categoryID, "study")
    }

    /// 창이 보여 주는 수와 실제로 바뀌는 수가 같아야 한다. 다르면 누르기 전 안내가 거짓말이 된다.
    func testOverwritePolicyReportsTheSameCountItApplies() {
        let track = MapHomeNLEClipEditor.makeMainTrack(segments: [
            segment(0, 300, "sleep", sources: [UUID()]),
            segment(300, 540, "work", sources: [UUID()]),
            segment(540, 1_440, "activity", sources: [UUID()]),
        ])
        let option = studyOption()

        let wholeDay = NLEOverwritePolicy.affectedCount(
            track, scope: .wholeDay, selectedCategoryID: nil
        )
        XCTAssertEqual(wholeDay, 3)
        let applied = NLEOverwritePolicy.apply(
            track, option: option, scope: .wholeDay,
            selectedCategoryID: nil, mergesAfter: false
        )
        XCTAssertEqual(applied.changed, wholeDay)
        XCTAssertEqual(applied.merged, 0, "합치기를 끄면 합치지 않는다")

        // '같은 분류만'인데 기준 분류가 없으면 바꿀 것이 없다.
        XCTAssertEqual(
            NLEOverwritePolicy.affectedCount(track, scope: .sameCategory, selectedCategoryID: nil),
            0
        )
        XCTAssertEqual(
            NLEOverwritePolicy.affectedCount(track, scope: .sameCategory, selectedCategoryID: "work"),
            1
        )
    }

    /// 분류를 고르지 않은 요청은 합치기만 한다(자막 합치기와 같은 단추).
    func testOverwritePolicyMergesOnlyWhenNoCategoryIsPicked() {
        let source = UUID()
        var track = MapHomeNLEClipEditor.makeMainTrack(segments: threeSegmentDay(sources: [source]))
        let work = try! XCTUnwrap(track.clip(atMinute: 400))
        _ = track.split(work.id, atMinute: 420)
        XCTAssertEqual(NLEOverwritePolicy.mergeableCount(track), 1)

        let result = NLEOverwritePolicy.apply(
            track, option: nil, scope: .wholeDay,
            selectedCategoryID: nil, mergesAfter: true
        )

        XCTAssertEqual(result.changed, 0)
        XCTAssertEqual(result.merged, 1)
        XCTAssertEqual(result.track.clips.count, 3)
        XCTAssertTrue(result.track.editRequests(dayStart: dayStart()).isEmpty)
    }
}
