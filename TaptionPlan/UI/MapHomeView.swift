import CoreLocation
import MapKit
import SwiftUI

struct MapHomeView: View {
    @Bindable private var model: AppModel

    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var isMenuOpen = false
    @State private var isCalendarPresented = false
    @State private var isHomeLocationPresented = false
    @State private var isMutedMap = true
    @State private var selectedScope: TimeScale = .day
    @State private var selectedTimelineMinute: Int?
    @State private var sectionEditSelection: MapHomeSectionEditSelection?
    @State private var isMapCenteredOnUser = false
    @State private var hasAppliedInitialLocation = false

    private static let userCenterTolerance: CLLocationDistance = 120

    private enum Layout {
        static let horizontalInset: CGFloat = 10
        static let headerVisibleHeight: CGFloat = 46
        static let headerHitTarget: CGFloat = 44
        static let headerIcon: CGFloat = 19
        static let mapControlSize: CGFloat = 44
        static let mapControlIcon: CGFloat = 15
        static let timeRailWidth: CGFloat = 58
        static let timeRailTopMargin: CGFloat = 18
        static let timeRailBottomMargin: CGFloat = 28
    }

    init(model: AppModel) {
        self._model = Bindable(model)
        _selectedScope = State(initialValue: .day)
    }

    var body: some View {
        ZStack(alignment: .top) {
            map
                .ignoresSafeArea()

            VStack(spacing: 12) {
                header
                Spacer()
            }
            .padding(.horizontal, Layout.horizontalInset)
            // The container already starts below the status-bar safe area; keep
            // only a minimal breathing room so the top bar stays high on screen.
            .padding(.top, 2)

            currentTimeRail
                .padding(.top, Layout.headerVisibleHeight + Layout.timeRailTopMargin)
                .padding(.bottom, Layout.timeRailBottomMargin)
                .padding(.trailing, Layout.horizontalInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)

            mapControls
                .padding(.leading, Layout.horizontalInset)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

            if isMenuOpen {
                menu
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        .preferredColorScheme(.light)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MapHomeBannerAdView()
        }
        .sheet(isPresented: $isCalendarPresented) {
            MapHomeCalendarSheet(
                selectedDate: $model.selectedDate,
                holidayName: { date in
                    TimelineAxisGrid.koreanHolidayName(on: date)
                }
            )
        }
        .sheet(isPresented: $isHomeLocationPresented) {
            MapHomeLocationSheet(model: model) {
                mapPosition = .automatic
                focusMapIfNeeded()
            }
                .presentationDetents([.height(260)])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $sectionEditSelection) { selection in
            MapHomeSectionEditSheet(selection: selection)
                .presentationDetents([.height(232)])
                .presentationDragIndicator(.visible)
        }
        .animation(.easeInOut(duration: 0.22), value: isMenuOpen)
        .task {
            focusMapIfNeeded()
            applyInitialLocationIfAvailable()
        }
        .onChange(of: model.latestSensorReading?.point) { _, _ in
            applyInitialLocationIfAvailable()
        }
        .onChange(of: model.settings.frequentPlaces) { _, _ in
            focusMapIfNeeded()
        }
        .onChange(of: model.selectedDate) { _, _ in
            if selectedTimelineMinute != nil {
                selectedTimelineMinute = nil
            }
            mapPosition = .automatic
            focusMapIfNeeded()
        }
    }

    @ViewBuilder
    private var map: some View {
        Map(position: $mapPosition, interactionModes: [.pan, .zoom, .rotate]) {
            ForEach(subwayRouteOverlays) { overlay in
                // A warm halo keeps the route readable over both the muted
                // and realistic Apple map styles without changing geometry.
                MapPolyline(coordinates: overlay.coordinates)
                    .stroke(
                        Color.tpReferenceGold.opacity(0.50),
                        style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round)
                    )
                MapPolyline(coordinates: overlay.coordinates)
                    .stroke(
                        Color.tpReferenceMint.opacity(0.92),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                    )
            }

            ForEach(homeAnnotations) { place in
                Annotation("", coordinate: place.coordinate, anchor: .bottom) {
                    MapHomePlacePin(name: place.name, floor: place.floor)
                }
            }

        }
        .mapStyle(mapStyle)
        .onMapCameraChange(frequency: .onEnd) { context in
            updateUserCenterState(for: context.region.center)
        }
        .overlay {
            MapHomeFairyAtmosphere()
                .allowsHitTesting(false)
        }
    }

