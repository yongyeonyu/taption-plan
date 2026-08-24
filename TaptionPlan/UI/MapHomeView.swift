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

enum MapHomeSearchLayoutMath {
    static let menuPanelWidth: CGFloat = 316
    static let playbackTouchSize: CGFloat = 44
    static let playbackVisualSize: CGFloat = 40.74
    static let playbackIconSize: CGFloat = 13.58
    static let itemSpacing: CGFloat = 8
    static let searchRowHeight: CGFloat = 48
    static let searchResultsMaximumHeight: CGFloat = 320

    static func searchWidth(
        viewportWidth: CGFloat,
        horizontalInset: CGFloat,
        trailingControlCount: Int = 1
    ) -> CGFloat {
        let menuAlignedWidth = menuPanelWidth - horizontalInset
        let controlCount = max(0, trailingControlCount)
        let controlsWidth = CGFloat(controlCount) * playbackTouchSize
            + CGFloat(max(0, controlCount - 1)) * itemSpacing
        let availableWidth = viewportWidth
            - horizontalInset * 2
            - controlsWidth
            - (controlCount > 0 ? itemSpacing : 0)
        return max(0, min(menuAlignedWidth, availableWidth))
    }

    static func searchResultsHeight(resultCount: Int) -> CGFloat {
        min(
            CGFloat(max(resultCount, 0)) * searchRowHeight,
            searchResultsMaximumHeight
        )
    }
}

enum MapHomeLayerPriority {
    static let map: Double = 0
    static let sidebar: Double = 2
    static let search: Double = 4
    static let menu: Double = 6
    static let header: Double = 8
}

enum MapHomeCameraLayoutMath {
    static let centeredTolerance: CGFloat = 18

    static func targetPoint(
        viewportSize: CGSize,
        searchBottom: CGFloat,
        sidebarLeft: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: max(0, sidebarLeft) / 2,
            y: min(max(searchBottom, 0), viewportSize.height)
                + max(0, viewportSize.height - searchBottom) / 2
        )
    }

    static func cameraCenterSourcePoint(
        currentLocationPoint: CGPoint,
        targetPoint: CGPoint,
        viewportSize: CGSize
    ) -> CGPoint {
        CGPoint(
            x: viewportSize.width / 2 + currentLocationPoint.x - targetPoint.x,
            y: viewportSize.height / 2 + currentLocationPoint.y - targetPoint.y
        )
    }

    static func isCentered(
        locationPoint: CGPoint,
        targetPoint: CGPoint,
        tolerance: CGFloat = centeredTolerance
    ) -> Bool {
        hypot(locationPoint.x - targetPoint.x, locationPoint.y - targetPoint.y)
            <= tolerance
    }
}

enum MapHomeLongPressRoutingMath {
    static let exclusionPadding: CGFloat = 8

    static func shouldPresentLocation(
        at point: CGPoint,
        excluding frame: CGRect
    ) -> Bool {
        guard !frame.isNull, !frame.isEmpty else { return true }
        return !frame.insetBy(
            dx: -exclusionPadding,
            dy: -exclusionPadding
        ).contains(point)
    }
}

enum MapHomeCameraZoomMath {
    static let minimumDistance: CLLocationDistance = 80
    static let maximumDistance: CLLocationDistance = 30_000_000
    static let zoomInFactor = 0.68
    static let zoomOutFactor = 1.48

    static func clampedDistance(_ distance: CLLocationDistance) -> CLLocationDistance {
        min(max(distance, minimumDistance), maximumDistance)
    }

    static func distance(
        from currentDistance: CLLocationDistance,
        direction: Int
    ) -> CLLocationDistance {
        clampedDistance(
            currentDistance * (direction > 0 ? zoomInFactor : zoomOutFactor)
        )
    }

    static func isAtLimit(
        distance: CLLocationDistance?,
        direction: Int
    ) -> Bool {
        guard let distance else { return false }
        return direction > 0
            ? distance <= minimumDistance
            : distance >= maximumDistance
    }

    static func centerPreservingAnchor(
        cameraCenter: CLLocationCoordinate2D,
        anchor: CLLocationCoordinate2D,
        oldDistance: CLLocationDistance,
        newDistance: CLLocationDistance
    ) -> CLLocationCoordinate2D {
        guard oldDistance.isFinite, oldDistance > 0,
              newDistance.isFinite else {
            return cameraCenter
        }
        let scale = newDistance / oldDistance
        let centerPoint = MKMapPoint(cameraCenter)
        let anchorPoint = MKMapPoint(anchor)
        return MKMapPoint(
            x: anchorPoint.x - (anchorPoint.x - centerPoint.x) * scale,
            y: anchorPoint.y - (anchorPoint.y - centerPoint.y) * scale
        ).coordinate
    }
}

enum MapHomeOverlayLayoutMath {
    static let controlSize: CGFloat = 44
    static let controlSpacing: CGFloat = 9
    static let sharedBottomMargin: CGFloat = 76
    static let maximumRailHeight: CGFloat = 680

    static func railHeight(availableHeight: CGFloat) -> CGFloat {
        min(maximumRailHeight, max(0, availableHeight))
    }

    static func controlStackHeight(buttonCount: Int) -> CGFloat {
        let count = max(buttonCount, 0)
        guard count > 0 else { return 0 }
        return CGFloat(count) * controlSize
            + CGFloat(count - 1) * controlSpacing
    }

    static func topOverlayHeight(
        headerFrame: CGRect,
        searchFrame: CGRect,
        fallback: CGFloat
    ) -> CGFloat {
        let measured = max(headerFrame.maxY, searchFrame.maxY)
        return measured > 0 ? measured : fallback
    }
}

enum MapHomeTimeSidebarPinchMath {
    static let scalePerStep: CGFloat = 1.18
    static let maximumStepOffset = 4

    static func stepOffset(magnification: CGFloat) -> Int {
        guard magnification.isFinite, magnification > 0 else { return 0 }
        let raw = log(Double(magnification)) / log(Double(scalePerStep))
        let offset = raw >= 0 ? Int(floor(raw)) : Int(ceil(raw))
        return min(max(offset, -maximumStepOffset), maximumStepOffset)
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

@MainActor
@Observable
final class MapHomeSearchCompleter: NSObject, @preconcurrency MKLocalSearchCompleterDelegate {
    private let completer = MKLocalSearchCompleter()
    private(set) var results: [MKLocalSearchCompletion] = []

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest, .query]
    }

    func update(query: String, region: MKCoordinateRegion) {
        completer.region = region
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            clear()
        } else if completer.queryFragment != value {
            completer.queryFragment = value
        }
    }

    func clear() {
        if !completer.queryFragment.isEmpty {
            completer.queryFragment = ""
        }
        if !results.isEmpty {
            results = []
        }
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let next = Array(completer.results.prefix(8))
        guard results.map(\.title) != next.map(\.title)
                || results.map(\.subtitle) != next.map(\.subtitle)
        else { return }
        results = next
    }

    func completer(
        _ completer: MKLocalSearchCompleter,
        didFailWithError error: Error
    ) {
        results = []
    }
}

enum MapHomeDayPlaybackMath {
    static let durationSeconds: TimeInterval = 24
    static let frameIntervalNanoseconds: UInt64 = 16_666_667

