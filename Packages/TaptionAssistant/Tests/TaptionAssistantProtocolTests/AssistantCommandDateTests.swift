import Foundation
import XCTest
@testable import TaptionAssistantProtocol

/// REV1117A02: AI가 보내는 `YYYY-MM-DD`는 기기 달력과 상관없이 서기다. 없는 날은 받지 않는다.
final class AssistantCommandDateTests: XCTestCase {
    private func calendar(_ identifier: Calendar.Identifier) -> Calendar {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = TimeZone(identifier: "Asia/Bangkok")!
        return calendar
    }

    func testADayIsReadAsTheGregorianDayOnABuddhistOrJapaneseCalendar() throws {
        var expected = Calendar(identifier: .gregorian)
        expected.timeZone = TimeZone(identifier: "Asia/Bangkok")!
        let midnight = try XCTUnwrap(expected.date(from: DateComponents(year: 2026, month: 11, day: 17)))
        for identifier in [Calendar.Identifier.gregorian, .buddhist, .japanese] {
            XCTAssertEqual(AssistantCommandParser.day("2026-11-17", calendar: calendar(identifier)), midnight, "\(identifier)")
        }
        let memo = AssistantCommandParser.memoInstant(date: "2026-11-17", time: "09:30", now: midnight, calendar: calendar(.buddhist))
        XCTAssertEqual(memo, midnight.addingTimeInterval(9.5 * 3_600))
    }

    func testADayThatDoesNotExistIsRefusedInsteadOfRollingOver() {
        let gregorian = calendar(.gregorian)
        XCTAssertNil(AssistantCommandParser.day("2026-02-31", calendar: gregorian))
        XCTAssertNil(AssistantCommandParser.day("2026-04-31", calendar: gregorian))
        XCTAssertNil(AssistantCommandParser.day("2027-02-29", calendar: gregorian))
        XCTAssertNotNil(AssistantCommandParser.day("2028-02-29", calendar: gregorian))
    }
}
