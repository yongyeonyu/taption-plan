import CoreLocation
import MapKit
import Observation
import SwiftUI
import UIKit

enum MapHomeCompassControlState: Equatable, Sendable {
    case directionArrow
    case compass

    var followsHeading: Bool {
        self == .compass
    }

    var toggled: Self {
        self == .directionArrow ? .compass : .directionArrow
    }

    static func iconRotationDegrees(for headingDegrees: Double) -> Double {
        guard headingDegrees.isFinite else { return 0 }
        let normalized = headingDegrees.truncatingRemainder(dividingBy: 360)
        return normalized == 0 ? 0 : -normalized
    }

    static func continuousIconRotationDegrees(
        previousRotationDegrees: Double?,
        headingDegrees: Double
    ) -> Double {
        let target = iconRotationDegrees(for: headingDegrees)
        guard let previousRotationDegrees,
              previousRotationDegrees.isFinite else {
            return target
        }
        var delta = (target - previousRotationDegrees)
            .truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return previousRotationDegrees + delta
    }

    static func preferredHeadingDegrees(
        trueHeading: Double,
        magneticHeading: Double
    ) -> Double {
        trueHeading.isFinite && trueHeading >= 0
            ? trueHeading
            : magneticHeading
    }
}

enum MapHomeOverlayPinchMath {
    static let minimumPublishInterval: TimeInterval = 1.0 / 60.0

    static func shouldForwardToMap(
        startLocation: CGPoint,
        viewportSize: CGSize,
        sidebarWidth: CGFloat,
        topOverlayHeight: CGFloat,
        controlsWidth: CGFloat,
        controlsHeight: CGFloat
    ) -> Bool {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return false }
        let sidebarStartX = viewportSize.width - max(0, sidebarWidth)
        guard startLocation.x < sidebarStartX else { return false }
        return startLocation.y <= topOverlayHeight
            || (startLocation.x <= controlsWidth
                && startLocation.y >= viewportSize.height - controlsHeight)
    }

    static func zoomedCamera(
        from camera: MapCamera,
        magnification: CGFloat
    ) -> MapCamera {
        let scale = min(max(Double(magnification), 0.05), 20)
        return MapCamera(
            centerCoordinate: camera.centerCoordinate,
            distance: min(max(camera.distance / scale, 80), 30_000_000),
            heading: camera.heading,
            pitch: camera.pitch
        )
    }

    static func shouldPublish(
        lastUptime: TimeInterval,
        currentUptime: TimeInterval,
        isFinal: Bool
    ) -> Bool {
        isFinal || currentUptime - lastUptime >= minimumPublishInterval
    }
}

enum MapHomeLocationActivation: Equatable {
    case currentLocation
    case savedLocation
    case edit

    static func resolve(
        isCurrentLocation: Bool,
        hasSavedPoint: Bool
    ) -> Self {
        if isCurrentLocation { return .currentLocation }
        return hasSavedPoint ? .savedLocation : .edit
    }
}

enum MapHomeLocationMapMath {
    static func region(
        center: CLLocationCoordinate2D,
        span: MKCoordinateSpan
    ) -> MKCoordinateRegion {
        MKCoordinateRegion(center: center, span: span)
    }
}

@MainActor
@Observable
final class MapHomeHeadingMonitor: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var rotationDegrees: Double?

    override init() {
        super.init()
        manager.delegate = self
        manager.headingFilter = 1
        manager.headingOrientation = .portrait
    }

    func start() {
        guard CLLocationManager.headingAvailable() else {
            rotationDegrees = nil
            return
        }
        manager.startUpdatingHeading()
    }

    func stop() {
        manager.stopUpdatingHeading()
    }

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateHeading newHeading: CLHeading
    ) {
        guard newHeading.headingAccuracy >= 0 else { return }
        let heading = MapHomeCompassControlState.preferredHeadingDegrees(
            trueHeading: newHeading.trueHeading,
            magneticHeading: newHeading.magneticHeading
        )
        let next = MapHomeCompassControlState.continuousIconRotationDegrees(
            previousRotationDegrees: rotationDegrees,
            headingDegrees: heading
        )
        guard rotationDegrees != next else { return }
        rotationDegrees = next
    }
}

enum MapHomeWeatherTimelineMath {
    static func context(
        at date: Date,
        contexts: [WeatherContext]
    ) -> WeatherContext? {
        WeatherTimelineEngine.coalesced(contexts)
            .filter { $0.observedAt <= date }
            .max { $0.observedAt < $1.observedAt }
    }

    static func persistentSpans(
        for date: Date,
        contexts: [WeatherContext],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [(context: WeatherContext, span: TimeSpan)] {
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? date
        let ordered = WeatherTimelineEngine.coalesced(contexts)
            .sorted { $0.observedAt < $1.observedAt }

        return ordered.enumerated().compactMap { index, context in
            let nextObservedAt = index + 1 < ordered.count
                ? ordered[index + 1].observedAt
                : dayEnd
            let start = max(context.observedAt, dayStart)
            let end = min(
                max(nextObservedAt, context.observedAt.addingTimeInterval(1)),
                dayEnd
            )
            guard start < end, start < dayEnd, end > dayStart else { return nil }
            return (context: context, span: TimeSpan(start: start, end: end))
        }
    }
}

@MainActor
struct MapHomeView: View {
    @Bindable private var model: AppModel
    @Bindable private var proAccess: TaptionProAccessController

    @State private var mapPosition: MapCameraPosition = .automatic
    @Namespace private var mapScope
    @State private var isMenuOpen = false
    @State private var isCalendarPresented = false
    @State private var selectedLocationDestination: MapHomeLocationDestination?
    @State private var isTransitLocationsPresented = false
    @State private var isLocationMenuExpanded = false
    @State private var isUserLocationsMenuExpanded = false
    @State private var isCategoryMenuExpanded = false
    @State private var isDisplayMenuExpanded = false
    @State private var isSettingsMenuExpanded = false
    @State private var isDataProtectionPresented = false
    @State private var isSettingsResetConfirmationPresented = false
    @AppStorage("taption.mapHome.language") private var languageRawValue = MapHomeLanguage.korean.rawValue
    @State private var compassControlState: MapHomeCompassControlState = .directionArrow
    @State private var headingMonitor = MapHomeHeadingMonitor()
    @State private var isGPSLoggingActionInFlight = false
    @State private var isGPSLoggingMenuExpanded = false
    @State private var gpsLoggingIntervalDraftSeconds = GPSLoggingPreferences.standard.intervalSeconds
    @State private var selectedScope: TimeScale = .day
    @State private var selectedTimelineMinute: Int?
    @State private var isTimelineSelectionPinned = false
    @State private var sectionEditSelection: MapHomeSectionEditSelection?
    @State private var isMapCenteredOnUser = false
    @State private var hasAppliedInitialLocation = false
    @State private var mapSearchText = ""
    @State private var mapSearchResults: [MapHomeSearchResult] = []
    @State private var selectedSearchPin: MapHomeSearchResult?
    @State private var isSearchPinMenuPresented = false
    @State private var selectedUserLocation: MapHomeUserLocationSelection?
    @State private var pendingUserLocationSelection: MapHomeUserLocationSelection?
    @State private var mapSearchTask: Task<Void, Never>?
    @FocusState private var isMapSearchFocused: Bool
    @State private var visibleMapCenter = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    @State private var timeRailSegments: [MapHomeTimeRailSegment] = [
        .wholeDayUnconfirmed,
    ]
    @State private var routeProjection: RouteTimelineProjection?
    @State private var routeReadings: [SensorReading] = []
    @State private var visibleMapSpan = MKCoordinateSpan(
        latitudeDelta: 0.025,
        longitudeDelta: 0.035
    )
    @State private var sharedZoomLevel: CGFloat = 1
    @State private var zoomResetToken = 0
    @State private var timeSidebarZoomStep = 0
    @State private var weatherVisibleStartMinute = 0
    @State private var weatherVisibleDurationMinutes = MapHomeTimeSidebarMath.fullDayMinutes
    @State private var sidebarPinchDirection = 0
    @State private var activePaletteCategoryID: String?
    @State private var customPaletteColor = Color.tpReferenceMint
    @State private var lastMapCameraPublishUptime: TimeInterval = 0
    @State private var visibleMapCamera: MapCamera?
    @State private var mapViewportSize = CGSize.zero
    @State private var overlayPinchRoutesToMap: Bool?
    @State private var overlayPinchInitialCamera: MapCamera?
    @State private var lastOverlayPinchPublishUptime: TimeInterval = 0

    private static let userCenterTolerance: CLLocationDistance = 120
    private static let categoryPaletteHexes = [
        "#29A383", "#2563EB", "#00A2C7", "#8B5CF6",
        "#5B5BD6", "#F76B15", "#DC2626", "#94A3B8",
        "#E1C453", "#F15C80", "#48B38C", "#2D9BF0",
    ]

    private enum Layout {
        static let horizontalInset: CGFloat = 10
        static let headerVisibleHeight: CGFloat = 46
        static let headerHitTarget: CGFloat = 44
        static let headerIcon: CGFloat = 19
        static let mapControlSize: CGFloat = 44
        static let mapControlIcon: CGFloat = 15
        static let timeRailWidth: CGFloat = 58
        static let weatherRailWidth: CGFloat = 58
        static let weatherRailSpacing: CGFloat = 4
        static let timeRailTopMargin: CGFloat = 18
        static let timeRailBottomMargin: CGFloat = 28
    }

    init(
        model: AppModel,
        proAccess: TaptionProAccessController
    ) {
        self._model = Bindable(model)
        self._proAccess = Bindable(proAccess)
        _selectedScope = State(initialValue: .day)
    }

    private var language: MapHomeLanguage {
        MapHomeLanguage(rawValue: languageRawValue) ?? .korean
    }

    private var isHeadingMode: Bool {
        compassControlState == .compass
    }

    private var compassRotationDegrees: Double {
        headingMonitor.rotationDegrees
            ?? MapHomeCompassControlState.iconRotationDegrees(
                for: model.latestSensorReading?.courseDegrees ?? 0
            )
    }

    private var sidebarInteractionWidth: CGFloat {
        (model.settings.weatherSidebarVisible
            ? Layout.weatherRailWidth + Layout.weatherRailSpacing
            : 0)
            + Layout.timeRailWidth
            + Layout.horizontalInset
    }

    private func sectionEditSheet(for selection: MapHomeSectionEditSelection) -> some View {
        MapHomeSectionEditSheet(selection: selection, language: language)
            .presentationDetents([.height(232)])
            .presentationDragIndicator(.visible)
    }

    private func locationDestinationSheet(
        for destination: MapHomeLocationDestination
    ) -> some View {
        MapHomeLocationSheet(
            model: model,
            destination: destination,
            language: language
        ) {
            mapPosition = .automatic
            focusMapIfNeeded()
        }
        .presentationDetents([.height(390)])
        .presentationDragIndicator(.visible)
    }