    static func minute(elapsedSeconds: TimeInterval) -> Int {
        guard elapsedSeconds.isFinite else { return 0 }
        let progress = min(max(elapsedSeconds / durationSeconds, 0), 1)
        return min(
            MapHomeTimeSidebarMath.fullDayMinutes,
            max(0, Int((progress * Double(MapHomeTimeSidebarMath.fullDayMinutes)).rounded(.down)))
        )
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

enum MapHomeUserTrackingPolicy {
    enum Interaction: Equatable {
        case pan
        case pinch
        case rotation
    }

    static func keepsFollowing(after interaction: Interaction) -> Bool {
        interaction != .pan
    }
}

enum MapHomeUserTrackingMode: String, Equatable {
    case idle
    case locating
    case following

    var keepsCameraLocked: Bool { self != .idle }
}

enum MapHomeLocationButtonState: Equatable {
    case unavailable
    case locating
    case available
    case following

    static func resolve(
        hasLocation: Bool,
        trackingMode: MapHomeUserTrackingMode,
        isCentered: Bool
    ) -> MapHomeLocationButtonState {
        if trackingMode == .locating { return .locating }
        guard hasLocation else { return .unavailable }
        return trackingMode == .following && isCentered
            ? .following
            : .available
    }

    var showsTrackingDot: Bool { self == .following }
}

enum MapHomeRouteReadingsPolicy {
    static func dayKey(
        for date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        calendar.startOfDay(for: date)
    }

    static func merging(
        existing: [SensorReading],
        loaded: [SensorReading],
        in span: TimeSpan
    ) -> [SensorReading] {
        var readingsByID: [UUID: SensorReading] = [:]
        for reading in existing where span.contains(reading.timestamp) {
            readingsByID[reading.id] = reading
        }
        for reading in loaded where span.contains(reading.timestamp) {
            readingsByID[reading.id] = reading
        }
        return readingsByID.values.sorted {
            if $0.timestamp == $1.timestamp {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.timestamp < $1.timestamp
        }
    }
}

@MainActor
struct MapHomeView: View {
    @Environment(\.scenePhase) private var scenePhase
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
    @State private var isCategoryAddPresented = false
    @State private var isDisplayMenuExpanded = false
    @State private var isSettingsMenuExpanded = false
    @State private var isDataProtectionPresented = false
    @State private var isSettingsResetConfirmationPresented = false
    @AppStorage(
        AppLanguagePreference.sharedDefaultsKey,
        store: UserDefaults(suiteName: AppLanguagePreference.appGroupIdentifier)
    ) private var languageRawValue = AppLanguagePreference.current.rawValue
    @State private var compassControlState: MapHomeCompassControlState = .directionArrow
    @State private var headingMonitor = MapHomeHeadingMonitor()
    @State private var selectedScope: TimeScale = .day
    @State private var selectedTimelineMinute: Int?
    @State private var isTimelineSelectionPinned = false
    @State private var sectionEditSelection: MapHomeSectionEditSelection?
    @State private var isMapCenteredOnUser = false
    @SceneStorage("MapHome.userTrackingMode")
    private var userTrackingModeRawValue = MapHomeUserTrackingMode.idle.rawValue
    @State private var currentLocationRequestTask: Task<Void, Never>?
    @State private var initialLocationRequestTask: Task<Void, Never>?
    @State private var hasAppliedInitialLocation = false
    @State private var hasCancelledInitialLocationFocus = false
    @State private var mapSearchText = ""
    @State private var mapSearchResults: [MapHomeSearchResult] = []
    @State private var selectedSearchPin: MapHomeSearchResult?
    @State private var isSearchPinMenuPresented = false
    @State private var selectedUserLocation: MapHomeUserLocationSelection?
    @State private var pendingUserLocationSelection: MapHomeUserLocationSelection?
    @State private var mapSearchTask: Task<Void, Never>?
    @State private var mapSearchCompleter = MapHomeSearchCompleter()
    @State private var mapSearchRequestID = UUID()
    @FocusState private var isMapSearchFocused: Bool
    @State private var visibleMapCenter = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    @State private var timeRailSegments: [MapHomeTimeRailSegment] = [
        .wholeDayUnconfirmed,
    ]
    @State private var routeProjection: RouteTimelineProjection?
    @State private var routeReadings: [SensorReading] = []
    @State private var normalizedRouteReadings: [SensorReading] = []
    @State private var displayRouteReadings: [SensorReading] = []
    @State private var historicalPlaybackPoint: GeoPoint?
    @State private var timelineRouteOverlays: [MapHomeTimelineRouteOverlay] = []
    @State private var expectedRouteOverlays: [MapHomeExpectedRouteOverlay] = []
    @State private var expectedRouteCache: [ExpectedRouteRequest: [CLLocationCoordinate2D]] = [:]
    @State private var expectedRouteRefreshTask: Task<Void, Never>?
    @State private var visibleMapSpan = MKCoordinateSpan(
        latitudeDelta: 0.025,
        longitudeDelta: 0.035
    )
    @State private var sharedZoomLevel: CGFloat = 1
    @State private var zoomResetToken = 0
    @State private var timeSidebarZoomStep = 0
    @State private var weatherVisibleStartMinute = 0
    @State private var weatherVisibleDurationMinutes = MapHomeTimeSidebarMath.fullDayMinutes
    @State private var sidebarPinchStepOffset = 0
    @State private var activePaletteCategoryID: String?
    @State private var customPaletteColor = Color.tpReferenceMint
    @State private var lastMapCameraPublishUptime: TimeInterval = 0
    @State private var visibleMapCamera: MapCamera?
    @State private var mapViewportSize = CGSize.zero
    @State private var headerFrame = CGRect.zero
    @State private var searchFieldFrame = CGRect.zero
    @State private var mapControlsFrame = CGRect.zero
    @State private var isDayPlaybackRunning = false
    @State private var dayPlaybackElapsedSeconds: TimeInterval = 0
    @State private var dayPlaybackTask: Task<Void, Never>?

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
        static let mapControlSize = MapHomeOverlayLayoutMath.controlSize
        static let mapControlIcon: CGFloat = 15
        static let mapControlSpacing = MapHomeOverlayLayoutMath.controlSpacing
        static let timeRailWidth: CGFloat = 58
        static let weatherRailWidth: CGFloat = 58
        static let timeRailTopMargin: CGFloat = 18
        static let topOverlayFallbackHeight: CGFloat = 104
        static let overlayBottomMargin = MapHomeOverlayLayoutMath.sharedBottomMargin
        static let menuWidth = MapHomeSearchLayoutMath.menuPanelWidth
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
        switch AppLanguagePreference.resolve(rawValue: languageRawValue) {
        case .korean: .korean
        case .english: .english
        }
    }

    private var languagePreference: AppLanguagePreference {
        AppLanguagePreference(rawValue: languageRawValue) ?? .automatic
    }

    private var userTrackingMode: MapHomeUserTrackingMode {
        MapHomeUserTrackingMode(rawValue: userTrackingModeRawValue) ?? .idle
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
        MapHomeTimeSidebarMath.totalWidth(railWidth: Layout.timeRailWidth)
            + Layout.horizontalInset
    }

    private var sidebarLeftX: CGFloat {
        max(0, mapViewportSize.width - sidebarInteractionWidth)
    }

    private var mapSearchWidth: CGFloat {
        MapHomeSearchLayoutMath.searchWidth(
            viewportWidth: mapViewportSize.width > 0
                ? mapViewportSize.width
                : UIScreen.main.bounds.width,
            horizontalInset: Layout.horizontalInset,
            trailingControlCount: 2
        )
    }

    private var isMapSearchOverlayPresented: Bool {
        isMapSearchFocused
            || hasMapSearchResults
    }

    private var hasMapSearchResults: Bool {
        !mapSearchResults.isEmpty || !mapSearchCompleter.results.isEmpty
    }

    private var mapSearchResultCount: Int {
        mapSearchResults.isEmpty
            ? mapSearchCompleter.results.count
            : mapSearchResults.count
    }

    private var mapSearchSurfaceHeight: CGFloat {
        guard hasMapSearchResults else { return 42 }
        return 42 + 5 + MapHomeSearchLayoutMath.searchResultsHeight(
            resultCount: mapSearchResultCount
        )
    }

    private var currentLocationTargetPoint: CGPoint {
        MapHomeCameraLayoutMath.targetPoint(
            viewportSize: mapViewportSize,
            searchBottom: searchFieldFrame.maxY > 0
                ? searchFieldFrame.maxY
                : CGFloat(2) + Layout.headerVisibleHeight + 8 + 42,
            sidebarLeft: sidebarLeftX
        )
    }

    private var topOverlayHeight: CGFloat {
        MapHomeOverlayLayoutMath.topOverlayHeight(
            headerFrame: headerFrame,
            searchFrame: searchFieldFrame,
            fallback: Layout.topOverlayFallbackHeight
        )
    }

    private func sectionEditSheet(for selection: MapHomeSectionEditSelection) -> some View {
        MapHomeSectionEditSheet(
            model: model,
            selection: selection,
            language: language,
            onSaved: { result in
                refreshTimeRailSegments()
                let calendar = Calendar.autoupdatingCurrent
                let dayStart = calendar.startOfDay(for: selection.date)
                let midpoint = result.selectedSpan.start.addingTimeInterval(
                    result.selectedSpan.duration / 2
                )
                selectedTimelineMinute = min(
                    1_439,
                    max(0, Int(midpoint.timeIntervalSince(dayStart) / 60))
                )
                isTimelineSelectionPinned = true
            }
        )
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
                .zIndex(MapHomeLayerPriority.map)

            if !isMenuOpen {
                currentTimeRail
                    .padding(.top, topOverlayHeight + Layout.timeRailTopMargin)
                    .padding(.bottom, Layout.overlayBottomMargin)
                    .padding(.trailing, Layout.horizontalInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .zIndex(MapHomeLayerPriority.sidebar)
            }

            VStack(spacing: 0) {
                Color.clear
                    .frame(height: Layout.headerVisibleHeight + 8)
                    .allowsHitTesting(false)
                HStack(alignment: .top, spacing: 0) {
                    mapSearchBar
                    Spacer(minLength: 0)
                    HStack(spacing: MapHomeSearchLayoutMath.itemSpacing) {
                        mapStyleButton
                        dayPlaybackButton
                    }
                    .padding(.leading, MapHomeSearchLayoutMath.itemSpacing)
                }
            }
            .padding(.horizontal, Layout.horizontalInset)
            .padding(.top, 2)
            .frame(maxHeight: .infinity, alignment: .top)
            .zIndex(MapHomeLayerPriority.search)

            if isMenuOpen {
                menu
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .zIndex(MapHomeLayerPriority.menu)
            }

            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Layout.horizontalInset)
            .padding(.top, 2)
            .zIndex(MapHomeLayerPriority.header)
        }
        .coordinateSpace(name: "mapHomeViewport")
        .ignoresSafeArea(.container, edges: .bottom)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onGeometryChange(
            for: CGSize.self,
            of: { $0.size },
            action: { size in
                guard mapViewportSize != size else { return }
                mapViewportSize = size
            }
        )
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
        .sheet(isPresented: $isCategoryAddPresented) {
            MapHomeCategoryAddSheet(model: model, language: language)
                .presentationDetents([.height(320)])
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
        .fullScreenCover(
            item: $sectionEditSelection,
            onDismiss: {
                sectionEditSelection = nil
                refreshTimeRailSegments()
            }
        ) { selection in
            sectionEditSheet(for: selection)
        }
        .animation(.easeInOut(duration: 0.22), value: isMenuOpen)
        .task {
            focusMapIfNeeded()
            refreshTimeRailSegments()
        }
        .onDisappear {
            currentLocationRequestTask?.cancel()
            currentLocationRequestTask = nil
            initialLocationRequestTask?.cancel()
            initialLocationRequestTask = nil
            mapSearchTask?.cancel()
            mapSearchTask = nil
            expectedRouteRefreshTask?.cancel()
            expectedRouteRefreshTask = nil
            mapSearchCompleter.clear()
            stopDayPlayback(resetProgress: true)
            headingMonitor.stop()
        }
        .task(id: MapHomeRouteReadingsPolicy.dayKey(for: model.selectedDate)) {
            let date = model.selectedDate
            prepareRouteProjectionReadings()
            refreshRouteProjection()
            await refreshRouteReadings(for: date)
            scheduleExpectedRouteRefresh()
            while !Task.isCancelled {
                refreshTimeRailSegments()
                await refreshRouteReadings(for: date)
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                } catch {
                    return
                }
            }
        }
        .onChange(of: model.latestSensorReading?.point) { _, _ in
            guard Calendar.autoupdatingCurrent.isDateInToday(
                model.selectedDate
            ) else { return }
            prepareRouteProjectionReadings()
            refreshRouteProjection()
            refreshHistoricalPlaybackPoint()
        }
        .onChange(of: model.settings.frequentPlaces) { _, _ in
            focusMapIfNeeded()
        }
        .onChange(of: model.selectedDate) { oldDate, newDate in
            let calendar = Calendar.autoupdatingCurrent
            let dayChanged = !calendar.isDate(oldDate, inSameDayAs: newDate)
            stopDayPlayback(resetProgress: true)
            selectedTimelineMinute = nil
            isTimelineSelectionPinned = false
            weatherVisibleStartMinute = 0
            weatherVisibleDurationMinutes = MapHomeTimeSidebarMath.fullDayMinutes

            if dayChanged {
                routeReadings = []
                normalizedRouteReadings = []
                displayRouteReadings = []
                routeProjection = nil
                timelineRouteOverlays = []
                expectedRouteOverlays = []
                historicalPlaybackPoint = nil
                prepareRouteProjectionReadings()
                refreshRouteProjection()
                refreshHistoricalPlaybackPoint()
            } else {
                prepareRouteProjectionReadings()
                refreshRouteProjection()
                refreshHistoricalPlaybackPoint()
            }

            if calendar.isDateInToday(newDate),
               currentCoordinate != nil {
                focusUserLocation()
            } else if dayChanged {
                mapPosition = .automatic
                focusMapIfNeeded()
            }
            refreshTimeRailSegments()
        }
        .onChange(of: model.snapshot.actuals) { _, _ in
            refreshTimeRailSegments()
            refreshRouteProjection()
        }
        .onChange(of: model.snapshot.travel) { _, _ in
            prepareRouteProjectionReadings()
            refreshRouteProjection()
            refreshHistoricalPlaybackPoint()
            scheduleExpectedRouteRefresh()
        }
        .onChange(of: model.snapshot.places) { _, _ in
            scheduleExpectedRouteRefresh()
        }
        .onChange(of: model.isBootstrapped) { _, isBootstrapped in
            guard isBootstrapped else { return }
            Task { await refreshRouteReadings(for: model.selectedDate) }
        }
        .onChange(of: model.backupRestoreRevision) { _, _ in
            Task {
                await refreshRouteReadings(for: model.selectedDate)
                scheduleExpectedRouteRefresh()
            }
        }
        .onChange(of: model.liveRouteState.readings) { _, _ in
            prepareRouteProjectionReadings()
            refreshRouteProjection()
            refreshHistoricalPlaybackPoint()
        }
        .onChange(of: selectedTimelineMinute) { _, minute in
            refreshSelectedTimelineMapPosition(minute: minute)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                stopDayPlayback(resetProgress: true)
            } else {
                Task { await refreshRouteReadings(for: model.selectedDate) }
            }
        }
    }

    @ViewBuilder
    private var map: some View {
        MapReader { proxy in
            Map(
                position: $mapPosition,
                interactionModes: .all,
                scope: mapScope
            ) {
            ForEach(visibleExpectedRouteOverlays) { overlay in
                MapPolyline(coordinates: overlay.coordinates)
                    .stroke(
                        mapCategoryColor("movement").opacity(0.48),
                        style: StrokeStyle(
                            lineWidth: 3,
                            lineCap: .round,
                            lineJoin: .round,
                            dash: [7, 5]
                        )
                    )
            }

            ForEach(subwayRouteOverlays) { overlay in
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
                            "\(selectedSearchPin.title) 위치 추가",
                            "Add \(selectedSearchPin.title) location"
                        )
                    )
                }
            }

