import SwiftUI

struct CategoryManagerView: View {
    @Bindable var model: AppModel
    @State private var editingCategory: CategoryDefinition?
    @State private var isCreatingCategory = false

    var body: some View {
        VStack(spacing: 0) {
            DraftTopBar(
                title: "대분류 관리",
                trailing: "\(model.snapshot.categories.count)개",
                onBack: { model.detail = nil }
            )

            List {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("계획을 추가할 때만 선택")
                            .font(.taption(size: 10.5, weight: .bold))
                            .foregroundStyle(Color.tpInk)
                        Text("오른쪽 손잡이를 길게 눌러 순서를 바꿉니다.")
                            .font(.taption(size: 7.5))
                            .foregroundStyle(Color.tpSecondary)
                    }
                    Spacer()
                    Button {
                        isCreatingCategory = true
                    } label: {
                        Label("추가", systemImage: "plus")
                            .font(.taption(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                Color.tpInk,
                                in: RoundedRectangle(cornerRadius: 9)
                            )
                    }
                    .buttonStyle(.borderless)
                }
                .padding(11)
                .draftCard(radius: 14)
                .categoryListRow(top: 12)

                ForEach(orderedCategories) { category in
                    categoryRow(category)
                        .categoryListRow()
                }
                .onMove(perform: model.moveCategories)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
            .background(Color.tpBackground)
        }
        .sheet(item: $editingCategory) { category in
            CategoryEditorSheet(model: model, category: category)
        }
        .sheet(isPresented: $isCreatingCategory) {
            CategoryEditorSheet(model: model, category: nil)
        }
    }

    private var orderedCategories: [CategoryDefinition] {
        model.snapshot.categories.sorted {
            $0.sortOrder < $1.sortOrder
        }
    }

    private func categoryRow(
        _ category: CategoryDefinition
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: category.icon.systemImage)
                .font(.taption(size: 14, weight: .semibold))
                .foregroundStyle(Color(hex: category.darkHex))
                .frame(width: 31, height: 31)
                .background(
                    Color(hex: category.lightHex),
                    in: RoundedRectangle(cornerRadius: 9)
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(category.name)
                        .font(.taption(size: 10, weight: .bold))
                        .foregroundStyle(
                            category.isHidden
                                ? Color.tpSecondary : Color.tpInk
                        )
                    Text(category.isBuiltIn ? "기본" : "사용자")
                        .font(.taption(size: 6.5, weight: .black))
                        .foregroundStyle(Color.tpSecondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.tpBackground, in: Capsule())
                }
                Text(category.isHidden ? "숨김" : "시간표에 표시")
                    .font(.taption(size: 7))
                    .foregroundStyle(Color.tpSecondary)
            }

            Spacer(minLength: 2)

            Button {
                model.updateCategory(
                    category.id,
                    name: category.name,
                    icon: category.icon,
                    lightHex: category.lightHex,
                    hidden: !category.isHidden
                )
            } label: {
                Image(systemName: category.isHidden ? "eye.slash" : "eye")
            }

            Button {
                editingCategory = category
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
        }
        .font(.taption(size: 10, weight: .semibold))
        .foregroundStyle(Color.tpSecondary)
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .frame(minHeight: 48)
        .background(
            Color.white,
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
    }
}

