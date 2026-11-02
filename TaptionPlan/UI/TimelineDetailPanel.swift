import SwiftUI
import UIKit
import MapKit

enum TimelineDetailSection: String, CaseIterable, Identifiable {
    case schedule = "일정"
    case location = "위치"
    case movement = "이동"
    case sleep = "수면"
    case activity = "활동"
    case appUsage = "어플"
    case weather = "날씨"
    case routine = "루틴"
    case action = "액션·메모"
    case photo = "사진"
    case memo = "메모"
    case event = "이벤트"
    case map = "지도"

    var id: Self { self }

    /// 시간표 줄과 같은 기호를 쓴다. 표를 두 벌 두면 한쪽만 바뀐다.
    var rowKind: TimelineRowKind? {
        switch self {
        case .schedule: .calendar
        case .location: .location
        case .movement: .movement
        case .sleep: .sleep
        case .activity: .activity
        case .appUsage: .appUsage
        case .weather: .weather
        case .photo: .photo
        case .memo: .memo
        case .routine, .action, .event, .map: nil
        }
    }

    var systemImage: String {
        if let rowKind { return rowKind.systemImage }
        switch self {
        case .routine: return "repeat.circle"
        case .action: return "checklist.checked"
        case .event: return "sparkles"
        case .map: return "map"
        default: return "circle"
        }
    }

    static let defaultOrder: [Self] = [
        .schedule,
        .location,
        .movement,
        .sleep,
        .activity,
        .appUsage,
        .weather,
        .photo,
        .memo,
        .map,
        .routine,
        .action,
        .event,
    ]
}

struct TimelineDetailPanel: View {
    @Bindable var model: AppModel
    let selection: TimelineSelection?
    let playheadDate: Date?
    @Binding var panelHeight: CGFloat
    let maxHeight: CGFloat
    @Binding var section: TimelineDetailSection
    let highlightedSection: TimelineDetailSection?
    @Binding var selectedPhotoCluster: PhotoCluster?
    let routeReadings: [SensorReading]
    let onActualDeleted: (UUID) -> Void
    let onRouteSelection: (TimelineSelection) -> Void
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var routeMapViewportSize = CGSize.zero
    // 지도에서 선을 골라내려면 지금 보이는 범위를 알아야 한다. 카메라가
    // 멈출 때만 받아 두어 프레임마다 값이 바뀌지 않게 한다.
    @State private var visibleMapRegion: MKCoordinateRegion?
    @State private var selectedPhotoIndex = 0
    @State private var pendingActualDeletionID: UUID?
    @State private var showsGoalLinkSheet = false
    @State private var showsRecordLinkSheet = false
    @State private var showsActionLinkSheet = false
    @State private var actionPlanForRoutineLink: PlanRecord?
    @State private var lastMapFocusCoordinate: CLLocationCoordinate2D?
    // Mutating the gate itself does not invalidate the detail view, unlike a
    // rapidly changing @State timestamp on every live sensor callback.
    @State private var mapFitGate = TimelineMapFitGate()
    @State private var photoClusterCache = TimelinePhotoClusterCache()
    // Route geometry is requested by several detail cards and by MapKit in
    // the same render pass. Cache the filtered segments and coordinate
    // polylines so a live playhead update does not rescan every reading for
    // each consumer.
    @State private var routePresentationCache =
        TimelineRoutePresentationCache()
    @State private var placeIndexCache = TimelinePlaceIndexCache()
    @State private var planIndexCache = TimelinePlanIndexCache()
    // The same filtered detail collections are consumed by both section
    // visibility and the card body. Reuse them for a playhead tick instead
    // of rescanning plans, actuals, places, and calendar events twice.
    @State private var detailDataCache = TimelineDetailDataCache()
    @State private var panelDragStartHeight: CGFloat?
    @State private var lastPanelResizeRenderUptime: TimeInterval = 0

