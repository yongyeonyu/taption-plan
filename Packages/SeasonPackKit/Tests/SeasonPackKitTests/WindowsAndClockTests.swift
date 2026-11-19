import Foundation
import Testing
@testable import SeasonPackKit

struct WindowsTests {
    private func manifest(_ built: (manifest: Data, files: [String: Data])) -> SeasonPackManifest { Fixture.manifest(built.manifest) }

    @Test func christmasRepeatsEveryYearAndRespectsEdges() {
        let christmas = manifest(Fixture.pack(id: "christmas"))
        for year in [2026, 2027, 2031] {
            #expect(Fixture.windows.isActive(christmas, at: Fixture.date(year, 12, 19, 0, 0)))
            #expect(Fixture.windows.isActive(christmas, at: Fixture.date(year, 12, 30, 23, 59)))
            #expect(!Fixture.windows.isActive(christmas, at: Fixture.date(year, 12, 18, 23, 59)))
            #expect(!Fixture.windows.isActive(christmas, at: Fixture.date(year, 12, 31, 0, 0)))
        }
        #expect(!Fixture.windows.isActive(christmas, at: Fixture.date(2026, 7, 1)))
    }

    @Test func windowCrossingNewYearIsRead() {
        let newYear = manifest(Fixture.pack(id: "newyear", windows: [Fixture.window(12, 31, 1, 1)]))
        #expect(Fixture.windows.isActive(newYear, at: Fixture.date(2026, 12, 31, 23, 50)))
        #expect(Fixture.windows.isActive(newYear, at: Fixture.date(2027, 1, 1, 12)))
        #expect(!Fixture.windows.isActive(newYear, at: Fixture.date(2027, 1, 2, 0, 0)))
        #expect(!Fixture.windows.isActive(newYear, at: Fixture.date(2026, 12, 30, 23, 59)))
    }

    @Test func yearSpecificWindowOnlyThatYear() {
        let only = manifest(Fixture.pack(windows: [Fixture.window(2, 6, 2, 9, year: 2027)]))
        #expect(Fixture.windows.isActive(only, at: Fixture.date(2027, 2, 7)))
        #expect(!Fixture.windows.isActive(only, at: Fixture.date(2028, 2, 7)))
    }

    @Test func sunsetAndSunriseTriggersGateTheWindow() {
        let evening = manifest(Fixture.pack(windows: [Fixture.window(12, 19, 12, 30, fromTime: "sunset", toTime: "sunrise")]))
        #expect(!Fixture.windows.isActive(evening, at: Fixture.date(2026, 12, 19, 16, 49)))
        #expect(Fixture.windows.isActive(evening, at: Fixture.date(2026, 12, 19, 16, 51)))
        #expect(Fixture.windows.isActive(evening, at: Fixture.date(2026, 12, 30, 7, 39)))
        #expect(!Fixture.windows.isActive(evening, at: Fixture.date(2026, 12, 30, 7, 41)))
        // 좌표(일몰 정보)가 없으면 시간 조건은 꺼지고 창 조건만 쓴다.
        let blind = SeasonPackWindows(calendar: Fixture.calendar, sun: { _ in SeasonPackSunTimes() })
        #expect(blind.isActive(evening, at: Fixture.date(2026, 12, 19, 3, 0)))
    }

    @Test func overlapPicksPriorityThenVersion() {
        let low = manifest(Fixture.pack(id: "low", version: 5, priority: 1))
        let high = manifest(Fixture.pack(id: "high", version: 1, priority: 9))
        let newer = manifest(Fixture.pack(id: "high", version: 2, priority: 9))
        let day = Fixture.date(2026, 12, 25)
        #expect(Fixture.windows.activePack(in: [low, high], at: day)?.id == "high")
        #expect(Fixture.windows.activePack(in: [high, newer, low], at: day)?.version == 2)
        #expect(Fixture.windows.activePack(in: [low, high], at: Fixture.date(2026, 6, 1)) == nil)
    }

    @Test func nthWeekdayRuleParsesToTheRightDay() {
        // 11월 셋째 목요일(수능 규칙): 2027-11-18.
        let rule: [String: Any] = ["rule": ["kind": "nthWeekday", "month": 11, "weekday": 5, "nth": 3]]
        let exam = manifest(Fixture.pack(windows: [rule]))
        #expect(Fixture.windows.isActive(exam, at: Fixture.date(2027, 11, 18, 9)))
        #expect(!Fixture.windows.isActive(exam, at: Fixture.date(2027, 11, 19, 9)))
        #expect(!Fixture.windows.isActive(exam, at: Fixture.date(2027, 11, 11, 9)))
        let last: [String: Any] = ["rule": ["kind": "nthWeekday", "month": 11, "weekday": 5, "nth": -1]]
        #expect(Fixture.windows.isActive(manifest(Fixture.pack(windows: [last])), at: Fixture.date(2027, 11, 25)))
    }

