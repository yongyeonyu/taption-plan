import SwiftUI

struct GoalsView: View {
    @Bindable var model: AppModel

    private var goals: [GoalCard] {
        let roots = model.snapshot.plans
            .filter { $0.parentID == nil && $0.status != .skipped }
            .sorted { $0.span.start < $1.span.start }
        guard !roots.isEmpty else { return Self.sampleGoals }

        let aggregation = TimelineAggregationEngine()
        return roots.map { plan in
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
                leftDetail: "하위 \(rollup?.descendantCount ?? 0)개 · 월→주→일",
                rightDetail: "실제 \(durationText(actual)) / 계획 \(durationText(planned))",
                progress: progress,
                category: PlanCategory(categoryID: plan.categoryID)
            )
        }
    }

    private static let sampleGoals = [
        GoalCard(
            id: UUID(),
            planID: nil,
            title: "목표:자격증 취득",
            period: "3월 – 6월",
            leftDetail: "하위 3개 · 월→주→일 연결됨",
            rightDetail: "실제 27h / 계획 40h",
            progress: 0.67,
            category: .study
        ),
        GoalCard(
            id: UUID(),
            planID: nil,
            title: "목표:주 3회 운동 습관",
            period: "1월 – 12월",
            leftDetail: "하위 2개 · 건강 데이터 연동",
            rightDetail: "실제 48h / 계획 72h",
            progress: 0.66,
            category: .exercise
        ),
        GoalCard(
            id: UUID(),
            planID: nil,
            title: "목표:신제품 프로젝트",
            period: "4월 – 9월",
            leftDetail: "하위 4개 · 이번 주 진행 중",
            rightDetail: "실제 112h / 계획 160h",
            progress: 0.70,
            category: .project
        ),
        GoalCard(
            id: UUID(),
            planID: nil,
            title: "목표:일본 여행",
            period: "8월",
            leftDetail: "하위 5개 · 예약 2건 완료",
            rightDetail: "D-9",
            progress: 0.40,
            category: .travel
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            DraftTopBar(title: "목표", trailing: "2026")

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 10) {
                    ForEach(goals) { goal in
                        let childRows = childTimelineRows(for: goal.planID)
                        VStack(alignment: .leading, spacing: 9) {
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
                                .padding(.bottom, 6)

                                GeometryReader { proxy in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color(red: 0.93, green: 0.93, blue: 0.94))
                                        Capsule()
                                            .fill(goal.category.darkColor)
                                            .frame(width: proxy.size.width * goal.progress)
                                    }
                                }
                                .frame(height: 6)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if let planID = goal.planID {
                                    model.openGroup(planID)
                                }
                            }

                            goalTimelineSection(
                                rows: childRows,
                                category: goal.category
                            )
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .draftCard()
                    }

                    Button {
                        model.addPlanContext = .goal
                        model.isAddPlanPresented = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                            Text("새 목표")
                        }
                        .font(.taption(size: 13, weight: .semibold))
                        .foregroundStyle(Color.tpSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(
                            Color(red: 0.94, green: 0.94, blue: 0.95),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .background(Color.tpBackground)
        }
    }

    @ViewBuilder
    private func goalTimelineSection(
        rows: [GoalChildPlanRow],
        category: PlanCategory
    ) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("계획 타임라인")
                        .font(.taption(size: 9, weight: .semibold))
                        .foregroundStyle(Color.tpSecondary)

                    Spacer(minLength: 4)

                    if let summary = childTimelineSummary(rows) {
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
            .sorted { $0.span.start < $1.span.start }
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

    private func childTimelineSummary(_ rows: [GoalChildPlanRow]) -> String? {
        let duplicateCount = rows.filter(\.isDuplicate).count
        let overlapCount = rows.filter(\.hasOverlap).count
        let parts = [
            duplicateCount > 0 ? "중복 \(duplicateCount)건" : nil,
            overlapCount > 0 ? "겹침 \(overlapCount)건" : nil,
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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

private struct GoalCard: Identifiable {
    let id: UUID
    let planID: UUID?
    let title: String
    let period: String
    let leftDetail: String
    let rightDetail: String
    let progress: CGFloat
    let category: PlanCategory
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
