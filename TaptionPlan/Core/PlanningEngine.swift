import Foundation
import TaptionPlanCore

/// High-frequency timeline gestures may arrive faster than the display can
/// present them. Keep the latest sample for the gesture end, but only publish
/// intermediate state at the display cadence.
typealias TimelineInteractionFrameGate = TaptionInputFrameGate

/// Keeps a timeline editor's latest gesture projection separate from the
/// presentation projection. Input can arrive at 240Hz; SwiftUI receives at
/// most the display-budgeted projections, plus the final gesture state.
final class TimelineNLEProjection<State: Equatable & Sendable> {
    private var projection = TaptionLatestValueProjection<State>()
    var latestState: State? { projection.latestValue }
    var renderedState: State? { projection.renderedValue }

    func begin(with state: State) { projection.begin(with: state) }
    func synchronize(with state: State) { projection.synchronize(with: state) }

    func submit(_ state: State, nowUptime: TimeInterval, force: Bool = false) -> State? {
        projection.submit(state, at: nowUptime, isFinal: force)
    }

    func finish(with state: State, nowUptime: TimeInterval) -> State? {
        projection.submit(state, at: nowUptime, isFinal: true)
    }

    func reset() { projection.reset() }
}

struct MapHomeTimeSidebarNLEState: Equatable, Sendable {
    var selectedMinute: Int
    var visibleStartMinute: Int
    var visibleDurationMinutes: Int
}

/// Integration reads are much more expensive than a timeline frame. A tab
/// selection, foreground callback and sensor callback can all arrive for the
/// same document window, so keep one short-lived admission gate in front of
/// HealthKit, Screen Time and location enumeration.
struct TimelineIntegrationRefreshGate {
    static let minimumRepeatInterval: TimeInterval = 5

    private(set) var lastKey: String?
    private(set) var lastUptime: TimeInterval?

    mutating func shouldStart(
        key: String,
        nowUptime: TimeInterval,
        force: Bool = false
    ) -> Bool {
        guard !force,
              let lastKey,
              let lastUptime,
              lastKey == key,
              nowUptime - lastUptime < Self.minimumRepeatInterval else {
            return true
        }
        return false
    }

    mutating func commit(key: String, nowUptime: TimeInterval) {
        lastKey = key
        lastUptime = nowUptime
    }
}

struct TimelineAggregationEngine: Sendable {
    var calendar: Calendar

    init(calendar: Calendar = .autoupdatingCurrent) {
        self.calendar = Self.normalizedTimelineCalendar(calendar)
    }

    private static func normalizedTimelineCalendar(_ calendar: Calendar) -> Calendar {
        var timelineCalendar = calendar
        timelineCalendar.locale = Locale(identifier: "ko_KR")
        timelineCalendar.firstWeekday = 2  // Monday
        timelineCalendar.minimumDaysInFirstWeek = 4
        return timelineCalendar
    }

    func rollup(
        goalID: UUID,
        plans: [PlanRecord],
        actuals: [ActualRecord],
        asOf: Date = .now
    ) throws -> GoalRollup {
        guard let goal = plans.first(where: { $0.id == goalID }) else {
            throw PlanningError.missingPlan(goalID)
        }
        let descendants = try PlanHierarchy.descendants(of: goalID, in: plans)
        let scopedPlans = descendants.isEmpty ? [goal] : descendants
        let goalMatches = GoalActivityMatchingEngine.matches(
            goal: goal,
            plans: plans,
            actuals: actuals,
            asOf: asOf
        )

        let plannedByCategory = accumulate(
            scopedPlans.map { ($0.categoryID, $0.span) },
            inside: goal.span
        )
        let actualByCategory = accumulate(
            goalMatches
                .map(\.actual)
                .map { ($0.categoryID, $0.span(asOf: asOf)) },
            inside: goal.span
        )

        return GoalRollup(
            goalID: goalID,
            descendantCount: descendants.count,
            plannedDuration: mergedDuration(
                scopedPlans.map(\.span),
                inside: goal.span
            ),
            actualDuration: mergedDuration(
                goalMatches.map { $0.actual.span(asOf: asOf) },
                inside: goal.span
            ),
            categories: mergeDurations(
                planned: plannedByCategory,
                actual: actualByCategory
            )
        )
    }

