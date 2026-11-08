import Foundation
import TaptionPlanEngine

/// 기록 화면에서 손가락으로 켜고 끄는 한 칸.
struct ReviewPeriodBucket: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let span: TimeSpan
}

/// 기록 화면이 읽을 구간을 정한다. 고른 칸이 없으면 기간 전체 하나이고,
/// 고른 칸이 있으면 그 칸들의 합집합이다. 합계·눈금판·목록이 모두 이 한
/// 값을 읽어야 서로 다른 숫자를 말하지 않는다.
enum ReviewSelectionEngine {
    /// 배율마다 고를 수 있는 칸의 크기. 하루는 나누지 않는다 — 하루는 늘
    /// 통째로 본다.
    static func bucketLevel(for level: TimelineLevel) -> TimelineLevel? {
        switch level {
        case .day: nil
        case .week: .day
        case .month: .week
        case .year: .month
        }
    }

    static func buckets(
        for level: TimelineLevel,
        in period: TimeSpan,
        calendar: Calendar
    ) -> [ReviewPeriodBucket] {
        guard let bucketLevel = bucketLevel(for: level) else { return [] }
        let component = component(for: bucketLevel)
        var result: [ReviewPeriodBucket] = []
        var cursor = period.start

        while cursor < period.end {
            guard let interval = calendar.dateInterval(
                of: component,
                for: cursor
            ) else {
                break
            }
            let span = TimeSpan(
                start: max(interval.start, period.start),
                end: min(interval.end, period.end)
            )
            if span.duration > 0 {
                result.append(
                    ReviewPeriodBucket(
                        id: identifier(of: span.start, calendar: calendar),
                        label: label(
                            of: span,
                            level: bucketLevel,
                            index: result.count,
                            calendar: calendar
                        ),
                        span: span
                    )
                )
            }
            guard interval.end > cursor else { break }
            cursor = interval.end.addingTimeInterval(0.001)
        }
        return result
    }

    /// 고른 칸이 없거나 지금 기간에 없는 칸만 남았으면 기간 전체로 돌아간다.
    /// 화면이 아무것도 가리키지 않는 상태에 빠지지 않게 하는 마지막 방어다.
    static func spans(
        period: TimeSpan,
        buckets: [ReviewPeriodBucket],
        selectedIDs: Set<String>
    ) -> [TimeSpan] {
        let chosen = buckets
            .filter { selectedIDs.contains($0.id) }
            .map(\.span)
        guard !chosen.isEmpty else { return [period] }
        return ActualIntervalMergeEngine.union(chosen, mergeGap: 0)
    }

    static func chartSpan(
        _ selectedID: String?,
        buckets: [RecordChartBucket]
    ) -> TimeSpan? {
        guard let selectedID else { return nil }
        return buckets.first { $0.id == selectedID }?.span
    }

    private static func component(
        for level: TimelineLevel
    ) -> Calendar.Component {
        switch level {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
    }

    /// 칸 ID. 차트 막대도 같은 표기를 써야 고른 칸과 막대가 맞물린다.
    static func identifier(
        of start: Date,
        calendar: Calendar
    ) -> String {
        ISO8601DateFormatter.string(
            from: start,
            timeZone: calendar.timeZone,
            formatOptions: [.withInternetDateTime]
        )
    }

    private static let weekdayNames = ["일", "월", "화", "수", "목", "금", "토"]

    private static func label(
        of span: TimeSpan,
        level: TimelineLevel,
        index: Int,
        calendar: Calendar
    ) -> String {
        switch level {
        case .day:
            let weekday = calendar.component(.weekday, from: span.start)
            return weekdayNames[max(1, min(7, weekday)) - 1]
        case .week:
            return "\(index + 1)주"
        case .month:
            return "\(calendar.component(.month, from: span.start))월"
        case .year:
            return "\(calendar.component(.year, from: span.start))년"
        }
    }
}
