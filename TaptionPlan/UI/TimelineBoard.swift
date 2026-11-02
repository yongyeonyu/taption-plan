import SwiftUI
import UIKit
import MapKit

struct TimelineBoard: View {
    @Bindable var model: AppModel
    let scale: TimeScale
    let storedPlans: [PlanRecord]
    var isGroup = false
    var usesFullWidthRuler = false
    @Binding var dayZoom: TimelineZoomPreset
    @Binding var editingPlanID: UUID?
    var onPlayheadMove: ((Date) -> Void)?
    var onSelection: ((TimelineSelection) -> Void)?
    var onFocus: ((TimelineSelection) -> Void)?
    var onPhotoSelection: ((PhotoCluster) -> Void)?
    @State private var viewport = GanttViewport.full
    @State private var dragOrigin: GanttViewport?
    @State private var magnifyOrigin: GanttViewport?
    @State private var continuousCenterDate: Date = .now
    @State private var continuousDragOrigin: Date?
    @State private var continuousTimelineDuration: TimeInterval = 86_400
    @State private var preserveViewportAfterContinuousDrag = false
    // During a continuous-day drag, keep a slightly wider data window alive
    // so the rows are not rebuilt on every 240 Hz touch sample.  Blocks carry
    // their source dates and are reprojected against the moving display span
    // at render time; the wider window is rebuilt only when a drag starts or
    // ends.
    @State private var dragLayoutSpan: TimeSpan?
    /// Keep row geometry stable while the timeline is being dragged.
    @State private var dragLayoutSnapshot: NLETimelineRenderSnapshot?
    @State private var zoomFeedbackSequence = 0
    @State private var continuousMagnifyOrigin: ContinuousMagnifyOrigin?
    @State private var selectedRowID: String?
    @State private var layoutCache = NLETimelineRenderCache()
    @State private var dataIndexCache = TimelineBoardDataIndexCache()
    @State private var summaryCache = TimelineSummaryCache()
    @State private var lastContinuousRenderUptime: TimeInterval = 0
    // Touch hardware can deliver 120/240 samples per second, while the
    // timeline only needs to invalidate at the display cadence.  Keeping a
    // separate gate for viewport gestures prevents day, week, and month
    // pans/pinches from rebuilding every row for every sample.
    @State private var lastViewportRenderUptime: TimeInterval = 0
    // This reference is intentionally mutated without publishing SwiftUI
    // state. It aggregates 120/240 Hz input and emits one support event at
    // gesture end, keeping the render path free of per-sample diagnostics.
    @State private var gestureMetrics = TimelineGestureMetrics()
    // Keep the ruler compact so the timeline retains the larger share of the
    // screen while still leaving room for labels and holiday names.
    private let axisHeight: CGFloat = 34