    @Test func nextTransitionFindsWindowEdgesAndSunEvents() {
        let christmas = manifest(Fixture.pack(extra: ["slots": ["house": ["base": "img.a", "lit": "img.a", "lights": ["on": "sunset", "off": "sunrise"]]]]))
        let next = SeasonPackTriggers.nextTransition(packs: [christmas], after: Fixture.date(2026, 12, 25, 12), windows: Fixture.windows)
        #expect(next == Fixture.date(2026, 12, 25, 16, 50))
        let before = SeasonPackTriggers.nextTransition(packs: [manifest(Fixture.pack())], after: Fixture.date(2026, 12, 18, 12), windows: Fixture.windows)
        #expect(before == Fixture.date(2026, 12, 19, 0, 0))
        #expect(!SeasonPackTriggers.needsExactMinute(manifest(Fixture.pack())))
        #expect(SeasonPackTriggers.needsExactMinute(manifest(Fixture.pack(windows: [Fixture.window(12, 31, 1, 1, fromTime: "23:50")]))))
    }
}

struct ClockTests {
    private func makeClock(_ time: TestTime, storage: SeasonPackClockStorage = MemoryClockStorage()) -> SeasonPackClock {
        SeasonPackClock(storage: storage, deviceNow: { time.device }, monotonic: { time.mono })
    }

    @Test func serverDatePlusMonotonicIsVerified() {
        let time = TestTime(device: Fixture.date(2026, 12, 25, 10))
        let clock = makeClock(time)
        clock.recordServerDate(Fixture.date(2026, 12, 25, 10))
        time.advance(3600)
        #expect(clock.reading() == .verified(Fixture.date(2026, 12, 25, 11)))
    }

    @Test func deviceJumpingForwardTwelveHoursIsSuspiciousUntilServerConfirms() {
        let time = TestTime(device: Fixture.date(2026, 12, 10, 10))
        let clock = makeClock(time)
        clock.recordServerDate(time.device)
        time.setDevice(Fixture.date(2026, 12, 25, 10)) // 사용자가 날짜를 앞으로 돌림
        #expect(clock.reading() == .suspicious)
        #expect(clock.eventDate == nil)
        clock.recordServerDate(Fixture.date(2026, 12, 10, 10).addingTimeInterval(1)) // 서버는 진짜 시각을 말한다
        #expect(clock.reading() == .suspicious) // 기기가 여전히 어긋나 있으면 계속 닫혀 있다
        time.setDevice(Fixture.date(2026, 12, 10, 10).addingTimeInterval(1))
        #expect(clock.reading().date != nil)
    }

    @Test func backwardTenMinutesIsSuspiciousAndSmallBackStepKeepsHighWater() {
        let time = TestTime(device: Fixture.date(2026, 12, 25, 10))
        let clock = makeClock(time)
        clock.recordServerDate(time.device)
        time.advance(1800)
        let high = clock.reading().date!
        time.setDevice(time.device.addingTimeInterval(-300)) // 5분 뒤로: 허용, 고수위 유지
        #expect(clock.reading().date! >= high)
        time.setDevice(time.device.addingTimeInterval(-600)) // 합쳐 15분 뒤로
        #expect(clock.reading() == .suspicious)
    }

    @Test func offlineWithinFortyEightHoursUsesDeviceTimeAndBeyondIsClosed() {
        let storage = MemoryClockStorage()
        let time = TestTime(device: Fixture.date(2026, 12, 20, 10))
        let first = makeClock(time, storage: storage)
        first.recordServerDate(time.device)
        _ = first.reading() // 고수위 확정
        // 앱을 껐다 켜고(단조 시간 초기화) 하루 뒤: 서버 없이 기기 시각.
        let reboot = TestTime(device: Fixture.date(2026, 12, 21, 12), mono: 5)
        let second = makeClock(reboot, storage: storage)
        #expect(second.reading() == .device(Fixture.date(2026, 12, 21, 12)))
        reboot.setDevice(Fixture.date(2026, 12, 23, 11)) // 고수위 + 49시간
        #expect(second.reading() == .suspicious)
    }

    @Test func staleAnchorOlderThanADayFallsBackToDeviceTime() {
        let time = TestTime(device: Fixture.date(2026, 12, 20, 10))
        let clock = makeClock(time)
        clock.recordServerDate(time.device)
        time.advance(25 * 3600)
        #expect(clock.reading() == .device(time.device))
    }

    @Test func neverSyncedFirstRunAcceptsDeviceTime() {
        let time = TestTime(device: Fixture.date(2026, 12, 25, 10))
        #expect(makeClock(time).reading() == .device(time.device))
    }

    @Test func debugHookIsOffByDefaultAndParsesArguments() {
        let time = TestTime(device: Fixture.date(2026, 6, 1, 10))
        let clock = makeClock(time)
        #expect(clock.reading().date == time.device) // 훅을 켜지 않으면 기기 시각 그대로
        #expect(SeasonPackClock.debugDateFromLaunchArguments(["app"], calendar: Fixture.calendar) == nil)
        #expect(SeasonPackClock.debugDateFromLaunchArguments(["app", "-seasonPackDate", "2026-12-25T21:00"], calendar: Fixture.calendar) == Fixture.date(2026, 12, 25, 21))
        clock.setDebugDate { Fixture.date(2026, 12, 25, 21) }
        #expect(clock.reading() == .verified(Fixture.date(2026, 12, 25, 21)))
        clock.setDebugDate(nil)
        #expect(clock.reading().date == time.device)
    }
}
