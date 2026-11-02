import Charts
import SwiftUI

enum ActivityCorrectionCatalog {
    static func options(
        for record: ActualRecord,
        actuals: [ActualRecord],
        customLabels: [String]
    ) -> [ActivityCorrectionOption] {
        RecordAnalysisCategoryPolicy.options
    }

    static func quickOptions(
        for record: ActualRecord,
        actuals: [ActualRecord],
        customLabels: [String]
    ) -> [ActivityCorrectionOption] {
        options(for: record, actuals: actuals, customLabels: customLabels)
    }

    static func activitySystemImage(
        title: String,
        behavior: String?,
        categoryID: String
    ) -> String {
        if let behavior,
           let kind = WatchBehaviorKind.fromModelLabel(behavior) {
            return kind.systemImage
        }
        if let behavior,
           let context = StationaryContextKind(rawValue: behavior) {
            return context.systemImage
        }

        let text = "\(title) \(behavior ?? "")"
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        let matches: [(String, String)] = [
            ("지하철", "tram.fill"), ("subway", "tram.fill"),
            ("버스", "bus.fill"), ("bus", "bus.fill"),
            ("자동차", "car.fill"), ("자가용", "car.fill"),
            ("택시", "taxi.fill"), ("자전거", "bicycle"),
            ("걷", "figure.walk"), ("walk", "figure.walk"),
            ("달리", "figure.run"), ("run", "figure.run"),
            ("샤워", "shower.fill"), ("shower", "shower.fill"),
            ("양치", "toothbrush.fill"), ("brush", "toothbrush.fill"),
            ("집안일", "washer.fill"), ("청소", "washer.fill"),
            ("식사", "fork.knife"), ("meal", "fork.knife"),
            ("타이핑", "keyboard"), ("typing", "keyboard"),
            ("서기", "figure.stand"), ("standing", "figure.stand"),
            ("앉기", "figure.seated.side"), ("sitting", "figure.seated.side"),
            ("눕기", "bed.double.fill"), ("수면", "bed.double.fill"),
            ("lying", "bed.double.fill"), ("sleep", "bed.double.fill"),
            ("집에서휴식", "house.fill"), ("정지", "pause.circle.fill"),
            ("휴식", "sofa.fill"),
            ("rest", "sofa.fill"), ("통화", "phone.fill"),
            ("회의", "person.3.fill"), ("근무", "briefcase.fill"),
            ("수업", "book.fill"), ("학습", "book.fill"),
            ("운동시설", "dumbbell.fill"), ("gym", "dumbbell.fill"),
            ("운동", "figure.run"),
            ("카페", "cup.and.saucer.fill"), ("cafe", "cup.and.saucer.fill"),
            ("대기", "hourglass"),
        ]
        if let match = matches.first(where: { text.contains($0.0) }) {
            return match.1
        }
        return TimelineRowKind(categoryID: categoryID)?.systemImage
            ?? "sparkles"
    }
}

enum ActivityCorrectionTarget {
    case record(UUID)
    case unconfirmed(ActualRecord)

    var isUnconfirmed: Bool {
        if case .unconfirmed = self { return true }
        return false
    }
}

struct ActivityCorrectionHierarchyPicker: View {
    let record: ActualRecord
    let options: [ActivityCorrectionOption]
    let onSelect: (ActivityCorrectionOption) -> Void
    @State private var selectedPhase: DayPhase

    init(
        record: ActualRecord,
        options: [ActivityCorrectionOption],
        onSelect: @escaping (ActivityCorrectionOption) -> Void
    ) {
        self.record = record
        self.options = options
        self.onSelect = onSelect
        _selectedPhase = State(
            initialValue: Self.phase(for: record)
        )
    }

    private var phaseChoices: [DayPhase] {
        let available = Set(options.map(Self.phase(for:)))
        let current = Self.phase(for: record)
        return RecordAnalysisCategoryPolicy.phaseOrder.filter {
            available.contains($0) || $0 == current
        }
    }

