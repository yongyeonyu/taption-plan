import SwiftUI

struct AddPlanSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel

    @State private var title = ""
    @State var categoryID = "study"
    @State var middleCategoryName = ""
    @State var subCategoryName = ""
    @State private var memoText = ""
    @State private var place: PlanPlace?
    @State private var spendText = ""
    @State private var durationMinutes = 30
    @State private var goalDurationMonths = 12
    @State private var usesCustomGoalRange = false
    @State private var goalEndAt = Date.now
    @State private var goalRepeatRules: [GoalRepeatRule] = []
    @State private var startAt = Date.now
    @State private var timelineWindowStart = Date.now
    @State private var parentID: UUID?
    @State var path: [AddRoute] = []
    @State var selectedDetent: PresentationDetent = .large
    @State private var isCalendarPresented = false
    @FocusState var titleFocused: Bool
    @State private var textSuggestion: PlanTextSuggestion?
    @State private var autoFilledTitle: String?
    @State private var autoFilledMemo: String?
    @State private var textSuggestionTask: Task<Void, Never>?

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
            requestTextSuggestion()
        }
        .onChange(of: categoryID) { requestTextSuggestion() }
        .onChange(of: middleCategoryName) { requestTextSuggestion() }
        .onChange(of: subCategoryName) { requestTextSuggestion() }
        .onChange(of: durationMinutes) { requestTextSuggestion() }
        .onDisappear { textSuggestionTask?.cancel() }
    }

    /// 지원 기기에서만 추천을 받는다. 미지원 기기는 아무것도 채우지 않는다.
    private func requestTextSuggestion() {
        textSuggestionTask?.cancel()
        guard PlanTextSuggester.isAvailable else { return }
        let context = PlanTextContext(
            categoryName: selectedCategory.name,
            middleCategoryName: middleCategoryName,
            subCategoryName: subCategoryName,
            startAt: startAt,
            durationMinutes: durationMinutes,
            recentTitles: recentPlanTitles,
            isGoal: model.addPlanContext.isGoal
        )
        textSuggestionTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled,
                  let suggestion = await PlanTextSuggester.suggest(for: context),
                  !Task.isCancelled else { return }
            applyTextSuggestion(suggestion)
        }
    }

    private var recentPlanTitles: [String] {
        var seen = Set<String>()
        return model.snapshot.plans.reversed()
            .map(\.title)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(PlanTextSuggestionFormat.maxRecentTitles)
            .map { $0 }
    }

    /// 비어 있거나 이전에 자동으로 채운 값만 바꾼다. 사용자가 쓴 값은 그대로 둔다.
    private func applyTextSuggestion(_ suggestion: PlanTextSuggestion) {
        textSuggestion = suggestion
        if model.addPlanContext.isGoal {
            if let first = suggestion.titles.first,
               title.isEmpty || title == selectedCategory.name || title == autoFilledTitle {
                title = first
                autoFilledTitle = first
            }
        } else if !suggestion.memo.isEmpty,
                  memoText.isEmpty || memoText == autoFilledMemo {
            memoText = suggestion.memo
            autoFilledMemo = suggestion.memo
        }
    }

    private func chooseSuggestion(_ candidate: String) {
        if model.addPlanContext.isGoal {
            title = candidate
            autoFilledTitle = nil
        } else {
            memoText = candidate
            autoFilledMemo = nil
        }
    }

    @ViewBuilder
    private var textSuggestionChips: some View {
        if let titles = textSuggestion?.titles, !titles.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: TaptionSpacing.snug) {
                    Image(systemName: "sparkles")
                        .font(.taption(size: 10, weight: .bold))
                        .foregroundStyle(Color.tpSecondary)
                        .accessibilityHidden(true)
                    ForEach(titles, id: \.self) { candidate in
                        Button {
                            chooseSuggestion(candidate)
                        } label: {
                            Text(candidate)
                                .font(.taption(size: 10, weight: .semibold))
                                .foregroundStyle(Color.tpInk)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .frame(minHeight: TaptionMenuMetrics.minimumHitSize)
                                .background(Color.tpFieldFill, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(AppLanguagePreference.text(korean: "추천 입력 \(candidate)", english: "Use suggestion \(candidate)"))
                    }
                }
            }
            .padding(.top, -6)
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
                        in: RoundedRectangle(cornerRadius: TaptionRadius.field)
                    )
                    .disabled(!canAddPlan)
            }
            .padding(.top, 10)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(Color.tpCard)
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
            textSuggestionChips

            Text("계획명은 중분류 이름으로 추가되고, 입력한 내용은 액션 메모에 연결됩니다.")
                .font(.taption(size: 8.5, weight: .semibold))
                .foregroundStyle(Color.tpSecondary)
                .padding(.top, -8)

            datePickerRow
            PlanSpotFields(model: model, place: $place, spendText: $spendText)

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
            textSuggestionChips

            goalDurationPicker

            if usesCustomGoalRange {
                customGoalRangeCalendars
            }

            GoalRepeatRulesEditor(rules: $goalRepeatRules)
        }
        .padding(.vertical, 4)
    }

    private var goalTitleField: some View {
        VStack(alignment: .leading, spacing: TaptionSpacing.snug) {
            HStack(spacing: TaptionSpacing.snug) {
                Text("루틴 이름")
                    .font(.taption(size: 10.5, weight: .bold))
                    .foregroundStyle(Color.tpInk)
                Text("비워두면 \(selectedCategory.name)")
                    .font(.taption(size: 7.5, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
            }

            HStack(spacing: TaptionSpacing.cozy) {
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
                    .accessibilityLabel("제목 지우기")
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                Color.tpFieldFill,
                in: RoundedRectangle(cornerRadius: TaptionRadius.field)
            )
        }
    }

    private var goalDurationPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: TaptionSpacing.cozy) {
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
                    .accessibilityAddTraits(.isButton)
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
                .accessibilityAddTraits(.isButton)
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
        VStack(alignment: .leading, spacing: TaptionSpacing.snug) {
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
            Color.tpFieldFill,
            in: RoundedRectangle(cornerRadius: TaptionRadius.panel)
        )
    }

    private var recentMiddleCategorySection: some View {
        VStack(alignment: .leading, spacing: TaptionSpacing.compact) {
            sectionLabel("최근", caption: "최근 추가한 중분류")
            if recentMiddleCategories.isEmpty {
                Text("아직 추가한 중분류가 없습니다")
                    .font(.taption(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                    .padding(.vertical, 5)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: TaptionSpacing.snug) {
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
                                        : Color.tpControlFillSoft,
                                    in: RoundedRectangle(cornerRadius: TaptionRadius.control)
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
        VStack(alignment: .leading, spacing: TaptionSpacing.compact) {
            sectionLabel("루틴 연결", caption: "상위 루틴 아래에 계획을 붙입니다")
            if rootPlans.isEmpty {
                Text("연결할 루틴이 없습니다")
                    .font(.taption(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                    .padding(.vertical, 5)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: TaptionSpacing.snug) {
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
            HStack(spacing: TaptionSpacing.regular) {
                Image(systemName: "calendar")
                    .font(.taption(size: 13, weight: .bold))
                Text(formattedSelectedDate)
                    .font(.taption(size: 12.5, weight: .bold))
                Spacer()
                Text("날짜 선택")
                    .font(.taption(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                Image(systemName: "chevron.down")
                    .accessibilityHidden(true)
                    .font(.taption(size: 9, weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
            }
            .foregroundStyle(Color.tpInk)
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background(
                Color.tpFieldFill,
                in: RoundedRectangle(cornerRadius: TaptionRadius.field)
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
            repeatRules: model.addPlanContext.isGoal ? goalRepeatRules : nil,
            spot: model.addPlanContext.isGoal ? nil : PlanSpot(place: place, spendText: spendText)
        )
        if !model.addPlanContext.isGoal, let planID { model.addMemo(text: memoText, kind: .idea, to: planID) }
        dismiss()
    }

    var selectedCategory: CategoryDefinition {
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

    var visibleCategories: [CategoryDefinition] {
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

    func selectCategory(_ newCategoryID: String) {
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

    func memoTextField(
        label: String,
        placeholder: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: TaptionSpacing.snug) {
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
            Color.tpFieldFill,
            in: RoundedRectangle(cornerRadius: TaptionRadius.field)
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
            let goalStart = Calendar.autoupdatingCurrent.startOfDay(for: startAt)
            let end = Calendar.autoupdatingCurrent.date(
                byAdding: .month,
                value: goalDurationMonths,
                to: goalStart
            ) ?? goalStart.addingTimeInterval(
                TimeInterval(goalDurationMonths * 30 * 86_400)
            )
            return max(86_400, end.timeIntervalSince(goalStart))
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
        HStack(spacing: TaptionSpacing.snug) {
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

enum AddRoute: Hashable {
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
                            .background(colors[selectedColor], in: RoundedRectangle(cornerRadius: TaptionRadius.compact))
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
                    .background(Color.tpCard, in: RoundedRectangle(cornerRadius: TaptionCorner.medium))

                    HStack {
                        Text("이름")
                            .font(.taption(size: 11))
                            .foregroundStyle(Color.tpSecondary)
                        TextField("대분류 이름", text: $name)
                            .font(.taption(size: 13, weight: .bold))
                            .multilineTextAlignment(.trailing)
                    }
                    .padding(11)
                    .background(Color.tpCard, in: RoundedRectangle(cornerRadius: TaptionRadius.panel))

                    VStack(alignment: .leading, spacing: 9) {
                        Text("아이콘 · \(CategoryIcon.allCases.count)개")
                            .font(.taption(size: 11, weight: .bold))
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: TaptionSpacing.compact) {
                            ForEach(icons, id: \.self) { icon in
                                Button {
                                    selectedIcon = icon
                                } label: {
                                    Image(systemName: icon.systemImage)
                                        .font(.taption(size: 15))
                                        .foregroundStyle(selectedIcon == icon ? Color.white : Color.tpSecondary)
                                        .frame(maxWidth: .infinity, minHeight: 31)
                                        .background(
                                            selectedIcon == icon ? Color.tpInk : Color.tpControlFill,
                                            in: RoundedRectangle(cornerRadius: TaptionRadius.control)
                                        )
                                }
                                .accessibilityLabel("아이콘 \(icon.rawValue)")
                                .accessibilityAddTraits(selectedIcon == icon ? .isSelected : [])
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(11)
                    .background(Color.tpCard, in: RoundedRectangle(cornerRadius: TaptionRadius.tile))

                    VStack(alignment: .leading, spacing: 9) {
                        Text("색상")
                            .font(.taption(size: 11, weight: .bold))
                        HStack {
                            ForEach(colors.indices, id: \.self) { index in
                                Button {
                                    selectedColor = index
                                } label: {
                                    RoundedRectangle(cornerRadius: TaptionRadius.field)
                                        .fill(colors[index])
                                        .frame(width: 31, height: 31)
                                        .overlay {
                                            if selectedColor == index {
                                                RoundedRectangle(cornerRadius: TaptionRadius.field)
                                                    .stroke(Color.tpInk, lineWidth: 1.5)
                                                    .padding(-3)
                                            }
                                        }
                                        .taptionTouchTarget(visualWidth: 31, visualHeight: 31)
                                }
                                .accessibilityLabel("색상 \(index + 1)")
                                .accessibilityAddTraits(selectedColor == index ? .isSelected : [])
                                .buttonStyle(.plain)
                                if index != colors.indices.last { Spacer() }
                            }
                        }
                    }
                    .padding(11)
                    .background(Color.tpCard, in: RoundedRectangle(cornerRadius: TaptionRadius.tile))

                    Button {
                        onSave(name, selectedIcon, colorHex)
                    } label: {
                        Text("대분류 추가")
                            .font(.taption(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Color.tpPrimaryFill, in: RoundedRectangle(cornerRadius: TaptionRadius.tile))
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

#Preview {
    AddPlanSheet(model: AppModel())
}
