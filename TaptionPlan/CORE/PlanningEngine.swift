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

struct TimelineAggregationEngine: Sendable {
    var calendar: Calendar

    init(calendar: Calendar = .autoupdatingCurrent) {
        self.calendar = calendar
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
        let scopedIDs = Set(scopedPlans.map(\.id))

        let plannedByCategory = accumulate(
            scopedPlans.map { ($0.categoryID, $0.span) },
            inside: goal.span
        )
        let actualByCategory = accumulate(
            actuals
                .filter { actual in
                    guard let planID = actual.planID else { return false }
                    return scopedIDs.contains(planID)
                }
                .map { ($0.categoryID, $0.span(asOf: asOf)) },
            inside: goal.span
        )

        return GoalRollup(
            goalID: goalID,
            descendantCount: descendants.count,
            plannedDuration: plannedByCategory.values.reduce(0, +),
            actualDuration: actualByCategory.values.reduce(0, +),
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
        entries.reduce(into: [:]) { partial, entry in
            guard let overlap = entry.1.intersection(with: bucket) else { return }
            partial[entry.0, default: 0] += overlap.duration
        }
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
                ReviewContext(
                    id: "weather-\($0.id.uuidString)",
                    date: $0.observedAt,
                    symbolName: $0.symbolName,
                    text: "\($0.condition) · \(Int($0.temperatureCelsius.rounded()))°",
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
        let hasCurrent = items.contains(where: \.isCurrent)
        return WidgetSnapshot(
            generatedAt: now,
            viewport: viewport,
            items: items,
            availableActions: hasCurrent
                ? [.complete, .postponeThirtyMinutes, .moveToNextFreeTime]
                : [],
            catStyle: catStyle,
            catIsRunning: hasCurrent,
            hidesSensitiveContent: hideSensitiveContent
        )
    }
}
