import Foundation
import TaptionPlanEngine
import TaptionPlanStore

/// 공유로 받은 글(카카오톡 메시지 등)에서 일정 하나를 기기 안에서 읽는다(FLT1119A01 확장).
/// 날짜(4형식 + 오늘·내일·모레·글피 + 「다음 주 금요일」)와 시각(「오후 3시」「14:30」「9-11」)을 모두 읽을 수 있을 때만 값이 나온다.
/// 하나라도 모호하면 nil이고, 호출한 쪽이 연결된 AI에게 맡기거나 메모로 남긴다. 글을 밖으로 보내지 않는다.
enum ShareScheduleParser {
    struct Draft: Equatable {
        /// 날짜·시각 말을 뺀 이름. 비면 호출한 쪽이 기본 이름을 쓴다.
        var title: String
        var start: Date
        var durationMinutes: Int
        var kind: String?
    }

    static let maximumCharacters = 2_000
    static let maximumTitle = 40
    /// 이만큼보다 더 지난 날짜는 이미 지난 일이라 일정으로 만들지 않는다.
    static let pastTolerance: TimeInterval = 86_400

    static func parse(_ raw: String, now: Date, calendar: Calendar = .autoupdatingCurrent) -> Draft? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maximumCharacters else { return nil }
        let normalized = FlightAlertText.normalize(text).text
        guard let (day, remainder) = date(in: normalized, now: now, calendar: calendar) else { return nil }
        let parsed = TravelQuickEntry.parse(remainder)
        guard let minute = parsed.startMinute, (0..<1_440).contains(minute), let start = calendar.date(byAdding: .minute, value: minute, to: day),
              start >= now.addingTimeInterval(-pastTolerance) else { return nil }
        let duration = min(max(parsed.durationMinutes ?? TravelQuickEntry.defaultDuration(kind: parsed.kind ?? "other"), 5), 1_440)
        return Draft(title: title(parsed.title), start: start, durationMinutes: duration, kind: parsed.kind)
    }

    // MARK: 날짜

    private static let weekdays = ["일": 1, "월": 2, "화": 3, "수": 4, "목": 5, "금": 6, "토": 7]

    /// 글에서 날짜 하나(맨 앞에 나온 것)를 찾아 그날 0시와 날짜 말을 뺀 글을 돌려준다.
    static func date(in text: String, now: Date, calendar: Calendar) -> (day: Date, remainder: String)? {
        let source = text as NSString
        var found: (range: NSRange, day: Date)?
        func consider(_ pattern: String, options: NSRegularExpression.Options = [], _ resolve: (NSTextCheckingResult) -> Date?) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
                  let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: source.length)), let day = resolve(match) else { return }
            if found == nil || match.range.location < found!.range.location { found = (match.range, day) }
        }
        func number(_ match: NSTextCheckingResult, _ group: Int) -> Int? {
            let range = match.range(at: group)
            return range.location == NSNotFound ? nil : Int(source.substring(with: range))
        }
        func dayOf(month: Int, dayOfMonth: Int, year: Int?) -> Date? {
            let resolved = FlightAlertDate(year: year, month: month, day: dayOfMonth).resolved(reference: now, calendar: calendar)
            return resolved.flatMap { calendar.date(from: DateComponents(year: $0.year, month: $0.month, day: $0.day)) }
        }
        let today = calendar.startOfDay(for: now)
        consider(#"(?<!\d)(20\d{2})\s?[-./]\s?(\d{1,2})\s?[-./]\s?(\d{1,2})(?!\d)"#) { m in
            guard let y = number(m, 1), let mo = number(m, 2), let d = number(m, 3) else { return nil }
            return dayOf(month: mo, dayOfMonth: d, year: y)
        }
        consider(#"(?<!\d)(\d{1,2})\s?월\s?(\d{1,2})\s?일"#) { m in
            guard let mo = number(m, 1), let d = number(m, 2) else { return nil }
            return dayOf(month: mo, dayOfMonth: d, year: nil)
        }
        consider(#"(?<![\d/.])(\d{1,2})/(\d{1,2})(?![\d/])"#) { m in
            guard let mo = number(m, 1), let d = number(m, 2), (1...12).contains(mo) else { return nil }
            return dayOf(month: mo, dayOfMonth: d, year: nil)
        }
        for (word, offset) in [("글피", 3), ("모레", 2), ("내일", 1), ("오늘", 0)] {
            consider(NSRegularExpression.escapedPattern(for: word)) { _ in calendar.date(byAdding: .day, value: offset, to: today) }
        }
        consider(#"(다음\s?주|담주|이번\s?주)?\s?([월화수목금토일])요일"#) { m in
            let range = m.range(at: 1)
            let prefix = range.location == NSNotFound ? "" : source.substring(with: range).replacingOccurrences(of: " ", with: "")
            guard let target = weekdays[source.substring(with: m.range(at: 2))] else { return nil }
            let current = calendar.component(.weekday, from: today)
            var delta = (target - current + 7) % 7
            if prefix.hasPrefix("다음") || prefix == "담주" {
                // 다음 주의 그 요일: 이번 주(일요일 시작)의 끝을 넘긴다.
                delta = (7 - (current - 1)) + (target - 1)
            }
            return calendar.date(byAdding: .day, value: delta, to: today)
        }
        guard let found else { return nil }
        let remainder = source.replacingCharacters(in: found.range, with: " ")
        return (found.day, remainder)
    }

    // MARK: 이름

    /// 이름: 줄바꿈·여러 칸 공백을 하나로, 앞뒤 기호를 떼고 40자까지.
    static func title(_ raw: String) -> String {
        let flat = raw.replacingOccurrences(of: "\n", with: " ").split(whereSeparator: { $0 == " " }).joined(separator: " ")
        let trimmed = flat.trimmingCharacters(in: CharacterSet(charactersIn: " ,.·:;-~/|()[]{}<>\"'!?"))
        return String(trimmed.prefix(maximumTitle))
    }
}