    private func userLocationSheet(
        for selection: MapHomeUserLocationSelection
    ) -> some View {
        MapHomeUserLocationActionSheet(
            model: model,
            selection: selection,
            language: language
        )
        .presentationDetents([.height(300)])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var searchPinSheet: some View {
        if let selectedSearchPin = self.selectedSearchPin {
            MapHomeSearchPinLocationSheet(
                model: model,
                result: selectedSearchPin,
                language: language,
                onSaved: { createdSelection in
                    pendingUserLocationSelection = createdSelection
                    isSearchPinMenuPresented = false
                    self.selectedSearchPin = nil
                }
            )
            .presentationDetents([.height(470)])
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(
                .enabled(upThrough: .height(470))
            )
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            map
                .ignoresSafeArea()

            VStack(spacing: 8) {
                header
                mapSearchBar
            }
            .padding(.horizontal, Layout.horizontalInset)
            // The container already starts below the status-bar safe area; keep
            // only a minimal breathing room so the top bar stays high on screen.
            .padding(.top, 2)
            .zIndex(4)
            .simultaneousGesture(
                TapGesture().onEnded {
                    if isMenuOpen {
                        isMenuOpen = false
                    }
                }
            )

            if isMenuOpen {
                menu
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .overlay(alignment: .trailing) {
            if !isMenuOpen {
                currentTimeRail
                    .padding(.top, Layout.headerVisibleHeight + Layout.timeRailTopMargin)
                    .padding(.bottom, Layout.timeRailBottomMargin)
                    .padding(.trailing, Layout.horizontalInset)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if !isMenuOpen {
                mapControls
                    .padding(.leading, Layout.horizontalInset)
                    .padding(.bottom, 12)
            }
        }
        .onGeometryChange(
            for: CGSize.self,
            of: { $0.size },
            action: { size in
                guard mapViewportSize != size else { return }
                mapViewportSize = size
            }
        )
        .simultaneousGesture(mapOverlayPinchGesture)
        .preferredColorScheme(.light)
        .sheet(isPresented: $isCalendarPresented) {
            MapHomeCalendarSheet(
                selectedDate: $model.selectedDate,
                holidayName: { date in
                    TimelineAxisGrid.koreanHolidayName(on: date)
                },
                language: language
            )
        }
        .sheet(item: $selectedLocationDestination) { destination in
            locationDestinationSheet(for: destination)
        }
        .sheet(isPresented: $isTransitLocationsPresented) {
            MapHomeTransitLocationsSheet(
                model: model,
                language: language,
                initialCenter: currentCoordinate ?? visibleMapCenter,
                initialSpan: visibleMapSpan
            )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $selectedUserLocation) { selection in
            userLocationSheet(for: selection)
        }
        .sheet(
            isPresented: $isSearchPinMenuPresented,
            onDismiss: {
                if let selection = pendingUserLocationSelection {
                    pendingUserLocationSelection = nil
                    selectedUserLocation = selection
                } else {
                    selectedSearchPin = nil
                }
            }
        ) {
            searchPinSheet
        }
        .sheet(isPresented: $isDataProtectionPresented) {
            MapHomeSecuritySheet(model: model, language: language)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $proAccess.isPurchaseSheetPresented) {
            TaptionProAccessView(
                controller: proAccess,
                allowsDismiss: true
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            language.text("설정을 기본값으로 초기화할까요?", "Reset settings to defaults?"),
            isPresented: $isSettingsResetConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(
                language.text("설정 초기화", "Reset settings"),
                role: .destructive
            ) {
                isMenuOpen = false
                Task { await model.resetSettingsToDefaults() }
            }
            Button(language.text("취소", "Cancel"), role: .cancel) {}
        } message: {
            Text(
                language.text(
                    "계획과 기록은 삭제되지 않습니다.",
                    "Your plans and records will not be deleted."
                )
            )
        }
        .sheet(item: $sectionEditSelection) { selection in
            sectionEditSheet(for: selection)
        }
        .animation(.easeInOut(duration: 0.22), value: isMenuOpen)
        .task {
            focusMapIfNeeded()
            applyInitialLocationIfAvailable()
            refreshTimeRailSegments()
        }
        .onDisappear {
            mapSearchTask?.cancel()
            mapSearchTask = nil
            headingMonitor.stop()
        }
        .task(id: model.selectedDate) {
            let date = model.selectedDate
            await refreshRouteReadings(for: date)
            while !Task.isCancelled {
                refreshTimeRailSegments()
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                } catch {
                    return
                }
            }
        }
        .onChange(of: model.latestSensorReading?.point) { _, _ in
            applyInitialLocationIfAvailable()
            refreshRouteProjection()
        }
        .onChange(of: model.settings.frequentPlaces) { _, _ in
            focusMapIfNeeded()
        }
        .onChange(of: model.selectedDate) { _, _ in
            selectedTimelineMinute = nil
            isTimelineSelectionPinned = false
            weatherVisibleStartMinute = 0
            weatherVisibleDurationMinutes = MapHomeTimeSidebarMath.fullDayMinutes
            if Calendar.autoupdatingCurrent.isDateInToday(model.selectedDate),
               currentCoordinate != nil {
                focusUserLocation()
            } else {
                mapPosition = .automatic
                focusMapIfNeeded()
            }
            refreshTimeRailSegments()
        }
        .onChange(of: model.snapshot.actuals) { _, _ in
            refreshTimeRailSegments()
            refreshRouteProjection()
        }
        .onChange(of: model.liveRouteState.readings) { _, _ in
            refreshRouteProjection()
        }
        .onChange(of: selectedTimelineMinute) { _, minute in
            guard minute != nil,
                  let projection = refreshRouteProjection(),
                  let point = projection.coordinateAtCutoff
            else { return }
            focusMap(on: point)
        }
    }

    @ViewBuilder
    private var map: some View {
        MapReader { proxy in
            Map(
                position: $mapPosition,
                interactionModes: [.pan, .zoom, .rotate],
                scope: mapScope
            ) {
            if timelineRouteOverlays.isEmpty {
                ForEach(subwayRouteOverlays) { overlay in
                    // Keep the inferred subway path as a fallback when raw
                    // GPS samples are unavailable for the selected day.
                    MapPolyline(coordinates: overlay.coordinates)
                        .stroke(
                            mapCategoryColor("movement").opacity(0.20),
                            style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round)
                        )
                    MapPolyline(coordinates: overlay.coordinates)
                        .stroke(
                            mapCategoryColor("movement").opacity(0.92),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                        )
                }
            }

            ForEach(timelineRouteOverlays) { overlay in
                MapPolyline(coordinates: overlay.coordinates)
                    .stroke(
                        mapCategoryColor(overlay.categoryID)
                            .opacity(overlay.opacity * 0.20),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round)
                    )
                MapPolyline(coordinates: overlay.coordinates)
                    .stroke(
                        mapCategoryColor(overlay.categoryID)
                            .opacity(overlay.opacity),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                    )
            }

            ForEach(placeAnnotations) { place in
                Annotation("", coordinate: place.coordinate, anchor: .bottom) {
                    if place.destination == .user {
                        Button {
                            selectedUserLocation = .frequentPlace(place.id)
                        } label: {
                            MapHomePlacePin(
                                name: place.name,
                                floor: place.floor,
                                destination: place.destination
                            )
                            .fixedSize()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            language.text(
                                place.name + " 사용자 위치 메뉴",
                                place.name + " user location menu"
                            )
                        )
                    } else {
                        MapHomePlacePin(
                            name: place.name,
                            floor: place.floor,
                            destination: place.destination
                        )
                        .fixedSize()
                        .zIndex(0)
                    }
                }
            }

            ForEach(transitAnnotations) { place in
                Annotation("", coordinate: place.coordinate, anchor: .bottom) {
                    Button {
                        selectedUserLocation = .transit(place.id)
                    } label: {
                        MapHomeTransitPlacePin(
                            name: place.name,
                            kind: place.kind
                        )
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        language.text(
                            place.name + " 사용자 위치 메뉴",
                            place.name + " user location menu"
                        )
                    )
                }
            }

            if let selectedSearchPin {
                Annotation(
                    selectedSearchPin.title,
                    coordinate: selectedSearchPin.coordinate,
                    anchor: .bottom
                ) {
                    Button {
                        isSearchPinMenuPresented = true
                    } label: {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 36, weight: .bold))
                            .foregroundStyle(Color.tpReferenceRose)
                            .background(Circle().fill(.white))
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.45)
                            .onEnded { _ in
                                isSearchPinMenuPresented = true
                            }
                    )
                    .accessibilityLabel(
                        language.text(
                            "(selectedSearchPin.title) 위치 추가",
                            "Add (selectedSearchPin.title) location"
                        )
                    )
                }
            }

                UserAnnotation()

            }
            .mapStyle(mapStyle)
            .mapControls {
                EmptyView()
            }
            .onMapCameraChange(frequency: .continuous) { context in
                let uptime = ProcessInfo.processInfo.systemUptime
                guard uptime - lastMapCameraPublishUptime >= (1.0 / 60.0) else { return }
                lastMapCameraPublishUptime = uptime
                if visibleMapCamera != context.camera {
                    visibleMapCamera = context.camera
                }
                visibleMapCenter = context.region.center
                updateVisibleMapSpan(context.region.span)
                updateUserCenterState(for: context.region.center)
                if let level = sharedZoomLevel(for: context.region.span),
                   abs(level - sharedZoomLevel) > 0.02 {
                    sharedZoomLevel = level
                }
            }
            .overlay {
                MapHomeFairyAtmosphere()
                    .allowsHitTesting(false)
            }
            .simultaneousGesture(
                SpatialTapGesture().onEnded { _ in
                    dismissMapSearchOverlay()
                }
            )
            .simultaneousGesture(mapLongPressGesture(proxy: proxy))
        }
    }

    private func mapLongPressGesture(proxy: MapProxy) -> some Gesture {
        LongPressGesture(minimumDuration: 0.55, maximumDistance: 12)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onEnded { value in
                guard case .second(true, let drag?) = value,
                      let coordinate = proxy.convert(drag.startLocation, from: .local)
                else { return }
                presentLocationAddition(at: coordinate)
            }
    }

    private func presentLocationAddition(at coordinate: CLLocationCoordinate2D) {
        mapSearchResults = []
        isMapSearchFocused = false
        selectedSearchPin = MapHomeSearchResult(
            title: language.text("사용자 지점", "User location"),
            subtitle: language.text("지도에서 선택한 위치", "Long-pressed map location"),
            coordinate: coordinate
        )
        isSearchPinMenuPresented = true
    }

    private var mapStyle: MapStyle {
        .standard(elevation: .realistic)
    }

