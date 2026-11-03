import Charts
import SwiftUI

struct UnconfirmedRecordDetailView: View {
    @Bindable var model: AppModel
    let span: TimeSpan
    @State private var isEditorPresented = true

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.tpBackground)
            .sheet(
                isPresented: $isEditorPresented,
                onDismiss: dismissDetail
            ) {
                ActivityCorrectionSheet(
                    model: model,
                    unconfirmedSpan: span,
                    showsQuickMenu: true
                )
            }
    }

    private func dismissDetail() {
        guard model.detail == .unconfirmedEditor(span) else { return }
        model.detail = nil
    }
}

struct ActualRecordDetailView: View {
    @Bindable var model: AppModel
    let recordID: UUID
    let correctionSpan: TimeSpan?
    let opensEditor: Bool
    @State private var isActivityPickerPresented = false
    @State private var focusedRecordID: UUID
    @State private var didOpenEditor = false

    init(
        model: AppModel,
        recordID: UUID,
        correctionSpan: TimeSpan? = nil,
        opensEditor: Bool = false
    ) {
        self.model = model
        self.recordID = recordID
        self.correctionSpan = correctionSpan
        self.opensEditor = opensEditor
        _focusedRecordID = State(initialValue: recordID)
    }

    private var record: ActualRecord? {
        guard var value = detailRecords.first(where: {
            $0.id == focusedRecordID
        }) else {
            return nil
        }
        if let focusedCorrectionSpan {
            value.startedAt = focusedCorrectionSpan.start
            value.endedAt = focusedCorrectionSpan.end
        }
        return value
    }

    private var focusedCorrectionSpan: TimeSpan? {
        focusedRecordID == recordID ? correctionSpan : nil
    }

    private var detailRecords: [ActualRecord] {
        MovementDisplayEngine.reviewActuals(
            model.snapshot.actuals,
            travel: model.snapshot.travel,
            calendarEvents: model.snapshot.calendarEvents
        )
    }

    private var classifiedRecords: [ActualRecord] {
        let calendar = Calendar.autoupdatingCurrent
        guard let anchor = detailRecords.first(where: {
            $0.id == focusedRecordID
        }) else { return [] }
        return detailRecords
            .filter {
                calendar.isDate($0.startedAt, inSameDayAs: anchor.startedAt)
                    && $0.span(asOf: Date.now).duration > 0
            }
            .sorted { $0.startedAt == $1.startedAt
                ? $0.id.uuidString < $1.id.uuidString
                : $0.startedAt < $1.startedAt }
    }

