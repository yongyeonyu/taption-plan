import Foundation
import TaptionPlanCore

public struct CategoryDuration: Identifiable, Codable, Hashable, Sendable {
    public var id: String { categoryID }
    public var categoryID: String
    public var planned: TimeInterval
    public var actual: TimeInterval

    public init(
        categoryID: String,
        planned: TimeInterval,
        actual: TimeInterval
    ) {
        self.categoryID = categoryID
        self.planned = planned
        self.actual = actual
    }
}

public struct SummaryBucket: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var span: TimeSpan
    public var categories: [CategoryDuration]
    public var photoCount: Int
    public var representativePhotoID: String?

    public var plannedDuration: TimeInterval {
        categories.reduce(0) { $0 + $1.planned }
    }

    public var actualDuration: TimeInterval {
        categories.reduce(0) { $0 + $1.actual }
    }

    public init(
        id: String,
        span: TimeSpan,
        categories: [CategoryDuration],
        photoCount: Int,
        representativePhotoID: String? = nil
    ) {
        self.id = id
        self.span = span
        self.categories = categories
        self.photoCount = photoCount
        self.representativePhotoID = representativePhotoID
    }
}

public struct GoalRollup: Codable, Hashable, Sendable {
    public var goalID: UUID
    public var descendantCount: Int
    public var plannedDuration: TimeInterval
    public var actualDuration: TimeInterval
    public var categories: [CategoryDuration]

    public init(
        goalID: UUID,
        descendantCount: Int,
        plannedDuration: TimeInterval,
        actualDuration: TimeInterval,
        categories: [CategoryDuration]
    ) {
        self.goalID = goalID
        self.descendantCount = descendantCount
        self.plannedDuration = plannedDuration
        self.actualDuration = actualDuration
        self.categories = categories
    }
}

public struct ReviewContext: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var date: Date
    public var symbolName: String
    public var text: String
    public var linkedPlanID: UUID?

    public init(
        id: String,
        date: Date,
        symbolName: String,
        text: String,
        linkedPlanID: UUID? = nil
    ) {
        self.id = id
        self.date = date
        self.symbolName = symbolName
        self.text = text
        self.linkedPlanID = linkedPlanID
    }
}

public struct ReviewReport: Codable, Hashable, Sendable {
    public var span: TimeSpan
    public var plannedDuration: TimeInterval
    public var actualDuration: TimeInterval
    public var categories: [CategoryDuration]
    public var unplannedActualDuration: TimeInterval
    public var contexts: [ReviewContext]

    public init(
        span: TimeSpan,
        plannedDuration: TimeInterval,
        actualDuration: TimeInterval,
        categories: [CategoryDuration],
        unplannedActualDuration: TimeInterval,
        contexts: [ReviewContext]
    ) {
        self.span = span
        self.plannedDuration = plannedDuration
        self.actualDuration = actualDuration
        self.categories = categories
        self.unplannedActualDuration = unplannedActualDuration
        self.contexts = contexts
    }
}

public struct RecordGroupChild: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let duration: TimeInterval
    public let start: Date
    public let recordID: UUID
    public let occurrenceCount: Int

    public init(
        id: String,
        title: String,
        duration: TimeInterval,
        start: Date,
        recordID: UUID,
        occurrenceCount: Int
    ) {
        self.id = id
        self.title = title
        self.duration = duration
        self.start = start
        self.recordID = recordID
        self.occurrenceCount = occurrenceCount
    }
}

public struct RecordCategoryGroup: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let colorHex: String?
    public let icon: CategoryIcon?
    public let duration: TimeInterval
    public let dominantChildTitle: String?
    public let children: [RecordGroupChild]

    public init(
        id: String,
        name: String,
        colorHex: String? = nil,
        icon: CategoryIcon? = nil,
        duration: TimeInterval,
        dominantChildTitle: String? = nil,
        children: [RecordGroupChild]
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.icon = icon
        self.duration = duration
        self.dominantChildTitle = dominantChildTitle
        self.children = children
    }
}

public struct DailyReviewArchive: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var span: TimeSpan
    public var report: ReviewReport
    /// 일과는 일별 확정값만 저장한다. nil은 이 필드가 없던 이전 백업이다.
    public var dayPhases: [CategoryDuration]? = nil
    public var groups: [RecordCategoryGroup]
    public var sourceFingerprint: String
    public var updatedAt: Date

    public init(
        id: String,
        span: TimeSpan,
        report: ReviewReport,
        dayPhases: [CategoryDuration]? = nil,
        groups: [RecordCategoryGroup],
        sourceFingerprint: String,
        updatedAt: Date
    ) {
        self.id = id
        self.span = span
        self.report = report
        self.dayPhases = dayPhases
        self.groups = groups
        self.sourceFingerprint = sourceFingerprint
        self.updatedAt = updatedAt
    }
}

public struct ReviewPeriodArchive: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var span: TimeSpan
    public var report: ReviewReport
    public var dayPhases: [CategoryDuration]? = nil
    public var dayIDs: [String]
    public var isComplete: Bool
}

public struct MonthlyReviewArchive: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var span: TimeSpan
    public var report: ReviewReport
    public var dayPhases: [CategoryDuration]? = nil
    public var weeks: [ReviewPeriodArchive]
    public var dayIDs: [String]
    public var isComplete: Bool
}

public struct YearlyReviewArchive: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var span: TimeSpan
    public var report: ReviewReport
    public var dayPhases: [CategoryDuration]? = nil
    public var months: [MonthlyReviewArchive]
    public var days: [DailyReviewArchive]
    public var isComplete: Bool
    public var updatedAt: Date
}

public enum ReviewArchiveHierarchy {
    public static func year(
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

    public static func merging(
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