    private var header: some View {
        HStack(spacing: 3) {
            Button {
                if !isMenuOpen {
                    isLocationMenuExpanded = false
                    isUserLocationsMenuExpanded = false
                    isCategoryMenuExpanded = false
                    isDisplayMenuExpanded = false
                    isSettingsMenuExpanded = false
                    isGPSLoggingMenuExpanded = false
                }
                isMenuOpen.toggle()
            } label: {
                Group {
                    if isMenuOpen {
                        Image(systemName: "xmark")
                            .font(.system(size: Layout.headerIcon, weight: .medium))
                    } else {
                        Image("MapHomeMainMenu")
                            .resizable()
                            .scaledToFit()
                            .padding(10)
                    }
                }
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
                jumpToTodayAndCurrentMapPosition()
            } label: {
                (isHeadingMode ? datePartTitleLabel : dateTitleLabel)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
                    .layoutPriority(1)
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
        .frame(maxWidth: .infinity)
        .frame(height: Layout.headerVisibleHeight)
        .background(Color.tpSurface.opacity(0.96), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.tpLine.opacity(0.78), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.07), radius: 9, y: 3)
        .simultaneousGesture(
            SpatialTapGesture().onEnded { _ in
                dismissMapSearchOverlay()
            }
        )
    }

    private var mapSearchBar: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(
                    language.text("장소·주소 검색", "Search places or addresses"),
                    text: $mapSearchText
                )
                .focused($isMapSearchFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { searchMap() }
                if !mapSearchText.isEmpty || !mapSearchResults.isEmpty || selectedSearchPin != nil {
                    Button {
                        clearMapSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(Color.tpSurface.opacity(0.96), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.tpLine.opacity(0.78), lineWidth: 1)
            }

            if !mapSearchResults.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(mapSearchResults) { result in
                        Button {
                            focusMap(
                                on: GeoPoint(
                                    latitude: result.coordinate.latitude,
                                    longitude: result.coordinate.longitude,
                                    altitude: 0,
                                    horizontalAccuracy: -1,
                                    verticalAccuracy: -1
                                )
                            )
                            selectedSearchPin = result
                            mapSearchResults = []
                            mapSearchText = result.title
                            isMapSearchFocused = false
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.title)
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                if !result.subtitle.isEmpty {
                                    Text(result.subtitle)
                                        .font(.system(size: 11, weight: .regular, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Color.tpSurface.opacity(0.98), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.tpLine.opacity(0.7), lineWidth: 1)
                }
            }
        }
        .containerRelativeFrame(
            .horizontal,
            count: 2,
            span: 1,
            spacing: 0,
            alignment: .leading
        )
        .zIndex(4)
    }

    private func dismissMapSearchOverlay() {
        if isSearchPinMenuPresented, selectedSearchPin != nil {
            cancelPendingMapLocationAddition()
            return
        }
        guard isMapSearchFocused || !mapSearchResults.isEmpty else { return }
        isMapSearchFocused = false
        mapSearchResults = []
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private func cancelPendingMapLocationAddition() {
        pendingUserLocationSelection = nil
        selectedSearchPin = nil
        isSearchPinMenuPresented = false
    }

    private func clearMapSearch() {
        mapSearchTask?.cancel()
        mapSearchTask = nil
        mapSearchText = ""
        mapSearchResults = []
        selectedSearchPin = nil
        isSearchPinMenuPresented = false
        isMapSearchFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private func searchMap() {
        let query = mapSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            mapSearchResults = []
            return
        }
        mapSearchTask?.cancel()
        mapSearchTask = Task { @MainActor in
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            if let coordinate = currentCoordinate {
                request.region = MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.25, longitudeDelta: 0.25)
                )
            }
            guard let response = try? await MKLocalSearch(request: request).start(),
                  !Task.isCancelled else { return }
            mapSearchResults = response.mapItems.prefix(6).map { item in
                MapHomeSearchResult(
                    title: item.name ?? query,
                    subtitle: item.placemark.title ?? "",
                    coordinate: item.placemark.coordinate
                )
            }
        }
    }

    private func headerDateButton(_ icon: String, amount: Int) -> some View {
        Button {
            moveDate(by: amount)
        } label: {
            Group {
                if let assetName = headerIconAssetName(for: icon) {
                    Image(assetName)
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .medium))
                }
            }
                .frame(width: 31, height: Layout.headerHitTarget)
        }
        .accessibilityLabel(
            amount < 0
                ? language.text("이전 날짜", "Previous date")
                : language.text("다음 날짜", "Next date")
        )
    }

    private func headerIconAssetName(for systemImage: String) -> String? {
        switch systemImage {
        case "chevron.backward.2": "MapHomeNavigatePreviousDouble"
        case "chevron.left": "MapHomeNavigatePrevious"
        case "chevron.right": "MapHomeNavigateNext"
        case "chevron.forward.2": "MapHomeNavigateNextDouble"
        default: nil
        }
    }

    private var currentTimeRail: some View {
        GeometryReader { proxy in
            let railHeight = min(680, max(500, proxy.size.height))
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                let minute = timelineSelectionMinute(at: timeline.date)
                let weatherWidth = model.settings.weatherSidebarVisible
                    ? Layout.weatherRailWidth + Layout.weatherRailSpacing
                    : 0
                HStack(spacing: Layout.weatherRailSpacing) {
                    if model.settings.weatherSidebarVisible {
                        MapHomeWeatherSidebar(
                            date: model.selectedDate,
                            contexts: model.snapshot.weather,
                            selectedMinute: minute,
                            language: language,
                            visibleStartMinute: weatherVisibleStartMinute,
                            visibleDurationMinutes: weatherVisibleDurationMinutes
                        )
                    }
                    MapHomeTimeSidebar(
                        date: model.selectedDate,
                        selectedMinute: Binding(
                            get: { timelineSelectionMinute(at: timeline.date) },
                            set: { minute in
                                guard selectedTimelineMinute != minute else { return }
                                isTimelineSelectionPinned = true
                                selectedTimelineMinute = minute
                            }
                        ),
                        activity: currentActivity(at: minute),
                        segments: timeRailSegments,
                        categoryColors: model.settings.mapCategoryColors,
                        currentWeather: model.settings.weatherSidebarVisible
                            ? nil
                            : weatherContext(at: minute),
                        zoomResetToken: zoomResetToken,
                        zoomStepToken: timeSidebarZoomStep,
                        railWidth: Layout.timeRailWidth,
                        onSelectionChanged: { minute in
                            isTimelineSelectionPinned = true
                            selectedTimelineMinute = minute
                        },
                        onViewportChanged: { start, duration in
                            weatherVisibleStartMinute = start
                            weatherVisibleDurationMinutes = duration
                        },
                        onSectionEdit: {
                            sectionEditSelection = MapHomeSectionEditSelection(
                                date: model.selectedDate,
                                minute: minute,
                                activity: currentActivity(at: minute)
                            )
                        }
                    )
                }
                .frame(
                    width: weatherWidth + Layout.timeRailWidth,
                    height: railHeight
                )
                .position(
                    x: proxy.size.width - (weatherWidth + Layout.timeRailWidth) / 2,
                    y: proxy.size.height / 2
                )
                .contentShape(Rectangle())
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { scale in
                            let direction: Int
                            if scale > 1.04 {
                                direction = 1
                            } else if scale < 0.96 {
                                direction = -1
                            } else {
                                direction = 0
                            }
                            guard direction != 0,
                                  direction != sidebarPinchDirection else { return }
                            sidebarPinchDirection = direction
                            timeSidebarZoomStep += direction
                        }
                        .onEnded { _ in
                            sidebarPinchDirection = 0
                        }
                )
            }
        }
        .frame(
            width: (model.settings.weatherSidebarVisible
                ? Layout.weatherRailWidth + Layout.weatherRailSpacing
                : 0) + Layout.timeRailWidth
        )
        .frame(maxHeight: .infinity, alignment: .trailing)
    }

    private var mapOverlayPinchGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                updateOverlayMapPinch(value, force: false)
            }
            .onEnded { value in
                updateOverlayMapPinch(value, force: true)
                overlayPinchRoutesToMap = nil
                overlayPinchInitialCamera = nil
                lastOverlayPinchPublishUptime = 0
            }
    }

    private func updateOverlayMapPinch(
        _ value: MagnifyGesture.Value,
        force: Bool
    ) {
        if overlayPinchRoutesToMap == nil {
            overlayPinchRoutesToMap = !isMenuOpen
                && MapHomeOverlayPinchMath.shouldForwardToMap(
                    startLocation: value.startLocation,
                    viewportSize: mapViewportSize,
                    sidebarWidth: sidebarInteractionWidth,
                    topOverlayHeight: 190,
                    controlsWidth: 82,
                    controlsHeight: 250
                )
            overlayPinchInitialCamera = visibleMapCamera
        }
        guard overlayPinchRoutesToMap == true,
              let initialCamera = overlayPinchInitialCamera else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        guard MapHomeOverlayPinchMath.shouldPublish(
            lastUptime: lastOverlayPinchPublishUptime,
            currentUptime: uptime,
            isFinal: force
        ) else { return }
        lastOverlayPinchPublishUptime = uptime
        mapPosition = .camera(
            MapHomeOverlayPinchMath.zoomedCamera(
                from: initialCamera,
                magnification: value.magnification
            )
        )
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

            if isHeadingMode {
                Button {
                    toggleMapHeadingMode()
                } label: {
                        Image("MapHomeCompass")
                            .resizable()
                            .scaledToFit()
                            .padding(9)
                            .rotationEffect(
                                .degrees(compassRotationDegrees)
                            )
                            .animation(
                                .linear(duration: 0.12),
                                value: compassRotationDegrees
                            )
                        .frame(width: Layout.mapControlSize, height: Layout.mapControlSize)
                        .background(Color.white.opacity(0.94), in: Circle())
                        .allowsHitTesting(false)
                }
                .accessibilityLabel(language.text("지도 방향 고정", "Fix map direction"))
            } else {
                Button {
                    toggleMapHeadingMode()
                } label: {
                    Image(systemName: "location.north.line")
                        .font(.system(size: Layout.mapControlIcon, weight: .bold))
                        .foregroundStyle(Color.tpReferenceRose)
                        .frame(width: Layout.mapControlSize, height: Layout.mapControlSize)
                        .background(Color.white.opacity(0.94), in: Circle())
                }
                .accessibilityLabel(language.text("나침반 표시", "Show compass"))
            }

            VStack(spacing: 3) {
                mapZoomButton(systemImage: "plus", direction: 1)
                mapZoomButton(systemImage: "minus", direction: -1)
            }
        }
        .simultaneousGesture(
            SpatialTapGesture().onEnded { _ in
                dismissMapSearchOverlay()
            }
        )
    }

    private func mapZoomButton(systemImage: String, direction: Int) -> some View {
        Button {
            adjustMapZoom(direction: direction)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: Layout.mapControlIcon, weight: .bold))
                .foregroundStyle(Color.tpInk)
                .frame(width: Layout.mapControlSize, height: Layout.mapControlSize)
                .background(Color.white.opacity(0.94), in: Circle())
        }
        .accessibilityLabel(
            direction > 0
                ? language.text("지도 확대", "Zoom map in")
                : language.text("지도 축소", "Zoom map out")
        )
    }

    private func adjustMapZoom(direction: Int) {
        let factor = direction > 0 ? 0.68 : 1.48
        let next = MKCoordinateSpan(
            latitudeDelta: min(max(visibleMapSpan.latitudeDelta * factor, 0.002), 80),
            longitudeDelta: min(max(visibleMapSpan.longitudeDelta * factor, 0.002), 80)
        )
        visibleMapSpan = next
        mapPosition = .region(
            MKCoordinateRegion(center: visibleMapCenter, span: next)
        )
    }

    private var menu: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.18)
                    .ignoresSafeArea(edges: .top)
                    .contentShape(Rectangle())
                    .onTapGesture { isMenuOpen = false }

                let menuHeight = max(0, proxy.size.height)
                let menuTop = Layout.headerVisibleHeight + 8
                sidebarContent
                .frame(width: 316, height: max(0, menuHeight - menuTop), alignment: .top)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(.top, menuTop)
                .shadow(color: Color.black.opacity(0.18), radius: 22, x: 8, y: 0)
            }
        }
    }

    private var sidebarContent: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image("MapHomeHomeIcon")
                    .resizable()
                    .scaledToFit()
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

            locationMenuItem
            gpsLoggingMenuItem
            categoryMenuItem
            displayMenuItem
            languageMenuItem
            settingsMenuItem

            Spacer(minLength: 28)

            menuItem(
                "sparkles",
                proAccess.menuTitle,
                isSelected: proAccess.hasPermanentAccess
            ) {
                proAccess.isPurchaseSheetPresented = true
            }

            Divider()
                .padding(.vertical, 12)

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
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(MapHomeScrollBounceDisabler())
    }

    private var categoryMenuItem: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                isCategoryMenuExpanded.toggle()
            } label: {
                HStack(spacing: 13) {
                    Image(systemName: "paintpalette.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.tpReferenceMint)
                        .frame(width: 24)
                    Text(language.text("행동 분류", "Activity categories"))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Spacer()
                    Image(systemName: isCategoryMenuExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.primary)
                .padding(.vertical, 12)
                .padding(.horizontal, 12)
                .background(
                    Color.tpReferenceMint.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(language.text("행동 분류 목록", "Activity category list"))

            if isCategoryMenuExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(
                        MapHomeSidebarMajorCategory.all(
                            categoryColors: model.settings.mapCategoryColors
                        )
                    ) { category in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 9) {
                                Circle()
                                    .fill(category.tint)
                                    .frame(width: 10, height: 10)
                                Image(systemName: category.systemImage)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(category.tint)
                                    .frame(width: 20)
                                Text(category.localizedTitle(language))
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                Spacer()
                                Button {
                                    if activePaletteCategoryID == category.id {
                                        activePaletteCategoryID = nil
                                    } else {
                                        customPaletteColor = Color(
                                            hex: model.settings.mapCategoryColors[category.id]
                                                ?? category.hex
                                        )
                                        activePaletteCategoryID = category.id
                                    }
                                } label: {
                                    Circle()
                                        .fill(category.tint)
                                        .frame(width: 23, height: 23)
                                        .overlay {
                                            Image(systemName: activePaletteCategoryID == category.id
                                                ? "chevron.up"
                                                : "paintpalette.fill")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundStyle(.white)
                                        }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(
                                    language.text(
                                        "\(category.localizedTitle(language)) 색상 팔레트",
                                        "\(category.localizedTitle(language)) color palette"
                                    )
                                )
                            }
                            if activePaletteCategoryID == category.id {
                                LazyVGrid(
                                    columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6),
                                    spacing: 6
                                ) {
                                    ForEach(Self.categoryPaletteHexes, id: \.self) { hex in
                                        Button {
                                            model.setMapCategoryColor(hex, for: category.id)
                                            activePaletteCategoryID = nil
                                        } label: {
                                            Circle()
                                                .fill(Color(hex: hex))
                                                .frame(width: 22, height: 22)
                                                .overlay {
                                                    Circle()
                                                        .stroke(.white.opacity(0.9), lineWidth: 1)
                                                }
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(language.text("색상 선택", "Choose color"))
                                    }

                                    ColorPicker(
                                        language.text("사용자 지정", "Custom"),
                                        selection: Binding(
                                            get: { customPaletteColor },
                                            set: { color in
                                                customPaletteColor = color
                                                if let hex = color.hexRGBString {
                                                    model.setMapCategoryColor(hex, for: category.id)
                                                }
                                            }
                                        ),
                                        supportsOpacity: false
                                    )
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .frame(maxWidth: .infinity, minHeight: 28)
                                    .padding(.horizontal, 5)
                                    .background(Color.tpInk.opacity(0.07), in: Capsule())
                                    .accessibilityLabel(
                                        language.text("사용자 지정 색상", "Custom category color")
                                    )
                                }
                                .padding(.leading, 39)
                                .padding(.bottom, 4)
                            }
                        }
                        .foregroundStyle(Color.primary)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(
                            category.tint.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                        .accessibilityElement(children: .contain)
                    }
                }
                .padding(.leading, 12)
                Text(language.text("색상을 선택하면 즉시 저장됩니다.", "Colors save immediately."))
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
        }
    }

    private var locationMenuItem: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                isLocationMenuExpanded.toggle()
            } label: {
                HStack(spacing: 13) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.tpReferenceBlue)
                        .frame(width: 24)
                    Text(language.text("위치", "Location"))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Spacer()
                    Image(systemName: isLocationMenuExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.primary)
                .padding(.vertical, 12)
                .padding(.horizontal, 12)
                .background(
                    Color.tpReferenceBlue.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(language.text("위치 목록", "Location list"))

            if isLocationMenuExpanded {
                VStack(spacing: 5) {
                    userLocationsMenuItem
                    ForEach(MapHomeLocationDestination.allCases.filter { $0 != .user }) { destination in
                        locationDestinationRow(destination)
                    }
                }
                .padding(.leading, 12)
            }
        }
    }

    private var userLocationsMenuItem: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                isUserLocationsMenuExpanded.toggle()
            } label: {
                HStack(spacing: 10) {
                    MapHomeLocationThumbnail(
                        destination: .user,
                        size: 34
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(language.text("사용자", "User"))
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                        Text(
                            language.text(
                                "등록된 사용자 위치 " + String(userLocationCount) + "개",
                                String(userLocationCount) + " saved user locations"
                            )
                        )
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: isUserLocationsMenuExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.primary)
                .padding(.vertical, 7)
                .padding(.horizontal, 8)
                .background(
                    Color.tpReferenceRose.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                language.text("사용자 위치 목록", "User location list")
            )

            if isUserLocationsMenuExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    if userLocationCount == 0 {
                        Text(language.text("등록된 사용자 위치가 없습니다.", "No saved user locations."))
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                    }

                    ForEach(userFrequentPlaces) { place in
                        userFrequentPlaceRow(place)
                    }
                    ForEach(model.settings.userTransitLocations) { location in
                        userTransitLocationRow(location)
                    }

                    Button {
                        isTransitLocationsPresented = true
                        isMenuOpen = false
                    } label: {
                        Label(
                            language.text("사용자 위치 관리", "Manage user locations"),
                            systemImage: "slider.horizontal.3"
                        )
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.tpReferenceBlue)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 12)
            }
        }
    }

    private var userFrequentPlaces: [FrequentPlace] {
        model.settings.frequentPlaces.filter { $0.kind == .custom }
    }

    private var userLocationCount: Int {
        userFrequentPlaces.count + model.settings.userTransitLocations.count
    }

    private func userFrequentPlaceRow(_ place: FrequentPlace) -> some View {
        Button {
            if let point = place.point {
                focusMap(on: point)
                isMenuOpen = false
            } else {
                selectedUserLocation = .frequentPlace(place.id)
                isMenuOpen = false
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: FrequentPlaceKind.custom.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MapHomeLocationDestination.user.tint)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(place.name)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Text(
                        place.point == nil
                            ? language.text("위치 미지정", "Location not set")
                            : language.text("사용자 위치", "User location")
                    )
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: place.point == nil ? "pencil" : "location.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    private func userTransitLocationRow(_ location: UserTransitLocation) -> some View {
        Button {
            focusMap(on: location.point)
            isMenuOpen = false
        } label: {
            HStack(spacing: 8) {
                Image(systemName: location.kind.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.tpReferenceBlue)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(location.name)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Text(language.text(location.kind.title, location.kind == .subwayStation ? "Subway station" : "Bus stop"))
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "location.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    private func locationDestinationRow(
        _ destination: MapHomeLocationDestination
    ) -> some View {
        HStack(spacing: 0) {
            Button {
                activateLocationDestination(destination)
            } label: {
                HStack(spacing: 10) {
                    MapHomeLocationThumbnail(destination: destination, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(language.text(destination.koreanName, destination.englishName))
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                        Text(locationDestinationSubtitle(destination))
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(destination == .user ? destination.tint : .secondary)
                    }
                    Spacer()
                }
                .foregroundStyle(Color.primary)
                .padding(.vertical, 7)
                .padding(.leading, 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(locationDestinationAccessibilityLabel(destination))

            if destination != .user {
                Button {
                    selectedLocationDestination = destination
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(destination.tint)
                        .frame(width: 38, height: 42)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    language.text(
                        "\(destination.koreanName) 위치 편집",
                        "Edit \(destination.englishName) location"
                    )
                )
            }
        }
        .padding(.trailing, destination == .user ? 8 : 2)
        .background(
            destination.tint.opacity(destination == .user ? 0.10 : 0.055),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private func activateLocationDestination(
        _ destination: MapHomeLocationDestination
    ) {
        let place = destination.placeKind.flatMap { kind in
            model.settings.frequentPlaces.first { $0.kind == kind }
        }
        switch MapHomeLocationActivation.resolve(
            isCurrentLocation: destination == .user,
            hasSavedPoint: place?.point != nil
        ) {
        case .currentLocation:
            focusUserLocation()
            isMenuOpen = false
        case .savedLocation:
            guard let point = place?.point else { return }
            focusMap(on: point)
            isMenuOpen = false
        case .edit:
            selectedLocationDestination = destination
        }
    }

    private func locationDestinationSubtitle(
        _ destination: MapHomeLocationDestination
    ) -> String {
        if destination == .user {
            return currentCoordinate == nil
                ? language.text("위치 확인 중", "Locating")
                : language.text("현재 위치", "Current location")
        }
        guard let kind = destination.placeKind,
              let place = model.settings.frequentPlaces.first(where: { $0.kind == kind })
        else {
            return language.text("설정 준비 중", "Setting up")
        }
        if place.point != nil {
            return language.text("설정됨", "Set") + " · Lv.\(place.floor ?? 1)"
        }
        return language.text("현재 위치로 설정", "Set from current location")
    }

    private func locationDestinationAccessibilityLabel(
        _ destination: MapHomeLocationDestination
    ) -> String {
        let name = language.text(destination.koreanName, destination.englishName)
        if destination == .user {
            return language.text("\(name) 현재 위치 보기", "Show \(name) location")
        }
        if let kind = destination.placeKind,
           model.settings.frequentPlaces.first(where: { $0.kind == kind })?.point != nil {
            return language.text("\(name) 위치 보기", "Show \(name) location")
        }
        return language.text("\(name) 위치 설정", "Set \(name) location")
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

    private var displayMenuItem: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                isDisplayMenuExpanded.toggle()
            } label: {
                HStack(spacing: 13) {
                    Image(systemName: "rectangle.3.group")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.tpReferenceBlue)
                        .frame(width: 24)
                    Text(language.text("표시", "Display"))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Spacer()
                    Image(systemName: isDisplayMenuExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.primary)
                .padding(.vertical, 12)
                .padding(.horizontal, 12)
                .background(
                    Color.tpReferenceBlue.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            }
            .buttonStyle(.plain)

            if isDisplayMenuExpanded {
                Toggle(
                    isOn: Binding(
                        get: { model.settings.weatherSidebarVisible },
                        set: { model.setWeatherSidebarVisible($0) }
                    )
                ) {
                    Label(
                        language.text("날씨", "Weather"),
                        systemImage: "cloud.sun.fill"
                    )
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                }
                .tint(Color.tpReferenceBlue)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .padding(.leading, 12)
            }
        }
    }

    private var settingsMenuItem: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                isSettingsMenuExpanded.toggle()
            } label: {
                HStack(spacing: 13) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.tpReferenceRose)
                        .frame(width: 24)
                    Text(language.text("설정", "Settings"))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Spacer()
                    Image(systemName: isSettingsMenuExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.primary)
                .padding(.vertical, 12)
                .padding(.horizontal, 12)
                .background(
                    Color.tpReferenceRose.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(language.text("설정 목록", "Settings list"))

            if isSettingsMenuExpanded {
                Button {
                    isDataProtectionPresented = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.tpReferenceRose)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(language.text("데이터 보호", "Data Protection"))
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                            Text(dataProtectionStatusText)
                                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(Color.primary)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 8)
                    .background(
                        Color.tpReferenceRose.opacity(0.055),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(language.text("데이터 보호 열기", "Open data protection"))
                .padding(.leading, 12)

                Button {
                    isSettingsResetConfirmationPresented = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.tpReferenceRose)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(language.text("설정 초기화", "Reset settings"))
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                            Text(
                                language.text(
                                    "화면·연동 설정을 기본값으로 복원",
                                    "Restore display and integration settings"
                                )
                            )
                                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(Color.primary)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 8)
                    .background(
                        Color.tpReferenceRose.opacity(0.055),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(language.text("설정 초기화", "Reset settings"))
                .padding(.leading, 12)
            }
        }
    }

    private var dataProtectionStatusText: String {
        if model.securityStatus.settings.midnightBackupEnabled {
            return language.text("00:00 자동 백업 켜짐", "00:00 automatic backup on")
        }
        if model.securityStatus.settings.cloudBackupEnabled {
            return language.text("월별 iCloud 백업 켜짐", "Monthly iCloud backup on")
        }
        if model.securityStatus.settings.lockOnLaunch {
            return language.text("앱 열 때마다 잠금", "Locks whenever the app opens")
        }
        return model.securityStatus.hasPIN
            ? language.text("비밀번호 등록됨", "Password registered")
            : language.text("보호 설정 안 됨", "Not configured")
    }

    private var gpsLoggingMenuItem: some View {
        let isLogging = true
        let preferences = model.settings.gpsLoggingPreferences
        let tint = Color.tpReferenceRose
        return VStack(alignment: .leading, spacing: 7) {
            Button {
                if !isGPSLoggingMenuExpanded {
                    gpsLoggingIntervalDraftSeconds = preferences.intervalSeconds
                }
                isGPSLoggingMenuExpanded.toggle()
            } label: {
                HStack(spacing: 13) {
                    Image(systemName: isLogging ? "location.fill" : "location.viewfinder")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(
                            isLogging
                                ? language.text("실시간 GPS 기록 중", "Live GPS logging")
                                : language.text("실시간 GPS 기록", "Live GPS logging")
                        )
                        .font(.system(size: 16, weight: .semibold, design: .rounded))

                        Text(
                            gpsLoggingIntervalText(preferences.effectiveIntervalSeconds)
                        )
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: isGPSLoggingMenuExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.primary)
                .padding(.vertical, 12)
                .padding(.horizontal, 12)
                .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(language.text("실시간 GPS 기록 설정", "Live GPS logging settings"))

            if isGPSLoggingMenuExpanded {
                VStack(alignment: .leading, spacing: 11) {
                    Toggle(
                        isOn: Binding(
                            get: { model.settings.gpsLoggingPreferences.isBatteryMinimal },
                            set: { model.setGPSLoggingBatteryMinimal($0) }
                        )
                    ) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(language.text("배터리 최소", "Minimum battery"))
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                            Text(
                                language.text(
                                    "10분마다 GPS와 사용 가능한 센서값을 기록",
                                    "Records GPS and available sensor values every 10 min"
                                )
                            )
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                        }
                    }
                    .tint(Color.tpReferenceMint)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(language.text("시간", "Interval"))
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                            Spacer()
                            Text(gpsLoggingIntervalText(gpsLoggingIntervalDisplay(preferences)))
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(tint)
                        }

                        Slider(
                            value: Binding(
                                get: {
                                    Double(
                                        GPSLoggingPreferences.supportedIntervalSeconds
                                            .firstIndex(of: gpsLoggingIntervalDraftSeconds) ?? 0
                                    )
                                },
                                set: { value in
                                    let index = min(
                                        max(Int(value.rounded()), 0),
                                        GPSLoggingPreferences.supportedIntervalSeconds.count - 1
                                    )
                                    gpsLoggingIntervalDraftSeconds =
                                        GPSLoggingPreferences.supportedIntervalSeconds[index]
                                }
                            ),
                            in: 0...Double(GPSLoggingPreferences.supportedIntervalSeconds.count - 1),
                            step: 1,
                            onEditingChanged: { isEditing in
                                if !isEditing {
                                    model.setGPSLoggingIntervalSeconds(gpsLoggingIntervalDraftSeconds)
                                }
                            }
                        )
                        .tint(tint)
                        .disabled(preferences.isBatteryMinimal)
                        .accessibilityLabel(language.text("GPS 기록 시간", "GPS logging interval"))
                        .accessibilityValue(gpsLoggingIntervalText(gpsLoggingIntervalDisplay(preferences)))

                        HStack {
                            Text(language.text("실시간 1초", "Live 1 sec"))
                            Spacer()
                            Text(language.text("기본 5분", "Default 5 min"))
                            Spacer()
                            Text(language.text("15분", "15 min"))
                        }
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(11)
                .background(tint.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                .padding(.leading, 12)
            }
        }
    }

    private func gpsLoggingIntervalDisplay(
        _ preferences: GPSLoggingPreferences
    ) -> Int {
        preferences.isBatteryMinimal
            ? preferences.effectiveIntervalSeconds
            : gpsLoggingIntervalDraftSeconds
    }

    private func gpsLoggingIntervalText(_ seconds: Int) -> String {
        if seconds < 60 {
            return language.text(
                seconds == 1 ? "실시간 · 1초마다" : "\(seconds)초마다 위치 확인",
                seconds == 1 ? "Live · every second" : "Checks location every \(seconds) sec"
            )
        }
        let minutes = seconds / 60
        return language.text(
            "\(minutes)분마다 위치 확인",
            "Checks location every \(minutes) min"
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

    private var placeAnnotations: [MapHomePlaceAnnotation] {
        model.settings.frequentPlaces.compactMap { place in
            guard let destination = MapHomeLocationDestination(placeKind: place.kind),
                  let point = place.point,
                  isValid(point) else { return nil }
            return MapHomePlaceAnnotation(
                id: place.id,
                name: place.name,
                floor: place.floor,
                destination: destination,
                coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
            )
        }
    }

    private var transitAnnotations: [MapHomeTransitAnnotation] {
        model.settings.userTransitLocations.compactMap { location in
            guard isValid(location.point) else { return nil }
            return MapHomeTransitAnnotation(
                id: location.id,
                name: location.name,
                kind: location.kind,
                coordinate: CLLocationCoordinate2D(
                    latitude: location.point.latitude,
                    longitude: location.point.longitude
                )
            )
        }
    }

    private var currentCoordinate: CLLocationCoordinate2D? {
        let point = model.latestSensorReading?.point ?? model.liveRouteState.readings.last?.point
        guard let point, isValid(point) else { return nil }
        return CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
    }

    private func weatherContext(at minute: Int) -> WeatherContext? {
        let calendar = Calendar.autoupdatingCurrent
        let clampedMinute = min(max(minute, 0), MapHomeTimeSidebarMath.fullDayMinutes - 1)
        guard let date = calendar.date(
            byAdding: .minute,
            value: clampedMinute,
            to: calendar.startOfDay(for: model.selectedDate)
        ) else { return nil }
        return MapHomeWeatherTimelineMath.context(
            at: date,
            contexts: model.snapshot.weather
        )
    }

    private func currentActivity(at minute: Int) -> MapHomeTimeSidebarActivity {
        let segment = MapHomeTimeRailSegmentEngine.segment(
            at: minute,
            in: timeRailSegments
        ) ?? .wholeDayUnconfirmed
        return .majorCategory(
            segment.categoryID,
            accessibilityLabel: segment.title,
            categoryColors: model.settings.mapCategoryColors
        )
    }

    private func mapCategoryColor(_ id: String) -> Color {
        Color(
            hex: model.settings.mapCategoryColors[id]
                ?? CanonicalCategoryPalette.hex(id)
        )
    }

    private func refreshTimeRailSegments() {
        let next = MapHomeTimeRailSegmentEngine.segments(
            from: model.snapshot.actuals,
            travel: model.snapshot.travel,
            on: model.selectedDate
        )
        guard next != timeRailSegments else { return }
        timeRailSegments = next
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

    private var timelineRouteOverlays: [MapHomeTimelineRouteOverlay] {
        (routeProjection?.segments ?? []).compactMap { segment in
            let coordinates = segment.coordinates.compactMap { point -> CLLocationCoordinate2D? in
                guard isValid(point) else { return nil }
                return CLLocationCoordinate2D(
                    latitude: point.latitude,
                    longitude: point.longitude
                )
            }
            guard coordinates.count >= 2 else { return nil }
            return MapHomeTimelineRouteOverlay(
                id: segment.id,
                categoryID: segment.category.rawValue,
                opacity: segment.opacity,
                coordinates: coordinates
            )
        }
    }

    private var effectiveTimelineMinute: Int {
        timelineSelectionMinute()
    }

    private func timelineSelectionMinute(
        at now: Date = .now
    ) -> Int {
        if isTimelineSelectionPinned, let selectedTimelineMinute {
            return selectedTimelineMinute
        }
        return selectedTimelineMinute ?? MapHomeTimeSidebarMath.defaultTimelineMinute(
            for: model.selectedDate,
            now: now,
            calendar: .autoupdatingCurrent
        )
    }

    private var timelineSelectionSpan: TimeSpan? {
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: model.selectedDate)
        guard let segment = MapHomeTimeRailSegmentEngine.segment(
            at: effectiveTimelineMinute,
            in: timeRailSegments
        ), let end = calendar.date(
            byAdding: .minute,
            value: segment.endMinute,
            to: dayStart
        ), let start = calendar.date(
            byAdding: .minute,
            value: segment.startMinute,
            to: dayStart
        ) else { return nil }
        return TimeSpan(start: start, end: end)
    }

    private func refreshRouteReadings(for date: Date) async {
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: date)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
        else { return }
        let readings = await model.sensorReadings(
            in: TimeSpan(start: dayStart, end: dayEnd)
        )
        guard !Task.isCancelled,
              calendar.isDate(date, inSameDayAs: model.selectedDate)
        else { return }
        routeReadings = readings
        let projection = refreshRouteProjection()
        if selectedTimelineMinute != nil,
           let point = projection?.coordinateAtCutoff {
            focusMap(on: point)
        } else {
            focusMapIfNeeded()
        }
    }

    @discardableResult
    private func refreshRouteProjection() -> RouteTimelineProjection? {
        let calendar = Calendar.autoupdatingCurrent
        let liveReadings = model.liveRouteState.readings
            + (model.latestSensorReading.map { [$0] } ?? [])
        let timelineDate = calendar.date(
            byAdding: .minute,
            value: effectiveTimelineMinute,
            to: calendar.startOfDay(for: model.selectedDate)
        )
        let next = RouteTimelineDataEngine.project(
            selectedDate: model.selectedDate,
            through: timelineDate,
            selectedSpan: timelineSelectionSpan,
            actuals: model.snapshot.actuals,
            readings: routeReadings,
            liveReadings: liveReadings,
            calendar: calendar
        )
        guard routeProjection != next else { return next }
        routeProjection = next
        return next
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
        let weekdayFormatter = DateFormatter()
        weekdayFormatter.locale = language.locale
        weekdayFormatter.dateFormat = language.weekdayFormat
        let weekday = Calendar.autoupdatingCurrent.component(.weekday, from: model.selectedDate)
        let weekdayText = Text(" \(weekdayFormatter.string(from: model.selectedDate))")
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .foregroundStyle(dateColor(weekday: weekday))
        return datePartTitleLabel + weekdayText
    }

    private var datePartTitleLabel: Text {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = language.locale
        dateFormatter.dateFormat = language.datePartFormat
        return Text(dateFormatter.string(from: model.selectedDate))
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .foregroundStyle(
                dateColor(
                    weekday: Calendar.autoupdatingCurrent.component(
                        .weekday,
                        from: model.selectedDate
                    )
                )
            )
    }

    private var ink: Color {
        .tpInk
    }

    private func dateColor(weekday: Int) -> Color {
        if TimelineAxisGrid.koreanHolidayName(on: model.selectedDate) != nil || weekday == 1 {
            return .tpHoliday
        }
        if weekday == 7 { return .tpSaturday }
        return ink
    }

    private func jumpToTodayAndCurrentMapPosition() {
        model.selectedDate = Date()
        selectedTimelineMinute = nil
        isTimelineSelectionPinned = false
        sharedZoomLevel = 1
        zoomResetToken += 1
        focusMapForSharedZoom()
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
        let routeCoordinates = timelineRouteOverlays.flatMap(\.coordinates)
        let coordinates = routeCoordinates.isEmpty
            ? subwayRouteOverlays.flatMap(\.coordinates)
            : routeCoordinates
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

    private func sharedZoomLevel(for span: MKCoordinateSpan) -> CGFloat? {
        let routeCoordinates = timelineRouteOverlays.flatMap(\.coordinates)
        let subwayCoordinates = subwayRouteOverlays.flatMap(\.coordinates)
        let coordinates: [CLLocationCoordinate2D]
        if !routeCoordinates.isEmpty {
            coordinates = routeCoordinates
        } else if !subwayCoordinates.isEmpty {
            coordinates = subwayCoordinates
        } else if let currentCoordinate {
            coordinates = [currentCoordinate]
        } else {
            return nil
        }
        guard let first = coordinates.first else { return nil }
        let fitLatitude = max(0.025, ((coordinates.map(\.latitude).max() ?? first.latitude) - (coordinates.map(\.latitude).min() ?? first.latitude)) * 1.8)
        let fitLongitude = max(0.035, ((coordinates.map(\.longitude).max() ?? first.longitude) - (coordinates.map(\.longitude).min() ?? first.longitude)) * 1.8)
        let scale = max(span.latitudeDelta / fitLatitude, span.longitudeDelta / fitLongitude)
        return min(max((scale - 0.05) / 0.95, 0), 1)
    }

    private func focusMapForSharedZoom() {
        let routeCoordinates = timelineRouteOverlays.flatMap(\.coordinates)
        let subwayCoordinates = subwayRouteOverlays.flatMap(\.coordinates)
        let coordinates: [CLLocationCoordinate2D]
        if !routeCoordinates.isEmpty {
            coordinates = routeCoordinates
        } else if !subwayCoordinates.isEmpty {
            coordinates = subwayCoordinates
        } else if let currentCoordinate {
            coordinates = [currentCoordinate]
        } else {
            mapPosition = .automatic
            return
        }
        guard let first = coordinates.first else {
            mapPosition = .automatic
            return
        }
        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        let fitLatitude = max(0.025, ((latitudes.max() ?? first.latitude) - (latitudes.min() ?? first.latitude)) * 1.8)
        let fitLongitude = max(0.035, ((longitudes.max() ?? first.longitude) - (longitudes.min() ?? first.longitude)) * 1.8)
        let zoom = 1 - sharedZoomLevel
        let spanScale = max(0.05, 1 - 0.95 * zoom)
        mapPosition = .region(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: ((latitudes.max() ?? first.latitude) + (latitudes.min() ?? first.latitude)) / 2,
                    longitude: ((longitudes.max() ?? first.longitude) + (longitudes.min() ?? first.longitude)) / 2
                ),
                span: MKCoordinateSpan(
                    latitudeDelta: max(0.001, fitLatitude * spanScale),
                    longitudeDelta: max(0.001, fitLongitude * spanScale)
                )
            )
        )
    }

    private func focusMap(on point: GeoPoint) {
        let coordinate = CLLocationCoordinate2D(
            latitude: point.latitude,
            longitude: point.longitude
        )
        mapPosition = .region(
            MKCoordinateRegion(center: coordinate, span: visibleMapSpan)
        )
        updateUserCenterState(for: coordinate)
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

    private func toggleMapHeadingMode() {
        compassControlState = compassControlState.toggled
        if compassControlState.followsHeading {
            headingMonitor.start()
            mapPosition = .userLocation(
                followsHeading: true,
                fallback: .automatic
            )
        } else {
            headingMonitor.stop()
            focusUserLocation()
        }
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

    private func updateVisibleMapSpan(_ span: MKCoordinateSpan) {
        let next = MKCoordinateSpan(
            latitudeDelta: min(max(span.latitudeDelta, 0.002), 80),
            longitudeDelta: min(max(span.longitudeDelta, 0.002), 80)
        )
        guard abs(visibleMapSpan.latitudeDelta - next.latitudeDelta) > 0.000_1
            || abs(visibleMapSpan.longitudeDelta - next.longitudeDelta) > 0.000_1
        else { return }
        visibleMapSpan = next
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

private struct MapHomeDataProtectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let language: MapHomeLanguage
    @State private var isWorking = false
    @State private var resultMessage: String?

    private var isProtected: Bool {
        model.biometricDataProtectionStatus.isProtected
    }

    private var statusTitle: String {
        switch model.biometricDataProtectionStatus {
        case let .protected(createdAt):
            let formatter = DateFormatter()
            formatter.locale = language.locale
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return language.text("보호 사본 생성됨", "Protected copy created")
                + " · " + formatter.string(from: createdAt)
        case .notProtected:
            return language.text("보호 사본 없음", "No protected copy")
        case .unavailable:
            return language.text("보호 저장소를 사용할 수 없음", "Protection storage unavailable")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.tpReferenceRose)
                    .frame(width: 46, height: 46)
                    .background(
                        Color.tpReferenceRose.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(language.text("데이터 보호", "Data Protection"))
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                    Text(statusTitle)
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(language.text("닫기", "Close")) { dismiss() }
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }

            Text(
                language.text(
                    "현재 기록을 LZFSE로 압축한 뒤 AES-GCM으로 암호화한 보호 사본을 이 기기에 만듭니다.",
                    "Creates an on-device protected copy by LZFSE-compressing and AES-GCM-encrypting your current records."
                )
            )
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            Text(
                language.text(
                    "Face ID 또는 Touch ID는 키체인 암호키를 여는 승인에만 사용되며, 생체 정보는 앱·iCloud·백업에 저장되지 않습니다.",
                    "Face ID or Touch ID only authorizes access to the Keychain encryption key. Biometric data is never stored in the app, iCloud, or the backup."
                )
            )
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(12)
                .background(
                    Color.tpReferenceBlue.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                )

            if let resultMessage {
                Text(resultMessage)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(isProtected ? Color.tpReferenceBlue : Color.tpReferenceRose)
            }

            Button {
                protectCurrentSnapshot()
            } label: {
                HStack(spacing: 8) {
                    if isWorking {
                        ProgressView()
                            .tint(.white)
                            .controlSize(.small)
                    } else {
                        Image(systemName: isProtected ? "arrow.clockwise" : "faceid")
                    }
                    Text(
                        isProtected
                            ? language.text("보호 사본 갱신", "Update protected copy")
                            : language.text("생체 인증으로 보호 시작", "Protect with biometrics")
                    )
                }
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .foregroundStyle(.white)
                .background(Color.tpReferenceRose, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .disabled(isWorking)

            if isProtected {
                Button {
                    validateProtectedSnapshot()
                } label: {
                    Label(
                        language.text("생체 인증으로 보호 사본 확인", "Verify protected copy with biometrics"),
                        systemImage: "checkmark.shield.fill"
                    )
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.tpReferenceBlue)
                .disabled(isWorking)
            }
        }
        .padding(22)
        .background(Color.tpSurface)
        .task {
            model.refreshBiometricDataProtectionStatus()
        }
    }

    private func protectCurrentSnapshot() {
        guard !isWorking else { return }
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            do {
                try await model.protectCurrentDataWithBiometrics()
                resultMessage = language.text(
                    "생체 인증으로 잠긴 보호 사본을 만들었습니다.",
                    "A biometric-protected copy was created."
                )
            } catch {
                resultMessage = error.localizedDescription
            }
        }
    }

    private func validateProtectedSnapshot() {
        guard !isWorking else { return }
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            do {
                try await model.validateBiometricProtectedData()
                resultMessage = language.text(
                    "보호 사본을 확인했습니다.",
                    "The protected copy was verified."
                )
            } catch {
                resultMessage = error.localizedDescription
            }
        }
    }
}

private struct MapHomeSecuritySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let language: MapHomeLanguage
    @State private var pin = ""
    @State private var confirmation = ""
    @State private var message: String?
    @State private var pendingRestore: TaptionDataSnapshot?
    @State private var isRestoreConfirmationPresented = false
    @State private var isApplyingRestore = false

    private var security: PlanSecurityStatus { model.securityStatus }
    private var hasPIN: Bool { security.hasPIN }
    private var appLockEnabled: Bool {
        security.settings.lockOnLaunch && security.settings.lockOnForeground
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.tpReferenceRose)
                        .frame(width: 46, height: 46)
                        .background(
                            Color.tpReferenceRose.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 14)
                        )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(language.text("데이터 보호", "Data Protection"))
                            .font(.system(size: 21, weight: .bold, design: .rounded))
                        Text(hasPIN
                            ? language.text("4자리 비밀번호 등록됨", "4-digit password registered")
                            : language.text("백업 전 비밀번호 등록 필요", "Set a password before backup")
                        )
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(language.text("닫기", "Close")) { dismiss() }
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                }

                card(language.text("4자리 비밀번호", "4-digit password")) {
                    SecureField(language.text("비밀번호", "Password"), text: $pin)
                        .keyboardType(.numberPad)
                        .textContentType(.newPassword)
                        .onChange(of: pin) { _, value in pin = numericPIN(value) }
                    SecureField(language.text("비밀번호 확인", "Confirm password"), text: $confirmation)
                        .keyboardType(.numberPad)
                        .textContentType(.newPassword)
                        .onChange(of: confirmation) { _, value in confirmation = numericPIN(value) }
                    Button(language.text("비밀번호 저장", "Save password")) {
                        savePIN()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.tpReferenceRose)
                    .disabled(pin.count != 4 || confirmation.count != 4)
                }

                card(language.text("앱 잠금", "App lock")) {
                    Toggle(
                        language.text("앱을 열 때마다 잠금", "Lock whenever the app opens"),
                        isOn: Binding(
                            get: { appLockEnabled },
                            set: { setAppLock($0) }
                        )
                    )
                    .tint(Color.tpReferenceRose)
                    Toggle(
                        language.text("Face ID / Touch ID 사용", "Use Face ID / Touch ID"),
                        isOn: Binding(
                            get: { security.settings.biometricUnlockEnabled },
                            set: { setBiometricUnlock($0) }
                        )
                    )
                    .tint(Color.tpReferenceMint)
                    Text(language.text(
                        "생체 인증은 빠른 잠금 해제용이며, 생체 정보는 앱이나 백업에 저장되지 않습니다.",
                        "Biometrics are only a fast local unlock; biometric data is never stored."
                    ))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                }

                card(language.text("iCloud 백업", "iCloud Backup")) {
                    Toggle(
                        language.text("월별 암호화 백업", "Monthly encrypted backup"),
                        isOn: Binding(
                            get: { security.settings.cloudBackupEnabled },
                            set: { setCloudBackup($0) }
                        )
                    )
                    .tint(Color.tpReferenceBlue)
                    Toggle(
                        language.text("00:00에 백업", "Back up at 00:00"),
                        isOn: Binding(
                            get: { security.settings.midnightBackupEnabled },
                            set: { setMidnightBackup($0) }
                        )
                    )
                    .tint(Color.tpReferenceMint)
                    Text(language.text(
                        "iCloud Drive/Taption Plan에 월별 단일 암호화 파일로 저장합니다. 같은 iCloud 계정이면 새 기기와 비밀번호 분실 후에도 복구할 수 있습니다.",
                        "One encrypted file is saved per month in iCloud Drive/Taption Plan. The same iCloud account can recover it on a new device or after password loss."
                    ))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button(language.text("지금 백업", "Back up now")) { saveBackup() }
                            .buttonStyle(.bordered)
                            .disabled(!security.settings.cloudBackupEnabled)
                        Button(language.text("백업 불러오기", "Restore backup")) { prepareRestore() }
                            .buttonStyle(.bordered)
                            .disabled(!hasPIN)
                    }
                }

                if let message {
                    Text(message)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.tpReferenceBlue)
                }
            }
            .padding(22)
        }
        .background(Color.tpSurface)
        .alert(
            language.text("iCloud 백업 불러오기", "Restore iCloud backup"),
            isPresented: $isRestoreConfirmationPresented
        ) {
            Button(language.text("취소", "Cancel"), role: .cancel) {
                pendingRestore = nil
            }
            Button(language.text("현재 데이터 교체", "Replace current data"), role: .destructive) {
                applyRestore()
            }
        } message: {
            Text(language.text(
                "현재 기기의 기록을 백업 내용으로 교체합니다.",
                "Current records on this device will be replaced by the backup."
            ))
        }
    }

    @ViewBuilder
    private func card<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .bold, design: .rounded))
            content()
        }
        .padding(13)
        .background(
            Color.tpSurfaceBlue.opacity(0.72),
            in: RoundedRectangle(cornerRadius: 14)
        )
    }

    private func numericPIN(_ value: String) -> String {
        String(value.filter(\.isNumber).prefix(4))
    }

    private func savePIN() {
        guard pin == confirmation else {
            message = language.text("비밀번호 확인이 일치하지 않습니다.", "Passwords do not match.")
            return
        }
        perform {
            try model.configureBackupPIN(pin)
            pin = ""
            confirmation = ""
            message = language.text("비밀번호를 저장했습니다.", "Password saved.")
        }
    }

    private func setAppLock(_ enabled: Bool) {
        var value = security.settings
        value.lockOnLaunch = enabled
        value.lockOnForeground = enabled
        configure(value)
    }

    private func setBiometricUnlock(_ enabled: Bool) {
        var value = security.settings
        value.biometricUnlockEnabled = enabled
        configure(value)
    }

    private func setCloudBackup(_ enabled: Bool) {
        var value = security.settings
        value.cloudBackupEnabled = enabled
        configure(value)
    }

    private func setMidnightBackup(_ enabled: Bool) {
        var value = security.settings
        value.midnightBackupEnabled = enabled
        configure(value)
    }

    private func configure(_ value: PlanAppLockSettings) {
        perform {
            try model.configureAppLock(value)
            message = language.text("보안 설정을 저장했습니다.", "Security settings saved.")
        }
    }

    private func saveBackup() {
        performAsync {
            try await model.saveCloudBackupNow()
            message = language.text("iCloud 백업을 저장했습니다.", "iCloud backup saved.")
        }
    }

    private func prepareRestore() {
        performAsync {
            pendingRestore = try await model.loadCloudBackup()
            isRestoreConfirmationPresented = pendingRestore != nil
        }
    }

    private func applyRestore() {
        guard let pendingRestore, !isApplyingRestore else { return }
        isApplyingRestore = true
        Task { @MainActor in
            await model.applyCloudBackup(pendingRestore)
            self.pendingRestore = nil
            self.isApplyingRestore = false
            message = language.text("백업을 불러왔습니다.", "Backup restored.")
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            message = error.localizedDescription
        }
    }

    private func performAsync(_ action: @escaping () async throws -> Void) {
        Task { @MainActor in
            do {
                try await action()
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

private struct MapHomeLocationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let destination: MapHomeLocationDestination
    let language: MapHomeLanguage
    let onSaved: () -> Void
    @State private var showsDeleteConfirmation = false

    private var place: FrequentPlace? {
        guard let kind = destination.placeKind else { return nil }
        return model.settings.frequentPlaces.first { $0.kind == kind }
    }

    private var hasCurrentLocation: Bool {
        model.latestSensorReading?.point != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                MapHomeLocationThumbnail(destination: destination)
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        language.text(destination.koreanName, destination.englishName)
                            + language.text(" 위치 설정", " location")
                    )
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    if let place, place.point != nil {
                        Text(language.text("현재 저장 상태", "Saved") + " · Lv.\(place.floor ?? 1)")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(
                            language.text(
                                "현재 위치를 기준으로 저장할 수 있습니다",
                                "Save this place from your current location"
                            )
                        )
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            Text(
                hasCurrentLocation
                    ? language.text(
                        "현재 위치를 이 장소의 기준 위치로 저장합니다. 좌표는 화면에 표시하지 않습니다.",
                        "Save the current location as this place. Coordinates are not shown."
                    )
                    : language.text(
                        "현재 위치를 받는 중입니다. 위치 기록이 잡히면 저장할 수 있습니다.",
                        "Waiting for location. Save becomes available when a location is recorded."
                    )
            )
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            Button {
                guard let place else { return }
                model.setFrequentPlaceToCurrentLocation(place.id)
                onSaved()
                dismiss()
            } label: {
                Label(
                    place?.point == nil
                        ? language.text("현재 위치로 저장", "Save current location")
                        : language.text("현재 위치로 다시 저장", "Update current location"),
                    systemImage: "location.fill"
                )
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(.white)
                .background(destination.tint, in: RoundedRectangle(cornerRadius: 13))
            }
            .buttonStyle(.plain)
            .disabled(place == nil || !hasCurrentLocation)
            .opacity(place == nil || !hasCurrentLocation ? 0.46 : 1)

            Button(role: .destructive) {
                showsDeleteConfirmation = true
            } label: {
                Label(
                    language.text("저장된 위치 삭제", "Delete saved location"),
                    systemImage: "trash"
                )
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .foregroundStyle(Color.red)
                .background(
                    Color.red.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 13)
                )
            }
            .buttonStyle(.plain)
            .disabled(place?.point == nil)
            .opacity(place?.point == nil ? 0.38 : 1)
        }
        .padding(22)
        .background(Color.tpSurface)
        .confirmationDialog(
            language.text(
                "저장된 위치를 삭제할까요?",
                "Delete the saved location?"
            ),
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                language.text("저장된 위치 삭제", "Delete saved location"),
                role: .destructive
            ) {
                guard let place else { return }
                model.clearFrequentPlaceLocation(place.id)
                onSaved()
                dismiss()
            }
            Button(language.text("취소", "Cancel"), role: .cancel) {}
        }
    }
}

