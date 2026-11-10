import XCTest
@testable import TaptionClassifierEngine

/// 서머타임 바뀌는 날에도 낮 창이 벽시계 9~21시인지 (REV1110A04).
final class SleepFusionDaylightSavingTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func local(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: minute))!
    }

    func testDaytimeWindowStartsAtNineOnSpringForwardDay() {
        // 2026-03-08 02시가 03시로 넘어간다. 자정+9시간은 벽시계 10시다.
        let nap = ClassifierInterval(start: local(8, 9, 30), end: local(8, 10, 30))
        XCTAssertTrue(SleepFusion.isDaytime(nap, calendar: calendar))
        XCTAssertFalse(SleepFusion.isDaytime(ClassifierInterval(start: local(8, 8, 30), end: local(8, 9, 30)), calendar: calendar))
    }

    func testDaytimeWindowEndsAtTwentyOneOnSpringForwardDay() {
        let evening = ClassifierInterval(start: local(8, 20, 30), end: local(8, 21, 30))
        XCTAssertFalse(SleepFusion.isDaytime(evening, calendar: calendar))
        // 21시 직후에 시작한 휴대폰 수면은 낮 창 시작으로 보지 않는다.
        let night = ClassifierInterval(start: local(8, 21, 15), end: local(8, 23, 45))
        XCTAssertTrue(SleepFusion.acceptsPhoneOnly(night, calendar: calendar))
    }
}
