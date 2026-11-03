import XCTest
@testable import TaptionPlan

/// 클립 편집 상세 층의 하위 행동(NLE1103A02)과 재탭 선택 취소(NLE1103A03).
@MainActor
final class NLESubActivityTests: XCTestCase {
    private let dayStart = Date(timeIntervalSinceReferenceDate: 815_000_000)

    private func date(_ minute: Int) -> Date {
        dayStart.addingTimeInterval(Double(minute) * 60)
    }

    private func workDay() -> [MapHomeTimeRailSegment] {
        [
            MapHomeTimeRailSegment(startMinute: 0, endMinute: 420, categoryID: "sleep", title: "수면"),
            MapHomeTimeRailSegment(startMinute: 420, endMinute: 720, categoryID: "work", title: "근무"),
            MapHomeTimeRailSegment(startMinute: 720, endMinute: 780, categoryID: "eating", title: "식사"),
        ]
    }

    private func record(
        _ title: String,
        behavior: String?,
        category: String = "work",
        _ start: Int,
        _ end: Int,
        source: ActualSource = .location,
        manual: Bool = false,
        evidence: [String] = ["자주가는 곳: 회사"]
    ) -> ActualRecord {
        ActualRecord(
            id: UUID(), planID: nil, routineID: nil, title: title, categoryID: category,
            startedAt: date(start), endedAt: date(end), source: source, confidence: .medium,
            createdAt: date(start), behavior: behavior, evidence: evidence, manuallyCorrected: manual
        )
    }

    private func event(_ title: String, _ start: Int, _ end: Int, allDay: Bool = false) -> CalendarRecord {
        CalendarRecord(
            id: "\(title)-\(start)", calendarID: "c", title: title,
            span: TimeSpan(start: date(start), end: date(end)), isAllDay: allDay,
            calendarTitle: "일정", calendarColorHex: nil, sourceTitle: nil
        )
    }

    private func titles(_ details: [MapHomeSectionDetail]) -> [String] {
        details.map { "\($0.title) \($0.startMinute)-\($0.endMinute)" }
    }

    // MARK: - 하위 행동

    /// 업무 구간에 회의·메일·통화·휴식이 나오고, 근거 없는 시간과 근무 자체는 비어 있다.
    func testWorkSegmentShowsSubActivitiesAndLeavesTheRestEmpty() {
        let details = NLESubActivityEngine.details(
            NLESubActivityInput(
                segments: workDay(),
                actuals: [
                    record("근무", behavior: "work", 420, 720),
                    record("휴식", behavior: "stationary", 570, 590),
                    record("통화", behavior: "phoneCall", category: "activity", 660, 680, source: .call, evidence: []),
                ],
                calendarEvents: [event("주간 회의", 480, 540), event("메일 정리", 600, 650)],
                dayStart: dayStart
            )
        )
        XCTAssertEqual(
            titles(details),
            ["회의 480-540", "휴식 570-590", "메일 정리 600-650", "통화 660-680"]
        )
        XCTAssertTrue(details.allSatisfy { $0.provenance?.origin == .automatic })
        XCTAssertEqual(details.first { $0.title == "통화" }?.provenance?.evidence, "CallKit 통화 기록")
        XCTAssertTrue(details.first { $0.title == "회의" }?.provenance?.evidence.contains("주간 회의") == true)
        // 상세 클립은 분류표 이름으로 세워지고 저장 대상이 아니다.
        let track = MapHomeNLEClipEditor.makeSubTrack(details: details, segments: workDay())
        XCTAssertEqual(track.clips.map(\.option.title), ["회의", "휴식", "메일 정리", "통화"])
        XCTAssertTrue(track.editRequests(dayStart: dayStart).isEmpty)
    }

    /// 근거가 없으면 하위 행동을 지어내지 않는다. 걷기·정지 모션과 대분류를 되풀이하는 기록은 상세로 올라오지 않는다.
    func testNoEvidenceLeavesDetailLayerEmpty() {
        let details = NLESubActivityEngine.details(
            NLESubActivityInput(
                segments: workDay(),
                actuals: [
                    record("근무", behavior: "work", 420, 720),
                    record("수면", behavior: "sleep", category: "sleep", 0, 420, source: .healthKit, evidence: []),
                    record("식사", behavior: "meal", category: "eating", 720, 780),
                    record("걷기", behavior: "walking", category: "movement", 500, 510, source: .motion, evidence: []),
                    record("정지", behavior: "stationary", 520, 560, source: .motion, evidence: []),
                ],
                calendarEvents: [event("연차", 420, 720, allDay: true), event("짧은 메모", 500, 502)],
                dayStart: dayStart
            )
        )
        XCTAssertEqual(titles(details), [])
    }

    /// 대분류와 맞지 않는 일정은 쓰지 않고, 사용자가 '분류 안 함'으로 정한 일정도 쓰지 않는다.
    func testCalendarEvidenceMustFitTheMainCategory() {
        let details = NLESubActivityEngine.details(
            NLESubActivityInput(
                segments: workDay(),
                calendarEvents: [event("치과", 430, 460), event("회의", 500, 530), event("점심 약속", 540, 560), event("숨긴 일정", 600, 630)],
                calendarTitleDetails: ["숨긴 일정": CalendarTitleDetail(detailID: nil)],
                dayStart: dayStart
            )
        )
        // "점심 약속"은 식사로 분류되고 업무 구간과 맞지 않는다.
        XCTAssertEqual(titles(details), ["회의 500-530"])
    }

