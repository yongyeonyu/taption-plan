import Foundation

enum TaptionDeepLink: Equatable {
    case today
    case plan(UUID)
    case catPicker

    init?(url: URL) {
        guard url.scheme?.lowercased() == "taptionplan" else { return nil }
        switch url.host {
        case "today":
            self = .today
        case "plan":
            let components = url.pathComponents.filter { $0 != "/" }
            guard let rawID = components.first,
                  let id = UUID(uuidString: rawID) else {
                return nil
            }
            self = .plan(id)
        case "cats":
            self = .catPicker
        default:
            return nil
        }
    }
}

enum AddPlanContext: Equatable {
    case quick
    case goal
    case child(UUID)

    var isGoal: Bool {
        if case .goal = self { return true }
        return false
    }

    var parentID: UUID? {
        if case .child(let id) = self { return id }
        return nil
    }
}

enum AppDetail: Equatable {
    case group
    case goal
    case locationTimeline
    case memo
    case inference
    case catPicker
    case categoryManager
    case categorySetup
    case widgetPreview
}

struct QuickActionItem: Identifiable {
    let id = UUID()
    let planID: UUID?
    let title: String
    let time: String
    let context: String

    init(
        planID: UUID? = nil,
        title: String,
        time: String,
        context: String
    ) {
        self.planID = planID
        self.title = title
        self.time = time
        self.context = context
    }
}

struct PlanEditorRequest: Identifiable, Equatable {
    let id: UUID
}

enum ReviewScale: String, CaseIterable, Identifiable {
    case week = "주"
    case month = "월"
    case year = "년"

    var id: Self { self }
}

enum RootTab: String, CaseIterable, Identifiable {
    case schedule = "시간표"
    case goals = "루틴"
    case review = "기록"
    case settings = "설정"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .schedule: "chart.bar.xaxis"
        case .goals: "scope"
        case .review: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }
}

enum TimeScale: String, CaseIterable, Identifiable {
    case day = "일"
    case week = "주"
    case month = "월"
    case year = "년"

    var id: Self { self }

    var title: String {
        switch self {
        case .day: "오늘"
        case .week: "이번 주"
        case .month: "이번 달"
        case .year: "올해"
        }
    }

    var axisLabels: [String] {
        switch self {
        case .day: ["00", "12"]
        case .week: ["월", "화", "수", "목", "금", "토", "일"]
        case .month: (1...31).map(String.init)
        case .year: (1...12).map { "\($0)월" }
        }
    }

    var timelineLevel: TimelineLevel {
        switch self {
        case .day: .day
        case .week: .week
        case .month: .month
        case .year: .year
        }
    }

    var narrower: TimeScale? {
        switch self {
        case .year: .month
        case .month: .week
        case .week: .day
        case .day: nil
        }
    }

    var broader: TimeScale? {
        switch self {
        case .year: nil
        case .month: .year
        case .week: .month
        case .day: .week
        }
    }
}

/// The shared bucket grid for the four schedule resolutions.
///
/// The board uses the same `TimeSpan` and bucket dates as the axis, so a plan
/// beginning at a bucket boundary always lands on the corresponding column.
struct TimelineAxisBucket: Identifiable, Equatable, Sendable {
    let index: Int
    let count: Int
    let date: Date
    let label: String
    let holidayName: String?

    var id: String {
        "\(index)-\(date.timeIntervalSinceReferenceDate)"
    }
}

enum TimelineAxisGrid {
    static let weekdayLabels = ["월", "화", "수", "목", "금", "토", "일"]

    /// Returns a Korean, Monday-first calendar without changing the caller's
    /// calendar value.
    static func normalizedCalendar(
        _ calendar: Calendar = .autoupdatingCurrent
    ) -> Calendar {
        var value = calendar
        value.locale = Locale(identifier: "ko_KR")
        value.firstWeekday = 2 // Monday
        value.minimumDaysInFirstWeek = 4
        return value
    }

