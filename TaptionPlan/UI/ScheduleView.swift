import SwiftUI
import UIKit

private let scheduleLabelColumnWidth: CGFloat = 64

private struct TimelineAxisMarker: Identifiable {
    let id: String
    let fraction: Double
    let label: String
    let isCurrent: Bool
}

struct TwoFingerDoubleTapAttachment: UIViewRepresentable {
    let onRecognized: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onRecognized: onRecognized)
    }

    func makeUIView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(
        _ uiView: AttachmentView,
        context: Context
    ) {
        context.coordinator.onRecognized = onRecognized
        uiView.installRecognizerIfNeeded()
    }

    static func dismantleUIView(
        _ uiView: AttachmentView,
        coordinator: Coordinator
    ) {
        uiView.removeRecognizer()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onRecognized: () -> Void

        init(onRecognized: @escaping () -> Void) {
            self.onRecognized = onRecognized
        }

        @objc func didRecognize() {
            onRecognized()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith
                otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }

    final class AttachmentView: UIView {
        weak var coordinator: Coordinator?
        private weak var installedSuperview: UIView?
        private var recognizer: UITapGestureRecognizer?

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            installRecognizerIfNeeded()
        }

        func installRecognizerIfNeeded() {
            guard let superview, let coordinator else { return }
            if installedSuperview === superview, recognizer != nil {
                return
            }
            removeRecognizer()
            let recognizer = UITapGestureRecognizer(
                target: coordinator,
                action: #selector(Coordinator.didRecognize)
            )
            recognizer.numberOfTapsRequired = 2
            recognizer.numberOfTouchesRequired = 2
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = coordinator
            superview.addGestureRecognizer(recognizer)
            installedSuperview = superview
            self.recognizer = recognizer
        }

        func removeRecognizer() {
            if let recognizer {
                installedSuperview?.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
            installedSuperview = nil
        }
    }
}

struct ScheduleView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            DraftTopBar(
                title: headerTitle,
                trailing: headerTrailing,
                selectedScale: model.selectedScale,
                onScaleChange: { model.selectScale($0) },
                onPrevious: { model.shiftSelectedDate(by: -1) },
                onNext: { model.shiftSelectedDate(by: 1) },
                isPreviousEnabled: model.canShiftToPreviousPeriod,
                isNextEnabled: model.canShiftToNextPeriod
            )
            TimelineBoard(
                model: model,
                scale: model.selectedScale,
                storedPlans: model.snapshot.plans
            )
        }
        .background(Color.white)
    }

    private var headerTitle: String {
        ScheduleHeaderFormatter().title(
            for: model.selectedDate,
            scale: model.selectedScale
        )
    }

    private var headerTrailing: String {
        switch model.selectedScale {
        case .day:
            if let weather = closestWeather {
                "\(weather.temperatureCelsius.rounded().formatted())° · \(weather.condition)"
            } else {
                ""
            }
        case .week:
            "W\(Calendar.autoupdatingCurrent.component(.weekOfYear, from: model.selectedDate))"
        case .month:
            "\(Calendar.autoupdatingCurrent.range(of: .day, in: .month, for: model.selectedDate)?.count ?? 30)일"
        case .year: "나의 한 해"
        }
    }

    private var visibleSpan: TimeSpan {
        TimelineAggregationEngine().interval(
            for: model.selectedScale.timelineLevel,
            containing: model.selectedDate
        )
    }

    private var closestWeather: WeatherContext? {
        model.snapshot.weather
            .filter { visibleSpan.contains($0.observedAt) }
            .min {
                abs($0.observedAt.timeIntervalSince(model.selectedDate))
                    < abs($1.observedAt.timeIntervalSince(model.selectedDate))
            }
    }
}

struct GroupGanttView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            DraftTopBar(
                title: selectedGroup?.title ?? "신제품 기획",
                trailing: selectedGroup.map(periodText) ?? "7.27 – 8.2",
                selectedScale: model.selectedScale,
                onScaleChange: { model.selectScale($0) },
                onBack: { model.closeCurrentGroup() }
            )
            TimelineBoard(
                model: model,
                scale: model.selectedScale,
                storedPlans: model.snapshot.plans,
                isGroup: true
            )
        }
        .background(Color.white)
    }

    private var selectedGroup: PlanRecord? {
        guard let id = model.selectedGroupPlanID else { return nil }
        return model.snapshot.plans.first { $0.id == id }
    }

    private func periodText(_ plan: PlanRecord) -> String {
        "\(plan.span.start.formatted(.dateTime.month().day())) – \(plan.span.end.formatted(.dateTime.month().day()))"
    }
}

private struct TimelineBoard: View {
    @Bindable var model: AppModel
    let scale: TimeScale
    let storedPlans: [PlanRecord]
    var isGroup = false
    @State private var editingPlanID: UUID?
    @State private var viewport = GanttViewport.full
    @State private var dragOrigin: GanttViewport?
    @State private var magnifyOrigin: GanttViewport?
    @State private var zoomFeedbackSequence = 0

    var body: some View {
        VStack(spacing: 0) {
            axis

            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            TimelineRow(
                                row: row,
                                editingPlanID: editingPlanID,
                                visibleDuration:
                                    visibleSpan.duration * viewport.length,
                                viewport: viewport,
                                onBlockTap: handleTap,
                                onBlockDoubleTap: focusOnBlock,
                                onEdit: { editingPlanID = $0 },
                                onMove: { block, delta in
                                    guard let planID = block.planID else {
                                        return
                                    }
                                    model.movePlan(planID, by: delta)
                                },
                                onResizeStart: { block, delta in
                                    guard let planID = block.planID else {
                                        return
                                    }
                                    model.resizePlan(
                                        planID,
                                        startDelta: delta
                                    )
                                },
                                onResizeEnd: { block, delta in
                                    guard let planID = block.planID else {
                                        return
                                    }
                                    model.resizePlan(
                                        planID,
                                        endDelta: delta
                                    )
                                }
                            )
                        }

                        if scale == .day,
                           !isGroup,
                           !photoClusters.isEmpty {
                            photoRow
                        } else if scale != .day {
                            summaryStrip
                        }

                        if scale == .day, hasVisibleActuals {
                            planActualStrip
                        }
                    }