private struct MapHomeSubwayRouteOverlay: Identifiable {
    let id: UUID
    let coordinates: [CLLocationCoordinate2D]
}

private struct MapHomeTimelineRouteOverlay: Identifiable {
    let id: String
    let categoryID: String
    let opacity: Double
    let coordinates: [CLLocationCoordinate2D]
}

private struct MapHomePlaceAnnotation: Identifiable {
    let id: UUID
    let name: String
    let floor: Int?
    let destination: MapHomeLocationDestination
    let coordinate: CLLocationCoordinate2D
}

private struct MapHomeTransitAnnotation: Identifiable {
    let id: UUID
    let name: String
    let kind: UserTransitLocationKind
    let coordinate: CLLocationCoordinate2D
}

private struct MapHomePlacePin: View {
    let name: String
    let floor: Int?
    let destination: MapHomeLocationDestination

    var body: some View {
        VStack(spacing: 5) {
            MapHomeMarkerLabel(title: name, color: destination.tint)

            MapHomeLocationThumbnail(destination: destination, size: 48)
                .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.13), radius: 6, y: 3)

            Text("Lv.\(floor ?? 1)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(destination.tint)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.white, in: Capsule())
                .shadow(color: .black.opacity(0.10), radius: 5, y: 2)
        }
        .accessibilityLabel("\(name), 레벨 \(floor ?? 1)")
    }
}

