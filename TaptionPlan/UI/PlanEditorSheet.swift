import SwiftUI

struct PlanEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let planID: UUID

    @State private var title: String
    @State private var categoryID: String
    @State private var middleCategoryName: String
    @State private var subCategoryName: String
    @State private var startAt: Date
    @State private var endAt: Date
    @State private var parentID: UUID?
    @State private var isImportant: Bool
    @State private var repeatRules: [GoalRepeatRule]
    @State private var showsDeleteConfirmation = false

    init(model: AppModel, planID: UUID) {
        self.model = model
        self.planID = planID
        let plan = model.snapshot.plans.first { $0.id == planID }
        _title = State(initialValue: plan?.title ?? "")
        _categoryID = State(
            initialValue: plan?.categoryID ?? "project"
        )
        _middleCategoryName = State(
            initialValue: plan?.middleCategoryName ?? ""
        )
        _subCategoryName = State(
            initialValue: plan?.subCategoryName ?? ""
        )
        _startAt = State(initialValue: plan?.span.start ?? .now)
        _endAt = State(
            initialValue:
                plan?.span.end
                ?? Date.now.addingTimeInterval(3_600)
        )
        _parentID = State(initialValue: plan?.parentID)
        _isImportant = State(initialValue: plan?.isImportant ?? false)
        _repeatRules = State(initialValue: plan?.repeatRules ?? [])
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    nameCard
                    categoryCard
                    categoryHierarchyCard
                    timeCard
                    if showsGoalRepeatEditor {
                        GoalRepeatRulesEditor(rules: $repeatRules)
                    }
                    hierarchyCard
                    Toggle("중요 계획", isOn: $isImportant)
                        .font(.taption(size: 10.5, weight: .bold))
                        .tint(Color.tpInk)
                        .padding(11)
                        .draftCard(radius: 13)

                    if currentPlan?.externalEventID == nil {
                        Button {
                            Task {
                                await model.addPlanToCalendar(planID)
                            }
                        } label: {
                            Label(
                                "Apple 캘린더로 보내기",
                                systemImage: "calendar.badge.plus"
                            )
                            .font(.taption(size: 10.5, weight: .bold))
                            .foregroundStyle(Color.tpInk)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                Color.white,
                                in: RoundedRectangle(cornerRadius: 12)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(13)
            }
            .background(Color.tpBackground)
            .navigationTitle("계획 편집")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                    Button("삭제", role: .destructive) {
                        showsDeleteConfirmation = true
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        save()
                    }
                    .font(.taption(size: 10.5, weight: .bold))
                    .disabled(isSaveDisabled)
                }
            }
        }
        .presentationDetents([.large])
        .confirmationDialog(
            "이 계획을 삭제할까요?",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("계획 삭제", role: .destructive) {
                dismiss()
                Task { await model.deletePlan(planID) }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
    }

    private var currentPlan: PlanRecord? {
        model.snapshot.plans.first { $0.id == planID }
    }

    private var visibleCategories: [CategoryDefinition] {
        model.snapshot.categories
            .filter {
                !$0.isHidden
                    || $0.id == categoryID
                    || (
                        showsGoalRepeatEditor
                            && GoalCategoryPolicy
                                .systemSelectableCategoryIDs
                                .contains($0.id)
                    )
            }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    private var possibleParents: [PlanRecord] {
        let descendantIDs = Set(
            (try? PlanHierarchy.descendants(
                of: planID,
                in: model.snapshot.plans
            ).map(\.id)) ?? []
        )
        return model.snapshot.plans
            .filter {
                $0.id != planID
                    && !descendantIDs.contains($0.id)
                    && $0.status != .skipped
                    && $0.span.start <= startAt
                    && endAt <= $0.span.end
            }
            .sorted { $0.span.start < $1.span.start }
    }

    private var childCount: Int {
        (try? PlanHierarchy.descendants(
            of: planID,
            in: model.snapshot.plans
        ).count) ?? 0
    }

    private var isSaveDisabled: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || endAt <= startAt
    }

    private var deleteMessage: String {
        if childCount == 0 {
            return "실제 실행 기록은 회고를 위해 보존됩니다."
        }
        return "하위 계획 \(childCount)개도 함께 삭제되며, 실제 실행 기록은 회고를 위해 보존됩니다."
    }

    private var nameCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("계획 이름")
                .font(.taption(size: 8.5, weight: .black))
                .foregroundStyle(Color.tpSecondary)
            TextField("계획 이름", text: $title)
                .font(.taption(size: 14, weight: .bold))
                .textInputAutocapitalization(.sentences)
        }
        .padding(11)
        .draftCard(radius: 13)
    }

    private var categoryCard: some View {
        HStack {
            Text("대분류")
                .font(.taption(size: 10))
                .foregroundStyle(Color.tpSecondary)
            Spacer()
            Picker("대분류", selection: $categoryID) {
                ForEach(visibleCategories) { category in
                    Label(
                        category.name,
                        systemImage: category.icon.systemImage
                    )
                    .tag(category.id)
                }
            }
            .font(.taption(size: 10.5, weight: .bold))
        }
        .padding(11)
        .draftCard(radius: 13)
    }

    private var categoryHierarchyCard: some View {
        VStack(spacing: 8) {
            hierarchyTextField(
                label: "중분류",
                placeholder: "예: 일본, 자격증, 가족여행",
                text: $middleCategoryName
            )
            hierarchyTextField(
                label: "소분류",
                placeholder: "예: 항공권, 필기, 숙소",
                text: $subCategoryName
            )
        }
        .padding(11)
        .draftCard(radius: 13)
    }

    private func hierarchyTextField(
        label: String,
        placeholder: String,
        text: Binding<String>
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.taption(size: 10))
                .foregroundStyle(Color.tpSecondary)
                .frame(width: 48, alignment: .leading)
            TextField(placeholder, text: text)
                .font(.taption(size: 10.5, weight: .bold))
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
        }
    }

    private var timeCard: some View {
        VStack(spacing: 8) {
            DatePicker(
                "시작",
                selection: $startAt,
                displayedComponents: [.date, .hourAndMinute]
            )
            DatePicker(
                "종료",
                selection: $endAt,
                in: startAt.addingTimeInterval(60)...,
                displayedComponents: [.date, .hourAndMinute]
            )
        }
        .font(.taption(size: 10.5, weight: .bold))
        .padding(11)
        .draftCard(radius: 13)
        .onChange(of: startAt) { oldValue, newValue in
            if endAt <= newValue {
                endAt = newValue.addingTimeInterval(
                    max(60, oldValue.distance(to: endAt))
                )
            }
        }
    }

    private var hierarchyCard: some View {
        HStack {
            Text("상위 목표")
                .font(.taption(size: 10))
                .foregroundStyle(Color.tpSecondary)
            Spacer()
            Picker("상위 목표", selection: $parentID) {
                Text("없음").tag(UUID?.none)
                ForEach(possibleParents) { plan in
                    Text(plan.title).tag(UUID?.some(plan.id))
                }
            }
            .font(.taption(size: 10.5, weight: .bold))
        }
        .padding(11)
        .draftCard(radius: 13)
    }

    private var showsGoalRepeatEditor: Bool {
        parentID == nil
            && title.trimmingCharacters(in: .whitespacesAndNewlines)
                .hasPrefix("목표:")
    }

    private func save() {
        model.updatePlan(
            planID,
            title: title,
            categoryID: categoryID,
            middleCategoryName: middleCategoryName,
            subCategoryName: subCategoryName,
            span: TimeSpan(start: startAt, end: endAt),
            parentID: parentID,
            isImportant: isImportant,
            repeatRules: showsGoalRepeatEditor ? repeatRules : nil
        )
        dismiss()
    }
}