    private var mapStyle: MapStyle {
        if isMutedMap {
            .standard(
                elevation: .flat,
                emphasis: .muted,
                pointsOfInterest: .excludingAll,
                showsTraffic: false
            )
        } else {
            .standard(elevation: .realistic)
        }
    }

    private var header: some View {
        HStack(spacing: 3) {
            Button {
                isMenuOpen.toggle()
            } label: {
                    Image(systemName: isMenuOpen ? "xmark" : "line.3.horizontal")
                        .font(.system(size: Layout.headerIcon, weight: .medium))
                    .frame(width: 42, height: Layout.headerHitTarget)
            }
            .accessibilityLabel(isMenuOpen ? "메뉴 닫기" : "메뉴 열기")

            headerDateButton("chevron.backward.2", amount: -7)
            headerDateButton("chevron.left", amount: -1)

            Button {
                model.selectedDate = Date()
            } label: {
                dateTitleLabel
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("오늘 날짜로 이동, \(dateTitle)")

            headerDateButton("chevron.right", amount: 1)
            headerDateButton("chevron.forward.2", amount: 7)

            Button {
                isCalendarPresented = true
            } label: {
                MapHomeCalendarGlyph(date: model.selectedDate)
                    .frame(width: 42, height: Layout.headerHitTarget)
            }
            .accessibilityLabel("날짜 선택")
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 7)
        .frame(height: Layout.headerVisibleHeight)
        .background(Color.tpSurface.opacity(0.96), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.tpLine.opacity(0.78), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.07), radius: 9, y: 3)
    }