private struct MapHomeTransitPlacePin: View {
    let name: String
    let kind: UserTransitLocationKind

    var body: some View {
        VStack(spacing: 4) {
            MapHomeMarkerLabel(title: name, color: Color.tpReferenceBlue)
            Image(systemName: kind.systemImage)
                .font(.system(size: 5.5, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.tpReferenceBlue, in: Circle())
                .overlay { Circle().stroke(.white, lineWidth: 1) }
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
        }
        .accessibilityLabel("\(name), \(kind.title)")
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

private struct MapHomeScrollBounceDisabler: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        UIView(frame: .zero)
    }

    func updateUIView(_ view: UIView, context: Context) {
        DispatchQueue.main.async {
            var ancestor = view.superview
            while let current = ancestor {
                if let scrollView = current as? UIScrollView {
                    scrollView.bounces = false
                    scrollView.alwaysBounceVertical = false
                    return
                }
                ancestor = current.superview
            }
        }
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

    private var weekday: Int {
        calendar.component(.weekday, from: date)
    }

    private var assetName: String {
        if style == .holiday {
            return "MapHomeCalendarSunday"
        }
        switch weekday {
        case 1: return "MapHomeCalendarSunday"
        case 2: return "MapHomeCalendarMonday"
        case 3: return "MapHomeCalendarTuesday"
        case 4: return "MapHomeCalendarWednesday"
        case 5: return "MapHomeCalendarThursday"
        case 6: return "MapHomeCalendarFriday"
        default: return "MapHomeCalendarSaturday"
        }
    }

    var body: some View {
        Image(assetName)
            .resizable()
            .scaledToFit()
            .frame(width: 24, height: 25)
        .accessibilityLabel(
            language.text("\(day)일 달력", "Calendar, day \(day)")
        )
    }
}

private struct MapHomeSearchResult: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let coordinate: CLLocationCoordinate2D
}

private enum MapHomeUserLocationSelection: Identifiable, Hashable {
    case frequentPlace(UUID)
    case transit(UUID)

