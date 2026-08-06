import SwiftUI

struct AddPlanSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel

    @State private var title = ""
    @State private var categoryID = "study"
    @State private var middleCategoryName = ""
    @State private var subCategoryName = ""
    @State private var memoText = ""
    @State private var durationMinutes = 30
    @State private var goalDurationMonths = 12
    @State private var usesCustomGoalRange = false
    @State private var goalEndAt = Date.now
    @State private var goalRepeatRules: [GoalRepeatRule] = []
    @State private var startAt = Date.now
    @State private var timelineWindowStart = Date.now
    @State private var parentID: UUID?
    @State private var path: [AddRoute] = []
    @State private var selectedDetent: PresentationDetent = .large
    @State private var isCalendarPresented = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        NavigationStack(path: $path) {
            rootSheet
                .navigationDestination(for: AddRoute.self) { route in
                    switch route {
                    case .customCategory:
                        CustomCategoryScreen { name, icon, colorHex in
                            if let category = model.addCustomCategory(
                                name: name,
                                icon: icon,
                                lightHex: colorHex
                            ) {
                                categoryID = category.id
                                middleCategoryName = ""
                                subCategoryName = ""
                                memoText = ""
                                path.removeAll()
                                selectedDetent = .large
                            }
                        } onCancel: {
                            path.removeLast()
                        }
                    case .time:
                        TimeSliderScreen(
                            startAt: $startAt,
                            durationMinutes: $durationMinutes
                        ) {
                            path.removeLast()
                            selectedDetent = .large
                        }
                    }
                }
                .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.large], selection: $selectedDetent)
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(22)
        .onAppear {
            parentID = model.addPlanContext.parentID
            if model.addPlanContext.isGoal {
                startAt = Calendar.autoupdatingCurrent.date(
                    from: Calendar.autoupdatingCurrent.dateComponents(
                        [.year, .month],
                        from: model.selectedDate
                    )
                ) ?? model.selectedDate
                goalEndAt = defaultGoalEndDate(from: startAt)
            } else if let parent = selectedParent {
                    categoryID = parent.categoryID
                    middleCategoryName = parent.middleCategoryName ?? ""
                    subCategoryName = ""
                    let proposed = QuickPlanDraftEngine.roundedUpToHalfHour(.now)
                let latestStart = parent.span.end.addingTimeInterval(
                    -QuickPlanDraftEngine.defaultDuration
                )
                startAt = min(max(proposed, parent.span.start), latestStart)
            } else {
                startAt = QuickPlanDraftEngine.roundedUpToHalfHour(.now)
            }
            durationMinutes = Int(QuickPlanDraftEngine.defaultDuration / 60)
            timelineWindowStart = makeTimelineWindowStart(around: startAt)
            if selectedCategory.isHidden,
               !isGoalSelectableSystemCategory(selectedCategory.id),
               let firstVisible = model.snapshot.categories.first(where: {
                   !$0.isHidden
               }) {
                categoryID = firstVisible.id
            }
            if model.addPlanContext.isGoal {
                autofillGoalTitleIfNeeded(replacing: "")
            }
            titleFocused = false
        }
    }

    private var rootSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule()
                .fill(Color(red: 0.84, green: 0.84, blue: 0.86))
                .frame(width: 36, height: 4)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)

            ScrollView(showsIndicators: false) {
                if model.addPlanContext.isGoal {
                    goalSheetContent
                } else {
                    quickSheetContent
                }
            }
            .scrollDismissesKeyboard(.interactively)

            HStack {
                Button("취소") { dismiss() }
                    .font(.taption(size: 11, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                Spacer()
                Button("추가", action: addPlan)
                    .font(.taption(size: 11, weight: .bold))
                    .foregroundStyle(canAddPlan ? Color.white : Color.tpSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        canAddPlan ? Color.tpInk : Color.tpLine,
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                    .disabled(!canAddPlan)
            }
            .padding(.top, 10)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(Color.white)
    }

    private var quickSheetContent: some View {
        VStack(alignment: .leading, spacing: 13) {
            recentMiddleCategorySection

            goalConnectionPicker
            categoryQuickPicker
            middleCategoryPicker
            subCategoryPicker

            memoTextField(
                label: "메모",
                placeholder: "예: 청계천 산책, 준비물, 체크포인트",
                text: $memoText
            )

            Text("계획명은 중분류 이름으로 추가되고, 입력한 내용은 액션 메모에 연결됩니다.")
                .font(.taption(size: 8.5, weight: .semibold))
                .foregroundStyle(Color.tpSecondary)
                .padding(.top, -8)

            datePickerRow

            MiniTimeSliceEditor(
                startAt: $startAt,
                durationMinutes: $durationMinutes,
                windowStart: timelineWindowStart,
                title: resolvedQuickTitle ?? "중분류를 선택하세요",
                category: selectedCategory
            )
        }
        .padding(.vertical, 4)
    }

    private var goalSheetContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            categoryQuickPicker

            goalTitleField

            goalDurationPicker

            if usesCustomGoalRange {
                customGoalRangeCalendars
            }

            GoalRepeatRulesEditor(rules: $goalRepeatRules)
        }
        .padding(.vertical, 4)
    }

    private var goalTitleField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("루틴 이름")
                    .font(.taption(size: 10.5, weight: .bold))
                    .foregroundStyle(Color.tpInk)
                Text("비워두면 \(selectedCategory.name)")
                    .font(.taption(size: 7.5, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
            }

            HStack(spacing: 7) {
                Text("루틴:")
                    .font(.taption(size: 15, weight: .semibold))
                    .foregroundStyle(Color.tpInk.opacity(0.72))
                TextField("루틴 이름", text: $title)
                    .font(.taption(size: 15, weight: .semibold))
                    .focused($titleFocused)
                    .submitLabel(.done)
                    .onSubmit(addPlan)

                if !title.isEmpty {
                    Button {
                        title = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.tpSecondary.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                Color(red: 0.965, green: 0.965, blue: 0.975),
                in: RoundedRectangle(cornerRadius: 10)
            )
        }
    }

    private var goalDurationPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                DraftChip(
                    title: startAt.formatted(
                        Date.FormatStyle()
                            .year()
                            .month(.abbreviated)
                            .locale(Locale(identifier: "ko_KR"))
                    ),
                    selected: true
                )
                ForEach([1, 3, 6, 12], id: \.self) { months in
                    DraftChip(
                        title: months == 12 ? "1년" : "\(months)개월",
                        selected: !usesCustomGoalRange
                            && goalDurationMonths == months
                    )
                    .onTapGesture {
                        usesCustomGoalRange = false
                        goalDurationMonths = months
                        goalEndAt = defaultGoalEndDate(from: startAt)
                    }
                }
                DraftChip(
                    title: "직접지정",
                    selected: usesCustomGoalRange
                )
                .onTapGesture {
                    usesCustomGoalRange = true
                    if goalEndAt <= startAt {
                        goalEndAt = defaultGoalEndDate(from: startAt)
                    }
                }
            }
        }
    }

    private var customGoalRangeCalendars: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("루틴 기간 직접 지정")
                .font(.taption(size: 10.5, weight: .bold))
                .foregroundStyle(Color.tpInk)

            goalCalendarCard(
                title: "시작일",
                selection: goalStartDayBinding
            )
            goalCalendarCard(
                title: "종료일",
                selection: goalEndDayBinding
            )
        }
    }

    private func goalCalendarCard(
        title: String,
        selection: Binding<Date>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.taption(size: 9.5, weight: .bold))
                .foregroundStyle(Color.tpSecondary)
            DatePicker(
                title,
                selection: selection,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
        }
        .padding(10)
        .background(
            Color(red: 0.965, green: 0.965, blue: 0.975),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    private var recentMiddleCategorySection: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionLabel("최근", caption: "최근 추가한 중분류")
            if recentMiddleCategories.isEmpty {
                Text("아직 추가한 중분류가 없습니다")
                    .font(.taption(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                    .padding(.vertical, 5)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(recentMiddleCategories) { recent in
                            Button {
                                titleFocused = false
                                categoryID = recent.categoryID
                                middleCategoryName = recent.name
                                subCategoryName = ""
                            } label: {
                                Label(
                                    recent.name,
                                    systemImage: recent.category.icon.systemImage
                                )
                                .font(.taption(size: 10, weight: .bold))
                                .foregroundStyle(Color.tpInk)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 7)
                                .background(
                                    categoryID == recent.categoryID
                                        && middleCategoryName == recent.name
                                        ? Color(hex: recent.category.lightHex)
                                        : Color(red: 0.95, green: 0.95, blue: 0.96),
                                    in: RoundedRectangle(cornerRadius: 9)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var goalConnectionPicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionLabel("루틴 연결", caption: "상위 루틴 아래에 계획을 붙입니다")
            if rootPlans.isEmpty {
                Text("연결할 루틴이 없습니다")
                    .font(.taption(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                    .padding(.vertical, 5)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Button {
                            parentID = nil
                        } label: {
                            DraftChip(title: "연결 안 함", selected: parentID == nil)
                        }
                        .buttonStyle(.plain)

                        ForEach(rootPlans) { plan in
                            Button {
                                parentID = parentID == plan.id ? nil : plan.id
                            } label: {
                                DraftChip(
                                    title: goalDisplayTitle(plan.title),
                                    selected: parentID == plan.id
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var datePickerRow: some View {
        Button {
            titleFocused = false
            isCalendarPresented = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.taption(size: 13, weight: .bold))
                Text(formattedSelectedDate)
                    .font(.taption(size: 12.5, weight: .bold))
                Spacer()
                Text("날짜 선택")
                    .font(.taption(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                Image(systemName: "chevron.down")
                    .font(.taption(size: 9, weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
            }
            .foregroundStyle(Color.tpInk)
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background(
                Color(red: 0.965, green: 0.965, blue: 0.975),
                in: RoundedRectangle(cornerRadius: 10)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isCalendarPresented) {
            DatePicker(
                "날짜",
                selection: selectedDayBinding,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
            .padding(14)
            .frame(width: 330)
            .presentationCompactAdaptation(.popover)
        }
    }

    private func addPlan() {
        guard let cleanTitle = resolvedPlanTitle else { return }

        let planID = model.addPlan(
            title: cleanTitle,
            categoryID: categoryID,
            middleCategoryName: middleCategoryName,
            subCategoryName: subCategoryName,
            startAt: startAt,
            duration: selectedDuration,
            parentID: model.addPlanContext.isGoal ? nil : parentID,
            repeatRules: model.addPlanContext.isGoal ? goalRepeatRules : nil
        )
        if !model.addPlanContext.isGoal,
           let planID {
            model.addMemo(
                text: memoText,
                kind: .idea,
                to: planID
            )
        }
        dismiss()
    }

    private var selectedCategory: CategoryDefinition {
        model.snapshot.categories.first { $0.id == categoryID }
            ?? CategoryCatalog.builtIn.first { $0.id == "study" }
            ?? CategoryCatalog.builtIn[0]
    }

    private var resolvedQuickTitle: String? {
        let middleCategory = middleCategoryName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return middleCategory.isEmpty ? nil : middleCategory
    }

    private var resolvedPlanTitle: String? {
        if model.addPlanContext.isGoal {
            let cleanGoal = cleanGoalTitleInput(
                title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? selectedCategory.name
                    : title
            )
            return cleanGoal.isEmpty ? nil : cleanGoal
        }
        return resolvedQuickTitle
    }

    private func cleanGoalTitleInput(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        return GoalRecordPolicy.displayTitle(trimmed)
    }

    private func goalDisplayTitle(_ raw: String) -> String {
        cleanGoalTitleInput(raw).isEmpty
            ? raw
            : cleanGoalTitleInput(raw)
    }

    private var canAddPlan: Bool { resolvedPlanTitle != nil }

    private var visibleCategories: [CategoryDefinition] {
        model.snapshot.categories
            .filter {
                !$0.isHidden || isGoalSelectableSystemCategory($0.id)
            }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    private func isGoalSelectableSystemCategory(_ id: String) -> Bool {
        model.addPlanContext.isGoal
            && GoalCategoryPolicy.systemSelectableCategoryIDs.contains(id)
    }

    private var categoryQuickPicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("대분류")
                    .font(.taption(size: 10.5, weight: .bold))
                    .foregroundStyle(Color.tpInk)
                Text("아이콘으로 빠르게 선택")
                    .font(.taption(size: 7.5, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(visibleCategories) { category in
                        Button {
                            selectCategory(category.id)
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: category.icon.systemImage)
                                    .font(.taption(size: 14, weight: .bold))
                                    .foregroundStyle(Color.tpInk)
                                    .frame(width: 38, height: 34)
                                    .background(
                                        Color(hex: category.lightHex),
                                        in: RoundedRectangle(cornerRadius: 10)
                                    )
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 10)
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
                                .font(.taption(size: 14, weight: .bold))
                                .foregroundStyle(Color.tpSecondary)
                                .frame(width: 38, height: 34)
                                .background(
                                    Color.white,
                                    in: RoundedRectangle(cornerRadius: 10)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10)
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

    private var middleCategoryPicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("중분류")
                    .font(.taption(size: 10.5, weight: .bold))
                    .foregroundStyle(Color.tpInk)
                Text("\(selectedCategory.name) 추천")
                    .font(.taption(size: 7.5, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
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

    private var subCategoryPicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("소분류")
                    .font(.taption(size: 10.5, weight: .bold))
                    .foregroundStyle(Color.tpInk)
                Text("상세 동작")
                    .font(.taption(size: 7.5, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
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

    private func selectCategory(_ newCategoryID: String) {
        titleFocused = false
        let previousCategoryName = selectedCategory.name
        guard categoryID != newCategoryID else { return }
        categoryID = newCategoryID
        if model.addPlanContext.isGoal {
            autofillGoalTitleIfNeeded(replacing: previousCategoryName)
        }
        middleCategoryName = ""
        memoText = ""
        subCategoryName = ""
    }

    private func autofillGoalTitleIfNeeded(replacing oldCategoryName: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let unprefixed: String
        if clean.hasPrefix(GoalRecordPolicy.currentPrefix) {
            unprefixed = clean.dropFirst(GoalRecordPolicy.currentPrefix.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if clean.hasPrefix(GoalRecordPolicy.legacyPrefix) {
            unprefixed = clean.dropFirst(GoalRecordPolicy.legacyPrefix.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            unprefixed = clean
        }
        if unprefixed.isEmpty || unprefixed == oldCategoryName {
            title = selectedCategory.name
        }
    }

    private func memoTextField(
        label: String,
        placeholder: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.taption(size: 10.5, weight: .bold))
                    .foregroundStyle(Color.tpInk)
                Spacer()
                Text("선택한 액션에 연결")
                    .font(.taption(size: 7.5, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
            }
            TextField(placeholder, text: text, axis: .vertical)
                .font(.taption(size: 11.5, weight: .semibold))
                .lineLimit(2...4)
                .textInputAutocapitalization(.sentences)
                .submitLabel(.done)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            Color(red: 0.965, green: 0.965, blue: 0.975),
            in: RoundedRectangle(cornerRadius: 10)
        )
    }

    private var selectedParent: PlanRecord? {
        guard let parentID else { return nil }
        return model.snapshot.plans.first { $0.id == parentID }
    }

    private var rootPlans: [PlanRecord] {
        model.snapshot.plans
            .filter { plan in
                guard plan.parentID == nil,
                      plan.status != .skipped else {
                    return false
                }
                return GoalRecordPolicy.isGoal(plan)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(8)
            .map { $0 }
    }

    private var recentMiddleCategories: [RecentMiddleCategory] {
        let categories = Dictionary(
            uniqueKeysWithValues: visibleCategories.map { ($0.id, $0) }
        )
        var seen = Set<String>()
        return model.snapshot.plans
            .sorted { $0.updatedAt > $1.updatedAt }
            .compactMap { plan -> RecentMiddleCategory? in
                guard let category = categories[plan.categoryID],
                      let rawName = plan.middleCategoryName else {
                    return nil
                }
                let name = rawName.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                let key = "\(category.id)|\(name)"
                guard !name.isEmpty, seen.insert(key).inserted else {
                    return nil
                }
                return RecentMiddleCategory(category: category, name: name)
            }
            .prefix(6)
            .map { $0 }
    }

    private var selectedDuration: TimeInterval {
        if model.addPlanContext.isGoal {
            if usesCustomGoalRange {
                let calendar = Calendar.autoupdatingCurrent
                let start = calendar.startOfDay(for: startAt)
                let endInclusive = calendar.startOfDay(for: goalEndAt)
                let endExclusive = calendar.date(
                    byAdding: .day,
                    value: 1,
                    to: max(start, endInclusive)
                ) ?? max(start, endInclusive).addingTimeInterval(86_400)
                return max(86_400, endExclusive.timeIntervalSince(start))
            }
            let end = Calendar.autoupdatingCurrent.date(
                byAdding: .month,
                value: goalDurationMonths,
                to: startAt
            ) ?? startAt.addingTimeInterval(
                TimeInterval(goalDurationMonths * 30 * 86_400)
            )
            return max(86_400, end.timeIntervalSince(startAt))
        }
        return TimeInterval(durationMinutes * 60)
    }

    private var goalStartDayBinding: Binding<Date> {
        Binding(
            get: { startAt },
            set: { newStart in
                let calendar = Calendar.autoupdatingCurrent
                startAt = calendar.startOfDay(for: newStart)
                if goalEndAt < startAt {
                    goalEndAt = startAt
                }
            }
        )
    }

    private var goalEndDayBinding: Binding<Date> {
        Binding(
            get: { goalEndAt },
            set: { newEnd in
                let calendar = Calendar.autoupdatingCurrent
                goalEndAt = max(
                    calendar.startOfDay(for: newEnd),
                    calendar.startOfDay(for: startAt)
                )
            }
        )
    }

    private func defaultGoalEndDate(from start: Date) -> Date {
        Calendar.autoupdatingCurrent.date(
            byAdding: .month,
            value: goalDurationMonths,
            to: Calendar.autoupdatingCurrent.startOfDay(for: start)
        ) ?? Calendar.autoupdatingCurrent.startOfDay(for: start)
            .addingTimeInterval(TimeInterval(goalDurationMonths * 30 * 86_400))
    }

    private var selectedDayBinding: Binding<Date> {
        Binding(
            get: { startAt },
            set: { newDay in
                let calendar = Calendar.autoupdatingCurrent
                let time = calendar.dateComponents(
                    [.hour, .minute, .second],
                    from: startAt
                )
                var day = calendar.dateComponents(
                    [.year, .month, .day],
                    from: newDay
                )
                day.hour = time.hour
                day.minute = time.minute
                day.second = 0
                startAt = calendar.date(from: day) ?? newDay
                timelineWindowStart = makeTimelineWindowStart(around: startAt)
            }
        )
    }

    private var formattedSelectedDate: String {
        startAt.formatted(
            Date.FormatStyle()
                .year()
                .month(.wide)
                .day()
                .weekday(.abbreviated)
                .locale(Locale(identifier: "ko_KR"))
        )
    }

    private func makeTimelineWindowStart(around date: Date) -> Date {
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(86_400)
        let latest = dayEnd.addingTimeInterval(-6 * 3_600)
        let intended = date.addingTimeInterval(-90 * 60)
        let halfHour: TimeInterval = 30 * 60
        let rounded = Date(
            timeIntervalSinceReferenceDate:
                floor(intended.timeIntervalSinceReferenceDate / halfHour)
                    * halfHour
        )
        return min(max(dayStart, rounded), latest)
    }

    private func sectionLabel(_ title: String, caption: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.taption(size: 10.5, weight: .bold))
                .foregroundStyle(Color.tpInk)
            Text(caption)
                .font(.taption(size: 7.5, weight: .semibold))
                .foregroundStyle(Color.tpSecondary)
        }
    }
}

private struct RecentMiddleCategory: Identifiable {
    let category: CategoryDefinition
    let name: String

    var id: String { "\(category.id)|\(name)" }
    var categoryID: String { category.id }
}

struct GoalRepeatRulesEditor: View {
    @Binding var rules: [GoalRepeatRule]

    private let weekdayOrder: [(value: Int, label: String)] = [
        (2, "월"), (3, "화"), (4, "수"), (5, "목"),
        (6, "금"), (7, "토"), (1, "일"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("반복")
                    .font(.taption(size: 10.5, weight: .bold))
                    .foregroundStyle(Color.tpInk)
                Text("요일별 · 시간별")
                    .font(.taption(size: 7.5, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
            }

            if rules.isEmpty {
                Text("예: 주중 23:00 취침 → 다음날 06:30 기상, 주말 01:00 → 10:00")
                    .font(.taption(size: 8.5, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                presetButton("주중", weekdays: [2, 3, 4, 5, 6],
                             start: 23 * 60, end: 6 * 60 + 30)
                presetButton("주말", weekdays: [7, 1],
                             start: 1 * 60, end: 10 * 60)
                presetButton("매일", weekdays: [1, 2, 3, 4, 5, 6, 7],
                             start: 9 * 60, end: 10 * 60)
            }

            ForEach(rules.indices, id: \.self) { index in
                repeatRuleCard(
                    rule: ruleBinding(index),
                    index: index
                )
            }
        }
        .padding(11)
        .draftCard(radius: 13)
    }

    private func presetButton(
        _ title: String,
        weekdays: Set<Int>,
        start: Int,
        end: Int
    ) -> some View {
        Button {
            rules.append(
                GoalRepeatRule(
                    name: title,
                    weekdays: weekdays,
                    startMinuteOfDay: start,
                    endMinuteOfDay: end
                )
            )
        } label: {
            Label(title, systemImage: "repeat")
                .font(.taption(size: 8.5, weight: .bold))
                .foregroundStyle(Color.tpInk)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    Color(red: 0.965, green: 0.965, blue: 0.975),
                    in: RoundedRectangle(cornerRadius: 9)
                )
        }
        .buttonStyle(.plain)
    }

    private func repeatRuleCard(
        rule: Binding<GoalRepeatRule>,
        index: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(GoalRepeatRuleFormatter.summary(rule.wrappedValue))
                    .font(.taption(size: 9.5, weight: .bold))
                    .foregroundStyle(Color.tpInk)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button {
                    rules.remove(at: index)
                } label: {
                    Image(systemName: "trash")
                        .font(.taption(size: 9.5, weight: .bold))
                        .foregroundStyle(Color.red.opacity(0.78))
                }
                .buttonStyle(.plain)
            }

            TextField("반복 이름 · 예: 주중 수면", text: nameBinding(rule))
                .font(.taption(size: 9.5, weight: .semibold))
                .textInputAutocapitalization(.sentences)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 4) {
                ForEach(weekdayOrder, id: \.value) { day in
                    Button {
                        toggle(day.value, in: rule)
                    } label: {
                        Text(day.label)
                            .font(.taption(size: 8.5, weight: .black))
                            .foregroundStyle(
                                rule.wrappedValue.weekdays.contains(day.value)
                                    ? Color.white
                                    : Color.tpSecondary
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                rule.wrappedValue.weekdays.contains(day.value)
                                    ? Color.tpInk
                                    : Color.white,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                repeatTimePicker(
                    title: "시작",
                    selection: timeBinding(rule, isStart: true)
                )
                repeatTimePicker(
                    title: "종료",
                    selection: timeBinding(rule, isStart: false)
                )
            }
        }
        .padding(9)
        .background(
            Color(red: 0.965, green: 0.965, blue: 0.975),
            in: RoundedRectangle(cornerRadius: 11)
        )
    }

    private func repeatTimePicker(
        title: String,
        selection: Binding<Date>
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.taption(size: 8.2, weight: .bold))
                .foregroundStyle(Color.tpSecondary)
            DatePicker(
                title,
                selection: selection,
                displayedComponents: .hourAndMinute
            )
            .labelsHidden()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
    }

    private func ruleBinding(_ index: Int) -> Binding<GoalRepeatRule> {
        Binding(
            get: { rules[index] },
            set: { rules[index] = $0 }
        )
    }

    private func nameBinding(
        _ rule: Binding<GoalRepeatRule>
    ) -> Binding<String> {
        Binding(
            get: { rule.wrappedValue.name ?? "" },
            set: { newValue in
                var value = rule.wrappedValue
                let clean = newValue.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                value.name = clean.isEmpty ? nil : clean
                rule.wrappedValue = value
            }
        )
    }

    private func timeBinding(
        _ rule: Binding<GoalRepeatRule>,
        isStart: Bool
    ) -> Binding<Date> {
        Binding(
            get: {
                date(fromMinute: isStart
                     ? rule.wrappedValue.startMinuteOfDay
                     : rule.wrappedValue.endMinuteOfDay)
            },
            set: { date in
                var value = rule.wrappedValue
                let minute = minuteOfDay(from: date)
                if isStart {
                    value.startMinuteOfDay = minute
                } else {
                    value.endMinuteOfDay = minute
                }
                rule.wrappedValue = value
            }
        )
    }

    private func toggle(
        _ weekday: Int,
        in rule: Binding<GoalRepeatRule>
    ) {
        var value = rule.wrappedValue
        if value.weekdays.contains(weekday) {
            value.weekdays.remove(weekday)
        } else {
            value.weekdays.insert(weekday)
        }
        rule.wrappedValue = value
    }

    private func date(fromMinute minute: Int) -> Date {
        let clamped = min(23 * 60 + 59, max(0, minute))
        let calendar = Calendar.autoupdatingCurrent
        return calendar.date(
            bySettingHour: clamped / 60,
            minute: clamped % 60,
            second: 0,
            of: .now
        ) ?? .now
    }

    private func minuteOfDay(from date: Date) -> Int {
        let calendar = Calendar.autoupdatingCurrent
        return calendar.component(.hour, from: date) * 60
            + calendar.component(.minute, from: date)
    }
}

enum GoalRepeatRuleFormatter {
    static func summary(_ rules: [GoalRepeatRule]?) -> String? {
        let rules = rules ?? []
        guard !rules.isEmpty else { return nil }
        let visible = rules.prefix(2).map(summary)
        let suffix = rules.count > 2 ? " 외 \(rules.count - 2)개" : ""
        return visible.joined(separator: " · ") + suffix
    }

    static func summary(_ rule: GoalRepeatRule) -> String {
        let name = rule.name.map { "\($0) · " } ?? ""
        let start = timeText(rule.startMinuteOfDay)
        let end = timeText(rule.endMinuteOfDay)
        let endPrefix = rule.endMinuteOfDay <= rule.startMinuteOfDay
            ? "다음날 "
            : ""
        return "\(name)\(weekdayText(rule.weekdays)) \(start)→\(endPrefix)\(end)"
    }

    static func weekdayText(_ weekdays: Set<Int>) -> String {
        let normalized = Set(weekdays.filter { (1...7).contains($0) })
        if normalized == [1, 2, 3, 4, 5, 6, 7] { return "매일" }
        if normalized == [2, 3, 4, 5, 6] { return "주중" }
        if normalized == [1, 7] { return "주말" }
        let labels = [
            2: "월", 3: "화", 4: "수", 5: "목",
            6: "금", 7: "토", 1: "일",
        ]
        return [2, 3, 4, 5, 6, 7, 1]
            .filter { normalized.contains($0) }
            .compactMap { labels[$0] }
            .joined(separator: "·")
    }

    static func timeText(_ minute: Int) -> String {
        let clamped = min(23 * 60 + 59, max(0, minute))
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }
}

private struct MiniTimeSliceEditor: View {
    @Binding var startAt: Date
    @Binding var durationMinutes: Int
    let windowStart: Date
    let title: String
    let category: CategoryDefinition

    @State private var resizeOrigin: TimeSpan?
    @State private var moveOrigin: TimeSpan?
    @State private var isMoving = false

    private let windowDuration: TimeInterval = 6 * 3_600

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("시간")
                    .font(.taption(size: 10.5, weight: .bold))
                Text("30분 기본 · 5분 단위 조정")
                    .font(.taption(size: 7.5, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                Spacer()
                Text(timeRangeLabel)
                    .font(.taption(size: 10.5, weight: .bold))
            }

            GeometryReader { proxy in
                let width = max(1, proxy.size.width)
                let lower = xPosition(for: span.start, width: width)
                let upper = xPosition(for: span.end, width: width)
                let barWidth = max(34, upper - lower)

                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 11)
                        .fill(Color(red: 0.965, green: 0.965, blue: 0.975))

                    ForEach(0...12, id: \.self) { tick in
                        let x = width * CGFloat(tick) / 12
                        Rectangle()
                            .fill(Color.tpLine.opacity(tick.isMultiple(of: 2) ? 0.9 : 0.45))
                            .frame(width: tick.isMultiple(of: 2) ? 0.8 : 0.5, height: 70)
                            .position(x: x, y: 35)

                        if tick.isMultiple(of: 2), tick < 12 {
                            Text(tickLabel(tick))
                                .font(.taption(size: 8, weight: .semibold))
                                .foregroundStyle(Color.tpSecondary)
                                .position(x: min(width - 17, max(17, x)), y: 10)
                        }
                    }

                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color(hex: category.lightHex))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9)
                                .stroke(
                                    Color(hex: category.darkHex),
                                    lineWidth: isMoving ? 2.5 : 1.2
                                )
                        }
                        .frame(width: barWidth, height: 36)
                        .overlay(alignment: .center) {
                            Text(title)
                                .font(.taption(size: 9.5, weight: .bold))
                                .foregroundStyle(Color.tpInk)
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                        }
                        .position(
                            x: min(width - barWidth / 2, lower + barWidth / 2),
                            y: 45
                        )
                        .contentShape(Rectangle())
                        .gesture(moveGesture(width: width))

                    sliderHandle
                        .position(x: lower, y: 45)
                        .gesture(resizeGesture(.start, width: width))
                    sliderHandle
                        .position(x: upper, y: 45)
                        .gesture(resizeGesture(.end, width: width))
                }
            }
            .frame(height: 70)

            HStack(spacing: 5) {
                Image(systemName: "arrow.left.and.right")
                Text("양 끝 드래그: 5분 조정")
                Text("·")
                Image(systemName: "hand.tap")
                Text("막대를 꾹 누른 뒤 이동")
            }
            .font(.taption(size: 8.5, weight: .semibold))
            .foregroundStyle(isMoving ? Color.tpInk : Color.tpSecondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("미니 간트 시간 슬라이더")
    }

    private var sliderHandle: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Color.white)
            .frame(width: 15, height: 32)
            .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
            .overlay {
                Capsule()
                    .fill(Color.tpSecondary.opacity(0.65))
                    .frame(width: 2.5, height: 14)
            }
            .contentShape(Rectangle().inset(by: -8))
    }

    private var span: TimeSpan {
        TimeSpan(
            start: startAt,
            end: startAt.addingTimeInterval(
                TimeInterval(max(5, durationMinutes) * 60)
            )
        )
    }

    private var windowBounds: TimeSpan {
        TimeSpan(
            start: windowStart,
            end: windowStart.addingTimeInterval(windowDuration)
        )
    }

    private var timeRangeLabel: String {
        "\(span.start.formatted(date: .omitted, time: .shortened)) – \(span.end.formatted(date: .omitted, time: .shortened)) · \(durationMinutes)분"
    }

    private func tickLabel(_ tick: Int) -> String {
        windowStart.addingTimeInterval(TimeInterval(tick) * 30 * 60)
            .formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute())
    }

    private func xPosition(for date: Date, width: CGFloat) -> CGFloat {
        let fraction = date.timeIntervalSince(windowBounds.start)
            / max(1, windowBounds.duration)
        return width * CGFloat(max(0, min(1, fraction)))
    }

    private func resizeGesture(
        _ handle: TimeSliderHandle,
        width: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if resizeOrigin == nil {
                    resizeOrigin = span
                }
                guard let origin = resizeOrigin else { return }
                let delta = Double(value.translation.width / width)
                    * windowDuration
                let adjusted = TimeSliderEngine.adjust(
                    origin,
                    handle: handle,
                    delta: delta,
                    snapInterval: QuickPlanDraftEngine.adjustmentStep,
                    bounds: windowBounds,
                    minimumDuration: QuickPlanDraftEngine.adjustmentStep
                )
                apply(adjusted)
            }
            .onEnded { _ in
                resizeOrigin = nil
            }
    }

    private func moveGesture(width: CGFloat) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35, maximumDistance: 12)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                switch value {
                case .first(true):
                    if !isMoving {
                        isMoving = true
                        UIImpactFeedbackGenerator(style: .medium)
                            .impactOccurred()
                    }
                case .second(true, let drag):
                    guard let drag else { return }
                    if moveOrigin == nil { moveOrigin = span }
                    guard let origin = moveOrigin else { return }
                    let delta = Double(drag.translation.width / width)
                        * windowDuration
                    let adjusted = TimeSliderEngine.adjust(
                        origin,
                        handle: .body,
                        delta: delta,
                        snapInterval: QuickPlanDraftEngine.adjustmentStep,
                        bounds: windowBounds,
                        minimumDuration: QuickPlanDraftEngine.adjustmentStep
                    )
                    apply(adjusted)
                default:
                    break
                }
            }
            .onEnded { _ in
                moveOrigin = nil
                isMoving = false
            }
    }

    private func apply(_ adjusted: TimeSpan) {
        startAt = adjusted.start
        durationMinutes = max(
            5,
            Int((adjusted.duration / 60).rounded())
        )
    }
}

private enum AddRoute: Hashable {
    case customCategory
    case time
}

private struct CustomCategoryScreen: View {
    @State private var name = "봉사"
    @State private var selectedIcon = CategoryIcon.family
    @State private var selectedColor = 1

    let onSave: (String, CategoryIcon, String) -> Void
    let onCancel: () -> Void

    private let icons: [CategoryIcon] = [
        .briefcase, .building, .book, .graduation, .target, .award,
        .stroller, .family, .shield, .health, .exercise, .sleep,
        .performance, .music, .travel, .location, .home, .meal,
        .cafe, .pet, .shopping, .nature, .calendar, .event, .memo,
        .movement, .activity, .relationship, .work, .community,
        .student, .exam, .military, .athlete, .pregnancy, .caregiver,
        .government, .food,
    ]
    private let colors: [Color] = [
        .tpProject, Color(red: 0.85, green: 0.90, blue: 0.78), .tpExercise,
        .tpTravel, .tpStudy, .tpRelationship,
    ]

    var body: some View {
        VStack(spacing: 0) {
            pickerHeader("새 대분류", trailing: "취소", action: onCancel)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 9) {
                    HStack(spacing: 9) {
                        Image(systemName: selectedIcon.systemImage)
                            .font(.taption(size: 18))
                            .foregroundStyle(Color(red: 0.33, green: 0.46, blue: 0.24))
                            .frame(width: 34, height: 34)
                            .background(colors[selectedColor], in: RoundedRectangle(cornerRadius: 11))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("미리보기")
                                .font(.taption(size: 9.5))
                                .foregroundStyle(Color.tpSecondary)
                            Text(name.isEmpty ? "새 대분류" : name)
                                .font(.taption(size: 14, weight: .bold))
                        }
                        Spacer()
                    }
                    .padding(13)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 15))

                    HStack {
                        Text("이름")
                            .font(.taption(size: 11))
                            .foregroundStyle(Color.tpSecondary)
                        TextField("대분류 이름", text: $name)
                            .font(.taption(size: 13, weight: .bold))
                            .multilineTextAlignment(.trailing)
                    }
                    .padding(11)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12))

                    VStack(alignment: .leading, spacing: 9) {
                        Text("아이콘 · \(CategoryIcon.allCases.count)개")
                            .font(.taption(size: 11, weight: .bold))
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 5) {
                            ForEach(icons, id: \.self) { icon in
                                Button {
                                    selectedIcon = icon
                                } label: {
                                    Image(systemName: icon.systemImage)
                                        .font(.taption(size: 15))
                                        .foregroundStyle(selectedIcon == icon ? Color.white : Color.tpSecondary)
                                        .frame(maxWidth: .infinity, minHeight: 31)
                                        .background(
                                            selectedIcon == icon ? Color.tpInk : Color(red: 0.94, green: 0.94, blue: 0.95),
                                            in: RoundedRectangle(cornerRadius: 9)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(11)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 13))

                    VStack(alignment: .leading, spacing: 9) {
                        Text("색상")
                            .font(.taption(size: 11, weight: .bold))
                        HStack {
                            ForEach(colors.indices, id: \.self) { index in
                                Button {
                                    selectedColor = index
                                } label: {
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(colors[index])
                                        .frame(width: 31, height: 31)
                                        .overlay {
                                            if selectedColor == index {
                                                RoundedRectangle(cornerRadius: 10)
                                                    .stroke(Color.tpInk, lineWidth: 2)
                                                    .padding(-3)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                                if index != colors.indices.last { Spacer() }
                            }
                        }
                    }
                    .padding(11)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 13))

                    Button {
                        onSave(name, selectedIcon, colorHex)
                    } label: {
                        Text("대분류 추가")
                            .font(.taption(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Color.tpInk, in: RoundedRectangle(cornerRadius: 13))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .background(Color.tpBackground)
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var colorHex: String {
        ["#BEDAE3", "#D9E6C7", "#FED5CF", "#F1B598", "#D3C7E6", "#F4D7E7"][
            selectedColor
        ]
    }
}

private struct TimeSliderScreen: View {
    @Binding var startAt: Date
    @Binding var durationMinutes: Int
    let onDone: () -> Void

    @State private var dragOriginSpan: TimeSpan?
    @State private var dragStartedAt: Date?
    @State private var previousFeedbackDate: Date?
    @State private var isPrecisionMode = false

    var body: some View {
        VStack(spacing: 0) {
            pickerHeader("시간 선택", trailing: "완료", action: onDone)

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.tpStudyDark).frame(width: 12, height: 12)
                    Text("영어 공부").font(.taption(size: 16, weight: .bold))
                }

                HStack(alignment: .firstTextBaseline) {
                    Text(timeRangeLabel)
                        .font(.taption(size: 24, weight: .black))
                    Spacer()
                    Text(durationLabel)
                        .font(.taption(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.tpSecondary)
                }

                GeometryReader { proxy in
                    let availableWidth = max(1, proxy.size.width - 12)
                    let lower =
                        xPosition(for: span.start, width: availableWidth) + 6
                    let upper =
                        xPosition(for: span.end, width: availableWidth) + 6
                    let barWidth = max(16, upper - lower)
                    ZStack {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color(red: 0.96, green: 0.96, blue: 0.97))
                        HStack(spacing: 0) {
                            ForEach(0..<24, id: \.self) { index in
                                Rectangle()
                                    .fill(index.isMultiple(of: 4) ? Color(red: 0.85, green: 0.85, blue: 0.87) : Color(red: 0.93, green: 0.93, blue: 0.94))
                                    .frame(width: 0.5)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.tpStudy)
                            .frame(width: barWidth, height: 38)
                            .position(x: lower + barWidth / 2, y: 28)
                            .gesture(
                                dragGesture(.body, width: availableWidth)
                            )
                        sliderHandle
                            .position(x: lower, y: 28)
                            .gesture(
                                dragGesture(.start, width: availableWidth)
                            )
                        sliderHandle
                            .position(x: upper, y: 28)
                            .gesture(
                                dragGesture(.end, width: availableWidth)
                            )
                        Text(
                            span.start.formatted(
                                date: .omitted,
                                time: .shortened
                            )
                        )
                            .font(.taption(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.tpInk, in: RoundedRectangle(cornerRadius: 10))
                            .position(
                                x: min(
                                    proxy.size.width - 31,
                                    max(31, lower)
                                ),
                                y: -5
                            )
                    }
                }
                .frame(height: 56)
                .padding(.horizontal, 6)
                .padding(.top, 18)

                HStack {
                    ForEach(["00", "04", "08", "12", "16", "20", "24"], id: \.self) {
                        Text($0).frame(maxWidth: .infinity)
                    }
                }
                .font(.taption(size: 10))
                .foregroundStyle(Color.tpSecondary)

                HStack(spacing: 6) {
                    ForEach([30, 60, 90, 120], id: \.self) { minutes in
                        Button {
                            durationMinutes = minutes
                        } label: {
                            Text(presetLabel(minutes))
                                .font(.taption(size: 9.5, weight: .bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .foregroundStyle(
                                    durationMinutes == minutes
                                        ? Color.white : Color.tpSecondary
                                )
                                .background(
                                    durationMinutes == minutes
                                        ? Color.tpStudyDark
                                        : Color(
                                            red: 0.94,
                                            green: 0.94,
                                            blue: 0.95
                                        ),
                                    in: RoundedRectangle(cornerRadius: 9)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: 6) {
                    hint("슬라이드", "1분 단위\n이동")
                    hint("빠르게", "10분 단위\n반올림 스냅")
                    hint(
                        "꾹 누르기",
                        isPrecisionMode
                            ? "정밀 조정\n사용 중"
                            : "정밀 조정\n1분 단위"
                    )
                }

                Button(action: onDone) {
                    Text("완료")
                        .font(.taption(size: 14.5, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color.tpInk, in: RoundedRectangle(cornerRadius: 13))
                }
                .buttonStyle(.plain)
            }
            .padding(18)
            Spacer()
        }
        .background(Color.white)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var sliderHandle: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(.white)
            .frame(width: 15, height: 30)
            .shadow(color: .black.opacity(0.30), radius: 3, y: 1)
            .overlay {
                Capsule().fill(Color(red: 0.79, green: 0.79, blue: 0.81)).frame(width: 2.5, height: 14)
            }
    }

    private var span: TimeSpan {
        TimeSpan(
            start: startAt,
            end: startAt.addingTimeInterval(
                TimeInterval(max(1, durationMinutes) * 60)
            )
        )
    }

    private var dayBounds: TimeSpan {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: startAt)
        let end = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(86_400)
        return TimeSpan(start: start, end: end)
    }

    private var timeRangeLabel: String {
        "\(span.start.formatted(date: .omitted, time: .shortened)) → \(span.end.formatted(date: .omitted, time: .shortened))"
    }

    private var durationLabel: String {
        let hours = durationMinutes / 60
        let minutes = durationMinutes % 60
        if hours == 0 { return "\(minutes)분" }
        if minutes == 0 { return "\(hours)시간" }
        return "\(hours)시간 \(minutes)분"
    }

    private func presetLabel(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)분" }
        if minutes.isMultiple(of: 60) { return "\(minutes / 60)시간" }
        return "\(minutes / 60)시간 \(minutes % 60)분"
    }

    private func xPosition(for date: Date, width: CGFloat) -> CGFloat {
        let fraction = date.timeIntervalSince(dayBounds.start)
            / max(1, dayBounds.duration)
        return width * CGFloat(max(0, min(1, fraction)))
    }

    private func dragGesture(
        _ handle: TimeSliderHandle,
        width: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let now = Date.now
                if dragOriginSpan == nil {
                    dragOriginSpan = span
                    dragStartedAt = now
                    previousFeedbackDate = handle == .end
                        ? span.end : span.start
                }
                guard let origin = dragOriginSpan,
                      let began = dragStartedAt else {
                    return
                }
                let elapsed = max(0.016, now.timeIntervalSince(began))
                let velocity = Double(value.translation.width) / elapsed
                let precision = elapsed >= 0.35
                isPrecisionMode = precision
                let delta = Double(value.translation.width / max(1, width))
                    * dayBounds.duration
                let adjusted = TimeSliderEngine.adjust(
                    origin,
                    handle: handle,
                    delta: delta,
                    velocityPointsPerSecond: velocity,
                    isLongPressPrecision: precision,
                    bounds: dayBounds,
                    minimumDuration: 10 * 60
                )
                if let previousFeedbackDate {
                    let current = handle == .end
                        ? adjusted.end : adjusted.start
                    if TimeSliderEngine.crossedTenMinuteTick(
                        previous: previousFeedbackDate,
                        current: current
                    ) {
                        UISelectionFeedbackGenerator().selectionChanged()
                        self.previousFeedbackDate = current
                    }
                }
                apply(adjusted)
            }
            .onEnded { _ in
                dragOriginSpan = nil
                dragStartedAt = nil
                previousFeedbackDate = nil
                isPrecisionMode = false
            }
    }

    private func apply(_ adjusted: TimeSpan) {
        startAt = adjusted.start
        durationMinutes = max(
            1,
            Int((adjusted.duration / 60).rounded())
        )
    }

    private func hint(_ title: String, _ caption: String) -> some View {
        VStack(spacing: 3) {
            Text(title).font(.taption(size: 11, weight: .bold))
            Text(caption)
                .font(.taption(size: 9.5))
                .foregroundStyle(Color.tpSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(Color(red: 0.96, green: 0.96, blue: 0.97), in: RoundedRectangle(cornerRadius: 11))
    }
}

private func pickerHeader(
    _ title: String,
    trailing: String,
    action: @escaping () -> Void
) -> some View {
    HStack {
        Text(title)
            .font(.taption(size: 19, weight: .bold))
        Spacer()
        Button(trailing, action: action)
            .font(.taption(size: 12, weight: .semibold))
            .foregroundStyle(Color.tpSecondary)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 12)
    .background(Color.white)
    .overlay(alignment: .bottom) { Rectangle().fill(Color.tpLine).frame(height: 0.5) }
}

#Preview {
    AddPlanSheet(model: AppModel())
}
