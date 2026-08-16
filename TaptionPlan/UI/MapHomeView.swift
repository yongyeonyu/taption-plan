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
    @AppStorage("taption.mapHome.language") private var languageRawValue = MapHomeLanguage.korean.rawValue
    @State private var isCompassVisible = false
    @State private var isGPSLoggingActionInFlight = false
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

    private var language: MapHomeLanguage {
        MapHomeLanguage(rawValue: languageRawValue) ?? .korean
    }

    var body: some View {
        ZStack(alignment: .top) {
            map
                .ignoresSafeArea()

            // Keep the time rail and its trailing breathing room outside the
            // map's gesture arena.  The rail itself is rendered above this
            // shield, so its controls remain tappable.
            trailingMapGestureShield

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
                },
                language: language
            )
        }
        .sheet(isPresented: $isHomeLocationPresented) {
            MapHomeLocationSheet(model: model, language: language) {
                mapPosition = .automatic
                focusMapIfNeeded()
            }
                .presentationDetents([.height(260)])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $sectionEditSelection) { selection in
            MapHomeSectionEditSheet(selection: selection, language: language)
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

            // Use MapKit's native location glyph so the marker follows the
            // system location source and heading behavior automatically.
            UserAnnotation()

        }
        .mapStyle(mapStyle)
        .mapControls {
            if isCompassVisible {
                MapCompass()
                    .mapControlVisibility(.visible)
            }
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            updateUserCenterState(for: context.region.center)
        }
        .overlay {
            MapHomeFairyAtmosphere()
                .allowsHitTesting(false)
        }
    }

    private var trailingMapGestureShield: some View {
        GeometryReader { proxy in
            let protectedTop = Layout.headerVisibleHeight + Layout.timeRailTopMargin
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .frame(
                    width: Layout.timeRailWidth + Layout.horizontalInset,
                    height: max(0, proxy.size.height - protectedTop)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .allowsHitTesting(true)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
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
            .accessibilityLabel(
                isMenuOpen
                    ? language.text("메뉴 닫기", "Close menu")
                    : language.text("메뉴 열기", "Open menu")
            )

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
            .accessibilityLabel(
                language.text("오늘 날짜로 이동", "Go to today") + ", \(dateTitle)"
            )

            headerDateButton("chevron.right", amount: 1)
            headerDateButton("chevron.forward.2", amount: 7)

            Button {
                isCalendarPresented = true
            } label: {
                MapHomeCalendarGlyph(date: model.selectedDate, language: language)
                    .frame(width: 42, height: Layout.headerHitTarget)
            }
            .accessibilityLabel(language.text("날짜 선택", "Choose date"))
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
        .accessibilityLabel(
            amount < 0
                ? language.text("이전 날짜", "Previous date")
                : language.text("다음 날짜", "Next date")
        )
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
            .accessibilityLabel(language.text("현재 위치", "Current location"))

            Button {
                if !isCompassVisible {
                    isCompassVisible = true
                }
                mapPosition = .userLocation(followsHeading: true, fallback: .automatic)
            } label: {
                Image(systemName: "location.north.line.fill")
                    .font(.system(size: Layout.mapControlIcon, weight: .bold))
                    .foregroundStyle(Color.tpReferenceRose)
                    .frame(width: Layout.mapControlSize, height: Layout.mapControlSize)
                    .background(Color.white.opacity(0.94), in: Circle())
            }
            .accessibilityLabel(language.text("나침반 표시", "Show compass"))

            Button {
                isMutedMap.toggle()
            } label: {
                Image(systemName: isMutedMap ? "paintpalette" : "paintpalette.fill")
                    .font(.system(size: Layout.mapControlIcon, weight: .bold))
                    .foregroundStyle(Color.tpReferenceMint)
                    .frame(width: Layout.mapControlSize, height: Layout.mapControlSize)
                    .background(Color.white.opacity(0.94), in: Circle())
            }
            .accessibilityLabel(language.text("지도 스타일", "Map style"))
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
                    Text(language.text("오늘의 지도", "Today's Map"))
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                    Text(language.text("자동으로 남은 하루의 기록", "Today's activity, automatically recorded"))
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

            menuItem("map", language.text("지도 홈", "Map Home"), isSelected: true) {
                isMenuOpen = false
            }

            homeLocationMenuItem
            gpsLoggingMenuItem
            languageMenuItem

            Spacer()

            HStack(spacing: 7) {
                Image(systemName: "map.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.tpReferenceBlue)
                Text(
                    currentCoordinate == nil
                        ? language.text("위치 기록을 기다리는 중", "Waiting for location")
                        : language.text("현재 위치 기록 중", "Recording current location")
                )
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
                    Text(language.text("집 위치", "Home location"))
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                    if let home = homePlace, home.point != nil {
                        Text(language.text("설정됨", "Set") + " · Lv.\(home.floor ?? 1)")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.tpReferenceMint)
                    } else {
                        Text(language.text("현재 위치로 설정", "Set from current location"))
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
        .accessibilityLabel(language.text("집 위치 설정", "Set home location"))
    }

    private var languageMenuItem: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(language.text("언어", "Language"), systemImage: "globe")
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(Color.primary)

            Picker(language.text("언어", "Language"), selection: $languageRawValue) {
                ForEach(MapHomeLanguage.allCases) { option in
                    Text(option.displayName).tag(option.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel(language.text("언어", "Language"))
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .background(Color.tpReferenceBlue.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private var gpsLoggingMenuItem: some View {
        let session = model.activeTrackingSession
        let isLogging = session != nil
        return Button {
            toggleGPSLogging()
        } label: {
            HStack(spacing: 13) {
                Image(systemName: isLogging ? "location.fill" : "location.viewfinder")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(
                        isLogging ? Color.tpReferenceRose : Color.tpReferenceBlue
                    )
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        isLogging
                            ? language.text("실시간 GPS 기록 중", "Live GPS logging")
                            : language.text("실시간 GPS 기록", "Live GPS logging")
                    )
                    .font(.system(size: 16, weight: .medium, design: .rounded))

                    Text(
                        isLogging
                            ? language.text(
                                "탭하면 기록을 종료합니다",
                                "Tap to stop recording"
                            )
                            : language.text(
                                "탭하면 고정밀 위치 기록을 시작합니다",
                                "Tap to start high-accuracy location logging"
                            )
                    )
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if isGPSLoggingActionInFlight {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: isLogging ? "stop.fill" : "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(isLogging ? Color.tpReferenceRose : Color.tpReferenceBlue)
                        .frame(width: 28, height: 28)
                        .background(
                            Color.white.opacity(0.76),
                            in: Circle()
                        )
                }
            }
            .foregroundStyle(Color.primary)
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .background(
                (isLogging ? Color.tpReferenceRose : Color.tpReferenceBlue)
                    .opacity(0.08),
                in: RoundedRectangle(cornerRadius: 12)
            )
        }
        .buttonStyle(.plain)
        .disabled(isGPSLoggingActionInFlight)
        .accessibilityLabel(
            isLogging
                ? language.text("실시간 GPS 기록 종료", "Stop live GPS logging")
                : language.text("실시간 GPS 기록 시작", "Start live GPS logging")
        )
    }

    private func toggleGPSLogging() {
        guard !isGPSLoggingActionInFlight else { return }
        isGPSLoggingActionInFlight = true
        Task { @MainActor in
            defer { isGPSLoggingActionInFlight = false }
            if model.activeTrackingSession == nil {
                await model.startTracking(.walking)
            } else {
                await model.stopTracking()
            }
        }
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
        formatter.locale = language.locale
        formatter.dateFormat = selectedScope == .day
            ? language.dateTitleFormat
            : language.monthTitleFormat
        return formatter.string(from: model.selectedDate)
    }

    private var dateTitleLabel: Text {
        let calendar = Calendar.autoupdatingCurrent
        let dateFormatter = DateFormatter()
        dateFormatter.locale = language.locale
        dateFormatter.dateFormat = language.datePartFormat
        let weekdayFormatter = DateFormatter()
        weekdayFormatter.locale = language.locale
        weekdayFormatter.dateFormat = language.weekdayFormat
        let weekday = calendar.component(.weekday, from: model.selectedDate)
        let weekdayText = Text(" \(weekdayFormatter.string(from: model.selectedDate))")
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .foregroundStyle(weekday == 1 ? Color.tpHoliday : weekday == 7 ? Color.tpSaturday : ink)
        return Text(dateFormatter.string(from: model.selectedDate))
            .font(.system(size: 17, weight: .semibold, design: .rounded))
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

enum MapHomeLanguage: String, CaseIterable, Identifiable {
    case korean
    case english

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .korean: "한국어"
        case .english: "English"
        }
    }

    var locale: Locale {
        switch self {
        case .korean: Locale(identifier: "ko_KR")
        case .english: Locale(identifier: "en_US")
        }
    }

    var dateTitleFormat: String {
        switch self {
        case .korean: "M월 d일 EEEE"
        case .english: "EEE, MMM d"
        }
    }

    var monthTitleFormat: String {
        switch self {
        case .korean: "yyyy년 M월"
        case .english: "MMMM yyyy"
        }
    }

    var datePartFormat: String {
        switch self {
        case .korean: "M월 d일"
        case .english: "MMM d"
        }
    }

    var weekdayFormat: String {
        switch self {
        case .korean: "EEEE"
        case .english: "EEE"
        }
    }

    func text(_ korean: String, _ english: String) -> String {
        switch self {
        case .korean: korean
        case .english: english
        }
    }
}

private struct MapHomeSectionEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let selection: MapHomeSectionEditSelection
    let language: MapHomeLanguage

    private var timeText: String {
        String(format: "%02d:%02d", selection.minute / 60, selection.minute % 60)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(language.text("섹션 편집", "Edit section"))
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                Spacer()
                Button(language.text("닫기", "Close")) { dismiss() }
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
                    Text(language.text("선택 시각", "Selected time") + " \(timeText)")
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

            Text(
                language.text(
                    "오른쪽 핸들을 위·아래로 끌어 선택 시각을 바꿀 수 있습니다.",
                    "Drag the right handle up or down to change the selected time."
                )
            )
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
    let language: MapHomeLanguage
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
                    Text(language.text("집 위치 설정", "Set home location"))
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    if let home, home.point != nil {
                        Text(language.text("현재 저장 상태", "Saved") + " · Lv.\(home.floor ?? 1)")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(language.text("집 장소를 찾을 수 없습니다", "Home place is unavailable"))
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            Text(
                hasCurrentLocation
                    ? language.text(
                        "현재 위치를 집의 기준 위치로 저장합니다. 좌표는 화면에 표시하지 않습니다.",
                        "Save the current location as home. Coordinates are not shown."
                    )
                    : language.text(
                        "현재 위치를 받는 중입니다. 위치 기록이 잡히면 저장할 수 있습니다.",
                        "Waiting for location. Save becomes available when a location is recorded."
                    )
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
                    home?.point == nil
                        ? language.text("현재 위치로 저장", "Save current location")
                        : language.text("현재 위치로 다시 저장", "Update current location"),
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
    let language: MapHomeLanguage

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
        NotionCalendarDaysIcon(tint: tint)
        .frame(width: 24, height: 25)
        .accessibilityLabel(
            language.text("\(day)일 달력", "Calendar, day \(day)")
        )
    }
}

private struct NotionCalendarDaysIcon: View {
    let tint: Color

    private let dateDots = [
        CGPoint(x: 8, y: 13), CGPoint(x: 12, y: 13), CGPoint(x: 16, y: 13),
        CGPoint(x: 8, y: 17), CGPoint(x: 12, y: 17), CGPoint(x: 16, y: 17)
    ]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: 18, height: 18)

            Path { path in
                path.move(to: CGPoint(x: 8, y: 2))
                path.addLine(to: CGPoint(x: 8, y: 5))
                path.move(to: CGPoint(x: 16, y: 2))
                path.addLine(to: CGPoint(x: 16, y: 5))
                path.move(to: CGPoint(x: 3, y: 9))
                path.addLine(to: CGPoint(x: 21, y: 9))
            }
            .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            ForEach(dateDots.indices, id: \.self) { index in
                Circle()
                    .fill(tint)
                    .frame(width: 2, height: 2)
                    .position(dateDots[index])
            }
        }
        .frame(width: 24, height: 24)
    }
}