    private var maximumPanelHeight: CGFloat {
        max(detailPanelCollapsedHeight, maxHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            panelResizeHandle
            // Keep the selected item's icon visible while the playhead moves.
            // Empty intervals still have no header because activeSelection is
            // nil, so no stale routine title is invented.
            if activeSelection != nil {
                detailContextHeader
            }
            if playheadDate == nil,
               !TaptionProductScope.automaticLoggingOnly,
               let selection,
               selection.recordNodeID != nil,
               selection.actualID == nil,
               selection.categoryID != "location",
               selection.categoryID != "movement" {
                recordLinkControl(selection)
            }

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 9) {
                        ForEach(availableDetailSections) { item in
                            detailCard(for: item)
                                .id(item)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    // 하단 탭 막대는 화면 위에 떠 있어 안전 영역을 넓혀 주지
                    // 않는다. 마지막 카드가 막대 뒤로 숨지 않게 비워 둔다.
                    .padding(.bottom, DraftBottomBarMetrics.contentInset)
                }
                .scrollDismissesKeyboard(.interactively)
                // 콘텐츠가 화면보다 짧거나 마지막 카드까지 도달하면
                // 아래쪽 고무줄 반동을 만들지 않는다.
                .scrollBounceBehavior(.basedOnSize)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .top
                )
                .background(Color.tpBackground)
                .onChange(of: section) { _, newSection in
                    withAnimation(.easeInOut(duration: 0.24)) {
                        proxy.scrollTo(newSection, anchor: .top)
                    }
                }
            }
        }
        .background(Color.tpBackground)
        .clipped()
        .overlay(alignment: .top) {
            Rectangle().fill(Color.tpLine).frame(height: 0.5)
        }
        .onChange(of: selection) { _, _ in
            ensureVisibleDetailSection()
            fitMapToRoutes(force: true)
            selectedPhotoIndex = 0
        }
        .onChange(of: playheadDate) { _, _ in
            // Playhead detail is delivered at 20 Hz, but MapKit does not
            // need a camera transaction for every delivered tick. Keep the
            // location marker responsive while limiting expensive region
            // updates to a 15 Hz presentation budget.
            fitMapToRoutes()
        }
        .onChange(of: routeReadingsSignature) { _, _ in
            fitMapToRoutes()
        }
        .onChange(of: model.latestSensorReading?.timestamp) { _, _ in
            // A fresh GPS fix is the source of truth for the idle map center.
            fitMapToRoutes()
        }
        .onChange(of: model.liveRouteState.lastUpdatedAt) { _, _ in
            // Live tracking can update before the archived readings refresh.
            fitMapToRoutes()
        }
        .onChange(of: selectedPhotoCluster?.id) { _, _ in
            selectedPhotoIndex = 0
        }
        .task {
            ensureVisibleDetailSection()
            fitMapToRoutes(force: true)
        }
        .confirmationDialog(
            "이 실제 기록을 삭제할까요?",
            isPresented: Binding(
                get: { pendingActualDeletionID != nil },
                set: { if !$0 { pendingActualDeletionID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("실제 기록 삭제", role: .destructive) {
                guard let actualID = pendingActualDeletionID else { return }
                pendingActualDeletionID = nil
                Task {
                    await model.deleteActual(actualID)
                    onActualDeleted(actualID)
                }
            }
            Button("취소", role: .cancel) {
                pendingActualDeletionID = nil
            }
        } message: {
            Text("이 기록만 삭제되며 연결된 계획은 그대로 유지됩니다.")
        }
        .sheet(isPresented: $showsGoalLinkSheet) {
            if let actual = selectedActual {
                GoalActualLinkSheet(model: model, actual: actual)
            }
        }
        .sheet(isPresented: $showsRecordLinkSheet) {
            if let selection,
               let sourceNodeID = selection.recordNodeID {
                RecordNodeLinkSheet(
                    model: model,
                    sourceNodeID: sourceNodeID,
                    sourceTitle: selection.title
                )
            }
        }
        .sheet(isPresented: $showsActionLinkSheet) {
            if let routine = focusedRoutineForDetail {
                GoalActionLinkSheet(model: model, goal: routine)
            }
        }
        .sheet(item: $actionPlanForRoutineLink) { action in
            RoutineActionLinkSheet(model: model, action: action)
        }
    }

    private var panelResizeHandle: some View {
        VStack(spacing: 3) {
            Capsule()
                .fill(Color.tpSecondary.opacity(0.45))
                .frame(width: 34, height: 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 18)
        .contentShape(Rectangle())
        .accessibilityLabel("상세항목 패널 크기 조절")
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    if panelDragStartHeight == nil {
                        panelDragStartHeight = panelHeight
                    }
                    let start = panelDragStartHeight ?? panelHeight
                    let nextHeight = min(
                        maximumPanelHeight,
                        max(
                            detailPanelMinimumHeight,
                            start - value.translation.height
                        )
                    )
                    guard abs(nextHeight - panelHeight) > 0.5 else { return }
                    guard TimelineInteractionFrameGate.shouldRender(
                        lastUptime: &lastPanelResizeRenderUptime,
                        nowUptime: ProcessInfo.processInfo.systemUptime
                    ) else { return }
                    panelHeight = nextHeight
                }
                .onEnded { value in
                    let start = panelDragStartHeight ?? panelHeight
                    let finalHeight = min(
                        maximumPanelHeight,
                        max(
                            detailPanelMinimumHeight,
                            start - value.translation.height
                        )
                    )
                    if abs(finalHeight - panelHeight) > 0.5 {
                        panelHeight = finalHeight
                    }
                    panelDragStartHeight = nil
                    lastPanelResizeRenderUptime = 0
                    let targetHeight: CGFloat?
                    if value.translation.height < -8,
                       panelHeight < maximumPanelHeight - 0.5 {
                        targetHeight = maximumPanelHeight
                    } else if value.translation.height > 8,
                              panelHeight > detailPanelCollapsedHeight + 0.5 {
                        targetHeight = detailPanelCollapsedHeight
                    } else {
                        targetHeight = nil
                    }
                    guard let targetHeight,
                          abs(targetHeight - panelHeight) > 0.5 else { return }
                    withAnimation(.snappy(duration: 0.2)) {
                        panelHeight = targetHeight
                    }
                }
        )
    }

    private var availableDetailSections: [TimelineDetailSection] {
        let visible = TimelineDetailSection.defaultOrder.filter { section in
            if TaptionProductScope.automaticLoggingOnly {
                switch section {
                case .routine, .action, .event:
                    return false
                default:
                    break
                }
            }
            return switch section {
            case .schedule:
                hasScheduleContent
            case .location:
                hasLocationContent
            case .movement:
                hasMovementContent
            case .sleep:
                hasSleepContent
            case .activity:
                hasActivityContent
            case .appUsage:
                hasAppUsageContent
            case .weather:
                hasWeatherContent
            case .routine:
                hasRoutineContent
            case .action:
                hasActionContent
            case .photo:
                activePhotoCluster != nil
            case .memo:
                hasMemoContent
            case .event:
                hasEventContent
            case .map:
                hasMapContent
            }
        }
        let ordered = TimelineRowOrder.ordered(
            visible.filter { detailRowID(for: $0) != nil },
            id: { detailRowID(for: $0) ?? "" },
            savedIDs: model.snapshot.settings.timelineRowOrder
        )
        let extras = visible.filter {
            detailRowID(for: $0) == nil && $0 != .map
        }
        var result = ordered
        if visible.contains(.map) {
            // 지도는 별도 행이 아니라 위치·이동의 상세 내용이다. 상단
            // 시간표에서 같은 행의 뒤에 삽입해 카드 순서를 유지한다.
            let anchorID = activeSelection?.isRoute == true
                ? "movement"
                : "location"
            let insertion = result.firstIndex {
                detailRowID(for: $0) == anchorID
            }.map { $0 + 1 } ?? result.count
            result.insert(.map, at: min(insertion, result.count))
        }
        return result + extras
    }

    private func detailRowID(
        for section: TimelineDetailSection
    ) -> String? {
        section.rowKind?.rawValue
    }

    private func ensureVisibleDetailSection() {
        guard let first = availableDetailSections.first else { return }
        if !availableDetailSections.contains(section) {
            section = first
        }
    }

    private var detailContextHeader: some View {
        VStack(alignment: .leading, spacing: TaptionSpacing.compact) {
            if playheadDetailSections.isEmpty {
                detailContextTitle
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: TaptionSpacing.compact) {
                        ForEach(playheadDetailSections) { item in
                            Button {
                                section = item
                            } label: {
                                Label(item.rawValue, systemImage: item.systemImage)
                                    .font(.taption(size: 8.5, weight: .semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .foregroundStyle(
                                        section == item
                                            ? Color.tpSurface
                                            : Color.tpInk
                                    )
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(
                                        section == item
                                            ? Color.tpProjectDark
                                            : Color.tpSurface,
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(item.rawValue) 상세 보기")
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }

            if !playheadDetailSections.isEmpty {
                detailContextTitle
                    .padding(.horizontal, 10)
            }
        }
        .padding(.vertical, 6)
        .background(Color.tpSky.opacity(0.18))
    }

    private var detailContextTitle: some View {
        HStack(spacing: TaptionSpacing.regular) {
            Image(systemName: activeSelection?.preferredDetailSection.systemImage ?? "clock")
                .font(.taption(size: 10, weight: .bold))
                .foregroundStyle(Color.tpInk)
                .frame(width: 24, height: 24)
                .background(
                    Color.tpSurface,
                    in: RoundedRectangle(cornerRadius: TaptionRadius.tight, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(activeSelection?.title ?? "하루 상세")
                    .font(.taption(size: 10.5, weight: .bold))
                    .foregroundStyle(Color.tpInk)
                    .lineLimit(1)
                Text(detailContextTimeLabel)
                    .font(.taption(size: 7.8, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)
        }
    }

    private var playheadDetailSections: [TimelineDetailSection] {
        availableDetailSections.filter { $0 != .map }
    }

    private var detailContextTimeLabel: String {
        if let plan = selectedPlanForDetail,
           let repeatSummary = GoalRepeatRuleFormatter.summary(
               effectiveRepeatRules(for: plan)
           ) {
            return "반복 · \(repeatSummary)"
        }
        if let playheadDate {
            return playheadDate.formatted(date: .abbreviated, time: .shortened)
        }
        if let selection = activeSelection {
            let start = selection.span.start.formatted(
                date: .abbreviated,
                time: .shortened
            )
            let end = selection.span.end.formatted(
                date: .omitted,
                time: .shortened
            )
            return "\(start)–\(end)"
        }
        return model.selectedDate.formatted(date: .complete, time: .omitted)
    }

    /// Generated repeat segments intentionally do not duplicate the rule
    /// payload. Resolve their parent here so the detail header still shows
    /// the configured clock time instead of the goal's date-only 00:00 span.
    private var selectedPlanForDetail: PlanRecord? {
        guard let selection = activeSelection,
              selection.actualID == nil,
              selection.travelID == nil,
              let planID = selection.planID else { return nil }
        return planIndexCache.plan(
            id: planID,
            timelineRevision: model.timelineRevision,
            plans: model.snapshot.plans
        )
    }

    private var selectedRoutineForDetail: PlanRecord? {
        guard var plan = selectedPlanForDetail else { return nil }
        var visited = Set<UUID>()
        while visited.insert(plan.id).inserted {
            if GoalRecordPolicy.isGoal(plan) {
                return plan
            }
            guard let parentID = plan.parentID,
                  let parent = planIndexCache.plan(
                      id: parentID,
                      timelineRevision: model.timelineRevision,
                      plans: model.snapshot.plans
                  ) else {
                break
            }
            plan = parent
        }
        return nil
    }

    private var focusedRoutineForDetail: PlanRecord? {
        if playheadDate == nil {
            return selectedRoutineForDetail
        }
        guard let date = playheadDate else { return nil }
        let repeatParentIDs = Set(
            model.snapshot.plans
                .filter {
                    $0.origin == .repeatRule
                        && $0.span.contains(date)
                }
                .compactMap(\.parentID)
        )
        let goals = model.snapshot.plans.filter {
            GoalRecordPolicy.isGoal($0)
                && ($0.span.contains(date) || repeatParentIDs.contains($0.id))
        }
        let preferredCategories: [String]
        if activeSelection?.categoryID == "sleep"
            || !detailSleepPlans.isEmpty
            || !detailSleepActuals.isEmpty {
            preferredCategories = ["sleep"]
        } else if activeSelection?.categoryID == "activity"
            || !detailActivityPlans.isEmpty
            || !detailActivityActuals.isEmpty {
            preferredCategories = ["activity"]
        } else {
            preferredCategories = ["sleep", "activity"]
        }
        for categoryID in preferredCategories {
            if let goal = goals
                .filter({ $0.categoryID == categoryID })
                .min(by: focusedRoutineSort) {
                return goal
            }
        }
        return nil
    }

    private func focusedRoutineSort(
        _ lhs: PlanRecord,
        _ rhs: PlanRecord
    ) -> Bool {
        if lhs.span.duration == rhs.span.duration {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.span.duration < rhs.span.duration
    }

    /// A selected root routine is a valid detail target even when it has no
    /// child action yet. The routine card is the place where the user can
    /// inspect its repeat rule and add the first action.
    private var activeSelection: TimelineSelection? {
        guard let selection else { return nil }
        if TaptionProductScope.automaticLoggingOnly,
           selection.planID != nil,
           selection.actualID == nil,
           selection.travelID == nil {
            return nil
        }
        if TaptionProductScope.automaticLoggingOnly,
           let actualID = selection.actualID,
           let actual = model.snapshot.actuals.first(where: {
               $0.id == actualID
           }),
           !AutomaticRecordTimelineEngine.isImmutable(actual) {
            return nil
        }
        if let playheadDate, !selection.span.contains(playheadDate) {
            return nil
        }
        return selection
    }

    private func effectiveRepeatRules(
        for plan: PlanRecord
    ) -> [GoalRepeatRule]? {
        if plan.repeatRules?.isEmpty == false {
            return plan.repeatRules
        }
        guard plan.origin == .repeatRule,
              let parentID = plan.parentID,
              let parent = planIndexCache.plan(
                  id: parentID,
                  timelineRevision: model.timelineRevision,
                  plans: model.snapshot.plans
              ) else {
            return nil
        }
        return parent.repeatRules
    }

    @ViewBuilder
    private func detailCard(
        for item: TimelineDetailSection
    ) -> some View {
        let isFocused = activeSelection?.preferredDetailSection == item
            || (focusedRoutineForDetail != nil && item == .routine)
            || (activeSelection != nil && section == item)
        VStack(alignment: .leading, spacing: TaptionSpacing.cozy) {
            Group {
                switch item {
                case .schedule:
                    scheduleContent
                case .location:
                    locationContent
                case .movement:
                    movementContent
                case .sleep:
                    sleepContent
                case .activity:
                    activityContent
                case .appUsage:
                    appUsageContent
                case .weather:
                    weatherContent
                case .routine:
                    routineContent
                case .action:
                    actionContent
                case .photo:
                    photoContent
                case .memo:
                    memoContent
                case .event:
                    eventContent
                case .map:
                    routeContent
                }
            }
            // 메모 카드는 이미 그 구간의 메모를 전부 펴 놓았다. 여기서 또
            // 붙이면 같은 메모가 두 번 나온다.
            if item != .memo,
               activeSelection?.preferredDetailSection == item {
                DetailMemoList(
                    model: model,
                    selection: activeSelection,
                    section: item
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            isFocused
                ? Color.tpInk.opacity(0.035)
                : Color.tpSurface,
            in: RoundedRectangle(cornerRadius: TaptionRadius.panel, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: TaptionRadius.panel, style: .continuous)
                .stroke(
                    isFocused
                        ? Color.tpInk.opacity(0.34)
                        : Color.tpLine.opacity(0.75),
                    lineWidth: isFocused ? 1 : 0.5
                )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.rawValue) 상세")
    }

    private var routeContent: some View {
        VStack(alignment: .leading, spacing: TaptionSpacing.snug) {
            HStack {
                Label(
                    routeTitle,
                    systemImage: "map"
                )
                .font(.taption(size: 10, weight: .bold))
                .foregroundStyle(Color.tpTransitDark)
                Spacer()
                Text(isPlayheadLocationOnly ? "Apple 지도 위치" : "Apple 지도 경로")
                    .font(.taption(size: 8))
                    .foregroundStyle(Color.tpSecondary)
            }
            if !TaptionProductScope.automaticLoggingOnly {
                trackingControls
            }
            if let air = closestAirQuality {
                HStack(spacing: TaptionSpacing.snug) {
                    Image(systemName: "aqi.medium")
                    Text("PM10 \(Int(air.pm10MicrogramsPerCubicMeter.rounded()))")
                    Text("PM2.5 \(Int(air.pm25MicrogramsPerCubicMeter.rounded()))")
                    Spacer(minLength: 4)
                    Text("\(air.stationName ?? air.providerName) · \(air.isFallback ? "대체값" : air.providerName)")
                        .lineLimit(1)
                }
                .font(.taption(size: 7.8, weight: .semibold))
                .foregroundStyle(Color.tpSecondary)
            }
            if !TaptionProductScope.automaticLoggingOnly,
               let travel = explicitlySelectedTravel {
                travelModeEditor(for: travel)
            }
            if !hasMapContent {
                Label("기록된 이동 경로가 없습니다", systemImage: "location.slash")
                    .font(.taption(size: 9, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                    .frame(maxWidth: .infinity, minHeight: 84)
            } else {
                MapReader { proxy in
                Map(position: $mapPosition, content: {
                    ForEach(routeLocationPins) { pin in
                        Marker(pin.title, systemImage: "mappin.circle.fill", coordinate: pin.coordinate)
                            .tint(pin.tint)
                    }

                    if let pin = playheadRoutePin {
                        Marker(pin.title, systemImage: "scope", coordinate: pin.coordinate)
                            .tint(Color.tpNow)
                    }

                    ForEach(dimmedRouteSegments) { segment in
                        let coordinates = coordinates(for: segment)
                        if coordinates.count >= 2 {
                            MapPolyline(coordinates: coordinates)
                                .stroke(
                                    routeColor(for: segment.mode)
                                        .opacity(RouteMapLineStyle.minimumOpacity),
                                    style: StrokeStyle(
                                        lineWidth: RouteMapLineStyle.lineWidth,
                                        lineCap: .round,
                                        lineJoin: .round
                                    )
                                )
                        }
                    }

                    ForEach(routeSegments) { segment in
                        let coordinates = coordinates(for: segment)
                        if coordinates.count >= 2 {
                            let isHighlighted = selectedSegmentIDs
                                .contains(segment.id)
                            MapPolyline(coordinates: coordinates)
                                .stroke(
                                    routeColor(for: segment.mode).opacity(
                                        isHighlighted
                                            ? 1
                                            : RouteMapLineStyle.minimumOpacity
                                    ),
                                    style: StrokeStyle(
                                        lineWidth: RouteMapLineStyle.lineWidth,
                                        lineCap: .round,
                                        lineJoin: .round
                                    )
                            )
                            .mapOverlayLevel(
                                level: isHighlighted
                                    ? .aboveLabels
                                    : .aboveRoads
                            )
                        }
                    }
                    if routeSegments.isEmpty,
                       displayedRouteCoordinates.count >= 2 {
                        MapPolyline(coordinates: displayedRouteCoordinates)
                            .stroke(
                                Color.tpTransitDark.opacity(RouteMapLineStyle.minimumOpacity),
                                style: StrokeStyle(
                                    lineWidth: RouteMapLineStyle.lineWidth,
                                    lineCap: .round,
                                    lineJoin: .round
                                )
                            )
                    } else if shouldDrawFallbackRoutePath {
                        MapPolyline(coordinates: fallbackRouteCoordinates)
                            .stroke(
                                Color.tpTransitDark.opacity(RouteMapLineStyle.minimumOpacity),
                                style: StrokeStyle(
                                    lineWidth: RouteMapLineStyle.lineWidth,
                                    lineCap: .round,
                                    lineJoin: .round
                                )
                            )
                    }
                    if let selected = selectedSegment {
                        let coordinates = coordinates(for: selected)
                        if let first = coordinates.first {
                            Marker(
                                "출발",
                                systemImage: routeModeSystemImage(selected.mode),
                                coordinate: first
                            )
                                .tint(routeColor(for: selected.mode))
                        }
                        if coordinates.count >= 2, let last = coordinates.last {
                            Marker("도착", systemImage: "flag.fill", coordinate: last)
                                .tint(routeColor(for: selected.mode))
                        }
                    }
                })
                .mapStyle(.standard(
                    elevation: .flat,
                    emphasis: .muted,
                    pointsOfInterest: .excludingAll,
                    showsTraffic: false
                ))
                .environment(\.colorScheme, .light)
                .mapControls {
                    MapCompass()
                    MapScaleView()
                }
                .onMapCameraChange(frequency: .onEnd) { context in
                    visibleMapRegion = context.region
                }
                .onTapGesture { location in
                    guard let coordinate = proxy.convert(
                        location,
                        from: .local
                    ) else { return }
                    selectRouteSegment(near: coordinate)
                }
                .frame(height: routeMapHeight)
                .background {
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear {
                                updateRouteMapViewportSize(geometry.size)
                            }
                            .onChange(of: geometry.size) { _, size in
                                updateRouteMapViewportSize(size)
                            }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: TaptionRadius.field, style: .continuous))
                }

                if displayedRouteCoordinates.count >= 2 {
                    HStack(spacing: 10) {
                        Label(
                            "GPS \(recordedRouteFixCount)개",
                            systemImage: "location.fill"
                        )
                        Label(
                            distanceLabel(recordedRouteDistanceMeters),
                            systemImage: "point.topleft.down.to.point.bottomright.curvepath"
                        )
                        Spacer(minLength: 4)
                        Text("기록 경로")
                    }
                    .font(.taption(size: 7.8, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                }
            }

            if isPlayheadLocationOnly {
                Text("이동 내용이 없어 현재 위치만 표시합니다.")
                    .font(.taption(size: 7.5, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Color(red: 0.98, green: 0.98, blue: 0.98),
                        in: Capsule()
                    )
            }

            if !routeSegments.isEmpty &&
                routeSegments.flatMap(coordinates(for:)).count < 2 {
                Text("좌표 정밀도가 낮아 선분을 그릴 수 없어서 위치 마커만 표시 중입니다.")
                    .font(.taption(size: 7.5, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Color(red: 0.98, green: 0.98, blue: 0.98),
                        in: Capsule()
                    )
            }
        }
    }

    private var trackingControls: some View {
        HStack(spacing: TaptionSpacing.snug) {
            if let session = model.activeTrackingSession {
                Label(
                    "\(session.kind.displayName) 기록 중",
                    systemImage: session.kind == .running
                        ? "figure.run"
                        : "figure.walk"
                )
                .font(.taption(size: 8.5, weight: .bold))
                .foregroundStyle(Color.tpTransitDark)
                Spacer(minLength: 4)
                Button("종료") {
                    Task { await model.stopTracking() }
                }
                .font(.taption(size: 8.5, weight: .bold))
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Button {
                    Task { await model.startTracking(.walking) }
                } label: {
                    Label("걷기 시작", systemImage: "figure.walk")
                }
                Button {
                    Task { await model.startTracking(.running) }
                } label: {
                    Label("달리기 시작", systemImage: "figure.run")
                }
                Spacer(minLength: 0)
            }
        }
        .font(.taption(size: 8.5, weight: .bold))
        .buttonStyle(.bordered)
    }

    private var closestAirQuality: AirQualityContext? {
        model.snapshot.weather
            .compactMap { weather in
                weather.airQuality.map { (weather.observedAt, $0) }
            }
            .min {
                abs($0.0.timeIntervalSince(playheadDate ?? .now))
                    < abs($1.0.timeIntervalSince(playheadDate ?? .now))
            }?.1
    }

    private var locationContent: some View {
        VStack(alignment: .leading, spacing: TaptionSpacing.snug) {
            detailHeading("위치", systemImage: "mappin.and.ellipse")
            if detailPlaces.isEmpty {
                if let coordinate = currentLocationCoordinate {
                    HStack(spacing: TaptionSpacing.cozy) {
                        Image(systemName: "scope")
                            .foregroundStyle(Color.tpNow)
                        Text(
                            "현재 위치 · "
                                + String(format: "%.5f", coordinate.latitude)
                                + ", "
                                + String(format: "%.5f", coordinate.longitude)
                        )
                        .font(.taption(size: 9, weight: .semibold))
                    }
                }
            } else {
                ForEach(detailPlaces) { place in
                    HStack(spacing: TaptionSpacing.cozy) {
                        Image(systemName: "building.2")
                            .font(.taption(size: 9, weight: .bold))
                            .foregroundStyle(Color.tpPlaceDark)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(placeTitle(place))
                                .font(.taption(size: 9, weight: .semibold))
                            Text(
                                "\(place.span.start.formatted(date: .omitted, time: .shortened))–\(place.span.end.formatted(date: .omitted, time: .shortened)) · \(confidenceLabel(place.confidence))"
                            )
                            .font(.taption(size: 7.5))
                            .foregroundStyle(Color.tpSecondary)
                        }
                        Spacer(minLength: 4)
                        if let point = place.point {
                            Text("해발 \(Int(point.altitude.rounded()))m")
                                .font(.taption(size: 7.5, weight: .semibold))
                                .foregroundStyle(Color.tpSecondary)
                        }
                    }
                }
            }
            automaticNodeLinkControl(for: "location")
        }
    }

    private var movementContent: some View {
        VStack(alignment: .leading, spacing: TaptionSpacing.snug) {
            detailHeading("이동", systemImage: "figure.walk.motion")
            ForEach(confirmedDetailTravel) { travel in
                VStack(alignment: .leading, spacing: TaptionSpacing.cozy) {
                    HStack(spacing: TaptionSpacing.cozy) {
                        Image(systemName: routeModeSystemImage(travel.mode))
                            .font(.taption(size: 9, weight: .bold))
                            .foregroundStyle(detailTravelColor(travel))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(detailTravelTitle(travel))
                                .font(.taption(size: 9, weight: .semibold))
                            Text(
                                "\(travel.span.start.formatted(date: .omitted, time: .shortened))–\(travel.span.end.formatted(date: .omitted, time: .shortened)) · \(confidenceLabel(travel.confidence))"
                            )
                            .font(.taption(size: 7.5))
                            .foregroundStyle(Color.tpSecondary)
                            if let location = travelLocationLabel(travel) {
                                Text(location)
                                    .font(.taption(size: 7.5, weight: .medium))
                                    .foregroundStyle(Color.tpPlaceDark)
                            }
                            if !travel.evidence.isEmpty {
                                Text(travel.evidence.prefix(2).joined(separator: " · "))
                                    .font(.taption(size: 7.2))
                                    .foregroundStyle(Color.tpSecondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                        Text(distanceLabel(travel.distanceMeters))
                            .font(.taption(size: 8, weight: .semibold))
                            .foregroundStyle(Color.tpSecondary)
                    }
                    if travel.mode == .subway, let route = travel.subwayRoute {
                        SubwayRouteTimelineView(
                            route: route,
                            span: travel.span,
                            isCompact: true
                        )
                    }
                }
            }
            ForEach(confirmedDetailMovementActuals) { actual in
                HStack(spacing: TaptionSpacing.cozy) {
                    Image(
                        systemName: movementActualSymbol(actual)
                    )
                    .font(.taption(size: 9, weight: .bold))
                    .foregroundStyle(Color.tpHealthDark)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("알고리즘 결과 · \(movementActualTitle(actual))")
                            .font(.taption(size: 9, weight: .semibold))
                        Text(actualDetailSubtitle(actual))
                            .font(.taption(size: 7.5))
                            .foregroundStyle(Color.tpSecondary)
                        if !actual.evidence.isEmpty {
                            Text(actual.evidence.prefix(2).joined(separator: " · "))
                                .font(.taption(size: 7.2))
                                .foregroundStyle(Color.tpSecondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                }
            }
            automaticNodeLinkControl(for: "movement")
        }
    }

    @ViewBuilder
    private func automaticNodeLinkControl(for categoryID: String) -> some View {
        if !TaptionProductScope.automaticLoggingOnly,
           let selection = activeSelection,
           selection.categoryID == categoryID,
           selection.actualID == nil,
           selection.recordNodeID != nil {
            recordLinkControl(selection)
        }
    }

    private var sleepContent: some View {
        automaticRecordsContent(
            title: "수면",
            systemImage: "moon.zzz",
            plans: detailSleepPlans,
            actuals: detailSleepActuals,
            tint: Color.tpSleepDark
        )
    }

    private var activityContent: some View {
        VStack(alignment: .leading, spacing: TaptionSpacing.snug) {
            automaticRecordsContent(
                title: "활동",
                systemImage: "figure.run",
                plans: detailActivityPlans,
                actuals: detailActivityActuals,
                tint: Color.tpHealthDark
            )
        }
    }

    /// 앱 사용은 "어떤 앱을, 언제부터, 얼마나"가 전부다. 선택한 줄은 앱
    /// 열기·알림 근거까지 펼쳐서 탭 한 번으로 전부 보이게 한다.
    private var appUsageContent: some View {
        VStack(alignment: .leading, spacing: TaptionSpacing.snug) {
            detailHeading(
                ScreenTimeUsageRecordEngine.laneTitle,
                systemImage: "app.badge.clock"
            )
            if detailData.appUsageActuals.isEmpty {
                Text("이 구간에 남은 앱 사용 기록이 없습니다")
                    .font(.taption(size: 9))
                    .foregroundStyle(Color.tpSecondary)
            }
            ForEach(detailData.appUsageActuals) { actual in
                appUsageRow(actual)
            }
        }
    }

    private func appUsageRow(_ actual: ActualRecord) -> some View {
        let span = actual.span()
        let isSelected = selectedActual?.id == actual.id
        return HStack(alignment: .top, spacing: TaptionSpacing.cozy) {
            Image(systemName: "app.badge.clock")
                .font(.taption(size: 9, weight: .bold))
                .foregroundStyle(Color.tpProjectDark)
            VStack(alignment: .leading, spacing: 1) {
                Text(actual.title)
                    .font(.taption(size: 9, weight: .semibold))
                AppUsageNameLabel(
                    record: actual,
                    tokenIndex: model.appUsageTokenIndex,
                    size: 9
                )
                Text(
                    "\(span.start.formatted(date: .omitted, time: .shortened))–\(span.end.formatted(date: .omitted, time: .shortened)) · \(ScreenTimeUsageRecordEngine.durationText(span.duration) ?? "1분 미만")"
                )
                .font(.taption(size: 7.5))
                .foregroundStyle(Color.tpSecondary)
                if isSelected {
                    ForEach(actual.evidence, id: \.self) { evidence in
                        Text("· \(evidence)")
                            .font(.taption(size: 7.5))
                            .foregroundStyle(Color.tpSecondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var weatherContent: some View {
        VStack(alignment: .leading, spacing: TaptionSpacing.snug) {
            detailHeading("날씨", systemImage: "cloud.sun")
            ForEach(detailData.weather) { weather in
                HStack(spacing: TaptionSpacing.cozy) {
                    Image(systemName: weather.symbolName)
                        .font(.taption(size: 12, weight: .bold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(
                            weatherSymbolColor(weather, component: .primary),
                            weatherSymbolColor(weather, component: .secondary)
                        )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(
                            "\(weather.condition) · \(Int(weather.temperatureCelsius.rounded()))°"
                        )
                        .font(.taption(size: 9, weight: .semibold))
                        Text(weather.observedAt.formatted(
                            date: .omitted,
                            time: .shortened
                        ))
                        .font(.taption(size: 7.5))
                        .foregroundStyle(Color.tpSecondary)
                        Text(weatherMeasurementLocation(weather))
                            .font(.taption(size: 7.5))
                            .foregroundStyle(Color.tpSecondary)
                    }
                    Spacer(minLength: 4)
                    if let air = weather.airQuality {
                        Text("미세 \(air.overallGrade.displayName)")
                            .font(.taption(size: 8, weight: .semibold))
                            .foregroundStyle(Color.tpWeatherDark)
                    }
                }
            }
            if !detailData.weather.isEmpty {
                WeatherAttributionView()
            }
        }
    }

    /// 메모 카드. 시간표 메모 줄이 표식으로 뭉쳐 보여 주는 것을 여기서는
    /// 하나씩 펼쳐 보여 준다. 새 메모 입력은 하단 메뉴에서 시작한다.
    private var memoContent: some View {
        VStack(alignment: .leading, spacing: TaptionSpacing.snug) {
            detailHeading(
                TimelineRowKind.memo.title,
                systemImage: TimelineRowKind.memo.systemImage
            )
            DetailMemoList(
                model: model,
                selection: nil,
                section: .memo,
                memos: detailData.memos,
                onSelect: nil
            )
        }
    }

    private func weatherMeasurementLocation(
        _ weather: WeatherContext
    ) -> String {
        if let placeName = weather.placeName,
           !placeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "측정 위치 · \(placeName)"
        }
        if let point = weather.point {
            return String(
                format: "측정 위치 · %.5f, %.5f",
                point.latitude,
                point.longitude
            )
        }
        return "측정 위치 · 위치 정보 없음"
    }

    private var routineContent: some View {
        VStack(alignment: .leading, spacing: TaptionSpacing.cozy) {
            detailHeading("루틴", systemImage: "repeat.circle")
            if let routine = focusedRoutineForDetail {
                HStack(spacing: TaptionSpacing.regular) {
                    Image(systemName: "repeat.circle.fill")
                        .font(.taption(size: 18, weight: .bold))
                        .foregroundStyle(Color.tpSleepDark)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(routineDisplayTitle(routine))
                            .font(.taption(size: 13, weight: .bold))
                            .foregroundStyle(Color.tpInk)
                        Text(
                            "기간 · \(routine.span.start.formatted(date: .abbreviated, time: .omitted))–\(routine.span.end.formatted(date: .abbreviated, time: .omitted))"
                        )
                        .font(.taption(size: 8))
                        .foregroundStyle(Color.tpSecondary)
                    }
                }

                if let summary = GoalRepeatRuleFormatter.summary(
                    effectiveRepeatRules(for: routine)
                ) {
                    Label("반복 · \(summary)", systemImage: "calendar.badge.clock")
                        .font(.taption(size: 8.5, weight: .semibold))
                        .foregroundStyle(Color.tpSleepDark)
                }
                let descendants = (try? PlanHierarchy.descendants(
                    of: routine.id,
                    in: model.snapshot.plans
                )) ?? []
                let actions = descendants.filter { isManualActionPlan($0) }
                let linkedActuals = GoalActivityMatchingEngine.matches(
                    goal: routine,
                    plans: model.snapshot.plans,
                    actuals: model.snapshot.actuals
                )
                HStack(spacing: TaptionSpacing.regular) {
                    Label("하위 액션 \(actions.count)개", systemImage: "checklist")
                    Label("연결 실적 \(linkedActuals.count)개", systemImage: "checkmark.circle")
                }
                .font(.taption(size: 8, weight: .semibold))
                .foregroundStyle(Color.tpSecondary)

                if !AutomaticRecordTimelineEngine.isRoutineOnlyCategory(
                    routine.categoryID
                ) {
                    Button {
                        showsActionLinkSheet = true
                    } label: {
                        Label("기존 액션아이템 연결", systemImage: "link")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                if actions.isEmpty && linkedActuals.isEmpty {
                    Text(
                        AutomaticRecordTimelineEngine.isRoutineOnlyCategory(
                            routine.categoryID
                        )
                            ? "수면·활동 실적은 자동 기록 카드에서 루틴으로 연결합니다."
                            : "아직 연결된 액션이나 실적이 없습니다. 기존 액션을 연결하거나 새 하위 계획을 만들어 주세요."
                    )
                        .font(.taption(size: 8.5, weight: .semibold))
                        .foregroundStyle(Color.tpSecondary)
                        .padding(.top, 2)
                }
            }
        }
    }

    private func automaticRecordsContent(
        title: String,
        systemImage: String,
        plans: [PlanRecord],
        actuals: [ActualRecord],
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: TaptionSpacing.snug) {
            detailHeading(title, systemImage: systemImage)
            ForEach(plans) { plan in
                HStack(spacing: TaptionSpacing.cozy) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(tint.opacity(0.72))
                        .frame(width: 5, height: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(plan.title)
                            .font(.taption(size: 9, weight: .semibold))
                        Text("계획 · \(actionPlanTimeLabel(plan))")
                            .font(.taption(size: 7.5))
                            .foregroundStyle(Color.tpSecondary)
                    }
                }
            }
            ForEach(actuals) { actual in
                HStack(spacing: TaptionSpacing.cozy) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.taption(size: 9, weight: .bold))
                        .foregroundStyle(tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(
                            isMovementActual(actual)
                                ? movementActualTitle(actual)
                                : isSleepActual(actual)
                                    ? actual.title
                                    : restActualTitle(actual)
                        )
                            .font(.taption(size: 9, weight: .semibold))
                        Text(
                            actualDetailSubtitle(actual)
                        )
                        .font(.taption(size: 7.5))
                        .foregroundStyle(Color.tpSecondary)
                    }
                }
            }
            // Sleep and activity are both automatic evidence. Keep the same
            // explicit-link affordance for either type; only the currently
            // focused record gets a control so a list of records stays quiet.
            if !TaptionProductScope.automaticLoggingOnly,
               let actual = selectedActual,
               actuals.contains(where: { $0.id == actual.id }) {
                actualGoalLinkControl(actual)
            }
        }
    }

    private func actualDetailSubtitle(_ actual: ActualRecord) -> String {
        let span = "\(TaptionActivityEngineAdapter.trustLabel(for: actual)) · \(actual.startedAt.formatted(date: .omitted, time: .shortened))–\((actual.endedAt ?? .now).formatted(date: .omitted, time: .shortened))"
        let source = actualSourceLabel(actual.source)
        let origin = actual.sourceKind.rawValue
        guard let behavior = actual.behavior
            .flatMap({ WatchBehaviorKind(rawValue: $0) }) else {
            return "\(span) · \(origin) · \(source)"
        }
        return "\(span) · \(origin) · \(source) · \(behavior.title)"
    }

    private var actionContent: some View {
        VStack(alignment: .leading, spacing: TaptionSpacing.cozy) {
            detailHeading("액션·메모", systemImage: "checklist.checked")
            if let actual = selectedActual {
                Text(actual.title)
                    .font(.taption(size: 14, weight: .bold))
                Text("\(actual.startedAt.formatted(date: .omitted, time: .shortened)) → \((actual.endedAt ?? .now).formatted(date: .omitted, time: .shortened))")
                    .font(.taption(size: 9))
                    .foregroundStyle(Color.tpSecondary)
                Text("실제 기록 · \(actualSourceLabel(actual.source))")
                    .font(.taption(size: 8.5, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                actualGoalLinkControl(actual)
                if AutomaticRecordTimelineEngine.isImmutable(actual) {
                    Label("자동 기록 · 수정 불가", systemImage: "lock.fill")
                        .font(.taption(size: 8.5, weight: .bold))
                        .foregroundStyle(Color.tpSecondary)
                } else {
                    Button(role: .destructive) {
                        pendingActualDeletionID = actual.id
                    } label: {
                        Label("실제 기록 삭제", systemImage: "trash")
                    }
                    .font(.taption(size: 9, weight: .bold))
                    .buttonStyle(.bordered)
                }
            } else if let plan = selectedManualActionPlan {
                Text(plan.title)
                    .font(.taption(size: 14, weight: .bold))
                Text("\(plan.span.start.formatted(date: .omitted, time: .shortened)) → \(plan.span.end.formatted(date: .omitted, time: .shortened))")
                    .font(.taption(size: 9))
                .foregroundStyle(Color.tpSecondary)
                actionMemoPreview(planID: plan.id)
                routineLinkControl(for: plan)
            } else {
                let plans = activeActionPlans
                if plans.isEmpty {
                    Text("이날 등록된 액션아이템이 없습니다")
                        .font(.taption(size: 9))
                        .foregroundStyle(Color.tpSecondary)
                } else {
                    ForEach(plans) { plan in
                        Button {
                            model.planEditorRequest = PlanEditorRequest(
                                id: plan.id
                            )
                        } label: {
                            HStack(spacing: TaptionSpacing.cozy) {
                                RoundedRectangle(
                                    cornerRadius: plan.origin == .repeatRule
                                        ? 0
                                        : 4
                                )
                                .fill(Color.tpInk.opacity(0.12))
                                .frame(width: 5, height: 30)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(plan.title)
                                        .font(.taption(size: 9.5, weight: .semibold))
                                        .foregroundStyle(Color.tpInk)
                                        .lineLimit(1)
                                    Text(actionPlanTimeLabel(plan))
                                        .font(.taption(size: 8))
                                        .foregroundStyle(Color.tpSecondary)
                                }
                                Spacer(minLength: 4)
                                let memoCount = model.memos(for: plan.id).count
                                if memoCount > 0 {
                                    Label("\(memoCount)", systemImage: "note.text")
                                        .font(.taption(size: 7.5, weight: .bold))
                                        .foregroundStyle(Color.tpSecondary)
                                }
                                Image(systemName: "chevron.right")
                                    .accessibilityHidden(true)
                                    .font(.taption(size: 7, weight: .bold))
                                    .foregroundStyle(Color.tpSecondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                Color.white.opacity(0.82),
                                in: RoundedRectangle(
                                    cornerRadius: TaptionRadius.control,
                                    style: .continuous
                                )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func routineLinkControl(for action: PlanRecord) -> some View {
        HStack(spacing: TaptionSpacing.snug) {
            if let routine = routineForAction(action) {
                Label(
                    "연결된 루틴 · \(routineDisplayTitle(routine))",
                    systemImage: "repeat.circle.fill"
                )
                .font(.taption(size: 8, weight: .semibold))
                .foregroundStyle(Color.tpSleepDark)
                .lineLimit(1)
            } else {
                Label("연결된 루틴 없음", systemImage: "repeat.circle")
                    .font(.taption(size: 8))
                    .foregroundStyle(Color.tpSecondary)
            }
            Spacer(minLength: 4)
            Button(routineForAction(action) == nil ? "루틴 연결" : "루틴 변경") {
                actionPlanForRoutineLink = action
            }
            .font(.taption(size: 8, weight: .bold))
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            Color.tpBackground,
            in: RoundedRectangle(cornerRadius: TaptionRadius.small, style: .continuous)
        )
    }

    private func routineForAction(_ action: PlanRecord) -> PlanRecord? {
        var parentID = action.parentID
        var visited = Set<UUID>()
        while let id = parentID,
              visited.insert(id).inserted,
              let parent = planIndexCache.plan(
                  id: id,
                  timelineRevision: model.timelineRevision,
                  plans: model.snapshot.plans
              ) {
            if GoalRecordPolicy.isGoal(parent) { return parent }
            parentID = parent.parentID
        }
        return nil
    }

    private func routineDisplayTitle(_ routine: PlanRecord) -> String {
        GoalRecordPolicy.displayTitle(routine.title)
            .replacingOccurrences(of: GoalRecordPolicy.currentPrefix, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func actualGoalLinkControl(_ actual: ActualRecord) -> some View {
        let routineOnly = AutomaticRecordTimelineEngine.linksOnlyToRoutine(actual)
        return HStack(spacing: TaptionSpacing.snug) {
            if let goal = goalForActual(actual) {
                Label(
                    "루틴 근거 · \(GoalRecordPolicy.displayTitle(goal.title).replacingOccurrences(of: GoalRecordPolicy.currentPrefix, with: ""))",
                    systemImage: "scope"
                )
                .font(.taption(size: 8, weight: .semibold))
                .foregroundStyle(PlanCategory(categoryID: goal.categoryID).darkColor)
                .lineLimit(1)
            } else {
                Label("연결된 루틴 없음", systemImage: "scope")
                    .font(.taption(size: 8))
                    .foregroundStyle(Color.tpSecondary)
            }
            Spacer(minLength: 4)
            Button {
                showsGoalLinkSheet = true
            } label: {
                Text(
                    goalForActual(actual) == nil
                        ? (routineOnly ? "루틴 연결" : "루틴·액션 연결")
                        : "연결 변경"
                )
                    .font(.taption(size: 8, weight: .bold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            Color.tpBackground,
            in: RoundedRectangle(cornerRadius: TaptionRadius.small, style: .continuous)
        )
    }

    private func recordLinkControl(_ selection: TimelineSelection) -> some View {
        HStack(spacing: TaptionSpacing.snug) {
            Label("연결은 직접 선택", systemImage: "link.badge.plus")
                .font(.taption(size: 8, weight: .semibold))
                .foregroundStyle(Color.tpSecondary)
            Spacer(minLength: 4)
            Button("루틴·액션 연결") {
                showsRecordLinkSheet = true
            }
            .font(.taption(size: 8, weight: .bold))
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            Color.tpBackground,
            in: RoundedRectangle(cornerRadius: TaptionRadius.small, style: .continuous)
        )
    }

    private func goalForActual(_ actual: ActualRecord) -> PlanRecord? {
        if let routineID = actual.routineID,
           let routine = planIndexCache.plan(
               id: routineID,
               timelineRevision: model.timelineRevision,
               plans: model.snapshot.plans
           ),
           GoalRecordPolicy.isGoal(routine) {
            return routine
        }
        guard var planID = actual.planID else { return nil }
        var visited = Set<UUID>()
        while visited.insert(planID).inserted,
              let plan = planIndexCache.plan(
                  id: planID,
                  timelineRevision: model.timelineRevision,
                  plans: model.snapshot.plans
              ) {
            if GoalRecordPolicy.isGoal(plan) { return plan }
            guard let parentID = plan.parentID else { return nil }
            planID = parentID
        }
        return nil
    }

    private var activeActionPlans: [PlanRecord] {
        detailData.actionPlans
    }

    private let automaticDetailCategoryIDs: Set<String> = [
        "location",
        "movement",
        "sleep",
        "activity",
        "appUsage",
    ]

    private func isManualActionPlan(_ plan: PlanRecord) -> Bool {
        plan.categoryID != "event"
            && !automaticDetailCategoryIDs.contains(plan.categoryID)
            && !GoalRecordPolicy.isGoal(plan)
    }

    private var selectedManualActionPlan: PlanRecord? {
        detailData.selectedManualActionPlan
    }

    private var detailPlaces: [PlaceStay] {
        detailData.places
    }

    private var detailTravel: [TravelSegment] {
        detailData.travel
    }

    private var detailMovementActuals: [ActualRecord] {
        detailData.movementActuals
    }

    private var confirmedDetailTravel: [TravelSegment] {
        detailTravel.filter { $0.isConfirmed || $0.confidence != .low }
    }

    private var confirmedDetailMovementActuals: [ActualRecord] {
        detailMovementActuals.filter(isConfirmedMovementActual)
    }

    private var detailSleepPlans: [PlanRecord] {
        detailData.sleepPlans
    }

    private var detailActivityPlans: [PlanRecord] {
        detailData.activityPlans
    }

    private var detailSleepActuals: [ActualRecord] {
        detailData.sleepActuals
    }

    private var detailActivityActuals: [ActualRecord] {
        detailData.activityActuals
    }

    private var detailAppUsageActuals: [ActualRecord] {
        detailData.appUsageActuals
    }

    private var detailData: TimelineDetailDataCache.Value {
        let contentSpan = detailContentSpan
        let displaySpan = detailDisplaySpan
        let selection = activeSelection
        let cacheSpan = selection?.span ?? contentSpan
        let memoSpan = detailMemoSpan
        let key = TimelineDetailDataCache.Key(
            timelineRevision: model.timelineRevision,
            contentStart: cacheSpan.start.timeIntervalSinceReferenceDate,
            contentEnd: cacheSpan.end.timeIntervalSinceReferenceDate,
            displayStart: cacheSpan.start.timeIntervalSinceReferenceDate,
            displayEnd: cacheSpan.end.timeIntervalSinceReferenceDate,
            memoStart: memoSpan.start.timeIntervalSinceReferenceDate,
            memoEnd: memoSpan.end.timeIntervalSinceReferenceDate,
            playheadMinute: playheadDate.map {
                Int(floor($0.timeIntervalSinceReferenceDate / 60))
            },
            selectedPlanID: selection?.planID,
            selectedActualID: selection?.actualID,
            selectedTravelID: selection?.travelID,
            selectedRecordNodeID: selection?.recordNodeID,
            selectedCategoryID: selection?.categoryID
        )
        return detailDataCache.value(for: key) {
            let plans = TaptionProductScope.automaticLoggingOnly
                ? []
                : model.snapshot.plans
            let actuals = model.snapshot.actuals
            let automaticIDs = automaticDetailCategoryIDs
            // Automatic records are time-local. When the playhead is moving,
            // use its instant instead of the selected event's whole-day span;
            // an overnight repeat would otherwise show both adjacent days as
            // identical "23:00–06:30" rows.
            let focusedSpan = playheadDate.map {
                TimeSpan(
                    start: $0.addingTimeInterval(-1),
                    end: $0.addingTimeInterval(1)
                )
            } ?? contentSpan
            let playheadMatch = playheadDate.map { date in
                TimelinePlayheadSynchronizer.match(
                    at: date,
                    plans: plans,
                    actuals: actuals,
                    places: model.snapshot.places,
                    travel: model.snapshot.travel,
                    calendarEvents: model.snapshot.calendarEvents,
                    weather: model.snapshot.weather
                )
            }
            let matchedPlans = playheadMatch?.plans ?? plans
            let selectedPlan = selection?.planID.flatMap { planID in
                planIndexCache.plan(
                    id: planID,
                    timelineRevision: model.timelineRevision,
                    plans: plans
                )
            }
            let selectedManual = selectedPlan.flatMap { plan in
                isManualActionPlan(plan)
                    && plan.span.intersection(with: contentSpan) != nil
                    ? plan
                    : nil
            }
            let actionPlans: [PlanRecord]
            if let selectedManual {
                actionPlans = [selectedManual]
            } else {
                actionPlans = deduplicatedPlans(
                    matchedPlans
                        .filter { plan in
                            plan.status != .skipped
                                && plan.categoryID != "event"
                                && !automaticIDs.contains(plan.categoryID)
                                && plan.span.intersection(
                                    with: playheadDate == nil
                                        ? displaySpan
                                        : focusedSpan
                                ) != nil
                                && !GoalRecordPolicy.isGoal(plan)
                                && !(
                                    plan.parentID == nil
                                        && plan.repeatRules?.isEmpty == false
                                )
                        }
                        .sorted { $0.span.start < $1.span.start }
                )
            }
            let places = PlaceStayPresentationEngine.consolidated(
                playheadMatch?.places ?? model.snapshot.places.filter {
                    $0.span.intersection(with: focusedSpan) != nil
                }
            )
            let travel = TravelSegmentPresentationEngine.consolidated(
                playheadMatch?.travel ?? model.snapshot.travel.filter {
                    $0.span.intersection(with: focusedSpan) != nil
                }
            )
            let sleepPlans = deduplicatedPlans(
                matchedPlans.filter {
                    $0.categoryID == "sleep"
                        && !GoalRecordPolicy.isGoal($0)
                        && $0.span.intersection(with: focusedSpan) != nil
                }
            )
            let activityPlans = deduplicatedPlans(
                matchedPlans.filter {
                    $0.categoryID == "activity"
                        && !GoalRecordPolicy.isGoal($0)
                        && $0.span.intersection(with: focusedSpan) != nil
                }
            )
            // The day timeline's automatic rows contain only HealthKit and
            // Apple Watch evidence. Timer/manual activity records belong to
            // the action layer and must not appear here when they are absent
            // from the visible activity row.
            let automaticActuals = playheadMatch?.automaticActuals
                ?? AutomaticRecordTimelineEngine.activities(
                    from: actuals,
                    inside: focusedSpan
                )
            let reviewedAutomaticActuals = MovementDisplayEngine.reviewActuals(
                automaticActuals,
                travel: travel,
                calendarEvents: model.snapshot.calendarEvents,
                asOf: .now
            )
            let displayedAutomaticActuals = RestSleepDisplayEngine
                .visibleActuals(
                    reviewedAutomaticActuals,
                    asOf: .now
                )
            let sleepActuals = deduplicatedActuals(
                displayedAutomaticActuals
                    .filter { isSleepActual($0) }
                    .sorted { $0.startedAt < $1.startedAt }
            )
            let activityActuals = deduplicatedActuals(
                displayedAutomaticActuals
                    .filter {
                        !isSleepActual($0) && !isMovementActual($0)
                            && $0.categoryID != "appUsage"
                    }
                    .sorted { $0.startedAt < $1.startedAt }
            )
            let appUsageActuals = deduplicatedActuals(
                displayedAutomaticActuals
                    .filter { $0.categoryID == "appUsage" }
                    .sorted { $0.startedAt < $1.startedAt }
            )
            let movementActuals = deduplicatedActuals(
                displayedAutomaticActuals
                    .filter(isMovementActual)
                    .sorted { $0.startedAt < $1.startedAt }
            )
            let weather = (playheadMatch?.weather ?? model.snapshot.weather
                .filter {
                    weatherTimelineSpan($0)
                        .intersection(with: focusedSpan) != nil
                })
                .sorted { $0.observedAt < $1.observedAt }
            let selectedActual = selection?.actualID.flatMap { actualID in
                (playheadMatch?.actuals ?? actuals).first { actual in
                    actual.id == actualID
                        && actual.span().intersection(with: contentSpan) != nil
                }
            }
            let eventPlans = matchedPlans
                .filter {
                    $0.span.intersection(with: displaySpan) != nil
                        && $0.categoryID == "event"
                        && $0.parentID == nil
                }
                .sorted { $0.span.start < $1.span.start }
            let calendarEvents = (playheadMatch?.calendarEvents
                ?? model.snapshot.calendarEvents.filter {
                    $0.span.intersection(with: displaySpan) != nil
                })
                .sorted { $0.span.start < $1.span.start }
            return TimelineDetailDataCache.Value(
                actionPlans: actionPlans,
                selectedManualActionPlan: selectedManual,
                places: places,
                travel: travel,
                movementActuals: movementActuals,
                sleepPlans: sleepPlans,
                activityPlans: activityPlans,
                sleepActuals: sleepActuals,
                activityActuals: activityActuals,
                appUsageActuals: appUsageActuals,
                weather: weather,
                selectedActual: selectedActual,
                eventPlans: eventPlans,
                calendarEvents: calendarEvents,
                memos: MemoTimelineEngine.detailList(
                    in: memoSpan,
                    from: model.snapshot.memos
                )
            )
        }
    }

    /// 메모 카드와 메모 알약이 읽는 구간. 시간표가 펼쳐 둔 기간을 그대로
    /// 본다. 다른 줄은 재생 머리가 짚은 순간에 걸친 기록만 골라내지만
    /// 메모는 길이가 없는 순간이라 그 방식으로는 영영 걸리지 않는다.
    /// 시간표 메모 줄에 표식이 보이면 알약도 함께 나오는 것이 규칙이다.
    private var detailMemoSpan: TimeSpan {
        Self.periodEngine.interval(
            for: model.selectedScale.timelineLevel,
            containing: model.selectedDate
        )
    }

    /// 달력을 고르는 값은 늘 같다. 재생 머리가 움직이는 동안 카드마다 이
    /// 달력을 새로 세우지 않게 한 번만 만들어 둔다.
    private static let periodEngine = TimelineAggregationEngine()

    private func deduplicatedPlans(
        _ plans: [PlanRecord]
    ) -> [PlanRecord] {
        var seen = Set<String>()
        return plans
            .sorted {
                if ($0.origin == .repeatRule) != ($1.origin == .repeatRule) {
                    return $0.origin != .repeatRule
                }
                return $0.span.start < $1.span.start
            }
            .filter { plan in
                let normalizedTitle = plan.title
                    .split(whereSeparator: { $0.isWhitespace })
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Repeat segments are generated projections. Their title can
                // differ between legacy and current stores, but an identical
                // slot is still one timeline segment.
                let key = [
                    plan.categoryID,
                    plan.origin == .repeatRule ? "repeat" : normalizedTitle,
                    String(Int(plan.span.start.timeIntervalSinceReferenceDate.rounded())),
                    String(Int(plan.span.end.timeIntervalSinceReferenceDate.rounded())),
                ].joined(separator: "|")
                return seen.insert(key).inserted
            }
    }

    private func deduplicatedActuals(
        _ actuals: [ActualRecord]
    ) -> [ActualRecord] {
        var seen = Set<String>()
        return actuals
            .sorted {
                if $0.startedAt == $1.startedAt {
                    return actualSourcePriority($0.source)
                        > actualSourcePriority($1.source)
                }
                return $0.startedAt < $1.startedAt
            }
            .filter { actual in
                let end = actual.endedAt.map {
                    String(Int($0.timeIntervalSinceReferenceDate.rounded()))
                } ?? "open"
                let key = [
                    actual.categoryID,
                    actual.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    String(Int(actual.startedAt.timeIntervalSinceReferenceDate.rounded())),
                    end,
                ].joined(separator: "|")
                return seen.insert(key).inserted
            }
    }

    private func actualSourcePriority(_ source: ActualSource) -> Int {
        switch source {
        case .healthKit, .appleWatch, .motion, .media, .call, .appUsage: 3
        case .location: 2
        case .timer, .manual: 1
        case .calendar, .photo: 0
        }
    }

    private var detailContentSpan: TimeSpan {
        // Once the playhead is inside a concrete item, the detail payload is
        // stable for that item's full span. Using the raw playhead instant
        // here changed the cache key on every 20 Hz tick and rebuilt all plan,
        // actual, place and calendar filters while scrubbing.
        if let selection = activeSelection {
            return selection.span
        }
        if let playheadDate {
            return TimeSpan(
                start: playheadDate,
                end: playheadDate.addingTimeInterval(1)
            )
        }
        return activeSelection?.span ?? daySpan
    }

    private var detailDisplaySpan: TimeSpan {
        if playheadDate != nil || activeSelection != nil {
            return detailContentSpan
        }
        return daySpan
    }

    private var hasScheduleContent: Bool {
        !detailData.calendarEvents.isEmpty
    }

    private var hasLocationContent: Bool {
        !detailPlaces.isEmpty
            || (playheadDate == nil
                && activeSelection == nil
                && currentLocationCoordinate != nil)
    }

    private var hasMovementContent: Bool {
        !confirmedDetailTravel.isEmpty || !confirmedDetailMovementActuals.isEmpty
    }

    private var hasSleepContent: Bool {
        !detailSleepPlans.isEmpty || !detailSleepActuals.isEmpty
    }

    private var hasActivityContent: Bool {
        !detailActivityPlans.isEmpty || !detailActivityActuals.isEmpty
    }

    private var hasAppUsageContent: Bool {
        !detailAppUsageActuals.isEmpty
    }

    private var hasWeatherContent: Bool {
        !detailData.weather.isEmpty
    }

    /// 다른 줄과 같은 규칙이다. 보고 있는 기간에 메모가 하나라도 있으면
    /// 알약과 카드가 함께 나오고, 없으면 함께 빠진다.
    private var hasMemoContent: Bool {
        !detailData.memos.isEmpty
    }

    private var hasRoutineContent: Bool {
        focusedRoutineForDetail != nil
    }

    private var hasActionContent: Bool {
        if let actual = selectedActual {
            return !isSleepActual(actual) && actual.categoryID != "activity"
        }
        return !activeActionPlans.isEmpty
    }

    private var hasEventContent: Bool {
        !detailData.eventPlans.isEmpty
    }

    private func isSleepActual(_ actual: ActualRecord) -> Bool {
        AutomaticRecordTimelineEngine.isSleep(actual)
    }


    private func actionPlanTimeLabel(_ plan: PlanRecord) -> String {
        if let repeatSummary = GoalRepeatRuleFormatter.summary(
            effectiveRepeatRules(for: plan)
        ) {
            return repeatSummary
        }
        let start = plan.span.start.formatted(
            date: .omitted,
            time: .shortened
        )
        let end = plan.span.end.formatted(
            date: .omitted,
            time: .shortened
        )
        return "\(start)–\(end)"
    }

    private var selectedActual: ActualRecord? {
        detailData.selectedActual
    }

    private func actualSourceLabel(_ source: ActualSource) -> String {
        switch source {
        case .timer: "타이머"
        case .manual: "직접 기록"
        case .healthKit: "Apple 건강"
        case .appleWatch: "Apple Watch"
        case .motion: "iPhone 모션"
        case .calendar: "캘린더"
        case .location: "위치"
        case .photo: "사진"
        case .media: "미디어 재생"
        case .call: "통화"
        case .appUsage: "앱 사용시간"
        }
    }

    private func confidenceLabel(_ confidence: ConfidenceLevel) -> String {
        switch confidence {
        case .low: "낮은 신뢰"
        case .medium: "중간 신뢰"
        case .high: "높은 신뢰"
        }
    }

    private func placeTitle(_ place: PlaceStay) -> String {
        if let floor = place.floor {
            return place.displayName + " · " + String(floor) + "층"
        }
        return place.displayName
    }

    private func travelPlaceTitle(_ placeID: UUID?) -> String? {
        guard let placeID else { return nil }
        return (detailPlaces + model.snapshot.places)
            .first { $0.id == placeID }
            .map(placeTitle)
    }

    private func travelLocationLabel(_ travel: TravelSegment) -> String? {
        if let stationRoute = travel.evidence.first(where: {
            $0.hasPrefix("지하철역 ")
        }) {
            return stationRoute
        }
        let from = travelPlaceTitle(travel.fromPlaceID)
        let to = travelPlaceTitle(travel.toPlaceID)
        switch (from, to) {
        case let (from?, to?): return from + " → " + to
        case let (from?, nil): return from + " → 위치 미확인"
        case let (nil, to?): return "위치 미확인 → " + to
        case (nil, nil): return nil
        }
    }

    private func distanceLabel(_ meters: Double) -> String {
        if meters >= 1_000 {
            return String(format: "%.1fkm", meters / 1_000)
        }
        return String(Int(meters.rounded())) + "m"
    }

    private func actionMemoPreview(planID: UUID) -> some View {
        let memos = model.memos(for: planID)
        return VStack(alignment: .leading, spacing: TaptionSpacing.compact) {
            HStack(spacing: TaptionSpacing.compact) {
                Image(systemName: "note.text")
                    .font(.taption(size: 8.5, weight: .bold))
                Text("메모 \(memos.count)개")
                    .font(.taption(size: 9, weight: .bold))
                Spacer()
            }
            .foregroundStyle(Color.tpSecondary)

            if memos.isEmpty {
                Text("아직 메모가 없습니다. 결정, 아이디어, 막힘, 다음 할 일을 이 액션에 바로 붙여둘 수 있습니다.")
                    .font(.taption(size: 8.5))
                    .foregroundStyle(Color.tpSecondary)
                    .lineLimit(2)
            } else {
                ForEach(memos.prefix(2)) { memo in
                    Text("• \(memo.text)")
                        .font(.taption(size: 9))
                        .foregroundStyle(Color.tpInk.opacity(0.78))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(
            Color.white.opacity(0.78),
            in: RoundedRectangle(cornerRadius: TaptionRadius.field, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: TaptionRadius.field, style: .continuous)
                .stroke(Color.tpLine.opacity(0.7), lineWidth: 0.5)
        }
    }

    private var eventContent: some View {
        VStack(alignment: .leading, spacing: TaptionSpacing.snug) {
            detailHeading("이벤트", systemImage: "sparkles")
            let events = detailData.eventPlans
            if events.isEmpty {
                Text("이날 등록된 이벤트가 없습니다")
                    .font(.taption(size: 9))
                    .foregroundStyle(Color.tpSecondary)
            } else {
                ForEach(events) { event in
                    HStack {
                        Text(event.title).font(.taption(size: 9, weight: .semibold))
                        Spacer()
                        Text(event.span.start.formatted(date: .omitted, time: .shortened))
                            .font(.taption(size: 8))
                            .foregroundStyle(Color.tpSecondary)
                    }
                }
            }
            Text("애플·구글·네이버 캘린더에서 가져온 내용은 ‘일정’ 카드에 표시됩니다.")
                .font(.taption(size: 7.5, weight: .semibold))
                .foregroundStyle(Color.tpSecondary)
        }
    }

    private var photoContent: some View {
        VStack(alignment: .leading, spacing: TaptionSpacing.snug) {
            HStack {
                detailHeading("사진", systemImage: "photo.on.rectangle")
                Spacer()
                if let cluster = activePhotoCluster {
                    Text("\(selectedPhotoIndex + 1) / \(cluster.photos.count)")
                        .font(.taption(size: 8, weight: .semibold))
                        .foregroundStyle(Color.tpSecondary)
                }
            }

            if let cluster = activePhotoCluster {
                let photos = cluster.photos.sorted { $0.capturedAt < $1.capturedAt }
                TabView(selection: $selectedPhotoIndex) {
                    ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                        PhotoClusterPage(
                            model: model,
                            photo: photo,
                            index: index,
                            totalCount: photos.count
                        )
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 220)
                .background(
                    Color.black,
                    in: RoundedRectangle(cornerRadius: TaptionRadius.field, style: .continuous)
                )
                .clipShape(RoundedRectangle(cornerRadius: TaptionRadius.field, style: .continuous))

                Text(cluster.capturedAt.formatted(date: .omitted, time: .shortened))
                    .font(.taption(size: 8, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                ContentUnavailableView(
                    "이날 기록된 사진이 없습니다",
                    systemImage: "photo"
                )
                .font(.taption(size: 9))
                .foregroundStyle(Color.tpSecondary)
                .frame(maxWidth: .infinity, minHeight: 84)
            }
        }
    }

    private var scheduleContent: some View {
        VStack(alignment: .leading, spacing: TaptionSpacing.snug) {
            detailHeading("일정", systemImage: "calendar")
            let calendarEvents = detailData.calendarEvents
            if calendarEvents.isEmpty {
                Text("이날 등록된 일정이 없습니다")
                    .font(.taption(size: 9))
                    .foregroundStyle(Color.tpSecondary)
            } else {
                ForEach(calendarEvents) { event in
                    HStack(spacing: TaptionSpacing.cozy) {
                        Image(systemName: "calendar")
                            .font(.taption(size: 8, weight: .bold))
                            .foregroundStyle(Color.tpSecondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.title)
                                .font(.taption(size: 9, weight: .semibold))
                            Text(calendarSourceLabel(for: event))
                                .font(.taption(size: 7.5))
                                .foregroundStyle(Color.tpSecondary)
                        }
                        Spacer()
                        Text(calendarEventDateTimeLabel(for: event))
                            .font(.taption(size: 8))
                            .foregroundStyle(Color.tpSecondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        }
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

    private func calendarSourceLabel(for event: CalendarRecord) -> String {
        let source = event.sourceTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let calendar = event.calendarTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if let source, !source.isEmpty, source != calendar {
            return "\(source) · \(calendar)"
        }
        return calendar.isEmpty ? "캘린더" : calendar
    }

    private func detailHeading(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.taption(size: 10, weight: .bold))
            .foregroundStyle(Color.tpInk)
    }

    private var daySpan: TimeSpan {
        TimelineAggregationEngine().interval(for: .day, containing: model.selectedDate)
    }

    private var activeRouteSpan: TimeSpan {
        if let playheadDate {
            if let selection = activeSelection,
               selection.isRoute,
               selection.span.contains(playheadDate) {
                return selection.span
            }
            return playheadFocusSpan(around: playheadDate)
        }
        return activeSelection?.span ?? daySpan
    }

    private var activePhotoCluster: PhotoCluster? {
        if let playheadDate {
            guard activeSelection?.categoryID == "photo" else { return nil }
            guard let selectedPhotoCluster else { return nil }
            return selectedPhotoCluster.photos.contains(where: {
                abs($0.capturedAt.timeIntervalSince(playheadDate))
                    <= photoDetailTolerance
            }) ? selectedPhotoCluster : nil
        }
        if let selectedPhotoCluster {
            return selectedPhotoCluster
        }
        let photoSpan = activeSelection?.span ?? daySpan
        // The cached clusters are already chronological. Reuse that order
        // instead of filtering and sorting the full photo library whenever
        // the detail panel is redrawn.
        let photos = photoClusterCache.value(
            timelineRevision: model.timelineRevision,
            photos: model.snapshot.photos
        )
        .flatMap { cluster in
            cluster.photos.filter { photoSpan.contains($0.capturedAt) }
        }
        guard let representative = photos.first(where: \.isFavorite)
            ?? photos.first else {
            return nil
        }
        return PhotoCluster(
            id: "detail-\(representative.id)",
            representative: representative,
            photos: photos
        )
    }

    private var photoDetailTolerance: TimeInterval {
        60
    }

    private var routeTitle: String {
        if playheadDate != nil,
           routeSegments.isEmpty,
           fallbackRouteCoordinates.count < 2,
           !hasDimmedRoutes {
            return "현재 위치"
        }
        // 지도가 기간 전체의 지난 경로를 담고 있으면 제목도 그 기간을
        // 말해야 한다. 년 눈금은 배경을 깔지 않아 예전 이름을 그대로 쓴다.
        if let period = routePeriodName, !contextRouteSegments.isEmpty {
            if playheadDate != nil {
                return "\(period) 이동 경로 · 현재 구간"
            }
            if activeSelection?.isRoute == true {
                return "\(period) 이동 경로 · 선택 구간"
            }
            return "\(period) 이동 경로"
        }
        if playheadDate != nil {
            return "현재 이동 경로"
        }
        if activeSelection?.isRoute == true {
            return "선택된 이동 경로"
        }
        if activeSelection != nil {
            return "선택된 시간 경로"
        }
        return "오늘 이동 경로"
    }

    private var routeSegments: [TravelSegment] {
        routePresentationCache.segments(
            for: routePresentationCacheKey,
            span: activeRouteSpan,
            playheadDate: playheadDate,
            selectedTravelID: activeSelection?.travelID,
            travel: model.snapshot.travel
        ) {
            TimelineRouteDisplayPolicy.segments(
                from: model.snapshot.travel,
                intersecting: activeRouteSpan,
                at: playheadDate,
                selectedTravelID: activeSelection?.travelID
            )
        }
    }

    private var routePresentationCacheKey:
        TimelineRoutePresentationCache.Key {
        TimelineRoutePresentationCache.Key(
            timelineRevision: model.timelineRevision,
            readingsCount: routeReadings.count,
            firstReadingID: routeReadings.first?.id,
            lastReadingID: routeReadings.last?.id,
            firstReadingTimestamp: routeReadings.first?.timestamp,
            lastReadingTimestamp: routeReadings.last?.timestamp,
            liveRouteUpdatedAt: model.liveRouteState.lastUpdatedAt
        )
    }

    private var routeReadingsSignature: TimelineRouteReadingSignature {
        TimelineRouteReadingSignature(
            count: routeReadings.count,
            firstID: routeReadings.first?.id,
            lastID: routeReadings.last?.id,
            firstTimestamp: routeReadings.first?.timestamp,
            lastTimestamp: routeReadings.last?.timestamp
        )
    }

    private var explicitlySelectedTravel: TravelSegment? {
        guard playheadDate == nil, let travelID = activeSelection?.travelID else {
            return nil
        }
        return model.snapshot.travel.first { $0.id == travelID }
    }

    private var selectedSegmentIDs: Set<UUID> {
        guard let selection = activeSelection, selection.isRoute else {
            return Set(routeSegments.map(\.id))
        }
        return Set(routeSegments.filter {
            $0.span.intersection(with: selection.span) != nil
        }.map(\.id))
    }

    private var selectedSegment: TravelSegment? {
        guard let selection = activeSelection, selection.isRoute else { return nil }
        return routeSegments.first {
            $0.span.intersection(with: selection.span) != nil
        }
    }

    private var routeMapHeight: CGFloat { 216 }

    /// 지도에 함께 깔 기간. 시간표가 보여 주는 기간과 같다.
    private var routeContextSpan: TimeSpan? {
        TimelineRouteDisplayPolicy.contextSpan(
            for: model.selectedScale.timelineLevel,
            visibleSpan: TimelineAggregationEngine().interval(
                for: model.selectedScale.timelineLevel,
                containing: model.selectedDate
            )
        )
    }

    private var contextRouteSegments: [TravelSegment] {
        guard let span = routeContextSpan else { return [] }
        return routePresentationCache.contextSegments(
            for: routePresentationCacheKey,
            span: span
        ) {
            TimelineRouteDisplayPolicy.contextSegments(
                from: model.snapshot.travel,
                intersecting: span
            )
        }
    }

    private var dimmedRouteSegments: [TravelSegment] {
        guard !contextRouteSegments.isEmpty else { return [] }
        let highlighted = Set(routeSegments.map(\.id))
        return contextRouteSegments.filter { !highlighted.contains($0.id) }
    }

    private var hasDimmedRoutes: Bool {
        !dimmedRouteSegments.isEmpty
    }

    private var routePeriodName: String? {
        guard routeContextSpan != nil else { return nil }
        switch model.selectedScale {
        case .day: return "하루"
        case .week: return "한 주"
        case .month: return "한 달"
        case .year: return nil
        }
    }

    /// 옅게 깔린 경로를 눌러도 그 구간이 고른 구간이 된다. 시간표 막대를
    /// 누른 것과 같은 선택을 만들어 올려 보내므로 선택 경로는 하나뿐이다.
    private func selectRouteSegment(near coordinate: CLLocationCoordinate2D) {
        guard let region = visibleMapRegion else { return }
        // 손가락 하나가 닿는 넓이를 지금 배율의 거리로 바꾼다.
        let metersPerPoint = region.span.latitudeDelta
            * 111_320
            / Double(max(1, routeMapHeight))
        let toleranceMeters = max(12, metersPerPoint * 22)
        var best: (segment: TravelSegment, distance: Double)?
        for segment in dimmedRouteSegments {
            let values = coordinates(for: segment)
            guard values.count >= 2,
                  let distance = RoutePolylineDecimator.distanceMeters(
                      from: coordinate,
                      to: values
                  ),
                  distance <= toleranceMeters else { continue }
            if best.map({ distance < $0.distance }) ?? true {
                best = (segment, distance)
            }
        }
        guard let picked = best?.segment else { return }
        onRouteSelection(
            TimelineSelection(
                title: timelineTravelModeName(picked.mode),
                span: picked.span,
                planID: nil,
                travelID: picked.id,
                recordNodeID: "automatic.travel.\(picked.id.uuidString)",
                isRoute: true,
                categoryID: "movement",
                categoryName: "이동"
            )
        )
    }

    private struct RouteLocationPin: Identifiable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let title: String
        let tint: Color
    }

    private var routeLocationPins: [RouteLocationPin] {
        if playheadDate != nil && routeSegments.isEmpty {
            return []
        }

        var pins: [RouteLocationPin] = []
        var usedPlaceIDs = Set<UUID>()
        var usedStationKeys = Set<String>()
        let values = selectedSegment == nil ? routeSegments : routeSegments.filter {
            selectedSegmentIDs.contains($0.id)
        }

        for segment in values {
            func appendIfValid(_ placeID: UUID?, segmentMode: TravelMode) {
                guard let placeID else { return }
                guard usedPlaceIDs.insert(placeID).inserted else { return }
                guard
                    let place = placeIndexCache.place(
                        id: placeID,
                        timelineRevision: model.timelineRevision,
                        places: model.snapshot.places
                    ),
                    let point = place.point,
                    isValidCoordinate(point) else { return }
                pins.append(
                    RouteLocationPin(
                        id: placeID.uuidString,
                        coordinate: CLLocationCoordinate2D(
                            latitude: point.latitude,
                            longitude: point.longitude
                        ),
                        title: place.displayName,
                        tint: routeColor(for: segmentMode)
                    )
                )
            }

            appendIfValid(segment.fromPlaceID, segmentMode: segment.mode)
            appendIfValid(segment.toPlaceID, segmentMode: segment.mode)

            if segment.mode == .subway, let route = segment.subwayRoute {
                for stop in route.stops {
                    guard let point = stop.coordinate,
                          isValidCoordinate(point),
                          usedStationKeys.insert(stop.stationName).inserted else {
                        continue
                    }
                    pins.append(
                        RouteLocationPin(
                            id: "\(segment.id)-station-\(stop.stationName)",
                            coordinate: CLLocationCoordinate2D(
                                latitude: point.latitude,
                                longitude: point.longitude
                            ),
                            title: "\(stop.stationName)역 · \(stop.lineName)",
                            tint: routeColor(for: segment.mode)
                        )
                    )
                }
            }
        }

        if pins.isEmpty {
            if !routeSegments.isEmpty {
                for segment in values {
                    let values = coordinates(for: segment)
                    if let first = values.first {
                        pins.append(
                            RouteLocationPin(
                                id: "\(segment.id)-start",
                                coordinate: first,
                                title: "\(routeModeName(segment.mode)) 시작",
                                tint: routeColor(for: segment.mode),
                            )
                        )
                    }
                    if let last = values.last {
                        pins.append(
                            RouteLocationPin(
                                id: "\(segment.id)-end",
                                coordinate: last,
                                title: "\(routeModeName(segment.mode)) 종료",
                                tint: routeColor(for: segment.mode),
                            )
                        )
                    }
                }
            } else if let first = fallbackRouteCoordinates.first {
                let last = fallbackRouteCoordinates.last ?? first
                pins.append(
                    RouteLocationPin(
                        id: "fallback-start",
                        coordinate: first,
                        title: "측정 시작",
                        tint: .tpTransitDark
                    )
                )
                if fallbackRouteCoordinates.count >= 2 {
                    pins.append(
                        RouteLocationPin(
                            id: "fallback-end",
                            coordinate: last,
                            title: "측정 종료",
                            tint: .tpPlaceDark
                        )
                    )
                }
                if fallbackRouteCoordinates.count == 1 {
                    pins.append(
                        RouteLocationPin(
                            id: "fallback-standby",
                            coordinate: CLLocationCoordinate2D(
                                latitude: first.latitude + 0.00002,
                                longitude: first.longitude + 0.00002
                            ),
                            title: "추정 이동 위치",
                            tint: .tpPlaceDark
                        )
                    )
                }
            }
        }

        // Outside timeline playback, the map is a live-location surface. Add
        // the current iPhone/Watch fix even when there is no travel segment so
        // the map remains available and has a concrete camera anchor.
        if playheadDate == nil,
           let coordinate = currentLocationCoordinate,
           !pins.contains(where: {
               CLLocation(
                   latitude: $0.coordinate.latitude,
                   longitude: $0.coordinate.longitude
               ).distance(
                   from: CLLocation(
                       latitude: coordinate.latitude,
                       longitude: coordinate.longitude
                   )
               ) < 8
           }) {
            pins.append(
                RouteLocationPin(
                    id: "current-location",
                    coordinate: coordinate,
                    title: "현재 위치",
                    tint: Color.tpNow
                )
            )
        }
        return pins
    }

    private var playheadRoutePin: RouteLocationPin? {
        guard let coordinate = playheadFocusCoordinate else { return nil }
        return RouteLocationPin(
            id: "playhead-focus",
            coordinate: coordinate,
            title: "현재 위치",
            tint: .tpNow
        )
    }

    private var allowsFallbackRoutePath: Bool {
        TimelineRouteDisplayPolicy.allowsFallbackPath(
            at: playheadDate,
            routeSegments: routeSegments
        ) || fallbackRouteCoordinates.count >= 2
    }

    private var shouldDrawFallbackRoutePath: Bool {
        guard allowsFallbackRoutePath,
              fallbackRouteCoordinates.count >= 2 else {
            return false
        }
        let segmentCoordinates = routeSegments.flatMap(coordinates(for:))
        return routeSegments.isEmpty || segmentCoordinates.count < 2
    }

    private var isPlayheadLocationOnly: Bool {
        playheadDate != nil
            && routeSegments.isEmpty
            && fallbackRouteCoordinates.count < 2
            && playheadRoutePin != nil
            && !hasDimmedRoutes
    }

    private var hasMapContent: Bool {
        playheadRoutePin != nil
            || !routeLocationPins.isEmpty
            || !displayedRouteCoordinates.isEmpty
            || hasDimmedRoutes
    }

    private var currentLocationCoordinate: CLLocationCoordinate2D? {
        let point = model.latestSensorReading?.point
            ?? model.liveRouteState.readings.last?.point
        guard let point, isValidCoordinate(point) else { return nil }
        return CLLocationCoordinate2D(
            latitude: point.latitude,
            longitude: point.longitude
        )
    }

    private var playheadFocusCoordinate: CLLocationCoordinate2D? {
        guard let playheadDate else { return nil }

        // A GPS fix is the moving source of truth during playback. PlaceStay
        // is only a coarse fallback for gaps in the archived sensor stream.
        let nearestReadingPoint = nearestRouteReadingPoint(
            to: playheadDate,
            inside: activeRouteSpan
        )
        if let point = nearestReadingPoint {
            return CLLocationCoordinate2D(
                latitude: point.latitude,
                longitude: point.longitude
            )
        }

        let place = placeIndexCache.containing(
            date: playheadDate,
            timelineRevision: model.timelineRevision,
            places: model.snapshot.places
        )
        if let place,
           let point = place.point,
           isValidCoordinate(point) {
            return CLLocationCoordinate2D(
                latitude: point.latitude,
                longitude: point.longitude
            )
        }

        return routeSegments
            .filter { $0.span.contains(playheadDate) }
            .compactMap { coordinates(for: $0).first }
            .first
    }

    private func nearestRouteReadingPoint(
        to date: Date,
        inside span: TimeSpan
    ) -> GeoPoint? {
        guard !routeReadings.isEmpty else { return nil }

        // sensorReadings(in:) returns chronological data. Restrict the
        // binary search to the active span, then walk outward from the
        // insertion point. This avoids a full filter/min scan of up to 4,000
        // live GPS samples on every 20 Hz playhead update.
        var lower = 0
        var upper = routeReadings.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if routeReadings[middle].timestamp < span.start {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        let firstInSpan = lower
        lower = firstInSpan
        upper = routeReadings.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if routeReadings[middle].timestamp <= span.end {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        let endInSpan = lower
        guard firstInSpan < endInSpan else { return nil }

        lower = firstInSpan
        upper = endInSpan
        while lower < upper {
            let middle = (lower + upper) / 2
            if routeReadings[middle].timestamp < date {
                lower = middle + 1
            } else {
                upper = middle
            }
        }

        var left = lower - 1
        var right = lower
        var bestDistance = TimeInterval.infinity
        var bestPoint: GeoPoint?
        while left >= firstInSpan || right < endInSpan {
            let leftDistance = left >= firstInSpan
                ? abs(routeReadings[left].timestamp.timeIntervalSince(date))
                : .infinity
            let rightDistance = right < endInSpan
                ? abs(routeReadings[right].timestamp.timeIntervalSince(date))
                : .infinity
            if min(leftDistance, rightDistance) > bestDistance {
                break
            }
            if leftDistance <= rightDistance, left >= firstInSpan {
                if let point = routeReadings[left].point,
                   isValidCoordinate(point),
                   leftDistance < bestDistance {
                    bestDistance = leftDistance
                    bestPoint = point
                }
                left -= 1
            } else if right < endInSpan {
                if let point = routeReadings[right].point,
                   isValidCoordinate(point),
                   rightDistance < bestDistance {
                    bestDistance = rightDistance
                    bestPoint = point
                }
                right += 1
            }
        }
        return bestPoint
    }

    private var fallbackRouteCoordinates: [CLLocationCoordinate2D] {
        routePresentationCache.fallbackCoordinates(
            for: routePresentationCacheKey,
            span: activeRouteSpan
        ) {
            buildFallbackRouteCoordinates(in: activeRouteSpan)
        }
    }

    private func buildFallbackRouteCoordinates(
        in span: TimeSpan
    ) -> [CLLocationCoordinate2D] {
        // Archived readings and the live merge are chronological. Avoid a
        // full sort whenever a new GPS fix invalidates the route cache.
        let readings = routeReadingSlice(in: span)
            .compactMap(\.point)
            .filter(isValidCoordinate)
        let precise = readings.filter {
            $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 50
        }
        return simplifiedRouteCoordinates(
            precise.count >= 2 ? precise : readings
        )
    }

    /// 기록은 시간 순서대로 쌓여 있다. 구간마다 전체를 훑는 대신 이진
    /// 탐색으로 잘라 낸다. 한 주치 기록에 이동 100개를 그려도 훑는 양이
    /// 기록 수에 비례해 늘지 않는다.
    private func routeReadingSlice(
        in span: TimeSpan
    ) -> ArraySlice<SensorReading> {
        guard !routeReadings.isEmpty else { return [] }
        let lower = firstReadingIndex { $0.timestamp >= span.start }
        let upper = firstReadingIndex { $0.timestamp > span.end }
        guard lower < upper else { return [] }
        return routeReadings[lower..<upper]
    }

    private func firstReadingIndex(
        where predicate: (SensorReading) -> Bool
    ) -> Int {
        var low = 0
        var high = routeReadings.count
        while low < high {
            let middle = (low + high) / 2
            if predicate(routeReadings[middle]) {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return low
    }

    private func simplifiedRouteCoordinates(
        _ points: [GeoPoint]
    ) -> [CLLocationCoordinate2D] {
        RoutePolylineDecimator.decimate(
            RoutePolylineDecimator.spaced(
                points.map {
                    CLLocationCoordinate2D(
                        latitude: $0.latitude,
                        longitude: $0.longitude
                    )
                }
            )
        )
    }

    private var displayedRouteCoordinates: [CLLocationCoordinate2D] {
        let segmentCoordinates = routeSegments.flatMap(coordinates(for:))
        if segmentCoordinates.count >= 2 {
            return segmentCoordinates
        }
        guard allowsFallbackRoutePath else { return [] }
        return fallbackRouteCoordinates
    }

    /// 그린 점이 아니라 실제로 받은 위치 수를 센다. 그리기 직전에 점을
    /// 줄이므로 폴리라인 점 수를 그대로 쓰면 20분 걸은 기록이 "GPS 2개"로
    /// 보인다.
    private var recordedRouteFixCount: Int {
        let recorded = routeReadingSlice(in: activeRouteSpan)
            .lazy
            .compactMap(\.point)
            .filter(isValidCoordinate)
            .count
        return max(recorded, displayedRouteCoordinates.count)
    }

    private var recordedRouteDistanceMeters: Double {
        if !routeSegments.isEmpty {
            return routeSegments.reduce(0) { $0 + $1.distanceMeters }
        }
        return zip(
            displayedRouteCoordinates,
            displayedRouteCoordinates.dropFirst()
        ).reduce(0) { result, pair in
            result + CLLocation(
                latitude: pair.0.latitude,
                longitude: pair.0.longitude
            ).distance(from: CLLocation(
                latitude: pair.1.latitude,
                longitude: pair.1.longitude
            ))
        }
    }

    private func routeModeName(_ mode: TravelMode) -> String {
        switch mode {
        case .walking:
            "걷기"
        case .running:
            "달리기"
        case .cycling:
            "자전거"
        case .bus:
            "버스"
        case .subway:
            "지하철"
        case .taxi:
            "택시"
        case .car:
            "자동차"
        case .train:
            "기차"
        case .airplane:
            "비행기"
        case .ship:
            "배"
        }
    }

    private func routeModeSystemImage(_ mode: TravelMode) -> String {
        switch mode {
        case .walking: "figure.walk"
        case .running: "figure.run"
        case .cycling: "bicycle"
        case .bus: "bus"
        case .subway: "tram"
        case .taxi: "car.side"
        case .car: "car"
        case .train: "train.side.front.car"
        case .airplane: "airplane"
        case .ship: "ferry"
        }
    }

    private func travelModeEditor(for travel: TravelSegment) -> some View {
        HStack(spacing: TaptionSpacing.regular) {
            Label(
                routeModeName(travel.mode),
                systemImage: routeModeSystemImage(travel.mode)
            )
            .font(.taption(size: 9, weight: .bold))
            .foregroundStyle(Color.tpInk)

            Text(
                "\(travel.span.start.formatted(date: .omitted, time: .shortened))–\(travel.span.end.formatted(date: .omitted, time: .shortened))"
            )
            .font(.taption(size: 8))
            .foregroundStyle(Color.tpSecondary)

            Spacer(minLength: 4)

            Menu {
                ForEach(TravelMode.allCases, id: \.self) { mode in
                    Button {
                        model.confirmTravel(travel.id, mode: mode)
                    } label: {
                        Label(
                            routeModeName(mode),
                            systemImage: routeModeSystemImage(mode)
                        )
                    }
                }
            } label: {
                Label("이동수단 변경", systemImage: "pencil")
                    .font(.taption(size: 8.5, weight: .bold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Color.tpPrimaryFill, in: Capsule())
            }
            .accessibilityLabel("이동수단 변경")
            .accessibilityValue(routeModeName(travel.mode))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.tpSurfaceCream, in: RoundedRectangle(cornerRadius: TaptionRadius.control))
        .overlay {
            RoundedRectangle(cornerRadius: TaptionRadius.control)
                .stroke(Color.tpLine, lineWidth: 0.7)
        }
    }

    private func isValidCoordinate(_ point: GeoPoint) -> Bool {
        guard point.latitude.isFinite, point.longitude.isFinite else { return false }
        return point.latitude >= -90 && point.latitude <= 90 &&
            point.longitude >= -180 && point.longitude <= 180 &&
            !(point.latitude == 0 && point.longitude == 0)
    }

    private func routeCoordinates(
        for segment: TravelSegment,
        includeImprecise: Bool
    ) -> [CLLocationCoordinate2D] {
        var points: [GeoPoint] = []
        if let from = segment.fromPlaceID,
           let point = placeIndexCache.place(
               id: from,
               timelineRevision: model.timelineRevision,
               places: model.snapshot.places
           )?.point,
           isValidCoordinate(point) {
            points.append(point)
        }
        let readings = routeReadingSlice(in: segment.span)
            .compactMap(\.point)
            .filter(isValidCoordinate)
        let preferredReadings = includeImprecise
            ? readings
            : readings.filter {
                $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 50
            }

        if preferredReadings.count >= 2 || includeImprecise {
            points.append(contentsOf: preferredReadings)
        } else if let first = readings.first {
            points.append(first)
        }

        if let to = segment.toPlaceID,
           let point = placeIndexCache.place(
               id: to,
               timelineRevision: model.timelineRevision,
               places: model.snapshot.places
           )?.point,
           isValidCoordinate(point) {
            points.append(point)
        }

        return simplifiedRouteCoordinates(points)
    }

    private func coordinates(for segment: TravelSegment) -> [CLLocationCoordinate2D] {
        routePresentationCache.coordinates(
            for: routePresentationCacheKey,
            segmentID: segment.id,
            includeImprecise: false
        ) {
            buildCoordinates(for: segment, includeImprecise: false)
        }
    }

    private func buildCoordinates(
        for segment: TravelSegment,
        includeImprecise: Bool
    ) -> [CLLocationCoordinate2D] {
        if segment.mode == .subway,
           let route = segment.subwayRoute {
            let routePoints = route.coordinates.filter(isValidCoordinate)
            if routePoints.count >= 2 {
                return simplifiedRouteCoordinates(routePoints)
            }
        }
        var values = routeCoordinates(
            for: segment,
            includeImprecise: includeImprecise
        )
        if !includeImprecise && (values.isEmpty || values.count == 1) {
            let fallback = routeCoordinates(for: segment, includeImprecise: true)
            if fallback.count >= 2 {
                return fallback
            }
            if fallback.count == 1 {
                values = fallback
            }
        }
        return values
    }

    private func routeColor(for mode: TravelMode) -> Color {
        switch mode {
        case .walking, .running: .tpHealthDark
        case .cycling: .tpTransitDark
        case .bus, .subway, .train: .tpProjectDark
        case .taxi, .car: .tpInk
        case .airplane, .ship: .tpPlaceDark
        }
    }

    private func detailTravelColor(_ travel: TravelSegment) -> Color {
        isWorkoutWalking(travel)
            ? RecordTimelinePalette.categoryColor("exercise")
            : routeColor(for: travel.mode)
    }

    private func detailTravelTitle(_ travel: TravelSegment) -> String {
        let kind = isWorkoutWalking(travel) ? "운동 기록" : "알고리즘 결과"
        return "\(kind) · \(timelineTravelModeName(travel.mode))"
    }

    private func isWorkoutWalking(_ travel: TravelSegment) -> Bool {
        TravelSegmentPresentationEngine.isWorkoutWalking(
            travel,
            actuals: model.snapshot.actuals
        )
    }

    private func fitMapToRoutes(force: Bool = false) {
        // Live sensor callbacks can arrive more often than MapKit needs. A
        // 30 Hz idle budget and a lighter 15 Hz playhead budget keep the
        // location-following map responsive without issuing duplicate region
        // transactions for every gesture sample; explicit selections still
        // bypass the throttle.
        let minimumInterval: TimeInterval = playheadDate == nil
            ? 1.0 / 30.0
            : 1.0 / 15.0
        guard mapFitGate.permits(
            force: force,
            minimumInterval: minimumInterval
        ) else {
            return
        }

        if playheadDate != nil, let focus = playheadFocusCoordinate {
            if let lastMapFocusCoordinate,
               CLLocation(
                   latitude: lastMapFocusCoordinate.latitude,
                   longitude: lastMapFocusCoordinate.longitude
               ).distance(
                   from: CLLocation(
                       latitude: focus.latitude,
                       longitude: focus.longitude
                   )
               ) < 5 {
                return
            }
            lastMapFocusCoordinate = focus
            mapPosition = .region(
                MKCoordinateRegion(
                    center: focus,
                    span: MKCoordinateSpan(
                        latitudeDelta: 0.004,
                        longitudeDelta: 0.004
                    )
                )
            )
            return
        }

        if playheadDate == nil,
           activeSelection?.isRoute == true,
           displayedRouteCoordinates.count >= 2 {
            lastMapFocusCoordinate = nil
            fitMap(to: displayedRouteCoordinates)
            return
        }

        // 고른 구간이 없으면 기간 전체가 이 카드의 주제다. 현재 위치를
        // 따라다니는 대신 기간 경로를 담는다. 좌표만으로 범위를 잡으므로
        // GPS가 들어와도 화면이 흔들리지 않는다.
        if playheadDate == nil, let region = periodRouteRegion() {
            lastMapFocusCoordinate = nil
            mapPosition = .region(region)
            return
        }

        // 그릴 경로가 아직 없을 때만 지도는 현재 위치를 따라간다.
        if playheadDate == nil, let focus = currentLocationCoordinate {
            if let lastMapFocusCoordinate,
               CLLocation(
                   latitude: lastMapFocusCoordinate.latitude,
                   longitude: lastMapFocusCoordinate.longitude
               ).distance(
                   from: CLLocation(
                       latitude: focus.latitude,
                       longitude: focus.longitude
                   )
               ) < 5 {
                return
            }
            lastMapFocusCoordinate = focus
            mapPosition = .region(
                MKCoordinateRegion(
                    center: focus,
                    span: MKCoordinateSpan(
                        latitudeDelta: 0.004,
                        longitudeDelta: 0.004
                    )
                )
            )
            return
        }

        // If playback has a timestamp but no coordinate yet, retain the last
        // camera rather than jumping to an unrelated route midpoint.
        if playheadDate != nil {
            return
        }

        lastMapFocusCoordinate = nil
        mapPosition = .automatic
    }

    private var resolvedRouteMapViewportSize: CGSize {
        guard routeMapViewportSize.width > 1,
              routeMapViewportSize.height > 1 else {
            return CGSize(width: 390, height: routeMapHeight)
        }
        return routeMapViewportSize
    }

    private func updateRouteMapViewportSize(_ size: CGSize) {
        guard size.width > 1,
              size.height > 1,
              abs(routeMapViewportSize.width - size.width) > 0.5
                || abs(routeMapViewportSize.height - size.height) > 0.5
        else { return }
        routeMapViewportSize = size
        fitMapToRoutes(force: true)
    }

    private func periodRouteRegion() -> MKCoordinateRegion? {
        RouteMapViewport.region(
            for: [displayedRouteCoordinates]
                + dimmedRouteSegments.map { coordinates(for: $0) },
            viewport: resolvedRouteMapViewportSize,
            padding: .timeline
        )
    }

    private func fitMap(to values: [CLLocationCoordinate2D]) {
        guard let region = RouteMapViewport.region(
            for: values,
            viewport: resolvedRouteMapViewportSize,
            padding: .timeline
        ) else { return }
        mapPosition = .region(region)
    }
}

/// 이 항목에 남아 있는 메모를 보여 주기만 한다. 입력은 시간표의 메모 줄
/// 하나로 모았다. 항목마다 입력칸을 두던 시절에는 메모를 남기려면 먼저 맞는
/// 줄과 기록을 찾아 눌러야 했고, 어떤 항목에서는 아예 열리지 않았다.
struct DetailMemoList: View {
    @Bindable var model: AppModel
    let selection: TimelineSelection?
    let section: TimelineDetailSection
    /// 이미 골라 둔 메모를 그대로 편다. 비워 두면 고른 항목에 달린 메모를
    /// 스스로 찾는다.
    var memos: [ActionMemo]?
    /// 누를 수 있는 목록인지. 메모 카드에서만 쓰고, 항목에 딸린 목록은
    /// 보여 주기만 한다.
    var onSelect: ((ActionMemo) -> Void)?

    var body: some View {
        let items = memos ?? savedMemos
        if items.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: TaptionSpacing.tight) {
                ForEach(items) { memo in
                    if let onSelect {
                        Button {
                            onSelect(memo)
                        } label: {
                            memoRow(memo)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            "\(memo.text) 메모 열기"
                        )
                    } else {
                        memoRow(memo)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                Color.tpBackground,
                in: RoundedRectangle(cornerRadius: TaptionRadius.small, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: TaptionRadius.small, style: .continuous)
                    .stroke(Color.tpLine.opacity(0.7), lineWidth: 0.5)
            }
            .accessibilityLabel(
                section == .memo ? "메모 목록" : "\(section.rawValue) 메모"
            )
        }
    }

    private func memoRow(_ memo: ActionMemo) -> some View {
        HStack(alignment: .top, spacing: TaptionSpacing.compact) {
            Image(systemName: TimelineRowKind.memo.systemImage)
                .font(.taption(size: 8, weight: .bold))
                .foregroundStyle(Color.tpSecondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(memo.text)
                    .font(.taption(size: 8.5))
                    .foregroundStyle(Color.tpInk)
                    .fixedSize(horizontal: false, vertical: true)
                Text(
                    memo.occurredAt.formatted(
                        date: .omitted,
                        time: .shortened
                    )
                )
                .font(.taption(size: 7))
                .foregroundStyle(Color.tpSecondary)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(
            Color.white.opacity(0.75),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
    }

    private var savedMemos: [ActionMemo] {
        guard let selection else {
            return []
        }
        if let targetID = selection.memoTargetID {
            let targetMemos = model.memos(forTargetID: targetID)
            // Keep old plan-only notes visible after migrating a plan to the
            // stable target key, without duplicating newly keyed entries.
            guard targetID.hasPrefix("plan."), let planID = selection.planID else {
                return targetMemos
            }
            return (targetMemos + model.memos(for: planID))
                .reduce(into: [UUID: ActionMemo]()) { result, memo in
                    result[memo.id] = memo
                }
                .values
                .sorted { $0.createdAt < $1.createdAt }
        }
        return model.memos(
            forCategoryID: selection.categoryID,
            on: selection.span.start
        )
    }
}

struct PhotoAssetThumbnail: View {
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
                        .accessibilityHidden(true)
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