    var body: some View {
        // Resolve the moving span once per render pass.  Before this local
        // snapshot was introduced, every row and every gesture overlay asked
        // for `visibleSpan` independently, rebuilding Calendar intervals
        // several dozen times while a 240 Hz touch stream was being reduced
        // to the 60 Hz display budget.
        let displaySpan = visibleSpan
        let layoutSpan = dragLayoutSpan ?? displaySpan
        let layout = dragLayoutSnapshot ?? cachedLayoutSnapshot(in: layoutSpan)
        // Axis labels are cheap to derive and must follow the moving
        // playhead even while the wider drag window keeps row geometry
        // cached.
        let displayAxisMarkers = dragLayoutSpan == nil
            ? layout.axisMarkers
            : axisMarkers(in: displaySpan)
        let visibleDuration = displaySpan.duration * viewport.length
        let cachedDragViewport = dragLayoutSpan.flatMap {
            TimelineCachedViewportProjection.viewport(
                displaySpan: displaySpan,
                dataSpan: $0,
                viewport: viewport
            )
        }
        let rowViewport = cachedDragViewport ?? viewport
        let usesCachedBlockFractions = dragLayoutSpan == nil
            || cachedDragViewport != nil
        GeometryReader { boardProxy in
            let contentTimelineWidth = max(
                1,
                boardProxy.size.width - scheduleLabelColumnWidth
            )
            let rulerTimelineWidth = max(
                1,
                boardProxy.size.width
                    - (usesFullWidthRuler ? 0 : scheduleLabelColumnWidth)
            )
            VStack(spacing: 0) {
                ScrollView(.vertical, showsIndicators: false) {
                    GeometryReader { _ in
                        ZStack(alignment: .topLeading) {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    editingPlanID = nil
                                }

                            // Rows can grow substantially once automatic
                            // location/activity history is populated. Lazy
                            // creation keeps off-screen rows out of the 240 Hz
                            // interaction path while fixed row heights still
                            // preserve the scrollable content size.
                            LazyVStack(spacing: 0) {
                                ForEach(layout.rows) { row in
                                    if row.id == "photo" {
                                        photoRow(layout.photoClusters)
                                            .draggable(row.id)
                                            .dropDestination(for: String.self) {
                                                sourceIDs, _ in
                                                guard let sourceID = sourceIDs.first
                                                else { return false }
                                                return finishRowDrop(
                                                    sourceID: sourceID,
                                                    targetID: row.id,
                                                    rows: layout.rows
                                                )
                                            }
                                    } else {
                                        TimelineRow(
                                            row: row,
                                            isSelected: selectedRowID == row.id,
                                            editingPlanID: editingPlanID,
                                            visibleDuration: visibleDuration,
                                            viewport: rowViewport,
                                            displaySpan: displaySpan,
                                            scale: scale,
                                            useCachedBlockFractions:
                                                usesCachedBlockFractions,
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
                                            },
                                            onRowTap: { handleRowTap(row) },
                                            onDrop: { sourceID in
                                                finishRowDrop(
                                                    sourceID: sourceID,
                                                    targetID: row.id,
                                                    rows: layout.rows
                                                )
                                            }
                                        )
                                    }
                                }

                                if scale != .day {
                                    summaryStrip(
                                        buckets: layout.summaryBuckets,
                                        colors: layout.summaryColors
                                    )
                                }
                            }

                            gridLines(markers: displayAxisMarkers)
                                .allowsHitTesting(false)

                            // The playhead is driven by `continuousCenterDate`
                            // during a drag and is always centered for the
                            // other resolutions. A minute-based TimelineView
                            // here only rebuilt this whole overlay for a date
                            // that was never read, so keep the line static
                            // until an actual playhead change arrives.
                            currentLine()
                                .allowsHitTesting(false)
                        }
                        .contentShape(Rectangle())
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .frame(height: layout.contentHeight)
                }
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .top
                )
                .scrollBounceBehavior(.basedOnSize)
                .simultaneousGesture(
                    viewportDragGesture(width: contentTimelineWidth)
                )
                // 시간표 핀치는 UIKit 인식기 한 경로로만 받는다. SwiftUI `MagnifyGesture`도 함께 걸려
                // 한 손짓이 두 번 반영됐다(PRF1101A01). 아래 눈금자는 이 인식기 밖이라 SwiftUI 핀치를 쓴다.
                .background {
                    TwoFingerPinchAttachment(
                        onChanged: { scale, anchor in
                            viewportMagnifyChanged(
                                factor: Double(scale),
                                anchor: Double(anchor)
                            )
                        },
                        onEnded: { scale, anchor in
                            viewportMagnifyEnded(
                                factor: Double(scale),
                                anchor: Double(anchor)
                            )
                        }
                    )
                }

                // Keep the time ruler below the timeline. It remains visible
                // while rows scroll, like a measuring scale in an editor.
                axis(markers: displayAxisMarkers)
                    .layoutPriority(1)
                    .simultaneousGesture(
                        viewportDragGesture(width: rulerTimelineWidth)
                    )
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            editingPlanID = nil
                        }
                    )
                    .highPriorityGesture(
                        viewportMagnifyGesture,
                        including: .subviews
                    )
            }
            .contentShape(Rectangle())
            .background {
                TwoFingerDoubleTapAttachment {
                    resetViewport(withFeedback: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
#if DEBUG
        .background(TimelineFrameBudgetProbeView())
#endif
        .background(Color.tpSurface)
        .onAppear {
            continuousCenterDate = model.selectedDate
            continuousTimelineDuration = continuousDuration(
                around: model.selectedDate
            )
            onPlayheadMove?(continuousCenterDate)
        }
        .onChange(of: scale) { _, _ in
            preserveViewportAfterContinuousDrag = false
            continuousCenterDate = model.selectedDate
            continuousTimelineDuration = continuousDuration(
                around: model.selectedDate
            )
            dragLayoutSpan = nil
            dragLayoutSnapshot = nil
            onPlayheadMove?(continuousCenterDate)
            resetViewport()
        }
        .onChange(of: model.selectedDate) { _, newDate in
            if continuousCenterDate != newDate {
                continuousCenterDate = newDate
                onPlayheadMove?(newDate)
            }
            let preserveViewport = preserveViewportAfterContinuousDrag
            preserveViewportAfterContinuousDrag = false
            // A continuous drag changes the selected date, but it must not
            // change the viewport that a preceding pinch established. Keep
            // the current length as a fallback as well, because SwiftUI can
            // deliver this callback after the gesture-end transaction.
            let keepZoom = preserveViewport
                || !viewport.isFull
                || hasCustomContinuousDuration
            if continuousDragOrigin == nil {
                dragLayoutSpan = nil
                dragLayoutSnapshot = nil
                if !keepZoom {
                    continuousTimelineDuration = continuousDuration(around: newDate)
                    resetViewport()
                }
            }
        }
        .accessibilityHint(
            "간트 본문을 드래그해 이동하고 두 손가락으로 최대 1분 단위까지 확대합니다"
        )
        .accessibilityIdentifier("schedule.timeline.board")
        .accessibilityValue(currentResolutionLabel)
        .sensoryFeedback(
            .impact(weight: .light),
            trigger: zoomFeedbackSequence
        )
    }

    private func cachedLayoutSnapshot(
        in span: TimeSpan
    ) -> NLETimelineRenderSnapshot {
        let key = NLETimelineRenderKey(
            documentRevision: model.timelineRevision,
            scale: scale,
            isGroup: isGroup,
            selectedGroupPlanID: model.selectedGroupPlanID,
            spanStart: span.start.timeIntervalSinceReferenceDate,
            spanEnd: span.end.timeIntervalSinceReferenceDate
        )
        return layoutCache.value(for: key) {
            makeLayoutSnapshot(in: span)
        }
    }

    private func makeLayoutSnapshot(
        in span: TimeSpan
    ) -> NLETimelineRenderSnapshot {
        let index = dataIndexCache.value(for: model.timelineRevision) {
            TimelineBoardDataIndex(
                plans: storedPlans,
                categories: model.snapshot.categories
            )
        }
        var rowModels = rows(in: span, index: index)
        let clusters: [PhotoCluster] = []
        rowModels = TimelineRowOrder.ordered(
            rowModels,
            id: \.id,
            savedIDs: model.snapshot.settings.timelineRowOrder
        )
        let buckets = summaryBuckets(in: span)
        let colors = summaryColors(for: buckets)
        // 넓은 배율의 요약 막대만 하단 여백을 쓴다.
        let footerHeight: CGFloat = scale == .day ? 0 : 46
        return NLETimelineRenderSnapshot(
            documentRevision: model.timelineRevision,
            rows: rowModels,
            axisMarkers: axisMarkers(in: span),
            photoClusters: clusters,
            summaryBuckets: buckets,
            summaryColors: colors,
            contentHeight: rowModels.reduce(0) { $0 + $1.height }
                + footerHeight
        )
    }

    private func axis(markers: [TimelineAxisMarker]) -> some View {
        HStack(spacing: 0) {
            if !usesFullWidthRuler {
                resolutionMenu
                    .frame(width: scheduleLabelColumnWidth)
            }
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Color.tpLine.opacity(0.8))
                        .frame(height: 0.5)
                        .position(
                            x: proxy.size.width / 2,
                            y: 12
                        )

                    ForEach(Array(markers.enumerated()), id: \.element.id) {
                        index,
                        marker in
                        let x = markerX(marker, width: proxy.size.width)
                        let nextX: CGFloat = {
                            guard index + 1 < markers.count else { return x }
                            return markerX(
                                markers[index + 1],
                                width: proxy.size.width
                            )
                        }()

                        Rectangle()
                            .fill(
                                marker.isCurrent
                                    ? Color.tpNow
                                    : Color.tpSecondary.opacity(0.72)
                            )
                            .frame(
                                width: marker.isCurrent ? 1.5 : 1,
                                height: 11
                            )
                            .position(x: x, y: 6)

                        if nextX > x + 2 {
                            ForEach(1..<rulerMinorDivisionCount, id: \.self) {
                                division in
                                Rectangle()
                                    .fill(Color.tpLine.opacity(0.72))
                                    .frame(width: 0.5, height: 5)
                                    .position(
                                        x: x + (nextX - x) * CGFloat(division)
                                            / CGFloat(rulerMinorDivisionCount),
                                        y: 3
                                    )
                            }
                        }

                        Group {
                            if marker.date != nil, scale != .day {
                                Button {
                                    drillDown(from: marker)
                                } label: {
                                    axisMarkerLabel(marker)
                                }
                                .buttonStyle(.plain)
                            } else {
                                axisMarkerLabel(marker)
                            }
                        }
                        .accessibilityLabel(
                            marker.holidayName.map {
                                "\(marker.label), \($0)"
                            } ?? marker.label
                        )
                                .font(
                                    .taption(
                                    size: 8.5,
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
                                x: x,
                                y: 24
                            )
                    }
                }
            }
            .clipped()
        }
        .overlay(alignment: .leading) {
            if usesFullWidthRuler {
                resolutionMenu
                    .frame(width: scheduleLabelColumnWidth)
                    .background(Color.tpSurface.opacity(0.92), in: Capsule())
            }
        }
        .padding(.horizontal, usesFullWidthRuler ? 0 : 4)
        .frame(height: axisHeight)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.tpLine).frame(height: 0.5)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func axisMarkerLabel(
        _ marker: TimelineAxisMarker
    ) -> some View {
        VStack(spacing: 0) {
            Text(marker.label)
            if let holidayName = marker.holidayName {
                Text(holidayName)
                    .font(.taption(size: 6.5, weight: .semibold))
                    .foregroundStyle(Color.tpNow)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
            }
        }
    }

    private func drillDown(from marker: TimelineAxisMarker) {
        guard let date = marker.date else { return }
        switch scale {
        case .week:
            model.selectedDate = date
            model.selectScale(.day)
            dayZoom = .oneHour
        case .month:
            model.selectedDate = date
            model.selectScale(.week)
            dayZoom = .oneWeek
        case .year:
            model.selectedDate = date
            model.selectScale(.month)
            dayZoom = .oneMonth
        case .day:
            return
        }
        onPlayheadMove?(date)
        zoomFeedbackSequence += 1
    }

    private var rulerMinorDivisionCount: Int {
        if isContinuousTimeline {
            return activeContinuousDuration <= 60 * 60 ? 5 : 4
        }
        return 2
    }

    private var resolutionMenu: some View {
        Menu {
            Section("화면 해상도") {
                ForEach(TimelineZoomPreset.scheduleCases) { preset in
                    Button {
                        selectResolution(preset)
                    } label: {
                        HStack {
                            Text(preset.rawValue)
                            Spacer()
                            Text(preset.detail)
                                .foregroundStyle(.secondary)
                            if preset == currentResolutionPreset {
                                Image(systemName: "checkmark")
                                    .accessibilityLabel("선택됨")
                            }
                        }
                    }
                }
            }
            if !viewport.isFull || hasCustomContinuousDuration {
                Section {
                    Button {
                        resetViewport(withFeedback: true)
                    } label: {
                        Label(
                            "현재 보기 전체로 맞춤",
                            systemImage: "arrow.counterclockwise"
                        )
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(currentResolutionLabel)
                Image(systemName: "chevron.down")
                    .font(.taption(size: 6.5, weight: .bold))
            }
            .font(.taption(size: 8.5, weight: .bold))
            .foregroundStyle(Color.tpSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("화면 해상도 \(currentResolutionLabel)")
        .accessibilityIdentifier("schedule.resolution.menu")
    }

    private var currentResolutionPreset: TimelineZoomPreset {
        TimelineZoomPreset.nearest(
            to: visibleSpan.duration * viewport.length
        )
    }

    private var currentResolutionLabel: String {
        TimelineZoomPreset.displayLabel(
            for: visibleSpan.duration * viewport.length
        )
    }

    private func selectResolution(_ preset: TimelineZoomPreset) {
        guard preset != .oneYear else { return }
        dayZoom = preset
        viewport = .full
        dragOrigin = nil
        magnifyOrigin = nil
        continuousMagnifyOrigin = nil
        continuousDragOrigin = nil
        continuousTimelineDuration = preset.duration
        model.selectScale(preset.preferredScale)
        if preset.preferredScale == .day {
            continuousCenterDate = model.selectedDate
            onPlayheadMove?(continuousCenterDate)
        }
        zoomFeedbackSequence += 1
    }

    private func selectScaleForResolution(_ targetScale: TimeScale) {
        model.selectScale(targetScale)
        dayZoom = TimelineZoomPreset.defaultPreset(for: targetScale)
        continuousTimelineDuration = continuousDuration(around: model.selectedDate)
    }

    private func rows(
        in span: TimeSpan,
        index: TimelineBoardDataIndex
    ) -> [TimelineRowModel] {
        let resolved = resolvedRows(in: span, index: index)
        // Do not synthesize sample rows when the user has no records. Apart
        // from showing misleading plans, those placeholder blocks forced the
        // board to build and diff several extra rows on every viewport tick.
        return resolved
    }

    private func finishRowDrop(
        sourceID: String,
        targetID: String,
        rows: [TimelineRowModel]
    ) -> Bool {
        let ids = rows.map(\.id)
        guard let ordered = TimelineRowOrder.moved(
            ids,
            sourceID: sourceID,
            targetID: targetID,
            savedIDs: model.snapshot.settings.timelineRowOrder
        ) else {
            return false
        }
        model.setTimelineRowOrder(ordered)
        return true
    }

    private func resolvedRows(
        in span: TimeSpan,
        index: TimelineBoardDataIndex
    ) -> [TimelineRowModel] {
        if isGroup {
            guard let groupID = model.selectedGroupPlanID else { return [] }
            return rows(
                from: PlanHierarchy.children(of: groupID, in: storedPlans),
                includesCalendar: false,
                visibleSpan: span,
                index: index
            )
        }
        return rows(
            from: rootTimelinePlans,
            includesCalendar: true,
            visibleSpan: span,
            index: index
        )
    }

    private var rootTimelinePlans: [PlanRecord] {
        guard !TaptionProductScope.automaticLoggingOnly else { return [] }
        let repeatGoalIDs = Set(
            storedPlans
                .filter {
                    $0.parentID == nil
                        && ($0.repeatRules?.isEmpty == false)
                }
                .map(\.id)
        )
        .union(
            storedPlans
                .filter { $0.origin == .repeatRule }
                .compactMap(\.parentID)
        )
        return storedPlans.filter { plan in
            if plan.origin == .repeatRule {
                return true
            }
            if let _ = plan.parentID {
                return false
            }
            return !repeatGoalIDs.contains(plan.id)
        }
    }

    private func rows(
        from plans: [PlanRecord],
        includesCalendar: Bool,
        visibleSpan span: TimeSpan,
        index: TimelineBoardDataIndex
    ) -> [TimelineRowModel] {
        let visiblePlans = plans
            .filter { $0.span.intersection(with: span) != nil }
            .sorted { $0.span.start < $1.span.start }
        let grouped = Dictionary(grouping: visiblePlans, by: \.categoryID)
        let now = Date.now
        let relevantTravel = TravelSegmentPresentationEngine.consolidated(
            model.snapshot.travel.filter {
                $0.span.intersection(with: span) != nil
            }
        )
        let visibleActuals = AutomaticRecordTimelineEngine.visibleThroughNow(
            model.snapshot.actuals,
            intersecting: span,
            asOf: now
        )
            .sorted { $0.startedAt < $1.startedAt }
        let phaseActuals = DayPhaseEvidenceEngine.records(
            from: model.snapshot.actuals,
            intersecting: span,
            asOf: now
        )
        let displayedVisibleActuals = RestSleepDisplayEngine.visibleActuals(
            MovementDisplayEngine.reviewActuals(
                visibleActuals,
                travel: relevantTravel,
                calendarEvents: model.snapshot.calendarEvents,
                asOf: now
            ),
            asOf: now
        )
        // 일·주·월이 모두 같은 줄 목록을 쓴다. 예전에는 하루만 이 경로를
        // 지나서 나머지 배율이 기록의 categoryID를 그대로 이름으로 찍었고
        // (appUsage), 줄 순서도 시간표와 어긋났다.
        let usesAutomaticDayRows = includesCalendar
        let unconfirmedActuals = model.selectedScale == .day
            ? ReviewCoverageEngine.unconfirmedRecords(
                actuals: displayedVisibleActuals,
                in: [span],
                asOf: now
            )
            : []
        var automaticActuals = AutomaticRecordTimelineEngine.activities(
            from: displayedVisibleActuals,
            inside: span
        )
        if model.selectedScale == .day {
            automaticActuals += unconfirmedActuals
        }
        let categoryVisibleActuals: [ActualRecord]
        if usesAutomaticDayRows && TaptionProductScope.automaticLoggingOnly {
            categoryVisibleActuals = []
        } else if usesAutomaticDayRows {
            categoryVisibleActuals = displayedVisibleActuals.filter {
                $0.source != .healthKit && $0.source != .appleWatch
            } + unconfirmedActuals
        } else {
            categoryVisibleActuals = displayedVisibleActuals + unconfirmedActuals
        }
        let actualsGrouped = Dictionary(
            grouping: categoryVisibleActuals,
            by: \.categoryID
        )
        var values: [TimelineRowModel] = []

        let events = model.snapshot.calendarEvents
            .filter { $0.span.intersection(with: span) != nil }
            .sorted { $0.span.start < $1.span.start }
        if usesAutomaticDayRows {
            values.append(
                contentsOf: automaticDayPhaseRows(
                    events: events,
                    actuals: phaseActuals,
                    activities: automaticActuals,
                    travel: relevantTravel,
                    visibleSpan: span,
                    index: index
                )
            )
            let appUsageActuals = displayedVisibleActuals
                .filter { $0.categoryID == TimelineRowKind.appUsage.rawValue }
            if !appUsageActuals.isEmpty {
                values.append(
                    automaticAppUsageRow(
                        actuals: appUsageActuals
                    )
                )
            }
            values.append(
                automaticLocationRow(
                    plans: grouped[
                        TimelineRowKind.location.rawValue,
                        default: []
                    ],
                    visibleSpan: span,
                    index: index
                )
            )
            values.append(automaticWeatherRow(visibleSpan: span))
        }

        let orderedCategories = model.snapshot.categories.sorted {
            $0.sortOrder < $1.sortOrder
        }
        for definition in orderedCategories {
            if usesAutomaticDayRows,
               GoalCategoryPolicy.systemSelectableCategoryIDs.contains(
                   definition.id
               ) {
                continue
            }
            let categoryPlans = grouped[definition.id, default: []]
            let categoryActuals = actualsGrouped[definition.id, default: []]
            if definition.isHidden,
               !GoalCategoryPolicy.systemSelectableCategoryIDs.contains(
                   definition.id
               ) {
                continue
            }
            guard !categoryPlans.isEmpty
                || !categoryActuals.isEmpty else {
                continue
            }
            let category = PlanCategory(categoryID: definition.id)
            let plansByPath = Dictionary(
                grouping: categoryPlans,
                by: PlanCategoryPathPresentation.key
            )
            let rootKey = PlanCategoryPathKey(
                categoryID: definition.id,
                middleName: nil,
                subName: nil
            )
            let rowKeys = Array(
                Set(plansByPath.keys)
                    .union(categoryActuals.isEmpty ? [] : [rootKey])
            )
            .sorted {
                PlanCategoryPathPresentation.isOrderedBefore(
                    $0,
                    $1,
                    categoryName: definition.name,
                    plansBeforeRoot: isGroup
                )
            }

            for key in rowKeys {
                let rowPlans = plansByPath[key, default: []]
                let rowActuals = key.isRoot ? categoryActuals : []
                let planAllocation = laneAllocation(
                    rowPlans,
                    span: \.span
                )
                let actualAllocation = laneAllocation(
                    rowActuals,
                    span: { $0.span() }
                )
                let planBlocks = rowPlans.map { plan in
                    timelineBlock(
                        plan: plan,
                        index: index,
                        top: 7 + CGFloat(
                            planAllocation.lanes[plan.id, default: 0]
                        ) * 28,
                        height: 22
                    )
                }
                let actualBlocks = rowActuals.map { actual in
                    timelineBlock(
                        actual: actual,
                        index: index,
                        top: 7
                            + CGFloat(planAllocation.count) * 28
                            + CGFloat(
                                actualAllocation.lanes[actual.id, default: 0]
                            ) * 16,
                        height: 12
                    )
                }
                let sensorBlocks = key.isRoot
                    ? sensorTimelineBlocks(
                        categoryID: definition.id,
                        top: 7
                            + CGFloat(planAllocation.count) * 28
                            + CGFloat(actualAllocation.count) * 16,
                        visibleSpan: span
                    )
                    : []
                let sensorLaneCount = sensorBlocks.isEmpty ? 0 : 1
                values.append(
                    TimelineRowModel(
                        title: PlanCategoryPathPresentation.title(
                            categoryName: definition.name,
                            key: key
                        ),
                        id: key.stableID,
                        category: category,
                        categoryID: definition.id,
                        dotColor: Color(hex: definition.darkHex),
                        systemImage: TimelineRowKind(categoryID: definition.id)?
                            .systemImage ?? definition.icon.systemImage,
                        fillColor: Color(hex: definition.lightHex),
                        actualColor: Color(hex: definition.actualHex),
                        height: max(
                            key.isRoot ? 52 : 64,
                            14
                                + CGFloat(planAllocation.count) * 28
                                + CGFloat(actualAllocation.count) * 16
                                + CGFloat(sensorLaneCount) * 22
                        ),
                        blocks: planBlocks + actualBlocks + sensorBlocks
                    )
                )
            }
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
                    // 사용자 카테고리에 없는 줄도 한글 이름으로 그린다.
                    title: TimelineRowKind.title(forCategoryID: categoryID)
                        ?? categoryID,
                    category: PlanCategory(categoryID: categoryID),
                    categoryID: categoryID,
                    systemImage: TimelineRowKind(categoryID: categoryID)?
                        .systemImage,
                    height: max(
                        60,
                        14
                            + CGFloat(planAllocation.count) * 28
                            + CGFloat(actualAllocation.count) * 16
                    ),
                    blocks: categoryPlans.map { plan in
                        timelineBlock(
                            plan: plan,
                            index: index,
                            top: 7 + CGFloat(
                                planAllocation.lanes[plan.id, default: 0]
                            ) * 28,
                            height: 22
                        )
                    } + categoryActuals.map { actual in
                        timelineBlock(
                            actual: actual,
                            index: index,
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

    private func automaticDayPhaseRows(
        events: [CalendarRecord],
        actuals: [ActualRecord],
        activities: [ActualRecord],
        travel: [TravelSegment],
        visibleSpan: TimeSpan,
        index: TimelineBoardDataIndex
    ) -> [TimelineRowModel] {
        let placeKinds = FrequentPlaceResolutionEngine().kindsByPlaceKey(
            model.snapshot.settings.frequentPlaces
        )
        let phases = DayPhaseEngine.completePhasesAcrossDays(
            actuals: actuals,
            travel: travel,
            stays: model.snapshot.places,
            placeKinds: placeKinds,
            in: visibleSpan,
            calendar: TimelineAxisGrid.normalizedCalendar()
        )
        var values = phaseActivityValues(
            actuals: activities,
            travel: travel,
            phases: phases,
            visibleSpan: visibleSpan,
            index: index
        )
        values += events.compactMap { event in
            event.span.intersection(with: visibleSpan).map { span in
                phaseActivity(
                    seed: "calendar.\(event.id)",
                    phase: .appointment,
                    title: event.title,
                    span: span,
                    categoryID: "calendar",
                    categoryName: "일정",
                    detailText: calendarDetailText(event),
                    color: dayPhaseColor(.appointment),
                    recordNodeID: "automatic.calendar.\(event.id)"
                )
            }
        }
        values += inferredPhaseActivities(phases, coveredBy: values)

        // 왼쪽 행은 화면의 기준축이므로 기록이 없어도 같은 자리를 유지한다.
        return DayPhase.timelineRows.map { phase in
            let activities = values
                .filter { $0.phase == phase }
                .sorted { $0.span.start < $1.span.start }
            let allocation = laneAllocation(activities, span: \.span)
            return TimelineRowModel(
                title: phase.title,
                id: "dayPhase.\(phase.rawValue)",
                dotColor: dayPhaseColor(phase),
                systemImage: dayPhaseSystemImage(phase),
                fillColor: dayPhaseColor(phase).opacity(0.18),
                actualColor: dayPhaseColor(phase),
                isSystemAutomatic: true,
                height: compactAutomaticHeight(allocation.count),
                blocks: activities.map { activity in
                    timelineBlock(
                        id: activity.id,
                        title: activity.title,
                        span: activity.span,
                        top: compactAutomaticTop(
                            allocation.lanes[activity.id, default: 0]
                        ),
                        height: 14,
                        isFixed: true,
                        status: activity.isMeasured ? .completed : .planned,
                        isActual: activity.isMeasured,
                        opensLocationTimeline: activity.isRoute,
                        minimumWidth: 4,
                        detailText: activity.detailText,
                        categoryID: activity.categoryID,
                        categoryName: activity.categoryName,
                        appUsageTokenData: activity.appUsageTokenData,
                        actualID: activity.actualID,
                        travelID: activity.travelID,
                        recordNodeID: activity.recordNodeID,
                        fillColor: activity.color.opacity(0.20),
                        actualColor: activity.color,
                        styleKey: activity.styleKey,
                        minimumFraction: 0.000_001
                    )
                }
            )
        }
    }

    private func phaseActivityValues(
        actuals: [ActualRecord],
        travel: [TravelSegment],
        phases: [DayPhaseSpan],
        visibleSpan: TimeSpan,
        index: TimelineBoardDataIndex
    ) -> [TimelinePhaseActivity] {
        let now = Date.now
        let observed = TimeSpan(
            start: visibleSpan.start,
            end: min(visibleSpan.end, now)
        )
        guard observed.duration > 0 else { return [] }
        var values: [TimelinePhaseActivity] = []

        let sleepRing = RecordClockDetailEngine.activitySleepRing(
            sessions: model.sleepSessions,
            in: observed
        )
        let sleepSpans: [TimeSpan] = sleepRing?.arcs.compactMap { arc in
            let span = TimeSpan(
                start: observed.start.addingTimeInterval(
                    observed.duration * arc.startFraction
                ),
                end: observed.start.addingTimeInterval(
                    observed.duration * arc.endFraction
                )
            )
            guard let stage = SleepStage(rawValue: arc.token) else {
                return nil
            }
            values += assignedPhaseActivities(
                seed: "sleep.\(arc.id)",
                title: stage.displayName,
                span: span,
                phases: phases,
                categoryID: "sleep",
                categoryName: "수면",
                detailText: "Apple 건강 · 수정 불가",
                color: RecordTimelinePalette.detailColor(
                    .sleepStage,
                    token: arc.token
                ),
                isMeasured: true,
                styleKey: "sleep.\(arc.token)"
            )
            return span
        } ?? []

        var travelSpans: [TimeSpan] = []
        var workoutTravelSpans: [TimeSpan] = []
        for segment in travel.sorted(by: { $0.span.start < $1.span.start }) {
            guard let span = segment.span.intersection(with: observed) else {
                continue
            }
            let isWorkout = TravelSegmentPresentationEngine
                .isWorkoutTravel(segment, actuals: actuals, asOf: now)
            if isWorkout {
                workoutTravelSpans.append(span)
            } else {
                travelSpans.append(span)
            }
            values += assignedPhaseActivities(
                seed: "travel.\(segment.id.uuidString)",
                title: travelModeName(segment.mode),
                span: span,
                phases: phases,
                categoryID: isWorkout ? "exercise" : "movement",
                categoryName: isWorkout ? "운동" : "이동",
                detailText: isWorkout
                    ? "운동 기록 · 수정 불가"
                    : "센서 추정 · \(confidenceName(segment.confidence))",
                color: isWorkout
                    ? RecordTimelinePalette.categoryColor("exercise")
                    : RecordTimelinePalette.detailColor(
                        .travel,
                        token: segment.mode.rawValue
                    ),
                isMeasured: true,
                travelID: segment.id,
                recordNodeID: "automatic.travel.\(segment.id.uuidString)",
                isRoute: true,
                styleKey: isWorkout
                    ? "exercise.\(segment.mode.rawValue).workout"
                    : "travel.\(segment.mode.rawValue)"
            )
        }

        var seen = Set<UUID>()
        for actual in actuals where seen.insert(actual.id).inserted {
            guard let span = actual.span(asOf: now).intersection(with: observed)
            else { continue }
            let categoryID = ActualRecordCategoryResolver.categoryID(for: actual)
            let covered: [TimeSpan] = if categoryID == "sleep" {
                sleepSpans
            } else if categoryID == "movement" {
                travelSpans
            } else if categoryID == "exercise",
                      AutomaticRecordTimelineEngine.isConfirmedWorkout(actual) {
                workoutTravelSpans
            } else {
                []
            }
            let color = activityColor(categoryID)
            for remainder in ActualIntervalMergeEngine.subtracting(
                covered,
                from: span
            ) {
                values += assignedPhaseActivities(
                    seed: "actual.\(actual.id.uuidString)",
                    title: activityTitle(actual, categoryID: categoryID),
                    span: remainder,
                    phases: phases,
                    categoryID: categoryID,
                    categoryName: index.categoryNames[categoryID]
                        ?? TimelineRowKind.title(forCategoryID: categoryID)
                        ?? actual.title,
                    detailText:
                        "자동 활동 · \(actualSourceName(actual.source))",
                    color: color,
                    isMeasured: true,
                    actualID: actual.id,
                    isRoute: categoryID == "movement",
                    appUsageTokenData: model.appUsageTokenIndex[actual.id],
                    styleKey: "actual.\(categoryID).\(actual.title)"
                )
            }
        }
        return values
    }

    private func assignedPhaseActivities(
        seed: String,
        title: String,
        span: TimeSpan,
        phases: [DayPhaseSpan],
        categoryID: String,
        categoryName: String,
        detailText: String,
        color: Color,
        isMeasured: Bool,
        actualID: UUID? = nil,
        travelID: UUID? = nil,
        recordNodeID: String? = nil,
        isRoute: Bool = false,
        appUsageTokenData: Data? = nil,
        styleKey: String
    ) -> [TimelinePhaseActivity] {
        let activityPhase = DayPhase.phase(forActivityCategory: categoryID)
        return DayPhaseEngine.assignments(of: span, to: phases)
            .filter { $0.phase == activityPhase }
            .map { assignment in
            phaseActivity(
                seed: seed,
                phase: assignment.phase,
                title: title,
                span: assignment.span,
                categoryID: categoryID,
                categoryName: categoryName,
                detailText: detailText,
                color: color,
                isMeasured: isMeasured,
                actualID: actualID,
                travelID: travelID,
                recordNodeID: recordNodeID,
                isRoute: isRoute,
                appUsageTokenData: appUsageTokenData,
                styleKey: styleKey
            )
        }
    }

    private func inferredPhaseActivities(
        _ phases: [DayPhaseSpan],
        coveredBy values: [TimelinePhaseActivity]
    ) -> [TimelinePhaseActivity] {
        let byPhase = Dictionary(grouping: values, by: \.phase)
        return phases.flatMap { value -> [TimelinePhaseActivity] in
            let covered = byPhase[value.phase, default: []]
                .compactMap { $0.span.intersection(with: value.span) }
            let fallback = fallbackActivity(for: value.phase)
            return ActualIntervalMergeEngine.subtracting(
                covered,
                from: value.span
            ).map { span in
                phaseActivity(
                    seed: "inferred.\(value.phase.rawValue)",
                    phase: value.phase,
                    title: fallback.title,
                    span: span,
                    categoryID: fallback.categoryID,
                    categoryName: fallback.title,
                    detailText: "일과에서 추정",
                    color: activityColor(fallback.categoryID),
                    styleKey: "inferred.\(fallback.categoryID)"
                )
            }
        }
    }

    private func phaseActivity(
        seed: String,
        phase: DayPhase,
        title: String,
        span: TimeSpan,
        categoryID: String,
        categoryName: String,
        detailText: String,
        color: Color,
        isMeasured: Bool = false,
        actualID: UUID? = nil,
        travelID: UUID? = nil,
        recordNodeID: String? = nil,
        isRoute: Bool = false,
        appUsageTokenData: Data? = nil,
        styleKey: String? = nil
    ) -> TimelinePhaseActivity {
        TimelinePhaseActivity(
            id: stablePhaseActivityID(seed, phase: phase, span: span),
            phase: phase,
            title: title,
            span: span,
            categoryID: categoryID,
            categoryName: categoryName,
            detailText: detailText,
            color: color,
            isMeasured: isMeasured,
            actualID: actualID,
            travelID: travelID,
            recordNodeID: recordNodeID,
            isRoute: isRoute,
            appUsageTokenData: appUsageTokenData,
            styleKey: styleKey ?? "\(categoryID).\(title)"
        )
    }

    private func dayPhaseSystemImage(_ phase: DayPhase) -> String {
        switch phase {
        case .sleep: "bed.double.fill"
        case .movement: "arrow.left.arrow.right"
        case .exercise: "figure.run"
        case .hobby: "paintpalette.fill"
        case .activity: "figure.stand"
        case .appointment: "calendar"
        case .work: "briefcase.fill"
        case .study: "book.fill"
        case .evening: "fork.knife"
        case .unconfirmed: "questionmark.circle"
        case .commuteToWork, .commuteToSchool, .commuteToAcademy,
             .activityDeparture, .commuteHomeFromWork,
             .commuteHomeFromSchool, .commuteHomeFromAcademy,
             .activityReturn: "arrow.left.arrow.right"
        }
    }

    private func dayPhaseColor(_ phase: DayPhase) -> Color {
        RecordTimelinePalette.detailColor(
            .dayPhase,
            token: phase.rawValue
        )
    }

    private func activityColor(_ categoryID: String) -> Color {
        let fallback = model.snapshot.categories.first {
            $0.id == categoryID
        }?.actualHex
        return RecordTimelinePalette.categoryColor(
            categoryID,
            fallbackHex: fallback
        )
    }

    private func activityTitle(
        _ actual: ActualRecord,
        categoryID: String
    ) -> String {
        if categoryID == "movement",
           let mode = MovementPresentation.mode(for: actual) {
            return travelModeName(mode)
        }
        return actual.title
    }

    private func fallbackActivity(
        for phase: DayPhase
    ) -> (title: String, categoryID: String) {
        switch phase {
        case .sleep: ("수면", "sleep")
        case .movement: ("이동", "movement")
        case .exercise: ("운동", "exercise")
        case .hobby: ("취미", "hobby")
        case .activity: ("활동", "activity")
        case .appointment: ("일정", "calendar")
        case .work: ("업무", "work")
        case .study: ("학업", "study")
        case .evening: ("생활", "activity")
        case .unconfirmed: ("미확인", "unconfirmed")
        case .commuteToWork, .commuteToSchool, .commuteToAcademy,
             .activityDeparture, .commuteHomeFromWork,
             .commuteHomeFromSchool, .commuteHomeFromAcademy,
             .activityReturn: ("이동", "movement")
        }
    }

    private func stablePhaseActivityID(
        _ seed: String,
        phase: DayPhase,
        span: TimeSpan
    ) -> UUID {
        let value = [
            seed,
            phase.rawValue,
            String(Int(span.start.timeIntervalSinceReferenceDate.rounded())),
            String(Int(span.end.timeIntervalSinceReferenceDate.rounded())),
        ].joined(separator: "|")
        var bytes = Array(repeating: UInt8(0), count: 16)
        var hash = UInt64(14_695_981_039_346_656_037)
        for (index, byte) in value.utf8.enumerated() {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
            bytes[index % 16] ^= UInt8(truncatingIfNeeded: hash >> 24)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// 메모 줄. 다른 줄과 달리 손으로 남긴 기록이라 자동 줄의 회색 바탕을
    /// 쓰지 않고, 줄을 누르면 하단 상세 내용만 갱신한다.
    ///
    /// 메모는 순간이라 길이가 없다. 순간마다 눈에 걸리는 최소 길이의 표식을
    /// 만들고, 배율이 넓어져 서로 구분되지 않는 표식은 `MemoTimelineEngine`
    /// 이 미리 하나로 합쳐 준다. 합쳐도 남는 자투리 너비는 막대 쪽의
    /// `minimumWidth`·`TimelineRowBarMerging` 이 다시 받아 준다.
    private func memoRow(visibleSpan: TimeSpan) -> TimelineRowModel {
        let markers = MemoTimelineEngine.markers(
            from: model.timelineMemos(in: visibleSpan),
            in: visibleSpan,
            visibleDuration: visibleSpan.duration
        )
        return TimelineRowModel(
            title: TimelineRowKind.memo.title,
            id: TimelineRowKind.memo.rawValue,
            categoryID: TimelineRowKind.memo.rawValue,
            dotColor: .tpStudyDark,
            systemImage: TimelineRowKind.memo.systemImage,
            fillColor: .tpStudy,
            actualColor: .tpStudyDark,
            height: compactAutomaticHeight(1),
            blocks: markers.map { marker in
                timelineBlock(
                    id: marker.id,
                    title: marker.title,
                    span: marker.span,
                    top: compactAutomaticTop(0),
                    height: 16,
                    isFixed: true,
                    groupCount: marker.count > 1 ? marker.count : nil,
                    isActual: true,
                    minimumWidth: memoMarkerMinimumWidth,
                    detailText: marker.span.start.formatted(
                        date: .omitted,
                        time: .shortened
                    ),
                    categoryID: TimelineRowKind.memo.rawValue,
                    categoryName: TimelineRowKind.memo.title
                )
            }
        )
    }

    /// 순간을 그린 표식이 손가락보다 좁아지지 않게 하는 하한.
    private var memoMarkerMinimumWidth: CGFloat { 22 }

    private func automaticAppUsageRow(
        actuals: [ActualRecord]
    ) -> TimelineRowModel {
        let values = actuals.filter { $0.startedAt <= .now }
        let allocation = laneAllocation(values, span: { $0.span() })
        let blocks = values.map { actual in
            timelineBlock(
                id: actual.id,
                title: actual.title,
                span: actual.span(),
                top: compactAutomaticTop(
                    allocation.lanes[actual.id, default: 0]
                ),
                height: 14,
                isFixed: true,
                status: .completed,
                isActual: true,
                detailText: appUsageDetailText(actual),
                categoryID: "appUsage",
                categoryName: ScreenTimeUsageRecordEngine.laneTitle,
                appUsageTokenData: model.appUsageTokenIndex[actual.id]
            )
        }
        return TimelineRowModel(
            title: TimelineRowKind.appUsage.title,
            id: TimelineRowKind.appUsage.rawValue,
            dotColor: .tpProjectDark,
            systemImage: TimelineRowKind.appUsage.systemImage,
            fillColor: .tpProject,
            actualColor: .tpProjectDark,
            isSystemAutomatic: true,
            height: compactAutomaticHeight(allocation.count),
            blocks: blocks
        )
    }

    private func appUsageDetailText(_ actual: ActualRecord) -> String {
        guard let duration = ScreenTimeUsageRecordEngine
            .durationText(actual.span().duration) else {
            return actualSourceName(actual.source)
        }
        return "\(duration) · \(actualSourceName(actual.source))"
    }

    private func automaticWeatherRow(
        visibleSpan: TimeSpan
    ) -> TimelineRowModel {
        let now = Date.now
        let contexts = WeatherTimelineEngine.coalesced(model.snapshot.weather)
            .filter {
                $0.observedAt <= now
                    && weatherTimelineSpan($0)
                        .intersection(with: visibleSpan) != nil
            }
            .sorted { $0.observedAt < $1.observedAt }
        let allocation = laneAllocation(contexts) { context in
            automaticSpanThroughNow(
                weatherTimelineSpan(context),
                asOf: now
            ) ?? weatherTimelineSpan(context)
        }
        let blocks = contexts.map { context in
            let span = automaticSpanThroughNow(
                weatherTimelineSpan(context),
                asOf: now
            ) ?? weatherTimelineSpan(context)
            return timelineBlock(
                id: context.id,
                title: weatherTimelineTitle(context),
                span: span,
                top: compactAutomaticTop(
                    allocation.lanes[context.id, default: 0]
                ),
                height: 14,
                isFixed: true,
                status: .completed,
                isActual: true,
                detailText: weatherTimelineDetail(context),
                categoryID: "weather",
                categoryName: "날씨"
            )
        }
        return TimelineRowModel(
            title: TimelineRowKind.weather.title,
            id: TimelineRowKind.weather.rawValue,
            dotColor: .tpWeatherDark,
            systemImage: contexts.first?.symbolName
                ?? TimelineRowKind.weather.systemImage,
            fillColor: .tpWeather,
            actualColor: .tpWeatherDark,
            isSystemAutomatic: true,
            height: compactAutomaticHeight(allocation.count),
            blocks: blocks
        )
    }

    private func automaticLocationRow(
        plans: [PlanRecord],
        visibleSpan: TimeSpan,
        index: TimelineBoardDataIndex
    ) -> TimelineRowModel {
        let now = Date.now
        let visiblePlans = plans.filter { $0.span.start <= now }
        let visiblePlaces = PlaceStayPresentationEngine.consolidated(
            model.snapshot.places.compactMap { place -> PlaceStay? in
                guard place.span.start <= now,
                      place.span.start < visibleSpan.end,
                      place.span.end > visibleSpan.start,
                      let clipped = place.span.intersection(
                          with: TimeSpan(start: .distantPast, end: now)
                      ) else { return nil }
                var value = place
                value.span = clipped
                return value
            }
            .filter { $0.span.intersection(with: visibleSpan) != nil }
        )
        let planAllocation = laneAllocation(visiblePlans, span: \.span)
        let placeAllocation = laneAllocation(visiblePlaces, span: \.span)
        let offset = planAllocation.count
        let planBlocks = visiblePlans.map { plan in
            timelineBlock(
                plan: plan,
                index: index,
                top: compactAutomaticTop(
                    planAllocation.lanes[plan.id, default: 0]
                ),
                height: 14
            )
        }
        let placeBlocks = visiblePlaces.map { place in
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
                top: compactAutomaticTop(
                    offset
                        + placeAllocation.lanes[place.id, default: 0]
                ),
                height: 14,
                isFixed: true,
                status: .completed,
                isActual: true,
                opensLocationTimeline: true,
                detailText: [
                    "자동 위치",
                    confidenceName(place.confidence),
                    altitude,
                ]
                .compactMap { $0 }
                .joined(separator: " · "),
                categoryID: "location",
                categoryName: "위치"
            )
        }
        return TimelineRowModel(
            title: TimelineRowKind.location.title,
            id: TimelineRowKind.location.rawValue,
            category: .location,
            categoryID: TimelineRowKind.location.rawValue,
            systemImage: TimelineRowKind.location.systemImage,
            isSystemAutomatic: true,
            height: compactAutomaticHeight(
                planAllocation.count + placeAllocation.count
            ),
            blocks: planBlocks + placeBlocks
        )
    }

    private func compactAutomaticHeight(_ laneCount: Int) -> CGFloat {
        10 + CGFloat(max(1, laneCount)) * 18
    }

    private func compactAutomaticTop(_ lane: Int) -> CGFloat {
        5 + CGFloat(lane) * 18
    }

    private func calendarDetailText(_ event: CalendarRecord) -> String {
        [
            calendarEventDateTimeLabel(for: event),
            event.sourceTitle,
            event.calendarTitle,
            "고정 일정",
        ]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")
    }

    private func calendarEventDateTimeLabel(for event: CalendarRecord) -> String {
        let date = calendarDateLabel(event.span.start)
        if event.isAllDay {
            return "\(date) · 종일"
        }
        let start = event.span.start.formatted(date: .omitted, time: .shortened)
        let end = event.span.end.formatted(date: .omitted, time: .shortened)
        return "\(date) · \(start)–\(end)"
    }

    private func calendarDateLabel(_ date: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        let weekdaySymbols = ["일", "월", "화", "수", "목", "금", "토"]
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        let weekdayIndex = max(
            0,
            min(
                weekdaySymbols.count - 1,
                calendar.component(.weekday, from: date) - 1
            )
        )
        return "\(month)월 \(day)일 (\(weekdaySymbols[weekdayIndex]))"
    }

    private func timelineBlock(
        plan: PlanRecord,
        index: TimelineBoardDataIndex,
        top: CGFloat = 16,
        height: CGFloat = 26
    ) -> TimelineBlock {
        let childCount = index.childCounts[plan.id, default: 0]
        let categoryName = index.categoryNames[plan.categoryID]
            ?? plan.categoryID
        let categoryDetail = PlanCategoryPathPresentation.detail(
            categoryName: categoryName,
            key: PlanCategoryPathPresentation.key(for: plan)
        )
        let isGoalPlan = isGoalPlan(plan)
        let displayTitle = isGoalPlan
            ? goalDisplayTitle(plan.title)
            : plan.title
        return timelineBlock(
            id: plan.id,
            planID: plan.id,
            title: displayTitle,
            span: plan.span,
            top: top,
            height: height,
            isFixed: plan.isFixed
                || plan.origin == .repeatRule
                || plan.origin == .health
                || plan.origin == .location
                || plan.origin == .motion,
            groupCount: childCount > 0 ? childCount : nil,
            status: plan.status,
            detailText: isGoalPlan
                ? "루틴 · \(categoryDetail)"
                : ["계획", categoryDetail]
                .joined(separator: " · "),
            isGoal: isGoalPlan,
            categoryID: plan.categoryID,
            categoryName: categoryDetail
        )
    }

    private func isGoalPlan(_ plan: PlanRecord) -> Bool {
        // Only an explicit goal or a generated repeat segment gets goal
        // styling. A regular plan having child items is still a plan; the
        // mere existence of descendants must not invent a goal in details.
        if plan.origin == .repeatRule {
            return true
        }
        return GoalRecordPolicy.isGoal(plan)
    }

    private func goalDisplayTitle(_ title: String) -> String {
        GoalRecordPolicy.displayTitle(title)
    }

    private func timelineBlock(
        actual: ActualRecord,
        index: TimelineBoardDataIndex,
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
                "\(TaptionActivityEngineAdapter.trustLabel(for: actual)) · \(actualSourceName(actual.source)) · \(confidenceName(actual.confidence))",
            categoryID: actual.categoryID,
            categoryName: index.categoryNames[actual.categoryID]
        )
    }

    private func sensorTimelineBlocks(
        categoryID: String,
        top: CGFloat,
        visibleSpan: TimeSpan
    ) -> [TimelineBlock] {
        let now = Date.now
        switch categoryID {
        case "movement":
            let visibleTravel: [TravelSegment] = model.snapshot.travel.compactMap {
                travel in
                guard let clipped = automaticSpanThroughNow(
                    travel.span,
                    asOf: now
                ), clipped.intersection(with: visibleSpan) != nil else {
                    return nil
                }
                var value = travel
                value.span = clipped
                return value
            }
            return visibleTravel
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
                            "센서 추정 · \(confidenceName(travel.confidence))",
                        categoryID: "movement",
                        categoryName: "이동",
                        travelID: travel.id,
                        recordNodeID: "automatic.travel.\(travel.id.uuidString)"
                    )
                }
        case "location":
            let visiblePlaces = PlaceStayPresentationEngine.consolidated(
                model.snapshot.places.compactMap { place in
                    guard let clipped = automaticSpanThroughNow(
                        place.span,
                        asOf: now
                    ), clipped.intersection(with: visibleSpan) != nil else {
                        return nil
                    }
                    var value = place
                    value.span = clipped
                    return value
                }
            )
            return visiblePlaces
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
                            .joined(separator: " · "),
                        categoryID: "location",
                        categoryName: "위치"
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
        case .car: "자동차"
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
        case .appleWatch: "Apple Watch 센서"
        case .motion: "iPhone Core Motion"
        case .calendar: "캘린더"
        case .location: "위치"
        case .photo: "사진"
        case .media: "미디어 재생"
        case .call: "통화"
        case .appUsage: "앱 사용시간"
        }
    }

    private func laneAllocation<Item: Identifiable>(
        _ items: [Item],
        span: (Item) -> TimeSpan
    ) -> (lanes: [Item.ID: Int], count: Int)
    where Item.ID: Hashable {
        let allocation = TimelineLaneAllocator.allocate(items, span: span)
        return (allocation.lanes, allocation.count)
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
        minimumWidth: CGFloat = 18,
        detailText: String? = nil,
        isGoal: Bool = false,
        categoryID: String? = nil,
        categoryName: String? = nil,
        appUsageTokenData: Data? = nil,
        actualID: UUID? = nil,
        travelID: UUID? = nil,
        recordNodeID: String? = nil,
        fillColor: Color? = nil,
        actualColor: Color? = nil,
        styleKey: String? = nil,
        minimumFraction: CGFloat = 0.012
    ) -> TimelineBlock {
        let overlap = span.intersection(with: layoutDataSpan) ?? span
        let start = CGFloat(
            timelineFraction(of: overlap.start, in: layoutDataSpan)
        )
        let end = CGFloat(
            timelineFraction(of: overlap.end, in: layoutDataSpan)
        )
        let length = max(0, end - start)
        return TimelineBlock(
            id: id,
            planID: planID,
            title: title,
            start: max(0, min(1, start)),
            length: max(minimumFraction, min(1, length)),
            top: top,
            height: height,
            isFixed: isFixed,
            groupCount: groupCount,
            actualFraction: actualFraction,
            status: status,
            isActual: isActual,
            opensLocationTimeline: opensLocationTimeline,
            minimumWidth: minimumWidth,
            startsAt: span.start,
            endsAt: span.end,
            detailText: detailText,
            categoryID: categoryID,
            categoryName: categoryName,
            isGoal: isGoal,
            appUsageTokenData: appUsageTokenData,
            actualID: actualID,
            travelID: travelID,
            recordNodeID: recordNodeID,
            fillColor: fillColor,
            actualColor: actualColor,
            styleKey: styleKey
        )
    }

    private var isContinuousDay: Bool {
        scale == .day
    }

    /// Every schedule resolution now uses the same continuous NLE playhead
    /// model. Day keeps its selected zoom duration; week and month retain the
    /// calendar period's initial width while the center moves through adjacent
    /// periods.
    private var isContinuousTimeline: Bool {
        switch scale {
        case .day, .week, .month:
            true
        case .year:
            false
        }
    }

    private func continuousDuration(around date: Date) -> TimeInterval {
        if scale == .day {
            return max(60, dayZoom.duration)
        }
        return max(
            86_400,
            TimelineAxisGrid.span(for: scale, containing: date).duration
        )
    }

    private var activeContinuousDuration: TimeInterval {
        return max(
            60,
            continuousTimelineDuration > 0
                ? continuousTimelineDuration
                : continuousDuration(around: continuousCenterDate)
        )
    }

    private var hasCustomContinuousDuration: Bool {
        let standard = continuousDuration(around: continuousCenterDate)
        return abs(activeContinuousDuration - standard) > 1
    }

    private var layoutDataSpan: TimeSpan {
        dragLayoutSpan ?? visibleSpan
    }

    /// 드래그하는 동안 쓰는 데이터 창.  손가락이 움직이는 도중에는 이 창을
    /// 다시 만들지 않는다.  전체 기록을 한 번 더 계산하는 순간 그 프레임이
    /// 통째로 사라지기 때문이다.  대신 보이는 구간의 다섯 배를 미리 담고,
    /// 최종 위치는 제스처가 끝날 때 정확한 구간으로 다시 그린다.
    ///
    /// 창의 중심은 보이는 구간 길이의 격자에 맞춰 둔다.  손을 뗀 자리마다
    /// 경계가 조금씩 달라지면 같은 곳을 다시 훑어도 캐시가 매번 빗나간다.
    private var dragLayoutWindow: TimeSpan {
        let currentSpan = visibleSpan
        let unit = max(60, currentSpan.duration)
        let center = currentSpan.start.timeIntervalSinceReferenceDate
            + currentSpan.duration / 2
        let snappedCenter = (center / unit).rounded() * unit
        let half = unit * 2.5
        return TimeSpan(
            start: Date(
                timeIntervalSinceReferenceDate: snappedCenter - half
            ),
            end: Date(timeIntervalSinceReferenceDate: snappedCenter + half)
        )
    }

    private func timelineFraction(
        of date: Date,
        in span: TimeSpan
    ) -> Double {
        guard span.duration > 0 else { return 0 }
        return date.timeIntervalSince(span.start) / span.duration
    }

    private func timelineDate(
        at fraction: Double,
        in span: TimeSpan
    ) -> Date {
        span.start.addingTimeInterval(
            span.duration * min(1, max(0, fraction))
        )
    }

    /// 확대·축소는 보이는 구간의 길이 자체가 바뀌므로 드래그처럼 창을 한 번만
    /// 잡아 둘 수 없다.  여유 폭을 두고, 실제로 모자랄 때만 다시 잡는다.
    private func ensureMagnifyLayoutWindow(around center: Date) {
        guard isContinuousTimeline else { return }

        let minimumWindowDuration = max(60, activeContinuousDuration * 3)
        if let current = dragLayoutSpan,
           current.duration >= minimumWindowDuration {
            let margin = current.duration * 0.25
            let safeStart = current.start.addingTimeInterval(margin)
            let safeEnd = current.end.addingTimeInterval(-margin)
            if safeStart <= center, center <= safeEnd {
                return
            }
        }

        let windowDuration = max(
            minimumWindowDuration,
            dragLayoutSpan?.duration ?? 0
        )
        let halfDuration = windowDuration / 2
        let nextWindow = TimeSpan(
            start: center.addingTimeInterval(-halfDuration),
            end: center.addingTimeInterval(halfDuration)
        )
        guard dragLayoutSpan != nextWindow else { return }
        // Keep the data window and its derived rows as one cache entry. If the
        // window advances during a pinch, leaving the snapshot nil makes the
        // next SwiftUI pass rebuild every row on the hot path.
        dragLayoutSnapshot = cachedLayoutSnapshot(in: nextWindow)
        dragLayoutSpan = nextWindow
    }

    private var standardVisibleSpan: TimeSpan {
        TimelineAxisGrid.span(
            for: scale,
            containing: model.selectedDate
        )
    }

    private var visibleSpan: TimeSpan {
        guard isContinuousTimeline else { return standardVisibleSpan }
        return NLETimelineViewport(
            centerDate: continuousCenterDate,
            visibleDuration: activeContinuousDuration
        ).span
    }

    @ViewBuilder
    private func gridLines(markers: [TimelineAxisMarker]) -> some View {
        HStack(spacing: 0) {
            if !usesFullWidthRuler {
                Color.clear.frame(width: scheduleLabelColumnWidth)
            }
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    ForEach(markers) { marker in
                        Rectangle()
                            .fill(ganttTableLineColor)
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

    @ViewBuilder
    private func currentLine() -> some View {
        if isContinuousTimeline {
            GeometryReader { proxy in
                let leadingWidth = usesFullWidthRuler
                    ? 0
                    : scheduleLabelColumnWidth
                let x = leadingWidth
                    + max(1, proxy.size.width - leadingWidth) / 2
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Color.tpNow)
                        .frame(width: 2, height: proxy.size.height)
                        .position(x: x, y: proxy.size.height / 2)
                    Circle()
                        .fill(Color.tpNow)
                        .frame(width: 9, height: 9)
                        .position(x: x, y: 1)
                    Text(
                        continuousCenterDate.formatted(
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
            .zIndex(20)
        } else {
            GeometryReader { proxy in
                let leadingWidth = usesFullWidthRuler
                    ? 0
                    : scheduleLabelColumnWidth
                let timelineWidth = max(
                    1,
                    proxy.size.width - leadingWidth
                )
                let x = leadingWidth + timelineWidth / 2
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Color.tpNow)
                        .frame(width: 2, height: proxy.size.height)
                        .position(x: x, y: proxy.size.height / 2)
                    Circle()
                        .fill(Color.tpNow)
                        .frame(width: 8, height: 8)
                        .position(x: x, y: 1)
                    Text(playheadAxisLabel(continuousCenterDate))
                        .font(.taption(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.tpNow, in: Capsule())
                        .fixedSize()
                        .position(x: x, y: 7)
                }
            }
            .zIndex(20)
        }
    }

    private func photoRow(_ clusters: [PhotoCluster]) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: TaptionSpacing.tight) {
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
                    ForEach(clusters) { cluster in
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
            Rectangle().fill(ganttTableLineColor).frame(height: 0.5)
        }
    }

    private func photoMarker(
        cluster: PhotoCluster,
        x: CGFloat
    ) -> some View {
        Button {
            onPhotoSelection?(cluster)
        } label: {
            VStack(spacing: 2) {
                ZStack(alignment: .topTrailing) {
                    PhotoAssetThumbnail(
                        model: model,
                        localIdentifier: cluster.representative.id
                    )
                        .frame(width: 39, height: 39)
                        .clipShape(RoundedRectangle(cornerRadius: TaptionRadius.field, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: TaptionRadius.field, style: .continuous)
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
        let fraction = timelineFraction(
            of: cluster.capturedAt,
            in: visibleSpan
        )
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

    private func summaryStrip(
        buckets: [SummaryBucket],
        colors: [SummaryColor]
    ) -> some View {
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
                ForEach(colors.indices, id: \.self) { index in
                    Button {
                        zoomIntoSummary(buckets[index])
                    } label: {
                        ZStack {
                            RoundedRectangle(
                                cornerRadius: 5,
                                style: .continuous
                            )
                            .fill(
                                colors[index].color.opacity(
                                    colors[index].opacity
                                )
                            )
                            if buckets[index].photoCount > 0 {
                                HStack(spacing: 1) {
                                    Image(systemName: "photo.fill")
                                    Text(
                                        "\(buckets[index].photoCount)"
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
                            buckets[index]
                        )
                    )
                }
            }
            .padding(.horizontal, 3)
        }
        .frame(height: 46)
        .background(Color(red: 0.98, green: 0.98, blue: 0.985))
        .overlay(alignment: .bottom) {
            Rectangle().fill(ganttTableLineColor).frame(height: 0.5)
        }
    }

    private var summaryTitle: String {
        switch scale {
        case .week, .day: "일 요약"
        case .month: "주·일 요약"
        case .year: "월·주·일 요약"
        }
    }

    private func summaryColors(
        for buckets: [SummaryBucket]
    ) -> [SummaryColor] {
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

    private func nowFraction(at date: Date) -> CGFloat {
        max(
            0,
            min(
                1,
                CGFloat(
                    timelineFraction(of: date, in: visibleSpan)
                )
            )
        )
    }

    private var viewportMinimumLength: Double {
        GanttViewport.oneMinuteMinimumLength(
            for: visibleSpan.duration
        )
    }

    private var viewportVisibleSpan: TimeSpan {
        TimeSpan(
            start: timelineDate(at: viewport.start, in: visibleSpan),
            end: timelineDate(at: viewport.end, in: visibleSpan)
        )
    }

    private func axisMarkers(in visibleSpan: TimeSpan) -> [TimelineAxisMarker] {
        if isContinuousTimeline {
            return continuousAxisMarkers(
                in: viewport.isFull ? visibleSpan : viewportVisibleSpan
            )
        }
        guard !viewport.isFull else {
            return TimelineAxisGrid.buckets(
                for: scale,
                containing: model.selectedDate
            ).map { bucket in
                TimelineAxisMarker(
                    id: "full-\(bucket.id)",
                    date: bucket.date,
                    fraction: Double(bucket.index) / Double(bucket.count),
                    label: bucket.label,
                    isCurrent: isCurrentBucket(bucket),
                    holidayName: bucket.holidayName
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
                    date: date,
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
                    date: date,
                    fraction: 0.5,
                    label: axisTickLabel(date),
                    isCurrent: span.contains(.now)
                )
            ]
        }
        return markers
    }

    private func continuousAxisMarkers(
        in span: TimeSpan
    ) -> [TimelineAxisMarker] {
        let calendar = TimelineAxisGrid.normalizedCalendar()
        let zoomDuration = span.duration
        let component: Calendar.Component
        let componentValue: Int
        let step: TimeInterval
        switch scale {
        case .day:
            component = .minute
            switch zoomDuration {
            case ...Double(5 * 60): componentValue = 1
            case ...Double(15 * 60): componentValue = 5
            case ...Double(60 * 60): componentValue = 10
            case ...Double(6 * 60 * 60): componentValue = 30
            case ...Double(12 * 60 * 60): componentValue = 60
            case ...Double(24 * 60 * 60): componentValue = 120
            case ...Double(3 * 24 * 60 * 60): componentValue = 360
            default: componentValue = 1_440
            }
            step = Double(componentValue * 60)
        case .week:
            component = .day
            componentValue = 1
            step = 86_400
        case .month:
            component = .day
            componentValue = span.duration <= 14 * 86_400 ? 1 : 2
            step = Double(componentValue) * 86_400
        case .year:
            component = .month
            componentValue = 1
            step = 31 * 86_400
        }
        let start = span.start.timeIntervalSinceReferenceDate
        let end = span.end.timeIntervalSinceReferenceDate
        var nextDate: Date
        if scale == .year {
            nextDate = calendar.dateInterval(of: .month, for: span.start)?.start
                ?? span.start
        } else if scale == .day {
            nextDate = calendar.startOfDay(for: span.start)
        } else {
            nextDate = calendar.startOfDay(for: span.start)
        }
        while nextDate < span.start {
            nextDate = calendar.date(
                byAdding: component,
                value: componentValue,
                to: nextDate
            ) ?? nextDate.addingTimeInterval(step)
        }
        var next = nextDate.timeIntervalSinceReferenceDate
        var markers: [TimelineAxisMarker] = []
        while next <= end, markers.count < 64 {
            let date = Date(timeIntervalSinceReferenceDate: next)
            let label: String
            if scale == .day && zoomDuration <= 6 * 60 * 60 {
                label = axisHourMinuteLabel(date, calendar: calendar)
            } else if scale == .day && zoomDuration <= 24 * 60 * 60 {
                let hour = calendar.component(.hour, from: date)
                label = String(format: "%02d", hour)
            } else if scale == .year {
                label = "\(calendar.component(.month, from: date))월"
            } else if scale == .week {
                label = "\(calendar.component(.month, from: date))/\(calendar.component(.day, from: date))"
            } else {
                label = "\(calendar.component(.day, from: date))"
            }
            markers.append(
                TimelineAxisMarker(
                    id: "continuous-\(next)",
                    date: date,
                    fraction: (next - start) / max(1, end - start),
                    label: label,
                    isCurrent: abs(date.timeIntervalSince(continuousCenterDate))
                        < step / 2
                )
            )
            nextDate = calendar.date(
                byAdding: component,
                value: componentValue,
                to: nextDate
            ) ?? nextDate.addingTimeInterval(step)
            next = nextDate.timeIntervalSinceReferenceDate
        }
        return markers
    }

    private func isCurrentBucket(_ bucket: TimelineAxisBucket) -> Bool {
        switch scale {
        case .week:
            return TimelineAxisGrid.normalizedCalendar().isDate(
                bucket.date,
                inSameDayAs: model.selectedDate
            )
        case .month:
            return TimelineAxisGrid.normalizedCalendar().isDate(
                bucket.date,
                equalTo: model.selectedDate,
                toGranularity: .day
            )
        case .year:
            return TimelineAxisGrid.normalizedCalendar().isDate(
                bucket.date,
                equalTo: model.selectedDate,
                toGranularity: .month
            )
        case .day:
            return false
        }
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
            ?? supportedSteps.last
            ?? 60
    }

    private func axisTickLabel(_ date: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        if viewportVisibleSpan.duration <= 60 * 60 {
            return axisHourMinuteLabel(date, calendar: calendar)
        }
        if viewportVisibleSpan.duration <= 2 * 24 * 60 * 60 {
            return String(format: "%02d", calendar.component(.hour, from: date))
        }
        if viewportVisibleSpan.duration <= 90 * 24 * 60 * 60 {
            return "\(calendar.component(.month, from: date)).\(calendar.component(.day, from: date))"
        }
        return "\(calendar.component(.month, from: date))월"
    }

    private func axisHourMinuteLabel(
        _ date: Date,
        calendar: Calendar
    ) -> String {
        String(
            format: "%02d:%02d",
            calendar.component(.hour, from: date),
            calendar.component(.minute, from: date)
        )
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

    private func playheadAxisLabel(_ date: Date) -> String {
        let calendar = TimelineAxisGrid.normalizedCalendar()
        switch scale {
        case .day:
            return date.formatted(date: .omitted, time: .shortened)
        case .week:
            let weekday = date.formatted(
                Date.FormatStyle()
                    .weekday(.short)
                    .locale(Locale(identifier: "ko_KR"))
            )
            return "\(calendar.component(.month, from: date))월 \(calendar.component(.day, from: date))일 \(weekday)"
        case .month:
            return "\(calendar.component(.month, from: date))월 \(calendar.component(.day, from: date))일"
        case .year:
            return "\(calendar.component(.year, from: date))년 \(calendar.component(.month, from: date))월"
        }
    }

    private func photoClusters(in visibleSpan: TimeSpan) -> [PhotoCluster] {
        PhotoClusterer.cluster(
            model.snapshot.photos.filter {
                visibleSpan.contains($0.capturedAt)
            }
        )
    }

    /// 요약 띠는 선택한 날짜의 달력 구간만 본다.  드래그는 재생 머리만
    /// 움직이므로 띠 내용은 그대로다.  움직이는 데이터 창에 딸려 다시
    /// 계산되지 않도록 따로 캐시한다.
    private func summaryBuckets(in visibleSpan: TimeSpan) -> [SummaryBucket] {
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
        let engine = TimelineAggregationEngine()
        let outerSpan = engine.interval(
            for: scale.timelineLevel,
            containing: model.selectedDate
        )
        let key = TimelineSummaryKey(
            timelineRevision: model.timelineRevision,
            childLevel: childLevel,
            spanStart: outerSpan.start.timeIntervalSinceReferenceDate,
            spanEnd: outerSpan.end.timeIntervalSinceReferenceDate
        )
        return summaryCache.value(for: key) {
            engine.buckets(
                of: childLevel,
                inside: outerSpan,
                plans: model.snapshot.plans,
                actuals: model.snapshot.actuals,
                photos: model.snapshot.photos
            )
        }
    }

    private func zoomIntoSummary(_ bucket: SummaryBucket) {
        model.selectedDate = bucket.span.start
        switch scale {
        case .week:
            selectScaleForResolution(.day)
        case .month:
            selectScaleForResolution(.week)
        case .year:
            selectScaleForResolution(.month)
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
                guard abs(value.translation.width)
                        > abs(value.translation.height) else {
                    return
                }
                viewportDragChanged(
                    translationWidth: value.translation.width,
                    width: width
                )
            }
            .onEnded { value in
                viewportDragEnded(
                    translationWidth: value.translation.width,
                    width: width
                )
            }
    }

    private func viewportDragChanged(
        translationWidth: CGFloat,
        width: CGFloat
    ) {
        guard editingPlanID == nil else { return }
        gestureMetrics.begin("pan")
        gestureMetrics.inputSample()
        do {
                if isContinuousTimeline {
                    if continuousDragOrigin == nil {
                        continuousDragOrigin = continuousCenterDate
                        continuousTimelineDuration = visibleSpan.duration
                        editingPlanID = nil
                        lastContinuousRenderUptime = 0
                    }
                    if dragLayoutSpan == nil {
                        let window = dragLayoutWindow
                        dragLayoutSpan = window
                        dragLayoutSnapshot = cachedLayoutSnapshot(in: window)
                    }
                    guard let continuousDragOrigin else { return }
                    let candidate = NLETimelineViewport(
                        centerDate: continuousDragOrigin,
                        visibleDuration: activeContinuousDuration
                    )
                    .panned(
                        by: Double(translationWidth),
                        viewportWidth: Double(max(1, width))
                    )
                    .centerDate
                    let uptime = ProcessInfo.processInfo.systemUptime
                    guard TimelineInteractionFrameGate.shouldRender(
                        lastUptime: &lastContinuousRenderUptime,
                        nowUptime: uptime
                    ) else {
                        return
                    }
                    gestureMetrics.renderedSample()
                    guard continuousCenterDate != candidate else { return }
                    continuousCenterDate = candidate
                } else {
                    if dragOrigin == nil {
                        dragOrigin = viewport
                    }
                    guard let dragOrigin else { return }
                    let candidate = dragOrigin.panning(
                        translation: Double(translationWidth),
                        viewportWidth: Double(width)
                    )
                    let uptime = ProcessInfo.processInfo.systemUptime
                    guard TimelineInteractionFrameGate.shouldRender(
                        lastUptime: &lastViewportRenderUptime,
                        nowUptime: uptime
                    ) else {
                        return
                    }
                    gestureMetrics.renderedSample()
                    guard viewport != candidate else { return }
                    viewport = candidate
                }
        }
    }

    private func viewportDragEnded(
        translationWidth: CGFloat,
        width: CGFloat
    ) {
        do {
                if isContinuousTimeline {
                    var finalDate = continuousCenterDate
                    if let continuousDragOrigin {
                        finalDate = NLETimelineViewport(
                            centerDate: continuousDragOrigin,
                            visibleDuration: activeContinuousDuration
                        )
                        .panned(
                            by: Double(translationWidth),
                            viewportWidth: Double(max(1, width))
                        )
                        .centerDate
                    }
                    // 손을 뗀 자리가 곧 최종 자리다. 기록이 없는 구간에
                    // 멈추면 그 빈 구간을 보여 준다. 예전에는 가장 가까운
                    // 기록으로 끌어당겼는데, 아직 아무것도 없는 앞날을 펼쳐
                    // 계획을 세우려 할 때마다 화면이 되돌아왔다.
                    continuousCenterDate = finalDate
                    // Changing the selected date normally resets the
                    // viewport. A continuous drag is different: it pans the
                    // already zoomed range, so keep that zoom after commit.
                    preserveViewportAfterContinuousDrag = true
                    let preservedViewport = viewport
                    model.selectedDate = finalDate
                    onPlayheadMove?(finalDate)
                    // Restore synchronously as well as in the selected-date
                    // observer. This covers the case where the parent view
                    // re-renders before that observer is delivered.
                    viewport = preservedViewport
                    lastContinuousRenderUptime = 0
                    dragLayoutSpan = nil
                    dragLayoutSnapshot = nil
                } else if let dragOrigin {
                    // Commit the final sample even when the last 240 Hz
                    // callback arrived inside the 60 Hz presentation gate.
                    viewport = dragOrigin.panning(
                        translation: Double(translationWidth),
                        viewportWidth: Double(width)
                    )
                    if dragOrigin.isFull,
                       abs(translationWidth) > width * 0.18 {
                        // At the default full-period view, a horizontal swipe
                        // crosses the period boundary instead of stopping at
                        // the edge. Zoomed views retain the existing free pan.
                        model.shiftSelectedDate(
                            by: translationWidth < 0 ? 1 : -1
                        )
                    }
                }
                dragOrigin = nil
                continuousDragOrigin = nil
                lastViewportRenderUptime = 0
        }
        recordGestureMetrics()
    }

    private var viewportMagnifyGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.001)
            .onChanged { value in
                viewportMagnifyChanged(
                    factor: Double(value.magnification),
                    anchor: Double(value.startAnchor.x)
                )
            }
            .onEnded { value in
                viewportMagnifyEnded(
                    factor: Double(value.magnification),
                    anchor: Double(value.startAnchor.x)
                )
            }
    }

    private func viewportMagnifyChanged(
        factor: Double,
        anchor: Double
    ) {
        gestureMetrics.begin("zoom")
        gestureMetrics.inputSample()
        if magnifyOrigin == nil {
            magnifyOrigin = viewport
            editingPlanID = nil
            TaptionPlanDiagnosticsLogger.shared.record(
                "timeline_zoom_began",
                fields: [
                    "scale": String(format: "%.3f", factor),
                    "anchor": String(format: "%.3f", anchor),
                    "resolution": scale.rawValue,
                ]
            )
            if isContinuousTimeline {
                let originSpan = visibleSpan
                let clampedAnchor = min(1, max(0, anchor))
                let anchorFraction = viewport.start
                    + viewport.length * clampedAnchor
                continuousMagnifyOrigin = ContinuousMagnifyOrigin(
                    duration: max(
                        60,
                        originSpan.duration * viewport.length
                    ),
                    anchorDate: timelineDate(
                        at: anchorFraction,
                        in: originSpan
                    ),
                    anchor: clampedAnchor
                )
                // The live duration becomes the source of truth.  Do not
                // leave a second viewport multiplier behind to quantize it.
                viewport = .full
                dragLayoutSpan = nil
                dragLayoutSnapshot = nil
            }
        }
        guard let magnifyOrigin else { return }
        if continuousMagnifyOrigin != nil {
            let lastRender = lastViewportRenderUptime
            applyContinuousMagnification(
                factor: factor,
                force: false
            )
            if lastViewportRenderUptime != lastRender {
                gestureMetrics.renderedSample()
            }
            return
        }
        let candidate = magnifyOrigin.magnifying(
            by: factor,
            anchor: anchor,
            minimumLength: viewportMinimumLength
        )
        let uptime = ProcessInfo.processInfo.systemUptime
        guard TimelineInteractionFrameGate.shouldRender(
            lastUptime: &lastViewportRenderUptime,
            nowUptime: uptime
        ) else {
            return
        }
        gestureMetrics.renderedSample()
        viewport = candidate
    }

    private func viewportMagnifyEnded(
        factor: Double,
        anchor: Double
    ) {
        guard magnifyOrigin != nil else {
            TaptionPlanDiagnosticsLogger.shared.record(
                "timeline_zoom_ended_without_begin",
                fields: [
                    "scale": String(format: "%.3f", factor),
                    "anchor": String(format: "%.3f", anchor),
                    "resolution": scale.rawValue,
                ]
            )
            return
        }
        finishSemanticMagnification(
            factor: factor,
            anchor: anchor
        )
        magnifyOrigin = nil
        lastViewportRenderUptime = 0
        recordGestureMetrics()
        TaptionPlanDiagnosticsLogger.shared.record(
            "timeline_zoom_ended",
            fields: [
                "scale": String(format: "%.3f", factor),
                "anchor": String(format: "%.3f", anchor),
                "resolution": scale.rawValue,
            ]
        )
    }

    private func finishSemanticMagnification(
        factor: Double,
        anchor: Double
    ) {
        if continuousMagnifyOrigin != nil {
            applyContinuousMagnification(factor: factor, force: true)
            let finalCenter = continuousCenterDate
            continuousMagnifyOrigin = nil
            viewport = .full
            preserveViewportAfterContinuousDrag = true
            model.selectedDate = finalCenter
            onPlayheadMove?(finalCenter)
            zoomFeedbackSequence += 1
            return
        }

        let origin = magnifyOrigin ?? viewport
        let zoomsIn = factor >= 1.15
        let zoomsOut = factor <= 0.85
        guard zoomsIn || zoomsOut else {
            // The live viewport already follows the fingers. Do not snap a
            // small but intentional pinch back to the pre-gesture range.
            return
        }

        if scale != .day {
            let targetScale = zoomsIn
                ? scale.scheduleNarrower
                : scale.scheduleBroader
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
            guard let broader = scale.scheduleBroader else {
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
        model.selectedDate = timelineDate(
            at: anchorFraction,
            in: visibleSpan
        )
        viewport = .full
        selectScaleForResolution(targetScale)
        zoomFeedbackSequence += 1
    }

    private func applyContinuousMagnification(
        factor: Double,
        force: Bool
    ) {
        guard let origin = continuousMagnifyOrigin else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        guard TimelineInteractionFrameGate.shouldRender(
            lastUptime: &lastViewportRenderUptime,
            nowUptime: uptime,
            force: force
        ) else {
            return
        }

        let safeFactor = max(0.01, factor)
        let nleViewport = NLETimelineViewport(
            centerDate: origin.anchorDate,
            visibleDuration: origin.duration
        )
        let magnified = nleViewport.magnified(
            by: safeFactor,
            anchor: origin.anchor,
            maximumDuration: NLETimelineViewport.maximumScheduleDuration
        )
        let duration = magnified.visibleDuration
        let center = magnified.centerDate
        if continuousTimelineDuration != duration {
            continuousTimelineDuration = duration
        }
        if continuousCenterDate != center {
            continuousCenterDate = center
        }
        viewport = .full
        ensureMagnifyLayoutWindow(around: center)
    }

    private func recordGestureMetrics() {
        guard let fields = gestureMetrics.finish() else { return }
        TaptionPlanDiagnosticsLogger.shared.record(
            "timeline_gesture_metrics",
            fields: fields
        )
    }

    private func resetViewport(withFeedback: Bool = false) {
        let changed = !viewport.isFull || hasCustomContinuousDuration
        if isContinuousTimeline {
            continuousTimelineDuration = continuousDuration(
                around: model.selectedDate
            )
            if isContinuousDay {
                dayZoom = .oneHour
            }
            continuousDragOrigin = nil
        }
        viewport = .full
        dragOrigin = nil
        magnifyOrigin = nil
        continuousMagnifyOrigin = nil
        dragLayoutSpan = nil
        dragLayoutSnapshot = nil
        editingPlanID = nil
        if withFeedback, changed {
            zoomFeedbackSequence += 1
        }
    }

    private func handleRowTap(_ row: TimelineRowModel) {
        selectedRowID = row.id
        if row.id.hasPrefix("dayPhase."),
           let block = nearestBlock(
               in: row.blocks,
               to: continuousCenterDate
           ) {
            onSelection?(selectionFromBlock(block))
            return
        }
        let selectableBlocks = row.blocks
            .filter { !$0.isActual && $0.planID != nil }
            .sorted {
                ($0.startsAt ?? .distantPast) < ($1.startsAt ?? .distantPast)
            }
        if let block = selectableBlocks.first {
            onSelection?(selectionFromBlock(block))
            return
        }

        guard let categoryID = row.categoryID else { return }
        if categoryID == "calendar" {
            onSelection?(
                TimelineSelection(
                    title: "일정",
                    span: visibleSpan,
                    planID: nil,
                    isRoute: false,
                    categoryID: "calendar",
                    categoryName: "일정"
                )
            )
            return
        }
        onSelection?(
            TimelineSelection(
                title: row.title,
                span: visibleSpan,
                planID: nil,
                isRoute: categoryID == "movement" || categoryID == "location",
                categoryID: categoryID,
                categoryName: row.title
            )
        )
    }

    private func nearestBlock(
        in blocks: [TimelineBlock],
        to date: Date
    ) -> TimelineBlock? {
        blocks.min { lhs, rhs in
            blockDistance(lhs, to: date) < blockDistance(rhs, to: date)
        }
    }

    private func blockDistance(
        _ block: TimelineBlock,
        to date: Date
    ) -> TimeInterval {
        guard let start = block.startsAt, let end = block.endsAt else {
            return .greatestFiniteMagnitude
        }
        if start <= date, date <= end { return 0 }
        return min(abs(start.timeIntervalSince(date)), abs(end.timeIntervalSince(date)))
    }

    private func focusOnBlock(_ block: TimelineBlock) {
        let selection = selectionFromBlock(block)
        onFocus?(selection)
        onSelection?(selection)

        if isContinuousTimeline,
           let startsAt = block.startsAt,
           let endsAt = block.endsAt {
            continuousCenterDate = startsAt.addingTimeInterval(
                max(0, endsAt.timeIntervalSince(startsAt)) / 2
            )
            model.selectedDate = continuousCenterDate
            if scale == .day {
                dayZoom = TimelineZoomPreset.nearest(
                    to: max(60, endsAt.timeIntervalSince(startsAt) * 6)
                )
            } else {
                continuousTimelineDuration = continuousDuration(
                    around: continuousCenterDate
                )
            }
            editingPlanID = nil
            zoomFeedbackSequence += 1
            return
        }
        let blockStart: Double
        let blockLength: Double
        if let startsAt = block.startsAt,
           let endsAt = block.endsAt {
            blockStart = timelineFraction(of: startsAt, in: visibleSpan)
            blockLength = timelineFraction(of: endsAt, in: visibleSpan)
                - blockStart
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
        let selection = selectionFromBlock(block)
        onSelection?(selection)

        if selection.categoryID == ReviewCoverageEngine.unconfirmedCategoryID {
            model.detail = .unconfirmedEditor(selection.span)
            return
        }

        // A stored actual record is the editable source for the selected
        // timeline block.  Open its detail editor directly so a tap on the
        // timetable is enough to correct the displayed activity and time.
        // The editor persists a correction while keeping automatic sensor /
        // HealthKit source values unchanged.
        if let actualID = selection.actualID,
           model.snapshot.actuals.contains(where: { $0.id == actualID }) {
            model.detail = .actualEditor(actualID)
            return
        }

        if block.opensLocationTimeline {
            return
        }

        if block.groupCount != nil {
            if let planID = block.planID {
                model.openGroup(planID)
            }
            return
        }

    }

    private func selectionFromBlock(_ block: TimelineBlock) -> TimelineSelection {
        let selectionSpan: TimeSpan = {
            if let startsAt = block.startsAt, let endsAt = block.endsAt {
                return TimeSpan(start: startsAt, end: endsAt)
            }
            let start = timelineDate(
                at: Double(block.start),
                in: visibleSpan
            )
            let end = timelineDate(
                at: min(1, Double(block.start + block.length)),
                in: visibleSpan
            )
            return TimeSpan(
                start: start,
                end: max(
                    start.addingTimeInterval(60),
                    end
                )
            )
        }()
        let actualID = block.actualID ?? (
            block.isActual
                && model.snapshot.actuals.contains(where: { $0.id == block.id })
                ? block.id
                : nil
        )
        let travelID = block.travelID ?? (
            block.categoryID == "movement"
                && model.snapshot.travel.contains(where: { $0.id == block.id })
                ? block.id
                : nil
        )
        return TimelineSelection(
            title: block.title,
            span: selectionSpan,
            planID: block.planID,
            actualID: actualID,
            travelID: travelID,
            recordNodeID: {
                if let recordNodeID = block.recordNodeID {
                    return recordNodeID
                }
                if let travelID {
                    return "automatic.travel.\(travelID.uuidString)"
                }
                if let actualID {
                    return "automatic.actual.\(actualID.uuidString)"
                }
                if block.isActual {
                    if block.categoryID == "location",
                       model.snapshot.places.contains(where: {
                           $0.id == block.id
                       }) {
                        return "automatic.place.\(block.id.uuidString)"
                    }
                    if block.categoryID == "weather",
                       model.snapshot.weather.contains(where: {
                           $0.id == block.id
                       }) {
                        return "automatic.weather.\(block.id.uuidString)"
                    }
                }
                if block.categoryID == "calendar" {
                    let event = model.snapshot.calendarEvents.first {
                        $0.title == block.title
                            && abs($0.span.start.timeIntervalSince(
                                selectionSpan.start
                            )) < 2
                    }
                    return event.map {
                        "automatic.calendar.\($0.id)"
                    }
                }
                if let planID = block.planID {
                    let isRoutine = model.snapshot.plans.first {
                        $0.id == planID
                    }.map(GoalRecordPolicy.isGoal) ?? false
                    return "\(isRoutine ? "routine" : "action").\(planID.uuidString)"
                }
                return nil
            }(),
            isRoute: block.opensLocationTimeline,
            categoryID: block.categoryID,
            categoryName: block.categoryName
        )
    }
}
