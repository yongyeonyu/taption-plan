import SwiftUI

struct GoalsView: View {
    private let goals = [
        GoalCard(title: "자격증 취득", period: "3월–6월", detail: "하위 3개 · 실제 27h / 계획 40h", progress: 0.67, category: .study),
        GoalCard(title: "주 3회 운동 습관", period: "1월–12월", detail: "하위 2개 · 건강 데이터 연결", progress: 0.66, category: .exercise),
        GoalCard(title: "신제품 프로젝트", period: "4월–9월", detail: "하위 4개 · 실제 112h / 계획 160h", progress: 0.70, category: .project),
        GoalCard(title: "일본 여행", period: "8월", detail: "하위 5개 · 예약 2건 완료", progress: 0.40, category: .travel),
    ]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(goals) { goal in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Circle()
                                .fill(goal.category.color)
                                .frame(width: 11, height: 11)
                            Text(goal.title)
                                .font(.headline)
                            Spacer()
                            Text(goal.period)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text(goal.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ProgressView(value: goal.progress)
                            .tint(goal.category.color)
                    }
                    .padding(14)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                }

                Button("＋ 새 목표") {}
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.tpSecondary)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            }
            .padding(14)
        }
        .background(Color.tpBackground)
        .overlay(alignment: .topLeading) {
            Text("목표")
                .font(.title2.bold())
                .padding(.leading, 16)
                .offset(y: -44)
        }
        .safeAreaPadding(.top, 52)
    }
}

private struct GoalCard: Identifiable {
    let id = UUID()
    let title: String
    let period: String
    let detail: String
    let progress: Double
    let category: PlanCategory
}

#Preview {
    GoalsView()
}
