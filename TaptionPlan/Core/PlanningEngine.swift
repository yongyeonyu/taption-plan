import Foundation

enum PlanningError: Error, Equatable {
    case missingPlan(UUID)
    case parentCycle
    case childOutsideParent
    case invalidDuration
    case fixedPlan
}

enum PlanHierarchy {
    static func children(
        of parentID: UUID,
        in plans: [PlanRecord]
    ) -> [PlanRecord] {
        plans
            .filter { $0.parentID == parentID }
            .sorted { $0.span.start < $1.span.start }
    }

    static func descendants(
        of parentID: UUID,
        in plans: [PlanRecord]
    ) throws -> [PlanRecord] {
        let byParent = Dictionary(grouping: plans.compactMap { plan in
            plan.parentID.map { ($0, plan) }
        }, by: \.0)
        var result: [PlanRecord] = []
        var visiting = Set<UUID>()
        var visited = Set<UUID>()

        func visit(_ id: UUID) throws {
            guard !visiting.contains(id) else {
                throw PlanningError.parentCycle
            }
            guard !visited.contains(id) else { return }
            visiting.insert(id)
            for pair in byParent[id, default: []] {
                result.append(pair.1)
                try visit(pair.1.id)
            }
            visiting.remove(id)
            visited.insert(id)
        }

        try visit(parentID)
        return result
    }

    static func validate(_ plans: [PlanRecord]) throws {
        let ids = Set(plans.map(\.id))
        for plan in plans {
            if let parentID = plan.parentID, !ids.contains(parentID) {
                throw PlanningError.missingPlan(parentID)
            }
            _ = try descendants(of: plan.id, in: plans)
        }
    }

    static func attach(
        child: PlanRecord,
        to parentID: UUID,
        in plans: [PlanRecord]
    ) throws -> PlanRecord {
        guard let parent = plans.first(where: { $0.id == parentID }) else {
            throw PlanningError.missingPlan(parentID)
        }
        guard child.id != parentID else {
            throw PlanningError.parentCycle
        }
        let parentDescendants = try descendants(of: child.id, in: plans)
        guard !parentDescendants.contains(where: { $0.id == parentID }) else {
            throw PlanningError.parentCycle
        }
        guard parent.span.start <= child.span.start,
              child.span.end <= parent.span.end else {
            throw PlanningError.childOutsideParent
        }
        var value = child
        value.parentID = parentID
        value.updatedAt = .now
        return value
    }
}

enum GoalDecompositionEngine {
    static func makeChild(
        parent: PlanRecord,
        title: String,
        span: TimeSpan,
        categoryID: String? = nil
    ) throws -> PlanRecord {
        guard parent.span.start <= span.start, span.end <= parent.span.end else {
            throw PlanningError.childOutsideParent
        }
        return PlanRecord(
            title: title,
            span: span,
            categoryID: categoryID ?? parent.categoryID,
            parentID: parent.id
        )
    }
}

struct TimelineLaneAllocation<ID: Hashable> {
    var lanes: [ID: Int]
    var count: Int
}

/// Combines overlapping measured intervals without changing the source records.
/// Automatic sensors can emit the same activity from more than one device.
enum ActualIntervalMergeEngine {
    static func union(
        _ spans: [TimeSpan],
        mergeGap: TimeInterval = 1
    ) -> [TimeSpan] {
        let ordered = spans
            .filter { $0.duration > 0 }
            .sorted { $0.start < $1.start }
        guard var current = ordered.first else { return [] }

        var merged: [TimeSpan] = []
        for span in ordered.dropFirst() {
            if span.start <= current.end.addingTimeInterval(max(0, mergeGap)) {
                current.end = max(current.end, span.end)
            } else {
                merged.append(current)
                current = span
            }
        }
        merged.append(current)
        return merged
    }

    static func duration(
        of spans: [TimeSpan],
        mergeGap: TimeInterval = 1
    ) -> TimeInterval {
        union(spans, mergeGap: mergeGap).reduce(0) {
            $0 + $1.duration
        }
    }
}

/// Keeps measured movement records as raw evidence while showing one
/// canonical travel segment when the route inference covers that interval.
enum MovementDisplayEngine {
    static func visibleActuals(
        _ actuals: [ActualRecord],
        travel: [TravelSegment],
        asOf date: Date = .now
    ) -> [ActualRecord] {
        guard !travel.isEmpty else { return actuals }
        let travelSpans = travel.map(\.span)
        return actuals.filter { actual in
            guard actual.categoryID == "movement" else { return true }
            let actualSpan = actual.span(asOf: date)
            guard actualSpan.duration > 0 else { return false }
            let overlap = ActualIntervalMergeEngine.duration(
                of: travelSpans.compactMap {
                    $0.intersection(with: actualSpan)
                }
            )
            let coverageThreshold = min(
                30,
                max(1, actualSpan.duration * 0.5)
            )
            return overlap < coverageThreshold
        }
    }
}

