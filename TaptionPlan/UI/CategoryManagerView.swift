import SwiftUI

/// 앱 전체가 공유하는 JSON 분류표를 확인하는 화면이다.
/// 자동 센서·HealthKit 원본은 편집하지 않고, 화면과 분석이 같은 관계를
/// 읽고 있는지만 빠르게 확인할 수 있도록 한다.
struct CategoryManagerView: View {
    @Bindable var model: AppModel

    private var categories: [RecordClassificationCategory] {
        RecordClassificationCatalog.categories
    }

    var body: some View {
        VStack(spacing: 0) {
            DraftTopBar(
                title: "분류표 관리",
                trailing: "\(categories.count)개 일과",
                onBack: { model.detail = nil }
            )

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 9) {
                    overviewCard

                    ForEach(categories) { category in
                        categoryCard(category)
                    }
                }
                .padding(12)
            }
            .background(Color.tpBackground)
        }
    }

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("자동 분류 기준", systemImage: "list.bullet.rectangle")
                .font(.taption(size: 11, weight: .bold))
                .foregroundStyle(Color.tpInk)
            Text("기록 화면, 시간표, 위젯이 이 분류표를 함께 사용합니다.")
                .font(.taption(size: 9.5))
                .foregroundStyle(Color.tpSecondary)
            Text("센서·HealthKit 원본은 보존되며, 수면·운동처럼 자동 기록 전용인 항목은 직접 변경할 수 없습니다.")
                .font(.taption(size: 8.5))
                .foregroundStyle(Color.tpSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .draftCard(radius: 14)
    }

    private func categoryCard(
        _ category: RecordClassificationCategory
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: category.systemImage)
                    .font(.taption(size: 15, weight: .bold))
                    .foregroundStyle(categoryColor(category.id))
                    .frame(width: 32, height: 32)
                    .background(
                        categoryColor(category.id).opacity(0.16),
                        in: RoundedRectangle(cornerRadius: 9)
                    )

                Text(category.title)
                    .font(.taption(size: 12, weight: .bold))
                    .foregroundStyle(Color.tpInk)

                if category.automaticOnly == true {
                    automaticBadge
                }

                Spacer(minLength: 4)
                Text("상세 \(category.details.count)")
                    .font(.taption(size: 8, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
            }

            LazyVStack(spacing: 5) {
                ForEach(category.details) { detail in
                    detailRow(detail, tint: categoryColor(category.id))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
    }

    private func detailRow(
        _ detail: RecordClassificationDetail,
        tint: Color
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: detail.systemImage)
                .font(.taption(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22)
            Text(detail.title)
                .font(.taption(size: 9.5, weight: .semibold))
                .foregroundStyle(Color.tpInk)
                .lineLimit(1)
            Spacer(minLength: 4)
            if detail.automaticOnly == true {
                automaticBadge
            }
        }
        .padding(.horizontal, 9)
        .frame(minHeight: 34)
        .background(Color.tpBackground, in: RoundedRectangle(cornerRadius: 9))
    }

    private var automaticBadge: some View {
        Text("자동")
            .font(.taption(size: 7, weight: .bold))
            .foregroundStyle(Color.tpPlaceDark)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.tpPlace.opacity(0.24), in: Capsule())
    }

    private func categoryColor(_ id: String) -> Color {
        switch id {
        case "work": Color(red: 0.34, green: 0.45, blue: 0.78)
        case "study": Color(red: 0.45, green: 0.39, blue: 0.72)
        case "hobby": Color(red: 0.75, green: 0.42, blue: 0.66)
        case "sleep": Color(red: 0.37, green: 0.37, blue: 0.74)
        case "movement": Color(red: 0.84, green: 0.57, blue: 0.22)
        case "exercise": Color(red: 0.78, green: 0.35, blue: 0.34)
        default: Color.tpPlaceDark
        }
    }
}
