import Foundation

public struct SeasonPackSunTimes: Sendable, Equatable {
    public var sunrise: Date?
    public var sunset: Date?
    public init(sunrise: Date? = nil, sunset: Date? = nil) { self.sunrise = sunrise; self.sunset = sunset }
}

public typealias SeasonPackSunProvider = @Sendable (Date) -> SeasonPackSunTimes

public enum SeasonPackDateParsing {
    /// `2026-12-19T00:00`(기기 시간대) 또는 `2026-12-19`.
    public static func localDateTime(_ text: String, calendar: Calendar) -> Date? {
        let parts = text.split(separator: "T", omittingEmptySubsequences: false)
        let day = parts[0].split(separator: "-").compactMap { Int($0) }
        guard day.count == 3, parts.count <= 2 else { return nil }
        var comps = DateComponents(year: day[0], month: day[1], day: day[2], hour: 0, minute: 0)
        if parts.count == 2 {
            guard let time = hourMinute(String(parts[1])) else { return nil }
            comps.hour = time.hour; comps.minute = time.minute
        }
        return calendar.date(from: comps)
    }

    public static func hourMinute(_ text: String) -> (hour: Int, minute: Int)? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { return nil }
        return (parts[0], parts[1])
    }
}

/// 기간 판정. 창은 월·일 기준이라 해가 바뀌어도 그대로 쓰고, 창 안이어도 시간 조건이 맞아야 켜진다.
/// 시간 조건은 기간 전체에 걸친 구간이다: 첫날 `fromTime`부터 마지막 날 `toTime`까지.
public struct SeasonPackWindows: Sendable {
    public var calendar: Calendar
    public var sun: SeasonPackSunProvider

    public init(calendar: Calendar = .current, sun: @escaping SeasonPackSunProvider = { _ in SeasonPackSunTimes() }) {
        self.calendar = calendar; self.sun = sun
    }

    /// `startYear`에서 시작하는 창 한 번의 구간. 규칙 창은 그해 하루, 연말을 넘는 창은 다음 해에 끝난다.
    public func interval(of window: SeasonPackManifest.Window, startYear: Int) -> DateInterval? {
        if let year = window.year, year != startYear { return nil }
        let startDay: Date
        let endDay: Date
        if let rule = window.rule {
            guard rule.kind == "nthWeekday", let day = nthWeekday(rule, year: startYear) else { return nil }
            startDay = day; endDay = day
        } else {
            guard let from = window.from, let to = window.to else { return nil }
            let endYear = to < from ? startYear + 1 : startYear
            guard let start = calendar.date(from: DateComponents(year: startYear, month: from.month, day: from.day)),
                  let end = calendar.date(from: DateComponents(year: endYear, month: to.month, day: to.day)),
                  calendar.component(.month, from: start) == from.month, calendar.component(.month, from: end) == to.month
            else { return nil }
            startDay = start; endDay = end
        }
        let start = resolve(window.fromTime, on: startDay, isEnd: false) ?? startDay
        let nextDay = calendar.date(byAdding: .day, value: 1, to: endDay) ?? endDay
        let end = resolve(window.toTime, on: endDay, isEnd: true) ?? nextDay
        guard end > start else { return nil }
        return DateInterval(start: start, end: end)
    }

    public func isActive(_ window: SeasonPackManifest.Window, at date: Date) -> Bool {
        let year = calendar.component(.year, from: date)
        for startYear in [year - 1, year] {
            if let span = interval(of: window, startYear: startYear), span.start <= date, date < span.end { return true }
        }
        return false
    }

    public func isActive(_ manifest: SeasonPackManifest, at date: Date) -> Bool {
        manifest.event.windows.contains { isActive($0, at: date) }
    }

    /// 지금 켜질 팩 하나. 겹치면 `priority`가 높은 쪽, 같으면 `version`이 큰 쪽, 그래도 같으면 id 순.
    public func activePack(in packs: [SeasonPackManifest], at date: Date) -> SeasonPackManifest? {
        packs.filter { isActive($0, at: date) }.max { a, b in
            if (a.priority ?? 0) != (b.priority ?? 0) { return (a.priority ?? 0) < (b.priority ?? 0) }
            if a.version != b.version { return a.version < b.version }
            return a.id > b.id
        }
    }

    /// `HH:mm`·`sunset`·`sunrise`을 그날의 시각으로 푼다. 끝 시각의 `HH:mm`은 그 분의 끝(+60초)이다. 풀지 못하면 nil(조건 없음으로 본다).
    func resolve(_ spec: String?, on day: Date, isEnd: Bool) -> Date? {
        guard let spec else { return nil }
        switch spec {
        case "sunset": return sun(day).sunset
        case "sunrise": return sun(day).sunrise
        default:
            guard let hm = SeasonPackDateParsing.hourMinute(spec),
                  let date = calendar.date(bySettingHour: hm.hour, minute: hm.minute, second: 0, of: day) else { return nil }
            return isEnd ? date.addingTimeInterval(60) : date
        }
    }

    func nthWeekday(_ rule: SeasonPackManifest.Window.Rule, year: Int) -> Date? {
        guard let month = rule.month, let weekday = rule.weekday, let nth = rule.nth, (1...7).contains(weekday),
              let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let days = calendar.range(of: .day, in: .month, for: first)?.count else { return nil }
        let firstWeekday = calendar.component(.weekday, from: first)
        let firstHit = 1 + (weekday - firstWeekday + 7) % 7
        let day: Int
        if nth > 0 {
            day = firstHit + 7 * (nth - 1)
        } else {
            day = firstHit + 7 * ((days - firstHit) / 7)
        }
        guard (1...days).contains(day) else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }
}
