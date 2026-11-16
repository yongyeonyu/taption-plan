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
            DraftTopBar(title: "루틴", trailing: "")

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
                            .tint(Color.tpPrimaryFill)
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
                HStack(spacing: TaptionSpacing.cozy) {
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
                        Capsule().fill(Color.tpTrackFill)
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
            .accessibilityAddTraits(.isButton)

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
        VStack(alignment: .leading, spacing: TaptionSpacing.compact) {
            Text("아직 루틴이 없습니다")
                .font(.taption(size: 12.5, weight: .bold))
                .foregroundStyle(Color.tpInk)
            Text("새 루틴을 추가하거나 상황별 루틴을 만들 수 있습니다.")
                .font(.taption(size: 9))
                .foregroundStyle(Color.tpSecondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            Color.white.opacity(0.78),
            in: RoundedRectangle(cornerRadius: TaptionRadius.card, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: TaptionRadius.card, style: .continuous)
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
            VStack(alignment: .leading, spacing: TaptionSpacing.snug) {
                HStack(spacing: TaptionSpacing.snug) {
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
                        Color.tpFieldFill,
                        in: RoundedRectangle(cornerRadius: TaptionRadius.control)
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
        GoalRecordPolicy.displayTitle(raw)
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
            HStack(spacing: TaptionSpacing.regular) {
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
            .background(rowBackground, in: RoundedRectangle(cornerRadius: TaptionRadius.control))
            .overlay {
                RoundedRectangle(cornerRadius: TaptionRadius.control)
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