                    gridLines
                        .allowsHitTesting(false)

                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        currentLine(at: context.date)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .simultaneousGesture(
                    viewportDragGesture(
                        width: max(
                            1,
                            proxy.size.width
                                - scheduleLabelColumnWidth
                        )
                    )
                )
                .simultaneousGesture(viewportMagnifyGesture)
                .background {
                    TwoFingerDoubleTapAttachment {
                        resetViewport(withFeedback: true)
                    }
                }
            }
            .frame(height: contentHeight)

            Spacer(minLength: 0)
        }
        .background(Color.white)
        .onChange(of: scale) { _, _ in
            resetViewport()
        }
        .onChange(of: model.selectedDate) { _, _ in
            resetViewport()
        }
        .accessibilityHint(
            "간트 본문을 드래그해 이동하고 두 손가락으로 최대 1분 단위까지 확대합니다"
        )
        .accessibilityIdentifier("schedule.timeline.board")
        .accessibilityValue(currentZoomStage.label)
        .sensoryFeedback(
            .impact(weight: .light),
            trigger: zoomFeedbackSequence
        )
    }

    private var axis: some View {
        HStack(spacing: 0) {
            Button {
                resetViewport(withFeedback: true)
            } label: {
                HStack(spacing: 3) {
                    Text(currentZoomStage.label)
                    if !viewport.isFull {
                        Image(systemName: "arrow.counterclockwise")
                    }
                }
                .font(.taption(size: 8.5, weight: .bold))
                .foregroundStyle(
                    viewport.isFull
                        ? Color.tpSecondary
                        : Color.tpInk
                )
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    viewport.isFull
                        ? Color.clear
                        : Color(red: 0.94, green: 0.94, blue: 0.95),
                    in: Capsule()
                )
            }
            .buttonStyle(.plain)
            .frame(width: scheduleLabelColumnWidth)
            .accessibilityLabel(
                viewport.isFull
                    ? "현재 배율 \(currentZoomStage.label)"
                    : "현재 배율 \(currentZoomStage.label), 전체 보기로 복귀"
            )
            .accessibilityIdentifier("schedule.zoom.level")
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    ForEach(axisMarkers) { marker in
                        Text(marker.label)
                            .font(
                                .taption(
                                    size: 10,
                                    weight: marker.isCurrent
                                        ? .bold
                                        : .regular
                                )
                            )
                            .foregroundStyle(
                                marker.isCurrent
                                    ? Color.tpNow
                                    : Color.tpSecondary
                            )
                            .fixedSize()
                            .position(
                                x: markerX(
                                    marker,
                                    width: proxy.size.width
                                ),
                                y: proxy.size.height / 2
                            )
                    }
                }
            }
            .clipped()
        }
        .padding(.leading, 4)
        .padding(.trailing, 4)
        .frame(height: 32)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.tpLine).frame(height: 0.5)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    guard abs(value.translation.width)
                        > abs(value.translation.height) * 1.4 else {
                        return
                    }
                    model.shiftSelectedDate(
                        by: value.translation.width < 0 ? 1 : -1
                    )
                }
        )
    }

    private var rows: [TimelineRowModel] {
        let resolved = resolvedRows
        if resolved.contains(where: { !$0.blocks.isEmpty }) {
            return resolved
        }

        if isGroup {
            return groupRows
        }

        switch scale {
        case .day:
            let dayRows: [TimelineRowModel] = [
                .init(
                    title: "캘린더",
                    dotColor: Color(red: 0.56, green: 0.56, blue: 0.58),
                    blocks: [
                        .init(
                            title: "병원 14:00",
                            start: 0.47,
                            length: 0.22,
                            isFixed: true
                        )
                    ]
                ),
                .init(
                    title: "프로젝트",
                    category: .project,
                    blocks: [.init(title: "보고서 작성", start: 0.14, length: 0.44)]
                ),
                .init(
                    title: "운동",
                    category: .exercise,
                    blocks: [.init(title: "러닝 40분", start: 0.63, length: 0.20)]
                ),
                .init(
                    title: "학습",
                    category: .study,
                    blocks: [.init(title: "영어", start: 0.80, length: 0.17)]
                ),
                .init(
                    title: "생활",
                    category: .routine,
                    blocks: [.init(title: "점심", start: 0.38, length: 0.12)]
                ),
            ]

            return resolved + dayRows

        case .week:
            return [
                .init(
                    title: "프로젝트",
                    category: .project,
                    height: 68,
                    blocks: [
                        .init(title: "신제품 기획", start: 0.02, length: 0.55, top: 8, groupCount: 4),
                        .init(title: "보고서", start: 0.44, length: 0.26, top: 38),
                    ]
                ),
                .init(
                    title: "운동",
                    category: .exercise,
                    blocks: [
                        .init(title: "런", start: 0.02, length: 0.12),
                        .init(title: "런", start: 0.30, length: 0.12),
                        .init(title: "런", start: 0.58, length: 0.12),
                        .init(title: "런", start: 0.86, length: 0.12),
                    ]
                ),
                .init(
                    title: "학습",
                    category: .study,
                    blocks: [.init(title: "영어 매일 30분", start: 0.02, length: 0.83)]
                ),
            ]

        case .month:
            return [
                .init(
                    title: "프로젝트",
                    category: .project,
                    height: 68,
                    blocks: [
                        .init(title: "신제품 기획", start: 0.08, length: 0.44, top: 8, groupCount: 4),
                        .init(title: "월간 보고서", start: 0.62, length: 0.27, top: 38),
                    ]
                ),
                .init(
                    title: "운동",
                    category: .exercise,
                    blocks: [.init(title: "주 3회 운동", start: 0.02, length: 0.96)]
                ),
                .init(
                    title: "학습",
                    category: .study,
                    blocks: [.init(title: "자격증 2단계", start: 0.16, length: 0.56)]
                ),
                .init(
                    title: "여행",
                    category: .travel,
                    blocks: [.init(title: "출발", start: 0.76, length: 0.20, top: 20, height: 20)]
                ),
            ]

        case .year:
            return [
                .init(
                    title: "학습",
                    category: .study,
                    blocks: [.init(title: "자격증 취득", start: 0.16, length: 0.34, groupCount: 3)]
                ),
                .init(
                    title: "여행",
                    category: .travel,
                    blocks: [
                        .init(title: "일본", start: 0.58, length: 0.10),
                        .init(title: "제주", start: 0.88, length: 0.10, top: 20, height: 20),
                    ]
                ),
                .init(
                    title: "운동",
                    category: .exercise,
                    blocks: [.init(title: "주 3회 운동 습관", start: 0.02, length: 0.96)]
                ),
                .init(
                    title: "프로젝트",
                    category: .project,
                    blocks: [.init(title: "신제품 프로젝트", start: 0.25, length: 0.42, groupCount: 4)]
                ),
            ]
        }
    }

    private var resolvedRows: [TimelineRowModel] {
        if isGroup {
            guard let groupID = model.selectedGroupPlanID else { return [] }
            return rows(
                from: PlanHierarchy.children(of: groupID, in: storedPlans),
                includesCalendar: false
            )
        }
        return rows(
            from: storedPlans.filter { $0.parentID == nil },
            includesCalendar: true
        )
    }

    private func rows(
        from plans: [PlanRecord],
        includesCalendar: Bool
    ) -> [TimelineRowModel] {
        let span = visibleSpan
        let visiblePlans = plans
            .filter { $0.span.intersection(with: span) != nil }
            .sorted { $0.span.start < $1.span.start }
        let grouped = Dictionary(grouping: visiblePlans, by: \.categoryID)
        let visibleActuals = model.snapshot.actuals
            .filter { $0.span().intersection(with: span) != nil }
            .sorted { $0.startedAt < $1.startedAt }
        let actualsGrouped = Dictionary(
            grouping: visibleActuals,
            by: \.categoryID
        )
        var values: [TimelineRowModel] = []

        if includesCalendar {
            let events = model.snapshot.calendarEvents
                .filter { $0.span.intersection(with: span) != nil }
                .sorted { $0.span.start < $1.span.start }
            if !events.isEmpty {
                let allocation = laneAllocation(events, span: \.span)
                values.append(
                    TimelineRowModel(
                        title: "캘린더",
                        dotColor: Color(red: 0.56, green: 0.56, blue: 0.58),
                        height: max(
                            60,
                            14 + CGFloat(allocation.count) * 28
                        ),
                        blocks: events.map { event in
                            timelineBlock(
                                title: event.title,
                                span: event.span,
                                top: 7 + CGFloat(
                                    allocation.lanes[event.id, default: 0]
                                ) * 28,
                                height: 22,
                                isFixed: true,
                                detailText: "고정 일정"
                            )
                        }
                    )
                )
            }
        }

        let orderedCategories = model.snapshot.categories.sorted {
            $0.sortOrder < $1.sortOrder
        }
        for definition in orderedCategories {
            let isDefaultSensorCategory =
                scale == .day
                && includesCalendar
                && (definition.id == "movement"
                    || definition.id == "location")
            guard !definition.isHidden || isDefaultSensorCategory else {
                continue
            }
            let categoryPlans = grouped[definition.id, default: []]
            let categoryActuals = actualsGrouped[definition.id, default: []]
            guard isDefaultSensorCategory
                || !categoryPlans.isEmpty
                || !categoryActuals.isEmpty else {
                continue
            }
            let category = PlanCategory(categoryID: definition.id)
            let planAllocation = laneAllocation(
                categoryPlans,
                span: \.span
            )
            let actualAllocation = laneAllocation(
                categoryActuals,
                span: { $0.span() }
            )
            let planBlocks = categoryPlans.map { plan in
                timelineBlock(
                    plan: plan,
                    top: 7 + CGFloat(
                        planAllocation.lanes[plan.id, default: 0]
                    ) * 28,
                    height: 22
                )
            }
            let actualBlocks = categoryActuals.map { actual in
                timelineBlock(
                    actual: actual,
                    top: 7
                        + CGFloat(planAllocation.count) * 28
                        + CGFloat(
                            actualAllocation.lanes[actual.id, default: 0]
                        ) * 16,
                    height: 12
                )
            }
            let sensorBlocks = sensorTimelineBlocks(
                categoryID: definition.id,
                top: 7
                    + CGFloat(planAllocation.count) * 28
                    + CGFloat(actualAllocation.count) * 16
            )
            let sensorLaneCount = sensorBlocks.isEmpty ? 0 : 1
            values.append(
                TimelineRowModel(
                    title: definition.name,
                    category: category,
                    dotColor: Color(hex: definition.darkHex),
                    fillColor: Color(hex: definition.lightHex),
                    actualColor: Color(hex: definition.actualHex),
                    height: max(
                        60,
                        14
                            + CGFloat(planAllocation.count) * 28
                            + CGFloat(actualAllocation.count) * 16
                            + CGFloat(sensorLaneCount) * 22
                    ),
                    blocks: planBlocks + actualBlocks + sensorBlocks
                )
            )
        }

        let knownIDs = Set(orderedCategories.map(\.id))
        let unknownIDs = Set(grouped.keys)
            .union(actualsGrouped.keys)
            .subtracting(knownIDs)
        for categoryID in unknownIDs.sorted() {
            let categoryPlans = grouped[categoryID, default: []]
            let categoryActuals = actualsGrouped[categoryID, default: []]
            let planAllocation = laneAllocation(
                categoryPlans,
                span: \.span
            )
            let actualAllocation = laneAllocation(
                categoryActuals,
                span: { $0.span() }
            )
            values.append(
                TimelineRowModel(
                    title: categoryID,
                    category: PlanCategory(categoryID: categoryID),
                    height: max(
                        60,
                        14
                            + CGFloat(planAllocation.count) * 28
                            + CGFloat(actualAllocation.count) * 16
                    ),
                    blocks: categoryPlans.map { plan in
                        timelineBlock(
                            plan: plan,
                            top: 7 + CGFloat(
                                planAllocation.lanes[plan.id, default: 0]
                            ) * 28,
                            height: 22
                        )
                    } + categoryActuals.map { actual in
                        timelineBlock(
                            actual: actual,
                            top: 7
                                + CGFloat(planAllocation.count) * 28
                                + CGFloat(
                                    actualAllocation.lanes[
                                        actual.id,
                                        default: 0
                                    ]
                                ) * 16,
                            height: 12
                        )
                    }
                )
            )
        }
        return values
    }

    private func timelineBlock(
        plan: PlanRecord,
        top: CGFloat = 16,
        height: CGFloat = 26
    ) -> TimelineBlock {
        let childCount = storedPlans.filter { $0.parentID == plan.id }.count
        return timelineBlock(
            id: plan.id,
            planID: plan.id,
            title: plan.title,
            span: plan.span,
            top: top,
            height: height,
            isFixed: plan.isFixed,
            groupCount: childCount > 0 ? childCount : nil,
            status: plan.status,
            detailText: "계획"
        )
    }

    private func timelineBlock(
        actual: ActualRecord,
        top: CGFloat = 16,
        height: CGFloat = 26
    ) -> TimelineBlock {
        timelineBlock(
            id: actual.id,
            title: "\(actual.title) · 실제",
            span: actual.span(),
            top: top,
            height: height,
            isFixed: true,
            status: .completed,
            isActual: true,
            detailText:
                "실제 · \(actualSourceName(actual.source)) · \(confidenceName(actual.confidence))"
        )
    }

    private func sensorTimelineBlocks(
        categoryID: String,
        top: CGFloat
    ) -> [TimelineBlock] {
        switch categoryID {
        case "movement":
            return model.snapshot.travel
                .filter {
                    $0.span.intersection(with: visibleSpan) != nil
                }
                .sorted { $0.span.start < $1.span.start }
                .map { travel in
                    timelineBlock(
                        id: travel.id,
                        title: travelModeName(travel.mode),
                        span: travel.span,
                        top: top,
                        height: 16,
                        isFixed: true,
                        status: .completed,
                        isActual: true,
                        opensLocationTimeline: true,
                        detailText:
                            "센서 추정 · \(confidenceName(travel.confidence))"
                    )
                }
        case "location":
            return model.snapshot.places
                .filter {
                    $0.span.intersection(with: visibleSpan) != nil
                }
                .sorted { $0.span.start < $1.span.start }
                .map { place in
                    let title = place.floor.map {
                        "\(place.displayName) · \($0)층"
                    } ?? place.displayName
                    let altitude = place.point.map {
                        "해발 \(Int($0.altitude.rounded()))m"
                            + (
                                $0.verticalAccuracy >= 0
                                    ? " · ±\(Int($0.verticalAccuracy.rounded()))m"
                                    : ""
                            )
                    }
                    return timelineBlock(
                        id: place.id,
                        title: title,
                        span: place.span,
                        top: top,
                        height: 16,
                        isFixed: true,
                        status: .completed,
                        isActual: true,
                        opensLocationTimeline: true,
                        detailText:
                            [
                                "센서 추정",
                                confidenceName(place.confidence),
                                altitude,
                            ]
                            .compactMap { $0 }
                            .joined(separator: " · ")
                    )
                }
        default:
            return []
        }
    }

    private func travelModeName(_ mode: TravelMode) -> String {
        switch mode {
        case .walking: "걷기"
        case .running: "달리기"
        case .cycling: "자전거"
        case .bus: "버스"
        case .subway: "지하철"
        case .taxi: "택시"
        case .car: "자가용"
        case .train: "기차"
        case .airplane: "비행기"
        case .ship: "배"
        }
    }

    private func confidenceName(_ confidence: ConfidenceLevel) -> String {
        switch confidence {
        case .low: "낮은 신뢰"
        case .medium: "중간 신뢰"
        case .high: "높은 신뢰"
        }
    }

    private func actualSourceName(_ source: ActualSource) -> String {
        switch source {
        case .manual: "직접 기록"
        case .timer: "타이머"
        case .healthKit: "Apple 건강"
        case .calendar: "캘린더"
        case .location: "위치"
        case .photo: "사진"
        }
    }

    private func laneAllocation<Item: Identifiable>(
        _ items: [Item],
        span: (Item) -> TimeSpan
    ) -> (lanes: [Item.ID: Int], count: Int)
    where Item.ID: Hashable {
        let sorted = items.sorted {
            let lhs = span($0)
            let rhs = span($1)
            if lhs.start == rhs.start {
                return lhs.end < rhs.end
            }
            return lhs.start < rhs.start
        }
        var laneEnds: [Date] = []
        var lanes: [Item.ID: Int] = [:]

        for item in sorted {
            let itemSpan = span(item)
            let lane = laneEnds.firstIndex {
                $0 <= itemSpan.start
            } ?? laneEnds.count

            if lane == laneEnds.count {
                laneEnds.append(itemSpan.end)
            } else {
                laneEnds[lane] = itemSpan.end
            }
            lanes[item.id] = lane
        }

        return (lanes, laneEnds.count)
    }

    private func timelineBlock(
        id: UUID = UUID(),
        planID: UUID? = nil,
        title: String,
        span: TimeSpan,
        top: CGFloat,
        height: CGFloat,
        isFixed: Bool,
        groupCount: Int? = nil,
        actualFraction: Double? = nil,
        status: PlanStatus = .planned,
        isActual: Bool = false,
        opensLocationTimeline: Bool = false,
        detailText: String? = nil
    ) -> TimelineBlock {
        let overlap = span.intersection(with: visibleSpan) ?? span
        let duration = max(1, visibleSpan.duration)
        let start = CGFloat(
            overlap.start.timeIntervalSince(visibleSpan.start) / duration
        )
        let length = CGFloat(overlap.duration / duration)
        return TimelineBlock(
            id: id,
            planID: planID,
            title: title,
            start: max(0, min(1, start)),
            length: max(0.012, min(1, length)),
            top: top,
            height: height,
            isFixed: isFixed,
            groupCount: groupCount,
            actualFraction: actualFraction,
            status: status,
            isActual: isActual,
            opensLocationTimeline: opensLocationTimeline,
            startsAt: span.start,
            endsAt: span.end,
            detailText: detailText
        )
    }

    private var visibleSpan: TimeSpan {
        TimelineAggregationEngine().interval(
            for: scale.timelineLevel,
            containing: model.selectedDate
        )
    }

    private var groupRows: [TimelineRowModel] {
        [
            .init(
                title: "조사",
                dotColor: .clear,
                blocks: [.init(title: "시장 조사", start: 0.02, length: 0.26)]
            ),
            .init(
                title: "분석",
                dotColor: .clear,
                blocks: [.init(title: "경쟁사 분석", start: 0.16, length: 0.26)]
            ),
            .init(
                title: "컨셉",
                dotColor: .clear,
                blocks: [.init(title: "컨셉 정리", start: 0.30, length: 0.28)]
            ),
            .init(
                title: "초안",
                dotColor: .clear,
                blocks: [.init(title: "보고서 초안", start: 0.58, length: 0.26)]
            ),
        ]
    }

    @ViewBuilder
    private var gridLines: some View {
        if scale == .day || !viewport.isFull {
            HStack(spacing: 0) {
                Color.clear.frame(width: scheduleLabelColumnWidth)
                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        ForEach(axisMarkers) { marker in
                            Rectangle()
                                .fill(
                                    Color(
                                        red: 0.96,
                                        green: 0.96,
                                        blue: 0.97
                                    )
                                )
                                .frame(width: 0.5)
                                .position(
                                    x: proxy.size.width
                                        * CGFloat(marker.fraction),
                                    y: proxy.size.height / 2
                                )
                        }
                    }
                }
                .clipped()
            }
        }
    }

    @ViewBuilder
    private func currentLine(at date: Date) -> some View {
        if visibleSpan.contains(date) {
        GeometryReader { proxy in
            let timelineWidth = max(
                1,
                proxy.size.width - scheduleLabelColumnWidth
            )
            let viewportFraction = (
                Double(nowFraction(at: date)) - viewport.start
            ) / viewport.length
            let x = scheduleLabelColumnWidth
                + timelineWidth * CGFloat(viewportFraction)

            if (0...1).contains(viewportFraction) {
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Color.tpNow)
                        .frame(width: 2, height: proxy.size.height)
                        .position(x: x, y: proxy.size.height / 2)

                    Circle()
                        .fill(Color.tpNow)
                        .frame(width: 8, height: 8)
                        .position(x: x, y: 1)

                    if scale == .day, !isGroup {
                        Text(
                            date.formatted(
                                date: .omitted,
                                time: .shortened
                            )
                        )
                            .font(.taption(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.tpNow, in: Capsule())
                            .fixedSize()
                            .position(x: x, y: 7)
                    }
                }
            }
        }
        .zIndex(20)
        }
    }

    private var photoRow: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.tpPhotoDark)
                    .frame(width: 8, height: 8)
                Text("사진")
                    .font(.taption(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(Color.tpInk)
            .padding(.leading, 8)
            .frame(
                width: scheduleLabelColumnWidth,
                alignment: .leading
            )

            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    ForEach(photoClusters) { cluster in
                        if let x = photoMarkerX(
                            cluster,
                            width: proxy.size.width
                        ) {
                            photoMarker(cluster: cluster, x: x)
                        }
                    }
                }
            }
            .clipped()
        }
        .frame(height: 65)
        .background(Color(red: 0.99, green: 0.98, blue: 1.00))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(red: 0.95, green: 0.95, blue: 0.96)).frame(height: 0.5)
        }
    }

    private func photoMarker(
        cluster: PhotoCluster,
        x: CGFloat
    ) -> some View {
        Button {
            model.selectedPhotoCluster = cluster
        } label: {
            VStack(spacing: 2) {
                ZStack(alignment: .topTrailing) {
                    PhotoAssetThumbnail(
                        model: model,
                        localIdentifier: cluster.representative.id
                    )
                        .frame(width: 39, height: 39)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(.white, lineWidth: 2)
                        }
                        .shadow(color: .black.opacity(0.24), radius: 2.5, y: 1)

                    if cluster.additionalCount > 0 {
                        Text("+\(cluster.additionalCount)")
                            .font(.taption(size: 7, weight: .black))
                            .foregroundStyle(.white)
                            .frame(minWidth: 17, minHeight: 17)
                            .background(Color.tpPhotoDark, in: Capsule())
                            .overlay { Capsule().stroke(.white, lineWidth: 1.5) }
                            .offset(x: 5, y: -5)
                    }
                }
                Text(
                    cluster.capturedAt.formatted(
                        date: .omitted,
                        time: .shortened
                    )
                )
                    .font(.taption(size: 6.5, weight: .black))
                    .foregroundStyle(Color.tpPhotoDark)
            }
        }
        .buttonStyle(.plain)
        .position(
            x: x,
            y: 32
        )
    }

    private func photoMarkerX(
        _ cluster: PhotoCluster,
        width: CGFloat
    ) -> CGFloat? {
        let fraction =
            cluster.capturedAt.timeIntervalSince(visibleSpan.start)
            / max(1, visibleSpan.duration)
        guard viewport.start <= fraction, fraction <= viewport.end else {
            return nil
        }
        let viewportFraction =
            (fraction - viewport.start) / viewport.length
        return min(
            width - 22,
            max(22, width * CGFloat(viewportFraction))
        )
    }

    private var summaryStrip: some View {
        HStack(spacing: 0) {
            Text(summaryTitle)
                .font(.taption(size: scale == .month ? 9 : 10, weight: .regular))
                .foregroundStyle(Color.tpSecondary)
                .padding(.leading, scale == .month ? 4 : 8)
                .frame(
                    width: scheduleLabelColumnWidth,
                    alignment: .leading
                )

            HStack(spacing: 3) {
                ForEach(summaryColors.indices, id: \.self) { index in
                    Button {
                        zoomIntoSummary(summaryBuckets[index])
                    } label: {
                        ZStack {
                            RoundedRectangle(
                                cornerRadius: 5,
                                style: .continuous
                            )
                            .fill(
                                summaryColors[index].color.opacity(
                                    summaryColors[index].opacity
                                )
                            )
                            if summaryBuckets[index].photoCount > 0 {
                                HStack(spacing: 1) {
                                    Image(systemName: "photo.fill")
                                    Text(
                                        "\(summaryBuckets[index].photoCount)"
                                    )
                                }
                                .font(.taption(size: 6.5, weight: .black))
                                .foregroundStyle(Color.tpPhotoDark)
                            }
                        }
                        .frame(height: 18)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        summaryAccessibilityLabel(
                            summaryBuckets[index]
                        )
                    )
                }
            }
            .padding(.horizontal, 3)
        }
        .frame(height: 46)
        .background(Color(red: 0.98, green: 0.98, blue: 0.985))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.tpLine).frame(height: 0.5)
        }
    }

    private var planActualStrip: some View {
        HStack(spacing: 5) {
            Image(systemName: "chart.bar.fill")
                .font(.taption(size: 8, weight: .bold))
                .foregroundStyle(Color.tpProjectDark)
            Text("계획")
                .foregroundStyle(Color.tpSecondary)
            Text(durationLabel(visiblePlannedDuration))
                .fontWeight(.black)
            Text("· 실제")
                .foregroundStyle(Color.tpSecondary)
            Text(durationLabel(visibleActualDuration))
                .fontWeight(.black)
                .foregroundStyle(Color.tpProjectDark)
        }
        .font(.taption(size: 9))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Color.tpProject.opacity(0.45),
            in: Capsule()
        )
        .frame(maxWidth: .infinity, minHeight: 30)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.tpLine).frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
    }

    private var summaryTitle: String {
        switch scale {
        case .week, .day: "일 요약"
        case .month: "주·일 요약"
        case .year: "월·주·일 요약"
        }
    }

    private var summaryColors: [SummaryColor] {
        let buckets = summaryBuckets
        let maximum = max(
            1,
            buckets.map {
                max($0.actualDuration, $0.plannedDuration)
            }.max() ?? 1
        )
        return buckets.map { bucket in
            let dominant = bucket.categories.max {
                max($0.actual, $0.planned) < max($1.actual, $1.planned)
            }
            let definition = dominant.flatMap { value in
                model.snapshot.categories.first {
                    $0.id == value.categoryID
                }
            }
            let activity = max(bucket.actualDuration, bucket.plannedDuration)
            return SummaryColor(
                Color(hex: definition?.darkHex ?? "#D9D9DD"),
                activity == 0 ? 0.18 : 0.25 + 0.70 * activity / maximum
            )
        }
    }

    private var contentHeight: CGFloat {
        let footerHeight: CGFloat
        if scale == .day {
            footerHeight = !isGroup && !photoClusters.isEmpty ? 65 : 0
        } else {
            footerHeight = 46
        }
        let planActualHeight: CGFloat =
            scale == .day && hasVisibleActuals ? 30 : 0
        return rows.reduce(0) { $0 + $1.height }
            + footerHeight
            + planActualHeight
    }

    private func nowFraction(at date: Date) -> CGFloat {
        max(
            0,
            min(
                1,
                CGFloat(
                    date.timeIntervalSince(visibleSpan.start)
                        / max(1, visibleSpan.duration)
                )
            )
        )
    }

    private var viewportMinimumLength: Double {
        GanttViewport.oneMinuteMinimumLength(
            for: visibleSpan.duration
        )
    }

    private var currentZoomStage: GanttZoomStage {
        GanttZoomStage.nearest(
            to: visibleSpan.duration * viewport.length
        )
    }

    private var viewportVisibleSpan: TimeSpan {
        TimeSpan(
            start: visibleSpan.start.addingTimeInterval(
                visibleSpan.duration * viewport.start
            ),
            end: visibleSpan.start.addingTimeInterval(
                visibleSpan.duration * viewport.end
            )
        )
    }

    private var axisMarkers: [TimelineAxisMarker] {
        guard !viewport.isFull else {
            let labels = scale.axisLabels
            return labels.enumerated().map { index, label in
                TimelineAxisMarker(
                    id: "full-\(index)-\(label)",
                    fraction: Double(index) / Double(max(1, labels.count)),
                    label: label,
                    isCurrent: label == currentAxisLabel
                )
            }
        }

        let span = viewportVisibleSpan
        let step = axisTickInterval
        let start = span.start.timeIntervalSinceReferenceDate
        let end = span.end.timeIntervalSinceReferenceDate
        var next = ceil(start / step) * step
        var markers: [TimelineAxisMarker] = []

        while next <= end, markers.count < 64 {
            let date = Date(timeIntervalSinceReferenceDate: next)
            markers.append(
                TimelineAxisMarker(
                    id: "zoom-\(next)",
                    fraction: (next - start) / max(1, end - start),
                    label: axisTickLabel(date),
                    isCurrent: abs(date.timeIntervalSinceNow) < step / 2
                )
            )
            next += step
        }

        if markers.isEmpty {
            let date = span.start.addingTimeInterval(span.duration / 2)
            return [
                TimelineAxisMarker(
                    id: "zoom-center-\(date.timeIntervalSinceReferenceDate)",
                    fraction: 0.5,
                    label: axisTickLabel(date),
                    isCurrent: span.contains(.now)
                )
            ]
        }
        return markers
    }

    private var axisTickInterval: TimeInterval {
        let target = viewportVisibleSpan.duration / 6
        let supportedSteps: [TimeInterval] = [
            60,
            5 * 60,
            15 * 60,
            30 * 60,
            60 * 60,
            3 * 60 * 60,
            6 * 60 * 60,
            12 * 60 * 60,
            24 * 60 * 60,
            2 * 24 * 60 * 60,
            5 * 24 * 60 * 60,
            7 * 24 * 60 * 60,
            14 * 24 * 60 * 60,
            30 * 24 * 60 * 60,
            90 * 24 * 60 * 60,
        ]
        return supportedSteps.first { $0 >= target }
            ?? supportedSteps.last!
    }

    private func axisTickLabel(_ date: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        if viewportVisibleSpan.duration <= 2 * 24 * 60 * 60 {
            return String(
                format: "%02d:%02d",
                calendar.component(.hour, from: date),
                calendar.component(.minute, from: date)
            )
        }
        if viewportVisibleSpan.duration <= 90 * 24 * 60 * 60 {
            return "\(calendar.component(.month, from: date)).\(calendar.component(.day, from: date))"
        }
        return "\(calendar.component(.month, from: date))월"
    }

    private func markerX(
        _ marker: TimelineAxisMarker,
        width: CGFloat
    ) -> CGFloat {
        min(
            max(18, width - 18),
            max(18, width * CGFloat(marker.fraction))
        )
    }

    private var currentAxisLabel: String {
        let calendar = Calendar.autoupdatingCurrent
        return switch scale {
        case .day:
            String(format: "%02d", calendar.component(.hour, from: .now))
        case .week:
            Date.now.formatted(
                Date.FormatStyle()
                    .weekday(.short)
                    .locale(Locale(identifier: "ko_KR"))
            )
        case .month:
            "\(calendar.component(.day, from: .now))"
        case .year:
            "\(calendar.component(.month, from: .now))"
        }
    }

    private var photoClusters: [PhotoCluster] {
        PhotoClusterer.cluster(
            model.snapshot.photos.filter {
                visibleSpan.contains($0.capturedAt)
            }
        )
    }

    private var hasVisibleActuals: Bool {
        model.snapshot.actuals.contains {
            $0.span().intersection(with: visibleSpan) != nil
        }
    }

    private var visibleActualDuration: TimeInterval {
        model.snapshot.actuals.reduce(0) { result, actual in
            result
                + (actual.span().intersection(with: visibleSpan)?.duration
                    ?? 0)
        }
    }

    private var visiblePlannedDuration: TimeInterval {
        let leafPlans = storedPlans.filter { plan in
            plan.span.intersection(with: visibleSpan) != nil
                && !storedPlans.contains { $0.parentID == plan.id }
        }
        return leafPlans.reduce(0) { result, plan in
            result
                + (plan.span.intersection(with: visibleSpan)?.duration ?? 0)
        }
    }

    private func durationLabel(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int(interval / 60))
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(remainder)분" }
        if remainder == 0 { return "\(hours)시간" }
        return "\(hours)시간 \(remainder)분"
    }

    private var summaryBuckets: [SummaryBucket] {
        let childLevel: TimelineLevel
        switch scale {
        case .day:
            return []
        case .week:
            childLevel = .day
        case .month:
            childLevel = .week
        case .year:
            childLevel = .month
        }
        return TimelineAggregationEngine().hierarchySummaries(
            for: scale.timelineLevel,
            containing: model.selectedDate,
            plans: model.snapshot.plans,
            actuals: model.snapshot.actuals,
            photos: model.snapshot.photos
        )[childLevel] ?? []
    }

    private func zoomIntoSummary(_ bucket: SummaryBucket) {
        model.selectedDate = bucket.span.start
        switch scale {
        case .week:
            model.selectScale(.day)
        case .month:
            model.selectScale(.week)
        case .year:
            model.selectScale(.month)
        case .day:
            break
        }
    }

    private func summaryAccessibilityLabel(
        _ bucket: SummaryBucket
    ) -> String {
        let range =
            bucket.span.start.formatted(.dateTime.month().day())
            + "부터 "
            + bucket.span.end.addingTimeInterval(-1)
                .formatted(.dateTime.month().day())
        let photoText = bucket.photoCount > 0
            ? ", 사진 \(bucket.photoCount)장"
            : ""
        return "\(range) 요약\(photoText), 탭하여 확대"
    }

    private func viewportDragGesture(
        width: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard editingPlanID == nil,
                      abs(value.translation.width)
                        > abs(value.translation.height) else {
                    return
                }
                if dragOrigin == nil {
                    dragOrigin = viewport
                }
                guard let dragOrigin else { return }
                viewport = dragOrigin.panning(
                    translation: Double(value.translation.width),
                    viewportWidth: Double(width)
                )
            }
            .onEnded { _ in
                dragOrigin = nil
            }
    }

    private var viewportMagnifyGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                if magnifyOrigin == nil {
                    magnifyOrigin = viewport
                    editingPlanID = nil
                }
                guard let magnifyOrigin else { return }
                viewport = magnifyOrigin.magnifying(
                    by: Double(value.magnification),
                    anchor: Double(value.startAnchor.x),
                    minimumLength: viewportMinimumLength
                )
            }
            .onEnded { value in
                finishSemanticMagnification(
                    factor: Double(value.magnification),
                    anchor: Double(value.startAnchor.x)
                )
                magnifyOrigin = nil
            }
    }

    private func finishSemanticMagnification(
        factor: Double,
        anchor: Double
    ) {
        let origin = magnifyOrigin ?? viewport
        let zoomsIn = factor >= 1.15
        let zoomsOut = factor <= 0.85
        guard zoomsIn || zoomsOut else {
            viewport = origin
            return
        }

        if scale != .day {
            let targetScale = zoomsIn ? scale.narrower : scale.broader
            guard let targetScale else {
                viewport = origin
                return
            }
            transitionScale(
                to: targetScale,
                origin: origin,
                anchor: anchor
            )
            return
        }

        let originStage = GanttZoomStage.nearest(
            to: visibleSpan.duration * origin.length
        )
        if zoomsOut, originStage == .day {
            guard let broader = scale.broader else {
                viewport = origin
                return
            }
            transitionScale(
                to: broader,
                origin: origin,
                anchor: anchor
            )
            return
        }

        let targetStage = zoomsIn
            ? originStage.narrower
            : originStage.broader
        guard let targetStage, targetStage >= .day else {
            viewport = origin
            return
        }
        viewport = origin.fitting(
            visibleDuration: targetStage.duration,
            within: visibleSpan.duration,
            anchor: anchor
        )
        zoomFeedbackSequence += 1
    }

    private func transitionScale(
        to targetScale: TimeScale,
        origin: GanttViewport,
        anchor: Double
    ) {
        let clampedAnchor = min(1, max(0, anchor))
        let anchorFraction =
            origin.start + origin.length * clampedAnchor
        model.selectedDate = visibleSpan.start.addingTimeInterval(
            visibleSpan.duration * anchorFraction
        )
        viewport = .full
        model.selectScale(targetScale)
        zoomFeedbackSequence += 1
    }

    private func resetViewport(withFeedback: Bool = false) {
        let changed = !viewport.isFull
        viewport = .full
        dragOrigin = nil
        magnifyOrigin = nil
        editingPlanID = nil
        if withFeedback, changed {
            zoomFeedbackSequence += 1
        }
    }

    private func focusOnBlock(_ block: TimelineBlock) {
        let totalDuration = max(60, visibleSpan.duration)
        let blockStart: Double
        let blockLength: Double
        if let startsAt = block.startsAt,
           let endsAt = block.endsAt {
            blockStart = startsAt.timeIntervalSince(visibleSpan.start)
                / totalDuration
            blockLength = endsAt.timeIntervalSince(startsAt)
                / totalDuration
        } else {
            blockStart = Double(block.start)
            blockLength = Double(block.length)
        }

        viewport = GanttViewport.full.focusing(
            start: blockStart,
            length: blockLength,
            minimumLength: viewportMinimumLength
        )
        editingPlanID = nil
        zoomFeedbackSequence += 1
    }

    private func handleTap(_ block: TimelineBlock) {
        if block.opensLocationTimeline {
            model.detail = .locationTimeline
            return
        }

        if block.groupCount != nil {
            if let planID = block.planID {
                model.openGroup(planID)
            }
            return
        }

        let plan = block.planID.flatMap { id in
            model.snapshot.plans.first { $0.id == id }
        }
        model.selectedAction = QuickActionItem(
            planID: plan?.id,
            title: block.title,
            time: plan.map {
                "\($0.span.start.formatted(date: .omitted, time: .shortened)) → \($0.span.end.formatted(date: .omitted, time: .shortened))"
            } ?? (block.title == "영어" ? "21:00 → 22:00" : "09:00 → 12:00"),
            context: plan.map {
                "\(PlanCategory(categoryID: $0.categoryID).rawValue) · 계획 \(Int($0.span.duration / 60))분"
            } ?? (block.title == "영어"
                ? "자격증 취득 › 이번 주 학습 · 계획 1시간"
                : "2026년 출시 목표 › 이번 주 기획안 확정")
        )
    }
}