    func buckets(
        of unit: TimelineLevel,
        inside outerSpan: TimeSpan,
        plans: [PlanRecord],
        actuals: [ActualRecord],
        photos: [PhotoMoment],
        asOf: Date = .now
    ) -> [SummaryBucket] {
        let bucketSpans = intervals(of: unit, inside: outerSpan)
        guard !bucketSpans.isEmpty else { return [] }

        // 칸마다 기록 전체를 다시 훑으면 칸 수 × 기록 수만큼 일한다.  기록을
        // 한 번만 훑어 겹치는 칸에만 나눠 담는다.
        let planned = distribute(
            plans.map { ($0.categoryID, $0.span) },
            over: bucketSpans
        )
        let actual = distribute(
            actuals.map { ($0.categoryID, $0.span(asOf: asOf)) },
            over: bucketSpans
        )
        var photoCounts = [Int](repeating: 0, count: bucketSpans.count)
        var representatives = [(Date, String)?](
            repeating: nil,
            count: bucketSpans.count
        )
        for photo in photos where !photo.isHiddenFromTimeline {
            guard let index = bucketIndex(
                containing: photo.capturedAt,
                in: bucketSpans
            ) else { continue }
            photoCounts[index] += 1
            if let current = representatives[index],
               current.0 <= photo.capturedAt {
                continue
            }
            representatives[index] = (photo.capturedAt, photo.id)
        }

        return bucketSpans.enumerated().map { index, bucketSpan in
            SummaryBucket(
                id: "\(unit.rawValue)-\(bucketSpan.start.timeIntervalSince1970)",
                span: bucketSpan,
                categories: mergeDurations(
                    planned: planned[index],
                    actual: actual[index]
                ),
                photoCount: photoCounts[index],
                representativePhotoID: representatives[index]?.1
            )
        }
    }

    /// 구간 하나를 통째로 요약한다. 배율이 정한 칸이 아니라 사용자가 고른
    /// 칸의 합집합처럼 달력 경계와 어긋난 구간도 같은 규칙으로 잰다.
    func summary(
        of span: TimeSpan,
        plans: [PlanRecord],
        actuals: [ActualRecord],
        photos: [PhotoMoment],
        asOf: Date = .now
    ) -> SummaryBucket {
        let planned = distribute(
            plans.map { ($0.categoryID, $0.span) },
            over: [span]
        )
        let actual = distribute(
            actuals.map { ($0.categoryID, $0.span(asOf: asOf)) },
            over: [span]
        )
        let visiblePhotos = photos.filter {
            !$0.isHiddenFromTimeline && span.contains($0.capturedAt)
        }
        return SummaryBucket(
            id: "span-\(span.start.timeIntervalSince1970)",
            span: span,
            categories: mergeDurations(
                planned: planned[0],
                actual: actual[0]
            ),
            photoCount: visiblePhotos.count,
            representativePhotoID: visiblePhotos
                .min { $0.capturedAt < $1.capturedAt }?
                .id
        )
    }

    private func distribute(
        _ entries: [(String, TimeSpan)],
        over buckets: [TimeSpan]
    ) -> [[String: TimeInterval]] {
        var spansByBucket = [[String: [TimeSpan]]](
            repeating: [:],
            count: buckets.count
        )
        var categoryIDs: Set<String> = []
        for (categoryID, span) in entries {
            categoryIDs.insert(categoryID)
            var index = firstBucketIndex(endingAfter: span.start, in: buckets)
            while index < buckets.count, buckets[index].start < span.end {
                if let clipped = span.intersection(with: buckets[index]) {
                    spansByBucket[index][categoryID, default: []]
                        .append(clipped)
                }
                index += 1
            }
        }
        // 원래 계산은 어느 칸에도 걸치지 않은 분류도 0으로 남겼다.  요약 띠의
        // 색과 정렬이 그 빈 항목까지 보므로 같은 열쇠 집합을 유지한다.
        return spansByBucket.enumerated().map { index, grouped in
            var value = [String: TimeInterval](
                minimumCapacity: categoryIDs.count
            )
            for categoryID in categoryIDs {
                value[categoryID] = mergedDuration(
                    grouped[categoryID] ?? [],
                    inside: buckets[index]
                )
            }
            return value
        }
    }