            if let historicalPlaybackCoordinate {
                Annotation(
                    historicalPlaybackAccessibilityLabel,
                    coordinate: historicalPlaybackCoordinate,
                    anchor: .center
                ) {
                    MapHomeHistoricalLocationMarker()
                        .accessibilityLabel(historicalPlaybackAccessibilityLabel)
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
                let isCentered = updateUserCenterState(using: proxy)
                if userTrackingMode == .locating, isCentered {
                    setUserTrackingMode(.following)
                }
                if let level = sharedZoomLevel(for: context.region.span),
                   abs(level - sharedZoomLevel) > 0.02 {
                    sharedZoomLevel = level
                }
            }
            .overlay {
                MapHomeFairyAtmosphere()
                    .allowsHitTesting(false)
            }
            .background {
                MapHomePanGestureObserver {
                    handleUserMapPan()
                }
                .allowsHitTesting(false)
            }
            .simultaneousGesture(
                SpatialTapGesture().onEnded { _ in
                    dismissMapSearchOverlay()
                }
            )
            .simultaneousGesture(mapLongPressGesture(proxy: proxy))
            .task {
                applyInitialLocationIfAvailable(using: proxy)
                beginInitialLocationRequest(using: proxy)
            }
            .onChange(of: model.latestSensorReading?.id) { _, _ in
                applyInitialLocationIfAvailable(using: proxy)
                guard userTrackingMode.keepsCameraLocked else { return }
                focusUserLocation(using: proxy)
            }
            .onChange(of: model.liveRouteState.readings.last?.id) { _, _ in
                guard userTrackingMode.keepsCameraLocked else { return }
                focusUserLocation(using: proxy)
            }
            .overlay(alignment: .bottomLeading) {
                if !isMenuOpen {
                    mapControls(proxy: proxy)
                        .padding(.leading, Layout.horizontalInset)
                        .padding(.bottom, Layout.overlayBottomMargin)
                        .onGeometryChange(
                            for: CGRect.self,
                            of: { geometry in
                                geometry.frame(in: .named("mapHomeViewport"))
                            },
                            action: { frame in
                                guard mapControlsFrame != frame else { return }
                                mapControlsFrame = frame
                            }
                        )
                }
            }
        }
    }

    private func mapLongPressGesture(proxy: MapProxy) -> some Gesture {
        LongPressGesture(minimumDuration: 0.55, maximumDistance: 12)
            .sequenced(before: DragGesture(
                minimumDistance: 0,
                coordinateSpace: .named("mapHomeViewport")
            ))
            .onEnded { value in
                guard case .second(true, let drag?) = value,
                      MapHomeLongPressRoutingMath.shouldPresentLocation(
                          at: drag.startLocation,
                          excluding: mapControlsFrame
                      ),
                      let coordinate = proxy.convert(
                          drag.startLocation,
                          from: .named("mapHomeViewport")
                      )
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
        switch model.settings.mapDisplayStyle {
        case .standard:
            .standard(elevation: .realistic)
        case .hybrid:
            .hybrid(elevation: .realistic)
        case .imagery:
            .imagery(elevation: .realistic)
        }
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
        .onGeometryChange(
            for: CGRect.self,
            of: { proxy in
                proxy.frame(in: .named("mapHomeViewport"))
            },
            action: { frame in
                guard headerFrame != frame else { return }
                headerFrame = frame
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
                .onChange(of: mapSearchText) { _, value in
                    guard isMapSearchFocused else { return }
                    mapSearchResults = []
                    mapSearchCompleter.update(
                        query: value,
                        region: mapSearchRegion
                    )
                }
                .onChange(of: isMapSearchFocused) { _, focused in
                    if focused {
                        mapSearchCompleter.update(
                            query: mapSearchText,
                            region: mapSearchRegion
                        )
                    }
                }
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
            .onGeometryChange(
                for: CGRect.self,
                of: { proxy in
                    proxy.frame(in: .named("mapHomeViewport"))
                },
                action: { frame in
                    guard searchFieldFrame != frame else { return }
                    searchFieldFrame = frame
                }
            )

            if hasMapSearchResults {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if mapSearchResults.isEmpty {
                            ForEach(
                                Array(mapSearchCompleter.results.enumerated()),
                                id: \.offset
                            ) { _, completion in
                                mapSearchRow(
                                    title: completion.title,
                                    subtitle: completion.subtitle
                                ) {
                                    searchMap(completion: completion)
                                }
                            }
                        } else {
                            ForEach(mapSearchResults) { result in
                                mapSearchRow(
                                    title: result.title,
                                    subtitle: result.subtitle
                                ) {
                                    selectSearchResult(result)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(
                    height: MapHomeSearchLayoutMath.searchResultsHeight(
                        resultCount: mapSearchResultCount
                    ),
                    alignment: .top
                )
                .background(Color.tpSurface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.tpLine.opacity(0.7), lineWidth: 1)
                }
                .contentShape(Rectangle())
            }
        }
        .frame(
            width: mapSearchWidth,
            height: mapSearchSurfaceHeight,
            alignment: .top
        )
    }

    private var dayPlaybackButton: some View {
        Button {
            toggleDayPlayback()
        } label: {
            Image(systemName: isDayPlaybackRunning ? "pause.fill" : "play.fill")
                .font(.system(size: MapHomeSearchLayoutMath.playbackIconSize, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(
                    width: MapHomeSearchLayoutMath.playbackVisualSize,
                    height: MapHomeSearchLayoutMath.playbackVisualSize
                )
                .background(Color.tpInk.opacity(0.46), in: Circle())
                .frame(
                    width: MapHomeSearchLayoutMath.playbackTouchSize,
                    height: MapHomeSearchLayoutMath.playbackTouchSize
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isDayPlaybackRunning
                ? language.text("하루 재생 일시 정지", "Pause day playback")
                : language.text("하루 재생", "Play day")
        )
    }

    private var mapStyleButton: some View {
        Menu {
            ForEach(MapDisplayStyle.allCases, id: \.self) { style in
                Button {
                    model.setMapDisplayStyle(style)
                } label: {
                    Label(
                        mapStyleTitle(style),
                        systemImage: model.settings.mapDisplayStyle == style
                            ? "checkmark"
                            : mapStyleSystemImage(style)
                    )
                }
            }
        } label: {
            Image(systemName: "map.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(
                    width: MapHomeSearchLayoutMath.playbackVisualSize,
                    height: MapHomeSearchLayoutMath.playbackVisualSize
                )
                .background(Color.tpInk.opacity(0.46), in: Circle())
                .frame(
                    width: MapHomeSearchLayoutMath.playbackTouchSize,
                    height: MapHomeSearchLayoutMath.playbackTouchSize
                )
                .contentShape(Rectangle())
        }
        .accessibilityLabel(
            language.text("지도 스타일 변경", "Change map style")
        )
    }

    private func mapStyleTitle(_ style: MapDisplayStyle) -> String {
        switch style {
        case .standard: language.text("표준", "Standard")
        case .hybrid: language.text("하이브리드", "Hybrid")
        case .imagery: language.text("위성", "Satellite")
        }
    }

    private func mapStyleSystemImage(_ style: MapDisplayStyle) -> String {
        switch style {
        case .standard: "map"
        case .hybrid: "square.3.layers.3d"
        case .imagery: "globe.asia.australia.fill"
        }
    }

    private func mapSearchRow(
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.tpReferenceBlue)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11, weight: .regular, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: MapHomeSearchLayoutMath.searchRowHeight)
        }
        .buttonStyle(.plain)
    }

    private var mapSearchRegion: MKCoordinateRegion {
        let center = currentCoordinate ?? visibleMapCenter
        let span = visibleMapSpan.latitudeDelta > 0 && visibleMapSpan.longitudeDelta > 0
            ? visibleMapSpan
            : MKCoordinateSpan(latitudeDelta: 0.25, longitudeDelta: 0.25)
        return MKCoordinateRegion(center: center, span: span)
    }

    private func dismissMapSearchOverlay() {
        if isSearchPinMenuPresented, selectedSearchPin != nil {
            cancelPendingMapLocationAddition()
            return
        }
        guard isMapSearchFocused
                || !mapSearchResults.isEmpty
                || !mapSearchCompleter.results.isEmpty
        else { return }
        isMapSearchFocused = false
        mapSearchResults = []
        mapSearchCompleter.clear()
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
        mapSearchRequestID = UUID()
        mapSearchCompleter.clear()
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
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = mapSearchRegion
        runMapSearch(request, fallbackTitle: query)
    }

    private func searchMap(completion: MKLocalSearchCompletion) {
        let request = MKLocalSearch.Request(completion: completion)
        request.region = mapSearchRegion
        runMapSearch(request, fallbackTitle: completion.title)
    }

    private func runMapSearch(
        _ request: MKLocalSearch.Request,
        fallbackTitle: String
    ) {
        mapSearchTask?.cancel()
        let requestID = UUID()
        mapSearchRequestID = requestID
        mapSearchTask = Task { @MainActor in
            guard let response = try? await MKLocalSearch(request: request).start(),
                  !Task.isCancelled,
                  requestID == mapSearchRequestID
            else { return }
            let results = response.mapItems.prefix(8).map { item in
                MapHomeSearchResult(
                    title: item.name ?? fallbackTitle,
                    subtitle: item.placemark.title ?? "",
                    coordinate: item.placemark.coordinate
                )
            }
            mapSearchCompleter.clear()
            if let first = results.first {
                selectSearchResult(first)
            } else {
                mapSearchResults = []
            }
        }
    }

    private func selectSearchResult(_ result: MapHomeSearchResult) {
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
        mapSearchCompleter.clear()
        isMapSearchFocused = false
        mapSearchText = result.title
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
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .medium))
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

    private func toggleDayPlayback() {
        if isDayPlaybackRunning {
            stopDayPlayback(resetProgress: false)
        } else {
            startDayPlayback()
        }
    }

    private func startDayPlayback() {
        dayPlaybackTask?.cancel()
        if dayPlaybackElapsedSeconds >= MapHomeDayPlaybackMath.durationSeconds {
            dayPlaybackElapsedSeconds = 0
        }
        let baseElapsed = dayPlaybackElapsedSeconds
        isTimelineSelectionPinned = true
        isDayPlaybackRunning = true
        refreshRouteProjection()
        if baseElapsed == 0 {
            selectedTimelineMinute = 0
        }
        refreshHistoricalPlaybackPoint()
        let startedAt = ProcessInfo.processInfo.systemUptime
        dayPlaybackTask = Task { @MainActor in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        nanoseconds: MapHomeDayPlaybackMath
                            .frameIntervalNanoseconds
                    )
                } catch {
                    return
                }
                let elapsed = min(
                    MapHomeDayPlaybackMath.durationSeconds,
                    baseElapsed + ProcessInfo.processInfo.systemUptime - startedAt
                )
                let minute = MapHomeDayPlaybackMath.minute(elapsedSeconds: elapsed)
                if dayPlaybackElapsedSeconds != elapsed {
                    dayPlaybackElapsedSeconds = elapsed
                }
                if selectedTimelineMinute != minute {
                    selectedTimelineMinute = minute
                }
                guard elapsed < MapHomeDayPlaybackMath.durationSeconds else {
                    selectedTimelineMinute = MapHomeTimeSidebarMath.fullDayMinutes
                    isDayPlaybackRunning = false
                    historicalPlaybackPoint = nil
                    refreshRouteProjection()
                    refreshHistoricalPlaybackPoint()
                    dayPlaybackTask = nil
                    return
                }
            }
        }
    }

    private func stopDayPlayback(resetProgress: Bool) {
        let wasRunning = isDayPlaybackRunning
        dayPlaybackTask?.cancel()
        dayPlaybackTask = nil
        isDayPlaybackRunning = false
        historicalPlaybackPoint = nil
        if resetProgress {
            dayPlaybackElapsedSeconds = 0
        }
        if wasRunning {
            refreshRouteProjection()
            refreshHistoricalPlaybackPoint()
        }
    }

    private var currentTimeRail: some View {
        GeometryReader { proxy in
            let railHeight = MapHomeOverlayLayoutMath.railHeight(
                availableHeight: proxy.size.height
            )
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                let minute = timelineSelectionMinute(at: timeline.date)
                let timeSidebarWidth = MapHomeTimeSidebarMath.totalWidth(
                    railWidth: Layout.timeRailWidth
                )
                let weatherOriginX = MapHomeWeatherRailAlignmentMath.weatherOriginX(
                    weatherRailWidth: Layout.weatherRailWidth,
                    timeRailWidth: Layout.timeRailWidth
                )
                ZStack(alignment: .topLeading) {
                    if model.settings.weatherSidebarVisible {
                        MapHomeWeatherSidebar(
                            date: model.selectedDate,
                            contexts: model.snapshot.weather,
                            selectedMinute: minute,
                            language: language,
                            visibleStartMinute: weatherVisibleStartMinute,
                            visibleDurationMinutes: weatherVisibleDurationMinutes,
                            playheadCenterX: MapHomeWeatherRailAlignmentMath.playheadCenterX(
                                weatherOriginX: weatherOriginX,
                                timeRailWidth: Layout.timeRailWidth
                            )
                        )
                        .offset(x: weatherOriginX)
                    }
                    MapHomeTimeSidebar(
                        date: model.selectedDate,
                        selectedMinute: Binding(
                            get: { timelineSelectionMinute(at: timeline.date) },
                            set: { minute in
                                guard selectedTimelineMinute != minute else { return }
                                stopDayPlayback(resetProgress: true)
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
                        maximumSelectableMinute: dayPlaybackElapsedSeconds > 0
                            ? MapHomeTimeSidebarMath.fullDayMinutes
                            : nil,
                        onSelectionChanged: { minute in
                            stopDayPlayback(resetProgress: true)
                            isTimelineSelectionPinned = true
                            selectedTimelineMinute = minute
                        },
                        onViewportChanged: { start, duration in
                            weatherVisibleStartMinute = start
                            weatherVisibleDurationMinutes = duration
                        },
                        onInteractionChanged: { isInteracting in
                            if !isInteracting {
                                refreshSelectedTimelineMapPosition(
                                    minute: selectedTimelineMinute
                                )
                            }
                        },
                        onSectionEdit: { selectedMinute in
                            openSectionEditor(at: selectedMinute)
                        }
                    )
                }
                .frame(
                    width: timeSidebarWidth,
                    height: railHeight
                )
                .position(
                    x: proxy.size.width - timeSidebarWidth / 2,
                    y: max(
                        railHeight / 2,
                        proxy.size.height - railHeight / 2
                    )
                )
                .contentShape(Rectangle())
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { scale in
                            let offset = MapHomeTimeSidebarPinchMath.stepOffset(
                                magnification: scale
                            )
                            guard offset != sidebarPinchStepOffset else { return }
                            timeSidebarZoomStep += offset - sidebarPinchStepOffset
                            sidebarPinchStepOffset = offset
                        }
                        .onEnded { _ in
                            sidebarPinchStepOffset = 0
                        }
                )
            }
        }
        .frame(
            width: MapHomeTimeSidebarMath.totalWidth(
                railWidth: Layout.timeRailWidth
            )
        )
        .frame(maxHeight: .infinity, alignment: .trailing)
    }

    private func mapControls(proxy: MapProxy) -> some View {
        VStack(spacing: Layout.mapControlSpacing) {
            Button {
                requestAndFollowUserLocation(using: proxy)
            } label: {
                MapHomeLocationButtonIcon(
                    state: MapHomeLocationButtonState.resolve(
                        hasLocation: currentCoordinate != nil,
                        trackingMode: userTrackingMode,
                        isCentered: isMapCenteredOnUser
                    )
                )
                    .frame(width: Layout.mapControlSize, height: Layout.mapControlSize)
                    .background(Color.white.opacity(0.94), in: Circle())
            }
            .accessibilityLabel(language.text("현재 위치", "Current location"))

            if isHeadingMode {
                Button {
                    toggleMapHeadingMode(using: proxy)
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
                    toggleMapHeadingMode(using: proxy)
                } label: {
                    Image(systemName: "location.north.line")
                        .font(.system(size: Layout.mapControlIcon, weight: .bold))
                        .foregroundStyle(Color.tpReferenceRose)
                        .frame(width: Layout.mapControlSize, height: Layout.mapControlSize)
                        .background(Color.white.opacity(0.94), in: Circle())
                }
                .accessibilityLabel(language.text("나침반 표시", "Show compass"))
            }

            mapZoomButton(systemImage: "plus", direction: 1, proxy: proxy)
            mapZoomButton(systemImage: "minus", direction: -1, proxy: proxy)
        }
        .simultaneousGesture(
            SpatialTapGesture().onEnded { _ in
                dismissMapSearchOverlay()
            }
        )
    }

    private func mapZoomButton(
        systemImage: String,
        direction: Int,
        proxy: MapProxy
    ) -> some View {
        Button {
            adjustMapZoom(direction: direction, proxy: proxy)
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
        .disabled(
            MapHomeCameraZoomMath.isAtLimit(
                distance: visibleMapCamera?.distance,
                direction: direction
            )
        )
    }

    private func adjustMapZoom(direction: Int, proxy: MapProxy) {
        guard let camera = visibleMapCamera else { return }
        let distance = MapHomeCameraZoomMath.distance(
            from: camera.distance,
            direction: direction
        )
        guard distance != camera.distance else { return }
        let anchor = userTrackingMode.keepsCameraLocked || isMapCenteredOnUser
            ? currentCoordinate ?? camera.centerCoordinate
            : camera.centerCoordinate
        let center = MapHomeCameraZoomMath.centerPreservingAnchor(
            cameraCenter: camera.centerCoordinate,
            anchor: anchor,
            oldDistance: camera.distance,
            newDistance: distance
        )
        mapPosition = .camera(
            MapCamera(
                centerCoordinate: center,
                distance: distance,
                heading: camera.heading,
                pitch: camera.pitch
            )
        )
        updateUserCenterState(using: proxy)
    }

    private var menu: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.18)
                    .ignoresSafeArea(edges: .top)
                    .contentShape(Rectangle())
                    .onTapGesture { isMenuOpen = false }

                let menuHeight = max(0, proxy.size.height)
                let menuTop = max(
                    Layout.headerVisibleHeight + 8,
                    headerFrame.maxY + 8
                )
                sidebarContent
                .frame(
                    width: Layout.menuWidth,
                    height: max(0, menuHeight - menuTop),
                    alignment: .top
                )
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
                    Text(language.text("오늘의 기록", "Today's Record"))
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
            categoryMenuItem
            displayMenuItem
            languageMenuItem
            settingsMenuItem

            Spacer(minLength: 28)

            menuItem(
                "sparkles",
                proMenuTitle,
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

                    Button {
                        isCategoryAddPresented = true
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 16, weight: .semibold))
                            Text(language.text("사용자 추가", "Add custom"))
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                            Spacer()
                        }
                        .foregroundStyle(Color.tpReferenceBlue)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 8)
                    }
                    .buttonStyle(.plain)

                    ForEach(model.settings.mapUserActivityCategories) { category in
                        HStack(spacing: 9) {
                            Circle()
                                .fill(Color(hex: category.hex))
                                .frame(width: 10, height: 10)
                            Image(systemName: category.systemImage)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color(hex: category.hex))
                                .frame(width: 20)
                            Text(category.title)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                            Spacer()
                        }
                        .padding(.vertical, 7)
                        .padding(.horizontal, 8)
                        .background(
                            Color.tpReferenceMint.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
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
        Menu {
            ForEach(AppLanguagePreference.allCases) { option in
                Button {
                    guard languageRawValue != option.rawValue else { return }
                    languageRawValue = option.rawValue
                    AppLanguagePreference.save(option)
                } label: {
                    if option == languagePreference {
                        Label(
                            languagePreferenceTitle(option),
                            systemImage: "checkmark"
                        )
                    } else {
                        Text(languagePreferenceTitle(option))
                    }
                }
            }
        } label: {
            HStack(spacing: 13) {
                Image(systemName: "globe")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.tpReferenceBlue)
                    .frame(width: 24)
                Text(language.text("언어", "Language"))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Spacer()
                Text(languagePreferenceTitle(languagePreference))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(Color.primary)
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .background(
                Color.tpReferenceBlue.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 12)
            )
        }
        .accessibilityLabel(language.text("언어 선택", "Choose language"))
    }

    private func languagePreferenceTitle(
        _ preference: AppLanguagePreference
    ) -> String {
        switch preference {
        case .automatic:
            language.text("자동", "Automatic")
        case .korean:
            language.text("한국어", "Korean")
        case .english:
            "English"
        }
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

                gpsLoggingMenuItem
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

    private var proMenuTitle: String {
        switch proAccess.menuPresentation {
        case .purchase:
            language.text("Pro 구매", "Buy Pro")
        case .trial(let remainingDays):
            language.text(
                "14일 무료 체험 · \(remainingDays)일 남음",
                "14-day free trial · \(remainingDays) days left"
            )
        case .purchased:
            language.text("Pro 구매 완료", "Pro purchased")
        }
    }

    private var gpsLoggingMenuItem: some View {
        let isLogging = model.sensorCollectionSessionState == .collecting
        let tint = Color.tpReferenceRose
        return HStack(spacing: 13) {
            Image(systemName: isLogging ? "location.fill" : "location.viewfinder")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(language.text("GPS 및 센서 데이터", "GPS & Sensor Data"))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Text(sensorCollectionStatusText + " · " + gpsLoggingIntervalText(1))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "lock.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(Color.primary)
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel(
            language.text(
                "GPS 및 센서 데이터 실시간 기록 고정",
                "GPS and sensor data fixed to realtime recording"
            )
        )
    }

    private var sensorCollectionStatusText: String {
        switch model.sensorCollectionSessionState {
        case .waiting:
            language.text("대기", "Waiting")
        case .collecting:
            language.text("수집 중", "Collecting")
        case .stopped:
            language.text("종료", "Stopped")
        }
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
        let reading = MapCurrentLocationAnchorPolicy.latestValidReading(
            in: [model.latestSensorReading, model.liveRouteState.readings.last]
                .compactMap { $0 }
        )
        let point = reading?.point
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

    private func refreshSelectedTimelineMapPosition(minute: Int?) {
        guard minute != nil else {
            historicalPlaybackPoint = nil
            return
        }
        let point: GeoPoint?
        if isDayPlaybackRunning {
            point = refreshHistoricalPlaybackPoint()
        } else {
            let projection = refreshRouteProjection()
            point = refreshHistoricalPlaybackPoint()
                ?? projection?.coordinateAtCutoff
        }
        guard let point else { return }
        focusMap(on: point)
    }

    private func openSectionEditor(at minute: Int) {
        stopDayPlayback(resetProgress: true)
        let segment = MapHomeTimeRailSegmentEngine.segment(
            at: minute,
            in: timeRailSegments
        ) ?? .wholeDayUnconfirmed
        TaptionPlanDiagnosticsLogger.shared.record(
            "section_edit_open_requested",
            fields: [
                "minute": String(minute),
                "category": segment.categoryID,
                "source_count": String(segment.sourceIDs.count),
            ]
        )
        sectionEditSelection = MapHomeSectionEditSelection(
            date: model.selectedDate,
            minute: minute,
            activity: currentActivity(at: minute),
            segment: segment,
            details: sectionDetails(at: minute)
        )
    }

    private var visibleExpectedRouteOverlays: [MapHomeExpectedRouteOverlay] {
        let cutoff = RouteTimelineDataEngine.timelineDate(
            selectedDate: model.selectedDate,
            minute: effectiveTimelineMinute
        )
        return expectedRouteOverlays.compactMap {
            $0.visible(through: cutoff)
        }
    }

    private func scheduleExpectedRouteRefresh() {
        expectedRouteRefreshTask?.cancel()
        expectedRouteRefreshTask = Task { @MainActor in
            defer { expectedRouteRefreshTask = nil }
            await refreshExpectedRouteOverlays()
        }
    }

    private func refreshExpectedRouteOverlays() async {
        let calendar = Calendar.autoupdatingCurrent
        let selectedDay = calendar.startOfDay(for: model.selectedDate)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: selectedDay)
            ?? selectedDay.addingTimeInterval(24 * 60 * 60)
        let requests = ExpectedRouteRequestEngine.requests(
            travel: model.snapshot.travel,
            places: model.snapshot.places,
            readings: normalizedRouteReadings,
            in: TimeSpan(start: selectedDay, end: dayEnd),
            through: dayEnd
        )
        guard !requests.isEmpty else {
            expectedRouteOverlays = []
            return
        }
        if expectedRouteCache.count > 128 {
            expectedRouteCache.removeAll(keepingCapacity: true)
        }

        var overlays: [MapHomeExpectedRouteOverlay] = []
        for request in requests.prefix(24) {
            guard !Task.isCancelled else { return }
            let coordinates: [CLLocationCoordinate2D]
            if let cached = expectedRouteCache[request] {
                coordinates = cached
            } else {
                coordinates = await mapKitRouteCoordinates(for: request)
                expectedRouteCache[request] = coordinates
            }
            guard coordinates.count >= 2 else { continue }
            overlays.append(
                MapHomeExpectedRouteOverlay(
                    id: request.segmentID,
                    mode: request.mode,
                    departureDate: request.departureDate,
                    arrivalDate: request.arrivalDate,
                    coordinates: coordinates
                )
            )
        }
        guard !Task.isCancelled,
              calendar.isDate(selectedDay, inSameDayAs: model.selectedDate)
        else { return }
        expectedRouteOverlays = overlays
    }

    private func mapKitRouteCoordinates(
        for routeRequest: ExpectedRouteRequest
    ) async -> [CLLocationCoordinate2D] {
        let request = MKDirections.Request()
        request.source = MKMapItem(
            placemark: MKPlacemark(
                coordinate: CLLocationCoordinate2D(
                    latitude: routeRequest.start.latitude,
                    longitude: routeRequest.start.longitude
                )
            )
        )
        request.destination = MKMapItem(
            placemark: MKPlacemark(
                coordinate: CLLocationCoordinate2D(
                    latitude: routeRequest.end.latitude,
                    longitude: routeRequest.end.longitude
                )
            )
        )
        request.requestsAlternateRoutes = false
        request.transportType = switch routeRequest.transport {
        case .automobile: .automobile
        case .transit: .transit
        case .walking: .walking
        }
        if routeRequest.transport == .transit {
            request.departureDate = .now
        }
        guard let response = try? await MKDirections(request: request).calculate(),
              let route = response.routes.min(by: {
                  $0.expectedTravelTime < $1.expectedTravelTime
              }) else { return [] }
        let points = route.polyline.points()
        return (0..<route.polyline.pointCount).map { points[$0].coordinate }
    }

    private var subwayRouteOverlays: [MapHomeSubwayRouteOverlay] {
        let calendar = Calendar.autoupdatingCurrent
        guard let dayStart = calendar.startOfDay(for: model.selectedDate) as Date?,
              let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
        else { return [] }
        let day = TimeSpan(start: dayStart, end: dayEnd)
        let cutoff = RouteTimelineDataEngine.timelineDate(
            selectedDate: model.selectedDate,
            minute: effectiveTimelineMinute,
            calendar: calendar
        )
        return model.snapshot.travel.compactMap { segment in
            guard segment.mode == .subway,
                  segment.isConfirmed,
                  segment.span.intersection(with: day) != nil,
                  let route = segment.subwayRoute,
                  SubwayStationCatalog.isValid(route) else { return nil }
            let coordinates = RouteTimelineDataEngine.confirmedSubwayCoordinates(
                for: segment,
                through: cutoff
            ).compactMap { point -> CLLocationCoordinate2D? in
                guard isValid(point) else { return nil }
                return CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
            }
            guard coordinates.count >= 2 else { return nil }
            return MapHomeSubwayRouteOverlay(id: segment.id, coordinates: coordinates)
        }
    }

    private func makeTimelineRouteOverlays(
        _ projection: RouteTimelineProjection
    ) -> [MapHomeTimelineRouteOverlay] {
        projection.segments.compactMap { segment in
            guard segment.confirmedSubwayTravelID == nil else { return nil }
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

    private var historicalPlaybackCoordinate: CLLocationCoordinate2D? {
        guard selectedTimelineMinute != nil,
              let point = historicalPlaybackPoint
                ?? routeProjection?.coordinateAtCutoff,
              isValid(point) else { return nil }
        return CLLocationCoordinate2D(
            latitude: point.latitude,
            longitude: point.longitude
        )
    }

    private var historicalPlaybackAccessibilityLabel: String {
        let minute = min(
            max(selectedTimelineMinute ?? 0, 0),
            MapHomeTimeSidebarMath.fullDayMinutes
        )
        let time = String(format: "%02d:%02d", minute / 60, minute % 60)
        return language.text("과거 위치 \(time)", "Past location \(time)")
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

    private func sectionDetails(at minute: Int) -> [MapHomeSectionDetail] {
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: model.selectedDate)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart),
              let segment = MapHomeTimeRailSegmentEngine.segment(
                at: minute,
                in: timeRailSegments
              )
        else { return [] }
        return MapHomeSectionDetailEngine.details(
            actuals: model.snapshot.actuals,
            travel: model.snapshot.travel,
            segment: segment,
            dayStart: dayStart,
            dayEnd: dayEnd,
            asOf: .now
        )
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
        let merged = MapHomeRouteReadingsPolicy.merging(
            existing: routeReadings,
            loaded: readings,
            in: TimeSpan(start: dayStart, end: dayEnd)
        )
        guard merged != routeReadings else { return }
        routeReadings = merged
        prepareRouteProjectionReadings()
        let projection = refreshRouteProjection()
        if selectedTimelineMinute != nil,
           let point = refreshHistoricalPlaybackPoint()
                ?? projection?.coordinateAtCutoff {
            focusMap(on: point)
        } else {
            focusMapIfNeeded()
        }
    }

    @discardableResult
    private func refreshRouteProjection() -> RouteTimelineProjection? {
        let calendar = Calendar.autoupdatingCurrent
        let timelineDate = isDayPlaybackRunning
            ? nil
            : RouteTimelineDataEngine.timelineDate(
                selectedDate: model.selectedDate,
                minute: effectiveTimelineMinute,
                calendar: calendar
            )
        let next = RouteTimelineDataEngine.project(
            selectedDate: model.selectedDate,
            through: timelineDate,
            selectedSpan: isDayPlaybackRunning ? nil : timelineSelectionSpan,
            actuals: model.snapshot.actuals,
            travel: model.snapshot.travel,
            readings: displayRouteReadings,
            readingsAreNormalized: true,
            filtersSparseRouteConnections: true,
            calendar: calendar
        )
        let overlays = makeTimelineRouteOverlays(next)
        guard routeProjection != next
            || timelineRouteOverlays.map(\.id) != overlays.map(\.id)
        else { return next }
        routeProjection = next
        timelineRouteOverlays = overlays
        return next
    }

    private func prepareRouteProjectionReadings() {
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: model.selectedDate)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(24 * 60 * 60)
        let sourceReadings = routeReadings
            + model.liveRouteState.readings
            + (model.latestSensorReading.map { [$0] } ?? [])
        normalizedRouteReadings = RouteTimelineDataEngine
            .normalizedReadings(sourceReadings)
            .filter { $0.timestamp >= dayStart && $0.timestamp < dayEnd }
        displayRouteReadings = RouteTimelineDataEngine.displayReadings(
            from: normalizedRouteReadings
        )
    }

    @discardableResult
    private func refreshHistoricalPlaybackPoint() -> GeoPoint? {
        guard selectedTimelineMinute != nil else {
            historicalPlaybackPoint = nil
            return nil
        }
        let date = RouteTimelineDataEngine.timelineDate(
            selectedDate: model.selectedDate,
            minute: effectiveTimelineMinute
        )
        let point = RouteTimelineDataEngine.playbackCoordinate(
            at: date,
            inNormalizedReadings: normalizedRouteReadings
        )
        if historicalPlaybackPoint != point {
            historicalPlaybackPoint = point
        }
        return point
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
        let coordinates = timelineRouteOverlays.flatMap(\.coordinates)
            + visibleExpectedRouteOverlays.flatMap(\.coordinates)
            + subwayRouteOverlays.flatMap(\.coordinates)
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
        var coordinates = timelineRouteOverlays.flatMap(\.coordinates)
            + visibleExpectedRouteOverlays.flatMap(\.coordinates)
            + subwayRouteOverlays.flatMap(\.coordinates)
        if coordinates.isEmpty, let currentCoordinate {
            coordinates = [currentCoordinate]
        }
        guard let first = coordinates.first else { return nil }
        let fitLatitude = max(0.025, ((coordinates.map(\.latitude).max() ?? first.latitude) - (coordinates.map(\.latitude).min() ?? first.latitude)) * 1.8)
        let fitLongitude = max(0.035, ((coordinates.map(\.longitude).max() ?? first.longitude) - (coordinates.map(\.longitude).min() ?? first.longitude)) * 1.8)
        let scale = max(span.latitudeDelta / fitLatitude, span.longitudeDelta / fitLongitude)
        return min(max((scale - 0.05) / 0.95, 0), 1)
    }

    private func focusMapForSharedZoom() {
        var coordinates = timelineRouteOverlays.flatMap(\.coordinates)
            + visibleExpectedRouteOverlays.flatMap(\.coordinates)
            + subwayRouteOverlays.flatMap(\.coordinates)
        if coordinates.isEmpty, let currentCoordinate {
            coordinates = [currentCoordinate]
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
        if let camera = visibleMapCamera {
            mapPosition = .camera(
                MapCamera(
                    centerCoordinate: coordinate,
                    distance: camera.distance,
                    heading: camera.heading,
                    pitch: camera.pitch
                )
            )
        } else {
            mapPosition = .region(
                MKCoordinateRegion(center: coordinate, span: visibleMapSpan)
            )
        }
        setUserTrackingMode(.idle)
        isMapCenteredOnUser = false
    }

    private func focusUserLocation(using proxy: MapProxy? = nil) {
        guard let coordinate = currentCoordinate else {
            isMapCenteredOnUser = false
            return
        }

        if let proxy,
           let camera = visibleMapCamera,
           let locationPoint = proxy.convert(
               coordinate,
               to: .named("mapHomeViewport")
           ),
           let center = proxy.convert(
                MapHomeCameraLayoutMath.cameraCenterSourcePoint(
                    currentLocationPoint: locationPoint,
                    targetPoint: currentLocationTargetPoint,
                    viewportSize: mapViewportSize
                ),
                from: .named("mapHomeViewport")
           ) {
            mapPosition = .camera(
                MapCamera(
                    centerCoordinate: center,
                    distance: camera.distance,
                    heading: camera.heading,
                    pitch: camera.pitch
                )
            )
        } else if let camera = visibleMapCamera {
            mapPosition = .camera(
                MapCamera(
                    centerCoordinate: coordinate,
                    distance: camera.distance,
                    heading: camera.heading,
                    pitch: camera.pitch
                )
            )
        } else {
            mapPosition = .region(
                MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.010)
                )
            )
        }
    }

    private func requestAndFollowUserLocation(using proxy: MapProxy) {
        setUserTrackingMode(.locating)
        if currentCoordinate != nil {
            focusUserLocation(using: proxy)
        }
        currentLocationRequestTask?.cancel()
        currentLocationRequestTask = Task { @MainActor in
            defer { currentLocationRequestTask = nil }
            let isAvailable = await model.requestMapCurrentLocation(
                requiresFreshReading: true
            )
            guard !Task.isCancelled,
                  userTrackingMode.keepsCameraLocked else { return }
            guard isAvailable else {
                if currentCoordinate == nil {
                    setUserTrackingMode(.idle)
                }
                return
            }
            focusUserLocation(using: proxy)
        }
    }

    private func toggleMapHeadingMode(using proxy: MapProxy? = nil) {
        compassControlState = compassControlState.toggled
        if compassControlState.followsHeading {
            headingMonitor.start()
            mapPosition = .userLocation(
                followsHeading: true,
                fallback: .automatic
            )
        } else {
            headingMonitor.stop()
            focusUserLocation(using: proxy)
        }
    }

    private func applyInitialLocationIfAvailable(using proxy: MapProxy) {
        guard !hasAppliedInitialLocation, currentCoordinate != nil else { return }
        focusUserLocation(using: proxy)
        hasAppliedInitialLocation = true
    }

    private func beginInitialLocationRequest(using proxy: MapProxy) {
        guard initialLocationRequestTask == nil else { return }
        initialLocationRequestTask = Task { @MainActor in
            defer { initialLocationRequestTask = nil }
            let isAvailable = await model.requestMapCurrentLocation(
                requiresFreshReading: true
            )
            guard !Task.isCancelled,
                  isAvailable,
                  !hasCancelledInitialLocationFocus,
                  userTrackingMode == .idle else {
                return
            }
            focusUserLocation(using: proxy)
            hasAppliedInitialLocation = true
        }
    }

    private func setUserTrackingMode(_ mode: MapHomeUserTrackingMode) {
        guard userTrackingModeRawValue != mode.rawValue else { return }
        userTrackingModeRawValue = mode.rawValue
    }

    private func handleUserMapPan() {
        guard MapHomeUserTrackingPolicy.keepsFollowing(after: .pan) == false
        else { return }
        hasCancelledInitialLocationFocus = true
        initialLocationRequestTask?.cancel()
        initialLocationRequestTask = nil
        currentLocationRequestTask?.cancel()
        currentLocationRequestTask = nil
        setUserTrackingMode(.idle)
        isMapCenteredOnUser = false
    }

    @discardableResult
    private func updateUserCenterState(using proxy: MapProxy) -> Bool {
        let nextValue = currentCoordinate
            .flatMap {
                proxy.convert($0, to: .named("mapHomeViewport"))
            }
            .map {
                MapHomeCameraLayoutMath.isCentered(
                    locationPoint: $0,
                    targetPoint: currentLocationTargetPoint
                )
            } ?? false
        if isMapCenteredOnUser != nextValue {
            isMapCenteredOnUser = nextValue
        }
        return nextValue
    }

    private func updateVisibleMapSpan(_ span: MKCoordinateSpan) {
        let next = MKCoordinateSpan(
            latitudeDelta: min(max(span.latitudeDelta, 0.000_001), 180),
            longitudeDelta: min(max(span.longitudeDelta, 0.000_001), 360)
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

struct MapHomeSectionDetail: Identifiable, Hashable {
    let id: UUID
    let title: String
    let categoryID: String
    let behavior: String?
    let startMinute: Int
    let endMinute: Int
}

enum MapHomeSectionDetailEngine {
    static func details(
        actuals: [ActualRecord],
        travel: [TravelSegment],
        segment: MapHomeTimeRailSegment,
        dayStart: Date,
        dayEnd: Date,
        asOf: Date
    ) -> [MapHomeSectionDetail] {
        let calendar = Calendar.autoupdatingCurrent
        guard let segmentStart = calendar.date(
            byAdding: .minute,
            value: segment.startMinute,
            to: dayStart
        ), let segmentEnd = calendar.date(
            byAdding: .minute,
            value: segment.endMinute,
            to: dayStart
        ) else { return [] }
        let segmentSpan = TimeSpan(start: segmentStart, end: segmentEnd)
        let majorSourceIDs = Set(segment.sourceIDs)
        var result = actuals.compactMap { actual -> MapHomeSectionDetail? in
            guard !majorSourceIDs.contains(actual.id),
                  let clipped = actual.span(asOf: asOf).intersection(with: segmentSpan),
                  clipped.start < dayEnd,
                  clipped.end > dayStart
            else { return nil }
            let minutes = clippedMinutes(clipped, dayStart: dayStart)
            return MapHomeSectionDetail(
                id: actual.id,
                title: actual.title,
                categoryID: RecordAnalysisCategoryPolicy.categoryID(for: actual),
                behavior: actual.behavior,
                startMinute: minutes.start,
                endMinute: minutes.end
            )
        }
        result.append(contentsOf: travel.compactMap { item -> MapHomeSectionDetail? in
            guard !majorSourceIDs.contains(item.id),
                  let clipped = item.span.intersection(with: segmentSpan),
                  clipped.start < dayEnd,
                  clipped.end > dayStart
            else { return nil }
            let minutes = clippedMinutes(clipped, dayStart: dayStart)
            return MapHomeSectionDetail(
                id: item.id,
                title: "\(MovementPresentation.title(for: item.mode)) 탑승",
                categoryID: "movement",
                behavior: item.mode.rawValue,
                startMinute: minutes.start,
                endMinute: minutes.end
            )
        })
        return result.sorted { lhs, rhs in
            lhs.startMinute == rhs.startMinute
                ? lhs.endMinute < rhs.endMinute
                : lhs.startMinute < rhs.startMinute
        }
    }

    private static func clippedMinutes(
        _ span: TimeSpan,
        dayStart: Date
    ) -> (start: Int, end: Int) {
        let start = min(
            1_440,
            max(0, Int((span.start.timeIntervalSince(dayStart) / 60).rounded(.down)))
        )
        let end = min(
            1_440,
            max(start + 1, Int((span.end.timeIntervalSince(dayStart) / 60).rounded(.up)))
        )
        return (start, end)
    }
}

private struct MapHomeSectionEditSelection: Identifiable {
    let id = UUID()
    let date: Date
    let minute: Int
    let activity: MapHomeTimeSidebarActivity
    let segment: MapHomeTimeRailSegment
    let details: [MapHomeSectionDetail]

}

struct MapHomeSectionViewportState: Hashable {
    var startMinute: Int
    var durationMinutes: Int

    var range: ClosedRange<Int> {
        startMinute...min(1_440, startMinute + durationMinutes)
    }
}

enum MapHomeSectionViewportMath {
    static let minimumDurationMinutes = 30
    static let maximumDurationMinutes = 1_440

    static func initialState(
        segmentStart: Int,
        segmentEnd: Int
    ) -> MapHomeSectionViewportState {
        let center = (segmentStart + segmentEnd) / 2
        let duration = min(
            maximumDurationMinutes,
            max(360, segmentEnd - segmentStart + 180)
        )
        return state(centerMinute: center, durationMinutes: duration)
    }

    static func zoomed(
        from origin: MapHomeSectionViewportState,
        magnification: CGFloat,
        anchorY: CGFloat,
        height: CGFloat
    ) -> MapHomeSectionViewportState {
        guard magnification.isFinite, magnification > 0, height > 0 else {
            return origin
        }
        let duration = min(
            maximumDurationMinutes,
            max(
                minimumDurationMinutes,
                Int((CGFloat(origin.durationMinutes) / magnification).rounded())
            )
        )
        let fraction = min(max(anchorY / height, 0), 1)
        let anchorMinute = CGFloat(origin.startMinute)
            + CGFloat(origin.durationMinutes) * fraction
        let proposedStart = Int(
            (anchorMinute - CGFloat(duration) * fraction).rounded()
        )
        return MapHomeSectionViewportState(
            startMinute: min(max(proposedStart, 0), 1_440 - duration),
            durationMinutes: duration
        )
    }

    static func minute(
        atY y: CGFloat,
        height: CGFloat,
        viewport: MapHomeSectionViewportState
    ) -> Int {
        let fraction = min(max(y / max(height, 1), 0), 1)
        return min(
            viewport.range.upperBound,
            max(
                viewport.range.lowerBound,
                viewport.startMinute
                    + Int((fraction * CGFloat(viewport.durationMinutes)).rounded())
            )
        )
    }

    static func acceptsDetailSlice(
        translation: CGSize,
        minimumDistance: CGFloat = 64
    ) -> Bool {
        translation.width >= minimumDistance
            && abs(translation.width) > abs(translation.height) * 1.5
    }

    private static func state(
        centerMinute: Int,
        durationMinutes: Int
    ) -> MapHomeSectionViewportState {
        let duration = min(
            maximumDurationMinutes,
            max(minimumDurationMinutes, durationMinutes)
        )
        return MapHomeSectionViewportState(
            startMinute: min(
                max(centerMinute - duration / 2, 0),
                maximumDurationMinutes - duration
            ),
            durationMinutes: duration
        )
    }
}

enum MapHomeSectionTimelineLayoutMath {
    static let timeGutterWidth: CGFloat = 52
    static let minimumGap: CGFloat = 8
    static let trailingInset: CGFloat = 8
    static let detailColumnSpacing: CGFloat = 4

    struct DetailColumn: Hashable {
        let index: Int
        let count: Int

        static let single = DetailColumn(index: 0, count: 1)
    }

    private struct DetailInterval {
        let id: UUID
        let startMinute: Int
        let endMinute: Int
    }

    static func detailFrame(leftWidth: CGFloat) -> CGRect {
        let minX = timeGutterWidth + minimumGap
        return CGRect(
            x: minX,
            y: 0,
            width: max(1, leftWidth - minX - trailingInset),
            height: 1
        )
    }

    static func detailFrame(
        leftWidth: CGFloat,
        column: DetailColumn
    ) -> CGRect {
        let container = detailFrame(leftWidth: leftWidth)
        let count = max(1, column.count)
        let index = min(max(column.index, 0), count - 1)
        let totalSpacing = detailColumnSpacing * CGFloat(count - 1)
        let width = max(
            1,
            (container.width - totalSpacing) / CGFloat(count)
        )
        return CGRect(
            x: container.minX
                + CGFloat(index) * (width + detailColumnSpacing),
            y: container.minY,
            width: width,
            height: container.height
        )
    }

    static func detailColumns(
        for details: [MapHomeSectionDetail],
        visibleRange: ClosedRange<Int>
    ) -> [UUID: DetailColumn] {
        let intervals = details.compactMap { detail -> DetailInterval? in
            let start = max(detail.startMinute, visibleRange.lowerBound)
            let end = min(detail.endMinute, visibleRange.upperBound)
            guard start < end else { return nil }
            return DetailInterval(
                id: detail.id,
                startMinute: start,
                endMinute: end
            )
        }
        .sorted { lhs, rhs in
            if lhs.startMinute == rhs.startMinute {
                if lhs.endMinute == rhs.endMinute {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.endMinute < rhs.endMinute
            }
            return lhs.startMinute < rhs.startMinute
        }

        var result: [UUID: DetailColumn] = [:]
        var group: [DetailInterval] = []
        var groupEnd = Int.min
        for interval in intervals {
            if !group.isEmpty, interval.startMinute >= groupEnd {
                assignColumns(in: group, to: &result)
                group.removeAll(keepingCapacity: true)
                groupEnd = Int.min
            }
            group.append(interval)
            groupEnd = max(groupEnd, interval.endMinute)
        }
        assignColumns(in: group, to: &result)
        return result
    }

    private static func assignColumns(
        in group: [DetailInterval],
        to result: inout [UUID: DetailColumn]
    ) {
        guard !group.isEmpty else { return }
        var columnEnds: [Int] = []
        var indices: [UUID: Int] = [:]
        for interval in group {
            let index = columnEnds.firstIndex {
                $0 <= interval.startMinute
            } ?? columnEnds.count
            if index == columnEnds.count {
                columnEnds.append(interval.endMinute)
            } else {
                columnEnds[index] = interval.endMinute
            }
            indices[interval.id] = index
        }
        let count = max(1, columnEnds.count)
        for interval in group {
            result[interval.id] = DetailColumn(
                index: indices[interval.id] ?? 0,
                count: count
            )
        }
    }
}

private struct MapHomeSectionPreviewPiece: Identifiable {
    let id: String
    let startMinute: Int
    let endMinute: Int
    let category: MapHomeSidebarMajorCategory
}

enum MapHomeSectionBoundaryMath {
    static let minimumPublishInterval: TimeInterval = 1.0 / 60.0

    static func minute(
        baseMinute: Int,
        translation: CGFloat,
        trackHeight: CGFloat,
        visibleRange: ClosedRange<Int>,
        limit: Int,
        isStart: Bool
    ) -> Int {
        let duration = max(1, visibleRange.upperBound - visibleRange.lowerBound)
        let delta = Int(
            (translation / max(trackHeight, 1) * CGFloat(duration)).rounded()
        )
        let raw = baseMinute + delta
        return isStart
            ? min(max(raw, visibleRange.lowerBound), limit - 1)
            : max(min(raw, visibleRange.upperBound), limit + 1)
    }

    static func shouldPublish(
        lastUptime: TimeInterval,
        currentUptime: TimeInterval,
        isFinal: Bool
    ) -> Bool {
        isFinal || currentUptime - lastUptime >= minimumPublishInterval
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

enum MapHomeMovementEditOption {
    static let modes: [TravelMode] = [
        .walking,
        .cycling,
        .car,
        .subway,
        .bus,
        .ship,
        .airplane,
        .train,
    ]

    static func mode(
        categoryID: String,
        behavior: String?,
        title: String
    ) -> TravelMode? {
        guard categoryID == "movement" else { return nil }
        if let behavior,
           let mode = TravelMode(rawValue: behavior),
           modes.contains(mode) {
            return mode
        }
        return modes.first {
            MovementPresentation.title(for: $0) == title
                || englishTitle(for: $0) == title
        }
    }

    static func localizedTitle(
        for mode: TravelMode,
        language: MapHomeLanguage
    ) -> String {
        language.text(
            MovementPresentation.title(for: mode),
            englishTitle(for: mode)
        )
    }

    private static func englishTitle(for mode: TravelMode) -> String {
        switch mode {
        case .walking: "Walking"
        case .cycling: "Bicycle"
        case .car: "Car"
        case .subway: "Subway"
        case .bus: "Bus"
        case .ship: "Ship"
        case .airplane: "Airplane"
        case .train: "Train"
        case .running: "Running"
        case .taxi: "Taxi"
        }
    }
}

private struct MapHomeSectionEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let selection: MapHomeSectionEditSelection
    let language: MapHomeLanguage
    let onSaved: (ActivitySectionEditSaveResult) -> Void

    @State private var startMinute: Int
    @State private var endMinute: Int
    @State private var selectedCategoryID: String
    @State private var selectedMovementMode: TravelMode?
    @State private var movementSelectionWasChanged = false
    @State private var dragBaseMinute: Int?
    @State private var lastDragPublishUptime: TimeInterval = 0
    @State private var viewport: MapHomeSectionViewportState
    @State private var magnifyOrigin: MapHomeSectionViewportState?
    @State private var lastMagnifyPublishUptime: TimeInterval = 0
    @State private var cutMinute: Int?
    @State private var cutDragBaseMinute: Int?
    @State private var insertedDetailID: UUID?
    @State private var draggingDetailID: UUID?
    @State private var detailDragTranslation: CGFloat = 0
    @State private var isSaving = false

    init(
        model: AppModel,
        selection: MapHomeSectionEditSelection,
        language: MapHomeLanguage,
        onSaved: @escaping (ActivitySectionEditSaveResult) -> Void
    ) {
        self.model = model
        self.selection = selection
        self.language = language
        self.onSaved = onSaved
        _startMinute = State(initialValue: selection.segment.startMinute)
        _endMinute = State(initialValue: selection.segment.endMinute)
        _selectedCategoryID = State(initialValue: selection.segment.categoryID)
        _selectedMovementMode = State(initialValue: MapHomeMovementEditOption.mode(
            categoryID: selection.segment.categoryID,
            behavior: selection.segment.behavior,
            title: selection.segment.title
        ))
        _viewport = State(initialValue: MapHomeSectionViewportMath.initialState(
            segmentStart: selection.segment.startMinute,
            segmentEnd: selection.segment.endMinute
        ))
    }

    private var categories: [MapHomeSidebarMajorCategory] {
        MapHomeSidebarMajorCategory.all(
            categoryColors: model.settings.mapCategoryColors
        ) + model.settings.mapUserActivityCategories.map(MapHomeSidebarMajorCategory.custom)
    }

    private var selectedCategory: MapHomeSidebarMajorCategory {
        categories.first { $0.id == selectedCategoryID }
            ?? MapHomeSidebarMajorCategory.presentation(
                for: selectedCategoryID,
                categoryColors: model.settings.mapCategoryColors
            )
    }

    private var selectedPreviewCategory: MapHomeSidebarMajorCategory {
        guard selectedCategoryID == "movement",
              let selectedMovementMode else { return selectedCategory }
        return MapHomeSidebarMajorCategory(
            id: "movement:\(selectedMovementMode.rawValue)",
            title: MapHomeMovementEditOption.localizedTitle(
                for: selectedMovementMode,
                language: language
            ),
            systemImage: MovementPresentation.symbol(for: selectedMovementMode),
            hex: model.settings.mapCategoryColors["movement"]
                ?? CanonicalCategoryPalette.hex("movement")
        )
    }

    private var visibleRange: ClosedRange<Int> {
        viewport.range
    }

    private var insertedDetail: MapHomeSectionDetail? {
        guard let insertedDetailID else { return nil }
        return selection.details.first { $0.id == insertedDetailID }
    }

    private var originalOption: ActivityCorrectionOption {
        ActivityCorrectionOption(
            id: "phase.\(selection.segment.categoryID)",
            title: selection.segment.title,
            behavior: selection.segment.behavior,
            categoryID: selection.segment.categoryID,
            systemImage: selection.activity.systemImage,
            isAutomatic: false,
            isCustom: false
        )
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Button(language.text("닫기", "Close")) { dismiss() }
                    .buttonStyle(.bordered)
                Spacer()
                Text(language.text("행동 구간 편집", "Edit activity section"))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Spacer()
                Button(language.text("저장", "Save")) {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || startMinute >= endMinute)
            }

            HStack(spacing: 10) {
                timeControl(
                    title: language.text("시작", "Start"),
                    minute: startMinute,
                    range: selection.segment.startMinute...(endMinute - 1),
                    isStart: true
                )
                .disabled(cutMinute != nil || insertedDetail != nil)
                .opacity(cutMinute != nil || insertedDetail != nil ? 0.62 : 1)
                timeControl(
                    title: language.text("끝", "End"),
                    minute: endMinute,
                    range: (startMinute + 1)...selection.segment.endMinute,
                    isStart: false
                )
                .disabled(cutMinute != nil || insertedDetail != nil)
                .opacity(cutMinute != nil || insertedDetail != nil ? 0.62 : 1)
                categorySelectionMenu
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
                .frame(height: 44)
                .background(Color.tpSurface, in: Capsule())
            }
            HStack(spacing: 8) {
                Button {
                    if cutMinute == nil {
                        insertedDetailID = nil
                        cutMinute = (selection.segment.startMinute
                            + selection.segment.endMinute) / 2
                    } else {
                        cutMinute = nil
                    }
                } label: {
                    Label(
                        cutMinute == nil
                            ? language.text("대분류 자르기", "Slice category")
                            : language.text("자르기 취소", "Cancel slice"),
                        systemImage: cutMinute == nil ? "scissors" : "xmark"
                    )
                }
                .buttonStyle(.bordered)

                if cutMinute != nil || insertedDetail != nil {
                    Button(language.text("편집 초기화", "Reset edit")) {
                        cutMinute = nil
                        insertedDetailID = nil
                        startMinute = selection.segment.startMinute
                        endMinute = selection.segment.endMinute
                        selectedCategoryID = selection.segment.categoryID
                        selectedMovementMode = MapHomeMovementEditOption.mode(
                            categoryID: selection.segment.categoryID,
                            behavior: selection.segment.behavior,
                            title: selection.segment.title
                        )
                        movementSelectionWasChanged = false
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                Text(
                    insertedDetail == nil
                        ? language.text(
                            "상세 활동을 오른쪽으로 밀어 삽입",
                            "Swipe a detail right to insert"
                        )
                        : language.text("상세 활동 시간으로 분할됨", "Split to detail time")
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            HStack {
                Text(language.text("상세 활동", "Detailed activities"))
                    .frame(maxWidth: .infinity)
                Text(language.text("대분류", "Category"))
                    .frame(width: 118)
            }
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(.secondary)

            GeometryReader { proxy in
                let trackHeight = max(proxy.size.height, 1)
                let leftWidth = max(120, proxy.size.width - 130)
                let detailColumns = MapHomeSectionTimelineLayoutMath
                    .detailColumns(
                        for: selection.details,
                        visibleRange: visibleRange
                    )
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.tpSurface)

                    timelineGrid(height: trackHeight)

                    ForEach(selection.details) { detail in
                        detailBlock(
                            detail,
                            column: detailColumns[detail.id] ?? .single,
                            leftWidth: leftWidth,
                            height: trackHeight
                        )
                    }

                    majorTimeline(
                        x: leftWidth + 9,
                        width: 112,
                        height: trackHeight
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.tpLine.opacity(0.7), lineWidth: 1)
                }
                .simultaneousGesture(sectionMagnifyGesture(height: trackHeight))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(Color.tpBackground.ignoresSafeArea())
    }

    private var categorySelectionMenu: some View {
        Menu {
            ForEach(categories) { category in
                if category.id == "movement" {
                    Menu {
                        Button {
                            selectCategory(category, movementMode: nil)
                        } label: {
                            Label(
                                category.localizedTitle(language),
                                systemImage: category.systemImage
                            )
                        }
                        Divider()
                        ForEach(MapHomeMovementEditOption.modes, id: \.self) { mode in
                            Button {
                                selectCategory(category, movementMode: mode)
                            } label: {
                                Label(
                                    MapHomeMovementEditOption.localizedTitle(
                                        for: mode,
                                        language: language
                                    ),
                                    systemImage: MovementPresentation.symbol(for: mode)
                                )
                            }
                        }
                    } label: {
                        Label(
                            category.localizedTitle(language),
                            systemImage: category.systemImage
                        )
                    }
                } else {
                    Button {
                        selectCategory(category, movementMode: nil)
                    } label: {
                        Label(
                            category.localizedTitle(language),
                            systemImage: category.systemImage
                        )
                    }
                }
            }
        } label: {
            Label(
                selectedMovementMode.map {
                    MapHomeMovementEditOption.localizedTitle(
                        for: $0,
                        language: language
                    )
                } ?? selectedCategory.localizedTitle(language),
                systemImage: selectedMovementMode.map {
                    MovementPresentation.symbol(for: $0)
                } ?? selectedCategory.systemImage
            )
            .font(.system(size: 13, weight: .semibold, design: .rounded))
        }
    }

    private func selectCategory(
        _ category: MapHomeSidebarMajorCategory,
        movementMode: TravelMode?
    ) {
        selectedCategoryID = category.id
        selectedMovementMode = category.id == "movement" ? movementMode : nil
        movementSelectionWasChanged = true
    }

    private func timeControl(
        title: String,
        minute: Int,
        range: ClosedRange<Int>,
        isStart: Bool
    ) -> some View {
        Menu {
            Picker(
                title,
                selection: Binding(
                    get: { isStart ? startMinute : endMinute },
                    set: { value in
                        if isStart {
                            startMinute = value
                        } else {
                            endMinute = value
                        }
                    }
                )
            ) {
                ForEach(Array(stride(from: range.lowerBound, through: range.upperBound, by: 5)), id: \.self) {
                    Text(timeLabel($0)).tag($0)
                }
            }
        } label: {
            VStack(spacing: 1) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(timeLabel(minute)).font(.system(size: 13, weight: .bold, design: .rounded))
            }
            .frame(width: 70, height: 44)
            .background(Color.tpSurface, in: Capsule())
        }
    }

    private func timelineGrid(height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(hourMarks, id: \.self) { minute in
                let y = yPosition(minute, height: height)
                Path { path in
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: 1_000, y: y))
                }
                .stroke(Color.tpLine.opacity(0.45), lineWidth: 1)
                Text(timeLabel(minute))
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 5)
                    .position(x: 23, y: max(7, y + 7))
            }
        }
    }

    private var hourMarks: [Int] {
        let first = Int(ceil(Double(visibleRange.lowerBound) / 60)) * 60
        return Array(stride(from: first, through: visibleRange.upperBound, by: 60))
    }

    @ViewBuilder
    private func detailBlock(
        _ detail: MapHomeSectionDetail,
        column: MapHomeSectionTimelineLayoutMath.DetailColumn,
        leftWidth: CGFloat,
        height: CGFloat
    ) -> some View {
        let start = max(detail.startMinute, visibleRange.lowerBound)
        let end = min(detail.endMinute, visibleRange.upperBound)
        if start < end {
            let y = yPosition(start, height: height)
            let blockHeight = max(26, yPosition(end, height: height) - y)
            let detailFrame = MapHomeSectionTimelineLayoutMath.detailFrame(
                leftWidth: leftWidth,
                column: column
            )
            let isCompact = column.count > 1
            let category = MapHomeSidebarMajorCategory.presentation(
                for: detail.categoryID,
                categoryColors: model.settings.mapCategoryColors
            )
            HStack(spacing: isCompact ? 2 : 5) {
                Image(systemName: category.systemImage)
                VStack(alignment: .leading, spacing: 1) {
                    Text(detail.title).lineLimit(1)
                    Text("\(timeLabel(detail.startMinute))–\(timeLabel(detail.endMinute))")
                        .font(.system(
                            size: isCompact ? 8 : 9,
                            weight: .medium,
                            design: .rounded
                        ))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .opacity(0.72)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .bold))
            }
            .font(.system(
                size: isCompact ? 9 : 11,
                weight: .semibold,
                design: .rounded
            ))
            .foregroundStyle(category.tint)
            .padding(.horizontal, isCompact ? 5 : 8)
            .frame(width: detailFrame.width, height: blockHeight, alignment: .leading)
            .background(
                insertedDetailID == detail.id
                    ? category.tint.opacity(0.30)
                    : category.tint.opacity(0.13),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .offset(
                x: draggingDetailID == detail.id
                    ? min(max(detailDragTranslation, 0), 94)
                    : 0
            )
            .position(x: detailFrame.midX, y: y + blockHeight / 2)
            .highPriorityGesture(detailSliceGesture(detail))
            .accessibilityLabel("\(detail.title), \(timeLabel(detail.startMinute))부터 \(timeLabel(detail.endMinute))")
            .accessibilityHint(
                language.text(
                    "오른쪽으로 밀면 대분류에 삽입합니다",
                    "Swipe right to insert into the category"
                )
            )
        }
    }

    private func detailSliceGesture(
        _ detail: MapHomeSectionDetail
    ) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard value.translation.width > 0,
                      abs(value.translation.width) > abs(value.translation.height)
                else { return }
                draggingDetailID = detail.id
                detailDragTranslation = value.translation.width
            }
            .onEnded { value in
                if draggingDetailID == detail.id,
                   MapHomeSectionViewportMath.acceptsDetailSlice(
                       translation: value.translation
                   ) {
                    activateDetailSlice(detail)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
                draggingDetailID = nil
                detailDragTranslation = 0
            }
    }

    private func activateDetailSlice(_ detail: MapHomeSectionDetail) {
        let start = max(detail.startMinute, selection.segment.startMinute)
        let end = min(detail.endMinute, selection.segment.endMinute)
        guard start < end else { return }
        cutMinute = nil
        insertedDetailID = detail.id
        startMinute = start
        endMinute = end
        selectedCategoryID = categories.contains { $0.id == detail.categoryID }
            ? detail.categoryID
            : "activity"
        selectedMovementMode = MapHomeMovementEditOption.mode(
            categoryID: detail.categoryID,
            behavior: detail.behavior,
            title: detail.title
        )
        movementSelectionWasChanged = false
    }

    private func majorTimeline(
        x: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(majorPreviewPieces) { piece in
                if piece.endMinute > visibleRange.lowerBound,
                   piece.startMinute < visibleRange.upperBound {
                    majorPreviewBlock(piece, width: width, height: height)
                        .position(
                            x: x + width / 2,
                            y: yPosition(
                                (max(piece.startMinute, visibleRange.lowerBound)
                                    + min(piece.endMinute, visibleRange.upperBound)) / 2,
                                height: height
                            )
                        )
                }
            }

            if cutMinute == nil, insertedDetail == nil {
                boundaryHandle(isStart: true, x: x, width: width, height: height)
                boundaryHandle(isStart: false, x: x, width: width, height: height)
            }

            if let cutMinute {
                ZStack {
                    Capsule().fill(Color.white)
                    Image(systemName: "scissors")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.tpInk)
                }
                .frame(width: width - 12, height: 12)
                .contentShape(Rectangle().inset(by: -12))
                .position(
                    x: x + width / 2,
                    y: yPosition(cutMinute, height: height)
                )
                .highPriorityGesture(cutDragGesture(trackHeight: height))
                .accessibilityLabel(language.text("자르기 위치", "Slice position"))
                .accessibilityValue(timeLabel(cutMinute))
            }
        }
    }

    private var majorPreviewPieces: [MapHomeSectionPreviewPiece] {
        let originalStart = selection.segment.startMinute
        let originalEnd = selection.segment.endMinute
        let originalCategory = MapHomeSidebarMajorCategory(
            id: selection.segment.categoryID,
            title: selection.segment.title,
            systemImage: selection.activity.systemImage,
            hex: model.settings.mapCategoryColors[selection.segment.categoryID]
                ?? CanonicalCategoryPalette.hex(selection.segment.categoryID)
        )
        let unconfirmed = MapHomeSidebarMajorCategory.presentation(
            for: "unconfirmed",
            categoryColors: model.settings.mapCategoryColors
        )
        let raw: [(Int, Int, MapHomeSidebarMajorCategory)]
        if let detail = insertedDetail {
            let detailStart = max(detail.startMinute, originalStart)
            let detailEnd = min(detail.endMinute, originalEnd)
            raw = [
                (originalStart, detailStart, originalCategory),
                (detailStart, detailEnd, selectedPreviewCategory),
                (detailEnd, originalEnd, originalCategory),
            ]
        } else if let cutMinute {
            raw = [
                (originalStart, cutMinute, selectedPreviewCategory),
                (cutMinute, originalEnd, unconfirmed),
            ]
        } else {
            raw = [
                (originalStart, startMinute, unconfirmed),
                (startMinute, endMinute, selectedPreviewCategory),
                (endMinute, originalEnd, unconfirmed),
            ]
        }
        return raw.enumerated().compactMap { index, value in
            guard value.0 < value.1 else { return nil }
            return MapHomeSectionPreviewPiece(
                id: "\(index)-\(value.0)-\(value.1)-\(value.2.id)",
                startMinute: value.0,
                endMinute: value.1,
                category: value.2
            )
        }
    }

    private func majorPreviewBlock(
        _ piece: MapHomeSectionPreviewPiece,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        let visibleStart = max(piece.startMinute, visibleRange.lowerBound)
        let visibleEnd = min(piece.endMinute, visibleRange.upperBound)
        let blockHeight = max(
            1,
            yPosition(visibleEnd, height: height)
                - yPosition(visibleStart, height: height)
        )
        return ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(piece.category.tint.opacity(0.88))
            if blockHeight >= 34 {
                VStack(spacing: 2) {
                    Image(systemName: piece.category.systemImage)
                    Text(piece.category.localizedTitle(language)).lineLimit(1)
                    if blockHeight >= 54 {
                        Text("\(timeLabel(piece.startMinute))–\(timeLabel(piece.endMinute))")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                    }
                }
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            }
        }
        .frame(width: width, height: blockHeight)
    }

    private func boundaryHandle(
        isStart: Bool,
        x: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        Capsule()
            .fill(Color.white)
            .overlay(Capsule().stroke(Color.tpInk.opacity(0.25), lineWidth: 1))
            .frame(width: width - 20, height: 8)
            .contentShape(Rectangle().inset(by: -12))
            .position(
                x: x + width / 2,
                y: yPosition(isStart ? startMinute : endMinute, height: height)
            )
            .highPriorityGesture(
                boundaryDragGesture(isStart: isStart, trackHeight: height)
            )
    }

    private func cutDragGesture(trackHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                updateCutMinute(
                    translation: value.translation.height,
                    trackHeight: trackHeight,
                    isFinal: false
                )
            }
            .onEnded { value in
                updateCutMinute(
                    translation: value.translation.height,
                    trackHeight: trackHeight,
                    isFinal: true
                )
                cutDragBaseMinute = nil
                lastDragPublishUptime = 0
            }
    }

    private func updateCutMinute(
        translation: CGFloat,
        trackHeight: CGFloat,
        isFinal: Bool
    ) {
        if cutDragBaseMinute == nil {
            cutDragBaseMinute = cutMinute
        }
        guard let cutDragBaseMinute else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        guard MapHomeSectionBoundaryMath.shouldPublish(
            lastUptime: lastDragPublishUptime,
            currentUptime: uptime,
            isFinal: isFinal
        ) else { return }
        lastDragPublishUptime = uptime
        let delta = Int(
            (translation / max(trackHeight, 1)
                * CGFloat(viewport.durationMinutes)).rounded()
        )
        cutMinute = min(
            max(cutDragBaseMinute + delta, selection.segment.startMinute + 1),
            selection.segment.endMinute - 1
        )
    }

    private func boundaryDragGesture(
        isStart: Bool,
        trackHeight: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                updateBoundary(
                    translation: value.translation.height,
                    isStart: isStart,
                    trackHeight: trackHeight,
                    isFinal: false
                )
            }
            .onEnded { value in
                updateBoundary(
                    translation: value.translation.height,
                    isStart: isStart,
                    trackHeight: trackHeight,
                    isFinal: true
                )
                dragBaseMinute = nil
                lastDragPublishUptime = 0
            }
    }

    private func updateBoundary(
        translation: CGFloat,
        isStart: Bool,
        trackHeight: CGFloat,
        isFinal: Bool
    ) {
        if dragBaseMinute == nil {
            dragBaseMinute = isStart ? startMinute : endMinute
        }
        guard let dragBaseMinute else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        guard MapHomeSectionBoundaryMath.shouldPublish(
            lastUptime: lastDragPublishUptime,
            currentUptime: uptime,
            isFinal: isFinal
        ) else { return }
        lastDragPublishUptime = uptime
        let projectedMinute = MapHomeSectionBoundaryMath.minute(
            baseMinute: dragBaseMinute,
            translation: translation,
            trackHeight: trackHeight,
            visibleRange: visibleRange,
            limit: isStart ? endMinute : startMinute,
            isStart: isStart
        )
        let minute = isStart
            ? max(projectedMinute, selection.segment.startMinute)
            : min(projectedMinute, selection.segment.endMinute)
        if isStart {
            if startMinute != minute { startMinute = minute }
        } else if endMinute != minute {
            endMinute = minute
        }
    }

    private func sectionMagnifyGesture(
        height: CGFloat
    ) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.005)
            .onChanged { value in
                if magnifyOrigin == nil {
                    magnifyOrigin = viewport
                }
                guard let magnifyOrigin else { return }
                let uptime = ProcessInfo.processInfo.systemUptime
                guard MapHomeSectionBoundaryMath.shouldPublish(
                    lastUptime: lastMagnifyPublishUptime,
                    currentUptime: uptime,
                    isFinal: false
                ) else { return }
                lastMagnifyPublishUptime = uptime
                viewport = MapHomeSectionViewportMath.zoomed(
                    from: magnifyOrigin,
                    magnification: value.magnification,
                    anchorY: value.startLocation.y,
                    height: height
                )
            }
            .onEnded { value in
                if let magnifyOrigin {
                    viewport = MapHomeSectionViewportMath.zoomed(
                        from: magnifyOrigin,
                        magnification: value.magnification,
                        anchorY: value.startLocation.y,
                        height: height
                    )
                }
                self.magnifyOrigin = nil
                lastMagnifyPublishUptime = 0
            }
    }

    private func yPosition(_ minute: Int, height: CGFloat) -> CGFloat {
        let duration = max(1, visibleRange.upperBound - visibleRange.lowerBound)
        return height * CGFloat(minute - visibleRange.lowerBound) / CGFloat(duration)
    }

    private func timeLabel(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    private func save() {
        guard !isSaving, startMinute < endMinute else { return }
        isSaving = true
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: selection.date)
        guard let originalStart = calendar.date(
            byAdding: .minute,
            value: selection.segment.startMinute,
            to: dayStart
        ), let originalEnd = calendar.date(
            byAdding: .minute,
            value: selection.segment.endMinute,
            to: dayStart
        ), let start = calendar.date(
            byAdding: .minute,
            value: startMinute,
            to: dayStart
        ), let end = calendar.date(
            byAdding: .minute,
            value: endMinute,
            to: dayStart
        ) else {
            isSaving = false
            return
        }
        let option = selectedEditOption
        let originalSpan = TimeSpan(start: originalStart, end: originalEnd)
        let mode: ActivitySectionEditMode
        if let detail = insertedDetail,
           let detailStart = calendar.date(
               byAdding: .minute,
               value: max(detail.startMinute, selection.segment.startMinute),
               to: dayStart
           ),
           let detailEnd = calendar.date(
               byAdding: .minute,
               value: min(detail.endMinute, selection.segment.endMinute),
               to: dayStart
           ) {
            mode = .insertDetail(
                detailSpan: TimeSpan(start: detailStart, end: detailEnd),
                option: option
            )
        } else if let cutMinute,
                  let cutAt = calendar.date(
                      byAdding: .minute,
                      value: cutMinute,
                      to: dayStart
                  ) {
            mode = .cutLowerUnconfirmed(cutAt: cutAt, option: option)
        } else {
            mode = .replace(
                editedSpan: TimeSpan(start: start, end: end),
                option: option
            )
        }
        let request = ActivitySectionEditRequest(
            sourceIDs: selection.segment.sourceIDs,
            originalSpan: originalSpan,
            originalOption: originalOption,
            mode: mode
        )
        Task { @MainActor in
            guard let result = await model.saveActivitySectionEdit(request) else {
                isSaving = false
                return
            }
            onSaved(result)
            dismiss()
        }
    }

    private var selectedEditOption: ActivityCorrectionOption {
        let category = selectedCategory
        if category.id.hasPrefix("custom:") {
            return ActivityCorrectionOption.custom(category.title)
        }
        if category.id == "movement" {
            if let selectedMovementMode {
                return ActivityCorrectionOption(
                    id: "phase.movement.\(selectedMovementMode.rawValue)",
                    title: MovementPresentation.title(for: selectedMovementMode),
                    behavior: selectedMovementMode.rawValue,
                    categoryID: category.id,
                    systemImage: MovementPresentation.symbol(
                        for: selectedMovementMode
                    ),
                    isAutomatic: false,
                    isCustom: false
                )
            }
            if movementSelectionWasChanged {
                return ActivityCorrectionOption(
                    id: "phase.movement",
                    title: category.title,
                    behavior: nil,
                    categoryID: category.id,
                    systemImage: category.systemImage,
                    isAutomatic: false,
                    isCustom: false
                )
            }
        }
        if let detail = insertedDetail,
           detail.categoryID == category.id {
            return ActivityCorrectionOption(
                id: "detail.\(detail.id.uuidString)",
                title: detail.title,
                behavior: detail.behavior,
                categoryID: category.id,
                systemImage: category.systemImage,
                isAutomatic: false,
                isCustom: false
            )
        }
        return ActivityCorrectionOption(
            id: "phase.\(category.id)",
            title: category.title,
            behavior: category.id == "unconfirmed" ? "unconfirmed-gap" : nil,
            categoryID: category.id,
            systemImage: category.systemImage,
            isAutomatic: false,
            isCustom: false
        )
    }
}

