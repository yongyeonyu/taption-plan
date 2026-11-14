import Foundation

/// 명령의 글·날짜·시각 칸을 읽는 순수 함수. 명령 읽기 본체는 앱의 `extension AssistantCommandParser`에 있다.
public enum AssistantCommandParser {
    public static func clean(_ value: String?, max: Int) -> String? {
        guard let value, value.count <= max else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 시각이 없으면 오늘은 지금, 다른 날은 정오에 놓는다.
    public static func memoInstant(date: String?, time: String?, now: Date, calendar: Calendar) -> Date? {
        var day = calendar.startOfDay(for: now)
        if let date {
            guard let parsed = self.day(date, calendar: calendar) else { return nil }
            day = parsed
        }
        guard let time else { return calendar.isDate(day, inSameDayAs: now) ? now : day.addingTimeInterval(12 * 3_600) }
        return clock(time, on: day, calendar: calendar)
    }

    public static func day(_ text: String, calendar: Calendar) -> Date? {
        guard let parts = numbers(text, separator: "-", count: 3), parts[0] >= 2_000,
              (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    public static func clock(_ text: String, on day: Date, calendar: Calendar) -> Date? {
        guard let parts = numbers(text, separator: ":", count: 2), (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        return calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day)
    }

    private static func numbers(_ text: String, separator: Character, count: Int) -> [Int]? {
        let parts = text.split(separator: separator, omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == count, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }
    }

    /// `2026-11-12T15:00+09:00`(초·Z도 받는다).
    public static func instant(_ text: String) -> Date? {
        for format in ["yyyy-MM-dd'T'HH:mmXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

extension AssistantCommandParser {
    /// `HH:mm` → 자정부터의 분.
    public static func minutes(_ text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 2, let hour = parts[0], let minute = parts[1], (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return hour * 60 + minute
    }
}
