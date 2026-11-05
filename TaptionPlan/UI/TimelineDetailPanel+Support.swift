import SwiftUI
import UIKit
import MapKit

extension TimelineDetailPanel {
    var maximumPanelHeight: CGFloat {
        max(detailPanelCollapsedHeight, maxHeight)
    }

    var panelResizeHandle: some View {
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

    var detailContextTitle: some View {
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

    var detailContextTimeLabel: String {
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
    var selectedPlanForDetail: PlanRecord? {
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

    var selectedRoutineForDetail: PlanRecord? {
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

    var focusedRoutineForDetail: PlanRecord? {
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

    func focusedRoutineSort(
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
    var activeSelection: TimelineSelection? {
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

    func effectiveRepeatRules(
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

    var routeContent: some View {
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

    var trackingControls: some View {
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

    var closestAirQuality: AirQualityContext? {
        model.snapshot.weather
            .compactMap { weather in
                weather.airQuality.map { (weather.observedAt, $0) }
            }
            .min {
                abs($0.0.timeIntervalSince(playheadDate ?? .now))
                    < abs($1.0.timeIntervalSince(playheadDate ?? .now))
            }?.1
    }

    var locationContent: some View {
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

    var movementContent: some View {
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
    func automaticNodeLinkControl(for categoryID: String) -> some View {
        if !TaptionProductScope.automaticLoggingOnly,
           let selection = activeSelection,
           selection.categoryID == categoryID,
           selection.actualID == nil,
           selection.recordNodeID != nil {
            recordLinkControl(selection)
        }
    }

    var sleepContent: some View {
        automaticRecordsContent(
            title: "수면",
            systemImage: "moon.zzz",
            plans: detailSleepPlans,
            actuals: detailSleepActuals,
            tint: Color.tpSleepDark
        )
    }

    var activityContent: some View {
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
    var appUsageContent: some View {
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

    var weatherContent: some View {
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
                            "\(weather.condition) · \(AppRegion.current.temperature(celsius: weather.temperatureCelsius))°"
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
    var memoContent: some View {
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

    func weatherMeasurementLocation(
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

    var routineContent: some View {
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

    func automaticRecordsContent(
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

    func actualDetailSubtitle(_ actual: ActualRecord) -> String {
        let span = "\(TaptionActivityEngineAdapter.trustLabel(for: actual)) · \(actual.startedAt.formatted(date: .omitted, time: .shortened))–\((actual.endedAt ?? .now).formatted(date: .omitted, time: .shortened))"
        let source = actualSourceLabel(actual.source)
        let origin = actual.sourceKind.rawValue
        guard let behavior = actual.behavior
            .flatMap({ WatchBehaviorKind(rawValue: $0) }) else {
            return "\(span) · \(origin) · \(source)"
        }
        return "\(span) · \(origin) · \(source) · \(behavior.title)"
    }

    var actionContent: some View {
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

    func routineLinkControl(for action: PlanRecord) -> some View {
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

    func routineForAction(_ action: PlanRecord) -> PlanRecord? {
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

    func routineDisplayTitle(_ routine: PlanRecord) -> String {
        GoalRecordPolicy.displayTitle(routine.title)
            .replacingOccurrences(of: GoalRecordPolicy.currentPrefix, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func actualGoalLinkControl(_ actual: ActualRecord) -> some View {
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

    func recordLinkControl(_ selection: TimelineSelection) -> some View {
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
}