private struct TimelineBlockSlice {
    let centerX: CGFloat
    let width: CGFloat
}

private struct TimelineRow: View {
    let row: TimelineRowModel
    let editingPlanID: UUID?
    let visibleDuration: TimeInterval
    let viewport: GanttViewport
    let onBlockTap: (TimelineBlock) -> Void
    let onBlockDoubleTap: (TimelineBlock) -> Void
    let onEdit: (UUID?) -> Void
    let onMove: (TimelineBlock, TimeInterval) -> Void
    let onResizeStart: (TimelineBlock, TimeInterval) -> Void
    let onResizeEnd: (TimelineBlock, TimeInterval) -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                if row.dotColor != .clear {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(row.dotColor)
                        .frame(width: 8, height: 8)
                }
                Text(row.title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .font(.taption(size: row.title.count > 4 ? 9 : 10.5, weight: .semibold))
            .foregroundStyle(Color.tpInk)
            .padding(.leading, row.title.count > 4 ? 4 : 8)
            .frame(
                width: scheduleLabelColumnWidth,
                alignment: .leading
            )

            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    ForEach(row.blocks) { block in
                        if let slice = visibleSlice(
                            for: block,
                            width: proxy.size.width
                        ) {
                            TimelineBar(
                                block: block,
                                color: row.fillColor,
                                actualColor: row.actualColor,
                                width: slice.width,
                                isEditing: editingPlanID == block.planID,
                                visibleDuration: visibleDuration,
                                secondsPerPoint:
                                    visibleDuration
                                    / max(1, proxy.size.width),
                                onTap: { onBlockTap(block) },
                                onDoubleTap: {
                                    onBlockDoubleTap(block)
                                },
                                onEdit: { onEdit(block.planID) },
                                onMove: { onMove(block, $0) },
                                onResizeStart: {
                                    onResizeStart(block, $0)
                                },
                                onResizeEnd: {
                                    onResizeEnd(block, $0)
                                }
                            )
                                .position(
                                    x: slice.centerX,
                                    y: block.top + block.height / 2
                                )
                        }
                    }
                }
            }
            .clipped()
        }
        .frame(height: row.height)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(red: 0.95, green: 0.95, blue: 0.96))
                .frame(height: 0.5)
        }
    }

    private func visibleSlice(
        for block: TimelineBlock,
        width: CGFloat
    ) -> TimelineBlockSlice? {
        let blockStart = Double(block.start)
        let blockEnd = blockStart + Double(block.length)
        let overlapStart = max(blockStart, viewport.start)
        let overlapEnd = min(blockEnd, viewport.end)
        guard overlapStart < overlapEnd else { return nil }

        let startFraction =
            (overlapStart - viewport.start) / viewport.length
        let endFraction =
            (overlapEnd - viewport.start) / viewport.length
        let naturalWidth =
            width * CGFloat(endFraction - startFraction)
        return TimelineBlockSlice(
            centerX:
                width * CGFloat((startFraction + endFraction) / 2),
            width: max(block.minimumWidth, naturalWidth)
        )
    }
}