    private func firstBucketIndex(
        endingAfter date: Date,
        in buckets: [TimeSpan]
    ) -> Int {
        var low = 0
        var high = buckets.count
        while low < high {
            let middle = (low + high) / 2
            if buckets[middle].end <= date {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    private func bucketIndex(
        containing date: Date,
        in buckets: [TimeSpan]
    ) -> Int? {
        let index = firstBucketIndex(endingAfter: date, in: buckets)
        guard index < buckets.count,
              buckets[index].contains(date) else { return nil }
        return index
    }

    func interval(
        for level: TimelineLevel,
        containing date: Date
    ) -> TimeSpan {
        let component: Calendar.Component
        switch level {
        case .day:
            component = .day
        case .week:
            component = .weekOfYear
        case .month:
            component = .month
        case .year:
            component = .year
        }
        let interval = calendar.dateInterval(of: component, for: date)
            ?? DateInterval(start: date, duration: 86_400)
        return TimeSpan(start: interval.start, end: interval.end)
    }

    private func intervals(
        of level: TimelineLevel,
        inside outer: TimeSpan
    ) -> [TimeSpan] {
        var result: [TimeSpan] = []
        var cursor = outer.start
        let component: Calendar.Component
        switch level {
        case .day:
            component = .day
        case .week:
            component = .weekOfYear
        case .month:
            component = .month
        case .year:
            component = .year
        }

        while cursor < outer.end {
            guard let interval = calendar.dateInterval(of: component, for: cursor) else {
                break
            }
            let span = TimeSpan(
                start: max(interval.start, outer.start),
                end: min(interval.end, outer.end)
            )
            if span.duration > 0 {
                result.append(span)
            }
            guard interval.end > cursor else { break }
            cursor = interval.end.addingTimeInterval(0.001)
        }
        return result
    }

    private func accumulate(
        _ entries: [(String, TimeSpan)],
        inside bucket: TimeSpan
    ) -> [String: TimeInterval] {
        let grouped = Dictionary(grouping: entries, by: \.0)
        return grouped.reduce(into: [:]) { partial, pair in
            partial[pair.key] = mergedDuration(
                pair.value.map(\.1),
                inside: bucket
            )
        }
    }

    private func mergedDuration(
        _ spans: [TimeSpan],
        inside bucket: TimeSpan
    ) -> TimeInterval {
        let ordered = spans
            .compactMap { $0.intersection(with: bucket) }
            .sorted { $0.start < $1.start }
        guard var current = ordered.first else { return 0 }
        var total: TimeInterval = 0
        for span in ordered.dropFirst() {
            if span.start <= current.end {
                current.end = max(current.end, span.end)
            } else {
                total += current.duration
                current = span
            }
        }
        return total + current.duration
    }

    private func mergeDurations(
        planned: [String: TimeInterval],
        actual: [String: TimeInterval]
    ) -> [CategoryDuration] {
        let keys = Set(planned.keys).union(actual.keys)
        return keys
            .map {
                CategoryDuration(
                    categoryID: $0,
                    planned: planned[$0, default: 0],
                    actual: actual[$0, default: 0]
                )
            }
            .sorted {
                max($0.actual, $0.planned) > max($1.actual, $1.planned)
            }
    }
}

struct TimelinePeriodNavigationEngine: Sendable {
    var calendar: Calendar

    init(calendar: Calendar = .autoupdatingCurrent) {
        self.calendar = calendar
    }

    func adjacentDate(
        from date: Date,
        level: TimelineLevel,
        direction: Int
    ) -> Date? {
        guard direction != 0 else { return date }
        return calendar.date(
            byAdding: component(for: level),
            value: direction > 0 ? 1 : -1,
            to: date
        )
    }

    func canNavigate(
        from date: Date,
        level: TimelineLevel,
        direction: Int,
        snapshot: TaptionDataSnapshot,
        asOf: Date = .now
    ) -> Bool {
        // 기록이 없는 날짜도 고를 수 있어야 한다. 계획을 세우려면 아직
        // 아무것도 없는 앞날로 넘어가야 하고, 빈 날이라는 사실 자체도
        // 확인할 수 있어야 한다. 달력이 날짜를 만들어 주는지만 본다.
        guard direction != 0 else { return false }
        return adjacentDate(
            from: date,
            level: level,
            direction: direction
        ) != nil
    }

    private func component(
        for level: TimelineLevel
    ) -> Calendar.Component {
        switch level {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
    }
}
