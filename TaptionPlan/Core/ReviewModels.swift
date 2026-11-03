import Foundation
import TaptionPlanCore

struct CategoryDuration: Identifiable, Codable, Hashable, Sendable {
    var id: String { categoryID }
    var categoryID: String
    var planned: TimeInterval
    var actual: TimeInterval
}

struct SummaryBucket: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var span: TimeSpan
    var categories: [CategoryDuration]
    var photoCount: Int
    var representativePhotoID: String?

    var plannedDuration: TimeInterval {
        categories.reduce(0) { $0 + $1.planned }
    }

    var actualDuration: TimeInterval {
        categories.reduce(0) { $0 + $1.actual }
    }
}

struct GoalRollup: Codable, Hashable, Sendable {
    var goalID: UUID
    var descendantCount: Int
    var plannedDuration: TimeInterval
    var actualDuration: TimeInterval
    var categories: [CategoryDuration]
}

struct ReviewContext: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var date: Date
    var symbolName: String
    var text: String
    var linkedPlanID: UUID?
}

struct ReviewReport: Codable, Hashable, Sendable {
    var span: TimeSpan
    var plannedDuration: TimeInterval
    var actualDuration: TimeInterval
    var categories: [CategoryDuration]
    var unplannedActualDuration: TimeInterval
    var contexts: [ReviewContext]
}

struct RecordGroupChild: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let duration: TimeInterval
    let start: Date
    let recordID: UUID
    let occurrenceCount: Int
}

struct RecordCategoryGroup: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let colorHex: String?
    let icon: CategoryIcon?
    let duration: TimeInterval
    let dominantChildTitle: String?
    let children: [RecordGroupChild]
}

struct DailyReviewArchive: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var span: TimeSpan
    var report: ReviewReport
    /// 일과는 일별 확정값만 저장한다. nil은 이 필드가 없던 이전 백업이다.
    var dayPhases: [CategoryDuration]? = nil
    var groups: [RecordCategoryGroup]
    var sourceFingerprint: String
    var updatedAt: Date
}

struct ReviewPeriodArchive: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var span: TimeSpan
    var report: ReviewReport
    var dayPhases: [CategoryDuration]? = nil
    var dayIDs: [String]
    var isComplete: Bool
}

struct MonthlyReviewArchive: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var span: TimeSpan
    var report: ReviewReport
    var dayPhases: [CategoryDuration]? = nil
    var weeks: [ReviewPeriodArchive]
    var dayIDs: [String]
    var isComplete: Bool
}

struct YearlyReviewArchive: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var span: TimeSpan
    var report: ReviewReport
    var dayPhases: [CategoryDuration]? = nil
    var months: [MonthlyReviewArchive]
    var days: [DailyReviewArchive]
    var isComplete: Bool
    var updatedAt: Date
}

enum ReviewArchiveHierarchy {
    static func year(
        span: TimeSpan,
        days: [DailyReviewArchive],
        asOf: Date,
        calendar: Calendar
    ) -> YearlyReviewArchive {
        let ordered = days.sorted { $0.span.start < $1.span.start }
        let months = Dictionary(grouping: ordered) {
            calendar.dateInterval(of: .month, for: $0.span.start)?.start
                ?? $0.span.start
        }.keys.sorted().compactMap { start -> MonthlyReviewArchive? in
            guard let interval = calendar.dateInterval(of: .month, for: start)
            else { return nil }
            let monthSpan = TimeSpan(
                start: max(span.start, interval.start),
                end: min(span.end, interval.end)
            )
            let monthDays = ordered.filter {
                monthSpan.contains($0.span.start)
            }
            return month(span: monthSpan, days: monthDays, asOf: asOf, calendar: calendar)
        }
        let complete = span.end <= asOf
        let latestDay = ordered.map(\.updatedAt).max() ?? .distantPast
        return YearlyReviewArchive(
            id: archiveID("year", span.start, calendar: calendar),
            span: span,
            report: aggregate(ordered, span: span),
            dayPhases: aggregateDayPhases(ordered),
            months: months,
            days: ordered,
            isComplete: complete,
            updatedAt: complete ? max(latestDay, span.end) : latestDay
        )
    }

