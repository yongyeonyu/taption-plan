import Foundation
import CryptoKit
import TaptionPlanEngine

enum ReviewReportArchiveEngine {
    static func refreshed(
        snapshot: TaptionDataSnapshot,
        asOf: Date = .now,
        calendar: Calendar = .autoupdatingCurrent,
        cancellationCheck: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> [YearlyReviewArchive] {
        try cancellationCheck()
        let today = calendar.startOfDay(for: asOf)
        var sources = try sourcesByDay(
            snapshot: snapshot,
            asOf: asOf,
            calendar: calendar,
            cancellationCheck: cancellationCheck
        )
        sources[today, default: .empty].categories = snapshot.categories

        let existingDays = Dictionary(
            snapshot.yearlyReports
                .flatMap(\.days)
                .map { ($0.span.start, $0) },
            uniquingKeysWith: { _, last in last }
        )
        let dayStarts = Set(sources.keys).union(existingDays.keys).filter {
            $0 <= today
        }
        let review = ReviewEngine(calendar: calendar)
        let days = try dayStarts.sorted().compactMap { dayStart -> DailyReviewArchive? in
            try cancellationCheck()
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            else { return nil }
            let span = TimeSpan(start: dayStart, end: dayEnd)
            let effectiveEnd = min(dayEnd, asOf)
            guard effectiveEnd > dayStart else { return nil }
            var source = sources[dayStart, default: .empty]
            source.categories = snapshot.categories
            source.frequentPlaces = snapshot.settings.frequentPlaces
            source.sort()
            let fingerprint = try fingerprint(source, effectiveEnd: effectiveEnd)
            if let existing = existingDays[dayStart],
               existing.sourceFingerprint == fingerprint {
                return existing
            }
            if let existing = existingDays[dayStart],
               dayStart < today,
               source.isEmpty {
                return existing
            }

            let visibleActuals = ReviewCoverageEngine.records(
                actuals: RestSleepDisplayEngine.visibleActuals(
                    MovementDisplayEngine.reviewActuals(
                        source.actuals,
                        travel: source.travel,
                        calendarEvents: source.calendarEvents,
                        asOf: effectiveEnd
                    ),
                    asOf: effectiveEnd
                ),
                in: [span],
                asOf: effectiveEnd
            )
            let phaseActuals = DayPhaseEvidenceEngine.records(
                from: source.actuals,
                intersecting: span,
                asOf: effectiveEnd
            )
            let report = review.report(
                over: [span],
                plans: source.plans,
                actuals: visibleActuals,
                weather: source.weather,
                photos: source.photos,
                memos: source.memos,
                asOf: effectiveEnd,
                scope: .canonical
            )
            let dayPhases = DayPhaseEngine.categoryDurations(
                DayPhaseEngine.completePhases(
                    actuals: phaseActuals,
                    travel: source.travel,
                    stays: source.places,
                    placeKinds: FrequentPlaceResolutionEngine()
                        .kindsByPlaceKey(source.frequentPlaces),
                    in: span,
                    asOf: effectiveEnd
                ),
                scope: .canonical
            )
            return DailyReviewArchive(
                id: dayID(dayStart, calendar: calendar),
                span: span,
                report: report,
                dayPhases: dayPhases,
                groups: ActualRecordGroupingEngine.groups(
                    actuals: visibleActuals,
                    in: span,
                    categories: source.categories,
                    asOf: effectiveEnd,
                    scope: .canonical
                ),
                sourceFingerprint: fingerprint,
                updatedAt: asOf
            )
        }

        try cancellationCheck()
        let daysByYear = Dictionary(grouping: days) {
            calendar.dateInterval(of: .year, for: $0.span.start)?.start
                ?? $0.span.start
        }
        var archives: [YearlyReviewArchive] = []
        for start in daysByYear.keys.sorted() {
            try cancellationCheck()
            guard let interval = calendar.dateInterval(of: .year, for: start)
            else { continue }
            let span = TimeSpan(start: interval.start, end: interval.end)
            archives.append(ReviewArchiveHierarchy.year(
                span: span,
                days: daysByYear[start] ?? [],
                asOf: asOf,
                calendar: calendar
            ))
        }
        return archives
    }

    private static func sourcesByDay(
        snapshot: TaptionDataSnapshot,
        asOf: Date,
        calendar: Calendar,
        cancellationCheck: () throws -> Void
    ) throws -> [Date: DailyReviewSource] {
        var result: [Date: DailyReviewSource] = [:]
        for plan in snapshot.plans {
            try cancellationCheck()
            try distribute(
                plan.span,
                asOf: asOf,
                calendar: calendar,
                cancellationCheck: cancellationCheck
            ) { day, span in
                var value = plan
                value.span = span
                result[day, default: .empty].plans.append(value)
            }
        }
        for actual in snapshot.actuals {
            try cancellationCheck()
            try distribute(
                actual.span(asOf: asOf),
                asOf: asOf,
                calendar: calendar,
                cancellationCheck: cancellationCheck
            ) {
                day, span in
                var value = actual
                value.startedAt = span.start
                value.endedAt = span.end
                result[day, default: .empty].actuals.append(value)
            }
        }
        for event in snapshot.calendarEvents {
            try cancellationCheck()
            try distribute(
                event.span,
                asOf: asOf,
                calendar: calendar,
                cancellationCheck: cancellationCheck
            ) { day, span in
                var value = event
                value.span = span
                result[day, default: .empty].calendarEvents.append(value)
            }
        }
        for place in snapshot.places {
            try cancellationCheck()
            try distribute(
                place.span,
                asOf: asOf,
                calendar: calendar,
                cancellationCheck: cancellationCheck
            ) { day, span in
                var value = place
                value.span = span
                result[day, default: .empty].places.append(value)
            }
        }
        for travel in snapshot.travel {
            try cancellationCheck()
            try distribute(
                travel.span,
                asOf: asOf,
                calendar: calendar,
                cancellationCheck: cancellationCheck
            ) { day, span in
                var value = travel
                value.span = span
                result[day, default: .empty].travel.append(value)
            }
        }
        for memo in snapshot.memos where memo.occurredAt <= asOf {
            try cancellationCheck()
            result[calendar.startOfDay(for: memo.occurredAt), default: .empty]
                .memos.append(memo)
        }
        for weather in snapshot.weather where weather.observedAt <= asOf {
            try cancellationCheck()
            result[calendar.startOfDay(for: weather.observedAt), default: .empty]
                .weather.append(weather)
        }
        for photo in snapshot.photos where photo.capturedAt <= asOf {
            try cancellationCheck()
            result[calendar.startOfDay(for: photo.capturedAt), default: .empty]
                .photos.append(photo)
        }
        return result
    }

    private static func distribute(
        _ source: TimeSpan,
        asOf: Date,
        calendar: Calendar,
        cancellationCheck: () throws -> Void,
        body: (Date, TimeSpan) -> Void
    ) throws {
        let end = min(source.end, asOf)
        guard end > source.start else { return }
        var day = calendar.startOfDay(for: source.start)
        while day < end {
            try cancellationCheck()
            guard let next = calendar.date(byAdding: .day, value: 1, to: day)
            else { break }
            if let clipped = TimeSpan(start: source.start, end: end)
                .intersection(with: TimeSpan(start: day, end: next)) {
                body(day, clipped)
            }
            day = next
        }
    }

    private static func fingerprint(
        _ source: DailyReviewSource,
        effectiveEnd: Date
    ) throws -> String {
        let minute = Date(
            timeIntervalSince1970: floor(effectiveEnd.timeIntervalSince1970 / 60) * 60
        )
        let payload = DailyReviewFingerprint(source: source, effectiveEnd: minute)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(payload)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func dayID(_ date: Date, calendar: Calendar) -> String {
        let value = calendar.dateComponents([.year, .month, .day], from: date)
        return "day-\(value.year ?? 0)-\(value.month ?? 0)-\(value.day ?? 0)"
    }
}

private struct DailyReviewFingerprint: Codable {
    var source: DailyReviewSource
    var effectiveEnd: Date
}

private struct DailyReviewSource: Codable {
    var plans: [PlanRecord] = []
    var actuals: [ActualRecord] = []
    var memos: [ActionMemo] = []
    var categories: [CategoryDefinition] = []
    var frequentPlaces: [FrequentPlace] = []
    var photos: [PhotoMoment] = []
    var calendarEvents: [CalendarRecord] = []
    var weather: [WeatherContext] = []
    var places: [PlaceStay] = []
    var travel: [TravelSegment] = []

    static let empty = DailyReviewSource()

    var isEmpty: Bool {
        plans.isEmpty && actuals.isEmpty && memos.isEmpty && photos.isEmpty
            && calendarEvents.isEmpty && weather.isEmpty && places.isEmpty
            && travel.isEmpty
    }

    mutating func sort() {
        plans.sort { $0.id.uuidString < $1.id.uuidString }
        actuals.sort { $0.id.uuidString < $1.id.uuidString }
        memos.sort { $0.id.uuidString < $1.id.uuidString }
        categories.sort { $0.id < $1.id }
        frequentPlaces.sort { $0.id.uuidString < $1.id.uuidString }
        photos.sort { $0.id < $1.id }
        calendarEvents.sort { $0.id < $1.id }
        weather.sort { $0.id.uuidString < $1.id.uuidString }
        places.sort { $0.id.uuidString < $1.id.uuidString }
        travel.sort { $0.id.uuidString < $1.id.uuidString }
    }
}
