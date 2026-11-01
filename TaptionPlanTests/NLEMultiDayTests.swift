import XCTest
import UIKit
import CoreLocation
import StoreKit
import StoreKitTest
import TaptionPlanCore
@testable import TaptionPlan

/// 클립 편집기의 여러 날 창(NLE1029A02): 전날을 음수 분으로 앞에 잇고, 자정을 넘는 기록은 클립 하나다.
@MainActor
final class NLEMultiDayTests: XCTestCase {
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

    private let sleepID = UUID()

    /// 오늘: 수면 00:00–07:00(어제에서 이어짐), 업무 07:00–24:00.
    private func todayTrack() -> NLETrack {
        MapHomeNLEClipEditor.makeMainTrack(segments: [
            segment(0, 420, "sleep", sources: [sleepID]),
            segment(420, 1_440, "work", sources: [UUID()]),
        ])
    }

    /// 어제: 일상 00:00–22:00, 수면 22:00–24:00(오늘 수면과 같은 기록).
    private func yesterdayClips() -> NLEDayClips {
        NLEDayWindow.clips(
            segments: [
                segment(0, 1_320, "activity", sources: [UUID()]),
                segment(1_320, 1_440, "sleep", sources: [sleepID]),
            ],
            details: [],
            dayOffset: -1
        )
    }

    /// 어제는 −1,440…0으로 옮겨져 하루를 빈틈없이 채운다.
    func testYesterdayShiftsToNegativeMinutes() {
        let clips = yesterdayClips().main
        XCTAssertEqual(clips.first?.startMinute, -1_440)
        XCTAssertEqual(clips.last?.endMinute, 0)
        XCTAssertEqual(clips.reduce(0) { $0 + $1.lengthMinutes }, NLETrack.dayMinutes)
        XCTAssertTrue(clips.allSatisfy { $0.id.hasPrefix("main|d-1|") })
        let track = MapHomeNLEClipEditor.makeMainTrack(segments: [], dayOffset: -1)
        XCTAssertEqual(track.rangeStartMinute, -1_440)
        XCTAssertEqual(track.rangeEndMinute, 0)
    }

    /// 자정을 넘는 수면은 앞에 이은 뒤 클립 하나·원본 구간 하나가 된다.
    func testOvernightSleepJoinsIntoOneClip() throws {
        let joined = NLEDayWindow.prepending(yesterdayClips().main, to: todayTrack())
        XCTAssertEqual(joined.rangeStartMinute, -1_440)
        XCTAssertEqual(joined.clips.count, 3)
        let sleep = try XCTUnwrap(joined.clip(atMinute: -60))
        XCTAssertEqual(sleep.id, joined.clip(atMinute: 60)?.id)
        XCTAssertEqual(sleep.startMinute, -120)
        XCTAssertEqual(sleep.endMinute, 420)
        XCTAssertEqual(sleep.parent.startMinute, -120)
        XCTAssertEqual(sleep.parent.endMinute, 420)
        XCTAssertEqual(sleep.parent.sourceIDs, [sleepID])
        XCTAssertFalse(sleep.isDirty, "이어 붙이기만 한 상태는 저장할 것이 없어야 한다")
    }

    /// 이은 수면의 분류를 바꾸면 23:00→07:00을 덮는 요청 하나가 나간다.
    func testJoinedSleepYieldsOneRequestAcrossMidnight() throws {
        var joined = NLEDayWindow.prepending(yesterdayClips().main, to: todayTrack())
        let sleep = try XCTUnwrap(joined.clip(atMinute: -60))
        let rest = MapHomeNLEClipEditor.option(forCategoryID: "hobby", title: "hobby", behavior: nil)
        XCTAssertTrue(joined.setOption(sleep.id, to: rest))

        let requests = joined.editRequests(dayStart: dayStart(), calendar: calendar)
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.sourceIDs, [sleepID])
        XCTAssertEqual(
            request.originalSpan.start,
            calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 22))
        )
        XCTAssertEqual(
            request.originalSpan.end,
            calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 7))
        )
        guard case let .cover(pieces, _) = request.mode else { return XCTFail("cover 요청이어야 한다") }
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces.first?.option.categoryID, "hobby")
    }

    /// 눈금은 전날로 넘어가도 24시간으로 감는다.
    func testRulerWrapsIntoPreviousDay() {
        XCTAssertEqual(MapHomeNLEClipEditor.minuteLabel(-30), "23:30")
        XCTAssertEqual(MapHomeNLEClipEditor.minuteLabel(-1_440), "00:00")
        XCTAssertEqual(MapHomeNLEClipEditor.minuteLabel(1_440), "24:00")
        XCTAssertEqual(NLEDayWindow.wrappedHour(-60), 23)
        XCTAssertEqual(NLEDayWindow.wrappedHour(-1_440), 0)
        XCTAssertEqual(NLEDayWindow.dayIndex(-30), -1)
        XCTAssertEqual(NLEDayWindow.dayIndex(0), 0)
        XCTAssertEqual(NLEDayWindow.dayIndex(-1_440), -1)
        XCTAssertEqual(NLEDayWindow.dayIndex(-1_441), -2)
        XCTAssertEqual(NLEDayWindow.dayLabel(dayIndex: -1, baseDate: dayStart(), calendar: calendar), "10/22")
        XCTAssertEqual(NLEDayWindow.dayLabel(dayIndex: 0, baseDate: dayStart(), calendar: calendar), "10/23")
    }

    /// 이미 고친 클립은 전날을 앞에 이어도 그대로 남고, 창은 하루씩 넓어진다.
    func testPrependingKeepsEditedClip() throws {
        var track = todayTrack()
        let work = try XCTUnwrap(track.clip(atMinute: 600))
        let hobby = MapHomeNLEClipEditor.option(forCategoryID: "hobby", title: "hobby", behavior: nil)
        XCTAssertTrue(track.setOption(work.id, to: hobby))

        let joined = NLEDayWindow.prepending(yesterdayClips().main, to: track)
        let kept = try XCTUnwrap(joined.clip(work.id))
        XCTAssertEqual(kept.option.categoryID, "hobby")
        XCTAssertTrue(kept.isDirty)
        XCTAssertEqual(kept.startMinute, 420)
        XCTAssertEqual(kept.endMinute, 1_440)
        XCTAssertEqual(joined.rangeStartMinute, -1_440)
        XCTAssertEqual(joined.rangeEndMinute, 1_440)

        let window = NLEDayWindow(baseDate: dayStart(), loadedDays: 2, calendar: calendar)
        XCTAssertEqual(window.rangeStartMinute, -1_440)
        XCTAssertEqual(window.nextEarlierOffset, -2)
        XCTAssertEqual(
            window.nextEarlierDate,
            calendar.date(from: DateComponents(year: 2026, month: 10, day: 21))
        )
        XCTAssertTrue(NLEDayWindow.needsEarlierDay(visibleStartMinute: -1_000, visibleMinutes: 600, rangeStartMinute: -1_440))
        XCTAssertFalse(NLEDayWindow.needsEarlierDay(visibleStartMinute: -800, visibleMinutes: 600, rangeStartMinute: -1_440))
    }
}
