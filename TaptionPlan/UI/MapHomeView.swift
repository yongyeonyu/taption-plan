import CoreLocation
import MapKit
import Observation
import SwiftUI
import UIKit
import TaptionPlanCore

enum RouteMapLineStyle {
    static let lineWidth: CGFloat = 3
    static let minimumOpacity: Double = 0.72
}

enum MapHomeWBSTripStyle {
    static let paperHex = "#FCF9F4"
    static let actualRouteHex = "#458B88"
    static let forecastRouteHex = "#C65D4D"
    static let actualRouteOpacity = 0.96
    static let forecastRouteOpacity = 0.78
    static let actualRouteLineWidth: CGFloat = 2.2
    static let forecastRouteLineWidth: CGFloat = 1.8
    static let routeDash: [NSNumber] = [4, 3]
}

enum MapHomeCompassControlState: Equatable, Sendable {
    case directionArrow
    case compass

    var followsHeading: Bool {
        self == .compass
    }

    var mapCameraHeading: CLLocationDirection? {
        followsHeading ? nil : 0
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
    static let stickman: Double = 1
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

struct MapHomeCameraFrame: Equatable {
    let camera: MapCamera
    let centerLatitude: CLLocationDegrees
    let centerLongitude: CLLocationDegrees
    let latitudeDelta: CLLocationDegrees
    let longitudeDelta: CLLocationDegrees

    init(camera: MapCamera, region: MKCoordinateRegion) {
        self.camera = camera
        centerLatitude = region.center.latitude
        centerLongitude = region.center.longitude
        latitudeDelta = region.span.latitudeDelta
        longitudeDelta = region.span.longitudeDelta
    }

    var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: centerLatitude,
            longitude: centerLongitude
        )
    }

    var span: MKCoordinateSpan {
        MKCoordinateSpan(
            latitudeDelta: latitudeDelta,
            longitudeDelta: longitudeDelta
        )
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.camera.centerCoordinate.latitude == rhs.camera.centerCoordinate.latitude
            && lhs.camera.centerCoordinate.longitude == rhs.camera.centerCoordinate.longitude
            && lhs.camera.distance == rhs.camera.distance
            && lhs.camera.heading == rhs.camera.heading
            && lhs.camera.pitch == rhs.camera.pitch
            && lhs.centerLatitude == rhs.centerLatitude
            && lhs.centerLongitude == rhs.centerLongitude
            && lhs.latitudeDelta == rhs.latitudeDelta
            && lhs.longitudeDelta == rhs.longitudeDelta
    }
}

/// Coalesces continuous MapKit camera callbacks into display-rate frames while
/// retaining the latest input for the next render or gesture-end flush.
final class MapHomeCameraFrameProjection {
    private(set) var latestFrame: MapHomeCameraFrame?
    private var renderedFrame: MapHomeCameraFrame?
    private var inputBudget = TaptionPlanNLEInputBudgetEngine()

    func submit(
        _ frame: MapHomeCameraFrame,
        nowUptime: TimeInterval,
        force: Bool = false
    ) -> MapHomeCameraFrame? {
        latestFrame = frame
        let decision = inputBudget.submit(at: nowUptime, isFinal: force)
        guard decision.shouldPublish else { return nil }
        guard renderedFrame != frame else { return nil }
        renderedFrame = frame
        return frame
    }

    func finish(nowUptime: TimeInterval) -> MapHomeCameraFrame? {
        guard let latestFrame else { return nil }
        return submit(latestFrame, nowUptime: nowUptime, force: true)
    }

    func reset() {
        latestFrame = nil
        renderedFrame = nil
        _ = inputBudget.beginGeneration()
    }
}

final class MapHomeStickmanViewportProjection {
    private var latestPoint: CGPoint?
    private var renderedPoint: CGPoint?
    private var inputBudget = TaptionPlanNLEInputBudgetEngine()

    func submit(
        _ point: CGPoint,
        nowUptime: TimeInterval,
        force: Bool = false
    ) -> CGPoint? {
        latestPoint = point
        let decision = inputBudget.submit(at: nowUptime, isFinal: force)
        guard decision.shouldPublish else { return nil }
        if let renderedPoint,
           abs(renderedPoint.x - point.x) <= 0.25,
           abs(renderedPoint.y - point.y) <= 0.25 {
            return nil
        }
        renderedPoint = point
        return point
    }

    func finish(nowUptime: TimeInterval) -> CGPoint? {
        guard let latestPoint else { return nil }
        return submit(latestPoint, nowUptime: nowUptime, force: true)
    }
}

@MainActor
@Observable
final class MapHomeVectorViewportStore {
    private(set) var viewport: MapHomeVectorViewport?
    private(set) var stickmanPoint: CGPoint?
    private var stickmanProjection = MapHomeStickmanViewportProjection()
    private var lastParentReadbackUptime = -Double.infinity

    func update(_ next: MapHomeVectorViewport) {
        guard viewport != next else { return }
        viewport = next
    }

    func updateStickmanPoint(
        _ point: CGPoint,
        nowUptime: TimeInterval
    ) {
        guard let rendered = stickmanProjection.submit(
            point,
            nowUptime: nowUptime
        ) else { return }
        if stickmanPoint != rendered {
            stickmanPoint = rendered
        }
    }

    func finishStickmanPoint(nowUptime: TimeInterval) {
        guard let rendered = stickmanProjection.finish(nowUptime: nowUptime)
        else { return }
        if stickmanPoint != rendered {
            stickmanPoint = rendered
        }
    }

    func shouldPublishParentReadback(
        nowUptime: TimeInterval,
        isFinal: Bool
    ) -> Bool {
        guard isFinal || nowUptime - lastParentReadbackUptime >= 1.0 / 15.0
        else { return false }
        lastParentReadbackUptime = nowUptime
        return true
    }
}

private struct MapHomeCachedCoordinate: Codable, Sendable {
    let latitude: Double
    let longitude: Double
}

private struct MapHomeCachedRouteOverlay: Codable, Sendable {
    let id: String
    let categoryID: String
    let opacity: Double
    let speedMetersPerSecond: Double?
    let coordinates: [MapHomeCachedCoordinate]
}

private struct MapHomeCachedExpectedRouteOverlay: Codable, Sendable {
    let id: UUID
    let modeRawValue: String
    let departureDate: Date
    let arrivalDate: Date
    let coordinates: [MapHomeCachedCoordinate]
}

private struct MapHomeCachedSubwayRouteOverlay: Codable, Sendable {
    let id: UUID
    let estimated: Bool
    let coordinates: [MapHomeCachedCoordinate]
}

private struct MapHomeCachedTemporaryLocation: Codable, Sendable {
    let id: UUID
    let timestamp: Date
    let stationName: String
    let latitude: Double
    let longitude: Double
    let reason: String
}

private struct MapHomeTransitBoardingCandidateCacheKey: Equatable {
    let snapshotRevision: UInt64
    let readingsRevision: UInt64
    let nearbyPlacesRevision: UInt64
    let cutoff: Date
}

private struct MapHomeDayCachePayload: Codable, Sendable {
    let centerLatitude: Double
    let centerLongitude: Double
    let latitudeDelta: Double
    let longitudeDelta: Double
    let timeline: [MapHomeCachedRouteOverlay]
    let expected: [MapHomeCachedExpectedRouteOverlay]?
    let subway: [MapHomeCachedSubwayRouteOverlay]?
    let subwayMinute: Int?
    let temporaryLocations: [MapHomeCachedTemporaryLocation]?

    private enum CodingKeys: String, CodingKey {
        case centerLatitude, centerLongitude, latitudeDelta, longitudeDelta
        case timeline, expected, subway, subwayMinute, temporaryLocations
    }

    init(centerLatitude: Double, centerLongitude: Double, latitudeDelta: Double, longitudeDelta: Double,
         timeline: [MapHomeCachedRouteOverlay], expected: [MapHomeCachedExpectedRouteOverlay]?,
         subway: [MapHomeCachedSubwayRouteOverlay]?, subwayMinute: Int?,
         temporaryLocations: [MapHomeCachedTemporaryLocation]? = nil) {
        self.centerLatitude = centerLatitude
        self.centerLongitude = centerLongitude
        self.latitudeDelta = latitudeDelta
        self.longitudeDelta = longitudeDelta
        self.timeline = timeline
        self.expected = expected
        self.subway = subway
        self.subwayMinute = subwayMinute
        self.temporaryLocations = temporaryLocations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        centerLatitude = try container.decode(Double.self, forKey: .centerLatitude)
        centerLongitude = try container.decode(Double.self, forKey: .centerLongitude)
        latitudeDelta = try container.decode(Double.self, forKey: .latitudeDelta)
        longitudeDelta = try container.decode(Double.self, forKey: .longitudeDelta)
        timeline = try container.decode([MapHomeCachedRouteOverlay].self, forKey: .timeline)
        expected = try container.decodeIfPresent([MapHomeCachedExpectedRouteOverlay].self, forKey: .expected)
        subway = try container.decodeIfPresent([MapHomeCachedSubwayRouteOverlay].self, forKey: .subway)
        subwayMinute = try container.decodeIfPresent(Int.self, forKey: .subwayMinute)
        temporaryLocations = try container.decodeIfPresent([MapHomeCachedTemporaryLocation].self, forKey: .temporaryLocations)
    }
}

struct MapHomeRouteDocumentRefresh: Equatable, Sendable {
    let preparesReadings: Bool
}

/// Keeps source mutations out of the interactive render loop. Any number of
/// sensor or timeline callbacks collapse into one document refresh on commit.
final class MapHomeRouteDocumentProjectionGate {
    private var needsRefresh = false
    private var needsReadingPreparation = false

    func deferRefresh(preparingReadings: Bool) {
        needsRefresh = true
        needsReadingPreparation = needsReadingPreparation || preparingReadings
    }

    func consumeDeferredRefresh() -> MapHomeRouteDocumentRefresh? {
        guard needsRefresh || needsReadingPreparation else { return nil }
        let refresh = MapHomeRouteDocumentRefresh(
            preparesReadings: needsReadingPreparation
        )
        needsRefresh = false
        needsReadingPreparation = false
        return refresh
    }
}

private struct MapHomeRouteCoordinateBounds {
    var minLatitude = CLLocationDegrees.greatestFiniteMagnitude
    var maxLatitude = -CLLocationDegrees.greatestFiniteMagnitude
    var minLongitude = CLLocationDegrees.greatestFiniteMagnitude
    var maxLongitude = -CLLocationDegrees.greatestFiniteMagnitude

    var isEmpty: Bool {
        minLatitude == CLLocationDegrees.greatestFiniteMagnitude
    }

    mutating func include(_ coordinates: [CLLocationCoordinate2D]) {
        for coordinate in coordinates {
            guard coordinate.latitude.isFinite, coordinate.longitude.isFinite else {
                continue
            }
            minLatitude = min(minLatitude, coordinate.latitude)
            maxLatitude = max(maxLatitude, coordinate.latitude)
            minLongitude = min(minLongitude, coordinate.longitude)
            maxLongitude = max(maxLongitude, coordinate.longitude)
        }
    }
}

enum MapHomeRouteFitMath {
    static func region(
        for coordinates: [CLLocationCoordinate2D],
        minimumLatitudeDelta: CLLocationDegrees = 0.025,
        minimumLongitudeDelta: CLLocationDegrees = 0.035,
        padding: CLLocationDegrees = 1.8
    ) -> MKCoordinateRegion? {
        let valid = coordinates.filter {
            $0.latitude.isFinite
                && $0.longitude.isFinite
                && (-90...90).contains($0.latitude)
                && (-180...180).contains($0.longitude)
        }
        guard !valid.isEmpty else { return nil }
        let latitudes = valid.map(\.latitude)
        let longitudes = valid.map(\.longitude)
        let latitudeDelta = max(
            minimumLatitudeDelta,
            (latitudes.max()! - latitudes.min()!) * padding
        )
        let longitudeDelta = max(
            minimumLongitudeDelta,
            (longitudes.max()! - longitudes.min()!) * padding
        )
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (latitudes.max()! + latitudes.min()!) / 2,
                longitude: (longitudes.max()! + longitudes.min()!) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: latitudeDelta,
                longitudeDelta: longitudeDelta
            )
        )
    }
}

private final class MapHomeMapRenderCache {
    private(set) var subwayRouteOverlays: [MapHomeSubwayRouteOverlay]?
    private(set) var subwayRouteDay: Date?
    private(set) var subwayRouteMinute: Int?
    private(set) var visibleExpectedRouteOverlays: [MapHomeExpectedRouteOverlay]?
    private(set) var visibleExpectedRouteCutoff: Date?
    private(set) var routeBounds: MapHomeRouteCoordinateBounds?
    private var transitBoardingCandidateCache:
        (key: MapHomeTransitBoardingCandidateCacheKey, candidates: [TransitBoardingCandidate])?

    func invalidateRouteData() {
        subwayRouteOverlays = nil
        subwayRouteDay = nil
        subwayRouteMinute = nil
        visibleExpectedRouteOverlays = nil
        visibleExpectedRouteCutoff = nil
        routeBounds = nil
        transitBoardingCandidateCache = nil
    }

    func transitBoardingCandidates(
        key: MapHomeTransitBoardingCandidateCacheKey,
        make: () -> [TransitBoardingCandidate]
    ) -> [TransitBoardingCandidate] {
        if let cached = transitBoardingCandidateCache,
           cached.key == key {
            return cached.candidates
        }
        let candidates = make()
        transitBoardingCandidateCache = (key, candidates)
        return candidates
    }

    func invalidateExpectedRoutes() {
        visibleExpectedRouteOverlays = nil
        visibleExpectedRouteCutoff = nil
        routeBounds = nil
    }

    func restoreSubwayRoutes(
        day: Date,
        minute: Int,
        overlays: [MapHomeSubwayRouteOverlay]
    ) {
        subwayRouteDay = day
        subwayRouteMinute = minute
        subwayRouteOverlays = overlays
        routeBounds = nil
    }

    func subwayRoutes(
        day: Date,
        minute: Int,
        make: () -> [MapHomeSubwayRouteOverlay]
    ) -> [MapHomeSubwayRouteOverlay] {
        if subwayRouteDay == day,
           subwayRouteMinute == minute,
           let subwayRouteOverlays {
            return subwayRouteOverlays
        }
        let overlays = make()
        subwayRouteDay = day
        subwayRouteMinute = minute
        subwayRouteOverlays = overlays
        routeBounds = nil
        return overlays
    }

    func visibleExpectedRoutes(
        cutoff: Date,
        make: () -> [MapHomeExpectedRouteOverlay]
    ) -> [MapHomeExpectedRouteOverlay] {
        if visibleExpectedRouteCutoff == cutoff,
           let visibleExpectedRouteOverlays {
            return visibleExpectedRouteOverlays
        }
        let overlays = make()
        visibleExpectedRouteCutoff = cutoff
        visibleExpectedRouteOverlays = overlays
        routeBounds = nil
        return overlays
    }

    func bounds(
        timeline: [MapHomeTimelineRouteOverlay],
        expected: [MapHomeExpectedRouteOverlay],
        generated: [MapHomeWBSGeneratedRouteOverlay],
        subway: [MapHomeSubwayRouteOverlay],
        current: CLLocationCoordinate2D?
    ) -> MapHomeRouteCoordinateBounds? {
        if let routeBounds { return routeBounds }
        var bounds = MapHomeRouteCoordinateBounds()
        timeline.forEach { bounds.include($0.coordinates) }
        expected.forEach { bounds.include($0.coordinates) }
        generated.forEach { bounds.include($0.coordinates) }
        subway.forEach { bounds.include($0.coordinates) }
        if bounds.isEmpty, let current {
            bounds.include([current])
        }
        routeBounds = bounds.isEmpty ? nil : bounds
        return routeBounds
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
    private(set) var headingDegrees: CLLocationDirection?

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
        guard heading.isFinite else { return }
        headingDegrees = heading
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
    static let routeProjectionInterval: TimeInterval = 0.25
    static let mapFocusInterval: TimeInterval = 1.0 / 30.0
    static let stationaryMinutesPerSecond = 60.0
    static let movementPlaybackMultiplier = 1.0 / 6.0
    static let movingMinutesPerSecond = stationaryMinutesPerSecond * movementPlaybackMultiplier

    static func playbackEndMinute(
        for selectedDate: Date,
        now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Double {
        guard calendar.isDate(selectedDate, inSameDayAs: now) else {
            return Double(MapHomeTimeSidebarMath.fullDayMinutes)
        }
        let components = calendar.dateComponents([.hour, .minute, .second], from: now)
        let minute = Double((components.hour ?? 0) * 60 + (components.minute ?? 0))
            + Double(components.second ?? 0) / 60
        return min(
            Double(MapHomeTimeSidebarMath.fullDayMinutes),
            max(0, minute)
        )
    }

    static func playbackStartMinute(
        selectedMinute: Int?,
        endMinute: Double,
        isToday: Bool
    ) -> Double {
        let selected = min(
            Double(MapHomeTimeSidebarMath.fullDayMinutes),
            max(0, Double(selectedMinute ?? 0))
        )
        guard isToday, selected >= endMinute.rounded(.down) else {
            return min(selected, endMinute)
        }
        return 0
    }

    static func minute(elapsedSeconds: TimeInterval) -> Int {
        guard elapsedSeconds.isFinite else { return 0 }
        let progress = min(max(elapsedSeconds / durationSeconds, 0), 1)
        return min(
            MapHomeTimeSidebarMath.fullDayMinutes,
            max(0, Int((progress * Double(MapHomeTimeSidebarMath.fullDayMinutes)).rounded(.down)))
        )
    }

    static func advancedMinute(
        from currentMinute: Double,
        elapsedSeconds: TimeInterval,
        normalizedMovingRanges: [MapHomePlaybackMovementRange]
    ) -> Double {
        guard elapsedSeconds.isFinite, elapsedSeconds > 0 else {
            return min(1_440, max(0, currentMinute))
        }
        let ranges = normalizedMovingRanges
        var minute = min(1_440, max(0, currentMinute))
        var remaining = elapsedSeconds
        while remaining > 0, minute < 1_440 {
            let active = ranges.filter {
                $0.startMinute <= minute && minute < $0.endMinute
            }
            let rate = active.isEmpty
                ? stationaryMinutesPerSecond
                : active.map { $0.minutesPerSecond }.min()
                    ?? movingMinutesPerSecond
            let nextBoundary = active.map(\.endMinute).min()
                ?? ranges.first { $0.startMinute > minute }?.startMinute
                ?? 1_440
            let minutesToBoundary = max(0, nextBoundary - minute)
            let secondsToBoundary = minutesToBoundary / rate
            if secondsToBoundary <= 0 {
                minute = min(1_440, minute + 0.000_001)
            } else if remaining < secondsToBoundary {
                minute += remaining * rate
                remaining = 0
            } else {
                minute = nextBoundary
                remaining -= secondsToBoundary
            }
        }
        return min(1_440, max(0, minute))
    }
}

enum MapHomeRouteOverlayCutoffPolicy {
    static func cutoff(
        selectedDayEnd: Date,
        timelineDate: Date,
        isPlaybackRunning: Bool
    ) -> Date {
        // Playback grows the displayed route up to the current playhead.  The
        // day end remains the hard upper bound for a malformed/future date.
        min(selectedDayEnd, timelineDate)
    }
}

struct MapHomePlaybackMovementRange: Hashable, Sendable {
    let startMinute: Double
    let endMinute: Double
    let mode: TravelMode?

    init(
        startMinute: Double,
        endMinute: Double,
        mode: TravelMode? = nil
    ) {
        self.startMinute = min(1_440, max(0, startMinute))
        self.endMinute = min(1_440, max(self.startMinute, endMinute))
        self.mode = mode
    }

    var minutesPerSecond: Double {
        switch mode {
        case .walking, .running, nil:
            return MapHomeDayPlaybackMath.movingMinutesPerSecond
        case .cycling, .bus, .subway, .taxi, .car, .train, .airplane, .ship:
            return MapHomeDayPlaybackMath.movingMinutesPerSecond
        }
    }

    static func normalized(
        _ ranges: [Self]
    ) -> [Self] {
        let ordered = ranges
            .filter { $0.startMinute < $0.endMinute }
            .sorted { $0.startMinute < $1.startMinute }
        var result: [Self] = []
        for range in ordered {
            guard let previous = result.last,
                  range.startMinute <= previous.endMinute,
                  range.mode == previous.mode else {
                result.append(range)
                continue
            }
            result[result.count - 1] = Self(
                startMinute: previous.startMinute,
                endMinute: max(previous.endMinute, range.endMinute),
                mode: previous.mode
            )
        }
        return result
    }
}

enum MapHomeWeatherTimelineMath {
    private struct DisplaySignature: Equatable {
        let symbolName: String
        let temperature: Int

        init(_ context: WeatherContext) {
            symbolName = context.symbolName
            temperature = Int(context.temperatureCelsius.rounded())
        }
    }

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
        var displayRuns: [(context: WeatherContext, start: Date)] = []

        for context in ordered {
            guard let lastIndex = displayRuns.indices.last else {
                displayRuns.append((context: context, start: context.observedAt))
                continue
            }
            if DisplaySignature(displayRuns[lastIndex].context)
                == DisplaySignature(context) {
                displayRuns[lastIndex].context = context
            } else {
                displayRuns.append((context: context, start: context.observedAt))
            }
        }

        return displayRuns.enumerated().compactMap { index, run in
            let nextObservedAt = index + 1 < displayRuns.count
                ? displayRuns[index + 1].start
                : dayEnd
            let start = max(run.start, dayStart)
            let end = min(
                max(nextObservedAt, run.start.addingTimeInterval(1)),
                dayEnd
            )
            guard start < end, start < dayEnd, end > dayStart else { return nil }
            return (context: run.context, span: TimeSpan(start: start, end: end))
        }
    }
}

enum MapHomeWeatherDisplayCache {
    static func merged(
        cached: [WeatherContext],
        incoming: [WeatherContext]
    ) -> [WeatherContext] {
        let fresh = incoming.filter(MapHomeWeatherDisplayPolicy.isComplete)
        guard !fresh.isEmpty else { return cached }
        return WeatherTimelineEngine.coalesced(
            cached + fresh
        )
    }

    static func contexts(
        incoming: [WeatherContext],
        cached: [WeatherContext]
    ) -> [WeatherContext] {
        let merged = merged(cached: cached, incoming: incoming)
        return merged.isEmpty ? incoming : merged
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

    static func keepsFollowing(
        after interaction: Interaction,
        duringPlayback: Bool
    ) -> Bool {
        duringPlayback || keepsFollowing(after: interaction)
    }

    static func isSingleFingerPanStart(
        state: UIGestureRecognizer.State,
        numberOfTouches: Int
    ) -> Bool {
        (state == .began || state == .changed) && numberOfTouches == 1
    }
}

enum MapHomePlaybackCameraPolicy {
    static func allowsAutomaticFit(
        isPlaybackRunning: Bool,
        hasUserAdjustedMap: Bool
    ) -> Bool {
        !isPlaybackRunning && !hasUserAdjustedMap
    }