    private func headerDateButton(_ icon: String, amount: Int) -> some View {
        Button {
            moveDate(by: amount)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 31, height: Layout.headerHitTarget)
        }
        .accessibilityLabel(amount < 0 ? "이전 날짜" : "다음 날짜")
    }

    private var currentTimeRail: some View {
        GeometryReader { proxy in
            let railHeight = min(680, max(500, proxy.size.height))
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                let minute = selectedTimelineMinute ?? minuteOfDay(for: timeline.date)
                MapHomeTimeSidebar(
                    date: model.selectedDate,
                    selectedMinute: Binding(
                        get: { selectedTimelineMinute ?? minuteOfDay(for: timeline.date) },
                        set: { minute in
                            guard selectedTimelineMinute != minute else { return }
                            selectedTimelineMinute = minute
                        }
                    ),
                    activity: currentActivity(at: minute),
                    railWidth: Layout.timeRailWidth,
                    onSectionEdit: {
                        sectionEditSelection = MapHomeSectionEditSelection(
                            date: model.selectedDate,
                            minute: minute,
                            activity: currentActivity(at: minute)
                        )
                    }
                )
                .frame(width: Layout.timeRailWidth, height: railHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
        }
    }

    private var mapControls: some View {
        VStack(spacing: 9) {
            Button {
                focusUserLocation()
            } label: {
                MapHomeLocationButtonIcon(
                    isCentered: isMapCenteredOnUser,
                    hasLocation: currentCoordinate != nil
                )
                    .frame(width: Layout.mapControlSize, height: Layout.mapControlSize)
                    .background(Color.white.opacity(0.94), in: Circle())
            }
            .accessibilityLabel("현재 위치")

            Button {
                mapPosition = .userLocation(followsHeading: true, fallback: .automatic)
            } label: {
                Image(systemName: "location.north.line.fill")
                    .font(.system(size: Layout.mapControlIcon, weight: .bold))
                    .foregroundStyle(Color.tpReferenceRose)
                    .frame(width: Layout.mapControlSize, height: Layout.mapControlSize)
                    .background(Color.white.opacity(0.94), in: Circle())
            }
            .accessibilityLabel("나침반")

            Button {
                isMutedMap.toggle()
            } label: {
                Image(systemName: isMutedMap ? "paintpalette" : "paintpalette.fill")
                    .font(.system(size: Layout.mapControlIcon, weight: .bold))
                    .foregroundStyle(Color.tpReferenceMint)
                    .frame(width: Layout.mapControlSize, height: Layout.mapControlSize)
                    .background(Color.white.opacity(0.94), in: Circle())
            }
            .accessibilityLabel("지도 스타일")
        }
    }

    private var menu: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.18)
                    .ignoresSafeArea(edges: .top)
                    .onTapGesture { isMenuOpen = false }

                sidebarContent
                .frame(width: 316, height: proxy.size.height, alignment: .top)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .ignoresSafeArea(edges: .top)
                .shadow(color: Color.black.opacity(0.18), radius: 22, x: 8, y: 0)
            }
        }
    }

    private var sidebarContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image("MapHomeNotionMascot")
                    .resizable()
                    .scaledToFit()
                    .saturation(0.78)
                    .frame(width: 48, height: 44)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("오늘의 지도")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                    Text("자동으로 남은 하루의 기록")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { isMenuOpen = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 40, height: 40)
                        .background(Color.black.opacity(0.06), in: Circle())
                }
            }
            .padding(.bottom, 27)

            menuItem("map", "지도 홈", isSelected: true) {
                isMenuOpen = false
            }

            homeLocationMenuItem

            Spacer()

            HStack(spacing: 7) {
                Image(systemName: "map.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.tpReferenceBlue)
                Text(currentCoordinate == nil ? "위치 기록을 기다리는 중" : "현재 위치 기록 중")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 60)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var homeLocationMenuItem: some View {
        Button {
            isHomeLocationPresented = true
        } label: {
            HStack(spacing: 13) {
                Image(systemName: "house.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text("집 위치")
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                    if let home = homePlace, home.point != nil {
                        Text("설정됨 · Lv.\(home.floor ?? 1)")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.tpReferenceMint)
                    } else {
                        Text("현재 위치로 설정")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(Color.primary)
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .background(Color.tpReferenceMint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("집 위치 설정")
    }

    private var homePlace: FrequentPlace? {
        model.settings.frequentPlaces.first { $0.kind == .home }
    }

    @ViewBuilder
    private func menuItem(_ icon: String, _ title: String, isSelected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 16, weight: isSelected ? .bold : .medium, design: .rounded))
                Spacer()
                if isSelected { Circle().fill(Color.blue).frame(width: 6, height: 6) }
            }
            .foregroundStyle(isSelected ? Color.tpReferenceBlue : Color.primary)
            .padding(.vertical, 15)
            .padding(.horizontal, 12)
            .background(isSelected ? Color.tpReferenceBlue.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var homeAnnotations: [MapHomePlaceAnnotation] {
        model.settings.frequentPlaces.compactMap { place in
            guard place.kind == .home,
                  let point = place.point,
                  isValid(point) else { return nil }
            return MapHomePlaceAnnotation(
                id: place.id,
                name: place.name,
                floor: place.floor,
                coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
            )
        }
    }

    private var currentCoordinate: CLLocationCoordinate2D? {
        let point = model.latestSensorReading?.point ?? model.liveRouteState.readings.last?.point
        guard let point, isValid(point) else { return nil }
        return CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
    }

    private func currentActivity(at minute: Int) -> MapHomeTimeSidebarActivity {
        let calendar = Calendar.autoupdatingCurrent
        let moment = calendar.startOfDay(for: model.selectedDate)
            .addingTimeInterval(TimeInterval(minute * 60))
        guard let actual = model.snapshot.actuals
            .filter({
                $0.startedAt <= moment
                    && ($0.endedAt ?? .distantFuture) >= moment
            })
            .max(by: { $0.startedAt < $1.startedAt }) else {
            return MapHomeTimeSidebarActivity(
                systemImage: "sparkles",
                tint: .tpReferenceMint,
                accessibilityLabel: "활동 없음"
            )
        }

        let categoryID = RecordAnalysisCategoryPolicy.categoryID(for: actual)
        let category = model.snapshot.categories.first { $0.id == categoryID }
            ?? model.snapshot.categories.first { $0.id == actual.categoryID }
        return MapHomeTimeSidebarActivity(
            systemImage: categoryID == "movement"
                ? MovementPresentation.symbol(for: actual)
                : category.map { $0.icon.systemImage } ?? "sparkles",
            tint: Color(hex: category?.darkHex ?? "#48B38C"),
            accessibilityLabel: actual.title
        )
    }

    /// Show the persisted, station-to-station subway path on the map.  The
    /// route is derived from the classified segment, not from a straight line
    /// between the home and office pins, so transfers remain visible.
    private var subwayRouteOverlays: [MapHomeSubwayRouteOverlay] {
        let calendar = Calendar.autoupdatingCurrent
        guard let dayStart = calendar.startOfDay(for: model.selectedDate) as Date?,
              let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
        else { return [] }
        let day = TimeSpan(start: dayStart, end: dayEnd)
        return model.snapshot.travel.compactMap { segment in
            guard segment.mode == .subway,
                  segment.span.intersection(with: day) != nil,
                  let route = segment.subwayRoute,
                  SubwayStationCatalog.isValid(route) else { return nil }
            let coordinates = route.coordinates.compactMap { point -> CLLocationCoordinate2D? in
                guard isValid(point) else { return nil }
                return CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
            }
            guard coordinates.count >= 2 else { return nil }
            return MapHomeSubwayRouteOverlay(id: segment.id, coordinates: coordinates)
        }
    }

    private var dateTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = selectedScope == .day ? "M월 d일 EEEE" : "yyyy년 M월"
        return formatter.string(from: model.selectedDate)
    }

    private var dateTitleLabel: Text {
        let calendar = Calendar.autoupdatingCurrent
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "ko_KR")
        dateFormatter.dateFormat = "M월 d일"
        let weekdayFormatter = DateFormatter()
        weekdayFormatter.locale = Locale(identifier: "ko_KR")
        weekdayFormatter.dateFormat = "EEEE"
        let weekday = calendar.component(.weekday, from: model.selectedDate)
        let weekdayText = Text(" \(weekdayFormatter.string(from: model.selectedDate))")
            .font(.system(size: weekday == 7 ? 17 : 19, weight: .semibold, design: .rounded))
            .foregroundStyle(weekday == 1 ? Color.tpHoliday : weekday == 7 ? Color.tpSaturday : ink)
        return Text(dateFormatter.string(from: model.selectedDate))
            .font(.system(size: weekday == 7 ? 17 : 19, weight: .semibold, design: .rounded))
            .foregroundStyle(ink) + weekdayText
    }

    private var ink: Color {
        .tpInk
    }

    private func minuteOfDay(for date: Date) -> Int {
        let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute, .second], from: date)
        return min(1_439, max(0, (components.hour ?? 0) * 60 + (components.minute ?? 0)))
    }

    private func moveDate(by amount: Int) {
        let component: Calendar.Component = switch selectedScope {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
        if let date = Calendar.autoupdatingCurrent.date(byAdding: component, value: amount, to: model.selectedDate) {
            model.selectedDate = date
        }
    }

    private func focusMapIfNeeded() {
        let coordinates = homeAnnotations.map(\.coordinate)
            + subwayRouteOverlays.flatMap(\.coordinates)
            + (currentCoordinate.map { [$0] } ?? [])
        guard let first = coordinates.first else {
            mapPosition = .automatic
            return
        }
        guard case .automatic = mapPosition else { return }
        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        let latitudeDelta = max(0.025, ((latitudes.max() ?? first.latitude) - (latitudes.min() ?? first.latitude)) * 1.8)
        let longitudeDelta = max(0.035, ((longitudes.max() ?? first.longitude) - (longitudes.min() ?? first.longitude)) * 1.8)
        mapPosition = .region(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: ((latitudes.max() ?? first.latitude) + (latitudes.min() ?? first.latitude)) / 2,
                    longitude: ((longitudes.max() ?? first.longitude) + (longitudes.min() ?? first.longitude)) / 2
                ),
                span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
            )
        )
    }

    private func focusUserLocation() {
        guard let coordinate = currentCoordinate else {
            isMapCenteredOnUser = false
            mapPosition = .automatic
            return
        }

        mapPosition = .region(
            MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.010)
            )
        )
        updateUserCenterState(for: coordinate)
    }

    private func applyInitialLocationIfAvailable() {
        guard !hasAppliedInitialLocation, currentCoordinate != nil else { return }
        focusUserLocation()
        hasAppliedInitialLocation = true
    }

    private func updateUserCenterState(for center: CLLocationCoordinate2D) {
        let nextValue: Bool
        if let coordinate = currentCoordinate {
            nextValue = CLLocation(latitude: center.latitude, longitude: center.longitude)
                .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
                <= Self.userCenterTolerance
        } else {
            nextValue = false
        }
        guard isMapCenteredOnUser != nextValue else { return }
        isMapCenteredOnUser = nextValue
    }

    private func isValid(_ point: GeoPoint) -> Bool {
        (-90...90).contains(point.latitude)
            && (-180...180).contains(point.longitude)
            && point.horizontalAccuracy >= 0
    }
}