private struct MapHomeCategoryAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let language: MapHomeLanguage
    @State private var title = ""
    @State private var systemImage = "tag.fill"
    @State private var color = Color.tpReferenceMint
    @FocusState private var isFocused: Bool

    private var iconNames: [String] {
        MapUserActivityIconCatalog.available(
            for: model.settings.mapUserActivityCategories
        )
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(language.text("행동분류 추가", "Add activity category"))
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                Spacer()
                Button(language.text("닫기", "Close")) { dismiss() }
            }

            TextField(
                language.text("행동분류 이름", "Category name"),
                text: $title
            )
            .focused($isFocused)
            .textInputAutocapitalization(.words)
            .submitLabel(.done)
            .onSubmit(save)
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.tpLine.opacity(0.7), lineWidth: 1)
            }

            HStack(spacing: 12) {
                Picker(language.text("아이콘", "Icon"), selection: $systemImage) {
                    ForEach(iconNames, id: \.self) { name in
                        Image(systemName: name).tag(name)
                    }
                }
                .pickerStyle(.menu)
                .disabled(iconNames.isEmpty)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Color.tpSurface, in: Capsule())

                ColorPicker(
                    language.text("색상", "Color"),
                    selection: $color,
                    supportsOpacity: false
                )
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Color.tpSurface, in: Capsule())
            }

            Button(action: save) {
                Text(language.text("추가", "Add"))
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
            }
            .buttonStyle(.borderedProminent)
            .disabled(trimmedTitle.isEmpty || systemImage.isEmpty)

            if iconNames.isEmpty {
                Text(
                    language.text(
                        "사용할 수 있는 새 아이콘이 없습니다.",
                        "No unused icons are available."
                    )
                )
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.tpSecondary)
            }
        }
        .padding(20)
        .background(Color.tpBackground)
        .task {
            if !iconNames.contains(systemImage) {
                systemImage = iconNames.first ?? ""
            }
            isFocused = true
        }
    }

    private func save() {
        guard !trimmedTitle.isEmpty, !systemImage.isEmpty else { return }
        guard model.addMapUserActivityCategory(
            title: trimmedTitle,
            systemImage: systemImage,
            hex: color.hexRGBString ?? "#29A383"
        ) else { return }
        dismiss()
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
    @State private var backupAlertMessage: String?
    @State private var pendingRestore: PlanCloudBackupPayload?
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
            .alert(
                language.text("iCloud 백업 결과", "iCloud Backup Result"),
                isPresented: Binding(
                    get: { backupAlertMessage != nil },
                    set: { isPresented in
                        if !isPresented { backupAlertMessage = nil }
                    }
                )
            ) {
                Button(language.text("확인", "OK")) {
                    backupAlertMessage = nil
                }
            } message: {
                Text(backupAlertMessage ?? "")
            }
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
            showBackupFeedback(
                language.text("iCloud 백업을 저장했습니다.", "iCloud backup saved.")
            )
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
            do {
                let result = try await model.applyCloudBackup(pendingRestore)
                self.pendingRestore = nil
                switch result {
                case .complete:
                    showBackupFeedback(
                        language.text(
                            "백업을 불러왔습니다.",
                            "Backup restored."
                        )
                    )
                case .snapshotOnly:
                    showBackupFeedback(
                        language.text(
                            "저장 위치는 복구했지만 이동경로 저장에 실패했습니다.",
                            "Saved locations were restored, but the route could not be saved."
                        )
                    )
                }
            } catch {
                showBackupFeedback(error.localizedDescription)
            }
            self.isApplyingRestore = false
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
                showBackupFeedback(error.localizedDescription)
            }
        }
    }

    private func showBackupFeedback(_ text: String) {
        message = text
        backupAlertMessage = text
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

private struct MapHomeExpectedRouteOverlay: Identifiable {
    let id: UUID
    let mode: TravelMode
    let departureDate: Date
    let arrivalDate: Date
    let coordinates: [CLLocationCoordinate2D]

    func visible(through cutoff: Date) -> Self? {
        guard cutoff > departureDate, coordinates.count >= 2 else { return nil }
        guard cutoff < arrivalDate else { return self }
        let duration = arrivalDate.timeIntervalSince(departureDate)
        guard duration > 0 else { return self }
        let fraction = min(
            max(cutoff.timeIntervalSince(departureDate) / duration, 0),
            1
        )
        let lastIndex = max(
            1,
            min(
                coordinates.count - 1,
                Int(ceil(Double(coordinates.count - 1) * fraction))
            )
        )
        return Self(
            id: id,
            mode: mode,
            departureDate: departureDate,
            arrivalDate: arrivalDate,
            coordinates: Array(coordinates.prefix(lastIndex + 1))
        )
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
    let state: MapHomeLocationButtonState

    private let targetColor = Color(red: 0.20, green: 0.48, blue: 0.78)
    private let dotColor = Color(red: 0.92, green: 0.25, blue: 0.28)

    var body: some View {
        ZStack {
            Image(systemName: "scope")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(targetColor)

            if state.showsTrackingDot {
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

private struct MapHomeHistoricalLocationMarker: View {
    var body: some View {
        Canvas { context, size in
            let scaleX = size.width / 22
            let scaleY = size.height / 22
            let point: (CGFloat, CGFloat) -> CGPoint = {
                CGPoint(x: $0 * scaleX, y: $1 * scaleY)
            }
            let lineWidth = min(scaleX, scaleY) * 2.4
            let color = Color.tpReferenceRose

            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: point(7.8, 1.2).x,
                        y: point(7.8, 1.2).y,
                        width: 6.4 * scaleX,
                        height: 6.4 * scaleY
                    )
                ),
                with: .color(color)
            )

            var body = Path()
            body.move(to: point(11, 8.2))
            body.addLine(to: point(11, 14.2))
            body.move(to: point(5.2, 10.7))
            body.addLine(to: point(11, 9.5))
            body.addLine(to: point(16.8, 10.7))
            body.move(to: point(11, 14.2))
            body.addLine(to: point(6.4, 20.2))
            body.move(to: point(11, 14.2))
            body.addLine(to: point(15.6, 20.2))
            context.stroke(
                body,
                with: .color(color),
                style: StrokeStyle(
                    lineWidth: lineWidth,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        }
        .frame(width: 22, height: 22)
        .padding(4)
        .background(.white, in: Circle())
        .overlay {
            Circle().stroke(Color.tpReferenceRose.opacity(0.25), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.18), radius: 3, y: 2)
        .accessibilityHidden(true)
    }
}

private struct MapHomePanGestureObserver: UIViewRepresentable {
    let onSingleFingerPanBegan: () -> Void

    func makeUIView(context: Context) -> ObservationView {
        let view = ObservationView()
        view.onSingleFingerPanBegan = onSingleFingerPanBegan
        return view
    }

    func updateUIView(_ view: ObservationView, context: Context) {
        view.onSingleFingerPanBegan = onSingleFingerPanBegan
        view.attachToVisibleMapIfNeeded()
    }

    static func dismantleUIView(_ view: ObservationView, coordinator: ()) {
        view.detach()
    }

    final class ObservationView: UIView {
        var onSingleFingerPanBegan: (() -> Void)?
        private weak var observedPanGesture: UIPanGestureRecognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                self?.attachToVisibleMapIfNeeded()
            }
        }

        func attachToVisibleMapIfNeeded() {
            guard let window else {
                detach()
                return
            }
            let ownFrame = convert(bounds, to: window)
            let mapView = mapViews(in: window).max { lhs, rhs in
                overlapArea(lhs, with: ownFrame, in: window)
                    < overlapArea(rhs, with: ownFrame, in: window)
            }
            guard let mapView,
                  let panGesture = panGesture(in: mapView),
                  observedPanGesture !== panGesture else { return }
            detach()
            observedPanGesture = panGesture
            panGesture.addTarget(self, action: #selector(handlePan(_:)))
        }

        func detach() {
            observedPanGesture?.removeTarget(
                self,
                action: #selector(handlePan(_:))
            )
            observedPanGesture = nil
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard gesture.state == .began,
                  gesture.numberOfTouches == 1 else { return }
            onSingleFingerPanBegan?()
        }

        private func mapViews(in view: UIView) -> [MKMapView] {
            var result: [MKMapView] = []
            if let mapView = view as? MKMapView {
                result.append(mapView)
            }
            for child in view.subviews {
                result.append(contentsOf: mapViews(in: child))
            }
            return result
        }

        private func panGesture(in view: UIView) -> UIPanGestureRecognizer? {
            if let scrollView = view as? UIScrollView {
                return scrollView.panGestureRecognizer
            }
            for child in view.subviews {
                if let gesture = panGesture(in: child) {
                    return gesture
                }
            }
            return nil
        }

        private func overlapArea(
            _ view: UIView,
            with frame: CGRect,
            in window: UIWindow
        ) -> CGFloat {
            let intersection = view.convert(view.bounds, to: window)
                .intersection(frame)
            guard !intersection.isNull else { return 0 }
            return intersection.width * intersection.height
        }
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