    private var focusedRecordIndex: Int? {
        classifiedRecords.firstIndex { $0.id == focusedRecordID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    model.detail = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.taption(size: 18, weight: .semibold))
                }
                .accessibilityLabel("뒤로")
                .buttonStyle(.plain)
                Text("기록 상세")
                    .font(.taption(size: 19, weight: .bold))
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(
                LinearGradient(
                    colors: [Color.tpSurface, Color.tpSurfaceBlue.opacity(0.48)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.tpLine).frame(height: 0.5)
            }

            ScrollView(showsIndicators: false) {
                if let record {
                    VStack(alignment: .leading, spacing: 10) {
                        recordPager
                        detailContent(record)
                    }
                        .padding(14)
                } else {
                    ContentUnavailableView(
                        "기록을 찾을 수 없습니다",
                        systemImage: "clock.badge.exclamationmark",
                        description: Text("저장된 자동 기록이 변경되었을 수 있습니다.")
                    )
                    .padding(24)
                }
            }
            .background(Color.tpBackground)
            .simultaneousGesture(recordSwipeGesture)
        }
        .sheet(isPresented: $isActivityPickerPresented) {
            ActivityCorrectionSheet(
                model: model,
                recordID: focusedRecordID,
                displayedSpan: focusedCorrectionSpan,
                showsQuickMenu: true
            )
        }
        .onAppear {
            guard opensEditor,
                  !didOpenEditor,
                  isStoredRecord(focusedRecordID) else { return }
            didOpenEditor = true
            isActivityPickerPresented = true
        }
    }

    private var recordPager: some View {
        guard let index = focusedRecordIndex, classifiedRecords.count > 1
        else { return AnyView(EmptyView()) }

        return AnyView(
            HStack(spacing: TaptionSpacing.regular) {
                pagerButton("chevron.left", enabled: index > 0) {
                    moveRecord(by: -1)
                }
                Spacer()
                Text("분류된 기록 (index + 1) / (classifiedRecords.count)")
                    .font(.taption(size: 10, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                Spacer()
                pagerButton(
                    "chevron.right",
                    enabled: index + 1 < classifiedRecords.count
                ) {
                    moveRecord(by: 1)
                }
            }
            .padding(.horizontal, 4)
        )
    }

    private func pagerButton(
        _ systemImage: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.taption(size: 11, weight: .bold))
                .foregroundStyle(enabled ? Color.tpInk : Color.tpLine)
                .frame(width: 28, height: 28)
                .background(Color.tpSurface, in: Circle())
                .overlay(Circle().stroke(Color.tpLine, lineWidth: 0.7))
                .taptionTouchTarget(visualWidth: 28, visualHeight: 28)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(
            systemImage == "chevron.left" ? "이전 기록" : "다음 기록"
        )
    }

    private var recordSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height),
                      abs(value.translation.width) >= 40 else { return }
                moveRecord(by: value.translation.width < 0 ? 1 : -1)
            }
    }

    private func moveRecord(by offset: Int) {
        guard let index = focusedRecordIndex else { return }
        let next = index + offset
        guard classifiedRecords.indices.contains(next) else { return }
        isActivityPickerPresented = false
        focusedRecordID = classifiedRecords[next].id
    }

    private func detailContent(_ record: ActualRecord) -> some View {
        let categoryID = displayCategoryID(record)
        let span = record.span(asOf: Date.now)
        return VStack(alignment: .leading, spacing: 12) {
            Button {
                if isStoredRecord(record.id) {
                    isActivityPickerPresented = true
                }
            } label: {
                VStack(alignment: .leading, spacing: TaptionSpacing.compact) {
                    HStack(alignment: .firstTextBaseline, spacing: TaptionSpacing.regular) {
                        Label(
                            displayTitle(record, categoryID: categoryID),
                            systemImage: symbolName(record, categoryID: categoryID)
                        )
                        .font(.taption(size: 17, weight: .bold))
                        .foregroundStyle(PlanCategory(categoryID: categoryID).darkColor)
                        Spacer(minLength: 4)
                        if isStoredRecord(record.id) {
                            Image(systemName: "chevron.right")
                                .font(.taption(size: 11, weight: .semibold))
                                .foregroundStyle(Color.tpSecondary)
                        }
                    }
                    applicationNameLabel(record)
                    Text("\(span.start.formatted(date: .abbreviated, time: .shortened)) – \(span.end.formatted(date: .omitted, time: .shortened))")
                        .font(.taption(size: 11))
                        .foregroundStyle(Color.tpSecondary)
                    Text(durationText(span.duration))
                        .font(.taption(size: 15, weight: .semibold))
                        .foregroundStyle(Color.tpProjectDark)
                    Text(
                        isStoredRecord(record.id)
                            ? "탭하여 상세활동·시간 수정"
                            : "센서에서 복원한 이동 기록"
                    )
                        .font(.taption(size: 9, weight: .medium))
                        .foregroundStyle(Color.tpSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .tpCardSurface(radius: 15, tint: .tpSurfaceBlue)
            }
            .buttonStyle(.plain)

            if let travel = subwayTravel(for: record),
               let route = travel.subwayRoute {
                SubwayRouteTimelineView(route: route, span: travel.span)
            }

            detailRow("데이터 출처", sourceName(record.source))
            detailRow("데이터 신뢰도", TaptionActivityEngineAdapter.trustLabel(for: record))
            detailRow("신뢰도", record.confidence.rawValue)
            let related = relatedRecords(for: record)
            if related.count > 1 {
                let total = ActualIntervalMergeEngine.duration(
                    of: related.map { $0.span(asOf: Date.now) }
                )
                detailRow("같은 날 합산", "\(durationText(total)) · \(related.count)회")
            }
            if let behavior = record.behavior, !behavior.isEmpty {
                detailRow("행동 분류", behavior)
            }
            if !record.evidence.isEmpty {
                VStack(alignment: .leading, spacing: TaptionSpacing.compact) {
                    Text("측정 근거")
                        .font(.taption(size: 10, weight: .bold))
                    ForEach(record.evidence, id: \.self) { evidence in
                        Text("· \(evidence)")
                            .font(.taption(size: 10))
                            .foregroundStyle(Color.tpSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .tpCardSurface(radius: 13, tint: .tpSurfacePink)
            }
            if AutomaticRecordTimelineEngine.isImmutable(record) {
                Label("센서·건강 원본은 보존되고 표시 활동만 변경됩니다.", systemImage: "lock.fill")
                    .font(.taption(size: 9))
                    .foregroundStyle(Color.tpSecondary)
                    .padding(.horizontal, 2)
            }
        }
    }

    private func isStoredRecord(_ id: UUID) -> Bool {
        model.snapshot.actuals.contains { $0.id == id }
    }

    private func subwayTravel(for record: ActualRecord) -> TravelSegment? {
        let span = record.span(asOf: Date.now)
        return model.snapshot.travel
            .filter {
                $0.mode == .subway
                    && $0.subwayRoute != nil
                    && $0.span.intersection(with: span) != nil
            }
            .max {
                ($0.span.intersection(with: span)?.duration ?? 0)
                    < ($1.span.intersection(with: span)?.duration ?? 0)
            }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.taption(size: 10, weight: .semibold))
            Spacer()
            Text(value)
                .font(.taption(size: 10))
                .foregroundStyle(Color.tpSecondary)
        }
        .padding(12)
        .tpCardSurface(radius: 12, tint: .tpSurfaceCream)
    }

    private func applicationNameLabel(_ record: ActualRecord) -> some View {
        AppUsageNameLabel(
            record: record,
            tokenIndex: model.appUsageTokenIndex
        )
    }

    private func displayCategoryID(_ record: ActualRecord) -> String {
        ActualRecordCategoryResolver.categoryID(for: record)
    }

    private func symbolName(
        _ record: ActualRecord,
        categoryID: String
    ) -> String {
        if categoryID == "movement" {
            return MovementPresentation.symbol(for: record)
        }
        return TimelineRowKind(categoryID: categoryID)?.systemImage
            ?? PlanCategory(categoryID: categoryID).systemImage
    }

    private func displayTitle(
        _ record: ActualRecord,
        categoryID: String
    ) -> String {
        if categoryID == "movement" {
            return MovementPresentation.title(for: record)
        }
        return record.title.isEmpty ? categoryName(categoryID) : record.title
    }

    private func categoryName(_ id: String) -> String {
        if let title = TimelineRowKind.title(forCategoryID: id) { return title }
        return model.snapshot.categories.first { $0.id == id }?.name
            ?? PlanCategory(categoryID: id).rawValue
    }

    private func relatedRecords(for record: ActualRecord) -> [ActualRecord] {
        let calendar = Calendar.autoupdatingCurrent
        return model.snapshot.actuals.filter { candidate in
            candidate.categoryID == record.categoryID
                && candidate.title == record.title
                && calendar.isDate(
                    candidate.startedAt,
                    inSameDayAs: record.startedAt
                )
        }
    }

    private func sourceName(_ source: ActualSource) -> String {
        switch source {
        case .manual: "직접 기록"
        case .timer: "타이머"
        case .healthKit: "Apple 건강"
        case .appleWatch: "Apple Watch 센서"
        case .motion: "iPhone 센서"
        case .calendar: "캘린더"
        case .location: "위치"
        case .photo: "사진"
        case .media: "미디어 재생"
        case .call: "통화"
        case .appUsage: "앱 사용시간"
        }
    }

    private func durationText(_ interval: TimeInterval) -> String {
        DurationText.korean(interval)
    }
}
