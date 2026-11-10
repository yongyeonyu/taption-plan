import XCTest
@testable import TaptionClassifierEngine

/// 베타 기록(2026-11-09, 위치 꺼짐·워치 미착용)을 줄인 자료로 휴대폰 점수형 수면을 확인한다(SLP1110A01).
final class PhoneSleepScoreTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }()

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func mark(_ date: Date) -> ClassifierInterval { ClassifierInterval(start: date, end: date) }

    func testLocationOffNightBecomesSleepBetweenPhoneTouches() throws {
        let signals = PhoneSleepScore.Signals(
            night: ClassifierInterval(start: at(8, 18), end: at(9, 12)),
            wakeEvents: [
                ClassifierInterval(start: at(8, 22, 30), end: at(8, 22, 50)),
                mark(at(9, 0, 57)), mark(at(9, 1, 21)), mark(at(9, 1, 53)),
                mark(at(9, 7, 38)), mark(at(9, 10, 21)),
                ClassifierInterval(start: at(9, 11, 16), end: at(9, 11, 31)),
            ],
            stillEvents: [ClassifierInterval(start: at(9, 1, 53), end: at(9, 1, 54))]
        )
        let verdict = try XCTUnwrap(PhoneSleepScore.evaluate(signals, calendar: calendar))
        XCTAssertEqual(verdict.interval, ClassifierInterval(start: at(9, 1, 53), end: at(9, 7, 38)))
        XCTAssertTrue(verdict.isSleep, "\(verdict.score) \(verdict.factors)")
        XCTAssertTrue(verdict.factors.contains("위치 없음"))
    }

    func testLongDaytimeStillnessIsNotSleep() throws {
        let signals = PhoneSleepScore.Signals(
            night: ClassifierInterval(start: at(9, 9), end: at(9, 21)),
            wakeEvents: [mark(at(9, 13)), mark(at(9, 18, 30))],
            samples: [PhoneSleepScore.Sample(timestamp: at(9, 15), screenIsOn: false, isCharging: true, isAtHome: false)]
        )
        let verdict = try XCTUnwrap(PhoneSleepScore.evaluate(signals, calendar: calendar))
        XCTAssertFalse(verdict.isSleep, "\(verdict.score) \(verdict.factors)")
    }

    func testScreenOnAndAwayFromHomeLowerTheScore() throws {
        let night = ClassifierInterval(start: at(9, 18), end: at(10, 12))
        let quiet = PhoneSleepScore.Signals(night: night, wakeEvents: [ClassifierInterval(start: at(9, 18), end: at(10, 1)), ClassifierInterval(start: at(10, 7), end: at(10, 12))])
        let base = try XCTUnwrap(PhoneSleepScore.evaluate(quiet, calendar: calendar))
        var busy = quiet
        busy.samples = stride(from: 1, to: 24, by: 1).map {
            PhoneSleepScore.Sample(timestamp: at(10, 1).addingTimeInterval(Double($0) * 900), screenIsOn: true, isAtHome: false)
        }
        let lowered = try XCTUnwrap(PhoneSleepScore.evaluate(busy, calendar: calendar))
        XCTAssertLessThan(lowered.score, base.score)
        XCTAssertFalse(lowered.isSleep, "\(lowered.score) \(lowered.factors)")
    }

    func testShortQuietSpanIsNoCandidate() {
        let signals = PhoneSleepScore.Signals(
            night: ClassifierInterval(start: at(9, 18), end: at(10, 12)),
            wakeEvents: stride(from: 0, to: 18, by: 1).map { mark(at(9, 18).addingTimeInterval(Double($0) * 7_200)) }
        )
        XCTAssertNil(PhoneSleepScore.evaluate(signals, calendar: calendar))
    }

    func testUsualWindowLearnsAcrossMidnight() throws {
        let nights = [(1, 23, 50, 2, 7, 10), (2, 0, 20, 3, 7, 40), (3, 23, 40, 4, 6, 50), (4, 0, 5, 5, 7, 20)].map {
            ClassifierInterval(start: at($0.0 + ($0.1 < 12 ? 1 : 0), $0.1, $0.2), end: at($0.3, $0.4, $0.5))
        }
        let window = try XCTUnwrap(PhoneSleepScore.usualWindow(pastSleeps: nights, calendar: calendar))
        XCTAssertTrue(window.isLearned)
        XCTAssertTrue(window.bedMinute >= 23 * 60 || window.bedMinute <= 60, "\(window.bedMinute)")
        XCTAssertTrue((6 * 60...8 * 60).contains(window.wakeMinute), "\(window.wakeMinute)")
    }

    func testRealNightBeatsLongerQuietEvening() throws {
        let signals = PhoneSleepScore.Signals(
            night: ClassifierInterval(start: at(8, 18), end: at(9, 12)),
            wakeEvents: [mark(at(9, 0, 30)), mark(at(9, 1, 54)), mark(at(9, 7, 38)), ClassifierInterval(start: at(9, 9), end: at(9, 12))]
        )
        let verdict = try XCTUnwrap(PhoneSleepScore.evaluate(signals, calendar: calendar))
        XCTAssertEqual(verdict.interval, ClassifierInterval(start: at(9, 1, 54), end: at(9, 7, 38)), "\(verdict.factors)")
        XCTAssertTrue(verdict.isSleep)
    }

    /// REV1110A01: 평소 취침이 자정 뒤여도 그 전 저녁에 잠든 밤을 밤 시간대로 센다.
    func testUsualWindowAfterMidnightCoversEveningStart() {
        let window = PhoneSleepScore.UsualWindow(bedMinute: 30, wakeMinute: 450, isLearned: true)
        let overlap = PhoneSleepScore.nightOverlap(ClassifierInterval(start: at(8, 23, 45), end: at(9, 7)), window: window, calendar: calendar)
        XCTAssertEqual(overlap, 1, accuracy: 0.01)
    }
}