private struct MapHomeSectionEditSelection: Identifiable {
    let date: Date
    let minute: Int
    let activity: MapHomeTimeSidebarActivity

    var id: String {
        "\(date.timeIntervalSinceReferenceDate)-\(minute)"
    }
}

private struct MapHomeSectionEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let selection: MapHomeSectionEditSelection

    private var timeText: String {
        String(format: "%02d:%02d", selection.minute / 60, selection.minute % 60)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("섹션 편집")
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                Spacer()
                Button("닫기") { dismiss() }
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }

            HStack(spacing: 10) {
                Image(systemName: selection.activity.systemImage)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(selection.activity.tint)
                    .frame(width: 38, height: 38)
                    .background(
                        selection.activity.tint.opacity(0.13),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(selection.activity.accessibilityLabel)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text("선택 시각 \(timeText)")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(
                Color.tpSurface,
                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )

            Text("오른쪽 핸들을 위·아래로 끌어 선택 시각을 바꿀 수 있습니다.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 22)
    }
}

private struct MapHomeLocationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let onSaved: () -> Void

    private var home: FrequentPlace? {
        model.settings.frequentPlaces.first { $0.kind == .home }
    }

    private var hasCurrentLocation: Bool {
        model.latestSensorReading?.point != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "house.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.tpReferenceMint)
                    .frame(width: 42, height: 42)
                    .background(Color.tpReferenceMint.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("집 위치 설정")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    if let home, home.point != nil {
                        Text("현재 저장 상태 · Lv.\(home.floor ?? 1)")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("집 장소를 찾을 수 없습니다")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            Text(
                hasCurrentLocation
                    ? "현재 위치를 집의 기준 위치로 저장합니다. 좌표는 화면에 표시하지 않습니다."
                    : "현재 위치를 받는 중입니다. 위치 기록이 잡히면 저장할 수 있습니다."
            )
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            Button {
                guard let home else { return }
                model.setFrequentPlaceToCurrentLocation(home.id)
                onSaved()
                dismiss()
            } label: {
                Label(
                    home?.point == nil ? "현재 위치로 저장" : "현재 위치로 다시 저장",
                    systemImage: "location.fill"
                )
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(.white)
                .background(Color.tpReferenceMint, in: RoundedRectangle(cornerRadius: 13))
            }
            .buttonStyle(.plain)
            .disabled(home == nil || !hasCurrentLocation)
            .opacity(home == nil || !hasCurrentLocation ? 0.46 : 1)
        }
        .padding(22)
        .background(Color.tpSurface)
    }
}

private struct MapHomeSubwayRouteOverlay: Identifiable {
    let id: UUID
    let coordinates: [CLLocationCoordinate2D]
}

private struct MapHomePlaceAnnotation: Identifiable {
    let id: UUID
    let name: String
    let floor: Int?
    let coordinate: CLLocationCoordinate2D
}

private struct MapHomePlacePin: View {
    let name: String
    let floor: Int?

    var body: some View {
        VStack(spacing: 5) {
            MapHomeMarkerLabel(title: name, color: Color(red: 0.12, green: 0.15, blue: 0.24))

            Image("MapHomeHouseMarker")
                .resizable()
                .scaledToFit()
                .frame(width: 60, height: 60)

            Text("Lv.\(floor ?? 1)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color.tpReferenceGold)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.white, in: Capsule())
                .shadow(color: .black.opacity(0.10), radius: 5, y: 2)
        }
        .accessibilityLabel("\(name), 레벨 \(floor ?? 1)")
    }
}

private struct MapHomeLocationButtonIcon: View {
    let isCentered: Bool
    let hasLocation: Bool

    private let targetColor = Color(red: 0.20, green: 0.48, blue: 0.78)
    private let dotColor = Color(red: 0.92, green: 0.25, blue: 0.28)

    var body: some View {
        ZStack {
            Image(systemName: "scope")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(targetColor)

            if isCentered && hasLocation {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                    .overlay {
                        Circle()
                            .stroke(.white, lineWidth: 1.2)
                    }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct MapHomeMarkerLabel: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(.white, in: Capsule())
            .shadow(color: .black.opacity(0.10), radius: 6, y: 3)
    }
}

/// A restrained pastel wash gives the native map a storybook tone while
/// leaving Apple map labels, roads, and gestures intact.  This is deliberately
/// a view-layer treatment: no custom tile dependency or coordinate transform
/// is involved, so location accuracy and map performance remain native.
private struct MapHomeFairyAtmosphere: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.tpReferenceBlue.opacity(0.13),
                    Color.white.opacity(0.02),
                    Color.tpReferenceBlush.opacity(0.14)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.white.opacity(0.10))
                .frame(width: 210, height: 210)
                .blur(radius: 28)
                .offset(x: -150, y: -210)

            Circle()
                .fill(Color.tpReferenceGold.opacity(0.08))
                .frame(width: 270, height: 270)
                .blur(radius: 34)
                .offset(x: 170, y: 240)
        }
        .blendMode(.softLight)
        .opacity(0.72)
    }
}

