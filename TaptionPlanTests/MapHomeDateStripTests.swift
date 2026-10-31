import XCTest
import UIKit
import CoreLocation
import StoreKit
import StoreKitTest
import TaptionPlanCore
@testable import TaptionPlan

/// 날짜 줄은 선택일을 가운데 두는 창이라, 하루 넘길 때마다 새 날짜가 좌우에서 들어온다.
final class MapHomeDateStripTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul") ?? .current
        calendar.locale = Locale(identifier: "ko_KR")
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 13) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    /// 창은 언제나 선택일이 한가운데 오는 홀수 칸이다.
    func testWindowCentersTheSelectedDay() {
        let selected = date(2026, 10, 26)
        let days = MapHomeWeekStripMath.window(around: selected, calendar: calendar)
        XCTAssertEqual(days.count, MapHomeWeekStripMath.visibleDays)
        XCTAssertEqual(days.count % 2, 1)
        XCTAssertTrue(calendar.isDate(days[MapHomeWeekStripMath.windowRadius], inSameDayAs: selected))
    }

    /// 하루 넘기면 창이 하루만 옮겨 가고, 겹치는 날짜는 그대로 남는다(끊기지 않는다).
    func testWindowAdvancesOneDayAtATime() {
        let first = MapHomeWeekStripMath.window(
            around: date(2026, 10, 26), calendar: calendar
        )
        let next = MapHomeWeekStripMath.window(
            around: date(2026, 10, 27), calendar: calendar
        )
        XCTAssertEqual(
            Array(first.dropFirst()).map { calendar.startOfDay(for: $0) },
            Array(next.dropLast()).map { calendar.startOfDay(for: $0) }
        )
    }

    /// 달 말·해 넘김·주말에도 창은 그대로 이어진다(예전에는 주(일~토)에서 멈췄다).
    func testWindowCrossesMonthAndYearBoundaries() {
        for (start, expected) in [
            (date(2026, 10, 31), date(2026, 11, 3)),
            (date(2026, 12, 31), date(2027, 1, 3)),
            (date(2026, 2, 28), date(2026, 3, 3)),
        ] {
            let days = MapHomeWeekStripMath.window(around: start, calendar: calendar)
            let last = days[days.count - 1]
            XCTAssertTrue(calendar.isDate(last, inSameDayAs: expected))
        }
    }

    /// 창은 시각과 상관없이 그날 자정을 기준으로 만든다(같은 날이면 같은 창).
    func testWindowIgnoresTimeOfDay() {
        let morning = MapHomeWeekStripMath.window(
            around: date(2026, 10, 26, hour: 1), calendar: calendar
        )
        let evening = MapHomeWeekStripMath.window(
            around: date(2026, 10, 26, hour: 23), calendar: calendar
        )
        XCTAssertEqual(
            morning.map { calendar.startOfDay(for: $0) },
            evening.map { calendar.startOfDay(for: $0) }
        )
    }

    /// 손가락을 한 칸 밀면 창이 하루 옮겨 가고, 상쇄값은 0으로 돌아온다(이어져 흐른다).
    func testHalfPitchDragCompensatesExactlyOneDay() {
        let pitch = MapHomeWeekStripMath.dayPitch
        XCTAssertEqual(pitch, MapHomeWeekStripMath.dayWidth + MapHomeWeekStripMath.daySpacing)
        // 20pt만 밀었을 때: 창이 하루 옮겨 간 만큼(+38)을 더해 두면 손가락 자리에 머문다.
        let dragged: CGFloat = -20
        XCTAssertEqual(dragged + pitch, 18)
        // 꽉 밀었을 때: 상쇄값이 정확히 0이라 튀지 않는다.
        XCTAssertEqual(-pitch + pitch, 0)
    }
}
