import SwiftUI
import UIKit
import MapKit

struct RoutineActionLinkSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let action: PlanRecord

    private var candidates: [PlanRecord] {
        GoalRecordPolicy.visibleGoals(in: model.snapshot.plans)
            .filter {
                $0.span.start <= action.span.start
                    && action.span.end <= $0.span.end
            }
            .sorted { lhs, rhs in
                let left = distanceScore(lhs)
                let right = distanceScore(rhs)
                if left == right { return lhs.span.start < rhs.span.start }
                return left < right
            }
    }

    var body: some View {
        NavigationStack {
            Group {
                if candidates.isEmpty {
                    ContentUnavailableView(
                        "가까운 루틴이 없습니다",
                        systemImage: "repeat.circle",
                        description: Text("액션 시간을 포함하는 루틴을 먼저 만들어 주세요.")
                    )
                } else {
                    List(candidates) { routine in
Group {
                        Button {
                            Task {
                                await model.connectActionItem(
                                    action.id,
                                    toGoal: routine.id
                                )
                                dismiss()
                            }
                        } label: {
                            HStack(spacing: TaptionSpacing.regular) {
                                Image(systemName: isCurrentRoutine(routine)
                                    ? "checkmark.circle.fill"
                                    : "repeat.circle")
                                    .foregroundStyle(
                                        isCurrentRoutine(routine)
                                            ? Color.tpSleepDark
                                            : Color.tpSecondary
                                    )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(routineDisplayTitle(routine))
                                        .font(.taption(size: 10.5, weight: .semibold))
                                        .foregroundStyle(Color.tpInk)
                                        .lineLimit(1)
                                    Text(routineHint(routine))
                                        .font(.taption(size: 8))
                                        .foregroundStyle(Color.tpSecondary)
                                }
                                Spacer(minLength: 4)
                                if candidates.first?.id == routine.id {
                                    Text("가장 가까움")
                                        .font(.taption(size: 7.5, weight: .bold))
                                        .foregroundStyle(Color.tpSleepDark)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    
}
.listRowBackground(Color.tpSurface)
}
.tpListStyle()
                    .listStyle(.plain)
                }
            }
            .navigationTitle("액션을 루틴에 연결")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func distanceScore(_ routine: PlanRecord) -> TimeInterval {
        max(0, routine.span.duration - action.span.duration)
    }

    private func isCurrentRoutine(_ routine: PlanRecord) -> Bool {
        var parentID = action.parentID
        var visited = Set<UUID>()
        while let id = parentID,
              visited.insert(id).inserted,
              let parent = model.snapshot.plans.first(where: { $0.id == id }) {
            if parent.id == routine.id { return true }
            parentID = parent.parentID
        }
        return false
    }

    private func routineDisplayTitle(_ routine: PlanRecord) -> String {
        GoalRecordPolicy.displayTitle(routine.title)
            .replacingOccurrences(of: GoalRecordPolicy.currentPrefix, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func routineHint(_ routine: PlanRecord) -> String {
        let date = routine.span.start.formatted(date: .abbreviated, time: .omitted)
        return "액션 시간이 포함됨 · \(date)"
    }
}

struct GoalActualLinkSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let actual: ActualRecord
    @State private var candidateCache = GoalActualLinkCandidateCache()

    private var routinesOnly: Bool {
        AutomaticRecordTimelineEngine.linksOnlyToRoutine(actual)
    }

    private var candidates: [GoalActualLinkCandidate] {
        candidateCache.values(
            actual: actual,
            timelineRevision: model.timelineRevision,
            plans: model.snapshot.plans,
            routinesOnly: routinesOnly
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if candidates.isEmpty {
                    ContentUnavailableView(
                        routinesOnly ? "연결할 루틴이 없습니다" : "연결할 루틴·액션이 없습니다",
                        systemImage: "scope",
                        description: Text(
                            routinesOnly
                                ? "수면·활동 기록은 시간을 포함하는 루틴에만 연결할 수 있습니다."
                                : "먼저 루틴 탭에서 루틴을 만들어 주세요."
                        )
                    )
                } else {
                    List(candidates) { candidate in
Group {
                        let goal = candidate.plan
                        Button {
                            // The relationship is written to the in-memory
                            // snapshot immediately. Dismiss first so a slow
                            // disk/CloudKit/widget save never blocks the
                            // interaction surface.
                            dismiss()
                            Task {
                                await model.connectActualRecord(
                                    actual.id,
                                    toGoal: goal.id
                                )
                            }
                        } label: {
                            HStack(spacing: TaptionSpacing.regular) {
                                Image(systemName: candidate.isCurrent
                                    ? "checkmark.circle.fill"
                                    : "scope")
                                    .foregroundStyle(
                                        candidate.isCurrent
                                            ? PlanCategory(categoryID: goal.categoryID).darkColor
                                            : Color.tpSecondary
                                    )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(GoalRecordPolicy.isGoal(goal)
                                        ? GoalRecordPolicy.displayTitle(goal.title)
                                            .replacingOccurrences(of: GoalRecordPolicy.currentPrefix, with: "")
                                        : goal.title)
                                        .font(.taption(size: 10.5, weight: .semibold))
                                        .foregroundStyle(Color.tpInk)
                                    Text(candidate.hint)
                                        .font(.taption(size: 8))
                                        .foregroundStyle(Color.tpSecondary)
                                }
                                Spacer(minLength: 4)
                                if candidate.score >= 300 {
                                    Text(GoalRecordPolicy.isGoal(goal) ? "루틴" : "액션")
                                        .font(.taption(size: 7.5, weight: .bold))
                                        .foregroundStyle(Color.tpHealthDark)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    
}
.listRowBackground(Color.tpSurface)
}
.tpListStyle()
                    .listStyle(.plain)
                }
            }
            .navigationTitle(
                routinesOnly ? "기록을 루틴에 연결" : "기록을 루틴·액션에 연결"
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

}

struct GoalActualLinkCandidate: Identifiable {
    let plan: PlanRecord
    let score: Int
    let isCurrent: Bool
    let hint: String

    var id: UUID { plan.id }
}

/// Builds activity-link candidates once per timeline revision. The previous
/// implementation rebuilt a parent dictionary and traversed every candidate's
/// descendants from inside the sort comparator and again for every row. With
/// repeat segments this became quadratic and made the sheet feel frozen.
@MainActor
final class GoalActualLinkCandidateCache {
    private struct Key: Equatable {
        let timelineRevision: UInt64
        let actualID: UUID
        let routinesOnly: Bool
    }

    private var key: Key?
    private var cached: [GoalActualLinkCandidate] = []

    func values(
        actual: ActualRecord,
        timelineRevision: UInt64,
        plans: [PlanRecord],
        routinesOnly: Bool
    ) -> [GoalActualLinkCandidate] {
        let newKey = Key(
            timelineRevision: timelineRevision,
            actualID: actual.id,
            routinesOnly: routinesOnly
        )
        if key == newKey {
            return cached
        }

        let actualSpan = actual.span()
        let byID = Dictionary(
            plans.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let childrenByParent = Dictionary(
            grouping: plans.compactMap { plan in
                plan.parentID.map { ($0, plan) }
            },
            by: \.0
        )

        // Memoize the category set for each subtree. Every plan is visited at
        // most once, rather than rebuilding PlanHierarchy's index per sort
        // comparison.
        var categoriesBySubtree: [UUID: Set<String>] = [:]
        var visiting = Set<UUID>()
        func categories(in id: UUID) -> Set<String> {
            if let cached = categoriesBySubtree[id] {
                return cached
            }
            guard visiting.insert(id).inserted else {
                // Invalid cycles are rejected by the model, but returning the
                // node's own category keeps this UI cache total if a corrupt
                // snapshot is loaded.
                return byID[id].map { [$0.categoryID] } ?? []
            }
            var result = byID[id].map { Set([$0.categoryID]) } ?? []
            for child in childrenByParent[id, default: []] {
                result.formUnion(categories(in: child.1.id))
            }
            visiting.remove(id)
            categoriesBySubtree[id] = result
            return result
        }

        var currentIDs = Set<UUID>()
        if let routineID = actual.routineID {
            currentIDs.insert(routineID)
        }
        var visited = Set<UUID>()
        var parentID = actual.planID
        while let id = parentID,
              visited.insert(id).inserted,
              let plan = byID[id] {
            currentIDs.insert(plan.id)
            parentID = plan.parentID
        }

        let values = plans
            .filter {
                !$0.isFixed
                    && $0.status != .skipped
                    && $0.origin != .repeatRule
                    && $0.origin != .calendar
                    && (!routinesOnly || GoalRecordPolicy.isGoal($0))
            }
            .map { plan -> GoalActualLinkCandidate in
                let overlaps = plan.span.intersection(with: actualSpan) != nil
                let categoryMatches = categories(in: plan.id)
                    .contains(actual.categoryID)
                let isCurrent = currentIDs.contains(plan.id)
                let score: Int
                if isCurrent {
                    score = 1_000
                } else if categoryMatches && overlaps {
                    score = 300
                } else if overlaps {
                    score = 200
                } else if categoryMatches {
                    score = 100
                } else {
                    score = 0
                }
                let hint: String
                switch (categoryMatches, overlaps) {
                case (true, true): hint = "카테고리 · 시간 겹침"
                case (false, true): hint = "시간 겹침"
                case (true, false): hint = "같은 카테고리"
                case (false, false):
                    hint = plan.span.start.formatted(
                        date: .abbreviated,
                        time: .omitted
                    )
                }
                return GoalActualLinkCandidate(
                    plan: plan,
                    score: score,
                    isCurrent: isCurrent,
                    hint: hint
                )
            }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.plan.span.start < rhs.plan.span.start
                }
                return lhs.score > rhs.score
            }

        key = newKey
        cached = values
        return values
    }
}

struct RecordNodeLinkSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let sourceNodeID: String
    let sourceTitle: String

    private var candidates: [PlanRecord] {
        model.snapshot.plans
            .filter {
                !$0.isFixed
                    && $0.status != .skipped
                    && $0.origin != .repeatRule
                    && $0.origin != .calendar
            }
            .sorted {
                if GoalRecordPolicy.isGoal($0) != GoalRecordPolicy.isGoal($1) {
                    return GoalRecordPolicy.isGoal($0)
                }
                return $0.span.start < $1.span.start
            }
    }

    var body: some View {
        NavigationStack {
            Group {
                if candidates.isEmpty {
                    ContentUnavailableView(
                        "연결할 루틴 또는 액션이 없습니다",
                        systemImage: "link.badge.plus"
                    )
                } else {
                    List(candidates) { plan in
Group {
                        Button {
                            // Keep the detail card responsive while the
                            // relationship is persisted in the background.
                            dismiss()
                            Task {
                                await model.connectRecordNode(
                                    sourceNodeID,
                                    to: plan.id
                                )
                            }
                        } label: {
                            HStack(spacing: TaptionSpacing.regular) {
                                Image(systemName: GoalRecordPolicy.isGoal(plan)
                                    ? "repeat.circle"
                                    : "checklist")
                                    .foregroundStyle(
                                        GoalRecordPolicy.isGoal(plan)
                                            ? Color.tpSleepDark
                                            : Color.tpInk
                                    )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(GoalRecordPolicy.isGoal(plan)
                                        ? GoalRecordPolicy.displayTitle(plan.title)
                                        : plan.title)
                                        .font(.taption(size: 10, weight: .semibold))
                                    Text(
                                        "\(plan.span.start.formatted(date: .abbreviated, time: .shortened)) · "
                                            + (GoalRecordPolicy.isGoal(plan)
                                                ? "루틴"
                                                : "액션")
                                    )
                                    .font(.taption(size: 8))
                                    .foregroundStyle(Color.tpSecondary)
                                }
                                Spacer(minLength: 4)
                            }
                        }
                        .buttonStyle(.plain)
                    
}
.listRowBackground(Color.tpSurface)
}
.tpListStyle()
                    .listStyle(.plain)
                }
            }
            .navigationTitle("\(sourceTitle) 연결")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
