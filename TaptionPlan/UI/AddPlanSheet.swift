import SwiftUI

struct AddPlanSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel

    @State private var title = ""
    @State private var categoryID = "study"
    @State private var durationMinutes = 60
    @State private var goalDurationMonths = 12
    @State private var startAt = Date.now
    @State private var parentID: UUID?
    @State private var path: [AddRoute] = []
    @State private var selectedDetent: PresentationDetent = .height(330)
    @FocusState private var titleFocused: Bool

    var body: some View {
        NavigationStack(path: $path) {
            rootSheet
                .navigationDestination(for: AddRoute.self) { route in
                    switch route {
                    case .category:
                        CategoryPickerScreen(
                            categories: model.snapshot.categories,
                            selection: $categoryID,
                            onSelect: {
                                path.removeLast()
                                selectedDetent = .height(330)
                            },
                            onCustom: { path.append(.customCategory) },
                            onCancel: {
                                path.removeLast()
                                selectedDetent = .height(330)
                            }
                        )
                    case .customCategory:
                        CustomCategoryScreen { name, icon, colorHex in
                            if let category = model.addCustomCategory(
                                name: name,
                                icon: icon,
                                lightHex: colorHex
                            ) {
                                categoryID = category.id
                                path.removeAll()
                                selectedDetent = .height(330)
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
                            selectedDetent = .height(330)
                        }
                    }
                }
                .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.height(330), .large], selection: $selectedDetent)
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
            } else if let parent = selectedParent {
                categoryID = parent.categoryID
                startAt = max(
                    roundedToNextTenMinutes(model.selectedDate),
                    parent.span.start
                )
            } else {
                startAt = roundedToNextTenMinutes(startAt)
            }
            if selectedCategory.isHidden,
               let firstVisible = model.snapshot.categories.first(where: {
                   !$0.isHidden
               }) {
                categoryID = firstVisible.id
            }
            titleFocused = true
        }
    }

    private var rootSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule()
                .fill(Color(red: 0.84, green: 0.84, blue: 0.86))
                .frame(width: 36, height: 4)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 14)

            HStack(spacing: 0) {
                TextField(
                    planNamePlaceholder,
                    text: $title
                )
                    .font(.system(size: 17, weight: .semibold))
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
            .padding(.horizontal, 2)
            .padding(.vertical, 9)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.tpInk).frame(height: 2)
            }
            .padding(.bottom, 8)

            Button {
                titleFocused = false
                selectedDetent = .large
                path.append(.category)
            } label: {
                HStack(spacing: 8) {
                    Text("대분류")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.tpSecondary)
                    Spacer()
                    Label(
                        selectedCategory.name,
                        systemImage: selectedCategory.icon.systemImage
                    )
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.tpInk)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(red: 0.68, green: 0.68, blue: 0.70))
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 10)
                .overlay {
                    VStack {
                        Rectangle().fill(Color.tpLine).frame(height: 0.5)
                        Spacer()
                        Rectangle().fill(Color.tpLine).frame(height: 0.5)
                    }
                }
            }
            .buttonStyle(.plain)

            if model.addPlanContext.isGoal {
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
                            title: months == 12
                                ? "1년" : "\(months)개월",
                            selected: goalDurationMonths == months
                        )
                        .onTapGesture {
                            goalDurationMonths = months
                        }
                    }
                }
                .padding(.top, 10)
            } else {
                HStack(spacing: 7) {
                    DraftChip(
                        title: startAt.formatted(
                            Date.FormatStyle(
                                date: .abbreviated,
                                time: .shortened
                            )
                            .locale(Locale(identifier: "ko_KR"))
                        ),
                        selected: true
                    )
                    DraftChip(
                        title: "30분",
                        selected: durationMinutes == 30
                    )
                    .onTapGesture { durationMinutes = 30 }
                    DraftChip(
                        title: "1시간",
                        selected: durationMinutes == 60
                    )
                    .onTapGesture { durationMinutes = 60 }
                    DraftChip(
                        title: "2시간",
                        selected: durationMinutes == 120
                    )
                    .onTapGesture { durationMinutes = 120 }
                    DraftChip(title: "슬라이더…")
                        .onTapGesture {
                            titleFocused = false
                            selectedDetent = .large
                            path.append(.time)
                        }
                }
                .padding(.top, 10)
            }

            if !model.addPlanContext.isGoal {
            HStack(spacing: 7) {
                Text("최근")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.tpSecondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(quickSuggestions, id: \.self) { suggestion in
                            Button {
                                title = suggestion
                            } label: {
                                DraftChip(
                                    title: suggestion,
                                    selected: title == suggestion
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.top, 6)
            }

            if let parent = selectedParent,
               model.addPlanContext.parentID != nil {
                HStack(spacing: 7) {
                    Text("상위 목표")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.tpSecondary)
                    Spacer()
                    Label(
                        parent.title,
                        systemImage: "arrow.turn.down.right"
                    )
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(Color.tpInk)
                    .lineLimit(1)
                }
                .padding(.top, 8)
            } else if model.addPlanContext == .quick {
                HStack(spacing: 7) {
                    Text("상위 목표")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.tpSecondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(rootPlans.prefix(3)) { plan in
                                DraftChip(
                                    title: plan.title,
                                    selected: parentID == plan.id
                                )
                                .onTapGesture { parentID = plan.id }
                            }
                            DraftChip(
                                title: "없음",
                                selected: parentID == nil
                            )
                            .onTapGesture { parentID = nil }
                        }
                    }
                }
                .padding(.top, 6)
            }

            Spacer(minLength: 0)

            HStack {
                Button("취소") { dismiss() }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                Spacer()
                Button("추가", action: addPlan)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.tpSecondary : Color.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.tpLine : Color.tpInk,
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(Color.white)
    }

    private func addPlan() {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }

        model.addPlan(
            title: cleanTitle,
            categoryID: categoryID,
            startAt: startAt,
            duration: selectedDuration,
            parentID: model.addPlanContext.isGoal ? nil : parentID
        )
        dismiss()
    }

    private var selectedCategory: CategoryDefinition {
        model.snapshot.categories.first { $0.id == categoryID }
            ?? CategoryCatalog.builtIn.first { $0.id == "study" }
            ?? CategoryCatalog.builtIn[0]
    }

    private var selectedParent: PlanRecord? {
        guard let parentID else { return nil }
        return model.snapshot.plans.first { $0.id == parentID }
    }

    private var planNamePlaceholder: String {
        if model.addPlanContext.isGoal { return "목표 이름" }
        if model.addPlanContext.parentID != nil {
            return "하위 계획 이름"
        }
        return "계획 이름"
    }

    private var rootPlans: [PlanRecord] {
        model.snapshot.plans
            .filter { $0.parentID == nil && $0.status != .skipped }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var quickSuggestions: [String] {
        var values = model.snapshot.plans
            .sorted { $0.updatedAt > $1.updatedAt }
            .map(\.title)
        values.append(
            contentsOf: model.pendingTemplateApplication?.quickAdds ?? []
        )
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }.prefix(6).map {
            $0
        }
    }

    private var selectedDuration: TimeInterval {
        if model.addPlanContext.isGoal {
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

    private func roundedToNextTenMinutes(_ date: Date) -> Date {
        let interval: TimeInterval = 10 * 60
        return Date(
            timeIntervalSinceReferenceDate:
                ceil(date.timeIntervalSinceReferenceDate / interval) * interval
        )
    }
}

private enum AddRoute: Hashable {
    case category
    case customCategory
    case time
}

private struct CategoryPickerScreen: View {
    let categories: [CategoryDefinition]
    @Binding var selection: String
    let onSelect: () -> Void
    let onCustom: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            pickerHeader("대분류 선택", trailing: "취소", action: onCancel)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    Text("영어 공부에 가장 가까운 대분류 하나를 선택하세요. 선택 후 항목 추가 화면으로 바로 돌아갑니다.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.tpSecondary)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                        spacing: 8
                    ) {
                        ForEach(categories.filter { !$0.isHidden }) { category in
                            Button {
                                selection = category.id
                            } label: {
                                Label(
                                    category.name,
                                    systemImage: category.icon.systemImage
                                )
                                    .font(.system(size: 10.5, weight: .bold))
                                    .foregroundStyle(Color.tpInk)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(
                                        Color(hex: category.lightHex),
                                        in: RoundedRectangle(cornerRadius: 10)
                                    )
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(
                                                selection == category.id ? Color.tpInk : Color.tpLine,
                                                lineWidth: selection == category.id ? 2 : 1
                                            )
                                    }
                            }
                            .buttonStyle(.plain)
                        }

                        Button(action: onCustom) {
                            Label("직접 추가", systemImage: "plus")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(Color.tpSecondary)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.tpSecondary.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                }
                        }
                        .buttonStyle(.plain)
                    }

                    Button(action: onSelect) {
                        Text("\(selectedCategoryName)으로 선택")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Color.tpInk, in: RoundedRectangle(cornerRadius: 13))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .background(Color.tpBackground)
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var selectedCategoryName: String {
        categories.first { $0.id == selection }?.name ?? "대분류"
    }
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
        .cafe, .pet, .shopping, .nature, .calendar, .memo,
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
                            .font(.system(size: 18))
                            .foregroundStyle(Color(red: 0.33, green: 0.46, blue: 0.24))
                            .frame(width: 34, height: 34)
                            .background(colors[selectedColor], in: RoundedRectangle(cornerRadius: 11))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("미리보기")
                                .font(.system(size: 9.5))
                                .foregroundStyle(Color.tpSecondary)
                            Text(name.isEmpty ? "새 대분류" : name)
                                .font(.system(size: 14, weight: .bold))
                        }
                        Spacer()
                    }
                    .padding(13)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 15))

                    HStack {
                        Text("이름")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.tpSecondary)
                        TextField("대분류 이름", text: $name)
                            .font(.system(size: 13, weight: .bold))
                            .multilineTextAlignment(.trailing)
                    }
                    .padding(11)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12))

                    VStack(alignment: .leading, spacing: 9) {
                        Text("아이콘 · 24개")
                            .font(.system(size: 11, weight: .bold))
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 5) {
                            ForEach(icons, id: \.self) { icon in
                                Button {
                                    selectedIcon = icon
                                } label: {
                                    Image(systemName: icon.systemImage)
                                        .font(.system(size: 15))
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
                            .font(.system(size: 11, weight: .bold))
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
                            .font(.system(size: 14, weight: .bold))
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
                    Text("영어 공부").font(.system(size: 16, weight: .bold))
                }

                HStack(alignment: .firstTextBaseline) {
                    Text(timeRangeLabel)
                        .font(.system(size: 24, weight: .black))
                    Spacer()
                    Text(durationLabel)
                        .font(.system(size: 12.5, weight: .semibold))
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
                            .font(.system(size: 12, weight: .bold))
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
                .font(.system(size: 10))
                .foregroundStyle(Color.tpSecondary)

                HStack(spacing: 6) {
                    ForEach([30, 60, 90, 120], id: \.self) { minutes in
                        Button {
                            durationMinutes = minutes
                        } label: {
                            Text(presetLabel(minutes))
                                .font(.system(size: 9.5, weight: .bold))
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
                        .font(.system(size: 14.5, weight: .bold))
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
            Text(title).font(.system(size: 11, weight: .bold))
            Text(caption)
                .font(.system(size: 9.5))
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
            .font(.system(size: 19, weight: .bold))
        Spacer()
        Button(trailing, action: action)
            .font(.system(size: 12, weight: .semibold))
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
