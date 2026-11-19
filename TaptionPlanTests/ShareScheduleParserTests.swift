import XCTest
@testable import TaptionPlan

/// 공유 글에서 일정 읽기. 샘플은 전부 가짜다. 기준 시각은 2027-03-01(월) 10:00 UTC 달력.
final class ShareScheduleParserTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    private var now: Date { calendar.date(from: DateComponents(year: 2027, month: 3, day: 1, hour: 10)) ?? .now }

    private func parts(_ draft: ShareScheduleParser.Draft?) -> [Int]? {
        guard let draft else { return nil }
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: draft.start)
        return [c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0]
    }

    func testRelativeDayWithAfternoonTime() throws {
        let draft = try XCTUnwrap(ShareScheduleParser.parse("내일 오후 3시 치과 예약", now: now, calendar: calendar))
        XCTAssertEqual(parts(draft), [2027, 3, 2, 15, 0])
        XCTAssertTrue(draft.title.contains("치과"))
        XCTAssertFalse(draft.title.contains("내일"))
        XCTAssertEqual(draft.durationMinutes, 60)
    }

    func testExplicitDateFormsAllReadTheSameDay() {
        for form in ["3월 7일", "03/07", "2027-03-07", "2027.3.7"] {
            XCTAssertEqual(parts(ShareScheduleParser.parse("\(form) 14:30 미팅", now: now, calendar: calendar)), [2027, 3, 7, 14, 30], form)
        }
    }

    func testDateWithoutYearRollsToTheNextYearWhenFarPast() {
        let december = calendar.date(from: DateComponents(year: 2026, month: 12, day: 20, hour: 9)) ?? .now
        XCTAssertEqual(parts(ShareScheduleParser.parse("1월 5일 오전 10시 모임", now: december, calendar: calendar)), [2027, 1, 5, 10, 0])
    }

    func testTimeRangeBecomesDurationAndDateTokensAreNotReadAsARange() throws {
        let draft = try XCTUnwrap(ShareScheduleParser.parse("2027-03-07 9-11 워크숍", now: now, calendar: calendar))
        XCTAssertEqual(parts(draft), [2027, 3, 7, 9, 0], "날짜의 하이픈이 시각 범위로 읽히지 않는다")
        XCTAssertEqual(draft.durationMinutes, 120)
        XCTAssertTrue(draft.title.contains("워크숍"))
    }

    func testWeekdaysThisWeekAndNextWeek() {
        // 2027-03-01은 월요일.
        XCTAssertEqual(parts(ShareScheduleParser.parse("금요일 오후 7시 저녁", now: now, calendar: calendar)), [2027, 3, 5, 19, 0])
        XCTAssertEqual(parts(ShareScheduleParser.parse("이번 주 수요일 10:00 회의", now: now, calendar: calendar)), [2027, 3, 3, 10, 0])
        XCTAssertEqual(parts(ShareScheduleParser.parse("다음 주 금요일 오전 11시 점심", now: now, calendar: calendar)), [2027, 3, 12, 11, 0])
        XCTAssertEqual(parts(ShareScheduleParser.parse("모레 20:00 영화", now: now, calendar: calendar)), [2027, 3, 3, 20, 0])
        XCTAssertEqual(parts(ShareScheduleParser.parse("글피 8:30 출발", now: now, calendar: calendar))?.prefix(3).map { $0 }, [2027, 3, 4])
    }

    func testFirstDateInTextWins() {
        XCTAssertEqual(parts(ShareScheduleParser.parse("3월 9일 오후 2시 세미나 (3월 5일 신청 마감)", now: now, calendar: calendar)), [2027, 3, 9, 14, 0])
    }

    func testAmbiguousOrMissingPartsReturnNil() {
        XCTAssertNil(ShareScheduleParser.parse("내일 회식", now: now, calendar: calendar), "시각이 없다")
        XCTAssertNil(ShareScheduleParser.parse("오후 3시에 봐요", now: now, calendar: calendar), "날짜가 없다")
        XCTAssertNil(ShareScheduleParser.parse("안녕하세요 오늘 점심 뭐 드실래요", now: now, calendar: calendar), "시각이 없다")
        XCTAssertNil(ShareScheduleParser.parse("2020-01-05 오후 3시 모임", now: now, calendar: calendar), "이미 지난 날짜")
        XCTAssertNil(ShareScheduleParser.parse("2월 30일 오후 3시 모임", now: now, calendar: calendar), "없는 날짜")
        XCTAssertNil(ShareScheduleParser.parse("   ", now: now, calendar: calendar))
        XCTAssertNil(ShareScheduleParser.parse(String(repeating: "가", count: ShareScheduleParser.maximumCharacters + 1), now: now, calendar: calendar))
    }

    func testTitleIsCleanedAndCapped() throws {
        let long = "내일 오후 3시 " + String(repeating: "아주긴제목", count: 20)
        let draft = try XCTUnwrap(ShareScheduleParser.parse(long, now: now, calendar: calendar))
        XCTAssertLessThanOrEqual(draft.title.count, ShareScheduleParser.maximumTitle)
        XCTAssertEqual(ShareScheduleParser.title("  [ 치과 \n 예약 ] ,"), "치과 예약")
        XCTAssertEqual(ShareScheduleParser.title("...").count, 0)
    }

    func testLongInputsStayFast() {
        let clock = ContinuousClock()
        for text in [String(repeating: "내일 ", count: 600), String(repeating: "3/4 ", count: 500), String(repeating: "가", count: 1_900)] {
            let elapsed = clock.measure { _ = ShareScheduleParser.parse(text, now: now, calendar: calendar) }
            XCTAssertLessThan(elapsed, .seconds(2))
        }
    }
}