    private var detailOptions: [ActivityCorrectionOption] {
        options.filter {
            !RecordAnalysisCategoryPolicy.isPhaseOption($0)
                && Self.phase(for: $0) == selectedPhase
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: TaptionSpacing.regular) {
            VStack(alignment: .leading, spacing: TaptionSpacing.compact) {
                Text("일과")
                    .font(.taption(size: 9, weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
                ForEach(phaseChoices, id: \.rawValue) { phase in
                    phaseButton(phase)
                }
            }
            .frame(width: 94, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: TaptionSpacing.compact) {
                Text("상세활동")
                    .font(.taption(size: 9, weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
                if detailOptions.isEmpty {
                    Text("선택 가능한 활동 없음")
                        .font(.taption(size: 9))
                        .foregroundStyle(Color.tpSecondary)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: 38,
                            alignment: .leading
                        )
                } else {
                    ForEach(detailOptions) { option in
                        optionButton(option)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private func phaseButton(_ phase: DayPhase) -> some View {
        let isSelected = selectedPhase == phase
        let tint = Self.phaseColor(phase)
        return Button {
            guard selectedPhase != phase else { return }
            selectedPhase = phase
        } label: {
            HStack(spacing: TaptionSpacing.compact) {
                Image(systemName: Self.phaseSystemImage(phase))
                    .font(.taption(size: 10, weight: .semibold))
                    .frame(width: 15)
                Text(phase.title)
                    .font(
                        .taption(
                            size: 9.5,
                            weight: isSelected ? .bold : .regular
                        )
                    )
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? tint : Color.tpInk)
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(
                isSelected
                    ? tint.opacity(0.14)
                    : Color.tpControlFillSoft,
                in: RoundedRectangle(cornerRadius: TaptionRadius.control)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func optionButton(
        _ option: ActivityCorrectionOption
    ) -> some View {
        let tint = PlanCategory(categoryID: option.categoryID).darkColor
        return Button {
            guard !option.isAutomaticOnly else { return }
            onSelect(option)
        } label: {
            HStack(spacing: TaptionSpacing.cozy) {
                Image(systemName: option.systemImage)
                    .font(.taption(size: 10, weight: .semibold))
                    .frame(width: 17)
                Text(option.title)
                    .font(.taption(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 0)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .background(
                tint.opacity(0.1),
                in: RoundedRectangle(cornerRadius: TaptionRadius.control)
            )
            .overlay {
                RoundedRectangle(cornerRadius: TaptionRadius.control)
                    .stroke(tint.opacity(0.22), lineWidth: 0.7)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(option.isAutomaticOnly)
        .opacity(option.isAutomaticOnly ? 0.55 : 1)
        .accessibilityLabel(option.title)
    }

    private static func phase(for record: ActualRecord) -> DayPhase {
        RecordAnalysisCategoryPolicy.phase(
            for: RecordAnalysisCategoryPolicy.categoryID(for: record)
        )
    }

    private static func phase(
        for option: ActivityCorrectionOption
    ) -> DayPhase {
        RecordAnalysisCategoryPolicy.phase(for: option.categoryID)
    }

    private static func phase(for kind: WatchBehaviorKind) -> DayPhase {
        switch kind {
        case .sleep: .sleep
        case .automotive, .publicTransit, .subway, .walking, .running,
             .cycling, .stairsUp, .stairsDown, .elevator: .movement
        case .exercise: .exercise
        default: .activity
        }
    }

    private static func phaseSystemImage(_ phase: DayPhase) -> String {
        switch phase {
        case .sleep: "moon.zzz.fill"
        case .movement: "figure.walk.motion"
        case .exercise: "figure.strengthtraining.traditional"
        case .work: "briefcase.fill"
        case .study: "book.fill"
        case .hobby: "paintpalette.fill"
        case .appointment: "calendar"
        case .unconfirmed: "questionmark.circle"
        default: "sparkles"
        }
    }

    private static func phaseColor(_ phase: DayPhase) -> Color {
        RecordTimelinePalette.detailColor(
            .dayPhase,
            token: phase.rawValue
        )
    }
}

struct ActivityCorrectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let target: ActivityCorrectionTarget
    let displayedSpan: TimeSpan?
    let showsQuickMenu: Bool
    @State private var selectedOption: ActivityCorrectionOption?
    @State private var startAt: Date
    @State private var endAt: Date
    @State private var isSaving = false

    init(
        model: AppModel,
        recordID: UUID,
        displayedSpan: TimeSpan? = nil,
        showsQuickMenu: Bool = false
    ) {
        self.model = model
        target = .record(recordID)
        self.displayedSpan = displayedSpan
        self.showsQuickMenu = showsQuickMenu
        let record = model.snapshot.actuals.first { $0.id == recordID }
        let start = displayedSpan?.start ?? record?.startedAt ?? .now
        _startAt = State(initialValue: start)
        _endAt = State(
            initialValue: displayedSpan?.end
                ?? record?.endedAt
                ?? start.addingTimeInterval(5 * 60)
        )
        _selectedOption = State(initialValue: nil)
    }

    init(
        model: AppModel,
        unconfirmedSpan: TimeSpan,
        showsQuickMenu: Bool = false
    ) {
        self.model = model
        displayedSpan = nil
        self.showsQuickMenu = showsQuickMenu
        target = .unconfirmed(
            ActualRecord(
                planID: nil,
                title: "미확인",
                categoryID: ReviewCoverageEngine.unconfirmedCategoryID,
                startedAt: unconfirmedSpan.start,
                endedAt: unconfirmedSpan.end,
                source: .manual,
                confidence: .low,
                behavior: "unconfirmed-gap"
            )
        )
        _startAt = State(initialValue: unconfirmedSpan.start)
        _endAt = State(initialValue: unconfirmedSpan.end)
        _selectedOption = State(initialValue: nil)
    }

    private var record: ActualRecord? {
        switch target {
        case .record(let id):
            model.snapshot.actuals.first { $0.id == id }
        case .unconfirmed(let placeholder):
            placeholder
        }
    }

    private var options: [ActivityCorrectionOption] {
        guard let record else { return [] }
        return ActivityCorrectionCatalog.options(
            for: record,
            actuals: model.snapshot.actuals,
            customLabels: model.snapshot.settings.customActivityLabels
        )
    }

    private var quickOptions: [ActivityCorrectionOption] {
        guard let record else { return [] }
        return RecentActivitySelectionStore.prioritize(
            ActivityCorrectionCatalog.quickOptions(
                for: record,
                actuals: model.snapshot.actuals,
                customLabels: model.snapshot.settings.customActivityLabels
            )
        )
    }

    private var automaticOptions: [ActivityCorrectionOption] {
        options.filter(\.isAutomatic)
    }

    private var suggestedOptions: [ActivityCorrectionOption] {
        options.filter { !$0.isAutomatic && !$0.isCustom }
    }

    var body: some View {
        NavigationStack {
            List {
Group {

                if showsQuickMenu, let record, !quickOptions.isEmpty {
                    Section("빠른 변경") {
                        ActivityCorrectionHierarchyPicker(
                            record: record,
                            options: quickOptions,
                            onSelect: selectQuickOption
                        )
                    }
                }
                Section("시간 조정") {
                    DatePicker(
                        "시작",
                        selection: $startAt,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    DatePicker(
                        "끝",
                        selection: $endAt,
                        in: startAt...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    HStack {
                        Text("표시 시간")
                        Spacer()
                        Text(durationText)
                            .foregroundStyle(Color.tpProjectDark)
                            .font(.taption(size: 11, weight: .semibold))
                    }
                }
                if !automaticOptions.isEmpty {
                    Section("자동으로 구분된 활동") {
                        ForEach(automaticOptions) { optionRow($0) }
                    }
                }
                Section("활동 선택") {
                    ForEach(suggestedOptions) { optionRow($0) }
                }
            
}
.listRowBackground(Color.tpSurface)
}
.tpListStyle()
            .listStyle(.insetGrouped)
            .navigationTitle(target.isUnconfirmed ? "활동 결정" : "활동 변경")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("저장") { save() }
                        .fontWeight(.semibold)
                        .disabled(
                            isSaving
                                || endAt <= startAt
                                || target.isUnconfirmed && selectedOption == nil
                        )
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    func selectQuickOption(_ option: ActivityCorrectionOption) {
        guard !isSaving, endAt > startAt, !option.isAutomaticOnly else { return }
        RecentActivitySelectionStore.remember(option)
        selectedOption = option
        // `@State` is committed on the next render pass. Passing the option
        // directly avoids saving the previous selection when the quick menu
        // closes immediately after a tap.
        save(option: option)
    }

    func optionRow(_ option: ActivityCorrectionOption) -> some View {
        Button {
            guard !option.isAutomaticOnly else { return }
            select(option)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: option.systemImage)
                    .frame(width: 22)
                    .foregroundStyle(PlanCategory(categoryID: option.categoryID).darkColor)
                Text(option.title)
                    .foregroundStyle(Color.tpInk)
                Spacer()
                if isSelected(option) {
                    Image(systemName: "checkmark.circle.fill")
                        .accessibilityLabel("선택됨")
                        .foregroundStyle(Color.tpProjectDark)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(option.isAutomaticOnly)
        .opacity(option.isAutomaticOnly ? 0.55 : 1)
    }

    func isSelected(_ option: ActivityCorrectionOption) -> Bool {
        guard let record else { return false }
        if let selectedOption {
            return selectedOption.id == option.id
        }
        let current = ActivityCorrection(
            title: record.title,
            behavior: record.behavior,
            categoryID: record.categoryID,
            startedAt: nil,
            endedAt: nil
        )
        guard option.correction == current else { return false }
        return options.first(where: { $0.correction == current })?.id == option.id
    }

    func select(_ option: ActivityCorrectionOption) {
        selectedOption = option
    }

    var durationText: String {
        DurationText.korean(max(0, endAt.timeIntervalSince(startAt)))
    }

    func save(option selectedOverride: ActivityCorrectionOption? = nil) {
        guard !isSaving, endAt > startAt else { return }
        let option = selectedOverride ?? selectedOption
        if target.isUnconfirmed, option == nil { return }
        if let option {
            RecentActivitySelectionStore.remember(option)
        }
        isSaving = true
        Task {
            defer { isSaving = false }
            switch target {
            case .record(let recordID):
                if let displayedSpan {
                    await model.correctActualFragment(
                        recordID,
                        displayedSpan: displayedSpan,
                        startAt: startAt,
                        endAt: endAt,
                        with: option
                    )
                } else {
                    if let option {
                        await model.updateActualActivity(recordID, with: option)
                    }
                    await model.updateActualSpan(
                        recordID,
                        startAt: startAt,
                        endAt: endAt
                    )
                }
            case .unconfirmed:
                guard let option else { return }
                await model.classifyUnconfirmedSpan(
                    TimeSpan(start: startAt, end: endAt),
                    with: option
                )
            }
            dismiss()
        }
    }
}