enum TimelineLaneAllocator {
    static func allocate<Item: Identifiable>(
        _ items: [Item],
        span: (Item) -> TimeSpan
    ) -> TimelineLaneAllocation<Item.ID>
    where Item.ID: Hashable {
        let sorted = items.sorted {
            let lhs = span($0)
            let rhs = span($1)
            if lhs.start == rhs.start {
                return lhs.end < rhs.end
            }
            return lhs.start < rhs.start
        }
        var laneEnds: [Date] = []
        var lanes: [Item.ID: Int] = [:]

        for item in sorted {
            let itemSpan = span(item)
            let lane = laneEnds.firstIndex {
                $0 <= itemSpan.start
            } ?? laneEnds.count

            if lane == laneEnds.count {
                laneEnds.append(itemSpan.end)
            } else {
                laneEnds[lane] = itemSpan.end
            }
            lanes[item.id] = lane
        }

        return TimelineLaneAllocation(
            lanes: lanes,
            count: laneEnds.count
        )
    }
}

enum AutomaticRecordTimelineEngine {
    /// Device/HealthKit records are ground truth. Their timestamps and
    /// measured duration must never be changed by the plan editor or the
    /// routine progress slider.
    static func isImmutable(_ actual: ActualRecord) -> Bool {
        switch actual.source {
        case .healthKit, .appleWatch, .motion, .location, .media, .call,
             .appUsage:
            true
        case .manual, .timer, .calendar, .photo:
            false
        }
    }

    static func isSleep(_ actual: ActualRecord) -> Bool {
        // 앱 이름은 임의의 낱말이라 제목만 보고 수면으로 오인하면 안 된다.
        if actual.categoryID == "appUsage" { return false }
        return actual.categoryID == "sleep"
            || actual.title.localizedCaseInsensitiveContains("수면")
            || actual.title.localizedCaseInsensitiveContains("취침")
            || actual.title.localizedCaseInsensitiveContains("sleep")
    }

    static func isRoutineOnlyCategory(_ categoryID: String) -> Bool {
        categoryID == "sleep" || categoryID == "activity"
    }

    static func linksOnlyToRoutine(_ actual: ActualRecord) -> Bool {
        isRoutineOnlyCategory(actual.categoryID)
    }

    static func activities(
        from actuals: [ActualRecord],
        inside span: TimeSpan,
        asOf: Date = .now
    ) -> [ActualRecord] {
        visibleThroughNow(actuals, asOf: asOf)
            .filter {
                ($0.source == .healthKit
                    || $0.source == .appleWatch
                    || $0.source == .motion
                    || $0.source == .location
                    || $0.source == .media
                    || $0.source == .call
                    || $0.source == .appUsage)
                    && $0.span(asOf: asOf).intersection(with: span) != nil
            }
            .sorted {
                if $0.startedAt == $1.startedAt {
                    return $0.span(asOf: asOf).end
                        < $1.span(asOf: asOf).end
                }
                return $0.startedAt < $1.startedAt
            }
    }

