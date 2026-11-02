import XCTest
@testable import TaptionPlan

final class MapHomeAllowanceTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func rate(_ amount: Double, _ period: MapHomeAllowancePolicy.Period, on day: Date) -> Double {
        MapHomeAllowancePolicy.hourlyRate(.init(amount: amount, period: period), on: day, calendar: calendar)
    }

    func testMonthDividesByThatMonthsActualHours() {
        XCTAssertEqual(rate(300_000, .month, on: date(2026, 11, 15)), 300_000.0 / (30 * 24), accuracy: 0.0001)
        XCTAssertEqual(rate(300_000, .month, on: date(2026, 12, 15)), 300_000.0 / (31 * 24), accuracy: 0.0001)
        XCTAssertEqual(rate(300_000, .month, on: date(2026, 2, 15)), 300_000.0 / (28 * 24), accuracy: 0.0001)
    }

    func testLeapFebruaryUses29Days() {
        XCTAssertEqual(rate(300_000, .month, on: date(2028, 2, 29)), 300_000.0 / (29 * 24), accuracy: 0.0001)
    }

    func testWeekAndDayRates() {
        XCTAssertEqual(rate(50_000, .week, on: date(2026, 11, 2)), 50_000.0 / 168, accuracy: 0.0001)
        XCTAssertEqual(rate(24_000, .day, on: date(2026, 11, 2)), 1_000, accuracy: 0.0001)
    }

    func testEarnedAccumulatesFromMidnightAroundTheClock() {
        let settings = MapHomeAllowancePolicy.Settings(amount: 24_000, period: .day)
        let day = date(2026, 11, 2)
        func earned(asOf: Date, tick: TimeInterval = 1) -> Double {
            MapHomeAllowancePolicy.earned(settings, day: day, asOf: asOf, tick: tick, calendar: calendar)
        }
        XCTAssertEqual(earned(asOf: day), 0)
        XCTAssertEqual(earned(asOf: date(2026, 11, 2, hour: 3)), 3_000, accuracy: 0.0001, "새벽 수면 시간도 쌓인다")
        XCTAssertEqual(earned(asOf: date(2026, 11, 2, hour: 13, minute: 30)), 13_500, accuracy: 0.0001)
        XCTAssertEqual(earned(asOf: date(2026, 11, 2, hour: 0, minute: 59), tick: 3_600), 0, "표시 간격 단위로 끊는다")
    }

    func testPastDayIsFullAndFutureDayIsZero() {
        let settings = MapHomeAllowancePolicy.Settings(amount: 300_000, period: .month)
        let now = date(2026, 11, 2, hour: 12)
        let past = MapHomeAllowancePolicy.earned(settings, day: date(2026, 10, 15), asOf: now, calendar: calendar)
        XCTAssertEqual(past, 300_000.0 / 31, accuracy: 0.0001, "지난 날은 그 달 일수로 나눈 하루치")
        XCTAssertEqual(MapHomeAllowancePolicy.earned(settings, day: date(2026, 11, 3), asOf: now, calendar: calendar), 0)
    }

    func testFullMonthAddsUpToEnteredAmount() {
        let settings = MapHomeAllowancePolicy.Settings(amount: 300_000, period: .month)
        let total = (1...29).reduce(0.0) { sum, day in
            sum + MapHomeAllowancePolicy.earned(settings, day: date(2028, 2, day), asOf: date(2028, 3, 2), calendar: calendar)
        }
        XCTAssertEqual(total, 300_000, accuracy: 0.001)
    }

    func testLoadUsesMonthByDefaultAndCounterLineNeedsAmount() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MapHomeAllowanceTests"))
        defaults.removePersistentDomain(forName: "MapHomeAllowanceTests")
        defer { defaults.removePersistentDomain(forName: "MapHomeAllowanceTests") }
        XCTAssertEqual(MapHomeAllowancePolicy.load(defaults), .init(amount: 0, period: .month))
        XCTAssertFalse(MapHomeAllowancePolicy.load(defaults).isConfigured)
        defaults.set(50_000.0, forKey: MapHomeAllowancePolicy.amountKey)
        defaults.set("week", forKey: MapHomeAllowancePolicy.periodKey)
        XCTAssertEqual(MapHomeAllowancePolicy.load(defaults), .init(amount: 50_000, period: .week))

        let day = date(2026, 11, 2)
        XCTAssertNil(MapHomeAllowancePolicy.counterLine(
            day: day, playbackMinute: nil, now: day, tick: 1, language: .korean, settings: .init()
        ))
    }

    func testCounterLinePlaybackStopsAtPlaybackMinuteNotNow() throws {
        let local = MapHomeGrowthPolicy.localCalendar
        let day = local.startOfDay(for: date(2026, 10, 15))
        let line = try XCTUnwrap(MapHomeAllowancePolicy.counterLine(
            day: day, playbackMinute: 90, now: day.addingTimeInterval(20 * 3_600), tick: 1,
            language: .korean, settings: .init(amount: 24_000, period: .day)
        ))
        XCTAssertEqual(line.text, "1,500원")
        XCTAssertTrue(line.isAllowance)
    }
}