    /// 수동 기록은 자동 근거에 덮이지 않고, 원본 값도 그대로이며, 출처로 구분된다.
    func testManualRecordWinsOverAutomaticEvidenceAndStaysDistinct() {
        let manual = record("코드 리뷰", behavior: nil, 500, 520, source: .manual, manual: true, evidence: [])
        let before = manual
        let details = NLESubActivityEngine.details(
            NLESubActivityInput(
                segments: workDay(),
                actuals: [manual],
                calendarEvents: [event("회의", 480, 540)],
                dayStart: dayStart
            )
        )
        XCTAssertEqual(titles(details), ["회의 480-500", "코드 리뷰 500-520", "회의 520-540"])
        XCTAssertEqual(details[1].id, manual.id)
        XCTAssertEqual(details[1].provenance?.origin, .manual)
        XCTAssertEqual(details[0].provenance?.origin, .automatic)
        XCTAssertEqual(Set(details.map(\.id)).count, 3, "나뉜 조각은 ID가 겹치면 안 된다")
        XCTAssertEqual(manual, before)
    }

    /// 사용자가 구간 전체를 대분류로 고친 기록은 대분류 자체라 상세에 또 쓰지 않는다.
    func testManualWholeSegmentRestatementIsNotRepeated() {
        let manual = record("업무", behavior: nil, 420, 720, source: .manual, manual: true, evidence: [])
        let details = NLESubActivityEngine.details(
            NLESubActivityInput(segments: workDay(), actuals: [manual], dayStart: dayStart)
        )
        XCTAssertEqual(titles(details), [])
    }

    /// 메일은 메일 앱 사용 기록이 있을 때만 나온다. 다른 앱 이름은 하위 행동이 아니다.
    func testMailComesOnlyFromMailAppUsage() {
        let details = NLESubActivityEngine.details(
            NLESubActivityInput(
                segments: workDay(),
                actuals: [
                    record("Gmail", behavior: "screen-time", category: "appUsage", 540, 560, source: .appUsage),
                    record("Instagram", behavior: "screen-time", category: "appUsage", 600, 620, source: .appUsage),
                ],
                dayStart: dayStart
            )
        )
        XCTAssertEqual(titles(details), ["메일 540-560"])
    }

    /// 대분류 블록은 합쳐진 첫 기록의 제목이 아니라 분류 이름을 적는다. 사용자 분류는 제목 그대로다.
    func testMainBlockShowsTheCategoryName() {
        let meeting = MapHomeNLEClipEditor.option(forCategoryID: "work", title: "회의", behavior: "meeting")
        XCTAssertEqual(MapHomeNLEClipEditor.mainTitle(meeting, language: .korean), "업무")
        XCTAssertEqual(MapHomeNLEClipEditor.mainTitle(.custom("양치"), language: .korean), "양치")
    }

    func testStationarySensorDoesNotContradictADetail() {
        let segments = [
            MapHomeNLESensorSegment(
                channel: .motion, startMinute: 0, endMinute: 60, title: "정지 · iPhone",
                categoryID: "activity", behavior: MotionKind.stationary.rawValue
            ),
        ]
        XCTAssertFalse(NLESensorEvidenceText.summary(segments, start: 10, end: 20, categoryID: "work").differs)
    }

    /// 센서 글자는 상세 블록이 가리지 않는 시간에 놓인다.
    func testSensorLabelsUseMinutesWithoutDetails() {
        let details = [
            MapHomeSectionDetail(id: UUID(), title: "회의", categoryID: "work", behavior: "meeting", startMinute: 480, endMinute: 540),
            MapHomeSectionDetail(id: UUID(), title: "통화", categoryID: "activity", behavior: "phoneCall", startMinute: 600, endMinute: 620),
        ]
        let clips = MapHomeNLEClipEditor.makeSubTrack(details: details, segments: workDay()).clips
        XCTAssertEqual(
            NLESensorLabelPlacement.freeRanges(start: 470, end: 720, occupied: clips),
            [470..<480, 540..<600, 620..<720]
        )
        XCTAssertEqual(NLESensorLabelPlacement.freeRanges(start: 490, end: 530, occupied: clips), [])
    }

    // MARK: - 선택 취소

    private func clears(
        before: String? = "a",
        touched: String? = "a",
        main: Bool = true,
        left: Bool = false,
        edit: Bool = false,
        lifted: Bool = false
    ) -> Bool {
        NLESelectionTapPolicy.clearsSelection(
            selectedAtTouchStart: before, touchedClipID: touched, isMainLaneTouch: main,
            leftSlop: left, didEdit: edit, isLifted: lifted
        )
    }

    func testSecondTapOnSelectedClipClearsSelection() {
        XCTAssertTrue(clears())
    }

    func testFirstTapOrOtherClipKeepsSelection() {
        XCTAssertFalse(clears(before: nil), "처음 누르면 고르기만 한다")
        XCTAssertFalse(clears(before: "b"), "다른 클립을 누르면 그 클립을 고른다")
        XCTAssertFalse(clears(before: nil, touched: nil))
    }

    func testDragTrimAndLiftAreNotCancels() {
        XCTAssertFalse(clears(left: true), "끌기")
        XCTAssertFalse(clears(edit: true), "경계 다듬기")
        XCTAssertFalse(clears(lifted: true), "길게 눌러 집어 들기")
        XCTAssertFalse(clears(main: false), "상세·센서 칸과 재생 헤드")
    }

    func testTapSlopBoundary() {
        XCTAssertFalse(NLESelectionTapPolicy.hasLeftSlop(translation: CGSize(width: 1, height: 2)))
        XCTAssertTrue(NLESelectionTapPolicy.hasLeftSlop(translation: CGSize(width: 2, height: 2)))
    }
}