    /// Automatic records are observations, not forecasts.  Keep the source
    /// record immutable while clipping the copy used by timelines/widgets to
    /// the current instant.
    static func visibleThroughNow(
        _ actuals: [ActualRecord],
        asOf: Date = .now
    ) -> [ActualRecord] {
        actuals.compactMap { actual in
            guard actual.startedAt <= asOf else { return nil }
            var visible = actual
            if visible.endedAt == nil || visible.endedAt! > asOf {
                visible.endedAt = asOf
            }
            return visible
        }
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

    func hierarchySummaries(
        for level: TimelineLevel,
        containing date: Date,
        plans: [PlanRecord],
        actuals: [ActualRecord],
        photos: [PhotoMoment],
        asOf: Date = .now
    ) -> [TimelineLevel: [SummaryBucket]] {
        let childLevels: [TimelineLevel]
        switch level {
        case .day:
            childLevels = []
        case .week:
            childLevels = [.day]
        case .month:
            childLevels = [.week, .day]
        case .year:
            childLevels = [.month, .week, .day]
        }

        return Dictionary(uniqueKeysWithValues: childLevels.map { childLevel in
            (
                childLevel,
                buckets(
                    of: childLevel,
                    inside: interval(for: level, containing: date),
                    plans: plans,
                    actuals: actuals,
                    photos: photos,
                    asOf: asOf
                )
            )
        })
    }

    func buckets(
        of unit: TimelineLevel,
        inside outerSpan: TimeSpan,
        plans: [PlanRecord],
        actuals: [ActualRecord],
        photos: [PhotoMoment],
        asOf: Date = .now
    ) -> [SummaryBucket] {
        intervals(of: unit, inside: outerSpan).map { bucketSpan in
            let planned = accumulate(
                plans.map { ($0.categoryID, $0.span) },
                inside: bucketSpan
            )
            let actual = accumulate(
                actuals.map { ($0.categoryID, $0.span(asOf: asOf)) },
                inside: bucketSpan
            )
            let bucketPhotos = photos
                .filter { bucketSpan.contains($0.capturedAt) && !$0.isHiddenFromTimeline }
                .sorted { $0.capturedAt < $1.capturedAt }
            return SummaryBucket(
                id: "\(unit.rawValue)-\(bucketSpan.start.timeIntervalSince1970)",
                span: bucketSpan,
                categories: mergeDurations(planned: planned, actual: actual),
                photoCount: bucketPhotos.count,
                representativePhotoID: bucketPhotos.first?.id
            )
        }
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
        guard direction != 0,
              let targetDate = adjacentDate(
                from: date,
                level: level,
                direction: direction
              ) else {
            return false
        }
        let targetSpan = TimelineAggregationEngine(
            calendar: calendar
        ).interval(for: level, containing: targetDate)
        return containsTimelineData(
            in: targetSpan,
            snapshot: snapshot,
            asOf: asOf
        )
    }

    func containsTimelineData(
        in span: TimeSpan,
        snapshot: TaptionDataSnapshot,
        asOf: Date = .now
    ) -> Bool {
        snapshot.plans.contains {
            $0.span.intersection(with: span) != nil
        }
            || snapshot.actuals.contains {
                $0.span(asOf: asOf).intersection(with: span) != nil
            }
            || snapshot.calendarEvents.contains {
                $0.span.intersection(with: span) != nil
            }
            || snapshot.photos.contains {
                !$0.isHiddenFromTimeline
                    && span.start <= $0.capturedAt
                    && $0.capturedAt < span.end
            }
            || snapshot.places.contains {
                $0.span.intersection(with: span) != nil
            }
            || snapshot.travel.contains {
                $0.span.intersection(with: span) != nil
            }
            || snapshot.floorTransitions.contains {
                $0.span.intersection(with: span) != nil
            }
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

enum ScheduleEditEngine {
    static let dragSnap: TimeInterval = 15 * 60

    static func move(
        _ plan: PlanRecord,
        by delta: TimeInterval
    ) throws -> PlanRecord {
        guard !plan.isFixed else { throw PlanningError.fixedPlan }
        let snapped = (delta / dragSnap).rounded() * dragSnap
        var value = plan
        value.span = TimeSpan(
            start: plan.span.start.addingTimeInterval(snapped),
            end: plan.span.end.addingTimeInterval(snapped)
        )
        value.updatedAt = .now
        return value
    }

    static func resize(
        _ plan: PlanRecord,
        newStart: Date? = nil,
        newEnd: Date? = nil
    ) throws -> PlanRecord {
        guard !plan.isFixed else { throw PlanningError.fixedPlan }
        let start = snap(newStart ?? plan.span.start)
        let end = snap(newEnd ?? plan.span.end)
        guard start < end else { throw PlanningError.invalidDuration }
        var value = plan
        value.span = TimeSpan(start: start, end: end)
        value.updatedAt = .now
        return value
    }

    private static func snap(_ date: Date) -> Date {
        let seconds = date.timeIntervalSinceReferenceDate
        return Date(
            timeIntervalSinceReferenceDate: (seconds / dragSnap).rounded() * dragSnap
        )
    }
}

enum ActionMemoEditingEngine {
    static func updating(
        _ memo: ActionMemo,
        text: String,
        kind: MemoKind,
        at date: Date = .now
    ) -> ActionMemo? {
        let cleanText = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !cleanText.isEmpty else { return nil }
        var value = memo
        value.text = cleanText
        value.kind = kind
        value.updatedAt = date
        return value
    }
}

enum ActualRecordSuppressionEngine {
    static func visibleRecords(
        from records: [ActualRecord],
        suppressedIDs: Set<UUID>
    ) -> [ActualRecord] {
        records.filter { !suppressedIDs.contains($0.id) }
    }
}

struct QuickActionResult: Sendable {
    var plan: PlanRecord
    var actuals: [ActualRecord]
}

enum QuickActionEngine {
    static func start(
        plan: PlanRecord,
        actuals: [ActualRecord],
        at date: Date = .now
    ) -> QuickActionResult {
        var updated = plan
        updated.status = .running
        updated.updatedAt = date

        guard !actuals.contains(where: { $0.planID == plan.id && $0.endedAt == nil }) else {
            return QuickActionResult(plan: updated, actuals: actuals)
        }
        var values = actuals
        values.append(
            ActualRecord(
                planID: plan.id,
                title: plan.title,
                categoryID: plan.categoryID,
                startedAt: date,
                source: .timer
            )
        )
        return QuickActionResult(plan: updated, actuals: values)
    }

    static func complete(
        plan: PlanRecord,
        actuals: [ActualRecord],
        at date: Date = .now,
        copyPlannedDurationWhenMissing: Bool = false
    ) -> QuickActionResult {
        var updated = plan
        updated.status = .completed
        updated.updatedAt = date
        var values = actuals

        if let runningIndex = values.lastIndex(where: {
            $0.planID == plan.id && $0.endedAt == nil
        }) {
            values[runningIndex].endedAt = max(
                values[runningIndex].startedAt,
                date
            )
        } else if copyPlannedDurationWhenMissing {
            values.append(
                ActualRecord(
                    planID: plan.id,
                    title: plan.title,
                    categoryID: plan.categoryID,
                    startedAt: plan.span.start,
                    endedAt: plan.span.end,
                    source: .manual
                )
            )
        }
        return QuickActionResult(plan: updated, actuals: values)
    }

    static func postpone(
        plan: PlanRecord,
        by interval: TimeInterval = 30 * 60
    ) throws -> PlanRecord {
        try ScheduleEditEngine.move(plan, by: interval)
    }

    static func skip(
        plan: PlanRecord,
        at date: Date = .now
    ) -> PlanRecord {
        var value = plan
        value.status = .skipped
        value.updatedAt = date
        return value
    }

    static func moveToNextFreeTime(
        plan: PlanRecord,
        occupied: [TimeSpan],
        after date: Date = .now,
        searchLimit: Date? = nil
    ) throws -> PlanRecord {
        guard !plan.isFixed else { throw PlanningError.fixedPlan }
        let duration = plan.span.duration
        guard duration > 0 else { throw PlanningError.invalidDuration }
        let limit = searchLimit ?? date.addingTimeInterval(14 * 86_400)
        let sorted = occupied
            .filter { $0.end > date }
            .sorted { $0.start < $1.start }
        var candidate = date

        for block in sorted {
            if candidate.addingTimeInterval(duration) <= block.start {
                break
            }
            if candidate < block.end {
                candidate = block.end
            }
            guard candidate.addingTimeInterval(duration) <= limit else {
                throw PlanningError.invalidDuration
            }
        }

        var value = plan
        value.span = TimeSpan(
            start: candidate,
            end: candidate.addingTimeInterval(duration)
        )
        value.updatedAt = .now
        return value
    }
}

enum PhotoClusterer {
    static func cluster(
        _ photos: [PhotoMoment],
        threshold: TimeInterval = 20 * 60
    ) -> [PhotoCluster] {
        let visible = photos
            .filter { !$0.isHiddenFromTimeline }
            .sorted { $0.capturedAt < $1.capturedAt }
        guard var first = visible.first else { return [] }
        var current = [first]
        var clusters: [PhotoCluster] = []

        func appendCluster(_ values: [PhotoMoment]) {
            guard let representative = values.first(where: \.isFavorite) ?? values.first else {
                return
            }
            clusters.append(
                PhotoCluster(
                    id: representative.id,
                    representative: representative,
                    photos: values
                )
            )
        }

        for photo in visible.dropFirst() {
            if photo.capturedAt.timeIntervalSince(first.capturedAt) <= threshold {
                current.append(photo)
            } else {
                appendCluster(current)
                current = [photo]
            }
            first = photo
        }
        appendCluster(current)
        return clusters
    }

    static func nearestCluster(
        to date: Date,
        in photos: [PhotoMoment],
        tolerance: TimeInterval,
        threshold: TimeInterval = 20 * 60
    ) -> PhotoCluster? {
        let searchRadius = max(0, tolerance) + max(0, threshold)
        let candidates = photos.filter {
            !$0.isHiddenFromTimeline
                && abs($0.capturedAt.timeIntervalSince(date)) <= searchRadius
        }
        return cluster(candidates, threshold: threshold)
            .filter { cluster in
                guard let start = cluster.photos.first?.capturedAt,
                      let end = cluster.photos.last?.capturedAt else {
                    return false
                }
                return start.addingTimeInterval(-tolerance) <= date
                    && date <= end.addingTimeInterval(tolerance)
            }
            .min {
                abs($0.capturedAt.timeIntervalSince(date))
                    < abs($1.capturedAt.timeIntervalSince(date))
            }
    }
}

struct ReviewEngine: Sendable {
    var aggregation: TimelineAggregationEngine

    init(calendar: Calendar = .autoupdatingCurrent) {
        self.aggregation = TimelineAggregationEngine(calendar: calendar)
    }

    func report(
        for level: TimelineLevel,
        containing date: Date,
        plans: [PlanRecord],
        actuals: [ActualRecord],
        weather: [WeatherContext],
        photos: [PhotoMoment],
        memos: [ActionMemo],
        asOf: Date = .now
    ) -> ReviewReport {
        let span = aggregation.interval(for: level, containing: date)
        let bucket = aggregation.buckets(
            of: level,
            inside: span,
            plans: plans,
            actuals: actuals,
            photos: photos,
            asOf: asOf
        ).first ?? SummaryBucket(
            id: "empty",
            span: span,
            categories: [],
            photoCount: 0,
            representativePhotoID: nil
        )
        let knownPlanIDs = Set(plans.map(\.id))
        let unplanned = actuals.reduce(0) { partial, actual in
            guard actual.planID == nil || !knownPlanIDs.contains(actual.planID!) else {
                return partial
            }
            return partial + (actual.span(asOf: asOf).intersection(with: span)?.duration ?? 0)
        }

        var contexts: [ReviewContext] = weather
            .filter { span.contains($0.observedAt) }
            .map {
                let airQualityText = $0.airQuality.map {
                    " · 미세 \($0.overallGrade.displayName) (PM10 \(Int($0.pm10MicrogramsPerCubicMeter.rounded())) / PM2.5 \(Int($0.pm25MicrogramsPerCubicMeter.rounded())))"
                } ?? ""
                return ReviewContext(
                    id: "weather-\($0.id.uuidString)",
                    date: $0.observedAt,
                    symbolName: $0.symbolName,
                    text: "\($0.condition) · \(Int($0.temperatureCelsius.rounded()))°\(airQualityText)",
                    linkedPlanID: nil
                )
            }

        let visiblePhotos = photos.filter {
            span.contains($0.capturedAt) && !$0.isHiddenFromTimeline
        }
        if let first = visiblePhotos.first {
            contexts.append(
                ReviewContext(
                    id: "photos-\(span.start.timeIntervalSince1970)",
                    date: first.capturedAt,
                    symbolName: "photo",
                    text: "기억으로 남긴 사진 \(visiblePhotos.count)장",
                    linkedPlanID: first.linkedPlanID
                )
            )
        }

        contexts.append(contentsOf: memos
            .filter {
                $0.isHighlightedInReview
                    && span.contains($0.createdAt)
            }
            .map {
                ReviewContext(
                    id: "memo-\($0.id.uuidString)",
                    date: $0.createdAt,
                    symbolName: "note.text",
                    text: $0.text,
                    linkedPlanID: $0.planID
                )
            })

        return ReviewReport(
            span: span,
            plannedDuration: bucket.plannedDuration,
            actualDuration: bucket.actualDuration,
            categories: bucket.categories,
            unplannedActualDuration: unplanned,
            contexts: contexts.sorted { $0.date < $1.date }
        )
    }
}

enum GoalRecordPolicy {
    static let currentPrefix = "루틴:"
    static let legacyPrefix = "목표:"

    static func isGoal(_ plan: PlanRecord) -> Bool {
        guard plan.parentID == nil else { return false }
        let title = plan.title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return title.hasPrefix(currentPrefix)
            || title.hasPrefix(legacyPrefix)
    }

    static func displayTitle(_ raw: String) -> String {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.hasPrefix(currentPrefix) {
            return title
        }
        if title.hasPrefix(legacyPrefix) {
            return currentPrefix + title.dropFirst(legacyPrefix.count)
        }
        return currentPrefix + title
    }

    static func visibleGoals(in plans: [PlanRecord]) -> [PlanRecord] {
        plans
            .filter { isGoal($0) && $0.status != .skipped }
            .sorted { lhs, rhs in
                if lhs.span.start == rhs.span.start {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.span.start < rhs.span.start
            }
    }
}

/// How an actual record was associated with a goal.
enum GoalActualMatchKind: String, Equatable, Hashable, Sendable {
    case linked
    case automatic

    var displayName: String {
        switch self {
        case .linked: "연결됨"
        case .automatic: "자동 근거"
        }
    }
}

struct GoalActualMatch: Identifiable, Equatable, Hashable, Sendable {
    let actual: ActualRecord
    let kind: GoalActualMatchKind
    let overlapDuration: TimeInterval
    let matchedPlanID: UUID?

    var id: UUID { actual.id }
}

/// Resolves explicit links first, then associates unlinked HealthKit/Watch
/// sleep and activity records with the best overlapping repeat segment.
enum GoalActivityMatchingEngine {
    static func matches(
        goal: PlanRecord,
        plans: [PlanRecord],
        actuals: [ActualRecord],
        asOf: Date = .now
    ) -> [GoalActualMatch] {
        let descendants = (try? PlanHierarchy.descendants(
            of: goal.id,
            in: plans
        )) ?? []
        let scopedIDs = Set([goal.id] + descendants.map(\.id))
        var claimed = Set<UUID>()
        let explicit = actuals.compactMap { actual -> GoalActualMatch? in
            if AutomaticRecordTimelineEngine.linksOnlyToRoutine(actual) {
                guard let routineID = actual.routineID,
                      scopedIDs.contains(routineID) else { return nil }
                claimed.insert(actual.id)
                return GoalActualMatch(
                    actual: actual,
                    kind: .linked,
                    overlapDuration: actual.span(asOf: asOf).duration,
                    matchedPlanID: routineID
                )
            }

            if let planID = actual.planID {
                // A record explicitly attached elsewhere must not be copied
                // into another goal merely because its category/time match.
                guard scopedIDs.contains(planID) else { return nil }
                return GoalActualMatch(
                    actual: actual,
                    kind: .linked,
                    overlapDuration: actual.span(asOf: asOf).duration,
                    matchedPlanID: planID
                )
            }

            if let routineID = actual.routineID,
               scopedIDs.contains(routineID) {
                return GoalActualMatch(
                    actual: actual,
                    kind: .linked,
                    overlapDuration: actual.span(asOf: asOf).duration,
                    matchedPlanID: routineID
                )
            }

            return nil
        }
        let repeatSegments = descendants.filter {
            $0.origin == .repeatRule
                && $0.categoryID == goal.categoryID
        }
        let automatic = actuals.compactMap { actual -> GoalActualMatch? in
            guard !claimed.contains(actual.id),
                  actual.planID == nil,
                  actual.routineID == nil,
                  (actual.source == .healthKit
                      || actual.source == .appleWatch
                      || actual.source == .motion
                      || actual.source == .media
                      || actual.source == .call),
                  AutomaticRecordTimelineEngine.isRoutineOnlyCategory(
                      goal.categoryID
                  ) else { return nil }
            let actualSpan = actual.span(asOf: asOf)
            let best = repeatSegments.compactMap { segment -> (PlanRecord, TimeInterval)? in
                guard let overlap = actualSpan.intersection(with: segment.span) else {
                    return nil
                }
                return (segment, overlap.duration)
            }.max { lhs, rhs in
                lhs.1 == rhs.1
                    ? lhs.0.span.start > rhs.0.span.start
                    : lhs.1 < rhs.1
            }
            guard let best else { return nil }
            return GoalActualMatch(
                actual: actual,
                kind: .automatic,
                overlapDuration: best.1,
                matchedPlanID: best.0.id
            )
        }
        return (explicit + automatic).sorted {
            if $0.actual.startedAt == $1.actual.startedAt {
                return $0.actual.id.uuidString < $1.actual.id.uuidString
            }
            return $0.actual.startedAt < $1.actual.startedAt
        }
    }

    static func progress(
        for plan: PlanRecord,
        matches: [GoalActualMatch],
        asOf: Date = .now
    ) -> Double {
        let spans = matches.compactMap { match -> TimeSpan? in
            let actual = match.actual
            if actual.planID == plan.id
                || actual.routineID == plan.id
                || match.matchedPlanID == plan.id {
                return actual.span(asOf: asOf).intersection(with: plan.span)
            }
            return nil
        }
        guard plan.span.duration > 0 else { return 0 }
        let covered = unionDuration(spans)
        return min(1, max(0, covered / plan.span.duration))
    }

    static func unionDuration(_ spans: [TimeSpan]) -> TimeInterval {
        let ordered = spans
            .filter { $0.duration > 0 }
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
}

// MARK: - Automatic · routine · action record graph

enum RecordLayer: String, CaseIterable, Sendable {
    case automatic = "자동"
    case routine = "루틴"
    case action = "액션"
}

struct RecordGraphNode: Identifiable, Hashable, Sendable {
    let id: String
    let layer: RecordLayer
    let title: String
    let span: TimeSpan
    let categoryID: String?
}

struct RecordGraphEdge: Identifiable, Hashable, Sendable {
    let from: String
    let to: String
    var id: String { "\(from)->\(to)" }
}

struct RecordRelationshipGraph: Sendable {
    let nodes: [RecordGraphNode]
    let edges: [RecordGraphEdge]
    var isEmpty: Bool { nodes.isEmpty }
    var hasConnections: Bool { !edges.isEmpty }
}

/// Keeps automatic evidence, a routine, and its concrete action as separate
/// nodes while exposing only explicit relationships. Time/category overlap is
/// deliberately not treated as a connection.
enum RecordRelationshipEngine {
    static func make(
        inside span: TimeSpan,
        plans: [PlanRecord],
        actuals: [ActualRecord],
        calendarEvents: [CalendarRecord],
        places: [PlaceStay],
        travel: [TravelSegment],
        recordLinks: [RecordLink] = [],
        focusNodeID: String? = nil
    ) -> RecordRelationshipGraph {
        var allNodes: [RecordGraphNode] = []
        var edges: [RecordGraphEdge] = []
        var nodeIDs = Set<String>()
        var edgeIDs = Set<String>()
        let plansByID = Dictionary(
            plans.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        allNodes.reserveCapacity(
            calendarEvents.count
                + places.count
                + travel.count
                + actuals.count
                + plans.count
        )

        func appendEdge(from: String, to: String) {
            let edge = RecordGraphEdge(from: from, to: to)
            guard edgeIDs.insert(edge.id).inserted else { return }
            edges.append(edge)
        }

        func append(_ node: RecordGraphNode, includeOutsideSpan: Bool = false) {
            guard includeOutsideSpan || node.span.intersection(with: span) != nil,
                  nodeIDs.insert(node.id).inserted else { return }
            allNodes.append(node)
        }

        for event in calendarEvents {
            append(RecordGraphNode(
                id: "automatic.calendar.\(event.id)",
                layer: .automatic,
                title: event.title,
                span: event.span,
                categoryID: "calendar"
            ))
        }
        for place in places {
            append(RecordGraphNode(
                id: "automatic.place.\(place.id.uuidString)",
                layer: .automatic,
                title: place.floor.map { "\(place.displayName) · \($0)층" } ?? place.displayName,
                span: place.span,
                categoryID: "location"
            ))
        }
        for segment in travel {
            append(RecordGraphNode(
                id: "automatic.travel.\(segment.id.uuidString)",
                layer: .automatic,
                title: travelTitle(segment.mode),
                span: segment.span,
                categoryID: "movement"
            ))
        }
        for actual in actuals where isAutomaticActual(actual) {
            append(RecordGraphNode(
                id: "automatic.actual.\(actual.id.uuidString)",
                layer: .automatic,
                title: actual.categoryID == "movement"
                    ? MovementPresentation.title(for: actual)
                    : actual.title,
                span: actual.span(),
                categoryID: actual.categoryID
            ))
        }

        // Repeat-rule segments are projections of a routine, not separate
        // relationship nodes. Keeping them here made one routine appear as
        // several duplicate cards and caused evidence to link to a phantom
        // action. The root routine owns the rule; concrete actions remain
        // separate nodes.
        for plan in plans where isRoutine(plan) {
            append(RecordGraphNode(
                id: "routine.\(plan.id.uuidString)",
                layer: .routine,
                title: GoalRecordPolicy.displayTitle(plan.title),
                span: plan.span,
                categoryID: plan.categoryID
            ), includeOutsideSpan: true)
        }
        for plan in plans where isAction(plan) {
            append(RecordGraphNode(
                id: "action.\(plan.id.uuidString)",
                layer: .action,
                title: plan.title,
                span: plan.span,
                categoryID: plan.categoryID
            ), includeOutsideSpan: true)
        }

        let routines = allNodes.filter { $0.layer == .routine }
        let actions = allNodes.filter { $0.layer == .action }
        for action in actions {
            guard let actionID = UUID(
                uuidString: action.id.replacingOccurrences(of: "action.", with: "")
            ), let routineID = rootRoutineID(
                for: actionID,
                plansByID: plansByID
            ) else {
                continue
            }
            let routineNodeID = "routine.\(routineID.uuidString)"
            guard routines.contains(where: { $0.id == routineNodeID }) else {
                continue
            }
            appendEdge(from: routineNodeID, to: action.id)
        }

        for actual in actuals {
            let actualNodeID = "automatic.actual.\(actual.id.uuidString)"
            guard nodeIDs.contains(actualNodeID) else { continue }
            if let routineID = routineID(
                for: actual,
                plansByID: plansByID
            ) {
                let nodeID = "routine.\(routineID.uuidString)"
                if nodeIDs.contains(nodeID) {
                    appendEdge(from: actualNodeID, to: nodeID)
                }
            }
            if let planID = actionID(
                for: actual,
                plansByID: plansByID
            ) {
                let nodeID = "action.\(planID.uuidString)"
                if nodeIDs.contains(nodeID) {
                    appendEdge(from: actualNodeID, to: nodeID)
                }
            }
        }

        for link in recordLinks {
            let from = canonicalNodeID(link.fromNodeID, plansByID: plansByID)
            let to = canonicalNodeID(link.toNodeID, plansByID: plansByID)
            guard from != to,
                  nodeIDs.contains(from),
                  nodeIDs.contains(to) else { continue }
            appendEdge(from: from, to: to)
        }

        let visibleIDs: Set<String>
        if let focusNodeID {
            let canonicalFocus = canonicalNodeID(focusNodeID, plansByID: plansByID)
            var connected = Set([canonicalFocus])
            var changed = true
            while changed {
                changed = false
                for edge in edges where connected.contains(edge.from) || connected.contains(edge.to) {
                    if connected.insert(edge.from).inserted { changed = true }
                    if connected.insert(edge.to).inserted { changed = true }
                }
            }
            visibleIDs = connected
        } else {
            visibleIDs = Set(
                allNodes
                    .filter { $0.span.intersection(with: span) != nil }
                    .map(\.id)
            )
        }
        let nodes = allNodes.filter { visibleIDs.contains($0.id) }
        let visibleEdges = edges.filter {
            visibleIDs.contains($0.from) && visibleIDs.contains($0.to)
        }
        return RecordRelationshipGraph(
            nodes: nodes.sorted { lhs, rhs in
                let leftLayer = RecordLayer.allCases.firstIndex(of: lhs.layer) ?? 0
                let rightLayer = RecordLayer.allCases.firstIndex(of: rhs.layer) ?? 0
                return leftLayer == rightLayer
                    ? lhs.span.start < rhs.span.start
                    : leftLayer < rightLayer
            },
            edges: visibleEdges
        )
    }

    private static func isAutomaticActual(_ actual: ActualRecord) -> Bool {
        actual.categoryID == "sleep"
            || actual.categoryID == "activity"
            || actual.source == .healthKit
            || actual.source == .appleWatch
            || actual.source == .motion
            || actual.source == .location
            || actual.source == .media
            || actual.source == .call
    }

    private static func isRoutine(_ plan: PlanRecord) -> Bool {
        GoalRecordPolicy.isGoal(plan)
    }

    private static func isAction(_ plan: PlanRecord) -> Bool {
        !GoalRecordPolicy.isGoal(plan)
            && plan.origin != .repeatRule
            && plan.origin != .calendar
    }

    private static func rootRoutineID(
        for planID: UUID,
        plansByID: [UUID: PlanRecord]
    ) -> UUID? {
        var currentID: UUID? = planID
        var visited = Set<UUID>()
        while let id = currentID,
              visited.insert(id).inserted,
              let plan = plansByID[id] {
            if GoalRecordPolicy.isGoal(plan) {
                return plan.id
            }
            currentID = plan.parentID
        }
        return nil
    }

    private static func routineID(
        for actual: ActualRecord,
        plansByID: [UUID: PlanRecord]
    ) -> UUID? {
        if let routineID = actual.routineID,
           let rootID = rootRoutineID(for: routineID, plansByID: plansByID) {
            return rootID
        }
        guard let planID = actual.planID else { return nil }
        return rootRoutineID(for: planID, plansByID: plansByID)
    }

    private static func actionID(
        for actual: ActualRecord,
        plansByID: [UUID: PlanRecord]
    ) -> UUID? {
        guard !AutomaticRecordTimelineEngine.linksOnlyToRoutine(actual),
              let planID = actual.planID,
              let plan = plansByID[planID],
              isAction(plan) else {
            return nil
        }
        return plan.id
    }

    private static func canonicalNodeID(
        _ nodeID: String,
        plansByID: [UUID: PlanRecord]
    ) -> String {
        let prefixes = ["routine.", "action."]
        guard let prefix = prefixes.first(where: { nodeID.hasPrefix($0) }),
              let id = UUID(uuidString: String(nodeID.dropFirst(prefix.count))) else {
            return nodeID
        }
        guard let plan = plansByID[id] else { return nodeID }
        if let rootID = rootRoutineID(for: plan.id, plansByID: plansByID) {
            if prefix == "routine." || plan.origin == .repeatRule {
                return "routine.\(rootID.uuidString)"
            }
        }
        return nodeID
    }

    private static func travelTitle(_ mode: TravelMode) -> String {
        switch mode {
        case .walking: "걷기"
        case .running: "달리기"
        case .cycling: "자전거"
        case .bus: "버스"
        case .subway: "지하철"
        case .taxi: "택시"
        case .car: "자동차"
        case .train: "기차"
        case .airplane: "비행기"
        case .ship: "배"
        }
    }
}

enum WeatherTimelineEngine {
    static let defaultDuration: TimeInterval = 15 * 60

    private struct Signature: Equatable {
        let condition: String
        let temperature: Int
        let airGrade: AirQualityGrade?
    }

    static func span(
        for context: WeatherContext,
        defaultDuration: TimeInterval = 15 * 60
    ) -> TimeSpan {
        let fallbackEnd = context.observedAt.addingTimeInterval(defaultDuration)
        return TimeSpan(
            start: context.observedAt,
            end: max(
                context.observedAt.addingTimeInterval(1),
                context.validUntil ?? fallbackEnd
            )
        )
    }

    static func coalesced(
        _ contexts: [WeatherContext],
        defaultDuration: TimeInterval = 15 * 60
    ) -> [WeatherContext] {
        var seen = Set<UUID>()
        let ordered = contexts
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.observedAt < $1.observedAt }
        var result: [WeatherContext] = []
        result.reserveCapacity(ordered.count)

        for original in ordered {
            var current = original
            current.validUntil = span(
                for: current,
                defaultDuration: defaultDuration
            ).end
            guard let lastIndex = result.indices.last else {
                result.append(current)
                continue
            }

            let last = result[lastIndex]
            let lastSpan = span(for: last, defaultDuration: defaultDuration)
            if signature(last) == signature(current) {
                result[lastIndex].validUntil = max(
                    lastSpan.end,
                    span(for: current, defaultDuration: defaultDuration).end
                )
                // Keep the most recent detail values while preserving one
                // continuous block for the same displayed weather.
                result[lastIndex].airQuality = current.airQuality
                result[lastIndex].point = current.point ?? result[lastIndex].point
                result[lastIndex].placeID = current.placeID ?? result[lastIndex].placeID
                result[lastIndex].placeName = current.placeName ?? result[lastIndex].placeName
                if let fetchedAt = current.fetchedAt,
                   fetchedAt > (result[lastIndex].fetchedAt ?? .distantPast) {
                    result[lastIndex].fetchedAt = fetchedAt
                    result[lastIndex].isStale = current.isStale
                }
            } else {
                result[lastIndex].validUntil = current.observedAt
                result.append(current)
            }
        }
        return result
    }

    private static func signature(_ context: WeatherContext) -> Signature {
        Signature(
            condition: context.condition,
            temperature: Int(context.temperatureCelsius.rounded()),
            // Merge by what the timeline shows.  Raw PM values, provider and
            // fallback state belong to the detail view and must not split a
            // visually identical weather run.
            airGrade: context.airQuality?.overallGrade
        )
    }
}

enum TimelineCoordinateMapper {
    static func fraction(
        for date: Date,
        in viewport: TimelineViewport
    ) -> Double {
        let visibleStart = viewport.dayStart.addingTimeInterval(
            viewport.horizontalOffset
        )
        return date.timeIntervalSince(visibleStart) / viewport.visibleSpan
    }

    static func date(
        at fraction: Double,
        in viewport: TimelineViewport
    ) -> Date {
        viewport.dayStart.addingTimeInterval(
            viewport.horizontalOffset + fraction * viewport.visibleSpan
        )
    }

    static func pan(
        _ viewport: TimelineViewport,
        by interval: TimeInterval
    ) -> TimelineViewport {
        var value = viewport
        value.horizontalOffset = max(0, value.horizontalOffset + interval)
        value.followsCurrentTime = false
        return value
    }

    static func zoom(
        _ viewport: TimelineViewport,
        factor: Double,
        anchor: Double = 0.5
    ) -> TimelineViewport {
        var value = viewport
        let oldSpan = viewport.visibleSpan
        let newSpan = min(86_400, max(15 * 60, oldSpan / max(0.1, factor)))
        let anchorOffset = viewport.horizontalOffset + oldSpan * anchor
        value.visibleSpan = newSpan
        value.horizontalOffset = max(0, anchorOffset - newSpan * anchor)
        value.followsCurrentTime = false
        return value
    }

    static func followNow(
        _ viewport: TimelineViewport,
        now: Date = .now,
        anchor: Double = 0.6
    ) -> TimelineViewport {
        var value = viewport
        value.currentTime = now
        value.horizontalOffset = max(
            0,
            now.timeIntervalSince(viewport.dayStart) - viewport.visibleSpan * anchor
        )
        value.followsCurrentTime = true
        return value
    }
}

enum WidgetSnapshotFactory {
    static func make(
        plans: [PlanRecord],
        now: Date,
        catStyle: CatStyle,
        hideSensitiveContent: Bool,
        horizon: TimeInterval = 4 * 3_600
    ) -> WidgetSnapshot {
        let viewport = TimeSpan(
            start: now.addingTimeInterval(-horizon / 2),
            end: now.addingTimeInterval(horizon / 2)
        )
        let visiblePlans = plans
            .filter { $0.span.intersection(with: viewport) != nil && $0.status != .skipped }
            .sorted { $0.span.start < $1.span.start }
        let items = visiblePlans.map { plan in
            WidgetTimelineItem(
                id: plan.id,
                title: plan.title,
                span: plan.span,
                categoryID: plan.categoryID,
                isCurrent: plan.span.contains(now) && plan.status != .completed
            )
        }
        return WidgetSnapshot(
            generatedAt: now,
            viewport: viewport,
            items: items,
            availableActions: [],
            catStyle: catStyle,
            catIsRunning: items.contains(where: \.isCurrent),
            hidesSensitiveContent: hideSensitiveContent
        )
    }
}
