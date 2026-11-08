import SwiftUI

struct CategorySetupView: View {
    @Bindable var model: AppModel

    private let automaticIDs: Set<String> = [
        "movement", "location", "activity", "sleep", "photo"
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("닫기") { model.cancelInitialCategorySelection() }
                    .font(.taption(size: 11, weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
                Spacer()
                Text("시작 구성")
                    .font(.taption(size: 13, weight: .bold))
                    .foregroundStyle(Color.tpInk)
                Spacer()
                Button("저장") {
                    Task { await model.applyInitialCategorySelection() }
                }
                .font(.taption(size: 11, weight: .bold))
                .foregroundStyle(
                    model.selectedSetupCategoryCount > 0
                        ? Color.tpInk
                        : Color.tpSecondary.opacity(0.35)
                )
                .disabled(model.selectedSetupCategoryCount == 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.tpCard)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.tpLine).frame(height: 0.5)
            }

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("필요한 일과만 골라보세요")
                        .font(.taption(size: 21, weight: .bold))
                    Text("역할·상황·루틴에 맞는 항목을 시간표와 추가 메뉴에 표시합니다. 자동 기록 항목도 여기서 켜고 끌 수 있습니다.")
                        .font(.taption(size: 10.5))
                        .foregroundStyle(Color.tpSecondary)

                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible())],
                        spacing: 8
                    ) {
                        ForEach(model.setupCategories) { category in
                            categoryCard(category)
                        }
                    }

                    Text("선택 \(model.selectedSetupCategoryCount)개 · 분류표 관리에서 자동 분류 기준을 확인할 수 있습니다.")
                        .font(.taption(size: 9, weight: .semibold))
                        .foregroundStyle(Color.tpSecondary)
                        .padding(.top, 2)

                    Button {
                        model.cancelInitialCategorySelection()
                        model.selectedTab = .settings
                    } label: {
                        Label("자주가는 곳 설정", systemImage: "star.circle.fill")
                            .font(.taption(size: 9.5, weight: .bold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.tpPlaceDark)
                }
                .padding(14)
            }
            .background(Color.tpBackground)
        }
        .background(Color.tpBackground)
    }

    private func categoryCard(_ category: CategoryDefinition) -> some View {
        let selected = model.pendingSetupCategoryIDs.contains(category.id)
        let tint = Color(hex: category.darkHex)
        return Button {
            model.toggleSetupCategory(category.id)
        } label: {
            VStack(alignment: .leading, spacing: TaptionSpacing.cozy) {
                HStack {
                    Image(systemName: category.icon.systemImage)
                        .accessibilityHidden(true)
                        .font(.taption(size: 16, weight: .bold))
                        .foregroundStyle(tint)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .accessibilityHidden(true)
                        .font(.taption(size: 15, weight: .bold))
                        .foregroundStyle(selected ? tint : Color.tpLine)
                }
                Text(category.name)
                    .font(.taption(size: 11, weight: .bold))
                    .foregroundStyle(Color.tpInk)
                    .lineLimit(1)
                Text(automaticIDs.contains(category.id) ? "자동 기록" : category.isBuiltIn ? "기본 대분류" : "직접 추가")
                    .font(.taption(size: 8, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
            .background(
                selected ? Color(hex: category.lightHex).opacity(0.75) : Color.white,
                in: RoundedRectangle(cornerRadius: TaptionRadius.tile, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: TaptionRadius.tile, style: .continuous)
                    .stroke(selected ? tint.opacity(0.65) : Color.tpLine, lineWidth: selected ? 1.5 : 0.8)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("대분류 \(category.name)")
        .accessibilityValue(selected ? "선택됨" : "선택 안 됨")
    }
}
