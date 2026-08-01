import SwiftUI

struct GoalsView: View {
    @Bindable var model: AppModel

    private var goals: [GoalCard] {
        let roots = GoalRecordPolicy.visibleGoals(in: model.snapshot.plans)

        let aggregation = TimelineAggregationEngine()
        return roots.map { plan in
            let descendants =
                (try? PlanHierarchy.descendants(
                    of: plan.id,
                    in: model.snapshot.plans
                )) ?? []
            let repeatSegmentCount = descendants.filter {
                $0.origin == .repeatRule
            }.count
            let manualChildCount = descendants.count - repeatSegmentCount
            let rollup = try? aggregation.rollup(
                goalID: plan.id,
                plans: model.snapshot.plans,
                actuals: model.snapshot.actuals
            )
            let planned = rollup?.plannedDuration ?? plan.span.duration
            let actual = rollup?.actualDuration ?? 0
            let progress = planned > 0
                ? min(1, max(0, actual / planned))
                : 0
            return GoalCard(
                id: plan.id,
                planID: plan.id,
                title: goalDisplayTitle(plan.title),
                period: periodText(plan.span),
                leftDetail: goalLeftDetail(
                    manualChildCount: manualChildCount,
                    repeatSegmentCount: repeatSegmentCount
                ),
                rightDetail: "실제 \(durationText(actual)) / 계획 \(durationText(planned))",
                repeatSummary: GoalRepeatRuleFormatter.summary(
                    plan.repeatRules
                ),
                progress: progress,
                category: PlanCategory(categoryID: plan.categoryID)
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            DraftTopBar(title: "목표", trailing: "")

            List {
                if goals.isEmpty {
                    emptyGoalState
                        .goalListRow()
                }

                ForEach(goals) { goal in
                    goalCardView(goal)
                        .goalListRow()
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                deleteGoal(goal)
                            } label: {
                                Label("삭제", systemImage: "trash")
                            }
                            .tint(.red)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button {
                                editGoal(goal)
                            } label: {
                                Label("수정", systemImage: "pencil")
                            }
                            .tint(Color.tpInk)
                        }
                }

            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.tpBackground)
        }
    }

    private func goalCardView(_ goal: GoalCard) -> some View {
        let childRows = childTimelineRows(for: goal.planID)
        let repeatSegmentCount = repeatSegmentCount(for: goal.planID)
        return VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(goal.category.darkColor)
                        .frame(width: 10, height: 10)
                    Text(goal.title)
                        .font(.taption(size: 13.5, weight: .bold))
                        .foregroundStyle(Color.tpInk)
                    Spacer(minLength: 4)
                    Text(goal.period)
                        .font(.taption(size: 10.5))
                        .foregroundStyle(Color.tpSecondary)
                }

                HStack {
                    if goal.title.contains("운동") {
                        Image(systemName: "heart.text.square")
                            .font(.taption(size: 9))
                    }
                    Text(goal.leftDetail)
                    Spacer(minLength: 4)
                    Text(goal.rightDetail)
                        .fontWeight(.semibold)
                }
                .font(.taption(size: 10.5))
                .foregroundStyle(Color.tpSecondary)
                .padding(.top, 8)

                if let repeatSummary = goal.repeatSummary {
                    Label(repeatSummary, systemImage: "repeat")
                        .font(.taption(size: 8.5, weight: .bold))
                        .foregroundStyle(Color.tpInk.opacity(0.66))
                        .lineLimit(2)
                        .padding(.top, 5)
                }

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(red: 0.93, green: 0.93, blue: 0.94))
                        Capsule()
                            .fill(goal.category.darkColor)
                            .frame(width: proxy.size.width * goal.progress)
                    }
                }
                .frame(height: 6)
                .padding(.top, 6)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if let planID = goal.planID {
                    model.openGoalDetail(planID)
                }
            }

            goalTimelineSection(
                rows: childRows,
                category: goal.category,
                repeatSegmentCount: repeatSegmentCount
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .draftCard()
    }

    private func deleteGoal(_ goal: GoalCard) {
        guard let planID = goal.planID else { return }
        Task { await model.deletePlan(planID) }
    }

    private func editGoal(_ goal: GoalCard) {
        guard let planID = goal.planID else { return }
        model.planEditorRequest = PlanEditorRequest(id: planID)
    }

    private var emptyGoalState: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("아직 목표가 없습니다")
                .font(.taption(size: 12.5, weight: .bold))
                .foregroundStyle(Color.tpInk)
            Text("새 목표를 추가하거나 시작 구성에서 상황별 목표를 만들 수 있습니다.")
                .font(.taption(size: 9))
                .foregroundStyle(Color.tpSecondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            Color.white.opacity(0.78),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.tpLine.opacity(0.75), lineWidth: 0.6)
        }
    }

    @ViewBuilder
    private func goalTimelineSection(
        rows: [GoalChildPlanRow],
        category: PlanCategory,
        repeatSegmentCount: Int
    ) -> some View {
        if !rows.isEmpty || repeatSegmentCount > 0 {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("계획 타임라인")
                        .font(.taption(size: 9, weight: .semibold))
                        .foregroundStyle(Color.tpSecondary)

                    Spacer(minLength: 4)

                    if let summary = childTimelineSummary(
                        rows,
                        repeatSegmentCount: repeatSegmentCount
                    ) {
                        Text(summary)
                            .font(.taption(size: 7.5, weight: .bold))
                            .foregroundStyle(Color.tpInk.opacity(0.58))
                            .lineLimit(1)
                    }
                }

                ForEach(rows) { row in
                    GoalChildPlanRowView(
                        row: row,
                        category: category
                    ) {
                        model.planEditorRequest = PlanEditorRequest(id: row.id)
                    }
                }

                if repeatSegmentCount > 0 {
                    Label(
                        "반복 세그먼트 \(repeatSegmentCount)개는 시간표 간트에 표시됩니다.",
                        systemImage: "rectangle.split.3x1"
                    )
                    .font(.taption(size: 8.5, weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color(red: 0.965, green: 0.965, blue: 0.975),
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                }
            }
        } else {
            Text("아직 계획이 없습니다. ‘+’로 하위 계획을 추가하세요.")
                .font(.taption(size: 8.5))
                .foregroundStyle(Color.tpSecondary)
        }
    }

    private func childPlans(for goalID: UUID?) -> [PlanRecord] {
        guard let goalID else { return [] }
        return PlanHierarchy.children(of: goalID, in: model.snapshot.plans)
            .filter { $0.origin != .repeatRule }
            .sorted { $0.span.start < $1.span.start }
    }

    private func repeatSegmentCount(for goalID: UUID?) -> Int {
        guard let goalID else { return 0 }
        return ((try? PlanHierarchy.descendants(
            of: goalID,
            in: model.snapshot.plans
        )) ?? [])
        .filter { $0.origin == .repeatRule }
        .count
    }

    private func childTimelineRows(for goalID: UUID?) -> [GoalChildPlanRow] {
        let plans = childPlans(for: goalID)
        let duplicateGroups = Dictionary(
            grouping: plans,
            by: childPlanDuplicateKey
        )
        var duplicateOrdinals: [UUID: Int] = [:]

        for group in duplicateGroups.values where group.count > 1 {
            for (index, plan) in group.sorted(by: childPlanSort).enumerated() {
                duplicateOrdinals[plan.id] = index + 1
            }
        }

        return plans.map { plan in
            let key = childPlanDuplicateKey(plan)
            let duplicateCount = duplicateGroups[key]?.count ?? 1
            let overlapCount = plans.filter { other in
                other.id != plan.id
                    && plan.span.intersection(with: other.span) != nil
            }.count

            return GoalChildPlanRow(
                id: plan.id,
                title: plan.title,
                timeText: childPlanTimeText(plan.span),
                detailText: childPlanDetailText(plan),
                duplicateCount: duplicateCount,
                duplicateOrdinal: duplicateOrdinals[plan.id],
                overlapCount: overlapCount
            )
        }
    }

    private func childTimelineSummary(
        _ rows: [GoalChildPlanRow],
        repeatSegmentCount: Int
    ) -> String? {
        let duplicateCount = rows.filter(\.isDuplicate).count
        let overlapCount = rows.filter(\.hasOverlap).count
        let parts = [
            repeatSegmentCount > 0 ? "반복 \(repeatSegmentCount)개" : nil,
            duplicateCount > 0 ? "중복 \(duplicateCount)건" : nil,
            overlapCount > 0 ? "겹침 \(overlapCount)건" : nil,
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func goalLeftDetail(
        manualChildCount: Int,
        repeatSegmentCount: Int
    ) -> String {
        if repeatSegmentCount > 0 {
            let manualText = manualChildCount > 0
                ? " · 계획 \(manualChildCount)개"
                : ""
            return "반복 세그먼트 \(repeatSegmentCount)개\(manualText)"
        }
        return "하위 \(manualChildCount)개 · 월→주→일"
    }

    private func childPlanDuplicateKey(_ plan: PlanRecord) -> String {
        plan.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func childPlanSort(_ lhs: PlanRecord, _ rhs: PlanRecord) -> Bool {
        if lhs.span.start == rhs.span.start {
            return lhs.span.end < rhs.span.end
        }
        return lhs.span.start < rhs.span.start
    }

    private func childPlanTimeText(_ span: TimeSpan) -> String {
        let start = span.start.formatted(.dateTime.hour().minute())
        let end = span.end.formatted(.dateTime.hour().minute())
        return "\(start)~\(end)"
    }

    private func childPlanDetailText(_ plan: PlanRecord) -> String {
        let parts = [
            plan.middleCategoryName,
            plan.subCategoryName,
        ].compactMap { value -> String? in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if !parts.isEmpty {
            return parts.joined(separator: " · ")
        }
        return PlanCategory(categoryID: plan.categoryID).rawValue
    }

    private func periodText(_ span: TimeSpan) -> String {
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDate(span.start, equalTo: span.end, toGranularity: .month) {
            return span.start.formatted(.dateTime.month().day())
                + " – "
                + span.end.formatted(.dateTime.day())
        }
        return span.start.formatted(.dateTime.month().day())
            + " – "
            + span.end.formatted(.dateTime.month().day())
    }

    private func durationText(_ interval: TimeInterval) -> String {
        let totalMinutes = max(0, Int(interval / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return "\(minutes)m" }
        if minutes == 0 { return "\(hours)h" }
        return "\(hours)h \(minutes)m"
    }

    private func goalDisplayTitle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.hasPrefix("목표:") {
            return trimmed
        }
        return "목표:\(trimmed)"
    }
}

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
    var plannedDuration: TimeInterval
    var actualDuration: TimeInterval
    var weekDays: [GoalHabitDay]
    var nextPlan: PlanRecord?
    var fourWeekActuals: [TimeInterval]
    var evidence: [String]
}

enum GoalDetailEngine {
    static func make(
        goal: PlanRecord,
        plans: [PlanRecord],
        actuals: [ActualRecord],
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
        let scopedActuals = matchedActuals(
            goal: goal,
            descendants: descendants,
            actuals: actuals,
            scopedIDs: scopedIDs
        )
        let plannedLeaves = descendants.isEmpty
            ? [goal]
            : descendants.filter { child in
                !descendants.contains(where: { $0.parentID == child.id })
            }
        let plannedDuration = unionDuration(plannedLeaves.map(\.span))
        let actualDuration = unionDuration(
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
                planned: unionDuration(
                    plannedLeaves.compactMap { $0.span.intersection(with: day) }
                ),
                actual: unionDuration(
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
            return unionDuration(
                scopedActuals.compactMap {
                    $0.span(asOf: referenceDate).intersection(with: span)
                }
            )
        }
        let nextPlan = descendants
            .filter { $0.span.end >= referenceDate && $0.status != .skipped }
            .sorted { $0.span.start < $1.span.start }
            .first
        let evidence = Array(Set(scopedActuals.map { actual in
            switch actual.source {
            case .healthKit: "HealthKit"
            case .appleWatch: "Apple Watch"
            case .location: "iPhone 위치·센서"
            case .timer: "앱 타이머"
            case .manual: "직접 기록"
            case .calendar: "캘린더"
            case .photo: "사진"
            }
        })).sorted()
        return GoalDetailSnapshot(
            mode: mode,
            descendants: descendants,
            plannedDuration: plannedDuration,
            actualDuration: actualDuration,
            weekDays: weekDays,
            nextPlan: nextPlan,
            fourWeekActuals: fourWeekActuals,
            evidence: evidence
        )
    }

    private static func matchedActuals(
        goal: PlanRecord,
        descendants: [PlanRecord],
        actuals: [ActualRecord],
        scopedIDs: Set<UUID>
    ) -> [ActualRecord] {
        let repeatPlans = descendants.filter { $0.origin == .repeatRule }
        return actuals.filter { actual in
            if let planID = actual.planID, scopedIDs.contains(planID) {
                return true
            }
            guard actual.planID == nil,
                  actual.categoryID == goal.categoryID else { return false }
            let actualSpan = actual.span()
            return repeatPlans.contains {
                $0.span.intersection(with: actualSpan) != nil
            }
        }
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

struct GoalDetailView: View {
    @Bindable var model: AppModel

    private var goal: PlanRecord? {
        guard let id = model.selectedGoalPlanID else { return nil }
        return model.snapshot.plans.first { $0.id == id }
    }

    private var detail: GoalDetailSnapshot? {
        goal.map {
            GoalDetailEngine.make(
                goal: $0,
                plans: model.snapshot.plans,
                actuals: model.snapshot.actuals
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            detailHeader
            if let goal, let detail {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 10) {
                        summaryCard(goal: goal, detail: detail)
                        switch detail.mode {
                        case .habit:
                            habitDashboard(goal: goal, detail: detail)
                        case .project:
                            projectRoadmap(goal: goal, detail: detail)
                        case .empty:
                            emptyDashboard(goal: goal)
                        }
                        actionButtons(goal: goal)
                    }
                    .padding(12)
                }
                .background(Color.tpBackground)
            } else {
                ContentUnavailableView(
                    "목표를 찾을 수 없습니다",
                    systemImage: "scope"
                )
            }
        }
    }

    private var detailHeader: some View {
        HStack(spacing: 8) {
            Button {
                model.closeGoalDetail()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.taption(size: 15, weight: .bold))
            }
            Text(goal?.title ?? "목표 상세")
                .font(.taption(size: 16, weight: .bold))
                .lineLimit(1)
            Spacer()
            if let goal {
                Button("편집") {
                    model.planEditorRequest = PlanEditorRequest(id: goal.id)
                }
                .font(.taption(size: 10, weight: .bold))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.tpLine).frame(height: 0.5)
        }
    }

    private func summaryCard(
        goal: PlanRecord,
        detail: GoalDetailSnapshot
    ) -> some View {
        let progress = detail.plannedDuration > 0
            ? min(1, detail.actualDuration / detail.plannedDuration)
            : 0
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(
                    detail.mode == .habit ? "습관 대시보드" : "목표 로드맵",
                    systemImage: detail.mode == .habit
                        ? "repeat.circle.fill"
                        : "point.topleft.down.to.point.bottomright.curvepath"
                )
                .font(.taption(size: 10, weight: .bold))
                Spacer()
                Text(dDayText(goal.span.end))
                    .font(.taption(size: 9, weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
            }
            HStack {
                metric("계획", duration(detail.plannedDuration))
                metric("실제", duration(detail.actualDuration))
                metric("진행", "\(Int(progress * 100))%")
            }
            ProgressView(value: progress)
                .tint(PlanCategory(categoryID: goal.categoryID).darkColor)
        }
        .padding(12)
        .draftCard()
    }

    private func habitDashboard(
        goal: PlanRecord,
        detail: GoalDetailSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if let next = detail.nextPlan {
                Label("다음 실행", systemImage: "clock.badge.checkmark")
                    .font(.taption(size: 10, weight: .bold))
                Text("\(next.span.start.formatted(date: .abbreviated, time: .shortened)) → \(next.span.end.formatted(date: .omitted, time: .shortened))")
                    .font(.taption(size: 9, weight: .semibold))
            }
            Text("이번 주 계획과 실제")
                .font(.taption(size: 10, weight: .bold))
            ForEach(detail.weekDays) { day in
                HStack {
                    Text(day.date.formatted(.dateTime.weekday(.abbreviated)))
                        .frame(width: 28, alignment: .leading)
                    Text("계획 \(duration(day.planned))")
                    Spacer()
                    Text("실제 \(duration(day.actual))")
                        .foregroundStyle(day.actual > 0 ? Color.tpInk : Color.tpSecondary)
                }
                .font(.taption(size: 8.5, weight: .semibold))
            }
            Text("4주 실제 추세")
                .font(.taption(size: 9, weight: .bold))
            HStack(alignment: .bottom, spacing: 8) {
                let maximum = max(detail.fourWeekActuals.max() ?? 1, 1)
                ForEach(Array(detail.fourWeekActuals.enumerated()), id: \.offset) { index, value in
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(PlanCategory(categoryID: goal.categoryID).darkColor.opacity(0.7))
                            .frame(height: max(4, 45 * value / maximum))
                        Text("\(index + 1)주")
                            .font(.taption(size: 7))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            if !detail.evidence.isEmpty {
                Label(
                    detail.evidence.joined(separator: " · "),
                    systemImage: "applewatch"
                )
                .font(.taption(size: 8, weight: .semibold))
                .foregroundStyle(Color.tpSecondary)
            }
        }
        .padding(12)
        .draftCard()
    }

    private func projectRoadmap(
        goal: PlanRecord,
        detail: GoalDetailSnapshot
    ) -> some View {
        let manual = detail.descendants.filter { $0.origin != .repeatRule }
        return VStack(alignment: .leading, spacing: 9) {
            Label("목표 내리기", systemImage: "arrow.down.right.and.arrow.up.left")
                .font(.taption(size: 10, weight: .bold))
            ForEach(manual) { plan in
                HStack(spacing: 7) {
                    Circle()
                        .fill(PlanCategory(categoryID: plan.categoryID).darkColor)
                        .frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plan.title)
                            .font(.taption(size: 9, weight: .bold))
                        Text(plan.span.start.formatted(date: .abbreviated, time: .shortened))
                            .font(.taption(size: 7.5))
                            .foregroundStyle(Color.tpSecondary)
                    }
                    Spacer()
                    Image(systemName: plan.status == .completed
                        ? "checkmark.circle.fill"
                        : "circle")
                }
                .padding(.leading, indentation(for: plan, in: manual))
            }
        }
        .padding(12)
        .draftCard()
    }

    private func emptyDashboard(goal: PlanRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("첫 실행 계획이 필요합니다", systemImage: "flag.checkered")
                .font(.taption(size: 10, weight: .bold))
            Text("목표를 월·주·일 계획으로 내려보내면 실제 기록이 다시 이 목표로 합쳐집니다.")
                .font(.taption(size: 8.5))
                .foregroundStyle(Color.tpSecondary)
            Button("첫 하위 계획 만들기") {
                presentChildPlan(for: goal.id)
            }
            .font(.taption(size: 9, weight: .bold))
            .buttonStyle(.borderedProminent)
            .tint(.tpInk)
        }
        .padding(12)
        .draftCard()
    }

    private func actionButtons(goal: PlanRecord) -> some View {
        VStack(spacing: 7) {
            Button {
                presentChildPlan(for: goal.id)
            } label: {
                Label("하위 계획 내리기", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.tpInk)
            HStack {
                Button("시간표에서 보기") { model.openGroup(goal.id) }
                Button("메모") { model.openMemo(for: goal.id) }
                Button("반복 설정") {
                    model.planEditorRequest = PlanEditorRequest(id: goal.id)
                }
            }
            .font(.taption(size: 8.5, weight: .bold))
            .buttonStyle(.bordered)
        }
    }

    private func presentChildPlan(for goalID: UUID) {
        model.addPlanContext = .child(goalID)
        model.isAddPlanPresented = true
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(Color.tpSecondary)
            Text(value).fontWeight(.bold)
        }
        .font(.taption(size: 9))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func duration(_ value: TimeInterval) -> String {
        let minutes = max(0, Int(value / 60))
        return minutes >= 60
            ? "\(minutes / 60)시간 \(minutes % 60)분"
            : "\(minutes)분"
    }

    private func dDayText(_ date: Date) -> String {
        let days = Calendar.autoupdatingCurrent.dateComponents(
            [.day],
            from: Calendar.autoupdatingCurrent.startOfDay(for: .now),
            to: Calendar.autoupdatingCurrent.startOfDay(for: date)
        ).day ?? 0
        return days >= 0 ? "D-\(days)" : "D+\(-days)"
    }

    private func indentation(
        for plan: PlanRecord,
        in plans: [PlanRecord]
    ) -> CGFloat {
        var depth = 0
        var parentID = plan.parentID
        while let id = parentID,
              let parent = plans.first(where: { $0.id == id }) {
            depth += 1
            parentID = parent.parentID
        }
        return CGFloat(min(depth, 3) * 12)
    }
}

private struct GoalCard: Identifiable {
    let id: UUID
    let planID: UUID?
    let title: String
    let period: String
    let leftDetail: String
    let rightDetail: String
    let repeatSummary: String?
    let progress: CGFloat
    let category: PlanCategory
}

private extension View {
    func goalListRow() -> some View {
        self
            .listRowSeparator(.hidden)
            .listRowInsets(
                EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14)
            )
            .listRowBackground(Color.clear)
    }
}

private struct GoalChildPlanRow: Identifiable {
    let id: UUID
    let title: String
    let timeText: String
    let detailText: String
    let duplicateCount: Int
    let duplicateOrdinal: Int?
    let overlapCount: Int

    var isDuplicate: Bool {
        duplicateCount > 1
    }

    var hasOverlap: Bool {
        overlapCount > 0
    }
}

private struct GoalChildPlanRowView: View {
    let row: GoalChildPlanRow
    let category: PlanCategory
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Text(row.timeText)
                    .font(.taption(size: 8.5, weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
                    .monospacedDigit()
                    .frame(width: 75, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.taption(size: 8.8, weight: .semibold))
                        .foregroundStyle(Color.tpInk)
                        .lineLimit(1)

                    Text(row.detailText)
                        .font(.taption(size: 7.5, weight: .semibold))
                        .foregroundStyle(Color.tpSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if row.isDuplicate {
                    badge(
                        "중복 \(row.duplicateOrdinal ?? 1)/\(row.duplicateCount)",
                        fill: Color(red: 0.91, green: 0.87, blue: 0.96),
                        ink: Color(red: 0.37, green: 0.29, blue: 0.54)
                    )
                }

                if row.hasOverlap {
                    badge(
                        "겹침 \(row.overlapCount)",
                        fill: Color(red: 1.0, green: 0.86, blue: 0.77),
                        ink: Color(red: 0.61, green: 0.23, blue: 0.12)
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(rowStroke, lineWidth: row.hasOverlap ? 1.1 : 0.6)
            }
        }
        .buttonStyle(.plain)
    }

    private var rowBackground: Color {
        if row.hasOverlap {
            return Color(red: 1.0, green: 0.95, blue: 0.91)
        }
        if row.isDuplicate {
            return Color(red: 0.97, green: 0.95, blue: 0.99)
        }
        return Color.white.opacity(0.78)
    }

    private var rowStroke: Color {
        if row.hasOverlap {
            return Color(red: 0.88, green: 0.46, blue: 0.26).opacity(0.70)
        }
        if row.isDuplicate {
            return Color(red: 0.52, green: 0.43, blue: 0.68).opacity(0.42)
        }
        return category.darkColor.opacity(0.10)
    }

    private func badge(
        _ title: String,
        fill: Color,
        ink: Color
    ) -> some View {
        Text(title)
            .font(.taption(size: 7.2, weight: .bold))
            .foregroundStyle(ink)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(fill, in: Capsule())
    }
}

#Preview {
    GoalsView(model: AppModel())
}
