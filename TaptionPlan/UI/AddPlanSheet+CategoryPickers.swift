import SwiftUI

extension AddPlanSheet {
    var categoryQuickPicker: some View {
        VStack(alignment: .leading, spacing: TaptionSpacing.compact) {
            HStack(spacing: TaptionSpacing.snug) {
                Text("대분류")
                    .font(.taption(size: 10.5, weight: .bold))
                    .foregroundStyle(Color.tpInk)
                Text("아이콘으로 빠르게 선택")
                    .font(.taption(size: 7.5, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: TaptionSpacing.cozy) {
                    ForEach(visibleCategories) { category in
                        Button {
                            selectCategory(category.id)
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: category.icon.systemImage)
                                    .accessibilityHidden(true)
                                    .font(.taption(size: 14, weight: .bold))
                                    .foregroundStyle(Color.tpInk)
                                    .frame(width: 38, height: 34)
                                    .background(
                                        Color(hex: category.lightHex),
                                        in: RoundedRectangle(cornerRadius: TaptionRadius.field)
                                    )
                                    .overlay {
                                        RoundedRectangle(cornerRadius: TaptionRadius.field)
                                            .stroke(
                                                categoryID == category.id
                                                    ? Color.tpInk
                                                    : Color.clear,
                                                lineWidth: 2
                                            )
                                    }
                                Text(category.name)
                                    .font(.taption(size: 7.5, weight: .bold))
                                    .foregroundStyle(Color.tpInk)
                                    .lineLimit(1)
                            }
                            .frame(width: 48)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("대분류 \(category.name)")
                        .accessibilityAddTraits(
                            categoryID == category.id ? .isSelected : []
                        )
                    }

                    Button {
                        titleFocused = false
                        selectedDetent = .large
                        path.append(.customCategory)
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: "plus")
                                .accessibilityHidden(true)
                                .font(.taption(size: 14, weight: .bold))
                                .foregroundStyle(Color.tpSecondary)
                                .frame(width: 38, height: 34)
                                .background(
                                    Color.white,
                                    in: RoundedRectangle(cornerRadius: TaptionRadius.field)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: TaptionRadius.field)
                                        .stroke(
                                            Color.tpSecondary.opacity(0.55),
                                            style: StrokeStyle(
                                                lineWidth: 1,
                                                dash: [3, 2]
                                            )
                                        )
                                }
                            Text("추가")
                                .font(.taption(size: 7.5, weight: .bold))
                                .foregroundStyle(Color.tpSecondary)
                        }
                        .frame(width: 48)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("대분류 직접 추가")
                }
            }
        }
    }

    var middleCategoryPicker: some View {
        VStack(alignment: .leading, spacing: TaptionSpacing.compact) {
            HStack(spacing: TaptionSpacing.snug) {
                Text("중분류")
                    .font(.taption(size: 10.5, weight: .bold))
                    .foregroundStyle(Color.tpInk)
                Text("\(selectedCategory.name) 추천")
                    .font(.taption(size: 7.5, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: TaptionSpacing.snug) {
                    ForEach(middleCategorySuggestions, id: \.self) { suggestion in
                        Button {
                            titleFocused = false
                            middleCategoryName = suggestion
                            subCategoryName = ""
                        } label: {
                            DraftChip(
                                title: suggestion,
                                selected: middleCategoryName == suggestion
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("중분류 \(suggestion)")
                        .accessibilityAddTraits(
                            middleCategoryName == suggestion
                                ? .isSelected
                                : []
                        )
                    }
                }
            }
        }
    }

    var subCategoryPicker: some View {
        VStack(alignment: .leading, spacing: TaptionSpacing.compact) {
            HStack(spacing: TaptionSpacing.snug) {
                Text("소분류")
                    .font(.taption(size: 10.5, weight: .bold))
                    .foregroundStyle(Color.tpInk)
                Text("상세 동작")
                    .font(.taption(size: 7.5, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: TaptionSpacing.snug) {
                    ForEach(subCategorySuggestions, id: \.self) { suggestion in
                        Button {
                            titleFocused = false
                            subCategoryName = suggestion
                        } label: {
                            DraftChip(
                                title: suggestion,
                                selected: subCategoryName == suggestion
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("소분류 \(suggestion)")
                        .accessibilityAddTraits(
                            subCategoryName == suggestion
                                ? .isSelected
                                : []
                        )
                    }
                }
            }

            memoTextField(
                label: "소분류 직접 입력",
                placeholder: "예: 걷기, 달리기, 자전거",
                text: $subCategoryName
            )
        }
    }

    private var middleCategorySuggestions: [String] {
        var values = CategoryHierarchyCatalog.middleSuggestions(
            for: selectedCategory.id
        )
        let cleanSelection = middleCategoryName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if !cleanSelection.isEmpty,
           !values.contains(cleanSelection) {
            values.append(cleanSelection)
        }
        values.append(
            contentsOf: model.snapshot.plans
                .filter { $0.categoryID == selectedCategory.id }
                .sorted { $0.updatedAt > $1.updatedAt }
                .compactMap(\.middleCategoryName)
        )

        var seen = Set<String>()
        return values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(10)
            .map { $0 }
    }

    private var subCategorySuggestions: [String] {
        var values = CategoryHierarchyCatalog.subSuggestions(
            for: selectedCategory.id,
            middleName: middleCategoryName
        )
        let cleanSelection = subCategoryName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if !cleanSelection.isEmpty,
           !values.contains(cleanSelection) {
            values.append(cleanSelection)
        }
        let cleanMiddle = middleCategoryName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if !cleanMiddle.isEmpty {
            values.append(
                contentsOf:
                    model.snapshot.plans
                        .filter { plan in
                            plan.categoryID == selectedCategory.id
                                && plan.middleCategoryName == cleanMiddle
                        }
                        .sorted { $0.updatedAt > $1.updatedAt }
                        .compactMap(\.subCategoryName)
            )
        }

        var seen = Set<String>()
        return values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(10)
            .map { $0 }
    }
}
