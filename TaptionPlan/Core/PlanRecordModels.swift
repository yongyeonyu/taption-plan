import Foundation
import TaptionPlanCore

// `PlanStatus`·`PlanOrigin`·`PlanRecord`·`GoalRepeatRule`은 `TaptionPlanCore/Domain/PlanRecord.swift`에 있다.

enum GoalCategoryPolicy {
    static let systemSelectableCategoryIDs: Set<String> = [
        "movement",
        "location",
        "sleep",
        "activity",
        "appUsage",
    ]
}

extension PlanRecord {
    /// Plans use the same semantic vocabulary as automatic records.  The
    /// routine/action distinction remains an origin relationship in the graph.
    var semanticLevel: TimelineSemanticLevel {
        middleCategoryName?.isEmpty == false
            || subCategoryName?.isEmpty == false
            ? .activity
            : .dayPhase
    }

    var sourceKind: TimelineSourceKind {
        GoalRecordPolicy.isGoal(self) ? .routine : .action
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
