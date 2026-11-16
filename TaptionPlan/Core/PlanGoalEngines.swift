import Foundation
import TaptionPlanCore

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
        asOf: Date = .now,
        scope: RecordAnalysisScope = .legacy
    ) -> ReviewReport {
        report(
            over: [aggregation.interval(for: level, containing: date)],
            plans: plans,
            actuals: actuals,
            weather: weather,
            photos: photos,
            memos: memos,
            asOf: asOf,
            scope: scope
        )
    }

    /// 떨어져 있는 여러 칸을 한 번에 본다. 칸마다 잰 값을 더하므로 사이의
    /// 빈 시간은 어디에도 들어가지 않는다. 구간은 서로 겹치지 않는다고 본다.
    func report(
        over spans: [TimeSpan],
        plans: [PlanRecord],
        actuals: [ActualRecord],
        weather: [WeatherContext],
        photos: [PhotoMoment],
        memos: [ActionMemo],
        asOf: Date = .now,
        scope: RecordAnalysisScope = .legacy
    ) -> ReviewReport {
        let ordered = spans.sorted { $0.start < $1.start }
        guard let first = ordered.first, let last = ordered.last else {
            return ReviewReport(
                span: TimeSpan(start: asOf, end: asOf),
                plannedDuration: 0,
                actualDuration: 0,
                categories: [],
                unplannedActualDuration: 0,
                contexts: []
            )
        }
        let hull = TimeSpan(start: first.start, end: last.end)

        let scopedPlans: [PlanRecord]
        let scopedActuals: [ActualRecord]
        switch scope {
        case .legacy:
            scopedPlans = plans
            scopedActuals = actuals
        case .canonical:
            scopedPlans = plans.map { plan in
                var value = plan
                value.categoryID = RecordAnalysisCategoryNormalizer.categoryID(
                    for: plan.categoryID
                )
                return value
            }
            scopedActuals = actuals.map { actual in
                var value = actual
                value.categoryID = RecordAnalysisCategoryNormalizer.categoryID(
                    for: actual.categoryID,
                    title: actual.title,
                    behavior: actual.behavior
                )
                return value
            }
        }

        var planned: [String: TimeInterval] = [:]
        var actual: [String: TimeInterval] = [:]
        for span in ordered {
            let bucket = aggregation.summary(
                of: span,
                plans: scopedPlans,
                actuals: scopedActuals,
                photos: photos,
                asOf: asOf
            )
            for category in bucket.categories {
                planned[category.categoryID, default: 0] += category.planned
                actual[category.categoryID, default: 0] += category.actual
            }
        }
        let categories = Set(planned.keys).union(actual.keys)
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

        let knownPlanIDs = Set(scopedPlans.map(\.id))
        let unplanned = scopedActuals.reduce(0) { partial, actual in
            if let planID = actual.planID, knownPlanIDs.contains(planID) {
                return partial
            }
            let measured = actual.span(asOf: asOf)
            return partial + ordered.reduce(0) {
                $0 + (measured.intersection(with: $1)?.duration ?? 0)
            }
        }

        func isSelected(_ date: Date) -> Bool {
            ordered.contains { $0.contains(date) }
        }

        var contexts: [ReviewContext] = weather
            .filter { isSelected($0.observedAt) }
            .map {
                let airQualityText = $0.airQuality.map {
                    " · 미세 \($0.overallGrade.displayName) (PM10 \(Int($0.pm10MicrogramsPerCubicMeter.rounded())) / PM2.5 \(Int($0.pm25MicrogramsPerCubicMeter.rounded())))"
                } ?? ""
                return ReviewContext(
                    id: "weather-\($0.id.uuidString)",
                    date: $0.observedAt,
                    symbolName: $0.symbolName,
                    text: "\($0.condition) · \(AppRegion.current.temperature(celsius: $0.temperatureCelsius))°\(airQualityText)",
                    linkedPlanID: nil
                )
            }

        let visiblePhotos = photos.filter {
            isSelected($0.capturedAt) && !$0.isHiddenFromTimeline
        }
        if let first = visiblePhotos.first {
            contexts.append(
                ReviewContext(
                    id: "photos-\(hull.start.timeIntervalSince1970)",
                    date: first.capturedAt,
                    symbolName: "photo",
                    text: "기억으로 남긴 사진 \(visiblePhotos.count)장",
                    linkedPlanID: first.linkedPlanID
                )
            )
        }

        // 메모가 놓이는 자리는 적은 시각이 아니라 그 메모가 말하는 시각이다.
        // 오늘 적은 지난 화요일 이야기는 지난 화요일에 남는다.
        contexts.append(contentsOf: memos
            .filter {
                $0.isHighlightedInReview && isSelected($0.occurredAt)
            }
            .map {
                ReviewContext(
                    id: "memo-\($0.id.uuidString)",
                    date: $0.occurredAt,
                    symbolName: "note.text",
                    text: $0.text,
                    linkedPlanID: $0.planID
                )
            })

        return ReviewReport(
            span: hull,
            plannedDuration: categories.reduce(0) { $0 + $1.planned },
            actualDuration: categories.reduce(0) { $0 + $1.actual },
            categories: categories,
            unplannedActualDuration: unplanned,
            contexts: contexts.sorted { $0.date < $1.date }
        )
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
        let covered = TimeSpan.unionDuration(spans)
        return min(1, max(0, covered / plan.span.duration))
    }
}