private struct TimelineBar: View {
    let block: TimelineBlock
    let color: Color
    let actualColor: Color
    let width: CGFloat
    let isEditing: Bool
    let visibleDuration: TimeInterval
    let secondsPerPoint: TimeInterval
    let onTap: () -> Void
    let onDoubleTap: () -> Void
    let onEdit: () -> Void
    let onMove: (TimeInterval) -> Void
    let onResizeStart: (TimeInterval) -> Void
    let onResizeEnd: (TimeInterval) -> Void

    var body: some View {
        HStack(spacing: 3) {
            Text(primaryText)
                .font(.taption(size: block.height <= 20 ? 9.5 : 10.5, weight: .semibold))
                .foregroundStyle(
                    block.isActual
                        ? Color.white
                        : Color.tpInk.opacity(0.64)
                )
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            if !showsMinuteDetails, let count = block.groupCount {
                Spacer(minLength: 1)
                Text("▸ \(count)")
                    .font(.taption(size: 8.5, weight: .bold))
                    .foregroundStyle(Color.tpInk.opacity(0.62))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.70), in: Capsule())
            }
            if !showsMinuteDetails, block.status == .completed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.taption(size: 9, weight: .bold))
                    .foregroundStyle(actualColor)
            }
        }
        .padding(.horizontal, 6)
        .frame(
            width: width,
            height: block.height,
            alignment: .leading
        )
        .background {
            if block.isFixed {
                if block.isActual {
                    actualColor.opacity(0.82)
                } else {
                    FixedStripeBackground()
                }
            } else {
                color
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: block.height <= 20 ? 10 : 7, style: .continuous))
        .overlay {
            if block.isFixed {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(
                        block.isActual
                            ? actualColor
                            : Color(
                                red: 0.78,
                                green: 0.78,
                                blue: 0.80
                            ),
                        lineWidth: 1
                    )
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let fraction = block.actualFraction, fraction > 0 {
                Capsule()
                    .fill(actualColor)
                    .frame(
                        width: max(4, width * CGFloat(fraction)),
                        height: 3
                    )
                    .padding(.horizontal, 2)
                    .padding(.bottom, 2)
            }
        }
        .overlay {
            if isEditing, block.planID != nil {
                HStack {
                    resizeHandle
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onEnded {
                                    onResizeStart(
                                        $0.translation.width * secondsPerPoint
                                    )
                                }
                        )
                    Spacer()
                    resizeHandle
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onEnded {
                                    onResizeEnd(
                                        $0.translation.width * secondsPerPoint
                                    )
                                }
                        )
                }
                .padding(.horizontal, -5)
            }
        }
        .highPriorityGesture(
            TapGesture(count: 2)
                .exclusively(before: TapGesture(count: 1))
                .onEnded { value in
                    switch value {
                    case .first:
                        onDoubleTap()
                    case .second:
                        onTap()
                    }
                }
        )
        .onLongPressGesture(minimumDuration: 0.35, perform: onEdit)
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onEnded {
                    guard isEditing, block.planID != nil else { return }
                    onMove($0.translation.width * secondsPerPoint)
                }
        )
        .accessibilityHint(
            block.isFixed
                ? "두 번 탭하면 일정에 맞춰 확대합니다"
                : "두 번 탭하면 확대하고, 길게 누른 뒤 드래그하면 이동하며 양 끝점을 끌면 길이를 조절합니다"
        )
    }

    private var showsMinuteDetails: Bool {
        visibleDuration
            <= GanttZoomStage.oneMinute.duration * 1.15
    }

    private var primaryText: String {
        GanttPrecisionPresentation.label(
            title: block.title,
            startsAt: block.startsAt,
            endsAt: block.endsAt,
            detailText: block.detailText,
            visibleDuration: visibleDuration
        )
    }

    private var resizeHandle: some View {
        Circle()
            .fill(Color.white)
            .frame(width: 12, height: 12)
            .overlay {
                Circle().stroke(Color.tpInk.opacity(0.65), lineWidth: 1.5)
            }
            .shadow(color: .black.opacity(0.16), radius: 2)
    }
}

