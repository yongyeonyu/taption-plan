import SwiftUI

enum GoalDetailMode: Equatable {
    case habit
    case project
    case empty
}

struct GoalHabitDay: Identifiable, Equatable {
    var id: Date { date }
    var date: Date
    var planned: TimeInterval
    var actual: TimeInterval
}

struct GoalDetailSnapshot: Equatable {
    var mode: GoalDetailMode
    var descendants: [PlanRecord]
    var actualMatches: [GoalActualMatch]
    var plannedDuration: TimeInterval
    var actualDuration: TimeInterval
    var weekDays: [GoalHabitDay]
    var missedDays: [GoalHabitDay]
    var nextPlan: PlanRecord?
    var upcomingPlans: [PlanRecord]
    var blockerMemos: [ActionMemo]
    var fourWeekActuals: [TimeInterval]
    var evidence: [String]
}

enum GoalDetailEngine {
    static func make(
        goal: PlanRecord,
        plans: [PlanRecord],
        actuals: [ActualRecord],
        memos: [ActionMemo] = [],
        referenceDate: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> GoalDetailSnapshot {
        let descendants = (try? PlanHierarchy.descendants(
            of: goal.id,
            in: plans
        )) ?? []
        let hasRepeat = goal.repeatRules?.isEmpty == false
            || descendants.contains(where: { $0.origin == .repeatRule })
        let manualChildren = descendants.filter { $0.origin != .repeatRule }
        let mode: GoalDetailMode = hasRepeat
            ? .habit
            : manualChildren.isEmpty ? .empty : .project
        let scopedIDs = Set([goal.id] + descendants.map(\.id))
        let actualMatches = GoalActivityMatchingEngine.matches(
            goal: goal,
            plans: plans,
            actuals: actuals,
            asOf: referenceDate
        )
        let scopedActuals = actualMatches.map(\.actual)
        let plannedLeaves = descendants.isEmpty
            ? [goal]
            : descendants.filter { child in
                !descendants.contains(where: { $0.parentID == child.id })
            }
        let plannedDuration = TimeSpan.unionDuration(plannedLeaves.map(\.span))
        let actualDuration = TimeSpan.unionDuration(
            scopedActuals.map { $0.span(asOf: referenceDate) }
        )
        let week = calendar.dateInterval(
            of: .weekOfYear,
            for: referenceDate
        ) ?? DateInterval(
            start: calendar.startOfDay(for: referenceDate),
            duration: 7 * 86_400
        )
        let weekDays = (0..<7).compactMap { offset -> GoalHabitDay? in
            guard let date = calendar.date(
                byAdding: .day,
                value: offset,
                to: week.start
            ) else { return nil }
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: date)
                ?? date.addingTimeInterval(86_400)
            let day = TimeSpan(start: date, end: dayEnd)
            return GoalHabitDay(
                date: date,
                planned: TimeSpan.unionDuration(
                    plannedLeaves.compactMap { $0.span.intersection(with: day) }
                ),
                actual: TimeSpan.unionDuration(
                    scopedActuals.compactMap {
                        $0.span(asOf: referenceDate).intersection(with: day)
                    }
                )
            )
        }
        let fourWeekActuals = (0..<4).reversed().map { offset in
            let end = calendar.date(
                byAdding: .weekOfYear,
                value: 1 - offset,
                to: week.start
            ) ?? week.end
            let start = calendar.date(
                byAdding: .day,
                value: -7,
                to: end
            ) ?? end.addingTimeInterval(-7 * 86_400)
            let span = TimeSpan(start: start, end: end)
            return TimeSpan.unionDuration(
                scopedActuals.compactMap {
                    $0.span(asOf: referenceDate).intersection(with: span)
                }
            )
        }
        let upcomingPlans = descendants
            .filter { $0.span.end >= referenceDate && $0.status != .skipped }
            .sorted { $0.span.start < $1.span.start }
        let nextPlan = upcomingPlans.first
        let blockerMemos = memos
            .filter {
                $0.planID.map(scopedIDs.contains) == true
                    && $0.kind == .blocker
                    && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .sorted { $0.createdAt > $1.createdAt }
        let missedDays = weekDays.filter {
            $0.planned > 0 && $0.actual < 60
        }
        let evidence = Array(Set(scopedActuals.map { actual in
            switch actual.source {
            case .healthKit: "HealthKit"
            case .appleWatch: "Apple Watch"
            case .motion: "iPhone Core Motion"
            case .location: "iPhone 위치·센서"
            case .timer: "앱 타이머"
            case .manual: "직접 기록"
            case .calendar: "캘린더"
            case .photo: "사진"
            case .media: "미디어 재생"
            case .call: "통화"
            case .appUsage: "앱 사용시간"
            }
        })).sorted()
        return GoalDetailSnapshot(
            mode: mode,
            descendants: descendants,
            actualMatches: actualMatches,
            plannedDuration: plannedDuration,
            actualDuration: actualDuration,
            weekDays: weekDays,
            missedDays: missedDays,
            nextPlan: nextPlan,
            upcomingPlans: Array(upcomingPlans.prefix(3)),
            blockerMemos: Array(blockerMemos.prefix(3)),
            fourWeekActuals: fourWeekActuals,
            evidence: evidence
        )
    }
}