    var id: String {
        switch self {
        case .frequentPlace(let id): "frequent-" + id.uuidString
        case .transit(let id): "transit-" + id.uuidString
        }
    }
}

private struct MapHomeUserLocationActionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let selection: MapHomeUserLocationSelection
    let language: MapHomeLanguage

    @State private var name = ""
    @State private var isEditing = false
    @State private var showsDeleteConfirmation = false

    private var frequentPlace: FrequentPlace? {
        guard case .frequentPlace(let id) = selection else { return nil }
        return model.settings.frequentPlaces.first { $0.id == id }
    }

    private var transitLocation: UserTransitLocation? {
        guard case .transit(let id) = selection else { return nil }
        return model.settings.userTransitLocations.first { $0.id == id }
    }

    private var locationName: String {
        frequentPlace?.name ?? transitLocation?.name ?? ""
    }

    private var locationSubtitle: String {
        if let transitLocation {
            return language.text(
                transitLocation.kind.title,
                transitLocation.kind == .subwayStation ? "Subway station" : "Bus stop"
            )
        }
        return language.text("사용자 위치", "User location")
    }

    private var locationIcon: String {
        transitLocation?.kind.systemImage ?? FrequentPlaceKind.custom.systemImage
    }

    private var locationTint: Color {
        transitLocation == nil
            ? MapHomeLocationDestination.user.tint
            : Color.tpReferenceBlue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: locationIcon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(locationTint)
                    .frame(width: 34, height: 34)
                    .background(
                        locationTint.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(locationName)
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    Text(locationSubtitle)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if isEditing {
                TextField(
                    language.text("위치 이름", "Location name"),
                    text: $name
                )
                .textFieldStyle(.roundedBorder)

                HStack(spacing: 8) {
                    Button(language.text("취소", "Cancel")) {
                        name = locationName
                        isEditing = false
                    }
                    .buttonStyle(.bordered)

                    Button(language.text("저장", "Save")) {
                        saveName()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Button {
                    name = locationName
                    isEditing = true
                } label: {
                    Label(
                        language.text("위치 편집", "Edit location"),
                        systemImage: "pencil"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    showsDeleteConfirmation = true
                } label: {
                    Label(
                        language.text("위치 삭제", "Delete location"),
                        systemImage: "trash"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .background(Color.tpSurface)
        .onAppear {
            name = locationName
        }
        .confirmationDialog(
            language.text("이 위치를 삭제할까요?", "Delete this location?"),
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(language.text("위치 삭제", "Delete location"), role: .destructive) {
                deleteLocation()
            }
            Button(language.text("취소", "Cancel"), role: .cancel) {}
        }
    }

    private func saveName() {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        switch selection {
        case .frequentPlace(let id):
            model.renameFrequentPlace(id, name: cleanName)
        case .transit(let id):
            model.renameUserTransitLocation(id, name: cleanName)
        }
        name = cleanName
        isEditing = false
    }

    private func deleteLocation() {
        switch selection {
        case .frequentPlace(let id):
            model.deleteFrequentPlace(id)
        case .transit(let id):
            model.deleteUserTransitLocation(id)
        }
        dismiss()
    }
}

private struct MapHomeSearchPinLocationSheet: View {
    @Bindable var model: AppModel
    let result: MapHomeSearchResult
    let language: MapHomeLanguage
    let onSaved: (MapHomeUserLocationSelection?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(language.text("위치 추가", "Add location"))
                .font(.system(size: 20, weight: .bold, design: .rounded))
            VStack(alignment: .leading, spacing: 3) {
                Text(result.title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                if !result.subtitle.isEmpty {
                    Text(result.subtitle)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 8
            ) {
                ForEach(MapHomeLocationDestination.allCases) { destination in
                    Button {
                        save(destination)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: destination.systemImage)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(destination.tint)
                            Text(language.text(destination.koreanName, destination.englishName))
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 11)
                        .background(
                            destination.tint.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            Text(language.text("대중교통 위치", "Transit location"))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 8
            ) {
                ForEach(UserTransitLocationKind.allCases, id: \.self) { kind in
                    Button {
                        saveTransit(kind)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: kind.systemImage)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.tpReferenceBlue)
                            Text(
                                language.text(
                                    kind.title,
                                    kind == .subwayStation ? "Subway station" : "Bus stop"
                                )
                            )
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 11)
                        .background(
                            Color.tpReferenceBlue.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
        }
        .padding(20)
        .background(Color.tpSurface)
    }

    private func save(_ destination: MapHomeLocationDestination) {
        let latitude = result.coordinate.latitude
        let longitude = result.coordinate.longitude
        if let kind = destination.placeKind,
           let place = model.settings.frequentPlaces.first(where: { $0.kind == kind }) {
            model.setFrequentPlaceLocation(
                place.id,
                latitude: latitude,
                longitude: longitude
            )
        } else if destination == .user {
            model.addCustomFrequentPlace(name: result.title)
            if let place = model.settings.frequentPlaces.last(where: {
                $0.kind == .custom && $0.name == result.title
            }) {
                model.setFrequentPlaceLocation(
                    place.id,
                    latitude: latitude,
                    longitude: longitude
                )
            }
        }
        onSaved(nil)
    }

    private func saveTransit(_ kind: UserTransitLocationKind) {
        let cleanName = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let createdID = model.addUserTransitLocation(
            name: cleanName.isEmpty ? kind.title : cleanName,
            kind: kind,
            latitude: result.coordinate.latitude,
            longitude: result.coordinate.longitude
        ) else { return }
        onSaved(.transit(createdID))
    }
}

private struct MapHomeTransitLocationsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let language: MapHomeLanguage
    let initialCenter: CLLocationCoordinate2D
    let initialSpan: MKCoordinateSpan

    @State private var name = ""
    @State private var kind: UserTransitLocationKind = .subwayStation
    @State private var searchText = ""
    @State private var searchResults: [MapHomeSearchResult] = []
    @State private var selectedCoordinate: CLLocationCoordinate2D?
    @State private var selectedPinTitle = ""
    @State private var selectedLocationID: UUID?
    @State private var mapPosition: MapCameraPosition
    @State private var editingLocation: UserTransitLocation?
    @State private var deletingLocation: UserTransitLocation?
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var isTransitSearchFocused: Bool

    init(
        model: AppModel,
        language: MapHomeLanguage,
        initialCenter: CLLocationCoordinate2D,
        initialSpan: MKCoordinateSpan
    ) {
        self.model = model
        self.language = language
        self.initialCenter = initialCenter
        self.initialSpan = initialSpan
        let position: MapCameraPosition
        if CLLocationCoordinate2DIsValid(initialCenter) {
            position = .region(
                MapHomeLocationMapMath.region(center: initialCenter, span: initialSpan)
            )
        } else {
            position = .automatic
        }
        _mapPosition = State(initialValue: position)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                header
                searchCard
                savedLocationsCard
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.tpBackground.ignoresSafeArea())
        .sheet(item: $editingLocation) { location in
            MapHomeTransitLocationNameEditor(
                model: model,
                location: location,
                language: language,
                onSaved: { savedName in
                    if selectedLocationID == location.id {
                        selectedPinTitle = savedName
                    }
                }
            )
        }
        .confirmationDialog(
            language.text("이 위치를 삭제할까요?", "Delete this location?"),
            isPresented: Binding(
                get: { deletingLocation != nil },
                set: { if !$0 { deletingLocation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(language.text("위치 삭제", "Delete location"), role: .destructive) {
                guard let deletingLocation else { return }
                model.deleteUserTransitLocation(deletingLocation.id)
                if selectedLocationID == deletingLocation.id {
                    selectedLocationID = nil
                    selectedCoordinate = nil
                    selectedPinTitle = ""
                    mapPosition = .region(
                        MapHomeLocationMapMath.region(
                            center: initialCenter,
                            span: initialSpan
                        )
                    )
                }
                self.deletingLocation = nil
            }
            Button(language.text("취소", "Cancel"), role: .cancel) {
                deletingLocation = nil
            }
        }
        .onDisappear {
            searchTask?.cancel()
            searchTask = nil
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(language.text("사용자 위치", "User locations"))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tpInk)
                Text(
                    language.text(
                        "지하철역과 버스정류장을 지도에서 관리합니다.",
                        "Manage subway stations and bus stops on the map."
                    )
                )
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.tpInk)
                    .frame(width: 42, height: 42)
                    .background(Color.tpInk.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(language.text("닫기", "Close"))
        }
    }

    private var searchCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.tpReferenceBlue)
                    TextField(
                        language.text("역·정류장 검색", "Search station or stop"),
                        text: $searchText
                    )
                    .focused($isTransitSearchFocused)
                    .submitLabel(.search)
                    .onSubmit { search() }
                    if isTransitSearchFocused || !searchText.isEmpty {
                        Button {
                            isTransitSearchFocused = false
                        } label: {
                            Image(systemName: "keyboard.chevron.compact.down")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            language.text("키보드 닫기", "Dismiss keyboard")
                        )
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 13))

                Button(language.text("검색", "Search")) { search() }
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 44)
                    .background(Color.tpInk, in: RoundedRectangle(cornerRadius: 13))
                    .buttonStyle(.plain)
                    .disabled(
                        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .opacity(
                        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? 0.38
                            : 1
                    )
            }

            if !searchResults.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(searchResults) { result in
                            Button(result.title) {
                                focusMap(
                                    on: result.coordinate,
                                    title: result.title,
                                    locationID: nil
                                )
                                if name.isEmpty { name = result.title }
                                searchResults = []
                            }
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.tpReferenceBlue)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                Color.tpReferenceBlue.opacity(0.10),
                                in: Capsule()
                            )
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            MapReader { proxy in
                Map(position: $mapPosition) {
                    if let selectedCoordinate {
                        Marker(
                            selectedPinTitle.isEmpty
                                ? language.text("선택 위치", "Selected location")
                                : selectedPinTitle,
                            coordinate: selectedCoordinate
                        )
                    }
                    UserAnnotation()
                }
                .mapStyle(.standard(elevation: .realistic))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.tpLine.opacity(0.7), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .onTapGesture { point in
                    guard let coordinate = proxy.convert(point, from: .local) else { return }
                    focusMap(
                        on: coordinate,
                        title: language.text("선택 위치", "Selected location"),
                        locationID: nil
                    )
                }
            }
            .frame(height: 250)

            Picker(language.text("유형", "Type"), selection: $kind) {
                ForEach(UserTransitLocationKind.allCases, id: \.self) { value in
                    Text(
                        language.text(
                            value.title,
                            value == .subwayStation ? "Subway station" : "Bus stop"
                        )
                    )
                    .tag(value)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 8) {
                TextField(language.text("이름", "Name"), text: $name)
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 13))
                Button(language.text("추가", "Add")) { addLocation() }
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 44)
                    .background(
                        Color.tpReferenceBlue,
                        in: RoundedRectangle(cornerRadius: 13)
                    )
                    .buttonStyle(.plain)
                    .disabled(!canAddLocation)
                    .opacity(canAddLocation ? 1 : 0.38)
            }
        }
        .padding(14)
        .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 22))
    }