private extension View {
    func categoryListRow(top: CGFloat = 4) -> some View {
        listRowInsets(
            EdgeInsets(
                top: top,
                leading: 12,
                bottom: 4,
                trailing: 8
            )
        )
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

private struct CategoryEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let category: CategoryDefinition?

    @State private var name: String
    @State private var selectedIcon: CategoryIcon
    @State private var selectedHex: String
    @State private var isHidden: Bool
    @State private var replacementID: String
    @State private var showsDeleteConfirmation = false

    private let icons: [CategoryIcon] = [
        .briefcase, .building, .book, .graduation, .target, .award,
        .stroller, .family, .shield, .health, .exercise, .sleep,
        .performance, .music, .travel, .location, .home, .meal,
        .cafe, .pet, .shopping, .nature, .calendar, .memo,
    ]
    private let colorHexes = [
        "#BEDAE3", "#D9E6C7", "#FED5CF",
        "#F1B598", "#D3C7E6", "#F4D7E7",
    ]

    init(model: AppModel, category: CategoryDefinition?) {
        self.model = model
        self.category = category
        _name = State(initialValue: category?.name ?? "")
        _selectedIcon = State(
            initialValue: category?.icon ?? .briefcase
        )
        _selectedHex = State(
            initialValue: category?.lightHex ?? "#BEDAE3"
        )
        _isHidden = State(initialValue: category?.isHidden ?? false)
        let replacement = model.snapshot.categories.first {
            $0.id == "project" && $0.id != category?.id
        } ?? model.snapshot.categories.first {
            $0.id != category?.id
        }
        _replacementID = State(initialValue: replacement?.id ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    preview
                    nameRow
                    iconGrid
                    colorPicker

                    if category != nil {
                        Toggle("시간표에서 숨기기", isOn: $isHidden)
                            .font(.taption(size: 10.5, weight: .bold))
                            .tint(Color.tpInk)
                            .padding(11)
                            .draftCard(radius: 13)
                    }

                    Button(action: save) {
                        Text(category == nil ? "대분류 추가" : "변경 저장")
                            .font(.taption(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(
                                Color.tpInk,
                                in: RoundedRectangle(cornerRadius: 12)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        name.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                    )

                    if let category, !category.isBuiltIn {
                        deletionCard(category)
                    }
                }
                .padding(13)
            }
            .background(Color.tpBackground)
            .navigationTitle(
                category == nil ? "새 대분류" : "대분류 편집"
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .confirmationDialog(
            "이 대분류를 삭제할까요?",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("기록을 옮기고 삭제", role: .destructive) {
                guard let category else { return }
                model.deleteCustomCategory(
                    category.id,
                    reassigningTo: replacementID
                )
                dismiss()
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("기존 계획과 실제 기록은 선택한 대분류로 옮겨집니다.")
        }
    }

    private var preview: some View {
        HStack(spacing: 9) {
            Image(systemName: selectedIcon.systemImage)
                .font(.taption(size: 18, weight: .semibold))
                .foregroundStyle(Color.tpInk)
                .frame(width: 38, height: 38)
                .background(
                    Color(hex: selectedHex),
                    in: RoundedRectangle(cornerRadius: 11)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text("미리보기")
                    .font(.taption(size: 8))
                    .foregroundStyle(Color.tpSecondary)
                Text(name.isEmpty ? "새 대분류" : name)
                    .font(.taption(size: 13, weight: .bold))
            }
            Spacer()
        }
        .padding(12)
        .draftCard(radius: 14)
    }

    private var nameRow: some View {
        HStack {
            Text("이름")
                .font(.taption(size: 10))
                .foregroundStyle(Color.tpSecondary)
            TextField("대분류 이름", text: $name)
                .font(.taption(size: 12, weight: .bold))
                .multilineTextAlignment(.trailing)
        }
        .padding(11)
        .draftCard(radius: 13)
    }

    private var iconGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("아이콘 · 24개")
                .font(.taption(size: 10, weight: .bold))
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible()),
                    count: 8
                ),
                spacing: 5
            ) {
                ForEach(icons, id: \.self) { icon in
                    Button {
                        selectedIcon = icon
                    } label: {
                        Image(systemName: icon.systemImage)
                            .font(.taption(size: 14))
                            .foregroundStyle(
                                selectedIcon == icon
                                    ? Color.white : Color.tpSecondary
                            )
                            .frame(maxWidth: .infinity, minHeight: 31)
                            .background(
                                selectedIcon == icon
                                    ? Color.tpInk
                                    : Color.tpBackground,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(11)
        .draftCard(radius: 13)
    }

    private var colorPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("색상")
                .font(.taption(size: 10, weight: .bold))
            HStack {
                ForEach(colorHexes, id: \.self) { hex in
                    Button {
                        selectedHex = hex
                    } label: {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Color(hex: hex))
                            .frame(width: 31, height: 31)
                            .overlay {
                                if selectedHex.uppercased()
                                    == hex.uppercased() {
                                    RoundedRectangle(cornerRadius: 9)
                                        .stroke(Color.tpInk, lineWidth: 2)
                                        .padding(-3)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    if hex != colorHexes.last { Spacer() }
                }
            }
        }
        .padding(11)
        .draftCard(radius: 13)
    }

    private func deletionCard(
        _ category: CategoryDefinition
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("대분류 삭제")
                .font(.taption(size: 10, weight: .bold))
                .foregroundStyle(Color(red: 0.72, green: 0.19, blue: 0.16))
            Picker("기존 기록 이동", selection: $replacementID) {
                ForEach(model.snapshot.categories.filter {
                    $0.id != category.id
                }) { replacement in
                    Text(replacement.name).tag(replacement.id)
                }
            }
            .font(.taption(size: 9.5))

            Button(role: .destructive) {
                showsDeleteConfirmation = true
            } label: {
                Text("기록을 옮기고 대분류 삭제")
                    .font(.taption(size: 10, weight: .bold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(11)
        .draftCard(radius: 13)
    }

    private func save() {
        if let category {
            model.updateCategory(
                category.id,
                name: name,
                icon: selectedIcon,
                lightHex: selectedHex,
                hidden: isHidden
            )
        } else {
            _ = model.addCustomCategory(
                name: name,
                icon: selectedIcon,
                lightHex: selectedHex
            )
        }
        if model.userFacingError == nil {
            dismiss()
        }
    }
}