private struct TimelineRowModel: Identifiable {
    let id = UUID()
    let title: String
    let category: PlanCategory?
    let dotColor: Color
    let customFillColor: Color?
    let customActualColor: Color?
    let height: CGFloat
    let blocks: [TimelineBlock]

    init(
        title: String,
        category: PlanCategory? = nil,
        dotColor: Color? = nil,
        fillColor: Color? = nil,
        actualColor: Color? = nil,
        height: CGFloat = 60,
        blocks: [TimelineBlock]
    ) {
        self.title = title
        self.category = category
        self.dotColor = dotColor ?? category?.darkColor ?? .clear
        self.customFillColor = fillColor
        self.customActualColor = actualColor
        self.height = height
        self.blocks = blocks
    }

    var fillColor: Color {
        customFillColor
            ?? category?.color
            ?? Color(red: 0.94, green: 0.94, blue: 0.95)
    }

    var actualColor: Color {
        customActualColor
            ?? category?.darkColor
            ?? Color.tpSecondary
    }
}

private struct TimelineBlock: Identifiable {
    let id: UUID
    let planID: UUID?
    let title: String
    let start: CGFloat
    let length: CGFloat
    let top: CGFloat
    let height: CGFloat
    let isFixed: Bool
    let groupCount: Int?
    let actualFraction: Double?
    let status: PlanStatus
    let isActual: Bool
    let opensLocationTimeline: Bool
    let minimumWidth: CGFloat
    let startsAt: Date?
    let endsAt: Date?
    let detailText: String?