enum MapHomeCalendarDayStyle: Equatable {
    case weekday
    case saturday
    case holiday

    init(date: Date, calendar: Calendar = .autoupdatingCurrent) {
        let calendar = TimelineAxisGrid.normalizedCalendar(calendar)
        let weekday = calendar.component(.weekday, from: date)
        if weekday == 1 {
            self = .holiday
        } else if weekday == 7 {
            self = .saturday
        } else if TimelineAxisGrid.koreanHolidayName(on: date, calendar: calendar) != nil {
            self = .holiday
        } else {
            self = .weekday
        }
    }
}

private struct MapHomeCalendarGlyph: View {
    let date: Date

    private var calendar: Calendar {
        TimelineAxisGrid.normalizedCalendar()
    }

    private var day: String {
        String(calendar.component(.day, from: date))
    }

    private var style: MapHomeCalendarDayStyle {
        MapHomeCalendarDayStyle(date: date, calendar: calendar)
    }

    private var tint: Color {
        switch style {
        case .weekday: .tpInk
        case .saturday: .tpSaturday
        case .holiday: .tpHoliday
        }
    }

    var body: some View {
        let symbol: String = switch style {
        case .weekday: calendar.isDateInToday(date) ? "calendar.badge.clock" : "calendar"
        case .saturday: "calendar.badge.plus"
        case .holiday: "calendar.badge.exclamationmark"
        }
        ZStack(alignment: .top) {
            Image(systemName: symbol)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(tint)

            Text(day)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .padding(.top, 7)
        }
        .frame(width: 24, height: 25)
        .accessibilityLabel("\(day)일 달력")
    }
}