    static func merging(
        _ lhs: YearlyReviewArchive,
        _ rhs: YearlyReviewArchive,
        asOf: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> YearlyReviewArchive {
        var byID = Dictionary(
            uniqueKeysWithValues: lhs.days.map { ($0.id, $0) }
        )
        for day in rhs.days where day.updatedAt > byID[day.id]?.updatedAt
            ?? .distantPast {
            byID[day.id] = day
        }
        let source = lhs.updatedAt >= rhs.updatedAt ? lhs : rhs
        return year(
            span: source.span,
            days: Array(byID.values),
            asOf: asOf,
            calendar: calendar
        )
    }

    private static func month(
        span: TimeSpan,
        days: [DailyReviewArchive],
        asOf: Date,
        calendar: Calendar
    ) -> MonthlyReviewArchive {
        let weeks = Dictionary(grouping: days) {
            calendar.dateInterval(of: .weekOfYear, for: $0.span.start)?.start
                ?? $0.span.start
        }.keys.sorted().compactMap { start -> ReviewPeriodArchive? in
            guard let interval = calendar.dateInterval(
                of: .weekOfYear,
                for: start
            ) else { return nil }
            let weekSpan = TimeSpan(
                start: max(span.start, interval.start),
                end: min(span.end, interval.end)
            )
            let weekDays = days.filter { weekSpan.contains($0.span.start) }
            return ReviewPeriodArchive(
                id: archiveID("week", weekSpan.start, calendar: calendar),
                span: weekSpan,
                report: aggregate(weekDays, span: weekSpan),
                dayPhases: aggregateDayPhases(weekDays),
                dayIDs: weekDays.map(\.id).sorted(),
                isComplete: weekSpan.end <= asOf
            )
        }
        return MonthlyReviewArchive(
            id: archiveID("month", span.start, calendar: calendar),
            span: span,
            report: aggregate(days, span: span),
            dayPhases: aggregateDayPhases(days),
            weeks: weeks,
            dayIDs: days.map(\.id).sorted(),
            isComplete: span.end <= asOf
        )
    }

    private static func aggregate(
        _ days: [DailyReviewArchive],
        span: TimeSpan
    ) -> ReviewReport {
        var planned: [String: TimeInterval] = [:]
        var actual: [String: TimeInterval] = [:]
        var contexts: [String: ReviewContext] = [:]
        var unplanned: TimeInterval = 0
        for day in days {
            unplanned += day.report.unplannedActualDuration
            for category in day.report.categories {
                planned[category.categoryID, default: 0] += category.planned
                actual[category.categoryID, default: 0] += category.actual
            }
            for context in day.report.contexts {
                contexts[context.id] = context
            }
        }
        let categories = Set(planned.keys).union(actual.keys).map {
            CategoryDuration(
                categoryID: $0,
                planned: planned[$0, default: 0],
                actual: actual[$0, default: 0]
            )
        }.sorted {
            max($0.actual, $0.planned) > max($1.actual, $1.planned)
        }
        return ReviewReport(
            span: span,
            plannedDuration: categories.reduce(0) { $0 + $1.planned },
            actualDuration: categories.reduce(0) { $0 + $1.actual },
            categories: categories,
            unplannedActualDuration: unplanned,
            contexts: contexts.values.sorted { $0.date < $1.date }
        )
    }

    private static func aggregateDayPhases(
        _ days: [DailyReviewArchive]
    ) -> [CategoryDuration] {
        var totals: [String: TimeInterval] = [:]
        for value in days.flatMap({ $0.dayPhases ?? [] }) {
            totals[value.categoryID, default: 0] += value.actual
        }
        return totals.map {
            CategoryDuration(categoryID: $0.key, planned: 0, actual: $0.value)
        }.sorted {
            $0.actual == $1.actual
                ? $0.categoryID < $1.categoryID
                : $0.actual > $1.actual
        }
    }

    private static func archiveID(
        _ prefix: String,
        _ date: Date,
        calendar: Calendar
    ) -> String {
        let value = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(prefix)-\(value.year ?? 0)-\(value.month ?? 0)-\(value.day ?? 0)"
    }
}