    init(
        id: UUID = UUID(),
        planID: UUID? = nil,
        title: String,
        start: CGFloat,
        length: CGFloat,
        top: CGFloat = 16,
        height: CGFloat = 26,
        isFixed: Bool = false,
        groupCount: Int? = nil,
        actualFraction: Double? = nil,
        status: PlanStatus = .planned,
        isActual: Bool = false,
        opensLocationTimeline: Bool = false,
        minimumWidth: CGFloat = 18,
        startsAt: Date? = nil,
        endsAt: Date? = nil,
        detailText: String? = nil
    ) {
        self.id = id
        self.planID = planID
        self.title = title
        self.start = start
        self.length = length
        self.top = top
        self.height = height
        self.isFixed = isFixed
        self.groupCount = groupCount
        self.actualFraction = actualFraction
        self.status = status
        self.isActual = isActual
        self.opensLocationTimeline = opensLocationTimeline
        self.minimumWidth = minimumWidth
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.detailText = detailText
    }
}

private struct SummaryColor {
    let color: Color
    let opacity: Double

    init(_ color: Color, _ opacity: Double) {
        self.color = color
        self.opacity = opacity
    }
}

private struct PhotoAssetThumbnail: View {
    @Bindable var model: AppModel
    let localIdentifier: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [.tpPhoto, .tpPhotoDark.opacity(0.72)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "photo")
                        .font(.taption(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .clipped()
        .task(id: localIdentifier) {
            guard image == nil else { return }
            guard let data = try? await model.photoThumbnailData(
                localIdentifier: localIdentifier,
                size: CGSize(width: 120, height: 120)
            ) else {
                return
            }
            image = UIImage(data: data)
        }
    }
}

#Preview {
    ScheduleView(model: AppModel())
}
