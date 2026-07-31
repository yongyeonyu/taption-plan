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
                title: plan.title,
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
            title: "자격증 취득",
            period: "3월 – 6월",
            leftDetail: "하위 3개 · 월→주→일 연결됨",
            rightDetail: "실제 27h / 계획 40h",
            progress: 0.67,
            category: .study
        ),
        GoalCard(
            id: UUID(),
            planID: nil,
            title: "주 3회 운동 습관",
            period: "1월 – 12월",
            leftDetail: "하위 2개 · 건강 데이터 연동",
            rightDetail: "실제 48h / 계획 72h",
            progress: 0.66,
            category: .exercise
        ),
        GoalCard(
            id: UUID(),
            planID: nil,
            title: "신제품 프로젝트",
            period: "4월 – 9월",
            leftDetail: "하위 4개 · 이번 주 진행 중",
            rightDetail: "실제 112h / 계획 160h",
            progress: 0.70,
            category: .project
        ),
        GoalCard(
            id: UUID(),
            planID: nil,
            title: "일본 여행",
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
                        Button {
                            if let planID = goal.planID {
                                model.openGroup(planID)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 0) {
                                HStack(spacing: 7) {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(goal.category.darkColor)
                                        .frame(width: 10, height: 10)
                                    Text(goal.title)
                                        .font(.system(size: 13.5, weight: .bold))
                                        .foregroundStyle(Color.tpInk)
                                    Spacer(minLength: 4)
                                    Text(goal.period)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(Color.tpSecondary)
                                }

                                HStack {
                                    if goal.title.contains("운동") {
                                        Image(systemName: "heart.text.square")
                                            .font(.system(size: 9))
                                    }
                                    Text(goal.leftDetail)
                                    Spacer(minLength: 4)
                                    Text(goal.rightDetail)
                                        .fontWeight(.semibold)
                                }
                                .font(.system(size: 10.5))
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
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .draftCard()
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        model.addPlanContext = .goal
                        model.isAddPlanPresented = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                            Text("새 목표")
                        }
                        .font(.system(size: 13, weight: .semibold))
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

#Preview {
    GoalsView(model: AppModel())
}