    private var savedLocationsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(language.text("등록된 위치", "Saved locations"))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tpInk)
                Spacer()
                Text(String(model.settings.userTransitLocations.count))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tpReferenceBlue)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.tpReferenceBlue.opacity(0.10), in: Capsule())
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)

            if model.settings.userTransitLocations.isEmpty {
                Text(
                    language.text(
                        "등록된 지하철역이나 버스정류장이 없습니다.",
                        "No subway stations or bus stops are saved."
                    )
                )
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 18)
            }

            ForEach(model.settings.userTransitLocations) { location in
                HStack(spacing: 4) {
                    Button {
                        focusMap(
                            on: CLLocationCoordinate2D(
                                latitude: location.point.latitude,
                                longitude: location.point.longitude
                            ),
                            title: location.name,
                            locationID: location.id
                        )
                    } label: {
                        HStack(spacing: 11) {
                            Image(systemName: location.kind.systemImage)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(Color.tpReferenceBlue)
                                .frame(width: 38, height: 38)
                                .background(
                                    Color.tpReferenceBlue.opacity(0.11),
                                    in: RoundedRectangle(cornerRadius: 11)
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(location.name)
                                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Color.tpInk)
                                    .lineLimit(1)
                                Text(
                                    language.text(
                                        location.kind.title,
                                        location.kind == .subwayStation
                                            ? "Subway station"
                                            : "Bus stop"
                                    )
                                )
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "location.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(
                                    selectedLocationID == location.id
                                        ? Color.tpReferenceRose
                                        : Color.tpSecondary
                                )
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        editingLocation = location
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.tpReferenceBlue)
                            .frame(width: 36, height: 38)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        language.text("\(location.name) 이름 편집", "Edit \(location.name)")
                    )

                    Button(role: .destructive) {
                        deletingLocation = location
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.red)
                            .frame(width: 36, height: 38)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        language.text("\(location.name) 삭제", "Delete \(location.name)")
                    )
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    selectedLocationID == location.id
                        ? Color.tpReferenceBlue.opacity(0.08)
                        : Color.white.opacity(0.78),
                    in: RoundedRectangle(cornerRadius: 15)
                )
            }
        }
        .padding(14)
        .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 22))
    }

    private var canAddLocation: Bool {
        selectedCoordinate != nil
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func focusMap(
        on coordinate: CLLocationCoordinate2D,
        title: String,
        locationID: UUID?
    ) {
        selectedCoordinate = coordinate
        selectedPinTitle = title
        selectedLocationID = locationID
        mapPosition = .region(
            MapHomeLocationMapMath.region(center: coordinate, span: initialSpan)
        )
    }

    private func addLocation() {
        guard let selectedCoordinate else { return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let createdID = model.addUserTransitLocation(
            name: cleanName,
            kind: kind,
            latitude: selectedCoordinate.latitude,
            longitude: selectedCoordinate.longitude
        ) else { return }
        selectedPinTitle = cleanName
        selectedLocationID = createdID
        name = ""
        searchText = ""
        searchResults = []
        isTransitSearchFocused = false
    }

    private func search() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searchTask?.cancel()
        searchTask = Task { @MainActor in
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            if CLLocationCoordinate2DIsValid(initialCenter) {
                request.region = MKCoordinateRegion(
                    center: initialCenter,
                    span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
                )
            }
            guard let response = try? await MKLocalSearch(request: request).start(),
                  !Task.isCancelled else { return }
            searchResults = response.mapItems.prefix(8).map { item in
                MapHomeSearchResult(
                    title: item.name ?? query,
                    subtitle: item.placemark.title ?? "",
                    coordinate: item.placemark.coordinate
                )
            }
        }
    }
}

private struct MapHomeTransitLocationNameEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let location: UserTransitLocation
    let language: MapHomeLanguage
    let onSaved: (String) -> Void
    @State private var name: String

    init(
        model: AppModel,
        location: UserTransitLocation,
        language: MapHomeLanguage,
        onSaved: @escaping (String) -> Void
    ) {
        self.model = model
        self.location = location
        self.language = language
        self.onSaved = onSaved
        _name = State(initialValue: location.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(language.text("위치 이름 수정", "Edit location name"))
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(Color.tpInk)
            TextField(language.text("이름", "Name"), text: $name)
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 13))
            HStack(spacing: 8) {
                Button(language.text("취소", "Cancel")) { dismiss() }
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color.tpInk.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
                    .buttonStyle(.plain)
                Button(language.text("저장", "Save")) {
                    let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.renameUserTransitLocation(location.id, name: cleanName)
                    onSaved(cleanName)
                    dismiss()
                }
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Color.tpInk, in: RoundedRectangle(cornerRadius: 13))
                .buttonStyle(.plain)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .background(Color.tpBackground)
        .presentationDetents([.height(230)])
    }
}