    static func allowsInitialFocus(isPlaybackRunning: Bool) -> Bool {
        !isPlaybackRunning
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

enum MapHomeCurrentGPSPolicy {
    static func isConfirmed(in readings: [SensorReading]) -> Bool {
        let iPhoneReadings = readings.filter {
            $0.sourceDevice != .appleWatch
                && $0.gpsAvailable
                && $0.locationFixQuality != .approximate
        }
        return MapCurrentLocationAnchorPolicy.latestValidReading(
            in: iPhoneReadings
        ) != nil
    }
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

    static func clampedTimelineDate(
        selectedDate: Date,
        timelineDate: Date,
        now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        calendar.isDate(selectedDate, inSameDayAs: now)
            ? min(timelineDate, now)
            : timelineDate
    }
}

enum MapHomeRouteReadingsLoadState: Equatable {
    case idle
    case loading(Date)
    case loaded(Date)
    case failed(Date)

    func isLoaded(
        for date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Bool {
        guard case .loaded(let loadedDay) = self else { return false }
        return calendar.isDate(loadedDay, inSameDayAs: date)
    }

    func isResolved(
        for date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Bool {
        let resolvedDay: Date
        switch self {
        case .loaded(let day), .failed(let day):
            resolvedDay = day
        case .idle, .loading:
            return false
        }
        return calendar.isDate(resolvedDay, inSameDayAs: date)
    }
}

struct MapHomeRouteReadingsTaskKey: Hashable {
    let day: Date
    let isBootstrapped: Bool

    init(
        date: Date,
        isBootstrapped: Bool,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        day = calendar.startOfDay(for: date)
        self.isBootstrapped = isBootstrapped
    }
}

@MainActor
struct MapHomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable private var model: AppModel
    @Bindable private var proAccess: TaptionProAccessController
    private let onInitialDataReady: () -> Void

    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var mapCameraRevision = 0
    @State private var appleCenterCommand: MapHomeAppleCenterCommand?
    @State private var vectorMapViewportStore = MapHomeVectorViewportStore()
    @State private var isMenuOpen = false
    @State private var isCalendarPresented = false
    @State private var selectedLocationDestination: MapHomeLocationDestination?
    @State private var isTransitLocationsPresented = false
    @State private var isLocationMenuExpanded = false
    @State private var isUserLocationsMenuExpanded = false
    @State private var isCategoryMenuExpanded = false
    @State private var isCategoryAddPresented = false
    @State private var isDisplayMenuExpanded = false
    @State private var isStickerMenuExpanded = false
    @State private var isStickerMode = false
    @State private var selectedMapStickerEditor: MapHomeStickerEditorTarget?
    @State private var selectedMapTargetID: String?
    @State private var isAppleWatchMenuExpanded = false
    @State private var isSettingsMenuExpanded = false
    @State private var isGPSLoggingMenuExpanded = false
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
    @State private var hasAppliedInitialMapFocus = false
    @State private var hasCancelledInitialLocationFocus = false
    @State private var mapSearchText = ""
    @State private var mapSearchResults: [MapHomeSearchResult] = []
    @State private var selectedSearchPin: MapHomeSearchResult?
    @State private var isSearchPinMenuPresented = false
    @State private var selectedUserLocation: MapHomeUserLocationSelection?
    @State private var selectedTransitBoardingCandidate: TransitBoardingCandidate?
    @State private var pendingUserLocationSelection: MapHomeUserLocationSelection?
    @State private var mapSearchTask: Task<Void, Never>?
    @State private var transitPOIRefreshTask: Task<Void, Never>?
    @State private var nearbyTransitPlaces: [TransitBoardingPlace] = []
    @State private var transitBoardingReadingsRevision: UInt64 = 0
    @State private var nearbyTransitPlacesRevision: UInt64 = 0
    @State private var mapSearchCompleter = MapHomeSearchCompleter()
    @State private var mapSearchRequestID = UUID()
    @FocusState private var isMapSearchFocused: Bool
    @State private var visibleMapCenter = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    @State private var timeRailSegments: [MapHomeTimeRailSegment] = [
        .wholeDayUnconfirmed,
    ]
    @State private var routeProjection: RouteTimelineProjection?
    @State private var wbsPlaybackProjection: MapHomeWBSPlaybackProjection?
    @State private var hasDeferredWBSPlaybackRefresh = false
    @State private var routeReadings: [SensorReading] = []
    @State private var routeReadingsLoadState: MapHomeRouteReadingsLoadState = .idle
    @State private var hasReportedInitialDataReady = false
    @State private var normalizedRouteReadings: [SensorReading] = []
    @State private var historicalPlaybackReadings: [SensorReading] = []
    @State private var displayRouteReadings: [SensorReading] = []
    @State private var historicalPlaybackPoint: GeoPoint?
    @State private var timelineRouteOverlays: [MapHomeTimelineRouteOverlay] = []
    @State private var cachedTemporaryLocations: [SubwayStationCatalog.TemporaryLocation] = []
    @State private var expectedRouteOverlays: [MapHomeExpectedRouteOverlay] = []
    @State private var wbsGeneratedRouteOverlays: [MapHomeWBSGeneratedRouteOverlay] = []
    @State private var pendingForecastRouteState: MapHomeForecastRouteState?
    @State private var expectedRouteCache: [ExpectedRouteRequest: [CLLocationCoordinate2D]] = [:]
    @State private var expectedRouteRefreshTask: Task<Void, Never>?
    @State private var liveRouteProjectionRefreshTask: Task<Void, Never>?
    @State private var visibleMapSpan = MKCoordinateSpan(
        latitudeDelta: 0.025,
        longitudeDelta: 0.035
    )
    @State private var sharedZoomLevel: CGFloat = 1
    @State private var zoomResetToken = 0
    @State private var timeSidebarZoomStep = 0
    @State private var weatherVisibleStartMinute = 0
    @State private var weatherVisibleDurationMinutes = MapHomeTimeSidebarMath.fullDayMinutes
    @State private var timeSidebarVisibleStartMinute = 0
    @State private var timeSidebarVisibleDurationMinutes = MapHomeTimeSidebarMath.fullDayMinutes
    @State private var cachedWeatherContexts: [WeatherContext]
    @State private var sidebarPinchStepOffset = 0
    @State private var lastSidebarPinchRenderUptime: TimeInterval = 0
    @State private var activePaletteCategoryID: String?
    @State private var customPaletteColor = Color.tpReferenceMint
    @State private var mapCameraFrameProjection = MapHomeCameraFrameProjection()
    @State private var mapRenderCache = MapHomeMapRenderCache()
    @State private var visibleMapCamera: MapCamera?
    @State private var shouldFitRoutesAfterDateChange = false
    @State private var hasUserAdjustedMap = false
    @State private var stickmanViewportProjection = MapHomeStickmanViewportProjection()
    @State private var displayedStickmanViewportPoint: CGPoint?
    @State private var mapViewportSize = CGSize.zero
    @State private var headerFrame = CGRect.zero
    @State private var searchFieldFrame = CGRect.zero
    @State private var mapControlsFrame = CGRect.zero
    @State private var isDayPlaybackRunning = false
    @State private var dayPlaybackCurrentMinute: Double?
    @State private var isTimelineInteractionActive = false
    @State private var routeDocumentProjectionGate = MapHomeRouteDocumentProjectionGate()
    @State private var lastPlaybackRouteProjectionUptime: TimeInterval = 0
    @State private var lastPlaybackMapFocusUptime: TimeInterval = 0
    @State private var lastPlaybackMarkerUptime: TimeInterval = 0
    @State private var lastTimelineMapFocusUptime: TimeInterval = 0
    @State private var dayPlaybackElapsedSeconds: TimeInterval = 0
    @State private var dayPlaybackTask: Task<Void, Never>?
    @State private var mapDayCacheStore: TaptionPlanDayStore?

    private static let categoryPaletteHexes = [
        "#8FD9C5", "#A9CFF0", "#A7DDEB", "#C2B4E9",
        "#B8B7E8", "#F2B18D", "#F2A8B8", "#CBD5E1",
        "#F2D58D", "#F28FA9", "#B7DCC7", "#B7D5EE",
    ]

    private static let mapCacheAlgorithmKey = "route-document-v2"

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
        static let menuMinimumWidth: CGFloat = 260
        static let menuMaximumWidth: CGFloat = 300

        static func menuWidth(for viewportWidth: CGFloat) -> CGFloat {
            min(max(viewportWidth * 0.72, menuMinimumWidth), menuMaximumWidth)
        }
    }

    init(
        model: AppModel,
        proAccess: TaptionProAccessController,
        onInitialDataReady: @escaping () -> Void = {}
    ) {
        self._model = Bindable(model)
        self._proAccess = Bindable(proAccess)
        self.onInitialDataReady = onInitialDataReady
        _selectedScope = State(initialValue: .day)
        _timeRailSegments = State(
            initialValue: MapHomeTimeRailSegmentEngine.segments(
                from: model.snapshot.actuals,
                travel: model.snapshot.travel,
                on: model.selectedDate
            )
        )
        _cachedWeatherContexts = State(
            initialValue: WeatherTimelineEngine.coalesced(
                model.snapshot.weather.filter(MapHomeWeatherDisplayPolicy.isComplete)
            )
        )
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
            trailingControlCount: 1
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
            setMapPosition(.automatic)
            focusMapIfNeeded()
        }
        .presentationDetents([.height(440)])
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
            .presentationDetents([.height(540)])
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(
                .enabled(upThrough: .height(540))
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
                    dayPlaybackButton
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
        .sheet(item: $selectedMapStickerEditor) { target in
            MapHomeStickerEditorSheet(
                model: model,
                target: target,
                language: language
            )
        }
        .sheet(item: $selectedTransitBoardingCandidate) { candidate in
            MapHomeTransitBoardingCandidateSheet(
                model: model,
                candidate: candidate,
                language: language
            )
            .presentationDetents([.height(270)])
            .presentationDragIndicator(.visible)
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
        .onDisappear {
            currentLocationRequestTask?.cancel()
            currentLocationRequestTask = nil
            initialLocationRequestTask?.cancel()
            initialLocationRequestTask = nil
            mapSearchTask?.cancel()
            mapSearchTask = nil
            expectedRouteRefreshTask?.cancel()
            expectedRouteRefreshTask = nil
            liveRouteProjectionRefreshTask?.cancel()
            liveRouteProjectionRefreshTask = nil
            transitPOIRefreshTask?.cancel()
            transitPOIRefreshTask = nil
            mapSearchCompleter.clear()
            stopDayPlayback(resetProgress: true)
            headingMonitor.stop()
        }
        .task(
            id: MapHomeRouteReadingsTaskKey(
                date: model.selectedDate,
                isBootstrapped: model.isBootstrapped
            )
        ) {
            guard model.isBootstrapped else { return }
            let date = model.selectedDate
            let dayKey = MapHomeRouteReadingsPolicy.dayKey(for: date)
            if !routeReadingsLoadState.isLoaded(for: date) {
                routeReadingsLoadState = .loading(dayKey)
            }
            prepareRouteProjectionReadings()
            refreshRouteProjection()
            focusMapIfNeeded()
            refreshTimeRailSegments()
            await loadMapDayCache(for: date)
            applyInitialMapFocusIfNeeded()
            guard !Task.isCancelled,
                  Calendar.autoupdatingCurrent.isDate(
                      date,
                      inSameDayAs: model.selectedDate
                  ) else { return }
            refreshTimeRailSegments()
            reportInitialMapShellReadyIfNeeded(for: date)
            scheduleExpectedRouteRefresh()
            persistMapDayCache()
            await refreshRouteReadings(for: date)
            applyInitialMapFocusIfNeeded()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                } catch {
                    return
                }
                refreshTimeRailSegments()
                await refreshRouteReadings(for: date)
                applyInitialMapFocusIfNeeded()
            }
        }
        .onChange(of: model.latestSensorReading?.point) { _, _ in
            guard Calendar.autoupdatingCurrent.isDateInToday(
                model.selectedDate
            ) else { return }
            transitBoardingReadingsRevision &+= 1
            scheduleLiveRouteProjectionRefresh()
            scheduleTransitPOIRefresh()
        }
        .onChange(of: model.settings.frequentPlaces) { _, _ in
            focusMapIfNeeded()
            scheduleExpectedRouteRefresh()
        }
        .onChange(of: model.snapshot.weather) { _, weather in
            cachedWeatherContexts = MapHomeWeatherDisplayCache.merged(
                cached: cachedWeatherContexts,
                incoming: weather
            )
        }
        .onChange(of: model.settings.mapDisplayStyle) { _, _ in
            mapCameraRevision &+= 1
            persistMapDayCache()
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
                hasUserAdjustedMap = false
                routeReadings = []
                routeReadingsLoadState = .loading(
                    MapHomeRouteReadingsPolicy.dayKey(for: newDate)
                )
                normalizedRouteReadings = []
                historicalPlaybackReadings = []
                displayRouteReadings = []
                routeProjection = nil
                wbsPlaybackProjection = nil
                hasDeferredWBSPlaybackRefresh = false
                timelineRouteOverlays = []
                cachedTemporaryLocations = []
                expectedRouteOverlays = []
                wbsGeneratedRouteOverlays = []
                pendingForecastRouteState = nil
                historicalPlaybackPoint = nil
                nearbyTransitPlaces = []
                transitBoardingReadingsRevision &+= 1
                nearbyTransitPlacesRevision &+= 1
                prepareRouteProjectionReadings()
                refreshRouteProjection()
                refreshHistoricalPlaybackPoint()
            } else {
                prepareRouteProjectionReadings()
                refreshRouteProjection()
                refreshHistoricalPlaybackPoint()
            }

            let shouldFitRoutes = shouldFitRoutesAfterDateChange
            shouldFitRoutesAfterDateChange = false
            if shouldFitRoutes || dayChanged {
                setMapPosition(.automatic)
                focusMapIfNeeded()
            } else if calendar.isDateInToday(newDate),
                      currentCoordinate != nil {
                focusUserLocation()
            }
            refreshTimeRailSegments()
        }
        .onChange(of: model.snapshot.actuals) { _, _ in
            refreshTimeRailSegments()
            requestRouteProjectionRefresh()
        }
        .onChange(of: model.snapshot.travel) { _, _ in
            refreshTimeRailSegments()
            requestRouteProjectionRefresh(preparingReadings: true)
            scheduleExpectedRouteRefresh()
        }
        .onChange(of: model.snapshot.places) { _, _ in
            requestWBSPlaybackProjectionRefresh()
            scheduleExpectedRouteRefresh()
        }
        .onChange(of: model.backupRestoreRevision) { _, _ in
            Task {
                await refreshRouteReadings(for: model.selectedDate)
                scheduleExpectedRouteRefresh()
            }
        }
        .onChange(of: model.liveRouteState.readings.last?.id) { _, _ in
            transitBoardingReadingsRevision &+= 1
            scheduleLiveRouteProjectionRefresh()
            scheduleTransitPOIRefresh()
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
        if let style = currentVectorStyle {
            vectorMap(style: style)
        } else {
            mapKitMap
        }
    }

    private var currentVectorStyle: MapHomeVectorStyle? {
        model.settings.mapDisplayStyle.runtimeStyle.mapHomeVectorStyle
    }

    private var mapStickersOnMap: [MapSticker] {
        MapStickerDisplayFilterEngine.visibleMapStickers(
            model.snapshot.stickers,
            on: model.selectedDate
        ).filter { $0.point.map(isValid) == true }
    }

    private var scheduleStickersForSelectedDate: [MapSticker] {
        model.snapshot.stickers.filter {
            $0.placement == .schedule
                && Calendar.autoupdatingCurrent.isDate(
                    $0.occurredAt,
                    inSameDayAs: model.selectedDate
                )
        }
    }

    private var selectedSchedulePlanIDs: Set<UUID> {
        let selectedDate = timelineDate(forMinute: Double(effectiveTimelineMinute))
        return Set(
            model.snapshot.plans
                .filter { $0.span.start <= selectedDate && selectedDate < $0.span.end }
                .map(\.id)
        )
    }

    private var mapCenterPoint: GeoPoint? {
        let candidate = visibleMapCenter
        if candidate.latitude.isFinite,
           candidate.longitude.isFinite,
           (-90...90).contains(candidate.latitude),
           (-180...180).contains(candidate.longitude),
           candidate.latitude != 0 || candidate.longitude != 0 {
            return GeoPoint(
                latitude: candidate.latitude,
                longitude: candidate.longitude,
                altitude: 0,
                horizontalAccuracy: 0,
                verticalAccuracy: 0
            )
        }
        guard let currentCoordinate else { return nil }
        return GeoPoint(
            latitude: currentCoordinate.latitude,
            longitude: currentCoordinate.longitude,
            altitude: 0,
            horizontalAccuracy: 0,
            verticalAccuracy: 0
        )
    }

    private func addMapSticker() {
        guard let point = mapCenterPoint,
              let id = model.addMapSticker(
                  title: language.text("새 지도 메모", "New map memo"),
                  placement: .map,
                  point: point,
                  planID: nil,
                  occurredAt: timelineDate(forMinute: Double(effectiveTimelineMinute))
              ) else { return }
        isStickerMode = true
        isStickerMenuExpanded = false
        isMenuOpen = false
        selectedMapStickerEditor = .sticker(id)
    }

    private func addScheduleSticker() {
        let date = timelineDate(forMinute: Double(effectiveTimelineMinute))
        guard let id = model.addMapSticker(
            title: language.text("새 일정 메모", "New schedule memo"),
            placement: .schedule,
            point: nil,
            planID: selectedSchedulePlanIDs.first,
            occurredAt: date
        ) else { return }
        isStickerMode = true
        isStickerMenuExpanded = false
        isMenuOpen = false
        selectedMapStickerEditor = .sticker(id)
    }

    private var usesVectorRoadMap: Bool {
        currentVectorStyle != nil
    }

    private var vectorMapContentInsets: UIEdgeInsets {
        UIEdgeInsets(
            top: searchFieldFrame.maxY > 0
                ? searchFieldFrame.maxY
                : topOverlayHeight,
            left: 0,
            bottom: 0,
            right: isMenuOpen ? 0 : sidebarInteractionWidth
        )
    }

    private func vectorMap(style: MapHomeVectorStyle) -> some View {
        MapHomeVectorMap(
            style: style,
            cameraPosition: mapPosition,
            cameraRevision: mapCameraRevision,
            historicalRoutes: vectorHistoricalRoutes,
            activeRoute: vectorActiveRoute,
            expectedRoutes: vectorExpectedRoutes,
            subwayRoutes: vectorSubwayRoutes,
            markers: vectorMapMarkers,
            contentInsets: vectorMapContentInsets,
            followsHeading: isHeadingMode,
            headingDegrees: -compassRotationDegrees,
            displayedCoordinate: displayedLocationCoordinate,
            onViewportChange: applyVectorMapViewport,
            onSingleFingerPanBegan: handleUserMapPan,
            onSingleFingerPanEnded: finishDisplayedStickmanViewportProjection,
            onLongPress: presentLocationAddition
        )
        .id(style.rawValue)
        .overlay {
            MapHomeVectorViewportOverlay(store: vectorMapViewportStore) {
                viewport, stickmanPoint in
                vectorMapAnnotationOverlay(
                    style: style,
                    viewport: viewport,
                    stickmanPoint: stickmanPoint
                )
            }
        }
        .simultaneousGesture(
            SpatialTapGesture().onEnded { _ in
                dismissMapSearchOverlay()
            }
        )
        .task {
            applyInitialLocationIfAvailable(using: nil)
            beginInitialLocationRequest(using: nil)
        }
        .onChange(of: mapViewportSize) { _, size in
            guard size.width > 0, size.height > 0 else { return }
            applyInitialLocationIfAvailable(using: nil)
            beginInitialLocationRequest(using: nil)
        }
        .onChange(of: selectedTimelineMinute) { _, minute in
            if isTimelineInteractionActive || isDayPlaybackRunning {
                let interval = isDayPlaybackRunning
                    ? MapHomeDayPlaybackMath.mapFocusInterval
                    : TimelineInteractionFrameGate.minimumInterval
                let now = ProcessInfo.processInfo.systemUptime
                let shouldFocus: Bool
                if isDayPlaybackRunning {
                    shouldFocus = TimelineInteractionFrameGate.shouldRender(
                        lastUptime: &lastPlaybackMapFocusUptime,
                        nowUptime: now,
                        minimumInterval: interval
                    )
                } else {
                    shouldFocus = TimelineInteractionFrameGate.shouldRender(
                        lastUptime: &lastTimelineMapFocusUptime,
                        nowUptime: now,
                        minimumInterval: interval
                    )
                }
                guard shouldFocus else { return }
                let point = isDayPlaybackRunning
                    ? displayedPlaybackFocusPoint
                        ?? historicalPlaybackPoint
                        ?? refreshHistoricalPlaybackPoint()
                    : displayedPlaybackFocusPoint
                        ?? refreshHistoricalPlaybackPoint()
                guard let point else { return }
                focusMap(on: point, using: nil, followsTracking: true)
            } else {
                refreshSelectedTimelineMapPosition(minute: minute, using: nil)
            }
        }
        .onChange(of: isTimelineInteractionActive) { _, isInteracting in
            guard !isInteracting, !isDayPlaybackRunning,
                  selectedTimelineMinute != nil else { return }
            refreshSelectedTimelineMapPosition(
                minute: selectedTimelineMinute,
                using: nil
            )
            finishDisplayedStickmanViewportProjection()
        }
        .onChange(of: model.latestSensorReading?.id) { _, _ in
            applyInitialLocationIfAvailable(using: nil)
            guard userTrackingMode.keepsCameraLocked else { return }
            focusDisplayedLocation(using: nil)
        }
        .onChange(of: model.liveRouteState.readings.last?.id) { _, _ in
            guard userTrackingMode.keepsCameraLocked else { return }
            focusDisplayedLocation(using: nil)
        }
        .overlay(alignment: .bottomLeading) {
            if !isMenuOpen {
                mapControls(proxy: nil)
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


    private var mapKitMap: some View {
        MapHomeAppleMap(
            style: model.settings.mapDisplayStyle,
            cameraPosition: mapPosition,
            cameraRevision: mapCameraRevision,
            centerCommand: appleCenterCommand,
            routes: appleMapRoutes,
            annotations: appleMapAnnotations,
            playback: appleMapPlayback,
            centersPlayback: selectedTimelineMinute != nil
                || isTimelineInteractionActive
                || userTrackingMode.keepsCameraLocked,
            contentInsets: vectorMapContentInsets,
            onCameraFrame: { frame, locationPoint, isFinal in
                let now = ProcessInfo.processInfo.systemUptime
                if let rendered = mapCameraFrameProjection.submit(
                    frame,
                    nowUptime: now,
                    force: isFinal
                ) {
                    applyMapCameraFrame(rendered, locationPoint: locationPoint)
                }
                if let locationPoint {
                    submitDisplayedStickmanViewportPoint(locationPoint)
                }
                if isFinal {
                    finishDisplayedStickmanViewportProjection()
                }
            },
            onSingleFingerPanBegan: handleUserMapPan,
            onSingleFingerPanEnded: finishDisplayedStickmanViewportProjection,
            onLongPress: { coordinate in
                presentLocationAddition(at: coordinate)
            },
            onAnnotationSelected: handleAppleMapAnnotation
        )
        .simultaneousGesture(
            SpatialTapGesture().onEnded { _ in
                dismissMapSearchOverlay()
            }
        )
        .task {
            applyInitialLocationIfAvailable(using: nil)
            beginInitialLocationRequest(using: nil)
        }
        .onChange(of: mapViewportSize) { _, size in
            guard size.width > 0, size.height > 0 else { return }
            applyInitialLocationIfAvailable(using: nil)
            beginInitialLocationRequest(using: nil)
        }
        .onChange(of: headingMonitor.headingDegrees) { _, _ in
            applyMapHeading(using: nil)
        }
        .onChange(of: isTimelineInteractionActive) { _, isInteracting in
            guard !isInteracting else { return }
            flushDeferredWBSPlaybackProjection()
            finishDisplayedStickmanViewportProjection()
        }
        .onChange(of: model.latestSensorReading?.id) { _, _ in
            applyInitialLocationIfAvailable(using: nil)
            guard userTrackingMode.keepsCameraLocked else { return }
            focusDisplayedLocation(using: nil)
        }
        .onChange(of: model.liveRouteState.readings.last?.id) { _, _ in
            guard userTrackingMode.keepsCameraLocked else { return }
            focusDisplayedLocation(using: nil)
        }
        .overlay(alignment: .bottomLeading) {
            if !isMenuOpen {
                mapControls(proxy: nil)
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

    private var vectorHistoricalRoutes: [MapHomeVectorRoute] {
        timelineRouteOverlays.dropLast().map { overlay in
            MapHomeVectorRoute(
                id: overlay.id,
                coordinates: overlay.coordinates,
                colorHex: MapHomeWBSTripStyle.actualRouteHex,
                opacity: MapHomeWBSTripStyle.actualRouteOpacity
            )
        }
    }

    private var appleMapRoutes: [MapHomeAppleRoute] {
        var routes = timelineRouteOverlays.map { overlay in
            MapHomeAppleRoute(
                id: "timeline-\(overlay.id)",
                coordinates: overlay.coordinates,
                colorHex: MapHomeWBSTripStyle.actualRouteHex,
                opacity: MapHomeWBSTripStyle.actualRouteOpacity,
                phase: .actual,
                transport: nil
            )
        }

        routes += subwayRouteOverlays.compactMap { overlay in
            guard !overlay.estimated, overlay.coordinates.count >= 2 else { return nil }
            return MapHomeAppleRoute(
                id: "subway-\(overlay.id.uuidString)",
                coordinates: overlay.coordinates,
                colorHex: MapHomeWBSTripStyle.actualRouteHex,
                opacity: MapHomeWBSTripStyle.actualRouteOpacity,
                phase: .actual,
                transport: .transit
            )
        }

        routes += visibleExpectedRouteOverlays.map { overlay in
            MapHomeAppleRoute(
                id: "expected-\(overlay.id.uuidString)",
                coordinates: overlay.coordinates,
                colorHex: MapHomeWBSTripStyle.forecastRouteHex,
                opacity: MapHomeWBSTripStyle.forecastRouteOpacity,
                phase: .forecast,
                transport: MapHomeAppleRouteTransport(mode: overlay.mode)
            )
        }
        routes += visibleWBSGeneratedRouteOverlays.map { overlay in
            MapHomeAppleRoute(
                id: "wbs-\(overlay.id)",
                coordinates: overlay.coordinates,
                colorHex: MapHomeWBSTripStyle.forecastRouteHex,
                opacity: MapHomeWBSTripStyle.forecastRouteOpacity,
                phase: .forecast,
                transport: overlay.mode.map { MapHomeAppleRouteTransport(mode: $0) }
            )
        }
        return routes.filter { $0.coordinates.count >= 2 }
    }

    private var appleMapAnnotations: [MapHomeAppleAnnotation] {
        var annotations = temporaryLocationAnnotations.map { location in
            MapHomeAppleAnnotation(
                id: "temporary-\(location.id.uuidString)",
                coordinate: location.coordinate,
                kind: .temporary(
                    stationName: location.stationName,
                    accessibilityLabel: language.text(
                        "\(location.stationName) 지하철 임시 위치",
                        "\(location.stationName) temporary subway location"
                    )
                ),
                isInteractive: false
            )
        }
        annotations += placeAnnotations.map { place in
            MapHomeAppleAnnotation(
                id: "place-\(place.id.uuidString)",
                coordinate: place.coordinate,
                kind: .place(place),
                isInteractive: place.destination == .user
            )
        }
        annotations += transitAnnotations.map { place in
            MapHomeAppleAnnotation(
                id: "transit-\(place.id.uuidString)",
                coordinate: place.coordinate,
                kind: .transit(place),
                isInteractive: true
            )
        }
        annotations += transitBoardingCandidates.map { candidate in
            MapHomeAppleAnnotation(
                id: "boarding-\(candidate.id)",
                coordinate: CLLocationCoordinate2D(
                    latitude: candidate.point.latitude,
                    longitude: candidate.point.longitude
                ),
                kind: .boarding(candidate),
                isInteractive: true
            )
        }
        annotations += mapStickersOnMap.compactMap { sticker in
            guard let point = sticker.point else { return nil }
            return MapHomeAppleAnnotation(
                id: "sticker-\(sticker.id.uuidString)",
                coordinate: CLLocationCoordinate2D(
                    latitude: point.latitude,
                    longitude: point.longitude
                ),
                kind: .sticker(sticker),
                isInteractive: isStickerMode
            )
        }
        if let selectedSearchPin {
            annotations.append(
                MapHomeAppleAnnotation(
                    id: "search-pin",
                    coordinate: selectedSearchPin.coordinate,
                    kind: .search(selectedSearchPin),
                    isInteractive: true
                )
            )
        }
        return annotations
    }

    private var appleMapPlayback: MapHomeApplePlayback? {
        guard let coordinate = displayedLocationCoordinate else { return nil }
        let heading: CLLocationDirection
        let phase: MapHomeAppleRoutePhase
        let animationPhase: Int?
        let cameraCoordinate: CLLocationCoordinate2D
        if let frame = wbsPlaybackFrame {
            heading = CLLocationDirection(frame.direction.rawValue * 45)
            phase = frame.routePhase == .actual ? .actual : .forecast
            animationPhase = frame.stickmanFrameIndex
            cameraCoordinate = CLLocationCoordinate2D(
                latitude: frame.cameraCoordinate.latitude,
                longitude: frame.cameraCoordinate.longitude
            )
        } else if let route = activeExpectedRoute {
            heading = MapHomeApplePlaybackMath.heading(
                at: displayedLocationDate,
                departureDate: route.departureDate,
                arrivalDate: route.arrivalDate,
                coordinates: route.coordinates
            )
            phase = .forecast
            animationPhase = MapHomeExpectedRoutePlaybackMath.progress(
                at: displayedLocationDate,
                departureDate: route.departureDate,
                arrivalDate: route.arrivalDate
            ).map(MapHomeStickmanAnimationEngine.phase(for:))
            cameraCoordinate = coordinate
        } else {
            heading = MapHomeApplePlaybackMath.stableHeading(
                MapHomeApplePlaybackMath.heading(
                    at: displayedLocationDate,
                    readings: historicalPlaybackReadings
                ) ?? model.latestSensorReading?.courseDegrees
                    ?? headingMonitor.headingDegrees
                    ?? 0
            )
            phase = .actual
            animationPhase = routeProjection.flatMap {
                MapHomeRouteTimelinePlaybackMath.progress(
                    at: displayedLocationDate,
                    in: $0.segments
                )
            }.map(MapHomeStickmanAnimationEngine.phase(for:))
            cameraCoordinate = coordinate
        }
        return MapHomeApplePlayback(
            coordinate: coordinate,
            cameraCoordinate: cameraCoordinate,
            headingDegrees: heading,
            action: displayedStickmanAction,
            accessibilityLabel: "\(displayedLocationAccessibilityLabel) · \(displayedStickmanAction.title)",
            phase: phase,
            stickmanAnimationPhase: selectedTimelineMinute == nil
                ? nil
                : animationPhase
        )
    }

    private func handleAppleMapAnnotation(_ kind: MapHomeAppleAnnotationKind) {
        switch kind {
        case .temporary:
            break
        case .place(let place):
            guard place.destination == .user else { return }
            selectedMapTargetID = "place.\(place.id.uuidString)"
            selectedUserLocation = .frequentPlace(place.id)
        case .transit(let place):
            selectedMapTargetID = "transit.\(place.id.uuidString)"
            selectedUserLocation = .transit(place.id)
        case .boarding(let candidate):
            selectedTransitBoardingCandidate = candidate
        case .sticker(let sticker):
            guard isStickerMode else { return }
            selectedMapStickerEditor = .sticker(sticker.id)
        case .search:
            isSearchPinMenuPresented = true
        }
    }

    private var vectorActiveRoute: MapHomeVectorRoute? {
        guard let overlay = timelineRouteOverlays.last else { return nil }
        return MapHomeVectorRoute(
            id: "active-\(overlay.id)",
            coordinates: overlay.coordinates,
            colorHex: MapHomeWBSTripStyle.actualRouteHex,
            opacity: MapHomeWBSTripStyle.actualRouteOpacity
        )
    }

    private var vectorExpectedRoutes: [MapHomeVectorRoute] {
        let expected = visibleExpectedRouteOverlays.map { overlay in
            MapHomeVectorRoute(
                id: "expected-\(overlay.id.uuidString)",
                coordinates: overlay.coordinates,
                colorHex: MapHomeWBSTripStyle.forecastRouteHex,
                opacity: MapHomeWBSTripStyle.forecastRouteOpacity
            )
        }
        let generated = visibleWBSGeneratedRouteOverlays.map { overlay in
            MapHomeVectorRoute(
                id: "wbs-\(overlay.id)",
                coordinates: overlay.coordinates,
                colorHex: MapHomeWBSTripStyle.forecastRouteHex,
                opacity: MapHomeWBSTripStyle.forecastRouteOpacity
            )
        }
        return expected + generated
    }

    private var vectorSubwayRoutes: [MapHomeVectorRoute] {
        subwayRouteOverlays.compactMap { overlay in
            guard !overlay.estimated else { return nil }
            return MapHomeVectorRoute(
                id: "subway-\(overlay.id)",
                coordinates: overlay.coordinates,
                colorHex: MapHomeWBSTripStyle.actualRouteHex,
                opacity: MapHomeWBSTripStyle.actualRouteOpacity
            )
        }
    }

    private var vectorMapMarkers: [MapHomeVectorMarker] {
        var markers = temporaryLocationAnnotations.map {
            MapHomeVectorMarker(
                id: vectorTemporaryMarkerID($0.id),
                coordinate: $0.coordinate
            )
        }
        markers += placeAnnotations.map {
            MapHomeVectorMarker(
                id: vectorPlaceMarkerID($0.id),
                coordinate: $0.coordinate
            )
        }
        markers += transitAnnotations.map {
            MapHomeVectorMarker(
                id: vectorTransitMarkerID($0.id),
                coordinate: $0.coordinate
            )
        }
        markers += transitBoardingCandidates.map {
            MapHomeVectorMarker(
                id: vectorBoardingCandidateMarkerID($0.id),
                coordinate: CLLocationCoordinate2D(
                    latitude: $0.point.latitude,
                    longitude: $0.point.longitude
                )
            )
        }
        markers += mapStickersOnMap.compactMap { sticker in
            guard let point = sticker.point else { return nil }
            return MapHomeVectorMarker(
                id: vectorMapStickerMarkerID(sticker.id),
                coordinate: CLLocationCoordinate2D(
                    latitude: point.latitude,
                    longitude: point.longitude
                )
            )
        }
        if let displayedLocationCoordinate {
            markers.append(
                MapHomeVectorMarker(
                    id: vectorDisplayedMarkerID,
                    coordinate: displayedLocationCoordinate
                )
            )
        }
        if let selectedSearchPin {
            markers.append(
                MapHomeVectorMarker(
                    id: vectorSearchMarkerID,
                    coordinate: selectedSearchPin.coordinate
                )
            )
        }
        return markers
    }

    private var vectorPlayerHeading: CLLocationDirection {
        appleMapPlayback?.headingDegrees ?? 0
    }

    private func vectorMapAnnotationOverlay(
        style: MapHomeVectorStyle,
        viewport: MapHomeVectorViewport?,
        stickmanPoint: CGPoint?
    ) -> some View {
        ZStack {
            ForEach(temporaryLocationAnnotations) { location in
                if let point = vectorPoint(
                    in: viewport,
                    for: vectorTemporaryMarkerID(location.id)
                ) {
                    MapHomeProjectedAnnotation(point: point, anchor: .center) {
                        VStack(spacing: 2) {
                            Image(systemName: "tram.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.tpReferenceBlue.opacity(0.72))
                            Text(language.text("임시 위치", "Temporary"))
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.tpInk.opacity(0.72))
                        }
                        .padding(5)
                        .background(Color.tpSurface.opacity(0.66), in: Capsule())
                        .overlay {
                            Capsule().stroke(
                                Color.tpReferenceBlue.opacity(0.45),
                                style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                            )
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            language.text(
                                "\(location.stationName) 지하철 임시 위치",
                                "\(location.stationName) temporary subway location"
                            )
                        )
                    }
                }
            }

            ForEach(placeAnnotations) { place in
                if let point = vectorPoint(
                    in: viewport,
                    for: vectorPlaceMarkerID(place.id)
                ) {
                    MapHomeProjectedAnnotation(point: point, anchor: .bottom) {
                        if place.destination == .user {
                            Button {
                                selectedMapTargetID = "place.\(place.id.uuidString)"
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
                            .allowsHitTesting(false)
                        }
                    }
                }
            }

            ForEach(transitAnnotations) { place in
                if let point = vectorPoint(
                    in: viewport,
                    for: vectorTransitMarkerID(place.id)
                ) {
                    MapHomeProjectedAnnotation(point: point, anchor: .bottom) {
                    Button {
                        selectedMapTargetID = "transit.\(place.id.uuidString)"
                        selectedUserLocation = .transit(place.id)
                        } label: {
                            MapHomeTransitPlacePin(name: place.name, kind: place.kind)
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
            }

            ForEach(transitBoardingCandidates) { candidate in
                if let point = vectorPoint(
                    in: viewport,
                    for: vectorBoardingCandidateMarkerID(candidate.id)
                ) {
                    MapHomeProjectedAnnotation(point: point, anchor: .bottom) {
                        Button {
                            selectedTransitBoardingCandidate = candidate
                        } label: {
                            MapHomeTransitBoardingCandidatePin(
                                name: candidate.name,
                                kind: candidate.kind
                            )
                            .fixedSize()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            language.text(
                                "\(candidate.name) \(candidate.kind.title) 탑승 확인",
                                "Confirm boarding at \(candidate.name) \(candidate.kind.englishTitle)"
                            )
                        )
                    }
                }
            }

            ForEach(mapStickersOnMap) { sticker in
                if let point = vectorPoint(
                    in: viewport,
                    for: vectorMapStickerMarkerID(sticker.id)
                ) {
                    MapHomeProjectedAnnotation(point: point, anchor: .bottom) {
                        Button {
                            selectedMapStickerEditor = .sticker(sticker.id)
                        } label: {
                            MapHomeMapStickerMarker(sticker: sticker)
                        }
                        .buttonStyle(.plain)
                        .allowsHitTesting(isStickerMode)
                        .accessibilityLabel(
                            language.text(
                                "\(sticker.title) 메모 스티커",
                                "\(sticker.title) memo sticker"
                            )
                        )
                    }
                }
            }

            if selectedTimelineMinute != nil,
               let point = vectorPoint(in: viewport, for: vectorDisplayedMarkerID) {
                MapHomeVectorPlayerMarker(
                    heading: vectorPlayerHeading,
                    backgroundHex: style.backgroundHex
                )
                    .position(x: point.x, y: point.y + 11)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            if displayedLocationCoordinate != nil,
               let point = stickmanPoint {
                MapHomeStickmanMarker(
                    action: displayedStickmanAction,
                    animationPhase: appleMapPlayback?.stickmanAnimationPhase,
                    routePhase: appleMapPlayback?.phase == .forecast
                        ? .forecast
                        : .actual
                )
                    .position(
                        x: point.x,
                        y: point.y - MapHomeStickmanMarker.size.height / 2
                    )
                    .zIndex(MapHomeLayerPriority.stickman)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        "\(displayedLocationAccessibilityLabel) · \(displayedStickmanAction.title)"
                    )
            }

            if let selectedSearchPin,
               let point = vectorPoint(in: viewport, for: vectorSearchMarkerID) {
                MapHomeProjectedAnnotation(point: point, anchor: .bottom) {
                    Button {
                        isSearchPinMenuPresented = true
                    } label: {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 36, weight: .bold))
                            .foregroundStyle(Color.tpPastelRose)
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
        }
        .clipped()
    }

    private var vectorDisplayedMarkerID: String { "displayed-location" }
    private var vectorSearchMarkerID: String { "search-location" }

    private func vectorTemporaryMarkerID(_ id: UUID) -> String {
        "temporary-\(id.uuidString)"
    }

    private func vectorPlaceMarkerID(_ id: UUID) -> String {
        "place-\(id.uuidString)"
    }

    private func vectorTransitMarkerID(_ id: UUID) -> String {
        "transit-\(id.uuidString)"
    }

    private func vectorMapStickerMarkerID(_ id: UUID) -> String {
        "map-sticker-\(id.uuidString)"
    }

    private func vectorMapMemoMarkerID(_ id: UUID) -> String {
        "map-memo-\(id.uuidString)"
    }

    private func vectorBoardingCandidateMarkerID(_ id: String) -> String {
        "boarding-candidate-\(id)"
    }

    private func vectorPoint(
        in viewport: MapHomeVectorViewport?,
        for id: String
    ) -> CGPoint? {
        viewport?.markerPoints[id]
    }

    private func applyVectorMapViewport(
        _ viewport: MapHomeVectorViewport,
        isFinal: Bool
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        vectorMapViewportStore.update(viewport)
        let displayedPoint = viewport.markerPoints[vectorDisplayedMarkerID]
        if let displayedPoint {
            vectorMapViewportStore.updateStickmanPoint(
                displayedPoint,
                nowUptime: now
            )
        }
        let frame = MapHomeCameraFrame(
            camera: viewport.camera,
            region: viewport.region
        )
        _ = mapCameraFrameProjection.submit(
            frame,
            nowUptime: now,
            force: isFinal
        )
        if vectorMapViewportStore.shouldPublishParentReadback(
            nowUptime: now,
            isFinal: isFinal
        ), let latestFrame = mapCameraFrameProjection.latestFrame {
            applyMapCameraFrame(latestFrame, locationPoint: displayedPoint)
        }
        if isFinal {
            vectorMapViewportStore.finishStickmanPoint(nowUptime: now)
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
                .foregroundStyle(Color.tpInk)
                .frame(
                    width: MapHomeSearchLayoutMath.playbackVisualSize,
                    height: MapHomeSearchLayoutMath.playbackVisualSize
                )
                .background(Color.white.opacity(0.96), in: Circle())
                .overlay {
                    Circle().stroke(Color.tpPastelGray.opacity(0.65), lineWidth: 1)
                }
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

    private func mapStyleTitle(_ style: MapDisplayStyle) -> String {
        switch style {
        case .standard: language.text("표준", "Standard")
        case .simplified: language.text("간략화", "Simplified")
        case .hybrid: language.text("하이브리드", "Hybrid")
        case .imagery: language.text("위성", "Satellite")
        case .mapLibreNight: language.text("벡터 야간", "Vector Night")
        case .mapLibreLight: language.text("벡터 밝은 지도", "Vector Light")
        case .mapLibreContrast: language.text("벡터 고대비", "Vector Contrast")
        case .mapLibrePastel: language.text("벡터 파스텔", "Vector Pastel")
        case .mapLibreCasual: language.text("벡터 캐주얼", "Vector Casual")
        }
    }

    private func mapStyleSystemImage(_ style: MapDisplayStyle) -> String {
        switch style {
        case .standard: "map"
        case .simplified: "map.fill"
        case .hybrid: "square.3.layers.3d"
        case .imagery: "globe.asia.australia.fill"
        case .mapLibreNight: "moon.stars.fill"
        case .mapLibreLight: "sun.max.fill"
        case .mapLibreContrast: "circle.lefthalf.filled"
        case .mapLibrePastel: "paintpalette.fill"
        case .mapLibreCasual: "sparkles"
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
        if (selectedTimelineMinute ?? 0) >= MapHomeTimeSidebarMath.fullDayMinutes {
            dayPlaybackElapsedSeconds = 0
            selectedTimelineMinute = 0
        }
        let currentDate = Date.now
        let playbackEndMinute = MapHomeDayPlaybackMath.playbackEndMinute(
            for: model.selectedDate,
            now: currentDate
        )
        let currentMinute = MapHomeDayPlaybackMath.playbackStartMinute(
            selectedMinute: selectedTimelineMinute,
            endMinute: playbackEndMinute,
            isToday: Calendar.autoupdatingCurrent.isDate(
                model.selectedDate,
                inSameDayAs: currentDate
            )
        )
        var playbackMinute = currentMinute
        if currentMinute == 0 {
            dayPlaybackElapsedSeconds = 0
        }
        dayPlaybackCurrentMinute = currentMinute
        let movingRanges = dayPlaybackMovementRanges
        if currentMinute == 0 {
            selectedTimelineMinute = 0
        }
        isTimelineSelectionPinned = true
        isTimelineInteractionActive = true
        isDayPlaybackRunning = true
        lastPlaybackRouteProjectionUptime = 0
        lastPlaybackMapFocusUptime = 0
        lastPlaybackMarkerUptime = 0
        mapRenderCache.invalidateRouteData()
        routeProjection = nil
        timelineRouteOverlays = []
        prepareRouteProjectionReadings()
        hasDeferredWBSPlaybackRefresh = false
        refreshWBSPlaybackProjection()
        refreshRouteProjection()
        refreshHistoricalPlaybackPoint()
        lastPlaybackRouteProjectionUptime = ProcessInfo.processInfo.systemUptime
        var lastUptime = ProcessInfo.processInfo.systemUptime
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
                let uptime = ProcessInfo.processInfo.systemUptime
                let elapsed = min(
                    max(0, uptime - lastUptime),
                    0.1
                )
                lastUptime = uptime
                playbackMinute = min(
                    MapHomeDayPlaybackMath.advancedMinute(
                        from: playbackMinute,
                        elapsedSeconds: elapsed,
                        normalizedMovingRanges: movingRanges
                    ),
                    playbackEndMinute
                )
                dayPlaybackElapsedSeconds += elapsed
                let minute = min(
                    MapHomeTimeSidebarMath.fullDayMinutes,
                    max(0, Int(playbackMinute.rounded(.down)))
                )
                if selectedTimelineMinute != minute {
                    selectedTimelineMinute = minute
                }
                if TimelineInteractionFrameGate.shouldRender(
                    lastUptime: &lastPlaybackMarkerUptime,
                    nowUptime: uptime,
                    minimumInterval: MapHomeDayPlaybackMath.mapFocusInterval
                ) {
                    dayPlaybackCurrentMinute = playbackMinute
                    if wbsPlaybackProjection?.legs.isEmpty != false {
                        refreshHistoricalPlaybackPoint()
                    }
                }
                if TimelineInteractionFrameGate.shouldRender(
                    lastUptime: &lastPlaybackRouteProjectionUptime,
                    nowUptime: uptime,
                    minimumInterval: MapHomeDayPlaybackMath
                        .routeProjectionInterval
                ) {
                    refreshRouteProjection()
                }
                guard playbackMinute < playbackEndMinute else {
                    selectedTimelineMinute = playbackEndMinute
                        >= Double(MapHomeTimeSidebarMath.fullDayMinutes)
                        ? MapHomeTimeSidebarMath.fullDayMinutes
                        : min(
                            MapHomeTimeSidebarMath.fullDayMinutes - 1,
                            max(0, Int(playbackEndMinute.rounded(.down)))
                        )
                    isDayPlaybackRunning = false
                    isTimelineInteractionActive = false
                    historicalPlaybackPoint = nil
                    dayPlaybackCurrentMinute = nil
                    _ = flushDeferredRouteProjection()
                        ?? refreshRouteProjection()
                    flushDeferredWBSPlaybackProjection()
                    refreshHistoricalPlaybackPoint()
                    dayPlaybackTask = nil
                    lastPlaybackRouteProjectionUptime = 0
                    lastPlaybackMapFocusUptime = 0
                    lastPlaybackMarkerUptime = 0
                    return
                }
            }
        }
    }

    private var dayPlaybackMovementRanges: [MapHomePlaybackMovementRange] {
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: model.selectedDate)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(24 * 60 * 60)
        let readingRanges = dayPlaybackReadingRanges(
            from: routeReadings + model.liveRouteState.readings,
            dayStart: dayStart,
            dayEnd: dayEnd
        )
        let travelRanges = model.snapshot.travel.compactMap {
            segment -> MapHomePlaybackMovementRange? in
            guard segment.distanceMeters > 0
                    || segment.mode == .subway
                        && ((segment.subwayRoute?.coordinates.count ?? 0) >= 2),
                  segment.isConfirmed || !segment.evidence.isEmpty
            else { return nil }
            return MapHomePlaybackMovementRange(
                startMinute: segment.span.start.timeIntervalSince(dayStart) / 60,
                endMinute: segment.span.end.timeIntervalSince(dayStart) / 60,
                mode: segment.mode
            )
        }
        return MapHomePlaybackMovementRange.normalized(
            readingRanges + travelRanges
        )
    }

    private func dayPlaybackReadingRanges(
        from readings: [SensorReading],
        dayStart: Date,
        dayEnd: Date
    ) -> [MapHomePlaybackMovementRange] {
        let ordered = readings
            .filter {
                $0.timestamp >= dayStart
                    && $0.timestamp < dayEnd
                    && $0.point != nil
                    && $0.motion.isMovement
            }
            .sorted { $0.timestamp < $1.timestamp }
        guard let first = ordered.first else { return [] }

        var result: [MapHomePlaybackMovementRange] = []
        var start = first.timestamp
        var previous = first.timestamp
        var mode = playbackMode(for: first)
        for reading in ordered.dropFirst() {
            let nextMode = playbackMode(for: reading)
            if reading.timestamp.timeIntervalSince(previous) > 15 * 60
                || nextMode != mode {
                result.append(
                    MapHomePlaybackMovementRange(
                        startMinute: start.timeIntervalSince(dayStart) / 60,
                        endMinute: previous.timeIntervalSince(dayStart) / 60,
                        mode: mode
                    )
                )
                start = reading.timestamp
                mode = nextMode
            }
            previous = reading.timestamp
        }
        result.append(
            MapHomePlaybackMovementRange(
                startMinute: start.timeIntervalSince(dayStart) / 60,
                endMinute: previous.timeIntervalSince(dayStart) / 60,
                mode: mode
            )
        )
        return result
    }

    private func playbackMode(for reading: SensorReading) -> TravelMode? {
        if reading.matchesRailRoute
            || (reading.subwayWiFiObservationStreak ?? 0) > 0 {
            return .subway
        }
        if reading.matchesPublicTransitRoute {
            return .bus
        }
        if reading.onWater {
            return .ship
        }
        switch reading.motion {
        case .walking: return .walking
        case .running: return .running
        case .cycling: return .cycling
        case .automotive: return .car
        case .stationary, .unknown: return nil
        }
    }

    private func stopDayPlayback(resetProgress: Bool) {
        let wasRunning = isDayPlaybackRunning
        if wasRunning, !resetProgress, let currentMinute = dayPlaybackCurrentMinute {
            selectedTimelineMinute = min(
                MapHomeTimeSidebarMath.fullDayMinutes,
                max(0, Int(currentMinute.rounded(.down)))
            )
        }
        dayPlaybackTask?.cancel()
        dayPlaybackTask = nil
        isDayPlaybackRunning = false
        dayPlaybackCurrentMinute = nil
        historicalPlaybackPoint = nil
        lastPlaybackRouteProjectionUptime = 0
        lastPlaybackMapFocusUptime = 0
        lastPlaybackMarkerUptime = 0
        lastTimelineMapFocusUptime = 0
        if resetProgress {
            dayPlaybackElapsedSeconds = 0
        }
        if wasRunning {
            isTimelineInteractionActive = false
            _ = flushDeferredRouteProjection()
                ?? refreshRouteProjection()
            flushDeferredWBSPlaybackProjection()
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
                let timeSidebarInteractionWidth =
                    MapHomeTimeSidebarMath.interactionWidth(
                        railWidth: Layout.timeRailWidth,
                        trailingInteractionWidth: Layout.horizontalInset
                    )
                let weatherOriginX = MapHomeWeatherRailAlignmentMath.weatherOriginX(
                    weatherRailWidth: Layout.weatherRailWidth,
                    timeRailWidth: Layout.timeRailWidth
                )
                ZStack(alignment: .topLeading) {
                    if model.settings.weatherSidebarVisible {
                        MapHomeWeatherSidebar(
                            date: model.selectedDate,
                            contexts: MapHomeWeatherDisplayCache.contexts(
                                incoming: model.snapshot.weather,
                                cached: cachedWeatherContexts
                            ),
                            selectedMinute: minute,
                            language: language,
                            visibleStartMinute: weatherVisibleStartMinute,
                            visibleDurationMinutes: weatherVisibleDurationMinutes
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
                        zoomResetToken: zoomResetToken,
                        zoomStepToken: timeSidebarZoomStep,
                        railWidth: Layout.timeRailWidth,
                        maximumSelectableMinute: dayPlaybackElapsedSeconds > 0
                            ? MapHomeTimeSidebarMath.fullDayMinutes
                            : nil,
                        trailingInteractionWidth: Layout.horizontalInset,
                        onViewportChanged: { start, duration in
                            weatherVisibleStartMinute = start
                            weatherVisibleDurationMinutes = duration
                            timeSidebarVisibleStartMinute = start
                            timeSidebarVisibleDurationMinutes = duration
                        },
                        onInteractionChanged: { isInteracting in
                            if isInteracting, isDayPlaybackRunning {
                                stopDayPlayback(resetProgress: true)
                            }
                            isTimelineInteractionActive = isInteracting
                            if !isInteracting {
                                flushDeferredWBSPlaybackProjection()
                            }
                        },
                        onSectionEdit: { selectedMinute in
                            openSectionEditor(at: selectedMinute)
                        }
                    )

                    ForEach(scheduleStickersForSelectedDate) { sticker in
                        let window = MapHomeTimeSidebarMath.visibleWindow(
                            startMinute: timeSidebarVisibleStartMinute,
                            durationMinutes: timeSidebarVisibleDurationMinutes,
                            centerMinute: effectiveTimelineMinute
                        )
                        let minute = minuteOfDay(for: sticker.occurredAt)
                        let trackHeight = max(1, railHeight - 28)
                        let y = 14 + trackHeight * MapHomeTimeSidebarMath.position(
                            minute: minute,
                            window: window
                        )
                        Button {
                            selectedMapStickerEditor = .sticker(sticker.id)
                        } label: {
                            Image(systemName: sticker.systemImage)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color(hex: sticker.colorHex))
                                .frame(width: 22, height: 22)
                                .background(Color.white.opacity(0.96), in: Circle())
                                .overlay(Circle().stroke(Color(hex: sticker.colorHex), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .allowsHitTesting(isStickerMode)
                        .accessibilityLabel(
                            language.text(
                                "\(sticker.title) 일정 메모",
                                "\(sticker.title) schedule memo"
                            )
                        )
                        .position(
                            x: MapHomeTimeSidebarMath.handleLaneWidth + 8,
                            y: min(max(y, 14), railHeight - 14)
                        )
                    }
                }
                .frame(
                    width: timeSidebarInteractionWidth,
                    height: railHeight
                )
                .position(
                    x: proxy.size.width - timeSidebarInteractionWidth / 2,
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
                            guard TimelineInteractionFrameGate.shouldRender(
                                lastUptime: &lastSidebarPinchRenderUptime,
                                nowUptime: ProcessInfo.processInfo.systemUptime
                            ) else { return }
                            timeSidebarZoomStep += offset - sidebarPinchStepOffset
                            sidebarPinchStepOffset = offset
                        }
                        .onEnded { scale in
                            let offset = MapHomeTimeSidebarPinchMath.stepOffset(
                                magnification: scale
                            )
                            if offset != sidebarPinchStepOffset {
                                timeSidebarZoomStep += offset - sidebarPinchStepOffset
                            }
                            sidebarPinchStepOffset = 0
                            lastSidebarPinchRenderUptime = 0
                        }
                )
            }
        }
        .frame(
            width: MapHomeTimeSidebarMath.interactionWidth(
                railWidth: Layout.timeRailWidth,
                trailingInteractionWidth: Layout.horizontalInset
            )
        )
        .frame(maxHeight: .infinity, alignment: .trailing)
    }

    private func mapControls(proxy: MapProxy?) -> some View {
        VStack(spacing: Layout.mapControlSpacing) {
            Button {
                requestAndFollowUserLocation(using: proxy)
            } label: {
                MapHomeLocationButtonIcon(
                    state: MapHomeLocationButtonState.resolve(
                        hasLocation: displayedLocationCoordinate != nil,
                        trackingMode: userTrackingMode,
                        isCentered: isMapCenteredOnUser
                    ),
                    showsGPSDot: hasConfirmedCurrentGPS
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
                        .foregroundStyle(Color.tpPastelRose)
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
        proxy: MapProxy?
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

    private func adjustMapZoom(direction: Int, proxy: MapProxy?) {
        guard let camera = visibleMapCamera else { return }
        let distance = MapHomeCameraZoomMath.distance(
            from: camera.distance,
            direction: direction
        )
        guard distance != camera.distance else { return }
        let anchor = userTrackingMode.keepsCameraLocked || isMapCenteredOnUser
            ? displayedLocationCoordinate ?? camera.centerCoordinate
            : camera.centerCoordinate
        let center = MapHomeCameraZoomMath.centerPreservingAnchor(
            cameraCenter: camera.centerCoordinate,
            anchor: anchor,
            oldDistance: camera.distance,
            newDistance: distance
        )
        setMapPosition(.camera(
            MapCamera(
                centerCoordinate: center,
                distance: distance,
                heading: camera.heading,
                pitch: camera.pitch
            )
        ))
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
                    width: Layout.menuWidth(for: proxy.size.width),
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
            .padding(.bottom, 18)

            locationMenuItem
            categoryMenuItem
            displayMenuItem
            stickerMenuItem
            languageMenuItem
            appleWatchMenuItem
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
                .padding(.vertical, 9)

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
            .padding(.horizontal, 20)
            .padding(.top, 60)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(MapHomeScrollBounceDisabler())
    }

    private var categoryMenuItem: some View {
        VStack(alignment: .leading, spacing: 5) {
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
                .padding(.vertical, 10)
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
                                MapHomeStickmanGlyph(
                                    action: category.stickmanAction,
                                    size: 22
                                )
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
                        VStack(alignment: .leading, spacing: 4) {
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
                                Button {
                                    if activePaletteCategoryID == category.id.uuidString {
                                        activePaletteCategoryID = nil
                                    } else {
                                        customPaletteColor = Color(hex: category.hex)
                                        activePaletteCategoryID = category.id.uuidString
                                    }
                                } label: {
                                    Image(systemName: "paintpalette.fill")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(Color(hex: category.hex))
                                        .frame(width: 28, height: 28)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(language.text("\(category.title) 색상 팔레트", "\(category.title) color palette"))
                            }
                            if activePaletteCategoryID == category.id.uuidString {
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                                    ForEach(Self.categoryPaletteHexes, id: \.self) { hex in
                                        Button {
                                            model.setMapCategoryColor(hex, for: category.id.uuidString)
                                            activePaletteCategoryID = nil
                                        } label: {
                                            Circle().fill(Color(hex: hex)).frame(width: 22, height: 22)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    ColorPicker(language.text("사용자 지정", "Custom"), selection: Binding(
                                        get: { customPaletteColor },
                                        set: { color in
                                            customPaletteColor = color
                                            if let hex = color.hexRGBString {
                                                model.setMapCategoryColor(hex, for: category.id.uuidString)
                                            }
                                        }
                                    ), supportsOpacity: false)
                                    .frame(minHeight: 28)
                                }
                                .padding(.leading, 39)
                            }
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
        VStack(alignment: .leading, spacing: 5) {
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
                .padding(.vertical, 9)
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
        model.settings.frequentPlaces.filter {
            $0.kind == .custom || $0.kind == .restaurant
        }
    }

    private var userLocationCount: Int {
        userFrequentPlaces.count + model.settings.userTransitLocations.count
    }

    private func userFrequentPlaceRow(_ place: FrequentPlace) -> some View {
        Button {
            selectedMapTargetID = "place.\(place.id.uuidString)"
            if let point = place.point {
                focusMap(on: point)
                isMenuOpen = false
            } else {
                selectedUserLocation = .frequentPlace(place.id)
                isMenuOpen = false
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: place.kind.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(
                        MapHomeLocationDestination(placeKind: place.kind)?.tint
                            ?? MapHomeLocationDestination.user.tint
                    )
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(displayedFrequentPlaceName(place))
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Text(
                        place.point == nil
                            ? language.text("위치 미지정", "Location not set")
                            : place.kind == .restaurant
                                ? language.text("등록 식당", "Restaurant")
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
                    Text(language.text(location.kind.title, location.kind.englishTitle))
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
            return language.text("현재 위치로 설정", "Set from current location")
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
            .padding(.vertical, 9)
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

    private var stickerMenuItem: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                isStickerMenuExpanded.toggle()
            } label: {
                HStack(spacing: 13) {
                    Image(systemName: "seal.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.tpPastelRose)
                        .frame(width: 24)
                    Text(language.text("메모", "Memos"))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Spacer()
                    Image(systemName: isStickerMenuExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.primary)
                .padding(.vertical, 9)
                .padding(.horizontal, 12)
                .background(
                    Color.tpPastelRose.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(language.text("메모 메뉴", "Memo menu"))

            if isStickerMenuExpanded {
                Toggle(
                    isOn: Binding(
                        get: { isStickerMode },
                        set: { isStickerMode = $0 }
                    )
                ) {
                    Label(
                        language.text("메모 모드", "Memo mode"),
                        systemImage: "note.text"
                    )
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                }
                .tint(Color.tpPastelRose)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)

                Button {
                    addMapSticker()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.tpReferenceBlue)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(language.text("지도에 메모 추가", "Add memo to map"))
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                            Text(language.text("현재 지도 중심에 메모 스티커 배치", "Place a memo sticker at the current map center"))
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
                        Color.tpReferenceBlue.opacity(0.055),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(language.text("지도에 메모 추가", "Add memo to map"))
                .padding(.leading, 12)

                Button {
                    addScheduleSticker()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "calendar.badge.plus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.tpReferenceMint)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(language.text("일정에 메모 추가", "Add memo to schedule"))
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                            Text(language.text("선택한 시간에 메모 스티커 배치", "Place a memo sticker at the selected time"))
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
                        Color.tpReferenceMint.opacity(0.055),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(language.text("일정에 메모 추가", "Add memo to schedule"))
                .padding(.leading, 12)

                if isStickerMode {
                    Text(language.text("지도의 메모 스티커를 탭해 수정할 수 있어요.", "Tap a memo sticker on the map to edit it."))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                        .padding(.horizontal, 12)
                }
            }
        }
    }

    private var displayMenuItem: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                isDisplayMenuExpanded.toggle()
            } label: {
                HStack(spacing: 13) {
                    Image(systemName: "square.3.layers.3d")
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
                .padding(.vertical, 9)
                .padding(.horizontal, 12)
                .background(
                    Color.tpReferenceBlue.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            }
            .buttonStyle(.plain)

            if isDisplayMenuExpanded {
                Text(language.text("지도 스타일", "Map style"))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                    .padding(.horizontal, 12)

                HStack(spacing: 10) {
                    Image(systemName: "map.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 22)
                    Text(language.text("WBS 지도 · Apple", "WBS map · Apple"))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Spacer()
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundStyle(Color.primary)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    language.text("지도 스타일 WBS 지도 Apple 고정", "Map style fixed to WBS Apple")
                )

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
            }
        }
    }

    private var settingsMenuItem: some View {
        VStack(alignment: .leading, spacing: 5) {
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
                .padding(.vertical, 9)
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

    private var appleWatchMenuItem: some View {
        let state = model.appleWatchConnectionState
        let tint = Color.tpMovementDark
        return VStack(alignment: .leading, spacing: 5) {
            Button {
                model.refreshAppleWatchConnectionState()
                isAppleWatchMenuExpanded.toggle()
            } label: {
                HStack(spacing: 13) {
                    Image(systemName: "applewatch")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(language.text("Apple Watch 데이터", "Apple Watch data"))
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                        Text(appleWatchMenuSubtitle)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(appleWatchMenuValue(for: state))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(tint)
                    Image(
                        systemName: isAppleWatchMenuExpanded
                            ? "chevron.up"
                            : "chevron.down"
                    )
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.primary)
                .padding(.vertical, 12)
                .padding(.horizontal, 12)
                .background(
                    tint.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 12)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                language.text(
                    "Apple Watch 데이터 상태",
                    "Apple Watch data status"
                )
            )
            .accessibilityValue(appleWatchMenuSubtitle)

            if isAppleWatchMenuExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text(appleWatchMenuDescription(for: state))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !hasRecentAppleWatchData
                        || model.appleWatchReceivedDataKinds.isEmpty {
                        Text(
                            language.text(
                                "최근 수신된 데이터 항목 없음",
                                "No data types received recently"
                            )
                        )
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(language.text("최근 수신 항목", "Recently received"))
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(tint)
                            ForEach(
                                model.appleWatchReceivedDataKinds.sorted {
                                    $0.rawValue < $1.rawValue
                                },
                                id: \.self
                            ) { kind in
                                Label(
                                    appleWatchDataKindTitle(kind),
                                    systemImage: "checkmark.circle.fill"
                                )
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.primary)
                            }
                        }
                    }

                    if let receivedAt = model.appleWatchLastDataReceivedAt {
                        Text(
                            language.text(
                                "최근 데이터 시각 \(receivedAt.formatted(date: .omitted, time: .shortened))",
                                "Latest data \(receivedAt.formatted(date: .omitted, time: .shortened))"
                            )
                        )
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        Text(
                            language.text(
                                "가져오기: \(model.settings.watchDataSyncProfile.localizedSubtitle(AppLanguagePreference.resolve(rawValue: languageRawValue)))",
                                "Import: \(model.settings.watchDataSyncProfile.localizedSubtitle(AppLanguagePreference.resolve(rawValue: languageRawValue)))"
                            )
                        )
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button(language.text("지금 가져오기", "Import now")) {
                            model.requestWatchDataSync()
                            model.refreshAppleWatchConnectionState()
                        }
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(tint)
                    }
                }
                .padding(.vertical, 9)
                .padding(.horizontal, 12)
                .background(
                    tint.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .padding(.leading, 12)
            }
        }
    }

    private var appleWatchMenuSubtitle: String {
        switch model.appleWatchConnectionState {
        case .unsupported:
            language.text("이 기기에서 사용할 수 없음", "Unavailable on this device")
        case .notPaired:
            language.text("Apple Watch 미페어링", "Apple Watch not paired")
        case .appNotInstalled:
            language.text("워치 앱 설치 필요", "Watch app needs installation")
        case .noRecentData:
            language.text("최근 15분 내 데이터 없음", "No data in the last 15 min")
        case .background:
            language.text("최근 데이터 · 백그라운드 수신", "Recent data · background")
        case .reachable:
            language.text("최근 데이터 · 실시간 수신", "Recent data · live")
        }
    }

    private var hasRecentAppleWatchData: Bool {
        guard let receivedAt = model.appleWatchLastDataReceivedAt else {
            return false
        }
        let age = Date.now.timeIntervalSince(receivedAt)
        return age >= 0
            && age <= AppleWatchConnectionPolicy.recentContactWindow
    }

    private func appleWatchMenuValue(
        for state: AppleWatchConnectionState
    ) -> String {
        switch state {
        case .unsupported: language.text("사용 불가", "Unavailable")
        case .notPaired: language.text("미페어링", "Not paired")
        case .appNotInstalled: language.text("설치 필요", "Install")
        case .noRecentData: language.text("수신 대기", "Waiting")
        case .background: language.text("연결됨", "Connected")
        case .reachable: language.text("실시간", "Live")
        }
    }

    private func appleWatchMenuDescription(
        for state: AppleWatchConnectionState
    ) -> String {
        switch state {
        case .unsupported:
            language.text(
                "이 기기에서는 Apple Watch 데이터를 사용할 수 없습니다.",
                "Apple Watch data is unavailable on this device."
            )
        case .notPaired:
            language.text(
                "Apple Watch를 연결하면 손목 움직임·심박수·운동 정보를 더 수집합니다.",
                "Pairing Apple Watch adds wrist motion, heart-rate, and workout data."
            )
        case .appNotInstalled:
            language.text(
                "연결된 Apple Watch에 앱을 설치하면 손목 센서 데이터를 더 수집합니다.",
                "Install the app on the paired Apple Watch to collect more wrist-sensor data."
            )
        case .noRecentData:
            language.text(
                "최근 15분 내 실제 센서·건강 데이터가 없어 수신을 기다리는 중입니다.",
                "No sensor or health data arrived in the last 15 minutes."
            )
        case .background, .reachable:
            language.text(
                "Apple Watch가 있어 iPhone만으로 얻기 어려운 손목 센서 정보를 더 수집합니다.",
                "Apple Watch adds wrist-sensor data that iPhone cannot collect alone."
            )
        }
    }

    private func appleWatchDataKindTitle(
        _ kind: AppleWatchDataKind
    ) -> String {
        switch kind {
        case .motion:
            language.text("손목 움직임·가속도", "Wrist motion and acceleration")
        case .heartRate:
            language.text("심박수", "Heart rate")
        case .route:
            language.text("워치 이동 경로", "Watch route")
        case .activity:
            language.text("운동·행동", "Workout and behavior")
        case .health:
            language.text("활동·수면 건강 데이터", "Activity and sleep health data")
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
        let preferences = model.settings.gpsLoggingPreferences
        return VStack(spacing: 8) {
            Button {
                isGPSLoggingMenuExpanded.toggle()
            } label: {
                HStack(spacing: 13) {
                    Image(systemName: isLogging ? "location.fill" : "location.viewfinder")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(language.text("GPS 및 센서 데이터", "GPS & Sensor Data"))
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                        Text(sensorCollectionStatusText)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(
                        systemName: isGPSLoggingMenuExpanded
                            ? "chevron.up"
                            : "chevron.down"
                    )
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.primary)
                .padding(.vertical, 12)
                .padding(.horizontal, 12)
                .background(
                    tint.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 12)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                language.text(
                    "GPS 및 센서 데이터 설정",
                    "GPS and sensor settings"
                )
            )
            .accessibilityValue(
                gpsLoggingIntervalText(preferences.effectiveIntervalSeconds)
            )

            if isGPSLoggingMenuExpanded {
                VStack(spacing: 8) {
                    Button {
                        model.setGPSLoggingBatteryMinimal(
                            !preferences.isBatteryMinimal
                        )
                    } label: {
                        HStack {
                            Label(
                                language.text(
                                    "배터리 최소",
                                    "Minimum battery"
                                ),
                                systemImage: "battery.25percent"
                            )
                            Spacer()
                            Text(gpsLoggingIntervalText(preferences.effectiveIntervalSeconds))
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                            if preferences.isBatteryMinimal {
                                Image(systemName: "checkmark.circle.fill")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(
                        preferences.isBatteryMinimal ? tint : Color.primary
                    )

                    VStack(spacing: 5) {
                        Slider(
                            value: Binding(
                                get: {
                                    Double(
                                        GPSLoggingPreferences.supportedIntervalSeconds
                                            .firstIndex(
                                                of: preferences.effectiveIntervalSeconds
                                            ) ?? 0
                                    )
                                },
                                set: { value in
                                    let index = min(
                                        max(Int(value.rounded()), 0),
                                        GPSLoggingPreferences.supportedIntervalSeconds.count - 1
                                    )
                                    model.setGPSLoggingIntervalSeconds(
                                        GPSLoggingPreferences.supportedIntervalSeconds[index]
                                    )
                                }
                            ),
                            in: 0...Double(
                                max(
                                    0,
                                    GPSLoggingPreferences.supportedIntervalSeconds.count - 1
                                )
                            ),
                            step: 1
                        )
                        .tint(tint)
                        HStack {
                            Text(
                                gpsLoggingIntervalText(
                                    GPSLoggingPreferences.supportedIntervalSeconds.first ?? 60
                                )
                            )
                            Spacer()
                            Text(
                                gpsLoggingIntervalText(
                                    GPSLoggingPreferences.supportedIntervalSeconds[1]
                                )
                            )
                            Spacer()
                            Text(
                                gpsLoggingIntervalText(
                                    GPSLoggingPreferences.supportedIntervalSeconds.last ?? 900
                                )
                            )
                        }
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
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
                name: displayedFrequentPlaceName(place),
                floor: place.floor,
                destination: destination,
                coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
            )
        }
    }

    private func displayedFrequentPlaceName(_ place: FrequentPlace) -> String {
        guard place.kind == .restaurant else { return place.name }
        let name = place.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "사용자 지점"
            || name.caseInsensitiveCompare("User location") == .orderedSame {
            return "식당"
        }
        return name
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

    private var transitBoardingReadings: [SensorReading] {
        var seen = Set<UUID>()
        return (
            routeReadings
                + model.liveRouteState.readings
                + (model.latestSensorReading.map { [$0] } ?? [])
        )
        .filter { seen.insert($0.id).inserted }
        .sorted { $0.timestamp < $1.timestamp }
    }

    private var transitBoardingCandidates: [TransitBoardingCandidate] {
        let key = MapHomeTransitBoardingCandidateCacheKey(
            snapshotRevision: model.snapshotRevision,
            readingsRevision: transitBoardingReadingsRevision,
            nearbyPlacesRevision: nearbyTransitPlacesRevision,
            cutoff: routeOverlayCutoff
        )
        return mapRenderCache.transitBoardingCandidates(key: key) {
            TransitBoardingCandidateEngine.candidates(
                readings: transitBoardingReadings,
                registeredLocations: model.settings.userTransitLocations,
                nearbyPlaces: nearbyTransitPlaces,
                travel: model.snapshot.travel,
                decisions: model.settings.transitBoardingDecisions,
                through: routeOverlayCutoff
            )
        }
    }

    private var currentCoordinate: CLLocationCoordinate2D? {
        let readings = [model.latestSensorReading, model.liveRouteState.readings.last]
            .compactMap { $0 }
        let temporaryLocations = SubwayStationCatalog.temporaryLocations(from: readings)
        let point = MapCurrentLocationAnchorPolicy.latestValidReading(
            in: readings
        )?.point ?? RealtimeSensorMapProjection.project(
            readings: readings,
            at: .now,
            temporaryLocations: temporaryLocations.isEmpty
                ? cachedTemporaryLocations
                : temporaryLocations
        )?.point
        guard let point, isValid(point) else { return nil }
        return CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
    }

    private var hasConfirmedCurrentGPS: Bool {
        MapHomeCurrentGPSPolicy.isConfirmed(
            in: [model.latestSensorReading, model.liveRouteState.readings.last]
                .compactMap { $0 }
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
                ?? MapHomePastelPalette.hex(id)
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

    private func refreshSelectedTimelineMapPosition(
        minute: Int?,
        using proxy: MapProxy? = nil
    ) {
        let deferredProjection = flushDeferredRouteProjection()
        guard minute != nil else {
            historicalPlaybackPoint = nil
            return
        }
        let projection = deferredProjection
            ?? refreshRouteProjection()
        let point = refreshHistoricalPlaybackPoint()
            ?? (routeReadingsLoadState.isLoaded(for: model.selectedDate)
                ? projection?.coordinateAtCutoff
                : nil)
        guard let point else { return }
        focusMap(on: point, using: proxy, followsTracking: true)
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
        let cutoff = routeOverlayCutoff
        return mapRenderCache.visibleExpectedRoutes(cutoff: cutoff) {
            expectedRouteOverlays.compactMap {
                $0.visible(through: cutoff)
            }
        }
    }

    private var visibleWBSGeneratedRouteOverlays: [MapHomeWBSGeneratedRouteOverlay] {
        let cutoff = routeOverlayCutoff
        return wbsGeneratedRouteOverlays.compactMap {
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
            through: dayEnd,
            frequentPlaces: model.settings.frequentPlaces
        )
        if expectedRouteCache.count > 128 {
            expectedRouteCache.removeAll(keepingCapacity: true)
        }

        let limitedRequests = Array(requests.prefix(24))
        let fallbackExpected = limitedRequests.map {
            expectedRouteOverlay(for: $0, coordinates: [
                CLLocationCoordinate2D(
                    latitude: $0.start.latitude,
                    longitude: $0.start.longitude
                ),
                CLLocationCoordinate2D(
                    latitude: $0.end.latitude,
                    longitude: $0.end.longitude
                ),
            ])
        }
        let fallbackProjection = makeWBSPlaybackProjection(
            expected: fallbackExpected,
            generated: []
        )
        let excludedLegIDs = Set(
            fallbackExpected.map { "movement-\($0.id.uuidString)" }
                + storedWBSResolvedRoutes.map(\.legID)
        )
        let fallbackGenerated = generatedWBSRouteOverlays(
            from: fallbackProjection,
            excluding: excludedLegIDs
        )
        _ = applyForecastRouteState(
            MapHomeForecastRouteState(
                expected: fallbackExpected,
                generated: fallbackGenerated
            )
        )

        var resolvedExpected: [MapHomeExpectedRouteOverlay] = []
        for request in limitedRequests {
            guard !Task.isCancelled else { return }
            let coordinates: [CLLocationCoordinate2D]
            if let cached = expectedRouteCache[request], cached.count >= 2 {
                coordinates = cached
            } else {
                let resolved = await mapKitRouteCoordinates(for: request)
                if resolved.count >= 2 {
                    expectedRouteCache[request] = resolved
                    coordinates = resolved
                } else {
                    coordinates = [
                        CLLocationCoordinate2D(
                            latitude: request.start.latitude,
                            longitude: request.start.longitude
                        ),
                        CLLocationCoordinate2D(
                            latitude: request.end.latitude,
                            longitude: request.end.longitude
                        ),
                    ]
                }
            }
            resolvedExpected.append(
                expectedRouteOverlay(for: request, coordinates: coordinates)
            )
        }
        guard !Task.isCancelled,
              calendar.isDate(selectedDay, inSameDayAs: model.selectedDate)
        else { return }

        let resolvedProjection = makeWBSPlaybackProjection(
            expected: resolvedExpected,
            generated: []
        )
        var resolvedGenerated = generatedWBSRouteOverlays(
            from: resolvedProjection,
            excluding: Set(
                resolvedExpected.map { "movement-\($0.id.uuidString)" }
                    + storedWBSResolvedRoutes.map(\.legID)
            )
        )
        for index in resolvedGenerated.indices {
            guard !Task.isCancelled else { return }
            guard let transport = wbsRouteTransport(for: resolvedGenerated[index].mode),
                  let start = resolvedGenerated[index].coordinates.first,
                  let end = resolvedGenerated[index].coordinates.last else { continue }
            if let coordinates = await MapHomeAppleRouteResolver.shared.resolve(
                start: start,
                end: end,
                transport: transport,
                departureDate: resolvedGenerated[index].departureDate
            ), coordinates.count >= 2 {
                resolvedGenerated[index] = MapHomeWBSGeneratedRouteOverlay(
                    id: resolvedGenerated[index].id,
                    mode: resolvedGenerated[index].mode,
                    departureDate: resolvedGenerated[index].departureDate,
                    arrivalDate: resolvedGenerated[index].arrivalDate,
                    coordinates: coordinates
                )
            }
        }
        guard !Task.isCancelled,
              calendar.isDate(selectedDay, inSameDayAs: model.selectedDate)
        else { return }
        let didApply = applyForecastRouteState(
            MapHomeForecastRouteState(
                expected: resolvedExpected,
                generated: resolvedGenerated
            )
        )
        guard didApply else { return }
        applyInitialMapFocusIfNeeded()
        if MapHomePlaybackCameraPolicy.allowsAutomaticFit(
            isPlaybackRunning: isDayPlaybackRunning,
            hasUserAdjustedMap: hasUserAdjustedMap
        ) {
            focusMapOnAllRoutes()
        }
        persistMapDayCache()
    }

    private func expectedRouteOverlay(
        for request: ExpectedRouteRequest,
        coordinates: [CLLocationCoordinate2D]
    ) -> MapHomeExpectedRouteOverlay {
        MapHomeExpectedRouteOverlay(
            id: request.segmentID,
            mode: request.mode,
            departureDate: request.departureDate,
            arrivalDate: request.arrivalDate,
            coordinates: coordinates
        )
    }

    private func generatedWBSRouteOverlays(
        from projection: MapHomeWBSPlaybackProjection,
        excluding excludedLegIDs: Set<String>
    ) -> [MapHomeWBSGeneratedRouteOverlay] {
        projection.legs.compactMap { leg in
            guard leg.routePhase == .forecast,
                  leg.activity == .movement,
                  !excludedLegIDs.contains(leg.id),
                  leg.coordinates.count >= 2 else { return nil }
            return MapHomeWBSGeneratedRouteOverlay(
                id: leg.id,
                mode: leg.mode,
                departureDate: leg.startDate,
                arrivalDate: leg.endDate,
                coordinates: leg.coordinates.map {
                    CLLocationCoordinate2D(
                        latitude: $0.latitude,
                        longitude: $0.longitude
                    )
                }
            )
        }
    }

    private func wbsRouteTransport(
        for mode: TravelMode?
    ) -> ExpectedRouteTransport? {
        guard let mode else { return .automobile }
        switch mode {
        case .car, .taxi, .bus: return .automobile
        case .subway, .train: return .transit
        case .walking, .running, .cycling: return .walking
        case .airplane, .ship: return nil
        }
    }

    @discardableResult
    private func applyForecastRouteState(
        _ state: MapHomeForecastRouteState
    ) -> Bool {
        guard !isTimelineInteractionActive || isDayPlaybackRunning else {
            pendingForecastRouteState = state
            hasDeferredWBSPlaybackRefresh = true
            return false
        }
        pendingForecastRouteState = nil
        mapRenderCache.invalidateExpectedRoutes()
        expectedRouteOverlays = state.expected
        wbsGeneratedRouteOverlays = state.generated
        refreshWBSPlaybackProjection()
        return true
    }

    private func mapKitRouteCoordinates(
        for routeRequest: ExpectedRouteRequest
    ) async -> [CLLocationCoordinate2D] {
        await MapHomeAppleRouteResolver.shared.resolve(
            start: CLLocationCoordinate2D(
                latitude: routeRequest.start.latitude,
                longitude: routeRequest.start.longitude
            ),
            end: CLLocationCoordinate2D(
                latitude: routeRequest.end.latitude,
                longitude: routeRequest.end.longitude
            ),
            transport: routeRequest.transport,
            departureDate: routeRequest.departureDate
        ) ?? []
    }

    private var subwayRouteOverlays: [MapHomeSubwayRouteOverlay] {
        let calendar = Calendar.autoupdatingCurrent
        guard let dayStart = calendar.startOfDay(for: model.selectedDate) as Date?,
              let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
        else { return [] }
        let day = TimeSpan(start: dayStart, end: dayEnd)
        let cutoff = routeOverlayCutoff
        let cutoffMinute = calendar.dateComponents(
            [.minute],
            from: dayStart,
            to: cutoff
        ).minute ?? effectiveTimelineMinute
        return mapRenderCache.subwayRoutes(
            day: dayStart,
            minute: cutoffMinute
        ) {
            MapHomeSubwayRouteOverlayEngine.overlays(
                travel: model.snapshot.travel,
                readings: routeReadings
                    + model.liveRouteState.readings
                    + (model.latestSensorReading.map { [$0] } ?? []),
                day: day,
                through: cutoff
            )
        }
    }

    private var temporaryLocationAnnotations: [MapHomeTemporaryLocationAnnotation] {
        let readings = routeReadings
            + model.liveRouteState.readings
            + (model.latestSensorReading.map { [$0] } ?? [])
        let derived = SubwayStationCatalog.temporaryLocations(from: readings)
        let locations = derived.isEmpty ? cachedTemporaryLocations : derived
        return locations
            .filter { $0.timestamp <= routeOverlayCutoff }
            .map {
                MapHomeTemporaryLocationAnnotation(
                    id: $0.id,
                    stationName: $0.stationName,
                    timestamp: $0.timestamp,
                    point: $0.point,
                    reason: $0.reason
                )
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
                speedMetersPerSecond: segment.speedMetersPerSecond,
                coordinates: coordinates
            )
        }
    }

    private var wbsPlaybackFrame: MapHomeWBSPlaybackFrame? {
        guard selectedTimelineMinute != nil else { return nil }
        return wbsPlaybackProjection?.frame(at: displayedLocationDate)
    }

    private var historicalPlaybackCoordinate: CLLocationCoordinate2D? {
        if let point = wbsPlaybackFrame?.coordinate {
            let coordinate = CLLocationCoordinate2D(
                latitude: point.latitude,
                longitude: point.longitude
            )
            return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
        }
        guard selectedTimelineMinute != nil,
              let point = historicalPlaybackPoint
                ?? routeProjection?.coordinateAtCutoff,
              isValid(point) else { return nil }
        return CLLocationCoordinate2D(
            latitude: point.latitude,
            longitude: point.longitude
        )
    }

    private var activeExpectedRoute: MapHomeExpectedRouteOverlay? {
        let date = displayedLocationDate
        return expectedRouteOverlays
            .filter {
                $0.coordinates.count >= 2
                    && $0.departureDate <= date
                    && date <= $0.arrivalDate
            }
            .min { $0.departureDate < $1.departureDate }
    }

    private var expectedRoutePlaybackCoordinate: CLLocationCoordinate2D? {
        activeExpectedRoute?.coordinate(at: displayedLocationDate)
    }

    private var displayedPlaybackFocusPoint: GeoPoint? {
        if let point = wbsPlaybackFrame?.cameraCoordinate {
            return point
        }
        guard let coordinate = expectedRoutePlaybackCoordinate
            ?? historicalPlaybackCoordinate else { return nil }
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        return GeoPoint(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            altitude: 0,
            horizontalAccuracy: -1,
            verticalAccuracy: -1
        )
    }

    private var displayedLocationCoordinate: CLLocationCoordinate2D? {
        if let coordinate = historicalPlaybackCoordinate,
           selectedTimelineMinute != nil {
            return coordinate
        }
        if let expectedRoutePlaybackCoordinate,
           selectedTimelineMinute != nil || currentCoordinate == nil {
            return expectedRoutePlaybackCoordinate
        }
        return historicalPlaybackCoordinate ?? currentCoordinate
    }

    private var displayedPlaybackMinute: Double? {
        guard selectedTimelineMinute != nil else { return nil }
        if isDayPlaybackRunning {
            return dayPlaybackCurrentMinute
                ?? Double(selectedTimelineMinute ?? effectiveTimelineMinute)
        }
        return Double(selectedTimelineMinute ?? effectiveTimelineMinute)
    }

    private var displayedPlaybackDate: Date? {
        displayedPlaybackMinute.map(timelineDate(forMinute:))
    }

    private var displayedLocationDate: Date {
        displayedPlaybackDate ?? .now
    }

    private var displayedStickmanAction: MapHomeStickmanAction {
        if let mode = wbsPlaybackFrame?.mode {
            return MapHomeStickmanActionResolver.action(for: mode)
        }
        if let activeExpectedRoute {
            return MapHomeStickmanActionResolver.action(for: activeExpectedRoute.mode)
        }
        return MapHomeStickmanActionResolver.action(
            at: displayedLocationDate,
            actuals: model.snapshot.actuals,
            travel: model.snapshot.travel,
            places: model.snapshot.places,
            frequentPlaces: model.settings.frequentPlaces,
            readings: routeReadings
                + model.liveRouteState.readings
                + (model.latestSensorReading.map { [$0] } ?? [])
        )
    }

    private var displayedLocationAccessibilityLabel: String {
        if wbsPlaybackFrame?.routePhase == .forecast
            || expectedRoutePlaybackCoordinate != nil {
            return language.text("예상 경로 위치", "Expected route location")
        }
        return historicalPlaybackCoordinate == nil
            ? language.text("현재 위치", "Current location")
            : historicalPlaybackAccessibilityLabel
    }

    private var historicalPlaybackAccessibilityLabel: String {
        let minute = min(
            max(Int((displayedPlaybackMinute ?? 0).rounded(.down)), 0),
            MapHomeTimeSidebarMath.fullDayMinutes
        )
        let time = String(format: "%02d:%02d", minute / 60, minute % 60)
        return language.text("과거 위치 \(time)", "Past location \(time)")
    }

    private var effectiveTimelineMinute: Int {
        timelineSelectionMinute()
    }

    private func timelineDate(forMinute minute: Double) -> Date {
        let safeMinute = minute.isFinite
            ? min(
                Double(MapHomeTimeSidebarMath.fullDayMinutes),
                max(0, minute)
            )
            : 0
        let wholeMinute = min(
            MapHomeTimeSidebarMath.fullDayMinutes,
            Int(safeMinute.rounded(.down))
        )
        let fraction = safeMinute - Double(wholeMinute)
        let date = RouteTimelineDataEngine.timelineDate(
            selectedDate: model.selectedDate,
            minute: wholeMinute
        ).addingTimeInterval(fraction * 60)
        return clampedTimelineDate(date)
    }

    private var routeTimelineDate: Date {
        displayedPlaybackDate
            ?? clampedTimelineDate(
                RouteTimelineDataEngine.timelineDate(
                    selectedDate: model.selectedDate,
                    minute: effectiveTimelineMinute
                )
            )
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
        let result = await model.sensorReadingsLoadResult(
            in: TimeSpan(start: dayStart, end: dayEnd)
        )
        guard !Task.isCancelled,
              calendar.isDate(date, inSameDayAs: model.selectedDate)
        else { return }
        let merged = MapHomeRouteReadingsPolicy.merging(
            existing: routeReadings,
            loaded: result.readings,
            in: TimeSpan(start: dayStart, end: dayEnd)
        )
        routeReadingsLoadState = result.isComplete
            ? .loaded(dayStart)
            : .failed(dayStart)
        if merged != routeReadings {
            routeReadings = merged
            transitBoardingReadingsRevision &+= 1
        }
        scheduleTransitPOIRefresh()
        scheduleExpectedRouteRefresh()
        guard !isTimelineInteractionActive else {
            routeDocumentProjectionGate.deferRefresh(preparingReadings: true)
            return
        }
        prepareRouteProjectionReadings()
        let projection = refreshRouteProjection()
        if selectedTimelineMinute != nil {
            if let point = refreshHistoricalPlaybackPoint()
                ?? (result.isComplete ? projection?.coordinateAtCutoff : nil) {
                focusMap(
                    on: point,
                    followsTracking: true
                )
            }
        } else {
            focusMapIfNeeded()
        }
    }

    private func scheduleTransitPOIRefresh() {
        guard model.isBootstrapped else { return }
        let selectedDate = model.selectedDate
        transitPOIRefreshTask?.cancel()
        transitPOIRefreshTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            let places = await AppleTransitBoardingPOIResolver.shared.resolving(
                readings: transitBoardingReadings
            )
            guard !Task.isCancelled,
                  Calendar.autoupdatingCurrent.isDate(
                      selectedDate,
                      inSameDayAs: model.selectedDate
                  ) else { return }
            if nearbyTransitPlaces != places {
                nearbyTransitPlaces = places
                nearbyTransitPlacesRevision &+= 1
            }
        }
    }

    private func loadMapDayCache(for date: Date) async {
        if mapDayCacheStore == nil {
            mapDayCacheStore = makeMapDayCacheStore()
        }
        guard let mapDayCacheStore else { return }
        let key = TaptionPlanDayKey(date: date)
        let styleKey = model.settings.mapDisplayStyle.rawValue
        guard let payload = try? await mapDayCacheStore.codableMapDayDocument(
            MapHomeDayCachePayload.self,
            day: key,
            algorithmKey: Self.mapCacheAlgorithmKey,
            styleKey: styleKey
        ), Calendar.autoupdatingCurrent.isDate(date, inSameDayAs: model.selectedDate)
        else { return }

        guard payload.centerLatitude.isFinite,
              payload.centerLongitude.isFinite,
              (-90...90).contains(payload.centerLatitude),
              (-180...180).contains(payload.centerLongitude),
              payload.latitudeDelta.isFinite,
              payload.longitudeDelta.isFinite else { return }
        let center = CLLocationCoordinate2D(
            latitude: payload.centerLatitude,
            longitude: payload.centerLongitude
        )
        let span = MKCoordinateSpan(
            latitudeDelta: payload.latitudeDelta,
            longitudeDelta: payload.longitudeDelta
        )
        let shouldApplyCachedCamera = MapHomePlaybackCameraPolicy.allowsInitialFocus(
            isPlaybackRunning: isDayPlaybackRunning
        )
        if shouldApplyCachedCamera {
            visibleMapCenter = center
            visibleMapSpan = span
        }
        timelineRouteOverlays = payload.timeline.compactMap { overlay in
            let coordinates = overlay.coordinates.compactMap { coordinate -> CLLocationCoordinate2D? in
                guard coordinate.latitude.isFinite,
                      coordinate.longitude.isFinite,
                      (-90...90).contains(coordinate.latitude),
                      (-180...180).contains(coordinate.longitude) else { return nil }
                return CLLocationCoordinate2D(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                )
            }
            guard coordinates.count >= 2 else { return nil }
            return MapHomeTimelineRouteOverlay(
                id: overlay.id,
                categoryID: overlay.categoryID,
                opacity: overlay.opacity,
                speedMetersPerSecond: overlay.speedMetersPerSecond,
                coordinates: coordinates
            )
        }
        cachedTemporaryLocations = (payload.temporaryLocations ?? []).compactMap { item in
            guard item.latitude.isFinite, item.longitude.isFinite,
                  (-90...90).contains(item.latitude), (-180...180).contains(item.longitude)
            else { return nil }
            return SubwayStationCatalog.TemporaryLocation(
                id: item.id, timestamp: item.timestamp, stationName: item.stationName,
                point: GeoPoint(
                    latitude: item.latitude, longitude: item.longitude,
                    altitude: .nan, horizontalAccuracy: .nan, verticalAccuracy: .nan
                ), reason: item.reason
            )
        }
        expectedRouteOverlays = (payload.expected ?? []).compactMap { overlay in
            guard let mode = TravelMode(rawValue: overlay.modeRawValue)
            else { return nil }
            let coordinates = overlay.coordinates.compactMap {
                cachedCoordinate($0)
            }
            guard coordinates.count >= 2 else { return nil }
            return MapHomeExpectedRouteOverlay(
                id: overlay.id,
                mode: mode,
                departureDate: overlay.departureDate,
                arrivalDate: overlay.arrivalDate,
                coordinates: coordinates
            )
        }
        mapRenderCache.invalidateExpectedRoutes()
        requestWBSPlaybackProjectionRefresh()
        if let subwayMinute = payload.subwayMinute {
            let overlays: [MapHomeSubwayRouteOverlay] =
                (payload.subway ?? []).compactMap { overlay in
                let coordinates = overlay.coordinates.compactMap {
                    cachedCoordinate($0)
                }
                guard coordinates.count >= 2 else { return nil }
                return MapHomeSubwayRouteOverlay(
                    id: overlay.id,
                    coordinates: coordinates,
                    estimated: overlay.estimated
                )
            }
            mapRenderCache.restoreSubwayRoutes(
                day: Calendar.autoupdatingCurrent.startOfDay(for: date),
                minute: subwayMinute,
                overlays: overlays
            )
        }
        if shouldApplyCachedCamera {
            setMapPosition(.region(
                MapHomeLocationMapMath.region(center: center, span: span)
            ))
        }
    }

    private func cachedCoordinate(
        _ coordinate: MapHomeCachedCoordinate
    ) -> CLLocationCoordinate2D? {
        guard coordinate.latitude.isFinite,
              coordinate.longitude.isFinite,
              (-90...90).contains(coordinate.latitude),
              (-180...180).contains(coordinate.longitude) else { return nil }
        return CLLocationCoordinate2D(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
    }

    private func makeMapDayCacheStore() -> TaptionPlanDayStore? {
        guard let url = try? TaptionLocalDatabaseLocation
            .sharedOrApplicationSupport() else { return nil }
        return try? TaptionPlanDayStore(url: url)
    }

    private func persistMapDayCache() {
        guard visibleMapCenter.latitude.isFinite,
              visibleMapCenter.longitude.isFinite,
              visibleMapSpan.latitudeDelta.isFinite,
              visibleMapSpan.longitudeDelta.isFinite else { return }
        if mapDayCacheStore == nil {
            mapDayCacheStore = makeMapDayCacheStore()
        }
        guard let mapDayCacheStore else { return }
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: model.selectedDate)
        let subwayMinute = calendar.dateComponents(
            [.minute],
            from: dayStart,
            to: routeOverlayCutoff
        ).minute ?? effectiveTimelineMinute
        let cachedSubwayRoutes = subwayRouteOverlays
        let payload = MapHomeDayCachePayload(
            centerLatitude: visibleMapCenter.latitude,
            centerLongitude: visibleMapCenter.longitude,
            latitudeDelta: visibleMapSpan.latitudeDelta,
            longitudeDelta: visibleMapSpan.longitudeDelta,
            timeline: timelineRouteOverlays.map { overlay in
                MapHomeCachedRouteOverlay(
                    id: overlay.id,
                    categoryID: overlay.categoryID,
                    opacity: overlay.opacity,
                    speedMetersPerSecond: overlay.speedMetersPerSecond,
                    coordinates: overlay.coordinates.map {
                        MapHomeCachedCoordinate(
                            latitude: $0.latitude,
                            longitude: $0.longitude
                        )
                    }
                )
            },
            expected: expectedRouteOverlays.map { overlay in
                MapHomeCachedExpectedRouteOverlay(
                    id: overlay.id,
                    modeRawValue: overlay.mode.rawValue,
                    departureDate: overlay.departureDate,
                    arrivalDate: overlay.arrivalDate,
                    coordinates: overlay.coordinates.map {
                        MapHomeCachedCoordinate(
                            latitude: $0.latitude,
                            longitude: $0.longitude
                        )
                    }
                )
            },
            subway: cachedSubwayRoutes.map { overlay in
                MapHomeCachedSubwayRouteOverlay(
                    id: overlay.id,
                    estimated: overlay.estimated,
                    coordinates: overlay.coordinates.map {
                        MapHomeCachedCoordinate(
                            latitude: $0.latitude,
                            longitude: $0.longitude
                        )
                    }
                )
            },
            subwayMinute: subwayMinute,
            temporaryLocations: temporaryLocationAnnotations.map { location in
                MapHomeCachedTemporaryLocation(
                    id: location.id, timestamp: location.timestamp,
                    stationName: location.stationName,
                    latitude: location.point.latitude, longitude: location.point.longitude,
                    reason: location.reason
                )
            }
        )
        let day = TaptionPlanDayKey(date: model.selectedDate)
        let styleKey = model.settings.mapDisplayStyle.rawValue
        Task {
            try? await mapDayCacheStore.saveCodableMapDayDocument(
                payload,
                day: day,
                algorithmKey: Self.mapCacheAlgorithmKey,
                styleKey: styleKey
            )
        }
    }

    private func reportInitialMapShellReadyIfNeeded(for date: Date) {
        guard !hasReportedInitialDataReady,
              model.isBootstrapped,
              Calendar.autoupdatingCurrent.isDate(
                  date,
                  inSameDayAs: model.selectedDate
              ) else { return }
        hasReportedInitialDataReady = true
        onInitialDataReady()
    }

    private var routeOverlayCutoff: Date {
        if isTimelineInteractionActive, let routeProjection {
            return routeProjection.cutoff
        }
        let timelineDate = routeTimelineDate
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: model.selectedDate)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(24 * 60 * 60)
        return MapHomeRouteOverlayCutoffPolicy.cutoff(
            selectedDayEnd: dayEnd,
            timelineDate: timelineDate,
            isPlaybackRunning: isDayPlaybackRunning
        )
    }

    private func requestRouteProjectionRefresh(
        preparingReadings: Bool = false
    ) {
        guard !isTimelineInteractionActive else {
            routeDocumentProjectionGate.deferRefresh(
                preparingReadings: preparingReadings
            )
            return
        }
        if preparingReadings {
            prepareRouteProjectionReadings()
        }
        refreshRouteProjection()
        refreshHistoricalPlaybackPoint()
    }

    private func scheduleLiveRouteProjectionRefresh() {
        liveRouteProjectionRefreshTask?.cancel()
        liveRouteProjectionRefreshTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return
            }
            mapRenderCache.invalidateRouteData()
            requestRouteProjectionRefresh(preparingReadings: true)
            liveRouteProjectionRefreshTask = nil
        }
    }

    @discardableResult
    private func flushDeferredRouteProjection() -> RouteTimelineProjection? {
        guard let refresh = routeDocumentProjectionGate
            .consumeDeferredRefresh() else {
            return nil
        }
        if refresh.preparesReadings {
            prepareRouteProjectionReadings()
        }
        let projection = refreshRouteProjection()
        flushDeferredWBSPlaybackProjection()
        refreshHistoricalPlaybackPoint()
        return projection
    }

    @discardableResult
    private func refreshRouteProjection() -> RouteTimelineProjection? {
        mapRenderCache.invalidateRouteData()
        let calendar = Calendar.autoupdatingCurrent
        let timelineDate = routeTimelineDate
        let dayStart = calendar.startOfDay(for: model.selectedDate)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(24 * 60 * 60)
        let projectionDate = MapHomeRouteOverlayCutoffPolicy.cutoff(
            selectedDayEnd: dayEnd,
            timelineDate: timelineDate,
            isPlaybackRunning: isDayPlaybackRunning
        )
        let next = RouteTimelineDataEngine.project(
            selectedDate: model.selectedDate,
            through: projectionDate,
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
        let filteredRouteReadings = TaptionRouteEngineAdapter
            .filteredReadings(from: sourceReadings)
        normalizedRouteReadings = RouteTimelineDataEngine
            .normalizedDisplayReadings(filteredRouteReadings)
            .filter { $0.timestamp >= dayStart && $0.timestamp < dayEnd }
        historicalPlaybackReadings = RouteTimelineDataEngine
            .normalizedDisplayReadings(filteredRouteReadings)
            .filter { $0.timestamp >= dayStart && $0.timestamp < dayEnd }
        displayRouteReadings = RouteTimelineDataEngine.displayReadings(
            from: normalizedRouteReadings
        )
        requestWBSPlaybackProjectionRefresh()
    }

    private func requestWBSPlaybackProjectionRefresh() {
        guard !isTimelineInteractionActive || isDayPlaybackRunning else {
            hasDeferredWBSPlaybackRefresh = true
            return
        }
        refreshWBSPlaybackProjection()
    }

    private func flushDeferredWBSPlaybackProjection() {
        if let pendingForecastRouteState {
            self.pendingForecastRouteState = nil
            hasDeferredWBSPlaybackRefresh = false
            _ = applyForecastRouteState(pendingForecastRouteState)
            return
        }
        guard hasDeferredWBSPlaybackRefresh else { return }
        hasDeferredWBSPlaybackRefresh = false
        refreshWBSPlaybackProjection()
    }

    private func refreshWBSPlaybackProjection() {
        let next = makeWBSPlaybackProjection(
            expected: expectedRouteOverlays,
            generated: wbsGeneratedRouteOverlays
        )
        if wbsPlaybackProjection != next {
            wbsPlaybackProjection = next
        }
    }

    private func makeWBSPlaybackProjection(
        expected: [MapHomeExpectedRouteOverlay],
        generated: [MapHomeWBSGeneratedRouteOverlay]
    ) -> MapHomeWBSPlaybackProjection {
        let expectedRoutes = expected.map { overlay in
            MapHomeWBSResolvedRoute(
                legID: "movement-\(overlay.id.uuidString)",
                coordinates: overlay.coordinates.map(wbsGeoPoint)
            )
        }
        let generatedRoutes = generated.map { overlay in
            MapHomeWBSResolvedRoute(
                legID: overlay.id,
                coordinates: overlay.coordinates.map(wbsGeoPoint)
            )
        }
        return MapHomeWBSPlaybackProjection.make(
            selectedDate: model.selectedDate,
            places: model.snapshot.places,
            travel: model.snapshot.travel,
            readings: historicalPlaybackReadings,
            resolvedRoutes: expectedRoutes + generatedRoutes + storedWBSResolvedRoutes
        )
    }

    private var storedWBSResolvedRoutes: [MapHomeWBSResolvedRoute] {
        model.snapshot.travel.compactMap { segment in
            guard segment.mode == .subway,
                  let route = segment.subwayRoute,
                  SubwayStationCatalog.isValid(route),
                  route.coordinates.count >= 2 else { return nil }
            return MapHomeWBSResolvedRoute(
                legID: "movement-\(segment.id.uuidString)",
                coordinates: route.coordinates
            )
        }
    }

    private func wbsGeoPoint(
        _ coordinate: CLLocationCoordinate2D
    ) -> GeoPoint {
        GeoPoint(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            altitude: 0,
            horizontalAccuracy: -1,
            verticalAccuracy: -1
        )
    }

    @discardableResult
    private func refreshHistoricalPlaybackPoint() -> GeoPoint? {
        if let point = wbsPlaybackProjection?.frame(at: routeTimelineDate)?.coordinate,
           selectedTimelineMinute != nil {
            if historicalPlaybackPoint != point {
                historicalPlaybackPoint = point
            }
            return point
        }
        guard selectedTimelineMinute != nil,
              routeReadingsLoadState.isLoaded(for: model.selectedDate) else {
            historicalPlaybackPoint = nil
            return nil
        }
        let date = routeTimelineDate
        let confirmedSubwayPoint = model.snapshot.travel
            .filter { segment in
                guard segment.mode == .subway,
                      segment.isConfirmed,
                      let route = segment.subwayRoute,
                      SubwayStationCatalog.isValid(route) else {
                    return false
                }
                return segment.span.contains(date)
            }
            .max { $0.span.start < $1.span.start }
            .flatMap { segment in
                RouteTimelineDataEngine.confirmedSubwayCoordinates(
                    for: segment,
                    through: date
                ).last
            }
        let timelineRoutePoint = routeProjection.flatMap {
            MapHomeRouteTimelinePlaybackMath.coordinate(
                at: date,
                in: $0.segments
            )
        }
        let point = confirmedSubwayPoint
            ?? timelineRoutePoint
            ?? RouteTimelineDataEngine.playbackCoordinate(
                at: date,
                inNormalizedReadings: historicalPlaybackReadings
            )
        if historicalPlaybackPoint != point {
            historicalPlaybackPoint = point
        }
        return point
    }

    private func clampedTimelineDate(
        _ date: Date,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        MapHomeRouteReadingsPolicy.clampedTimelineDate(
            selectedDate: model.selectedDate,
            timelineDate: date,
            now: now,
            calendar: calendar
        )
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
        shouldFitRoutesAfterDateChange = true
        hasUserAdjustedMap = false
        model.selectedDate = Date()
        selectedTimelineMinute = nil
        isTimelineSelectionPinned = false
        sharedZoomLevel = 1
        zoomResetToken += 1
        focusMapOnAllRoutes()
    }

    private func setMapPosition(_ position: MapCameraPosition) {
        mapPosition = position
        mapCameraRevision &+= 1
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
        guard MapHomePlaybackCameraPolicy.allowsInitialFocus(
            isPlaybackRunning: isDayPlaybackRunning
        ) else { return }
        guard let region = mapRouteFitRegion else { return }
        guard case .automatic = mapPosition else { return }
        setMapPosition(.region(region))
    }

    private var mapRouteFitRegion: MKCoordinateRegion? {
        var coordinates = timelineRouteOverlays.flatMap(\.coordinates)
            + visibleExpectedRouteOverlays.flatMap(\.coordinates)
            + visibleWBSGeneratedRouteOverlays.flatMap(\.coordinates)
            + subwayRouteOverlays.flatMap(\.coordinates)
        if coordinates.isEmpty, let currentCoordinate {
            coordinates = [currentCoordinate]
        }
        return MapHomeRouteFitMath.region(for: coordinates)
    }

    private func applyInitialMapFocusIfNeeded() {
        guard MapHomePlaybackCameraPolicy.allowsInitialFocus(
            isPlaybackRunning: isDayPlaybackRunning
        ),
              !hasAppliedInitialMapFocus,
              let region = mapRouteFitRegion else { return }
        hasAppliedInitialMapFocus = true
        hasCancelledInitialLocationFocus = true
        initialLocationRequestTask?.cancel()
        initialLocationRequestTask = nil
        setMapPosition(.region(region))
    }

    private func sharedZoomLevel(for span: MKCoordinateSpan) -> CGFloat? {
        guard let bounds = mapRenderCache.bounds(
            timeline: timelineRouteOverlays,
            expected: visibleExpectedRouteOverlays,
            generated: visibleWBSGeneratedRouteOverlays,
            subway: subwayRouteOverlays,
            current: currentCoordinate
        ) else { return nil }
        let fitLatitude = max(
            0.025,
            (bounds.maxLatitude - bounds.minLatitude) * 1.8
        )
        let fitLongitude = max(
            0.035,
            (bounds.maxLongitude - bounds.minLongitude) * 1.8
        )
        let scale = max(span.latitudeDelta / fitLatitude, span.longitudeDelta / fitLongitude)
        return min(max((scale - 0.05) / 0.95, 0), 1)
    }

    private func focusMapOnAllRoutes() {
        guard MapHomePlaybackCameraPolicy.allowsInitialFocus(
            isPlaybackRunning: isDayPlaybackRunning
        ) else { return }
        guard let region = mapRouteFitRegion else {
            setMapPosition(.automatic)
            return
        }
        setMapPosition(.region(region))
    }

    private func focusMap(
        on point: GeoPoint,
        using proxy: MapProxy? = nil,
        followsTracking: Bool = false
    ) {
        let coordinate = CLLocationCoordinate2D(
            latitude: point.latitude,
            longitude: point.longitude
        )
        if followsTracking,
           let proxy,
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
            setMapPosition(.camera(
                MapCamera(
                    centerCoordinate: center,
                    distance: camera.distance,
                    heading: camera.heading,
                    pitch: camera.pitch
                )
            ))
        } else if let camera = visibleMapCamera {
            setMapPosition(.camera(
                MapCamera(
                    centerCoordinate: coordinate,
                    distance: camera.distance,
                    heading: camera.heading,
                    pitch: camera.pitch
                )
            ))
        } else {
            setMapPosition(.region(
                MKCoordinateRegion(center: coordinate, span: visibleMapSpan)
            ))
        }
        if followsTracking {
            setUserTrackingMode(.following)
            isMapCenteredOnUser = true
        } else {
            setUserTrackingMode(.idle)
            isMapCenteredOnUser = false
        }
    }

    private func focusDisplayedLocation(using proxy: MapProxy?) {
        if selectedTimelineMinute != nil {
            guard let point = displayedPlaybackFocusPoint
                ?? historicalPlaybackPoint
                ?? refreshHistoricalPlaybackPoint()
            else { return }
            focusMap(on: point, using: proxy, followsTracking: true)
        } else {
            focusUserLocation(using: proxy, preservesCamera: true)
        }
    }

    private func focusUserLocation(
        using proxy: MapProxy? = nil,
        heading: CLLocationDirection? = nil,
        preservesCamera: Bool = false
    ) {
        guard let coordinate = currentCoordinate else {
            isMapCenteredOnUser = false
            return
        }

        if preservesCamera, !usesVectorRoadMap, heading == nil {
            requestAppleMapCenter(coordinate)
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
            setMapPosition(.camera(
                MapCamera(
                    centerCoordinate: center,
                    distance: camera.distance,
                    heading: heading ?? camera.heading,
                    pitch: camera.pitch
                )
            ))
        } else if let camera = visibleMapCamera {
            setMapPosition(.camera(
                MapCamera(
                    centerCoordinate: coordinate,
                    distance: camera.distance,
                    heading: heading ?? camera.heading,
                    pitch: camera.pitch
                )
            ))
        } else {
            let span = preservesCamera
                ? visibleMapSpan
                : MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.010)
            setMapPosition(.region(
                MKCoordinateRegion(
                    center: coordinate,
                    span: span
                )
            ))
        }
    }

    private func requestAppleMapCenter(
        _ coordinate: CLLocationCoordinate2D
    ) {
        appleCenterCommand = MapHomeAppleCenterCommand(
            revision: (appleCenterCommand?.revision ?? 0) &+ 1,
            coordinate: coordinate
        )
    }

    private func requestAndFollowUserLocation(using proxy: MapProxy?) {
        hasCancelledInitialLocationFocus = false
        setUserTrackingMode(.locating)
        if currentCoordinate != nil {
            focusUserLocation(using: proxy, preservesCamera: true)
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
            focusUserLocation(using: proxy, preservesCamera: true)
        }
    }

    private func toggleMapHeadingMode(using proxy: MapProxy? = nil) {
        compassControlState = compassControlState.toggled
        if compassControlState.followsHeading {
            headingMonitor.start()
            applyMapHeading(using: proxy)
        } else {
            headingMonitor.stop()
            focusUserLocation(
                using: proxy,
                heading: compassControlState.mapCameraHeading
            )
        }
    }

    private func applyMapHeading(using proxy: MapProxy?) {
        guard isHeadingMode else { return }
        let heading = headingMonitor.headingDegrees
            ?? visibleMapCamera?.heading
            ?? 0
        if currentCoordinate != nil {
            focusUserLocation(using: proxy, heading: heading)
            setUserTrackingMode(.following)
        } else if let camera = visibleMapCamera {
            setMapPosition(.camera(
                MapCamera(
                    centerCoordinate: camera.centerCoordinate,
                    distance: camera.distance,
                    heading: heading,
                    pitch: camera.pitch
                )
            ))
        }
    }

    private func applyInitialLocationIfAvailable(using proxy: MapProxy?) {
        guard MapHomePlaybackCameraPolicy.allowsInitialFocus(
            isPlaybackRunning: isDayPlaybackRunning
        ),
              mapViewportSize.width > 0,
              mapViewportSize.height > 0,
              !hasAppliedInitialLocation,
              !hasAppliedInitialMapFocus,
              currentCoordinate != nil else { return }
        focusUserLocation(using: proxy)
        hasAppliedInitialLocation = true
    }

    private func beginInitialLocationRequest(using proxy: MapProxy?) {
        guard MapHomePlaybackCameraPolicy.allowsInitialFocus(
            isPlaybackRunning: isDayPlaybackRunning
        ),
              mapViewportSize.width > 0,
              mapViewportSize.height > 0,
              !hasAppliedInitialMapFocus,
              initialLocationRequestTask == nil else { return }
        initialLocationRequestTask = Task { @MainActor in
            defer { initialLocationRequestTask = nil }
            let isAvailable = await model.requestMapCurrentLocation(
                requiresFreshReading: true
            )
            guard !Task.isCancelled,
                  isAvailable,
                  !hasCancelledInitialLocationFocus,
                  !hasAppliedInitialMapFocus,
                  MapHomePlaybackCameraPolicy.allowsInitialFocus(
                      isPlaybackRunning: isDayPlaybackRunning
                  ),
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
        guard MapHomeUserTrackingPolicy.keepsFollowing(
            after: .pan,
            duringPlayback: isDayPlaybackRunning
        ) == false
        else { return }
        hasUserAdjustedMap = true
        if usesVectorRoadMap,
           let vectorMapViewport = vectorMapViewportStore.viewport {
            mapPosition = .region(vectorMapViewport.region)
        }
        hasCancelledInitialLocationFocus = true
        initialLocationRequestTask?.cancel()
        initialLocationRequestTask = nil
        currentLocationRequestTask?.cancel()
        currentLocationRequestTask = nil
        appleCenterCommand = nil
        setUserTrackingMode(.idle)
        isMapCenteredOnUser = false
    }

    @discardableResult
    private func updateUserCenterState(using proxy: MapProxy?) -> Bool {
        let point: CGPoint?
        if let proxy, let coordinate = displayedLocationCoordinate {
            point = proxy.convert(coordinate, to: .named("mapHomeViewport"))
        } else {
            point = vectorMapViewportStore.viewport?
                .markerPoints[vectorDisplayedMarkerID]
        }
        return updateUserCenterState(locationPoint: point)
    }

    @discardableResult
    private func updateUserCenterState(locationPoint: CGPoint?) -> Bool {
        let nextValue = locationPoint.map {
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

    private func applyMapCameraFrame(
        _ frame: MapHomeCameraFrame,
        using proxy: MapProxy
    ) {
        let locationPoint = displayedLocationCoordinate.flatMap {
            proxy.convert($0, to: .named("mapHomeViewport"))
        }
        applyMapCameraFrame(frame, locationPoint: locationPoint)
    }

    private func applyMapCameraFrame(
        _ frame: MapHomeCameraFrame,
        locationPoint: CGPoint?
    ) {
        if visibleMapCamera != frame.camera {
            visibleMapCamera = frame.camera
        }
        if visibleMapCenter.latitude != frame.centerLatitude
            || visibleMapCenter.longitude != frame.centerLongitude {
            visibleMapCenter = frame.center
        }
        updateVisibleMapSpan(frame.span)
        let isCentered = updateUserCenterState(locationPoint: locationPoint)
        if userTrackingMode == .locating, isCentered {
            setUserTrackingMode(.following)
        }
        if let level = sharedZoomLevel(for: frame.span),
           abs(level - sharedZoomLevel) > 0.02 {
            sharedZoomLevel = level
        }
    }

    private func submitDisplayedStickmanViewportPoint(_ point: CGPoint) {
        guard let rendered = stickmanViewportProjection.submit(
            point,
            nowUptime: ProcessInfo.processInfo.systemUptime
        ) else { return }
        displayedStickmanViewportPoint = rendered
    }

    private func finishDisplayedStickmanViewportProjection() {
        guard let rendered = stickmanViewportProjection.finish(
            nowUptime: ProcessInfo.processInfo.systemUptime
        ) else { return }
        displayedStickmanViewportPoint = rendered
    }

    private func flushMapCameraFrame(using proxy: MapProxy) {
        guard let frame = mapCameraFrameProjection.finish(
            nowUptime: ProcessInfo.processInfo.systemUptime
        ) else { return }
        applyMapCameraFrame(frame, using: proxy)
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
    private struct DuplicateKey: Hashable {
        let categoryID: String
        let title: String
        let behavior: String?
        let startMinute: Int
        let endMinute: Int
    }

    private struct Candidate {
        let detail: MapHomeSectionDetail
        let priority: Int
        let tieBreak: String

        var key: DuplicateKey {
            DuplicateKey(
                categoryID: detail.categoryID,
                title: detail.title,
                behavior: detail.behavior,
                startMinute: detail.startMinute,
                endMinute: detail.endMinute
            )
        }
    }

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
        var candidates = actuals.compactMap { actual -> Candidate? in
            guard !majorSourceIDs.contains(actual.id),
                  let clipped = actual.span(asOf: asOf).intersection(with: segmentSpan),
                  clipped.start < dayEnd,
                  clipped.end > dayStart
            else { return nil }
            let minutes = clippedMinutes(clipped, dayStart: dayStart)
            let detail = MapHomeSectionDetail(
                    id: actual.id,
                    title: actual.title,
                    categoryID: RecordAnalysisCategoryPolicy.categoryID(for: actual),
                    behavior: actual.behavior,
                    startMinute: minutes.start,
                    endMinute: minutes.end
            )
            return Candidate(
                detail: detail,
                priority: actualPriority(actual),
                tieBreak: "actual|\(actual.source.rawValue)|\(actual.id.uuidString)"
            )
        }
        candidates.append(contentsOf: travel.compactMap { item -> Candidate? in
            guard !majorSourceIDs.contains(item.id),
                  let clipped = item.span.intersection(with: segmentSpan),
                  clipped.start < dayEnd,
                  clipped.end > dayStart
            else { return nil }
            let minutes = clippedMinutes(clipped, dayStart: dayStart)
            let detail = MapHomeSectionDetail(
                    id: item.id,
                    title: "\(MovementPresentation.title(for: item.mode)) 탑승",
                    categoryID: "movement",
                    behavior: item.mode.rawValue,
                    startMinute: minutes.start,
                    endMinute: minutes.end
            )
            return Candidate(
                detail: detail,
                priority: 0,
                tieBreak: "travel|\(item.mode.rawValue)|\(item.id.uuidString)"
            )
        })

        var selected: [DuplicateKey: Candidate] = [:]
        for candidate in candidates {
            guard let current = selected[candidate.key] else {
                selected[candidate.key] = candidate
                continue
            }
            if isPreferred(candidate, over: current) {
                selected[candidate.key] = candidate
            }
        }
        return selected.values.map(\.detail).sorted { lhs, rhs in
            if lhs.startMinute != rhs.startMinute {
                return lhs.startMinute < rhs.startMinute
            }
            if lhs.endMinute != rhs.endMinute {
                return lhs.endMinute < rhs.endMinute
            }
            if lhs.categoryID != rhs.categoryID {
                return lhs.categoryID < rhs.categoryID
            }
            if lhs.title != rhs.title {
                return lhs.title < rhs.title
            }
            if lhs.behavior != rhs.behavior {
                return (lhs.behavior ?? "") < (rhs.behavior ?? "")
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private static func actualPriority(_ actual: ActualRecord) -> Int {
        if actual.manuallyCorrected || actual.source == .manual {
            return 4
        }
        switch actual.source {
        case .healthKit, .appleWatch:
            return 3
        case .motion:
            return 2
        case .location:
            return 1
        default:
            return 0
        }
    }

    private static func isPreferred(
        _ candidate: Candidate,
        over current: Candidate
    ) -> Bool {
        if candidate.priority != current.priority {
            return candidate.priority > current.priority
        }
        return candidate.tieBreak < current.tieBreak
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

enum MapHomeSectionEditLayout {
    static let boundaryHandleHeight: CGFloat = 8

    static func handleCenterY(
        boundaryY: CGFloat,
        frameHeight: CGFloat
    ) -> CGFloat {
        let halfHeight = boundaryHandleHeight / 2
        return min(
            max(halfHeight, boundaryY + halfHeight),
            max(halfHeight, frameHeight - halfHeight)
        )
    }
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
    @State private var lastDetailDragRenderUptime: TimeInterval = 0
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
                ?? MapHomePastelPalette.hex("movement")
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

    private var editHeader: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Text(language.text("닫기", "Close"))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.tpReferenceRose)
                    .padding(.horizontal, 15)
                    .frame(minHeight: 38)
                    .background(
                        Color.tpReferenceRose.opacity(0.10),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            Spacer()
            Text(language.text("행동 구간 편집", "Edit activity section"))
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer()
            Button {
                save()
            } label: {
                Text(language.text("저장", "Save"))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 15)
                    .frame(minHeight: 38)
                    .background(
                        Color.tpReferenceBlue,
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            .disabled(isSaving || startMinute >= endMinute)
            .opacity(isSaving || startMinute >= endMinute ? 0.45 : 1)
        }
        .frame(minHeight: 44)
        .background(Color.tpBackground)
        .zIndex(1)
    }

    var body: some View {
        VStack(spacing: 14) {
            editHeader

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
                let sliceTint = Color(hex: selectedPreviewCategory.hex)
                let isSlicing = cutMinute != nil
                Button {
                    if !isSlicing {
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
                        systemImage: isSlicing
                            ? "xmark.circle.fill"
                            : "rectangle.split.1x2"
                    )
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(isSlicing ? Color.white : sliceTint)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 36)
                    .background(
                        isSlicing ? sliceTint : sliceTint.opacity(0.10),
                        in: Capsule()
                    )
                    .overlay {
                        Capsule()
                            .stroke(sliceTint.opacity(isSlicing ? 0 : 0.55))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .accessibilityLabel(
                    isSlicing
                        ? language.text("대분류 자르기 취소", "Cancel category slice")
                        : language.text("대분류 자르기", "Slice category")
                )

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
            .padding(.horizontal, 6)
            .padding(.bottom, 6)

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
                MapHomeStickmanGlyph(
                    action: category.stickmanAction,
                    size: 22
                )
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
                if draggingDetailID != detail.id {
                    draggingDetailID = detail.id
                }
                guard TimelineInteractionFrameGate.shouldRender(
                    lastUptime: &lastDetailDragRenderUptime,
                    nowUptime: ProcessInfo.processInfo.systemUptime
                ) else { return }
                if detailDragTranslation != value.translation.width {
                    detailDragTranslation = value.translation.width
                }
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
                lastDetailDragRenderUptime = 0
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
                ?? MapHomePastelPalette.hex(selection.segment.categoryID)
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
                    MapHomeStickmanGlyph(
                        action: piece.category.stickmanAction,
                        size: 22
                    )
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
            .frame(
                width: width - 20,
                height: MapHomeSectionEditLayout.boundaryHandleHeight
            )
            .contentShape(Rectangle().inset(by: -12))
            .position(
                x: x + width / 2,
                y: MapHomeSectionEditLayout.handleCenterY(
                    boundaryY: yPosition(
                        isStart ? startMinute : endMinute,
                        height: height
                    ),
                    frameHeight: height
                )
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
                    if let latestBackupText {
                        Text(language.text(
                            "최근 백업: \(latestBackupText)",
                            "Last backup: \(latestBackupText)"
                        ))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.tpReferenceBlue)
                    }
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

    private var latestBackupText: String? {
        guard let date = security.latestSuccessfulBackupDate else { return nil }
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private struct MapHomeLocationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let destination: MapHomeLocationDestination
    let language: MapHomeLanguage
    let onSaved: () -> Void
    @State private var showsDeleteConfirmation = false
    @State private var floor = 1

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
                        Text(
                            language.text("현재 저장 상태", "Saved")
                                + " · "
                                + FloorLabel.korean(place.floor ?? 1)
                        )
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

            Stepper(value: $floor, in: FloorCalibrationPrompt.range) {
                HStack {
                    Text(language.text("저장할 층수", "Floor to save"))
                    Spacer()
                    Text(FloorLabel.korean(floor))
                        .fontWeight(.bold)
                        .foregroundStyle(destination.tint)
                }
            }
            .tint(destination.tint)

            Button {
                guard let place else { return }
                model.setFrequentPlaceToCurrentLocation(place.id, floor: floor)
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
        .onAppear {
            floor = place?.floor ?? 1
        }
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

enum MapHomeExpectedRoutePlaybackMath {
    static func progress(
        at date: Date,
        departureDate: Date,
        arrivalDate: Date
    ) -> Double? {
        guard departureDate <= date,
              date <= arrivalDate,
              arrivalDate > departureDate else { return nil }
        return min(
            max(date.timeIntervalSince(departureDate) / arrivalDate.timeIntervalSince(departureDate), 0),
            1
        )
    }

    static func coordinate(
        at date: Date,
        departureDate: Date,
        arrivalDate: Date,
        coordinates: [CLLocationCoordinate2D]
    ) -> CLLocationCoordinate2D? {
        guard coordinates.count >= 2,
              departureDate <= date,
              date <= arrivalDate,
              arrivalDate > departureDate else { return nil }

        let lengths = zip(coordinates, coordinates.dropFirst()).map {
            CLLocation(latitude: $0.0.latitude, longitude: $0.0.longitude)
                .distance(from: CLLocation(latitude: $0.1.latitude, longitude: $0.1.longitude))
        }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return coordinates.first }

        guard let fraction = progress(
            at: date,
            departureDate: departureDate,
            arrivalDate: arrivalDate
        ) else { return nil }
        let target = total * fraction
        var traversed = 0.0
        for (index, length) in lengths.enumerated() {
            guard length > 0 else { continue }
            let next = coordinates[index + 1]
            if traversed + length >= target {
                let ratio = min(max((target - traversed) / length, 0), 1)
                return CLLocationCoordinate2D(
                    latitude: coordinates[index].latitude
                        + (next.latitude - coordinates[index].latitude) * ratio,
                    longitude: coordinates[index].longitude
                        + (next.longitude - coordinates[index].longitude) * ratio
                )
            }
            traversed += length
        }
        return coordinates.last
    }
}

enum MapHomeRouteTimelinePlaybackMath {
    static func coordinate(
        at date: Date,
        in segments: [RouteTimelineSegment]
    ) -> GeoPoint? {
        guard let segment = segment(at: date, in: segments) else { return nil }
        let progress = progress(at: date, in: segment)
        return interpolate(segment.coordinates, progress: progress)
    }

    static func progress(
        at date: Date,
        in segments: [RouteTimelineSegment]
    ) -> Double? {
        guard let segment = segment(at: date, in: segments) else { return nil }
        return progress(at: date, in: segment)
    }

    private static func segment(
        at date: Date,
        in segments: [RouteTimelineSegment]
    ) -> RouteTimelineSegment? {
        let usable = segments.filter {
            $0.end > $0.start && $0.coordinates.count >= 2
        }
        guard let first = usable.first, let last = usable.last else { return nil }
        if date < first.start { return first }
        if date > last.end { return last }
        return usable.first { $0.start <= date && date <= $0.end }
    }

    private static func progress(
        at date: Date,
        in segment: RouteTimelineSegment
    ) -> Double {
        min(
            max(date.timeIntervalSince(segment.start) / segment.end.timeIntervalSince(segment.start), 0),
            1
        )
    }

    private static func interpolate(
        _ points: [GeoPoint],
        progress: Double
    ) -> GeoPoint? {
        guard let first = points.first else { return nil }
        guard points.count > 1 else { return first }
        let lengths = zip(points, points.dropFirst()).map { distance($0.0, $0.1) }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return first }
        let target = total * min(max(progress, 0), 1)
        var traversed = 0.0
        for (index, length) in lengths.enumerated() where length > 0 {
            if traversed + length >= target {
                let next = points[index + 1]
                let ratio = min(max((target - traversed) / length, 0), 1)
                return GeoPoint(
                    latitude: blend(first: points[index].latitude, second: next.latitude, ratio: ratio),
                    longitude: blend(first: points[index].longitude, second: next.longitude, ratio: ratio),
                    altitude: blend(first: points[index].altitude, second: next.altitude, ratio: ratio),
                    horizontalAccuracy: blend(first: points[index].horizontalAccuracy, second: next.horizontalAccuracy, ratio: ratio),
                    verticalAccuracy: blend(first: points[index].verticalAccuracy, second: next.verticalAccuracy, ratio: ratio)
                )
            }
            traversed += length
        }
        return points.last
    }

    private static func blend(first: Double, second: Double, ratio: Double) -> Double {
        guard first.isFinite, second.isFinite else {
            return first.isFinite ? first : second
        }
        return first + (second - first) * ratio
    }

    private static func distance(_ first: GeoPoint, _ second: GeoPoint) -> Double {
        CLLocation(latitude: first.latitude, longitude: first.longitude)
            .distance(from: CLLocation(latitude: second.latitude, longitude: second.longitude))
    }
}

private struct MapHomeExpectedRouteOverlay: Identifiable {
    let id: UUID
    let mode: TravelMode
    let departureDate: Date
    let arrivalDate: Date
    let coordinates: [CLLocationCoordinate2D]

    func coordinate(at date: Date) -> CLLocationCoordinate2D? {
        MapHomeExpectedRoutePlaybackMath.coordinate(
            at: date,
            departureDate: departureDate,
            arrivalDate: arrivalDate,
            coordinates: coordinates
        )
    }

    func visible(through cutoff: Date) -> Self? {
        guard cutoff > departureDate, coordinates.count >= 2 else { return nil }
        guard cutoff < arrivalDate else { return self }
        let duration = arrivalDate.timeIntervalSince(departureDate)
        guard duration > 0 else { return self }
        let fraction = min(
            max(cutoff.timeIntervalSince(departureDate) / duration, 0),
            1
        )
        let visibleCoordinates = Self.prefixByDistance(
            coordinates,
            fraction: fraction
        )
        return Self(
            id: id,
            mode: mode,
            departureDate: departureDate,
            arrivalDate: arrivalDate,
            coordinates: visibleCoordinates
        )
    }

    fileprivate static func prefixByDistance(
        _ coordinates: [CLLocationCoordinate2D],
        fraction: Double
    ) -> [CLLocationCoordinate2D] {
        guard coordinates.count >= 2 else { return coordinates }
        let lengths = zip(coordinates, coordinates.dropFirst()).map {
            CLLocation(
                latitude: $0.0.latitude,
                longitude: $0.0.longitude
            ).distance(from: CLLocation(
                latitude: $0.1.latitude,
                longitude: $0.1.longitude
            ))
        }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return Array(coordinates.prefix(2)) }

        let target = total * min(max(fraction, 0), 1)
        var traversed = 0.0
        var result = [coordinates[0]]
        for (index, length) in lengths.enumerated() {
            let next = coordinates[index + 1]
            guard length > 0 else { continue }
            if traversed + length >= target {
                let ratio = min(
                    max((target - traversed) / length, 0),
                    1
                )
                result.append(
                    CLLocationCoordinate2D(
                        latitude: coordinates[index].latitude
                            + (next.latitude - coordinates[index].latitude) * ratio,
                        longitude: coordinates[index].longitude
                            + (next.longitude - coordinates[index].longitude) * ratio
                    )
                )
                return result.count >= 2
                    ? result
                    : Array(coordinates.prefix(2))
            }
            result.append(next)
            traversed += length
        }
        return Array(coordinates.suffix(2))
    }
}

private struct MapHomeWBSGeneratedRouteOverlay: Identifiable {
    let id: String
    let mode: TravelMode?
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
        return Self(
            id: id,
            mode: mode,
            departureDate: departureDate,
            arrivalDate: arrivalDate,
            coordinates: MapHomeExpectedRouteOverlay.prefixByDistance(
                coordinates,
                fraction: fraction
            )
        )
    }
}

private struct MapHomeForecastRouteState {
    let expected: [MapHomeExpectedRouteOverlay]
    let generated: [MapHomeWBSGeneratedRouteOverlay]
}

struct MapHomeSubwayRouteOverlay: Identifiable {
    let id: UUID
    let coordinates: [CLLocationCoordinate2D]
    let estimated: Bool
}

enum MapHomeSubwayRouteOverlayEngine {
    private static let readingMargin: TimeInterval = 2 * 60

    static func overlays(
        travel: [TravelSegment],
        readings: [SensorReading],
        day: TimeSpan,
        through cutoff: Date
    ) -> [MapHomeSubwayRouteOverlay] {
        let subwaySegments = travel
            .filter { $0.mode == .subway && $0.span.intersection(with: day) != nil }
            .sorted { $0.span.start < $1.span.start }
        let confirmedSpans = subwaySegments.compactMap { segment -> TimeSpan? in
            guard segment.isConfirmed,
                  let route = segment.subwayRoute,
                  SubwayStationCatalog.isValid(route) else { return nil }
            return segment.span
        }

        return subwaySegments.compactMap { segment in
            if segment.isConfirmed,
               let route = segment.subwayRoute,
               SubwayStationCatalog.isValid(route) {
                let points = RouteTimelineDataEngine.confirmedSubwayCoordinates(
                    for: segment,
                    through: cutoff
                )
                return makeOverlay(
                    id: segment.id,
                    points: points,
                    estimated: false
                )
            }

            // A confirmed route is authoritative for an overlapping interval;
            // do not draw an inferred path on top of it.
            guard !confirmedSpans.contains(where: {
                $0.intersection(with: segment.span) != nil
            }) else { return nil }
            if let route = segment.subwayRoute,
               SubwayStationCatalog.isValid(route) {
                let points = visibleCoordinates(
                    route.coordinates,
                    start: segment.span.start,
                    end: segment.span.end,
                    through: cutoff
                )
                return makeOverlay(
                    id: segment.id,
                    points: points,
                    estimated: true
                )
            }
            let sourceReadings = readings.filter {
                $0.timestamp >= segment.span.start.addingTimeInterval(-readingMargin)
                    && $0.timestamp <= segment.span.end.addingTimeInterval(readingMargin)
            }
            guard hasSupportingEvidence(in: sourceReadings) else { return nil }
            let preciseReadings = sourceReadings.filter {
                $0.locationFixQuality != .approximate
            }
            let trajectory = SubwayStationCatalog.coordinateTrajectory(
                from: preciseReadings
            ) ?? SubwayStationCatalog.sparseEndpointTrajectory(
                from: preciseReadings
            )
            let route = trajectory?.route
                ?? SubwayStationCatalog.route(for: sourceReadings)
            guard let route,
                  SubwayStationCatalog.isValid(route) else { return nil }
            let points = visibleCoordinates(
                route.coordinates,
                start: segment.span.start,
                end: segment.span.end,
                through: cutoff
            )
            return makeOverlay(
                id: segment.id,
                points: points,
                estimated: true
            )
        }
    }

    private static func hasSupportingEvidence(
        in readings: [SensorReading]
    ) -> Bool {
        guard !readings.isEmpty else { return false }
        let railRatio = Double(readings.filter(\.matchesRailRoute).count)
            / Double(readings.count)
        if railRatio >= 0.25 {
            return true
        }
        if SubwayWiFiSSID.hasContinuousEvidence(
            readings.map(\.connectedWiFiSSID)
        ) {
            return true
        }
        let stationNames = Set(
            readings.compactMap(\.nearbyStationName).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "역", with: "")
            }
        )
        return stationNames.count >= 2
            || readings.filter(\.nearbyStation).count >= 3
    }

    private static func visibleCoordinates(
        _ points: [GeoPoint],
        start: Date,
        end: Date,
        through cutoff: Date
    ) -> [GeoPoint] {
        guard points.count >= 2, cutoff > start else { return [] }
        guard cutoff < end, end > start else { return points }
        let fraction = min(
            max(cutoff.timeIntervalSince(start) / end.timeIntervalSince(start), 0),
            1
        )
        let lastIndex = max(
            1,
            min(points.count - 1, Int(ceil(Double(points.count - 1) * fraction)))
        )
        return Array(points.prefix(lastIndex + 1))
    }

    private static func makeOverlay(
        id: UUID,
        points: [GeoPoint],
        estimated: Bool
    ) -> MapHomeSubwayRouteOverlay? {
        let coordinates = points.compactMap { point -> CLLocationCoordinate2D? in
            guard isValid(point) else { return nil }
            return CLLocationCoordinate2D(
                latitude: point.latitude,
                longitude: point.longitude
            )
        }
        guard coordinates.count >= 2 else { return nil }
        return MapHomeSubwayRouteOverlay(
            id: id,
            coordinates: coordinates,
            estimated: estimated
        )
    }

    private static func isValid(_ point: GeoPoint) -> Bool {
        point.latitude.isFinite
            && point.longitude.isFinite
            && (-90...90).contains(point.latitude)
            && (-180...180).contains(point.longitude)
    }
}

private struct MapHomeTimelineRouteOverlay: Identifiable {
    let id: String
    let categoryID: String
    let opacity: Double
    let speedMetersPerSecond: Double?
    let coordinates: [CLLocationCoordinate2D]
}

private struct MapHomeTemporaryLocationAnnotation: Identifiable {
    let id: UUID
    let stationName: String
    let timestamp: Date
    let point: GeoPoint
    let reason: String

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
    }
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

private struct MapHomeTransitBoardingCandidatePin: View {
    let name: String
    let kind: UserTransitLocationKind

    var body: some View {
        VStack(spacing: 4) {
            MapHomeMarkerLabel(title: name, color: Color.tpReferenceGold)
            Text("?")
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.tpReferenceGold, in: Circle())
                .overlay { Circle().stroke(.white, lineWidth: 1.5) }
                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
        }
        .accessibilityLabel("\(name), \(kind.title) 탑승 확인")
    }
}

private struct MapHomeVectorViewportOverlay<Content: View>: View {
    let store: MapHomeVectorViewportStore
    let content: (MapHomeVectorViewport?, CGPoint?) -> Content

    var body: some View {
        content(store.viewport, store.stickmanPoint)
            .clipped()
    }
}

private struct MapHomeProjectedAnnotation<Content: View>: View {
    let point: CGPoint
    let anchor: UnitPoint
    let content: Content
    @State private var contentSize = CGSize.zero

    init(
        point: CGPoint,
        anchor: UnitPoint,
        @ViewBuilder content: () -> Content
    ) {
        self.point = point
        self.anchor = anchor
        self.content = content()
    }

    var body: some View {
        content
            .onGeometryChange(
                for: CGSize.self,
                of: { $0.size },
                action: { size in
                    guard contentSize != size else { return }
                    contentSize = size
                }
            )
            .position(
                x: point.x + (0.5 - anchor.x) * contentSize.width,
                y: point.y + (0.5 - anchor.y) * contentSize.height
            )
    }
}

private struct MapHomeVectorPlayerMarker: View {
    let heading: CLLocationDirection
    let backgroundHex: String

    var body: some View {
        MapHomeVectorPlayerTriangle()
            .fill(Color(hex: MapHomeVectorStyle.routeHex))
            .frame(width: 13, height: 17)
            .overlay {
                MapHomeVectorPlayerTriangle()
                    .stroke(Color(hex: backgroundHex), lineWidth: 1.5)
            }
            .shadow(color: .black.opacity(0.32), radius: 2, y: 1)
            .rotationEffect(.degrees(heading))
    }
}

private struct MapHomeVectorPlayerTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY * 0.78))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct MapHomeLocationButtonIcon: View {
    let state: MapHomeLocationButtonState
    let showsGPSDot: Bool

    private let targetColor = Color.tpPastelSky
    private let dotColor = Color.tpPastelRose

    var body: some View {
        ZStack {
            Image(systemName: "scope")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(targetColor)

            if showsGPSDot {
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
            let color = Color.tpPastelRose

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
            Circle().stroke(Color.tpPastelRose.opacity(0.35), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.18), radius: 3, y: 2)
        .accessibilityHidden(true)
    }
}

private struct MapHomePanGestureObserver: UIViewRepresentable {
    let onSingleFingerPanBegan: () -> Void
    let onSingleFingerPanEnded: () -> Void
    let onLongPress: (CLLocationCoordinate2D) -> Void

    func makeUIView(context: Context) -> ObservationView {
        let view = ObservationView()
        view.onSingleFingerPanBegan = onSingleFingerPanBegan
        view.onSingleFingerPanEnded = onSingleFingerPanEnded
        view.onLongPress = onLongPress
        return view
    }

    func updateUIView(_ view: ObservationView, context: Context) {
        view.onSingleFingerPanBegan = onSingleFingerPanBegan
        view.onSingleFingerPanEnded = onSingleFingerPanEnded
        view.onLongPress = onLongPress
    }

    static func dismantleUIView(_ view: ObservationView, coordinator: ()) {
        view.detach()
    }

    final class ObservationView: UIView {
        var onSingleFingerPanBegan: (() -> Void)?
        var onSingleFingerPanEnded: (() -> Void)?
        var onLongPress: ((CLLocationCoordinate2D) -> Void)?
        private weak var attachedMapView: MKMapView?
        private var observedPanGestures: [UIPanGestureRecognizer] = []
        private var longPressGesture: UILongPressGestureRecognizer?
        private var notifiedPanGestureIDs = Set<ObjectIdentifier>()
        private var attachmentRetryWorkItem: DispatchWorkItem?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            scheduleAttachmentRetries()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            attachToVisibleMapIfNeeded()
        }

        func attachToVisibleMapIfNeeded() {
            guard let window else {
                detach()
                return
            }
            if let attachedMapView,
               attachedMapView.window === window,
               !observedPanGestures.isEmpty,
               longPressGesture?.view === attachedMapView {
                return
            }
            let ownFrame = convert(bounds, to: window)
            let mapView = mapViews(in: window).max { lhs, rhs in
                overlapArea(lhs, with: ownFrame, in: window)
                    < overlapArea(rhs, with: ownFrame, in: window)
            }
            guard let mapView else { return }
            let panGestures = panGestures(in: mapView)
            guard !panGestures.isEmpty else { return }

            let currentIDs = Set(observedPanGestures.map(ObjectIdentifier.init))
            let nextIDs = Set(panGestures.map(ObjectIdentifier.init))
            guard currentIDs != nextIDs else { return }

            detachObservedPanGestures()
            attachedMapView = mapView
            observedPanGestures = panGestures
            for panGesture in panGestures {
                panGesture.addTarget(self, action: #selector(handlePan(_:)))
            }
            let longPress = UILongPressGestureRecognizer(
                target: self,
                action: #selector(handleLongPress(_:))
            )
            longPress.minimumPressDuration = 0.55
            longPress.allowableMovement = 12
            longPress.numberOfTouchesRequired = 1
            longPress.cancelsTouchesInView = false
            longPress.delegate = self
            mapView.addGestureRecognizer(longPress)
            longPressGesture = longPress
            attachmentRetryWorkItem?.cancel()
            attachmentRetryWorkItem = nil
        }

        func detach() {
            attachmentRetryWorkItem?.cancel()
            attachmentRetryWorkItem = nil
            detachObservedPanGestures()
        }

        private func detachObservedPanGestures() {
            for panGesture in observedPanGestures {
                panGesture.removeTarget(
                    self,
                    action: #selector(handlePan(_:))
                )
            }
            if let longPressGesture {
                longPressGesture.view?.removeGestureRecognizer(longPressGesture)
            }
            longPressGesture = nil
            observedPanGestures = []
            attachedMapView = nil
            notifiedPanGestureIDs.removeAll()
        }

        private func scheduleAttachmentRetries() {
            attachmentRetryWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.attachToVisibleMapIfNeeded()
            }
            attachmentRetryWorkItem = workItem
            for delay in [0.0, 0.05, 0.2, 0.5, 1.0] {
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + delay,
                    execute: workItem
                )
            }
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            let gestureID = ObjectIdentifier(gesture)
            if MapHomeUserTrackingPolicy.isSingleFingerPanStart(
                state: gesture.state,
                numberOfTouches: gesture.numberOfTouches
            ) {
                guard notifiedPanGestureIDs.insert(gestureID).inserted else {
                    return
                }
                onSingleFingerPanBegan?()
            } else if gesture.state == .ended
                        || gesture.state == .cancelled
                        || gesture.state == .failed {
                notifiedPanGestureIDs.remove(gestureID)
                onSingleFingerPanEnded?()
            }
        }

        @objc private func handleLongPress(
            _ gesture: UILongPressGestureRecognizer
        ) {
            guard gesture.state == .began,
                  let mapView = attachedMapView else { return }
            onLongPress?(
                mapView.convert(
                    gesture.location(in: mapView),
                    toCoordinateFrom: mapView
                )
            )
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

        private func panGestures(in view: UIView) -> [UIPanGestureRecognizer] {
            var result = view.gestureRecognizers?.compactMap {
                $0 as? UIPanGestureRecognizer
            } ?? []
            for child in view.subviews {
                result.append(contentsOf: panGestures(in: child))
            }
            var seen = Set<ObjectIdentifier>()
            return result.filter { seen.insert(ObjectIdentifier($0)).inserted }
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

extension MapHomePanGestureObserver.ObservationView: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
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

private struct MapHomeTransitBoardingCandidateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let candidate: TransitBoardingCandidate
    let language: MapHomeLanguage

    private var dwellText: String {
        let minutes = max(3, Int((candidate.dwellDuration / 60).rounded(.down)))
        return language.text("\(minutes)분 체류 후보", "Stayed \(minutes) minutes")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: candidate.kind.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.tpReferenceGold)
                    .frame(width: 38, height: 38)
                    .background(
                        Color.tpReferenceGold.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.name)
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    Text(
                        language.text(
                            "\(candidate.kind.title) · \(dwellText)",
                            "\(candidate.kind.englishTitle) · \(dwellText)"
                        )
                    )
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            Button {
                model.confirmTransitBoarding(candidate)
                dismiss()
            } label: {
                Label(
                    language.text(
                        "\(MovementPresentation.title(for: candidate.mode)) 탑승",
                        "Board \(MovementPresentation.englishTitle(for: candidate.mode))"
                    ),
                    systemImage: candidate.mode == .subway
                        ? "tram.fill"
                        : candidate.mode == .bus
                            ? "bus.fill"
                            : MovementPresentation.symbol(for: candidate.mode)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.tpReferenceBlue)

            Button(role: .destructive) {
                Task { @MainActor in
                    await model.deleteTransitBoardingCandidate(candidate)
                    dismiss()
                }
            } label: {
                Label(
                    language.text("이 후보 삭제", "Delete this candidate"),
                    systemImage: "trash"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)

            Spacer(minLength: 0)
        }
        .padding(20)
        .background(Color.tpSurface)
    }
}

private enum MapHomeStickerEditorTarget: Identifiable {
    case sticker(UUID)
    case memo(UUID)

    var id: String {
        switch self {
        case .sticker(let id): "sticker-\(id.uuidString)"
        case .memo(let id): "memo-\(id.uuidString)"
        }
    }
}

private struct MapHomeMapStickerMarker: View {
    let sticker: MapSticker

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: sticker.systemImage)
                .font(.system(size: 15, weight: .bold))
            Text(sticker.title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(Color.tpInk)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            Color(hex: sticker.colorHex).opacity(0.92),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.white.opacity(0.9), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        .fixedSize()
    }
}

private struct MapHomeMapMemoMarker: View {
    let memo: ActionMemo

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "note.text")
                .font(.system(size: 12, weight: .bold))
            Text(memo.text)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .frame(maxWidth: 118, alignment: .leading)
        }
        .foregroundStyle(Color.tpInk)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            Color.tpPastelButter.opacity(0.94),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.tpReferenceGold.opacity(0.72), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.10), radius: 4, y: 2)
        .fixedSize()
    }
}

private struct MapHomeStickerEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let target: MapHomeStickerEditorTarget
    let language: MapHomeLanguage

    @State private var title = ""
    @State private var memoText = ""
    @State private var memoKind: MemoKind = .idea
    @State private var placement: MapStickerPlacement = .map
    @State private var systemImage = "star.fill"
    @State private var colorHex = "#F28FA9"
    @State private var latitudeText = ""
    @State private var longitudeText = ""
    @State private var occurredAt = Date()
    @State private var isDeleteConfirmationPresented = false

    private let symbols = [
        "star.fill", "heart.fill", "flag.fill", "pin.fill",
        "sparkles", "leaf.fill"
    ]
    private let colors = [
        "#F28FA9", "#A9CFF0", "#8FD9C5", "#F2D58D",
        "#C2B4E9", "#F2B18D"
    ]

    private var isSticker: Bool {
        if case .sticker = target { return true }
        return false
    }

    private var canSave: Bool {
        let cleanTitle = (isSticker ? title : memoText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return false }
        if isSticker && placement == .schedule { return true }
        return editedPoint != nil
    }

    private var editedPoint: GeoPoint? {
        guard let latitude = Double(latitudeText),
              let longitude = Double(longitudeText),
              (-90...90).contains(latitude),
              (-180...180).contains(longitude) else {
            return nil
        }
        return GeoPoint(
            latitude: latitude,
            longitude: longitude,
            altitude: 0,
            horizontalAccuracy: 0,
            verticalAccuracy: 0
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                if isSticker {
                    stickerFields
                } else {
                    memoFields
                }

                Section {
                    Button(language.text("삭제", "Delete"), role: .destructive) {
                        isDeleteConfirmationPresented = true
                    }
                }
            }
            .navigationTitle(
                language.text(
                    isSticker ? "메모 스티커 수정" : "지도 메모 수정",
                    isSticker ? "Edit memo sticker" : "Edit map memo"
                )
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.text("취소", "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.text("저장", "Save")) { save() }
                        .disabled(!canSave)
                }
            }
            .confirmationDialog(
                language.text("이 항목을 삭제할까요?", "Delete this item?"),
                isPresented: $isDeleteConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button(language.text("삭제", "Delete"), role: .destructive) {
                    delete()
                }
                Button(language.text("취소", "Cancel"), role: .cancel) {}
            }
            .onAppear(perform: load)
        }
    }

    @ViewBuilder
    private var stickerFields: some View {
        Section(language.text("메모 스티커", "Memo sticker")) {
            TextField(language.text("제목", "Title"), text: $title)
            TextField(
                language.text("메모 내용", "Memo text"),
                text: $memoText,
                axis: .vertical
            )
            Picker(
                language.text("추가 위치", "Placement"),
                selection: $placement
            ) {
                Text(language.text("지도", "Map")).tag(MapStickerPlacement.map)
                Text(language.text("일정", "Schedule")).tag(MapStickerPlacement.schedule)
            }
            DatePicker(
                language.text("시간", "Time"),
                selection: $occurredAt,
                displayedComponents: [.date, .hourAndMinute]
            )
            symbolPicker
            colorPicker
            if placement == .map {
                coordinateFields
            }
        }
    }

    @ViewBuilder
    private var memoFields: some View {
        Section(language.text("메모", "Memo")) {
            TextField(
                language.text("메모 내용", "Memo text"),
                text: $memoText,
                axis: .vertical
            )
            Picker(language.text("종류", "Kind"), selection: $memoKind) {
                ForEach(MemoKind.allCases, id: \.rawValue) { kind in
                    Text(memoKindTitle(kind)).tag(kind)
                }
            }
            DatePicker(
                language.text("시간", "Time"),
                selection: $occurredAt,
                displayedComponents: [.date, .hourAndMinute]
            )
            coordinateFields
        }
    }

    private var coordinateFields: some View {
        Group {
            TextField("Latitude", text: $latitudeText)
                .keyboardType(.decimalPad)
            TextField("Longitude", text: $longitudeText)
                .keyboardType(.decimalPad)
        }
    }

    private var symbolPicker: some View {
        HStack(spacing: 9) {
            ForEach(symbols, id: \.self) { symbol in
                Button {
                    systemImage = symbol
                } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color(hex: colorHex))
                        .frame(width: 34, height: 34)
                        .background(
                            systemImage == symbol
                                ? Color(hex: colorHex).opacity(0.18)
                                : Color.black.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var colorPicker: some View {
        HStack(spacing: 10) {
            ForEach(colors, id: \.self) { color in
                Button {
                    colorHex = color
                } label: {
                    Circle()
                        .fill(Color(hex: color))
                        .frame(width: 24, height: 24)
                        .overlay {
                            Circle()
                                .stroke(
                                    colorHex == color ? Color.tpInk : .white,
                                    lineWidth: colorHex == color ? 2 : 1
                                )
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func load() {
        switch target {
        case .sticker(let id):
            guard let sticker = model.snapshot.stickers.first(where: { $0.id == id }) else { return }
            title = sticker.title
            memoText = sticker.memo ?? ""
            placement = sticker.placement
            systemImage = sticker.systemImage
            colorHex = sticker.colorHex
            occurredAt = sticker.occurredAt
            if let point = sticker.point {
                latitudeText = String(format: "%.6f", point.latitude)
                longitudeText = String(format: "%.6f", point.longitude)
            }
        case .memo(let id):
            guard let memo = model.snapshot.memos.first(where: { $0.id == id }) else { return }
            memoText = memo.text
            memoKind = memo.kind
            occurredAt = memo.occurredAt
            if let point = memo.mapPoint {
                latitudeText = String(format: "%.6f", point.latitude)
                longitudeText = String(format: "%.6f", point.longitude)
            }
        }
    }

    private func save() {
        switch target {
        case .sticker(let id):
            let point = placement == .map ? editedPoint : nil
            guard model.updateMapSticker(
                id,
                title: title,
                memo: memoText,
                systemImage: systemImage,
                colorHex: colorHex,
                placement: placement,
                point: point,
                planID: model.snapshot.stickers.first(where: { $0.id == id })?.planID,
                occurredAt: occurredAt
            ) else { return }
        case .memo(let id):
            guard model.updateMapMemo(
                id,
                text: memoText,
                kind: memoKind,
                mapPoint: editedPoint,
                occurredAt: occurredAt
            ) else { return }
        }
        dismiss()
    }

    private func delete() {
        switch target {
        case .sticker(let id): model.deleteMapSticker(id)
        case .memo(let id): model.deleteMemo(id)
        }
        dismiss()
    }

    private func memoKindTitle(_ kind: MemoKind) -> String {
        switch kind {
        case .decision: language.text("결정", "Decision")
        case .idea: language.text("아이디어", "Idea")
        case .blocker: language.text("장애물", "Blocker")
        case .nextAction: language.text("다음 행동", "Next action")
        }
    }
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
        if let frequentPlace {
            let name = frequentPlace.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if frequentPlace.kind == .restaurant,
               name.isEmpty || name == "사용자 지점"
                    || name.caseInsensitiveCompare("User location") == .orderedSame {
                return "식당"
            }
            return name
        }
        return transitLocation?.name ?? ""
    }

    private var locationSubtitle: String {
        if let transitLocation {
            return language.text(
                transitLocation.kind.title,
                transitLocation.kind.englishTitle
            )
        }
        if frequentPlace?.kind == .restaurant {
            return language.text("등록 식당", "Restaurant")
        }
        return language.text("사용자 위치", "User location")
    }

    private var locationIcon: String {
        transitLocation?.kind.systemImage
            ?? frequentPlace?.kind.systemImage
            ?? FrequentPlaceKind.custom.systemImage
    }

    private var locationTint: Color {
        if let frequentPlace,
           let destination = MapHomeLocationDestination(placeKind: frequentPlace.kind) {
            return destination.tint
        }
        return transitLocation == nil
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
    @State private var floor = 1

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

            Stepper(value: $floor, in: FloorCalibrationPrompt.range) {
                HStack {
                    Text(language.text("저장할 층수", "Floor to save"))
                    Spacer()
                    Text(FloorLabel.korean(floor))
                        .fontWeight(.bold)
                        .foregroundStyle(Color.tpReferenceBlue)
                }
            }
            .tint(Color.tpReferenceBlue)

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
                                    kind.englishTitle
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
        if destination == .restaurant {
            let restaurantName = resolvedRestaurantName
            model.addRestaurant(name: restaurantName)
            if let place = model.settings.frequentPlaces.last(where: {
                $0.kind == .restaurant && $0.name == restaurantName
            }) {
                model.setFrequentPlaceLocation(
                    place.id,
                    latitude: latitude,
                    longitude: longitude,
                    floor: floor
                )
            }
        } else if let kind = destination.placeKind,
                  let place = model.settings.frequentPlaces.first(where: {
                      $0.kind == kind
                  }) {
            model.setFrequentPlaceLocation(
                place.id,
                latitude: latitude,
                longitude: longitude,
                floor: floor
            )
        } else if destination == .user {
            model.addCustomFrequentPlace(name: result.title)
            if let place = model.settings.frequentPlaces.last(where: {
                $0.kind == .custom && $0.name == result.title
            }) {
                model.setFrequentPlaceLocation(
                    place.id,
                    latitude: latitude,
                    longitude: longitude,
                    floor: floor
                )
            }
        }
        onSaved(nil)
    }

    private var resolvedRestaurantName: String {
        let title = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
              title != "사용자 지점",
              title.caseInsensitiveCompare("User location") != .orderedSame
        else {
            let names = Set(
                model.settings.frequentPlaces
                    .filter { $0.kind == .restaurant }
                    .map(\.name)
            )
            if !names.contains("식당") { return "식당" }
            var suffix = 2
            while names.contains("식당 \(suffix)") { suffix += 1 }
            return "식당 \(suffix)"
        }
        return title
    }

    private func saveTransit(_ kind: UserTransitLocationKind) {
        let cleanName = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let createdID = model.addUserTransitLocation(
            name: cleanName.isEmpty ? kind.title : cleanName,
            kind: kind,
            latitude: result.coordinate.latitude,
            longitude: result.coordinate.longitude,
            floor: floor
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
    @State private var floor = 1
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
                        "지하철역·버스정류장·기차역·공항·항구를 지도에서 관리합니다.",
                        "Manage subway stations, bus stops, train stations, airports, and harbors on the map."
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
                        language.text("역·정류장·공항·항구 검색", "Search transit location"),
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
                }
                .mapStyle(.standard(
                    elevation: .flat,
                    emphasis: .muted,
                    pointsOfInterest: .excludingAll,
                    showsTraffic: false
                ))
                .environment(\.colorScheme, .light)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.tpLine.opacity(0.7), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .topLeading) {
                    if let liveUserCoordinate,
                       let point = proxy.convert(liveUserCoordinate, to: .local) {
                        MapHomeHistoricalLocationMarker()
                            .position(point)
                            .accessibilityLabel(
                                language.text("현재 위치", "Current location")
                            )
                            .allowsHitTesting(false)
                    }
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
                            value.englishTitle
                        )
                    )
                    .tag(value)
                }
            }
            .pickerStyle(.segmented)

            Stepper(value: $floor, in: FloorCalibrationPrompt.range) {
                HStack {
                    Text(language.text("저장할 층수", "Floor to save"))
                    Spacer()
                    Text(FloorLabel.korean(floor))
                        .fontWeight(.bold)
                        .foregroundStyle(Color.tpReferenceBlue)
                }
            }
            .tint(Color.tpReferenceBlue)

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
                        "등록된 교통 위치가 없습니다.",
                        "No transit locations are saved."
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
                                        location.kind.englishTitle
                                    )
                                )
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                if let floor = location.floor {
                                    Text(FloorLabel.korean(floor))
                                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                                        .foregroundStyle(Color.tpReferenceBlue)
                                }
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

    private var liveUserCoordinate: CLLocationCoordinate2D? {
        let reading = MapCurrentLocationAnchorPolicy.latestValidReading(
            in: [model.latestSensorReading, model.liveRouteState.readings.last]
                .compactMap { $0 }
        )
        guard let point = reading?.point,
              point.latitude.isFinite,
              point.longitude.isFinite,
              (-90...90).contains(point.latitude),
              (-180...180).contains(point.longitude) else { return nil }
        return CLLocationCoordinate2D(
            latitude: point.latitude,
            longitude: point.longitude
        )
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
            longitude: selectedCoordinate.longitude,
            floor: floor
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
    @State private var floor: Int

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
        _floor = State(initialValue: location.floor ?? 1)
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
            Stepper(value: $floor, in: FloorCalibrationPrompt.range) {
                HStack {
                    Text(language.text("층수", "Floor"))
                    Spacer()
                    Text(FloorLabel.korean(floor))
                        .fontWeight(.bold)
                        .foregroundStyle(Color.tpReferenceBlue)
                }
            }
            .tint(Color.tpReferenceBlue)
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
                    model.setUserTransitLocationFloor(location.id, floor: floor)
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
        .presentationDetents([.height(270)])
    }
}

enum MapHomeAppleRouteFallbackPolicy {
    static func transports(
        for preferred: ExpectedRouteTransport
    ) -> [ExpectedRouteTransport] {
        switch preferred {
        case .automobile:
            [.automobile, .walking]
        case .transit:
            [.transit, .automobile, .walking]
        case .walking:
            [.walking, .automobile]
        }
    }
}

private enum MapHomeAppleRoutePhase {
    case actual
    case forecast
}

private enum MapHomeAppleRouteTransport: String {
    case automobile
    case transit
    case walking

    init(mode: TravelMode) {
        switch mode {
        case .car, .taxi:
            self = .automobile
        case .subway, .train, .bus:
            self = .transit
        case .walking, .running, .cycling, .airplane, .ship:
            self = .walking
        }
    }

}

private struct MapHomeAppleRoute {
    let id: String
    let coordinates: [CLLocationCoordinate2D]
    let colorHex: String
    let opacity: Double
    let phase: MapHomeAppleRoutePhase
    let transport: MapHomeAppleRouteTransport?
}

private enum MapHomeAppleAnnotationKind {
    case temporary(stationName: String, accessibilityLabel: String)
    case place(MapHomePlaceAnnotation)
    case transit(MapHomeTransitAnnotation)
    case boarding(TransitBoardingCandidate)
    case sticker(MapSticker)
    case search(MapHomeSearchResult)

    var accessibilityLabel: String {
        switch self {
        case .temporary(_, let accessibilityLabel):
            accessibilityLabel
        case .place(let place):
            place.destination == .user
                ? "\(place.name) 사용자 위치 메뉴"
                : "\(place.name), 레벨 \(place.floor ?? 1)"
        case .transit(let place):
            "\(place.name) 사용자 위치 메뉴"
        case .boarding(let candidate):
            "\(candidate.name) \(candidate.kind.title) 탑승 확인"
        case .sticker(let sticker):
            "\(sticker.title) 메모 스티커"
        case .search(let result):
            "\(result.title) 위치 추가"
        }
    }
}

private struct MapHomeAppleAnnotation {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let kind: MapHomeAppleAnnotationKind
    let isInteractive: Bool
}

private struct MapHomeApplePlayback {
    let coordinate: CLLocationCoordinate2D
    let cameraCoordinate: CLLocationCoordinate2D
    let headingDegrees: CLLocationDirection
    let action: MapHomeStickmanAction
    let accessibilityLabel: String
    let phase: MapHomeAppleRoutePhase
    let stickmanAnimationPhase: Int?
}

struct MapHomeAppleCenterCommand {
    let revision: Int
    let coordinate: CLLocationCoordinate2D
}

enum MapHomeAppleCameraCommand {
    @MainActor
    static func center(
        _ coordinate: CLLocationCoordinate2D,
        on mapView: MKMapView
    ) {
        mapView.setCenter(coordinate, animated: false)
    }
}

enum MapHomeApplePlaybackMath {
    private static let directionStep: CLLocationDirection = 45
    private static let lookAheadProgress = 0.01

    static func heading(
        at date: Date,
        departureDate: Date,
        arrivalDate: Date,
        coordinates: [CLLocationCoordinate2D]
    ) -> CLLocationDirection {
        guard coordinates.count >= 2 else { return 0 }
        let duration = arrivalDate.timeIntervalSince(departureDate)
        let progress = duration > 0
            ? min(max(date.timeIntervalSince(departureDate) / duration, 0), 1)
            : 1
        let currentCoordinate = coordinate(atProgress: progress, coordinates: coordinates)
        let lookAhead = coordinate(
            atProgress: min(1, progress + lookAheadProgress),
            coordinates: coordinates
        )
        if !sameLocation(currentCoordinate, lookAhead) {
            return stableHeading(
                MapHomeVectorNavigationMath.bearing(
                    from: currentCoordinate,
                    to: lookAhead
                )
            )
        }
        let lookBehind = coordinate(
            atProgress: max(0, progress - lookAheadProgress),
            coordinates: coordinates
        )
        return stableHeading(
            MapHomeVectorNavigationMath.bearing(
                from: lookBehind,
                to: currentCoordinate
            )
        )
    }

    static func stableHeading(_ heading: CLLocationDirection) -> CLLocationDirection {
        guard heading.isFinite else { return 0 }
        let normalized = heading.truncatingRemainder(dividingBy: 360) < 0
            ? heading.truncatingRemainder(dividingBy: 360) + 360
            : heading.truncatingRemainder(dividingBy: 360)
        let quantized = (normalized / directionStep).rounded() * directionStep
        return quantized >= 360 ? 0 : quantized
    }

    static func heading(
        at date: Date,
        readings: [SensorReading]
    ) -> CLLocationDirection? {
        let points = readings
            .compactMap { reading -> (Date, CLLocationCoordinate2D)? in
                guard let point = reading.point,
                      point.latitude.isFinite,
                      point.longitude.isFinite,
                      (-90...90).contains(point.latitude),
                      (-180...180).contains(point.longitude) else { return nil }
                return (
                    reading.timestamp,
                    CLLocationCoordinate2D(
                        latitude: point.latitude,
                        longitude: point.longitude
                    )
                )
            }
            .sorted { $0.0 < $1.0 }
        guard points.count >= 2 else { return nil }
        if let before = points.last(where: { $0.0 <= date }),
           let after = points.first(where: { $0.0 >= date }),
           before.1.latitude != after.1.latitude
                || before.1.longitude != after.1.longitude {
            return stableHeading(
                MapHomeVectorNavigationMath.bearing(from: before.1, to: after.1)
            )
        }
        return stableHeading(
            MapHomeVectorNavigationMath.bearing(
                from: points[points.count - 2].1,
                to: points[points.count - 1].1
            )
        )
    }

    private static func coordinate(
        atProgress progress: Double,
        coordinates: [CLLocationCoordinate2D]
    ) -> CLLocationCoordinate2D {
        let lengths = zip(coordinates, coordinates.dropFirst()).map {
            distance(from: $0.0, to: $0.1)
        }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return coordinates[0] }
        let target = total * min(max(progress, 0), 1)
        var traversed = 0.0
        for (index, length) in lengths.enumerated() where length > 0 {
            if traversed + length >= target {
                let next = coordinates[index + 1]
                let ratio = min(max((target - traversed) / length, 0), 1)
                return CLLocationCoordinate2D(
                    latitude: coordinates[index].latitude
                        + (next.latitude - coordinates[index].latitude) * ratio,
                    longitude: coordinates[index].longitude
                        + (next.longitude - coordinates[index].longitude) * ratio
                )
            }
            traversed += length
        }
        return coordinates[coordinates.count - 1]
    }

    private static func sameLocation(
        _ lhs: CLLocationCoordinate2D,
        _ rhs: CLLocationCoordinate2D
    ) -> Bool {
        lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude
    }

    private static func distance(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
    }
}

private final class MapHomeAppleMapAnnotation: NSObject, MKAnnotation {
    let identifier: String
    var kind: MapHomeAppleAnnotationKind
    var isInteractive: Bool
    dynamic var coordinate: CLLocationCoordinate2D

    init(annotation: MapHomeAppleAnnotation) {
        identifier = annotation.id
        kind = annotation.kind
        isInteractive = annotation.isInteractive
        coordinate = annotation.coordinate
        super.init()
    }

    var title: String? {
        kind.accessibilityLabel
    }

    func update(from annotation: MapHomeAppleAnnotation) {
        kind = annotation.kind
        isInteractive = annotation.isInteractive
        guard coordinate.latitude != annotation.coordinate.latitude
                || coordinate.longitude != annotation.coordinate.longitude else { return }
        coordinate = annotation.coordinate
    }
}

private final class MapHomeAppleWalkerAnnotation: NSObject, MKAnnotation {
    dynamic var coordinate: CLLocationCoordinate2D
    var headingDegrees: CLLocationDirection
    var action: MapHomeStickmanAction
    var label: String
    var phase: MapHomeAppleRoutePhase
    var stickmanAnimationPhase: Int?

    init(playback: MapHomeApplePlayback) {
        coordinate = playback.coordinate
        headingDegrees = playback.headingDegrees
        action = playback.action
        label = playback.accessibilityLabel
        phase = playback.phase
        stickmanAnimationPhase = playback.stickmanAnimationPhase
        super.init()
    }

    var title: String? { label }

    func update(with playback: MapHomeApplePlayback) {
        if coordinate.latitude != playback.coordinate.latitude
            || coordinate.longitude != playback.coordinate.longitude {
            coordinate = playback.coordinate
        }
        headingDegrees = playback.headingDegrees
        action = playback.action
        label = playback.accessibilityLabel
        phase = playback.phase
        stickmanAnimationPhase = playback.stickmanAnimationPhase
    }
}

private struct MapHomeAppleHostedDescriptor {
    let rootView: AnyView
    let size: CGSize
    let centerOffset: CGPoint
}

private final class MapHomeAppleHostedAnnotationView: MKAnnotationView {
    private var hostingController: UIHostingController<AnyView>?

    func update(
        rootView: AnyView,
        size: CGSize,
        centerOffset: CGPoint
    ) {
        if let hostingController {
            hostingController.rootView = rootView
        } else {
            let controller = UIHostingController(rootView: rootView)
            controller.view.backgroundColor = .clear
            controller.view.isOpaque = false
            addSubview(controller.view)
            hostingController = controller
        }
        bounds = CGRect(origin: .zero, size: size)
        hostingController?.view.frame = bounds
        hostingController?.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.centerOffset = centerOffset
        clipsToBounds = false
        canShowCallout = false
    }
}

private final class MapHomeAppleDirectionsHandle: @unchecked Sendable {
    let directions: MKDirections

    init(_ directions: MKDirections) {
        self.directions = directions
    }
}

private actor MapHomeAppleRouteResolver {
    static let shared = MapHomeAppleRouteResolver()

    private struct CacheKey: Hashable {
        let startLatitude: Int
        let startLongitude: Int
        let endLatitude: Int
        let endLongitude: Int
        let transport: ExpectedRouteTransport
    }

    private var cache: [CacheKey: [CLLocationCoordinate2D]] = [:]

    func resolve(
        start: CLLocationCoordinate2D,
        end: CLLocationCoordinate2D,
        transport: ExpectedRouteTransport,
        departureDate: Date
    ) async -> [CLLocationCoordinate2D]? {
        let key = CacheKey(
            startLatitude: Int((start.latitude * 100_000).rounded()),
            startLongitude: Int((start.longitude * 100_000).rounded()),
            endLatitude: Int((end.latitude * 100_000).rounded()),
            endLongitude: Int((end.longitude * 100_000).rounded()),
            transport: transport
        )
        if let cached = cache[key] {
            return cached
        }
        for candidate in MapHomeAppleRouteFallbackPolicy.transports(for: transport) {
            guard !Task.isCancelled else { return nil }
            if let coordinates = await calculate(
                start: start,
                end: end,
                transport: candidate,
                departureDate: departureDate
            ) {
                cache[key] = coordinates
                return coordinates
            }
        }
        return nil
    }

    private func calculate(
        start: CLLocationCoordinate2D,
        end: CLLocationCoordinate2D,
        transport: ExpectedRouteTransport,
        departureDate: Date
    ) async -> [CLLocationCoordinate2D]? {
        let request = MKDirections.Request()
        request.source = MKMapItem(
            placemark: MKPlacemark(coordinate: start)
        )
        request.destination = MKMapItem(
            placemark: MKPlacemark(coordinate: end)
        )
        request.requestsAlternateRoutes = false
        request.transportType = switch transport {
        case .automobile: .automobile
        case .transit: .transit
        case .walking: .walking
        }
        if transport == .transit {
            request.departureDate = departureDate
        }
        let handle = MapHomeAppleDirectionsHandle(MKDirections(request: request))
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                handle.directions.calculate { response, _ in
                    guard let route = response?.routes.min(by: {
                        $0.expectedTravelTime < $1.expectedTravelTime
                    }), route.polyline.pointCount > 1 else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let points = route.polyline.points()
                    continuation.resume(
                        returning: (0..<route.polyline.pointCount).map {
                            points[$0].coordinate
                        }
                    )
                }
            }
        }, onCancel: {
            handle.directions.cancel()
        })
    }
}

private struct MapHomeAppleMap: UIViewRepresentable {
    let style: MapDisplayStyle
    let cameraPosition: MapCameraPosition
    let cameraRevision: Int
    let centerCommand: MapHomeAppleCenterCommand?
    let routes: [MapHomeAppleRoute]
    let annotations: [MapHomeAppleAnnotation]
    let playback: MapHomeApplePlayback?
    let centersPlayback: Bool
    let contentInsets: UIEdgeInsets
    let onCameraFrame: (MapHomeCameraFrame, CGPoint?, Bool) -> Void
    let onSingleFingerPanBegan: () -> Void
    let onSingleFingerPanEnded: () -> Void
    let onLongPress: (CLLocationCoordinate2D) -> Void
    let onAnnotationSelected: (MapHomeAppleAnnotationKind) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.delegate = context.coordinator
        mapView.layoutMargins = contentInsets
        mapView.isRotateEnabled = true
        mapView.isPitchEnabled = true
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.showsTraffic = false
        mapView.showsUserLocation = true
        mapView.pointOfInterestFilter = .excludingAll
        mapView.accessibilityIdentifier = "MapHome.appleMap"
        mapView.accessibilityLabel = "Apple map"
        context.coordinator.attach(to: mapView)
        context.coordinator.applyMapStyle(to: mapView)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self
        mapView.layoutMargins = contentInsets
        context.coordinator.applyMapStyle(to: mapView)
        context.coordinator.updateContent(in: mapView)
        context.coordinator.applyCameraCommandIfNeeded(to: mapView)
        context.coordinator.applyCenterCommandIfNeeded(to: mapView)
    }

    static func dismantleUIView(_ mapView: MKMapView, coordinator: Coordinator) {
        coordinator.detach(from: mapView)
        mapView.delegate = nil
    }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: MapHomeAppleMap
        private weak var mapView: MKMapView?
        private var lastCameraRevision = Int.min
        private var lastCenterCommandRevision = 0
        private var lastRoutesSignature = ""
        private var routeStyles: [ObjectIdentifier: MapHomeAppleRouteStyle] = [:]
        private var walkerAnnotation: MapHomeAppleWalkerAnnotation?
        private var lastCenteredPlaybackCoordinate: CLLocationCoordinate2D?
        private var panGesture: UIPanGestureRecognizer?
        private var longPressGesture: UILongPressGestureRecognizer?

        init(parent: MapHomeAppleMap) {
            self.parent = parent
        }

        func attach(to mapView: MKMapView) {
            self.mapView = mapView
            let pan = UIPanGestureRecognizer(
                target: self,
                action: #selector(handlePan(_:))
            )
            pan.minimumNumberOfTouches = 1
            pan.maximumNumberOfTouches = 1
            pan.cancelsTouchesInView = false
            pan.delegate = self
            mapView.addGestureRecognizer(pan)
            panGesture = pan

            let longPress = UILongPressGestureRecognizer(
                target: self,
                action: #selector(handleLongPress(_:))
            )
            longPress.minimumPressDuration = 0.55
            longPress.allowableMovement = 12
            longPress.delegate = self
            mapView.addGestureRecognizer(longPress)
            longPressGesture = longPress
        }

        func detach(from mapView: MKMapView) {
            if let panGesture {
                mapView.removeGestureRecognizer(panGesture)
            }
            if let longPressGesture {
                mapView.removeGestureRecognizer(longPressGesture)
            }
            panGesture = nil
            longPressGesture = nil
            self.mapView = nil
        }

        func applyMapStyle(to mapView: MKMapView) {
            switch parent.style {
            case .hybrid:
                mapView.mapType = .hybrid
                let configuration = MKHybridMapConfiguration(elevationStyle: .realistic)
                configuration.pointOfInterestFilter = .excludingAll
                configuration.showsTraffic = false
                mapView.preferredConfiguration = configuration
            case .imagery:
                mapView.mapType = .satellite
                mapView.preferredConfiguration = MKImageryMapConfiguration(
                    elevationStyle: .realistic
                )
            case .standard, .simplified:
                mapView.mapType = .mutedStandard
                mapView.overrideUserInterfaceStyle = .light
                mapView.clipsToBounds = true
                mapView.layer.masksToBounds = true
                mapView.backgroundColor = UIColor(hex: MapHomeWBSTripStyle.paperHex)
                let configuration = MKStandardMapConfiguration(
                    elevationStyle: .flat,
                    emphasisStyle: .muted
                )
                configuration.pointOfInterestFilter = .excludingAll
                configuration.showsTraffic = false
                mapView.preferredConfiguration = configuration
            case .mapLibreNight, .mapLibreLight, .mapLibreContrast,
                 .mapLibrePastel, .mapLibreCasual:
                break
            }
            mapView.pointOfInterestFilter = .excludingAll
            mapView.showsTraffic = false
        }

        func updateContent(in mapView: MKMapView) {
            updateRoutes(in: mapView)
            updateAnnotations(in: mapView)
            updateWalker(in: mapView)
        }

        func applyCameraCommandIfNeeded(to mapView: MKMapView) {
            guard lastCameraRevision != parent.cameraRevision else { return }
            lastCameraRevision = parent.cameraRevision

            if let region = parent.cameraPosition.region {
                mapView.setRegion(region, animated: false)
            } else if let camera = parent.cameraPosition.camera {
                mapView.setCamera(
                    MKMapCamera(
                        lookingAtCenter: camera.centerCoordinate,
                        fromDistance: camera.distance,
                        pitch: camera.pitch,
                        heading: camera.heading
                    ),
                    animated: false
                )
            } else if let coordinate = parent.playback?.cameraCoordinate {
                mapView.setCenter(coordinate, animated: false)
            } else if let coordinate = parent.routes.first?.coordinates.first {
                mapView.setCenter(coordinate, animated: false)
            }
            publishCameraFrame(from: mapView, isFinal: true)
        }

        func applyCenterCommandIfNeeded(to mapView: MKMapView) {
            guard let command = parent.centerCommand,
                  command.revision != lastCenterCommandRevision else { return }
            lastCenterCommandRevision = command.revision
            MapHomeAppleCameraCommand.center(command.coordinate, on: mapView)
            publishCameraFrame(from: mapView, isFinal: true)
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            publishCameraFrame(from: mapView, isFinal: false)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            publishCameraFrame(from: mapView, isFinal: true)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let walker = annotation as? MapHomeAppleWalkerAnnotation {
                let reuseIdentifier = "MapHome.appleWalker"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseIdentifier)
                    as? MapHomeAppleHostedAnnotationView)
                    ?? MapHomeAppleHostedAnnotationView(
                        annotation: walker,
                        reuseIdentifier: reuseIdentifier
                    )
                configureWalker(view, annotation: walker)
                return view
            }
            guard let annotation = annotation as? MapHomeAppleMapAnnotation else {
                return nil
            }
            let reuseIdentifier = "MapHome.appleAnnotation"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseIdentifier)
                as? MapHomeAppleHostedAnnotationView)
                ?? MapHomeAppleHostedAnnotationView(
                    annotation: annotation,
                    reuseIdentifier: reuseIdentifier
                )
            configure(view, annotation: annotation)
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation as? MapHomeAppleMapAnnotation else {
                return
            }
            if annotation.isInteractive {
                parent.onAnnotationSelected(annotation.kind)
            }
            mapView.deselectAnnotation(annotation, animated: false)
        }

        func mapView(
            _ mapView: MKMapView,
            rendererFor overlay: MKOverlay
        ) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline,
                  let style = routeStyles[ObjectIdentifier(polyline)] else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = style.color.withAlphaComponent(style.opacity)
            renderer.lineWidth = style.lineWidth
            renderer.lineCap = .round
            renderer.lineJoin = .round
            if style.dashed {
                renderer.lineDashPattern = MapHomeWBSTripStyle.routeDash
            }
            return renderer
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            if gestureRecognizer === longPressGesture {
                return true
            }
            var view: UIView? = touch.view
            while let current = view {
                if current is MKAnnotationView { return false }
                view = current.superview
            }
            return true
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard gesture.numberOfTouches <= 1 else { return }
            switch gesture.state {
            case .began:
                parent.onSingleFingerPanBegan()
            case .ended, .cancelled, .failed:
                parent.onSingleFingerPanEnded()
            default:
                break
            }
        }

        @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began,
                  let mapView else { return }
            parent.onLongPress(
                mapView.convert(
                    gesture.location(in: mapView),
                    toCoordinateFrom: mapView
                )
            )
        }

        private func updateRoutes(in mapView: MKMapView) {
            let signature = parent.routes.map { route in
                let first = route.coordinates.first
                let last = route.coordinates.last
                return [
                    route.id,
                    route.phase == .actual ? "actual" : "forecast",
                    String(route.coordinates.count),
                    String(first?.latitude ?? 0),
                    String(first?.longitude ?? 0),
                    String(last?.latitude ?? 0),
                    String(last?.longitude ?? 0),
                    route.colorHex,
                    String(route.opacity),
                ].joined(separator: "|")
            }.joined(separator: ";")
            guard signature != lastRoutesSignature else { return }
            lastRoutesSignature = signature
            mapView.removeOverlays(mapView.overlays)
            routeStyles.removeAll(keepingCapacity: true)
            let polylines = parent.routes.compactMap { route -> MKPolyline? in
                guard route.coordinates.count >= 2 else { return nil }
                var coordinates = route.coordinates
                let polyline = MKPolyline(
                    coordinates: &coordinates,
                    count: coordinates.count
                )
                routeStyles[ObjectIdentifier(polyline)] = MapHomeAppleRouteStyle(
                    color: UIColor(hex: route.colorHex),
                    opacity: CGFloat(min(max(route.opacity, 0), 1)),
                    lineWidth: route.phase == .actual
                        ? MapHomeWBSTripStyle.actualRouteLineWidth
                        : MapHomeWBSTripStyle.forecastRouteLineWidth,
                    dashed: route.phase == .forecast
                )
                return polyline
            }
            guard !polylines.isEmpty else { return }
            mapView.addOverlays(polylines, level: .aboveRoads)
        }

        private func updateAnnotations(in mapView: MKMapView) {
            let existing = mapView.annotations.compactMap { $0 as? MapHomeAppleMapAnnotation }
            let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.identifier, $0) })
            let wantedIDs = Set(parent.annotations.map(\.id))
            let removed = existing.filter { !wantedIDs.contains($0.identifier) }
            if !removed.isEmpty {
                mapView.removeAnnotations(removed)
            }
            for annotation in parent.annotations {
                if let existing = byID[annotation.id] {
                    existing.update(from: annotation)
                    if let view = mapView.view(for: existing) as? MapHomeAppleHostedAnnotationView {
                        configure(view, annotation: existing)
                    }
                } else {
                    mapView.addAnnotation(MapHomeAppleMapAnnotation(annotation: annotation))
                }
            }
        }

        private func updateWalker(in mapView: MKMapView) {
            guard let playback = parent.playback else {
                if let walkerAnnotation {
                    mapView.removeAnnotation(walkerAnnotation)
                }
                walkerAnnotation = nil
                lastCenteredPlaybackCoordinate = nil
                return
            }
            let walker: MapHomeAppleWalkerAnnotation
            if let walkerAnnotation {
                walker = walkerAnnotation
                walker.update(with: playback)
            } else {
                walker = MapHomeAppleWalkerAnnotation(playback: playback)
                walkerAnnotation = walker
                mapView.addAnnotation(walker)
            }
            if let view = mapView.view(for: walker) as? MapHomeAppleHostedAnnotationView {
                configureWalker(view, annotation: walker)
            }
            if parent.centersPlayback,
               shouldCenterPlayback(at: playback.cameraCoordinate) {
                mapView.setCenter(playback.cameraCoordinate, animated: false)
            }
        }

        private func shouldCenterPlayback(
            at coordinate: CLLocationCoordinate2D
        ) -> Bool {
            defer { lastCenteredPlaybackCoordinate = coordinate }
            guard let lastCenteredPlaybackCoordinate else { return true }
            return abs(lastCenteredPlaybackCoordinate.latitude - coordinate.latitude) > 0.000_001
                || abs(lastCenteredPlaybackCoordinate.longitude - coordinate.longitude) > 0.000_001
        }

        private func configureWalker(
            _ view: MapHomeAppleHostedAnnotationView,
            annotation: MapHomeAppleWalkerAnnotation
        ) {
            view.annotation = annotation
            view.update(
                rootView: AnyView(
                    MapHomeStickmanMarker(
                        action: annotation.action,
                        animationPhase: annotation.stickmanAnimationPhase,
                        routePhase: annotation.phase == .forecast
                            ? .forecast
                            : .actual
                    )
                ),
                size: MapHomeStickmanMarker.size,
                centerOffset: .zero
            )
            UIView.performWithoutAnimation {
                view.transform = .identity
            }
            view.isEnabled = false
            view.isAccessibilityElement = true
            view.accessibilityTraits = .image
            view.accessibilityLabel = annotation.label
        }

        private func configure(
            _ view: MapHomeAppleHostedAnnotationView,
            annotation: MapHomeAppleMapAnnotation
        ) {
            let descriptor = descriptor(for: annotation.kind)
            view.annotation = annotation
            view.update(
                rootView: descriptor.rootView,
                size: descriptor.size,
                centerOffset: descriptor.centerOffset
            )
            view.transform = .identity
            view.isEnabled = annotation.isInteractive
            view.isAccessibilityElement = true
            view.accessibilityTraits = annotation.isInteractive ? .button : .image
            view.accessibilityIdentifier = "MapHome.appleAnnotation.\(annotation.identifier)"
            view.accessibilityLabel = annotation.kind.accessibilityLabel
        }

        private func descriptor(
            for kind: MapHomeAppleAnnotationKind
        ) -> MapHomeAppleHostedDescriptor {
            switch kind {
            case .temporary(let stationName, _):
                return MapHomeAppleHostedDescriptor(
                    rootView: AnyView(
                        VStack(spacing: 2) {
                            Image(systemName: "tram.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.tpReferenceBlue.opacity(0.72))
                            Text("임시 위치")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.tpInk.opacity(0.72))
                        }
                        .padding(5)
                        .background(Color.tpSurface.opacity(0.66), in: Capsule())
                        .overlay {
                            Capsule().stroke(
                                Color.tpReferenceBlue.opacity(0.45),
                                style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                            )
                        }
                        .accessibilityLabel("\(stationName) 지하철 임시 위치")
                    ),
                    size: CGSize(width: 92, height: 36),
                    centerOffset: CGPoint(x: 0, y: -18)
                )
            case .place(let place):
                return MapHomeAppleHostedDescriptor(
                    rootView: AnyView(
                        MapHomePlacePin(
                            name: place.name,
                            floor: place.floor,
                            destination: place.destination
                        )
                        .fixedSize()
                    ),
                    size: CGSize(width: 130, height: 138),
                    centerOffset: CGPoint(x: 0, y: -69)
                )
            case .transit(let place):
                return MapHomeAppleHostedDescriptor(
                    rootView: AnyView(
                        MapHomeTransitPlacePin(name: place.name, kind: place.kind)
                            .fixedSize()
                    ),
                    size: CGSize(width: 132, height: 70),
                    centerOffset: CGPoint(x: 0, y: -35)
                )
            case .boarding(let candidate):
                return MapHomeAppleHostedDescriptor(
                    rootView: AnyView(
                        MapHomeTransitBoardingCandidatePin(
                            name: candidate.name,
                            kind: candidate.kind
                        )
                        .fixedSize()
                    ),
                    size: CGSize(width: 145, height: 72),
                    centerOffset: CGPoint(x: 0, y: -36)
                )
            case .sticker(let sticker):
                return MapHomeAppleHostedDescriptor(
                    rootView: AnyView(MapHomeMapStickerMarker(sticker: sticker)),
                    size: CGSize(width: 150, height: 52),
                    centerOffset: CGPoint(x: 0, y: -26)
                )
            case .search:
                return MapHomeAppleHostedDescriptor(
                    rootView: AnyView(
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 36, weight: .bold))
                            .foregroundStyle(Color.tpPastelRose)
                            .background(Circle().fill(.white))
                    ),
                    size: CGSize(width: 48, height: 48),
                    centerOffset: CGPoint(x: 0, y: -24)
                )
            }
        }

        private func publishCameraFrame(
            from mapView: MKMapView,
            isFinal: Bool
        ) {
            let camera = MapCamera(
                centerCoordinate: mapView.camera.centerCoordinate,
                distance: max(mapView.camera.altitude, 1),
                heading: mapView.camera.heading,
                pitch: mapView.camera.pitch
            )
            let frame = MapHomeCameraFrame(
                camera: camera,
                region: mapView.region
            )
            let locationPoint = walkerAnnotation.map {
                mapView.convert($0.coordinate, toPointTo: mapView)
            }
            parent.onCameraFrame(frame, locationPoint, isFinal)
        }
    }
}

private struct MapHomeAppleRouteStyle {
    let color: UIColor
    let opacity: CGFloat
    let lineWidth: CGFloat
    let dashed: Bool
}

private extension UIColor {
    convenience init(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var integer: UInt64 = 0
        Scanner(string: value).scanHexInt64(&integer)
        let red = CGFloat((integer >> 16) & 0xFF) / 255
        let green = CGFloat((integer >> 8) & 0xFF) / 255
        let blue = CGFloat(integer & 0xFF) / 255
        self.init(red: red, green: green, blue: blue, alpha: 1)
    }
}