    static func span(
        for scale: TimeScale,
        containing date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> TimeSpan {
        let calendar = normalizedCalendar(calendar)
        let component: Calendar.Component = switch scale {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
        let interval = calendar.dateInterval(of: component, for: date)
            ?? DateInterval(start: date, duration: 86_400)
        return TimeSpan(start: interval.start, end: interval.end)
    }

    static func buckets(
        for scale: TimeScale,
        containing date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [TimelineAxisBucket] {
        let calendar = normalizedCalendar(calendar)
        let span = span(for: scale, containing: date, calendar: calendar)

        switch scale {
        case .day:
            return [
                bucket(
                    index: 0,
                    count: 2,
                    date: span.start,
                    label: "00",
                    holidayName: nil
                ),
                bucket(
                    index: 1,
                    count: 2,
                    date: calendar.date(
                        byAdding: .hour,
                        value: 12,
                        to: span.start
                    ) ?? span.start,
                    label: "12",
                    holidayName: nil
                ),
            ]
        case .week:
            return (0..<7).map { index in
                let date = calendar.date(
                    byAdding: .day,
                    value: index,
                    to: span.start
                ) ?? span.start
                return bucket(
                    index: index,
                    count: 7,
                    date: date,
                    label: weekdayLabels[index],
                    holidayName: koreanHolidayName(
                        on: date,
                        calendar: calendar
                    )
                )
            }
        case .month:
            let count = calendar.range(
                of: .day,
                in: .month,
                for: date
            )?.count ?? 30
            return (0..<count).map { index in
                let date = calendar.date(
                    byAdding: .day,
                    value: index,
                    to: span.start
                ) ?? span.start
                return bucket(
                    index: index,
                    count: count,
                    date: date,
                    label: "\(index + 1)",
                    holidayName: nil
                )
            }
        case .year:
            return (0..<12).map { index in
                let date = calendar.date(
                    byAdding: .month,
                    value: index,
                    to: span.start
                ) ?? span.start
                return bucket(
                    index: index,
                    count: 12,
                    date: date,
                    label: "\(index + 1)월",
                    holidayName: nil
                )
            }
        }
    }

    static func monthDayCount(
        for date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Int {
        normalizedCalendar(calendar).range(
            of: .day,
            in: .month,
            for: date
        )?.count ?? 30
    }

    /// Maps a date into an equal-width bucket grid. Day scale remains a
    /// continuous clock; week/month/year use one equal slot per calendar
    /// bucket even though their real durations differ.
    static func fraction(
        of date: Date,
        in span: TimeSpan,
        scale: TimeScale,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Double {
        guard span.duration > 0 else { return 0 }
        if date <= span.start { return 0 }
        if date >= span.end { return 1 }

        let calendar = normalizedCalendar(calendar)
        switch scale {
        case .day:
            return date.timeIntervalSince(span.start) / span.duration
        case .week, .month:
            let count = scale == .week
                ? 7
                : monthDayCount(for: span.start, calendar: calendar)
            let firstDay = calendar.startOfDay(for: span.start)
            let dayStart = calendar.startOfDay(for: date)
            let index = calendar.dateComponents(
                [.day],
                from: firstDay,
                to: dayStart
            ).day ?? 0
            let bucketStart = calendar.date(
                byAdding: .day,
                value: index,
                to: firstDay
            ) ?? firstDay
            let bucketEnd = calendar.date(
                byAdding: .day,
                value: 1,
                to: bucketStart
            ) ?? bucketStart.addingTimeInterval(86_400)
            let intra = min(
                1,
                max(
                    0,
                    date.timeIntervalSince(bucketStart)
                        / max(1, bucketEnd.timeIntervalSince(bucketStart))
                )
            )
            return (Double(index) + intra) / Double(count)
        case .year:
            let monthIndex = calendar.dateComponents(
                [.month],
                from: span.start,
                to: date
            ).month ?? 0
            let monthStart = calendar.date(
                byAdding: .month,
                value: monthIndex,
                to: span.start
            ) ?? span.start
            let monthEnd = calendar.date(
                byAdding: .month,
                value: 1,
                to: monthStart
            ) ?? monthStart.addingTimeInterval(31 * 86_400)
            let intra = min(
                1,
                max(
                    0,
                    date.timeIntervalSince(monthStart)
                        / max(1, monthEnd.timeIntervalSince(monthStart))
                )
            )
            return (Double(monthIndex) + intra) / 12
        }
    }

    static func date(
        at fraction: Double,
        in span: TimeSpan,
        scale: TimeScale,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        let value = min(1, max(0, fraction))
        guard span.duration > 0 else { return span.start }
        let calendar = normalizedCalendar(calendar)
        switch scale {
        case .day:
            return span.start.addingTimeInterval(span.duration * value)
        case .week, .month:
            let count = scale == .week
                ? 7
                : monthDayCount(for: span.start, calendar: calendar)
            let scaled = value * Double(count)
            let index = min(count - 1, max(0, Int(scaled.rounded(.down))))
            let intra = scaled - Double(index)
            let bucketStart = calendar.date(
                byAdding: .day,
                value: index,
                to: span.start
            ) ?? span.start
            let bucketEnd = calendar.date(
                byAdding: .day,
                value: 1,
                to: bucketStart
            ) ?? bucketStart.addingTimeInterval(86_400)
            return bucketStart.addingTimeInterval(
                bucketEnd.timeIntervalSince(bucketStart) * intra
            )
        case .year:
            let scaled = value * 12
            let index = min(11, max(0, Int(scaled.rounded(.down))))
            let intra = scaled - Double(index)
            let monthStart = calendar.date(
                byAdding: .month,
                value: index,
                to: span.start
            ) ?? span.start
            let monthEnd = calendar.date(
                byAdding: .month,
                value: 1,
                to: monthStart
            ) ?? monthStart.addingTimeInterval(31 * 86_400)
            return monthStart.addingTimeInterval(
                monthEnd.timeIntervalSince(monthStart) * intra
            )
        }
    }

    static func koreanHolidayName(
        on date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String? {
        let calendar = normalizedCalendar(calendar)
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day else {
            return nil
        }

        return holidayDates[year]?.first {
            $0.month == month && $0.day == day
        }?.name
    }

    private static func bucket(
        index: Int,
        count: Int,
        date: Date,
        label: String,
        holidayName: String?
    ) -> TimelineAxisBucket {
        TimelineAxisBucket(
            index: index,
            count: count,
            date: date,
            label: label,
            holidayName: holidayName
        )
    }

    private struct HolidayDate: Sendable {
        let month: Int
        let day: Int
        let name: String
    }

    // Public holiday dates through 2030. Lunar holiday dates and observed
    // substitute days are kept explicit so the timeline remains deterministic
    // and works offline.
    private static let holidayDates: [Int: [HolidayDate]] = [
        2026: [
            .init(month: 1, day: 1, name: "신정"),
            .init(month: 2, day: 16, name: "설날 연휴"),
            .init(month: 2, day: 17, name: "설날"),
            .init(month: 2, day: 18, name: "설날 연휴"),
            .init(month: 3, day: 1, name: "삼일절"),
            .init(month: 3, day: 2, name: "삼일절 대체"),
            .init(month: 5, day: 1, name: "근로자의 날"),
            .init(month: 5, day: 5, name: "어린이날"),
            .init(month: 5, day: 24, name: "부처님오신날"),
            .init(month: 5, day: 25, name: "부처님오신날 대체"),
            .init(month: 6, day: 6, name: "현충일"),
            .init(month: 8, day: 15, name: "광복절"),
            .init(month: 8, day: 17, name: "광복절 대체"),
            .init(month: 9, day: 24, name: "추석 연휴"),
            .init(month: 9, day: 25, name: "추석"),
            .init(month: 9, day: 26, name: "추석 연휴"),
            .init(month: 10, day: 3, name: "개천절"),
            .init(month: 10, day: 5, name: "개천절 대체"),
            .init(month: 10, day: 9, name: "한글날"),
            .init(month: 12, day: 25, name: "성탄절"),
        ],
        2027: [
            .init(month: 1, day: 1, name: "신정"),
            .init(month: 2, day: 6, name: "설날 연휴"),
            .init(month: 2, day: 7, name: "설날"),
            .init(month: 2, day: 8, name: "설날 연휴"),
            .init(month: 2, day: 9, name: "설날 대체"),
            .init(month: 3, day: 1, name: "삼일절"),
            .init(month: 5, day: 1, name: "근로자의 날"),
            .init(month: 5, day: 5, name: "어린이날"),
            .init(month: 5, day: 13, name: "부처님오신날"),
            .init(month: 6, day: 6, name: "현충일"),
            .init(month: 8, day: 15, name: "광복절"),
            .init(month: 8, day: 16, name: "광복절 대체"),
            .init(month: 9, day: 14, name: "추석 연휴"),
            .init(month: 9, day: 15, name: "추석"),
            .init(month: 9, day: 16, name: "추석 연휴"),
            .init(month: 10, day: 3, name: "개천절"),
            .init(month: 10, day: 4, name: "개천절 대체"),
            .init(month: 10, day: 9, name: "한글날"),
            .init(month: 10, day: 11, name: "한글날 대체"),
            .init(month: 12, day: 25, name: "성탄절"),
        ],
        2028: [
            .init(month: 1, day: 1, name: "신정"),
            .init(month: 1, day: 26, name: "설날 연휴"),
            .init(month: 1, day: 27, name: "설날"),
            .init(month: 1, day: 28, name: "설날 연휴"),
            .init(month: 3, day: 1, name: "삼일절"),
            .init(month: 5, day: 1, name: "근로자의 날"),
            .init(month: 5, day: 2, name: "부처님오신날"),
            .init(month: 5, day: 5, name: "어린이날"),
            .init(month: 6, day: 6, name: "현충일"),
            .init(month: 8, day: 15, name: "광복절"),
            .init(month: 10, day: 2, name: "추석 연휴"),
            .init(month: 10, day: 3, name: "추석·개천절"),
            .init(month: 10, day: 4, name: "추석 연휴"),
            .init(month: 10, day: 5, name: "추석 대체"),
            .init(month: 10, day: 9, name: "한글날"),
            .init(month: 12, day: 25, name: "성탄절"),
        ],
        2029: [
            .init(month: 1, day: 1, name: "신정"),
            .init(month: 2, day: 12, name: "설날 연휴"),
            .init(month: 2, day: 13, name: "설날"),
            .init(month: 2, day: 14, name: "설날 연휴"),
            .init(month: 3, day: 1, name: "삼일절"),
            .init(month: 5, day: 1, name: "근로자의 날"),
            .init(month: 5, day: 5, name: "어린이날"),
            .init(month: 5, day: 7, name: "어린이날 대체"),
            .init(month: 5, day: 20, name: "부처님오신날"),
            .init(month: 5, day: 21, name: "부처님오신날 대체"),
            .init(month: 6, day: 6, name: "현충일"),
            .init(month: 8, day: 15, name: "광복절"),
            .init(month: 9, day: 21, name: "추석 연휴"),
            .init(month: 9, day: 22, name: "추석"),
            .init(month: 9, day: 23, name: "추석 연휴"),
            .init(month: 9, day: 24, name: "추석 대체"),
            .init(month: 10, day: 3, name: "개천절"),
            .init(month: 10, day: 9, name: "한글날"),
            .init(month: 12, day: 25, name: "성탄절"),
        ],
        2030: [
            .init(month: 1, day: 1, name: "신정"),
            .init(month: 2, day: 2, name: "설날 연휴"),
            .init(month: 2, day: 3, name: "설날"),
            .init(month: 2, day: 4, name: "설날 연휴"),
            .init(month: 3, day: 1, name: "삼일절"),
            .init(month: 5, day: 1, name: "근로자의 날"),
            .init(month: 5, day: 5, name: "어린이날"),
            .init(month: 5, day: 6, name: "어린이날 대체"),
            .init(month: 5, day: 9, name: "부처님오신날"),
            .init(month: 6, day: 6, name: "현충일"),
            .init(month: 8, day: 15, name: "광복절"),
            .init(month: 9, day: 11, name: "추석 연휴"),
            .init(month: 9, day: 12, name: "추석"),
            .init(month: 9, day: 13, name: "추석 연휴"),
            .init(month: 10, day: 3, name: "개천절"),
            .init(month: 10, day: 9, name: "한글날"),
            .init(month: 12, day: 25, name: "성탄절"),
        ],
    ]
}

struct ScheduleHeaderFormatter {
    var calendar: Calendar

    init(calendar: Calendar = .autoupdatingCurrent) {
        self.calendar = calendar
    }

    func title(for date: Date, scale: TimeScale) -> String {
        switch scale {
        case .day:
            return format(date, pattern: "M월 d일 (E)")
        case .week:
            let span = TimelineAxisGrid.span(
                for: .week,
                containing: date,
                calendar: calendar
            )
            return "\(format(span.start, pattern: "M월 d일")) – \(format(span.end.addingTimeInterval(-1), pattern: "M월 d일"))"
        case .month:
            return format(date, pattern: "yyyy년 M월")
        case .year:
            return format(date, pattern: "yyyy년")
        }
    }

    /// The title shown while the playhead is the primary navigation anchor.
    /// The period remains visible in the scale picker/trailing metadata, so
    /// this stays focused on the exact date under the playhead at every scale.
    func playheadTitle(for date: Date, scale: TimeScale) -> String {
        switch scale {
        case .day:
            return title(for: date, scale: scale)
        case .week, .month, .year:
            return format(date, pattern: "M월 d일 (E)")
        }
    }

    private func format(_ date: Date, pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
